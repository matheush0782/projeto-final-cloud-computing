#!/usr/bin/env bash
set -euo pipefail

DB_HOST="$1"; DB_PASS="$2"; URL="$3"

cd /tmp
curl -sLO https://wordpress.org/latest.tar.gz
tar xzf latest.tar.gz
rm -f /var/www/html/index.html
cp -a wordpress/. /var/www/html/
cp /var/www/html/wp-config-sample.php /var/www/html/wp-config.php

sed -i "s/database_name_here/wordpress/; s/username_here/wpuser/; s/password_here/${DB_PASS}/; s/'localhost'/'${DB_HOST}'/" /var/www/html/wp-config.php
sed -i "1a define('WP_SITEURL','${URL}');" /var/www/html/wp-config.php
sed -i "1a define('WP_HOME','${URL}');" /var/www/html/wp-config.php

echo 'SetEnvIf X-Forwarded-Proto https HTTPS=on' > /etc/apache2/conf-available/proxy-https.conf
a2enconf proxy-https
chown -R www-data:www-data /var/www/html
systemctl restart apache2
