'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const express = require('express');
const { rateLimit } = require('express-rate-limit');
const multer = require('multer');
const bcrypt = require('bcryptjs');
const { pool } = require('./db');

const app = express();
const port = Number(process.env.PORT || 3000);
const frontendOrigin = process.env.FRONTEND_ORIGIN ? (() => {
    const origin = new URL(process.env.FRONTEND_ORIGIN);
    if (!['http:', 'https:'].includes(origin.protocol)) {
        throw new Error('FRONTEND_ORIGIN must use http or https');
    }
    return origin.origin;
})() : null;
const sessionDays = 7;
const uploadDirectory = path.join(__dirname, 'uploads');
const maxUploadMb = Number(process.env.MAX_UPLOAD_MB || 100);
const allowedVideoTypes = new Map([
    ['video/mp4', '.mp4'],
    ['video/x-m4v', '.mp4'],
    ['video/webm', '.webm'],
    ['video/quicktime', '.mov']
]);
const allowedVideoExtensions = new Map([
    ['.mp4', '.mp4'],
    ['.webm', '.webm'],
    ['.mov', '.mov']
]);

function videoExtension(file) {
    const mimeExtension = allowedVideoTypes.get(file.mimetype);
    if (mimeExtension) return mimeExtension;
    if (!file.mimetype || file.mimetype === 'application/octet-stream') {
        return allowedVideoExtensions.get(path.extname(file.originalname).toLowerCase()) || null;
    }
    return null;
}

if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error('PORT must be an integer between 1 and 65535');
}
if (!Number.isInteger(maxUploadMb) || maxUploadMb < 1 || maxUploadMb > 1024) {
    throw new Error('MAX_UPLOAD_MB must be an integer between 1 and 1024');
}
fs.mkdirSync(uploadDirectory, { recursive: true });

app.disable('x-powered-by');
app.use(express.json({ limit: '32kb' }));
app.use((req, res, next) => {
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
    next();
});

app.use('/api', (req, res, next) => {
    const origin = req.get('origin');
    if (origin && isAllowedFrontendOrigin(origin, req)) {
        res.setHeader('Access-Control-Allow-Origin', origin);
        res.setHeader('Access-Control-Allow-Credentials', 'true');
        res.setHeader('Vary', 'Origin');
        if (req.method === 'OPTIONS') {
            res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PATCH, OPTIONS');
            res.setHeader('Access-Control-Allow-Headers', 'Accept, Content-Type');
            return res.sendStatus(204);
        }
    }
    next();
});

app.use('/api', (req, res, next) => {
    if (req.method === 'GET' || req.method === 'HEAD' || req.method === 'OPTIONS') return next();
    const origin = req.get('origin');
    if (!origin) return sendError(res, 403, 'A same-origin request is required.');
    if (!isAllowedFrontendOrigin(origin, req)) return sendError(res, 403, 'Cross-origin requests are not allowed.');
    next();
});

const authRateLimit = rateLimit({
    windowMs: 15 * 60 * 1000,
    limit: 10,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    message: { error: 'Too many sign-in attempts. Please try again later.' }
});

function asyncRoute(handler) {
    return (req, res, next) => Promise.resolve(handler(req, res, next)).catch(next);
}

function sendError(res, status, message) {
    return res.status(status).json({ error: message });
}

function isAllowedFrontendOrigin(origin, req) {
    try {
        const parsedOrigin = new URL(origin);
        if (!['http:', 'https:'].includes(parsedOrigin.protocol)) return false;
        if (parsedOrigin.host === req.get('host')) return true;
        if (frontendOrigin && parsedOrigin.origin === frontendOrigin) return true;
        if (process.env.NODE_ENV === 'production') return false;

        const requestHostname = new URL(`http://${req.get('host')}`).hostname.replace(/^\[|\]$/g, '');
        const frontendHostname = parsedOrigin.hostname.replace(/^\[|\]$/g, '');
        const loopbackHosts = new Set(['localhost', '127.0.0.1', '::1']);
        return loopbackHosts.has(frontendHostname) && loopbackHosts.has(requestHostname);
    } catch {
        return false;
    }
}

