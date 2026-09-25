# PatchMon agent deployment for Windows

Deploys the [PatchMon](https://patchmon.net) agent to Windows machines so that **new domain
members install and enrol themselves** - no pre-creating host records, no touching each box.

Each machine uses the PatchMon *auto-enrollment* API to create its own host record, get its own
`api_id`/`api_key`, install the agent as a LocalSystem service, and then re-check itself daily.

Based on the script posted in [PatchMon issue #721](https://github.com/PatchMon/PatchMon/issues/721#issuecomment-4455329530),
cleaned up and packaged.

Everything here uses `example.com` placeholders and `REPLACE_WITH_...` tokens so the repo can be
public. See [Site settings](#site-settings-change-these-before-deploying) for what to change, and
[Keeping this repo public](#keeping-this-repo-public) for the guard that stops real values from
being committed.

## Files

| File | What it is |
| --- | --- |
| `patchmon-agent-install.ps1` | The installer. Runs on every client, daily, as SYSTEM. Idempotent. |
| `uninstall-patchmon-agent.ps1` | Removes the service, the daily task and (optionally) the files. |
| `PatchMon-Agent-Install.xml` | Task Scheduler definition you paste into the GPO. |
| `deploy-patchmon-gpo.ps1` | Run once on a DC: stages files in SYSVOL, fixes the path in the XML, creates and links the GPO. |
| `tests/Run-Checks.ps1` | Offline sanity checks for the fiddly parsing in the installer. Run with `pwsh -File tests/Run-Checks.ps1` (works on Linux/macOS too). |
| `tests/Check-NoSecrets.ps1` | Pre-commit scanner for credentials, internal hostnames and RFC1918 addresses. |
| `.githooks/pre-commit` | Runs that scanner before every commit. Enable with `git config core.hooksPath .githooks`. |
| `patchmon-dc-reporter.ps1` | Agent-less Windows Update reporter for DCs. **AGPL-3.0** (derived from PatchMon source, see [Domain controllers](#domain-controllers-no-agent)). |
| `setup-patchmon-dcs.ps1` | Run from an admin workstation: enrolls each DC, stages the reporter, registers its scheduled task. Same AGPL note. |

## Site settings (change these before deploying)

Real values belong in a git-ignored file in your clone - `SITE-SETTINGS.local.md` is the
convention used here and `.gitignore` already covers `*.local.md`.

| Where | Setting | Placeholder |
| --- | --- | --- |
| `patchmon-agent-install.ps1` | `$ServerURL` | `https://patchmon.example.com` |
| `patchmon-agent-install.ps1` | `$AutoEnrollmentKey` / `$AutoEnrollmentSecret` | `REPLACE_WITH_...` (installer exits 2 if left alone) |
| `PatchMon-Agent-Install.xml` | the UNC path in `<Arguments>` | `\\example.com\SYSVOL\example.com\scripts\patchmon\...` |
| `deploy-patchmon-gpo.ps1` | `-Domain` / `-OU` | `example.com` |

If you use `deploy-patchmon-gpo.ps1`, it rewrites the UNC path in the task XML for you, so the XML
file only needs hand-editing when you skip that script.

## Before you start

1. **Server URL.** The installer defaults to `https://patchmon.example.com`. If your PatchMon server
   is still plain HTTP on a port (e.g. `http://patchmon.example.com:3000`), either uncomment the
   commented `http://...:3000` line right above the default, or pass
   `-ServerURL "http://patchmon.example.com:3000"` to the scheduled task. HTTPS is the right end
   state - those credentials should not cross the network in clear text.
2. **Auto-enrollment token.** PatchMon UI -> Settings -> Auto Enrollment -> create a token. You get
   a key and a secret. Paste both into `$AutoEnrollmentKey` / `$AutoEnrollmentSecret` in
   `patchmon-agent-install.ps1`. Give the token a sensible expiry/rotation reminder - it is the
   master key for creating host records.
3. **Decide the OU scope.** The agent should reach workstations and member servers. Linking the GPO
   at the domain root also hits domain controllers - usually not what you want.

## Path A - Group Policy (recommended)

### 1. Stage and create the GPO (on a DC or RSAT workstation)

```powershell
# dry run first
.\deploy-patchmon-gpo.ps1 -Domain example.com -OU 'OU=Workstations,DC=example,DC=com' -WhatIf

# for real, letting the script sign the installer (it signs before it copies - correct order)
.\deploy-patchmon-gpo.ps1 -Domain example.com -OU 'OU=Workstations,DC=example,DC=com' `
    -SignedCertThumbprint 'A1B2C3D4...'
```

Signing it yourself? Leave `-SignedCertThumbprint` out and sign **after** step 2 below - this script
copies the installer into SYSVOL with `-Force`, which would otherwise overwrite your signed copy. See
[Code signing](#code-signing).

This writes a path-corrected copy of the task XML to your desktop and creates + links the
`PatchMon Agent Deployment` GPO.

**Staging uses the DC's own local SYSVOL path** - `C:\Windows\SYSVOL\sysvol\<domain>\scripts\patchmon`
- not `\\<domain>\SYSVOL\...`. Writing locally means no SMB access to the SYSVOL share is needed and
its share permissions stay exactly as they are. That matters because the tempting fix for "access
denied writing to SYSVOL" is to grant change permission to a wider group, which is a domain-wide
mistake. DFSR replicates the folder regardless of what wrote to it, so clients still get the file.

Consequences of local staging:

- Run it **on a domain controller**. Off a DC there is no local path, so it falls back to the UNC and
  warns you; a denial there is the share permissions working as intended. Pass `-StagePath` for a
  share you own instead - the task path is rewritten to match.
- **Let DFSR replicate before testing.** A client authenticates to whichever DC it likes; if that DC
  has not replicated yet, the task fails with path not found. `repadmin /syncall /AdeP` to force it,
  `repadmin /showrepl` to check.
- The staged file is readable by every authenticated user in the domain and holds your auto-enrollment
  token. If that is not acceptable, stage to a share ACL'd to `Domain Computers` plus Administrators
  only, via `-StagePath '\\files01\patchmon$\scripts'`.

### 2. Attach the scheduled task (one GUI paste - no cmdlets exist for this)

1. `gpmc.msc` -> Forest: example.com -> Domains -> example.com -> Group Policy Objects
2. Right-click **PatchMon Agent Deployment** -> Edit
3. Computer Configuration > Preferences > Control Panel Settings > **Scheduled Tasks**
4. New > **Scheduled Task (At least Windows 7)** -> XML tab -> paste the generated XML -> OK
   (the task runs as `S-1-5-18` / LocalSystem)
5. Close the editor.

The task runs at boot (+5 min) and then daily around 03:15 with a 2-hour random delay, so a
large fleet does not stampede the server at the same second.

### 3. Test on one client

```powershell
gpupdate /force
schtasks /query /tn "PatchMon Agent Install" /v /fo LIST
schtasks /run   /tn "PatchMon Agent Install"
type C:\ProgramData\PatchMon\deploy.log
```

Then confirm the host appears in the PatchMon UI and the service is up:

```powershell
Get-Service PatchMonAgent
& "C:\Program Files\PatchMon\patchmon-agent.exe" --config C:\ProgramData\PatchMon\config.yml ping
```

### 4. Roll out

Move the GPO link onto the rest of your workstation/servers OUs. Machines pick it up on their next
policy refresh; nothing else to do. `gpresult /h report.html` on a client shows whether it landed.

## Path B - push without Group Policy

Useful for a pilot, for workgroup machines, or from Intune/PDQ/Ansible. `-RegisterScheduledTask`
makes the box keep itself healthy without any GPO at all:

```powershell
# copy the script over, then run it remotely
Copy-Item .\patchmon-agent-install.ps1 \\workstation01\C$\Windows\Temp\ -Force
Invoke-Command -ComputerName workstation01 -FilePath C:\Windows\Temp\patchmon-agent-install.ps1 -ArgumentList '-RegisterScheduledTask'

# or PsExec, from the DC
PsExec64 \\workstation01 -s -h powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\patchmon-agent-install.ps1 -RegisterScheduledTask
```

## Domain controllers (no agent)

Installing the agent binary on DCs is not permitted here, so DCs are covered differently:
`patchmon-dc-reporter.ps1` is a plain script that collects the same Windows Update data the agent
would and POSTs it to the same API endpoint, and `setup-patchmon-dcs.ps1` deploys it. Nothing is
installed on a DC - no service, no binary, no agent.

**Why this reports identically to a real agent:** the PatchMon agent is open source, and its Windows
collector is itself a PowerShell script (`Get-HotFix` for installed KBs, the Windows Update Agent
COM API for pending updates, two registry keys for reboot-pending). The reporter reproduces that
collection and posts a full report to `POST /api/v1/hosts/update` with the same `X-API-ID`/`X-API-KEY`
host credentials and the same JSON field names, so the DC shows up in the UI like any other host
(`osType: Windows`, `packageManager: windows`, installed/pending updates, reboot flag). Two protocol
details make this tractable: a report with no `sections` field is treated as a full report (only
requirement: a non-empty packages array), and the server only validates section hashes it actually
receives - so the reporter never has to reproduce the agent's canonical hashing or its
ping/hash-gate check-in loop.

**What a DC will NOT have:** third-party package inventory (the agent scans installed programs; the
reporter reports Windows Update only), remote patch installation from the UI, agent self-update, and
- depending on the DC - pending updates: the WUA COM API sometimes fails for non-interactive SYSTEM
sessions, and the reporter then degrades to installed-KBs-only and says so in
`C:\ProgramData\PatchMon-Reporter\report.log`. The PatchMon agent has the same limitation (it falls
back to a PowerShell module we may not install on DCs either).

**Deployment** (from an admin workstation or member server, never a DC; needs WinRM on the DCs -
no SMB/C$ admin share, so DCs hardened with admin shares disabled still work):

```powershell
# same three placeholders as the installer, then:
git update-index --skip-worktree setup-patchmon-dcs.ps1

.\setup-patchmon-dcs.ps1 -WhatIf      # enumerate DCs, show the plan
.\setup-patchmon-dcs.ps1              # enroll + stage + register task + first run
.\setup-patchmon-dcs.ps1 -Status      # task results and log tails on every DC
```

Per DC it: auto-enrolls **from the workstation** (the shared enrollment secret never reaches a DC;
the returned per-DC api_id/api_key are cached in `.\dc-credentials\`, which is gitignored - keep it
ACL'd to yourself), stages the reporter to `C:\Program Files\PatchMon-Reporter` and that DC's own
`config.json`/`credentials.json` to `C:\ProgramData\PatchMon-Reporter` (same code/data split as the
real agent), strips inherited NTFS ACLs on both so only SYSTEM and Administrators can read them
(this is why nothing goes through SYSVOL), registers a scheduled task as SYSTEM (boot +5 minutes,
daily 03:25, and every 30 minutes) and runs it once, reporting the exit result.

**Two "offline" badges, only one of which we can fix.** PatchMon shows two different statuses and
DCs behave differently in each:

- **Up / stale / down** is computed from `last_update`, refreshed by any accepted `/hosts/update`
  (threshold: 3x the configured update interval, default 60 min → offline after 3h). A once-daily
  report would leave DCs "offline" all day, so the task runs every 30 minutes and the reporter
  self-decides: a **heartbeat** - a coherent hostname-only partial report of a few hundred bytes
  that touches no inventory - keeps the badge green, and the full WUA collection runs every 12
  hours. `-Heartbeat` / `-Full` force either mode by hand.
- **WS Offline / "WebSocket Disconnected"** is the agent registry: the agent binary holds a live
  WebSocket (`/api/v1/agents/ws`) for server-initiated actions ("Update Now", patch wizard). A
  scheduled reporter holds no socket, so this badge stays Offline on reporter hosts - permanently,
  correctly, and harmlessly. It is the UI truthfully saying "interactive agent actions are not
  available on this DC", which is exactly the policy that kept the agent off DCs. Do not "fix" it
  with a persistent PowerShell daemon: that is an agent by another name, and a host that looks
  online but never executes commands is worse than one that honestly reports offline.

**Signing:** if your Default Domain Policy enforces AllSigned on DCs, the task's
`-ExecutionPolicy Bypass` is ignored and `patchmon-dc-reporter.ps1` must be signed before staging
(same cert as the installer). The setup script detects the enforced policy per DC and refuses to
pretend an unsigned file will work.

**Uninstall:** `.\setup-patchmon-dcs.ps1 -Uninstall` removes the task and folders; delete the host
records in the PatchMon UI yourself (the script holds no admin API credentials).

**Licence:** the reporter's collection logic and payload shapes are taken from the PatchMon agent
(`agent-source-code/internal/packages/windows.go`), Copyright (c) PatchMon contributors, under
AGPL-3.0-only. Those two files are therefore AGPL-3.0 covered work - attribution is in their headers.
Using them internally on your own network carries no further obligation; if you redistribute them,
the AGPL applies to them. The rest of this repository is unaffected.

## Code signing

Only `patchmon-agent-install.ps1` needs signing - the bootstrap token is no longer baked into a
separate static file, so there is one artefact to sign. Add `uninstall-patchmon-agent.ps1` if you
enforce signing on clients.

### Order matters: stage first, sign last

`deploy-patchmon-gpo.ps1` copies the installer into SYSVOL with `-Force`. If you sign your working
copy and *then* run that script, it overwrites the signed copy in SYSVOL with an unsigned one, and
clients refuse to run it. So either let the script sign for you - it signs before it copies, which
is the correct order:

```powershell
.\deploy-patchmon-gpo.ps1 -Domain example.com -OU 'OU=Workstations,DC=example,DC=com' -SignedCertThumbprint 'A1B2...'
```

or sign it yourself after everything else has run:

```powershell
$staged = '\\example.com\SYSVOL\example.com\scripts\patchmon\patchmon-agent-install.ps1'
Set-AuthenticodeSignature -FilePath $staged -Certificate $cert `
    -HashAlgorithm SHA256 -TimestampServer 'http://timestamp.digicert.com'
```

With manual signing, sign **after** `deploy-patchmon-gpo.ps1` and after the GPMC paste, and remember
that re-running that script for any reason undoes your signature. Signing is the last thing that
happens to the file: an edit, a re-save in another encoding, or a formatter pass afterwards all break
it. Sign a staging copy rather than your working copy if you want the repo copy to stay unsigned.

Check from a client, not from the DC:

```powershell
Get-AuthenticodeSignature $staged | Select-Object Status, StatusMessage, SignerCertificate
```

| Status | What happened |
| --- | --- |
| `NotSigned` | something copied an unsigned file over your signed one - re-sign |
| `HashMismatch` | the file changed after signing - re-sign |
| `Valid` | good, as long as the chain is trusted (below) |

### One-time certificate

```powershell
# A code-signing cert from your internal CA, or a self-signed one for a small estate
$cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Example PatchMon Deployment' `
    -CertStoreLocation Cert:\LocalMachine\My -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(3)
Export-Certificate -Cert $cert -FilePath C:\Users\Public\patchmon-signing.cer   # distribute this one
```

What makes clients accept the signature:

- **Code Signing EKU** (`1.3.6.1.5.5.7.3.3`). A TLS or authenticated-web-server cert is rejected
  client-side even if `Set-AuthenticodeSignature` accepted it locally.
- **A trusted chain.** A cert from an AD CS code-signing template is already trusted by every domain
  member. A self-signed cert is not: publish `patchmon-signing.cer` by GPO to **Trusted Root
  Certification Authorities** *and* **Trusted People** (or Trusted Publishers), then
  `gpupdate /force` on the client.
- **A timestamp** (`-TimestampServer`), so the signature survives cert expiry. That needs outbound
  HTTPS from the machine doing the signing; sign without it if you cannot reach a timestamping
  authority and accept that the signature dies with the cert.
- **Revocation has to be checkable.** If the cert is revoked, or the client cannot reach the CRL, a
  policy that requires trusted signatures can fail the run.

### Signing and execution policy

Signing does not by itself make anything run, and it does not fight the task's
`-ExecutionPolicy Bypass`:

- If nothing enforces signing, the task runs the script signed or unsigned. Signing is defence in
  depth and keeps AppLocker/AV quieter.
- If you enforce **AllSigned** / "Require signed scripts" by Group Policy, **`-ExecutionPolicy Bypass`
  on the command line is ignored** - a GPO-configured execution policy outranks the parameter. Then
  the signature must be trusted on every client, and the uninstaller must be signed too, because
  that is the one you run by hand.

### Never commit a signed script

The `# SIG # Begin signature block` trailer embeds your X.509 certificate, and your name and email
address are in it. Keep the repository copy unsigned; sign only the deployed copy. The pre-commit
scanner will **not** catch this: the signature block is base64, so none of the hostname or
credential rules fire on it. Check before committing:

```powershell
git show HEAD:patchmon-agent-install.ps1 | Select-String 'SIG # Begin' -Quiet   # must be False
```

## Exit codes and logs

`patchmon-agent-install.ps1` is safe to run on a loop - that is the whole design.

| Exit | Meaning |
| --- | --- |
| `0` | Installed and healthy, or was already installed (the normal daily outcome) |
| `1` | Enrollment, download, credential, config, service or connectivity failure |
| `2` | Auto-enrollment key/secret are still the placeholders |

- Deploy log: `C:\ProgramData\PatchMon\deploy.log` (installer decisions)
- Agent log: `C:\ProgramData\PatchMon\patchmon-agent.log` (what the agent itself does)

## config.yml and YAML quoting

`C:\ProgramData\PatchMon\config.yml` must use **single-quoted** values for Windows paths:

```yaml
patchmon_server: 'https://patchmon.example.com'
api_version: 'v1'
credentials_file: 'C:\ProgramData\PatchMon\credentials.yml'
log_file: 'C:\ProgramData\PatchMon\patchmon-agent.log'
log_level: 'info'
skip_ssl_verify: false
```

In YAML, a double-quoted scalar processes backslash escapes, so
`credentials_file: "C:\ProgramData\PatchMon\credentials.yml"` is invalid - `\c` is an unknown
escape - and some sequences are accepted but silently mangled. A literal apostrophe in a path is
written as two (`'C:\Users\O''Neil\...'`). The file is written without a BOM for the same reason.

Why this deserves care: when the agent cannot parse `config.yml` it does **not** stop. It prints a
warning, replaces the file with its own defaults - which have no `patchmon_server` - and carries on.
The host then never reports in and nothing looks broken. PatchMon's own installer has the same
single-quote rule, so this script matches it.

What the installer does with an existing file, rather than blindly keeping it:

- rewrites any double-quoted path into single quotes
- adds `patchmon_server` if it is missing (the signature of an agent-reset file)
- updates `patchmon_server` and `skip_ssl_verify` to match what the script was told, which is how an
  existing fleet moves from `http://host:3000` to `https://host` after you re-stage the installer
- treats an empty or blank file as absent and writes a fresh one
- refuses to continue (exit 1) if the file still would not parse, instead of letting the agent eat it

`tests/Run-Checks.ps1` executes that code directly - fresh write, repair of a broken file,
agent-reset file, empty file, path with an apostrophe - and fails if any key is lost. It also
checks the gate that decides whether an installed agent can skip the installer, because a gate
that is wrong in either direction either leaves a broken host alone or re-enrols healthy ones.

If a client is already stuck on defaults, just run the installer again - or wait for the daily task,
which now notices this by itself: the "already installed, nothing to do" exit only happens when
`config.yml` is present, parseable and pointing at `$ServerURL`. Anything else goes through the
repair path, which fixes the file, restarts the service and confirms with `patchmon-agent ping`
before deciding whether a full reinstall is needed. That is also how an existing fleet picks up a new
server URL after you re-stage the installer with HTTPS.

## TLS

Once HTTPS is on `patchmon.example.com`:

- Use a cert from your internal CA (or Let's Encrypt with a DNS name that resolves publicly).
  Windows clients already trust an AD CS-issued cert, so nothing else is needed on the clients.
- Keep `skip_ssl_verify: false`. Do **not** ship `-SkipSslVerify $true` permanently - it turns off
  the one thing protecting the API credentials in transit. It exists only for a quick self-signed
  cert experiment.
- If you must use a self-signed server cert temporarily, deploy the server's CA cert to clients'
  Trusted Root store via GPO instead of skipping verification.
- Switching URL is now just: change `$ServerURL` in the installer, re-stage to SYSVOL, and let the
  daily task run. The installer updates `patchmon_server` in an existing `config.yml` and restarts
  nothing it does not have to - see [config.yml and YAML quoting](#configyml-and-yaml-quoting). Only
  reach for `uninstall-patchmon-agent.ps1 -RemoveData` if a client's config is beyond repair.

## Keeping this repo public

The riskiest edit in this project is pasting your real auto-enrollment secret and real server name
into `patchmon-agent-install.ps1` (and `setup-patchmon-dcs.ps1`, which carries the same three
placeholders) and then committing it to a public repo. Two things stop that:

1. `.gitignore` keeps `SITE-SETTINGS.local.md`, any `*.local.md`, `reference/`, the DC credential
   cache `dc-credentials/` and all key material (`*.pfx`, `*.key`, `*.cer`, ...) out of the repository.
2. `tests/Check-NoSecrets.ps1` scans what you are about to commit for credential-looking literals,
   RFC1918 addresses and internal DNS names (`*.local`, `*.lan`, `*.internal`, ...) and fails the
   commit when it finds one.

Turn the hook on once per clone:

```powershell
git config core.hooksPath .githooks
pwsh -File tests/Check-NoSecrets.ps1 -All   # scan the whole tree once
```

A genuine false positive can be annotated with `#nosecret` on that line. Do not reach for
`git commit --no-verify` to get past a real finding - if a value only makes sense on your network,
it belongs in an ignored file.

And when you link this work back to PatchMon issue #721, paste the scrubbed `example.com` version of
the script. Every pushed commit stays publicly readable even after you delete it, so if a token ever
does land here, rotate it in PatchMon first and rewrite history second.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `deploy.log` says enrollment failed HTTP 401/403 | Wrong/expired auto-enrollment key or secret |
| Enrollment failed HTTP 409 | A host record with this computer name already exists and won't re-issue creds. Delete the stale record in PatchMon, or pass `-Force` to reinstall |
| Download fails, bootstrap fallback also fails | Agent binary not available for this OS/arch on the server, or a proxy is blocking the download |
| Service created but not running | `Get-Content C:\ProgramData\PatchMon\patchmon-agent.log -Tail 50` - usually bad `config.yml` or the server is unreachable from that box |
| Task never appears on the client | `gpresult /h report.html`; check the GPO link/WMI filtering and that the SYSVOL path is readable by `Domain Computers` |
| Task fails with "path not found" on some clients only | SYSVOL has not replicated to the DC that client authenticates to: `repadmin /showrepl`, then `repadmin /syncall /AdeP` |
| Helper warns it is using the current directory | You pasted the script into a console, `Invoke-Expression`'d it, or shipped it with `Invoke-Command -FilePath`, so there is no script folder to work from. Run the file, or pass `-SourceDir` |
| Task exists but fails with "Access is denied" reading the script | SYSVOL share permissions, or the script was copied somewhere other than `\\example.com\SYSVOL\example.com\scripts\patchmon\` |
| Agent installs then vanishes | Something (AppLocker/WDAC/AV) is quarantining the binary - allow-list `C:\Program Files\PatchMon` |

## Uninstall

```powershell
# from the client
.\uninstall-patchmon-agent.ps1 -DryRun
.\uninstall-patchmon-agent.ps1 -RemoveData
```

It removes the daily task first, otherwise Group Policy just reinstalls the agent on the next run.
