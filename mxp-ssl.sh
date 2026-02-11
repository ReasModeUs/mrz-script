#!/bin/bash

# ==========================================================
# MXP SSL Manager (Marzban - X-UI - PasarGuard)
# Version: 1.0.2
# Copyright (c) 2026 ReasModeUs
# GitHub: https://github.com/ReasModeUs
# ==========================================================

# Command to run: mxp
COMMAND_NAME="mxp"
SCRIPT_PATH="/usr/local/bin/$COMMAND_NAME"
LOG_FILE="/var/log/mxp-ssl.log"
ACME_SCRIPT="$HOME/.acme.sh/acme.sh"
GITHUB_RAW="https://raw.githubusercontent.com/ReasModeUs/mrz-script/main/mxp-ssl.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# --- Initial Checks ---
[[ $EUID -ne 0 ]] && echo -e "${RED}Error: Root access required.${NC}" && exit 1

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$LOG_FILE"; }
log_err() { echo -e "${RED}[ERROR] $1${NC}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$LOG_FILE"; }

# --- Panel Automations ---

deploy_marzban() {
    local domain=$1; local cert=$2; local key=$3
    local HOST_CERT_DIR="/var/lib/marzban/certs"
    mkdir -p "$HOST_CERT_DIR"
    cp "$cert" "$HOST_CERT_DIR/fullchain.pem"
    cp "$key" "$HOST_CERT_DIR/key.pem"
    
    local env_file=""
    for path in "/opt/marzban/.env" "/var/lib/marzban/.env" "/root/marzban/.env"; do
        [[ -f "$path" ]] && env_file="$path" && break
    done

    if [[ -n "$env_file" ]]; then
        sed -i '/UVICORN_SSL_CERTFILE/d' "$env_file"
        sed -i '/UVICORN_SSL_KEYFILE/d' "$env_file"
        printf "\nUVICORN_SSL_CERTFILE=\"/var/lib/marzban/certs/fullchain.pem\"\nUVICORN_SSL_KEYFILE=\"/var/lib/marzban/certs/key.pem\"\n" >> "$env_file"
        
        # Check if docker or normal install
        cd "$(dirname "$env_file")" 
        docker compose up -d 2>/dev/null || marzban restart 2>/dev/null
        log_info "Marzban certs deployed and service restarted."
    fi
}

deploy_pasarguard() {
    local cert=$1; local key=$2
    # Standard location for PasarGuard
    local PG_DIR="/var/lib/pasarguard/certs"
    local PG_BACKUP="/root/pasarguard_certs"
    
    mkdir -p "$PG_DIR" "$PG_BACKUP"
    
    # Copy to service directory
    cp "$cert" "$PG_DIR/fullchain.pem"
    cp "$key" "$PG_DIR/key.pem"
    
    # Copy to backup just in case
    cp "$cert" "$PG_BACKUP/fullchain.pem"
    cp "$key" "$PG_BACKUP/key.pem"

    # Try restart
    if systemctl is-active --quiet pasarguard; then
        systemctl restart pasarguard
        log_info "PasarGuard service restarted."
    else
        log_info "Certs saved to: $PG_DIR (Please map this volume if using Docker)"
    fi
    echo -e "${YELLOW}Backup certs also saved in: $PG_BACKUP${NC}"
}

# --- Core Functions ---

