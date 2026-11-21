#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash -n scripts/fase5-tls.sh scripts/fase5-acesso.sh
php -l conf/atualiza-url-wp.php
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
cat > "$TMP/wp-config.php" <<'PHP'
<?php
define( 'DB_NAME', 'wordpress' );
define( 'WP_HOME', 'http://127.0.0.1:8081' );
define('WP_SITEURL','http://127.0.0.1:8081');
PHP
WP_SITE_URL=https://127.0.0.1:8444 php conf/atualiza-url-wp.php "$TMP/wp-config.php"
php -l "$TMP/wp-config.php"
grep -q "'WP_HOME', 'https://127.0.0.1:8444'" "$TMP/wp-config.php"
grep -q "'WP_SITEURL', 'https://127.0.0.1:8444'" "$TMP/wp-config.php"
grep -q "'DB_NAME', 'wordpress'" "$TMP/wp-config.php"
# Repeticao local da atualizacao das URLs.
WP_SITE_URL=https://127.0.0.1:8444 php conf/atualiza-url-wp.php "$TMP/wp-config.php"
echo 'OK: bash, PHP e atualizacao idempotente de URL em arquivo de teste.'
