# VPS Homelab Gateway with WireGuard

Alpha V0.1 (Still in Testing)

This project provides a set of automated scripts to establish a secure gateway for your homelab using a Virtual Private Server (VPS) and WireGuard. It centralizes external access management and security on your VPS, simplifying your homelab's firewall configuration.

## Project Overview

The goal of this project is to allow you to securely expose services running in your homelab to the internet without directly exposing your homelab's public IP address. Your VPS acts as a secure intermediary (a "bastion host" or "gateway") that forwards only the specific ports you define to your homelab via an encrypted WireGuard tunnel.

## Features

* **Automated VPS Setup:** Configures your VPS with:
    * WireGuard server.
    * `nftables` for NAT (Masquerading) and initial port forwarding rules.
    * Changed SSH port for enhanced security.
    * Fail2Ban to protect the VPS's new SSH port.
    * Automatic generation and secure exchange of WireGuard keys.

* **Automated Homelab Client Setup:** Configures your homelab machine with:
    * WireGuard client to connect to the VPS.
    * Automatic key fetching from the VPS.

* **Centralized Port Management:** A dedicated script deployed on the VPS allows you to dynamically add or remove port forwarding rules (DNAT) from your homelab, without needing to directly SSH into the VPS for every change.

* **Graceful Operation:** The homelab script orchestrates WireGuard restarts on the VPS in a detached `screen` session to avoid SSH disconnections during port rule application, followed by verification.

* **Enhanced Security:** By using a VPS as a gateway and centralizing security, you reduce the direct exposure of your homelab to the internet.

## Components

This project consists of two main bash scripts:

1.  **`VPS-Setup.sh`**:
    * **Runs On:** Your **VPS**.
    * **Purpose:** Sets up the VPS side of the WireGuard tunnel, including network configurations (`nftables`), SSH hardening, and Fail2Ban for the VPS itself. It also pre-generates the WireGuard keys needed for the homelab client.

2.  **`Homelab-Setup.sh`**:
    * **Runs On:** Your **Homelab server**.
    * **Purpose:** Configures your homelab as the WireGuard client. It connects to the VPS to fetch necessary keys, sets up the WireGuard tunnel, and then provides an interactive interface to manage port forwarding rules on the VPS, effectively controlling which services on your homelab are exposed to the internet. This script also handles the deployment of the `manage_vps_forwarded_ports.sh` utility script onto your VPS.

    * **`manage_vps_forwarded_ports.sh` (deployed *to* VPS by `Homelab-Setup.sh`)**:
        * **Runs On:** Your **VPS** (executed remotely by `Homelab-Setup.sh`).
        * **Purpose:** A utility script that simply adds or removes `nftables` DNAT rules on the VPS. It does **not** restart WireGuard. The restart is orchestrated by the `Homelab-Setup.sh` from the homelab.

## Prerequisites

Before running the scripts, ensure you have:

* **Two Linux Machines:**
    * One **VPS** (Tested on, Ubuntu 24.04+).
    * One **Homelab server** (Tested on, Ubuntu 24.04+).

* **SSH Access:** Root or sudo access to both the VPS and the homelab server.

* **Snapshots/Backups:** **Crucially, take a snapshot or full backup of both your VPS and your homelab server before running these scripts.** They modify critical network and SSH configurations.

* **VPS Provider Firewall:** Ensure your VPS provider's external firewall (e.g., security groups in AWS, firewall rules in DigitalOcean/Linode) allows:
    * Inbound TCP traffic on your chosen **new SSH port (e.g., 9001)** to your VPS.
    * Inbound UDP traffic on the **WireGuard port (51820)** to your VPS.
    * Any other public-facing ports you intend to forward (e.g., 80, 443).

## Setup Instructions

Follow these steps in order:

### Step 1: Prepare your VPS

1.  **SSH into your VPS** using its current public IP and default SSH port (usually 22).

2.  **Download the VPS setup script:**
    ```
    curl -sL https://raw.githubusercontent.com/D0H-org/D0H-Scripts/refs/heads/main/VPS-HomeLab-Tunnel-For-Static-IP/VPS-Setup.sh | bash
    ```
    
    * Follow the prompts. It will detect your public interface and IP, ask you to confirm, and then proceed with installing WireGuard, `nftables`, Fail2Ban, and changing your SSH port.
    * **Crucially, it will output your Homelab Client WireGuard Private Key and the VPS WireGuard Public Key.** Copy these down carefully, especially the Homelab Private Key, as it will be immediately deleted from the VPS for security.
    * **Test your new SSH connection to the VPS on the new port (`9001` or whatever you chose) immediately** before closing your current SSH session. If you get locked out, you'll need to use your VPS provider's console.

