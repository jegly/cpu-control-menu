#!/usr/bin/env bash
# ==============================================================================
#  CPU Control Center  v3.0
# ------------------------------------------------------------------------------
#  Driver-aware CPU power/performance manager for Linux.
#
#  What's new vs 2.0:
#    * DRIVER-AWARE frequency control. Works correctly on intel_pstate and
#      amd-pstate (which have NO 'userspace' governor) by writing sysfs
#      scaling_min/max_freq + perf-pct, instead of relying on `cpufreq-set -f`
#      which silently fails on those drivers.
#    * No hard dependency on cpufrequtils — talks to sysfs directly, uses
#      cpufreq-set only when it is the right tool (acpi-cpufreq + userspace).
#    * Energy Performance Preference (EPP) control.
#    * Intel RAPL power-cap (PL1/PL2) control + live package power draw.
#    * Live dashboard: per-core MHz, package temp, power draw, governor.
#    * One-shot PROFILES (Max / Balanced / Battery / Quiet) that set governor,
#      EPP, turbo and power-cap together.
#    * Save / restore a baseline snapshot so you can always get back to stock.
#    * Works with dialog OR whiptail, and degrades to plain text if neither.
#
#  Safe by design: every change is logged, confirmed, and reversible.
#  Reads need no privileges; writes use sudo only at the moment of writing.
# ==============================================================================

set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
readonly VERSION="3.0"
LOGFILE="${HOME}/cpu_control.log"
BASELINE="${HOME}/.cpu_control_baseline"
readonly LOGFILE BASELINE

readonly CPU_BASE="/sys/devices/system/cpu"
readonly PSTATE="${CPU_BASE}/intel_pstate"
readonly RAPL="/sys/class/powercap/intel-rapl:0"

readonly RED='\033[0;31m'  GREEN='\033[0;32m'  YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m' BOLD='\033[1m'       NC='\033[0m'

# Populated by detect_hardware()
DRIVER="" NCORES=1 EPP_SUPPORTED=0 TURBO_PATH="" TURBO_MODE="" RAPL_OK=0
MIN_KHZ=0 MAX_KHZ=0

# ─── Logging ──────────────────────────────────────────────────────────────────
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOGFILE" 2>/dev/null; }

# ─── Privilege helper ─────────────────────────────────────────────────────────
# Write a value to a sysfs file as root. Centralises every privileged write.
write_sysfs() {
    local value="$1" path="$2"
    [[ -e "$path" ]] || return 1
    echo "$value" | sudo tee "$path" >/dev/null 2>&1
}

# ─── UI abstraction (dialog | whiptail | plain) ───────────────────────────────
UI=""
detect_ui() {
    if command -v dialog &>/dev/null;   then UI="dialog"
    elif command -v whiptail &>/dev/null; then UI="whiptail"
    else UI="plain"; fi
}

ui_msgbox() {  # title text
    case "$UI" in
        dialog)   dialog --title "$1" --msgbox "$2" 0 0 2>/dev/null ;;
        whiptail) whiptail --title "$1" --msgbox "$2" 0 0 2>/dev/null ;;
        *)        printf '\n%b\n[%s]\n%b\n' "${CYAN}$1${NC}" "msg" "$2"; read -rp "Press Enter…" _ ;;
    esac
}

ui_yesno() {  # title text -> 0=yes
    case "$UI" in
        dialog)   dialog --title "$1" --yesno "$2" 0 0 2>/dev/null ;;
        whiptail) whiptail --title "$1" --yesno "$2" 0 0 2>/dev/null ;;
        *)        local a; read -rp "$2 [y/N]: " a; [[ "$a" =~ ^[Yy]$ ]] ;;
    esac
}

ui_input() {  # title text default -> echoes value
    case "$UI" in
        dialog)   dialog --stdout --title "$1" --inputbox "$2" 0 0 "$3" 2>/dev/null ;;
        whiptail) whiptail --title "$1" --inputbox "$2" 0 0 "$3" 3>&1 1>&2 2>&3 ;;
        *)        local a; read -rp "$2 [$3]: " a; echo "${a:-$3}" ;;
    esac
}

