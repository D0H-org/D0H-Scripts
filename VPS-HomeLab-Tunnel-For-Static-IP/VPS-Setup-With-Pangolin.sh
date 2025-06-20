#!/bin/bash

# VPS Homelab Gateway Setup Script (Automated)
# This script configures a VPS to act as a central gateway for a homelab via WireGuard.
# It sets up nftables for NAT and port forwarding, changes the VPS's SSH port,
# configures the WireGuard server, generates homelab client keys, and sets up Fail2Ban.
# This version also offers to install the Pangolin reverse proxy stack on the VPS.

# IMPORTANT:
# - Run this script on your VPS with root privileges (e.g., sudo ./setup_vps_gateway.sh).
# - This script will modify your SSH configuration and firewall rules.
# - Ensure you have out-of-band access (e.g., VPS console) in case of SSH issues.
# - Take a snapshot of your VPS before running this script!

# --- Configuration Variables ---
# Customize these values to match your setup.
# Network detection will attempt to fill VPS_PUBLIC_INTERFACE and VPS_PUBLIC_ENDPOINT_IPs.

# Internal WireGuard IP address of your VPS (e.g., 10.0.0.1)
VPS_WG_IPV4="10.0.0.1"
# Internal WireGuard IPv6 address of your VPS (e.g., fd42:42:42::1)
VPS_WG_IPV6="fd42:42:42::1"
# WireGuard subnet for IPv4 (e.g., 10.0.0.0/24)
WG_IPV4_SUBNET="10.0.0.0/24"
# WireGuard subnet for IPv6 (e.g., fd42:42:42::/64)
WG_IPV6_SUBNET="fd42:42:42::/64"

# WireGuard IP address of your homelab client (e.g., 10.0.0.2)
HOMELAB_WG_IPV4="10.0.0.2"
# WireGuard IPv6 address of your homelab client (e.g., fd42:42:42::2)
HOMELAB_WG_IPV6="fd42:42:42::2"

# New SSH port for the VPS itself (e.g., 9001). This frees up 22.
# Traffic to this port will go directly to the VPS SSH, NOT forwarded to homelab.
VPS_NEW_SSH_PORT="9001"

# WireGuard config file path
WG_CONFIG_FILE="/etc/wireguard/wg0.conf"

# Paths for generated keys on VPS
VPS_PRIVKEY_FILE="/etc/wireguard/vps_privatekey"
VPS_PUBKEY_FILE="/etc/wireguard/vps_publickey"
HOMELAB_PRIVKEY_FILE_ON_VPS="/etc/wireguard/homelab_privatekey_temp.txt" # Temporary, will be displayed/fetched
HOMELAB_PUBKEY_FILE_ON_VPS="/etc/wireguard/homelab_publickey_on_vps"

# Auto-detected variables (will be populated by detect_vps_network_info)
VPS_PUBLIC_INTERFACE=""
VPS_PUBLIC_ENDPOINT_IPV4=""
VPS_PUBLIC_ENDPOINT_IPV6="" # Can be empty if no IPv6 is available

# Pangolin specific variables
PANGOLIN_DIR="/opt/pangolin"
PANGOLIN_GITHUB_RAW="https://raw.githubusercontent.com/fosrl/pangolin/main" # Base URL for raw files

# --- Function Definitions ---

log_info() {
    echo -e "\n\033[1;34m[INFO]\033[0m $1"
}

log_success() {
    echo -e "\n\033[1;32m[SUCCESS]\033[0m $1"
}

log_error() {
    echo -e "\n\033[1;31m[ERROR]\033[0m $1" >&2
}

log_warning() {
    echo -e "\n\033[1;33m[WARNING]\033[0m $1" >&2
}

# Function to get user input with a default
get_input() {
    local prompt="$1"
    local default_value="$2"
    read -rp "$prompt [$default_value]: " input
    echo "${input:-$default_value}"
}