### Step 2: Prepare your Homelab Server

1.  **SSH into your Homelab server.**

2.  **Download the Homelab setup script:**
    ```
    curl -sL https://raw.githubusercontent.com/D0H-org/D0H-Scripts/refs/heads/main/VPS-HomeLab-Tunnel-For-Static-IP/Homelab-Setup.sh | bash```
    ```

    * The script will prompt you for your **VPS's Public IP, SSH username, and SSH password**. This is used to fetch keys and deploy the port management script.
    * It will install necessary prerequisites on your homelab, configure WireGuard, and start the service.
    * **IMPORTANT SECURITY NOTE:** The script will confirm that UFW and Fail2Ban on the homelab are stopped/disabled. This means **all external security relies on your VPS**. If your VPS is compromised, your homelab services would be directly exposed through the tunnel. Ensure your VPS is well-secured.

### Step 3: Manage Port Forwarding (from Homelab)

After the `Homelab-Setup.sh` completes its initial setup, it will present an interactive menu for managing ports on the VPS.

You can use the following commands in the interactive prompt:

* **`add <port_number> <protocol>`**: Adds a DNAT rule on the VPS to forward traffic from the VPS's public IP on `<port_number>` (TCP or UDP) to your homelab's WireGuard IP (`10.0.0.2` or `fd42:42:42::2`) on the same port.
    * Example: `add 80 tcp` (for HTTP)
    * Example: `add 443 tcp` (for HTTPS)
    * Example: `add 53 udp` (for DNS)
    * Example for ranges: `add "8080-8085" tcp` (note quotes for ranges)

* **`remove <port_number> <protocol>`**: Removes a previously added DNAT rule.
    * Example: `remove 80 tcp`
    * Example for ranges: `remove "8080-8085" tcp`

* **`list`**: Displays all active port forwarding (DNAT) rules on your VPS.

* **`done`**: Exits the port management interface.

**How it works (behind the scenes):**
When you `add` or `remove` a port, the `Homelab-Setup.sh` remotely executes the `manage_vps_forwarded_ports.sh` script on your VPS. This script updates the `nftables` rules. Immediately after, the `Homelab-Setup.sh` launches a temporary helper script on the VPS via `screen -dm` (detached mode) to restart the WireGuard service. This restart applies the new `nftables` rules. Your SSH session on the homelab won't drop because the WireGuard restart on the VPS happens in a separate, detached process. The homelab script then waits 30 seconds and attempts to reconnect to verify the changes.

## Security Considerations

* **VPS as Single Point of Failure:** Your VPS is now the critical security gateway. A compromise of your VPS means your homelab could become directly exposed. Ensure your VPS has:
    * Very strong, unique SSH credentials (preferably SSH keys only).
    * Regular security updates.
    * Minimal services running on it beyond what's strictly necessary for this gateway function.

* **Homelab Internal Security:** While external threats are filtered by the VPS, ensure your homelab still has basic internal security (e.g., proper user permissions, up-to-date software, internal firewall if exposing services to other local network segments not behind the tunnel).

* **VPS Provider Firewall:** Do not forget to configure your VPS provider's external firewall (security groups, ACLs) to only allow traffic to your chosen SSH port and the WireGuard UDP port (51820), and any other public ports you explicitly forward.

## Troubleshooting

* **SSH Disconnections:** If you experience frequent SSH disconnections when directly working on the VPS, use `screen` or `tmux` on the VPS to run commands that might restart network services.

* **WireGuard Tunnel Not Working:**
    * Check `sudo systemctl status wg-quick@wg0` on both VPS and homelab.
    * Check `sudo wg show` on both to see if a handshake occurred (`latest handshake` field).
    * Verify `nftables` rules on the VPS: `sudo nft list ruleset`.
    * Ensure VPS provider's firewall allows required inbound ports (SSH, WireGuard).
    * Double-check IP addresses and public keys in `wg0.conf` files on both sides.

* **Services Not Accessible:**
    * Verify the port forwarding rule is correctly added on the VPS (`sudo nft list ruleset | grep 'prerouting'`).
    * Ensure the service is actually listening on the correct port on your homelab.
    * Check if any local firewall on the homelab (if you re-enabled it) is blocking the inbound traffic on the `wg0` interface. (In this setup, UFW and Fail2Ban are explicitly disabled on the homelab for simplicity, but if you deviated, check them).
