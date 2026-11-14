<#
.SYNOPSIS
    Detect new devices joining the local network and alert on them.

.DESCRIPTION
    monitor-network.ps1 periodically refreshes the ARP cache with a quick ping
    sweep, reads the neighbour table (Get-NetNeighbor, or `arp -a` / `ip neigh`
    as a fallback), and compares every MAC address with a known-devices
    baseline CSV (MAC, IP, hostname, first/last seen).

    - First run: the baseline is created (learning mode), no alerts.
    - New MAC: logged as NEW and alerted (console + beep + Windows balloon tip).
    - Known MAC on a different IP: logged as IP_CHANGED.

    Read-only towards the network apart from the ping sweep; needs no admin rights.

    Author : Arnold Rurangwa - MIT License
    Legal  : Only monitor networks you own or are authorised to monitor.

.PARAMETER Subnet
    Subnet to sweep in CIDR notation (/20 - /30). Default: auto-detected from
    the interface holding the default route.

.PARAMETER IntervalSeconds
    Seconds between checks (10-86400). Default: 300.

.PARAMETER Once
    Run a single check and exit (use with Task Scheduler).

.PARAMETER BaselinePath
    Known-devices CSV. Default: .\known-devices.csv

.PARAMETER LogPath
    Log of new/changed devices. Default: .\network-monitor.log

.PARAMETER NoSweep
    Do not ping-sweep; only read the current neighbour table.

.PARAMETER ArpFile
    Parse neighbour entries from a saved `arp -a` or `ip neigh` output file
    instead of the live table (testing / offline analysis). Implies -NoSweep.

.PARAMETER NoAlert
    Log only; no beep or pop-up.

.EXAMPLE
    .\monitor-network.ps1 -Once

.EXAMPLE
    .\monitor-network.ps1 -Subnet 192.168.1.0/24 -IntervalSeconds 120

.EXAMPLE
    arp -a > arp.txt; .\monitor-network.ps1 -Once -ArpFile .\arp.txt

.NOTES
    Requirements: Windows PowerShell 5.1+ or PowerShell 7+. Get-NetNeighbor is
    used on Windows 8/Server 2012 and later; otherwise `arp -a` is parsed.
#>
[CmdletBinding()]
param(
    [ValidatePattern('^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$')]
    [string]$Subnet,

    [ValidateRange(10, 86400)]
    [int]$IntervalSeconds = 300,

    [switch]$Once,

    [string]$BaselinePath = (Join-Path (Get-Location) 'known-devices.csv'),

    [string]$LogPath = (Join-Path (Get-Location) 'network-monitor.log'),

    [switch]$NoSweep,

    [string]$ArpFile,

    [switch]$NoAlert
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$onWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
$script:AlertsEnabled = -not $NoAlert
if ($ArpFile) {
    if (-not (Test-Path -LiteralPath $ArpFile)) { throw "Cannot read $ArpFile" }
    $NoSweep = $true
}

function Get-Timestamp { (Get-Date).ToString('yyyy-MM-dd HH:mm:sszzz') }

# Normalise MAC to lower-case aa:bb:cc:dd:ee:ff; return $null for
# broadcast/multicast/empty entries that are not real devices.
function ConvertTo-Mac([string]$Raw) {
    $m = $Raw.Trim().ToLower().Replace('-', ':')
    if ($m -notmatch '^([0-9a-f]{2}:){5}[0-9a-f]{2}$') { return $null }
    if ($m -eq 'ff:ff:ff:ff:ff:ff' -or $m -eq '00:00:00:00:00:00') { return $null }
    # Multicast MACs have the lowest bit of the first octet set.
    if (([Convert]::ToInt32($m.Substring(0, 2), 16) -band 1) -eq 1) { return $null }
    return $m
}

# Parse text from `arp -a` (Windows/macOS) or `ip neigh` (Linux).
function ConvertFrom-NeighbourText([string[]]$Lines) {
    foreach ($line in $Lines) {
        if ($line -match '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9a-fA-F]{2}(?:-[0-9a-fA-F]{2}){5})\s+(\w+)') {
            $mac = ConvertTo-Mac $Matches[2]                      # Windows arp -a
            if ($mac) { [pscustomobject]@{ Mac = $mac; IP = $Matches[1] } }
        }
        elseif ($line -match '^(\d{1,3}(?:\.\d{1,3}){3})\s.*lladdr\s+([0-9a-fA-F:]{17})\s+(\S+)') {
            if ($Matches[3] -notin 'FAILED', 'INCOMPLETE') {      # Linux ip neigh
                $mac = ConvertTo-Mac $Matches[2]
                if ($mac) { [pscustomobject]@{ Mac = $mac; IP = $Matches[1] } }
            }
        }
        elseif ($line -match '\((\d{1,3}(?:\.\d{1,3}){3})\) at ([0-9a-fA-F:]{11,17})') {
            # macOS / BSD arp -a, which may drop leading zeros (0:1b:...)
            $fixed = ($Matches[2].Split(':') | ForEach-Object { $_.PadLeft(2, '0') }) -join ':'
            $mac = ConvertTo-Mac $fixed
            if ($mac) { [pscustomobject]@{ Mac = $mac; IP = $Matches[1] } }
        }
    }
}

function Get-Neighbour {
    if ($ArpFile) { return ConvertFrom-NeighbourText (Get-Content -LiteralPath $ArpFile) }
    if ($onWindows -and (Get-Command Get-NetNeighbor -ErrorAction SilentlyContinue)) {
        return Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.State -notin 'Unreachable', 'Incomplete' } |
            ForEach-Object {
                $mac = ConvertTo-Mac $_.LinkLayerAddress
                if ($mac) { [pscustomobject]@{ Mac = $mac; IP = $_.IPAddress } }
            }
    }
    if (Get-Command ip -ErrorAction SilentlyContinue) { return ConvertFrom-NeighbourText (& ip -4 neigh show) }
    return ConvertFrom-NeighbourText (& arp -a)
}

