#Requires -Version 5.1
<#
.SYNOPSIS
    Blocks commits that would leak secrets or site-internal identifiers into this public repo.

.DESCRIPTION
    Scans the staged changes (or every tracked file, with -All) and fails on anything that
    looks like a credential, a RFC1918 address, or an internal hostname such as
    something.internal / something.lan.

    This repo is public, and the natural next edit to patchmon-agent-install.ps1 is pasting
    in the real auto-enrollment secret and the real server name. That edit is meant to stay
    on your workstation; this script is what keeps it there.

    Lines ending in #nosecret are skipped. This file is not scanned - its rules are, by
    nature, full of the patterns it looks for.

.EXAMPLE
    pwsh -File tests/Check-NoSecrets.ps1

.EXAMPLE
    pwsh -File tests/Check-NoSecrets.ps1 -All
    Scan every tracked file, not just what is staged.
#>
[CmdletBinding()]
param(
    [switch]$All,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$self = Split-Path -Leaf $MyInvocation.MyCommand.Path
# Empty when this script was piped or Invoke-Expression'd rather than run as a file.
$rootDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }
$excludeSelf = $true

$rules = @(
    @{
        Name    = 'GitHub token'
        Pattern = '\bgh[pousr]_[A-Za-z0-9]{20,}'
        Hint    = 'A GitHub OAuth/personal token. Revoke it at https://github.com/settings/tokens'
    }
    @{
        Name    = 'Private key material'
        Pattern = '-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----'
        Hint    = 'A private key. Remove it and rotate the keypair.'
    }
    @{
        Name    = 'Credential assignment'
        # No leading \b: real variable names are AutoEnrollmentSecret, gitlab_token, DB_PASSWORD.
        Pattern = '(?i)(secret|token|password|passwd|pwd|api[_-]?key|access[_-]?key)\s*[:=]\s*[''"][^''"$<>]{6,}[''"]'
        Hint    = 'A literal secret value. Use REPLACE_WITH_YOUR_VALUE or read it from the environment.'
    }
    @{
        Name    = 'Bearer/Authorization literal'
        Pattern = '(?i)\b(bearer|basic)\s+[''"]?[A-Za-z0-9+/=_.-]{20,}'
        Hint    = 'An auth header with a literal value.'
    }
    @{
        Name    = 'RFC1918 address'
        Pattern = '\b(?:10\.\d{1,3}(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3})\b'
        Hint    = 'An internal IP address. Your addressing scheme does not belong in a public repo.'
    }
    @{
        Name    = 'Internal hostname'
        # The lookahead keeps documentation about our own *.local.md ignore convention from
        # tripping the rule; a real host such as server.corp still matches.
        Pattern = '\b(?:[\w-]+\.)+(?:local|lan|internal|corp|intra|localdomain|home)(?!\.(?:md|ps1|txt|example|gitignore))\b'
        Hint    = 'An internal DNS name. Use something.example.com instead.'
    }
)

# Obvious placeholders are fine.
$allowed = @(
    '(?i)example\.(com|org|net|edu)'
    '(?i)REPLACE_WITH_|CHANGE_?ME|YOUR[_-]?(VALUE|HERE)|FIX_?ME'
    '(?i)\bplaceholder\b|\bfake\b|\bsample\b|\bdummy\b'
    '<[A-Z_]+>'            # <API_KEY>, <SERVER_URL>
    '\$env:'
    '\blocalhost\b'
    '\b127\.0\.0\.1\b'
)

