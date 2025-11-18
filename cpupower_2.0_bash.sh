#!/bin/bash
set -euo pipefail

# CPU Control Menu with enhanced error handling and validation

# Configuration
LOGFILE="$HOME/cpu_control.log"
readonly LOGFILE

# Colors for terminal output (when not using dialog)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Logging function with timestamps
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"
}

# Error handling
error_exit() {
    log "ERROR: $1"
    dialog --msgbox "Error: $1" 10 50
    return 1
}

# Check and install dependencies
check_dep() {
    local pkg=$1
    local cmd=$2
    
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${YELLOW}Missing dependency: $pkg ($cmd)${NC}"
        read -rp "Install $pkg now? [y/N]: " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            sudo apt update || return 1
            sudo apt install -y "$pkg" || return 1
            log "Installed dependency: $pkg"
        else
            echo -e "${RED}Skipping $pkg. Some features may not work.${NC}"
            return 1
        fi
    fi
    return 0
}

# Get number of CPU cores
get_cpu_count() {
    nproc
}

# Detect maximum CPU frequency
get_max_cpu_frequency() {
    local max_freq_khz
    local max_freq_ghz
    
    # Try to read from cpuinfo_max_freq (in kHz)
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]]; then
        max_freq_khz=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)
        # Convert kHz to GHz with 1 decimal place
        max_freq_ghz=$(awk "BEGIN {printf \"%.1f\", $max_freq_khz/1000000}")
        echo "${max_freq_ghz}GHz"
        return 0
    fi
    
    # Fallback: try cpufreq-info
    if command -v cpufreq-info &>/dev/null; then
        max_freq_ghz=$(cpufreq-info -l | awk '{print $2/1000000}' | head -1)
        if [[ -n "$max_freq_ghz" ]]; then
            max_freq_ghz=$(awk "BEGIN {printf \"%.1f\", $max_freq_ghz}")
            echo "${max_freq_ghz}GHz"
            return 0
        fi
    fi
    
    # Last resort: check hardware limits from cpufreq-info output
    if command -v cpufreq-info &>/dev/null; then
        max_freq_ghz=$(cpufreq-info | grep "hardware limits" | awk '{print $NF}' | sed 's/GHz//')
        if [[ -n "$max_freq_ghz" ]]; then
            echo "${max_freq_ghz}GHz"
            return 0
        fi
    fi
    
    # If all fails, return empty
    echo ""
    return 1
}

# Get current CPU frequency range
get_frequency_range() {
    local min_freq max_freq
    
    if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq ]] && \
       [[ -f /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq ]]; then
        min_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq)
        max_freq=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq)
        
        min_freq=$(awk "BEGIN {printf \"%.1f\", $min_freq/1000000}")
        max_freq=$(awk "BEGIN {printf \"%.1f\", $max_freq/1000000}")
        
        echo "${min_freq}GHz - ${max_freq}GHz"
        return 0
    fi
    
    echo "Unknown"
    return 1
}

# Get CPU model name
get_cpu_model() {
    grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs
}

# Validate frequency input
validate_frequency() {
    local freq=$1
    if [[ ! "$freq" =~ ^[0-9]+(\.[0-9]+)?(GHz|MHz)$ ]]; then
        error_exit "Invalid frequency format. Use format like '2.0GHz' or '2000MHz'"
        return 1
    fi
    return 0
}

# Set governor for all cores with error checking
set_governor() {
    local governor=$1
    local cpu_count
    cpu_count=$(get_cpu_count)
    local failed=0
    local success=0
    
    log "Setting governor to $governor for all cores"
    
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        if [[ -f "$cpu" ]]; then
            if echo "$governor" | sudo tee "$cpu" > /dev/null 2>&1; then
                ((++success))
            else
                ((++failed))
                log "Failed to set governor for $cpu"
            fi
        fi
    done
    
    if [[ $failed -eq 0 ]]; then
        dialog --msgbox "Governor set to '$governor' for all $cpu_count cores" 10 50
        log "Successfully set governor to $governor"
    else
        error_exit "Failed to set governor for $failed core(s)"
    fi
}

