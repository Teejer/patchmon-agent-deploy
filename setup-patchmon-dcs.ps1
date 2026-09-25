#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys the agent-less PatchMon reporter to every domain controller.

.DESCRIPTION
    For DCs where installing the PatchMon agent binary is not permitted. Run
    this from an admin workstation or member server (never a DC); it touches
    the DCs only over WinRM - no SMB/C$ admin share required, because many DCs
    are hardened with those disabled.

    For each domain controller it will:
      1. Enroll the DC with PatchMon auto-enrollment FROM THIS HOST, so the
         shared enrollment secret is never written to a DC (per-DC api_id/api_key
         are cached in .\dc-credentials\ - keep that folder out of git and ACL
         it to yourself).
      2. Stage patchmon-dc-reporter.ps1 into C:\Program Files\PatchMon-Reporter
         and that DC's own config.json + credentials.json into
         C:\ProgramData\PatchMon-Reporter over the WinRM session, then strip
         inherited NTFS ACLs so only SYSTEM and Administrators can read them
         (this is why we do not stage anything through SYSVOL).
      3. Register a scheduled task (boot +5 min, daily 03:25, and every 30
         min) running as SYSTEM; the reporter self-decides full report vs
         heartbeat on each run.
      4. Run it once and report the exit result.

    -Status re-checks task results and the reporter log tail on every DC.
    -Uninstall removes the task and both folders (delete the host records in
    the PatchMon UI yourself; this script holds no admin API credentials).

    If your DCs enforce AllSigned execution policy the reporter file must be
    code-signed before you run this; the task's -ExecutionPolicy Bypass is
    ignored under an enforced AllSigned policy. The script detects this per DC
    and says so instead of installing something that cannot run.

.LICENSE
    Deploys patchmon-dc-reporter.ps1, which contains logic derived from the
    PatchMon agent, Copyright (c) PatchMon contributors, AGPL-3.0-only.
    Upstream source: https://github.com/PatchMon/PatchMon

.PARAMETER Dcs
    Limit to these DCs (hostnames or FQDNs). Default: every DC in the domain.

.EXAMPLE
    .\setup-patchmon-dcs.ps1 -WhatIf

.EXAMPLE
    .\setup-patchmon-dcs.ps1 -Dcs DC01,DC02

.EXAMPLE
    .\setup-patchmon-dcs.ps1 -Status

.NOTES
    Exit codes: 0 = every DC succeeded, 1 = at least one DC failed (see table),
    2 = placeholders still filled in / reporter file missing.
