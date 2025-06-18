#!/bin/bash

# This script allows you to set the CPU priority (cpuunits) of a Proxmox VM.
# It automatically detects the number of cores assigned to the VM (though not directly
# used in the cpuunits calculation, it's good for context) and calculates
# the appropriate 'cpuunits' value based on your desired percentage of a reference share.
# This method provides fair sharing and prioritization, reducing the risk of VM starvation
# compared to a hard 'cpulimit'.

# Function to display error messages and exit
function exit_with_error() {
    echo "Error: $1" >&2
    exit 1
}

# Check if the script is run as root
if [[ $EUID -ne 0 ]]; then
   exit_with_error "This script must be run as root. Please use 'sudo'."
fi

echo "----------------------------------------"
echo "Proxmox VM CPU Prioritizer (using cpuunits)"
echo "----------------------------------------"

# 1. Get VM ID from user
read -p "Enter the VM ID (e.g., 101): " VMID

# Validate VMID is a number
if ! [[ "$VMID" =~ ^[0-9]+$ ]]; then
    exit_with_error "Invalid VM ID. Please enter a numeric ID."
fi

# Check if the VM exists
if ! qm status "$VMID" &> /dev/null; then
    exit_with_error "VM with ID $VMID does not exist or is not accessible."
fi

# 2. Get the number of CPU cores for the specified VM (for context, not direct calculation)
echo "Fetching VM configuration for VMID $VMID..."
NUM_CORES=$(qm config "$VMID" | grep -w "cores:" | awk '{print $2}')

if [ -z "$NUM_CORES" ]; then
    echo "Warning: Could not determine the number of cores for VM $VMID. Proceeding without this context."
    NUM_CORES=1 # Default to 1 for safer display if calculation is needed later
fi

echo "VM $VMID has $NUM_CORES CPU core(s) assigned."

# 3. Get desired CPU percentage for prioritization from user
# We'll map this percentage to the cpuunits range.
# A common reference for 'full' share could be the default 1024 or 100 for cgroup v2.
# Let's use 1024 as a baseline for 100% input for illustrative purposes,
# though the actual cpuunits can go much higher (up to 262144).
# This provides a relative weight rather than an absolute limit.
read -p "Enter the desired CPU share percentage (0-100) for this VM relative to others: " CPU_PERCENT_SHARE

# Validate CPU_PERCENT_SHARE is a number and within 0-100
if ! [[ "$CPU_PERCENT_SHARE" =~ ^[0-9]+$ ]]; then
    exit_with_error "Invalid CPU share percentage. Please enter a numeric value."
fi

if (( CPU_PERCENT_SHARE < 0 || CPU_PERCENT_SHARE > 100 )); then
    exit_with_error "CPU share percentage must be between 0 and 100."
fi

# 4. Calculate the 'cpuunits' value for Proxmox
# We'll map 100% to the default value of 1024 for a baseline,
# which is a common and robust default for cpuunits.
# This means if you enter 50, it will set cpuunits to 512, etc.
# The minimum cpuunits is 1.
BASE_CPUUNITS=1024 # A common default/reference for 100% share
CALCULATED_CPUUNITS=$(awk "BEGIN {printf \"%.0f\", ($CPU_PERCENT_SHARE / 100.0) * $BASE_CPUUNITS}")

# Ensure cpuunits is at least 1, as 0 is not valid according to documentation.
# If user enters 0%, we'll set it to 1, as 0 cpuunits effectively means no CPU time.
if (( CALCULATED_CPUUNITS < 1 )); then
    CALCULATED_CPUUNITS=1
    echo "Warning: CPU share percentage 0% maps to minimum cpuunits of 1."
fi

# Max cpuunits allowed by Proxmox is 262144. Our scaling typically won't exceed this
# if input is 0-100% of BASE_CPUUNITS. However, we can add a cap for robustness.
MAX_CPUUNITS_ALLOWED=262144
if (( CALCULATED_CPUUNITS > MAX_CPUUNITS_ALLOWED )); then
    CALCULATED_CPUUNITS="$MAX_CPUUNITS_ALLOWED"
    echo "Warning: Calculated cpuunits exceeded max allowed ($MAX_CPUUNITS_ALLOWED) and was capped."
fi


echo "Desired CPU share percentage: $CPU_PERCENT_SHARE%"
echo "Calculated Proxmox 'cpuunits' value to apply: $CALCULATED_CPUUNITS"
echo "(This value determines the VM's CPU priority relative to other VMs on the host.)"


# 5. Apply the CPU units
echo "Applying CPU units for VM $VMID..."
if qm set "$VMID" --cpuunits "$CALCULATED_CPUUNITS"; then
    echo "Successfully set CPU units for VM $VMID to: $CALCULATED_CPUUNITS."
    echo "This setting provides CPU prioritization/fair sharing, not a hard limit."
else
    exit_with_error "Failed to set CPU units for VM $VMID. Please check Proxmox logs for more details (e.g., 'journalctl -u pveproxy' or '/var/log/syslog')."
fi

echo "----------------------------------------"
echo "Operation complete."
echo "----------------------------------------"
