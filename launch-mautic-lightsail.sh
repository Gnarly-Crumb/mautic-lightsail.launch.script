#!/bin/sh
# This header is for Dash. It immediately hands off the rest of the file to Bash.
# Supported stack:
# - Ubuntu 24.04 LTS (noble)
# - Mautic 7.x
# - PHP 8.3
# - MySQL 8.4 LTS
# This script is intended for a production Mautic host, not a frontend build environment.
SCRIPT_SOURCE_PATH=$(readlink -f "$0" 2>/dev/null || printf '%s\n' "$0")
export SCRIPT_SOURCE_PATH
exec /bin/bash <<'PROVISIONER'

# === 0. GLOBAL SAFETY & LOGGING ===
set -euo pipefail
umask 002
exec 1>>/var/log/mautic-provision.log 2>&1
echo "=== PROVISIONING START: $(date) ==="

# --- CONFIGURATION ---
# allow an external file to override the defaults (gold‑standard practice)
# example /root/.mautic_env containing DOMAIN, ADMIN_EMAIL, etc.
if [ -f /root/.mautic_env ]; then
    # shellcheck disable=SC1090
    . /root/.mautic_env
fi

DOMAIN="${DOMAIN:-ems.mympress.com}"
ADMIN_EMAIL="${ADMIN_EMAIL:-administrator@mympress.com}"
MAUTIC_VERSION="7.0.1"
MAUTIC_DIR="/var/www/mautic"
MAUTIC_USER="mautic"
MAUTIC_GROUP="www-data"
# optional overrides
TIMEZONE="${TIMEZONE:-UTC}"          # e.g. America/New_York
LOCALE="${LOCALE:-en}"
MAILER_FROM_NAME="${MAILER_FROM_NAME:-Mautic}"
export DEBIAN_FRONTEND=noninteractive
# Composer needs a HOME directory when running as root
export HOME=/root
SUCCESS_MARKER="/root/.mautic_provision_complete"

if [ -f "${SUCCESS_MARKER}" ]; then
    echo "Provisioning already completed successfully. Exiting."
    exit 0
fi

# detect Ubuntu codename for the single supported stack.
CODENAME=$(lsb_release -cs || echo "")
echo "Detected Ubuntu codename: ${CODENAME}"
if [ "${CODENAME}" != "noble" ]; then
    echo "ERROR: unsupported Ubuntu codename '${CODENAME}'. Provisioning requires Ubuntu 24.04 LTS (noble)." >&2
    exit 1
fi
# third‑party repos should be added using this variable.  if a repo doesn't
# yet support the current release (e.g. noble) you may need to fall back to
# the previous LTS after verifying compatibility.

# set timezone for the system early on (helps mysql/app logs)
timedatectl set-timezone "$TIMEZONE" || true

# === 1. SYSTEM READINESS & SWAP ===
# ensure network is up before continuing (Lightsail pods sometimes delay)
until ping -c1 archive.ubuntu.com &>/dev/null; do sleep 2; done

# create a 2GB swapfile if the instance has only 2GB of RAM; useful during
# composer installs and other memory spikes.  having swap available keeps the
# system steady but we won't use it aggressively.
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# === 2. PRIMARY PACKAGE INSTALL (NOBLE NATIVE) ===
# base packages plus utilities required by Mautic and provisioning.
apt-get update && apt-get -y upgrade
apt-get install -y software-properties-common curl wget unzip git htop fail2ban ufw \
    chrony gnupg lsb-release ca-certificates nginx redis-server rsync \
    postfix unattended-upgrades monit

# allow Composer to work as root (script already sets HOME)
export COMPOSER_ALLOW_SUPERUSER=1

# Configure Postfix in local-only mode so Mautic can send mail via localhost
postconf -e 'inet_interfaces = loopback-only'
postconf -e 'mydestination = localhost'
postconf -e 'relayhost ='
service postfix restart

# enable unattended upgrades for security patches only
dpkg-reconfigure -f noninteractive unattended-upgrades

# configure basic monitoring/alerting using monit
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

# purge apt cache to minimize disk usage
apt-get clean