function removeUploadedFile(filePath) {
    fs.unlink(filePath, (error) => {
        if (error && error.code !== 'ENOENT') console.error('Could not remove rejected upload:', error);
    });
}

function sessionCookie(token, maxAgeSeconds) {
    const secure = process.env.NODE_ENV === 'production' ? '; Secure' : '';
    return `inganzo_session=${token}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${maxAgeSeconds}${secure}`;
}

function sessionToken(req) {
    const cookie = req.headers.cookie || '';
    const match = cookie.match(/(?:^|;\s*)inganzo_session=([a-f0-9]{64})(?:;|$)/);
    return match ? match[1] : null;
}

async function optionalAuth(req, res, next) {
    try {
        const token = sessionToken(req);
        if (!token) {
            req.user = null;
            return next();
        }
        const tokenHash = crypto.createHash('sha256').update(token).digest('hex');
        const [rows] = await pool.execute(
            `SELECT u.id, u.username, u.display_name, u.bio, u.country_code, u.lang
               FROM user_sessions s
               JOIN users u ON u.id = s.user_id
              WHERE s.token_hash = ? AND s.revoked_at IS NULL
                AND s.expires_at > NOW() AND u.status = 'active'
              LIMIT 1`,
            [tokenHash]
        );
        req.user = rows[0] || null;
        next();
    } catch (error) {
        next(error);
    }
}

app.use('/api', optionalAuth);

app.get('/api/health', asyncRoute(async (req, res) => {
    await pool.query('SELECT 1');
    res.json({ status: 'ok', database: 'connected' });
}));

// Feed endpoint – returns all cultural items for the front‑end feed
app.get('/api/feed', asyncRoute(async (req, res) => {
    const [rows] = await pool.query(`
        SELECT i.title, i.video_url, c.name AS country
        FROM items i
        JOIN countries c ON i.country_id = c.id
        ORDER BY i.id DESC
    `);
    res.json({ success: true, count: rows.length, data: rows });
}));

function requireAuth(req, res, next) {
    if (!req.user) return sendError(res, 401, 'Sign in to use this feature.');
    next();
}

function positiveId(value) {
    return /^\d+$/.test(String(value)) && Number(value) > 0 ? String(value) : null;
}

function publicUser(user) {
    return {
        id: Number(user.id),
        handle: user.username,
        displayName: user.display_name || '',
        bio: user.bio || '',
        country: user.country_code
    };
}

async function createSession(req, res, userId) {
    const token = crypto.randomBytes(32).toString('hex');
    const tokenHash = crypto.createHash('sha256').update(token).digest('hex');
    await pool.execute(
        `INSERT INTO user_sessions (user_id, token_hash, user_agent, ip, expires_at)
         VALUES (?, ?, ?, INET6_ATON(?), DATE_ADD(NOW(), INTERVAL ${sessionDays} DAY))`,
        [userId, tokenHash, (req.get('user-agent') || '').slice(0, 255) || null, req.ip]
    );
    res.setHeader('Set-Cookie', sessionCookie(token, sessionDays * 86400));
}

app.get('/api/me', asyncRoute(async (req, res) => {
    if (!req.user) return res.json({ user: null, liked: [], saved: [], following: [] });
    const [[likedRows], [savedRows], [followingRows]] = await Promise.all([
        pool.execute('SELECT video_id FROM video_likes WHERE user_id = ?', [req.user.id]),
    pool.execute('SELECT video_id FROM video_saves WHERE user_id = ?', [req.user.id]),
    pool.execute(
        `SELECT u.username FROM follows f JOIN users u ON u.id = f.followee_id
              WHERE f.follower_id = ?`,
            [req.user.id]
        )
    ]);
    res.json({
        user: publicUser(req.user),
        liked: likedRows.map((row) => Number(row.video_id)),
        saved: savedRows.map((row) => Number(row.video_id)),
        following: followingRows.map((row) => row.username)
    });
}));

