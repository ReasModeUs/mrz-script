#!/bin/bash

# ==========================================================
# MRZ SSL Manager - v2.8 (Full Auto Marzban)
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

# --- Marzban Smart Automator ---
auto_configure_marzban() {
    log_info "Starting auto-configuration for Marzban..."
    
    # 1. Finding Marzban directory (where docker-compose.yml and .env are)
    local marzban_path=""
    local possible_paths=("/opt/marzban" "/var/lib/marzban" "/root/marzban" "$(pwd)")
    
    for path in "${possible_paths[@]}"; do
        if [[ -f "$path/.env" && -f "$path/docker-compose.yml" ]]; then
            marzban_path="$path"
            break
        fi
    done

    if [[ -z "$marzban_path" ]]; then
        marzban_path=$(find / -name "docker-compose.yml" -exec grep -l "marzban" {} + | xargs -I {} dirname {} | head -n 1)
    fi

    if [[ -n "$marzban_path" ]]; then
        log_info "Marzban detected at: $marzban_path"
        
        # 2. Backup and Update .env file
        cp "$marzban_path/.env" "$marzban_path/.env.bak"
        
        # Remove existing SSL lines to avoid duplicates
        sed -i '/UVICORN_SSL_CERTFILE/d' "$marzban_path/.env"
        sed -i '/UVICORN_SSL_KEYFILE/d' "$marzban_path/.env"
        
        # Add new SSL configurations
        echo 'UVICORN_SSL_CERTFILE="/var/lib/marzban/certs/fullchain.pem"' >> "$marzban_path/.env"
        echo 'UVICORN_SSL_KEYFILE="/var/lib/marzban/certs/key.pem"' >> "$marzban_path/.env"
        
        log_info ".env file updated and backed up."

        # 3. Restarting Marzban using Docker Compose
        log_info "Restarting Marzban to apply changes..."
        cd "$marzban_path" || return
        docker compose up -d || docker-compose up -d
        log_info "Marzban is now running on HTTPS!"
    else
        log_err "Marzban installation directory not found. Please update .env manually."
    fi
}

issue_cert() {
    clear
    read -rp "Enter Domain: " domain
    read -rp "Enter Email: " user_email
    [[ -z "$user_email" ]] && user_email="admin@$domain"

    echo -e "\nChoose Panel:\n1) Marzban (Fully Automated)\n2) Sanaei/PasarGuard/Other"
    read -rp "Choice: " p_choice

    # Standard Issue Logic (Same as v2.5 but better)
    "$ACME_SCRIPT" --set-default-ca --server letsencrypt &> /dev/null
    "$ACME_SCRIPT" --register-account -m "$user_email" &> /dev/null

    # Stopping services to free Port 80
    systemctl stop nginx x-ui 3x-ui marzban 2>/dev/null
    local pids=$(lsof -t -i:80 -sTCP:LISTEN)
    [[ -n "$pids" ]] && kill -9 $pids 2>/dev/null

    if "$ACME_SCRIPT" --issue -d "$domain" --standalone --force; then
        local cp="$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
        local kp="$HOME/.acme.sh/${domain}_ecc/${domain}.key"
        
        if [[ "$p_choice" == "1" ]]; then
            # Copy files to Marzban standard cert path
            mkdir -p /var/lib/marzban/certs
            cp "$cp" /var/lib/marzban/certs/fullchain.pem
            cp "$kp" /var/lib/marzban/certs/key.pem
            # Run the Auto-Configurator
            auto_configure_marzban
        else
            mkdir -p "/root/certs/$domain"
            cp "$cp" "/root/certs/$domain/public.crt"
            cp "$kp" "/root/certs/$domain/private.key"
            log_info "Success! Certs saved in /root/certs/$domain/"
        fi
    else
        log_err "SSL Request failed. Check your DNS/Cloudflare."
    fi
    systemctl start nginx x-ui 3x-ui 2>/dev/null
}

show_menu() {
    clear
    echo -e "${CYAN}==============================================${NC}"
    echo -e "      MRZ SSL Manager v2.8 (Full Auto) "
    echo -e "${CYAN}==============================================${NC}"
    echo "1) Get New Certificate"
    echo "2) List All Certificates"
    echo "0) Exit"
    read -rp "Option: " opt
    case $opt in
        1) issue_cert ;;
        2) "$ACME_SCRIPT" --list; read -p "Press Enter..."; show_menu ;;
        0) exit 0 ;;
        *) show_menu ;;
    esac
}

# Install Deps
apt-get update -qq && apt-get install -y socat lsof curl 2>/dev/null
[[ ! -f "$ACME_SCRIPT" ]] && curl -s https://get.acme.sh | sh &>/dev/null
[[ ! -f "$SCRIPT_PATH" ]] && cp "$0" "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH"
show_menu
