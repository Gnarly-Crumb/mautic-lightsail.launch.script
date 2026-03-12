#!/bin/sh
SCRIPT_SOURCE_PATH=$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")
export SCRIPT_SOURCE_PATH
exec /bin/bash <<'PROVISIONER'
set -euo pipefail
umask 002
exec 1>>/var/log/mautic-provision.log 2>&1
echo "=== PROVISIONING START: $(date) ==="
if [ -f /root/.mautic_env ]; then
    . /root/.mautic_env
fi
DOMAIN="${DOMAIN:-ems.mympress.com}"
ADMIN_EMAIL="${ADMIN_EMAIL:-administrator@mympress.com}"
MAUTIC_VERSION="7.0.1"
MAUTIC_DIR="/var/www/mautic"
MAUTIC_USER="mautic"
MAUTIC_GROUP="www-data"
TIMEZONE="${TIMEZONE:-UTC}"          # e.g. America/New_York
LOCALE="${LOCALE:-en}"
MAILER_FROM_NAME="${MAILER_FROM_NAME:-Mautic}"
export DEBIAN_FRONTEND=noninteractive
export HOME=/root
CODENAME=$(lsb_release -cs || echo "")
echo "Using apt codename: $CODENAME"
timedatectl set-timezone "$TIMEZONE" || true
until ping -c1 archive.ubuntu.com &>/dev/null; do sleep 2; done
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
apt-get update && apt-get -y upgrade
apt-get install -y software-properties-common curl wget unzip git htop fail2ban ufw \
    chrony gnupg lsb-release ca-certificates nginx mysql-server redis-server rsync \
    postfix unattended-upgrades monit
export COMPOSER_ALLOW_SUPERUSER=1
postconf -e 'inet_interfaces = loopback-only'
postconf -e 'mydestination = localhost'
postconf -e 'relayhost ='
service postfix restart
dpkg-reconfigure -f noninteractive unattended-upgrades
cat <<MONIT > /etc/monit/monitrc
set daemon 60
set logfile syslog
set mailserver localhost
set alert ${ADMIN_EMAIL} but not on { instance, action }

# check critical services
check process nginx with pidfile /run/nginx.pid
    start program = "/bin/systemctl start nginx"
    stop program  = "/bin/systemctl stop nginx"
    if failed port 80 protocol http then alert

check process php-fpm with pidfile /run/php/php8.3-fpm.pid
    start program = "/bin/systemctl start php8.3-fpm"
    stop program  = "/bin/systemctl stop php8.3-fpm"
    if failed unixsocket /run/php/php8.3-fpm.sock then alert

check process mysql with pidfile /var/run/mysqld/mysqld.pid
    start program = "/bin/systemctl start mysql"
    stop program  = "/bin/systemctl stop mysql"
    if failed port 3306 then alert

check process redis with pidfile /var/run/redis/redis-server.pid
    start program = "/bin/systemctl start redis-server"
    stop program  = "/bin/systemctl stop redis-server"
    if failed port 6379 then alert

# disk space warning
check filesystem rootfs with path /
    if space usage > 80% then alert
MONIT
chmod 600 /etc/monit/monitrc
systemctl enable --now monit
apt-get clean
add-apt-repository ppa:ondrej/php -y && apt-get update
apt-get install -y php8.3-fpm php8.3-cli php8.3-mysql php8.3-gd php8.3-mbstring \
    php8.3-xml php8.3-curl php8.3-zip php8.3-intl php8.3-imap php8.3-bcmath \
    php8.3-redis php8.3-opcache
PHP_INI="/etc/php/8.3/fpm/php.ini"
sed -i "s/^memory_limit = .*/memory_limit = 512M/" "$PHP_INI"
sed -i "s/^;\\?session.save_handler.*/session.save_handler = redis/" "$PHP_INI"
sed -i "s|^;\\?session.save_path.*|session.save_path = \"tcp://127.0.0.1:6379?database=0\"|" "$PHP_INI"
grep -q '^opcache.memory_consumption' "$PHP_INI" || cat >> "$PHP_INI" <<'EOP'
opcache.memory_consumption=256
opcache.max_accelerated_files=10000
opcache.revalidate_freq=0
EOP
MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
CHILDREN=$((MEM_KB / 120000))
[ $CHILDREN -lt 5 ] && CHILDREN=5
[ $CHILDREN -gt 100 ] && CHILDREN=100
cat <<EOF > /etc/php/8.3/fpm/pool.d/www.conf
[www]
user = www-data
group = www-data
listen = /run/php/php8.3-fpm.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = $CHILDREN
pm.start_servers = $((CHILDREN/4))
pm.min_spare_servers = $((CHILDREN/4))
pm.max_spare_servers = $((CHILDREN/2))
EOF
systemctl restart php8.3-fpm
if [ -f /root/.mautic_env ]; then
    . /root/.mautic_env
