#Requires -Version 5.1
<#
.SYNOPSIS
    Reports this domain controller's Windows Update state to PatchMon without
    installing the PatchMon agent.

.DESCRIPTION
    Intended for hosts where installing the agent binary is not permitted (our
    domain controllers). setup-patchmon-dcs.ps1 enrolls the DC with PatchMon
    auto-enrollment, then drops this script plus a config.json and a
    credentials.json (this DC's own api_id/api_key, nothing shared) into
    C:\Program Files\PatchMon-Reporter and registers a scheduled task.

    Each run collects installed KBs (Get-HotFix), pending updates (Windows
    Update Agent COM API) and reboot-pending state, and POSTs them to
    /api/v1/hosts/update in exactly the payload shape the real agent uses, so
    the host looks like any other agent host in the PatchMon UI.

    It deliberately does NOT run the agent's ping/hash-gate check-in protocol;
    a full report per scheduled run is a few hundred KB at worst and the server
    COALESCEs fields it is not given.

.LICENSE
    The Windows Update collection and the report payload shape reproduce logic
    from the PatchMon agent (agent-source-code/internal/packages/windows.go),
    Copyright (c) PatchMon contributors, licensed under AGPL-3.0-only. This
    file is a "work based on the Program" under that licence and is offered
    under the same terms; the other files in this repository are not covered.
    Upstream source: https://github.com/PatchMon/PatchMon

.PARAMETER CredentialsDir
    Directory holding config.json and credentials.json.

.PARAMETER DryRun
    Collect and print the payload; do not contact the server.

.EXAMPLE
    .\patchmon-dc-reporter.ps1 -DryRun

.NOTES
    Exit codes: 0 = report delivered (or dry run), 1 = collection/POST failure,
    2 = not configured yet (run setup-patchmon-dcs.ps1 from an admin host).
    Log: C:\ProgramData\PatchMon-Reporter\report.log
#>
[CmdletBinding()]
param(
    [string]$ServerURL,
    [string]$ApiId,
    [string]$ApiKey,
    [string]$CredentialsDir,
    [string]$LogFile,
    [switch]$DryRun,
    [switch]$Heartbeat,
    [switch]$Full,
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'

# Defaults resolve here, not in the param block: param defaults must not call
# Join-Path or touch $env: (they evaluate in the wrong scope under some hosts).
if (-not $CredentialsDir) { $CredentialsDir = Join-Path $env:ProgramData 'PatchMon-Reporter' }
if (-not $LogFile)       { $LogFile = Join-Path $CredentialsDir 'report.log' }

$AgentVersionLabel = 'ps-reporter 1.0'

# A full WUA collection is the expensive one; the 30-minute task run mostly
# sends heartbeats. 12h keeps two full reports a day (boot and/or whatever
# crosses the staleness line) and the online badge (3x update interval) fresh.
$FullIntervalHours = 12
$lastFullFile = Join-Path $CredentialsDir 'last_full.txt'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try {
        # Same 1 MB rotation the installer uses, so a misbehaving loop cannot fill the system drive.
        if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 1MB) {
            Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
        }
        Add-Content -LiteralPath $LogFile -Value $line
    } catch { }
}

# --- DC-REPORT-BEGIN : tests/Run-Checks.ps1 executes this block verbatim ---
# Everything between these markers is pure: no CIM, no registry, no network,
# no WUA COM, so it runs and can be asserted anywhere.

