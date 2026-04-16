#!/bin/bash
set -euo pipefail

DOMAIN="${DOMAIN:-ems.mympress.com}"
ADMIN_EMAIL="${ADMIN_EMAIL:-administrator@mympress.com}"
TIMEZONE="${TIMEZONE:-UTC}"
LOCALE="${LOCALE:-en}"
MAILER_FROM_NAME="${MAILER_FROM_NAME:-Mautic}"

MAUTIC_DIR="/var/www/mautic"
MAUTIC_USER="www-data"
LOG_FILE="/var/log/mautic-prep.log"
STATUS_FILE="/root/mautic-prep-status.txt"
SUCCESS_MARKER="/root/.mautic_prep_complete"
ENV_FILE="/root/.mautic_env"
REPO_BASE="https://raw.githubusercontent.com/Gnarly-Crumb/mautic-lightsail.launch.script/main"

exec > >(tee -a "${LOG_FILE}") 2>&1
export DEBIAN_FRONTEND=noninteractive

echo "=== MAUTIC PREP START $(date) ==="

if [ -f "${SUCCESS_MARKER}" ]; then
  echo "Prep already completed successfully."
  cat "${STATUS_FILE}" 2>/dev/null || true
  exit 0
fi

CODENAME="$(lsb_release -cs || true)"
echo "Detected Ubuntu codename: ${CODENAME}"
if [ "${CODENAME}" != "noble" ]; then
  echo "ERROR: Ubuntu 24.04 LTS (noble) is required." >&2
  exit 1
fi

until ping -c1 archive.ubuntu.com >/dev/null 2>&1; do sleep 2; done
timedatectl set-timezone "${TIMEZONE}" || true

echo "STEP 1/9: swap"
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "STEP 2/9: base packages"
apt-get update
apt-get upgrade -y
apt-get install -y \
  software-properties-common \
  curl wget unzip git \
  ca-certificates gnupg lsb-release \
  htop fail2ban ufw chrony rsync \
  nginx redis-server postfix monit \
  snapd certbot python3-certbot-nginx \
  composer \
  php8.3-fpm php8.3-cli php8.3-common php8.3-mysql \
  php8.3-gd php8.3-mbstring php8.3-xml php8.3-curl \
  php8.3-zip php8.3-intl php8.3-imap php8.3-bcmath \
  php8.3-redis php8.3-opcache php8.3-soap

echo "STEP 3/9: postfix"
postconf -e 'inet_interfaces = loopback-only'
postconf -e 'mydestination = localhost'
postconf -e 'relayhost ='
systemctl restart postfix

echo "STEP 4/9: PHP tuning"
PHP_INI="/etc/php/8.3/fpm/php.ini"
sed -i "s/^memory_limit = .*/memory_limit = 512M/" "${PHP_INI}"
sed -i "s/^;\\?cgi.fix_pathinfo=.*/cgi.fix_pathinfo=0/" "${PHP_INI}" || true
sed -i "s/^;\\?session.save_handler.*/session.save_handler = redis/" "${PHP_INI}"
sed -i "s|^;\\?session.save_path.*|session.save_path = \"tcp://127.0.0.1:6379?database=0\"|" "${PHP_INI}"

grep -q '^opcache.memory_consumption' "${PHP_INI}" || cat >> "${PHP_INI}" <<'EOF'
opcache.memory_consumption=256
opcache.max_accelerated_files=10000
opcache.revalidate_freq=0
EOF

MEM_KB="$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
CHILDREN=$((MEM_KB / 120000))
[ "${CHILDREN}" -lt 5 ] && CHILDREN=5
[ "${CHILDREN}" -gt 100 ] && CHILDREN=100

cat > /etc/php/8.3/fpm/pool.d/www.conf <<EOF
[www]
user = www-data
group = www-data
listen = /run/php/php8.3-fpm.sock
listen.owner = www-data
listen.group = www-data
pm = dynamic
pm.max_children = ${CHILDREN}
pm.start_servers = $((CHILDREN/4))
pm.min_spare_servers = $((CHILDREN/4))
pm.max_spare_servers = $((CHILDREN/2))
EOF

systemctl restart php8.3-fpm

