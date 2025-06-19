#!/bin/bash

# Homelab Setup Script (VPS-Centric Security)
# This script configures the homelab client for WireGuard and fetches keys from the VPS.
# It then deploys a port management script on the VPS and orchestrates its execution
# to manage forwarded ports, handling WireGuard restarts gracefully.
# ALL external port management and security (firewall, Fail2Ban) are centralized on the VPS.

# IMPORTANT:
# - Run this script on your homelab system with root privileges (e.g., sudo ./setup_homelab.sh).
# - This script will modify your homelab's WireGuard configuration.
# - Ensure you have proper SSH access (username and password/key) to your VPS.
# - Take a snapshot of your homelab before running this script!

# --- Configuration Variables (Homelab Side) ---
# These should match the values used in your VPS setup script.
HOMELAB_WG_IPV4="10.0.0.2"
HOMELAB_WG_IPV6="fd42:42:42::2"

# New SSH port for your VPS (from the VPS setup script, typically 9001)
VPS_NEW_SSH_PORT="9001"

# WireGuard config file path on homelab
WG_CONFIG_FILE="/etc/wireguard/wg0.conf"

# Path on VPS where the temporary private key for homelab client is stored
HOMELAB_PRIVKEY_FILE_ON_VPS="/etc/wireguard/homelab_privatekey_temp.txt"
HOMELAB_PUBKEY_FILE_ON_VPS="/etc/wireguard/homelab_publickey_on_vps" # For peer public key
VPS_PUBKEY_FILE="/etc/wireguard/vps_publickey" # For peer public key from VPS

# --- Global Variables for VPS Info (will be set by user input) ---
VPS_PUBLIC_IP=""
VPS_SSH_USER=""
VPS_SSH_PASSWORD="" # Will be prompted securely

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

# Function to get user input
get_input() {
    local prompt="$1"
    local default_value="$2"
    read -rp "$prompt [$default_value]: " input
    echo "${input:-$default_value}"
}

# Function to install prerequisites on homelab
install_prerequisites() {
    log_info "Installing necessary prerequisites: WireGuard, sshpass..."
    sudo apt update || { log_error "Failed to update package lists."; return 1; }
    sudo apt install -y wireguard wireguard-tools sshpass || { log_error "Failed to install required packages."; return 1; }
    log_success "Prerequisites installed successfully."
    return 0
}