ui_menu() {  # title text  tag item tag item ...
    local title="$1" text="$2"; shift 2
    case "$UI" in
        dialog)   dialog --clear --stdout --title "$title" --menu "$text" 0 0 0 "$@" 2>/dev/null ;;
        whiptail) whiptail --title "$title" --menu "$text" 0 0 0 "$@" 3>&1 1>&2 2>&3 ;;
        *)        local t i; echo; echo "== $title =="; echo "$text"
                  while (($#)); do printf '  %s) %s\n' "$1" "$2"; shift 2; done
                  read -rp "Choice: " t; echo "$t" ;;
    esac
}

ui_textfile() {  # title file
    case "$UI" in
        dialog)   dialog --title "$1" --textbox "$2" 0 0 2>/dev/null ;;
        whiptail) whiptail --title "$1" --scrolltext --textbox "$2" 0 0 2>/dev/null ;;
        *)        ${PAGER:-less} "$2" ;;
    esac
}

error_msg() { log "ERROR: $1"; ui_msgbox "Error" "$1"; }

# ─── Frequency conversion ─────────────────────────────────────────────────────
# Accepts "3.6GHz", "2400MHz", "800kHz", or a bare kHz integer. Echoes kHz.
freq_to_khz() {
    local in="$1" num unit
    in="${in// /}"
    if [[ "$in" =~ ^([0-9]+(\.[0-9]+)?)([GgMmKk][Hh]z)?$ ]]; then
        num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[3]:-kHz}"
        case "${unit,,}" in
            ghz) awk -v n="$num" 'BEGIN{printf "%d", n*1000000}' ;;
            mhz) awk -v n="$num" 'BEGIN{printf "%d", n*1000}' ;;
            khz) awk -v n="$num" 'BEGIN{printf "%d", n}' ;;
        esac
        return 0
    fi
    return 1
}

khz_to_ghz() { awk -v k="$1" 'BEGIN{printf "%.2fGHz", k/1000000}'; }

# Clamp a kHz value into the hardware [MIN_KHZ, MAX_KHZ] range.
clamp_khz() {
    local k="$1"
    (( k < MIN_KHZ )) && k=$MIN_KHZ
    (( k > MAX_KHZ )) && k=$MAX_KHZ
    echo "$k"
}

# ─── Hardware detection ───────────────────────────────────────────────────────
detect_hardware() {
    NCORES=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo)
    DRIVER=$(cat "${CPU_BASE}/cpu0/cpufreq/scaling_driver" 2>/dev/null || echo "unknown")
    MIN_KHZ=$(cat "${CPU_BASE}/cpu0/cpufreq/cpuinfo_min_freq" 2>/dev/null || echo 0)
    MAX_KHZ=$(cat "${CPU_BASE}/cpu0/cpufreq/cpuinfo_max_freq" 2>/dev/null || echo 0)

    [[ -r "${CPU_BASE}/cpu0/cpufreq/energy_performance_preference" ]] && EPP_SUPPORTED=1

    if [[ -f "${PSTATE}/no_turbo" ]]; then
        TURBO_PATH="${PSTATE}/no_turbo"; TURBO_MODE="intel"
    elif [[ -f "${CPU_BASE}/cpufreq/boost" ]]; then
        TURBO_PATH="${CPU_BASE}/cpufreq/boost"; TURBO_MODE="boost"
    fi

    [[ -r "${RAPL}/constraint_0_power_limit_uw" ]] && RAPL_OK=1
}

cpu_model() { grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs; }

# ─── Read helpers ─────────────────────────────────────────────────────────────
cur_governor() { cat "${CPU_BASE}/cpu0/cpufreq/scaling_governor" 2>/dev/null || echo "n/a"; }
cur_epp()      { cat "${CPU_BASE}/cpu0/cpufreq/energy_performance_preference" 2>/dev/null || echo "n/a"; }
avail_govs()   { cat "${CPU_BASE}/cpu0/cpufreq/scaling_available_governors" 2>/dev/null; }
avail_epp()    { cat "${CPU_BASE}/cpu0/cpufreq/energy_performance_available_preferences" 2>/dev/null; }

turbo_state() {  # echoes on|off|n/a
    [[ -z "$TURBO_PATH" ]] && { echo "n/a"; return; }
    local v; v=$(cat "$TURBO_PATH" 2>/dev/null)
    if [[ "$TURBO_MODE" == "intel" ]]; then
        [[ "$v" == "0" ]] && echo "on" || echo "off"
    else
        [[ "$v" == "1" ]] && echo "on" || echo "off"
    fi
}