app.patch('/api/me', requireAuth, asyncRoute(async (req, res) => {
    const displayName = typeof req.body.displayName === 'string' ? req.body.displayName.trim() : '';
    const bio = typeof req.body.bio === 'string' ? req.body.bio.trim() : '';
    const country = typeof req.body.country === 'string' ? req.body.country.toUpperCase() : '';

    if (displayName.length > 60) return sendError(res, 400, 'Display name must be 60 characters or fewer.');
    if (bio.length > 160) return sendError(res, 400, 'Bio must be 160 characters or fewer.');
    const [countryRows] = await pool.execute('SELECT code FROM countries WHERE code = ? AND is_active = 1', [country]);
    if (!countryRows.length) return sendError(res, 400, 'Choose an available country.');

    await pool.execute(
        'UPDATE users SET display_name = ?, bio = ?, country_code = ? WHERE id = ?',
        [displayName || null, bio || null, country, req.user.id]
    );
    res.json({
        user: publicUser(Object.assign({}, req.user, {
            display_name: displayName || null,
            bio: bio || null,
            country_code: country
        }))
    });
}));

app.get('/api/me/videos', requireAuth, asyncRoute(async (req, res) => {
    const limit = Math.min(Math.max(Number.parseInt(req.query.limit, 10) || 20, 1), 50);
    const offset = Math.min(Math.max(Number.parseInt(req.query.offset, 10) || 0, 0), 1000000);
    const [rows] = await pool.execute(
        `SELECT v.id, v.title, v.description, v.video_url, v.country_code,
                v.category_slug, v.status, v.like_count, v.comment_count,
                v.share_count, v.view_count, v.created_at, v.mime_type, v.size_bytes,
                c.name_rw AS country_name
           FROM videos v
           JOIN countries c ON c.code = v.country_code
          WHERE v.user_id = ?
          ORDER BY v.created_at DESC, v.id DESC
          LIMIT ? OFFSET ?`,
        [req.user.id, limit, offset]
    );
    res.json(rows.map((row) => ({
        id: Number(row.id),
        title: row.title,
        description: row.description,
        url: row.video_url,
        country: row.country_code,
        countryName: row.country_name,
        category: row.category_slug,
        status: row.status,
        likes: Number(row.like_count),
        comments: Number(row.comment_count),
        shares: Number(row.share_count),
        views: Number(row.view_count),
        createdAt: row.created_at,
        mimeType: row.mime_type,
        sizeBytes: row.size_bytes == null ? null : Number(row.size_bytes)
    })));
}));

app.post('/api/auth/signup', authRateLimit, asyncRoute(async (req, res) => {
    const username = typeof req.body.username === 'string' ? req.body.username.trim() : '';
    const identifier = typeof req.body.identifier === 'string' ? req.body.identifier.trim() : '';
    const password = typeof req.body.password === 'string' ? req.body.password : '';
    const country = typeof req.body.country === 'string' ? req.body.country.toUpperCase() : '';
    const phone = req.body.method === 'phone';

    if (!/^[A-Za-z0-9_]{3,24}$/.test(username)) return sendError(res, 400, 'Username must be 3–24 letters, digits, or underscores.');
    if (password.length < 8 || password.length > 128) return sendError(res, 400, 'Password must be between 8 and 128 characters.');
    if (phone
        ? identifier.length > 20 || !/^\+?[0-9]{7,15}$/.test(identifier.replace(/[\s().-]/g, ''))
        : identifier.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(identifier)) {
        return sendError(res, 400, 'Enter a valid email address or phone number.');
    }

    const normalizedPhone = phone ? identifier.replace(/[\s().-]/g, '') : null;
    const normalizedEmail = phone ? null : identifier.toLowerCase();
    const [countryRows] = await pool.execute('SELECT code FROM countries WHERE code = ? AND is_active = 1', [country]);
    if (!countryRows.length) return sendError(res, 400, 'Choose an available country.');

    const passwordHash = await bcrypt.hash(password, 12);
    let result;
    try {
        [result] = await pool.execute(
            `INSERT INTO users (username, email, phone, password_hash, country_code, lang)
             VALUES (?, ?, ?, ?, ?, ?)`,
            [username, normalizedEmail, normalizedPhone, passwordHash, country, req.body.lang === 'en' ? 'en' : 'rw']
        );
    } catch (error) {
        if (error.code === 'ER_DUP_ENTRY') return sendError(res, 409, 'That username, email, or phone number is already registered.');
        throw error;
    }

    await createSession(req, res, result.insertId);
    res.status(201).json({ user: { id: Number(result.insertId), handle: username, country } });
}));

