$ErrorActionPreference = 'Stop'
# tests/Run-Checks.ps1 lives one level below the scripts it checks. $PSScriptRoot is
# empty when this file is piped or Invoke-Expression'd, and the current directory may
# be the repo root or anything else, so probe for the installer instead of assuming.
$startedIn = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }
$root = $null
foreach ($candidate in @((Split-Path -Parent $startedIn), $startedIn, (Get-Location).ProviderPath, (Split-Path -Parent (Get-Location).ProviderPath))) {
    if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'patchmon-agent-install.ps1'))) { $root = $candidate; break }
}
if (-not $root) {
    Write-Error 'Cannot find patchmon-agent-install.ps1 above this location. Run the tests from the repo root or its tests folder.'
    exit 1
}
Write-Host "checking scripts in: $root"

# -------------------------------------------------------------------- #
#  config.yml generation: run the installer's real config block         #
# -------------------------------------------------------------------- #
# These run before the Test-Path stub below, which deliberately lies about paths.
$fail = 0
$installerSrc = Get-Content (Join-Path $root 'patchmon-agent-install.ps1') -Raw

function Get-MarkedBlock {
    # Everything between two marker comments; the installer is expected to execute this
    # same text on a real machine, so the test must not paraphrase it. Starts after the
    # whole begin-marker line, otherwise the rest of that comment is executed as code.
    param([string]$Source, [string]$Begin, [string]$End)
    $b = $Source.IndexOf($Begin)
    $e = $Source.IndexOf($End)
    if ($b -lt 0 -or $e -lt 0 -or $e -lt $b) { return $null }
    $nl = $Source.IndexOf("`n", $b)
    if ($nl -lt 0 -or $nl -gt $e) { return $null }
    return $Source.Substring($nl + 1, $e - $nl - 1)
}

function Read-YamlLike {
    # Enough of YAML to check what we wrote: key: value, single-quoted, unquoted.
    param([string]$Text)
    $map = [ordered]@{}
    foreach ($line in ($Text -split "\r?\n")) {
        if ($line -match "^[ \t]*([A-Za-z_]+)[ \t]*:[ \t]*(.*?)[ \t]*$") {
            $k = $Matches[1]
            $raw = $Matches[2]
            $v = $raw
            if ($raw -match "^'(.*)'$") { $v = ($Matches[1] -replace "''", "'") }
            $map[$k] = $v
            $map["$k`_raw"] = $raw
        }
    }
    return $map
}

function Get-FunctionSource {
    # Pull a whole function out of the installer so the test exercises the shipped code.
    param([string]$Source, [string]$Name)
    $start = $Source.IndexOf("function $Name")
    if ($start -lt 0) { return $null }
    $open = $Source.IndexOf('{', $start)
    if ($open -lt 0) { return $null }
    $depth = 0
    for ($j = $open; $j -lt $Source.Length; $j++) {
        if ($Source[$j] -eq '{') { $depth++ }
        elseif ($Source[$j] -eq '}') { $depth--; if ($depth -eq 0) { return $Source.Substring($start, $j - $start + 1) } }
    }
    return $null
}

function Get-SingleQuotedLiteral {
    # The first ... last apostrophe on the line that assigns a regex, so the test cannot
    # drift from the regex the installer actually uses.
    param([string]$Source, [string]$Marker)
    $line = ($Source -split "\r?\n" | Where-Object { $_ -match [regex]::Escape($Marker) } | Select-Object -First 1)
    if (-not $line) { return $null }
    $first = $line.IndexOf("'")
    $last = $line.LastIndexOf("'")
    if ($first -lt 0 -or $last -le $first) { return $null }
    return $line.Substring($first + 1, $last - $first - 1)
}

function Get-MissingKeys {
    # A repaired config must still contain every key. Regex replacements that eat the key
    # name are exactly the kind of bug that leaves a config the agent silently resets.
    param($Map)
    return @('patchmon_server', 'api_version', 'credentials_file', 'log_file', 'log_level', 'skip_ssl_verify') |
        Where-Object { -not $Map.Contains($_) }
}

function Get-LostKeys {
    # The repair path may add keys but must never drop one that was already there.
    # (An agent-reset config legitimately has no log_file/log_level, so requiring all six
    # would be wrong; losing one that was present is the actual bug class.)
    param($Before, $After)
    return @($Before.Keys | Where-Object { $_ -notlike '*_raw' -and -not $After.Contains($_) })
}