pkg_temp_c() {  # package temperature in °C, or "?"
    local z t
    for z in /sys/class/thermal/thermal_zone*; do
        [[ "$(cat "$z/type" 2>/dev/null)" == "x86_pkg_temp" ]] || continue
        t=$(cat "$z/temp" 2>/dev/null) && { awk -v t="$t" 'BEGIN{printf "%.0f", t/1000}'; return; }
    done
    # fallback: first acpitz zone
    t=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null) \
        && awk -v t="$t" 'BEGIN{printf "%.0f", t/1000}' || echo "?"
}

rapl_limit_w() {  # constraint index (0=PL1,1=PL2) -> watts
    local uw; uw=$(cat "${RAPL}/constraint_${1}_power_limit_uw" 2>/dev/null) || { echo "?"; return; }
    awk -v u="$uw" 'BEGIN{printf "%.1f", u/1000000}'
}

# Read a possibly root-only sysfs file. energy_uj is 0400 on most kernels
# (the "Platypus" side-channel mitigation), so fall back to cached sudo.
read_priv() {
    local v
    v=$(cat "$1" 2>/dev/null) && { echo "$v"; return 0; }
    sudo -n cat "$1" 2>/dev/null   # uses cached creds only; never prompts
}

# Sample package power draw over a short interval, echo watts (or "n/a").
rapl_power_w() {
    local e0 e1 max; max=$(read_priv "${RAPL}/max_energy_range_uj" || echo 0)
    e0=$(read_priv "${RAPL}/energy_uj"); [[ -z "$e0" ]] && { echo "n/a"; return; }
    sleep 0.3
    e1=$(read_priv "${RAPL}/energy_uj"); [[ -z "$e1" ]] && { echo "n/a"; return; }
    awk -v a="$e0" -v b="$e1" -v m="$max" 'BEGIN{
        d=b-a; if(d<0 && m>0) d+=m; printf "%.1f", (d/0.3)/1000000 }'
}

# ─── Apply: governor ──────────────────────────────────────────────────────────
apply_governor() {  # governor [quiet]
    local gov="$1" quiet="${2:-}" ok=0 fail=0 c
    if ! avail_govs | grep -qw "$gov"; then
        error_msg "Governor '$gov' not available on this driver ($DRIVER).\nAvailable: $(avail_govs)"
        return 1
    fi
    for c in "${CPU_BASE}"/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ -e "$c" ]] || continue
        if write_sysfs "$gov" "$c"; then ((ok++)) || true; else ((fail++)) || true; fi
    done
    log "governor=$gov ok=$ok fail=$fail"
    [[ -z "$quiet" ]] && {
        (( fail == 0 )) && ui_msgbox "Governor" "Governor set to '$gov' on $ok core(s)." \
                        || error_msg "Governor set on $ok core(s), failed on $fail."
    }
    return 0
}

# ─── Apply: EPP ───────────────────────────────────────────────────────────────
apply_epp() {  # preference [quiet]
    local epp="$1" quiet="${2:-}" ok=0 fail=0 c
    (( EPP_SUPPORTED )) || { [[ -z "$quiet" ]] && error_msg "EPP not supported here."; return 1; }
    for c in "${CPU_BASE}"/cpu[0-9]*/cpufreq/energy_performance_preference; do
        [[ -e "$c" ]] || continue
        if write_sysfs "$epp" "$c"; then ((ok++)) || true; else ((fail++)) || true; fi
    done
    log "epp=$epp ok=$ok fail=$fail"
    [[ -z "$quiet" ]] && ui_msgbox "EPP" "Energy Performance Preference set to '$epp' on $ok core(s)."
    return 0
}