echo "STEP 5/9: Redis"
sed -i 's/^# maxmemory <bytes>/maxmemory 256mb/' /etc/redis/redis.conf
sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf
systemctl restart redis-server

echo "STEP 6/9: nginx placeholder"
mkdir -p "${MAUTIC_DIR}/public"
cat > "${MAUTIC_DIR}/public/index.html" <<EOF
<!doctype html>
<html>
<head><title>Mautic server prepared</title></head>
<body>
<h1>Mautic server prepared</h1>
<p>Stage 1 completed. Install/verify MySQL 8.4, then run:</p>
<pre>sudo bash /root/mautic-installer.sh</pre>
</body>
</html>
EOF

chown -R ${MAUTIC_USER}:${MAUTIC_USER} "${MAUTIC_DIR}"
find "${MAUTIC_DIR}" -type d -exec chmod 775 {} \;
find "${MAUTIC_DIR}" -type f -exec chmod 664 {} \;

cat > /etc/nginx/sites-available/mautic <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    root ${MAUTIC_DIR}/public;
    index index.php index.html;

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
systemctl restart nginx

echo "STEP 7/9: monit/fail2ban/ufw"
cat > /etc/monit/monitrc <<EOF
set daemon 60
set logfile syslog
set mailserver localhost
set alert ${ADMIN_EMAIL} but not on { instance, action }

check process nginx with pidfile /run/nginx.pid
    start program = "/bin/systemctl start nginx"
    stop program  = "/bin/systemctl stop nginx"
    if failed port 80 protocol http then alert

check process php-fpm with pidfile /run/php/php8.3-fpm.pid
    start program = "/bin/systemctl start php8.3-fpm"
    stop program  = "/bin/systemctl stop php8.3-fpm"
    if failed unixsocket /run/php/php8.3-fpm.sock then alert

check process redis with pidfile /var/run/redis/redis-server.pid
    start program = "/bin/systemctl start redis-server"
    stop program  = "/bin/systemctl stop redis-server"
    if failed port 6379 then alert
EOF
chmod 600 /etc/monit/monitrc
systemctl enable --now monit

cat > /etc/fail2ban/jail.d/mautic.local <<'EOF'
[sshd]
enabled = true

[nginx-http-auth]
enabled = true
EOF
systemctl restart fail2ban

ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

echo "STEP 8/9: env + installer download"
cat > "${ENV_FILE}" <<EOF
DOMAIN="${DOMAIN}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
TIMEZONE="${TIMEZONE}"
LOCALE="${LOCALE}"
MAILER_FROM_NAME="${MAILER_FROM_NAME}"
EOF
chmod 600 "${ENV_FILE}"

curl -fsSL "${REPO_BASE}/mautic-installer.sh" -o /root/mautic-installer.sh
chmod +x /root/mautic-installer.sh

echo "STEP 9/9: SSL best effort"
if [ ! -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
  certbot --nginx -d "${DOMAIN}" -m "${ADMIN_EMAIL}" --agree-tos --non-interactive --redirect || true
fi

MYSQL_STATUS="NOT INSTALLED"
if command -v mysql >/dev/null 2>&1; then
  MYSQL_STATUS="$(mysql --version || true)"
fi

CERT_STATUS="NOT PRESENT"
if [ -d "/etc/letsencrypt/live/${DOMAIN}" ]; then
  CERT_STATUS="PRESENT"
fi

cat > "${STATUS_FILE}" <<EOF
MAUTIC SERVER PREP STATUS
=========================
OS: $(lsb_release -ds)
Domain: ${DOMAIN}
Timezone: ${TIMEZONE}
PHP: $(php -v | head -n1)
Composer: $(composer --version 2>/dev/null || echo missing)
Nginx: $(nginx -v 2>&1)
Redis: $(redis-server --version 2>/dev/null || echo missing)
Postfix: $(postconf mail_version 2>/dev/null | awk '{print $3}')
MySQL: ${MYSQL_STATUS}
SSL Cert: ${CERT_STATUS}

NEXT STEPS
==========
1. SSH in
2. Install or verify MySQL 8.4 manually
3. Run:
   sudo bash /root/mautic-installer.sh
EOF

chmod 600 "${STATUS_FILE}"
touch "${SUCCESS_MARKER}"

echo
echo "=== PREP COMPLETE ==="
cat "${STATUS_FILE}"