#!/bin/bash
# =============================================================================
# deploy-telemt.sh — Развёртывание MTProto прокси
# Схема: Клиент → HTTPS:443 (Nginx, реальный сертификат) → HTTP → Telemt (secure MTProto)
# ОС: Debian 11/12
# Использование: sudo bash deploy-telemt.sh
# =============================================================================

set -euo pipefail

# ─── НАСТРОЙКИ — ЗАПОЛНИ ПЕРЕД ЗАПУСКОМ ─────────────────────────────────────
DOMAIN="your.domain.com"   # домен (A-запись должна указывать на этот сервер)
EMAIL="your@email.com"         # email для Let's Encrypt уведомлений
TELEMT_PORT=9000                      # внутренний порт Telemt (не публичный)
API_TOKEN=""                          # токен для API (оставь пустым — сгенерируется)
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
sep()  { echo -e "${BOLD}────────────────────────────────────────${NC}"; }

# ─── ПРОВЕРКИ ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Запусти от root: sudo bash deploy-telemt.sh"
[[ "$DOMAIN" == "proxy.example.com" ]] && err "Укажи свой домен в переменной DOMAIN"
[[ "$EMAIL" == "admin@example.com" ]]  && err "Укажи свой email в переменной EMAIL"

sep
log "Начало развёртывания Telemt + Nginx TLS на $DOMAIN"
sep

# ─── 1. ОБНОВЛЕНИЕ СИСТЕМЫ ───────────────────────────────────────────────────
log "Обновление системы..."
apt-get update -qq
apt-get install -y -qq curl wget jq certbot net-tools

# ─── 2. NGINX С STREAM-МОДУЛЕМ ───────────────────────────────────────────────
log "Установка Nginx..."
apt-get install -y -qq nginx libnginx-mod-stream
nginx -V 2>&1 | grep -q "stream" || err "Nginx stream-модуль не найден"


# ─── 3. УСТАНОВКА TELEMT ─────────────────────────────────────────────────────
log "Загрузка Telemt (официальный бинарник)..."

LIBC=$(ldd --version 2>&1 | grep -iq musl && echo musl || echo gnu)
ARCH=$(uname -m)
TELEMT_URL="https://github.com/telemt/telemt/releases/latest/download/telemt-${ARCH}-linux-${LIBC}.tar.gz"

log "Архитектура: $ARCH, libc: $LIBC"
wget -qO- "$TELEMT_URL" | tar -xz -C /tmp
mv /tmp/telemt /bin/telemt
chmod +x /bin/telemt

TELEMT_VER=$(/bin/telemt --version 2>/dev/null | head -1 || echo "unknown")
log "Telemt установлен: $TELEMT_VER"

# ─── 4. ПОЛЬЗОВАТЕЛЬ TELEMT ──────────────────────────────────────────────────
log "Создание системного пользователя telemt..."
id telemt &>/dev/null || useradd -d /opt/telemt -m -r -U telemt

# ─── 5. ГЕНЕРАЦИЯ СЕКРЕТА И API-ТОКЕНА ───────────────────────────────────────
log "Генерация секретов..."
USER_SECRET=$(openssl rand -hex 16)

if [[ -z "$API_TOKEN" ]]; then
    API_TOKEN=$(openssl rand -hex 32)
fi

log "Секрет пользователя: $USER_SECRET"
log "API токен сгенерирован"

# ─── 6. КОНФИГ TELEMT ────────────────────────────────────────────────────────
log "Создание конфига Telemt..."
mkdir -p /etc/telemt

cat > /etc/telemt/telemt.toml <<EOF
# =============================================================================
# Telemt — secure MTProto (без TLS, без HTTP)
# Схема: Клиент → HTTPS Nginx:443 → HTTP proxy_pass → Telemt:${TELEMT_PORT}
# Nginx делает TLS-маску, Telemt получает raw MTProto через proxy_pass
# =============================================================================