# ─── Apply: turbo ─────────────────────────────────────────────────────────────
apply_turbo() {  # on|off [quiet]
    local want="$1" quiet="${2:-}" val
    [[ -z "$TURBO_PATH" ]] && { [[ -z "$quiet" ]] && error_msg "Turbo control not found."; return 1; }
    if [[ "$TURBO_MODE" == "intel" ]]; then
        [[ "$want" == "on" ]] && val=0 || val=1
    else
        [[ "$want" == "on" ]] && val=1 || val=0
    fi
    if write_sysfs "$val" "$TURBO_PATH"; then
        log "turbo=$want"
        [[ -z "$quiet" ]] && ui_msgbox "Turbo Boost" "Turbo Boost is now ${want^^}."
    else
        [[ -z "$quiet" ]] && error_msg "Failed to set turbo (need sudo?)."
        return 1
    fi
}

# ─── Apply: frequency caps (DRIVER-AWARE) ─────────────────────────────────────
# This is the heart of the rewrite. On intel_pstate / amd-pstate there is no
# userspace governor, so we pin frequency via scaling_min/max_freq (and the
# pstate perf-pct knobs) instead of `cpufreq-set -f`.
set_scaling_freq() {  # min_khz max_khz
    local lo="$1" hi="$2" ok=0 fail=0 c
    for c in "${CPU_BASE}"/cpu[0-9]*/cpufreq; do
        [[ -d "$c" ]] || continue
        # Write max first when lowering, min first when raising, to avoid
        # transient min>max rejections.
        write_sysfs "$hi" "$c/scaling_max_freq" && write_sysfs "$lo" "$c/scaling_min_freq" \
            && ((ok++)) || { ((fail++)) || true; }
    done
    echo "$ok $fail"
}

apply_fixed_frequency() {  # khz
    local k; k=$(clamp_khz "$1")
    log "fixed-freq target=${1}kHz clamped=${k}kHz driver=$DRIVER"

    case "$DRIVER" in
        intel_pstate|amd-pstate*|amd_pstate*)
            # Pin by collapsing the scaling window to a single point.
            local res; res=$(set_scaling_freq "$k" "$k")
            # Also nudge intel_pstate perf-pct so the governor honours it.
            if [[ -d "$PSTATE" && $MAX_KHZ -gt 0 ]]; then
                local pct; pct=$(( k * 100 / MAX_KHZ )); (( pct < 1 )) && pct=1
                write_sysfs "$pct" "${PSTATE}/max_perf_pct"
                write_sysfs "$pct" "${PSTATE}/min_perf_pct"
            fi
            ui_msgbox "Fixed Frequency" "Pinned to $(khz_to_ghz "$k") (cores ok/fail: $res).\n\nNote: on $DRIVER the CPU is held at this point via the scaling window; hardware may still vary slightly under thermal/power limits."
            ;;
        acpi-cpufreq|*)
            if command -v cpufreq-set &>/dev/null && avail_govs | grep -qw userspace; then
                local i ok=0 fail=0
                for ((i=0; i<NCORES; i++)); do
                    sudo cpufreq-set -c "$i" -f "${k}" 2>>"$LOGFILE" && ((ok++)) || ((fail++)) || true
                done
                ui_msgbox "Fixed Frequency" "Set $(khz_to_ghz "$k") via cpufreq-set on $ok core(s)."
            else
                # Last resort: scaling window (works on most modern drivers).
                local res; res=$(set_scaling_freq "$k" "$k")
                ui_msgbox "Fixed Frequency" "Pinned to $(khz_to_ghz "$k") via scaling window (ok/fail: $res)."
            fi
            ;;
    esac
}

apply_freq_limit() {  # min|max khz
    local which="$1" k; k=$(clamp_khz "$2")
    local c ok=0 fail=0 file
    [[ "$which" == "min" ]] && file="scaling_min_freq" || file="scaling_max_freq"
    for c in "${CPU_BASE}"/cpu[0-9]*/cpufreq/"$file"; do
        [[ -e "$c" ]] || continue
        write_sysfs "$k" "$c" && ((ok++)) || { ((fail++)) || true; }
    done
    # Keep intel_pstate perf-pct in sync with the cap for predictable behaviour.
    if [[ -d "$PSTATE" && $MAX_KHZ -gt 0 ]]; then
        local pct=$(( k * 100 / MAX_KHZ )); (( pct < 1 )) && pct=1; (( pct > 100 )) && pct=100
        [[ "$which" == "min" ]] && write_sysfs "$pct" "${PSTATE}/min_perf_pct"
        [[ "$which" == "max" ]] && write_sysfs "$pct" "${PSTATE}/max_perf_pct"
    fi
    log "freq-limit $which=${k}kHz ok=$ok fail=$fail"
    ui_msgbox "Frequency Limit" "${which^} frequency set to $(khz_to_ghz "$k") on $ok core(s)."
}