# Install MySQL 8.4 LTS from Oracle's APT repository instead of the distro
# default MySQL package, which may lag behind Mautic's supported version floor.
MYSQL_REPO_CODENAME="noble"
mkdir -p /etc/apt/keyrings
rm -f /etc/apt/keyrings/mysql.gpg /usr/share/keyrings/mysql-archive-keyring.gpg
curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 | gpg --dearmor --yes -o /etc/apt/keyrings/mysql.gpg
cat <<EOF > /etc/apt/sources.list.d/mysql.list
deb [signed-by=/etc/apt/keyrings/mysql.gpg] http://repo.mysql.com/apt/ubuntu/ ${MYSQL_REPO_CODENAME} mysql-8.4-lts
deb [signed-by=/etc/apt/keyrings/mysql.gpg] http://repo.mysql.com/apt/ubuntu/ ${MYSQL_REPO_CODENAME} mysql-tools
EOF
if ! apt-get update; then
    echo "ERROR: failed to refresh APT metadata after MySQL keyring update" >&2
    exit 1
fi
apt-get install -y mysql-server

# === 3. PHP 8.3 SETUP & TUNING ===
add-apt-repository ppa:ondrej/php -y && apt-get update
apt-get install -y php8.3-fpm php8.3-cli php8.3-mysql php8.3-gd php8.3-mbstring \
    php8.3-xml php8.3-curl php8.3-zip php8.3-intl php8.3-imap php8.3-bcmath \
    php8.3-redis php8.3-opcache

PHP_INI="/etc/php/8.3/fpm/php.ini"
# basic tuning
sed -i "s/^memory_limit = .*/memory_limit = 512M/" "$PHP_INI"
sed -i "s/^;\\?session.save_handler.*/session.save_handler = redis/" "$PHP_INI"
sed -i "s|^;\\?session.save_path.*|session.save_path = \"tcp://127.0.0.1:6379?database=0\"|" "$PHP_INI"
# opcache is critical for performance
grep -q '^opcache.memory_consumption' "$PHP_INI" || cat >> "$PHP_INI" <<'EOP'
opcache.memory_consumption=256
opcache.max_accelerated_files=10000
opcache.revalidate_freq=0
EOP

# PHP-FPM Pool Tuning: set children based on available RAM (approx 120MB/child)
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

# === 4. SECRETS & DATABASE (ROBUST AUTH) ===
# if we have previously saved credentials, reuse them; otherwise generate
# new ones and persist to /root/.mautic_env so re‑running the script keeps
# the same database/admin passwords.
if [ -f /root/.mautic_env ]; then
    # shellcheck disable=SC1090
    . /root/.mautic_env
fi

DB_ROOT_PASS="${DB_ROOT_PASS:-$(openssl rand -base64 24)}"
DB_USER="${DB_USER:-ems_mautic_user}"
DB_PASS="${DB_PASS:-$(openssl rand -base64 24)}"
DB_NAME="${DB_NAME:-ems_mautic}"
ADMIN_PASS="${ADMIN_PASS:-$(openssl rand -base64 18)}"

# write back the persistent file so future invocations keep same values
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

# create a simple MySQL tuning file sized to about half of RAM (cap 1G)
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

# Robust MySQL Socket-to-Password transition. We attempt to authenticate
# as root with the unix socket (no password) and then immediately set a
# password without forcing an auth plugin that may not exist in MySQL 8.4.
ROOT_AUTH_READY=0
for i in {1..10}; do
    if mysql --protocol=socket -e "SELECT 1" >/dev/null 2>&1; then
        mysql --protocol=socket -e \
            "ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}'; FLUSH PRIVILEGES;"
        ROOT_AUTH_READY=1
        break
    fi
    if mysql -u root -p"${DB_ROOT_PASS}" -e "SELECT 1" >/dev/null 2>&1; then
        ROOT_AUTH_READY=1
        break
    fi
    sleep 3
done
[ "${ROOT_AUTH_READY}" -eq 1 ] || {
    echo "ERROR: unable to authenticate to MySQL as root after bootstrap" >&2
    exit 1
}

# after the password has been set use it for the rest of the provisioning
mysql -u root -p"${DB_ROOT_PASS}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -p"${DB_ROOT_PASS}" -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -u root -p"${DB_ROOT_PASS}" -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
mysql -u root -p"${DB_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

# === 5. TUNING (REDIS) ===
sed -i 's/^# maxmemory <bytes>/maxmemory 256mb/' /etc/redis/redis.conf
sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
systemctl restart redis-server

# === 6. NGINX CONFIG & WEBROOT DETECTION ===
BUILD_DIR="/tmp/mautic_build"
mkdir -p "$BUILD_DIR"
wget -q "https://github.com/mautic/mautic/releases/download/${MAUTIC_VERSION}/${MAUTIC_VERSION}.zip" -O /tmp/mautic.zip
unzip -o /tmp/mautic.zip -d "$BUILD_DIR"

