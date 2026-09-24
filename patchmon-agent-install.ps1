#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs the PatchMon agent on a Windows machine and self-enrolls the host record.

.DESCRIPTION
    What it does, in order:
      1. Exits quietly (code 0) if a healthy PatchMonAgent service is already installed.
      2. Calls the PatchMon auto-enrollment API to create this machine's host record
         and get its permanent api_id / api_key. No pre-populating hosts required.
      3. Downloads the agent binary for this machine's architecture.
      4. Writes config.yml and credentials under C:\ProgramData\PatchMon.
      5. Verifies with `patchmon-agent ping`, then creates and starts the
         PatchMonAgent service (LocalSystem, automatic, auto-restart on failure).

    It is idempotent and cheap on repeat runs, so it is meant to be run every day
    from a GPO Scheduled Task as SYSTEM. New domain members pick up the GPO and
    install themselves.

.PARAMETER ServerURL
    Base URL of the PatchMon server. Defaults to $DefaultServerURL below.

.PARAMETER RegisterScheduledTask
    Also register the daily "PatchMon Agent Install" scheduled task on this machine.
    Use this for the first push (Intune / PDQ / PsExec); GPO-managed machines get the
    task from Group Policy instead and do not need this.

.PARAMETER Force
    Reinstall the agent even if the service already exists.

.EXAMPLE
    .\patchmon-agent-install.ps1
    Install using the settings hard-coded below.

.EXAMPLE
    .\patchmon-agent-install.ps1 -RegisterScheduledTask
    Install and leave a daily self-healing task behind on this box.

.EXAMPLE
    .\patchmon-agent-install.ps1 -ServerURL "http://patchmon.example.com:3000" -SkipSslVerify $true
    Point at a different server without editing the script.

.NOTES
    Deployment walkthrough (auto-enrollment token, signing, GPO): see README.md
    Cleanup: uninstall-patchmon-agent.ps1