fi
DB_ROOT_PASS="${DB_ROOT_PASS:-$(openssl rand -base64 24)}"
DB_USER="${DB_USER:-ems_mautic_user}"
DB_PASS="${DB_PASS:-$(openssl rand -base64 24)}"
DB_NAME="${DB_NAME:-ems_mautic}"
ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -base64 18)}"
cat <<ENV > /root/.mautic_env
DB_ROOT_PASS="${DB_ROOT_PASS}"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"
DB_NAME="${DB_NAME}"
ADMIN_PASS="${ADMIN_PASS}"
DOMAIN="${DOMAIN}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
MAILER_FROM_NAME="${MAILER_FROM_NAME}"
ENV
chmod 600 /root/.mautic_env
MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
POOL=$((MEM_KB/2/1024))
[ $POOL -gt 1024 ] && POOL=1024
cat <<EOF > /etc/mysql/conf.d/mautic.cnf
[mysqld]
innodb_buffer_pool_size = ${POOL}M
innodb_log_file_size = 64M
max_connections = 200
innodb_flush_log_at_trx_commit = 2
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
EOF
systemctl restart mysql
for i in {1..10}; do
    if mysql --protocol=socket -e "SELECT 1" >/dev/null 2>&1; then
        mysql --protocol=socket -e \
            "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DB_ROOT_PASS}'; FLUSH PRIVILEGES;"
        break
    fi
    sleep 3
done
mysql -u root -p"${DB_ROOT_PASS}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -p"${DB_ROOT_PASS}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -u root -p"${DB_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"
sed -i 's/^# maxmemory <bytes>/maxmemory 256mb/' /etc/redis/redis.conf
sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
systemctl restart redis-server
BUILD_DIR="/tmp/mautic_build"
mkdir -p "$BUILD_DIR"
wget -q "https://github.com/mautic/mautic/releases/download/${MAUTIC_VERSION}/${MAUTIC_VERSION}.zip" -O /tmp/mautic.zip
unzip -o /tmp/mautic.zip -d "$BUILD_DIR"
if [ ! -f "${BUILD_DIR}/index.php" ]; then
    subdir=$(find "$BUILD_DIR" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)
    if [ -n "$subdir" ]; then
        BUILD_DIR="$subdir"
    fi
