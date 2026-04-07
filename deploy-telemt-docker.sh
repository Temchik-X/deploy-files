#!/bin/bash
# =============================================================================
# deploy-telemt-docker.sh — Развёртывание Telemt MTProto прокси в Docker
#
# Архитектура:
#   Клиент → :443 (telemt, TLS SNI-мимикрия под SNI_DOMAIN)
#   DPI видит легитимный TLS к SNI_DOMAIN (реальный сертификат, реальные записи)
#   Telegram-клиент с ee-секретом распознаётся и обрабатывается как MTProto
#   Nginx НЕ нужен — telemt сам делает TLS-фронтинг
#
# ОС: Debian 11/12
# Использование: sudo bash deploy-telemt-docker.sh
# =============================================================================

set -euo pipefail

# ─── НАСТРОЙКИ — ЗАПОЛНИ ПЕРЕД ЗАПУСКОМ ─────────────────────────────────────
DOMAIN="your.domain.com"   # твой домен (IP или домен для tg:// ссылки)
SNI_DOMAIN="wb.ru"         # сайт под который маскируемся
API_TOKEN=""               # API-токен (пустым — сгенерируется)
DEPLOY_DIR="/opt/telemt"   # рабочая папка
# ─────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
sep()  { echo -e "${BOLD}────────────────────────────────────────${NC}"; }

[[ $EUID -ne 0 ]] && err "Запусти от root: sudo bash deploy-telemt-docker.sh"
[[ "$DOMAIN" == "your.domain.com" ]] && warn "Используется домен по умолчанию: $DOMAIN"

sep
log "Развёртывание Telemt | SNI: $SNI_DOMAIN | Домен: $DOMAIN"
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

# ─── 3. ПРОВЕРКА ПОРТА 443 ───────────────────────────────────────────────────
if ss -tlnp | grep -q ':443 '; then
    PROC=$(ss -tlnp | grep ':443 ' | grep -oP 'users:\(\("\K[^"]+' | head -1 || echo "unknown")
    err "Порт 443 занят: ${PROC}. Освободи его перед запуском."
fi
log "Порт 443 свободен"

# ─── 4. ГЕНЕРАЦИЯ СЕКРЕТОВ ───────────────────────────────────────────────────
sep
# ee-префикс обязателен для TLS fake-режима (не dd!)
USER_SECRET="ee$(openssl rand -hex 16)"
[[ -z "$API_TOKEN" ]] && API_TOKEN=$(openssl rand -hex 32)
log "Секрет: ${USER_SECRET}"

# ─── 5. СТРУКТУРА ФАЙЛОВ ─────────────────────────────────────────────────────
mkdir -p "${DEPLOY_DIR}"
log "Рабочая папка: ${DEPLOY_DIR}"

# ─── 6. КОНФИГ TELEMT ────────────────────────────────────────────────────────
log "Создание config.toml..."
cat > "${DEPLOY_DIR}/config.toml" <<EOF
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure  = false
tls     = true

[general.links]
show        = "*"
public_host = "${DOMAIN}"
public_port = 443

[server]
port = 443

[server.api]
enabled    = true
listen     = "0.0.0.0:9091"
whitelist  = ["127.0.0.0/8"]
auth_header = "Bearer ${API_TOKEN}"

# Слушаем на всех IPv4-интерфейсах
[[server.listeners]]
ip = "0.0.0.0"

# SNI-мимикрия: незнакомые соединения прозрачно уходят на ${SNI_DOMAIN}
# DPI видит реальный TLS-сертификат и реальные длины записей
[censorship]
tls_domain    = "${SNI_DOMAIN}"
mask          = true
tls_emulation = true
tls_front_dir = "tlsfront"   # относительно working_dir (/run/telemt)

[access.users]
default = "${USER_SECRET}"
EOF

# ─── 7. DOCKER COMPOSE ───────────────────────────────────────────────────────
log "Создание docker-compose.yml..."
cat > "${DEPLOY_DIR}/docker-compose.yml" <<EOF
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt
    restart: unless-stopped
    working_dir: /run/telemt
    ports:
      - "443:443"
      - "127.0.0.1:9091:9091"
    volumes:
      - ./config.toml:/run/telemt/config.toml:ro
    tmpfs:
      - /run/telemt:rw,mode=1777,size=10m
    environment:
      - RUST_LOG=info
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
EOF

# ─── 8. ЗАПУСК ───────────────────────────────────────────────────────────────
sep
log "Запуск контейнера..."
cd "${DEPLOY_DIR}"
docker compose pull
docker compose up -d

sleep 5

STATUS=$(docker inspect --format='{{.State.Status}}' telemt 2>/dev/null || echo "unknown")
if [[ "$STATUS" == "running" ]]; then
    log "Telemt запущен успешно"
else
    warn "Статус: $STATUS"
    docker compose logs --tail=40 telemt
fi

# ─── 9. ПОЛУЧЕНИЕ ССЫЛКИ ─────────────────────────────────────────────────────
sleep 3
PROXY_LINK=$(curl -s \
    -H "Authorization: Bearer ${API_TOKEN}" \
    http://127.0.0.1:9091/v1/users \
    | jq -r '.data[] | select(.username == "default") | .links[0]' 2>/dev/null || echo "")

# ─── 10. СОХРАНЕНИЕ ──────────────────────────────────────────────────────────
cat > /root/telemt-info.txt <<EOF
# Telemt — $(date)
DOMAIN=${DOMAIN}
SNI_DOMAIN=${SNI_DOMAIN}
DEPLOY_DIR=${DEPLOY_DIR}
API_TOKEN=${API_TOKEN}
DEFAULT_SECRET=${USER_SECRET}
PROXY_LINK=${PROXY_LINK}

# docker compose -f ${DEPLOY_DIR}/docker-compose.yml logs -f telemt
# docker compose -f ${DEPLOY_DIR}/docker-compose.yml restart telemt

# Создать пользователя:
# curl -s -X POST http://127.0.0.1:9091/v1/users \
#   -H "Authorization: Bearer ${API_TOKEN}" \
#   -H "Content-Type: application/json" \
#   -d '{"username":"user1"}' | jq

# Список пользователей:
# curl -s -H "Authorization: Bearer ${API_TOKEN}" http://127.0.0.1:9091/v1/users | jq
EOF
chmod 600 /root/telemt-info.txt

# ─── ИТОГ ────────────────────────────────────────────────────────────────────
echo ""
sep
echo -e "${GREEN}${BOLD}  ГОТОВО${NC}"
sep
echo -e "  ${BOLD}Прокси:${NC}    ${DOMAIN}:443"
echo -e "  ${BOLD}SNI маска:${NC} ${SNI_DOMAIN}"
echo -e "  ${BOLD}Секрет:${NC}    ${USER_SECRET}"
echo -e "  ${BOLD}API:${NC}       http://127.0.0.1:9091/v1/"
echo ""
if [[ -n "$PROXY_LINK" ]]; then
    echo -e "  ${BOLD}Ссылка:${NC}"
    echo -e "  ${GREEN}${PROXY_LINK}${NC}"
else
    echo -e "  ${YELLOW}Получи ссылку:${NC}"
    echo -e "  curl -s -H \"Authorization: Bearer ${API_TOKEN}\" http://127.0.0.1:9091/v1/users | jq"
fi
echo ""
echo -e "  ${BOLD}Данные:${NC} /root/telemt-info.txt"
sep