# Function to install prerequisites
install_prerequisites() {
    log_info "Installing necessary prerequisites: WireGuard, nftables, Fail2Ban, socat..."
    sudo apt update || { log_error "Failed to update package lists."; return 1; }
    sudo apt install -y wireguard wireguard-tools screen nftables fail2ban socat || { log_error "Failed to install required packages."; return 1; }
    
    # Check for Docker and Docker Compose, install if not present
    if ! command -v docker &> /dev/null; then
        log_info "Docker not found, installing Docker..."
        # Install Docker (official way)
        sudo apt install -y ca-certificates curl gnupg lsb-release
        sudo mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt update
        sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        if [ $? -ne 0 ]; then
            log_error "Failed to install Docker. Exiting."
            return 1
        fi
        log_success "Docker installed."
    else
        log_info "Docker already installed."
    fi

    # Docker Compose V2 is installed via docker-compose-plugin
    if ! command -v docker compose &> /dev/null; then # Note the space for V2
        log_error "Docker Compose Plugin not found. This should have been installed with Docker CE. Please check your Docker installation."
        return 1
    else
        log_info "Docker Compose Plugin (V2) found."
    fi

    log_success "Prerequisites installed successfully."
    return 0
}

# Function to generate WireGuard keys and save to files
# Args: <private_key_file_path> <public_key_file_path>
generate_wg_keys() {
    log_info "Generating WireGuard keys for ${2}..."
    umask 077 # Set restrictive umask
    local privkey=$(wg genkey)
    local pubkey=$(echo "${privkey}" | wg pubkey)
    echo "${privkey}" | sudo tee "${1}" > /dev/null
    echo "${pubkey}" | sudo tee "${2}" > /dev/null
    sudo chmod 600 "${1}" "${2}" # Ensure strong permissions
    umask 022 # Reset umask
    log_success "Keys generated and saved."
}

# Function to detect VPS network information
detect_vps_network_info() {
    log_info "Attempting to auto-detect VPS public network interface and IP addresses..."

    # Detect public interface (interface with default route)
    VPS_PUBLIC_INTERFACE=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $5; exit}')

    if [ -z "${VPS_PUBLIC_INTERFACE}" ]; then
        log_warning "Could not auto-detect public interface. Please enter it manually."
        VPS_PUBLIC_INTERFACE=$(get_input "Enter your VPS's public network interface (e.g., eth0, ens3)" "")
        if [ -z "${VPS_PUBLIC_INTERFACE}" ]; then
            log_error "Public interface cannot be empty. Exiting."
            exit 1
        fi
    else
        log_info "Auto-detected public interface: ${VPS_PUBLIC_INTERFACE}"
        VPS_PUBLIC_INTERFACE=$(get_input "Confirm or correct public network interface" "${VPS_PUBLIC_INTERFACE}")
    fi

    # Get IPv4 address
    VPS_PUBLIC_ENDPOINT_IPV4=$(ip -4 a show dev "${VPS_PUBLIC_INTERFACE}" 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
    if [ -z "${VPS_PUBLIC_ENDPOINT_IPV4}" ]; then
        log_warning "No IPv4 address detected on ${VPS_PUBLIC_INTERFACE}. This might be an issue if your VPS is IPv6-only or has a complex network setup."
    else
        log_info "Detected IPv4 address: ${VPS_PUBLIC_ENDPOINT_IPV4}"
    fi

    # Get IPv6 address
    VPS_PUBLIC_ENDPOINT_IPV6=$(ip -6 a show dev "${VPS_PUBLIC_INTERFACE}" 2>/dev/null | grep -oP 'inet6 \K[0-9a-fA-F:]+' | head -1 | cut -d'/' -f1)
    if [ -z "${VPS_PUBLIC_ENDPOINT_IPV6}" ]; then
        log_warning "No IPv6 address detected on ${VPS_PUBLIC_INTERFACE}. IPv6 endpoint for homelab client will not be provided."
    else
        log_info "Detected IPv6 address: ${VPS_PUBLIC_ENDPOINT_IPV6}"
    fi

    log_success "Network information detection complete."
}

