#!/bin/bash
# Module: Install Node Only

setup_itdog_dat() {
    local TARGET_DIR="/opt/remnanode/xray/share"
    local FILE_URL="https://github.com/itdoginfo/allow-domains/releases/latest/download/geosite.dat"
    local FILE_NAME="itdog.dat"
    local COMPOSE_DIR="/opt/remnanode"

    mkdir -p "$TARGET_DIR"
    wget -qO "$TARGET_DIR/$FILE_NAME" "$FILE_URL"
    echo "✓ Файл сохранён: $TARGET_DIR/$FILE_NAME"

    if ! grep -q "itdog.dat" "$COMPOSE_DIR/docker-compose.yml"; then
        awk '
            /- \/dev\/shm:\/dev\/shm:rw/ {
                count++
                if (count == 2) {
                    print
                    print "      - /opt/remnanode/xray/share/itdog.dat:/usr/local/bin/itdog.dat"
                    next
                }
            }
            { print }
        ' "$COMPOSE_DIR/docker-compose.yml" > /tmp/docker-compose.tmp \
        && mv /tmp/docker-compose.tmp "$COMPOSE_DIR/docker-compose.yml"

        echo "✓ Volume добавлен в docker-compose.yml"
        docker compose -f "$COMPOSE_DIR/docker-compose.yml" up -d remnanode
        echo "✓ Контейнер перезапущен с новым volume"
    else
        echo "✓ Volume уже есть в docker-compose.yml"
    fi

    local CRON_JOB="0 3 * * 0 wget -qO $TARGET_DIR/$FILE_NAME $FILE_URL && docker compose -f $COMPOSE_DIR/docker-compose.yml restart remnanode"
    ( crontab -l 2>/dev/null | grep -qF "$FILE_NAME" ) \
      && echo "✓ Cron уже существует, пропускаем" \
      || ( crontab -l 2>/dev/null; echo "$CRON_JOB" ) | crontab -
    echo "✓ Cron настроен: каждое воскресенье в 03:00"
}

setup_traffic_guard() {
    wget -qO- https://raw.githubusercontent.com/dotX12/traffic-guard/master/install.sh | sudo bash
    sudo traffic-guard full \
      -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list \
      -u https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list \
      --enable-logging
    sudo apt install -y whois
    echo "✓ Traffic-guard установлен"
}

disable_icmp_ping() {
    if ! grep -q "net.ipv4.icmp_echo_ignore_all = 1" /etc/sysctl.conf; then
        echo "net.ipv4.icmp_echo_ignore_all = 1" | sudo tee -a /etc/sysctl.conf
        sudo sysctl -p
        echo "✓ ICMP ping отключен"
    else
        echo "✓ ICMP ping уже отключен"
    fi
}

setup_auto_cleanup() {
    journalctl --vacuum-size=100M
    if ! grep -q "SystemMaxUse=200M" /etc/systemd/journald.conf; then
        echo "SystemMaxUse=200M" | sudo tee -a /etc/systemd/journald.conf
    fi
    systemctl restart systemd-journald
    truncate -s 0 /var/log/syslog /var/log/kern.log /var/log/ufw.log 2>/dev/null
    rm -f /var/log/syslog.1 /var/log/kern.log.1 /var/log/ufw.log.1 2>/dev/null
    docker image prune -a -f
    echo "✓ Автоочистка выполнена"
}

setup_weekly_reboot() {
    ( crontab -l 2>/dev/null; echo "0 3 * * 0 /sbin/reboot" ) | sort -u | crontab -
    echo "✓ Crontab обновлён (еженедельная перезагрузка):"
    crontab -l | grep reboot
}

install_node_nginx() {
    # Load selfsteal templates module
    load_selfsteal_templates_module

    mkdir -p /opt/remnanode && cd /opt/remnanode

    reading "${LANG[SELFSTEAL]}" SELFSTEAL_DOMAIN

    check_domain "$SELFSTEAL_DOMAIN" true false
    local domain_check_result=$?
    if [ $domain_check_result -eq 2 ]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

    while true; do
        reading "${LANG[PANEL_IP_PROMPT]}" PANEL_IP
        if echo "$PANEL_IP" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' >/dev/null && \
           [[ $(echo "$PANEL_IP" | tr '.' '\n' | wc -l) -eq 4 ]] && \
           [[ ! $(echo "$PANEL_IP" | tr '.' '\n' | grep -vE '^[0-9]{1,3}$') ]] && \
           [[ ! $(echo "$PANEL_IP" | tr '.' '\n' | grep -E '^(25[6-9]|2[6-9][0-9]|[3-9][0-9]{2})$') ]]; then
            break
        else
            echo -e "${COLOR_RED}${LANG[IP_ERROR]}${COLOR_RESET}"
        fi
    done

    echo -n "$(question "${LANG[CERT_PROMPT]}")"
    CERTIFICATE=""
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            if [ -n "$CERTIFICATE" ]; then
                break
            fi
        else
            CERTIFICATE="$CERTIFICATE$line\n"
        fi
    done

    echo -e "${COLOR_YELLOW}${LANG[CERT_CONFIRM]}${COLOR_RESET}"
    read confirm
    echo

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

    SELFSTEAL_BASE_DOMAIN=$(extract_domain "$SELFSTEAL_DOMAIN")

    local DEFAULT_XHTTP_PATH=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16)
    reading "${LANG[XHTTP_PATH_PROMPT]} ($DEFAULT_XHTTP_PATH)" XHTTP_PATH
    XHTTP_PATH="${XHTTP_PATH:-$DEFAULT_XHTTP_PATH}"

    unique_domains["$SELFSTEAL_BASE_DOMAIN"]=1

