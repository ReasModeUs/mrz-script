#!/bin/bash

# ==========================================================
# MRZ SSL Manager
# Version: 2.2 (Multi-Domain Support)
# Copyright (c) 2026 ReasModeUs
# GitHub: https://github.com/ReasModeUs
# ==========================================================

SCRIPT_PATH="/usr/local/bin/mrz-ssl"
LOG_FILE="/var/log/mrz-ssl.log"
ACME_SCRIPT="$HOME/.acme.sh/acme.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}Error: Use root.${NC}" && exit 1

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$LOG_FILE"; }
log_err() { echo -e "${RED}[ERROR] $1${NC}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$LOG_FILE"; }

install_dependencies() {
    if ! command -v socat &> /dev/null || ! command -v lsof &> /dev/null; then
        apt-get update -qq && apt-get install -y socat lsof curl tar cron &> /dev/null
    fi
    [[ ! -f "$ACME_SCRIPT" ]] && curl -s https://get.acme.sh | sh &> /dev/null
}

stop_conflicting_services() {
    local port=$1
    local conflict_pid=$(lsof -t -i:"$port" -sTCP:LISTEN)
    if [[ -n "$conflict_pid" ]]; then
        systemctl stop nginx apache2 2>/dev/null
        kill -9 "$conflict_pid" 2>/dev/null
        sleep 2
    fi
}

deploy_marzban() {
    local domain=$1; local cert=$2; local key=$3; local target="/var/lib/marzban/certs"
    mkdir -p "$target"
    cp "$cert" "$target/fullchain.pem" && cp "$key" "$target/key.pem"
    log_info "Certs for $domain deployed to Marzban."
    command -v docker &> /dev/null && docker restart marzban &> /dev/null
}

deploy_generic() {
    local domain=$1; local cert=$2; local key=$3; local target="/root/certs/$domain"
    mkdir -p "$target"
    cp "$cert" "$target/public.crt" && cp "$key" "$target/private.key"
    chmod 644 "$target/public.crt" "$target/private.key"
    echo -e "\n${GREEN}>>> Success! Certs for $domain saved in:${NC}"
    echo -e "${YELLOW}$target/public.crt${NC}"
    echo -e "${YELLOW}$target/private.key${NC}\n"
}

issue_cert() {
    local domain=$1; local panel=$2; local method=$3
    [[ "$method" == "1" ]] && stop_conflicting_services 80 || stop_conflicting_services 443
    local mode_flag=$([[ "$method" == "1" ]] && echo "--standalone" || echo "--alpn")

    log_info "Issuing cert for $domain..."
    "$ACME_SCRIPT" --register-account -m "admin@$domain" --server zerossl &> /dev/null
    
    if "$ACME_SCRIPT" --issue -d "$domain" "$mode_flag" --force; then
        local cert_path="$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
        local key_path="$HOME/.acme.sh/${domain}_ecc/${domain}.key"
        [[ "$panel" == "1" ]] && deploy_marzban "$domain" "$cert_path" "$key_path" || deploy_generic "$domain" "$cert_path" "$key_path"
        systemctl start nginx 2>/dev/null
    else
        log_err "Failed for $domain. Check DNS/Cloudflare Proxy."
        systemctl start nginx 2>/dev/null
    fi
}

show_menu() {
    clear
    echo -e "${CYAN}MRZ SSL Manager v2.2 | GitHub: ReasModeUs${NC}"
    echo "1) Get New Certificate (Supports multiple domains)"
    echo "2) List Current Certificates"
    echo "3) View Logs"
    echo "4) Renew All"
    echo "5) Delete a Certificate"
    echo "0) Exit"
    read -rp "Option: " opt
    case $opt in
        1)
            read -rp "Enter Domain: " domain
            echo "1) Marzban  2) Sanaei/PasarGuard"
            read -rp "Panel: " p; echo "1) Port 80  2) Port 443"
            read -rp "Method: " m; issue_cert "$domain" "$p" "$m" ;;
        2) "$ACME_SCRIPT" --list; read -p "Enter..."; show_menu ;;
        3) tail -n 20 "$LOG_FILE"; read -p "Enter..."; show_menu ;;
        4) "$ACME_SCRIPT" --cron --force; show_menu ;;
        5) read -rp "Domain: " d; "$ACME_SCRIPT" --remove -d "$d"; rm -rf "$HOME/.acme.sh/${d}_ecc"; show_menu ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

install_dependencies
[[ ! -f "$SCRIPT_PATH" ]] && cp "$0" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
show_menu
