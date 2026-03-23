#!/bin/bash
# CPU Control Menu - Improved & Fixed
# Requires: cpufrequtils, dialog, stress (optional), cpupower (optional)

# ─── Strict mode (trap replaces set -e so we can handle errors gracefully) ────
set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
LOGFILE="${HOME}/cpu_control.log"
readonly LOGFILE

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# ─── Logging ──────────────────────────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE"
}

# ─── Error display (non-fatal: removed erroneous 'return 1' after dialog) ─────
error_msg() {
    log "ERROR: $1"
    dialog --msgbox "Error: $1" 8 55
}

# ─── Dependency checker ───────────────────────────────────────────────────────
check_dep() {
    local pkg="$1" cmd="$2"
    command -v "$cmd" &>/dev/null && return 0

    echo -e "${YELLOW}Missing dependency: $pkg ($cmd)${NC}"
    read -rp "Install $pkg now? [y/N]: " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        sudo apt-get update -qq || return 1
        sudo apt-get install -y "$pkg" || return 1
        log "Installed dependency: $pkg"
        return 0
    else
        echo -e "${RED}Skipping $pkg. Some features may not work.${NC}"
        return 1
    fi
}

# ─── CPU helpers ──────────────────────────────────────────────────────────────
get_cpu_count() {
    nproc
}

get_cpu_model() {
    grep -m1 "model name" /proc/cpuinfo | cut -d: -f2 | xargs
}

# Returns e.g. "3.6GHz" or empty string on failure
get_max_cpu_frequency() {
    local path="/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"
    if [[ -r "$path" ]]; then
        awk '{printf "%.1fGHz", $1/1000000}' "$path"
        return 0
    fi
    # Fallback via cpufreq-info
    if command -v cpufreq-info &>/dev/null; then
        local val
        val=$(cpufreq-info -l 2>/dev/null | awk '{print $2}' | head -1)
        [[ -n "$val" ]] && awk -v v="$val" 'BEGIN{printf "%.1fGHz", v/1000000}' && return 0
    fi
    return 1
}

# Returns e.g. "0.8GHz - 3.6GHz"
get_frequency_range() {
    local min_path="/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq"
    local max_path="/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"
    if [[ -r "$min_path" && -r "$max_path" ]]; then
        awk '{printf "%.1fGHz", $1/1000000}' "$min_path" | tr -d '\n'
        echo -n " - "
        awk '{printf "%.1fGHz\n", $1/1000000}' "$max_path"
        return 0
    fi
    echo "Unknown"
    return 1
}

# ─── Validation ───────────────────────────────────────────────────────────────
validate_frequency() {
    local freq="$1"
    # Accept: 2GHz  2.4GHz  2400MHz  2400000  (bare kHz numbers cpufreq-set accepts)
    if [[ ! "$freq" =~ ^[0-9]+(\.[0-9]+)?(GHz|MHz|kHz)?$ ]]; then
        error_msg "Invalid frequency format. Use e.g. '3.6GHz' or '2400MHz'."
        return 1
    fi
    return 0
}

# ─── Governor ─────────────────────────────────────────────────────────────────
set_governor() {
    local governor="$1"
    local failed=0 success=0

    log "Setting governor → $governor"
    while IFS= read -r -d '' cpu; do
        if echo "$governor" | sudo tee "$cpu" > /dev/null 2>&1; then
            (( success++ )) || true
        else
            (( failed++ )) || true
            log "Failed to set governor for $cpu"
        fi
    done < <(find /sys/devices/system/cpu -name "scaling_governor" -print0 2>/dev/null)

    if [[ $failed -eq 0 && $success -gt 0 ]]; then
        dialog --msgbox "Governor set to '$governor' for all $success core(s)." 8 55
        log "Governor → $governor (ok, $success cores)"
    elif [[ $success -eq 0 ]]; then
        error_msg "Could not set governor. Is cpufrequtils installed and the driver loaded?"
    else
        error_msg "Governor set on $success core(s) but failed on $failed core(s)."
    fi
}