#>
[CmdletBinding()]
param(
    [string]$ServerURL = 'https://REPLACE_WITH_PATCHMON_SERVER',
    [string]$AutoEnrollmentKey = 'REPLACE_WITH_AUTO_ENROLLMENT_KEY',
    [string]$AutoEnrollmentSecret = 'REPLACE_WITH_AUTO_ENROLLMENT_SECRET',
    [string[]]$Dcs,
    [string]$SourceDir,
    [string]$TaskName = 'PatchMon DC Reporter',
    [string]$DailyTime = '03:25',
    [string]$TaskUser,
    [switch]$WhatIf,
    [switch]$Status,
    [switch]$Uninstall,
    [switch]$RefreshCredentials,
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = 'Stop'

if (-not $SourceDir) { $SourceDir = $PSScriptRoot }
$ReporterSource = Join-Path $SourceDir 'patchmon-dc-reporter.ps1'
$CredCacheDir = Join-Path $PSScriptRoot 'dc-credentials'

# Remote layout on each DC. Program Files holds code+credentials with ACLs
# stripped; ProgramData holds the log.
$RemoteDir = 'C:\Program Files\PatchMon-Reporter'
$RemoteDataDir = 'C:\ProgramData\PatchMon-Reporter'

function Write-Step {
    param([string]$DC, [string]$Message, [string]$Level = 'INFO')
    # The tag is computed first: an inline if-statement is not valid inside a
    # -f argument list in Windows PowerShell 5.1.
    $tag = '     '
    if ($Level -ne 'INFO') { $tag = $Level.PadRight(5) + ' ' }
    Write-Host ('[{0}] {1} {2}' -f $DC.PadRight(14), $tag, $Message)
}

function Get-HttpStatus {
    param($ErrorRecord)
    try {
        if ($ErrorRecord.Exception.Response) { return [string][int]$ErrorRecord.Exception.Response.StatusCode }
    } catch { }
    return '0'
}

function Invoke-AutoEnrollment {
    # Same call the agent installer makes, run from here so the enrollment
    # secret stays on this host. Returns @{ apiId; apiKey }.
    param([string]$HostName)

    $body = @{ friendly_name = $HostName } | ConvertTo-Json
    $resp = Invoke-RestMethod `
        -Uri "$ServerURL/api/v1/auto-enrollment/enroll" `
        -Method Post `
        -Headers @{
            'X-Auto-Enrollment-Key'    = $AutoEnrollmentKey
            'X-Auto-Enrollment-Secret' = $AutoEnrollmentSecret
        } `
        -Body $body `
        -ContentType 'application/json' `
        -TimeoutSec 60
    if ($resp.host) {
        return @{ apiId = [string]$resp.host.api_id; apiKey = [string]$resp.host.api_key }
    }
    elseif ($resp.api_id) {
        return @{ apiId = [string]$resp.api_id; apiKey = [string]$resp.api_key }
    }
    throw 'enrollment response did not contain api_id/api_key'
}

function Get-DomainControllerList {
    # ADSI, not the AD module: this must run on a plain admin workstation with
    # no RSAT installed. The 8192 bit is the domain-controller flag.
    $root = [adsi]'LDAP://RootDSE'
    $namingContext = [string]$root.Get('defaultNamingContext')
    $searcher = New-Object System.DirectoryServices.DirectorySearcher([adsi]"LDAP://$namingContext")
    $searcher.Filter = '(&(objectCategory=computer)(userAccountControl:1.2.840.113556.1.4.803:=8192))'
    $searcher.PropertiesToLoad.Add('dNSHostName') | Out-Null
    $found = @()
    foreach ($r in $searcher.FindAll()) {
        $name = $r.Properties['dNSHostName']
        if ($name) { $found += [string]$name[0] }
    }
    $searcher.Dispose()
    return ($found | Sort-Object -Unique)
}

# ------------------------------------------------------------------------ #
#  Preflight                                                                #
# ------------------------------------------------------------------------ #
if ($ServerURL -like '*REPLACE_WITH_*' -or $AutoEnrollmentKey -like 'REPLACE_WITH_*' -or
    $AutoEnrollmentSecret -like 'REPLACE_WITH_*') {
    Write-Host 'Fill in $ServerURL, $AutoEnrollmentKey and $AutoEnrollmentSecret first (same placeholders as the agent installer).' -ForegroundColor Red
    Write-Host 'After editing, remember: git update-index --skip-worktree setup-patchmon-dcs.ps1'
    exit 2
}
if (-not (Test-Path -LiteralPath $ReporterSource)) {
    Write-Host "Cannot find $ReporterSource next to this script." -ForegroundColor Red
    exit 2
}

if ($SkipCertificateCheck) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

$reporterSignature = Get-AuthenticodeSignature -FilePath $ReporterSource
$reporterSigned = ($reporterSignature.Status -eq 'Valid')
if (-not $reporterSigned) {
    Write-Host "NOTE: $ReporterSource is not signed ($($reporterSignature.Status)). Fine unless a DC enforces AllSigned; that DC will be flagged during deployment." -ForegroundColor Yellow
}

$targets = @()
if ($Dcs) {
    # Short names get the domain suffix from RootDSE: "DC=corp,DC=example,DC=com" -> corp.example.com.
    $namingContext = [string]([adsi]'LDAP://RootDSE').Get('defaultNamingContext')
    $dnsDomain = ((($namingContext -split ',') | ForEach-Object { ($_ -split '=', 2)[1] }) -join '.')
    $targets = @($Dcs | ForEach-Object { if ($_ -match '\.') { $_ } else { "$_.$dnsDomain" } })
}
else {
    Write-Host 'Enumerating domain controllers...'
    $targets = @(Get-DomainControllerList)
}
if ($targets.Count -eq 0) {
    Write-Host 'No domain controllers found.' -ForegroundColor Red
    exit 1
}
Write-Host ("Target DCs ({0}): {1}" -f $targets.Count, ($targets -join ', '))

# ------------------------------------------------------------------------ #
#  -Status: just report what each DC is doing                               #
# ------------------------------------------------------------------------ #
if ($Status) {
    $bad = 0
    foreach ($dc in $targets) {
        try {
            $info = Invoke-Command -ComputerName $dc -ScriptBlock {
                param($Name)
                $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
                if (-not $task) { return @{ installed = $false } }
                $tinfo = $task | Get-ScheduledTaskInfo
                $log = ''
                $logFile = 'C:\ProgramData\PatchMon-Reporter\report.log'
                if (Test-Path -LiteralPath $logFile) {
                    $log = (Get-Content -LiteralPath $logFile -Tail 3) -join ' | '
                }
                return @{
                    installed  = $true
                    state      = [string]$task.State
                    lastRun    = "$($tinfo.LastRunTime)"
                    lastResult = ('0x{0:X}' -f $tinfo.LastTaskResult)
                    logTail    = $log
                }
            } -ArgumentList $TaskName
            if (-not $info.installed) {
                Write-Step $dc 'task not installed' 'WARN'
                $bad++
            }
            else {
                Write-Step $dc ("state={0} last={1} result={2}" -f $info.state, $info.lastRun, $info.lastResult)
                if ($info.logTail) { Write-Step $dc ("log: " + $info.logTail) }
                if ($info.lastResult -ne '0x0') { $bad++ }
            }
        }
        catch {
            Write-Step $dc "unreachable: $($_.Exception.Message)" 'ERROR'
            $bad++
        }
    }
    exit ([int]($bad -gt 0))
}

# ------------------------------------------------------------------------ #
#  -Uninstall                                                               #
# ------------------------------------------------------------------------ #
if ($Uninstall) {
    foreach ($dc in $targets) {
        try {
            Invoke-Command -ComputerName $dc -ScriptBlock {
                param($Name, $Dir, $DataDir)
                Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $DataDir -Recurse -Force -ErrorAction SilentlyContinue
            } -ArgumentList $TaskName, $RemoteDir, $RemoteDataDir
            Write-Step $dc 'task and folders removed (delete the host record in the PatchMon UI yourself)'
        }
        catch {
            Write-Step $dc "cleanup failed: $($_.Exception.Message)" 'ERROR'
        }
    }
    exit 0
}

# ------------------------------------------------------------------------ #
#  Deploy                                                                   #
# ------------------------------------------------------------------------ #
if ($WhatIf) {
    Write-Host "`nWHAT-IF only; nothing will change. Plan per DC:" -ForegroundColor Cyan
    foreach ($dc in $targets) {
        $cached = Join-Path $CredCacheDir (($dc -split '\.')[0] + '.json')
        $plan = @()
        if ((Test-Path -LiteralPath $cached) -and -not $RefreshCredentials) { $plan += 'reuse cached credentials' }
        else { $plan += 'auto-enroll (from this host)' }
        $plan += 'stage reporter to $RemoteDir, credentials to $RemoteDataDir (over WinRM)'
        $plan += 'strip NTFS inheritance (SYSTEM+Administrators only)'
        $plan += "register task '$TaskName' (boot +5 min, daily $DailyTime, +30min heartbeat, SYSTEM)"
        $plan += 'run once'
        Write-Step $dc ($plan -join ' -> ')
    }
    exit 0
}

if (-not (Test-Path -LiteralPath $CredCacheDir)) {
    New-Item -ItemType Directory -Path $CredCacheDir -Force | Out-Null
}

$failures = 0
$results = @()
foreach ($dc in $targets) {
    $short = ($dc -split '\.')[0]
    $cached = Join-Path $CredCacheDir ($short + '.json')
    $apiId = $null; $apiKey = $null
    $failed = $false

    try {
        # 1. Credentials: cache first. A second enroll for an existing host
        # name gets a 409, so the cached pair is the only sane source on rerun.
        if ((Test-Path -LiteralPath $cached) -and -not $RefreshCredentials) {
            $c = Get-Content -LiteralPath $cached -Raw | ConvertFrom-Json
            $apiId = [string]$c.apiId; $apiKey = [string]$c.apiKey
            Write-Step $dc 'using cached API credentials'
        }
        else {
            Write-Step $dc 'auto-enrolling...'
            $enroll = Invoke-AutoEnrollment -HostName $short
            $apiId = $enroll.apiId; $apiKey = $enroll.apiKey
            $enroll | ConvertTo-Json | Set-Content -LiteralPath $cached -Encoding UTF8
            Write-Step $dc "enrolled (api_id=$apiId)"
        }

        # 2. Stage code + this DC's own credentials THROUGH THE WINRM SESSION
        # itself. The first version copied over \\dc\C$, which fails with "The
        # network name cannot be found" on any DC hardened to disable admin
        # shares (AutoShareServer=0) - and Task Scheduler already needs WinRM,
        # so SMB was a dependency bought for nothing.
        $reporterText = Get-Content -LiteralPath $ReporterSource -Raw
        # UTF-8 without BOM; PS 5.1's Set-Content -Encoding UTF8 writes a BOM.
        $cfgJson = @{ serverUrl = $ServerURL; skipTlsVerify = [bool]$SkipCertificateCheck } | ConvertTo-Json
        $credJson = @{ apiId = $apiId; apiKey = $apiKey } | ConvertTo-Json
        Invoke-Command -ComputerName $dc -ScriptBlock {
            param($Dir, $DataDir, $Code, $Cfg, $Cred)
            New-Item -ItemType Directory -Path $Dir, $DataDir -Force | Out-Null
            $enc = New-Object System.Text.UTF8Encoding($false)
            # Code goes in Program Files; credentials and log go in ProgramData -
            # the same split the real agent uses, and where the reporter looks for
            # them. Writing all three to Program Files left the reporter reporting
            # "not configured" (exit 0x2 from the task) against correctly staged
            # files it would never read.
            [System.IO.File]::WriteAllText((Join-Path $Dir 'patchmon-dc-reporter.ps1'), $Code, $enc)
            [System.IO.File]::WriteAllText((Join-Path $DataDir 'config.json'), $Cfg, $enc)
            [System.IO.File]::WriteAllText((Join-Path $DataDir 'credentials.json'), $Cred, $enc)
            # NTFS: the default ACLs let every domain user read these. Strip
            # inheritance; keep only SYSTEM and Administrators.
            foreach ($d in @($Dir, $DataDir)) {
                & icacls $d /inheritance:r /grant '*S-1-5-18:(OI)(CI)F' /grant '*S-1-5-32-544:(OI)(CI)F' | Out-Null
            }
        } -ArgumentList $RemoteDir, $RemoteDataDir, $reporterText, $cfgJson, $credJson
        Write-Step $dc 'staged reporter + credentials over WinRM (ACLs locked to SYSTEM/Admins)'

        # 4. AllSigned check: -ExecutionPolicy Bypass is ignored under an
        # enforced policy, so an unsigned file simply will not run.
        $enforced = Invoke-Command -ComputerName $dc -ScriptBlock {
            $p = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell' -ErrorAction SilentlyContinue
            if ($p -and $p.ExecutionPolicy) { return [string]$p.ExecutionPolicy }
            return ''
        }
        if ($enforced -match 'AllSigned' -and -not $reporterSigned) {
            Write-Step $dc "domain policy enforces AllSigned and the reporter is NOT signed; the task would fail. Sign patchmon-dc-reporter.ps1 and re-run." 'ERROR'
            throw 'unsigned reporter under AllSigned'
        }

        # 5. Scheduled task: boot +5 min and daily. Created on the DC through
        # the native ScheduledTasks module (unlike GPO task preferences, this
        # is fully scriptable).
        $taskPassword = $null
        if ($TaskUser) {
            $secure = Read-Host "Password for service account $TaskUser" -AsSecureString
            $taskPassword = [System.Net.NetworkCredential]::new('', $secure).Password
        }
        Invoke-Command -ComputerName $dc -ScriptBlock {
            param($Name, $RemoteDir, $DailyTime, $TaskUser, $TaskPassword)
            Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue

            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
                '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}\patchmon-dc-reporter.ps1"' -f $RemoteDir)
            $triggerBoot = New-ScheduledTaskTrigger -AtStartup
            $triggerBoot.Delay = 'PT5M'
            $triggerDaily = New-ScheduledTaskTrigger -Daily -At $DailyTime
            # Every 30 min: the reporter itself decides full report vs heartbeat.
            # The heartbeat partial keeps PatchMon's last_update inside the 3x
            # update-interval window the UI uses for Up/stale/down; a full WUA
            # collection only runs every 12h. (The "WS Offline" badge is NOT
            # this - that one needs a live agent WebSocket and stays Offline by
            # design for reporter hosts.)
            $triggerRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date)
            $triggerRepeat.Repetition.Interval = 'PT30M'
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
                -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)
            if ($TaskUser) {
                $principal = New-ScheduledTaskPrincipal -UserId $TaskUser -LogonType Password -RunLevel Highest
                Register-ScheduledTask -TaskName $Name -Action $action -Trigger @($triggerBoot, $triggerDaily, $triggerRepeat) `
                    -Settings $settings -Principal $principal -Password $TaskPassword -Force | Out-Null
            }
            else {
                $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
                Register-ScheduledTask -TaskName $Name -Action $action -Trigger @($triggerBoot, $triggerDaily, $triggerRepeat) `
                    -Settings $settings -Principal $principal -Force | Out-Null
            }
        } -ArgumentList $TaskName, $RemoteDir, $DailyTime, $TaskUser, $taskPassword
        Write-Step $dc "task '$TaskName' registered"

        # 6. First run, then read its result so problems surface now, not at 03:25.
        Invoke-Command -ComputerName $dc -ScriptBlock {
            param($Name)
            Start-ScheduledTask -TaskName $Name
        } -ArgumentList $TaskName | Out-Null
        $lastResult = 'unknown'
        for ($i = 0; $i -lt 12; $i++) {
            Start-Sleep -Seconds 5
            $lastResult = Invoke-Command -ComputerName $dc -ScriptBlock {
                param($Name)
                $t = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
                if (-not $t) { return 'missing' }
                $tinfo = $t | Get-ScheduledTaskInfo
                if ($tinfo.LastTaskResult -ne 267009 -and $tinfo.LastTaskResult -ne 267011) {
                    return ('0x{0:X}' -f $tinfo.LastTaskResult)
                }
                return 'running'
            } -ArgumentList $TaskName
            if ($lastResult -ne 'running') { break }
        }
        if ($lastResult -eq '0x0') {
            Write-Step $dc "first run OK (0x0)"
        }
        else {
            $tail = Invoke-Command -ComputerName $dc -ScriptBlock {
                $logFile = 'C:\ProgramData\PatchMon-Reporter\report.log'
                if (Test-Path -LiteralPath $logFile) { return (Get-Content -LiteralPath $logFile -Tail 3) -join ' | ' }
                return 'no report.log'
            }
            Write-Step $dc "first run result $lastResult ; log: $tail" 'WARN'
            $failed = $true
        }
    }
    catch {
        Write-Step $dc "FAILED: $($_.Exception.Message)" 'ERROR'
        $failed = $true
    }

    $results += [pscustomobject]@{ DC = $dc; Failed = $failed }
    if ($failed) { $failures++ }
}

Write-Host ''
Write-Host 'Summary:' -ForegroundColor Cyan
$results | Format-Table -AutoSize
if ($failures -gt 0) {
    Write-Host "$failures DC(s) failed; fix and re-run - cached credentials make reruns cheap." -ForegroundColor Red
    exit 1
}
Write-Host 'All DCs staged and reporting. Check the PatchMon UI in a few minutes; the host appears with osType Windows and packageManager windows. Next nightly task: boot+5min / daily.'
exit 0