# Function to configure SSH
configure_ssh() {
    log_info "Configuring SSH on VPS..."
    local sshd_config="/etc/ssh/sshd_config"
    local backup_sshd_config="${sshd_config}.bak_$(date +%Y%m%d%H%M%S)"

    if [ ! -f "${sshd_config}" ]; then
        log_error "SSHD config file not found: ${sshd_config}. Cannot change SSH port."
        return 1
    fi

    log_info "Backing up SSHD config to ${backup_sshd_config}"
    sudo cp "${sshd_config}" "${backup_sshd_config}"

    log_info "Changing SSH port to ${VPS_NEW_SSH_PORT}..."
    # Remove existing Port lines and add the new one to prevent duplicates
    sudo sed -i '/^Port /d' "${sshd_config}"
    # Add new Port directive
    echo "Port ${VPS_NEW_SSH_PORT}" | sudo tee -a "${sshd_config}" > /dev/null

    log_info "Restarting SSH service. Ensure you can connect on port ${VPS_NEW_SSH_PORT} before closing this session!"
    if sudo systemctl restart sshd; then
        log_success "SSHD service restarted. New port: ${VPS_NEW_SSH_PORT}."
    else
        log_error "Failed to restart SSHD service. Please check 'sudo systemctl status sshd' and 'sudo journalctl -xeu sshd'."
        log_error "SSH port change might have failed. Revert from backup if necessary: sudo cp ${backup_sshd_config} ${sscd_config} && sudo systemctl restart sshd"
        return 1
    fi
    return 0
}

# Function to disable UFW if active
disable_ufw() {
    log_info "Checking for active UFW firewall..."
    if sudo systemctl is-active --quiet ufw; then
        log_warning "UFW is active. It is recommended to disable UFW and rely on nftables for firewall management to avoid conflicts."
        read -rp "Do you want to disable UFW now? (y/N): " confirm_ufw_disable
        if [[ "${confirm_ufw_disable}" =~ ^[yY]$ ]]; then
            log_info "Stopping and disabling UFW..."
            sudo systemctl stop ufw
            sudo systemctl disable ufw
            log_success "UFW has been disabled."
        else
            log_warning "UFW not disabled. You might encounter firewall conflicts if UFW rules clash with nftables."
        # If UFW remains enabled, ensure its rules allow the new SSH port and WireGuard port
        fi
    else
        log_info "UFW is not active."
    fi
    return 0
}

