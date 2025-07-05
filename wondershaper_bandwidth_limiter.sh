#!/bin/bash

# Script Name: wondershaper_bandwidth_limiter.sh
# Description: This script helps manage your Ubuntu 22.04 - 25.10 or Debian 11 - 12 server
#              monthly bandwidth by calculating a target connection speed and applying it
#              using wondershaper. It ensures the limits are persistent across reboots
#              by configuring a systemd service.
#
# Usage: ./wondershaper_bandwidth_limiter.sh [OPTIONS] <bandwidth_value> <unit>
#
# Arguments:
#   <bandwidth_value>: The numeric value of your total monthly bandwidth (e.g., 100, 1).
#   <unit>: The unit of bandwidth, either 'GB' for Gigabytes or 'TB' for Terabytes.
#           These two arguments are mandatory if no corresponding options are used.
#
# Options (can be used instead of or in combination with positional arguments):
#   -b, --bandwidth-value <value>   : Set the monthly bandwidth value (e.g., 100).
#   -u, --unit <unit>               : Set the bandwidth unit ('GB' or 'TB').
#   -d, --download-unmetered <bool> : Set download as unmetered ('true' or 'false').
#                                     If 'true', download is unlimited, upload gets 100% of calculated speed.
#                                     If 'false', download and upload limits are set based on split.
#   -s, --split <DL_perc>/<UL_perc> : Set download/upload percentage split (e.g., '70/30').
#                                     Only applies if download is NOT unmetered.
#                                     Percentages must be positive and sum to 100.
#   -p, --percentage-limit <perc>   : Set the overall speed limit percentage (e.g., 140 for 140%).
#                                     Default is 140%.
#   -e, --interface <name>          : Set the network interface name (e.g., 'eth0', 'enp0s3').
#   -h, --help                      : Display this help message and exit.
#
# Examples:
#   Interactive mode (prompts for all details):
#     ./wondershaper_bandwidth_limiter.sh
#
#   Using positional arguments:
#     ./wondershaper_bandwidth_limiter.sh 100 GB
#
#   Using options for full control:
#     ./wondershaper_bandwidth_limiter.sh --bandwidth-value 1 TB --unit TB --percentage-limit 120 --interface eth0 --download-unmetered false --split 60/40
#
#   Using options for unmetered download:
#     ./wondershaper_bandwidth_limiter.sh -b 500 -u GB -p 150 -e enp0s3 -d true
#
# Requirements:
#   - wondershaper: This script will automatically install it from the official
#                   GitHub repository if not found or if an outdated version is detected.
#   - sudo privileges: Required for installing dependencies, wondershaper, and configuring systemd.
#   - awk: For floating-point arithmetic (usually pre-installed on most Linux systems).
#
# Persistence:
#   The script configures a systemd service to make the wondershaper limits
#   persistent across reboots.
#
# Notes:
#   - The calculated speed is an ESTIMATE. Actual usage can vary.
#   - The percentage multiplier allows for burstable speeds, but consistent usage
#     at this rate will likely exceed your monthly quota depending on your setting.
#   - You can clear current limits with: sudo wondershaper clear <interface>
#   - To disable persistence, run: sudo systemctl disable --now wondershaper.service

# --- Configuration ---
# Default multiplier for the calculated average speed
DEFAULT_SPEED_PERCENTAGE=140
# --- End Configuration ---

# --- Initialize variables for command-line arguments ---
CLI_BANDWIDTH_VALUE=""
CLI_UNIT=""
CLI_DOWNLOAD_UNMETERED="" # "true" or "false"
CLI_SPLIT_PERCENTAGES=""  # "DL/UL" e.g. "70/30"
CLI_SPEED_PERCENTAGE=""
CLI_INTERFACE=""