# some release archives contain a top-level subdirectory (e.g. mautic-7.0.1/).
# validate the app root using the files the deploy/install path actually needs.
if [ ! -f "${BUILD_DIR}/bin/console" ] || [ ! -f "${BUILD_DIR}/index.php" ] || [ ! -f "${BUILD_DIR}/composer.json" ]; then
    subdir=$(find "$BUILD_DIR" -mindepth 1 -maxdepth 1 -type d \
        -exec test -f "{}/bin/console" ';' \
        -exec test -f "{}/index.php" ';' \
        -exec test -f "{}/composer.json" ';' \
        -print -quit)
    if [ -n "$subdir" ]; then
        BUILD_DIR="$subdir"
    fi
fi
if [ ! -f "${BUILD_DIR}/bin/console" ] || [ ! -f "${BUILD_DIR}/index.php" ] || [ ! -f "${BUILD_DIR}/composer.json" ]; then
    echo "ERROR: unable to locate Mautic application root in ${BUILD_DIR}" >&2
    exit 1
fi

# The release archive serves from the application root on this deployment.
WEBROOT_PATH="${MAUTIC_DIR}"

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

# === 7. HOST BUILD (COMPOSER) ===
# composer is used to assemble dependencies using the host PHP,
# which already has gd/imap enabled via apt packages.

# install composer locally if not already present
if ! command -v composer >/dev/null 2>&1; then
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
fi
# run a production-safe composer install inside the build tree using host PHP.
# this intentionally skips package scripts so the host does not run npm/webpack.
cd "$BUILD_DIR"
echo "Running Composer install without package scripts"
composer install --no-dev --no-scripts --no-plugins --no-autoloader --no-interaction
echo "Generating optimized Composer autoloader"
composer dump-autoload --optimize
cd -

# === 8. DEPLOY & CLI INSTALL ===
mkdir -p "$MAUTIC_DIR"
rsync -a "$BUILD_DIR/" "$MAUTIC_DIR/"
id -u ${MAUTIC_USER} >/dev/null 2>&1 || useradd -m -s /bin/bash ${MAUTIC_USER}
chown -R ${MAUTIC_USER}:${MAUTIC_GROUP} ${MAUTIC_DIR}

# we're done with the temporary build tree; remove it to free space
rm -rf "$BUILD_DIR"
# composer is left in place for potential future runs but can be purged if desired
# (no docker installed any more)

