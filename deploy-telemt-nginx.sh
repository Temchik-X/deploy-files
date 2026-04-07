#!/bin/bash
# =============================================================================
# deploy-telemt-nginx.sh — Telemt MTProto за Nginx TLS-фронтендом
#
# Архитектура:
#   :80  → Nginx HTTP → decoy-сайт
#   :443 → Nginx stream SSL (сертификат из /root/cert/DOMAIN/)
#              ↓ plain TCP
#         Telemt:9000 (MTProto secure, dd-секрет)
#
# DPI видит: реальный TLS-хендшейк от Nginx с реальным сертификатом.
#
# ОС: Debian 11/12
# Использование: sudo bash deploy-telemt-nginx.sh
# =============================================================================

set -euo pipefail

# ─── НАСТРОЙКИ ────────────────────────────────────────────────────────────────
DOMAIN="your.domain.com"       # домен
API_TOKEN=""                   # пусто → сгенерируется
DEPLOY_DIR="/opt/telemt-nginx"
TELEMT_PORT=9000
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
sep()  { echo -e "${BOLD}────────────────────────────────────────${NC}"; }

# ─── ПРОВЕРКИ ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Запусти от root"
[[ "$DOMAIN" == "your.domain.com" ]] && err "Заполни DOMAIN перед запуском"

CERT_SRC="/root/cert/${DOMAIN}"
[[ -f "${CERT_SRC}/fullchain.pem" ]] || err "Не найден ${CERT_SRC}/fullchain.pem"
[[ -f "${CERT_SRC}/privkey.pem"   ]] || err "Не найден ${CERT_SRC}/privkey.pem"

sep
log "Telemt + Nginx TLS frontend | ${DOMAIN}"
sep

# ─── 1. ЗАВИСИМОСТИ ──────────────────────────────────────────────────────────
log "Установка зависимостей..."
apt-get update -qq
apt-get install -y -qq curl jq

# ─── 2. DOCKER ───────────────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
    log "Установка Docker..."
    curl -fsSL https://get.docker.com | bash
    systemctl enable --now docker
else
    log "Docker: $(docker --version)"
fi

if ! docker compose version &>/dev/null 2>&1; then
    apt-get install -y -qq docker-compose-plugin
fi

# ─── 3. ПРОВЕРКА ПОРТОВ ──────────────────────────────────────────────────────
for PORT in 80 443; do
    if ss -tlnp | grep -q ":${PORT} "; then
        PROC=$(ss -tlnp | grep ":${PORT} " | grep -oP 'users:\(\("\K[^"]+' | head -1 || echo "unknown")
        err "Порт ${PORT} занят: ${PROC}"
    fi
done
log "Порты 80 и 443 свободны"

# ─── 4. ГЕНЕРАЦИЯ СЕКРЕТОВ ───────────────────────────────────────────────────
sep
# dd-префикс: secure MTProto. TLS делает Nginx, поэтому НЕ ee.
USER_SECRET="dd$(openssl rand -hex 16)"
[[ -z "$API_TOKEN" ]] && API_TOKEN=$(openssl rand -hex 32)
log "Секрет: ${USER_SECRET}"

# ─── 5. СТРУКТУРА ────────────────────────────────────────────────────────────
mkdir -p "${DEPLOY_DIR}"/{telemt,nginx/html,certs}
log "Рабочая папка: ${DEPLOY_DIR}"

# ─── 6. КОПИРОВАНИЕ СЕРТИФИКАТОВ ─────────────────────────────────────────────
log "Копирование сертификатов из ${CERT_SRC}..."
cp "${CERT_SRC}/fullchain.pem" "${DEPLOY_DIR}/certs/fullchain.pem"
cp "${CERT_SRC}/privkey.pem"   "${DEPLOY_DIR}/certs/privkey.pem"
chmod 644 "${DEPLOY_DIR}/certs/fullchain.pem"
chmod 600 "${DEPLOY_DIR}/certs/privkey.pem"

# ─── 7. КОНФИГ TELEMT ────────────────────────────────────────────────────────
log "Создание telemt/config.toml..."
cat > "${DEPLOY_DIR}/telemt/config.toml" <<EOF
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure  = true    # dd-секрет
tls     = false   # TLS делает Nginx, не telemt

[general.links]
show        = "*"
public_host = "${DOMAIN}"
public_port = 443

[server]
port = ${TELEMT_PORT}

[[server.listeners]]
ip = "0.0.0.0"

[server.api]
enabled     = true
listen      = "0.0.0.0:9091"
whitelist   = ["127.0.0.0/8", "172.16.0.0/12", "10.0.0.0/8"]
auth_header = "Bearer ${API_TOKEN}"

[censorship]
mask = false

[access.users]
default = "${USER_SECRET}"
EOF

# ─── 8. DECOY САЙТ ───────────────────────────────────────────────────────────
cat > "${DEPLOY_DIR}/nginx/html/index.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Добро пожаловать</title>
<style>
  body{font-family:sans-serif;background:#f5f5f5;display:flex;align-items:center;
       justify-content:center;height:100vh;margin:0}
  .box{background:#fff;padding:2rem 3rem;border-radius:8px;
       box-shadow:0 2px 8px rgba(0,0,0,.1);text-align:center}
  h1{color:#333;font-size:1.5rem}p{color:#666}
</style>
</head>
<body>
<div class="box">
  <h1>Сайт работает</h1>
  <p>Технические работы. Попробуйте позже.</p>
</div>
</body>
</html>
HTMLEOF

# ─── 9. КОНФИГ NGINX ─────────────────────────────────────────────────────────
log "Создание nginx/nginx.conf..."
cat > "${DEPLOY_DIR}/nginx/nginx.conf" <<EOF
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 4096;
    use epoll;
    multi_accept on;
}