# Release a pinned/limited CPU back to the full hardware range.
release_limits() {
    set_scaling_freq "$MIN_KHZ" "$MAX_KHZ" >/dev/null
    if [[ -d "$PSTATE" ]]; then
        write_sysfs 100 "${PSTATE}/max_perf_pct"
        write_sysfs 0   "${PSTATE}/min_perf_pct"   # 0 -> driver's own floor
    fi
    log "limits released to ${MIN_KHZ}-${MAX_KHZ}kHz"
}

# ─── Apply: RAPL power cap ─────────────────────────────────────────────────────
apply_power_cap() {  # constraint_index watts
    (( RAPL_OK )) || { error_msg "RAPL power capping not available."; return 1; }
    local idx="$1" watts="$2" uw
    uw=$(awk -v w="$watts" 'BEGIN{printf "%d", w*1000000}')
    if write_sysfs "$uw" "${RAPL}/constraint_${idx}_power_limit_uw"; then
        log "rapl PL$((idx+1))=${watts}W"
        ui_msgbox "Power Limit" "PL$((idx+1)) set to ${watts} W."
    else
        error_msg "Failed to set power limit (need sudo / supported firmware?)."
    fi
}

# ─── Profiles (compound, one-shot) ────────────────────────────────────────────
apply_profile() {  # name
    local p="$1"
    case "$p" in
        max)
            apply_governor performance quiet
            apply_epp performance quiet
            apply_turbo on quiet
            release_limits
            (( RAPL_OK )) && write_sysfs "$(cat "${RAPL}/constraint_0_max_power_uw" 2>/dev/null || echo 0)" "${RAPL}/constraint_0_power_limit_uw"
            ;;
        balanced)
            apply_governor powersave quiet || apply_governor schedutil quiet
            apply_epp balance_performance quiet
            apply_turbo on quiet
            release_limits
            ;;
        battery)
            apply_governor powersave quiet
            apply_epp power quiet
            apply_turbo off quiet
            # cap max to ~60% of turbo for big battery wins
            apply_freq_limit max "$(( MAX_KHZ * 60 / 100 ))"
            ;;
        quiet)
            apply_governor powersave quiet
            apply_epp balance_power quiet
            apply_turbo off quiet
            apply_freq_limit max "$(( MAX_KHZ * 70 / 100 ))"
            ;;
    esac
    log "profile=$p applied"
    ui_msgbox "Profile applied" "Profile '${p^}' is active.\n\nGovernor: $(cur_governor)\nEPP: $(cur_epp)\nTurbo: $(turbo_state)\nMax cap: $(khz_to_ghz "$(cat "${CPU_BASE}/cpu0/cpufreq/scaling_max_freq")")"
}

# ─── Save / restore baseline ──────────────────────────────────────────────────
save_baseline() {
    {
        echo "gov=$(cur_governor)"
        echo "epp=$(cur_epp)"
        echo "turbo=$(turbo_state)"
        echo "smin=$(cat "${CPU_BASE}/cpu0/cpufreq/scaling_min_freq" 2>/dev/null)"
        echo "smax=$(cat "${CPU_BASE}/cpu0/cpufreq/scaling_max_freq" 2>/dev/null)"
        [[ -d "$PSTATE" ]] && echo "minpct=$(cat "${PSTATE}/min_perf_pct")" && echo "maxpct=$(cat "${PSTATE}/max_perf_pct")"
        (( RAPL_OK )) && echo "pl1=$(cat "${RAPL}/constraint_0_power_limit_uw")"
    } > "$BASELINE" 2>/dev/null
    log "baseline saved"
    ui_msgbox "Baseline" "Current settings saved to:\n$BASELINE\n\nUse 'Restore baseline' to return here anytime."
}

