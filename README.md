<<<<<<< HEAD
# Inganzo

Inganzo is served as a Node.js application. The server provides the JSON API, connects to the MySQL/MariaDB schema in `inganzo.sql`, and serves `index.html`. The PHP file `db.php` is an optional standalone PDO connection check; PHP is not part of the application's request path.

## Requirements

- Node.js 18 or later
- MySQL 8.0.16+ or MariaDB 10.5+
- PHP with `pdo_mysql` only if you also want to use the standalone `db.php` helper

## Set up the database

From Command Prompt in this folder, import the schema and its demo data:

```bat
mysql -u root -p < inganzo.sql
```

The script creates and selects the `inganzo` database. Use a dedicated database account for the application rather than the MySQL root account in a deployed environment.

## Configure and run

Create `.env` from the example and add credentials for a MySQL account with access to Inganzo. The app also reads the existing extensionless `env` file when `.env` is absent; `.env` takes precedence.

```powershell
Copy-Item .env.example .env
npm ci
npm run test:db
npm start
```

Keep database credentials private and use a dedicated database account rather than `root`. The app serves the main platform at <http://localhost:3000> and the culture library at <http://localhost:3000/library.html>. `npm run test:db` checks the database connection.

On Windows, run `launch.bat` to install dependencies if needed and start the app. If Python 3 is installed, `python launch.py` starts the same Node server and opens the browser; `python launch.py --no-open` skips that step.

The health endpoint is <http://localhost:3000/api/health>; a healthy response is `{"status":"ok","database":"connected"}`. For production, use same-origin hosting or configure `FRONTEND_ORIGIN` for a separate frontend origin.

If you already imported an older version of the schema before `display_name` was added, apply this one-time migration before starting the updated API:

```sql
ALTER TABLE users ADD COLUMN display_name VARCHAR(60) NULL AFTER username;

CREATE TABLE IF NOT EXISTS video_saves (
  user_id BIGINT UNSIGNED NOT NULL,
  video_id BIGINT UNSIGNED NOT NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (user_id, video_id),
  KEY ix_saves_video (video_id),
  CONSTRAINT fk_saves_user FOREIGN KEY (user_id) REFERENCES users (id) ON DELETE CASCADE,
  CONSTRAINT fk_saves_video FOREIGN KEY (video_id) REFERENCES videos (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
```

The app supports registration and login with email or phone plus password, session cookies, the video feed, likes, follows, comments, shares, profile updates, and video uploads. The frontend calls the `/api` routes on the Node server, which stores app data in MySQL/MariaDB. Uploaded videos are saved under `uploads/`; keep that folder persistent and backed up. Set `MAX_UPLOAD_MB` to change the upload size limit (default: 100 MB), `PORT` to change the HTTP port (default: 3000), or `HOST` to change the bind address (default: `127.0.0.1`).

For production, set `NODE_ENV=production` and terminate HTTPS at the app or a trusted reverse proxy. The session cookie is then marked `Secure`.
=======
# inganzo
>>>>>>> f799690c427d091e3d4e78c0e67f05cbeae8cff8
