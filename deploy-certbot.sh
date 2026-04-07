#!/bin/bash
# =============================================================================
# deploy-certbot.sh — Получение и автообновление SSL через Nginx + Certbot (Docker)
#
# Схема:
#   certbot/certbot (standalone)  →  выдаёт сертификат
#   nginx:alpine                  →  перенаправляет /.well-known/ при обновлении
#   deploy-hook                   →  кладёт fullchain.pem / privkey.pem в /root/cert/DOMAIN/
#
# ОС: Debian 11/12
# Использование: sudo bash deploy-certbot.sh
# =============================================================================

set -euo pipefail

# ─── НАСТРОЙКИ — ЗАПОЛНИ ПЕРЕД ЗАПУСКОМ ─────────────────────────────────────
DOMAIN="your.domain.com"           # домен (A-запись должна указывать на этот сервер)
EMAIL="your@email.com"             # email для уведомлений Let's Encrypt
CERT_OUT_DIR="/root/cert/${DOMAIN}" # куда класть fullchain.pem / privkey.pem
DEPLOY_DIR="/opt/certbot-nginx"     # папка для docker-compose и конфигов
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
sep()  { echo -e "${BOLD}────────────────────────────────────────${NC}"; }

# ─── ПРОВЕРКИ ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]]                      && err "Запусти от root: sudo bash deploy-certbot.sh"
[[ "$DOMAIN" == "your.domain.com" ]]   && err "Заполни DOMAIN в начале скрипта"
[[ "$EMAIL"  == "your@email.com" ]]    && err "Заполни EMAIL в начале скрипта"

sep
log "SSL через Docker: ${DOMAIN}"
sep

# ─── 1. ЗАВИСИМОСТИ ──────────────────────────────────────────────────────────
log "Обновление пакетов..."
apt-get update -qq
apt-get install -y -qq curl

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

# ─── 3. ПРОВЕРКА ПОРТА 80 ────────────────────────────────────────────────────
sep
log "Проверка порта 80..."
if ss -tlnp 2>/dev/null | grep -q ':80 '; then
    PORT80_PROC=$(ss -tlnp | grep ':80 ' | grep -oP 'users:\(\("\K[^"]+' | head -1 || echo "unknown")
    err "Порт 80 занят процессом: ${PORT80_PROC}. Освободи его перед запуском."
fi
log "Порт 80 свободен"

# ─── 4. СТРУКТУРА ФАЙЛОВ ─────────────────────────────────────────────────────
log "Создание структуры ${DEPLOY_DIR}..."
mkdir -p "${DEPLOY_DIR}/nginx/conf.d"
mkdir -p "${DEPLOY_DIR}/webroot/.well-known/acme-challenge"
mkdir -p "${DEPLOY_DIR}/letsencrypt"
mkdir -p "${CERT_OUT_DIR}"

