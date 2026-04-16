#!/bin/bash
set -euo pipefail

DOMAIN="${DOMAIN:-ems.mympress.com}"
ADMIN_EMAIL="${ADMIN_EMAIL:-administrator@mympress.com}"
TIMEZONE="${TIMEZONE:-UTC}"
LOCALE="${LOCALE:-en}"
MAILER_FROM_NAME="${MAILER_FROM_NAME:-Mautic}"

DB_NAME="${DB_NAME:-ems_mautic}"
DB_USER="${DB_USER:-ems_mautic_user}"
DB_PASS="${DB_PASS:-$(openssl rand -base64 24)}"
ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -base64 18)}"
DB_ROOT_PASS="${DB_ROOT_PASS:-}"

MAUTIC_VERSION="7.0.1"
MAUTIC_DIR="/var/www/mautic"
MAUTIC_USER="www-data"
LOG_FILE="/var/log/mautic-installer.log"
SUCCESS_MARKER="/root/.mautic_install_complete"
CREDS_FILE="/root/mautic-credentials.txt"
ENV_FILE="/root/.mautic_env"

exec > >(tee -a "${LOG_FILE}") 2>&1
export DEBIAN_FRONTEND=noninteractive
export COMPOSER_ALLOW_SUPERUSER=1

echo "=== MAUTIC INSTALL START $(date) ==="

if [ -f "${ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
fi

if [ -f "${SUCCESS_MARKER}" ]; then
  echo "Mautic already installed."
  cat "${CREDS_FILE}" 2>/dev/null || true
  exit 0
fi

CODENAME="$(lsb_release -cs || true)"
if [ "${CODENAME}" != "noble" ]; then
  echo "ERROR: Ubuntu 24.04 LTS (noble) is required." >&2
  exit 1
fi

for cmd in php composer nginx mysql; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "ERROR: required command missing: ${cmd}" >&2
    exit 1
  }
done

MYSQL_VERSION="$(mysql --version || true)"
echo "Detected MySQL: ${MYSQL_VERSION}"
if ! echo "${MYSQL_VERSION}" | grep -Eq 'Distrib 8\.(4|[5-9]|[1-9][0-9])|Ver 8\.(4|[5-9]|[1-9][0-9])'; then
  echo "ERROR: MySQL 8.4+ is required." >&2
  exit 1
fi

run_mysql_root() {
  if mysql --protocol=socket -e "SELECT 1" >/dev/null 2>&1; then
    mysql --protocol=socket "$@"
  elif [ -n "${DB_ROOT_PASS}" ] && mysql -u root -p"${DB_ROOT_PASS}" -e "SELECT 1" >/dev/null 2>&1; then
    mysql -u root -p"${DB_ROOT_PASS}" "$@"
  else
    echo "ERROR: cannot authenticate to MySQL as root. Use socket auth or export DB_ROOT_PASS." >&2
    exit 1
  fi
}

echo "STEP 1/7: database"
run_mysql_root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
run_mysql_root -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
run_mysql_root -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
run_mysql_root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
mysql -u "${DB_USER}" -p"${DB_PASS}" -h 127.0.0.1 -D "${DB_NAME}" -e "SELECT 1;" >/dev/null

echo "STEP 2/7: mautic source install"
if [ ! -f "${MAUTIC_DIR}/composer.json" ]; then
  rm -rf "${MAUTIC_DIR}"
  composer create-project mautic/recommended-project "${MAUTIC_DIR}" "${MAUTIC_VERSION}" \
    --no-interaction --prefer-dist --no-progress
fi

chown -R ${MAUTIC_USER}:${MAUTIC_USER} "${MAUTIC_DIR}"
find "${MAUTIC_DIR}" -type d -exec chmod 775 {} \;
find "${MAUTIC_DIR}" -type f -exec chmod 664 {} \;
mkdir -p "${MAUTIC_DIR}/var"
chmod -R 775 "${MAUTIC_DIR}/var"