# Function to configure nftables rules via WireGuard PostUp/PreDown
configure_nftables() {
    log_info "Configuring nftables rules in WireGuard config..."

    # Ensure IP forwarding is enabled
    log_info "Ensuring IP forwarding is enabled..."
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
    sudo sysctl -w net.ipv6.conf.all.forwarding=1 > /dev/null
    sudo sysctl -w net.ipv6.conf.default.forwarding=1 > /dev/null
    # Append to sysctl.conf only if not already present to avoid duplicates
    grep -qF "net.ipv4.ip_forward = 1" /etc/sysctl.conf || echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf > /dev/null
    grep -qF "net.ipv6.conf.all.forwarding = 1" /etc/sysctl.conf || echo "net.ipv6.conf.all.forwarding = 1" | sudo tee -a /etc/sysctl.conf > /dev/null
    grep -qF "net.ipv6.conf.default.forwarding = 1" /etc/sysctl.conf || echo "net.ipv6.conf.default.forwarding = 1" | sudo tee -a /etc/sysctl.conf > /dev/null
    sudo sysctl -p > /dev/null
    log_success "IP forwarding enabled."

    # Define PostUp and PreDown commands
    cat <<EOF > /tmp/wg_postup_rules.txt
# === nftables rules added by setup_vps_gateway.sh ===

# Delete all WireGuard-specific tables and chains to ensure a clean state upon service restart
# This ensures idempotency and avoids accumulating old rules from previous runs.
# The 'ignore errors' is for the first run where tables might not exist.
nft delete table ip wg-quick-nat-rules 2>/dev/null || true
nft delete table ip6 wg-quick-nat-rules 2>/dev/null || true
nft delete table ip wg-quick-filter-rules 2>/dev/null || true
nft delete table ip6 wg-quick-filter-rules 2>/dev/null || true

# Add new tables for our rules
nft add table ip wg-quick-nat-rules
nft add table ip6 wg-quick-nat-rules
nft add table ip wg-quick-filter-rules
nft add table ip6 wg-quick-filter-rules

# IPv4 NAT (Masquerade) for outgoing traffic from homelab
nft add chain ip wg-quick-nat-rules postrouting { type nat hook postrouting priority 100; }
nft add rule ip wg-quick-nat-rules postrouting oifname "${VPS_PUBLIC_INTERFACE}" ip saddr ${WG_IPV4_SUBNET} masquerade

# IPv6 NAT (Masquerade) for outgoing traffic from homelab
nft add chain ip6 wg-quick-nat-rules postrouting { type nat hook postrouting priority 100; }
nft add rule ip6 wg-quick-nat-rules postrouting oifname "${VPS_PUBLIC_INTERFACE}" ip6 saddr ${WG_IPV6_SUBNET} masquerade

# IPv4 MSS clamping for TCP connections
# This chain is attached to the postrouting hook in the filter base chain.
nft add chain ip wg-quick-filter-rules mangle { type filter hook postrouting priority mangle; }
nft add rule ip wg-quick-filter-rules mangle tcp flags syn tcp option maxseg size set rt mtu

# IPv6 MSS clamping for TCP connections
nft add chain ip6 wg-quick-filter-rules mangle { type filter hook postrouting priority mangle; }
nft add rule ip6 wg-quick-filter-rules mangle tcp flags syn tcp option maxseg size set rt mtu

# DNAT for specific incoming IPv4 TCP/UDP ports to homelab
# NOTE: Ports 80 (HTTP) and 443 (HTTPS) are *explicitly excluded* from these
# default forwarding rules to allow another service (e.g., a Pangolin stack)
# to bind to and manage traffic on these ports directly on the VPS.
# If you want to forward 80/443 to your homelab via this tunnel, you would need
# to manually add those rules using the homelab's port management script or
# directly edit nftables.
nft add chain ip wg-quick-nat-rules prerouting { type nat hook prerouting priority -100; }

# DNS (UDP/TCP 53)
nft add rule ip wg-quick-nat-rules prerouting iifname "${VPS_PUBLIC_INTERFACE}" tcp dport 53 dnat to ${HOMELAB_WG_IPV4}
nft add rule ip wg-quick-nat-rules prerouting iifname "${VPS_PUBLIC_INTERFACE}" udp dport 53 dnat to ${HOMELAB_WG_IPV4}

# Other specified ports/ranges (IPv4 TCP)
nft add rule ip wg-quick-nat-rules prerouting iifname "${VPS_PUBLIC_INTERFACE}" tcp dport { 20-52, 54-79, 81-442, 444-9000 } dnat to ${HOMELAB_WG_IPV4}

# Other specified ports/ranges (IPv4 UDP)
nft add rule ip wg-quick-nat-rules prerouting iifname "${VPS_PUBLIC_INTERFACE}" udp dport { 20-52, 54-79, 81-442, 444-9000 } dnat to ${HOMELAB_WG_IPV4}


# DNAT for specific incoming IPv6 TCP/UDP ports to homelab
nft add chain ip6 wg-quick-nat-rules prerouting { type nat hook prerouting priority -100; }
# DNS (UDP/TCP 53)
nft add rule ip6 wg-quick-nat-rules prerouting iifname "${VPS_PUBLIC_INTERFACE}" tcp dport 53 dnat to ${HOMELAB_WG_IPV6}
nft add rule ip6 wg-quick-nat-rules prerouting iifname "${VPS_PUBLIC_INTERFACE}" udp dport 53 dnat to ${HOMELAB_WG_IPV6}

# Other specified ports/ranges (IPv6 TCP)
nft add rule ip6 wg-quick-nat-rules prerouting iifname "${VPS_PUBLIC_INTERFACE}" tcp dport { 20-52, 54-79, 81-442, 444-9000 } dnat to ${HOMELAB_WG_IPV6}

# Other specified ports/ranges (IPv6 UDP)
nft add rule ip6 wg-quick-nat-rules prerouting iifname "${VPS_PUBLIC_INTERFACE}" udp dport { 20-52, 54-79, 81-442, 444-9000 } dnat to ${HOMELAB_WG_IPV6}


# Add forwarding rules in the filter table to allow traffic between public and WG interfaces
nft add chain ip wg-quick-filter-rules forward { type filter hook forward priority 0; }
nft add rule ip wg-quick-filter-rules forward iifname "${VPS_PUBLIC_INTERFACE}" oifname "wg0" ct state related,established accept
nft add rule ip wg-quick-filter-rules forward iifname "wg0" oifname "${VPS_PUBLIC_INTERFACE}" accept

nft add chain ip6 wg-quick-filter-rules forward { type filter hook forward priority 0; }
nft add rule ip6 wg-quick-filter-rules forward iifname "${VPS_PUBLIC_INTERFACE}" oifname "wg0" ct state related,established accept
nft add rule ip6 wg-quick-filter-rules forward iifname "wg0" oifname "${VPS_PUBLIC_INTERFACE}" accept

# Allow WireGuard UDP port in INPUT chain
nft add chain ip wg-quick-filter-rules input { type filter hook input priority 0; }
nft add rule ip wg-quick-filter-rules input iifname "${VPS_PUBLIC_INTERFACE}" udp dport 51820 accept
nft add rule ip6 wg-quick-filter-rules input iifname "${VPS_PUBLIC_INTERFACE}" udp dport 51820 accept

# Allow SSH to VPS on new port (from anywhere) in INPUT chain
nft add rule ip wg-quick-filter-rules input iifname "${VPS_PUBLIC_INTERFACE}" tcp dport ${VPS_NEW_SSH_PORT} accept
nft add rule ip6 wg-quick-filter-rules input iifname "${VPS_PUBLIC_INTERFACE}" tcp dport ${VPS_NEW_SSH_PORT} accept

# Allow already established/related connections to VPS
nft add rule ip filter input ct state related,established accept
nft add rule ip6 filter input ct state related,established accept

# Drop invalid packets (general good practice)
nft add rule ip filter input ct state invalid drop
nft add rule ip6 filter input ct state invalid drop

EOF

    cat <<EOF > /tmp/wg_predown_rules.txt
# === nftables cleanup by setup_vps_gateway.sh ===
# Flush only the tables created by this script
# The 'ignore errors' is for cases where the tables might have been removed already.
nft delete table ip wg-quick-nat-rules 2>/dev/null || true
nft delete table ip6 wg-quick-nat-rules 2>/dev/null || true
nft delete table ip wg-quick-filter-rules 2>/dev/null || true
nft delete table ip6 wg-quick-filter-rules 2>/dev/null || true

# Note: The 'ct state related,established accept' and 'ct state invalid drop' rules
# added to the main 'filter' input chain are common and generally safe to keep
# even without the script managing them specifically. If you want a full revert,
# you'd need to explicitly delete those as well, but it's usually not necessary
# or recommended unless you have a very specific default firewall policy.
EOF

    log_success "nftables rules defined in temporary files."
    return 0
}