app.post('/api/auth/login', authRateLimit, asyncRoute(async (req, res) => {
    const identifier = typeof req.body.identifier === 'string' ? req.body.identifier.trim() : '';
    const password = typeof req.body.password === 'string' ? req.body.password : '';
    const phone = req.body.method === 'phone';
    const normalizedPhone = identifier.replace(/[\s().-]/g, '');
    const lookupField = phone ? 'phone' : 'email';
    const lookupValue = phone ? normalizedPhone : identifier.toLowerCase();
    const [rows] = await pool.execute(
        `SELECT id, username, country_code, password_hash, status
           FROM users WHERE ${lookupField} = ? AND is_demo = 0 LIMIT 1`,
        [lookupValue]
    );
    const user = rows[0];
    if (!password || password.length > 128 || !user || user.status !== 'active' || !(await bcrypt.compare(password, user.password_hash))) {
        return sendError(res, 401, 'Incorrect sign-in details.');
    }
    await pool.execute('UPDATE users SET last_login_at = NOW() WHERE id = ?', [user.id]);
    await createSession(req, res, user.id);
    res.json({ user: publicUser(user) });
}));

app.post('/api/auth/logout', asyncRoute(async (req, res) => {
    const token = sessionToken(req);
    if (token) {
        const tokenHash = crypto.createHash('sha256').update(token).digest('hex');
        await pool.execute(
            'UPDATE user_sessions SET revoked_at = NOW() WHERE token_hash = ? AND revoked_at IS NULL',
            [tokenHash]
        );
    }
    res.setHeader('Set-Cookie', sessionCookie('', 0));
    res.json({ ok: true });
}));

app.get('/api/videos', asyncRoute(async (req, res) => {
    const where = ['1 = 1'];
    const params = [];
    if (req.query.country) {
        where.push('f.country_code = ?');
        params.push(String(req.query.country).toUpperCase());
    }
    if (req.query.category) {
        where.push('f.category = ?');
        params.push(String(req.query.category));
    }
    if (req.query.tab === 'local') {
        where.push('f.country_code = ?');
        params.push(String(req.query.me || 'RW').toUpperCase());
    } else if (req.query.tab === 'following') {
        if (!req.user) return res.json([]);
        where.push('EXISTS (SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = f.user_id)');
        params.push(req.user.id);
    }
    if (req.query.q) {
        const search = `%${String(req.query.q).slice(0, 100)}%`;
        where.push(`(f.title LIKE ? OR f.description LIKE ? OR EXISTS (
            SELECT 1 FROM video_hashtags vh JOIN hashtags h ON h.id = vh.hashtag_id
             WHERE vh.video_id = f.id AND h.tag LIKE ?
        ))`);
        params.push(search, search, search);
    }
    const limit = Math.min(Math.max(Number.parseInt(req.query.limit, 10) || 50, 1), 100);
    const offset = Math.min(Math.max(Number.parseInt(req.query.offset, 10) || 0, 0), 1000000);
    const viewerId = req.user ? req.user.id : null;
    const [rows] = await pool.execute(
        `SELECT f.*,
                IF(? IS NOT NULL AND EXISTS (
                    SELECT 1 FROM video_likes l WHERE l.user_id = ? AND l.video_id = f.id
                ), 1, 0) AS liked_by_me,
                IF(? IS NOT NULL AND EXISTS (
                    SELECT 1 FROM follows fo WHERE fo.follower_id = ? AND fo.followee_id = f.user_id
                ), 1, 0) AS following_creator
           FROM v_video_feed f
          WHERE ${where.join(' AND ')}
          ORDER BY (f.country_code = ?) DESC, f.created_at DESC, f.id DESC
          LIMIT ? OFFSET ?`,
        [viewerId, viewerId, viewerId, viewerId, ...params, String(req.query.me || 'RW').toUpperCase(), limit, offset]
    );
    res.json(rows.map((row) => ({
        id: Number(row.id),
        c: row.country_code,
        cat: row.category,
        title: row.title,
        desc: row.description,
        h: row.handle,
        uid: Number(row.user_id),
        likes: Number(row.like_count),
        cm: Number(row.comment_count),
        sh: Number(row.share_count),
        tags: row.tags ? row.tags.split(',') : [],
        src: row.video_url,
        liked: Boolean(row.liked_by_me),
        following: Boolean(row.following_creator)
    })));
}));

