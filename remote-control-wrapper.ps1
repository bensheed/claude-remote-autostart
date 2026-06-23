param(
    # The CLI prefix passed as --remote-control-session-name-prefix. The CLI
    # appends its own unique suffix per launch so the full session name is
    # collision-free, even when an interactive `/remote-control` session
    # from the same machine is already registered under "<hostname>".
    [string]$SessionNamePrefix       = "$env:COMPUTERNAME-auto",
    [string]$PermissionMode          = 'auto',
    [int]$GraceSeconds               = 60,
    [int]$StallSeconds               = 120,
    [int]$BaseCooldownSeconds        = 30,
    [int]$MaxCooldownSeconds         = 900,
    # The CLI bridge register call frequently returns healthy-looking status
    # (TCP:443 established) within seconds but dies before doing any useful
    # work. A multi-minute floor on "healthy" prevents the wrapper from
    # resetting its quickExitCount too early and drifting into a crash-loop.
    [int]$HealthyLifetimeSeconds     = 300,
    # Proactively recycle a session after this long even if it looks healthy.
    # A remote-control session can keep a TCP:443 connection open and keep
    # getting HTTP 200 from /work/poll while the *environment* it registered
    # has been dropped server-side — a "ghost" that is network-alive but
    # invisible/unresponsive on claude.ai. Recycling on a fixed lifetime
    # bounds how long such a ghost can persist and keeps the registration
    # fresh. Set to 0 to disable.
    [int]$MaxSessionLifetimeSeconds  = 21600,
    # When detecting a mid-session environment *reuse* (the signature of a
    # ghost re-registration), ignore reuse markers within this many seconds
    # of launch — they belong to the initial registration, not a reconnect.
    [int]$GhostReuseGraceSeconds     = 60,
    [int]$MaxConsecutiveFailures     = 8,
    # Hard per-hour ceiling on launches, enforced across wrapper restarts
    # via a persisted history file. Independent of the exponential backoff
    # so that a bug or a Task-Scheduler-driven restart can't bypass it.
    [int]$MaxLaunchesPerHour         = 20,
    # After the wrapper gives up (hit MaxConsecutiveFailures), stay idle
    # for at least this long before any new launch attempt, even if the
    # wrapper process itself was restarted (by Task Scheduler or manually).
    [int]$GiveupCooldownSeconds      = 1800
)

$ErrorActionPreference = 'Continue'

$nodeExe = 'C:\Program Files\nodejs\node.exe'
$cliJs   = Join-Path $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code\cli.js'

$logDir     = Join-Path $env:USERPROFILE '.claude\remote-control-logs'
$null       = New-Item -ItemType Directory -Force -Path $logDir
$wrapperLog = Join-Path $logDir 'wrapper.log'
$outputLog  = Join-Path $logDir 'output.log'
$errorLog   = Join-Path $logDir 'output.err'
$debugLog   = Join-Path $logDir 'debug.log'

# Track the PID of the child we launched so the next wrapper iteration
# (or a Task-Scheduler-triggered restart after the wrapper itself died)
# can reap it without touching unrelated `/remote-control` sessions the
# user may have started interactively from the same machine.
$pidFile = Join-Path $logDir 'child.pid'

