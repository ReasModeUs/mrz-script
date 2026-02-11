#!/bin/bash

# ==========================================================
# MXP SSL Manager (Marzban - X-UI - PasarGuard)
# Version: 1.0.3
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
        
        cd "$(dirname "$env_file")" 
        docker compose up -d 2>/dev/null || marzban restart 2>/dev/null
        log_info "Marzban certs deployed and service restarted."
    fi
}

deploy_pasarguard() {
    local cert=$1; local key=$2
    local PG_DIR="/var/lib/pasarguard/certs"
    local PG_BACKUP="/root/pasarguard_certs"
    
    mkdir -p "$PG_DIR" "$PG_BACKUP"
    cp "$cert" "$PG_DIR/fullchain.pem"
    cp "$key" "$PG_DIR/key.pem"
    cp "$cert" "$PG_BACKUP/fullchain.pem"
    cp "$key" "$PG_BACKUP/key.pem"

    if systemctl is-active --quiet pasarguard; then
        systemctl restart pasarguard
        log_info "PasarGuard service restarted."
    else
        log_info "Certs saved to: $PG_DIR"
    fi
}

# --- Core Functions ---

issue_cert() {
    local mode=$1  # 'single' or 'multi'
    clear
    local domain_list=""
    local email=""

    # --- INPUT SECTION ---
    if [[ "$mode" == "single" ]]; then
        echo -e "${CYAN}--- Single Domain Mode ---${NC}"
        while [[ -z "$domain_list" ]]; do
            read -rp "Enter Domain (e.g., panel.site.com): " domain_list
            [[ -z "$domain_list" ]] && echo -e "${RED}Domain cannot be empty.${NC}"
        done
    elif [[ "$mode" == "multi" ]]; then
        echo -e "${CYAN}--- Multi-Domain (SAN) Mode ---${NC}"
        echo -e "${YELLOW}Note:${NC} You will get ONE file valid for ALL domains."
        echo -e "Example: ${GREEN}sub1.site.com,sub2.site.com${NC}"
        echo ""
        while [[ -z "$domain_list" ]]; do
            read -rp "Enter Domains: " domain_list
            domain_list=$(echo "$domain_list" | tr -d ' ')
            [[ -z "$domain_list" ]] && echo -e "${RED}Domains cannot be empty.${NC}"
        done
    fi

    # --- EMAIL SECTION ---
    while [[ -z "$email" ]]; do
        read -rp "Enter Email: " email
        if [[ -z "$email" ]]; then 
            local first_dom=$(echo "$domain_list" | cut -d',' -f1)
            email="admin@$first_dom"
            echo -e "${YELLOW}Using default email: $email${NC}"
        fi
    done

    # --- PANEL SELECTION ---
    echo -e "\nChoose Your Panel Automation:\n1) Marzban (M)\n2) PasarGuard (P)\n3) None (Just Save Files)"
    read -rp "Choice: " p_choice

    echo -e "\nChoose Method:\n1) Port 80 (Standard)\n2) Port 443 (ALPN)"
    read -rp "Choice: " m_choice

    # --- EXECUTION ---
    "$ACME_SCRIPT" --set-default-ca --server letsencrypt &> /dev/null
    "$ACME_SCRIPT" --register-account -m "$email" &> /dev/null

    local port=$([[ "$m_choice" == "1" ]] && echo "80" || echo "443")
    
    # Stop conflicting services
    systemctl stop nginx x-ui 3x-ui marzban pasarguard 2>/dev/null
    fuser -k "$port/tcp" 2>/dev/null
    sleep 1

    local mode_flag=$([[ "$m_choice" == "1" ]] && echo "--standalone" || echo "--alpn")

    # Build ACME arguments
    local acme_domain_args=""
    IFS=',' read -ra DOMAINS <<< "$domain_list"
    local main_domain="${DOMAINS[0]}"
    
    for d in "${DOMAINS[@]}"; do
        acme_domain_args="$acme_domain_args -d $d"
    done

    log_info "Issuing certificate for: $domain_list ..."
    
    if "$ACME_SCRIPT" --issue $acme_domain_args "$mode_flag" --force; then
        local cp="$HOME/.acme.sh/${main_domain}_ecc/fullchain.cer"
        local kp="$HOME/.acme.sh/${main_domain}_ecc/${main_domain}.key"
        
        # 1. Automate Panel
        case $p_choice in
            1) deploy_marzban "$main_domain" "$cp" "$kp" ;;
            2) deploy_pasarguard "$cp" "$kp" ;;
        esac

        # 2. Save Copy for EVERY domain provided (So user finds them easily)
        echo -e "\n${CYAN}--- Saving Certificates ---${NC}"
        for d in "${DOMAINS[@]}"; do
            mkdir -p "/root/certs/$d"
            cp "$cp" "/root/certs/$d/public.crt"
            cp "$kp" "/root/certs/$d/private.key"
            echo -e "${GREEN}Mapped: $d -> /root/certs/$d/${NC}"
        done
        echo -e "${YELLOW}(Note: The file content is the same for all, as it includes all domains)${NC}"

    else
        log_err "SSL issuance failed. Check DNS or Firewall."
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
        read -rp "Enter Main Domain to Revoke: " domain
        [[ -z "$domain" ]] && echo -e "${RED}Please enter a domain.${NC}"
    done

    read -rp "Confirm Delete? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        "$ACME_SCRIPT" --revoke -d "$domain" --ecc
        "$ACME_SCRIPT" --remove -d "$domain" --ecc
        # Try to remove folder, user might have multiple folders now
        rm -rf "/root/certs/$domain"*
        rm -rf "$HOME/.acme.sh/${domain}_ecc"
        log_info "Revoked and deleted: $domain"
    else
        echo "Cancelled."
    fi
}

update_script() {
    log_info "Updating..."
    curl -Ls "$GITHUB_RAW" -o "$SCRIPT_PATH.tmp"
    if [[ -f "$SCRIPT_PATH.tmp" ]]; then
        mv "$SCRIPT_PATH.tmp" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        log_info "Updated to v1.0.4. Restart script."
        exit 0
    else
        log_err "Update failed."
    fi
}

uninstall_script() {
    read -rp "Uninstall MXP-SSL? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        rm -f "$SCRIPT_PATH"
        echo -e "${GREEN}Removed.${NC}"
        exit 0
    fi
}

show_menu() {
    clear
    echo -e "${CYAN}==============================================${NC}"
    echo -e "      MXP SSL Manager  |  v1.0.4"
    echo -e "      [M]arzban - [X]-UI - [P]asarGuard"
    echo -e "${CYAN}==============================================${NC}"
    echo "1) Single Domain SSL (e.g. site.com)"
    echo "2) Multi-Domain SSL (One cert for all domains)"
    echo "3) Revoke & Delete Certificate"
    echo "4) List All Certificates"
    echo "5) Renew All Certificates"
    echo "6) Update Script"
    echo "7) Uninstall"
    echo "0) Exit"
    echo -e "${CYAN}==============================================${NC}"
    read -rp "Option: " opt
    case $opt in
        1) issue_cert "single" ;;
        2) issue_cert "multi" ;;
        3) revoke_cert; read -p "Press Enter..."; show_menu ;;
        4) "$ACME_SCRIPT" --list; read -p "Press Enter..."; show_menu ;;
        5) "$ACME_SCRIPT" --cron --force; read -p "Done..."; show_menu ;;
        6) update_script ;;
        7) uninstall_script ;;
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