# Function to configure WireGuard server
configure_wireguard_server() {
    log_info "Configuring WireGuard server..."

    # Generate VPS keys if not exists
    if [ ! -f "${VPS_PRIVKEY_FILE}" ] || [ ! -f "${VPS_PUBKEY_FILE}" ]; then
        generate_wg_keys "${VPS_PRIVKEY_FILE}" "${VPS_PUBKEY_FILE}"
    else
        log_success "Existing VPS WireGuard keys found."
    fi

    # Generate Homelab keys if not exists
    if [ ! -f "${HOMELAB_PRIVKEY_FILE_ON_VPS}" ] || [ ! -f "${HOMELAB_PUBKEY_FILE_ON_VPS}" ]; then
        generate_wg_keys "${HOMELAB_PRIVKEY_FILE_ON_VPS}" "${HOMELAB_PUBKEY_FILE_ON_VPS}"
    else
        log_success "Existing Homelab WireGuard keys on VPS found."
    fi

    VPS_WG_PRIVATE_KEY=$(sudo cat "${VPS_PRIVKEY_FILE}")
    VPS_WG_PUBLIC_KEY=$(sudo cat "${VPS_PUBKEY_FILE}")
    HOMELAB_WG_PUBLIC_KEY=$(sudo cat "${HOMELAB_PUBKEY_FILE_ON_VPS}")

    log_info "Your VPS WireGuard Public Key: ${VPS_WG_PUBLIC_KEY}"
    log_info "Homelab Client WireGuard Public Key (generated on VPS): ${HOMELAB_WG_PUBLIC_KEY}"

    # Prepare PostUp/PreDown commands
    POSTUP_COMMANDS=$(cat /tmp/wg_postup_rules.txt | tr '\n' ';')
    PREDOWN_COMMANDS=$(cat /tmp/wg_predown_rules.txt | tr '\n' ';')

    # Create WireGuard config file
    log_info "Creating ${WG_CONFIG_FILE}..."
    sudo bash -c "cat <<EOT > ${WG_CONFIG_FILE}
[Interface]
PrivateKey = ${VPS_WG_PRIVATE_KEY}
Address = ${VPS_WG_IPV4}/32, ${VPS_WG_IPV6}/128
ListenPort = 51820 # Default WireGuard port, ensure it's open in VPS provider's firewall if any
PostUp = ${POSTUP_COMMANDS}
PreDown = ${PREDOWN_COMMANDS}

[Peer]
# Homelab Client
PublicKey = ${HOMELAB_WG_PUBLIC_KEY}
AllowedIPs = ${HOMELAB_WG_IPV4}/32, ${HOMELAB_WG_IPV6}/128
PersistentKeepalive = 25
EOT"

    sudo chmod 600 "${WG_CONFIG_FILE}"

    log_success "WireGuard server config created: ${WG_CONFIG_FILE}"

    log_info "Restarting WireGuard service..."
    if sudo systemctl restart wg-quick@wg0; then
        log_success "WireGuard service restarted successfully."
    else
        log_error "Failed to restart WireGuard service. Please check 'sudo systemctl status wg-quick@wg0'."
        log_error "You might need to revert your config from backup if issues persist."
        return 1
    fi
    return 0
}