function ConvertTo-JsonSafe {
    # PowerShell 5.1's ConvertTo-Json degrades a single-element array to a bare
    # object, which makes e.g. a one-category WUA entry fail the server's
    # []string unmarshal with a 400. Serialize explicitly so arrays stay arrays.
    param($Value)

    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64] -or
        $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
        return $Value.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [string]) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        foreach ($ch in $Value.ToCharArray()) {
            $code = [int]$ch
            if ($ch -eq '"')       { [void]$sb.Append('\"') }
            elseif ($ch -eq '\')   { [void]$sb.Append('\\') }
            elseif ($ch -eq "`b")  { [void]$sb.Append('\b') }
            elseif ($ch -eq "`f")  { [void]$sb.Append('\f') }
            elseif ($ch -eq "`n")  { [void]$sb.Append('\n') }
            elseif ($ch -eq "`r")  { [void]$sb.Append('\r') }
            elseif ($ch -eq "`t")  { [void]$sb.Append('\t') }
            elseif ($code -lt 32)  { [void]$sb.Append('\u' + $code.ToString('x4')) }
            else                   { [void]$sb.Append($ch) }
        }
        [void]$sb.Append('"')
        return $sb.ToString()
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = foreach ($k in $Value.Keys) {
            (ConvertTo-JsonSafe ([string]$k)) + ':' + (ConvertTo-JsonSafe $Value[$k])
        }
        return '{' + ($parts -join ',') + '}'
    }
    # PSCustomObject (test fixtures) is treated as a map too.
    if ($Value -is [pscustomobject]) {
        $parts = foreach ($prop in $Value.PSObject.Properties) {
            (ConvertTo-JsonSafe $prop.Name) + ':' + (ConvertTo-JsonSafe $prop.Value)
        }
        return '{' + ($parts -join ',') + '}'
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = foreach ($item in $Value) { ConvertTo-JsonSafe $item }
        return '[' + ($parts -join ',') + ']'
    }
    # Anything else (DateTime, enums) goes through its string form.
    return ConvertTo-JsonSafe ([string]$Value)
}

function New-HotfixPackage {
    # Maps one Get-HotFix object to PatchMon's Package shape for WUA entries.
    # Mirrors the agent's collector field for field so the UI treats both alike.
    param($Hotfix)

    $installedOn = ''
    if ($Hotfix.InstalledOn) {
        try { $installedOn = $Hotfix.InstalledOn.ToString('yyyy-MM-dd') } catch { $installedOn = '' }
    }
    if (-not $installedOn) { $installedOn = 'installed' }
    $desc = 'Installed'
    if ($installedOn -ne 'installed') { $desc = "Installed $installedOn" }

    return [ordered]@{
        name              = [string]$Hotfix.HotFixID
        description       = $desc
        category          = 'Windows Update'
        currentVersion    = 'installed'
        availableVersion  = ''
        needsUpdate       = $false
        isSecurityUpdate  = [bool]($Hotfix.Description -match 'Security')
        sourceRepository  = ''
        wuaGuid           = ''
        wuaKb             = [string]$Hotfix.HotFixID
        wuaSeverity       = ''
        wuaCategories     = @()
        wuaSupportUrl     = ''
        wuaRevisionNumber = 0
    }
}

function New-ReportPayload {
    # Builds the full /api/v1/hosts/update body. Deliberately omits "sections"
    # and "hashes": an absent sections field means full report, and the server
    # only recomputes hashes it actually receives, so we never have to
    # reproduce the agent's canonical hashing.
    param(
        [hashtable]$Identity,
        [array]$Packages,
        [bool]$NeedsReboot,
        [string]$RebootReason,
        [double]$ExecutionSeconds,
        [string]$AgentVersion = 'ps-reporter 1.0'
    )

    $payload = [ordered]@{
        packages         = @($Packages)
        osType           = 'Windows'
        osVersion        = [string]$Identity.osVersion
        hostname         = [string]$Identity.hostname
        ip               = [string]$Identity.ip
        architecture     = [string]$Identity.architecture
        agentVersion     = $AgentVersion
        machineId        = [string]$Identity.machineId
        kernelVersion    = [string]$Identity.kernelVersion
        selinuxStatus    = ''
        systemUptime     = [string]$Identity.systemUptime
        loadAverage      = @()
        cpuModel         = [string]$Identity.cpuModel
        cpuCores         = [int]$Identity.cpuCores
        ramInstalled     = [double]$Identity.ramInstalled
        swapSize         = 0
        diskDetails      = @($Identity.diskDetails)
        gatewayIp        = [string]$Identity.gatewayIp
        dnsServers       = @($Identity.dnsServers)
        networkInterfaces = @()
        executionTime    = [math]::Round($ExecutionSeconds, 2)
        needsReboot      = $NeedsReboot
        packageManager   = 'windows'
        agentExecutionMs = [int]($ExecutionSeconds * 1000)
    }
    # reboot_reason has no COALESCE guard on the server when needs_reboot is
    # absent, so only send the pair together.
    if ($NeedsReboot -and $RebootReason) { $payload.rebootReason = $RebootReason }
    if ($Identity.bootTime) { $payload.bootTime = [string]$Identity.bootTime }
    return $payload
}