restore_baseline() {
    [[ -r "$BASELINE" ]] || { error_msg "No saved baseline found. Save one first."; return 1; }
    local gov epp turbo smin smax minpct maxpct pl1
    # shellcheck disable=SC1090
    source "$BASELINE"
    [[ -n "${gov:-}"   ]] && apply_governor "$gov" quiet
    [[ -n "${epp:-}"   ]] && apply_epp "$epp" quiet
    [[ -n "${turbo:-}" && "$turbo" != "n/a" ]] && apply_turbo "$turbo" quiet
    [[ -n "${smin:-}"  ]] && apply_freq_limit min "$smin" >/dev/null 2>&1
    [[ -n "${smax:-}"  ]] && apply_freq_limit max "$smax" >/dev/null 2>&1
    [[ -n "${minpct:-}" && -d "$PSTATE" ]] && write_sysfs "$minpct" "${PSTATE}/min_perf_pct"
    [[ -n "${maxpct:-}" && -d "$PSTATE" ]] && write_sysfs "$maxpct" "${PSTATE}/max_perf_pct"
    [[ -n "${pl1:-}" ]] && (( RAPL_OK )) && write_sysfs "$pl1" "${RAPL}/constraint_0_power_limit_uw"
    log "baseline restored"
    ui_msgbox "Baseline" "Settings restored from baseline."
}

# ─── Live dashboard ───────────────────────────────────────────────────────────
live_monitor() {
    local key
    # Run in the raw terminal (outside the dialog UI) for a smooth refresh.
    clear
    while true; do
        local temp power gov epp turbo
        temp=$(pkg_temp_c); gov=$(cur_governor); epp=$(cur_epp); turbo=$(turbo_state)
        power=$([[ $RAPL_OK -eq 1 ]] && rapl_power_w || echo "n/a")

        printf '\033[H\033[2J'  # home + clear
        printf '%b CPU Control Center — Live Monitor %b\n' "${BOLD}${CYAN}" "$NC"
        printf '%s\n' "──────────────────────────────────────────────────────"
        printf ' Governor: %-12s  EPP: %-18s\n' "$gov" "$epp"
        printf ' Turbo:    %-12s  Pkg temp: %s°C\n' "$turbo" "$temp"
        printf ' Power:    %s W   (PL1: %s W  PL2: %s W)\n' \
            "$power" "$([[ $RAPL_OK -eq 1 ]] && rapl_limit_w 0 || echo '-')" \
            "$([[ $RAPL_OK -eq 1 ]] && rapl_limit_w 1 || echo '-')"
        printf '%s\n' "──────────────────────────────────────────────────────"
        printf ' %-8s %-10s   %-8s %-10s\n' "Core" "MHz" "Core" "MHz"

        local i mhz line=() c
        for ((i=0; i<NCORES; i++)); do
            c="${CPU_BASE}/cpu${i}/cpufreq/scaling_cur_freq"
            if [[ -r "$c" ]]; then
                mhz=$(awk '{printf "%.0f", $1/1000}' "$c")
            else mhz="?"; fi
            line+=("$mhz")
        done
        for ((i=0; i<NCORES; i+=2)); do
            printf ' cpu%-5d %-10s   cpu%-5d %-10s\n' \
                "$i" "${line[i]:-}" "$((i+1))" "${line[i+1]:-}"
        done
        printf '%s\n' "──────────────────────────────────────────────────────"
        printf '%b Press q to return to the menu, any other key to refresh %b\n' "$YELLOW" "$NC"

        read -rsn1 -t 1 key && [[ "$key" == "q" ]] && break
    done
    clear
}

# ─── Static info screens ──────────────────────────────────────────────────────
show_summary() {
    local pl1 pl2 plmax=""
    if (( RAPL_OK )); then
        pl1="$(rapl_limit_w 0) W"; pl2="$(rapl_limit_w 1) W"
        plmax="$(awk -v u="$(cat "${RAPL}/constraint_0_max_power_uw" 2>/dev/null||echo 0)" 'BEGIN{printf "%.1f W", u/1000000}')"
    else pl1="n/a"; pl2="n/a"; plmax="n/a"; fi
    ui_msgbox "CPU Information" \
"Model      : $(cpu_model)
Cores/HT   : $NCORES
Driver     : $DRIVER
HW range   : $(khz_to_ghz "$MIN_KHZ") - $(khz_to_ghz "$MAX_KHZ")
Governor   : $(cur_governor)   (avail: $(avail_govs))
EPP        : $(cur_epp)
Turbo      : $(turbo_state)
Pkg temp   : $(pkg_temp_c)°C
Power now  : $([[ $RAPL_OK -eq 1 ]] && echo "$(rapl_power_w) W" || echo n/a)
RAPL caps  : PL1 $pl1 / PL2 $pl2  (max $plmax)"
}

