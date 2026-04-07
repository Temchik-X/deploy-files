#!/bin/bash
# =============================================================================
# deploy-3xui.sh — Развёртывание 3x-ui (Xray) через Docker Compose
# ОС: Debian 11/12
# Использование: sudo bash deploy-3xui.sh
# =============================================================================

set -euo pipefail

# ─── НАСТРОЙКИ — ЗАПОЛНИ ПЕРЕД ЗАПУСКОМ ─────────────────────────────────────
DOMAIN="your.domain.com"       # домен (для поиска сертификатов в /root/cert/)
DEPLOY_DIR="/opt/3xui"         # папка для docker-compose и данных
XUI_PORT=2053                  # порт веб-панели 3x-ui
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
sep()  { echo -e "${BOLD}────────────────────────────────────────${NC}"; }

# ─── ПРОВЕРКИ ─────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Запусти от root: sudo bash deploy-3xui.sh"
[[ "$DOMAIN" == "your.domain.com" ]] && warn "Используется домен по умолчанию: $DOMAIN"

sep
log "Развёртывание 3x-ui (Docker): $DOMAIN"
sep

# ─── 1. ЗАВИСИМОСТИ ──────────────────────────────────────────────────────────
log "Обновление пакетов..."
apt-get update -qq

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
CERT_DIR="/root/cert/${DOMAIN}"
log "Проверка сертификатов в ${CERT_DIR}..."

if [[ -f "${CERT_DIR}/fullchain.pem" && -f "${CERT_DIR}/privkey.pem" ]]; then
    log "Сертификаты найдены — будут смонтированы в контейнер"
else
    warn "Сертификаты не найдены в ${CERT_DIR}/"
    warn "Запусти сначала deploy-certbot.sh, или положи fullchain.pem и privkey.pem вручную"
    warn "3x-ui запустится без SSL (панель будет доступна по HTTP)"
fi

# ─── 4. СТРУКТУРА ФАЙЛОВ ─────────────────────────────────────────────────────
log "Создание структуры ${DEPLOY_DIR}..."
mkdir -p "${DEPLOY_DIR}/db"
mkdir -p "${DEPLOY_DIR}/cert"

# Симлинк на сертификаты если они есть
if [[ -f "${CERT_DIR}/fullchain.pem" ]]; then
    cp "${CERT_DIR}/fullchain.pem" "${DEPLOY_DIR}/cert/fullchain.pem"
    cp "${CERT_DIR}/privkey.pem"   "${DEPLOY_DIR}/cert/privkey.pem"
    chmod 644 "${DEPLOY_DIR}/cert/fullchain.pem"
    chmod 600 "${DEPLOY_DIR}/cert/privkey.pem"
    log "Сертификаты скопированы в ${DEPLOY_DIR}/cert/"
fi

# ─── 5. DOCKER COMPOSE ───────────────────────────────────────────────────────
log "Создание docker-compose.yml..."
cat > "${DEPLOY_DIR}/docker-compose.yml" <<EOF
services:
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: 3x-ui
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./db:/etc/x-ui
      - ./cert:/root/cert/${DOMAIN}:ro
    environment:
      XRAY_VMESS_AEAD_FORCED: "false"
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
EOF

# ─── 6. СКРИПТ ОБНОВЛЕНИЯ СЕРТИФИКАТОВ ───────────────────────────────────────
log "Создание скрипта обновления сертификатов..."
cat > "${DEPLOY_DIR}/update-certs.sh" <<'SCRIPT'
#!/bin/bash
# Копирует обновлённые сертификаты из /root/cert/DOMAIN/ и перезапускает контейнер
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOMAIN_DIR="$(ls -d /root/cert/*/  2>/dev/null | head -1)"

if [[ -z "$DOMAIN_DIR" ]]; then
    echo "[!] Не найдены сертификаты в /root/cert/"
    exit 1
fi

cp "${DOMAIN_DIR}fullchain.pem" "${SCRIPT_DIR}/cert/fullchain.pem"
cp "${DOMAIN_DIR}privkey.pem"   "${SCRIPT_DIR}/cert/privkey.pem"
chmod 644 "${SCRIPT_DIR}/cert/fullchain.pem"
chmod 600 "${SCRIPT_DIR}/cert/privkey.pem"

docker compose -f "${SCRIPT_DIR}/docker-compose.yml" restart 3x-ui
echo "[+] Сертификаты обновлены, 3x-ui перезапущен"
SCRIPT
chmod +x "${DEPLOY_DIR}/update-certs.sh"

# ─── 7. ЗАПУСК ───────────────────────────────────────────────────────────────
sep
log "Загрузка образа и запуск..."
cd "${DEPLOY_DIR}"
docker compose pull
docker compose up -d

sleep 5

CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' 3x-ui 2>/dev/null || echo "unknown")
log "Контейнер 3x-ui: ${CONTAINER_STATUS}"

# ─── 8. НАСТРОЙКА SSL В ПАНЕЛИ ───────────────────────────────────────────────
if [[ -f "${DEPLOY_DIR}/cert/fullchain.pem" ]]; then
    sep
    log "SSL-сертификаты смонтированы."
    log "Настрой пути в панели 3x-ui:"
    log "  Panel Settings → Certificate File Path: /root/cert/${DOMAIN}/fullchain.pem"
    log "  Panel Settings → Key File Path:         /root/cert/${DOMAIN}/privkey.pem"
fi

# ─── 9. ИТОГ ─────────────────────────────────────────────────────────────────
PANEL_PASS=$(docker exec 3x-ui /app/x-ui setting -show 2>/dev/null | grep -i password | awk '{print $NF}' || echo "(смотри логи: docker logs 3x-ui)")

echo ""
sep
echo -e "${GREEN}${BOLD}  РАЗВЁРТЫВАНИЕ ЗАВЕРШЕНО${NC}"
sep
echo ""
echo -e "  ${BOLD}Панель 3x-ui:${NC}  http://<server-ip>:${XUI_PORT}/  (или https если SSL настроен)"
echo -e "  ${BOLD}Deploy dir:${NC}    ${DEPLOY_DIR}"
echo ""
echo -e "  ${BOLD}Начальные реквизиты:${NC}"
echo -e "  Логин:     admin"
echo -e "  Пароль:    ${PANEL_PASS}"
echo ""
echo -e "  ${BOLD}Управление:${NC}"
echo -e "  cd ${DEPLOY_DIR}"
echo -e "  docker compose ps"
echo -e "  docker compose logs -f 3x-ui"
echo -e "  docker compose pull && docker compose up -d   # обновление"
echo ""
echo -e "  ${BOLD}Обновить сертификаты:${NC}"
echo -e "  bash ${DEPLOY_DIR}/update-certs.sh"
sep