# Function to configure Fail2Ban for SSH
configure_fail2ban() {
    log_info "Configuring Fail2Ban for SSH on port ${VPS_NEW_SSH_PORT}..."
    local jail_local_file="/etc/fail2ban/jail.local"
    local fail2ban_action_d="nftables" # Fail2Ban's action.d script for nftables

    if [ ! -f "${jail_local_file}" ]; then
        log_info "Creating ${jail_local_file}..."
        sudo cp /etc/fail2ban/jail.conf "${jail_local_file}"
    fi

    # Ensure sshd jail is enabled and configured for the new port
    sudo sed -i "/\[sshd\]/,/enabled =/s/enabled = .*/enabled = true/" "${jail_local_file}"
    sudo sed -i "/\[sshd\]/,/port =/s/port = .*/port = ${VPS_NEW_SSH_PORT}/" "${jail_local_file}"
    # Ensure it uses nftables action if available and suitable
    sudo sed -i "/\[DEFAULT\]/,/banaction =/s/banaction = .*/banaction = ${fail2ban_action_d}/" "${jail_local_file}"
    # Also ensure the sshd jail uses the default banaction or explicitly set it
    sudo sed -i "/\[sshd\]/,/banaction =/s/banaction = .*/banaction = ${fail2ban_action_d}/" "${jail_local_file}"

    # Restart Fail2Ban
    log_info "Restarting Fail2Ban service..."
    if sudo systemctl restart fail2ban; then
        log_success "Fail2Ban service restarted successfully."
        log_info "Verify Fail2Ban status: 'sudo fail2ban-client status sshd'"
    else
        log_error "Failed to restart Fail2Ban service. Please check 'sudo systemctl status fail2ban' and 'sudo journalctl -xeu fail2ban'."
        return 1
    fi
    return 0
}