# List available governors from the kernel
get_available_governors() {
    local path="/sys/devices/system/cpu/cpu0/cpufreq/scaling_available_governors"
    if [[ -r "$path" ]]; then
        cat "$path"
    elif command -v cpufreq-info &>/dev/null; then
        cpufreq-info 2>/dev/null | grep "available cpufreq governors" | cut -d: -f2
    else
        echo "performance powersave"
    fi
}

# ─── Frequency setters ────────────────────────────────────────────────────────
# FIX: cpufreq-set only sets ONE cpu at a time; loop over all cores
set_fixed_frequency_all() {
    local freq="$1"
    validate_frequency "$freq" || return 1

    local failed=0 success=0 ncores
    ncores=$(get_cpu_count)

    log "Setting fixed frequency → $freq (all cores)"
    for (( i=0; i<ncores; i++ )); do
        if sudo cpufreq-set -c "$i" -f "$freq" 2>>"$LOGFILE"; then
            (( success++ )) || true
        else
            (( failed++ )) || true
        fi
    done

    if [[ $failed -eq 0 ]]; then
        dialog --msgbox "Frequency set to $freq on all $success core(s)." 8 55
        log "Fixed frequency → $freq (ok)"
    else
        error_msg "Set $freq on $success core(s); failed on $failed core(s). Check log."
    fi
}

set_max_frequency() {
    local max_freq
    if ! max_freq=$(get_max_cpu_frequency); then
        error_msg "Could not detect maximum CPU frequency."
        return 1
    fi

    dialog --yesno "Set all cores to maximum frequency: $max_freq?" 8 60 || return 0

    set_fixed_frequency_all "$max_freq"
}

# FIX: loop over cores for min/max limits too
set_frequency_limit() {
    local flag="$1"    # -d (min) or -u (max)
    local prompt="$2"
    local default="$3"

    local freq
    freq=$(dialog --stdout --inputbox "$prompt" 10 55 "$default") || return 0
    [[ -z "$freq" ]] && return 0

    validate_frequency "$freq" || return 1

    local ncores failed=0 success=0
    ncores=$(get_cpu_count)
    for (( i=0; i<ncores; i++ )); do
        if sudo cpufreq-set -c "$i" "$flag" "$freq" 2>>"$LOGFILE"; then
            (( success++ )) || true
        else
            (( failed++ )) || true
        fi
    done

    if [[ $failed -eq 0 ]]; then
        dialog --msgbox "Limit set to $freq on $success core(s)." 8 50
        log "Freq limit $flag → $freq (ok)"
    else
        error_msg "Failed on $failed core(s); set on $success. Check log."
    fi
}

# ─── Display helpers ──────────────────────────────────────────────────────────
show_frequencies() {
    # FIX: 'grep MHz' is fragile; read scaling_cur_freq directly
    local output=""
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
        local cpu
        cpu=$(echo "$f" | grep -oP 'cpu\d+')
        local freq_mhz
        freq_mhz=$(awk '{printf "%.0f MHz", $1/1000}' "$f" 2>/dev/null || echo "N/A")
        output+="${cpu}: ${freq_mhz}\n"
    done
    if [[ -z "$output" ]]; then
        # Fallback to /proc/cpuinfo
        output=$(grep "cpu MHz" /proc/cpuinfo | nl -w3 -s'. ' | sed 's/cpu MHz\s*://g')
    fi
    dialog --title "Current CPU Frequencies" --msgbox "$(printf '%b' "$output")" 30 50
}

show_governors() {
    local output=""
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        local cpu
        cpu=$(echo "$g" | grep -oP 'cpu\d+')
        output+="${cpu}: $(cat "$g")\n"
    done
    dialog --title "Active Governors" --msgbox "$(printf '%b' "$output")" 30 40
}

