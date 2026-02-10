#!/bin/bash

# ==========================================================
# MRZ SSL Manager
# Version: 2.1 (Added TLS-ALPN Support)
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

# Check Root
[[ $EUID -ne 0 ]] && echo -e "${RED}Error: This script must be run as root.${NC}" && exit 1

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$LOG_FILE"; }
log_warn() { echo -e "${YELLOW}[WARN] $1${NC}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1" >> "$LOG_FILE"; }
log_err() { echo -e "${RED}[ERROR] $1${NC}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$LOG_FILE"; }

install_dependencies() {
    if ! command -v socat &> /dev/null || ! command -v lsof &> /dev/null; then
        log_info "Installing dependencies..."
        apt-get update -qq && apt-get install -y socat lsof curl tar cron &> /dev/null
    fi
    if [[ ! -f "$ACME_SCRIPT" ]]; then
        log_info "Installing acme.sh..."
        curl -s https://get.acme.sh | sh &> /dev/null
    fi
}

# New: Improved port checker for both 80 and 443
stop_conflicting_services() {
    local port=$1
    local conflict_pid
    conflict_pid=$(lsof -t -i:"$port" -sTCP:LISTEN)

    if [[ -n "$conflict_pid" ]]; then
        local process_name
        process_name=$(ps -p "$conflict_pid" -o comm=)
        log_warn "Port $port is used by: $process_name. Stopping it..."
        
        systemctl stop nginx apache2 2>/dev/null
        # Force kill if still alive
        kill -9 "$conflict_pid" 2>/dev/null
        sleep 2
    fi
}

deploy_marzban() {
    local cert=$1; local key=$2; local target="/var/lib/marzban/certs"
    mkdir -p "$target"
    cp "$cert" "$target/fullchain.pem" && cp "$key" "$target/key.pem"
    if command -v docker &> /dev/null; then
        docker restart marzban &> /dev/null
        log_info "Marzban restarted."
    fi
}

deploy_generic() {
    local cert=$1; local key=$2; local target="/root/certs"
    mkdir -p "$target"
    cp "$cert" "$target/public.crt" && cp "$key" "$target/private.key"
    chmod 644 "$target/public.crt" "$target/private.key"
    echo -e "\n${CYAN}>>> Certs saved in: $target${NC}\n"
}

issue_cert() {
    local domain=$1; local panel=$2; local method=$3
    
    # Method 1 = Port 80 (standalone), Method 2 = Port 443 (alpn)
    if [[ "$method" == "1" ]]; then
        stop_conflicting_services 80
        local mode_flag="--standalone"
    else
        stop_conflicting_services 443
        local mode_flag="--alpn"
    fi

    log_info "Requesting cert for $domain via $( [[ "$method" == "1" ]] && echo 'Port 80' || echo 'Port 443' )..."
    "$ACME_SCRIPT" --register-account -m "admin@$domain" --server zerossl &> /dev/null
    
    if "$ACME_SCRIPT" --issue -d "$domain" "$mode_flag" --force; then
        local cert_path="$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
        local key_path="$HOME/.acme.sh/${domain}_ecc/${domain}.key"
        
        [[ "$panel" == "1" ]] && deploy_marzban "$cert_path" "$key_path" || deploy_generic "$cert_path" "$key_path"
        systemctl start nginx 2>/dev/null
    else
        log_err "Issuance failed. Check DNS, Cloudflare (Proxy OFF), and Firewall."
        systemctl start nginx 2>/dev/null
    fi
}

uninstall_script() {
    read -rp "Uninstall MRZ-SSL? (y/n): " confirm
    [[ "$confirm" == "y" ]] && rm -f "$SCRIPT_PATH" && echo "Uninstalled." && exit 0
}

show_menu() {
    clear
    echo -e "${CYAN}==============================================${NC}"
    echo -e "      MRZ SSL Manager  |  v2.1"
    echo -e "      ${YELLOW}Method: HTTP(80) & TLS(443)${NC}"
    echo -e "${CYAN}==============================================${NC}"
    echo -e "${GREEN}1)${NC} Get New Certificate"
    echo -e "${GREEN}2)${NC} View Logs"
    echo -e "${GREEN}3)${NC} Renew All Certificates"
    echo -e "${GREEN}4)${NC} Delete a Certificate"
    echo -e "${RED}5) Uninstall Script${NC}"
    echo -e "${YELLOW}0) Exit${NC}"
    echo -e "${CYAN}==============================================${NC}"
    read -rp "Select Option: " opt

    case $opt in
        1)
            read -rp "Enter Domain: " domain
            echo -e "\nStep 1: Choose Panel\n1) Marzban\n2) Sanaei/PasarGuard/Other"
            read -rp "Choice: " p_choice
            echo -e "\nStep 2: Choose Validation Method\n1) Port 80 (Standard)\n2) Port 443 (ALPN - use if Port 80 is blocked)"
            read -rp "Choice: " m_choice
            issue_cert "$domain" "$p_choice" "$m_choice"
            ;;
        2) tail -n 20 "$LOG_FILE"; read -p "Press Enter..."; show_menu ;;
        3) "$ACME_SCRIPT" --cron --force; show_menu ;;
        4) read -rp "Domain to remove: " d; "$ACME_SCRIPT" --remove -d "$d" &>/dev/null; rm -rf "$HOME/.acme.sh/${d}_ecc"; show_menu ;;
        5) uninstall_script ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

if [[ ! -f "$SCRIPT_PATH" ]] || [[ "$(realpath "$0")" != "$SCRIPT_PATH" ]]; then
    cp "$0" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
fi

install_dependencies
show_menu
