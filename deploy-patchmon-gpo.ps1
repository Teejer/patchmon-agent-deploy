#Requires -Version 5.1
<#
.SYNOPSIS
    Stages the PatchMon installer in SYSVOL and creates/links the GPO that deploys it.

.DESCRIPTION
    Run this on a domain controller (or a workstation with the RSAT Group Policy tools).
    It does the parts that script cleanly:
      1. Writes patchmon-agent-install.ps1 (and the uninstaller) into the domain's
         scripts folder. On a DC that means the local SYSVOL content path, e.g.
         C:\Windows\SYSVOL\sysvol\example.com\scripts\patchmon , so no SMB write to the
         SYSVOL share is required and its share permissions stay untouched. DFSR
         replicates the folder regardless of what wrote to it.
      2. Regenerates the Task Scheduler XML with the UNC path clients will use.
      3. Creates the "PatchMon Agent Deployment" GPO and links it to an OU.

    The last step - attaching the scheduled task to the GPO - is a GUI paste job, because
    Scheduled Task preferences have no PowerShell cmdlets. The script prints the exact
    clicks at the end.

    Signing: this script copies the installer into SYSVOL with -Force. If you sign the
    installer yourself, sign the staged copy AFTER this script has run, otherwise your
    signature is silently replaced by the unsigned copy. Using -SignedCertThumbprint is
    safe because signing happens before the copy.

.PARAMETER OU
    Distinguished name or name of the OU to link the GPO to. Default: the Computers
    container of the current domain.

.EXAMPLE
    .\deploy-patchmon-gpo.ps1 -OU 'OU=Laptops,DC=example,DC=com' -WhatIf
    See what would happen.

.EXAMPLE
    .\deploy-patchmon-gpo.ps1 -SignedCertThumbprint 'A1B2...'
    Sign the installer with your code-signing cert, then stage and create the GPO.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    # DNS domain. Empty means "ask Active Directory" - resolved after the RSAT module
    # check so a machine without RSAT gets a readable message, not a red exception.
    [string]$Domain = '',
    # Distinguished name of the OU to link the GPO to. Empty means the built-in
    # Computers container; link to your real workstation OUs instead if that is how
    # the estate is organised.
    [string]$OU = '',
    [string]$GpoName = 'PatchMon Agent Deployment',
    # Folder that holds patchmon-agent-install.ps1 / uninstall / the task XML template.
    # Defaults to the folder this script lives in; empty means "work it out" (see below).
    [string]$SourceDir = '',
    # Subfolder under SYSVOL\<domain>\scripts that the installer is copied into.
    [string]$SysVolSubFolder = 'patchmon',
    # Where the installer files are written. Defaults to this DC's own SYSVOL content
    # folder (C:\Windows\SYSVOL\sysvol\<domain>\scripts) so the script needs no SMB
    # access to the SYSVOL share and never tempts anyone into loosening its share
    # permissions. DFSR replicates that folder whatever writes it. Pass a UNC to stage
    # somewhere else, e.g. a share ACL'd to Domain Computers only.
    [string]$StagePath,
    [string]$TaskXmlTemplate = 'PatchMon-Agent-Install.xml',
    # Where the path-corrected task XML is written for you to paste into GPMC.
    # Empty means the Desktop, worked out after startup (see below).
    [string]$TaskXmlOut = '',
    # Thumbprint of a code-signing cert with a private key in LocalMachine\My or
    # CurrentUser\My. Omit it to sign the staged copy yourself - see .DESCRIPTION, the
    # order matters.
    [string]$SignedCertThumbprint,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty when the script is pasted into a console, run through
