#!/bin/bash
set -e

### =========================
### НАСТРОЙКИ
### =========================

NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
STREAM_CONF="/etc/nginx/stream-enabled/stream.conf"
HTTP_CONF="${NGINX_AVAIL}/80.conf"

### =========================
### ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ
### =========================

info() { echo -e "\033[1;34m[INFO]\033[0m $1"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; exit 1; }

restore_file() {
    local file="$1"

    if [ -f "${file}.original" ]; then
        cp "${file}.original" "$file"
        info "Восстановлен original-бэкап: $file"
    else
        warn "Original-бэкап для $file не найден"
    fi
}

remove_line() {
    local pattern="$1"
    local file="$2"

    sed -i "\|${pattern}|d" "$file"
}

### =========================
### ПРОВЕРКИ
### =========================

[ "$EUID" -ne 0 ] && err "Скрипт должен запускаться от root"
command -v nginx >/dev/null || err "Nginx не установлен"

### =========================
### ВВОД ДАННЫХ
### =========================

read -rp "Введите домен для удаления: " DOMAIN
[ -z "$DOMAIN" ] && err "Домен не может быть пустым"

NGINX_CONF="${NGINX_AVAIL}/${DOMAIN}"

### =========================
### ОПРЕДЕЛЕНИЕ STREAM_PORT
### =========================

if [ -f "$NGINX_CONF" ]; then
    STREAM_PORT=$(grep -oP 'listen\s+\K[0-9]+' "$NGINX_CONF" | head -n1)
    info "Найден STREAM_PORT: ${STREAM_PORT}"
else
    warn "Конфиг ${NGINX_CONF} не найден"
fi

### =========================
### УДАЛЕНИЕ NGINX-КОНФИГА
### =========================

if [ -f "$NGINX_CONF" ]; then
    info "Удаление nginx-конфига ${NGINX_CONF}"

    rm -f "${NGINX_ENABLED}/${DOMAIN}"
    rm -f "$NGINX_CONF"

    info "Конфиг удалён"
else
    warn "Файл ${NGINX_CONF} уже отсутствует"
fi

### =========================
### ОЧИСТКА 80.conf
### =========================

if [ -f "$HTTP_CONF" ]; then
    info "Удаление домена из 80.conf"

    backup_file() {
        local file="$1"

        if [ ! -f "$file" ]; then
            return 0
        fi

        if [ ! -f "${file}.original" ]; then
            cp "$file" "${file}.original"
        fi
    }

    backup_file "$HTTP_CONF"

    sed -i -E "s/\b${DOMAIN}\b//g" "$HTTP_CONF"

    # cleanup двойных пробелов
    sed -i -E 's/[[:space:]]+/ /g' "$HTTP_CONF"

    # cleanup пробела перед ;
    sed -i -E 's/ ;/;/g' "$HTTP_CONF"

    info "Домен удалён из server_name"
fi

### =========================
### ОЧИСТКА stream.conf
### =========================

if [ -f "$STREAM_CONF" ]; then

    info "Очистка stream.conf"

    # backup
    if [ ! -f "${STREAM_CONF}.original" ]; then
        cp "$STREAM_CONF" "${STREAM_CONF}.original"
    fi

    # ==========================================
    # Находим service_X по домену
    # ==========================================

    SERVICE_NAME=$(
        grep -E "^\s*${DOMAIN}\s+" "$STREAM_CONF" \
        | awk '{print $2}' \
        | tr -d ';' \
        | head -n1
    )

    if [ -n "$SERVICE_NAME" ]; then

        info "Найден upstream: ${SERVICE_NAME}"

        # Удаление map строки
        sed -i "\|${DOMAIN}|d" "$STREAM_CONF"

        # Удаление upstream блока
        sed -i "/upstream ${SERVICE_NAME} {/,/}/d" "$STREAM_CONF"

        info "Удалён upstream ${SERVICE_NAME}"

    else
        warn "Связка DOMAIN -> service не найдена"
    fi
fi

### =========================
### УДАЛЕНИЕ CERTBOT
### =========================

if certbot certificates | grep -q "$DOMAIN"; then
    read -rp "Удалить сертификат Let's Encrypt? [y/N]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        info "Удаление сертификата Let's Encrypt для $DOMAIN"
        certbot delete \
            --cert-name "${DOMAIN}" \
            --non-interactive
    else
        warn "Сертификат оставлен"
    fi
else
    warn "Сертификат ${DOMAIN} не найден"
fi

### =========================
### ПРОВЕРКА NGINX
### =========================

info "Проверка конфигурации Nginx"

nginx -t

### =========================
### ПЕРЕЗАГРУЗКА
### =========================

info "Перезагрузка Nginx"

systemctl reload nginx

### =========================
### ФИНАЛ
### =========================

info "Удаление ${DOMAIN} завершено"