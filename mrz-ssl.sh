#!/bin/bash

# ==========================================================
# MRZ SSL Manager - v2.5 (Professional Edition)
# Copyright (c) 2026 ReasModeUs
# GitHub: https://github.com/ReasModeUs
# ==========================================================

SCRIPT_PATH="/usr/local/bin/mrz-ssl"
LOG_FILE="/var/log/mrz-ssl.log"
ACME_SCRIPT="$HOME/.acme.sh/acme.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}Error: Root access required.${NC}" && exit 1

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$LOG_FILE"; }
log_err() { echo -e "${RED}[ERROR] $1${NC}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$LOG_FILE"; }

install_deps() {
    log_info "Updating system and installing dependencies..."
    apt-get update -qq && apt-get install -y socat lsof curl tar cron &> /dev/null
    if [[ ! -f "$ACME_SCRIPT" ]]; then
        curl -s https://get.acme.sh | sh &> /dev/null
    fi
}

issue_cert() {
    read -rp "Enter Domain: " domain
    read -rp "Enter Email (for SSL notifications): " user_email
    [[ -z "$user_email" ]] && user_email="admin@$domain"

    echo -e "\nChoose Panel:\n1) Marzban\n2) Sanaei/PasarGuard/Other"
    read -rp "Choice: " p_choice

    echo -e "\nChoose Method:\n1) Port 80 (HTTP)\n2) Port 443 (TLS-ALPN)"
    read -rp "Choice: " m_choice

    # Setting Let's Encrypt as default (Better than ZeroSSL)
    "$ACME_SCRIPT" --set-default-ca --server letsencrypt &> /dev/null
    "$ACME_SCRIPT" --register-account -m "$user_email" &> /dev/null

    # Freeing ports
    local port=$([[ "$m_choice" == "1" ]] && echo "80" || echo "443")
    local pids=$(lsof -t -i:"$port" -sTCP:LISTEN)
    if [[ -n "$pids" ]]; then
        systemctl stop nginx apache2 x-ui 3x-ui marzban 2>/dev/null
        kill -9 $pids 2>/dev/null
        sleep 2
    fi

    local mode_flag=$([[ "$m_choice" == "1" ]] && echo "--standalone" || echo "--alpn")
    
    log_info "Requesting SSL for $domain via Let's Encrypt..."
    if "$ACME_SCRIPT" --issue -d "$domain" "$mode_flag" --force; then
        local cp="$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
        local kp="$HOME/.acme.sh/${domain}_ecc/${domain}.key"
        
        if [[ "$p_choice" == "1" ]]; then
            mkdir -p /var/lib/marzban/certs
            cp "$cp" /var/lib/marzban/certs/fullchain.pem && cp "$kp" /var/lib/marzban/certs/key.pem
            docker restart marzban 2>/dev/null
        else
            mkdir -p "/root/certs/$domain"
            cp "$cp" "/root/certs/$domain/public.crt" && cp "$kp" "/root/certs/$domain/private.key"
            echo -e "${GREEN}Certs saved in /root/certs/$domain/${NC}"
        fi
        log_info "SSL Issued Successfully!"
    else
        log_err "Failed. Make sure Cloudflare Proxy is OFF and Port $port is open in Cloud Console."
    fi
    systemctl start nginx x-ui 3x-ui 2>/dev/null
}

show_menu() {
    clear
    echo -e "${CYAN}==============================================${NC}"
    echo -e "      MRZ SSL Manager v2.5 | ReasModeUs"
    echo -e "${CYAN}==============================================${NC}"
    echo "1) Request New Certificate"
    echo "2) List All Certificates"
    echo "3) Delete a Certificate"
    echo "0) Exit"
    read -rp "Option: " opt
    case $opt in
        1) issue_cert ;;
        2) "$ACME_SCRIPT" --list; read -p "Press Enter..."; show_menu ;;
        3) read -rp "Domain: " d; "$ACME_SCRIPT" --remove -d "$d"; rm -rf "$HOME/.acme.sh/${d}_ecc"; show_menu ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

install_deps
[[ ! -f "$SCRIPT_PATH" ]] && cp "$0" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
show_menu