[general]
use_middle_proxy = false

# Режим: secure (obfuscated MTProto, без TLS — TLS делает Nginx)
[general.modes]
classic = false
secure  = true
tls     = false

# Публичный адрес для генерации tg:// ссылок через API
[general.links]
public_host = "${DOMAIN}"
public_port = 443

[server]
port             = ${TELEMT_PORT}
listen_addr_ipv4 = "127.0.0.1"   # только локально, Nginx проксирует

# REST API для управления пользователями
[server.api]
enabled    = true
listen     = "127.0.0.1:9091"
whitelist  = ["127.0.0.1/32"]
auth_header = "Bearer ${API_TOKEN}"
read_only  = false

[censorship]
mask = false   # маскировка не нужна — Nginx уже делает TLS-маску

[access.users]
# Первый пользователь (по умолчанию)
default = "${USER_SECRET}"
EOF

chown -R telemt:telemt /etc/telemt
chmod 600 /etc/telemt/telemt.toml
log "Конфиг записан: /etc/telemt/telemt.toml"

# ─── 7. SYSTEMD СЕРВИС TELEMT ────────────────────────────────────────────────
log "Создание systemd сервиса telemt..."

cat > /etc/systemd/system/telemt.service <<'EOF'
[Unit]
Description=Telemt MTProto Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=/opt/telemt
ExecStart=/bin/telemt /etc/telemt/telemt.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable telemt

# ─── 8. LET'S ENCRYPT СЕРТИФИКАТ ─────────────────────────────────────────────
log "Получение SSL-сертификата для $DOMAIN..."
systemctl stop nginx 2>/dev/null || true

certbot certonly \
    --standalone \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" \
    -d "$DOMAIN" \
    --preferred-challenges http

CERT_PATH="/etc/letsencrypt/live/$DOMAIN"
[[ -f "$CERT_PATH/fullchain.pem" ]] || err "Сертификат не получен. Проверь DNS A-запись для $DOMAIN"
log "Сертификат получён: $CERT_PATH"

# ─── 9. КОНФИГ NGINX ────────────────────────────────────────────────────────
log "Настройка Nginx (HTTPS → HTTP proxy_pass → Telemt)..."
rm -f /etc/nginx/sites-enabled/default

# Чистый nginx.conf — только http блок, без stream
cat > /etc/nginx/nginx.conf <<'NGINXEOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