function New-HeartbeatPayload {
    # The PatchMon UI marks a host offline when last_update is older than
    # 3x the configured update interval (dashboard.go), and last_update is
    # refreshed by ANY accepted /hosts/update - including a partial report.
    # This is that partial: hostname only, a few hundred bytes, no WUA COM,
    # no Get-HotFix. Coherence rules honored: hostname non-empty, every
    # unclaimed section absent/empty, and the server replaces package data
    # only when the packages section is claimed.
    param([string]$Hostname, [string]$MachineId, [string]$AgentVersion = 'ps-reporter 1.0')
    return [ordered]@{
        sections     = @('hostname')
        hostname     = $Hostname
        machineId    = $MachineId
        agentVersion = $AgentVersion
    }
}

# --- DC-REPORT-END ---

function Get-HostIdentity {
    # CIM-backed identity fields. Values mirror the agent's (osType 'Windows',
    # architecture like x86_64, uptime 'N days, N hours'); the server stores
    # most of these verbatim.
    $os = Get-CimInstance -ClassName Win32_OperatingSystem

    $arch = switch ($os.OSArchitecture) {
        '64-bit' { if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x86_64' } }
        '32-bit' { 'i686' }
        default  { [string]$os.OSArchitecture }
    }

    $uptime = (Get-Date) - $os.LastBootUpTime
    $days = [math]::Floor($uptime.TotalDays)
    $hours = $uptime.Hours
    if ($days -gt 0) { $uptimeStr = "$days days, $hours hours" } else { $uptimeStr = "$hours hours" }

    $cpus = @(Get-CimInstance -ClassName Win32_Processor)
    $cores = 0
    foreach ($cpu in $cpus) {
        $n = $cpu.NumberOfLogicalProcessors
        if (-not $n) { $n = 1 }
        $cores += $n
    }

    $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' |
        ForEach-Object {
            [ordered]@{
                name       = [string]$_.DeviceID
                size       = ('{0:N1} GB' -f ($_.Size / 1GB))
                mountpoint = [string]$_.DeviceID
            }
        })

    $ip = ''; $gateway = ''; $dns = @()
    $nics = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True')
    foreach ($nic in $nics) {
        if (-not $ip) {
            $v4 = @($nic.IPAddress) | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
            if ($v4) { $ip = $v4 }
        }
        if (-not $gateway -and $nic.DefaultIPGateway) { $gateway = @($nic.DefaultIPGateway)[0] }
        if (-not $dns -and $nic.DNSServerSearchOrder) { $dns = @($nic.DNSServerSearchOrder) }
    }

    $machineId = ''
    try {
        $machineId = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
    } catch { }

    return @{
        hostname      = [string]$env:COMPUTERNAME
        osVersion     = (([string]$os.Caption) -replace '^Microsoft\s+', '').Trim()
        architecture  = $arch
        kernelVersion = [string]$os.Version
        machineId     = $machineId
        systemUptime  = $uptimeStr
        bootTime      = $os.LastBootUpTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        cpuModel      = if ($cpus.Count) { [string]$cpus[0].Name } else { '' }
        cpuCores      = $cores
        ramInstalled  = [math]::Round(($os.TotalVisibleMemorySize / 1MB), 2)
        diskDetails   = $disks
        ip            = $ip
        gatewayIp     = $gateway
        dnsServers    = $dns
    }
}

function Get-RebootStatus {
    # Same two registry keys the agent's detector checks.
    $reasons = @()
    if (Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' -ErrorAction SilentlyContinue) {
        $reasons += 'Windows Update requires reboot'
    }
    if (Get-Item -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -ErrorAction SilentlyContinue) {
        $reasons += 'Component Based Servicing reboot pending'
    }
    return @{
        needsReboot = ($reasons.Count -gt 0)
        reason      = ($reasons -join '; ')
    }
}

