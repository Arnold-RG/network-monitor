#!/usr/bin/env bash
# =============================================================================
# monitor-network.sh - Detect new devices joining the local network
# -----------------------------------------------------------------------------
# Purpose : Periodically discover devices (optional ping sweep to refresh the
#           ARP cache, then read the ARP/neighbour table), compare them with a
#           known-devices baseline (MAC/IP/hostname) and log + alert on any
#           device that was not seen before, or a known MAC on a new IP.
# Usage   : ./monitor-network.sh [-t 192.168.1.0/24] [-i 300] [-1]
#                                [-b known-devices.csv] [-l network-monitor.log]
#           ./monitor-network.sh -h
# Requires: bash 4.3+, iproute2 (`ip neigh`) or /proc/net/arp, coreutils
#           `timeout`. Optional: `ping`, `getent`, `notify-send`, `logger`.
#           No root needed (the ARP table is readable by any user).
# Author  : Arnold Rurangwa - MIT License
# Legal   : Only monitor networks you own or are authorised to monitor.
# =============================================================================
set -uo pipefail

TARGET=""                 # empty = auto-detect the subnet of the default route
INTERVAL=300
ONCE=0
BASELINE="./known-devices.csv"
LOGFILE="./network-monitor.log"
NO_SWEEP=0
ARP_FILE=""               # read neighbour data from a file (testing / offline)
JOBS=64