# Function to install Pangolin stack
install_pangolin_stack() {
    log_info "Starting Pangolin stack installation..."

    read -rp "Do you want to install the Pangolin stack? (y/N): " confirm_pangolin
    if [[ ! "${confirm_pangolin}" =~ ^[yY]$ ]]; then
        log_info "Pangolin installation skipped."
        return 0
    fi

    # Create directory for Pangolin
    log_info "Creating Pangolin directory: ${PANGOLIN_DIR}..."
    sudo mkdir -p "${PANGOLIN_DIR}"
    sudo chown "${USER}":"${USER}" "${PANGOLIN_DIR}" # Give current user ownership for setup

    log_info "Downloading Pangolin Docker Compose files..."
    cd "${PANGOLIN_DIR}" || { log_error "Failed to change to Pangolin directory."; return 1; }
    
    curl -sL "${PANGOLIN_GITHUB_RAW}/docker-compose.yml" -o docker-compose.yml || { log_error "Failed to download docker-compose.yml"; return 1; }
    curl -sL "${PANGOLIN_GITHUB_RAW}/.env.example" -o .env.example || { log_error "Failed to download .env.example"; return 1; }

    # Copy .env.example to .env
    cp .env.example .env

    log_info "Configuring Pangolin environment variables in .env file."

    local pangolin_domain=$(get_input "Enter the domain name for Pangolin (e.g., pangolin.yourdomain.com)" "")
    if [ -z "${pangolin_domain}" ]; then
        log_error "Pangolin domain cannot be empty. Aborting Pangolin installation."
        return 1
    fi

    local admin_email=$(get_input "Enter the admin email for Pangolin" "")
    if [ -z "${admin_email}" ]; then
        log_error "Admin email cannot be empty. Aborting Pangolin installation."
        return 1
    fi

    local admin_password=$(get_input "Enter the admin password for Pangolin" "")
    if [ -z "${admin_password}" ]; then
        log_error "Admin password cannot be empty. Aborting Pangolin installation."
        return 1
    fi

    # Update .env file with user inputs
    sed -i "s|TRAEFIK_WEB_DOMAIN=.*|TRAEFIK_WEB_DOMAIN=${pangolin_domain}|g" .env
    sed -i "s|PANGOLIN_AUTH_WEB_USERNAME=.*|PANGOLIN_AUTH_WEB_USERNAME=${admin_email}|g" .env
    sed -i "s|PANGOLIN_AUTH_WEB_PASSWORD=.*|PANGOLIN_AUTH_WEB_PASSWORD=${admin_password}|g" .env

    # Ensure other necessary defaults for a basic public exposure (e.g., Traefik external access)
    # These might already be in .env.example, but ensure they are not commented out or are set.
    sed -i 's|^#PANGOLIN_TRAEFIK_API_ENTRYPOINTS=web,websecure|PANGOLIN_TRAEFIK_API_ENTRYPOINTS=web,websecure|g' .env
    sed -i 's|^#PANGOLIN_TRAEFIK_API_HOST_RULES=Host(`.*`)|PANGOLIN_TRAEFIK_API_HOST_RULES=Host(`'${pangolin_domain}'`)|g' .env


    log_info "Starting Pangolin Docker containers..."
    sudo docker compose pull || { log_error "Failed to pull Docker images for Pangolin."; return 1; }
    sudo docker compose up -d || { log_error "Failed to start Pangolin Docker containers."; return 1; }

    log_success "Pangolin stack deployed and running."
    log_info "Pangolin should now be accessible at: https://${pangolin_domain}"
    log_info "Remember to set up a DNS A record for '${pangolin_domain}' pointing to your VPS public IP: ${VPS_PUBLIC_ENDPOINT_IPV4}."
    log_info "Also, ensure ports 80/tcp and 443/tcp are open in your VPS provider's firewall."
    
    # Revert ownership of Pangolin directory back to root or other system user if desired, after setup.
    sudo chown root:root "${PANGOLIN_DIR}" -R
    
    return 0
}