#>
[CmdletBinding()]
param(
    # ------------------------------------------------------------------ #
    #  SITE SETTINGS - these three are the ones you edit.                #
    # ------------------------------------------------------------------ #
    # Put your real PatchMon URL here. HTTPS is strongly preferred: the agent sends
    # its API credentials on every report. If your server is still plain HTTP on a
    # port, uncomment the line below, change the one above, and switch back to HTTPS
    # as soon as the server has a certificate.
    # [string]$ServerURL = "http://patchmon.example.com:3000",
    [string]$ServerURL = "https://patchmon.example.com",

    # PatchMon -> Settings -> Auto Enrollment: create a token and paste both halves here.
    [string]$AutoEnrollmentKey = "REPLACE_WITH_AUTO_ENROLLMENT_KEY",
    [string]$AutoEnrollmentSecret = "REPLACE_WITH_AUTO_ENROLLMENT_SECRET",

    # ------------------------------------------------------------------ #
    #  Rarely changed                                                    #
    # ------------------------------------------------------------------ #
    # Empty means the standard Windows folders, worked out below. They are not
    # defaults here because a param default that calls Join-Path on a missing
    # environment variable fails before any logging exists - and this script runs
    # unattended as SYSTEM, where the environment is not always what you expect.
    [string]$InstallPath = '',
    [string]$ConfigPath = '',
    [string]$FriendlyName = $env:COMPUTERNAME,
    # Only set this for a temporary self-signed-cert situation; install the CA cert instead.
    [bool]$SkipSslVerify = $false,
    [string]$ServiceName = 'PatchMonAgent',
    [string]$ServiceDisplayName = 'PatchMon Agent',
    [string]$TaskName = 'PatchMon Agent Install',
    [switch]$RegisterScheduledTask,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$ServiceDescription = 'PatchMon Agent - Monitors system packages and sends updates to PatchMon server'

function Get-WindowsFolder {
    # Env var first, then the shell API, then SystemRoot. A SYSTEM task can start with
    # a stripped environment, and Join-Path on a null value fails before we can log.
    param([string]$SpecialFolder, [string]$FromEnv)
    if ($FromEnv) { return $FromEnv.TrimEnd('\') }
    try {
        $p = [Environment]::GetFolderPath($SpecialFolder)
        if ($p) { return $p.TrimEnd('\') }
    }
    catch { }
    $root = if ($env:SystemRoot) { $env:SystemRoot.TrimEnd('\') } else { 'C:\Windows' }
    if ($SpecialFolder -eq 'ProgramFiles') { return "$root\Program Files" }
    return "$root\ProgramData"
}

if (-not $InstallPath) {
    $InstallPath = Join-Path (Get-WindowsFolder 'ProgramFiles' $env:ProgramFiles) 'PatchMon'
}
if (-not $ConfigPath) {
    $ConfigPath = Join-Path (Get-WindowsFolder 'CommonApplicationData' $env:ProgramData) 'PatchMon'
}

$LogFile = Join-Path $ConfigPath 'deploy.log'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    try {
        if (-not (Test-Path $ConfigPath)) {
            New-Item -ItemType Directory -Force -Path $ConfigPath | Out-Null
        }
        Add-Content -Path $LogFile -Value $line
    }
    catch {
        # Never let logging break an install.
    }
}

function Get-HttpStatus {
    param($ErrorRecord)
    try { return [int]$ErrorRecord.Exception.Response.StatusCode }
    catch { return 0 }
}

function Invoke-PatchMonWebRequest {
    # Thin wrapper so -SkipCertificateCheck (PS 6+) and the .NET callback (PS 5.1)
    # are handled in one place.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'Get',
        [hashtable]$Headers = @{},
        [string]$Body,
        [string]$ContentType,
        [string]$OutFile,
        [int]$TimeoutSec = 300
    )
    $params = @{
        Uri             = $Uri
        Method          = $Method
        Headers         = $Headers
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
    }
    if ($Body) { $params['Body'] = $Body }
    if ($ContentType) { $params['ContentType'] = $ContentType }
    if ($OutFile) { $params['OutFile'] = $OutFile }
    if ($SkipSslVerify -and $PSVersionTable.PSVersion.Major -ge 6) {
        $params['SkipCertificateCheck'] = $true
    }
    return Invoke-WebRequest @params
}

# -------------------------------------------------------------------- #
#  Preflight                                                           #
# -------------------------------------------------------------------- #
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if ($SkipSslVerify) {
    # Windows PowerShell 5.1 has no -SkipCertificateCheck; do it at the .NET layer.
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

$ServerURL = $ServerURL.TrimEnd('/')

$arch = 'amd64'
if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { $arch = 'arm64' }

$binaryName = 'patchmon-agent.exe'
$targetPath = Join-Path $InstallPath $binaryName
# GetTempPath() falls back to %SystemRoot%\Temp rather than returning null.
$tmpDir = if ($env:TEMP) { $env:TEMP.TrimEnd('\') } else { [IO.Path]::GetTempPath().TrimEnd('\') }
$tempPath = Join-Path $tmpDir "patchmon-agent-windows-$arch.exe"
$configFile = Join-Path $ConfigPath 'config.yml'
$serviceName = $ServiceName

Write-Log "=== PatchMon agent install starting (server=$ServerURL arch=$arch ps=$($PSVersionTable.PSVersion)) ==="

if ($AutoEnrollmentKey -like 'REPLACE_WITH_*' -or $AutoEnrollmentSecret -like 'REPLACE_WITH_*') {
    Write-Log "Auto-enrollment key/secret are still placeholders. Edit `$AutoEnrollmentKey and `$AutoEnrollmentSecret at the top of this script." 'ERROR'
    exit 2
}

# -------------------------------------------------------------------- #
#  Already installed?                                                  #
# -------------------------------------------------------------------- #
$existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

function Get-ServiceBinaryPath {
    # PathName comes back as one of:
    #   "C:\Program Files\PatchMon\patchmon-agent.exe" serve
    #   C:\Program Files\PatchMon\patchmon-agent.exe serve
    #   C:\Windows\system32\svchost.exe -k netsvcs
    # Splitting on spaces breaks the forms with spaces, so take everything up to the
    # first .exe instead, then fall back to the raw string.
    param([string]$Name)
    try {
        $svcInfo = Get-CimInstance Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    }
    catch { return $null }
    if (-not $svcInfo -or -not $svcInfo.PathName) { return $null }

    $raw = $svcInfo.PathName.Trim()
    $exeMatch = [regex]::Match($raw, '^"?(.+?\.exe)"?')
    if ($exeMatch.Success -and (Test-Path -LiteralPath $exeMatch.Groups[1].Value)) {
        return $exeMatch.Groups[1].Value
    }
    if (Test-Path -LiteralPath $raw) { return $raw }
    return $null
}

if ($existingService -and -not $Force) {
    $binPath = Get-ServiceBinaryPath -Name $serviceName

    if ($binPath) {
        if ($existingService.Status -ne 'Running') {
            Write-Log "Service exists but is stopped, starting it."
            Start-Service -Name $serviceName -ErrorAction SilentlyContinue
        }
        # Deliberately not logged to deploy.log: this is the daily happy path.
        Write-Host "PatchMon agent already installed and healthy, nothing to do."
        exit 0
    }

    Write-Log "Service exists but its binary is missing, reinstalling." 'WARN'
    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
    & sc.exe delete $serviceName | Out-Null
    Start-Sleep -Seconds 2
}

# -------------------------------------------------------------------- #
#  Step 1 - enroll this host and get permanent API credentials         #
# -------------------------------------------------------------------- #
$apiId = $null
$apiKey = $null

Write-Log "Enrolling host '$FriendlyName' via auto-enrollment..."
try {
    $enrollBody = @{ friendly_name = $FriendlyName } | ConvertTo-Json
    $enroll = Invoke-PatchMonWebRequest `
        -Uri "$ServerURL/api/v1/auto-enrollment/enroll" `
        -Method Post `
        -Headers @{
            'X-Auto-Enrollment-Key'    = $AutoEnrollmentKey
            'X-Auto-Enrollment-Secret' = $AutoEnrollmentSecret
        } `
        -Body $enrollBody `
        -ContentType 'application/json'

    $enrollData = $enroll.Content | ConvertFrom-Json
    # API returns { host: { api_id, api_key } }; be forgiving if that changes.
    if ($enrollData.host) {
        $apiId = $enrollData.host.api_id
        $apiKey = $enrollData.host.api_key
    }
    elseif ($enrollData.api_id) {
        $apiId = $enrollData.api_id
        $apiKey = $enrollData.api_key
    }

    if (-not $apiId -or -not $apiKey) {
        throw "enrollment response did not contain api_id/api_key"
    }
    Write-Log "Enrolled successfully (api_id=$apiId)"
}
catch {
    $code = Get-HttpStatus $_
    Write-Log "Auto-enrollment failed (HTTP $code): $($_.Exception.Message)" 'ERROR'
    if ($code -eq 401 -or $code -eq 403) {
        Write-Log "Auto-enrollment credentials were rejected. Check the token in PatchMon -> Settings -> Auto Enrollment." 'ERROR'
    }
    elseif ($code -eq 409) {
        Write-Log "A host named '$FriendlyName' already exists and auto-enrollment refused to re-issue credentials. If this machine has no agent, delete the stale host record in PatchMon and run again." 'ERROR'
    }
    exit 1
}

$credHeaders = @{ 'X-API-ID' = $apiId; 'X-API-KEY' = $apiKey }

# -------------------------------------------------------------------- #
#  Step 2 - download the agent binary                                  #
# -------------------------------------------------------------------- #
if (Test-Path $tempPath) { Remove-Item $tempPath -Force -ErrorAction SilentlyContinue }

function Get-AgentBinary {
    param([hashtable]$Headers)
    $url = "$ServerURL/api/v1/hosts/agent/download?arch=$arch&os=windows"
    Write-Log "Downloading agent binary from $url ..."
    Invoke-PatchMonWebRequest -Uri $url -Headers $Headers -OutFile $tempPath -TimeoutSec 600 | Out-Null
}

$downloaded = $false
try {
    Get-AgentBinary -Headers $credHeaders
    $downloaded = $true
}
catch {
    Write-Log "Direct binary download failed (HTTP $(Get-HttpStatus $_)): $($_.Exception.Message)" 'WARN'
    Write-Log "Falling back to the bootstrap-token flow..."
}

if (-not $downloaded) {
    # Fallback: fetch the official installer script, pull the bootstrap token out of it
    # and exchange it for credentials, then retry the download. Those exchanged
    # credentials are used ONLY for the download - this machine keeps the identity it
    # got from auto-enrollment, otherwise the report lands against the wrong host.
    try {
        $installer = Invoke-PatchMonWebRequest -Uri "$ServerURL/api/v1/hosts/install?os=windows" -Headers $credHeaders
        # The installer wraps the token in "..." or, when it is embedded in a nested
        # powershell -c command, in ""..". Accept either, and unquoted.
        $match = [regex]::Match($installer.Content, 'PATCHMON_BOOTSTRAP_TOKEN\s*=\s*["'']{0,2}([^"''\s\r\n;)]+)["'']{0,2}')
        if (-not $match.Success) { throw 'could not find PATCHMON_BOOTSTRAP_TOKEN in the installer script' }
        $bootstrapToken = $match.Groups[1].Value

        $exchange = Invoke-PatchMonWebRequest `
            -Uri "$ServerURL/api/v1/hosts/bootstrap/exchange" `
            -Method Post `
            -Body (@{ token = $bootstrapToken } | ConvertTo-Json) `
            -ContentType 'application/json'
        $exData = $exchange.Content | ConvertFrom-Json
        if ($exData.credentials) { $exData = $exData.credentials }

        $dlHeaders = $credHeaders
        if ($exData.api_id -and $exData.api_key) {
            $dlHeaders = @{ 'X-API-ID' = $exData.api_id; 'X-API-KEY' = $exData.api_key }
            Write-Log 'Exchanged the bootstrap token; using it for the download only.'
        }

        Get-AgentBinary -Headers $dlHeaders
        $downloaded = $true
    }
    catch {
        Write-Log "Bootstrap fallback failed too (HTTP $(Get-HttpStatus $_)): $($_.Exception.Message)" 'ERROR'
        exit 1
    }
}

if (-not (Test-Path $tempPath) -or (Get-Item $tempPath).Length -lt 100KB) {
    Write-Log "Downloaded file looks wrong (missing or suspiciously small)." 'ERROR'
    exit 1
}

# -------------------------------------------------------------------- #
#  Step 3 - install binary, config, credentials                        #
# -------------------------------------------------------------------- #
Write-Log "Creating install/config directories..."
New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
New-Item -ItemType Directory -Force -Path $ConfigPath | Out-Null

Write-Log "Installing agent to $targetPath ..."
Copy-Item -Path $tempPath -Destination $targetPath -Force
Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $configFile)) {
    Write-Log "Writing $configFile ..."
    $configContent = @"
patchmon_server: "$ServerURL"
api_version: "v1"
credentials_file: "$ConfigPath\credentials.yml"
log_file: "$ConfigPath\patchmon-agent.log"
log_level: "info"
skip_ssl_verify: $($SkipSslVerify.ToString().ToLower())
"@
    Set-Content -Path $configFile -Value $configContent -Encoding UTF8
}
else {
    Write-Log "Keeping existing $configFile ..."
}

# PATH is a convenience for interactive use; the service does not need it.
$currentPath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
if ($currentPath -notlike "*$InstallPath*") {
    [Environment]::SetEnvironmentVariable('Path', "$currentPath;$InstallPath", [EnvironmentVariableTarget]::Machine)
    $env:Path = "$env:Path;$InstallPath"
}

Write-Log "Configuring API credentials..."
if ($SkipSslVerify) { $env:PATCHMON_SKIP_SSL_VERIFY = 'true' }
& $targetPath --config $configFile config set-api $apiId $apiKey $ServerURL
if ($LASTEXITCODE -ne 0) {
    Write-Log "Failed to configure credentials (exit $LASTEXITCODE). Run manually: patchmon-agent.exe config set-api <API_ID> <API_KEY> $ServerURL" 'ERROR'
    exit 1
}

Write-Log "Testing connectivity (patchmon-agent ping)..."
& $targetPath --config $configFile ping
if ($LASTEXITCODE -ne 0) {
    Write-Log "Installation test failed (exit $LASTEXITCODE). Check $LogFile and $ConfigPath\patchmon-agent.log" 'ERROR'
    exit 1
}
Write-Log "Connectivity test passed."

# -------------------------------------------------------------------- #
#  Step 4 - Windows service                                            #
# -------------------------------------------------------------------- #
Write-Log "Creating Windows service '$serviceName' ..."
try {
    New-Service -Name $serviceName `
        -BinaryPathName "`"$targetPath`" serve" `
        -DisplayName $ServiceDisplayName `
        -StartupType Automatic `
        -ErrorAction Stop | Out-Null

    # -Description is PowerShell 6+ only.
    & sc.exe description $serviceName "$ServiceDescription" | Out-Null
    # Restart the agent if it ever crashes: 3 tries, a minute apart, counter resets daily.
    & sc.exe failure $serviceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null

    Start-Service -Name $serviceName
    Start-Sleep -Seconds 3

    $svc = Get-Service -Name $serviceName
    if ($svc.Status -ne 'Running') {
        Write-Log "Service was created but is not running (status: $($svc.Status)). Start it with: Start-Service -Name $serviceName" 'WARN'
    }
    else {
        Write-Log "Service is running."
    }
}
catch {
    Write-Log "Failed to create/start the service: $($_.Exception.Message)" 'ERROR'
    Write-Log "The agent binary and credentials are installed; to create the service manually as Administrator:
  New-Service -Name $serviceName -BinaryPathName `"`"$targetPath`" serve`" -DisplayName '$ServiceDisplayName' -StartupType Automatic
  Start-Service -Name $serviceName" 'ERROR'
    exit 1
}

# -------------------------------------------------------------------- #
#  Step 5 - optional: leave a daily self-healing task behind           #
# -------------------------------------------------------------------- #
if ($RegisterScheduledTask) {
    if (-not $PSCommandPath) {
        Write-Log "-RegisterScheduledTask needs the script to be run from a file, not piped." 'WARN'
    }
    else {
        Write-Log "Registering daily scheduled task '$TaskName' -> $PSCommandPath ..."
        try {
            if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
            }
            $action = New-ScheduledTaskAction `
                -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$PSCommandPath`""
            $trigger = New-ScheduledTaskTrigger -Daily -At '03:15'
            $trigger.RandomDelay = 'PT2H'
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings `
                -User 'SYSTEM' -RunLevel Highest -Description 'Checks the PatchMon agent is installed and reporting; installs it if missing.' | Out-Null
            Write-Log "Scheduled task registered."
        }
        catch {
            Write-Log "Could not register the scheduled task: $($_.Exception.Message)" 'WARN'
        }
    }
}

# -------------------------------------------------------------------- #
#  Summary                                                             #
# -------------------------------------------------------------------- #
$svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
Write-Host ''
Write-Host 'Installation summary:'
Write-Host "  - Config directory : $ConfigPath"
Write-Host "  - Agent binary     : $targetPath ($arch)"
Write-Host "  - Windows service  : $(if ($svc -and $svc.Status -eq 'Running') { 'running' } elseif ($svc) { $svc.Status } else { 'not configured' })"
Write-Host "  - Host record      : $FriendlyName (api_id=$apiId)"
Write-Host "  - Deploy log       : $LogFile"
Write-Host "  - Agent log        : $ConfigPath\patchmon-agent.log"
Write-Host ''
Write-Host 'Handy commands:'
Write-Host "  patchmon-agent ping                                             # test connection"
Write-Host "  patchmon-agent report                                           # force a report now"
Write-Host "  patchmon-agent diagnostics                                      # troubleshoot"
Write-Host '  Get-Service -Name PatchMonAgent                                 # service status'
Write-Host "  Get-Content `"$ConfigPath\patchmon-agent.log`" -Tail 50 -Wait  # follow agent log"
Write-Host ''
Write-Host "Done. $FriendlyName should show up in PatchMon within a few minutes."
Write-Log "=== Install finished OK ==="
exit 0
