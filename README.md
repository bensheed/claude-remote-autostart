# claude-remote-autostart

[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/bensheed/claude-remote-autostart)

PowerShell wrapper that keeps `claude remote-control` running on Windows. Auto-launches at logon via Task Scheduler with unique session names, restarts on crash with exponential backoff, enforces a per-hour launch ceiling and cross-restart giveup cooldown so transient bridge-API outages don't become a 60/hr relaunch hammer.

## What it does

- Starts `claude remote-control` at Windows logon via Task Scheduler, hidden.
- Passes `--remote-control-session-name-prefix <HOSTNAME>-auto` so each launch gets a unique, collision-free session name in claude.ai/code.
- Passes `--permission-mode auto` so the remote session doesn't stall on permission prompts.
- Watches for `TCP:443 Established` and process lifetime; only marks a launch "healthy" after it survives several minutes.
- **Detects and recycles "ghost" sessions** — a session that keeps a TCP:443 connection and keeps getting `200` from `/work/poll` while the *environment* it registered has been dropped server-side, so it is network-alive but invisible/unresponsive on claude.ai. Two always-on defenses plus an optional fallback: (a) clears the bridge environment pointer before every launch so each session registers a brand-new environment instead of silently reusing a dead one; (b) the primary detector watches `debug.log` for a *mid-session* environment reuse (the ghost signature) using an **offset-based incremental scan** — it tracks a byte cursor rather than a fixed tail window, so a one-time marker can never scroll out of view before it's seen, and recycles immediately; (c) an **optional, off-by-default** lifetime cap (`MaxSessionLifetimeSeconds`) that recycles only when the session is also *idle*, so it never kills a conversation in flight. A recycle of a session that had become healthy (its environment was dropped while working) relaunches without backoff; a session that *ghosts before ever becoming healthy* is treated as a broken environment and escalates through the normal backoff → giveup path, so it can't relaunch at the hourly ceiling forever.
- On unhealthy exits: exponential backoff (30s → 60s → 120s → ... → 900s).
- After N consecutive unhealthy launches: writes a `lastGiveupAt` marker and exits cleanly so Task Scheduler's `RestartOnFailure` policy does not immediately relaunch. A persistent 30-minute cooldown is enforced across wrapper restarts.
- Enforces a hard ceiling of 20 launches per rolling hour, independent of backoff, to defend against any bug that could bypass the exponential pacing.

## Requirements