http {
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log   /var/log/nginx/access.log;
    include /etc/nginx/sites-enabled/*;
}
NGINXEOF

# Сайт-заглушка: HTML на HTTP (для certbot и decoy)
mkdir -p /var/www/html
cat > /var/www/html/index.html <<'HTML'
<!DOCTYPE html>
<html><head><title>Welcome</title></head>
<body><h1>Welcome</h1></body>
</html>
HTML

# HTTP → редирект на HTTPS + certbot challenge
cat > /etc/nginx/sites-enabled/http <<EOF
server {
    listen 80 default_server;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/lib/letsencrypt;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

# HTTPS → proxy_pass к Telemt (HTTP блок, без stream)
cat > /etc/nginx/sites-enabled/https <<EOF
server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_PATH}/fullchain.pem;
    ssl_certificate_key ${CERT_PATH}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    location / {
        proxy_pass http://127.0.0.1:${TELEMT_PORT};

        proxy_http_version 1.1;

        # Отключаем буферизацию — данные идут потоком сразу
        proxy_request_buffering off;
        proxy_buffering         off;

        proxy_set_header Host       \$host;
        proxy_set_header Connection "";

        # Таймауты под долгие MTProto-сессии
        proxy_read_timeout    3600s;
        proxy_send_timeout    3600s;
        proxy_connect_timeout 5s;
    }
}
EOF

nginx -t || err "Конфиг Nginx содержит ошибки. Проверь: nginx -t"
systemctl enable nginx
systemctl restart nginx
log "Nginx запущен (HTTP блок, proxy_pass → Telemt:${TELEMT_PORT})"

# ─── 10. ЗАПУСК TELEMT ───────────────────────────────────────────────────────
log "Запуск Telemt..."
systemctl start telemt
sleep 3
systemctl is-active --quiet telemt || err "Telemt не запустился. Проверь: journalctl -u telemt -n 50"
log "Telemt запущен на 127.0.0.1:${TELEMT_PORT}"

# ─── 11. АВТООБНОВЛЕНИЕ СЕРТИФИКАТА ──────────────────────────────────────────
log "Настройка автообновления Let's Encrypt..."
cat > /etc/cron.d/certbot-renew <<'EOF'
0 3 * * * root certbot renew --quiet --post-hook "systemctl reload nginx"
EOF

# ─── 12. ПОЛУЧЕНИЕ ССЫЛКИ ЧЕРЕЗ API ──────────────────────────────────────────
log "Получение прокси-ссылки через Telemt API..."
sleep 2
PROXY_LINK=$(curl -s \
    -H "Authorization: Bearer ${API_TOKEN}" \
    http://127.0.0.1:9091/v1/users \
    | jq -r '.data[] | select(.username == "default") | .links[0]' 2>/dev/null || echo "")

# ─── 13. СОХРАНЕНИЕ ДАННЫХ ───────────────────────────────────────────────────
cat > /root/telemt-info.txt <<EOF
# Telemt MTProto Proxy — данные развёртывания
# $(date)

DOMAIN=${DOMAIN}
PORT=443
API_URL=http://127.0.0.1:9091
API_TOKEN=${API_TOKEN}
DEFAULT_SECRET=${USER_SECRET}
PROXY_LINK=${PROXY_LINK}

# Управление пользователями через API:
#
# Список пользователей:
#   curl -s -H "Authorization: Bearer ${API_TOKEN}" http://127.0.0.1:9091/v1/users | jq
#
# Создать пользователя:
#   curl -s -X POST http://127.0.0.1:9091/v1/users \\
#     -H "Authorization: Bearer ${API_TOKEN}" \\
#     -H "Content-Type: application/json" \\
#     -d '{"username": "user1"}' | jq
#
# Удалить пользователя:
#   curl -s -X DELETE http://127.0.0.1:9091/v1/users/user1 \\
#     -H "Authorization: Bearer ${API_TOKEN}" | jq
#
# Логи Telemt:  journalctl -u telemt -f
# Логи Nginx:   tail -f /var/log/nginx/stream-access.log
EOF
chmod 600 /root/telemt-info.txt

# ─── ИТОГ ────────────────────────────────────────────────────────────────────
echo ""
sep
echo -e "${GREEN}${BOLD}  РАЗВЁРТЫВАНИЕ ЗАВЕРШЕНО${NC}"
sep
echo ""
echo -e "  ${BOLD}Прокси:${NC}    ${DOMAIN}:443"
echo -e "  ${BOLD}API URL:${NC}   http://127.0.0.1:9091"
echo -e "  ${BOLD}API токен:${NC} ${API_TOKEN}"
echo ""
if [[ -n "$PROXY_LINK" ]]; then
    echo -e "  ${BOLD}Ссылка для Telegram:${NC}"
    echo -e "  ${GREEN}${PROXY_LINK}${NC}"
else
    echo -e "  ${YELLOW}Ссылку получи вручную:${NC}"
    echo -e "  curl -s -H \"Authorization: Bearer ${API_TOKEN}\" http://127.0.0.1:9091/v1/users | jq"
fi
echo ""
echo -e "  ${BOLD}Управление:${NC}"
echo -e "  systemctl status telemt"
echo -e "  journalctl -u telemt -f"
echo ""
echo -e "  ${BOLD}Данные сохранены:${NC} /root/telemt-info.txt"
sep