issue_cert() {
    clear
    local domain_list=""
    local email=""
    
    # Input Validation: Domain
    while [[ -z "$domain_list" ]]; do
        read -rp "Enter Domain(s) (separate with comma for multi-domain): " domain_list
        [[ -z "$domain_list" ]] && echo -e "${RED}Domain cannot be empty.${NC}"
    done

    # Input Validation: Email
    while [[ -z "$email" ]]; do
        read -rp "Enter Email: " email
        if [[ -z "$email" ]]; then 
            # Auto-generate email based on first domain
            local first_dom=$(echo "$domain_list" | cut -d',' -f1)
            email="admin@$first_dom"
            echo -e "${YELLOW}Using default email: $email${NC}"
        fi
    done

    echo -e "\nChoose Your Panel:\n1) Marzban (M)\n2) PasarGuard (P)\n3) X-UI / Sanaei (X)"
    read -rp "Choice: " p_choice

    echo -e "\nChoose Method:\n1) Port 80 (Standard)\n2) Port 443 (ALPN)"
    read -rp "Choice: " m_choice

    "$ACME_SCRIPT" --set-default-ca --server letsencrypt &> /dev/null
    "$ACME_SCRIPT" --register-account -m "$email" &> /dev/null

    local port=$([[ "$m_choice" == "1" ]] && echo "80" || echo "443")
    
    # Free up ports
    systemctl stop nginx x-ui 3x-ui marzban pasarguard 2>/dev/null
    fuser -k "$port/tcp" 2>/dev/null
    sleep 1

    local mode_flag=$([[ "$m_choice" == "1" ]] && echo "--standalone" || echo "--alpn")

    # Handle Multi-Domain (SAN)
    local acme_domain_args=""
    IFS=',' read -ra DOMAINS <<< "$domain_list"
    local main_domain="${DOMAINS[0]}"
    
    for d in "${DOMAINS[@]}"; do
        acme_domain_args="$acme_domain_args -d $d"
    done

    log_info "Issuing certificate for: $domain_list ..."
    
    # Run ACME
    if "$ACME_SCRIPT" --issue $acme_domain_args "$mode_flag" --force; then
        local cp="$HOME/.acme.sh/${main_domain}_ecc/fullchain.cer"
        local kp="$HOME/.acme.sh/${main_domain}_ecc/${main_domain}.key"
        
        case $p_choice in
            1) deploy_marzban "$main_domain" "$cp" "$kp" ;;
            2) deploy_pasarguard "$cp" "$kp" ;;
            *) 
                mkdir -p "/root/certs/$main_domain"
                cp "$cp" "/root/certs/$main_domain/public.crt"
                cp "$kp" "/root/certs/$main_domain/private.key"
                echo -e "${GREEN}Certs saved in /root/certs/$main_domain/${NC}"
                ;;
        esac
    else
        log_err "SSL issuance failed. Check DNS A records or Firewall."
    fi
    
    # Restart services
    systemctl start x-ui 3x-ui nginx pasarguard 2>/dev/null
}

revoke_cert() {
    clear
    echo -e "${YELLOW}Existing Certificates:${NC}"
    "$ACME_SCRIPT" --list
    echo ""
    
    local domain=""
    while [[ -z "$domain" ]]; do
        read -rp "Enter Domain to Revoke: " domain
        [[ -z "$domain" ]] && echo -e "${RED}Please enter a domain.${NC}"
    done

    read -rp "Are you sure you want to delete SSL for $domain? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        "$ACME_SCRIPT" --revoke -d "$domain" --ecc
        "$ACME_SCRIPT" --remove -d "$domain" --ecc
        rm -rf "/root/certs/$domain"
        rm -rf "$HOME/.acme.sh/${domain}_ecc"
        log_info "Certificate for $domain revoked and deleted."
    else
        echo "Operation cancelled."
    fi
}

update_script() {
    log_info "Checking for updates..."
    curl -Ls "$GITHUB_RAW" -o "$SCRIPT_PATH.tmp"
    if [[ -f "$SCRIPT_PATH.tmp" ]]; then
        mv "$SCRIPT_PATH.tmp" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        log_info "Updated to v1.0.2. Please restart script."
        exit 0
    else
        log_err "Update failed."
    fi
}

uninstall_script() {
    read -rp "Uninstall MXP-SSL? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        rm -f "$SCRIPT_PATH"
        echo -e "${GREEN}MXP-SSL removed.${NC}"
        exit 0
    fi
}

show_menu() {
    clear
    echo -e "${CYAN}==============================================${NC}"
    echo -e "      MXP SSL Manager  |  v1.0.2"
    echo -e "      [M]arzban - [X]-UI - [P]asarGuard"
    echo -e "${CYAN}==============================================${NC}"
    echo "1) Request New Certificate (Multi-Domain Supported)"
    echo "2) Revoke/Delete Certificate"
    echo "3) List All Certificates"
    echo "4) Renew All Certificates"
    echo "5) Update Script"
    echo "6) Uninstall Script"
    echo "0) Exit"
    echo -e "${CYAN}==============================================${NC}"
    read -rp "Select Option: " opt
    case $opt in
        1) issue_cert ;;
        2) revoke_cert; read -p "Press Enter..."; show_menu ;;
        3) "$ACME_SCRIPT" --list; read -p "Press Enter..."; show_menu ;;
        4) "$ACME_SCRIPT" --cron --force; read -p "Done. Press Enter..."; show_menu ;;
        5) update_script ;;
        6) uninstall_script ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

# --- Initial Install & Sync ---
apt-get update -qq && apt-get install -y socat lsof curl &>/dev/null
[[ ! -f "$ACME_SCRIPT" ]] && curl -s https://get.acme.sh | sh &>/dev/null

if [[ ! -f "$SCRIPT_PATH" ]] || [[ "$(realpath "$0")" != "$SCRIPT_PATH" ]]; then
    cp "$0" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
fi

show_menu