# determine which scheme to use for the installer.  only use HTTPS if a
# certificate already exists; otherwise install over HTTP first.
if [ -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
    INSTALL_URL="https://${DOMAIN}"
else
    if ! grep -Fq "127.0.0.1 ${DOMAIN}" /etc/hosts; then
        echo "127.0.0.1 ${DOMAIN}" >> /etc/hosts
    fi
    INSTALL_URL="http://${DOMAIN}"
fi

# run the installer.  it's fine to use HTTPS as long as the certificate is
# already in place (LICENSES or pre‑provisioned by the user).
if [ -f "${MAUTIC_DIR}/config/local.php" ] || [ -f "${MAUTIC_DIR}/app/config/local.php" ]; then
    echo "Mautic appears to be already installed; skipping mautic:install"
else
    sudo -u ${MAUTIC_USER} bash -c "cd ${MAUTIC_DIR} && php bin/console mautic:install ${INSTALL_URL} \
        --db_user=${DB_USER} --db_password='${DB_PASS}' \
        --db_name=${DB_NAME} --admin_email='${ADMIN_EMAIL}' \
        --admin_password='${ADMIN_PASS}' \
        --no-interaction"
fi

# Configure mailer settings after install. Mautic's v7 installer does not
# accept mailer flags, but the docs allow direct DSN configuration in local.php.
MAUTIC_CONFIG_FILE="${MAUTIC_DIR}/config/local.php"
if [ ! -f "${MAUTIC_CONFIG_FILE}" ] && [ -f "${MAUTIC_DIR}/app/config/local.php" ]; then
    MAUTIC_CONFIG_FILE="${MAUTIC_DIR}/app/config/local.php"
fi
if [ -f "${MAUTIC_CONFIG_FILE}" ]; then
    echo "Configuring Mautic mailer settings in ${MAUTIC_CONFIG_FILE}"
    php -r '
        $file = $argv[1];
        $fromName = $argv[2];
        $fromEmail = $argv[3];
        $mailerDsn = $argv[4];
        $config = include $file;
        if (!is_array($config)) {
            fwrite(STDERR, "Unexpected Mautic config format\n");
            exit(1);
        }
        $config["mailer_from_name"] = $fromName;
        $config["mailer_from_email"] = $fromEmail;
        $config["mailer_dsn"] = $mailerDsn;
        file_put_contents($file, "<?php\nreturn ".var_export($config, true).";\n");
    ' "${MAUTIC_CONFIG_FILE}" "${MAILER_FROM_NAME}" "${ADMIN_EMAIL}" "smtp://127.0.0.1:25"
    chown ${MAUTIC_USER}:${MAUTIC_GROUP} "${MAUTIC_CONFIG_FILE}"
fi

# === 9. SECURITY (UFW/FAIL2BAN) & SSL ===
# firewall rules – only allow SSH and web traffic
ufw allow OpenSSH && ufw allow 'Nginx Full' && ufw --force enable

# basic SSH hardening for a single‑purpose host
sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl restart sshd

# fail2ban already installed; add nginx + ssh jails if absent
cat <<'EOF' > /etc/fail2ban/jail.d/mautic.local
[sshd]
enabled = true

[nginx-http-auth]
enabled = true
EOF
systemctl restart fail2ban

# only request a certificate if one doesn't already exist; this allows the
# script to be rerun without hitting Let's Encrypt rate limits.
if [ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
    snap install --classic certbot && ln -sf /snap/bin/certbot /usr/bin/certbot
    certbot --nginx -d "$DOMAIN" -m "$ADMIN_EMAIL" --agree-tos --non-interactive --redirect || true
fi
FINAL_URL="${INSTALL_URL}"
if [ -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
    FINAL_URL="https://${DOMAIN}"
    if [ -f "${MAUTIC_CONFIG_FILE}" ]; then
        echo "Updating Mautic site URL to ${FINAL_URL}"
        php -r '
            $file = $argv[1];
            $siteUrl = $argv[2];
            $config = include $file;
            if (!is_array($config)) {
                fwrite(STDERR, "Unexpected Mautic config format\n");
                exit(1);
            }
            $config["site_url"] = $siteUrl;
            file_put_contents($file, "<?php\nreturn ".var_export($config, true).";\n");
        ' "${MAUTIC_CONFIG_FILE}" "${FINAL_URL}"
        chown ${MAUTIC_USER}:${MAUTIC_GROUP} "${MAUTIC_CONFIG_FILE}"
    fi
fi

# === 10. CRONS & FINALIZATION ===
cat <<EOF > /etc/cron.d/mautic
# Mautic 7 production crons (every 5 minutes)
*/5 * * * * ${MAUTIC_USER} php ${MAUTIC_DIR}/bin/console mautic:segments:update > /dev/null 2>&1
*/5 * * * * ${MAUTIC_USER} php ${MAUTIC_DIR}/bin/console mautic:campaigns:update > /dev/null 2>&1
*/5 * * * * ${MAUTIC_USER} php ${MAUTIC_DIR}/bin/console mautic:campaigns:trigger > /dev/null 2>&1
*/5 * * * * ${MAUTIC_USER} php ${MAUTIC_DIR}/bin/console mautic:emails:send > /dev/null 2>&1
EOF

# rotate the Mautic log file; keep a week of history
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

# remove apt lists to shrink image/cleanup
rm -rf /var/lib/apt/lists/*

# update human-readable credentials file
cat <<CRED > /root/mautic-credentials.txt
URL: ${FINAL_URL}
Admin: ${ADMIN_EMAIL}
Pass: ${ADMIN_PASS}
DB_ROOT_PASS: ${DB_ROOT_PASS}
CRED
chmod 600 /root/mautic-credentials.txt

# === 11. SELF‑MAINTENANCE ===
# install a root cron entry that reruns this script weekly so that the
# system can pick up package updates and security tweaks.  the schedule and
# path can be changed as desired; using `run-parts` allows us to drop a file
# into /etc/cron.weekly instead of editing crontab directly.
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

touch "${SUCCESS_MARKER}"
echo "=== PROVISIONING COMPLETE ==="
# if running under cron we don't force a reboot; otherwise reboot the
# freshly‑provisioned machine so that kernel updates etc. take effect.
if [ -z "${CI:-}" ] && [ -z "${MAUTIC_PROVISION_FROM_CRON:-}" ]; then
    reboot
fi

PROVISIONER
