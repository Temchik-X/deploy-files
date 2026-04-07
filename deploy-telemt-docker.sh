#!/bin/bash
# =============================================================================
# deploy-telemt-docker.sh — Развёртывание MTProto прокси в Docker
# Схема: Клиент → HTTPS:443 (Nginx) → HTTP → Telemt (secure MTProto)
# ОС: Debian 11/12
# Использование: sudo bash deploy-telemt-docker.sh
# =============================================================================

set -euo pipefail

# ─── НАСТРОЙКИ — ЗАПОЛНИ ПЕРЕД ЗАПУСКОМ ─────────────────────────────────────
DOMAIN="your.domain.com"   # домен
EMAIL="your@email.com"         # email для Let's Encrypt
TELEMT_PORT=9000                      # внутренний порт Telemt внутри Docker-сети
API_TOKEN=""                          # токен API (пустым — сгенерируется)
DEPLOY_DIR="/opt/telemt"              # папка для docker-compose и конфигов
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
sep()  { echo -e "${BOLD}────────────────────────────────────────${NC}"; }

# ─── ПРОВЕРКИ ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Запусти от root: sudo bash deploy-telemt-docker.sh"
[[ "$DOMAIN" == "your.domain.com" ]] && warn "Используется домен по умолчанию: $DOMAIN"
[[ "$EMAIL" == "your@email.com" ]] && warn "Используется email по умолчанию: $EMAIL"

sep
log "Развёртывание Telemt (Docker): $DOMAIN"
sep

# ─── 1. ЗАВИСИМОСТИ ──────────────────────────────────────────────────────────
log "Установка зависимостей..."
apt-get update -qq
apt-get install -y -qq curl wget jq net-tools certbot

# ─── 2. DOCKER ───────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log "Установка Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable docker
    systemctl start docker
else
    log "Docker уже установлен: $(docker --version)"
fi

if ! docker compose version &>/dev/null 2>&1; then
    log "Установка Docker Compose plugin..."
    apt-get install -y -qq docker-compose-plugin
fi
log "Docker Compose: $(docker compose version)"

# ─── 3. СЕРТИФИКАТЫ ──────────────────────────────────────────────────────────
sep
log "Проверка SSL-сертификатов..."

CERT_SRC_DIR="/root/cert/${DOMAIN}"
CERT_DEST_DIR="${DEPLOY_DIR}/certs"

# Проверяем существующие сертификаты в /root/cert/DOMAIN/
if [[ -f "${CERT_SRC_DIR}/fullchain.pem" && -f "${CERT_SRC_DIR}/privkey.pem" ]]; then
    log "Найдены сертификаты в ${CERT_SRC_DIR} — используем их"
    mkdir -p "$CERT_DEST_DIR"
    cp "${CERT_SRC_DIR}/fullchain.pem" "${CERT_DEST_DIR}/fullchain.pem"
    cp "${CERT_SRC_DIR}/privkey.pem"   "${CERT_DEST_DIR}/privkey.pem"
    chmod 644 "${CERT_DEST_DIR}/fullchain.pem"
    chmod 600 "${CERT_DEST_DIR}/privkey.pem"
    log "Сертификаты скопированы в ${CERT_DEST_DIR}"