# Function to fetch keys from VPS via SSH
fetch_keys_from_vps() {
    log_info "Fetching WireGuard keys from VPS..."
    log_info "This initial connection will use the VPS's public IP and new SSH port, as the WireGuard tunnel is not yet established."

    # Prompt for VPS IP and SSH user
    VPS_PUBLIC_IP=$(get_input "Enter your VPS's Public IP address" "")
    if [ -z "${VPS_PUBLIC_IP}" ]; then
        log_error "VPS IP cannot be empty. Aborting."
        return 1
    fi

    VPS_SSH_USER=$(get_input "Enter your SSH username for the VPS" "${USER}")
    if [ -z "${VPS_SSH_USER}" ]; then
        log_error "VPS SSH username cannot be empty. Aborting."
        return 1
    fi

    # Prompt for password securely
    read -rsp "Enter your SSH password for ${VPS_SSH_USER}@${VPS_PUBLIC_IP}:${VPS_NEW_SSH_PORT}: " VPS_SSH_PASSWORD
    echo "" # Add a newline after password input for cleaner output

    # Fetch Homelab Private Key
    log_info "Attempting to fetch homelab private key from VPS..."
    local homelab_privkey_content=""
    homelab_privkey_content=$(sshpass -p "${VPS_SSH_PASSWORD}" ssh -p "${VPS_NEW_SSH_PORT}" "${VPS_SSH_USER}@${VPS_PUBLIC_IP}" "sudo cat ${HOMELAB_PRIVKEY_FILE_ON_VPS}" 2>&1)

    if echo "${homelab_privkey_content}" | grep -q "Authentication failed"; then
        log_error "SSH Authentication failed. Please check your username and password."
        return 1
    fi
    if echo "${homelab_privkey_content}" | grep -q "sudo: command not found"; then
        log_error "sudo not available for ${VPS_SSH_USER} on VPS. Please ensure the user has sudo access."
        return 1
    fi
    if echo "${homelab_privkey_content}" | grep -q "No such file or directory"; then
        log_error "Homelab private key file (${HOMELAB_PRIVKEY_FILE_ON_VPS}) not found on VPS. Did you run the VPS setup script correctly?"
        return 1
    fi

    # Save homelab private key locally
    echo "${homelab_privkey_content}" | sudo tee /etc/wireguard/homelab_privatekey > /dev/null
    sudo chmod 600 /etc/wireguard/homelab_privatekey
    log_success "Homelab private key fetched and saved locally."

    # Fetch VPS Public Key
    log_info "Attempting to fetch VPS public key..."
    local vps_pubkey_content=""
    vps_pubkey_content=$(sshpass -p "${VPS_SSH_PASSWORD}" ssh -p "${VPS_NEW_SSH_PORT}" "${VPS_SSH_USER}@${VPS_PUBLIC_IP}" "sudo cat ${VPS_PUBKEY_FILE}" 2>&1)

    if echo "${vps_pubkey_content}" | grep -q "Authentication failed"; then
        log_error "SSH Authentication failed for VPS Public Key fetch."
        return 1
    fi

    # Save VPS public key temporarily (we just need the content for the wg0.conf)
    VPS_WG_PUBLIC_KEY="${vps_pubkey_content}"
    log_success "VPS public key fetched."

    # Fetch VPS endpoint IP for WireGuard config
    local vps_endpoint_info=$(sshpass -p "${VPS_SSH_PASSWORD}" ssh -p "${VPS_NEW_SSH_PORT}" "${VPS_SSH_USER}@${VPS_PUBLIC_IP}" "sudo ip -4 a show dev \$(ip route get 8.8.8.8 | awk '{print \$5; exit}') | grep -oP 'inet \\K[\\d.]+' | head -1; sudo ip -6 a show dev \$(ip route get 8.8.8.8 | awk '{print \$5; exit}') | grep -oP 'inet6 \\K[0-9a-fA-F:]+' | head -1 | cut -d'/' -f1")
    local vps_public_ipv4=$(echo "${vps_endpoint_info}" | head -n 1)
    local vps_public_ipv6=$(echo "${vps_endpoint_info}" | tail -n 1)

    VPS_PUBLIC_ENDPOINT=""
    if [ -n "${vps_public_ipv6}" ]; then
        VPS_PUBLIC_ENDPOINT="${vps_public_ipv6}"
    elif [ -n "${vps_public_ipv4}" ]; then
        VPS_PUBLIC_ENDPOINT="${vps_public_ipv4}"
    else
        log_warning "Could not auto-detect VPS public endpoint IP. Please enter it manually if needed."
        VPS_PUBLIC_ENDPOINT=$(get_input "Enter VPS Public IP for WireGuard Endpoint" "${VPS_PUBLIC_IP}")
    fi
    log_success "VPS Endpoint IP detected: ${VPS_PUBLIC_ENDPOINT}"

    # Delete the temporary private key from VPS
    log_info "Deleting temporary homelab private key file from VPS..."
    sshpass -p "${VPS_SSH_PASSWORD}" ssh -p "${VPS_NEW_SSH_PORT}" "${VPS_SSH_USER}@${VPS_PUBLIC_IP}" "sudo rm ${HOMELAB_PRIVKEY_FILE_ON_VPS}" > /dev/null 2>&1
    log_success "Temporary homelab private key removed from VPS."

    return 0
}

