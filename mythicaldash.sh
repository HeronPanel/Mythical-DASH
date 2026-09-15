#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# MythicalDash + Pterodactyl Installer
# Ubuntu 22.04 / 24.04
#
# Made By Heron
#
# IMPORTANT:
# MythicalDash v3-remastered is currently marked by the
# upstream repository as a development/beta branch.
#
# This installer NEVER silently installs that branch.
# ============================================================

SCRIPT_VERSION="1.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[+]${NC} $1"
}

info() {
    echo -e "${CYAN}[i]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

error() {
    echo -e "${RED}[-]${NC} $1"
}

die() {
    error "$1"
    exit 1
}

trap 'error "Installer failed on line $LINENO. Check the output above."' ERR

clear || true

echo -e "${CYAN}"
cat <<'BANNER'
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║             MYTHICALDASH INSTALLER                      ║
║                                                          ║
║          MythicalDash + Pterodactyl                     ║
║                                                          ║
║                    Made By Heron                        ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

echo
echo -e "${WHITE}Installer:${NC} ${SCRIPT_VERSION}"
echo

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "Run this installer as root."
fi

# ------------------------------------------------------------
# OS check
# ------------------------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found."
fi

source /etc/os-release

if [[ "${ID}" != "ubuntu" ]]; then
    die "This installer supports Ubuntu 22.04 and Ubuntu 24.04 only."
fi

case "${VERSION_ID}" in
    22.04|24.04)
        log "Ubuntu ${VERSION_ID} detected."
        ;;
    *)
        die "Unsupported Ubuntu version: ${VERSION_ID}"
        ;;
esac

# ------------------------------------------------------------
# Architecture
# ------------------------------------------------------------

ARCH="$(dpkg --print-architecture)"

case "${ARCH}" in
    amd64|arm64)
        log "Architecture: ${ARCH}"
        ;;
    *)
        die "Unsupported architecture: ${ARCH}"
        ;;
esac

# ------------------------------------------------------------
# Variables
# ------------------------------------------------------------

PTERODACTYL_DIR="/var/www/pterodactyl"
MYTHICAL_DIR="/var/www/mythicaldash"

ENV_DIR="/etc/heron-mythicaldash"
CONFIG_FILE="${ENV_DIR}/installer.conf"

mkdir -p "${ENV_DIR}"

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

random_password() {
    tr -dc 'A-Za-z0-9_@%+=' </dev/urandom | head -c 32
}

random_hex() {
    openssl rand -hex 32
}

ask_required() {
    local prompt="$1"
    local value=""

    while [[ -z "${value}" ]]; do
        read -r -p "${prompt}: " value
    done

    echo "${value}"
}

ask_default() {
    local prompt="$1"
    local default="$2"
    local value=""

    read -r -p "${prompt} [${default}]: " value

    if [[ -z "${value}" ]]; then
        value="${default}"
    fi

    echo "${value}"
}

yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local answer

    while true; do
        if [[ "${default}" == "Y" ]]; then
            read -r -p "${prompt} [Y/n]: " answer
            answer="${answer:-Y}"
        else
            read -r -p "${prompt} [y/N]: " answer
            answer="${answer:-N}"
        fi

        case "${answer,,}" in
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
        esac
    done
}

# ------------------------------------------------------------
# Existing installation detection
# ------------------------------------------------------------

if [[ -d "${PTERODACTYL_DIR}" ]]; then
    warn "Pterodactyl directory already exists:"
    echo "      ${PTERODACTYL_DIR}"
fi

if [[ -d "${MYTHICAL_DIR}" ]]; then
    warn "MythicalDash directory already exists:"
    echo "      ${MYTHICAL_DIR}"
fi

if systemctl is-active --quiet nginx 2>/dev/null; then
    info "Nginx is already running."
fi

if systemctl is-active --quiet mysql 2>/dev/null ||
   systemctl is-active --quiet mariadb 2>/dev/null; then
    info "MariaDB/MySQL is already running."