# --- Function to display usage instructions ---
usage() {
    echo "Script Name: wondershaper_bandwidth_limiter.sh"
    echo "Description: This script helps manage your Ubuntu 22.04 - 25.10 or Debian 11 - 12 server"
    echo "             monthly bandwidth by calculating a target connection speed and applying it"
    echo "             using wondershaper. It ensures the limits are persistent across reboots"
    echo "             by configuring a systemd service."
    echo ""
    echo "Usage: $0 [OPTIONS] <bandwidth_value> <unit>"
    echo ""
    echo "Arguments:"
    echo "  <bandwidth_value>: The numeric value of your total monthly bandwidth (e.g., 100, 1)."
    echo "  <unit>: The unit of bandwidth, either 'GB' for Gigabytes or 'TB' for Terabytes."
    echo "          These two arguments are mandatory if no corresponding options are used."
    echo ""
    echo "Options (can be used instead of or in combination with positional arguments):"
    echo "  -b, --bandwidth-value <value>   : Set the monthly bandwidth value (e.g., 100)."
    echo "  -u, --unit <unit>               : Set the bandwidth unit ('GB' or 'TB')."
    echo "  -d, --download-unmetered <bool> : Set download as unmetered ('true' or 'false')."
    echo "                                    If 'true', download is unlimited, upload gets 100% of calculated speed.
                                    If 'false', download and upload limits are set based on split."
    echo "  -s, --split <DL_perc>/<UL_perc> : Set download/upload percentage split (e.g., '70/30')."
    echo "                                    Only applies if download is NOT unmetered."
    echo "                                    Percentages must be positive and sum to 100."
    echo "  -p, --percentage-limit <perc>   : Set the overall speed limit percentage (e.g., 140 for 140%)."
    echo "                                    Default is 140%."
    echo "  -e, --interface <name>          : Set the network interface name (e.g., 'eth0', 'enp0s3')."
    echo "  -h, --help                      : Display this help message and exit."
    echo ""
    echo "Examples:"
    echo "  Interactive mode (prompts for all details):"
    echo "    ./wondershaper_bandwidth_limiter.sh"
    echo ""
    echo "  Using positional arguments:"
    echo "    ./wondershaper_bandwidth_limiter.sh 100 GB"
    echo ""
    echo "  Using options for full control:"
    echo "    ./wondershaper_bandwidth_limiter.sh --bandwidth-value 1 TB --unit TB --percentage-limit 120 --interface eth0 --download-unmetered false --split 60/40"
    echo ""
    echo "  Using options for unmetered download:"
    echo "    ./wondershaper_bandwidth_limiter.sh -b 500 -u GB -p 150 -e enp0s3 -d true"
    echo ""
    echo "Requirements:"
    echo "  - wondershaper: This script will automatically install it from the official"
    echo "                  GitHub repository if not found or if an outdated version is detected."
    echo "  - sudo privileges: Required for installing dependencies, wondershaper, and configuring systemd."
    echo "  - awk: For floating-point arithmetic (usually pre-installed on most Linux systems)."
    echo ""
    echo "Persistence:"
    echo "  The script configures a systemd service to make the wondershaper limits"
    echo "  persistent across reboots."
    echo ""
    echo "Notes:
    - The calculated speed is an ESTIMATE. Actual usage can vary."
    echo "  - The percentage multiplier allows for burstable speeds, but consistent usage"
    echo "    at this rate will likely exceed your monthly quota depending on your setting."
    echo "  - You can clear current limits with: sudo wondershaper clear <interface>"
    echo "  - To disable persistence, run: sudo systemctl disable --now wondershaper.service"
    exit 0 # Exit with 0 for successful help display
}

