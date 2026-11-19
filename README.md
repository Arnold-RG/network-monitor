# network-monitor

Watch your local network and get an alert when a device you have not seen
before joins it. Works on Windows (PowerShell) and Linux (bash).

| Script | Platform |
|--------|----------|
| `monitor-network.ps1` | Windows PowerShell 5.1+ / PowerShell 7+ |
| `monitor-network.sh`  | bash 4.3+ on Linux |

## How it works

1. **Refresh**: a quick parallel ping sweep of the subnet makes the OS learn
   the MAC address of every device that is on-line (ARP cache). When ICMP is
   not available, a TCP connection attempt is used instead - that still
   triggers an ARP lookup.
2. **Read** the neighbour table: `Get-NetNeighbor` (Windows), `ip neigh`
   (Linux), or `arp -a` as a fallback. Broadcast, multicast and
   failed/incomplete entries are ignored.
3. **Compare** each MAC address with a baseline file of known devices
   (`known-devices.csv`: mac, ip, hostname, first_seen, last_seen).
4. **Report**:
   - first run -> builds the baseline ("learning mode"), no alerts
   - unknown MAC -> `NEW` line in the log + alert
   - known MAC on a new IP -> `IP_CHANGED` line in the log
5. **Repeat** every `-IntervalSeconds` / `-i` seconds, or once with `-Once` / `-1`.

**Alerts**

| | Console | Sound | Desktop | System log |
|-|---------|-------|---------|------------|
| PowerShell (Windows) | yes | beep | notification-area balloon | - |
| bash (Linux) | yes | terminal bell | `notify-send` if a desktop session exists | `logger -t network-monitor` (syslog/journal) |

No admin/root rights are needed. Nothing is changed on the network; the only
traffic is the sweep.

## Requirements

- **PowerShell:** Windows PowerShell 5.1 or PowerShell 7+. On Windows 8 /
  Server 2012+ the built-in `NetTCPIP` cmdlets are used.
- **bash:** bash 4.3+, `iproute2` (`ip`) or `/proc/net/arp`, coreutils
  `timeout`. Optional: `ping`, `getent`, `notify-send` (libnotify), `logger`.

## Usage

### PowerShell

```powershell
Get-Help .\monitor-network.ps1 -Full

.\monitor-network.ps1 -Once                                  # one check (auto-detects subnet)
.\monitor-network.ps1 -Subnet 192.168.1.0/24 -IntervalSeconds 120
.\monitor-network.ps1 -NoSweep -BaselinePath C:\netmon\known.csv -LogPath C:\netmon\netmon.log

# Analyse a saved table (e.g. from another PC)
arp -a > arp.txt
.\monitor-network.ps1 -Once -ArpFile .\arp.txt
```

Run it every 15 minutes with Task Scheduler (action):
`powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\netmon\monitor-network.ps1 -Once -BaselinePath C:\netmon\known.csv -LogPath C:\netmon\netmon.log`

### bash

```bash
chmod +x monitor-network.sh
./monitor-network.sh -h

./monitor-network.sh -1                         # one check (auto-detects subnet)
./monitor-network.sh -t 192.168.1.0/24 -i 120   # check every 2 minutes
./monitor-network.sh -s -1                      # no sweep, current ARP table only
ip neigh > neigh.txt; ./monitor-network.sh -1 -f neigh.txt
```

Cron example (every 15 minutes):
`*/15 * * * * /opt/netmon/monitor-network.sh -1 -b /opt/netmon/known.csv -l /opt/netmon/netmon.log >/dev/null`

| bash | PowerShell | Default | Meaning |
|------|-----------|---------|---------|
| `-t CIDR` | `-Subnet` | auto | subnet to sweep (/20 - /30) |
| `-i SEC` | `-IntervalSeconds` | 300 | delay between checks |
| `-1` | `-Once` | off | single check |
| `-b FILE` | `-BaselinePath` | `./known-devices.csv` | baseline |
| `-l FILE` | `-LogPath` | `./network-monitor.log` | event log |
| `-s` | `-NoSweep` | off | skip sweep |
| `-f FILE` | `-ArpFile` | - | read a saved neighbour table |
| - | `-NoAlert` | off | log only, no beep/pop-up |