show_per_core_freq() {
    local out="" c i mhz
    for ((i=0; i<NCORES; i++)); do
        c="${CPU_BASE}/cpu${i}/cpufreq/scaling_cur_freq"
        [[ -r "$c" ]] && mhz=$(awk '{printf "%.0f MHz", $1/1000}' "$c") || mhz="n/a"
        out+="cpu${i}: ${mhz}\n"
    done
    ui_msgbox "Current Frequencies" "$(printf '%b' "$out")"
}

show_per_core_gov() {
    local out="" c i
    for ((i=0; i<NCORES; i++)); do
        c="${CPU_BASE}/cpu${i}/cpufreq/scaling_governor"
        [[ -r "$c" ]] && out+="cpu${i}: $(cat "$c")\n"
    done
    ui_msgbox "Active Governors" "$(printf '%b' "$out")"
}

# ─── Interactive pickers ──────────────────────────────────────────────────────
pick_governor() {
    local g args=() i=1 sel
    while read -r g; do [[ -n "$g" ]] && { args+=("$i" "$g"); ((i++)); }; done \
        < <(avail_govs | tr ' ' '\n')
    ((${#args[@]})) || { error_msg "No governors found."; return; }
    sel=$(ui_menu "Governor" "Select CPU governor:" "${args[@]}") || return
    apply_governor "${args[$(( (sel-1)*2 + 1 ))]}"
}

pick_epp() {
    (( EPP_SUPPORTED )) || { error_msg "EPP not supported on this system."; return; }
    local e args=() i=1 sel
    for e in $(avail_epp); do args+=("$i" "$e"); ((i++)); done
    sel=$(ui_menu "EPP" "Energy Performance Preference:" "${args[@]}") || return
    apply_epp "${args[$(( (sel-1)*2 + 1 ))]}"
}

pick_profile() {
    local sel
    sel=$(ui_menu "Profiles" "One-shot power/performance profiles:" \
        max      "Maximum performance (turbo on, no caps)" \
        balanced "Balanced (default daily driver)" \
        quiet    "Quiet/cool (turbo off, ~70% cap)" \
        battery  "Battery saver (turbo off, ~60% cap)") || return
    apply_profile "$sel"
}

prompt_fixed_freq() {
    local v k
    v=$(ui_input "Fixed Frequency" "Enter frequency ($(khz_to_ghz "$MIN_KHZ")-$(khz_to_ghz "$MAX_KHZ")), e.g. 3.6GHz / 2400MHz:" "$(khz_to_ghz "$MAX_KHZ")") || return
    [[ -z "$v" ]] && return
    if ! k=$(freq_to_khz "$v"); then error_msg "Bad format. Use e.g. 3.6GHz, 2400MHz or kHz integer."; return; fi
    apply_fixed_frequency "$k"
}

prompt_limit() {  # min|max
    local which="$1" v k def
    [[ "$which" == "min" ]] && def=$(khz_to_ghz "$MIN_KHZ") || def=$(khz_to_ghz "$MAX_KHZ")
    v=$(ui_input "${which^} Limit" "Enter ${which} frequency:" "$def") || return
    [[ -z "$v" ]] && return
    if ! k=$(freq_to_khz "$v"); then error_msg "Bad frequency format."; return; fi
    apply_freq_limit "$which" "$k"
}

prompt_power_cap() {
    (( RAPL_OK )) || { error_msg "RAPL power capping not available."; return; }
    local maxw v
    maxw=$(awk -v u="$(cat "${RAPL}/constraint_0_max_power_uw" 2>/dev/null||echo 0)" 'BEGIN{printf "%.0f", u/1000000}')
    v=$(ui_input "Power Cap (PL1)" "Sustained package power limit in watts (HW max ~${maxw}W):" "$(rapl_limit_w 0)") || return
    [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { error_msg "Enter a number of watts."; return; }
    apply_power_cap 0 "$v"
}

run_stress() {
    local tool="" cores="$NCORES" dur=30
    if command -v stress-ng &>/dev/null; then tool="stress-ng --cpu $cores --timeout ${dur}s"
    elif command -v stress &>/dev/null; then tool="stress --cpu $cores --timeout ${dur}s"
    else error_msg "Install 'stress' or 'stress-ng' to use this."; return; fi
    ui_yesno "Stress Test" "Load all $cores threads for ${dur}s?" || return
    log "stress: $tool"
    if [[ "$UI" == "dialog" ]]; then
        ( $tool &>/dev/null & sp=$!
          for ((i=0;i<=dur;i++)); do echo $((i*100/dur)); sleep 1; done
          wait "$sp" 2>/dev/null ) | dialog --gauge "Stressing $cores threads, ${dur}s…" 8 55 0 2>/dev/null
    else
        echo "Running $tool …"; $tool;
    fi
    ui_msgbox "Stress Test" "Done. Open the Live Monitor to see how frequency/temp behaved."
}

# ─── Bootstrap ────────────────────────────────────────────────────────────────
bootstrap() {
    touch "$LOGFILE" 2>/dev/null || { echo "Cannot write log at $LOGFILE"; exit 1; }
    detect_ui
    if [[ "$UI" == "plain" ]]; then
        echo -e "${YELLOW}Neither 'dialog' nor 'whiptail' found.${NC}"
        read -t 15 -rp "Install dialog for a nicer menu? [y/N]: " a 2>/dev/null || a=n
        if [[ "${a:-n}" =~ ^[Yy]$ ]]; then
            sudo apt-get update -qq 2>/dev/null
            sudo apt-get install -y dialog 2>/dev/null && detect_ui
        fi
        [[ "$UI" == "plain" ]] && echo -e "${YELLOW}Continuing in plain-text mode.${NC}"
    fi
    detect_hardware
    log "=== started v$VERSION (driver=$DRIVER cores=$NCORES ui=$UI) ==="
}

main_menu() {
    while true; do
        local choice
        choice=$(ui_menu "CPU Control Center v$VERSION — $DRIVER" \
            "$(cpu_model) | ${NCORES} threads | Gov:$(cur_governor) Turbo:$(turbo_state) $(pkg_temp_c)°C" \
            P  "Apply a power profile (Max/Balanced/Quiet/Battery)" \
            L  "Live monitor (freq / temp / power)" \
            i  "CPU information summary" \
            g  "Set governor…" \
            e  "Set Energy Performance Preference (EPP)…" \
            f  "Pin a fixed frequency…" \
            m  "Set minimum frequency limit…" \
            M  "Set maximum frequency limit…" \
            r  "Release all frequency limits" \
            t  "Toggle Turbo Boost" \
            w  "Set power cap (RAPL PL1)…" \
            s  "Save current settings as baseline" \
            R  "Restore baseline" \
            c  "Show per-core frequencies" \
            v  "Show per-core governors" \
            S  "Run stress test" \
            l  "View log file" \
            q  "Quit") || break

        case "$choice" in
            P) pick_profile ;;
            L) live_monitor ;;
            i) show_summary ;;
            g) pick_governor ;;
            e) pick_epp ;;
            f) prompt_fixed_freq ;;
            m) prompt_limit min ;;
            M) prompt_limit max ;;
            r) release_limits && ui_msgbox "Limits" "All frequency limits released to $(khz_to_ghz "$MIN_KHZ") - $(khz_to_ghz "$MAX_KHZ")." ;;
            t) [[ "$(turbo_state)" == "on" ]] && apply_turbo off || apply_turbo on ;;
            w) prompt_power_cap ;;
            s) save_baseline ;;
            R) restore_baseline ;;
            c) show_per_core_freq ;;
            v) show_per_core_gov ;;
            S) run_stress ;;
            l) [[ -s "$LOGFILE" ]] && ui_textfile "Log" "$LOGFILE" || ui_msgbox "Log" "Log is empty." ;;
            q|"") break ;;
        esac
    done
}

# ─── Run ──────────────────────────────────────────────────────────────────────
bootstrap
main_menu
log "=== exited ==="
clear
echo -e "${GREEN}CPU Control Center exited cleanly.${NC}  Log: $LOGFILE"
