# D0H-Scripts

A collection of random utility scripts.

## 🚀 `proxmox-cpu-unit-updater.sh`

A command-line utility designed for Proxmox VE sysadmins to quickly adjust CPU shares (CPU units) for individual virtual machines. This script is particularly useful when one VM is unexpectedly consuming too many CPU resources, potentially impacting the performance of other virtual machines (the "noisy neighbor" problem).

### ✨ Features

* **Dynamic CPU Share Adjustment:** Easily modify a VM's CPU shares based on a percentage of the default `1024` (which typically represents 100% share in Proxmox).

* **GUI Synchronization:** Changes made via the script will be immediately reflected in the Proxmox web-based graphical user interface.

* **Performance Optimization:** Helps in mitigating performance bottlenecks caused by specific VMs, ensuring a fairer distribution of CPU resources across your Proxmox host.

### 💡 How it Works

The script assumes that a `cpuunits` value of `1024` corresponds to 100% CPU share. You provide a VM ID and a desired percentage, and the script calculates the new `cpuunits` value accordingly.

### 🛠️ Prerequisites

* **Proxmox VE Host:** This script must be run directly on your Proxmox VE host.

* **`qm` Command:** Relies on the Proxmox `qm` command-line tool, which is standard on Proxmox installations.

* **`htop` (Recommended):** While not strictly required for the script's execution, installing `htop` on your Proxmox host is highly recommended. It allows for quick identification of CPU-intensive VMs and their corresponding IDs, making it easier to pinpoint offending machines. You can usually install it with:

apt update && apt install htop


### 🏃‍♂️ Usage

./proxmox-cpu-unit-updater.sh &lt;VMID> &lt;PERCENTAGE_OF_1024>


* Replace `<VMID>` with the actual ID of the virtual machine you want to adjust.

* Replace `<PERCENTAGE_OF_1024>` with the desired CPU share as a percentage (e.g., `50` for 50% of 1024, which would set cpuunits to 512).

#### Example:

To set VM with ID `101` to 25% of the default CPU shares (equivalent to 256 cpuunits):

./proxmox-cpu-unit-updater.sh 101 25


### 🤝 Contributing

Feel free to fork this repository, open issues, or submit pull requests if you have improvements or other useful scripts to share
