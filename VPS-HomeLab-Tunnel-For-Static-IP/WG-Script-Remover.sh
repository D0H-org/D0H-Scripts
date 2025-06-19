#!/bin/bash

# Homelab Gateway Unified Uninstall Script
# This script can revert the setup either on the VPS or the Homelab,
# returning the chosen system to its approximate prior state.

# IMPORTANT:
# - Run this script with root privileges (e.g., sudo ./uninstall_gateway.sh).
# - This script will remove WireGuard, nftables rules (on VPS), Fail2Ban (on VPS),
#   and revert SSH port changes (on VPS).
# - Ensure you have out-of-band access (e.g., VPS console) for VPS operations
#   in case of SSH issues.
# - Take a snapshot or full backup of your system BEFORE running any setup/uninstall scripts for safety.

# --- Configuration Variables (MUST MATCH ORIGINAL SETUP) ---
# VPS-specific variables
VPS_NEW_SSH_PORT="9001" # Must match the port set in vps-homelab-gateway-setup.sh
VPS_WG_CONFIG_FILE="/etc/wireguard/wg0.conf" # WireGuard config for VPS
VPS_PRIVKEY_FILE="/etc/wireguard/vps_privatekey"
VPS_PUBKEY_FILE="/etc/wireguard/vps_publickey"
HOMELAB_PUBKEY_FILE_ON_VPS="/etc/wireguard/homelab_publickey_on_vps"
SSH_CONFIG_BACKUP_PREFIX="/etc/ssh/sshd_config.bak_" # Prefix used for SSHD backups on VPS

# Homelab-specific variables
HOMELAB_WG_CONFIG_FILE="/etc/wireguard/wg0.conf" # WireGuard config for Homelab
HOMELAB_PRIVKEY_FILE="/etc/wireguard/homelab_privatekey"

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

# Function to stop and disable a service
stop_and_disable_service() {
    local service_name="$1"
    log_info "Stopping and disabling ${service_name}..."
    if sudo systemctl is-active --quiet "${service_name}"; then
        sudo systemctl stop "${service_name}" || log_warning "Failed to stop ${service_name}."
    fi
    if sudo systemctl is-enabled --quiet "${service_name}"; then
        sudo systemctl disable "${service_name}" || log_warning "Failed to disable ${service_name}."
    fi
    log_success "${service_name} stopped and disabled."
}

# Function to remove files/directories
remove_files() {
    log_info "Removing specified files/directories..."
    sudo rm -rf "$@" || log_warning "Failed to remove some files/directories: $@"
    log_success "Files/directories removed."
}

# --- VPS Uninstall Functions ---
uninstall_vps_gateway() {
    log_info "Starting VPS Gateway Uninstall Process..."

    # 1. Stop and disable WireGuard
    stop_and_disable_service wg-quick@wg0

    # 2. Remove WireGuard configurations
    log_info "Removing WireGuard configuration files and keys..."
    remove_files "${VPS_WG_CONFIG_FILE}" \
                 "${VPS_PRIVKEY_FILE}" \
                 "${VPS_PUBKEY_FILE}" \
                 "${HOMELAB_PUBKEY_FILE_ON_VPS}" \
                 "/tmp/wg_postup_rules.txt" \
                 "/tmp/wg_predown_rules.txt"
    log_success "WireGuard files removed."

    # 3. Restore SSH port (from backup if exists, or to default 22)
    log_info "Attempting to restore SSH configuration..."
    LATEST_SSH_BACKUP=$(ls -t ${SSH_CONFIG_BACKUP_PREFIX}* 2>/dev/null | head -n 1)

    if [ -n "${LATEST_SSH_BACKUP}" ]; then
        log_info "Found SSHD config backup: ${LATEST_SSH_BACKUP}. Restoring..."
        sudo cp "${LATEST_SSH_BACKUP}" "/etc/ssh/sshd_config" || log_error "Failed to restore SSHD config from backup."
    else
        log_warning "No SSHD config backup found with prefix '${SSH_CONFIG_BACKUP_PREFIX}'. Manually reverting SSH port to 22."
        sudo sed -i '/^Port /d' "/etc/ssh/sshd_config" # Remove our new port
        grep -q '^Port 22$' "/etc/ssh/sshd_config" || echo "Port 22" | sudo tee -a "/etc/ssh/sshd_config" > /dev/null # Add default port 22 if not present
    fi
    log_info "Restarting SSH service to apply changes. Your current SSH session might disconnect."
    sudo systemctl restart sshd || log_error "Failed to restart SSHD service. Manual intervention required."
    log_success "SSH configuration reverted (or set to default 22) and service restarted."

    # 4. Stop and disable Fail2Ban
    stop_and_disable_service fail2ban

    # 5. Remove Fail2Ban configurations
    log_info "Removing Fail2Ban local configuration..."
    remove_files "/etc/fail2ban/jail.local"
    log_success "Fail2Ban configuration removed."

    # 6. Remove nftables rules (specifically the tables we created)
    log_info "Removing nftables tables created by the setup script..."
    sudo nft delete table ip wg-quick-nat-rules 2>/dev/null || true
    sudo nft delete table ip6 wg-quick-nat-rules 2>/dev/null || true
    sudo nft delete table ip wg-quick-filter-rules 2>/dev/null || true
    sudo nft delete table ip6 wg-quick-filter-rules 2>/dev/null || true
    log_success "Custom nftables tables removed."

    # 7. Disable IP forwarding
    log_info "Disabling IP forwarding persistence..."
    sudo sed -i '/net.ipv4.ip_forward = 1/d' /etc/sysctl.conf
    sudo sed -i '/net.ipv6.conf.all.forwarding = 1/d' /etc/sysctl.conf
    sudo sed -i '/net.ipv6.conf.default.forwarding = 1/d' /etc/sysctl.conf
    sudo sysctl -p > /dev/null
    log_success "IP forwarding disabled."

    # 8. Uninstall packages
    log_info "Uninstalling installed packages: wireguard, wireguard-tools, nftables, fail2ban, socat, screen..."
    sudo apt purge -y wireguard wireguard-tools nftables fail2ban socat screen || log_warning "Failed to purge some packages. Manual removal may be required."
    sudo apt autoremove -y || log_warning "Failed to autoremove unused dependencies."
    log_success "Packages uninstalled."

    # 9. Remove deployed VPS port management script
    log_info "Removing VPS port management script..."
    remove_files "/usr/local/bin/manage_vps_forwarded_ports.sh"
    log_success "VPS management script removed."

    log_success "VPS Gateway Uninstall Complete! The VPS should be largely returned to its pre-setup state."
    log_info "Please manually verify your SSH access (try both original port 22 and the new port ${VPS_NEW_SSH_PORT} if you didn't restore from backup)."
    log_info "If UFW was active before setup and you want it back, you'll need to reinstall and configure it manually."
}