function Send-ReportJson {
    # Posts a finished payload to /hosts/update; returns $true when the server
    # accepts it. One function shared by the full and heartbeat paths so TLS
    # handling and the 401 advice cannot drift between them.
    param([string]$Json, [string]$Label = 'Report')
    if ($SkipCertificateCheck) {
        # PS 5.1 has no -SkipCertificateCheck; process-lifetime callback instead.
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
    # PS 5.1 defaults to TLS 1.0 on some hosts; the server's TLS 1.2 is required.
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    try {
        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
        $resp = Invoke-RestMethod `
            -Uri "$ServerURL/api/v1/hosts/update" `
            -Method Post `
            -Headers @{ 'X-API-ID' = $ApiId; 'X-API-KEY' = $ApiKey } `
            -ContentType 'application/json' `
            -Body $bodyBytes `
            -TimeoutSec 180
        $msg = 'ok'
        if ($resp.message) { $msg = [string]$resp.message }
        Write-Log "$Label delivered; server said: $msg"
        return $true
    }
    catch {
        $status = ''
        try { if ($_.Exception.Response) { $status = [string][int]$_.Exception.Response.StatusCode } } catch { }
        if ($status -eq '401') {
            Write-Log "$Label rejected with HTTP 401. The host record may have been deleted in PatchMon; re-run setup-patchmon-dcs.ps1." 'ERROR'
        }
        else {
            Write-Log "$Label failed${status}: $($_.Exception.Message)" 'ERROR'
        }
        return $false
    }
}

# ------------------------------------------------------------------------ #
#  Config and credentials                                                   #
# ------------------------------------------------------------------------ #
$configFile = Join-Path $CredentialsDir 'config.json'
$credFile   = Join-Path $CredentialsDir 'credentials.json'

if (-not $ServerURL -or -not $ApiId -or -not $ApiKey) {
    if (-not (Test-Path -LiteralPath $configFile) -or -not (Test-Path -LiteralPath $credFile)) {
        Write-Log "Not configured: $configFile and/or $credFile missing. Run setup-patchmon-dcs.ps1 from an admin host first." 'ERROR'
        exit 2
    }
    $cfg  = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
    $cred = Get-Content -LiteralPath $credFile -Raw | ConvertFrom-Json
    if (-not $ServerURL) { $ServerURL = [string]$cfg.serverUrl }
    if (-not $ApiId)     { $ApiId     = [string]$cred.apiId }
    if (-not $ApiKey)    { $ApiKey     = [string]$cred.apiKey }
    if ($cfg.skipTlsVerify -and -not $SkipCertificateCheck) { $SkipCertificateCheck = $true }
}

if (-not $ServerURL -or -not $ApiId -or -not $ApiKey) {
    Write-Log 'serverUrl/apiId/apiKey incomplete; run setup-patchmon-dcs.ps1 again.' 'ERROR'
    exit 2
}

# ------------------------------------------------------------------------ #
#  Collect                                                                  #
# ------------------------------------------------------------------------ #
$collectStart = Get-Date
Write-Log "=== PatchMon DC reporter starting ==="

if ($Heartbeat -and $Full) { Write-Log '-Heartbeat and -Full are mutually exclusive.' 'ERROR'; exit 1 }
$mode = 'full'
if ($Heartbeat) {
    $mode = 'heartbeat'
}
elseif (-not $Full -and -not $DryRun -and (Test-Path -LiteralPath $lastFullFile)) {
    # Auto mode, which is what the scheduled task runs: the expensive full
    # collection happens only once the previous one has gone stale.
    try {
        $age = (Get-Date) - (Get-Item -LiteralPath $lastFullFile).LastWriteTime
        if ($age.TotalHours -lt $FullIntervalHours) { $mode = 'heartbeat' }
    } catch { }
}

if ($mode -eq 'heartbeat') {
    $hbMachineId = ''
    try { $hbMachineId = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid } catch { }
    $hbJson = ConvertTo-JsonSafe (New-HeartbeatPayload -Hostname ([string]$env:COMPUTERNAME) -MachineId $hbMachineId -AgentVersion $AgentVersionLabel)
    Write-Log "Heartbeat mode (last full report under $FullIntervalHours hours old); payload is $($hbJson.Length) bytes"
    if (Send-ReportJson -Json $hbJson -Label 'Heartbeat') { exit 0 }
    exit 1
}

$packages = @()

# Installed KBs: WMI-backed, works in every session.
$hotfixes = @()
try {
    $hotfixes = @(Get-HotFix -ErrorAction SilentlyContinue)
} catch {
    Write-Log "Get-HotFix failed: $($_.Exception.Message)" 'WARN'
}
foreach ($hf in $hotfixes) {
    if ($hf.HotFixID) { $packages += New-HotfixPackage $hf }
}
Write-Log "Installed KBs collected: $($packages.Count)"

# Pending updates via WUA COM. This is the part the real agent warns about in
# session 0 (a scheduled task runs there too), so failure is expected some of
# the time: degrade to installed-only and say so, rather than pretending.
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $results = $searcher.Search('IsInstalled=0 AND IsHidden=0')
    $pendingCount = 0
    foreach ($u in $results.Updates) {
        $kbs = @($u.KBArticleIDs | ForEach-Object { "KB$_" })
        $kbStr = $kbs -join ', '
        $name = [string]$u.Title
        if ($kbStr) { $name = "$($u.Title) ($kbStr)" }
        $guid = ''; $supportUrl = ''; $rev = 0
        try { $guid = [string]$u.Identity.UpdateID } catch { }
        try { $supportUrl = [string]$u.SupportURL } catch { }
        try { $rev = [int]$u.Identity.RevisionNumber } catch { }
        $cats = @($u.Categories | ForEach-Object { [string]$_.Name })
        $sev = ''
        try { if ($u.MsrcSeverity) { $sev = [string]$u.MsrcSeverity } } catch { }

        $packages += [ordered]@{
            name              = $name
            description       = [string]$u.Description
            category          = 'Windows Update'
            currentVersion    = 'pending'
            availableVersion  = ''
            needsUpdate       = $true
            isSecurityUpdate  = ($sev -eq 'Critical' -or $sev -eq 'Important')
            sourceRepository  = ''
            wuaGuid           = $guid
            wuaKb             = $kbStr
            wuaSeverity       = $sev
            wuaCategories     = $cats
            wuaSupportUrl     = $supportUrl
            wuaRevisionNumber = $rev
        }
        $pendingCount++
    }
    Write-Log "Pending updates collected: $pendingCount"
}
catch {
    Write-Log "WUA COM unavailable ($($_.Exception.Message)); reporting installed KBs only. Pending updates will be missing from this host's view." 'WARN'
}

