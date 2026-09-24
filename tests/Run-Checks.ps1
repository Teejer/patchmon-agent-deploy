$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$src = Get-Content (Join-Path $root 'patchmon-agent-install.ps1') -Raw

# --- extract Get-ServiceBinaryPath from the installer and exercise it offline ---
$start = $src.IndexOf('function Get-ServiceBinaryPath')
$open = $src.IndexOf('{', $start)
$depth = 0; $end = -1
for ($j = $open; $j -lt $src.Length; $j++) {
    if ($src[$j] -eq '{') { $depth++ }
    elseif ($src[$j] -eq '}') { $depth--; if ($depth -eq 0) { $end = $j; break } }
}
Invoke-Expression $src.Substring($start, $end - $start + 1)

# Known-good paths for the Test-Path stub below.
$valid = @(
    'C:\Program Files\PatchMon\patchmon-agent.exe'
    'C:\Windows\system32\svchost.exe'
)
function Test-Path {
    param([string]$Path, [string]$LiteralPath)
    $target = if ($PSBoundParameters.ContainsKey('LiteralPath')) { $LiteralPath } else { $Path }
    return $valid -contains $target
}
function Get-CimInstance {
    param([string]$ClassName, [string]$Filter, [string]$ErrorAction)
    return [pscustomobject]@{ PathName = $script:currentPath }
}

$fail = 0
$q = '"'
$cases = [ordered]@{
    "C:\Program Files\PatchMon\patchmon-agent.exe serve"                  = 'C:\Program Files\PatchMon\patchmon-agent.exe'
    ($q + 'C:\Program Files\PatchMon\patchmon-agent.exe' + $q + ' serve') = 'C:\Program Files\PatchMon\patchmon-agent.exe'
    'C:\Windows\system32\svchost.exe -k netsvcs'                           = 'C:\Windows\system32\svchost.exe'
    ($q + 'C:\Program Files\Nope\x.exe' + $q)                              = $null
    ''                                                                     = $null
}
foreach ($k in $cases.Keys) {
    $script:currentPath = $k
    $got = Get-ServiceBinaryPath -Name PatchMonAgent
    $want = $cases[$k]
    if ($got -eq $want) { Write-Host "PASS  PathName [$k] -> [$got]" }
    else { $fail++; Write-Host "FAIL  PathName [$k] -> got [$got] want [$want]" -ForegroundColor Red }
}

# --- bootstrap token scrape (must handle "x", ""x"" and 'x' forms) ---
# Pull the pattern straight out of the installer so this test can't drift from it.
$line = ($src -split "`r?`n" | Where-Object { $_ -match 'installer\.Content,' } | Select-Object -First 1)
if ($line) {
    $first = $line.IndexOf("'")
    $last = $line.LastIndexOf("'")
    $pattern = $line.Substring($first + 1, $last - $first - 1)
    Write-Host "using pattern from installer: $pattern"
}
else {
    $pattern = ''
}
if (-not $pattern) { $fail++; Write-Host 'FAIL  could not extract the token pattern from the installer' -ForegroundColor Red }
foreach ($form in @(
        '$env:PATCHMON_BOOTSTRAP_TOKEN = "btp_live_9f3a-1234"',
        'powershell -c "& { $env:PATCHMON_BOOTSTRAP_TOKEN = ""btp_live_9f3a-1234""; exit 0 }"',
        "`$env:PATCHMON_BOOTSTRAP_TOKEN = 'btp_live_9f3a-1234'",
        '$env:PATCHMON_BOOTSTRAP_TOKEN = btp_live_9f3a-1234'
    )) {
    $m = [regex]::Match($form, $pattern)
    if ($m.Success -and $m.Groups[1].Value -eq 'btp_live_9f3a-1234') {
        Write-Host "PASS  bootstrap token ($($form.Substring(0, [Math]::Min(40, $form.Length)))...)"
    }
    else { $fail++; Write-Host "FAIL  bootstrap token for: $form" -ForegroundColor Red }
}
$noToken = [regex]::Match('Write-Host "nothing here"', $pattern)
if (-not $noToken.Success) { Write-Host 'PASS  no false positive when the token is absent' }
else { $fail++; Write-Host 'FAIL  false positive on token regex' -ForegroundColor Red }

# --- enrollment response parsing (both known shapes) ---
foreach ($shape in @(
        '{"host":{"api_id":"host_abc","api_key":"k1","hostname":"WS01"}}',
        '{"api_id":"host_abc","api_key":"k1"}'
    )) {
    $d = $shape | ConvertFrom-Json
    if ($d.host) { $id = $d.host.api_id; $key = $d.host.api_key } elseif ($d.api_id) { $id = $d.api_id; $key = $d.api_key }
    if ($id -eq 'host_abc' -and $key -eq 'k1') { Write-Host "PASS  enroll shape -> $id/$key" }
    else { $fail++; Write-Host "FAIL  enroll shape $shape" -ForegroundColor Red }
}

# --- GPO helper: UNC rewrite in the task XML ---
$xml = Get-Content (Join-Path $root 'PatchMon-Agent-Install.xml') -Raw
# Replacement host must differ from the one in the committed XML, otherwise the
# "old path is gone" assertion is meaningless.
$unc = '\\dc02.example.org\SYSVOL\dc02.example.org\scripts\patchmon\patchmon-agent-install.ps1'
$new = $xml -replace '\\\\[^"<>\s]*?patchmon-agent-install\.ps1', $unc
if ($new -like ('*' + $unc + '*') -and $new -notlike '*example.com\SYSVOL*') {
    Write-Host 'PASS  xml UNC rewrite'
}
else { $fail++; Write-Host 'FAIL  xml UNC rewrite' -ForegroundColor Red }

# --- task XML is well formed and has the pieces GPMC needs ---
[xml]$task = Get-Content (Join-Path $root 'PatchMon-Agent-Install.xml')
$checks = @(
    ($task.Task.Principals.Principal.UserId -eq 'S-1-5-18'),
    ($task.Task.Actions.Exec.Command -like '*powershell.exe'),
    ($task.Task.Actions.Exec.Arguments -like '*patchmon-agent-install.ps1*'),
    (@($task.Task.Triggers.ChildNodes).Count -ge 2),
    ($task.Task.Settings.ExecutionTimeLimit -eq 'PT1H')
)
if (-not ($checks -contains $false)) { Write-Host 'PASS  task XML structure (SYSTEM principal, action, 2 triggers, time limit)' }
else { $fail++; Write-Host "FAIL  task XML structure: $($checks -join ',')" -ForegroundColor Red }

# --- placeholder guard trips on the shipped defaults ---
$defaults = Get-Content (Join-Path $root 'patchmon-agent-install.ps1') -Raw
$keyDefault = [regex]::Match($defaults, '\[string\]\$AutoEnrollmentKey\s*=\s*"([^"]+)"').Groups[1].Value
if ($keyDefault -like 'REPLACE_WITH_*') { Write-Host "PASS  shipped default is a placeholder ($keyDefault) so a forgotten edit fails loudly" }
else { $fail++; Write-Host 'FAIL  AutoEnrollmentKey default is not a placeholder pattern' -ForegroundColor Red }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All checks passed.' } else { Write-Host "$fail check(s) failed"; exit 1 }
