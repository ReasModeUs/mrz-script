#!/bin/bash
# MRZ SSL Manager v2.3 - Extreme Port Release
SCRIPT_PATH="/usr/local/bin/mrz-ssl"
LOG_FILE="/var/log/mrz-ssl.log"
ACME_SCRIPT="$HOME/.acme.sh/acme.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO] $1${NC}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$LOG_FILE"; }
log_err() { echo -e "${RED}[ERROR] $1${NC}"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1" >> "$LOG_FILE"; }

stop_services() {
    local port=$1
    local pids=$(lsof -t -i:"$port" -sTCP:LISTEN)
    if [[ -n "$pids" ]]; then
        log_info "Port $port is busy. Terminating processes..."
        systemctl stop nginx apache2 x-ui 3x-ui marzban 2>/dev/null
        for pid in $pids; do kill -9 "$pid" 2>/dev/null; done
        sleep 2
    fi
}

issue_cert() {
    local domain=$1; local panel=$2; local method=$3
    [[ "$method" == "1" ]] && stop_services 80 || stop_services 443
    local mode=$([[ "$method" == "1" ]] && echo "--standalone" || echo "--alpn")

    log_info "Issuing cert for $domain..."
    "$ACME_SCRIPT" --register-account -m "admin@$domain" --server zerossl &> /dev/null
    
    if "$ACME_SCRIPT" --issue -d "$domain" "$mode" --force; then
        local cp="$HOME/.acme.sh/${domain}_ecc/fullchain.cer"
        local kp="$HOME/.acme.sh/${domain}_ecc/${domain}.key"
        if [[ "$panel" == "1" ]]; then
            mkdir -p /var/lib/marzban/certs
            cp "$cp" /var/lib/marzban/certs/fullchain.pem && cp "$kp" /var/lib/marzban/certs/key.pem
            docker restart marzban 2>/dev/null
        else
            mkdir -p "/root/certs/$domain"
            cp "$cp" "/root/certs/$domain/public.crt" && cp "$kp" "/root/certs/$domain/private.key"
        fi
        log_info "Success!"
    else
        log_err "Failed. Check Cloudflare Proxy (must be OFF) or Firewall Port $port."
    fi
    systemctl start x-ui 3x-ui nginx marzban 2>/dev/null
}

show_menu() {
    clear
    echo -e "${CYAN}MRZ SSL v2.3 | Hetzner & X-UI Ready${NC}"
    echo "1) Get Certificate"
    echo "2) List All"
    echo "0) Exit"
    read -rp "Option: " opt
    [[ "$opt" == "1" ]] && {
        read -rp "Domain: " d
        echo "1) Marzban 2) X-UI"; read -rp "Panel: " p
        echo "1) Method 80 2) Method 443"; read -rp "Method: " m
        issue_cert "$d" "$p" "$m"
    } || exit
}

install_dependencies() {
    apt-get update -qq && apt-get install -y socat lsof curl 2>/dev/null
    [[ ! -f "$ACME_SCRIPT" ]] && curl -s https://get.acme.sh | sh &>/dev/null
}

install_dependencies
show_menu