const uploadRateLimit = rateLimit({
    windowMs: 60 * 60 * 1000,
    limit: 10,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    message: { error: 'Upload limit reached. Please try again later.' }
});

app.post('/api/videos', requireAuth, uploadRateLimit, (req, res, next) => {
    const storage = multer.diskStorage({
        destination: uploadDirectory,
        filename: (request, file, callback) => callback(null, `${crypto.randomUUID()}${videoExtension(file) || '.bin'}`)
    });
    const upload = multer({
        storage,
        limits: { fileSize: maxUploadMb * 1024 * 1024, files: 1 },
        fileFilter: (request, file, callback) => {
            if (!videoExtension(file)) return callback(new Error('Upload an MP4, WebM, or MOV video.'));
            callback(null, true);
        }
    }).single('video');

    upload(req, res, (error) => {
        if (error) return next(error);
        next();
    });
}, asyncRoute(async (req, res) => {
    if (!req.file) return sendError(res, 400, 'Choose a video to upload.');
    const country = typeof req.body.country === 'string' ? req.body.country.toUpperCase() : '';
    const category = typeof req.body.category === 'string' ? req.body.category : '';
    const title = typeof req.body.title === 'string' ? req.body.title.trim() : '';
    const description = typeof req.body.description === 'string' ? req.body.description.trim() : '';
    const tags = typeof req.body.tags === 'string' ? req.body.tags.split(',').slice(0, 4) : [];
    if (!title || title.length > 80 || description.length > 240) {
        removeUploadedFile(req.file.path);
        return sendError(res, 400, 'Enter a title (up to 80 characters) and description (up to 240 characters).');
    }

    let connection;
    let transactionStarted = false;
    try {
        connection = await pool.getConnection();
        await connection.beginTransaction();
        transactionStarted = true;
        const [result] = await connection.execute(
            `INSERT INTO videos
                (user_id, country_code, category_slug, title, description, video_url, storage_key, mime_type, size_bytes)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
            [
                req.user.id, country, category, title, description,
                `/uploads/${path.basename(req.file.filename)}`, req.file.filename,
                req.file.mimetype, req.file.size
            ]
        );
        for (const [index, rawTag] of tags.entries()) {
            const tag = rawTag.trim().replace(/^#/, '').slice(0, 40);
            if (!tag) continue;
            await connection.execute('INSERT IGNORE INTO hashtags (tag) VALUES (?)', [tag]);
            const [tagRows] = await connection.execute('SELECT id FROM hashtags WHERE tag = ?', [tag]);
            await connection.execute(
                'INSERT IGNORE INTO video_hashtags (video_id, hashtag_id, pos) VALUES (?, ?, ?)',
                [result.insertId, tagRows[0].id, index]
            );
        }
        await connection.commit();
        transactionStarted = false;
        res.status(201).json({ id: Number(result.insertId), url: `/uploads/${path.basename(req.file.filename)}` });
    } catch (error) {
        if (connection && transactionStarted) {
            try {
                await connection.rollback();
            } catch (rollbackError) {
                console.error('Could not roll back video upload:', rollbackError);
            }
        }
        removeUploadedFile(req.file.path);
        if (error.code === 'ER_NO_REFERENCED_ROW_2') return sendError(res, 400, 'Choose an available country and category.');
        throw error;
    } finally {
        if (connection) connection.release();
    }
}));

app.post('/api/videos/:id/like', requireAuth, asyncRoute(async (req, res) => {
    const videoId = positiveId(req.params.id);
    if (!videoId) return sendError(res, 400, 'Invalid video id.');
    const connection = await pool.getConnection();
    try {
        await connection.beginTransaction();
        const [videos] = await connection.execute('SELECT id FROM videos WHERE id = ? AND status = ? FOR UPDATE', [videoId, 'published']);
        if (!videos.length) {
            await connection.rollback();
            return sendError(res, 404, 'Video not found.');
        }
        const [removed] = await connection.execute('DELETE FROM video_likes WHERE user_id = ? AND video_id = ?', [req.user.id, videoId]);
        const liked = removed.affectedRows === 0;
        if (liked) await connection.execute('INSERT INTO video_likes (user_id, video_id) VALUES (?, ?)', [req.user.id, videoId]);
        const [countRows] = await connection.execute('SELECT like_count FROM videos WHERE id = ?', [videoId]);
        await connection.commit();
        res.json({ liked, likes: Number(countRows[0].like_count) });
    } catch (error) {
        await connection.rollback();
        throw error;
    } finally {
        connection.release();
    }
}));

app.post('/api/videos/:id/save', requireAuth, asyncRoute(async (req, res) => {
    const videoId = positiveId(req.params.id);
    if (!videoId) return sendError(res, 400, 'Invalid video id.');
    const connection = await pool.getConnection();
    try {
        await connection.beginTransaction();
        const [videos] = await connection.execute(
            'SELECT id FROM videos WHERE id = ? AND status = ? FOR UPDATE',
            [videoId, 'published']
        );
        if (!videos.length) {
            await connection.rollback();
            return sendError(res, 404, 'Video not found.');
        }
        const [removed] = await connection.execute(
            'DELETE FROM video_saves WHERE user_id = ? AND video_id = ?',
            [req.user.id, videoId]
        );
        const saved = removed.affectedRows === 0;
        if (saved) {
            await connection.execute(
                'INSERT INTO video_saves (user_id, video_id) VALUES (?, ?)',
                [req.user.id, videoId]
            );
        }
        await connection.commit();
        res.json({ saved });
    } catch (error) {
        await connection.rollback();
        throw error;
    } finally {
        connection.release();
    }
}));

app.post('/api/users/:id/follow', requireAuth, asyncRoute(async (req, res) => {
    const creatorId = positiveId(req.params.id);
    if (!creatorId) return sendError(res, 400, 'Invalid user id.');
    if (String(req.user.id) === creatorId) return sendError(res, 400, 'You cannot follow yourself.');
    const connection = await pool.getConnection();
    try {
        await connection.beginTransaction();
        const [creators] = await connection.execute(
            'SELECT id FROM users WHERE id = ? AND status = ? FOR UPDATE',
            [creatorId, 'active']
        );
        if (!creators.length) {
            await connection.rollback();
            return sendError(res, 404, 'Creator not found.');
        }
        const [removed] = await connection.execute('DELETE FROM follows WHERE follower_id = ? AND followee_id = ?', [req.user.id, creatorId]);
        const following = removed.affectedRows === 0;
        if (following) await connection.execute('INSERT INTO follows (follower_id, followee_id) VALUES (?, ?)', [req.user.id, creatorId]);
        const [[count]] = await connection.execute('SELECT COUNT(*) AS followers FROM follows WHERE followee_id = ?', [creatorId]);
        await connection.commit();
        res.json({ following, followers: Number(count.followers) });
    } catch (error) {
        await connection.rollback();
        throw error;
    } finally {
        connection.release();
    }
}));

app.get('/api/videos/:id/comments', asyncRoute(async (req, res) => {
    const videoId = positiveId(req.params.id);
    if (!videoId) return sendError(res, 400, 'Invalid video id.');
    const [rows] = await pool.execute(
        `SELECT c.id, c.body, c.created_at, u.username AS handle
           FROM comments c JOIN users u ON u.id = c.user_id
          WHERE c.video_id = ? AND c.status = 'visible'
          ORDER BY c.created_at DESC, c.id DESC LIMIT 100`,
        [videoId]
    );
    res.json(rows);
}));

app.post('/api/videos/:id/comments', requireAuth, asyncRoute(async (req, res) => {
    const videoId = positiveId(req.params.id);
    const body = typeof req.body.body === 'string' ? req.body.body.trim() : '';
    if (!videoId || !body || body.length > 200) return sendError(res, 400, 'Comment must contain 1–200 characters.');
    const [result] = await pool.execute(
        `INSERT INTO comments (video_id, user_id, body)
         SELECT v.id, ?, ? FROM videos v WHERE v.id = ? AND v.status = 'published'`,
        [req.user.id, body, videoId]
    );
    if (!result.affectedRows) return sendError(res, 404, 'Video not found.');
    res.status(201).json({ id: Number(result.insertId), handle: req.user.username, body });
}));

app.post('/api/videos/:id/share', asyncRoute(async (req, res) => {
    const videoId = positiveId(req.params.id);
    const channels = ['native', 'copy_link', 'whatsapp', 'facebook', 'x', 'other'];
    const channel = channels.includes(req.body.channel) ? req.body.channel : 'other';
    if (!videoId) return sendError(res, 400, 'Invalid video id.');
    const [result] = await pool.execute(
        `INSERT INTO shares (video_id, user_id, channel)
         SELECT id, ?, ? FROM videos WHERE id = ? AND status = 'published'`,
        [req.user ? req.user.id : null, channel, videoId]
    );
    if (!result.affectedRows) return sendError(res, 404, 'Video not found.');
    const [[video]] = await pool.execute('SELECT share_count FROM videos WHERE id = ?', [videoId]);
    res.json({ shares: Number(video.share_count) });
}));

app.use('/uploads', express.static(uploadDirectory, {
    dotfiles: 'deny',
    index: false,
    setHeaders: (res) => {
        res.setHeader('X-Content-Type-Options', 'nosniff');
        res.setHeader('Cache-Control', 'public, max-age=86400');
    }
}));

app.get(['/', '/index.html', '/inganzo.html'], (req, res) => res.sendFile(path.join(__dirname, 'index.html')));
app.get('/library.html', (req, res) => res.sendFile(path.join(__dirname, 'library.html')));

app.use((error, req, res, next) => {
    if (res.headersSent) return next(error);
    if (error instanceof multer.MulterError) {
        const message = error.code === 'LIMIT_FILE_SIZE'
            ? `Video exceeds the ${maxUploadMb} MB upload limit.`
            : 'Video upload failed.';
        return sendError(res, 400, message);
    }
    if (error.message === 'Upload an MP4, WebM, or MOV video.') return sendError(res, 400, error.message);
    console.error('Request failed:', error);
    sendError(res, 500, 'The request could not be completed. Check the server logs.');
});

app.listen(port, process.env.HOST || '127.0.0.1', () => {
    console.log(`Inganzo is running at http://localhost:${port}`);
});
