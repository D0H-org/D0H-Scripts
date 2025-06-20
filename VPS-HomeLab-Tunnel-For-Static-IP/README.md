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

1.  **`VPS-Setup.sh` / `VPS-Setup-With-Pangolin.sh`**:

    * **Runs On:** Your **VPS**.

    * **Purpose:** Sets up the VPS side of the WireGuard tunnel, including network configurations (`nftables`), SSH hardening, and Fail2Ban for the VPS itself. It also pre-generates the WireGuard keys needed for the homelab client. The `VPS-Setup-With-Pangolin.sh` script also includes an *optional* installation of the Pangolin stack.

2.  **`Homelab-Setup.sh`**:

    * **Runs On:** Your **Homelab server** (standard Linux distribution like Ubuntu).

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

2.  **Download and run the VPS setup script.** Choose the appropriate script based on whether you want to install Pangolin:

    * **For a standard VPS Gateway (no Pangolin installation):**
        ```
        curl -sL https://raw.githubusercontent.com/D0H-org/D0H-Scripts/refs/heads/main/VPS-HomeLab-Tunnel-For-Static-IP/VPS-Setup.sh | bash
        ```

    * **For a VPS Gateway with optional Pangolin installation:**
        ```
        curl -sL https://raw.githubusercontent.com/D0H-org/D0H-Scripts/refs/heads/main/VPS-HomeLab-Tunnel-For-Static-IP/VPS-Setup-With-Pangolin.sh | bash
        ```

    * Follow the prompts for your chosen script. It will detect your public interface and IP, ask you to confirm, and then proceed with installing WireGuard, `nftables`, Fail2Ban, and changing your SSH port.

    * **Crucially, it will output your Homelab Client WireGuard Private Key and the VPS WireGuard Public Key.** Copy these down carefully, especially the Homelab Private Key, as it will be immediately deleted from the VPS for security.

    * **Test your new SSH connection to the VPS on the new port (`9001` or whatever you chose) immediately** before closing your current SSH session. If you get locked out, you'll need to use your VPS provider's console.

### Step 2: Prepare your Homelab Server (Choose One Option Below)

You have two primary ways to set up your homelab as the WireGuard client: a standard Linux distribution or an OPNsense firewall appliance.

#### Option A: Standard Linux Setup (using `Homelab-Setup.sh`)

This is the default setup where your homelab runs a standard Linux distribution (like Ubuntu).

1.  **SSH into your Homelab server.**

2.  **Download the Homelab setup script:**
    ```
    curl -sL https://raw.githubusercontent.com/D0H-org/D0H-Scripts/refs/heads/main/VPS-HomeLab-Tunnel-For-Static-IP/Homelab-Setup.sh | bash
    ```

    * The script will prompt you for your **VPS's Public IP, SSH username, and SSH password**. This is used to fetch keys and deploy the port management script.

    * It will install necessary prerequisites on your homelab, configure WireGuard, and start the service.

    * **IMPORTANT SECURITY NOTE:** The script will confirm that UFW and Fail2Ban on the homelab are stopped/disabled. This means **all external security relies on your VPS**. If your VPS is compromised, your homelab services would be directly exposed through the tunnel. Ensure your VPS is well-secured.

#### Option B: OPNsense Firewall Alternative

This is an alternative setup where your homelab uses OPNsense as its network gateway, providing a robust firewall and routing solution with a web-based GUI. In this scenario, the `Homelab-Setup.sh` script is NOT used for configuring WireGuard on the homelab.