# Function to configure WireGuard on homelab
configure_wireguard_homelab() {
    log_info "Configuring WireGuard on homelab..."

    local homelab_privkey=$(sudo cat /etc/wireguard/homelab_privatekey)

    sudo bash -c "cat <<EOT > ${WG_CONFIG_FILE}
[Interface]
PrivateKey = ${homelab_privkey}
Address = ${HOMELAB_WG_IPV4}/32, ${HOMELAB_WG_IPV6}/128
DNS = 8.8.8.8, 8.8.4.4, 1.1.1.1, 1.0.0.1, 2001:4860:4860::8888, 2001:4860:4860::8844, 2606:4700:4700::1111, 2606:4700:4700::1001

[Peer]
PublicKey = ${VPS_WG_PUBLIC_KEY}
Endpoint = ${VPS_PUBLIC_ENDPOINT}:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOT"

    sudo chmod 600 "${WG_CONFIG_FILE}"
    log_success "Homelab WireGuard config created: ${WG_CONFIG_FILE}"

    log_info "Starting WireGuard service on homelab..."
    if sudo systemctl enable wg-quick@wg0 && sudo systemctl start wg-quick@wg0; then
        log_success "WireGuard service started successfully."
    else
        log_error "Failed to start WireGuard service. Please check 'sudo systemctl status wg-quick@wg0'."
        return 1
    fi
    return 0
}

