#!/bin/bash

# Function to parse lscpu -e output and format it for display
parse_lscpu_output() {
    # Check if lscpu command exists
    if ! command -v lscpu &> /dev/null; then
        echo "Error: 'lscpu' command not found. Please ensure 'util-linux' is installed." >&2
        return 1
    fi

    # Use awk to parse the lscpu -e output
    # It dynamically finds column indices for robustness
    # and then groups logical CPUs by their physical core (NODE, SOCKET, CORE)
    lscpu -e 2>/dev/null | awk '
    BEGIN { OFS=" " } # Output Field Separator

    # Find the header line to determine column indices
    /^CPU/ {
        for (i=1; i<=NF; i++) {
            if ($i == "CPU") cpu_col = i;
            if ($i == "NODE") node_col = i;
            if ($i == "SOCKET") socket_col = i;
            if ($i == "CORE") core_col = i;
        }
        next # Skip header line
    }
    
    # Process data lines
    {
        # Extract values based on dynamically found column indices
        node = $(node_col);
        socket = $(socket_col);
        core = $(core_col);
        cpu = $(cpu_col);

        # Create a unique key for each physical core: NODE_SOCKET_CORE
        key = node "_" socket "_" core;
        
        # Aggregate CPU IDs for each key
        if (data[key] == "") {
            data[key] = cpu;
        } else {
            data[key] = data[key] " " cpu;
        }
    }

    # After processing all lines, print the collected data
    END {
        # Sort keys to ensure consistent output order (optional, but good for readability)
        # This part is complex to do purely in awk for numeric sorting of parts of a string key.
        # We will rely on the bash 'sort' command in display_pairings for this.
        for (key in data) {
            print key, data[key];
        }
    }'
}

# Function to display the identified pairings
display_pairings() {
    local -A pairings_map
    local input_data="$1"

    if [ -z "$input_data" ]; then
        echo "No CPU core pairings found or input was empty."
        return
    fi

    # Read the input data back into an associative array
    # This loop runs in the current shell, so pairings_map will be populated correctly.
    while IFS= read -r line; do
        # Split the line into key and CPU IDs string
        key=$(echo "$line" | awk '{print $1}')
        cpus_str=$(echo "$line" | cut -d' ' -f2-)
        pairings_map["$key"]="$cpus_str"
    done <<< "$input_data" # Use here-string to feed input_data to the while loop

    echo -e "\n--- Proxmox CPU Core and Thread Pairings ---"
    echo "--------------------------------------------"

    # Sort keys numerically by NODE, then SOCKET, then CORE
    # This ensures a consistent and logical order of output
    sorted_keys=$(printf "%s\n" "${!pairings_map[@]}" | sort -t'_' -k1,1n -k2,2n -k3,3n)

    for key in $sorted_keys; do
        # Extract NODE, SOCKET, CORE from the key
        node_id=$(echo "$key" | cut -d'_' -f1)
        socket_id=$(echo "$key" | cut -d'_' -f2)
        core_id=$(echo "$key" | cut -d'_' -f3)
        
        cpu_ids_str="${pairings_map[$key]}"
        # Convert space-separated string to an array for easier processing
        read -r -a cpu_ids <<< "$cpu_ids_str"

        # Determine if it's a hyperthreaded pair or a single thread
        if [ ${#cpu_ids[@]} -eq 2 ]; then
            echo "  Physical Core (Node ${node_id}, Socket ${socket_id}, Core ${core_id}):"
            echo "    - Logical CPU (Thread 1): ${cpu_ids[0]}"
            echo "    - Logical CPU (Thread 2): ${cpu_ids[1]}"
        elif [ ${#cpu_ids[@]} -eq 1 ]; then
            echo "  Physical Core (Node ${node_id}, Socket ${socket_id}, Core ${core_id}):"
            echo "    - Logical CPU (Single Thread): ${cpu_ids[0]}"
        else
            echo "  Physical Core (Node ${node_id}, Socket ${socket_id}, Core ${core_id}):"
            echo "    - Logical CPUs: $(IFS=', '; echo "${cpu_ids[*]}") (Unusual number of threads)"
        fi
        echo "--------------------------------------------"
    done
}

# Main execution
# Call parse_lscpu_output and capture its entire output
processed_pairings=$(parse_lscpu_output)
parse_status=$? # Capture the exit status of parse_lscpu_output

if [ "$parse_status" -eq 0 ]; then # Check if parse_lscpu_output was successful
    display_pairings "$processed_pairings"
else
    echo "Script terminated due to error in getting/parsing lscpu output." >&2
fi
