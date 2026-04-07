#!/bin/bash
# =============================================================================
# deploy-amnezia-https.sh — HTTPS для amnezia-api через системный nginx
#
# Предусловия:
#   - amnezia-api установлен через setup.sh (nginx уже на хосте, API на :4001)
#   - Сертификаты получены через deploy-certbot.sh (или лежат в /root/cert/DOMAIN/)
#
# Результат:
#   https://DOMAIN:NGINX_PORT/   →  nginx (SSL) → 127.0.0.1:4001
#   Порт берётся из NGINX_PORT в .env репозитория amnezia-api
#
# ОС: Debian 11/12
# Использование: sudo bash deploy-amnezia-https.sh
# =============================================================================

set -euo pipefail

# ─── НАСТРОЙКИ — ЗАПОЛНИ ПЕРЕД ЗАПУСКОМ ─────────────────────────────────────
DOMAIN="your.domain.com"            # домен (A-запись → этот сервер)
AMNEZIA_DIR="/opt/amnezia-api"      # путь к репозиторию amnezia-api (где лежит .env)
API_PORT=4001                       # внутренний порт Fastify (не менять без причины)
CERT_DIR="/root/cert/${DOMAIN}"     # директория с fullchain.pem / privkey.pem
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
sep()  { echo -e "${BOLD}────────────────────────────────────────${NC}"; }

# ─── ПРОВЕРКИ ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]]                     && err "Запусти от root: sudo bash deploy-amnezia-https.sh"
[[ "$DOMAIN" == "your.domain.com" ]]  && err "Заполни DOMAIN в начале скрипта"

sep
log "HTTPS для amnezia-api: ${DOMAIN}"
sep

# ─── 1. ЧИТАЕМ NGINX_PORT ИЗ .env ─────────────────────────────────────────────
ENV_FILE="${AMNEZIA_DIR}/.env"
log "Чтение NGINX_PORT из ${ENV_FILE}..."

[[ -f "$ENV_FILE" ]] || err "Файл .env не найден: ${ENV_FILE}. Проверь AMNEZIA_DIR."

# Убираем пробелы вокруг = и значения
NGINX_PORT=$(grep -E '^NGINX_PORT' "$ENV_FILE" | head -1 | sed 's/.*=\s*//' | tr -d ' \r"'"'" || true)

if [[ -z "$NGINX_PORT" ]]; then
    warn "NGINX_PORT не найден в .env — используем значение по умолчанию: 8000"
    NGINX_PORT=8000
fi

# Проверяем что это число
[[ "$NGINX_PORT" =~ ^[0-9]+$ ]] || err "NGINX_PORT='${NGINX_PORT}' — не число. Проверь .env"

log "NGINX_PORT = ${NGINX_PORT}"

# ─── 2. NGINX ─────────────────────────────────────────────────────────────────
log "Проверка nginx..."
if ! command -v nginx &>/dev/null; then
    err "nginx не найден. Убедись что amnezia-api установлен через setup.sh"
fi

NGINX_STATUS=$(systemctl is-active nginx 2>/dev/null || echo "inactive")
if [[ "$NGINX_STATUS" != "active" ]]; then
    warn "nginx не запущен — пробуем запустить..."
    systemctl start nginx
    sleep 2
    systemctl is-active nginx &>/dev/null || err "nginx не удалось запустить"
fi
log "nginx активен"

# ─── 3. СЕРТИФИКАТЫ ───────────────────────────────────────────────────────────
log "Проверка сертификатов в ${CERT_DIR}..."
[[ -f "${CERT_DIR}/fullchain.pem" ]] || err "Не найден ${CERT_DIR}/fullchain.pem. Запусти сначала deploy-certbot.sh"
[[ -f "${CERT_DIR}/privkey.pem"   ]] || err "Не найден ${CERT_DIR}/privkey.pem"

EXPIRY=$(openssl x509 -enddate -noout -in "${CERT_DIR}/fullchain.pem" 2>/dev/null | cut -d= -f2 || echo "неизвестно")
log "Сертификат действителен до: ${EXPIRY}"

# ─── 4. API ДОСТУПЕН ──────────────────────────────────────────────────────────
log "Проверка доступности amnezia-api на 127.0.0.1:${API_PORT}..."
if ! curl -sf "http://127.0.0.1:${API_PORT}/healthz" &>/dev/null; then
    warn "amnezia-api не отвечает на /healthz — возможно ещё запускается"
    warn "nginx-конфиг будет создан, но убедись что API запущен"
fi

# ─── 5. ОТКЛЮЧАЕМ СУЩЕСТВУЮЩИЙ HTTP-КОНФИГ AMNEZIA (если есть) ───────────────
sep
log "Поиск существующих nginx-конфигов amnezia-api..."