# Set fixed frequency with validation
set_fixed_frequency() {
    local freq=$1
    
    if ! validate_frequency "$freq"; then
        return 1
    fi
    
    log "Setting fixed frequency to $freq"
    if sudo cpufreq-set -f "$freq" 2>&1 | tee -a "$LOGFILE"; then
        dialog --msgbox "Frequency set to $freq" 10 40
    else
        error_exit "Failed to set frequency to $freq"
    fi
}

# Set CPU to maximum frequency (auto-detected)
set_max_frequency() {
    local max_freq
    max_freq=$(get_max_cpu_frequency)
    
    if [[ -z "$max_freq" ]]; then
        error_exit "Could not detect maximum CPU frequency"
        return 1
    fi
    
    # Confirm with user
    if dialog --yesno "Set CPU to maximum frequency: $max_freq?\n\nThis will set all cores to max performance." 12 60; then
        log "Setting CPU to max frequency: $max_freq"
        if sudo cpufreq-set -f "$max_freq" 2>&1 | tee -a "$LOGFILE"; then
            dialog --msgbox "All cores set to maximum frequency: $max_freq" 10 50
            log "Successfully set to max frequency: $max_freq"
        else
            error_exit "Failed to set maximum frequency"
        fi
    fi
}

# Set frequency limits
set_frequency_limit() {
    local limit_type=$1  # 'd' for min, 'u' for max
    local prompt_msg=$2
    local default=$3
    
    local freq
    freq=$(dialog --inputbox "$prompt_msg" 10 50 "$default" --stdout)
    
    if [[ -z "$freq" ]]; then
        return 0  # User cancelled
    fi
    
    if ! validate_frequency "$freq"; then
        return 1
    fi
    
    log "Setting frequency limit (-$limit_type) to $freq"
    if sudo cpufreq-set -"$limit_type" "$freq" 2>&1 | tee -a "$LOGFILE"; then
        dialog --msgbox "Frequency limit set to $freq" 10 40
    else
        error_exit "Failed to set frequency limit"
    fi
}

# Show current CPU frequencies in a formatted way
show_frequencies() {
    local output
    output=$(cat /proc/cpuinfo | grep "MHz" | nl -w2 -s'. ')
    dialog --title "Current CPU Frequencies" --msgbox "$output" 30 80
}

# Show current governors
show_governors() {
    local output
    output=$(for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "$(basename $(dirname $(dirname "$gov"))): $(cat "$gov")"
    done)
    dialog --title "Current Governors (All Cores)" --msgbox "$output" 30 60
}

# Show CPU info summary
show_cpu_info() {
    local cpu_model
    local freq_range
    local max_freq
    local cores
    
    cpu_model=$(get_cpu_model)
    cores=$(get_cpu_count)
    freq_range=$(get_frequency_range)
    max_freq=$(get_max_cpu_frequency)
    
    local info="CPU Model: $cpu_model
Cores: $cores
Frequency Range: $freq_range
Max Boost Frequency: $max_freq"
    
    dialog --title "CPU Information" --msgbox "$info" 15 70
}

# Toggle turbo boost with confirmation
toggle_turbo() {
    local turbo_path="/sys/devices/system/cpu/intel_pstate/no_turbo"
    
    if [[ ! -f "$turbo_path" ]]; then
        # Try AMD path
        turbo_path="/sys/devices/system/cpu/cpufreq/boost"
        if [[ ! -f "$turbo_path" ]]; then
            error_exit "Turbo Boost control not available on this system"
            return 1
        fi
    fi
    
    local current
    current=$(cat "$turbo_path")
    local action new_val msg
    
    if [[ "$turbo_path" == *"no_turbo"* ]]; then
        # Intel: 0=enabled, 1=disabled
        if [[ "$current" == "0" ]]; then
            action="disable"
            new_val="1"
            msg="Turbo Boost will be DISABLED"
        else
            action="enable"
            new_val="0"
            msg="Turbo Boost will be ENABLED"
        fi
    else
        # AMD: 0=disabled, 1=enabled
        if [[ "$current" == "1" ]]; then
            action="disable"
            new_val="0"
            msg="Turbo Boost will be DISABLED"
        else
            action="enable"
            new_val="1"
            msg="Turbo Boost will be ENABLED"
        fi
    fi
    
    if dialog --yesno "$msg. Continue?" 10 50; then
        if echo "$new_val" | sudo tee "$turbo_path" > /dev/null; then
            dialog --msgbox "Turbo Boost ${action}d successfully" 10 40
            log "Turbo Boost ${action}d"
        else
            error_exit "Failed to $action Turbo Boost"
        fi
    fi
}

