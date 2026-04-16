#!/bin/bash
set -euo pipefail

DB_NAME="${DB_NAME:-ems_mautic}"
DB_USER="${DB_USER:-ems_mautic_user}"
DB_PASS="${DB_PASS:-$(openssl rand -base64 24)}"
DB_ROOT_PASS="${DB_ROOT_PASS:-}"

LOG_FILE="/var/log/mysql84-install.log"
ENV_FILE="/root/.mautic_env"
STATUS_FILE="/root/mysql84-status.txt"
SUCCESS_MARKER="/root/.mysql84_config_complete"

exec > >(tee -a "${LOG_FILE}") 2>&1
export DEBIAN_FRONTEND=noninteractive

echo "=== MYSQL 8.4 CONFIG START $(date) ==="

if [ -f "${ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
fi

if [ -f "${SUCCESS_MARKER}" ]; then
  echo "MySQL configuration already completed."
  cat "${STATUS_FILE}" 2>/dev/null || true
  exit 0
fi

command -v mysql >/dev/null 2>&1 || {
  echo "ERROR: mysql command not found. Install MySQL 8.4 manually first." >&2
  exit 1
}

MYSQL_VERSION="$(mysql --version || true)"
echo "Detected MySQL: ${MYSQL_VERSION}"
if ! echo "${MYSQL_VERSION}" | grep -Eq 'Distrib 8\.(4|[5-9]|[1-9][0-9])|Ver 8\.(4|[5-9]|[1-9][0-9])'; then
  echo "ERROR: MySQL 8.4+ is required. Current: ${MYSQL_VERSION}" >&2
  exit 1
fi

systemctl enable --now mysql

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

run_mysql_root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
run_mysql_root -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
run_mysql_root -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
run_mysql_root -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;"

mysql -u "${DB_USER}" -p"${DB_PASS}" -h 127.0.0.1 -D "${DB_NAME}" -e "SELECT 1;" >/dev/null

cat >> "${ENV_FILE}" <<EOF
DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
DB_PASS="${DB_PASS}"
EOF
chmod 600 "${ENV_FILE}"

cat > "${STATUS_FILE}" <<EOF
MYSQL 8.4 STATUS
================
Version: ${MYSQL_VERSION}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}

Next step:
  sudo bash /root/mautic-installer.sh
EOF
chmod 600 "${STATUS_FILE}"

touch "${SUCCESS_MARKER}"

echo
echo "=== MYSQL 8.4 CONFIG COMPLETE ==="
cat "${STATUS_FILE}"