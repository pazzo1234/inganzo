-- SQL Workbench: pt_root / pt_root
-- Result grids and table properties are read-only.
-- Use SQL for all data and schema changes.
-- Active: 1794649935941@@127.0.0.1@3306@inganzo
-- =====================================================================
--  INGANZO : MySQL / MariaDB database
--  Culture-video platform (Kinyarwanda + English)
--
--  Works on MySQL 8.0.16+ and MariaDB 10.5+  (engine InnoDB, utf8mb4)
--
--  HOW TO IMPORT
--    Command line :  mysql -u root -p < inganzo_mysql.sql
--    phpMyAdmin   :  Import tab -> choose this file.
--    Shared hosting (cPanel): create the database in the panel first, select it,
--                    DELETE the two lines "CREATE DATABASE ..." and "USE inganzo;" below, then import.
--
--  SECURITY RULES FOR YOUR BACKEND
--    * users.password_hash must hold a bcrypt/argon2 hash (PHP password_hash(), Node bcrypt).
--      NEVER store the password itself.
--    * Always use prepared statements. Never build SQL by joining user text.
--    * Store only a SHA-256 hash of session tokens (user_sessions.token_hash), not the token.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS inganzo
  CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE inganzo;

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

-- =====================================================================
-- 1. REFERENCE TABLES  (the COUNTRIES / CATS lists in the app code)
-- =====================================================================