Each script keeps its own baseline format (the PowerShell CSV is quoted), so
use separate baseline files for the two versions.

## Example output

Real run of the bash version using the recorded tables in `tests/fixtures/`
(documentation addresses 192.0.2.x, locally administered MACs). Day 1 builds
the baseline; on day 2 one device moved IP and a new one appeared:

```
$ ./monitor-network.sh -1 -f tests/fixtures/neigh-day1.txt
2026-11-14 13:51:33+0100  Baseline created with 3 device(s) -> ./known-devices.csv

$ ./monitor-network.sh -1 -f tests/fixtures/neigh-day2.txt
[INFO] 02:00:5e:00:00:14 moved from 192.0.2.20 to 192.0.2.21
[ALERT] New device: 192.0.2.55 (02:00:5e:00:00:37, -)
2026-11-14 13:51:33+0100  4 device(s) seen, 1 new, 1 IP change(s). Baseline: 4 known.
```

`network-monitor.log`:

```
2026-11-14 13:51:33+0100 BASELINE mac=02:00:5e:00:00:01 ip=192.0.2.1 hostname=-
2026-11-14 13:51:33+0100 BASELINE mac=02:00:5e:00:00:0a ip=192.0.2.10 hostname=-
2026-11-14 13:51:33+0100 BASELINE mac=02:00:5e:00:00:14 ip=192.0.2.20 hostname=-
2026-11-14 13:51:33+0100 IP_CHANGED mac=02:00:5e:00:00:14 old_ip=192.0.2.20 new_ip=192.0.2.21
2026-11-14 13:51:33+0100 NEW mac=02:00:5e:00:00:37 ip=192.0.2.55 hostname=-
```

`known-devices.csv`:

```
mac,ip,hostname,first_seen,last_seen
02:00:5e:00:00:01,192.0.2.1,-,2026-11-14 13:51:33+0100,2026-11-14 13:51:33+0100
02:00:5e:00:00:0a,192.0.2.10,-,2026-11-14 13:51:33+0100,2026-11-14 13:51:33+0100
02:00:5e:00:00:14,192.0.2.21,-,2026-11-14 13:51:33+0100,2026-11-14 13:51:33+0100
02:00:5e:00:00:37,192.0.2.55,-,2026-11-14 13:51:33+0100,2026-11-14 13:51:33+0100
```

## Tests

```bash
bash tests/run-tests.sh   # uses tests/fixtures; also tests the .ps1 if pwsh is installed
```

The PowerShell test also feeds a Windows `arp -a` capture
(`tests/fixtures/arp-windows.txt`) to check that parser. CI (GitHub Actions)
runs ShellCheck, PSScriptAnalyzer and the tests on every push.

## Limitations

- Sees only devices on the **same layer-2 segment** (ARP does not cross routers).
- MAC randomisation on phones (private Wi-Fi addresses) can make one phone look
  like a "new" device after it rotates its MAC.
- A device that is on-line but silent and ignores the sweep may be missed until it talks.
- IPv4 only. MAC addresses can be spoofed; treat this as an early-warning tool,
  not proof of identity.

## Legal and ethical use

Only monitor networks you own or are authorised to monitor.

## License

[MIT](LICENSE) - Copyright (c) 2026 Arnold Rurangwa

---

## Maintainer verification and operational safety

The monitor observes network neighbor tables and local probes; it does not guarantee the discovery of every connected device. Run only on networks you are authorized to monitor.

- **Privacy:** MAC/IP records and device names can be sensitive; keep baselines and logs out of public Git commits, set retention and protect local file permissions.
- **Accuracy:** test baseline creation, repeat runs, new-device alerts, changed IP detection, no-response scenarios and corrupted baseline handling.
- **Compatibility:** test Windows PowerShell and Linux bash separately, including user-session notification behavior and missing optional utilities.
- **Reliability:** guard against noisy repeat alerts, stale ARP entries and excessive network probing.
- **Release requirements:** record passing script/static-analysis tests and a supervised real-network smoke test before publishing version claims.

This lightweight utility does not require Kubernetes or continuous cloud hosting.
