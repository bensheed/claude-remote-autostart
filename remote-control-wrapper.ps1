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

    Write-WrapLog "Launching (attempt, quickExitCount=$quickExitCount, lastHour=$recentCount): $nodeExe $($argList -join ' ')"
    $launchTime = Get-Date
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