# ─── 5. КОНФИГ NGINX (только HTTP, для ACME challenge) ───────────────────────
log "Создание nginx.conf..."
cat > "${DEPLOY_DIR}/nginx/conf.d/acme.conf" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    # ACME challenge — certbot кладёт файлы в /var/www/certbot
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Всё остальное — заглушка (сертификат ещё не получен)
    location / {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
EOF

# ─── 6. DOCKER COMPOSE ───────────────────────────────────────────────────────
log "Создание docker-compose.yml..."
cat > "${DEPLOY_DIR}/docker-compose.yml" <<EOF
services:

  nginx:
    image: nginx:stable-alpine
    container_name: certbot-nginx
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./webroot:/var/www/certbot:ro
    networks:
      - certnet

  certbot:
    image: certbot/certbot:latest
    container_name: certbot
    volumes:
      - ./letsencrypt:/etc/letsencrypt
      - ./webroot:/var/www/certbot
    entrypoint: /bin/sh
    command: -c "trap exit TERM; while :; do certbot renew --webroot -w /var/www/certbot --quiet; sleep 12h & wait \$\${!}; done"
    networks:
      - certnet

networks:
  certnet:
    driver: bridge
EOF

# ─── 7. DEPLOY HOOK (копирует сертификаты в /root/cert/DOMAIN/) ──────────────
log "Создание deploy-hook..."
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/copy-to-root.sh <<HOOK
#!/bin/bash
# Автоматически вызывается certbot после успешного обновления сертификата
set -e
CERT_DIR="/etc/letsencrypt/live/${DOMAIN}"
OUT_DIR="${CERT_OUT_DIR}"

mkdir -p "\$OUT_DIR"
cp "\${CERT_DIR}/fullchain.pem" "\${OUT_DIR}/fullchain.pem"
cp "\${CERT_DIR}/privkey.pem"   "\${OUT_DIR}/privkey.pem"
chmod 644 "\${OUT_DIR}/fullchain.pem"
chmod 600 "\${OUT_DIR}/privkey.pem"

echo "[certbot hook] Сертификаты скопированы в \${OUT_DIR}"
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/copy-to-root.sh

# ─── 8. ЗАПУСК NGINX ─────────────────────────────────────────────────────────
sep
log "Запуск nginx..."
cd "${DEPLOY_DIR}"
docker compose pull nginx
docker compose up -d nginx
sleep 3

NGINX_STATUS=$(docker inspect --format='{{.State.Status}}' certbot-nginx 2>/dev/null || echo "unknown")
[[ "$NGINX_STATUS" != "running" ]] && err "nginx не запустился. Проверь: docker logs certbot-nginx"
log "nginx запущен: ${NGINX_STATUS}"

# ─── 9. ПЕРВИЧНЫЙ ВЫПУСК СЕРТИФИКАТА ─────────────────────────────────────────
sep
log "Запрос сертификата для ${DOMAIN}..."

# Certbot внутри compose-сети не может делать standalone, используем webroot
docker compose run --rm certbot certbot certonly \
    --webroot \
    --webroot-path /var/www/certbot \
    --non-interactive \
    --agree-tos \
    --email "${EMAIL}" \
    -d "${DOMAIN}"

log "Сертификат получен"

# ─── 10. КОПИРОВАНИЕ В /root/cert/DOMAIN/ ────────────────────────────────────
sep
log "Копирование сертификатов в ${CERT_OUT_DIR}..."
LE_DIR="${DEPLOY_DIR}/letsencrypt/live/${DOMAIN}"

if [[ ! -f "${LE_DIR}/fullchain.pem" ]]; then
    err "Не найден ${LE_DIR}/fullchain.pem после выпуска"
fi

cp "${LE_DIR}/fullchain.pem" "${CERT_OUT_DIR}/fullchain.pem"
cp "${LE_DIR}/privkey.pem"   "${CERT_OUT_DIR}/privkey.pem"
chmod 644 "${CERT_OUT_DIR}/fullchain.pem"
chmod 600 "${CERT_OUT_DIR}/privkey.pem"

log "fullchain.pem → ${CERT_OUT_DIR}/fullchain.pem"
log "privkey.pem   → ${CERT_OUT_DIR}/privkey.pem"

# ─── 11. ЗАПУСК CERTBOT АВТООБНОВЛЕНИЯ ───────────────────────────────────────
sep
log "Запуск certbot (фоновый режим автообновления каждые 12ч)..."
docker compose up -d certbot
sleep 3

CERTBOT_STATUS=$(docker inspect --format='{{.State.Status}}' certbot 2>/dev/null || echo "unknown")
log "certbot: ${CERTBOT_STATUS}"

# ─── 12. CRON ДЛЯ КОПИРОВАНИЯ ПОСЛЕ ОБНОВЛЕНИЯ ───────────────────────────────
log "Настройка cron для синхронизации сертификатов..."
cat > /etc/cron.d/certbot-copy <<CRONEOF
# Каждый день в 4:30 — копирует обновлённые сертификаты в /root/cert/${DOMAIN}/
# (certbot внутри Docker обновляет каждые 12ч, хук копирует автоматически)
30 4 * * * root \
  CERT="${DEPLOY_DIR}/letsencrypt/live/${DOMAIN}"; \
  OUT="${CERT_OUT_DIR}"; \
  [[ -f "\$CERT/fullchain.pem" ]] && \
  cp "\$CERT/fullchain.pem" "\$OUT/fullchain.pem" && \
  cp "\$CERT/privkey.pem"   "\$OUT/privkey.pem" && \
  chmod 644 "\$OUT/fullchain.pem" && \
  chmod 600 "\$OUT/privkey.pem" && \
  echo "\$(date): certs synced" >> /var/log/certbot-copy.log
CRONEOF

# ─── 13. ИТОГ ─────────────────────────────────────────────────────────────────
# Срок действия
EXPIRY=$(openssl x509 -enddate -noout -in "${CERT_OUT_DIR}/fullchain.pem" 2>/dev/null | cut -d= -f2 || echo "неизвестно")

echo ""
sep
echo -e "${GREEN}${BOLD}  SSL ГОТОВ${NC}"
sep
echo ""
echo -e "  ${BOLD}Домен:${NC}        ${DOMAIN}"
echo -e "  ${BOLD}Сертификат:${NC}   ${CERT_OUT_DIR}/fullchain.pem"
echo -e "  ${BOLD}Ключ:${NC}         ${CERT_OUT_DIR}/privkey.pem"
echo -e "  ${BOLD}Истекает:${NC}     ${EXPIRY}"
echo ""
echo -e "  ${BOLD}Автообновление:${NC}"
echo -e "  Certbot проверяет обновление каждые 12ч (docker container certbot)"
echo -e "  При обновлении файлы копируются в ${CERT_OUT_DIR}/"
echo ""
echo -e "  ${BOLD}Управление:${NC}"
echo -e "  cd ${DEPLOY_DIR}"
echo -e "  docker compose ps"
echo -e "  docker compose logs -f certbot"
echo -e "  docker compose exec certbot certbot certificates   # статус"
echo ""
echo -e "  ${BOLD}Принудительное обновление:${NC}"
echo -e "  docker compose exec certbot certbot renew --force-renewal"
sep