# --- Parse command-line arguments ---
# Using a while loop to handle both short and long options
while (( "$#" )); do
    case "$1" in
        -b|--bandwidth-value)
            if [ -n "$2" ] && ! [[ "$2" =~ ^- ]]; then
                CLI_BANDWIDTH_VALUE="$2"
                shift 2
            else
                echo "Error: --bandwidth-value requires a value."
                usage
            fi
            ;;
        -u|--unit)
            if [ -n "$2" ] && ! [[ "$2" =~ ^- ]]; then
                CLI_UNIT=$(echo "$2" | tr '[:lower:]' '[:upper:]')
                shift 2
            else
                echo "Error: --unit requires a value ('GB' or 'TB')."
                usage
            fi
            ;;
        -d|--download-unmetered)
            if [ -n "$2" ] && ! [[ "$2" =~ ^- ]]; then
                case $(echo "$2" | tr '[:lower:]' '[:upper:]') in
                    TRUE) CLI_DOWNLOAD_UNMETERED="true" ;;
                    FALSE) CLI_DOWNLOAD_UNMETERED="false" ;;
                    *)
                        echo "Error: --download-unmetered requires 'true' or 'false'."
                        usage
                        ;;
                esac
                shift 2
            else
                echo "Error: --download-unmetered requires a value ('true' or 'false')."
                usage
            fi
            ;;
        -s|--split)
            if [ -n "$2" ] && ! [[ "$2" =~ ^- ]]; then
                CLI_SPLIT_PERCENTAGES="$2"
                shift 2
            else
                echo "Error: --split requires a value (e.g., '70/30')."
                usage
            fi
            ;;
        -p|--percentage-limit)
            if [ -n "$2" ] && ! [[ "$2" =~ ^- ]]; then
                CLI_SPEED_PERCENTAGE="$2"
                shift 2
            else
                echo "Error: --percentage-limit requires a value."
                usage
            fi
            ;;
        -e|--interface)
            if [ -n "$2" ] && ! [[ "$2" =~ ^- ]]; then
                CLI_INTERFACE="$2"
                shift 2
            else
                echo "Error: --interface requires an interface name."
                usage
            fi
            ;;
        -h|--help)
            usage # Call usage function to display full help and exit
            ;;
        -*) # Unknown option
            echo "Error: Unknown option $1"
            usage
            ;;
        *) # Positional arguments (if not already set by options)
            if [ -z "$CLI_BANDWIDTH_VALUE" ]; then
                CLI_BANDWIDTH_VALUE="$1"
            elif [ -z "$CLI_UNIT" ]; then
                CLI_UNIT=$(echo "$1" | tr '[:lower:]' '[:upper:]')
            else
                echo "Error: Too many arguments provided."
                usage
            fi
            shift
            ;;
    esac
done

# --- Validate mandatory positional arguments if not set by options ---
if [ -z "$CLI_BANDWIDTH_VALUE" ] || [ -z "$CLI_UNIT" ]; then
    # If not enough arguments provided via CLI, prompt for usage
    if [ -z "$CLI_BANDWIDTH_VALUE" ] && [ -z "$CLI_UNIT" ]; then
        echo "No bandwidth value or unit provided via command line. Will prompt interactively."
    else
        echo "Missing bandwidth value or unit. Please provide both or use options."
        usage
    fi
fi

# --- Bandwidth Value Input (Interactive or CLI) ---
BANDWIDTH_VALUE=$CLI_BANDWIDTH_VALUE
if [ -z "$BANDWIDTH_VALUE" ]; then
    while true; do
        read -p "Enter your monthly bandwidth value (e.g., 100): " BANDWIDTH_VALUE
        if [[ "$BANDWIDTH_VALUE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            break
        else
            echo "Error: Bandwidth value must be a number."
        fi
    done
fi

# --- Unit Input (Interactive or CLI) ---
UNIT=$CLI_UNIT
if [ -z "$UNIT" ]; then
    while true; do
        read -p "Enter the unit (GB or TB): " UNIT
        UNIT=$(echo "$UNIT" | tr '[:lower:]' '[:upper:]')
        if [[ "$UNIT" == "GB" || "$UNIT" == "TB" ]]; then
            break
        else
            echo "Error: Invalid unit. Please use 'GB' or 'TB'."
        fi
    done
fi

# --- Overall Speed Percentage Input (Interactive or CLI) ---
SPEED_PERCENTAGE=${CLI_SPEED_PERCENTAGE:-$DEFAULT_SPEED_PERCENTAGE}
if [ -z "$CLI_SPEED_PERCENTAGE" ]; then
    read -p "Enter the percentage to limit the speed to (e.g., 140 for 140%). Default is ${DEFAULT_SPEED_PERCENTAGE}%: " user_percentage
    SPEED_PERCENTAGE=${user_percentage:-$DEFAULT_SPEED_PERCENTAGE}
fi

# Validate SPEED_PERCENTAGE
if ! [[ "$SPEED_PERCENTAGE" =~ ^[0-9]+$ ]] || [ "$SPEED_PERCENTAGE" -le 0 ]; then
    echo "Error: Percentage must be a positive number. Using default ${DEFAULT_SPEED_PERCENTAGE}%."
    SPEED_PERCENTAGE=$DEFAULT_PERCENTAGE
fi
SPEED_MULTIPLIER=$(awk "BEGIN {printf \"%.2f\n\", $SPEED_PERCENTAGE / 100}")

# --- Bandwidth Calculation ---
BANDWIDTH_GIGABITS_MONTH=0
case "$UNIT" in
    "GB")
        BANDWIDTH_GIGABITS_MONTH=$(awk "BEGIN {printf \"%.4f\n\", $BANDWIDTH_VALUE * 8}")
        ;;
    "TB")
        BANDWIDTH_GIGABITS_MONTH=$(awk "BEGIN {printf \"%.4f\n\", $BANDWIDTH_VALUE * 1024 * 8}")
        ;;