1.  **Install OPNsense:**

    * Download the OPNsense ISO from its [official website](https://opnsense.org/download/).

    * Install OPNsense on a dedicated physical machine with at least two network interfaces (one for the WireGuard WAN, one for your internal LAN) or as a virtual machine within a hypervisor (e.g., Proxmox, ESXi, VirtualBox, KVM).

    * Configure OPNsense's initial network interfaces (e.g., assign one interface to WAN/Internet, another to LAN for your internal homelab network).

2.  **Configure WireGuard Client on OPNsense:**

    * Access the OPNsense web GUI (usually via its LAN IP address).

    * Navigate to **VPN -> WireGuard**.

    * **Create a new Local Configuration (Tunnel):**

        * Set `Listen Port` to 51820 (or any chosen port if different, but 51820 is standard).

        * Set `Address` to your homelab's WireGuard IP (e.g., `10.0.0.2/32` and `fd42:42:42::2/128`).

        * Copy the `PrivateKey` for the homelab client that was output by the `VPS-Setup.sh` (or `VPS-Setup-With-Pangolin.sh`) script (from Step 1). Paste this into OPNsense.

    * **Add a new Peer (for the VPS):**

        * Set `Public Key` to the VPS's WireGuard Public Key (obtained from `VPS-Setup.sh` or `VPS-Setup-With-Pangolin.sh` output).

        * Set `Endpoint` to your VPS's public IP address and WireGuard port (e.g., `YOUR_VPS_PUBLIC_IP:51820`).

        * Set `Allowed IPs` to `0.0.0.0/0, ::/0` to route all traffic through the tunnel.

        * Set `Persistent Keepalive` to 25.

    * **Enable WireGuard:** Ensure the WireGuard service is enabled and applied in OPNsense.

3.  **Configure OPNsense Firewall and NAT/Reverse Proxy:**

    * In OPNsense, navigate to **Firewall -> Rules** and create rules to allow traffic through the WireGuard interface (`wg0` or whatever OPNsense names it) to your internal homelab network.

    * Configure **NAT -> Port Forward** rules within OPNsense to direct incoming traffic from the WireGuard tunnel's IP (`10.0.0.2`) to your specific internal homelab services (e.g., `192.168.1.100:8080`).

    * For routing domains, you can install and configure a reverse proxy plugin (like **HAProxy** which is available as a plugin in OPNsense under **System -> Firmware -> Plugins**) within OPNsense. This will provide a user-friendly GUI for managing domain-based routing directly on your homelab.

    * The `nftables` rules on your VPS will forward traffic from the internet to OPNsense's WireGuard IP (`10.0.0.2`), and OPNsense will then forward it to the actual internal IP and port of your service.

**Important Note for OPNsense Setup:**
When using OPNsense, the `Homelab-Setup.sh` script (for the standard Linux setup) is **not** used to configure WireGuard. All WireGuard client configuration, including key management and peer setup, is handled directly within the OPNsense web GUI. Furthermore, the `manage_vps_forwarded_ports.sh` script (which is deployed by `Homelab-Setup.sh` during its initial run) becomes irrelevant for *dynamically* managing external port forwarding from the VPS's public IP to OPNsense's WireGuard IP. Only the initially setup ports (53, 20-52, 54-79, 81-442, 444-9000) as configured by `VPS-Setup-With-Pangolin.sh` will be forwarded. This configuration **explicitly excludes ports 80 and 443 from direct `nftables` forwarding** to allow for a separate application, such as a Pangolin stack, to manage web traffic on those ports independently. OPNsense will then be solely responsible for routing and further port forwarding/reverse proxying this traffic to your internal homelab services. 
Or ports (53, 20-52, 54-9000)`VPS-Setup.sh` unless manually modified will be forwarded. 

### Step 3: Manage Port Forwarding (from Homelab)

After the `Homelab-Setup.sh` (for standard Linux homelab) or your OPNsense setup completes its initial WireGuard configuration, you can manage port forwarding.

If you are using the standard Linux homelab setup, the `Homelab-Setup.sh` provides an interactive menu:

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

### Step 4 (Optional): Configure Pangolin for Advanced Application Exposure

If you chose to install the Pangolin stack during the `VPS-Setup-With-Pangolin.sh` script execution in **Step 1**, this section guides you through its configuration for advanced application exposure.

Pangolin (a self-hosted tunneled reverse proxy with identity and access management) on your VPS allows for simpler domain/subdomain routing and secure access control for your web-based homelab services, especially useful if you are behind CGNAT or prefer a management GUI for exposing applications.

1.  **Access Pangolin's Web UI:**
    * During the `VPS-Setup-With-Pangolin.sh` script, you provided a domain name for Pangolin (e.g., `pangolin.yourdomain.com`).
    * **Crucially, set up a DNS `A` record for this domain** (e.g., `pangolin.yourdomain.com`) to point to your **VPS's public IP address**.
    * Once DNS has propagated (this can take a few minutes to a few hours), open a web browser and navigate to `https://your_pangolin_domain.com`.
    * Log in with the admin email and password you set during the script execution.

2.  **Install Newt Client on Your Homelab:**
    Pangolin uses `Newt` as its lightweight client to establish the secure tunnel from your homelab. You should install Newt on a machine within your homelab that has access to the services you want to expose. This is typically done via Docker.

    * **From your Pangolin Web UI:**
        * After logging in, go to the "Sites" section.
        * Click "Add Site" and give it a name (e.g., "Homelab Applications").
        * When prompted for the connection method, choose "Newt".
        * Pangolin will provide you with a `Newt ID`, `Newt Secret`, and the `Pangolin Endpoint URL`. **Copy these values carefully.**

    * **On your Homelab Server (Linux with Docker installed):**
        * Create a directory for your Newt configuration:
            ```bash
            mkdir -p ~/newt
            cd ~/newt
            ```
        * Create a `docker-compose.yml` file for Newt. Replace the placeholder values with the `Newt ID`, `Newt Secret`, and `Pangolin Endpoint URL` you obtained from the Pangolin UI:
            ```yaml
            # ~/newt/docker-compose.yml
            version: '3.8'

            services:
              newt:
                image: fosrl/newt:latest
                container_name: newt
                restart: unless-stopped
                environment:
                  - PANGOLIN_ENDPOINT=<YOUR_PANGOLIN_ENDPOINT_URL>
                  - NEWT_ID=<YOUR_NEWT_ID>
                  - NEWT_SECRET=<YOUR_NEWT_SECRET>
                # If you want Newt to auto-discover Docker containers, uncomment the volume below.
                # WARNING: This gives Newt access to your Docker socket, which has security implications.
                # - /var/run/docker.sock:/var/run/docker.sock:ro
            ```
        * Start the Newt container:
            ```bash
            sudo docker compose up -d
            ```
        * Verify Newt is running and connected (check Pangolin UI, the site should show as "Online").

3.  **Add Resources in Pangolin:**
    * Back in the Pangolin Web UI, go to the "Resources" section.
    * Click "Add Resource".
    * **Name:** A descriptive name for your service (e.g., "Jellyfin Web UI").
    * **Site:** Select the site you created in step 2 (e.g., "Homelab Applications").
    * **Subdomain:** The subdomain you want to use for this service (e.g., `jellyfin`). This will create `jellyfin.your_pangolin_domain.com`.
    * **Local Address:** The internal IP address and port of your service in your homelab (e.g., `192.168.1.100:8096` for Jellyfin). **This IP must be reachable from the machine where Newt is running.**
    * **Enable SSL:** Recommended for web services (Pangolin will handle Let's Encrypt for this subdomain).
    * Configure any desired authentication or access control rules within Pangolin.
    * Click "Create Resource".

4.  **DNS for Resources:**
    * For each resource you create, Pangolin generates a subdomain (e.g., `jellyfin.your_pangolin_domain.com`).
    * You **must** create a DNS `CNAME` record for each of these subdomains, pointing them to your main `pangolin.yourdomain.com` (e.g., `jellyfin.yourdomain.com CNAME pangolin.yourdomain.com`).
    * This tells internet users to route requests for your services through Pangolin's entry point on your VPS.

### Firewall Considerations (VPS Side)

* The `VPS-Setup-With-Pangolin.sh` script is designed to **not** forward ports 80 (HTTP) and 443 (HTTPS) through the WireGuard tunnel by default. This allows Pangolin to bind to these ports directly on your VPS.
* **You MUST ensure that your VPS provider's external firewall (security groups, ACLs) allows inbound TCP traffic on ports 80 and 443** to your VPS's public IP address for Pangolin to function correctly.


### Masternode Hosting (Important Distinction)

* For **masternodes** or other services that require direct, low-level TCP/UDP port forwarding without application-level proxying, continue to use the **port management script (`manage_vps_forwarded_ports.sh`) from your Homelab server**.
* These specific masternode ports will be forwarded by `nftables` on the VPS directly to your homelab via the original WireGuard tunnel, bypassing Pangolin's reverse proxy logic. This is generally the preferred method for such sensitive, non-HTTP/S protocols.

## Security Considerations

* **VPS as Single Point of Failure:** Your VPS is now the critical security gateway. A compromise of your VPS means your homelab could become directly exposed. Ensure your VPS has:

  * Very strong, unique SSH credentials (preferably SSH keys only).

  * Regular security updates.

  * Minimal services running on it beyond what's strictly necessary for this gateway function.

* **Homelab Internal Security:** While external threats are filtered by the VPS, ensure your homelab still has basic internal security (e.g., proper user permissions, up-to-date software, internal firewall if exposing services to other local network segments not behind the tunnel). When using OPNsense, its robust firewall capabilities will manage internal network security.

* **VPS Provider Firewall:** Do not forget to configure your VPS provider's external firewall (security groups, ACLs) to only allow traffic to your chosen SSH port and the WireGuard UDP port (51820), and any other public ports you explicitly forward.

## Troubleshooting

* **SSH Disconnections:** If you experience frequent SSH disconnections when directly working on the VPS, use `screen` or `tmux` on the VPS to run commands that might restart network services.

* **WireGuard Tunnel Not Working:**

  * Check `sudo systemctl status wg-quick@wg0` on the VPS.

  * On the Homelab (standard Linux) or OPNsense, check WireGuard status (e.g., `sudo wg show` or OPNsense GUI status).

  * Verify `nftables` rules on the VPS: `sudo nft list ruleset`.

  * Ensure VPS provider's firewall allows required inbound ports (SSH, WireGuard).

  * Double-check IP addresses and public keys in `wg0.conf` files (or OPNsense configuration) on both sides.

  * If using OPNsense, verify its internal firewall rules and routing.

* **Services Not Accessible:**

  * Verify the port forwarding rule is correctly added on the VPS (`sudo nft list ruleset | grep 'prerouting'`).

  * Ensure the service is actually listening on the correct port on your homelab.

  * Check if any local firewall on the homelab (if you re-enabled it) is blocking the inbound traffic on the `wg0` interface. (In the standard Linux setup, UFW and Fail2Ban are explicitly disabled on the homelab for simplicity, but if you deviated, check them).

  * If using OPNsense, ensure its internal NAT and firewall rules are correctly forwarding traffic from its WireGuard interface to your service's internal IP and port.

* **"sshpass: command not found"**: Install it on your homelab: `sudo apt install sshpass`.

## Uninstalling the Setup

(No Uninstall for the VPS with Pangolin at this moment)
If you need to revert the changes made by these setup scripts on either your VPS or your Homelab, you can use the unified uninstall script. **Always take a snapshot/backup before running this script, especially for the VPS.**

### Unified Uninstall Script (`WG-Script-Remover.sh`)

This single script can uninstall the setup from either your VPS or your Homelab, depending on your choice.

1.  **Download the script to the system you want to uninstall (either your VPS or your Homelab):**

    ```
    curl -sL https://raw.githubusercontent.com/D0H-org/D0H-Scripts/refs/heads/main/VPS-HomeLab-Tunnel-For-Static-IP/WG-Script-Remover.sh | bash
    ```

2.  **Follow the prompt:** The script will ask you whether you are uninstalling the **VPS Gateway** or the **Homelab Client**. Enter `1` for VPS or `2` for Homelab.

    * **If uninstalling VPS:**

        * The script will remove WireGuard, its configurations, `nftables` rules related to the setup, Fail2Ban, and attempt to restore your SSH port to its state before setup (or default to port 22 if no backup found).

        * You may experience a brief SSH disconnection when services restart.

        * If UFW was active on the VPS before setup, it will not be re-enabled by this script; you would need to reinstall and configure it manually if desired.

    * **If uninstalling Homelab:**

        * The script will remove WireGuard and its client configurations.

        * Since UFW and Fail2Ban were disabled on the homelab by the setup script, this uninstall script will confirm their state but will **not** re-enable them. You may need to manually re-enable and configure them on your homelab if you wish to use them again.

This unified script aims to simplify the cleanup process for your homelab gateway set