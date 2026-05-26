#!/bin/bash
set -e

### =========================
### НАСТРОЙКИ / КОНСТАНТЫ
### =========================

NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
STREAM_CONF="/etc/nginx/stream-enabled/stream.conf"
HTTP_CONF="${NGINX_AVAIL}/80.conf"

STREAM_PORT=""       # порт
HTTP_PORT=""         # порт docker-контейнера (вводится пользователем)

### =========================
### ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
### =========================

info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

backup_file() {
    local file="$1"

    # ==========================================
    # Если файла нет — backup не нужен
    # ==========================================

    if [ ! -f "$file" ]; then
        info "Файл $file ещё не существует, backup не требуется"
        return 0
    fi

    # ==========================================
    # Создание original backup
    # ==========================================

    if [ ! -f "${file}.original" ]; then
        cp "$file" "${file}.original"
        info "Создан original-бэкап: ${file}.original"
        return 0
    fi

    # ==========================================
    # HASH текущего файла
    # ==========================================

    local current_hash
    current_hash=$(sha256sum "$file" | awk '{print $1}')

    # ==========================================
    # Сравнение с ORIGINAL
    # ==========================================

    local original_hash
    original_hash=$(sha256sum "${file}.original" | awk '{print $1}')

    if [ "$current_hash" = "$original_hash" ]; then
        info "Файл идентичен original-бэкапу, backup не требуется"
        return 0
    fi

    # ==========================================
    # Сравнение со всеми bak-*
    # ==========================================

    local backup_hash

    for backup in "${file}".bak-*; do

        [ -f "$backup" ] || continue

        backup_hash=$(sha256sum "$backup" | awk '{print $1}')

        if [ "$current_hash" = "$backup_hash" ]; then
            info "Идентичный backup уже существует: $backup"
            return 0
        fi
    done

    # ==========================================
    # Создание нового backup
    # ==========================================

    local timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"

    cp "$file" "${file}.bak-${timestamp}"

    info "Создан бэкап: ${file}.bak-${timestamp}"
}

port_free() {
    ! ss -tulpen | awk '{print $5}' | grep -q ":$1$"
}

### =========================
### ПРОВЕРКИ
### =========================

[ "$EUID" -ne 0 ] && err "Скрипт должен запускаться от root"
command -v nginx >/dev/null || err "Nginx не установлен"
command -v certbot >/dev/null || err "Certbot не установлен"

### =========================
### ВВОД ДАННЫХ
### =========================

read -rp "Введите домен: " DOMAIN
[ -z "$DOMAIN" ] && err "Домен не может быть пустым"

read -rp "Введите порт docker-контейнера: " HTTP_PORT
[[ ! "$HTTP_PORT" =~ ^[0-9]+$ ]] && err "Некорректный порт"

read -rp "Введите порт для stream (например 4443, 5443, 6443): " STREAM_PORT
[[ ! "$STREAM_PORT" =~ ^[0-9]+$ ]] && err "Некорректный порт"

### =========================
### ПРОВЕРКА ПОРТОВ
### =========================

if port_free "$HTTP_PORT"; then
    err "На порту $HTTP_PORT нет docker-контейнера"
fi
if ! port_free "$STREAM_PORT"; then
    err "Порт $STREAM_PORT уже занят"
fi

### =========================
### CERTBOT
### =========================

info "Выпуск сертификата для $DOMAIN"
backup_file "$HTTP_CONF"

certbot certonly --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@"$DOMAIN"

### =========================
### 80.conf
### =========================

info "Обновление 80.conf"
if grep -q "server_name" "$HTTP_CONF"; then
    backup_file "$HTTP_CONF"
    if grep -qE "server_name .*\\b${DOMAIN}\\b" "$HTTP_CONF"; then
        info "Домен ${DOMAIN} уже присутствует в server_name — пропуск"
    else
        info "Добавление домена ${DOMAIN} в server_name"
        sed -i -E "s|(server_name\s+[^;]*);|\1 ${DOMAIN};|" "$HTTP_CONF"
    fi
else
    err "В 80.conf не найден server_name — ручная проверка обязательна"
fi

### =========================
### cloud.domain.conf
### =========================

info "Создание nginx-конфига для $DOMAIN"

NGINX_CONF="${NGINX_AVAIL}/${DOMAIN}"
backup_file "$NGINX_CONF"

cat > "$NGINX_CONF" <<EOF
server {
    server_name ${DOMAIN};

    listen ${STREAM_PORT} ssl http2 proxy_protocol;
    listen [::]:${STREAM_PORT} ssl http2 proxy_protocol;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    proxy_intercept_errors on;
    proxy_buffering off;
    proxy_request_buffering off;

    location / {
        proxy_pass http://127.0.0.1:${HTTP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF

ln -sf "$NGINX_CONF" "${NGINX_ENABLED}/${DOMAIN}"

### =========================
### stream.conf
### =========================

info "Обновление stream.conf"
backup_file "$STREAM_CONF"

# ==========================================
# Генерация уникального имени service_N
# ==========================================

LAST_SERVICE_NUM=$(
    grep -oE 'upstream service_[0-9]+' "$STREAM_CONF" \
    | grep -oE '[0-9]+' \
    | sort -n \
    | tail -1
)

if [ -z "$LAST_SERVICE_NUM" ]; then
    SERVICE_NUM=1
else
    SERVICE_NUM=$((LAST_SERVICE_NUM + 1))
fi

SERVICE_NAME="service_${SERVICE_NUM}"

info "Создан upstream: ${SERVICE_NAME}"

# ==========================================
# Добавление DOMAIN -> SERVICE_NAME
# ==========================================

if ! grep -q "${DOMAIN}" "$STREAM_CONF"; then
    sed -i "/^\s*default\s\+/i\    ${DOMAIN}   ${SERVICE_NAME};" "$STREAM_CONF"
fi

# ==========================================
# Добавление upstream service_N
# ==========================================

if ! grep -q "upstream ${SERVICE_NAME}" "$STREAM_CONF"; then
    sed -i "/^\s*server\s*{/i\
upstream ${SERVICE_NAME} {\n\
    server 127.0.0.1:${STREAM_PORT};\n\
}\n" "$STREAM_CONF"
fi


### =========================
### ПРОВЕРКА И ПЕРЕЗАГРУЗКА
### =========================

info "Проверка конфигурации Nginx"
nginx -t

info "Перезагрузка Nginx"
systemctl reload nginx

### =========================
### ФИНАЛ
### =========================

info "🌐 Доступ: https://${DOMAIN}"