# Invoke-Expression, or delivered with Invoke-Command -FilePath. Fall back to the
# current directory and say so, rather than letting Join-Path fail on an empty path.
if (-not $SourceDir) {
    if ($PSScriptRoot) {
        $SourceDir = $PSScriptRoot
    }
    else {
        $SourceDir = (Get-Location).ProviderPath
        Write-Warning "`$PSScriptRoot is empty (this script was not started from a file path), so it is using the current directory: $SourceDir"
    }
}
$resolvedSource = (Resolve-Path -LiteralPath $SourceDir -ErrorAction SilentlyContinue).Path
if (-not $resolvedSource) {
    Write-Error "-SourceDir '$SourceDir' does not exist. Run this from the folder that holds patchmon-agent-install.ps1, or pass -SourceDir."
    exit 1
}
$SourceDir = $resolvedSource

# Tools first: AD is only queried after the module is known to exist.
foreach ($mod in @('GroupPolicy', 'ActiveDirectory')) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Error "The $mod PowerShell module is required. Install RSAT: Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0"
        exit 1
    }
}
Import-Module GroupPolicy, ActiveDirectory

# Now it is safe to ask AD for the defaults.
if (-not $Domain -or -not $OU) {
    try {
        $ad = Get-ADDomain -ErrorAction Stop
    }
    catch {
        Write-Error "Could not determine the domain automatically ($_). Pass both explicitly, e.g. -Domain example.com -OU 'OU=Workstations,DC=example,DC=com'"
        exit 1
    }
    if (-not $Domain) { $Domain = $ad.DNSRoot }
    if (-not $OU) { $OU = $ad.ComputersContainerDN }
}

# Resolving paths here rather than in the param defaults: a param default that calls
# Join-Path on a missing environment variable fails before any of our own error
# handling runs. $env:USERPROFILE is empty for some service contexts, so fall back to
# the shell folder and then to the source folder.
if (-not $TaskXmlOut) {
    $desktop = $null
    try { $desktop = [Environment]::GetFolderPath('Desktop') } catch { }
    if (-not $desktop -and $env:USERPROFILE) { $desktop = Join-Path $env:USERPROFILE 'Desktop' }
    if (-not $desktop) { $desktop = $SourceDir }
    $TaskXmlOut = Join-Path $desktop 'PatchMon-Agent-Install.xml'
}

$installScript = Join-Path $SourceDir 'patchmon-agent-install.ps1'
$uninstallScript = Join-Path $SourceDir 'uninstall-patchmon-agent.ps1'
$templatePath = Join-Path $SourceDir $TaskXmlTemplate

foreach ($f in @($installScript, $templatePath)) {
    if (-not (Test-Path $f)) {
        Write-Error "Missing required file: $f`n  Expected the deployment files in '$SourceDir'. Pass -SourceDir if they live elsewhere."
        exit 1
    }
}

# -------------------------------------------------------------------- #
#  2. Stage the files                                                  #
# -------------------------------------------------------------------- #
# The UNC is what CLIENTS read from, so it is what goes in the task XML. It is not
# where we write. Netlogon\Parameters\SysVol is this DC's own SYSVOL content folder,
# which avoids guessing between the DFSR path and the old FRS junction.
$uncScripts = "\\$Domain\SYSVOL\$Domain\scripts"

function Get-LocalSysVolScripts {
    try {
        $sysVol = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' `
                    -Name SysVol -ErrorAction Stop).SysVol
        # The registry value is sometimes the domain-less sysvol root, so append the
        # DNS domain name when needed.
        $leaf = (Get-ADDomain -ErrorAction Stop).DNSRoot
    }
    catch { return $null }
    if (-not $sysVol) { return $null }
    $base = $sysVol.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $base)) { return $null }
    if ($leaf -and -not ($base -like "*\$leaf")) { $base = Join-Path $base $leaf }
    return (Join-Path $base 'scripts')
}