# --- self test: prove the rules actually fire, and that our own docs do not trip them ---
if ($SelfTest) {
    # Test fixtures are composed from parts so this file never contains a plausible
    # internal IP address, token or key, even as a sample. Do not "tidy" them into
    # literals - and do not paste a real address here.
    $bad = @(
        @{ Text = ('  $AutoEnrollmentSecret = "ae_liv' + 'e_8f3a9c2b1d4e6a"'); Rule = 'Credential assignment' },
        @{ Text = '  Authorization: Bearer ' + ('a' * 24); Rule = 'Bearer/Authorization literal' },
        @{ Text = ('server addressed at 10.1' + '0.24.7 on the patch vlan'); Rule = 'RFC1918 address' },
        @{ Text = ('gateway 172.20.5.' + '1 and printer 192.168.4.9'); Rule = 'RFC1918 address' },
        @{ Text = 'return , (Invoke-RestMethod https://patchmon.acme.internal/api)'; Rule = 'Internal hostname' },
        @{ Text = 'agent points at patchmon.acme.lan'; Rule = 'Internal hostname' },
        @{ Text = ('token = ''ghp_' + ('Z' * 36) + ''''); Rule = 'GitHub token' },
        @{ Text = '-----BEGIN RSA PRIVATE' + ' KEY-----'; Rule = 'Private key material' }
    )
    $good = @(
        '  [string]$AutoEnrollmentSecret = "REPLACE_WITH_AUTO_ENROLLMENT_SECRET",'
        '  [string]$ServerURL = "https://patchmon.example.com",'
        'Real values belong in SITE-SETTINGS.local.md which is ignored'
        '  any `*.local.md`, `reference/` and all key material'
        '  patchmon-agent.exe config set-api <API_ID> <API_KEY> <SERVER_URL>'
        '  $env:PATCHMON_SKIP_SSL_VERIFY = "true"'
        '  rsat capability Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0'
    )
    $selfFail = 0
    foreach ($case in $bad) {
        $hit = $null
        foreach ($rule in $rules) { if ($case.Text -match $rule.Pattern) { $hit = $rule.Name; break } }
        if ($hit -eq $case.Rule) { Write-Host "PASS  detects $($case.Rule)" }
        else { $selfFail++; Write-Host "FAIL  expected [$($case.Rule)], got [$hit] for: $($case.Text)" -ForegroundColor Red }
    }
    foreach ($line in $good) {
        $hit = $null
        foreach ($rule in $rules) {
            if ($line -match $rule.Pattern) {
                $exused = $false
                foreach ($allow in $allowed) { if ($line -match $allow) { $exused = $true; break } }
                if (-not $exused) { $hit = $rule.Name; break }
            }
        }
        if (-not $hit) { Write-Host "PASS  clean: $($line.Trim().Substring(0, [Math]::Min(52, $line.Trim().Length)))" }
        else { $selfFail++; Write-Host "FAIL  false positive [$hit]: $line" -ForegroundColor Red }
    }
    Write-Host ''
    if ($selfFail -eq 0) { Write-Host "Self-test OK ($($bad.Count) detections, $($good.Count) clean lines)."; exit 0 }
    Write-Host "$($selfFail) self-test failure(s) - the scanner is not trustworthy."
    exit 1
}

function Get-FilesToScan {
    $inRepo = $false
    if (Get-Command git -ErrorAction SilentlyContinue) {
        git rev-parse --is-inside-work-tree *> $null
        if ($LASTEXITCODE -eq 0) { $inRepo = $true }
    }

    if (-not $inRepo) {
        # Not a git checkout (before the first commit, or a copy on a share): scan what is on disk,
        # skipping the same things .gitignore keeps out so both modes agree.
        $root = Split-Path -Parent $rootDir
        $ignored = '\.local\.(md|ps1)$|\\reference\\|\\\.git\\|\.(pfx|p12|key|cer|pvk|log)$'
        return Get-ChildItem -LiteralPath $root -Recurse -File |
            Where-Object { $_.FullName -notmatch $ignored -and $_.Name -ne $self } |
            ForEach-Object { $_.FullName.Substring($root.Length + 1) }
    }
    if ($All) {
        # Tracked files only, so .gitignore keeps SITE-SETTINGS.local.md and reference/ out.
        git ls-files
    }
    else {
        $staged = git diff --cached --name-only --diff-filter=ACM
        if ($staged) { $staged }
        else { git ls-files }   # nothing staged: scan the tree so -All is not the only usable mode
    }
}

function Get-FileContent {
    param([string]$Path, [switch]$FromIndex)
    if ($FromIndex -and -not $All -and (Get-Command git -ErrorAction SilentlyContinue)) {
        git rev-parse --is-inside-work-tree *> $null
        if ($LASTEXITCODE -eq 0) {
            # Scan what is actually staged, not what the editor has in memory.
            $staged = git show ":$Path" 2>$null
            if ($LASTEXITCODE -eq 0) { return , $staged }
        }
    }
    if (Test-Path -LiteralPath $Path) { return , (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) }
    return , @()
}

$hits = New-Object System.Collections.ArrayList
$files = @(Get-FilesToScan | Where-Object { $_ })

foreach ($file in $files) {
    $leaf = Split-Path -Leaf $file
    if ($excludeSelf -and $leaf -eq $self) { continue }
    # Skip obvious binaries.
    if ($leaf -match '\.(pfx|p12|key|cer|pvk|png|jpg|jpeg|gif|ico|zip|gz|exe|dll)$') { continue }

    $lines = Get-FileContent -Path $file -FromIndex
    $lineNo = 0
    foreach ($line in $lines) {
        $lineNo++
        if ($line -match '#nosecret') { continue }
        foreach ($allow in $allowed) {
            if ($line -match $allow) { $line = '' ; break }
        }
        if (-not $line) { continue }
        foreach ($rule in $rules) {
            if ($line -match $rule.Pattern) {
                $preview = $line.Trim()
                if ($preview.Length -gt 110) { $preview = $preview.Substring(0, 107) + '...' }
                [void]$hits.Add([pscustomobject]@{
                        File   = $file
                        Line   = $lineNo
                        Rule   = $rule.Name
                        Text   = $preview
                        Hint   = $rule.Hint
                    })
                break
            }
        }
    }
}

Write-Host "Checked $(@($files).Count) file(s) against $($rules.Count) rule(s)."

if ($hits.Count -eq 0) {
    Write-Host 'OK - no secrets or site-internal identifiers found.'
    exit 0
}

Write-Host ''
Write-Host "$($hits.Count) finding(s) - this would be a leak in a public repo:" -ForegroundColor Red
foreach ($h in $hits) {
    Write-Host ''
    Write-Host "  $($h.File):$($h.Line)  [$($h.Rule)]" -ForegroundColor Yellow
    Write-Host "    $($h.Text)"
    Write-Host "    -> $($h.Hint)" -ForegroundColor DarkGray
}
Write-Host ''
Write-Host 'Fix it, or if this file is genuinely meant to hold that value, keep it out of the repo'
Write-Host '(add it to .gitignore, e.g. SITE-SETTINGS.local.md). For a single false-positive line'
Write-Host 'append  #nosecret  to that line.'
exit 1