esac

SECONDS_IN_MONTH=$((30 * 24 * 60 * 60))
AVERAGE_SPEED_GBPS=$(awk "BEGIN {printf \"%.4f\n\", $BANDWIDTH_GIGABITS_MONTH / $SECONDS_IN_MONTH}")
TARGET_SPEED_GBPS=$(awk "BEGIN {printf \"%.4f\n\", $AVERAGE_SPEED_GBPS * $SPEED_MULTIPLIER}")
TARGET_SPEED_MBPS=$(awk "BEGIN {printf \"%.2f\n\", $TARGET_SPEED_GBPS * 1000}")

# Convert to Kilobits per second (Kbps) for wondershaper
# 1 Mbps = 1000 Kbps
TARGET_SPEED_KBPS_FOR_WONDERSHAPER=$(awk "BEGIN {printf \"%.0f\n\", $TARGET_SPEED_MBPS * 1000}")

echo "--- Bandwidth Calculation ---"
echo "Monthly Bandwidth: $BANDWIDTH_VALUE $UNIT"
echo "Equivalent Gigabits per month: ${BANDWIDTH_GIGABITS_MONTH} Gb"
echo "Seconds in a month (approx 30 days): $SECONDS_IN_MONTH seconds"
echo "-----------------------------"
echo "Average sustained speed to use all bandwidth: ${AVERAGE_SPEED_GBPS} Gbps"
echo "Target connection speed (${SPEED_PERCENTAGE}% of average): ${TARGET_SPEED_MBPS} Mbps"
echo "This translates to approximately ${TARGET_SPEED_KBPS_FOR_WONDERSHAPER} Kbps for wondershaper."
echo ""

# --- Wondershaper Installation/Update Logic ---
echo "Managing wondershaper installation..."

# Function to install a package
install_package() {
    local package_name=$1
    if ! command -v "$package_name" &> /dev/null; then
        echo "$package_name is not installed. Installing $package_name..."
        sudo apt update && sudo apt install -y "$package_name"
        if [ $? -ne 0 ]; then
            echo "Error: Failed to install $package_name. Please install it manually and try again."
            exit 1
        fi
        echo "$package_name installed successfully."
    fi
}

# Check for and remove apt-installed wondershaper if present
if apt list --installed wondershaper &> /dev/null; then
    echo "Detected existing wondershaper package from apt. It might be outdated."
    read -p "Do you want to remove the apt package and install the latest from GitHub? (Y/n): " remove_apt_choice
    remove_apt_choice=${remove_apt_choice:-Y}
    if [[ "$remove_apt_choice" =~ ^[Yy]$ ]]; then
        echo "Removing apt-installed wondershaper..."
        sudo apt remove --purge wondershaper -y
        if [ $? -ne 0 ]; then
            echo "Warning: Failed to remove apt-installed wondershaper. Continuing with GitHub install, but conflicts might occur."
        else
            echo "Apt-installed wondershaper removed."
        fi
    else
        echo "Keeping apt-installed wondershaper. Note: This might lead to unexpected behavior if it's an old version."
    fi
fi

# Ensure git and make are installed for source compilation
install_package git
install_package make

# Install wondershaper from GitHub if not already installed or if apt version was removed
if ! command -v wondershaper &> /dev/null || [[ "$remove_apt_choice" =~ ^[Yy]$ ]]; then
    echo "Installing/Reinstalling wondershaper from GitHub..."
    TEMP_DIR=$(mktemp -d)
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create temporary directory. Exiting."
        exit 1
    fi
    echo "Cloning wondershaper into $TEMP_DIR..."
    git clone https://github.com/magnific0/wondershaper.git "$TEMP_DIR/wondershaper"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to clone wondershaper repository. Exiting."
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    cd "$TEMP_DIR/wondershaper"
    sudo make install
    if [ $? -ne 0 ]; then
        echo "Error: Failed to install wondershaper from source. Please check the output above."
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    cd - > /dev/null # Go back to previous directory
    rm -rf "$TEMP_DIR" # Clean up temporary directory
    echo "wondershaper installed successfully from GitHub source."
