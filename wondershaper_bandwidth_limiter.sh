#!/bin/bash

# Script Name: wondershaper_bandwidth_limiter.sh
# Description: This script helps manage your Ubuntu 22.04 - 25.10 or Debian 11 - 12 server
#              monthly bandwidth by calculating a target connection speed and applying it
#              using wondershaper. It ensures the limits are persistent across reboots
#              by configuring a systemd service.
#
# Usage: ./wondershaper_bandwidth_limiter [OPTIONS] <bandwidth_value> <unit>
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
#   - wondershaper: The script will check for its installation and offer to install it.
#   - sudo privileges: Required for installing wondershaper and configuring systemd.
#   - awk: For floating-point arithmetic (usually pre-installed on most Linux systems).
#
# Persistence:
#   The script configures a systemd service to make the wondershaper limits
#   persistent across system reboots.
#
# Notes:
#   - The calculated speed is an ESTIMATE. Actual usage can vary.
#   - The percentage multiplier allows for burstable speeds, but consistent usage
#     at this rate will likely exceed your monthly quota depending on your setting.
#   - You can clear current limits with: sudo wondershaper clear <interface>
#   - To disable persistence: sudo systemctl disable --now wondershaper.service

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
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo 
    echo "Options (can be used instead of or in combination with positional arguments):"
    echo "  -b, --bandwidth-value <value>   : Set the monthly bandwidth value (e.g., 100)."
    echo "  -u, --unit <unit>               : Set the bandwidth unit ('GB' or 'TB')."
    echo "  -d, --download-unmetered <bool> : Set download as unmetered ('true' or 'false')."
    echo "                                    If 'true', download is unlimited, upload gets 100% of calculated speed."
    echo "                                    If 'false', download and upload limits are set based on split."
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
    echo "  - wondershaper: The script will check for its installation and offer to install it."
    echo "  - sudo privileges: Required for installing wondershaper and configuring systemd."
    echo "  - awk: For floating-point arithmetic (usually pre-installed on most Linux systems)."
    echo ""
    echo "Persistence:"
    echo "  The script configures a systemd service to make the wondershaper limits"
    echo "  persistent across system reboots."
    echo ""
    echo "Notes:"
    echo "  - The calculated speed is an ESTIMATE. Actual usage can vary."
    echo "  - The percentage multiplier allows for burstable speeds, but consistent usage"
    echo "    at this rate will likely exceed your monthly quota depending on your setting."
    echo "  - You can clear current limits with: sudo wondershaper clear <interface>"
    echo "  - To disable persistence: sudo systemctl disable --now wondershaper.service"
    echo "  - Then you might want to remove the config and service files manually if desired."
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
    SPEED_PERCENTAGE=$DEFAULT_SPEED_PERCENTAGE
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
TARGET_SPEED_KBPS=$(awk "BEGIN {printf \"%.0f\n\", $TARGET_SPEED_MBPS * 125}")

echo "--- Bandwidth Calculation ---"
echo "Monthly Bandwidth: $BANDWIDTH_VALUE $UNIT"
echo "Equivalent Gigabits per month: ${BANDWIDTH_GIGABITS_MONTH} Gb"
echo "Seconds in a month (approx 30 days): $SECONDS_IN_MONTH seconds"
echo "-----------------------------"
echo "Average sustained speed to use all bandwidth: ${AVERAGE_SPEED_GBPS} Gbps"
echo "Target connection speed (${SPEED_PERCENTAGE}% of average): ${TARGET_SPEED_MBPS} Mbps"
echo "This translates to approximately ${TARGET_SPEED_KBPS} KB/s for wondershaper."
echo ""

# --- Wondershaper Installation Check ---
echo "Checking for wondershaper installation..."
if ! command -v wondershaper &> /dev/null; then
    echo "wondershaper is not installed."
    read -p "Do you want to install wondershaper now? (y/N): " install_choice
    if [[ "$install_choice" =~ ^[Yy]$ ]]; then
        echo "Attempting to install wondershaper..."
        sudo apt update && sudo apt install wondershaper -y
        if [ $? -ne 0 ]; then
            echo "Error: Failed to install wondershaper. Please install it manually and try again."
            exit 1
        fi
        echo "wondershaper installed successfully."
    else
        echo "wondershaper is required. Exiting."
        exit 1
    fi
else
    echo "wondershaper is already installed."
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
DOWNLOAD_LIMIT_KB="" # Initialize
UPLOAD_LIMIT_KB=""   # Initialize
UNMETERED_DL_CONFIRMED="" # To store final decision

if [ -n "$CLI_DOWNLOAD_UNMETERED" ]; then
    if [ "$CLI_DOWNLOAD_UNMETERED" = "true" ]; then
        UNMETERED_DL_CONFIRMED="y"
    else
        UNMETERED_DL_CONFIRMED="n"
    fi
else
    read -p "Is your download bandwidth unmetered? (y/N): " UNMETERED_DL_CONFIRMED
fi

if [[ "$UNMETERED_DL_CONFIRMED" =~ ^[Yy]$ ]]; then
    DOWNLOAD_LIMIT_KB=999999999 # A very high number to simulate unlimited download
    UPLOAD_LIMIT_KB=$TARGET_SPEED_KBPS # Upload gets 100% of the calculated speed
    echo "Download limit set to effectively unlimited."
    echo "Upload limit will be set to ${UPLOAD_LIMIT_KB} KB/s."
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
    DOWNLOAD_LIMIT_KB=$(awk "BEGIN {printf \"%.0f\n\", $TARGET_SPEED_KBPS * ($DL_PERCENT / 100)}")
    UPLOAD_LIMIT_KB=$(awk "BEGIN {printf \"%.0f\n\", $TARGET_SPEED_KBPS * ($UL_PERCENT / 100)}")

    echo "Download limit will be set to ${DOWNLOAD_LIMIT_KB} KB/s (${DL_PERCENT}% of calculated total)."
    echo "Upload limit will be set to ${UPLOAD_LIMIT_KB} KB/s (${UL_PERCENT}% of calculated total)."
fi
echo ""

# --- Apply Wondershaper Limits (Immediate) ---
echo "Applying wondershaper limits to $SELECTED_NIC immediately..."
echo "Command: sudo wondershaper $SELECTED_NIC $DOWNLOAD_LIMIT_KB $UPLOAD_LIMIT_KB"

sudo wondershaper "$SELECTED_NIC" "$DOWNLOAD_LIMIT_KB" "$UPLOAD_LIMIT_KB"

if [ $? -eq 0 ]; then
    echo "Wondershaper limits applied successfully for the current session."
    echo "Current limits for $SELECTED_NIC:"
    sudo wondershaper "$SELECTED_NIC" status
else
    echo "Error: Failed to apply wondershaper limits for the current session."
    exit 1
fi

echo ""

# --- Configure Wondershaper Persistence with Systemd ---
echo "Configuring wondershaper for persistence across reboots using systemd..."

# Create wondershaper.conf file
echo "Creating /etc/systemd/wondershaper.conf..."
sudo bash -c "cat <<EOF > /etc/systemd/wondershaper.conf
[wondershaper]
# Adapter
IFACE=\"$SELECTED_NIC\"
# Download rate in Kbps
DSPEED=\"$DOWNLOAD_LIMIT_KB\"
# Upload rate in Kbps
USPEED=\"$UPLOAD_LIMIT_KB\"
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
ExecStart=/usr/sbin/wondershaper $IFACE $DSPEED $USPEED
ExecStop=/usr/sbin/wondershaper clear $IFACE

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
echo "   Then you might want to remove the config and service files manually if desired."