$localScripts = Get-LocalSysVolScripts
if (-not $StagePath) {
    if ($localScripts) {
        $StagePath = $localScripts
    }
    else {
        $StagePath = $uncScripts
        Write-Warning "Could not find a local SYSVOL folder (HKLM\...\Netlogon\Parameters\SysVol), so this run writes over SMB to $uncScripts ."
        Write-Warning "If that write is denied: do NOT grant Authenticated Users change access to the SYSVOL share to make the error go away. Run this on a domain controller so it uses its own local path, or pass -StagePath for a share you own."
    }
}

$targetDir = Join-Path $StagePath $SysVolSubFolder

# What the scheduled task will actually run. Staging to a local SYSVOL path means
# clients reach it through the SYSVOL share; staging to your own share means they
# reach it through that share, and the task path must match.
if ($StagePath.StartsWith('\\')) {
    $uncScript = Join-Path $StagePath (Join-Path $SysVolSubFolder 'patchmon-agent-install.ps1')
}
else {
    $uncScript = Join-Path $uncScripts (Join-Path $SysVolSubFolder 'patchmon-agent-install.ps1')
}

Write-Host "Domain      : $Domain"
if ($StagePath.StartsWith('\\')) {
    Write-Host "Stage to    : $targetDir  (over SMB)"
    Write-Host "                A denial here is SYSVOL share permissions doing their job."
    Write-Host "                Run on a DC, or pass -StagePath; do not open the SYSVOL share up."
}
else {
    Write-Host "Stage to    : $targetDir  (local SYSVOL content, replicated by DFSR)"
}
Write-Host "Clients read: $uncScript"
Write-Host "GPO         : $GpoName"
Write-Host "Linked to   : $OU"
Write-Host ''

# -------------------------------------------------------------------- #
#  1. Sign the installer (optional, but keeps AppLocker/WDAC happy)     #
# -------------------------------------------------------------------- #
if ($SignedCertThumbprint) {
    $cert = Get-Item "Cert:\LocalMachine\My\$SignedCertThumbprint" -ErrorAction SilentlyContinue
    if (-not $cert) { $cert = Get-Item "Cert:\CurrentUser\My\$SignedCertThumbprint" -ErrorAction SilentlyContinue }
    if (-not $cert) {
        Write-Error "Certificate $SignedCertThumbprint not found in LocalMachine\My or CurrentUser\My."
        exit 1
    }
    if ($PSCmdlet.ShouldProcess($installScript, 'Authenticode sign')) {
        Set-AuthenticodeSignature -FilePath $installScript -Certificate $cert -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com' |
            Format-List Path, Status | Out-Null
        Write-Host "Signed $installScript : $((Get-AuthenticodeSignature $installScript).Status)"
    }
}

# -------------------------------------------------------------------- #
#  2. Stage the installer files                                        #
# -------------------------------------------------------------------- #
if ($PSCmdlet.ShouldProcess($targetDir, 'Stage installer files')) {
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    Copy-Item $installScript -Destination $targetDir -Force
    Write-Host "Staged patchmon-agent-install.ps1"
    if (Test-Path $uninstallScript) {
        Copy-Item $uninstallScript -Destination $targetDir -Force
        Write-Host "Staged uninstall-patchmon-agent.ps1"
    }
    if (-not $StagePath.StartsWith('\\')) {
        Write-Host "Written to this DC's own SYSVOL folder - no SMB write to the SYSVOL share was needed."
    }
}

# -------------------------------------------------------------------- #
#  3. Task XML with the real UNC path                                  #
# -------------------------------------------------------------------- #
$xml = Get-Content $templatePath -Raw
# Replace any \\...\...install.ps1 with the path we actually staged to.
$xml = $xml -replace '\\\\[^"<>\s]*?patchmon-agent-install\.ps1', $uncScript
if ($PSCmdlet.ShouldProcess($TaskXmlOut, 'Write task XML')) {
    Set-Content -Path $TaskXmlOut -Value $xml -Encoding UTF8
    Write-Host "Task XML (path-corrected): $TaskXmlOut"
}

