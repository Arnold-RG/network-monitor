#!/usr/bin/env bash
# Tests for monitor-network.sh / monitor-network.ps1 using recorded neighbour
# tables (tests/fixtures) - no live network needed. Addresses are from the
# 192.0.2.0/24 documentation range; MACs are locally administered.
set -euo pipefail
cd "$(dirname "$0")/.."
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

echo "== bash: day 1 builds the baseline"
./monitor-network.sh -1 -f tests/fixtures/neigh-day1.txt -b "$W/kd.csv" -l "$W/nm.log"
[[ $(grep -c '^02:' "$W/kd.csv") -eq 3 ]] || fail "baseline should hold 3 devices (FAILED entry skipped)"
grep -q "NEW" "$W/nm.log" && fail "learning run must not alert"

echo "== bash: day 2 detects one new device and one IP change"
./monitor-network.sh -1 -f tests/fixtures/neigh-day2.txt -b "$W/kd.csv" -l "$W/nm.log" | tee "$W/out.txt"
grep -q "NEW mac=02:00:5e:00:00:37 ip=192.0.2.55" "$W/nm.log" || fail "new device not logged"
grep -q "IP_CHANGED mac=02:00:5e:00:00:14 old_ip=192.0.2.20 new_ip=192.0.2.21" "$W/nm.log" || fail "IP change not logged"
grep -q "1 new, 1 IP change" "$W/out.txt" || fail "summary wrong"

echo "== bash: day 2 again is quiet"
out=$(./monitor-network.sh -1 -f tests/fixtures/neigh-day2.txt -b "$W/kd.csv" -l "$W/nm.log"); grep -q "0 new, 0 IP" <<< "$out" || fail "repeat run not quiet"

echo "== bash: validation"
./monitor-network.sh -i 1 -1 -s >/dev/null 2>&1 && fail "interval 1 accepted"
grep -q Usage <<< "$(./monitor-network.sh -h)" || fail "help missing"

if command -v pwsh >/dev/null 2>&1; then
    echo "== pwsh: learn from Linux format, then detect from Windows arp -a format"
    pwsh -NoProfile -Command "
        ./monitor-network.ps1 -Once -ArpFile tests/fixtures/neigh-day1.txt -BaselinePath '$W/kp.csv' -LogPath '$W/np.log' -NoAlert
        ./monitor-network.ps1 -Once -ArpFile tests/fixtures/neigh-day2.txt -BaselinePath '$W/kp.csv' -LogPath '$W/np.log' -NoAlert
        ./monitor-network.ps1 -Once -ArpFile tests/fixtures/arp-windows.txt -BaselinePath '$W/kp.csv' -LogPath '$W/np.log' -NoAlert
    "
    grep -q "NEW mac=02:00:5e:00:00:37 ip=192.0.2.55" "$W/np.log" || fail "pwsh new device not logged"
    grep -q "IP_CHANGED mac=02:00:5e:00:00:14 old_ip=192.0.2.21 new_ip=192.0.2.20" "$W/np.log" || fail "pwsh did not parse Windows arp -a"
    grep -q "ff-ff\|ff:ff:ff" "$W/kp.csv" && fail "broadcast entry should be ignored"
fi
echo "All tests passed."