# Function to generate and deploy the VPS port management script
deploy_vps_port_manager_script() {
    log_info "Generating VPS port management script..."

    local vps_mgmt_script_name="manage_vps_forwarded_ports.sh"
    local vps_mgmt_script_path="/usr/local/bin/${vps_mgmt_script_name}"

    # Get VPS_PUBLIC_INTERFACE from the VPS itself via SSH for embedding
    local VPS_PUBLIC_INTERFACE_FETCHED=$(sshpass -p "${VPS_SSH_PASSWORD}" ssh -p "${VPS_NEW_SSH_PORT}" "${VPS_SSH_USER}@${VPS_PUBLIC_IP}" "ip route get 8.8.8.8 2>/dev/null | awk '{print \$5; exit}'" 2>/dev/null)
    local VPS_PUBLIC_INTERFACE_ESCAPED=$(echo "${VPS_PUBLIC_INTERFACE_FETCHED}" | sed 's/\//\\\//g') # Escape slashes for sed

    sudo bash -c "cat << 'EOF' > /tmp/${vps_mgmt_script_name}
#!/bin/bash

# VPS Port Management Script
# This script allows dynamic modification of port forwarding rules (DNAT)
# on the VPS, configured via nftables.
#
# Usage:
#   sudo ./manage_vps_forwarded_ports.sh add <port_number_or_range> <protocol>
#   sudo ./manage_vps_forwarded_ports.sh remove <port_number_or_range> <protocol>
#   Example: sudo ./manage_vps_forwarded_ports.sh add 8080 tcp
#   Example: sudo ./manage_vps_forwarded_ports.sh remove 53 udp
#   Example: sudo ./manage_vps_forwarded_ports.sh add "5000-5010" tcp
#
# This script is deployed by the homelab setup script.
# It only modifies nftables rules, it DOES NOT restart WireGuard itself.
# WireGuard restart to apply changes is handled by the calling script on the homelab.

# --- Configuration Variables (INJECTED FROM HOMELAB SCRIPT) ---
# These variables are set during deployment by the homelab setup script.
VPS_PUBLIC_INTERFACE=\"${VPS_PUBLIC_INTERFACE_ESCAPED}\"
HOMELAB_WG_IPV4=\"${HOMELAB_WG_IPV4}\"
HOMELAB_WG_IPV6=\"${HOMELAB_WG_IPV6}\"

log_info() {
    echo -e \"\\n\033[1;34m[INFO]\033[0m \$1\"
}

log_success() {
    echo -e \"\\n\033[1;32m[SUCCESS]\033[0m \$1\"
}

log_error() {
    echo -e \"\\n\033[1;31m[ERROR]\033[0m \$1\" >&2
}

log_warning() {
    echo -e \"\\n\033[1;33m[WARNING]\033[0m \$1\" >&2
}


add_dnat_rule() {
    local port_spec=\"\$1\" # Can be single, range like "20-22"
    local proto=\"\$2\"     # Explicit protocol (tcp/udp)

    if [[ \"\$port_spec\" =~ ^[0-9]+-[0-9]+$ ]]; then # It's a range like 20-22
        local dport_format=\"{ \${port_spec} }\"
    elif [[ \"\$port_spec\" =~ ^[0-9]+$ ]]; then # It's a single port
        local dport_format=\"\${port_spec}\"
    else
        log_error "Invalid port specification: \${port_spec}. Must be a single port (e.g., 80) or a range (e.g., 20-22)."
        exit 1
    fi

    # Escaping curly braces for grep pattern matching
    local grep_port_pattern=\"\${dport_format}\"
    grep_port_pattern=\"\${grep_port_pattern//\{/\\\\\\{}\"
    grep_port_pattern=\"\${grep_port_pattern//\}/\\\\\\}\"

    local added_any=0

    # Add IPv4 rule if not exists
    if ! sudo nft list ruleset | grep -q "ip wg-quick-nat-rules prerouting .* \${proto} dport \${grep_port_pattern} dnat to \${HOMELAB_WG_IPV4}"; then
        log_info "Adding IPv4 DNAT rule for port \${port_spec}/\${proto} to \${HOMELAB_WG_IPV4}..."
        sudo nft add rule ip wg-quick-nat-rules prerouting iifname \"\${VPS_PUBLIC_INTERFACE}\" \${proto} dport \${dport_format} dnat to \${HOMELAB_WG_IPV4} || { log_error "Failed to add IPv4 DNAT rule."; return 1; }
        added_any=1
    else
        log_warning "Rule for \${port_spec}/\${proto} (IPv4) already exists. No action needed."
        # No return here, check IPv6 separately
    fi

    # Add IPv6 rule if not exists
    if [ -n \"\${HOMELAB_WG_IPV6}\" ] && ! sudo nft list ruleset | grep -q "ip6 wg-quick-nat-rules prerouting .* \${proto} dport \${grep_port_pattern} dnat to \${HOMELAB_WG_IPV6}"; then
        log_info "Adding IPv6 DNAT rule for port \${port_spec}/\${proto} to \${HOMELAB_WG_IPV6}..."
        sudo nft add rule ip6 wg-quick-nat-rules prerouting iifname \"\${VPS_PUBLIC_INTERFACE}\" \${proto} dport \${dport_format} dnat to \${HOMELAB_WG_IPV6} || { log_error "Failed to add IPv6 DNAT rule."; return 1; }
        added_any=1
    else
        if [ -n \"\${HOMELAB_WG_IPV6}\" ]; then
            log_warning "Rule for \${port_spec}/\${proto} (IPv6) already exists. No action needed."
        fi
    fi

    if [ \${added_any} -eq 1 ]; then
        log_success "DNAT rules modified in nftables. Changes will apply after WireGuard restart."
    else
        log_info "No new DNAT rules added/removed for \${port_spec}/\${proto}."
    fi
    return 0
}

remove_dnat_rule() {
    local port_spec=\"\$1\" # Can be single, range like "20-22"
    local proto=\"\$2\"     # Explicit protocol (tcp/udp)

    if [[ \"\$port_spec\" =~ ^[0-9]+-[0-9]+$ ]]; then # It's a range like 20-22
        local dport_format=\"{ \${port_spec} }\"
    elif [[ \"\$port_spec\" =~ ^[0-9]+$ ]]; then # It's a single port
        local dport_format=\"\${port_spec}\"
    else
        log_error "Invalid port specification: \${port_spec}. Must be a single port (e.g., 80) or a range (e.g., 20-22)."
        exit 1
    fi

    # Escaping curly braces for grep pattern matching
    local grep_port_pattern=\"\${dport_format}\"
    grep_port_pattern=\"\${grep_port_pattern//\{/\\\\\\{}\"
    grep_port_pattern=\"\${grep_port_pattern//\}/\\\\\\}\"

    local removed_any=0

    log_info "Attempting to remove IPv4 DNAT rule for port \${port_spec}/\${proto}..."
    if sudo nft list ruleset | grep -q "ip wg-quick-nat-rules prerouting .* \${proto} dport \${grep_port_pattern} dnat to \${HOMELAB_WG_IPV4}"; then
        sudo nft delete rule ip wg-quick-nat-rules prerouting iifname \"\${VPS_PUBLIC_INTERFACE}\" \${proto} dport \${dport_format} dnat to \${HOMELAB_WG_IPV4} || { log_error "Failed to delete IPv4 DNAT rule."; return 1; }
        removed_any=1
    else
        log_warning "IPv4 DNAT rule for \${port_spec}/\${proto} not found. Nothing to remove."
    fi

    log_info "Attempting to remove IPv6 DNAT rule for port \${port_spec}/\${proto}..."
    if [ -n \"\${HOMELAB_WG_IPV6}\" ] && sudo nft list ruleset | grep -q "ip6 wg-quick-nat-rules prerouting .* \${proto} dport \${grep_port_pattern} dnat to \${HOMELAB_WG_IPV6}"; then
        sudo nft delete rule ip6 wg-quick-nat-rules prerouting iifname \"\${VPS_PUBLIC_INTERFACE}\" \${proto} dport \${dport_format} dnat to \${HOMELAB_WG_IPV6} || { log_error "Failed to delete IPv6 DNAT rule."; return 1; }
        removed_any=1
    else
        if [ -n \"\${HOMELAB_WG_IPV6}\" ]; then
            log_warning "IPv6 DNAT rule for \${port_spec}/\${proto} not found. Nothing to remove."
        fi
    fi

    if [ \${removed_any} -eq 1 ]; then
        log_success "DNAT rules removal attempted for \${port_spec}/\${proto}. Changes will apply after WireGuard restart."
    else
        log_info "No DNAT rules removed for \${port_spec}/\${proto} as they did not exist."
    fi
    return 0
}

# Main logic for VPS management script
case \"\$1\" in
    add)
        if [ -z \"\$2\" ] || [ -z \"\$3\" ]; then
            log_error "Usage: sudo ./manage_vps_forwarded_ports.sh add <port_number_or_range> <protocol (tcp|udp)>"
            log_error "Example: sudo ./manage_vps_forwarded_ports.sh add 8080 tcp"
            log_error "Example: sudo ./manage_vps_forwarded_ports.sh add \\"5000-5010\\" udp"
            exit 1
        fi
        add_dnat_rule \"\$2\" \"\$3\"
        ;;
    remove)
        if [ -z \"\$2\" ] || [ -z \"\$3\" ]; then
            log_error "Usage: sudo ./manage_vps_forwarded_ports.sh remove <port_number_or_range> <protocol (tcp|udp)>"
            log_error "Example: sudo ./manage_vps_forwarded_ports.sh remove 8080 tcp"
            exit 1
        fi
        remove_dnat_rule \"\$2\" \"\$3\"
        ;;
    *)
        log_error "Unknown command: \$1"
        log_error "Usage: sudo ./manage_vps_forwarded_ports.sh [add|remove] <port_number_or_range> <protocol (tcp|udp)>"
        log_error "Example: sudo ./manage_vps_forwarded_ports.sh add 80 tcp"
        log_error "Example: sudo ./manage_vps_forwarded_ports.sh remove 2222 udp"
        exit 1
        ;;
esac
EOF
"

    # Transfer script to VPS
    log_info "Transferring VPS port management script to ${VPS_PUBLIC_IP}..."
    sshpass -p "${VPS_SSH_PASSWORD}" scp -P "${VPS_NEW_SSH_PORT}" "/tmp/${vps_mgmt_script_name}" "${VPS_SSH_USER}@${VPS_PUBLIC_IP}:/tmp/${vps_mgmt_script_name}" || { log_error "Failed to transfer script."; return 1; }

    # Make script executable and move to /usr/local/bin on VPS
    log_info "Setting permissions and moving script on VPS..."
    sshpass -p "${VPS_SSH_PASSWORD}" ssh -p "${VPS_NEW_SSH_PORT}" "${VPS_SSH_USER}@${VPS_PUBLIC_IP}" "sudo chmod +x /tmp/${vps_mgmt_script_name} && sudo mv /tmp/${vps_mgmt_script_name} ${vps_mgmt_script_path}" || { log_error "Failed to set permissions/move script on VPS."; return 1; }

    log_success "VPS port management script deployed to ${vps_mgmt_script_path} on VPS."
    return 0
}

# Function to orchestrate WireGuard restart and verification on VPS
orchestrate_vps_wireguard_restart() {
    local action="$1" # "add" or "remove"
    local port_spec="$2"
    local proto="$3"
    local vps_mgmt_script_path="/usr/local/bin/manage_vps_forwarded_ports.sh"
    local temp_restart_script_name="restart_wg_and_verify.sh"
    local temp_restart_script_path="/tmp/${temp_restart_script_name}"

    log_info "Executing port management command on VPS: ${action} \"${port_spec}\" ${proto}"
    # Run the port management script on VPS to modify nftables rules
    sshpass -p "${VPS_SSH_PASSWORD}" ssh -p "${VPS_NEW_SSH_PORT}" "${VPS_SSH_USER}@${VPS_PUBLIC_IP}" "sudo ${vps_mgmt_script_path} ${action} \"${port_spec}\" \"${proto}\"" || { log_error "Failed to execute port management script on VPS."; return 1; }

    log_info "Creating temporary WireGuard restart and verification script on VPS..."
    # Create a script on VPS to restart WireGuard and list rules, then clean up
    # This script runs on the VPS.
    local temp_script_content=$(cat <<EOF_RESTART
#!/bin/bash
log_info() { echo -e "\\n\033[1;34m[INFO]\033[0m \$1"; }
log_success() { echo -e "\\n\033[1;32m[SUCCESS]\033[0m \$1"; }
log_error() { echo -e "\\n\033[1;31m[ERROR]\033[0m \$1" >&2; }

log_info "Restarting WireGuard service to apply new nftables rules..."
if sudo systemctl restart wg-quick@wg0; then
    log_success "WireGuard restarted successfully on VPS."
else
    log_error "Failed to restart WireGuard on VPS."
    exit 1
fi
sleep 5 # Give WireGuard a moment to fully restart
echo "--- VPS Nftables Rules After Restart ---"
sudo nft list ruleset | grep 'wg-quick-nat-rules prerouting'
echo "----------------------------------------"
log_info "Self-cleaning temporary script..."
sudo rm -f ${temp_restart_script_path}
EOF_RESTART
)

    # Transfer the temporary restart script to VPS
    # Using printf for multi-line string with newlines preserved
    printf "%s" "${temp_script_content}" | sshpass -p "${VPS_SSH_PASSWORD}" ssh -p "${VPS_NEW_SSH_PORT}" "${VPS_SSH_USER}@${VPS_PUBLIC_IP}" "sudo tee ${temp_restart_script_path} > /dev/null" || { log_error "Failed to transfer restart script."; return 1; }
    sshpass -p "${VPS_SSH_PASSWORD}" ssh -p "${VPS_NEW_SSH_PORT}" "${VPS_SSH_USER}@${VPS_PUBLIC_IP}" "sudo chmod +x ${temp_restart_script_path}" || { log_error "Failed to set permissions for restart script."; return 1; }

    log_info "Executing WireGuard restart on VPS via 'screen' in detached mode. Your SSH session will briefly drop."
    # Execute the temporary script using screen in detached mode
    sshpass -p "${VPS_SSH_PASSWORD}" ssh -p "${VPS_NEW_SSH_PORT}" "${VPS_SSH_USER}@${VPS_PUBLIC_IP}" "screen -dm bash ${temp_restart_script_path}" || { log_error "Failed to start restart script in screen."; return 1; }

    log_info "Waiting 30 seconds for WireGuard to restart and tunnel to re-establish..."
    sleep 30

    log_info "Attempting to reconnect to VPS and verify changes..."
    # Reconnect and fetch status (the output will contain rules from the temp script)
    local verification_output=$(sshpass -p "${VPS_SSH_PASSWORD}" ssh -p "${VPS_NEW_SSH_PORT}" "${VPS_SSH_USER}@${VPS_PUBLIC_IP}" "sudo nft list ruleset | grep 'wg-quick-nat-rules prerouting'" 2>&1)
    if [ $? -eq 0 ]; then
        log_success "Successfully reconnected to VPS. Current Forwarded Rules (from VPS nftables):"
        echo "${verification_output}"
        if echo "${verification_output}" | grep -q "dport ${port_spec//-/:}" && [[ "${action}" == "add" ]]; then # Simple check for add
            log_success "Port ${port_spec}/${proto} rule verified as added on VPS."
        elif ! echo "${verification_output}" | grep -q "dport ${port_spec//-/:}" && [[ "${action}" == "remove" ]]; then # Simple check for remove
            log_success "Port ${port_spec}/${proto} rule verified as removed on VPS."
        else
            log_warning "Verification for ${action} ${port_spec}/${proto} was inconclusive. Please manually check 'sudo nft list ruleset' on VPS."
        fi
    else
        log_error "Failed to reconnect to VPS or verify changes. Please check manually."
        echo "${verification_output}"
        return 1
    fi

    log_success "VPS WireGuard restart and verification complete."
    # Temporary script automatically cleans itself up on VPS
    return 0
}


# --- Main Script Execution ---

log_info "Starting Homelab Setup Script (VPS-Centric Security)..."

# Install prerequisites
if ! install_prerequisites; then
    log_error "Prerequisite installation failed. Exiting."
    exit 1
fi

# Fetch keys and VPS info (initial connection uses public IP)
if ! fetch_keys_from_vps; then
    log_error "Failed to fetch keys or VPS info. Exiting."
    exit 1
fi

# Configure WireGuard on homelab
if ! configure_wireguard_homelab; then
    log_error "WireGuard homelab configuration failed. Exiting."
    exit 1
fi

# IMPORTANT SECURITY NOTE:
log_warning "By disabling UFW and Fail2Ban on the homelab, you are removing a local security layer."
log_warning "All external firewalling and brute-force protection will now solely rely on your VPS."
log_warning "If your VPS were to be compromised, your homelab would be more vulnerable."
log_warning "Ensure your VPS security (e.g., strong SSH passwords/keys, regular updates) is robust."


# Ensure UFW is not running on homelab, as we are centralizing security on VPS.
log_info "Ensuring UFW is not active on homelab (security centralized on VPS)..."
if sudo systemctl is-active --quiet ufw; then
    log_warning "UFW is active. Stopping and disabling it as security is now VPS-centric."
    sudo systemctl stop ufw
    sudo systemctl disable ufw
    log_success "UFW disabled on homelab."
else
    log_info "UFW is not active on homelab. Good."
fi

# Ensure Fail2Ban is not running on homelab, as we are centralizing security on VPS.
log_info "Ensuring Fail2Ban is not active on homelab (security centralized on VPS)..."
if sudo systemctl is-active --quiet fail2ban; then
    log_warning "Fail2Ban is active. Stopping and disabling it as security is now VPS-centric."
    sudo systemctl stop fail2ban
    sudo systemctl disable fail2ban
    log_success "Fail2Ban disabled on homelab."
else
    log_info "Fail2Ban is not active on homelab. Good."
fi

# Deploy VPS port management script
if ! deploy_vps_port_manager_script; then
    log_error "Failed to deploy VPS port management script. Exiting."
    exit 1
fi

# Now, add interactive prompt for managing ports on the VPS from homelab
log_info "\n--- Manage VPS Forwarded Ports to Homelab ---"
echo "You can now add or remove port forwarding rules on your VPS for services on your homelab."
echo "These changes will be applied by restarting WireGuard on the VPS via a detached 'screen' session."
echo "Examples: "
echo "  add 80 tcp"
echo "  remove 443 tcp"
echo "  add \"8080-8085\" tcp"
echo "  list (to see current forwarded rules)"
echo "Type 'done' to finish port management."

while true; do
    read -rp "Action (add/remove/list/done) and arguments (e.g., 'add 80 tcp'): " action_input

    case "${action_input%% *}" in # Get the first word as action
        add)
            IFS=' ' read -r _ port_spec proto <<< "${action_input}" # Parse remaining arguments
            if [ -z "${port_spec}" ] || [ -z "${proto}" ]; then
                log_error "Invalid 'add' command. Usage: add <port_number_or_range> <protocol (tcp|udp)>"
                continue
            fi
            if ! orchestrate_vps_wireguard_restart "add" "${port_spec}" "${proto}"; then
                log_error "Failed to add port. Please check output."
            fi
            ;;
        remove)
            IFS=' ' read -r _ port_spec proto <<< "${action_input}" # Parse remaining arguments
            if [ -z "${port_spec}" ] || [ -z "${proto}" ]; then
                log_error "Invalid 'remove' command. Usage: remove <port_number_or_range> <protocol (tcp|udp)>"
                continue
            fi
            if ! orchestrate_vps_wireguard_restart "remove" "${port_spec}" "${proto}"; then
                log_error "Failed to remove port. Please check output."
            fi
            ;;
        list)
            log_info "Listing current forwarded ports on VPS..."
            local current_rules=$(sshpass -p "${VPS_SSH_PASSWORD}" ssh -p "${VPS_NEW_SSH_PORT}" "${VPS_SSH_USER}@${VPS_PUBLIC_IP}" "sudo nft list ruleset | grep 'wg-quick-nat-rules prerouting'" 2>&1)
            if [ $? -eq 0 ]; then
                if [ -n "${current_rules}" ]; then
                    log_info "Current Forwarded Rules (from VPS nftables):"
                    echo "${current_rules}"
                else
                    log_info "No custom forwarded ports found (only WireGuard and VPS SSH are open)."
                fi
            else
                log_error "Failed to list rules from VPS. Please check SSH connection."
                echo "${current_rules}"
            fi
            ;;
        done)
            log_info "Exiting port management."
            break
            ;;
        *)
            log_warning "Unknown command or invalid format. Please use 'add', 'remove', 'list', or 'done'."
            ;;
    esac
done

log_success "Homelab Setup Complete! External security and port forwarding are now managed by your VPS."
log_info "You should now be able to access the internet via your VPS tunnel."
log_info "Verify connectivity: 'curl -v ifconfig.me', 'ping google.com', 'apt update'"
log_info "Remember to open any necessary ports on your VPS provider's external firewall (security groups)!"
log_info "To open/close ports to your homelab *after this script completes*, you can also manually use the deployed script on your VPS by SSHing into it (e.g.):"
echo "  ssh -p ${VPS_NEW_SSH_PORT} ${VPS_SSH_USER}@${VPS_PUBLIC_IP} 'sudo /usr/local/bin/manage_vps_forwarded_ports.sh add 8080 tcp'"
echo "  ssh -p ${VPS_NEW_SSH_PORT} ${VPS_SSH_USER}@${VPS_PUBLIC_IP} 'sudo /usr/local/bin/manage_vps_forwarded_ports.sh remove \"20-22\" tcp'"
echo "  ssh -p ${VPS_NEW_SSH_PORT} ${VPS_SSH_USER}@${VPS_PUBLIC_IP} 'sudo /usr/local/bin/manage_vps_forwarded_ports.sh list'"

# Clean up temporary files used for nftables commands (local and remote)
sudo rm -f /tmp/vps_temp_restart_script.sh # Ensure local temp file is removed
# Remote temp script /tmp/vps_temp_restart_script.sh is self-cleaning
