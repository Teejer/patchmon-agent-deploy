# PatchMon deployment notes

Project record: what was built, what was deployed, what was learned.
Sanitized for a public repo - no internal hostnames, addresses, or credentials.

## What PatchMon is

[PatchMon](https://github.com/PatchMon/PatchMon) (AGPL-3.0) is a patch-monitoring
server: hosts report installed/pending updates to it over its HTTP API, and the
UI rolls that up into a fleet patch dashboard. Hosts authenticate to the API with
a per-host `X-API-ID` / `X-API-KEY` pair, obtained either from the UI or from the
shared auto-enrollment key/secret.

## What we deployed

### 1. The server (Sep 23)

Dedicated Ubuntu host, Docker in rootless mode, PatchMon deployed via its
docker-compose stack. Currently plain HTTP behind an internal name; the planned
end state is HTTPS (see Open items).

### 2. The agent on member servers (Sep 25)

The official agent binary, deployed fleet-wide by Group Policy rather than
push installs:

- `patchmon-agent-install.ps1` - installer: downloads the agent, installs it as
  the `PatchMonAgent` service, auto-enrolls the host, writes `config.yml`.
- `deploy-patchmon-gpo.ps1` - workstation-side helper that creates/links the GPO
  which runs the installer as a scheduled task (boot +5 min, daily). A host that
  enrolls once keeps reporting; a host that was ever in scope self-repairs.
- Rollout tiers: Tier 2 first (verified end-to-end), then Tier 1 and Tier 0 with
  the same GPO method. Domain controllers deliberately excluded - see below.

Not everything went smoothly, and the scars are documented:

- **config.yml YAML bug.** The installer originally wrote Windows paths as
  double-quoted YAML scalars; the backslashes made the file unparseable and the
  agent *silently reset itself to defaults* and stopped reporting. Fixed by
  writing single-quoted scalars, plus a self-heal path so already-installed hosts
  repair their config (and pick up server URL changes) on the next daily task
  run. Regression tests cover it (`tests/Run-Checks.ps1`).
- **Upstream.** A writeup of the YAML bug with the fixed script was posted to
  PatchMon issue #721.
- **Signing.** Scripts are code-signed with our own cert before staging; signed
  files are never committed (the signature block embeds cert identity).
- **Leak hygiene.** The repo is public; a pre-commit scanner
  (`tests/Check-NoSecrets.ps1`) blocks secrets and site-internal identifiers.
  It has earned its keep - it caught real leaks before they were committed.

### 3. Domain controllers - agent-less reporter (Sep 25)

Policy: DCs may not run the agent binary. They still have to report. So we built
a PowerShell reimplementation of the agent's reporting side, and it is deployed
on every DC.

- `patchmon-dc-reporter.ps1` (runs on the DC, as SYSTEM, no software installed):
  collects the same data the agent reports - installed KBs (Get-HotFix), pending
  updates (Windows Update Agent COM), reboot state - and posts a full report to
  the same `/api/v1/hosts/update` API with the same per-host credentials.
  Degrades honestly: if WUA COM fails (e.g. the DC's WSUS path is broken) it
  still delivers the installed-KB report and logs why pending updates are
  missing. Exit codes: 0 reported, 1 failed, 2 not configured.
- `setup-patchmon-dcs.ps1` (runs from an admin workstation, never on a DC):
  - Enrolls each DC with auto-enrollment **from the workstation**, so the shared
    enrollment secret never lands on a DC. Per-DC api_id/api_key are cached in
    `.\dc-credentials\` (gitignored); re-runs reuse them.
  - Stages the reporter + that DC's own `config.json`/`credentials.json` **over
    the WinRM session itself** - no SMB/admin-share dependency. Code goes to
    `C:\Program Files\PatchMon-Reporter`, credentials to
    `C:\ProgramData\PatchMon-Reporter` (same code/data split as the real agent),
    NTFS inheritance stripped on both so only SYSTEM/Administrators can read
    them. Nothing goes through SYSVOL.
  - Registers the scheduled task (boot +5 min, daily 03:25) and runs it once.
  - `-WhatIf` / `-Status` / `-Uninstall` / `-RefreshCredentials` / `-Dcs` /
    `-TaskUser` for the rest of the lifecycle.

Deployed and verified reporting end-to-end on all DCs.

## Things we learned the hard way (or read in the server source first)

**Two "offline" badges, and only one is ours to fix.**

- *Up / stale / down* comes from `last_update` vs 3x the configured update
  interval (default 60 min -> offline after 3 quiet hours). A once-daily report
  means DCs read offline most of the day. **Accepted**: the data is at most 24h
  old and nothing decides off that badge. `setup-patchmon-dcs.ps1 -Heartbeat30m`
  exists if that ever changes - it makes the task fire every 30 min and the
  reporter self-decides between a hostname-only heartbeat partial (a few hundred
  bytes, cannot touch inventory) and the full collection (every 12h).
- *WS Offline / "WebSocket Disconnected"* is the agent registry: the agent binary
  holds a permanently open WebSocket to the server for interactive actions
  ("Update Now", patch wizard). A scheduled script holds no socket, so this badge
  stays Offline on reporter hosts - permanently, correctly, harmlessly. That
  always-on connection to a DC is exactly what we do *not* want, so the badge is
  the UI agreeing with our policy. Do not "fix" it with a persistent PowerShell
  daemon; that is an agent by another name.

**PS 5.1 traps that bit us during development** (all now covered by tests):

- `ConvertTo-Json` turns single-element arrays into bare objects - the reporter
  uses a custom serializer, otherwise a one-category WUA response 400s.
- Double-quoted YAML scalars eat backslashes (the config.yml bug above).
- `Set-Content -Encoding UTF8` writes a BOM; JSON files are written with
  `UTF8Encoding($false)` instead.

**The server API is forgiving in useful ways** (verified against upstream
source): a full report only needs a non-empty `packages` array; identity fields
are COALESCEd; hashes are validated only when present; unclaimed sections of a
partial report are never overwritten. That is what makes both the heartbeat
design and "report what you can collect" degradation safe.

**WUA health is per-DC and worth watching.** The first pilot DC logged
`WUA COM unavailable (0x80244010)` - a Windows Update <-> WSUS communication
fault that predated any of our software. The reporter surfaced a real problem.
Diagnosis recipe is in the README; a DC in that state still reports installed
KBs, just not pending updates.

## Current state (end of Sep 25)

- PatchMon server: live (HTTP; TLS pending).
- Tier 2 / Tier 1 / Tier 0 member servers: agent rolling out via GPO scheduled
  task; Tier 2 verified enrolled and reporting.
- All DCs: agent-less reporter deployed, reporting daily as SYSTEM.
- One DC had the agent installed by accident: removed (`sc.exe delete
  PatchMonAgent` + uninstall script + host record cleanup).
- Repo: all offline checks pass (`pwsh tests/Run-Checks.ps1`); public copies
  leak-scanned clean.

## Open items

1. **TLS migration** - move the server to HTTPS. The installer's self-heal path
   repairs `patchmon_server` in existing agent configs on the next daily run;
   DCs need only a `config.json` rewrite (or a one-off `-SkipCertificateCheck`
   run of setup).
2. **GPO scope guard for DCs** - the accidental agent install on a DC came from
   GPO reach. Deny "Apply group policy" for Domain Controllers on the PatchMon
   GPO (or keep the link on member OUs only), and sweep DCs for any agent that
   slipped in before the guard.
3. **WSUS health** on the staging DC(s) showing `0x80244010` - until fixed,
   those DCs report installed KBs only.
4. If the Up/stale badge ever starts mattering: `-Heartbeat30m`.

## Where things live

| Piece | Location |
| --- | --- |
| Agent installer / GPO deployer / uninstaller | `patchmon-agent-install.ps1`, `deploy-patchmon-gpo.ps1`, `uninstall-patchmon-agent.ps1` |
| DC reporter + deployer | `patchmon-dc-reporter.ps1`, `setup-patchmon-dcs.ps1` |
| Offline tests / leak scanner | `tests/Run-Checks.ps1`, `tests/Check-NoSecrets.ps1` + `.githooks/pre-commit` (re-enable per clone: `git config core.hooksPath .githooks`) |
| Full runbook | `README.md` |
| Real server URL / enrollment values | local only, never in the repo |