# Run stress test with progress
run_stress_test() {
    local duration=30
    local cores
    cores=$(get_cpu_count)
    
    if ! dialog --yesno "Run stress test on all $cores cores for ${duration}s?" 10 50; then
        return 0
    fi
    
    log "Starting stress test: $cores cores for ${duration}s"
    
    # Run in background and show progress
    (
        stress --cpu "$cores" --timeout "$duration" &>/dev/null &
        local stress_pid=$!
        
        for i in $(seq 0 $duration); do
            echo $((i * 100 / duration))
            sleep 1
        done
        
        wait $stress_pid
    ) | dialog --gauge "Stress testing $cores cores..." 10 50 0
    
    dialog --msgbox "Stress test complete!\n\nCheck option 6 to view current frequencies." 10 50
    log "Stress test completed"
}

# Check dependencies
echo "Checking dependencies..."
check_dep "cpufrequtils" "cpufreq-info" || true
check_dep "dialog" "dialog" || { echo "Dialog is required!"; exit 1; }
check_dep "stress" "stress" || true

# Create log file if it doesn't exist
touch "$LOGFILE" || { echo "Cannot create log file"; exit 1; }
log "=== CPU Control Menu Started ==="

# Detect CPU info on startup
MAX_FREQ=$(get_max_cpu_frequency)
CPU_MODEL=$(get_cpu_model)
CORES=$(get_cpu_count)

# Main menu loop
while true; do
    CHOICE=$(dialog --clear --stdout --title "CPU Control Menu - $CPU_MODEL" \
        --menu "Choose an option ($CORES cores | Max: ${MAX_FREQ:-Unknown}):" 25 80 15 \
        0 "Show CPU Information Summary" \
        1 "Set to MAX frequency (${MAX_FREQ:-Unknown}) - Auto-detected" \
        2 "Set custom fixed frequency" \
        3 "Set governor: performance (all cores)" \
        4 "Set governor: powersave (all cores)" \
        5 "Set minimum frequency" \
        6 "Set maximum frequency" \
        7 "Show current frequencies" \
        8 "Show current governor (all cores)" \
        9 "Show available governors" \
        10 "Show hardware limits" \
        11 "Toggle Turbo Boost (disable/enable)" \
        12 "Stress test all cores (30s)" \
        13 "View log file" \
        14 "Exit")
    
    # Handle ESC or Cancel
    [[ -z "$CHOICE" ]] && break
    
    case $CHOICE in
        0) show_cpu_info ;;
        1) set_max_frequency ;;
        2) 
            FREQ=$(dialog --inputbox "Enter custom frequency:" 10 40 "${MAX_FREQ:-4.0GHz}" --stdout)
            [[ -n "$FREQ" ]] && set_fixed_frequency "$FREQ"
            ;;
        3) set_governor "performance" ;;
        4) set_governor "powersave" ;;
        5) set_frequency_limit "d" "Enter minimum frequency:" "2.0GHz" ;;
        6) set_frequency_limit "u" "Enter maximum frequency:" "${MAX_FREQ:-4.0GHz}" ;;
        7) show_frequencies ;;
        8) show_governors ;;
        9) 
            output=$(cpufreq-info | grep -A1 "available cpufreq governors")
            dialog --title "Available Governors" --msgbox "$output" 20 60
            ;;
        10) 
            output=$(cpufreq-info | grep -A1 "hardware limits")
            dialog --title "Hardware Limits" --msgbox "$output" 20 60
            ;;
        11) toggle_turbo ;;
        12) run_stress_test ;;
        13) 
            if [[ -f "$LOGFILE" ]]; then
                dialog --title "Log File: $LOGFILE" --textbox "$LOGFILE" 30 80
            else
                dialog --msgbox "Log file not found" 10 40
            fi
            ;;
        14) 
            log "=== CPU Control Menu Exited ==="
            break
            ;;
    esac
done

clear
echo -e "${GREEN}CPU Control Menu exited successfully${NC}"