fi

echo

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

PTERO_DOMAIN="$(ask_required 'Pterodactyl domain, e.g. panel.example.com')"

DASH_DOMAIN="$(ask_required 'MythicalDash domain, e.g. dashboard.example.com')"

ADMIN_EMAIL="$(ask_required 'Admin email')"

read -r -s -p "Pterodactyl admin password: " PTERO_ADMIN_PASSWORD
echo

if [[ ${#PTERO_ADMIN_PASSWORD} -lt 12 ]]; then
    die "Admin password must contain at least 12 characters."
fi

DB_NAME="$(ask_default 'Pterodactyl database name' 'panel')"
DB_USER="$(ask_default 'Pterodactyl database user' 'pterodactyl')"

DB_PASSWORD="$(random_password)"

APP_KEY="$(random_hex)"

read -r -p "Enable automatic HTTPS with Let's Encrypt? [Y/n]: " SSL_CHOICE
SSL_CHOICE="${SSL_CHOICE:-Y}"

if [[ "${SSL_CHOICE,,}" == "y" || "${SSL_CHOICE,,}" == "yes" ]]; then
    ENABLE_SSL="yes"
else
    ENABLE_SSL="no"
fi

# ------------------------------------------------------------
# Save config
# ------------------------------------------------------------

cat > "${CONFIG_FILE}" <<EOF
PTERO_DOMAIN="${PTERO_DOMAIN}"
DASH_DOMAIN="${DASH_DOMAIN}"
ADMIN_EMAIL="${ADMIN_EMAIL}"
DB_NAME="${DB_NAME}"
DB_USER="${DB_USER}"
DB_PASSWORD="${DB_PASSWORD}"
APP_KEY="${APP_KEY}"
ENABLE_SSL="${ENABLE_SSL}"
EOF

chmod 600 "${CONFIG_FILE}"

echo
echo -e "${WHITE}Installation configuration:${NC}"
echo
echo "Pterodactyl : ${PTERO_DOMAIN}"
echo "MythicalDash: ${DASH_DOMAIN}"
echo "Admin email : ${ADMIN_EMAIL}"
echo "SSL         : ${ENABLE_SSL}"
echo

if ! yes_no "Continue with installation?" "Y"; then
    echo "Cancelled."
    exit 0
fi

# ------------------------------------------------------------
# System preparation
# ------------------------------------------------------------

log "Updating package lists..."

export DEBIAN_FRONTEND=noninteractive

apt-get update

log "Installing base dependencies..."

apt-get install -y \
    ca-certificates \
    curl \
    wget \
    git \
    unzip \
    tar \
    gzip \
    jq \
    openssl \
    gnupg \
    lsb-release \
    apt-transport-https \
    software-properties-common \
    sudo \
    cron \
    socat \
    acl \
    certbot \
    python3-certbot-nginx

# ------------------------------------------------------------
# Swap
# ------------------------------------------------------------

TOTAL_RAM_MB="$(free -m | awk '/^Mem:/{print $2}')"

if (( TOTAL_RAM_MB < 4096 )); then

    if [[ ! -f /swapfile ]]; then
        warn "Less than 4GB RAM detected."

        log "Creating 2GB swap..."

        fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048

        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile

        if ! grep -q "^/swapfile " /etc/fstab; then
            echo "/swapfile none swap sw 0 0" >> /etc/fstab
        fi
    fi
fi

# ------------------------------------------------------------
# Docker
# ------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1; then

    log "Installing Docker..."

    curl -fsSL https://get.docker.com | sh

    systemctl enable --now docker

else

    log "Docker already installed."
fi

# ------------------------------------------------------------
# Docker Compose
# ------------------------------------------------------------

if docker compose version >/dev/null 2>&1; then
    log "Docker Compose plugin detected."
else
    warn "Docker Compose plugin was not detected."

    apt-get install -y docker-compose-plugin
fi

# ------------------------------------------------------------
# MariaDB
# ------------------------------------------------------------

if ! command -v mariadb >/dev/null 2>&1; then

    log "Installing MariaDB..."

    apt-get install -y mariadb-server mariadb-client

    systemctl enable --now mariadb

else
    log "MariaDB already installed."
fi

systemctl enable --now mariadb

# ------------------------------------------------------------
# Redis
# ------------------------------------------------------------

if ! command -v redis-server >/dev/null 2>&1; then

    log "Installing Redis..."

    apt-get install -y redis-server

else

    log "Redis already installed."

fi

systemctl enable --now redis-server

# ------------------------------------------------------------
# Nginx
# ------------------------------------------------------------

if ! command -v nginx >/dev/null 2>&1; then

    log "Installing Nginx..."

    apt-get install -y nginx

else

    log "Nginx already installed."

fi

systemctl enable --now nginx

# ------------------------------------------------------------
# PHP
# ------------------------------------------------------------

log "Installing PHP and extensions..."

apt-get install -y \
    php \
    php-cli \
    php-common \
    php-curl \
    php-fpm \
    php-gd \
    php-intl \
    php-mbstring \
    php-mysql \
    php-bcmath \
    php-xml \
    php-zip \
    php-tokenizer \
    php-opcache \
    php-readline

PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"

log "Detected PHP ${PHP_VERSION}"

# ------------------------------------------------------------
# Composer
# ------------------------------------------------------------

if ! command -v composer >/dev/null 2>&1; then

    log "Installing Composer..."

    EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"

    php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"

    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"

    if [[ "${EXPECTED_CHECKSUM}" != "${ACTUAL_CHECKSUM}" ]]; then
        rm -f /tmp/composer-setup.php
        die "Composer installer checksum verification failed."
    fi

    php /tmp/composer-setup.php \
        --install-dir=/usr/local/bin \
        --filename=composer

    rm -f /tmp/composer-setup.php

else

    log "Composer already installed."

fi

# ------------------------------------------------------------
# MariaDB database
# ------------------------------------------------------------

log "Creating Pterodactyl database..."

mysql -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
CHARACTER SET utf8mb4
COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1'
IDENTIFIED BY '${DB_PASSWORD}';

ALTER USER '${DB_USER}'@'127.0.0.1'
IDENTIFIED BY '${DB_PASSWORD}';

GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.*
TO '${DB_USER}'@'127.0.0.1';

FLUSH PRIVILEGES;
SQL

# ------------------------------------------------------------
# Pterodactyl
# ------------------------------------------------------------

if [[ ! -d "${PTERODACTYL_DIR}" ]]; then

    log "Downloading Pterodactyl Panel..."

    mkdir -p "${PTERODACTYL_DIR}"

    cd "${PTERODACTYL_DIR}"

    # Official Pterodactyl panel repository.
    git clone https://github.com/pterodactyl/panel.git .

else

    warn "Pterodactyl directory already exists."
fi

cd "${PTERODACTYL_DIR}"

# ------------------------------------------------------------
# Composer dependencies
# ------------------------------------------------------------

if [[ -f composer.json ]]; then

    log "Installing Pterodactyl Composer dependencies..."

    COMPOSER_ALLOW_SUPERUSER=1 composer install \
        --no-dev \
        --optimize-autoloader \
        --no-interaction

else

    die "Pterodactyl composer.json was not found."
fi

# ------------------------------------------------------------
# Environment
# ------------------------------------------------------------

if [[ ! -f .env ]]; then

    if [[ -f .env.example ]]; then
        cp .env.example .env
    else
        die "Pterodactyl .env.example not found."
    fi

fi

php artisan key:generate --force

php artisan p:environment:setup \
    --author="${ADMIN_EMAIL}" \
    --url="https://${PTERO_DOMAIN}" \
    --timezone="UTC" \
    --cache="redis" \
    --session="redis" \
    --queue="redis" \
    --settings-ui=true

php artisan p:environment:database \
    --host="127.0.0.1" \
    --port="3306" \
    --database="${DB_NAME}" \
    --username="${DB_USER}" \
    --password="${DB_PASSWORD}"

# ------------------------------------------------------------
# Database migration
# ------------------------------------------------------------

log "Migrating Pterodactyl database..."

php artisan migrate --seed --force

# ------------------------------------------------------------
# Pterodactyl permissions
# ------------------------------------------------------------

chown -R www-data:www-data "${PTERODACTYL_DIR}"

chmod -R 755 "${PTERODACTYL_DIR}"

chmod -R 775 \
    "${PTERODACTYL_DIR}/storage" \
    "${PTERODACTYL_DIR}/bootstrap/cache"

# ------------------------------------------------------------
# Pterodactyl admin
# ------------------------------------------------------------

log "Creating Pterodactyl administrator..."

php artisan p:user:make \
    --email="${ADMIN_EMAIL}" \
    --username="admin" \
    --name-first="Admin" \
    --name-last="User" \
    --password="${PTERO_ADMIN_PASSWORD}" \
    --admin=1 \
    || warn "Admin may already exist."

# ------------------------------------------------------------
# Pterodactyl Nginx
# ------------------------------------------------------------

log "Configuring Pterodactyl Nginx..."

rm -f /etc/nginx/sites-enabled/default

cat > /etc/nginx/sites-available/pterodactyl.conf <<EOF
server {
    listen 80;
    server_name ${PTERO_DOMAIN};

    root ${PTERODACTYL_DIR}/public;
    index index.php;

    client_max_body_size 100m;

    access_log /var/log/nginx/pterodactyl.access.log;
    error_log /var/log/nginx/pterodactyl.error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;

        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;

        fastcgi_index index.php;

        include fastcgi_params;

        fastcgi_param PHP_VALUE "upload_max_filesize=100M
post_max_size=100M";

        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;

        fastcgi_param HTTP_PROXY "";

        fastcgi_intercept_errors off;

        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;

        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

ln -sf \
    /etc/nginx/sites-available/pterodactyl.conf \
    /etc/nginx/sites-enabled/pterodactyl.conf

nginx -t

systemctl reload nginx

# ------------------------------------------------------------
# Pterodactyl queue
# ------------------------------------------------------------

log "Creating Pterodactyl queue worker..."

cat > /etc/systemd/system/pteroq.service <<EOF
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service
Wants=redis-server.service

[Service]
User=www-data
Group=www-data
Restart=always
RestartSec=5

WorkingDirectory=${PTERODACTYL_DIR}

ExecStart=/usr/bin/php ${PTERODACTYL_DIR}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now pteroq.service

# ------------------------------------------------------------
# Pterodactyl cron
# ------------------------------------------------------------

cat > /etc/cron.d/pterodactyl <<EOF
* * * * * www-data php ${PTERODACTYL_DIR}/artisan schedule:run >> /dev/null 2>&1
EOF

chmod 644 /etc/cron.d/pterodactyl

# ------------------------------------------------------------
# MythicalDash
# ------------------------------------------------------------

echo
warn "MythicalDash upstream currently marks v3-remastered as beta/development."
warn "The current branch explicitly says not to install it for production."
echo

if ! yes_no "Attempt stable MythicalDash release installation?" "Y"; then
    warn "Skipping MythicalDash."
else

    if [[ -d "${MYTHICAL_DIR}/.git" ]]; then
        warn "Existing MythicalDash repository detected."
    else

        log "Cloning MythicalDash..."

        mkdir -p "${MYTHICAL_DIR}"

        cd /var/www

        git clone \
            --depth 1 \
            --branch v3-remastered \
            https://github.com/MythicalLTD/MythicalDash.git \
            mythicaldash

        warn "The upstream repository currently marks this branch as beta/development."
        warn "It has NOT been silently treated as production-ready."
    fi

    cd "${MYTHICAL_DIR}"

    if [[ -f composer.json ]]; then

        log "Installing MythicalDash PHP dependencies..."

        COMPOSER_ALLOW_SUPERUSER=1 composer install \
            --no-dev \
            --optimize-autoloader \
            --no-interaction

    fi

    if [[ -f package.json ]]; then

        if command -v npm >/dev/null 2>&1; then

            log "Installing frontend dependencies..."

            npm install

            if npm run build >/dev/null 2>&1; then
                log "MythicalDash frontend build completed."
            else
                warn "MythicalDash npm build command failed or is not defined."
            fi

        else
            warn "npm is not installed; frontend build was skipped."
        fi

    fi

    if [[ -f .env.example && ! -f .env ]]; then
        cp .env.example .env
    fi

    if [[ -f .env ]]; then

        sed -i \
            "s|^APP_URL=.*|APP_URL=https://${DASH_DOMAIN}|" \
            .env || true

    fi

    if [[ -f artisan ]]; then

        php artisan key:generate --force || true

        php artisan migrate --force || true

        php artisan storage:link || true

    fi

    chown -R www-data:www-data "${MYTHICAL_DIR}"

    chmod -R 755 "${MYTHICAL_DIR}"

    if [[ -d "${MYTHICAL_DIR}/storage" ]]; then
        chmod -R 775 "${MYTHICAL_DIR}/storage"
    fi

    if [[ -d "${MYTHICAL_DIR}/bootstrap/cache" ]]; then
        chmod -R 775 "${MYTHICAL_DIR}/bootstrap/cache"
    fi

fi

# ------------------------------------------------------------
# MythicalDash Nginx
# ------------------------------------------------------------

if [[ -d "${MYTHICAL_DIR}/public" ]]; then

    log "Configuring MythicalDash Nginx..."

    cat > /etc/nginx/sites-available/mythicaldash.conf <<EOF
server {
    listen 80;
    server_name ${DASH_DOMAIN};

    root ${MYTHICAL_DIR}/public;
    index index.php;

    client_max_body_size 100m;

    access_log /var/log/nginx/mythicaldash.access.log;
    error_log /var/log/nginx/mythicaldash.error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;

        fastcgi_pass unix:/run/php/php${PHP_VERSION}-fpm.sock;

        fastcgi_index index.php;

        include fastcgi_params;

        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;

        fastcgi_param HTTP_PROXY "";

        fastcgi_intercept_errors off;

        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;

        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    ln -sf \
        /etc/nginx/sites-available/mythicaldash.conf \
        /etc/nginx/sites-enabled/mythicaldash.conf

    nginx -t

    systemctl reload nginx

fi

# ------------------------------------------------------------
# Firewall
# ------------------------------------------------------------

if command -v ufw >/dev/null 2>&1; then

    if systemctl is-active --quiet ufw; then

        log "Opening required firewall ports..."

        ufw allow 22/tcp
        ufw allow 80/tcp
        ufw allow 443/tcp

    fi
fi

# ------------------------------------------------------------
# SSL
# ------------------------------------------------------------

if [[ "${ENABLE_SSL}" == "yes" ]]; then

    if [[ "${PTERO_DOMAIN}" != "${DASH_DOMAIN}" ]]; then

        log "Requesting SSL for Pterodactyl..."

        certbot --nginx \
            -d "${PTERO_DOMAIN}" \
            --non-interactive \
            --agree-tos \
            -m "${ADMIN_EMAIL}" \
            --redirect || warn "Pterodactyl SSL could not be issued automatically."

        if [[ -d "${MYTHICAL_DIR}/public" ]]; then

            log "Requesting SSL for MythicalDash..."

            certbot --nginx \
                -d "${DASH_DOMAIN}" \
                --non-interactive \
                --agree-tos \
                -m "${ADMIN_EMAIL}" \
                --redirect || warn "MythicalDash SSL could not be issued automatically."

        fi

    else

        warn "Pterodactyl and MythicalDash cannot use the same domain."
        warn "Use two subdomains, for example:"
        echo "  panel.example.com"
        echo "  dashboard.example.com"

    fi

fi

# ------------------------------------------------------------
# Final service restart
# ------------------------------------------------------------

log "Restarting services..."

systemctl restart nginx
systemctl restart redis-server
systemctl restart mariadb
systemctl restart pteroq

# ------------------------------------------------------------
# API instructions
# ------------------------------------------------------------

echo
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo -e "${WHITE} PTERODACTYL API CONNECTION                         ${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════${NC}"
echo
echo "MythicalDash needs access to your Pterodactyl API."
echo
echo "Create an Application API key in:"
echo
echo "  Pterodactyl Admin Panel"
echo "  → Application API"
echo
echo "Then configure that key in MythicalDash."
echo

# ------------------------------------------------------------
# Credentials file
# ------------------------------------------------------------

CREDENTIAL_FILE="${ENV_DIR}/credentials.txt"

cat > "${CREDENTIAL_FILE}" <<EOF
============================================================
MYTHICALDASH + PTERODACTYL INSTALLATION
============================================================

Pterodactyl URL:
https://${PTERO_DOMAIN}

MythicalDash URL:
https://${DASH_DOMAIN}

Admin Email:
${ADMIN_EMAIL}

Pterodactyl Admin Username:
admin

Pterodactyl Admin Password:
${PTERO_ADMIN_PASSWORD}

Database:
${DB_NAME}

Database User:
${DB_USER}

Database Password:
${DB_PASSWORD}

Installer Config:
${CONFIG_FILE}

============================================================
IMPORTANT
============================================================

Store this file securely.

Do not publish it.
Do not commit it to Git.
Do not send it publicly.

============================================================
EOF

chmod 600 "${CREDENTIAL_FILE}"

# ------------------------------------------------------------
# Health checks
# ------------------------------------------------------------

echo
log "Running health checks..."

echo

if systemctl is-active --quiet nginx; then
    echo -e "${GREEN}[OK]${NC} Nginx"
else
    echo -e "${RED}[FAIL]${NC} Nginx"
fi

if systemctl is-active --quiet mariadb; then
    echo -e "${GREEN}[OK]${NC} MariaDB"
else
    echo -e "${RED}[FAIL]${NC} MariaDB"
fi

if systemctl is-active --quiet redis-server; then
    echo -e "${GREEN}[OK]${NC} Redis"
else
    echo -e "${RED}[FAIL]${NC} Redis"
fi

if systemctl is-active --quiet pteroq; then
    echo -e "${GREEN}[OK]${NC} Pterodactyl Queue"
else
    echo -e "${RED}[FAIL]${NC} Pterodactyl Queue"
fi

if command -v docker >/dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} Docker"
else
    echo -e "${RED}[FAIL]${NC} Docker"
fi

# ------------------------------------------------------------
# Final output
# ------------------------------------------------------------

echo
echo -e "${CYAN}"
cat <<'DONE'
╔══════════════════════════════════════════════════════════╗
║                                                          ║
║                  INSTALLATION DONE                      ║
║                                                          ║
╚══════════════════════════════════════════════════════════╝
DONE
echo -e "${NC}"

echo
echo -e "${WHITE}Pterodactyl:${NC}"
echo "  https://${PTERO_DOMAIN}"

echo
echo -e "${WHITE}MythicalDash:${NC}"
echo "  https://${DASH_DOMAIN}"

echo
echo -e "${WHITE}Credentials:${NC}"
echo "  ${CREDENTIAL_FILE}"

echo
echo -e "${YELLOW}IMPORTANT:${NC}"
echo "1. Make sure both DNS records point to this VPS."
echo "2. Create a Pterodactyl Application API key."
echo "3. Enter that API key in MythicalDash."
echo "4. Configure Wings on your node(s)."
echo "5. Do not expose MariaDB or Redis publicly."
echo

echo -e "${GREEN}Made By Heron${NC}"
echo