fi
WEBROOT_PATH="${MAUTIC_DIR}/public"
cat <<EOF > /etc/nginx/sites-available/mautic.conf
server {
    listen 80;
    server_name ${DOMAIN};
    root ${WEBROOT_PATH};
    index index.php;

    # fastcgi buffers tuned to avoid 502/504 on large exports
    fastcgi_buffers 16 16k;
    fastcgi_buffer_size 32k;

    # static file handling
    location / { try_files \$uri \$uri/ /index.php\$is_args\$args; }
    location ~ ^/index\.php(/|$) {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$realpath_root\$fastcgi_script_name;
        fastcgi_read_timeout 300;
    }

    # internal protection of sensitive paths
    location ~* (app/config|var/logs|bin/console) { deny all; }

    # allow larger uploads (e.g. import files)
    client_max_body_size 100M;

    # security headers
    add_header X-Frame-Options SAMEORIGIN;
    add_header X-Content-Type-Options nosniff;

    # gzip for assets
    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;
    gzip_proxied any;
}
EOF
ln -sf /etc/nginx/sites-available/mautic.conf /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx
if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi
cd "$BUILD_DIR"
echo "Running Composer install without package scripts"
composer install --no-dev --no-scripts --no-plugins --no-autoloader --no-interaction
echo "Generating optimized Composer autoloader"
composer dump-autoload --optimize
cd -
mkdir -p "$MAUTIC_DIR"
rsync -a "$BUILD_DIR/" "$MAUTIC_DIR/"
id -u ${MAUTIC_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${MAUTIC_USER}
chown -R ${MAUTIC_USER}:${MAUTIC_GROUP} ${MAUTIC_DIR}
rm -rf "$BUILD_DIR"
if [ -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
    INSTALL_URL="https://${DOMAIN}"
else
    if ! grep -Fq "127.0.0.1 ${DOMAIN}" /etc/hosts; then
        echo "127.0.0.1 ${DOMAIN}" >> /etc/hosts
    fi
    INSTALL_URL="http://${DOMAIN}"
fi
if [ -f "${MAUTIC_DIR}/config/local.php" ] || [ -f "${MAUTIC_DIR}/app/config/local.php" ]; then
    echo "Mautic appears to be already installed; skipping mautic:install"
else
    sudo -u ${MAUTIC_USER} bash -c "cd ${MAUTIC_DIR} && php bin/console mautic:install ${INSTALL_URL} \
        --db_user=${DB_USER} --db_password='${DB_PASS}' \
        --db_name=${DB_NAME} --admin_email='${ADMIN_EMAIL}' \
        --admin_password='${ADMIN_PASS}' \
        --mailer_from_name='${MAILER_FROM_NAME}' --mailer_from_email='${ADMIN_EMAIL}' \
        --mailer_transport=smtp --mailer_host=localhost --mailer_port=25 \
        --timezone='${TIMEZONE}' --locale='${LOCALE}' \
        --no-interaction"
fi
ufw allow OpenSSH && ufw allow 'Nginx Full' && ufw --force enable
sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd
cat <<'EOF' > /etc/fail2ban/jail.d/mautic.local
[sshd]
enabled = true

[nginx-http-auth]
enabled = true
EOF
systemctl restart fail2ban
if [ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
    snap install --classic certbot && ln -sf /snap/bin/certbot /usr/bin/certbot
    certbot --nginx -d "$DOMAIN" -m "$ADMIN_EMAIL" --agree-tos --non-interactive --redirect || true
fi
cat <<EOF > /etc/cron.d/mautic
# Mautic 7 production crons (every 5 minutes)
*/5 * * * * ${MAUTIC_USER} php ${MAUTIC_DIR}/bin/console mautic:segments:update > /dev/null 2>&1
*/5 * * * * ${MAUTIC_USER} php ${MAUTIC_DIR}/bin/console mautic:campaigns:update > /dev/null 2>&1
*/5 * * * * ${MAUTIC_USER} php ${MAUTIC_DIR}/bin/console mautic:campaigns:trigger > /dev/null 2>&1
*/5 * * * * ${MAUTIC_USER} php ${MAUTIC_DIR}/bin/console mautic:emails:send > /dev/null 2>&1
EOF
cat <<LOGROT > /etc/logrotate.d/mautic
${MAUTIC_DIR}/var/logs/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
LOGROT
rm -rf /var/lib/apt/lists/*
cat <<CRED > /root/mautic-credentials.txt
URL: ${INSTALL_URL}
Admin: ${ADMIN_EMAIL}
Pass: ${ADMIN_PASS}
DB_ROOT_PASS: ${DB_ROOT_PASS}
CRED
chmod 600 /root/mautic-credentials.txt
SCRIPT_PATH="/usr/local/bin/launch-mautic-lightsail.sh"
if [ ! -e "$SCRIPT_PATH" ] && [ -f "${SCRIPT_SOURCE_PATH}" ]; then
    cp "${SCRIPT_SOURCE_PATH}" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
fi
cat <<CRON > /etc/cron.weekly/mautic-provisioner
#!/bin/sh
# re-run the provision script to apply any new configuration or updates
MAUTIC_PROVISION_FROM_CRON=1 ${SCRIPT_PATH} || true
CRON
chmod +x /etc/cron.weekly/mautic-provisioner
echo "=== PROVISIONING COMPLETE ==="
if [ -z "${CI:-}" ] && [ -z "${MAUTIC_PROVISION_FROM_CRON:-}" ]; then
    reboot
fi
PROVISIONER
