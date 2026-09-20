#!/bin/bash
# Legacy target entrypoint: seed the sqlite DB idempotently via PHP PDO (php-sqlite3 is
# baked in the image; sqlite3 CLI is NOT), then run apache in the foreground as root.
# No limits, no healthcheck, no non-root USER -- current-state legacy pattern [FR-06/NFR-03/FR-07].
set -e

if [ ! -f /var/www/html/data/app.db ]; then
  php -r '
    $sql = file_get_contents("/opt/setup.sql");
    $pdo = new PDO("sqlite:/var/www/html/data/app.db");
    $pdo->setAttribute(PDO::ATTR_ERRMODE, PDO::ERRMODE_EXCEPTION);
    $pdo->exec($sql);
  '
fi

exec apache2ctl -DFOREGROUND