usage() {
    cat <<USAGE
Usage: $(basename "$0") [options]

Watch the local network and alert when a new device appears.

  -t CIDR    Subnet to sweep (default: auto-detect from the default route)
  -i SEC     Seconds between checks (default: $INTERVAL, min 10)
  -1         Run one check and exit (good for cron / systemd timers)
  -b FILE    Known-devices baseline CSV (default: $BASELINE)
  -l FILE    Log file for new/changed devices (default: $LOGFILE)
  -s         Skip the ping sweep, only read the current ARP table
  -f FILE    Read neighbour entries from FILE (\`ip neigh\` format) instead of
             the live table - used by the tests; implies -s
  -h         Show this help

The first run creates the baseline (learning mode) without alerting.
Delete or edit the baseline file to re-learn.

Examples:
  $(basename "$0") -1
  $(basename "$0") -t 192.168.1.0/24 -i 120 -l /var/tmp/netmon.log
USAGE
}

die() { echo "Error: $*" >&2; exit 2; }
is_int_between() { [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 )); }
ts() { date '+%Y-%m-%d %H:%M:%S%z'; }

while getopts ":t:i:b:l:f:1sh" opt; do
    case "$opt" in
        t) TARGET="$OPTARG" ;;
        i) INTERVAL="$OPTARG" ;;
        1) ONCE=1 ;;
        b) BASELINE="$OPTARG" ;;
        l) LOGFILE="$OPTARG" ;;
        s) NO_SWEEP=1 ;;
        f) ARP_FILE="$OPTARG"; NO_SWEEP=1 ;;
        h) usage; exit 0 ;;
        :) die "option -$OPTARG needs a value (see -h)" ;;
        *) die "unknown option -$OPTARG (see -h)" ;;
    esac
done
is_int_between "$INTERVAL" 10 86400 || die "-i must be 10-86400 seconds"
[[ -z "$ARP_FILE" || -r "$ARP_FILE" ]] || die "cannot read $ARP_FILE"

# ---- subnet helpers --------------------------------------------------------------
ip_to_int() { local a b c d; IFS=. read -r a b c d <<< "$1"; echo $(( (a<<24)|(b<<16)|(c<<8)|d )); }
int_to_ip() { local n=$1; echo "$(( (n>>24)&255 )).$(( (n>>16)&255 )).$(( (n>>8)&255 )).$(( n&255 ))"; }

detect_subnet() {
    # The connected route on the default interface, e.g. "192.168.1.0/24".
    local dev
    dev=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -n "$dev" ]] || return 1
    ip -4 route show dev "$dev" scope link 2>/dev/null | awk '$1 ~ /\// {print $1; exit}'
}

if (( ! NO_SWEEP )); then
    [[ -n "$TARGET" ]] || TARGET=$(detect_subnet) || true
    [[ -n "$TARGET" ]] || die "could not detect the subnet; pass -t CIDR or -s"
    [[ "$TARGET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || die "bad CIDR: $TARGET"
    PFX=${BASH_REMATCH[2]}
    is_int_between "$PFX" 20 30 || die "sweep prefix must be /20 - /30"
fi

HAVE_PING=0; command -v ping >/dev/null 2>&1 && HAVE_PING=1

# Ping (or TCP-touch) every address so the kernel refreshes its ARP cache.
sweep() {
    local size net i ip
    size=$(( 1 << (32 - PFX) ))
    net=$(( $(ip_to_int "${TARGET%/*}") / size * size ))
    for (( i = net + 1; i < net + size - 1; i++ )); do
        ip=$(int_to_ip "$i")
        if (( HAVE_PING )); then
            ping -c 1 -W 1 "$ip" >/dev/null 2>&1 &
        else
            # Any connection attempt triggers an ARP request for on-link hosts.
            # shellcheck disable=SC2016  # $1 is expanded by the inner bash
            timeout 1 bash -c 'exec 3<>"/dev/tcp/$1/80"' _ "$ip" >/dev/null 2>&1 &
        fi
        while (( $(jobs -rp | wc -l) >= JOBS )); do wait -n; done
    done
    wait
}

# Print "mac ip" pairs for every usable neighbour entry.
read_neighbours() {
    if [[ -n "$ARP_FILE" ]]; then
        cat "$ARP_FILE"
    elif command -v ip >/dev/null 2>&1; then
        ip -4 neigh show
    else
        # /proc/net/arp fallback -> convert to "IP dev X lladdr MAC STATE"
        awk 'NR > 1 && $4 != "00:00:00:00:00:00" {print $1, "dev", $6, "lladdr", $4, "REACHABLE"}' /proc/net/arp
    fi | awk '
        {
            mac = ""; for (i = 1; i < NF; i++) if ($i == "lladdr") mac = tolower($(i + 1))
            state = $NF
            if (mac != "" && state != "FAILED" && state != "INCOMPLETE") print mac, $1
        }' | sort -u
}

resolve_name() {
    local n=""
    command -v getent >/dev/null 2>&1 && n=$(getent hosts "$1" 2>/dev/null | awk '{print $2; exit}')
    echo "${n:--}"
}

alert() {
    local msg=$1
    echo -e "\a[ALERT] $msg"                                   # console + bell
    command -v logger >/dev/null 2>&1 && logger -t network-monitor -- "$msg"
    if command -v notify-send >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        notify-send "Network monitor" "$msg" >/dev/null 2>&1 || true
    fi
}

log_line() { echo "$(ts) $*" >> "$LOGFILE" || die "cannot write $LOGFILE"; }

# ---- one monitoring pass ---------------------------------------------------------
check_once() {
    local learning=0 now mac ip name new=0 changed=0 total=0
    declare -A KIP=() KNAME=() KFIRST=() KLAST=()
    now=$(ts)

    if [[ -f "$BASELINE" ]]; then
        while IFS=, read -r mac ip name first last; do
            [[ "$mac" == mac || -z "$mac" ]] && continue
            KIP[$mac]=$ip; KNAME[$mac]=$name; KFIRST[$mac]=$first; KLAST[$mac]=$last
        done < "$BASELINE"
    else
        learning=1
    fi

    (( NO_SWEEP )) || sweep

    while read -r mac ip; do
        [[ -n "$mac" ]] || continue
        total=$(( total + 1 ))
        if [[ -z "${KIP[$mac]+x}" ]]; then
            name=$(resolve_name "$ip")
            KIP[$mac]=$ip; KNAME[$mac]=$name; KFIRST[$mac]=$now; KLAST[$mac]=$now
            if (( learning )); then
                log_line "BASELINE mac=$mac ip=$ip hostname=$name"
            else
                new=$(( new + 1 ))
                log_line "NEW mac=$mac ip=$ip hostname=$name"
                alert "New device: $ip ($mac, $name)"
            fi
        else
            if [[ "${KIP[$mac]}" != "$ip" ]]; then
                changed=$(( changed + 1 ))
                log_line "IP_CHANGED mac=$mac old_ip=${KIP[$mac]} new_ip=$ip"
                echo "[INFO] $mac moved from ${KIP[$mac]} to $ip"
                KIP[$mac]=$ip
            fi
            KLAST[$mac]=$now
        fi
    done < <(read_neighbours)

    # Rewrite the baseline atomically.
    local tmp="$BASELINE.tmp.$$"
    {
        echo "mac,ip,hostname,first_seen,last_seen"
        for mac in "${!KIP[@]}"; do
            echo "$mac,${KIP[$mac]},${KNAME[$mac]},${KFIRST[$mac]},${KLAST[$mac]}"
        done | sort -t, -k2,2V
    } > "$tmp" || die "cannot write $tmp"
    mv "$tmp" "$BASELINE" || die "cannot write $BASELINE"

    if (( learning )); then
        echo "$now  Baseline created with $total device(s) -> $BASELINE"
    else
        echo "$now  $total device(s) seen, $new new, $changed IP change(s). Baseline: ${#KIP[@]} known."
    fi
}

trap 'echo; echo "Stopped."; exit 0' INT TERM
if (( ! NO_SWEEP )); then
    echo "Monitoring $TARGET every ${INTERVAL}s (log: $LOGFILE, baseline: $BASELINE)"
fi
while :; do
    check_once
    (( ONCE )) && break
    sleep "$INTERVAL"
done
