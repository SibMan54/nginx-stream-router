# Nginx Stream Router

Автоматизация конфигурации Nginx Stream (SNI routing)  
с поддержкой:

- Let's Encrypt
- TLS passthrough
- stream proxy
- reverse proxy
- multi-service routing
- automatic rollback
- backup system

Проект предназначен для self-hosted VPS серверов.

---

# ✨ Возможности

- 🔐 Автоматический выпуск Let's Encrypt сертификатов
- 🌐 Добавление новых доменов
- 🔀 SNI routing через Nginx stream
- 📦 Reverse proxy на локальные сервисы
- 💾 Backup system с hash-проверкой
- ♻️ Безопасный rollback / uninstall
- 🧪 Проверка конфигурации Nginx
- 🔄 Idempotent-логика
- 🛡 Поддержка production-конфигураций

---

# 🧠 Архитектура

```text
Internet
   |
   | 443/TCP
   v
Nginx Stream (ssl_preread)
   |
   +--> domain1.com -> service_1
   +--> domain2.com -> service_2
   +--> domain3.com -> service_3
                        |
                        v
                 Reverse Proxy
                        |
                        v
                   Local Service
```

---

# 📋 Требования

- Ubuntu 22.04 / 24.04
- Nginx
- Certbot
- Stream module enabled
- Root access

---

# 🚀 Установка

## Скачать скрипт

```bash
curl -O https://raw.githubusercontent.com/SibMan54/nginx-stream-router/main/install.sh
chmod +x install.sh
```

## Запуск

```bash
sudo ./install.sh
```

---

# 🧹 Удаление сервиса

```bash
curl -O https://raw.githubusercontent.com/SibMan54/nginx-stream-router/main/uninstall.sh
chmod +x uninstall.sh
sudo ./uninstall.sh
```

---

# 📂 Что изменяет скрипт

## Nginx

- `/etc/nginx/sites-available/80.conf`
- `/etc/nginx/sites-available/<domain>`
- `/etc/nginx/stream-enabled/stream.conf`

## Let's Encrypt

- Выпуск сертификатов
- Удаление сертификатов

---

# 💾 Backup System

Скрипт автоматически создаёт:

| Тип | Назначение |
|------|------|
| `.original` | оригинальный конфиг |
| `.bak-*` | snapshot изменений |

Backup создаётся только если содержимое реально изменилось (SHA256 comparison).

---

# 🔐 Пример stream.conf

```nginx
map $ssl_preread_server_name $sni_name {
    hostnames;

    cloud.example.com service_1;
    notes.example.com service_2;

    default xray;
}

upstream service_1 {
    server 127.0.0.1:6443;
}

upstream service_2 {
    server 127.0.0.1:7443;
}

server {
    proxy_protocol on;
    listen 443;
    proxy_pass $sni_name;
    ssl_preread on;
}
```

---

# ⚠️ Важно

Скрипт предполагает наличие:

- существующего Nginx stream routing
- корректной структуры stream.conf
- уже работающего Nginx

---

# 📄 License

MIT License