# ── STREAM: порт 443 — TLS терминация → plain TCP → telemt ──────────────────
stream {
    upstream telemt_backend {
        server telemt:${TELEMT_PORT};
    }

    server {
        listen 443 ssl;

        ssl_certificate     /etc/nginx/certs/fullchain.pem;
        ssl_certificate_key /etc/nginx/certs/privkey.pem;
        ssl_protocols       TLSv1.2 TLSv1.3;
        ssl_ciphers         HIGH:!aNULL:!MD5;
        ssl_session_cache   shared:SSL:10m;
        ssl_session_timeout 10m;

        proxy_pass            telemt_backend;
        proxy_timeout         5m;
        proxy_connect_timeout 5s;
    }
}

# ── HTTP: порт 80 — decoy-сайт ───────────────────────────────────────────────
http {
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log   /var/log/nginx/access.log;

    server {
        listen 80;
        server_name ${DOMAIN};

        location / {
            root  /usr/share/nginx/html;
            index index.html;
        }
    }
}
EOF

# ─── 10. DOCKER COMPOSE ──────────────────────────────────────────────────────
log "Создание docker-compose.yml..."
cat > "${DEPLOY_DIR}/docker-compose.yml" <<EOF
services:

  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt
    restart: unless-stopped
    working_dir: /run/telemt
    expose:
      - "${TELEMT_PORT}"
    ports:
      - "127.0.0.1:9091:9091"
    volumes:
      - ./telemt/config.toml:/run/telemt/config.toml:ro
    tmpfs:
      - /run/telemt:rw,mode=1777,size=10m
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    security_opt:
      - no-new-privileges:true
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    networks:
      - proxy-net

  nginx:
    image: nginx:mainline
    container_name: nginx-telemt
    restart: unless-stopped
    depends_on:
      - telemt
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/html:/usr/share/nginx/html:ro
      - ./certs/fullchain.pem:/etc/nginx/certs/fullchain.pem:ro
      - ./certs/privkey.pem:/etc/nginx/certs/privkey.pem:ro
    networks:
      - proxy-net

networks:
  proxy-net:
    driver: bridge
EOF

# ─── 11. ЗАПУСК ──────────────────────────────────────────────────────────────
sep
log "Запуск контейнеров..."
cd "${DEPLOY_DIR}"
docker compose pull
docker compose up -d

sleep 6

for SVC in telemt nginx-telemt; do
    STATUS=$(docker inspect --format='{{.State.Status}}' "$SVC" 2>/dev/null || echo "not found")
    if [[ "$STATUS" == "running" ]]; then
        log "$SVC: running"
    else
        warn "$SVC: $STATUS"
        docker compose logs --tail=30 "$SVC" || true
    fi
done

# ─── 12. ПОЛУЧЕНИЕ ССЫЛКИ ────────────────────────────────────────────────────
sleep 3
log "Получение прокси-ссылки..."
PROXY_LINK=$(curl -s \
    -H "Authorization: Bearer ${API_TOKEN}" \
    http://127.0.0.1:9091/v1/users \
    | jq -r '.data[] | select(.username == "default") | .links[0]' 2>/dev/null || echo "")

# ─── 13. СОХРАНЕНИЕ ──────────────────────────────────────────────────────────
cat > /root/telemt-nginx-info.txt <<EOF
# Telemt + Nginx TLS frontend — $(date)
DOMAIN=${DOMAIN}
DEPLOY_DIR=${DEPLOY_DIR}
API_TOKEN=${API_TOKEN}
DEFAULT_SECRET=${USER_SECRET}
PROXY_LINK=${PROXY_LINK}

# Управление:
#   cd ${DEPLOY_DIR} && docker compose ps
#   docker compose logs -f telemt
#   docker compose logs -f nginx-telemt
#   docker compose restart

# После обновления сертификата — скопировать и перезагрузить nginx:
#   cp /root/cert/${DOMAIN}/fullchain.pem ${DEPLOY_DIR}/certs/fullchain.pem
#   cp /root/cert/${DOMAIN}/privkey.pem   ${DEPLOY_DIR}/certs/privkey.pem
#   docker exec nginx-telemt nginx -s reload

# Создать пользователя:
#   curl -s -X POST http://127.0.0.1:9091/v1/users \
#     -H "Authorization: Bearer ${API_TOKEN}" \
#     -H "Content-Type: application/json" \
#     -d '{"username":"user1"}' | jq

# Список пользователей:
#   curl -s -H "Authorization: Bearer ${API_TOKEN}" \
#     http://127.0.0.1:9091/v1/users | jq
EOF
chmod 600 /root/telemt-nginx-info.txt

# ─── ИТОГ ────────────────────────────────────────────────────────────────────
echo ""
sep
echo -e "${GREEN}${BOLD}  ГОТОВО${NC}"
sep
echo -e "  ${BOLD}Прокси:${NC}  ${DOMAIN}:443  (Nginx TLS → telemt)"
echo -e "  ${BOLD}Decoy:${NC}   http://${DOMAIN}:80"
echo -e "  ${BOLD}Секрет:${NC}  ${USER_SECRET}"
echo -e "  ${BOLD}API:${NC}     http://127.0.0.1:9091/v1/"
echo ""
if [[ -n "$PROXY_LINK" ]]; then
    echo -e "  ${BOLD}Ссылка для Telegram:${NC}"
    echo -e "  ${GREEN}${PROXY_LINK}${NC}"
else
    echo -e "  ${YELLOW}Получи ссылку:${NC}"
    echo -e "  curl -s -H \"Authorization: Bearer ${API_TOKEN}\" http://127.0.0.1:9091/v1/users | jq"
fi
echo ""
echo -e "  ${BOLD}Данные:${NC} /root/telemt-nginx-info.txt"
sep
