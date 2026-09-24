#Requires -Version 5.1
<#
.SYNOPSIS
    Stages the PatchMon installer in SYSVOL and creates/links the GPO that deploys it.

.DESCRIPTION
    Run this on a domain controller (or a workstation with the RSAT Group Policy tools).
    It does the parts that script cleanly:
      1. Copies patchmon-agent-install.ps1 (and the uninstaller) into
         \\<domain>\SYSVOL\<domain>\scripts\patchmon\ so every domain member can read it.
      2. Regenerates the Task Scheduler XML with your real SYSVOL path baked in.
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
    [string]$Domain = (Get-ADDomain -ErrorAction SilentlyContinue).DNSRoot,
    # Defaults to the built-in Computers container. Link to your real workstation
    # OUs instead if that is how the estate is organised.
    [string]$OU = (Get-ADDomain -ErrorAction SilentlyContinue).ComputersContainerDN,
    [string]$GpoName = 'PatchMon Agent Deployment',
    # Folder that holds patchmon-agent-install.ps1 / uninstall / the task XML template.
    [string]$SourceDir = $PSScriptRoot,
    # Subfolder under SYSVOL\<domain>\scripts that the installer is copied into.
    [string]$SysVolSubFolder = 'patchmon',
    [string]$TaskXmlTemplate = 'PatchMon-Agent-Install.xml',
    # Where the path-corrected task XML is written for you to paste into GPMC.
    [string]$TaskXmlOut = (Join-Path $env:USERPROFILE 'Desktop\PatchMon-Agent-Install.xml'),
    # Thumbprint of a code-signing cert with a private key in LocalMachine\My or
    # CurrentUser\My. Omit it to sign the staged copy yourself - see .DESCRIPTION, the
    # order matters.
    [string]$SignedCertThumbprint,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

if (-not $Domain) {
    Write-Error "Could not determine the domain. Pass -Domain explicitly, e.g. -Domain example.com"
    exit 1
}

foreach ($mod in @('GroupPolicy', 'ActiveDirectory')) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        Write-Error "The $mod PowerShell module is required. Install RSAT: Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0"
        exit 1
    }
}
Import-Module GroupPolicy, ActiveDirectory

$installScript = Join-Path $SourceDir 'patchmon-agent-install.ps1'
$uninstallScript = Join-Path $SourceDir 'uninstall-patchmon-agent.ps1'
$templatePath = Join-Path $SourceDir $TaskXmlTemplate

foreach ($f in @($installScript, $templatePath)) {
    if (-not (Test-Path $f)) {
        Write-Error "Missing required file: $f"
        exit 1
    }
}

$sysVolShare = "\\$Domain\SYSVOL\$Domain\scripts"
$targetDir = Join-Path $sysVolShare $SysVolSubFolder
$uncScript = "\\$Domain\SYSVOL\$Domain\scripts\$SysVolSubFolder\patchmon-agent-install.ps1"

Write-Host "Domain      : $Domain"
Write-Host "Stage to    : $targetDir"
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
#  2. Stage files in SYSVOL                                            #
# -------------------------------------------------------------------- #
if ($PSCmdlet.ShouldProcess($targetDir, 'Create SYSVOL folder')) {
    if (-not (Test-Path $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    Copy-Item $installScript -Destination $targetDir -Force
    Write-Host "Staged patchmon-agent-install.ps1"
    if (Test-Path $uninstallScript) {
        Copy-Item $uninstallScript -Destination $targetDir -Force
        Write-Host "Staged uninstall-patchmon-agent.ps1"
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
Write-Host ''
Write-Host " Reminder: fill in `$AutoEnrollmentKey / `$AutoEnrollmentSecret in"
Write-Host " $installScript (and sign it) before the first client run,"
Write-Host ' otherwise every client logs an enrollment failure.'