echo "STEP 3/7: nginx final vhost"
cat > /etc/nginx/sites-available/mautic <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root ${MAUTIC_DIR}/public;
    index index.php;

    client_max_body_size 100M;
    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;

    location / {
        try_files \$uri /index.php\$is_args\$args;
    }

    location ~ ^/index\.php(/|$) {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT \$realpath_root;
        fastcgi_read_timeout 300;
    }

    location ~* /(config|var|bin|app)/ {
        deny all;
    }
}
EOF
ln -sf /etc/nginx/sites-available/mautic /etc/nginx/sites-enabled/mautic
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

echo "STEP 4/7: SSL best effort"
if [ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
  certbot --nginx -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --non-interactive --redirect || true
fi

FINAL_URL="http://${DOMAIN}"
if [ -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
  FINAL_URL="https://${DOMAIN}"
fi

echo "STEP 5/7: mautic cli install"
CONFIG_FILE="${MAUTIC_DIR}/config/local.php"
if [ ! -f "${CONFIG_FILE}" ]; then
  sudo -u ${MAUTIC_USER} php "${MAUTIC_DIR}/bin/console" mautic:install "${FINAL_URL}" \
    --db_driver=pdo_mysql \
    --db_host=127.0.0.1 \
    --db_port=3306 \
    --db_name="${DB_NAME}" \
    --db_user="${DB_USER}" \
    --db_password="${DB_PASS}" \
    --admin_firstname="Admin" \
    --admin_lastname="User" \
    --admin_username="admin" \
    --admin_email="${ADMIN_EMAIL}" \
    --admin_password="${ADMIN_PASS}" \
    --force
fi

echo "STEP 6/7: post-install config"
php -r '\n$file = $argv[1];\n$siteUrl = $argv[2];\n$fromName = $argv[3];\n$fromEmail = $argv[4];\n$mailerDsn = $argv[5];\n$config = include $file;\nif (!is_array($config)) {\n    fwrite(STDERR, "Unexpected config format\\n");\n    exit(1);\n}\n$config["site_url"] = $siteUrl;\n$config["mailer_from_name"] = $fromName;\n$config["mailer_from_email"] = $fromEmail;\n$config["mailer_dsn"] = $mailerDsn;\nfile_put_contents($file, "<?php\\nreturn ".var_export($config, true).";\\n");\n' "${CONFIG_FILE}" "${FINAL_URL}" "${MAILER_FROM_NAME}" "${ADMIN_EMAIL}" "smtp://127.0.0.1:25"

chown ${MAUTIC_USER}:${MAUTIC_USER} "${CONFIG_FILE}"

cat > /etc/cron.d/mautic <<EOF
*/15 * * * * ${MAUTIC_USER} php ${MAUTIC_DIR}/bin/console mautic:segments:update --batch-limit=300 > /dev/null 2>&1
5-59/15 * * * * ${MAUTIC_USER} php ${MAUTIC_DIR}/bin/console mautic:campaigns:update --batch-limit=300 > /dev/null 2>&1
10-59/15 * * * * ${MAUTIC_USER} php ${MAUTIC_DIR}/bin/console mautic:campaigns:trigger --batch-limit=300 > /dev/null 2>&1
*/5 * * * * ${MAUTIC_USER} php ${MAUTIC_DIR}/bin/console mautic:emails:send --message-limit=200 > /dev/null 2>&1
EOF
chmod 0644 /etc/cron.d/mautic

echo "STEP 7/7: cache + credentials"
sudo -u ${MAUTIC_USER} php "${MAUTIC_DIR}/bin/console" cache:clear || true
sudo -u ${MAUTIC_USER} php "${MAUTIC_DIR}/bin/console" cache:warmup || true

cat > "${ENV_FILE}" <<EOF
DOMAIN="${DOMAIN}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
MAILER_FROM_NAME="${MAILER_FROM_NAME}"
DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"
ADMIN_PASS="${ADMIN_PASS}"
EOF
chmod 600 "${ENV_FILE}"

cat > "${CREDS_FILE}" <<EOF
URL=${FINAL_URL}
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASS=${ADMIN_PASS}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASS=${DB_PASS}
EOF
chmod 600 "${CREDS_FILE}"

touch "${SUCCESS_MARKER}"

echo
echo "=== MAUTIC INSTALL COMPLETE ==="
echo "URL: ${FINAL_URL}"
echo "Admin: ${ADMIN_EMAIL}"
echo "Password: ${ADMIN_PASS}"