# -------------------------------------------------------------------- #
#  4. GPO                                                              #
# -------------------------------------------------------------------- #
$gpo = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue
if ($gpo) {
    Write-Host "GPO '$GpoName' already exists, reusing it."
}
elseif ($PSCmdlet.ShouldProcess($GpoName, 'Create GPO')) {
    $gpo = New-GPO -Name $GpoName -Comment 'Installs and self-heals the PatchMon agent on domain members.'
    Write-Host "Created GPO '$GpoName'."
}

if ($gpo -and $PSCmdlet.ShouldProcess("$GpoName -> $OU", 'Link GPO')) {
    $existing = Get-GPInheritance -Target $OU -ErrorAction SilentlyContinue
    if ($existing.GpoLinks | Where-Object { $_.DisplayName -eq $GpoName }) {
        Write-Host "GPO is already linked to $OU"
    }
    else {
        New-GPLink -Name $GpoName -Target $OU -LinkEnabled Yes | Out-Null
        Write-Host "Linked GPO to $OU"
    }
}

# -------------------------------------------------------------------- #
#  5. The one manual step                                              #
# -------------------------------------------------------------------- #
Write-Host ''
Write-Host '---------------------------------------------------------------' -ForegroundColor Cyan
Write-Host ' Last step: attach the scheduled task to the GPO (GUI only).' -ForegroundColor Cyan
Write-Host '---------------------------------------------------------------' -ForegroundColor Cyan
Write-Host " 1. gpmc.msc -> Forest: $Domain -> Domains -> $Domain -> Group Policy Objects"
Write-Host " 2. Right-click '$GpoName' -> Edit"
Write-Host ' 3. Computer Configuration > Preferences > Control Panel Settings > Scheduled Tasks'
Write-Host '    (if the Scheduled Tasks node is missing: right-click Control Panel Settings > New > Scheduled Task)'
Write-Host ' 4. New > Scheduled Task (At least Windows 7), open the XML tab, paste'
Write-Host "    the contents of: $TaskXmlOut"
Write-Host '    Confirm the Security tab of the task shows SYSTEM (LocalSystem), then OK.'
Write-Host ' 5. On a test client:  gpupdate /force  then  schtasks /query /tn "PatchMon Agent Install" /v /fo LIST'
Write-Host '    Run it on demand to test:  schtasks /run /tn "PatchMon Agent Install"'
if ($SignedCertThumbprint) {
    Write-Host " 6. Installer was signed before staging (thumbprint $($cert.Thumbprint)) - nothing else to do."
}
else {
    Write-Host ' 6. If you sign the installer yourself, sign the STAGED copy now. This script copied'
    Write-Host '    the files with -Force, which overwrites any signature applied beforehand:'
    Write-Host "      Set-AuthenticodeSignature -FilePath '$uncScript' -Certificate `$cert ``"
    Write-Host "          -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com'"
    Write-Host "      Get-AuthenticodeSignature '$uncScript' | Select-Object Status, StatusMessage"
    Write-Host '    Expect Status: Valid from a client, not just from this machine.'
}
if (-not $StagePath.StartsWith('\\')) {
    Write-Host ''
    Write-Host ' SYSVOL replication: the files were written to this DC''s own SYSVOL folder. Clients'
    Write-Host ' read the DC they authenticate to, so let DFSR catch up before testing (or force it:'
    Write-Host " repadmin /syncall /AdeP ). Confirm on the other DCs that"
    Write-Host " C:\Windows\SYSVOL\sysvol\$Domain\scripts\$SysVolSubFolder\patchmon-agent-install.ps1"
    Write-Host ' exists; a client whose DC has not replicated yet fails the task with path not found.'
}
Write-Host ''
Write-Host " Reminder: fill in `$AutoEnrollmentKey / `$AutoEnrollmentSecret in"
Write-Host " $installScript (and sign it) before the first client run,"
Write-Host ' otherwise every client logs an enrollment failure.'