- Windows 10/11
- [Claude Code](https://code.claude.com) installed as a global npm package (`npm i -g @anthropic-ai/claude-code`)
- Node.js at `C:\Program Files\nodejs\node.exe` (default installer path — change `$nodeExe` in the script if yours differs)
- You have already run `claude` once in the directory you want to control, accepted the workspace trust dialog, and signed in with a subscription-bearing account. The OAuth token is stored in your user profile and must be present for `remote-control` to boot.

## Install

[![Install with Claude](https://img.shields.io/badge/Install%20with-Claude-d97706?style=for-the-badge)](https://bensheed.github.io/claude-remote-autostart/install-ux/index.html)

The badge above hands this repo to Claude Code (or Claude Desktop) and asks it to install and set everything up for you. Or follow the manual steps below.

### 1. Drop the script

```powershell
$dest = Join-Path $env:USERPROFILE '.claude\remote-control-wrapper.ps1'
New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/bensheed/claude-remote-autostart/main/remote-control-wrapper.ps1' -OutFile $dest
```

Or clone this repo and copy `remote-control-wrapper.ps1` to `~\.claude\remote-control-wrapper.ps1`.

### 2. Register the Task Scheduler task

Run this as your own user (not elevated — `remote-control` needs to run under your logon, not SYSTEM, because it reads your OAuth token from your profile):

```powershell
$wrapper = Join-Path $env:USERPROFILE '.claude\remote-control-wrapper.ps1'
$action  = New-ScheduledTaskAction `
    -Execute 'powershell.exe' `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $wrapper) `
    -WorkingDirectory $env:USERPROFILE

$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"

$principal = New-ScheduledTaskPrincipal `
    -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive `
    -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 10)

Register-ScheduledTask `
    -TaskName 'ClaudeRemoteControl' `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Auto-starts claude remote-control at logon with crash recovery and rate-limit safeguards.'
```

The `RestartCount 999 / RestartInterval PT10M` settings only matter if the wrapper itself crashes with a non-zero exit (e.g. PowerShell bug) — in that case Windows will retry up to 999 times, 10 minutes apart. The wrapper's own giveup path uses `exit 0`, which does **not** trigger `RestartOnFailure`, so you won't see the retry-on-failure behaviour during normal API outages.

### 3. First run

```powershell
Start-ScheduledTask -TaskName 'ClaudeRemoteControl'
Start-Sleep -Seconds 10
Get-Content "$env:USERPROFILE\.claude\remote-control-logs\wrapper.log" -Tail 15
```

You should see lines like:

```
wrapper starting (SessionNamePrefix='<HOST>-auto' PermissionMode='auto' PID=<n>)
Launching (attempt, quickExitCount=0, lastHour=0): ...
Started node PID <n>
Healthy: TCP:443 established and process lived 300s for PID <n>
```

The "Healthy" line shows up ~5 minutes after launch — that's the threshold the wrapper uses to decide a session is really working rather than superficially handshaking then dying.

Your machine will appear in the list at <https://claude.ai/code> under the name `<HOSTNAME>-auto-<something>`.

## Configuration

All tuning knobs are script parameters — override them by editing the task action's `-Argument` string, e.g. `-File "..." -MaxLaunchesPerHour 10`:

| Parameter | Default | Purpose |
| --- | --- | --- |
| `SessionNamePrefix` | `$env:COMPUTERNAME-auto` | Passed as `--remote-control-session-name-prefix`; the CLI appends a unique suffix per launch. |
| `PermissionMode` | `auto` | Passed as `--permission-mode`; requires `permissions.defaultMode: "auto"` and `skipAutoPermissionPrompt: true` in `~/.claude/settings.json` if your account's auto-mode dialog hasn't been accepted yet. |
| `HealthyLifetimeSeconds` | `300` | Minimum process lifetime before a launch counts as "healthy" and resets the backoff. Keep high — TCP:443 alone is not a reliable signal. |
| `BaseCooldownSeconds` | `30` | First backoff interval after an unhealthy exit. |
| `MaxCooldownSeconds` | `900` | Cap on exponential backoff (15 min). |
| `MaxConsecutiveFailures` | `8` | After this many unhealthy launches in a row, the wrapper gives up, writes `state.json.lastGiveupAt`, and `exit 0`s. |
| `GiveupCooldownSeconds` | `1800` | Minimum idle window after a giveup, enforced across wrapper restarts. |
| `MaxLaunchesPerHour` | `20` | Hard ceiling, enforced via the persistent launches list. Applies no matter what else the script does. |
| `StallSeconds` | `120` | If TCP:443 drops for longer than this after the session was healthy, kill and relaunch. |
| `MaxSessionLifetimeSeconds` | `0` (off) | Optional fallback recycle for a ghost the detector somehow misses. When set, a session is recycled once it has lived this long **and** is idle (see `IdleRecycleSeconds`). Off by default — the offset-based reuse detector is the real defense, and a fixed-clock kill would otherwise risk interrupting an active session. |
| `IdleRecycleSeconds` | `600` | How long with no bridge-transcript activity before a session counts as idle (and therefore safe for the lifetime cap to recycle). |
| `GhostReuseGraceSeconds` | `60` | Ignore environment-reuse markers in `debug.log` within this many seconds of launch (they belong to the initial registration, not a ghost reconnect). |

## Logs and state

All in `~\.claude\remote-control-logs\`:

- `wrapper.log` — one line per wrapper event (launch, health, cooldown, giveup). Rotates at 10 MB.
- `output.log` / `output.err` — captured stdout/stderr of the most recent `claude remote-control` child.
- `debug.log` — the CLI's own `--debug-file` output; useful for diagnosing bridge registration.
- `child.pid` — PID of the current child, used for clean reaping on restart.
- `state.json` — persistent `lastGiveupAt` timestamp and rolling list of launch timestamps. Delete to reset all rate-limit state.
- `bridge-transcript-<session>.jsonl` — per-session conversation transcript written by the CLI (next to `--debug-file`, i.e. here). Their modification time is the idle signal for the optional lifetime cap; the idle check fails closed (does not recycle) if none are found.

The wrapper also moves the CLI's bridge environment pointer (`~\.claude\projects\<encoded-cwd>\bridge-pointer.json`) to `bridge-pointer.json.prev` before each launch, forcing a fresh environment registration.

## Troubleshooting

**Wrapper starts but child dies within ~15s, `output.err` says `Error: timeout of 15000ms exceeded`.** The CLI's POST to `/v1/environments/bridge` is timing out. If this was preceded by many failed launches, you've likely tripped server-side rate limiting on new bridge registrations — wait 20-30 minutes and the wrapper's backoff + `GiveupCooldownSeconds` cooldown will handle the rest.

**Wrapper logs `FATAL: node.exe not at ...` or `FATAL: cli.js not at ...`.** Edit the hard-coded paths near the top of `remote-control-wrapper.ps1` to match your install, or install Node.js / `@anthropic-ai/claude-code` in the default locations.

**`claude remote-control` launches but the machine never shows up at claude.ai/code.** Usually either (a) your account isn't signed in under this Windows user profile — run `claude` interactively once to confirm, or (b) the CLI never successfully registered because the bridge-registration call is failing — check `debug.log` for `[bridge:api]` entries.

**The session shows as connected locally (`wrapper.log` says healthy, `debug.log` shows `/work/poll -> 200`) but it's missing or unresponsive at claude.ai/code.** This is a "ghost" session — the environment it registered was dropped server-side but the client keeps polling it. Look in `debug.log` for `[bridge:init] Found prior environment ... requesting reuse on registration` appearing *after* a launch. The wrapper now detects this and recycles automatically (`GHOST: detected mid-session environment reuse` in `wrapper.log`), and clears the bridge pointer before each launch so it can't recur. To force a clean session immediately, restart the task: `Stop-ScheduledTask -TaskName 'ClaudeRemoteControl'; Start-ScheduledTask -TaskName 'ClaudeRemoteControl'` (note the CLI child is detached, so the running wrapper reaps the old PID from `child.pid` on its next loop).

**Everything looks fine but a scheduled reboot doesn't bring the session back.** Task Scheduler's `AtLogOn` trigger requires the user to actually be logged in. For unattended-boot recovery (e.g. power outage on a headless machine), enable Windows auto-login via `netplwiz` (uncheck "Users must enter a username and password to use this computer…" and enter your password when prompted). The scheduled task fires as soon as auto-login completes.

## Uninstall

```powershell
Stop-ScheduledTask -TaskName 'ClaudeRemoteControl' -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName 'ClaudeRemoteControl' -Confirm:$false
Remove-Item "$env:USERPROFILE\.claude\remote-control-wrapper.ps1" -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\.claude\remote-control-logs" -Recurse -ErrorAction SilentlyContinue
```

## Notes

- This wrapper is user-made tooling, not part of Anthropic's Claude Code distribution. It depends on CLI surface (`claude remote-control --remote-control-session-name-prefix`, `--permission-mode`, `--debug-file`) that the CLI currently supports but could change in a future release.
- Tested against Claude Code CLI on Windows 10/11. PowerShell 5.1+ required.
