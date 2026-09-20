-- Legacy target seed (Phase 0 baseline). Creates schema + rows. sqlite3 CLI is part of the
-- baked toolchain; the entrypoint runs `sqlite3 app.db < setup.sql` idempotently at boot.
-- md5/sha1 hashes kept as plain blobs (classic vuln-app pattern) so the "password" column
-- is exactly what an attacker would extract via the SQLi sink in index.php.
CREATE TABLE IF NOT EXISTS users (
  id       INTEGER PRIMARY KEY,
  name     TEXT NOT NULL,
  password TEXT NOT NULL
);
INSERT OR REPLACE INTO users (id, name, password) VALUES
  (1, 'admin',     '5f4dcc3b5aa765d61d8327deb882cf99'),
  (2, 'alice',     '098f6bcd4621d373cade4e832627b4f6'),
  (3, 'corp-user', 'e99a18c428cb38d5f260853678922e03');