show_cpu_info() {
    local cpu_model cores freq_range max_freq
    cpu_model=$(get_cpu_model)
    cores=$(get_cpu_count)
    freq_range=$(get_frequency_range)
    max_freq=$(get_max_cpu_frequency 2>/dev/null || echo "Unknown")

    # Also show current governor of cpu0
    local gov="Unknown"
    [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]] && \
        gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)

    dialog --title "CPU Information" --msgbox \
"CPU Model   : $cpu_model
Cores       : $cores
Freq Range  : $freq_range
Max Boost   : $max_freq
Governor    : $gov" 12 70
}

show_available_governors() {
    local govs
    govs=$(get_available_governors)
    dialog --title "Available Governors" --msgbox \
"Available governors:\n\n${govs// /\\n}" 15 50
}

show_hardware_limits() {
    local output=""
    if command -v cpufreq-info &>/dev/null; then
        output=$(cpufreq-info 2>/dev/null | grep "hardware limits" || echo "Not available via cpufreq-info")
    fi
    if [[ -z "$output" ]]; then
        local min max
        min=$(awk '{printf "%.1fGHz", $1/1000000}' \
            /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null || echo "?")
        max=$(awk '{printf "%.1fGHz", $1/1000000}' \
            /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null || echo "?")
        output="Hardware limits: ${min} - ${max}"
    fi
    dialog --title "Hardware Limits" --msgbox "$output" 20 65
}