function Get-DefaultSubnet {
    if ($onWindows -and (Get-Command Get-NetRoute -ErrorAction SilentlyContinue)) {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
            Sort-Object RouteMetric | Select-Object -First 1
        if ($route) {
            $addr = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($addr) { return "$($addr.IPAddress)/$($addr.PrefixLength)" }
        }
    }
    elseif (Get-Command ip -ErrorAction SilentlyContinue) {
        $dev = (& ip -4 route show default) -replace '.*\bdev\s+(\S+).*', '$1' | Select-Object -First 1
        if ($dev) {
            $line = & ip -4 route show dev $dev scope link | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+/\d+' } | Select-Object -First 1
            if ($line) { return ($line -split '\s+')[0] }
        }
    }
    return $null
}

# Ping every address in the subnet (TCP touch if ICMP is unavailable) so the
# OS learns their MAC addresses.
function Invoke-Sweep([string]$Cidr) {
    $ip, $prefix = $Cidr.Split('/')
    $prefix = [int]$prefix
    if ($prefix -lt 20 -or $prefix -gt 30) { throw 'Sweep subnet must be /20 - /30.' }
    $b = ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes()
    $n = ([uint64]$b[0] * 16777216) + ([uint64]$b[1] * 65536) + ([uint64]$b[2] * 256) + [uint64]$b[3]
    $size = [uint64][math]::Pow(2, 32 - $prefix)
    $net = $n - ($n % $size)

    $probe = {
        param([string]$Addr)
        try { [void](New-Object System.Net.NetworkInformation.Ping).Send($Addr, 500) }
        catch {
            $c = New-Object System.Net.Sockets.TcpClient
            try { [void]$c.BeginConnect($Addr, 80, $null, $null).AsyncWaitHandle.WaitOne(500) } catch { $null = $_ }
            finally { $c.Close() }
        }
    }
    $pool = [RunspaceFactory]::CreateRunspacePool(1, 64); $pool.Open()
    try {
        $jobs = for ($i = $net + 1; $i -lt $net + $size - 1; $i++) {
            $addr = '{0}.{1}.{2}.{3}' -f ([math]::Floor($i / 16777216) % 256), ([math]::Floor($i / 65536) % 256), ([math]::Floor($i / 256) % 256), ($i % 256)
            $ps = [PowerShell]::Create(); $ps.RunspacePool = $pool
            [void]$ps.AddScript($probe).AddArgument($addr)
            [pscustomobject]@{ PS = $ps; H = $ps.BeginInvoke() }
        }
        foreach ($j in $jobs) { [void]$j.PS.EndInvoke($j.H); $j.PS.Dispose() }
    }
    finally { $pool.Close(); $pool.Dispose() }
}

