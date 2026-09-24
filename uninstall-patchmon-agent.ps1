#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes the PatchMon agent, its service and its daily scheduled task from a Windows machine.

.DESCRIPTION
    Stops and deletes the PatchMonAgent service and unregisters the daily
    "PatchMon Agent Install" scheduled task so Group Policy does not immediately
    reinstall the agent.

    The host record stays in PatchMon; delete it in the UI if you want it gone.

.PARAMETER RemoveData
    Also delete C:\Program Files\PatchMon and C:\ProgramData\PatchMon.

.PARAMETER DryRun
    Show what would be removed without touching anything.

.EXAMPLE
    .\uninstall-patchmon-agent.ps1 -RemoveData -DryRun
    See what would be removed.

.EXAMPLE
    .\uninstall-patchmon-agent.ps1 -RemoveData
    Actually remove it.
#>
[CmdletBinding()]
param(
    [string]$InstallPath = (Join-Path $env:ProgramFiles 'PatchMon'),
    [string]$ConfigPath = (Join-Path $env:ProgramData 'PatchMon'),
    [string]$ServiceName = 'PatchMonAgent',
    [string]$TaskName = 'PatchMon Agent Install',
    [switch]$RemoveData,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$whatIf = $DryRun.IsPresent

function Step {
    param([scriptblock]$Action, [string]$Description)
    if ($whatIf) {
        Write-Host "[would run] $Description" -ForegroundColor Yellow
        return
    }
    Write-Host "[running]  $Description"
    & $Action
}

# 1. Daily task first, otherwise Group Policy just re-installs on the next run.
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Step { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false } "Unregister scheduled task '$TaskName'"
}
else {
    Write-Host "           no local scheduled task named '$TaskName' (if it comes from Group Policy it will reappear on the next gpupdate - unlink the GPO or use gpresult to confirm)"
}

# 2. Service.
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne 'Stopped') {
        Step { Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue } "Stop service '$ServiceName'"
    }
    Step { & sc.exe delete $ServiceName | Out-Null } "Delete service '$ServiceName'"
    Start-Sleep -Seconds 2
}
else {
    Write-Host "           service '$ServiceName' is not installed"
}

# 3. Files.
if ($RemoveData) {
    foreach ($dir in @($InstallPath, $ConfigPath)) {
        if (Test-Path $dir) {
            Step { Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue } "Remove $dir"
        }
    }
    # PATH entry, if we added one.
    $machinePath = [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine)
    if ($machinePath -like "*$InstallPath*") {
        Step {
            $newPath = ($machinePath -split ';' | Where-Object { $_ -and $_ -ne $InstallPath }) -join ';'
            [Environment]::SetEnvironmentVariable('Path', $newPath, [EnvironmentVariableTarget]::Machine)
        } "Remove $InstallPath from system PATH"
    }
}
else {
    Write-Host "           left $InstallPath and $ConfigPath in place (use -RemoveData to delete them)"
}

# 4. Deploy logs at C:\ProgramData\PatchMon were removed above if -RemoveData was used.
Write-Host ''
if ($whatIf) {
    Write-Host 'Dry run only (-Confirm). Re-run without -Confirm to actually remove things.' -ForegroundColor Yellow
}
else {
    Write-Host 'PatchMon agent removed. Remember to delete the host record in the PatchMon UI if it should not linger.'
}