# --- Homelab Uninstall Functions ---
uninstall_homelab_gateway() {
    log_info "Starting Homelab Uninstall Process..."

    # 1. Stop and disable WireGuard
    stop_and_disable_service wg-quick@wg0

    # 2. Remove WireGuard configurations
    log_info "Removing WireGuard client configuration files and keys..."
    remove_files "${HOMELAB_WG_CONFIG_FILE}" "${HOMELAB_PRIVKEY_FILE}"
    log_success "WireGuard files removed."

    # 3. Uninstall packages
    log_info "Uninstalling installed packages: wireguard, wireguard-tools, sshpass..."
    sudo apt purge -y wireguard wireguard-tools sshpass || log_warning "Failed to purge some packages. Manual removal may be required."
    sudo apt autoremove -y || log_warning "Failed to autoremove unused dependencies."
    log_success "Packages uninstalled."

    # 4. Check on UFW and Fail2Ban (they were disabled, not re-enabled)
    log_info "Checking state of UFW and Fail2Ban..."
    if sudo systemctl is-active --quiet ufw; then
        log_warning "UFW is still active. Please stop and disable it manually if desired: 'sudo systemctl stop ufw && sudo systemctl disable ufw'"
    elif sudo systemctl is-enabled --quiet ufw; then
        log_warning "UFW is still enabled but inactive. Please disable it manually if desired: 'sudo systemctl disable ufw'"
    else
        log_info "UFW is neither active nor enabled, as expected."
    fi

    if sudo systemctl is-active --quiet fail2ban; then
        log_warning "Fail2Ban is still active. Please stop and disable it manually if desired: 'sudo systemctl stop fail2ban && sudo systemctl disable fail2ban'"
    elif sudo systemctl is-enabled --quiet fail2ban; then
        log_warning "Fail2Ban is still enabled but inactive. Please disable it manually if desired: 'sudo systemctl disable fail2ban'"
    else
        log_info "Fail2Ban is neither active nor enabled, as expected."
    fi

    log_success "Homelab Uninstall Complete! The homelab should be largely returned to its pre-setup state."
}

# --- Main Script Logic ---

log_info "This script can uninstall either the VPS or Homelab gateway setup."
echo "Please choose which system you are uninstalling:"
echo "1) VPS Gateway (run this script on your VPS)"
echo "2) Homelab Client (run this script on your Homelab)"
read -rp "Enter your choice (1 or 2): " choice

case "$choice" in
    1)
        uninstall_vps_gateway
        ;;
    2)
        uninstall_homelab_gateway
        ;;
    *)
        log_error "Invalid choice. Please enter '1' for VPS or '2' for Homelab."
        exit 1
        ;;
esac