else
    echo "Latest wondershaper from GitHub is already installed or opted to keep existing apt version."
fi
echo ""

# --- Clean up ifb0 device (moved here for earlier cleanup) ---
# Remove ifb0 device if it exists (newer wondershaper handles this internally)
# This ensures a clean state before kernel module checks or interface detection.
if ip link show ifb0 &> /dev/null; then
    echo "Removing existing ifb0 device (newer wondershaper manages this internally)..."
    sudo ip link set dev ifb0 down >/dev/null 2>&1
    sudo ip link delete ifb0 type ifb >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo "Warning: Failed to remove old ifb0 device. This might indicate lingering tc rules or a permission issue."
    else
        echo "Old ifb0 device removed."
    fi
fi
echo ""

# --- Kernel Module and tc functionality check ---
# Wondershaper relies on the sch_htb (Hierarchical Token Bucket) qdisc kernel module
# and the ifb (Intermediate Functional Block) module for ingress shaping.
echo "Verifying kernel modules and tc functionality..."

# Check and load sch_htb module
if ! lsmod | grep -q sch_htb; then
    echo "sch_htb kernel module not loaded. Attempting to load it..."
    sudo modprobe sch_htb
    if [ $? -ne 0 ]; then
        echo "Error: Failed to load sch_htb kernel module. This might be due to a custom kernel"
        echo "       or a virtualized environment that doesn't support it. Wondershaper may not work."
        read -p "Do you want to continue anyway? (y/N): " continue_choice
        if ! [[ "$continue_choice" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        echo "sch_htb module loaded successfully."
    fi
fi

# Check and load ifb module (crucial for download shaping)
# NOTE: The latest wondershaper manages ifb internally, but we ensure the module is loaded.
if ! lsmod | grep -q ifb; then
    echo "ifb kernel module not loaded. Attempting to load it (needed for download shaping by wondershaper)..."
    sudo modprobe ifb numifbs=1
    if [ $? -ne 0 ]; then
        echo "Error: Failed to load ifb kernel module. Download shaping might not work."
        read -p "Do you want to continue anyway? (y/N): " continue_choice
        if ! [[ "$continue_choice" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        echo "ifb module loaded successfully."
    fi
fi

# Basic tc functionality test
# Try to add a dummy qdisc and then delete it to ensure tc commands work.
DUMMY_IF="lo" # Use loopback interface for a safe test
echo "Performing a basic tc functionality test on $DUMMY_IF..."
sudo tc qdisc add dev "$DUMMY_IF" root handle 1:0 pfifo >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "Warning: Basic 'tc' command test failed on $DUMMY_IF. This could indicate an issue with"
    echo "         your kernel's traffic control support. Wondershaper might not function correctly."
    read -p "Do you want to continue anyway? (y/N): " continue_choice
    if ! [[ "$continue_choice" =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo "Basic tc functionality test passed."
    sudo tc qdisc del dev "$DUMMY_IF" root >/dev/null 2>&1 # Clean up
fi
echo ""

# --- Network Interface Detection and Selection (Interactive or CLI) ---
NETWORK_INTERFACES=($(ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo\|docker\|virbr\|veth' | sort))
if [ ${#NETWORK_INTERFACES[@]} -eq 0 ]; then
    echo "Error: No active network interfaces found (excluding loopback/virtual). Exiting."
    exit 1
fi

SELECTED_NIC=$CLI_INTERFACE
if [ -z "$SELECTED_NIC" ]; then
    echo "Detected network interfaces:"
    for i in "${!NETWORK_INTERFACES[@]}"; do
        echo "$((i+1))). ${NETWORK_INTERFACES[$i]}"
    done
    while true; do
        read -p "Please enter the number corresponding to your primary network interface: " nic_choice
        if [[ "$nic_choice" =~ ^[0-9]+$ ]] && [ "$nic_choice" -ge 1 ] && [ "$nic_choice" -le ${#NETWORK_INTERFACES[@]} ]; then
            SELECTED_NIC="${NETWORK_INTERFACES[$((nic_choice-1))]}"
            echo "You selected: $SELECTED_NIC"
            break
        else
            echo "Invalid choice. Please enter a number between 1 and ${#NETWORK_INTERFACES[@]}."
        fi
    done
else
    # Validate CLI_INTERFACE
    if ! printf '%s\n' "${NETWORK_INTERFACES[@]}" | grep -q -w "$SELECTED_NIC"; then
        echo "Error: Specified interface '$SELECTED_NIC' not found or is a virtual interface. Please choose from detected interfaces."
        SELECTED_NIC="" # Clear to trigger interactive prompt
        # Fallback to interactive selection
        echo "Detected network interfaces:"
        for i in "${!NETWORK_INTERFACES[@]}"; do
            echo "$((i+1))). ${NETWORK_INTERFACES[$i]}"
        done
        while true; do
            read -p "Please enter the number corresponding to your primary network interface: " nic_choice
            if [[ "$nic_choice" =~ ^[0-9]+$ ]] && [ "$nic_choice" -ge 1 ] && [ "$nic_choice" -le ${#NETWORK_INTERFACES[@]} ]; then
                SELECTED_NIC="${NETWORK_INTERFACES[$((nic_choice-1))]}"
                echo "You selected: $SELECTED_NIC"
                break
            else
                echo "Invalid choice. Please enter a number between 1 and ${#NETWORK_INTERFACES[@]}."
            fi
        done
    else
        echo "Using specified interface: $SELECTED_NIC"
    fi
fi
echo ""

# --- Unmetered Download Question (Interactive or CLI) ---
DOWNLOAD_LIMIT_KBPS="" # Initialize
UPLOAD_LIMIT_KBPS=""   # Initialize
UNMETERED_DL_CONFIRMED="" # To store final decision

if [ -n "$CLI_DOWNLOAD_UNMETERED" ]; then
    if [ "$CLI_DOWNLOAD_UNMETERED" = "true" ]; then
        UNMETERED_DL_CONFIRMED="y"
    else
        UNMETERED_DL_CONFIRMED="n"
    fi
else
    read -p "Is your download bandwidth unmetered? (y/N): " user_unmetered_choice
    UNMETERED_DL_CONFIRMED=${user_unmetered_choice:-N} # Default to N if empty input
fi

if [[ "$UNMETERED_DL_CONFIRMED" =~ ^[Yy]$ ]]; then
    DOWNLOAD_LIMIT_KBPS=999999999 # A very high number to simulate unlimited download
    UPLOAD_LIMIT_KBPS=$TARGET_SPEED_KBPS_FOR_WONDERSHAPER # Upload gets 100% of the calculated speed
    echo "Download limit set to effectively unlimited."
    echo "Upload limit will be set to ${UPLOAD_LIMIT_KBPS} Kbps."
else
    # If both are metered, ask for custom percentages or use CLI split
    DL_PERCENT=50
    UL_PERCENT=50

    if [ -n "$CLI_SPLIT_PERCENTAGES" ]; then
        # Parse CLI split
        IFS='/' read -r DL_PERCENT UL_PERCENT <<< "$CLI_SPLIT_PERCENTAGES"
        # Validate CLI split
        if ! [[ "$DL_PERCENT" =~ ^[0-9]+$ ]] || [ "$DL_PERCENT" -le 0 ] || \
           ! [[ "$UL_PERCENT" =~ ^[0-9]+$ ]] || [ "$UL_PERCENT" -le 0 ] || \
           $(awk "BEGIN {print ($DL_PERCENT + $UL_PERCENT) != 100}"); then
            echo "Error: Invalid split percentages '$CLI_SPLIT_PERCENTAGES'. Must be positive numbers summing to 100 (e.g., '70/30')."
            echo "Falling back to interactive percentage input."
            DL_PERCENT=50 # Reset to default for interactive
            UL_PERCENT=50
        else
            echo "Using specified split: Download ${DL_PERCENT}%, Upload ${UL_PERCENT}%."
        fi
    fi

    # Interactive percentage input (if not set by valid CLI split or if CLI split was invalid)
    if [ -z "$CLI_SPLIT_PERCENTAGES" ] || $(awk "BEGIN {print ($DL_PERCENT + $UL_PERCENT) != 100}"); then
        while true; do
            read -p "Enter download percentage (e.g., 70 for 70%). Default is ${DL_PERCENT}%: " user_dl_percent
            DL_PERCENT=${user_dl_percent:-$DL_PERCENT}

            read -p "Enter upload percentage (e.g., 30 for 30%). Default is ${UL_PERCENT}%: " user_ul_percent
            UL_PERCENT=${user_ul_percent:-$UL_PERCENT}

            # Validate percentages are numbers and positive
            if ! [[ "$DL_PERCENT" =~ ^[0-9]+$ ]] || [ "$DL_PERCENT" -le 0 ]; then
                echo "Error: Download percentage must be a positive number. Please re-enter."
                continue
            fi
            if ! [[ "$UL_PERCENT" =~ ^[0-9]+$ ]] || [ "$UL_PERCENT" -le 0 ]; then
                echo "Error: Upload percentage must be a positive number. Please re-enter."
                continue
            fi

            TOTAL_PERCENT=$(awk "BEGIN {print $DL_PERCENT + $UL_PERCENT}")
            if [ "$TOTAL_PERCENT" -ne 100 ]; then
                echo "Error: Download ($DL_PERCENT%) and Upload ($UL_PERCENT%) percentages must sum to 100%. Their current sum is ${TOTAL_PERCENT}%."
                echo "Please re-enter the percentages."
            else
                break
            fi
        done
    fi

    # Calculate limits based on custom percentages
    DOWNLOAD_LIMIT_KBPS=$(awk "BEGIN {printf \"%.0f\n\", $TARGET_SPEED_KBPS_FOR_WONDERSHAPER * ($DL_PERCENT / 100)}")
    UPLOAD_LIMIT_KBPS=$(awk "BEGIN {printf \"%.0f\n\", $TARGET_SPEED_KBPS_FOR_WONDERSHAPER * ($UL_PERCENT / 100)}")

    echo "Download limit will be set to ${DOWNLOAD_LIMIT_KBPS} Kbps (${DL_PERCENT}% of calculated total)."
    echo "Upload limit will be set to ${UPLOAD_LIMIT_KBPS} Kbps (${UL_PERCENT}% of calculated total)."
fi
echo ""

# --- Apply Wondershaper Limits (Immediate) ---
echo "Applying wondershaper limits to $SELECTED_NIC immediately..."
echo "Command: sudo wondershaper -a $SELECTED_NIC -d $DOWNLOAD_LIMIT_KBPS -u $UPLOAD_LIMIT_KBPS"

# Clear existing wondershaper rules before applying new ones
echo "Clearing any existing wondershaper rules on $SELECTED_NIC..."
sudo wondershaper -c -a "$SELECTED_NIC"

# Re-create and bring up ifb0 if download limiting is active (needed by wondershaper for ingress)
if [[ "$UNMETERED_DL_CONFIRMED" =~ ^[Nn]$ ]]; then # Only if download is NOT unmetered
    echo "Ensuring ifb0 interface is up for download shaping (needed by wondershaper)..."

    # Step 1: Remove any existing ifb0 to ensure a clean slate
    if ip link show ifb0 &> /dev/null; then
        echo "Found existing ifb0 device. Attempting to remove it for a clean setup..."
        sudo ip link set dev ifb0 down >/dev/null 2>&1
        sudo ip link delete ifb0 type ifb >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo "Warning: Failed to remove old ifb0 device. This might indicate lingering tc rules or a permission issue."
        else
            echo "Old ifb0 device removed."
        fi
    fi

    # Step 2: Create ifb0 if it doesn't exist after cleanup
    if ! ip link show ifb0 &> /dev/null; then
        echo "ifb0 device not found. Attempting to create it..."
        sudo ip link add ifb0 type ifb
        if [ $? -ne 0 ]; then
            echo "Error: Failed to create ifb0 device. Download shaping will not work. Exiting."
            exit 1
        fi
        echo "ifb0 device created."
        sleep 0.5 # Give a moment for the system to register the new device
    fi

    # Step 3: Ensure ifb0 is up
    if ip link show ifb0 | grep -q "state DOWN"; then
        echo "Bringing ifb0 interface up..."
        sudo ip link set dev ifb0 up
        if [ $? -ne 0 ]; then
            echo "Error: Failed to bring ifb0 interface up. Download shaping will not work. Exiting."
            exit 1
        fi
        echo "ifb0 interface is up."
        sleep 0.5 # Give a moment for the state change
    fi

    # Step 4: Verify ifb0 is actually present and up
    MAX_RETRIES=10
    RETRY_COUNT=0
    while ! ip link show ifb0 | grep -q "state UP" && [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
        echo "Waiting for ifb0 to be in UP state (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)..."
        sleep 1
        RETRY_COUNT=$((RETRY_COUNT+1))
    done

    if ! ip link show ifb0 | grep -q "state UP"; then
        echo "Error: ifb0 device is not in UP state after multiple attempts. Download shaping will likely fail. Exiting."
        exit 1
    else
        echo "ifb0 device confirmed to be present and UP."
    fi
fi

sudo wondershaper -a "$SELECTED_NIC" -d "$DOWNLOAD_LIMIT_KBPS" -u "$UPLOAD_LIMIT_KBPS"

if [ $? -eq 0 ]; then
    echo "Wondershaper limits applied successfully for the current session."
    echo "Current limits for $SELECTED_NIC:"
    sudo wondershaper -s -a "$SELECTED_NIC"
else
    echo "Error: Failed to apply wondershaper limits for the current session."
    echo "Please review the errors above. This might be due to kernel module issues or misconfiguration."
    exit 1
fi

echo ""

# --- Configure Wondershaper Persistence with Systemd ---
echo "Configuring wondershaper for persistence across reboots using systemd..."

# Clean up old systemd service and config files if they exist
echo "Checking for and cleaning up old wondershaper systemd configurations..."
if systemctl is-active --quiet wondershaper.service; then
    echo "Stopping active wondershaper.service..."
    sudo systemctl stop wondershaper.service
fi
if systemctl is-enabled --quiet wondershaper.service; then
    echo "Disabling wondershaper.service..."
    sudo systemctl disable wondershaper.service
fi
if [ -f "/etc/systemd/system/wondershaper.service" ]; then
    echo "Removing old /etc/systemd/system/wondershaper.service..."
    sudo rm "/etc/systemd/system/wondershaper.service"
fi
if [ -f "/etc/systemd/wondershaper.conf" ]; then
    echo "Removing old /etc/systemd/wondershaper.conf..."
    sudo rm "/etc/systemd/wondershaper.conf"
fi
sudo systemctl daemon-reload # Reload daemon after removing files
echo "Old systemd configurations cleaned up."

# Create wondershaper.conf file
echo "Creating /etc/systemd/wondershaper.conf..."
sudo bash -c "cat <<EOF > /etc/systemd/wondershaper.conf
[wondershaper]
# Adapter
IFACE=\"$SELECTED_NIC\"
# Download rate in Kbps
DSPEED=\"$DOWNLOAD_LIMIT_KBPS\"
# Upload rate in Kbps
USPEED=\"$UPLOAD_LIMIT_KBPS\"
EOF"

if [ $? -ne 0 ]; then
    echo "Error: Failed to create /etc/systemd/wondershaper.conf. Exiting."
    exit 1
fi
echo "/etc/systemd/wondershaper.conf created successfully."

# Create wondershaper.service file
echo "Creating /etc/systemd/system/wondershaper.service..."
sudo bash -c 'cat <<EOF > /etc/systemd/system/wondershaper.service
[Unit]
Description=Bandwidth shaper/Network rate limiter
After=network-online.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=/etc/systemd/wondershaper.conf
ExecStart=/usr/sbin/wondershaper -a $IFACE -d $DSPEED -u $USPEED
ExecStop=/usr/sbin/wondershaper -c -a $IFACE

[Install]
WantedBy=multi-user.target
EOF'

if [ $? -ne 0 ]; then
    echo "Error: Failed to create /etc/systemd/system/wondershaper.service. Exiting."
    exit 1
fi
echo "/etc/systemd/system/wondershaper.service created successfully."

# Reload systemd daemon and enable/start the service
echo "Reloading systemd daemon and enabling wondershaper service..."
sudo systemctl daemon-reload
sudo systemctl enable --now wondershaper.service

if [ $? -eq 0 ]; then
    echo "Wondershaper service enabled and started successfully. Limits will persist across reboots."
else
    echo "Error: Failed to enable or start wondershaper service. Please check systemd logs."
fi

echo ""
echo "--- IMPORTANT NOTES ---"
echo "1. Wondershaper limits are now configured to persist across reboots using systemd."
echo "2. The calculated speed is an ESTIMATE. Actual usage depends on many factors."
echo "3. The '$SPEED_PERCENTAGE%' multiplier means if you consistently use your connection at this speed,"
echo "   you can still exceed your monthly bandwidth quota depending on your setting."
echo "4. You can clear the limits at any time using: sudo wondershaper clear $SELECTED_NIC"
echo "   To disable persistence, run: sudo systemctl disable --now wondershaper.service"