function Resolve-Name([string]$Ip) {
    try { $h = [System.Net.Dns]::GetHostEntry($Ip).HostName; if ($h -and $h -ne $Ip) { return $h } } catch { $null = $_ }
    return '-'
}

function Send-Alert([string]$Message) {
    Write-Host "[ALERT] $Message" -ForegroundColor Yellow
    if (-not $script:AlertsEnabled) { return }
    if ($onWindows) {
        try { [console]::Beep(880, 300) } catch { $null = $_ }
        try {
            # Balloon tip from the notification area (works on PowerShell 5.1 and 7 on Windows).
            Add-Type -AssemblyName System.Windows.Forms, System.Drawing
            $icon = New-Object System.Windows.Forms.NotifyIcon
            # Resolve the type by name at run time: a [System.Drawing.*] type
            # literal would be bound when the function is compiled and throws
            # on non-Windows PowerShell even if this branch never runs.
            $systemIcons = 'System.Drawing.SystemIcons' -as [type]
            $icon.Icon = $systemIcons::Warning
            $icon.Visible = $true
            $icon.ShowBalloonTip(8000, 'Network monitor', $Message, 'Warning')
            Start-Sleep -Seconds 2
            $icon.Dispose()
        } catch { Write-Verbose "Balloon tip unavailable: $_" }
    }
}

function Write-MonitorLog([string]$Text) {
    Add-Content -LiteralPath $LogPath -Value "$(Get-Timestamp) $Text"
}

function Invoke-Check {
    $now = Get-Timestamp
    $known = @{}
    $learning = -not (Test-Path -LiteralPath $BaselinePath)
    if (-not $learning) {
        foreach ($row in Import-Csv -LiteralPath $BaselinePath) { $known[$row.mac] = $row }
    }
    if (-not $NoSweep) { Invoke-Sweep $Subnet }

    $seen = @(Get-Neighbour | Sort-Object Mac -Unique)
    $new = 0; $changed = 0
    foreach ($d in $seen) {
        if (-not $known.ContainsKey($d.Mac)) {
            $name = Resolve-Name $d.IP
            $known[$d.Mac] = [pscustomobject]@{ mac = $d.Mac; ip = $d.IP; hostname = $name; first_seen = $now; last_seen = $now }
            if ($learning) { Write-MonitorLog "BASELINE mac=$($d.Mac) ip=$($d.IP) hostname=$name" }
            else {
                $new++
                Write-MonitorLog "NEW mac=$($d.Mac) ip=$($d.IP) hostname=$name"
                Send-Alert "New device: $($d.IP) ($($d.Mac), $name)"
            }
        }
        else {
            $k = $known[$d.Mac]
            if ($k.ip -ne $d.IP) {
                $changed++
                Write-MonitorLog "IP_CHANGED mac=$($d.Mac) old_ip=$($k.ip) new_ip=$($d.IP)"
                Write-Host "[INFO] $($d.Mac) moved from $($k.ip) to $($d.IP)"
                $k.ip = $d.IP
            }
            $k.last_seen = $now
        }
    }

    $known.Values | Sort-Object { [version]$_.ip } |
        Select-Object mac, ip, hostname, first_seen, last_seen |
        Export-Csv -LiteralPath $BaselinePath -NoTypeInformation

    if ($learning) { Write-Host "$now  Baseline created with $($seen.Count) device(s) -> $BaselinePath" }
    else { Write-Host "$now  $($seen.Count) device(s) seen, $new new, $changed IP change(s). Baseline: $($known.Count) known." }
}

if (-not $NoSweep) {
    if (-not $Subnet) { $Subnet = Get-DefaultSubnet }
    if (-not $Subnet) { throw 'Could not detect the local subnet; use -Subnet or -NoSweep.' }
    Write-Host "Monitoring $Subnet every $IntervalSeconds s (log: $LogPath, baseline: $BaselinePath)"
}

do {
    Invoke-Check
    if (-not $Once) { Start-Sleep -Seconds $IntervalSeconds }
} while (-not $Once)