# The bridge pointer records the last environment id so a restarted session
# can re-register under the same environment. Reusing a *live* environment is
# fine, but reusing one the server has already dropped is exactly how a
# session becomes a ghost (keeps polling 200 but is invisible on claude.ai).
# We clear this before every launch so each session registers fresh. Derived
# from the working dir ($env:USERPROFILE) the same way the CLI encodes project
# dirs: replace ':' and '\' with '-'.
$bridgePointer = Join-Path $env:USERPROFILE (".claude\projects\" + ($env:USERPROFILE -replace '[:\\]','-') + "\bridge-pointer.json")

# Persistent state so launch-rate and giveup decisions survive a wrapper
# crash or a Task-Scheduler-driven restart. Without this, each new
# wrapper instance starts with a clean `quickExitCount` and can resume
# hammering the Anthropic bridge API right after the previous wrapper
# exhausted its budget — which is how we tripped server-side rate
# limiting earlier today.
$stateFile = Join-Path $logDir 'state.json'

function Read-State {
    if (-not (Test-Path $stateFile)) { return @{ lastGiveupAt = $null; launches = @() } }
    try {
        $raw = Get-Content $stateFile -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        return @{
            lastGiveupAt = $obj.lastGiveupAt
            launches     = @($obj.launches) | Where-Object { $_ }
        }
    } catch {
        return @{ lastGiveupAt = $null; launches = @() }
    }
}

function Write-State($state) {
    try {
        # Keep only the last 200 launch timestamps — more than enough to
        # compute a 1-hour rolling window, bounded file size.
        $launches = @($state.launches) | Select-Object -Last 200
        $payload = @{
            lastGiveupAt = $state.lastGiveupAt
            launches     = $launches
        } | ConvertTo-Json -Compress
        Set-Content -Path $stateFile -Value $payload -ErrorAction Stop
    } catch {
        Write-WrapLog "Warning: failed to write state file: $_"
    }
}

function Get-RecentLaunchCount($state, [int]$windowSeconds) {
    $cutoff = (Get-Date).ToUniversalTime().AddSeconds(-$windowSeconds)
    $count = 0
    foreach ($t in $state.launches) {
        try {
            $dt = [DateTime]::Parse($t).ToUniversalTime()
            if ($dt -gt $cutoff) { $count++ }
        } catch {}
    }
    return $count
}

function Write-WrapLog([string]$msg) {
    # Add-Content on Windows fails with IOException if any other process has
    # the target file open without FILE_SHARE_WRITE — Git Bash's tail.exe,
    # some antivirus mid-scan, and Windows Backup all do this. With the PS
    # host running -WindowStyle Hidden we have no stderr, so a failed
    # Add-Content would otherwise be silent and look like "wrapper running
    # but not logging" on diagnosis. Retry briefly, then fall back to a
    # sibling file so messages are not lost.
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$ts  $msg"
    for ($i = 0; $i -lt 5; $i++) {
        try {
            Add-Content -Path $wrapperLog -Value $line -ErrorAction Stop
            return
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 200
        } catch {
            break
        }
    }
    try {
        Add-Content -Path "$wrapperLog.fallback" -Value "$line  (written to fallback; primary log was locked)" -ErrorAction SilentlyContinue
    } catch { }
}

function QuoteArg([string]$s) { '"' + ($s -replace '"','\"') + '"' }

foreach ($path in @($wrapperLog, $outputLog, $errorLog, $debugLog)) {
    if ((Test-Path $path) -and ((Get-Item $path).Length -gt 10MB)) {
        Move-Item -Force $path "$path.old"
    }
}

Write-WrapLog '=========================================='
Write-WrapLog "wrapper starting (SessionNamePrefix='$SessionNamePrefix' PermissionMode='$PermissionMode' PID=$PID PS=$($PSVersionTable.PSVersion))"

if (-not (Test-Path $nodeExe)) { Write-WrapLog "FATAL: node.exe not at $nodeExe"; exit 1 }
if (-not (Test-Path $cliJs))   { Write-WrapLog "FATAL: cli.js not at $cliJs";   exit 1 }

function Kill-PidFromFile {
    if (-not (Test-Path $pidFile)) { return }
    try {
        $stalePid = [int](Get-Content $pidFile -Raw -ErrorAction Stop).Trim()
    } catch { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue; return }
    $stale = Get-CimInstance Win32_Process -Filter "ProcessId=$stalePid" -ErrorAction SilentlyContinue
    if ($stale -and $stale.Name -eq 'node.exe' -and $stale.CommandLine -like '*remote-control*') {
        Write-WrapLog "Killing stale remote-control PID $stalePid (from $pidFile)"
        Stop-Process -Id $stalePid -Force -ErrorAction SilentlyContinue
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

function Clear-BridgePointer {
    # Remove the stale environment pointer so the next launch registers a
    # fresh environment instead of reusing one that may already be dead.
    if (Test-Path $bridgePointer) {
        try {
            Move-Item -Force $bridgePointer "$bridgePointer.prev" -ErrorAction Stop
            Write-WrapLog "Cleared bridge pointer (forcing fresh environment registration)"
        } catch {
            Write-WrapLog "Warning: could not clear bridge pointer: $_"
        }
    }
}

function Test-GhostReuse {
    # A ghost session re-registers mid-flight by reusing a prior environment.
    # Because we clear the pointer before launch, the only way a reuse marker
    # appears after $afterUtc is an in-process reconnect onto a (possibly
    # dead) environment — treat that as a ghost and signal a recycle.
    param([datetime]$afterUtc)
    if (-not (Test-Path $debugLog)) { return $false }
    try {
        $tail = Get-Content $debugLog -Tail 60 -ErrorAction Stop
    } catch { return $false }
    foreach ($line in $tail) {
        if ($line -notmatch 'Found prior environment|requesting reuse on registration') { continue }
        if ($line -match '^(?<ts>\d{4}-\d{2}-\d{2}T[\d:.]+Z)') {
            try {
                $ts = [DateTime]::Parse($matches.ts).ToUniversalTime()
                if ($ts -gt $afterUtc) { return $true }
            } catch {}
        }
    }
    return $false
}

Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action {
    try {
        $pf = $using:pidFile
        if (Test-Path $pf) {
            $p = [int](Get-Content $pf -Raw -ErrorAction SilentlyContinue).Trim()
            if ($p -gt 0) { Stop-Process -Id $p -Force -ErrorAction SilentlyContinue }
            Remove-Item $pf -Force -ErrorAction SilentlyContinue
        }
    } catch {}
} | Out-Null

$state = Read-State

# Persistent giveup cooldown: honour the last wrapper's decision to stop
# hammering even though this is a fresh PS process with no in-memory
# quickExitCount.
if ($state.lastGiveupAt) {
    try {
        $since = [int]((Get-Date).ToUniversalTime() - [DateTime]::Parse($state.lastGiveupAt).ToUniversalTime()).TotalSeconds
        if ($since -ge 0 -and $since -lt $GiveupCooldownSeconds) {
            $remaining = $GiveupCooldownSeconds - $since
            Write-WrapLog "Previous wrapper instance gave up ${since}s ago; enforcing giveup cooldown, sleeping ${remaining}s."
            Start-Sleep -Seconds $remaining
        }
        # Clear the giveup marker once we've observed the cooldown so the
        # next failure path can set a fresh one.
        $state.lastGiveupAt = $null
        Write-State $state
    } catch {
        Write-WrapLog "Warning: could not parse lastGiveupAt='$($state.lastGiveupAt)': $_"
    }
}

$quickExitCount = 0

while ($true) {
    # Global rate ceiling — enforced across wrapper restarts. If we are
    # at or above the hourly cap, sleep until the oldest launch in the
    # window falls off. Safety net against any bug that could otherwise
    # iterate the loop faster than the exponential backoff.
    $state = Read-State
    $recentCount = Get-RecentLaunchCount $state 3600
    if ($recentCount -ge $MaxLaunchesPerHour) {
        $oldest = [DateTime]::Parse(@($state.launches)[0]).ToUniversalTime()
        $wait = 3600 - [int]((Get-Date).ToUniversalTime() - $oldest).TotalSeconds + 5
        if ($wait -lt 30) { $wait = 30 }
        Write-WrapLog "Rate ceiling hit: $recentCount launches in last hour (cap=$MaxLaunchesPerHour); sleeping ${wait}s."
        Start-Sleep -Seconds $wait
    }
    # Reap any previous child of this wrapper. Matching on a PID we wrote
    # to disk (rather than grepping command lines for a session name)
    # means we never kill interactive `/remote-control` sessions the user
    # may have started from the same machine.
    Kill-PidFromFile
    Start-Sleep -Seconds 2

    # Dropping --name lets the CLI auto-generate a unique session name
    # using --remote-control-session-name-prefix; this was added to claude
    # remote-control specifically so wrappers like this one can avoid the
    # "name already registered" 500 from /v1/environments/bridge.
    $argList = @(
        (QuoteArg $cliJs),
        'remote-control',
        '--remote-control-session-name-prefix', (QuoteArg $SessionNamePrefix),
        '--permission-mode', (QuoteArg $PermissionMode),
        '--debug-file', (QuoteArg $debugLog)
    )

    # Force a fresh environment registration each launch so a server-dropped
    # environment can never be silently reused into a ghost session.
    Clear-BridgePointer

    Write-WrapLog "Launching (attempt, quickExitCount=$quickExitCount, lastHour=$recentCount): $nodeExe $($argList -join ' ')"
    $launchTime = Get-Date
    $launchTimeUtc = $launchTime.ToUniversalTime()
    # Record the launch in persistent state BEFORE starting, so even a
    # crash between Start-Process and the state write cannot under-count.
    $state.launches = @(@($state.launches) + $launchTime.ToUniversalTime().ToString('o'))
    Write-State $state
    try {
        $proc = Start-Process -FilePath $nodeExe -ArgumentList $argList `
            -WorkingDirectory $env:USERPROFILE `
            -RedirectStandardOutput $outputLog `
            -RedirectStandardError  $errorLog `
            -WindowStyle Hidden -PassThru -ErrorAction Stop
    } catch {
        Write-WrapLog "Failed to start: $_"
        $quickExitCount++
        $cooldown = [Math]::Min($BaseCooldownSeconds * [Math]::Pow(2, $quickExitCount - 1), $MaxCooldownSeconds)
        Write-WrapLog "Cooldown ${cooldown}s (launch failure)"
        Start-Sleep -Seconds $cooldown
        continue
    }

    Write-WrapLog "Started node PID $($proc.Id)"
    try { Set-Content -Path $pidFile -Value $proc.Id -ErrorAction Stop } catch {
        Write-WrapLog "Warning: failed to write PID file $pidFile : $_"
    }
    $lastHealthy  = $null
    $everHealthy  = $false
    $graceUntil   = (Get-Date).AddSeconds($GraceSeconds)
    $reason       = $null

    while (-not $proc.HasExited) {
        Start-Sleep -Seconds 15
        $established = Get-NetTCPConnection -OwningProcess $proc.Id -State Established -ErrorAction SilentlyContinue |
            Where-Object RemotePort -eq 443
        $aliveSeconds = [int]((Get-Date) - $launchTime).TotalSeconds
        if ($established) {
            $lastHealthy = Get-Date
            if (-not $everHealthy -and $aliveSeconds -ge $HealthyLifetimeSeconds) {
                Write-WrapLog "Healthy: TCP:443 established and process lived ${aliveSeconds}s for PID $($proc.Id)"
                $everHealthy = $true
            }
        }

        if ($everHealthy -and $lastHealthy) {
            $since = [int]((Get-Date) - $lastHealthy).TotalSeconds
            if ($since -gt $StallSeconds) {
                Write-WrapLog "STALL: no TCP:443 Established for ${since}s -> killing PID $($proc.Id)"
                try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
                $reason = "stalled-${since}s"
                break
            }
        }

        # Ghost detection: an in-process environment reuse after launch means
        # the session reconnected onto a (possibly dead) environment and may
        # now be polling 200 while invisible on claude.ai. Recycle it so the
        # next launch registers cleanly from scratch.
        if (Test-GhostReuse -afterUtc $launchTimeUtc.AddSeconds($GhostReuseGraceSeconds)) {
            Write-WrapLog "GHOST: detected mid-session environment reuse -> killing PID $($proc.Id) to re-register fresh"
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
            $reason = "ghost-reuse"
            break
        }

        # Proactive lifetime recycle: bounds how long any undetected ghost can
        # persist and keeps the environment registration fresh.
        if ($MaxSessionLifetimeSeconds -gt 0 -and $aliveSeconds -ge $MaxSessionLifetimeSeconds) {
            Write-WrapLog "RECYCLE: session lived ${aliveSeconds}s (>= ${MaxSessionLifetimeSeconds}s) -> killing PID $($proc.Id) for fresh registration"
            try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch {}
            $reason = "lifetime-recycle"
            break
        }
    }

    try { $proc.WaitForExit(5000) | Out-Null } catch {}
    if (-not $reason) {
        $code = 'unknown'
        try { $code = $proc.ExitCode } catch {}
        $reason = "exited-code-$code"
    }
    $lifetime = [int]((Get-Date) - $launchTime).TotalSeconds

    if ($everHealthy) {
        if ($quickExitCount -gt 0) { Write-WrapLog "Resetting quickExitCount (was $quickExitCount)" }
        $quickExitCount = 0
    } else {
        $quickExitCount++
    }

    $cooldown = if ($everHealthy) {
        $BaseCooldownSeconds
    } else {
        [Math]::Min($BaseCooldownSeconds * [Math]::Pow(2, $quickExitCount - 1), $MaxCooldownSeconds)
    }

    Write-WrapLog "PID $($proc.Id) gone ($reason, lifetime=${lifetime}s, healthy=$everHealthy). Cooldown ${cooldown}s."

    if ($quickExitCount -ge $MaxConsecutiveFailures) {
        # Record the giveup in persistent state so a Task-Scheduler-driven
        # restart can't silently bypass the cooldown window. Exit 0 (not 1)
        # so Windows Task Scheduler's RestartOnFailure policy doesn't
        # immediately relaunch us — if it does anyway, the giveup-cooldown
        # check at wrapper startup enforces an extra ${GiveupCooldownSeconds}s
        # idle window.
        $state = Read-State
        $state.lastGiveupAt = (Get-Date).ToUniversalTime().ToString('o')
        Write-State $state
        Write-WrapLog "GIVING UP: $quickExitCount consecutive unhealthy launches (max=$MaxConsecutiveFailures). Enforcing ${GiveupCooldownSeconds}s persistent cooldown before any restart."
        exit 0
    }

    Start-Sleep -Seconds $cooldown
}