for f in /etc/nginx/sites-enabled/amnezia* /etc/nginx/sites-enabled/default; do
    if [[ -f "$f" ]] && grep -q "127.0.0.1:${API_PORT}" "$f" 2>/dev/null; then
        if [[ "$f" != "/etc/nginx/sites-enabled/default" ]]; then
            cp "$f" "${f}.bak"
            log "Бэкап: ${f}.bak"
            rm -f "$f"
            log "Старый конфиг отключён: ${f}"
        fi
    fi
done

# ─── 6. СОЗДАЁМ NGINX-КОНФИГ ──────────────────────────────────────────────────
CONF_PATH="/etc/nginx/sites-available/amnezia-api-ssl"
log "Создание ${CONF_PATH} (порт ${NGINX_PORT})..."

cat > "${CONF_PATH}" <<EOF
# amnezia-api — HTTPS reverse proxy
# Сгенерировано deploy-amnezia-https.sh $(date +%Y-%m-%d)
# Порт: ${NGINX_PORT} (из ${ENV_FILE})

server {
    listen ${NGINX_PORT} ssl;
    server_name ${DOMAIN};

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    # Безопасные заголовки
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Content-Type-Options    nosniff;
    add_header X-Frame-Options           DENY;

    # API — пробрасываем всё на amnezia-api
    location / {
        proxy_pass http://127.0.0.1:${API_PORT};

        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        # x-api-key пробрасывается как есть — Fastify сам проверяет
        proxy_pass_request_headers on;

        proxy_read_timeout    30s;
        proxy_connect_timeout 5s;
    }
}
EOF

# ─── 7. ВКЛЮЧАЕМ КОНФИГ ───────────────────────────────────────────────────────
ln -sf "${CONF_PATH}" /etc/nginx/sites-enabled/amnezia-api-ssl
log "Конфиг подключён: /etc/nginx/sites-enabled/amnezia-api-ssl"

# ─── 8. ПРОВЕРЯЕМ И ПЕРЕЗАГРУЖАЕМ NGINX ──────────────────────────────────────
log "Проверка синтаксиса nginx..."
nginx -t || err "Ошибка в конфиге nginx. Проверь вывод выше."

log "Перезагрузка nginx..."
systemctl reload nginx
log "nginx перезагружен"

# ─── 9. DEPLOY HOOK ДЛЯ АВТООБНОВЛЕНИЯ СЕРТИФИКАТОВ ─────────────────────────
sep
log "Настройка deploy-hook для автообновления сертификатов..."

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-amnezia.sh <<HOOK
#!/bin/bash
# Перезагружает nginx после обновления сертификата для ${DOMAIN}
systemctl reload nginx && echo "[certbot hook] nginx перезагружен после обновления ${DOMAIN}"
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-amnezia.sh
log "Deploy-hook создан"

# ─── 10. ПРОВЕРКА ─────────────────────────────────────────────────────────────
sep
log "Проверка HTTPS..."
sleep 1

HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://${DOMAIN}:${NGINX_PORT}/healthz" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" ]]; then
    log "HTTPS работает — /healthz вернул 200"
elif [[ "$HTTP_CODE" == "401" || "$HTTP_CODE" == "403" ]]; then
    log "HTTPS работает — /healthz вернул ${HTTP_CODE} (требует x-api-key, это нормально)"
else
    warn "https://${DOMAIN}:${NGINX_PORT}/healthz вернул ${HTTP_CODE}"
    warn "Проверь: curl -sk https://${DOMAIN}:${NGINX_PORT}/healthz"
fi

# ─── ИТОГ ─────────────────────────────────────────────────────────────────────
echo ""
sep
echo -e "${GREEN}${BOLD}  HTTPS ГОТОВ${NC}"
sep
echo ""
echo -e "  ${BOLD}API URL:${NC}       https://${DOMAIN}:${NGINX_PORT}/"
echo -e "  ${BOLD}Swagger UI:${NC}    https://${DOMAIN}:${NGINX_PORT}/docs"
echo -e "  ${BOLD}Порт из .env:${NC}  NGINX_PORT=${NGINX_PORT} (${ENV_FILE})"
echo -e "  ${BOLD}Сертификат:${NC}    ${CERT_DIR}/fullchain.pem"
echo -e "  ${BOLD}Истекает:${NC}      ${EXPIRY}"
echo ""
echo -e "  ${BOLD}Пример запроса:${NC}"
echo -e "  curl -s https://${DOMAIN}:${NGINX_PORT}/healthz \\"
echo -e "    -H \"x-api-key: <FASTIFY_API_KEY>\""
echo ""
echo -e "  ${BOLD}Управление nginx:${NC}"
echo -e "  systemctl reload nginx"
echo -e "  nginx -t"
echo -e "  cat ${CONF_PATH}"
echo ""
echo -e "  ${BOLD}Если поменяешь NGINX_PORT в .env — перезапусти этот скрипт${NC}"
sep