$reboot = Get-RebootStatus
$identity = Get-HostIdentity
$execSeconds = ((Get-Date) - $collectStart).TotalSeconds

if ($packages.Count -eq 0) {
    # The server rejects a full report with an empty packages array, and a DC
    # with not a single hotfix does not exist in practice - if we get here,
    # something is badly wrong with WMI, so say so instead of sending junk.
    Write-Log 'No packages collected (Get-HotFix returned nothing); not reporting.' 'ERROR'
    exit 1
}

$payload = New-ReportPayload -Identity $identity -Packages $packages `
    -NeedsReboot $reboot.needsReboot -RebootReason $reboot.reason `
    -ExecutionSeconds $execSeconds -AgentVersion $AgentVersionLabel

$json = ConvertTo-JsonSafe $payload

if ($DryRun) {
    Write-Log "Dry run: payload is $($json.Length) bytes, packages=$($packages.Count), needsReboot=$($reboot.needsReboot)"
    Write-Output $json
    exit 0
}

# ------------------------------------------------------------------------ #
#  Report                                                                   #
# ------------------------------------------------------------------------ #
if (Send-ReportJson -Json $json -Label ('Report ({0} packages, needsReboot={1})' -f $packages.Count, $reboot.needsReboot)) {
    # Stamp the full report so the 30-minute task runs know a heartbeat
    # is enough for the next $FullIntervalHours.
    try { Set-Content -LiteralPath $lastFullFile -Value (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') } catch { }
    exit 0
}
exit 1