# ─── Turbo Boost ──────────────────────────────────────────────────────────────
toggle_turbo() {
    local turbo_path="" mode=""

    # Intel pstate
    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        turbo_path="/sys/devices/system/cpu/intel_pstate/no_turbo"
        mode="intel"
    # AMD (cpufreq boost)
    elif [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        turbo_path="/sys/devices/system/cpu/cpufreq/boost"
        mode="amd"
    else
        error_msg "Turbo Boost control not found.\n(Intel: intel_pstate/no_turbo  AMD: cpufreq/boost)"
        return 1
    fi

    local current action new_val msg
    current=$(cat "$turbo_path")

    if [[ "$mode" == "intel" ]]; then
        # Intel: no_turbo=0 → turbo ON; no_turbo=1 → turbo OFF
        if [[ "$current" == "0" ]]; then
            action="disable"; new_val="1"; msg="Turbo Boost will be DISABLED"
        else
            action="enable";  new_val="0"; msg="Turbo Boost will be ENABLED"
        fi
    else
        # AMD: boost=1 → turbo ON; boost=0 → turbo OFF
        if [[ "$current" == "1" ]]; then
            action="disable"; new_val="0"; msg="Turbo Boost will be DISABLED"
        else
            action="enable";  new_val="1"; msg="Turbo Boost will be ENABLED"
        fi
    fi

    dialog --yesno "$msg. Continue?" 8 50 || return 0

    if echo "$new_val" | sudo tee "$turbo_path" > /dev/null; then
        dialog --msgbox "Turbo Boost ${action}d successfully." 8 45
        log "Turbo Boost ${action}d (path: $turbo_path)"
    else
        error_msg "Failed to $action Turbo Boost. Are you root / is sudo available?"
    fi
}

# ─── Stress test ──────────────────────────────────────────────────────────────
run_stress_test() {
    local duration=30
    local cores
    cores=$(get_cpu_count)

    dialog --yesno "Run stress test on all $cores cores for ${duration}s?" 8 55 || return 0

    log "Stress test: $cores cores × ${duration}s"

    # FIX: previous version had a race — stress PID was lost; use a temp fifo
    local tmpfifo
    tmpfifo=$(mktemp -u /tmp/cpu_stress_XXXXXX)
    mkfifo "$tmpfifo"

    (
        stress --cpu "$cores" --timeout "${duration}s" &>/dev/null &
        local spid=$!
        for (( i=0; i<=duration; i++ )); do
            echo $(( i * 100 / duration ))
            sleep 1
        done
        wait "$spid" 2>/dev/null || true
    ) > "$tmpfifo" &

    dialog --gauge "Stress testing $cores core(s) for ${duration}s …" 8 55 0 < "$tmpfifo"
    rm -f "$tmpfifo"

    dialog --msgbox "Stress test complete!\n\nUse 'Show current frequencies' to check results." 8 55
    log "Stress test complete"
}

# ─── Custom governor picker ───────────────────────────────────────────────────
pick_custom_governor() {
    local govs avail=()
    govs=$(get_available_governors)
    read -ra avail <<< "$govs"

    local menu_args=()
    local i=1
    for g in "${avail[@]}"; do
        menu_args+=( "$i" "$g" )
        (( i++ )) || true
    done

    local sel
    sel=$(dialog --stdout --menu "Select governor:" 15 50 8 "${menu_args[@]}") || return 0
    local chosen="${avail[$((sel-1))]}"
    set_governor "$chosen"
}

# ─── Bootstrap ────────────────────────────────────────────────────────────────
echo "Checking dependencies…"
check_dep "cpufrequtils" "cpufreq-set" || true
check_dep "dialog"       "dialog"      || { echo "dialog is required. Exiting."; exit 1; }
check_dep "stress"       "stress"      || true

touch "$LOGFILE" 2>/dev/null || { echo "Cannot create log file at $LOGFILE"; exit 1; }
log "=== CPU Control Menu Started ==="

MAX_FREQ=$(get_max_cpu_frequency 2>/dev/null || echo "Unknown")
CPU_MODEL=$(get_cpu_model)
CORES=$(get_cpu_count)

# ─── Main loop ────────────────────────────────────────────────────────────────
while true; do
    CHOICE=$(dialog --clear --stdout \
        --title "CPU Control Menu — $CPU_MODEL" \
        --menu "Cores: $CORES  |  Max Boost: ${MAX_FREQ:-Unknown}  |  Choose action:" \
        27 82 16 \
        0  "CPU Information Summary" \
        1  "Set ALL cores to MAX frequency (${MAX_FREQ:-auto-detect})" \
        2  "Set custom fixed frequency" \
        3  "Set governor: performance" \
        4  "Set governor: powersave" \
        5  "Set governor: other (pick from available)" \
        6  "Set minimum frequency limit" \
        7  "Set maximum frequency limit" \
        8  "Show current frequencies (per core)" \
        9  "Show active governor (per core)" \
        10 "Show available governors" \
        11 "Show hardware limits" \
        12 "Toggle Turbo Boost (Intel / AMD)" \
        13 "Run stress test (${CORES} cores, 30 s)" \
        14 "View log file" \
        15 "Exit") || break   # ESC / Cancel = exit

    case "$CHOICE" in
        0)  show_cpu_info ;;
        1)  set_max_frequency ;;
        2)
            FREQ=$(dialog --stdout --inputbox \
                "Enter frequency (e.g. 3.6GHz or 2400MHz):" \
                8 50 "${MAX_FREQ:-3.6GHz}") || continue
            [[ -n "$FREQ" ]] && set_fixed_frequency_all "$FREQ"
            ;;
        3)  set_governor "performance" ;;
        4)  set_governor "powersave" ;;
        5)  pick_custom_governor ;;
        6)  set_frequency_limit "-d" "Enter minimum frequency:" "0.8GHz" ;;
        7)  set_frequency_limit "-u" "Enter maximum frequency:" "${MAX_FREQ:-3.6GHz}" ;;
        8)  show_frequencies ;;
        9)  show_governors ;;
        10) show_available_governors ;;
        11) show_hardware_limits ;;
        12) toggle_turbo ;;
        13) run_stress_test ;;
        14)
            if [[ -s "$LOGFILE" ]]; then
                dialog --title "Log: $LOGFILE" --textbox "$LOGFILE" 30 82
            else
                dialog --msgbox "Log file is empty or not found." 8 45
            fi
            ;;
        15) break ;;
    esac
done

log "=== CPU Control Menu Exited ==="
clear
echo -e "${GREEN}CPU Control Menu exited cleanly.${NC}"
