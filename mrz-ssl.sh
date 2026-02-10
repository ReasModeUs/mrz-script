#!/bin/bash

# ==========================================================
# MRZ SSL Manager
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

# --- Helper Functions ---

log_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
    echo -e "${GREEN}$msg${NC}"
    echo "$msg" >> "$LOG_FILE"
}

log_warn() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1"
    echo -e "${YELLOW}$msg${NC}"
    echo "$msg" >> "$LOG_FILE"
}

log_err() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1"
    echo -e "${RED}$msg${NC}"
    echo "$msg" >> "$LOG_FILE"
}

install_dependencies() {
    if ! command -v socat &> /dev/null || ! command -v lsof &> /dev/null; then
        echo -e "${CYAN}Installing dependencies...${NC}"
        apt-get update -qq && apt-get install -y socat lsof curl tar cron &> /dev/null
    fi

    if [[ ! -f "$ACME_SCRIPT" ]]; then
        echo -e "${CYAN}Installing acme.sh submodule...${NC}"
        curl -s https://get.acme.sh | sh &> /dev/null
    fi
}

check_port_80() {
    local conflict_pid
    conflict_pid=$(lsof -t -i:80 -sTCP:LISTEN)

    if [[ -n "$conflict_pid" ]]; then
        local process_name
        process_name=$(ps -p "$conflict_pid" -o comm=)
        log_warn "Port 80 is used by: $process_name (PID: $conflict_pid). Stopping it momentarily..."
        
        if systemctl is-active --quiet nginx; then
            systemctl stop nginx
        elif systemctl is-active --quiet apache2; then
            systemctl stop apache2
        else
            kill -9 "$conflict_pid"
        fi
        sleep 2
    fi
}

deploy_marzban() {
    local cert=$1
    local key=$2
    local target="/var/lib/marzban/certs"
    
    mkdir -p "$target"
    cp "$cert" "$target/fullchain.pem"
    cp "$key" "$target/key.pem"
    
    if command -v docker &> /dev/null; then
        docker restart marzban &> /dev/null
        log_info "Certificate installed & Marzban restarted."
    else
        log_warn "Certificate copied, but Marzban docker not found."
    fi
}

deploy_generic() {
    local cert=$1
    local key=$2
    local target="/root/certs"
    
    mkdir -p "$target"
    cp "$cert" "$target/public.crt"
    cp "$key" "$target/private.key"
    chmod 644 "$target/public.crt"
    chmod 644 "$target/private.key"
    
    echo -e "\n${CYAN}>>> SUCCESS! DETAILS BELOW:${NC}"
    echo -e "Public Cert : ${YELLOW}$target/public.crt${NC}"
    echo -e "Private Key : ${YELLOW}$target/private.key${NC}"
    echo -e "${CYAN}Copy these paths to your panel settings.${NC}\n"
}

issue_cert() {
    local domain=$1
    local panel=$2

    check_port_80
    
    echo -e "${CYAN}Requesting certificate for $domain...${NC}"
    "$ACME_SCRIPT" --register-account -m "admin@$domain" --server zerossl &> /dev/null
    
    if "$ACME_SCRIPT" --issue -d "$domain" --standalone --force; then
        local cert_path="$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
        local key_path="$HOME/.acme.sh/${domain}_ecc/${domain}.key"
        
        if [[ "$panel" == "1" ]]; then
            deploy_marzban "$cert_path" "$key_path"
        else
            deploy_generic "$cert_path" "$key_path"
        fi
        
        systemctl start nginx 2>/dev/null
    else
        log_err "Certificate generation failed. Check Port 80 or DNS."
        systemctl start nginx 2>/dev/null
    fi
}

uninstall_script() {
    read -p "Are you sure you want to remove MRZ-SSL? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        rm -f "$SCRIPT_PATH"
        echo -e "${GREEN}Script uninstalled successfully.${NC}"
        exit 0
    else
        echo "Cancelled."
    fi
}

show_menu() {
    clear
    echo -e "${CYAN}==============================================${NC}"
    echo -e "      MRZ SSL Manager  |  v2.0"
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
            echo -e "\nWhich Panel?"
            echo "1) Marzban (Auto Install)"
            echo "2) Sanaei / PasarGuard / Other"
            read -rp "Select [1-2]: " p_choice
            issue_cert "$domain" "$p_choice"
            ;;
        2)
            echo -e "${CYAN}--- Last 20 Logs ---${NC}"
            tail -n 20 "$LOG_FILE"
            echo -e "${CYAN}--------------------${NC}"
            read -p "Press Enter to continue..."
            show_menu
            ;;
        3)
            "$ACME_SCRIPT" --cron --force
            read -p "Renewal done. Press Enter..."
            show_menu
            ;;
        4)
            read -rp "Enter Domain to remove: " domain
            "$ACME_SCRIPT" --remove -d "$domain" &>/dev/null
            rm -rf "$HOME/.acme.sh/${domain}_ecc"
            echo "Deleted."
            sleep 1
            show_menu
            ;;
        5)
            uninstall_script
            ;;
        0)
            echo "Bye!"
            exit 0
            ;;
        *)
            show_menu
            ;;
    esac
}

# --- Install & Run ---

if [[ ! -f "$SCRIPT_PATH" ]] || [[ "$(realpath "$0")" != "$SCRIPT_PATH" ]]; then
    cp "$0" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH"
fi

install_dependencies

if [[ $# -gt 0 ]]; then
    case $1 in
        new) issue_cert "$2" "2" ;;
        logs) tail -n 50 "$LOG_FILE" ;;
        uninstall) uninstall_script ;;
        *) show_menu ;;
    esac
else
    show_menu
fi