# Проверяем Let's Encrypt (стандартный путь certbot)
elif [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    log "Найдены сертификаты Let's Encrypt в /etc/letsencrypt/live/${DOMAIN}/"
    mkdir -p "$CERT_DEST_DIR"
    cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${CERT_DEST_DIR}/fullchain.pem"
    cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"   "${CERT_DEST_DIR}/privkey.pem"
    chmod 644 "${CERT_DEST_DIR}/fullchain.pem"
    chmod 600 "${CERT_DEST_DIR}/privkey.pem"
    log "Сертификаты скопированы в ${CERT_DEST_DIR}"

# Сертификатов нет — получаем через certbot
else
    warn "Сертификаты не найдены. Получаем через Let's Encrypt certbot..."

    # Проверяем порт 80
    if ss -tlnp | grep -q ':80 '; then
        PORT80_PROC=$(ss -tlnp | grep ':80 ' | grep -oP 'users:\(\("\K[^"]+' | head -1 || echo "unknown")
        warn "Порт 80 занят процессом: ${PORT80_PROC}"

        # Пробуем webroot если Nginx уже запущен
        if systemctl is-active --quiet nginx 2>/dev/null; then
            log "Nginx активен — используем webroot режим certbot"
            mkdir -p /var/lib/letsencrypt/.well-known
            certbot certonly \
                --webroot \
                --webroot-path /var/lib/letsencrypt \
                --non-interactive \
                --agree-tos \
                --email "$EMAIL" \
                -d "$DOMAIN"
        else
            err "Порт 80 занят (${PORT80_PROC}), но Nginx не запущен. Освободи порт 80 или положи сертификаты в ${CERT_SRC_DIR}/"
        fi
    else
        log "Порт 80 свободен — запускаем certbot standalone"
        certbot certonly \
            --standalone \
            --non-interactive \
            --agree-tos \
            --email "$EMAIL" \
            -d "$DOMAIN" \
            --preferred-challenges http
    fi

    # Копируем полученные сертификаты
    if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
        mkdir -p "$CERT_DEST_DIR"
        cp "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "${CERT_DEST_DIR}/fullchain.pem"
        cp "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"   "${CERT_DEST_DIR}/privkey.pem"
        chmod 644 "${CERT_DEST_DIR}/fullchain.pem"
        chmod 600 "${CERT_DEST_DIR}/privkey.pem"
        log "Сертификаты получены и скопированы в ${CERT_DEST_DIR}"
    else
        err "Не удалось получить сертификат для ${DOMAIN}. Проверь DNS A-запись."
    fi
fi

# Финальная проверка
[[ -f "${CERT_DEST_DIR}/fullchain.pem" ]] || err "fullchain.pem не найден в ${CERT_DEST_DIR}"
[[ -f "${CERT_DEST_DIR}/privkey.pem"   ]] || err "privkey.pem не найден в ${CERT_DEST_DIR}"
log "Сертификаты готовы"

# ─── 4. ГЕНЕРАЦИЯ СЕКРЕТОВ ───────────────────────────────────────────────────
sep
log "Генерация секретов..."
USER_SECRET=$(openssl rand -hex 16)
[[ -z "$API_TOKEN" ]] && API_TOKEN=$(openssl rand -hex 32)

# ─── 5. СТРУКТУРА ФАЙЛОВ ─────────────────────────────────────────────────────
log "Создание структуры ${DEPLOY_DIR}..."
mkdir -p "${DEPLOY_DIR}/telemt"
mkdir -p "${DEPLOY_DIR}/nginx"

# ─── 6. КОНФИГ TELEMT ────────────────────────────────────────────────────────
log "Создание telemt.toml..."
cat > "${DEPLOY_DIR}/telemt/telemt.toml" <<EOF
# =============================================================================
# Telemt — classic MTProto (без TLS, без префиксов)
# Nginx stream делает TLS-терминацию, Telemt получает чистый MTProto
# =============================================================================

[general]
use_middle_proxy = false

[general.modes]
classic = true
secure  = false
tls     = false

# Публичный адрес для генерации tg:// ссылок
[general.links]
public_host = "${DOMAIN}"
public_port = 443

[server]
port             = ${TELEMT_PORT}
listen_addr_ipv4 = "0.0.0.0"   # внутри Docker-сети — слушаем на всех интерфейсах

[server.api]
enabled    = true
listen     = "0.0.0.0:9091"
whitelist  = ["127.0.0.0/8", "172.16.0.0/12", "10.0.0.0/8"]  # Docker подсети
auth_header = "Bearer ${API_TOKEN}"
read_only  = false

[censorship]
mask = false

[access.users]
default = "${USER_SECRET}"
EOF

# ─── 7. КОНФИГ NGINX ─────────────────────────────────────────────────────────
log "Создание nginx.conf..."
cat > "${DEPLOY_DIR}/nginx/nginx.conf" <<EOF
user  nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid       /var/run/nginx.pid;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

# Stream-модуль для MTProto (TLS-терминация)
stream {
    # MTProto прокси на порту 443
    server {
        listen 443 ssl;
        
        ssl_certificate     /etc/nginx/certs/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/privkey.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;
        ssl_session_cache   shared:SSL:10m;
        ssl_session_timeout 10m;

        proxy_pass          telemt:${TELEMT_PORT};
        proxy_timeout       5m;
        proxy_connect_timeout 5s;
    }
}

# HTTP-модуль для API
http {
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log   /var/log/nginx/access.log;

    # HTTPS API — порт 9443 → telemt:9091
    server {
        listen 9443 ssl;
        server_name ${DOMAIN};

        ssl_certificate     /etc/nginx/certs/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/privkey.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers off;
        ssl_session_cache   shared:SSL:10m;
        ssl_session_timeout 10m;

        # Только /v1/ — блокируем всё остальное
        location /v1/ {
            proxy_pass http://telemt:9091;

            proxy_http_version 1.1;
            proxy_set_header Host              \$host;
            proxy_set_header X-Real-IP         \$remote_addr;
            proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto https;

            proxy_read_timeout    30s;
            proxy_connect_timeout 5s;

            # Authorization пробрасывается как есть — Telemt проверяет Bearer
        }

        location / {
            return 404;
        }
    }
}
EOF

# ─── 8. DOCKER COMPOSE ───────────────────────────────────────────────────────
log "Создание docker-compose.yml..."
cat > "${DEPLOY_DIR}/docker-compose.yml" <<EOF
services:

  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt
    restart: unless-stopped
    volumes:
      - ./telemt/telemt.toml:/app/config.toml:ro
    networks:
      # порт 9091 не пробрасывается наружу — nginx ходит к нему внутри docker-сети
      - proxy-net
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE

  nginx:
    image: nginx:stable-alpine
    container_name: nginx-telemt
    restart: unless-stopped
    depends_on:
      - telemt
    ports:
      - "443:443"
      - "9443:9443"    # HTTPS API
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./certs:/etc/nginx/certs:ro
    networks:
      - proxy-net

networks:
  proxy-net:
    driver: bridge
EOF

# ─── 9. ЗАПУСК ───────────────────────────────────────────────────────────────
sep
log "Запуск контейнеров..."
cd "${DEPLOY_DIR}"

docker compose pull
docker compose up -d

sleep 5

# Проверяем статус
TELEMT_STATUS=$(docker compose ps --format json telemt 2>/dev/null | jq -r '.[0].State // .State' 2>/dev/null || echo "unknown")
NGINX_STATUS=$(docker compose ps --format json nginx-telemt 2>/dev/null | jq -r '.[0].State // .State' 2>/dev/null || echo "unknown")

log "Telemt: $TELEMT_STATUS"
log "Nginx:  $NGINX_STATUS"

# ─── 10. АВТООБНОВЛЕНИЕ СЕРТИФИКАТОВ ─────────────────────────────────────────
log "Настройка автообновления сертификатов..."
cat > /etc/cron.d/telemt-cert-renew <<CRONEOF
# Обновление Let's Encrypt и копирование в ${CERT_DEST_DIR}
0 3 * * * root certbot renew --quiet && \
  cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ${CERT_DEST_DIR}/fullchain.pem && \
  cp /etc/letsencrypt/live/${DOMAIN}/privkey.pem   ${CERT_DEST_DIR}/privkey.pem && \
  docker compose -f ${DEPLOY_DIR}/docker-compose.yml restart nginx-telemt
CRONEOF

# ─── 11. ПОЛУЧЕНИЕ ССЫЛКИ ЧЕРЕЗ API ──────────────────────────────────────────
log "Получение прокси-ссылки через Telemt API..."
sleep 3
PROXY_LINK=$(curl -sk \
    -H "Authorization: Bearer ${API_TOKEN}" \
    https://127.0.0.1:9443/v1/users \
    | jq -r '.data[] | select(.username == "default") | .links[0]' 2>/dev/null || echo "")

# ─── 12. СОХРАНЕНИЕ ДАННЫХ ───────────────────────────────────────────────────
cat > /root/telemt-docker-info.txt <<EOF
# Telemt Docker — данные развёртывания
# $(date)

DOMAIN=${DOMAIN}
PORT=443
DEPLOY_DIR=${DEPLOY_DIR}

API_URL=https://${DOMAIN}:9443
API_TOKEN=${API_TOKEN}
DEFAULT_SECRET=${USER_SECRET}
PROXY_LINK=${PROXY_LINK}

# Управление:
#   cd ${DEPLOY_DIR}
#   docker compose ps
#   docker compose logs -f telemt
#   docker compose logs -f nginx-telemt
#   docker compose restart
#   docker compose down

# Создать пользователя через API (HTTPS снаружи):
#   curl -s -X POST https://${DOMAIN}:9443/v1/users \\
#     -H "Authorization: Bearer ${API_TOKEN}" \\
#     -H "Content-Type: application/json" \\
#     -d '{"username": "user1"}' | jq

# Удалить пользователя:
#   curl -s -X DELETE https://${DOMAIN}:9443/v1/users/user1 \\
#     -H "Authorization: Bearer ${API_TOKEN}" | jq

# Список всех пользователей со ссылками:
#   curl -s https://${DOMAIN}:9443/v1/users \\
#     -H "Authorization: Bearer ${API_TOKEN}" | jq
EOF
chmod 600 /root/telemt-docker-info.txt

# ─── ИТОГ ────────────────────────────────────────────────────────────────────
echo ""
sep
echo -e "${GREEN}${BOLD}  РАЗВЁРТЫВАНИЕ ЗАВЕРШЕНО${NC}"
sep
echo ""
echo -e "  ${BOLD}Прокси:${NC}      ${DOMAIN}:443"
echo -e "  ${BOLD}Deploy dir:${NC}  ${DEPLOY_DIR}"
echo -e "  ${BOLD}API URL:${NC}     https://${DOMAIN}:9443/v1/"
echo -e "  ${BOLD}API токен:${NC}   ${API_TOKEN}"
echo ""
if [[ -n "$PROXY_LINK" ]]; then
    echo -e "  ${BOLD}Ссылка для Telegram:${NC}"
    echo -e "  ${GREEN}${PROXY_LINK}${NC}"
else
    echo -e "  ${YELLOW}Получи ссылку вручную:${NC}"
    echo -e "  curl -s -H \"Authorization: Bearer ${API_TOKEN}\" https://${DOMAIN}:9443/v1/users | jq"
fi
echo ""
echo -e "  ${BOLD}Управление контейнерами:${NC}"
echo -e "  cd ${DEPLOY_DIR} && docker compose ps"
echo -e "  docker compose logs -f telemt"
echo ""
echo -e "  ${BOLD}Данные сохранены:${NC} /root/telemt-docker-info.txt"
sep