# Function to display homelab client config and retrieval instructions
display_homelab_client_config() {
    log_info "--- Homelab Client WireGuard Configuration ---"
    echo "Save this to /etc/wireguard/wg0.conf on your homelab client."
    echo "========================================================="
    echo "[Interface]"
    echo "PrivateKey = <HOMELAB_CLIENT_PRIVATE_KEY>" # Retrieve from VPS via SSH
    echo "Address = ${HOMELAB_WG_IPV4}/32, ${HOMELAB_WG_IPV6}/128"
    echo "DNS = 8.8.8.8, 8.8.4.4, 1.1.1.1, 1.0.0.1, 2001:4860:4860::8888, 2001:4860:4860::8844, 2606:4700:4700::1111, 2606:4700:4700::1001"

    echo ""
    echo "[Peer]"
    echo "PublicKey = ${VPS_WG_PUBLIC_KEY}"

    # Prefer IPv6 endpoint if available, otherwise use IPv4
    local endpoint_ip=""
    if [ -n "${VPS_PUBLIC_ENDPOINT_IPV6}" ]; then
        endpoint_ip="${VPS_PUBLIC_ENDPOINT_IPV6}"
    elif [ -n "${VPS_PUBLIC_ENDPOINT_IPV4}" ]; then
        endpoint_ip="${VPS_PUBLIC_ENDPOINT_IPV4}"
    else
        log_error "Could not determine a public IP for the VPS endpoint. You'll need to manually add it."
        echo "Endpoint = <YOUR_VPS_PUBLIC_IP>:51820"
        return 1
    fi

    echo "Endpoint = ${endpoint_ip}:51820"
    echo "AllowedIPs = 0.0.0.0/0, ::/0" # Route all traffic through the VPN
    echo "PersistentKeepalive = 25"
    echo "========================================================="
    log_success "Homelab client config displayed."
    log_info "To get the <HOMELAB_CLIENT_PRIVATE_KEY> for your homelab, run this command from your homelab:"
    echo "ssh -p ${VPS_NEW_SSH_PORT} your_vps_user@${VPS_PUBLIC_ENDPOINT_IPV4} 'sudo cat ${HOMELAB_PRIVKEY_FILE_ON_VPS}'"
    log_info "After fetching the key, you can delete it from the VPS for security:"
    echo "ssh -p ${VPS_NEW_SSH_PORT} your_vps_user@${VPS_PUBLIC_ENDPOINT_IPV4} 'sudo rm ${HOMELAB_PRIVKEY_FILE_ON_VPS}'"
    log_success "Remember to replace 'your_vps_user' with your actual SSH username on the VPS."
}

# --- Main Script Execution ---

log_info "Starting VPS Gateway Setup Script..."

# Install prerequisites (including Docker)
if ! install_prerequisites; then
    log_error "Prerequisite installation failed. Exiting."
    exit 1
fi

# Detect VPS network information first
detect_vps_network_info

# SSH Port Configuration
if ! configure_ssh; then
    log_error "SSH configuration failed. Exiting."
    exit 1
fi

# Disable UFW before configuring nftables to prevent conflicts
disable_ufw

# Configure nftables rules
if ! configure_nftables; then
    log_error "nftables configuration failed. Exiting."
    exit 1
fi

# Configure WireGuard server and peers
if ! configure_wireguard_server; then
    log_error "WireGuard server configuration failed. Exiting."
    exit 1
fi

# Configure Fail2Ban after SSH and nftables are set up
if ! configure_fail2ban; then
    log_error "Fail2Ban configuration failed. Exiting."
    exit 1
fi

# Install Pangolin (optional, prompted)
if ! install_pangolin_stack; then
    log_warning "Pangolin stack installation encountered issues or was skipped."
    # Non-fatal for the main gateway setup, so continue.
fi


# Display homelab client config and key retrieval instructions
display_homelab_client_config

log_success "VPS Gateway Setup Complete!"
log_success "IMPORTANT: Test your new SSH connection to the VPS on port ${VPS_NEW_SSH_PORT} immediately."
log_success "Then, configure your homelab client using the provided config and its own private key."
log_success "Ensure you open port 51820/udp and the new SSH port ${VPS_NEW_SSH_PORT}/tcp in your VPS provider's firewall/security groups if applicable!"
log_success "If you installed Pangolin, also ensure ports 80/tcp and 443/tcp are open in your VPS provider's firewall."

# Clean up temporary files used for nftables commands
sudo rm -f /tmp/wg_postup_rules.txt /tmp/wg_predown_rules.txt