cat > docker-compose.yml <<EOL
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: 5

services:
  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    <<: [*common, *logging]
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
EOL
}

installation_node() {
    echo -e "${COLOR_YELLOW}${LANG[INSTALLING_NODE]}${COLOR_RESET}"
    sleep 1

    declare -A unique_domains
    install_node_nginx

    declare -A domains_to_check
    domains_to_check["$SELFSTEAL_DOMAIN"]=1

    handle_certificates domains_to_check "$CERT_METHOD" "$LETSENCRYPT_EMAIL"

    if [ -z "$CERT_METHOD" ]; then
        local base_domain=$(extract_domain "$SELFSTEAL_DOMAIN")
        if [ -d "/etc/letsencrypt/live/$base_domain" ] && is_wildcard_cert "$base_domain"; then
            CERT_METHOD="1"
        else
            CERT_METHOD="2"
        fi
    fi

    if [ "$CERT_METHOD" == "1" ]; then
        local base_domain=$(extract_domain "$SELFSTEAL_DOMAIN")
        NODE_CERT_DOMAIN="$base_domain"
    else
        NODE_CERT_DOMAIN="$SELFSTEAL_DOMAIN"
    fi

    cat >> /opt/remnanode/docker-compose.yml <<EOL
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    <<: [*common, *logging]
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=$(echo -e "$CERTIFICATE")
    volumes:
      - /dev/shm:/dev/shm:rw
      - /opt/remnanode/xray/share/itdog.dat:/usr/local/bin/itdog.dat
EOL

cat > /opt/remnanode/nginx.conf <<EOL
server_names_hash_bucket_size 64;

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

server {
    server_name $SELFSTEAL_DOMAIN;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$NODE_CERT_DOMAIN/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem";

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;

    location /$XHTTP_PATH/ {
        client_max_body_size 0;
        proxy_set_header X-Real-IP \$proxy_protocol_addr;
        proxy_set_header X-Forwarded-For \$proxy_protocol_addr;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_http_version 1.1;
        client_body_timeout 5m;
        proxy_read_timeout 315s;
        proxy_send_timeout 5m;
        proxy_pass http://unix:/dev/shm/xrxh.socket;
    }
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
    ssl_reject_handshake on;
    return 444;
}
EOL

    ufw allow from $PANEL_IP to any port 2222 > /dev/null 2>&1
    ufw reload > /dev/null 2>&1

    echo -e "${COLOR_YELLOW}${LANG[STARTING_NODE]}${COLOR_RESET}"
    sleep 3
    cd /opt/remnanode
    docker compose up -d > /dev/null 2>&1 &

    spinner $! "${LANG[WAITING]}"

    randomhtml

    printf "${COLOR_YELLOW}${LANG[NODE_CHECK]}${COLOR_RESET}\n" "$SELFSTEAL_DOMAIN"
    local max_attempts=5
    local attempt=1
    local delay=15

    while [ $attempt -le $max_attempts ]; do
        printf "${COLOR_YELLOW}${LANG[NODE_ATTEMPT]}${COLOR_RESET}\n" "$attempt" "$max_attempts"
        if curl -s --fail --max-time 10 "https://$SELFSTEAL_DOMAIN" | grep -q "html"; then
            echo -e "${COLOR_GREEN}${LANG[NODE_LAUNCHED]}${COLOR_RESET}"
            break
        else
            printf "${COLOR_RED}${LANG[NODE_UNAVAILABLE]}${COLOR_RESET}\n" "$attempt"
            if [ $attempt -eq $max_attempts ]; then
                printf "${COLOR_RED}${LANG[NODE_NOT_CONNECTED]}${COLOR_RESET}\n" "$max_attempts"
                echo -e "${COLOR_YELLOW}${LANG[CHECK_CONFIG]}${COLOR_RESET}"
                exit 1
            fi
            sleep $delay
        fi
            ((attempt++))
        done

    setup_itdog_dat
    setup_traffic_guard
    disable_icmp_ping
    setup_auto_cleanup
    setup_weekly_reboot

    echo ""
    echo -e "${COLOR_GREEN}=== Установка завершена ===${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}XHTTP Path: /$XHTTP_PATH/${COLOR_RESET}"
    echo ""
}