function New-TestDir {
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("patchmon-cfgtest-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Invoke-ConfigBlock {
    # Calls the installer's real Write-PatchMonConfig against a scratch directory. A
    # failure calls exit / returns false and stops this run - loud, which is what we want.
    param([string]$Dir, [string]$Url, [bool]$SkipSsl, [string]$Preset)
    if ($Preset) {
        [System.IO.File]::WriteAllText((Join-Path $Dir 'config.yml'), $Preset, (New-Object System.Text.UTF8Encoding($false)))
    }
    function Write-Log { param([string]$Message, [string]$Level = 'INFO') $script:logLines += "[$Level] $Message" }
    $ok = Write-PatchMonConfig -ConfigDir $Dir -Url $Url -SkipSsl $SkipSsl
    if (-not $ok) { throw "Write-PatchMonConfig refused to finish (returned false)" }
    return (Get-Content -LiteralPath (Join-Path $Dir 'config.yml') -Raw)
}

$configBlock = Get-MarkedBlock -Source $installerSrc -Begin '# --- CONFIG-YAML-BEGIN' -End '# --- CONFIG-YAML-END'
if (-not $configBlock) {
    $fail++
    Write-Host 'FAIL  could not find the CONFIG-YAML markers in the installer' -ForegroundColor Red
}
else {
    # The marked block defines Quote-YamlValue, Write-ConfigFile, Write-PatchMonConfig and
    # Test-PatchMonConfigCurrent; load them, then drive them like the installer does.
    Invoke-Expression $configBlock
    $url = 'https://patchmon.example.com'
    $winPath = 'C:\ProgramData\PatchMon'

    # 1. fresh install: file created, values single-quoted, no BOM, server and ssl correct
    $dir = New-TestDir
    $out = Invoke-ConfigBlock -Dir $dir -Url $url -SkipSsl $false
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $dir 'config.yml'))
    $y = Read-YamlLike -Text $out
    $missing = Get-MissingKeys -Map $y
    $ok = ($missing.Count -eq 0) -and
          ($y['patchmon_server'] -eq $url) -and
          ($y['api_version'] -eq 'v1') -and
          ($y['log_level'] -eq 'info') -and
          ($y['credentials_file'] -like '*credentials.yml') -and
          ($y['log_file'] -like '*patchmon-agent.log') -and
          ($y['skip_ssl_verify'] -eq 'false') -and
          ($y['credentials_file_raw'] -match "^'.*'$") -and
          ($y['patchmon_server_raw'] -match "^'.*'$") -and
          ($out -notmatch "(?m)^[ \t]*[A-Za-z_]+[ \t]*:[ \t]*`"[^`"`r\n]*\\") -and
          ($bytes[0] -ne 0xEF)
    if ($ok) { Write-Host 'PASS  fresh config.yml: all keys present, single-quoted, no BOM' }
    else { $fail++; Write-Host "FAIL  fresh config.yml (missing: $($missing -join ', ')):`n$out" -ForegroundColor Red }

    # 1b. Windows path semantics, tested as strings so it also runs on Linux/macOS
    $qf = Get-FunctionSource -Source $installerSrc -Name 'Quote-YamlValue'
    if (-not $qf) { $fail++; Write-Host 'FAIL  could not extract Quote-YamlValue' -ForegroundColor Red }
    else {
        Invoke-Expression $qf
        $esc = Quote-YamlValue "C:\Program Files\PatchMon\credentials.yml"
        $esc2 = Quote-YamlValue "C:\Users\O'Neil\PatchMon\credentials.yml"
        if ($esc -eq "'C:\Program Files\PatchMon\credentials.yml'" -and $esc2 -eq "'C:\Users\O''Neil\PatchMon\credentials.yml'") {
            Write-Host 'PASS  YAML quoting keeps backslashes literal and doubles apostrophes'
        }
        else { $fail++; Write-Host "FAIL  YAML quoting: [$esc] [$esc2]" -ForegroundColor Red }
    }

    # 1c. the repair regex, taken from the installer, applied to a Windows config file
    $dq = Get-SingleQuotedLiteral -Source $installerSrc -Marker '$doubleQuotedPath ='
    if (-not $dq) { $fail++; Write-Host 'FAIL  could not extract the repair regex' -ForegroundColor Red }
    else {
        $win = "credentials_file: `"C:\ProgramData\PatchMon\credentials.yml`""
        $fixed = [regex]::Replace($win, $dq, {
            param($m) '{0}{1}: {2}{3}{4}' -f $m.Groups[1].Value, $m.Groups[2].Value,
                (Quote-YamlValue $m.Groups[3].Value), $m.Groups[4].Value, $m.Groups[5].Value
        })
        if ($fixed -eq "credentials_file: 'C:\ProgramData\PatchMon\credentials.yml'") {
            Write-Host 'PASS  repair regex converts a double-quoted Windows path'
        }
        else { $fail++; Write-Host "FAIL  repair regex produced [$fixed]" -ForegroundColor Red }
    }

    # 2. the file that broke the agent: double-quoted Windows paths, wrong server, ssl true
    $win = @(
        'patchmon_server: "http://old.example.com:3000"'
        'api_version: "v1"'
        ('credentials_file: "' + $winPath + '\credentials.yml"')
        ('log_file: "' + $winPath + '\patchmon-agent.log"')
        'log_level: "info"'
        'skip_ssl_verify: true'
    )
    $broken = ($win -join "`r`n") + "`r`n"
    $dir = New-TestDir
    $out = Invoke-ConfigBlock -Dir $dir -Url $url -SkipSsl $false -Preset $broken
    $y = Read-YamlLike -Text $out
    $missing = Get-MissingKeys -Map $y
    $ok = ($missing.Count -eq 0) -and
          ($out -notmatch "(?m)^[ \t]*[A-Za-z_]+[ \t]*:[ \t]*`"[^`"`r\n]*\\") -and
          ($y['credentials_file'] -eq "$winPath\credentials.yml") -and
          ($y['log_file'] -eq "$winPath\patchmon-agent.log") -and
          ($y['patchmon_server'] -eq $url) -and
          ($y['skip_ssl_verify'] -eq 'false')
    if ($ok) { Write-Host 'PASS  repaired a double-quoted config.yml; paths and server now parse' }
    else { $fail++; Write-Host "FAIL  repair of broken config.yml (missing: $($missing -join ', ')):`n$out" -ForegroundColor Red }

    # 3. config the agent replaced with defaults: no patchmon_server line at all
    $defaults = @("api_version: 'v1'", ('credentials_file: ' + "'" + $winPath + '\credentials.yml' + "'"), 'skip_ssl_verify: false')
    $defaults = ($defaults -join "`r`n") + "`r`n"
    $dir = New-TestDir
    $out = Invoke-ConfigBlock -Dir $dir -Url $url -SkipSsl $true -Preset $defaults
    $before = Read-YamlLike -Text $defaults
    $y = Read-YamlLike -Text $out
    $lost = Get-LostKeys -Before $before -After $y
    if ($lost.Count -eq 0 -and $y['patchmon_server'] -eq $url -and $y['skip_ssl_verify'] -eq 'true') {
        Write-Host 'PASS  re-added patchmon_server to a config the agent had reset, lost nothing'
    }
    else { $fail++; Write-Host "FAIL  config reset to defaults (lost: $($lost -join ', ')):`n$out" -ForegroundColor Red }

    # 3b. a zero-byte config (interrupted write) must be replaced, not appended to
    $dir = New-TestDir
    [System.IO.File]::WriteAllText((Join-Path $dir 'config.yml'), '', (New-Object System.Text.UTF8Encoding($false)))
    $out = Invoke-ConfigBlock -Dir $dir -Url $url -SkipSsl $false
    $y = Read-YamlLike -Text $out
    $missing = Get-MissingKeys -Map $y
    if ($missing.Count -eq 0 -and $y['patchmon_server'] -eq $url) {
        Write-Host 'PASS  replaced an empty config.yml instead of appending to it'
    }
    else { $fail++; Write-Host "FAIL  empty config.yml (missing: $($missing -join ', ')):`n$out" -ForegroundColor Red }

    # 4. a config path containing a single quote must be escaped, not corrupted
    $dir = New-TestDir
    $dir2 = Join-Path $dir "wo'men"
    New-Item -ItemType Directory -Path $dir2 -Force | Out-Null
    $out = Invoke-ConfigBlock -Dir $dir2 -Url $url -SkipSsl $false
    $y = Read-YamlLike -Text $out
    $missing = Get-MissingKeys -Map $y
    if ($missing.Count -eq 0 -and $y['credentials_file'] -like "*wo'men*" -and $y['credentials_file'] -like '*credentials.yml' -and $y['credentials_file_raw'] -like "'*''*'") {
        Write-Host "PASS  apostrophe in the path survives YAML escaping"
    }
    else { $fail++; Write-Host "FAIL  apostrophe path (missing: $($missing -join ', '), raw: $($y['credentials_file_raw'])):`n$out" -ForegroundColor Red }

    # 5. Test-PatchMonConfigCurrent gates the early exit; wrong either way is bad
    $gate = [ordered]@{ }
    $dir = New-TestDir
    $gate['missing file'] = (Test-PatchMonConfigCurrent -ConfigDir $dir -Url $url)

    $null = Invoke-ConfigBlock -Dir $dir -Url $url -SkipSsl $false
    $gate['fresh config'] = (Test-PatchMonConfigCurrent -ConfigDir $dir -Url $url)
    $gate['other server'] = (Test-PatchMonConfigCurrent -ConfigDir $dir -Url 'https://elsewhere.example.com')

    # Written by hand, not through the installer, so these are unrepaired inputs
    $dir = New-TestDir
    [System.IO.File]::WriteAllText((Join-Path $dir 'config.yml'), ("patchmon_server: `"http://old.example.com:3000`"" + "`r`n" + "api_version: 'v1'"), (New-Object System.Text.UTF8Encoding($false)))
    $gate['stale server'] = (Test-PatchMonConfigCurrent -ConfigDir $dir -Url $url)

    $dir = New-TestDir
    [System.IO.File]::WriteAllText((Join-Path $dir 'config.yml'), ("patchmon_server: '" + $url + "'" + "`r`n" + 'credentials_file: "C:\ProgramData\PatchMon\credentials.yml"'), (New-Object System.Text.UTF8Encoding($false)))
    $gate['unparsable quoting'] = (Test-PatchMonConfigCurrent -ConfigDir $dir -Url $url)

    $dir = New-TestDir
    [System.IO.File]::WriteAllText((Join-Path $dir 'config.yml'), '   ', (New-Object System.Text.UTF8Encoding($false)))
    $gate['blank config'] = (Test-PatchMonConfigCurrent -ConfigDir $dir -Url $url)

    # only "fresh config" may short-circuit the installer; the rest must reach the repair path
    $expected = [ordered]@{ 'missing file' = $false; 'fresh config' = $true; 'other server' = $false; 'stale server' = $false; 'unparsable quoting' = $false; 'blank config' = $false }
    $wrong = @($expected.Keys | Where-Object { [bool]$gate[$_] -ne $expected[$_] })
    if ($wrong.Count -eq 0) {
        Write-Host "PASS  config-current gate: only a good config short-circuits the installer ($($expected.Count) cases)"
    }
    else {
        $fail++
        Write-Host 'FAIL  config-current gate wrong for: ' ($wrong | ForEach-Object { "$_=$( [bool]$gate[$_] )" }) -ForegroundColor Red
    }

    # 6. the YAML the agent complained about must not appear anywhere in the installer
    if ($installerSrc -match '(?m)^\s*(credentials_file|log_file|patchmon_server)[^\r\n]*:\s*"[^"\r\n]*\\') {
        $fail++
        Write-Host 'FAIL  the installer still writes a double-quoted Windows path somewhere' -ForegroundColor Red
    }
    else { Write-Host 'PASS  no double-quoted Windows paths in the installer source' }
}
Write-Host ''
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

# NOTE: do not reset $fail here; the config.yml tests above already contribute to it.
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

# --- param defaults must not depend on a possibly-null variable ---
# A param default that calls Join-Path on $env:ProgramFiles / $env:USERPROFILE fails
# during parameter binding - before logging, before the RSAT check, before anything
# readable. $PSScriptRoot is empty under iex/paste too. Windows fills most of these in,
# so the only way to catch it is to look at the AST.
$unsafeFiles = @('patchmon-agent-install.ps1', 'uninstall-patchmon-agent.ps1', 'deploy-patchmon-gpo.ps1')
$unsafe = foreach ($f in $unsafeFiles) {
    $tok = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $f), [ref]$tok, [ref]$errs)
    if ($errs) { "$f has parse errors"; continue }
    foreach ($p in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)) {
        if (-not $p.Argument) { continue }
        $txt = ($p.Argument.Extent.Text -replace '\s+', ' ').Trim()
        if ($txt -match 'Join-Path' -or $txt -match '\$env:' -or $txt -match '\$PSScriptRoot') {
            "$($p.Name.UserPath) = $txt  (${f}:$($p.Extent.StartLineNumber))"
        }
    }
}
if ($unsafe) { $fail++; Write-Host 'FAIL  unsafe param defaults (resolve these after the param block):' -ForegroundColor Red; $unsafe | ForEach-Object { Write-Host "        $_" } }
else { Write-Host "PASS  no unsafe param defaults in $($unsafeFiles.Count) shipped scripts" }

Write-Host ''
if ($fail -eq 0) { Write-Host 'All checks passed.' } else { Write-Host "$fail check(s) failed"; exit 1 }