CREATE TABLE IF NOT EXISTS countries (
  code         CHAR(2)      NOT NULL,                 -- ISO 3166-1 alpha-2: RW, KE ...
  name_rw      VARCHAR(80)  NOT NULL,                 -- "Ubuhinde"
  name_en      VARCHAR(80)  NOT NULL,                 -- "India"
  locative_rw  VARCHAR(90)  NOT NULL,                 -- "mu Buhinde"  (used in "Turakeka ko uri mu Rwanda")
  color1       CHAR(7)      NOT NULL,                 -- poster palette #rrggbb
  color2       CHAR(7)      NOT NULL,
  color3       CHAR(7)      NOT NULL,
  motif        ENUM('diamond','zig','dots') NOT NULL DEFAULT 'diamond',
  is_active    TINYINT(1)   NOT NULL DEFAULT 1,
  PRIMARY KEY (code)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS categories (
  slug        VARCHAR(20)  NOT NULL,                  -- dance, song, food, cloth, craft, rite
  name_rw     VARCHAR(60)  NOT NULL,
  name_en     VARCHAR(60)  NOT NULL,
  sort_order  TINYINT UNSIGNED NOT NULL DEFAULT 0,
  PRIMARY KEY (slug)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- 2. USERS, SESSIONS, VERIFICATION CODES
-- =====================================================================

CREATE TABLE IF NOT EXISTS users (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  username       VARCHAR(24)   NOT NULL,              -- the @handle (3-24 letters, digits, _)
  display_name   VARCHAR(60)   NULL,
  email          VARCHAR(254)  NULL,                  -- sign in with email ...
  phone          VARCHAR(20)   NULL,                  -- ... or phone, stored as digits with optional +, e.g. +250781234567
  password_hash  VARCHAR(255)  NOT NULL,              -- bcrypt / argon2 hash only
  country_code   CHAR(2)       NOT NULL DEFAULT 'RW',
  lang           ENUM('rw','en') NOT NULL DEFAULT 'rw',
  bio            VARCHAR(160)  NULL,
  avatar_url     VARCHAR(500)  NULL,
  role           ENUM('user','moderator','admin') NOT NULL DEFAULT 'user',
  status         ENUM('active','suspended','deleted') NOT NULL DEFAULT 'active',
  email_verified_at DATETIME   NULL,
  phone_verified_at DATETIME   NULL,
  is_demo        TINYINT(1)    NOT NULL DEFAULT 0,    -- 1 = sample account from this script
  created_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  last_login_at  DATETIME      NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_users_username (username),
  UNIQUE KEY uq_users_email (email),
  UNIQUE KEY uq_users_phone (phone),
  KEY ix_users_country (country_code),
  CONSTRAINT fk_users_country FOREIGN KEY (country_code) REFERENCES countries (code)
    ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT chk_users_username CHECK (username REGEXP '^[A-Za-z0-9_]{3,24}$'),
  CONSTRAINT chk_users_contact  CHECK (email IS NOT NULL OR phone IS NOT NULL),
  CONSTRAINT chk_users_phone    CHECK (phone IS NULL OR phone REGEXP '^[+]?[0-9]{7,15}$')
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS user_sessions (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id     BIGINT UNSIGNED NOT NULL,
  token_hash  CHAR(64)     NOT NULL,                  -- SHA-256 (hex) of the cookie/bearer token
  user_agent  VARCHAR(255) NULL,
  ip          VARBINARY(16) NULL,                     -- INET6_ATON('1.2.3.4')
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at  DATETIME     NOT NULL,
  revoked_at  DATETIME     NULL,
  PRIMARY KEY (id),
  UNIQUE KEY uq_sessions_token (token_hash),
  KEY ix_sessions_user (user_id),
  KEY ix_sessions_expires (expires_at),
  CONSTRAINT fk_sessions_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- One-time codes (SMS/email) for phone sign-in, signup confirmation and password reset
CREATE TABLE IF NOT EXISTS verification_codes (
  id          BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  purpose     ENUM('signup','login','reset') NOT NULL,
  channel     ENUM('email','phone') NOT NULL,
  identifier  VARCHAR(254) NOT NULL,                  -- the email address or phone number
  code_hash   CHAR(64)     NOT NULL,                  -- SHA-256 of the code; never store the code
  attempts    TINYINT UNSIGNED NOT NULL DEFAULT 0,    -- block after 5 wrong tries
  expires_at  DATETIME     NOT NULL,
  consumed_at DATETIME     NULL,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_codes_lookup (identifier, purpose, expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- 3. VIDEOS, HASHTAGS
-- =====================================================================

CREATE TABLE IF NOT EXISTS videos (
  id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  user_id        BIGINT UNSIGNED NOT NULL,            -- creator
  country_code   CHAR(2)       NOT NULL,              -- the culture shown (not necessarily the creator's country)
  category_slug  VARCHAR(20)   NOT NULL,
  title          VARCHAR(80)   NOT NULL,
  description    VARCHAR(240)  NOT NULL DEFAULT '',
  video_url      VARCHAR(500)  NULL,                  -- NULL = demo clip (artwork only)
  storage_key    VARCHAR(300)  NULL,                  -- file path / S3 key
  thumbnail_url  VARCHAR(500)  NULL,
  mime_type      VARCHAR(60)   NULL,                  -- video/mp4, video/webm, video/quicktime
  size_bytes     BIGINT UNSIGNED NULL,
  duration_sec   SMALLINT UNSIGNED NULL,
  status         ENUM('processing','published','hidden','removed') NOT NULL DEFAULT 'published',
  like_count     INT UNSIGNED  NOT NULL DEFAULT 0,    -- kept up to date by triggers below
  comment_count  INT UNSIGNED  NOT NULL DEFAULT 0,
  share_count    INT UNSIGNED  NOT NULL DEFAULT 0,
  view_count     BIGINT UNSIGNED NOT NULL DEFAULT 0,
  created_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_videos_feed     (status, created_at, id),
  KEY ix_videos_country  (country_code, status, created_at),
  KEY ix_videos_category (category_slug, status, created_at),
  KEY ix_videos_user     (user_id, created_at),
  FULLTEXT KEY ft_videos_text (title, description),
  CONSTRAINT fk_videos_user     FOREIGN KEY (user_id)       REFERENCES users (id)       ON DELETE CASCADE,
  CONSTRAINT fk_videos_country  FOREIGN KEY (country_code)  REFERENCES countries (code) ON UPDATE CASCADE ON DELETE RESTRICT,
  CONSTRAINT fk_videos_category FOREIGN KEY (category_slug) REFERENCES categories (slug) ON UPDATE CASCADE ON DELETE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS hashtags (
  id   INT UNSIGNED NOT NULL AUTO_INCREMENT,
  tag  VARCHAR(40)  NOT NULL,                         -- without the #, e.g. Imigongo (case-insensitive unique)
  PRIMARY KEY (id),
  UNIQUE KEY uq_hashtags_tag (tag)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS video_hashtags (
  video_id    BIGINT UNSIGNED NOT NULL,
  hashtag_id  INT UNSIGNED NOT NULL,
  pos         TINYINT UNSIGNED NOT NULL DEFAULT 0,    -- display order
  PRIMARY KEY (video_id, hashtag_id),
  KEY ix_vh_hashtag (hashtag_id, video_id),
  CONSTRAINT fk_vh_video   FOREIGN KEY (video_id)   REFERENCES videos (id)   ON DELETE CASCADE,
  CONSTRAINT fk_vh_hashtag FOREIGN KEY (hashtag_id) REFERENCES hashtags (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================
-- 4. ENGAGEMENT: likes, saves, comments, follows, shares
-- =====================================================================

CREATE TABLE IF NOT EXISTS video_likes (
  user_id    BIGINT UNSIGNED NOT NULL,
  video_id   BIGINT UNSIGNED NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, video_id),                    -- one like per user per video
  KEY ix_likes_video (video_id),
  CONSTRAINT fk_likes_user  FOREIGN KEY (user_id)  REFERENCES users (id)  ON DELETE CASCADE,
  CONSTRAINT fk_likes_video FOREIGN KEY (video_id) REFERENCES videos (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS video_saves (
  user_id    BIGINT UNSIGNED NOT NULL,
  video_id   BIGINT UNSIGNED NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, video_id),
  KEY ix_saves_video (video_id),
  CONSTRAINT fk_saves_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_saves_video FOREIGN KEY (video_id) REFERENCES videos (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS comments (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  video_id   BIGINT UNSIGNED NOT NULL,
  user_id    BIGINT UNSIGNED NOT NULL,
  parent_id  BIGINT UNSIGNED NULL,                    -- reply to another comment (optional)
  body       VARCHAR(200)    NOT NULL,
  status     ENUM('visible','hidden','removed') NOT NULL DEFAULT 'visible',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_comments_video (video_id, status, created_at),
  KEY ix_comments_user (user_id),
  KEY ix_comments_parent (parent_id),
  CONSTRAINT fk_comments_video  FOREIGN KEY (video_id)  REFERENCES videos (id)   ON DELETE CASCADE,
  CONSTRAINT fk_comments_user   FOREIGN KEY (user_id)   REFERENCES users (id)    ON DELETE CASCADE,
  CONSTRAINT fk_comments_parent FOREIGN KEY (parent_id) REFERENCES comments (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS follows (
  follower_id BIGINT UNSIGNED NOT NULL,               -- who follows
  followee_id BIGINT UNSIGNED NOT NULL,               -- the creator being followed
  created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (follower_id, followee_id),
  KEY ix_follows_followee (followee_id),
  CONSTRAINT fk_follows_follower FOREIGN KEY (follower_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_follows_followee FOREIGN KEY (followee_id) REFERENCES users (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS shares (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  video_id   BIGINT UNSIGNED NOT NULL,
  user_id    BIGINT UNSIGNED NULL,                    -- NULL = visitor not signed in
  channel    ENUM('native','copy_link','whatsapp','facebook','x','other') NOT NULL DEFAULT 'other',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_shares_video (video_id),
  CONSTRAINT fk_shares_video FOREIGN KEY (video_id) REFERENCES videos (id) ON DELETE CASCADE,
  CONSTRAINT fk_shares_user  FOREIGN KEY (user_id)  REFERENCES users (id)  ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Moderation: users can report a video, comment or account
CREATE TABLE IF NOT EXISTS reports (
  id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  reporter_id  BIGINT UNSIGNED NULL,
  target_type  ENUM('video','comment','user') NOT NULL,
  target_id    BIGINT UNSIGNED NOT NULL,
  reason       ENUM('spam','nudity','violence','hate','copyright','misinformation','other') NOT NULL,
  details      VARCHAR(500) NULL,
  status       ENUM('open','reviewed','dismissed') NOT NULL DEFAULT 'open',
  created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  reviewed_by  BIGINT UNSIGNED NULL,
  reviewed_at  DATETIME NULL,
  PRIMARY KEY (id),
  KEY ix_reports_status (status, created_at),
  KEY ix_reports_target (target_type, target_id),
  CONSTRAINT fk_reports_reporter FOREIGN KEY (reporter_id) REFERENCES users (id) ON DELETE SET NULL,
  CONSTRAINT fk_reports_reviewer FOREIGN KEY (reviewed_by) REFERENCES users (id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- =====================================================================

-- 3. SEED DATA (safe to re-run: INSERT IGNORE)

-- =====================================================================

INSERT IGNORE INTO countries (code,name_rw,name_en,locative_rw,color1,color2,color3,motif) VALUES
  ('RW','Rwanda','Rwanda','mu Rwanda','#7a1410','#e9a23b','#f6e7d3','diamond'),
  ('KE','Kenya','Kenya','muri Kenya','#1d3b2a','#c8372d','#f6e7d3','zig'),
  ('UG','Uganda','Uganda','muri Uganda','#2a1f0e','#e9a23b','#c8372d','dots'),
  ('TZ','Tanzaniya','Tanzania','muri Tanzaniya','#0f3a45','#e9a23b','#f6e7d3','zig'),
  ('NG','Nigeriya','Nigeria','muri Nigeriya','#12402a','#e9a23b','#f6e7d3','diamond'),
  ('ET','Etiyopiya','Ethiopia','muri Etiyopiya','#3a1f10','#e9a23b','#3f8f5b','dots'),
  ('ZA','Afurika y''Epfo','South Africa','muri Afurika y''Epfo','#1c2a4a','#e9a23b','#c8372d','zig'),
  ('IN','Ubuhinde','India','mu Buhinde','#5a1a3a','#e9a23b','#f6e7d3','dots'),
  ('JP','Ubuyapani','Japan','mu Buyapani','#2a0f14','#c8372d','#f6e7d3','diamond'),
  ('BR','Berezile','Brazil','muri Berezile','#0f3a2a','#e9d23b','#2a5cc8','zig'),
  ('MX','Megizike','Mexico','muri Megizike','#3a0f2a','#e9a23b','#3f8f5b','dots'),
  ('FR','Ubufaransa','France','mu Bufaransa','#1c2a4a','#f6e7d3','#c8372d','diamond');

INSERT IGNORE INTO categories (slug,name_rw,name_en,sort_order) VALUES
  ('dance','Imbyino','Dances',1),
  ('song','Indirimbo','Songs',2),
  ('food','Ibiribwa','Food',3),
  ('cloth','Imyambaro','Clothing',4),
  ('craft','Ubukorikori','Crafts',5),
  ('rite','Imihango','Ceremonies',6);

-- Demo creators. password_hash '!' can never match a real hash, so these accounts cannot log in.
-- Remove all demo data any time with:  DELETE FROM users WHERE is_demo = 1;  (videos etc. cascade)

INSERT IGNORE INTO users (username,email,password_hash,country_code,lang,is_demo) VALUES
  ('intore_zacu','intore_zacu@demo.inganzo.invalid','!','RW','rw',1),
  ('agaseke_art','agaseke_art@demo.inganzo.invalid','!','RW','rw',1),
  ('inanga_ya_kera','inanga_ya_kera@demo.inganzo.invalid','!','RW','rw',1),
  ('imigongo_studio','imigongo_studio@demo.inganzo.invalid','!','RW','rw',1),
  ('isombe_mama','isombe_mama@demo.inganzo.invalid','!','RW','rw',1),
  ('maasai_vibes','maasai_vibes@demo.inganzo.invalid','!','KE','rw',1),
  ('bakisimba_ug','bakisimba_ug@demo.inganzo.invalid','!','UG','rw',1),
  ('aso_oke_ng','aso_oke_ng@demo.inganzo.invalid','!','NG','rw',1),
  ('coffee_ceremony','coffee_ceremony@demo.inganzo.invalid','!','ET','rw',1),
  ('gumboot_za','gumboot_za@demo.inganzo.invalid','!','ZA','rw',1),
  ('kathak_diaries','kathak_diaries@demo.inganzo.invalid','!','IN','rw',1),
  ('chado_kyoto','chado_kyoto@demo.inganzo.invalid','!','JP','rw',1),
  ('roda_de_capoeira','roda_de_capoeira@demo.inganzo.invalid','!','BR','rw',1),
  ('dia_de_muertos_mx','dia_de_muertos_mx@demo.inganzo.invalid','!','MX','rw',1),
  ('taarab_zanzibar','taarab_zanzibar@demo.inganzo.invalid','!','TZ','rw',1),
  ('boulangerie_fr','boulangerie_fr@demo.inganzo.invalid','!','FR','rw',1),
  ('patrick' ,'patrickiradukunda975@mail.com', 'patrick2005','RW','rw',1);


-- video_url NULL = demo clip: the app shows generated imigongo artwork instead of a real video.
INSERT IGNORE INTO videos (id,user_id,country_code,category_slug,title,description,video_url,status,like_count,comment_count,share_count,created_at) VALUES
  (1,(SELECT id FROM users WHERE username='intore_zacu'),'RW','dance','Imbyino y''Intore','Intore zibyina zifite amacumu n''ingabo, zikurikiza injyana y''ingoma.',NULL,' Official Music Video ).mp4',48200,1240,3100,NOW() - INTERVAL 1 HOUR),
  (2,(SELECT id FROM users WHERE username='agaseke_art'),'RW','craft','Kuboha agaseke',',Reba uko agaseke kaboshwa mu byatsi mu buryo bwa gakondo, intambwe ku yindi.',NULL,'published',31500,860,2200,NOW() - INTERVAL 2 HOUR),
  (3,(SELECT id FROM users WHERE username='inanga_ya_kera'),'RW','song','Inanga n''ibisigo','Umucuranzi acuranga inanga arangurura ibisigo by''umuco nyarwanda.',NULL,'published',22800,540,1500,NOW() - INTERVAL 3 HOUR),
  (4,(SELECT id FROM users WHERE username='imigongo_studio'),'RW','craft','Gushushanya imigongo','Imigongo ni ubugeni bukorwa mu mase y''inka; reba uko imiterere yayo ikorwa.',NULL,'published',19400,410,980,NOW() - INTERVAL 4 HOUR),
  (5,(SELECT id FROM users WHERE username='isombe_mama'),'RW','food','Guteka isombe','Isombe n''ibishyimbo n''ubugari: ifunguro rya gakondo ry''Abanyarwanda.',NULL,'published',27600,970,1800,NOW() - INTERVAL 5 HOUR),
  (6,(SELECT id FROM users WHERE username='maasai_vibes'),'KE','dance','Adumu y''Abamasayi','Abasore b''Abamasayi basimbuka hejuru mu mbyino ya gakondo yitwa adumu.',NULL,'published',61400,2100,5400,NOW() - INTERVAL 6 HOUR),
  (7,(SELECT id FROM users WHERE username='bakisimba_ug'),'UG','dance','Bakisimba y''Abaganda','Imbyino ya gakondo y''Abaganda irangwa n''ingoma n''indirimbo zishimishije.',NULL,'published',17900,380,760,NOW() - INTERVAL 7 HOUR),
  (8,(SELECT id FROM users WHERE username='aso_oke_ng'),'NG','cloth','Imyambaro ya Aso Oke','Imyenda iboshywe n''intoki n''Abayoruba, ikambarwa mu bukwe n''iminsi mikuru.',NULL,'published',24300,690,1400,NOW() - INTERVAL 8 HOUR),
  (9,(SELECT id FROM users WHERE username='coffee_ceremony'),'ET','rite','Umuhango w''ikawa muri Etiyopiya','Ikawa ikaranzwa imbere y''abashyitsi, igatekwa kandi igasangirwa nk''umuhango wo guhuza abantu.',NULL,'published',38700,1120,2900,NOW() - INTERVAL 9 HOUR),
  (10,(SELECT id FROM users WHERE username='gumboot_za'),'ZA','dance','Imbyino y''abacukuzi (Gumboot)','Imbyino yavutse mu bacukuzi b''amabuye y''agaciro, bakubita inkweto ku butaka mu njyana.',NULL,'published',29100,750,1700,NOW() - INTERVAL 10 HOUR),
  (11,(SELECT id FROM users WHERE username='kathak_diaries'),'IN','dance','Kathak mu Buhinde','Imbyino ya gakondo y''Abahinde ifite intambwe z''umuvuduko n''imvugo y''amaso n''amaboko.',NULL,'published',52800,1630,4100,NOW() - INTERVAL 11 HOUR),
  (12,(SELECT id FROM users WHERE username='chado_kyoto'),'JP','rite','Umuhango w''icyayi mu Buyapani','Gutegura no gutanga icyayi cya matcha mu bwitonzi n''ituze.',NULL,'published',44100,980,3300,NOW() - INTERVAL 12 HOUR),
  (13,(SELECT id FROM users WHERE username='roda_de_capoeira'),'BR','dance','Capoeira muri Berezile','Ubuhanzi buvanga imbyino n''imikino yo kurwana, bwavutse mu bakurambere b''Abanyafurika.',NULL,'published',57300,1880,4600,NOW() - INTERVAL 13 HOUR),
  (14,(SELECT id FROM users WHERE username='dia_de_muertos_mx'),'MX','rite','Umunsi w''Abapfuye muri Megizike','Imiryango itaka imva n''ibimera by''amabara kugira ngo yibuke abayo bapfuye.',NULL,'published',41900,1320,3700,NOW() - INTERVAL 14 HOUR),
  (15,(SELECT id FROM users WHERE username='taarab_zanzibar'),'TZ','song','Taarab ya Zanzibar','Umuziki w''ibitaramo wo ku nkombe z''inyanja, uvanga injyana z''Abarabu n''iz''Abanyafurika.',NULL,'published',15200,290,640,NOW() - INTERVAL 15 HOUR),
  (16,(SELECT id FROM users WHERE username='boulangerie_fr'),'FR','food','Ubuhanzi bw''imigati mu Bufaransa','Reba uko baguette ikorwa kuva ku ifu kugeza ku mugati ushyushye.',NULL,'published',33600,710,1300,NOW() - INTERVAL 16 HOUR),
    (17,(SELECT id FROM users WHERE username='patrick'),'RW','song','ubuhanzi gakondo y''urwanda','bafite umudiho mwiza',
   '/videos/Indashyikirwa%20-%20Intaramanaguhiga%20%28%20Official%20Music%20Video%20%29.mp4','published',1000,100,50,NOW() - INTERVAL 17 HOUR);
INSERT IGNORE INTO hashtags (tag) VALUES
  ('Intore'),
  ('Imbyino'),
  ('Agaseke'),
  ('Ubukorikori'),
  ('Inanga'),
  ('Ibisigo'),
  ('Imigongo'),
  ('Ubugeni'),
  ('Isombe'),
  ('Ibiribwa'),
  ('Adumu'),
  ('Kenya'),
  ('Bakisimba'),
  ('Uganda'),
  ('AsoOke'),
  ('Imyambaro'),
  ('Ikawa'),
  ('Etiyopiya'),
  ('Gumboot'),
  ('AfurikaYEpfo'),
  ('Kathak'),
  ('Ubuhinde'),
  ('Matcha'),
  ('Ubuyapani'),
  ('Capoeira'),
  ('Berezile'),
  ('Megizike'),
  ('Kwibuka'),
  ('Taarab'),
  ('Tanzaniya'),
  ('Baguette'),
  ('Ubufaransa');

INSERT IGNORE INTO video_hashtags (video_id,hashtag_id,pos)
SELECT x.video_id, h.id, x.pos FROM (
  SELECT 1 AS video_id, 'Intore' AS tag, 0 AS pos
  UNION ALL
  SELECT 1 AS video_id, 'Imbyino' AS tag, 1 AS pos
  UNION ALL
  SELECT 2 AS video_id, 'Agaseke' AS tag, 0 AS pos
  UNION ALL
  SELECT 2 AS video_id, 'Ubukorikori' AS tag, 1 AS pos
  UNION ALL
  SELECT 3 AS video_id, 'Inanga' AS tag, 0 AS pos
  UNION ALL
  SELECT 3 AS video_id, 'Ibisigo' AS tag, 1 AS pos
  UNION ALL
  SELECT 4 AS video_id, 'Imigongo' AS tag, 0 AS pos
  UNION ALL
  SELECT 4 AS video_id, 'Ubugeni' AS tag, 1 AS pos
  UNION ALL
  SELECT 5 AS video_id, 'Isombe' AS tag, 0 AS pos
  UNION ALL
  SELECT 5 AS video_id, 'Ibiribwa' AS tag, 1 AS pos
  UNION ALL
  SELECT 6 AS video_id, 'Adumu' AS tag, 0 AS pos
  UNION ALL
  SELECT 6 AS video_id, 'Kenya' AS tag, 1 AS pos
  UNION ALL
  SELECT 7 AS video_id, 'Bakisimba' AS tag, 0 AS pos
  UNION ALL
  SELECT 7 AS video_id, 'Uganda' AS tag, 1 AS pos
  UNION ALL
  SELECT 8 AS video_id, 'Asooke' AS tag, 0 AS pos
  UNION ALL
  SELECT 8 AS video_id, 'Imyambaro' AS tag, 1 AS pos
  UNION ALL
  SELECT 9 AS video_id, 'Ikawa' AS tag, 0 AS pos
  UNION ALL
  SELECT 9 AS video_id, 'Etiyopiya' AS tag, 1 AS pos
  UNION ALL
  SELECT 10 AS video_id, 'Gumboot' AS tag, 0 AS pos
  UNION ALL
  SELECT 10 AS video_id, 'AfurikaYEpfo' AS tag, 1 AS pos
  UNION ALL
  SELECT 11 AS video_id, 'Kathak' AS tag, 0 AS pos
  UNION ALL
  SELECT 11 AS video_id, 'Ubuhinde' AS tag, 1 AS pos
  UNION ALL
  SELECT 12 AS video_id, 'Matcha' AS tag, 0 AS pos
  UNION ALL
  SELECT 12 AS video_id, 'Ubuyapani' AS tag, 1 AS pos
  UNION ALL
  SELECT 13 AS video_id, 'Capoeira' AS tag, 0 AS pos
  UNION ALL
  SELECT 13 AS video_id, 'Berezile' AS tag, 1 AS pos
  UNION ALL
  SELECT 14 AS video_id, 'Megizike' AS tag, 0 AS pos
  UNION ALL
  SELECT 14 AS video_id, 'Kwibuka' AS tag, 1 AS pos
  UNION ALL
  SELECT 15 AS video_id, 'Taarab' AS tag, 0 AS pos
  UNION ALL
  SELECT 15 AS video_id, 'Tanzaniya' AS tag, 1 AS pos
  UNION ALL
  SELECT 16 AS video_id, 'Baguette' AS tag, 0 AS pos
  UNION ALL
  SELECT 16 AS video_id, 'Ubufaransa' AS tag, 1 AS pos
) x JOIN hashtags h ON h.tag = x.tag;

-- Keep new uploads numbered after the demo videos
ALTER TABLE videos AUTO_INCREMENT = 1000;


-- =====================================================================
-- 4. TRIGGERS : keep like / comment / share counters in step
--    (the seed videos above already carry their sample counts)
-- =====================================================================
DROP TRIGGER IF EXISTS trg_likes_ai;
DROP TRIGGER IF EXISTS trg_likes_ad;
DROP TRIGGER IF EXISTS trg_comments_ai;
DROP TRIGGER IF EXISTS trg_comments_ad;
DROP TRIGGER IF EXISTS trg_shares_ai;
DROP TRIGGER IF EXISTS trg_follows_bi;

DELIMITER $$

CREATE TRIGGER trg_likes_ai AFTER INSERT ON video_likes FOR EACH ROW
BEGIN
  UPDATE videos SET like_count = like_count + 1 WHERE id = NEW.video_id;
END$$

CREATE TRIGGER trg_likes_ad AFTER DELETE ON video_likes FOR EACH ROW
BEGIN
  UPDATE videos SET like_count = IF(like_count > 0, like_count - 1, 0) WHERE id = OLD.video_id;
END$$

CREATE TRIGGER trg_comments_ai AFTER INSERT ON comments FOR EACH ROW
BEGIN
  UPDATE videos SET comment_count = comment_count + 1 WHERE id = NEW.video_id;
END$$

CREATE TRIGGER trg_comments_ad AFTER DELETE ON comments FOR EACH ROW
BEGIN
  UPDATE videos SET comment_count = IF(comment_count > 0, comment_count - 1, 0) WHERE id = OLD.video_id;
END$$

CREATE TRIGGER trg_shares_ai AFTER INSERT ON shares FOR EACH ROW
BEGIN
  UPDATE videos SET share_count = share_count + 1 WHERE id = NEW.video_id;
END$$

-- nobody can follow themselves
CREATE TRIGGER trg_follows_bi BEFORE INSERT ON follows FOR EACH ROW
BEGIN
  IF NEW.follower_id = NEW.followee_id THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A user cannot follow themselves';
  END IF;
END$$

DELIMITER ;

-- =====================================================================
-- 5. VIEWS  (what each screen of the app reads)
-- =====================================================================

-- The feed card: one row per published video with creator, country, category and tags
CREATE OR REPLACE VIEW v_video_feed AS
SELECT v.id,
       v.title,
       v.description,
       v.video_url,
       v.thumbnail_url,
       v.country_code,
       c.name_rw       AS country_name_rw,
       c.name_en       AS country_name_en,
       v.category_slug AS category,
       k.name_rw       AS category_name_rw,
       k.name_en       AS category_name_en,
       v.user_id,
       u.username      AS handle,
       v.like_count,
       v.comment_count,
       v.share_count,
       v.view_count,
       v.created_at,
       (SELECT GROUP_CONCAT(h.tag ORDER BY vh.pos SEPARATOR ',')
          FROM video_hashtags vh JOIN hashtags h ON h.id = vh.hashtag_id
         WHERE vh.video_id = v.id) AS tags
  FROM videos v
  JOIN users u      ON u.id = v.user_id AND u.status = 'active'
  JOIN countries c  ON c.code = v.country_code
  JOIN categories k ON k.slug = v.category_slug
 WHERE v.status = 'published';

-- "Ibihugu" page: number of videos per country
CREATE OR REPLACE VIEW v_country_video_counts AS
SELECT c.code, c.name_rw, c.name_en, c.color1, c.color2, c.color3, c.motif,
       COUNT(v.id) AS video_count
  FROM countries c
  LEFT JOIN videos v ON v.country_code = c.code AND v.status = 'published'
 WHERE c.is_active = 1
 GROUP BY c.code, c.name_rw, c.name_en, c.color1, c.color2, c.color3, c.motif;

-- "Ibigezweho" (trending) hashtags: most used on videos from the last 30 days
CREATE OR REPLACE VIEW v_trending_hashtags AS
SELECT h.tag,
       COUNT(*)                AS videos,
       COALESCE(SUM(v.like_count), 0) AS likes
  FROM hashtags h
  JOIN video_hashtags vh ON vh.hashtag_id = h.id
  JOIN videos v ON v.id = vh.video_id AND v.status = 'published'
                AND v.created_at >= NOW() - INTERVAL 30 DAY
 GROUP BY h.id, h.tag
 ORDER BY likes DESC, videos DESC
 LIMIT 20;

-- Profile card: Amavidewo / Ukurikiye / Ukunda
CREATE OR REPLACE VIEW v_user_stats AS
SELECT u.id AS user_id, u.username,
       (SELECT COUNT(*) FROM videos     WHERE user_id     = u.id AND status = 'published') AS videos,
       (SELECT COUNT(*) FROM follows    WHERE follower_id = u.id)                          AS following,
       (SELECT COUNT(*) FROM follows    WHERE followee_id = u.id)                          AS followers,
       (SELECT COUNT(*) FROM video_likes WHERE user_id    = u.id)                          AS likes_given
  FROM users u;

-- =====================================================================
-- 6. STORED PROCEDURES  (ready-made queries for the API)
-- =====================================================================
DROP PROCEDURE IF EXISTS sp_toggle_like;
DROP PROCEDURE IF EXISTS sp_toggle_follow;
DROP PROCEDURE IF EXISTS sp_feed;
DROP PROCEDURE IF EXISTS sp_add_video;

DELIMITER $$

-- Heart button: like if not liked, unlike if already liked.
-- Returns: liked (1/0) and the new like_count.
CREATE PROCEDURE sp_toggle_like(IN p_user BIGINT UNSIGNED, IN p_video BIGINT UNSIGNED)
BEGIN
  DECLARE v_removed INT DEFAULT 0;
  DELETE FROM video_likes WHERE user_id = p_user AND video_id = p_video;
  SET v_removed = ROW_COUNT();
  IF v_removed = 0 THEN
    INSERT INTO video_likes (user_id, video_id) VALUES (p_user, p_video);
  END IF;
  SELECT (v_removed = 0) AS liked, like_count FROM videos WHERE id = p_video;
END$$

-- Follow / Kurikira button. Returns: following (1/0) and the creator's follower count.
CREATE PROCEDURE sp_toggle_follow(IN p_follower BIGINT UNSIGNED, IN p_creator BIGINT UNSIGNED)
BEGIN
  DECLARE v_removed INT DEFAULT 0;
  DELETE FROM follows WHERE follower_id = p_follower AND followee_id = p_creator;
  SET v_removed = ROW_COUNT();
  IF v_removed = 0 THEN
    INSERT INTO follows (follower_id, followee_id) VALUES (p_follower, p_creator);
  END IF;
  SELECT (v_removed = 0) AS following,
         (SELECT COUNT(*) FROM follows WHERE followee_id = p_creator) AS followers;
END$$

-- The main feed.
--   p_user     signed-in user id, or NULL for visitors
--   p_my_cc    visitor's country code (e.g. 'RW'); on the 'world' tab these videos come first
--   p_tab      'world' | 'local' | 'following'
--   p_country  filter by country code, or NULL
--   p_category filter by category slug, or NULL
--   p_q        search text (title, description, hashtags), or NULL
CREATE PROCEDURE sp_feed(
  IN p_user BIGINT UNSIGNED, IN p_my_cc CHAR(2) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci, IN p_tab VARCHAR(10) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  IN p_country CHAR(2) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci, IN p_category VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci, IN p_q VARCHAR(100) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  IN p_limit INT, IN p_offset INT)
BEGIN
  DECLARE v_like VARCHAR(110) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  SET v_like = IF(p_q IS NULL OR p_q = '', NULL, CONCAT('%', p_q, '%'));
  SET p_limit = LEAST(GREATEST(IFNULL(p_limit, 20), 1), 50);
  SET p_offset = GREATEST(IFNULL(p_offset, 0), 0);

  SELECT f.*,
         (p_user IS NOT NULL AND EXISTS (SELECT 1 FROM video_likes l
                                          WHERE l.user_id = p_user AND l.video_id = f.id)) AS liked_by_me,
         (p_user IS NOT NULL AND EXISTS (SELECT 1 FROM follows fo
                                          WHERE fo.follower_id = p_user AND fo.followee_id = f.user_id)) AS following_creator
    FROM v_video_feed f
   WHERE (p_country  IS NULL OR f.country_code = p_country)
     AND (p_category IS NULL OR f.category = p_category)
     AND (p_tab <> 'local' OR f.country_code = p_my_cc)
     AND (p_tab <> 'following'
          OR EXISTS (SELECT 1 FROM follows fo2
                      WHERE fo2.follower_id = p_user AND fo2.followee_id = f.user_id))
     AND (v_like IS NULL
          OR f.title LIKE v_like OR f.description LIKE v_like
          OR EXISTS (SELECT 1 FROM video_hashtags vh JOIN hashtags h ON h.id = vh.hashtag_id
                      WHERE vh.video_id = f.id AND h.tag LIKE v_like))
   ORDER BY (p_tab = 'world' AND f.country_code = p_my_cc) DESC,
            f.created_at DESC, f.id DESC
   LIMIT p_limit OFFSET p_offset;
END$$

-- Upload form (Sangiza): creates the video and its hashtags in one go.
--   p_tags is a comma separated list, e.g. 'Imigongo,Ubugeni' (max 4 are used)
-- Returns the new video id.
CREATE PROCEDURE sp_add_video(
  IN p_user BIGINT UNSIGNED, IN p_country CHAR(2) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci, IN p_category VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  IN p_title VARCHAR(80) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci, IN p_desc VARCHAR(240) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci, IN p_video_url VARCHAR(500) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci,
  IN p_storage_key VARCHAR(300) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci, IN p_mime VARCHAR(60) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci, IN p_size BIGINT UNSIGNED,
  IN p_tags VARCHAR(200) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci)
BEGIN
  DECLARE v_id BIGINT UNSIGNED;
  DECLARE v_rest VARCHAR(200) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  DECLARE v_tag VARCHAR(40) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  DECLARE v_pos INT DEFAULT 0;
  DECLARE v_tag_id INT UNSIGNED;

  INSERT INTO videos (user_id, country_code, category_slug, title, description,
                      video_url, storage_key, mime_type, size_bytes, status)
  VALUES (p_user, p_country, p_category, p_title, IFNULL(p_desc, ''),
          p_video_url, p_storage_key, p_mime, p_size, ' Official Music Video ).mp4');
  SET v_id = LAST_INSERT_ID();

  SET v_rest = IFNULL(p_tags, '');
  WHILE CHAR_LENGTH(v_rest) > 0 AND v_pos < 4 DO
    SET v_tag = TRIM(SUBSTRING_INDEX(v_rest, ',', 1));
    SET v_rest = IF(LOCATE(',', v_rest) > 0, SUBSTRING(v_rest, LOCATE(',', v_rest) + 1), '');
    SET v_tag = TRIM(LEADING '#' FROM v_tag);
    IF CHAR_LENGTH(v_tag) > 0 THEN
      INSERT IGNORE INTO hashtags (tag) VALUES (v_tag);
      SELECT id INTO v_tag_id FROM hashtags WHERE tag = v_tag LIMIT 1;
      INSERT IGNORE INTO video_hashtags (video_id, hashtag_id, pos) VALUES (v_id, v_tag_id, v_pos);
      SET v_pos = v_pos + 1;
    END IF;
  END WHILE;

  SELECT v_id AS video_id;
END$$
INSERT INTO users (username,email,password_hash,country_code,lang,is_demo) VALUES
  ('patti','patrickiradukunda975@gmail.com','2005200530125pi','RW','rw',0);
DELIMITER ;

    SELECT * FROM v_country_video_counts;
  CALL sp_feed(NULL, 'RW', 'world', NULL, NULL, NULL, 20, 0);
    CALL sp_feed(NULL, 'KE', 'local', NULL, NULL, NULL, 20, 0);
  CALL sp_feed(NULL, 'RW', 'world', NULL, NULL, 'imigongo', 20, 0);
    SELECT * FROM v_trending_hashtags;


