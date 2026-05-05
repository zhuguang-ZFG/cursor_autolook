function Write-InteractionFeedLine {
    param([hashtable]$Fields)
    $row = [ordered]@{
        ts = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
    }
    foreach ($k in @($Fields.Keys | Sort-Object)) {
        $row[$k] = $Fields[$k]
    }
    try {
        $line = (($row | ConvertTo-Json -Compress -Depth 8))
        Ensure-Directory $RuntimeDir
        Add-Content -LiteralPath $InteractionFeedFile -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # best-effort: never break watchdog/consume paths
    }
}

function Format-InteractionFeedConsole {
    param([object]$ev)
    if (-not $ev) { return }
    $proj = ""
    try { $proj = [string]$ev.project } catch {}
    try {
        $ts = ""
        try { $tsRaw = [string]$ev.ts; if (-not [string]::IsNullOrWhiteSpace($tsRaw)) { $ts = ([datetime]::Parse($tsRaw)).ToString("HH:mm:ss") } } catch { $ts = "?" }
        switch ([string]$ev.kind) {
            "callback_queued" {
                $fn = ""; try { $fn = [string]$ev.file } catch {}
                Write-Host ("{0}  [worker->hub] queued callback task={1} src={2} trace={3} session={4} file={5} proj={6}" `
                        -f $ts, ([string]$ev.taskId), ([string]$ev.source), `
                        ($(if ($ev.traceId) { [string]$ev.traceId } else { "-" })), `
                        ($(if ($ev.sessionId) { [string]$ev.sessionId } else { "-" })), `
                        $fn, $proj) -ForegroundColor Cyan
            }
            "callback_consumed" {
                Write-Host ("{0}  [hub] consumed callback agent_done pipeline task={1} src={2} trace={3} session={4} proj={5}" `
                        -f $ts, ([string]$ev.taskId), ([string]$ev.source), `
                        ($(if ($ev.traceId) { [string]$ev.traceId } else { "-" })), `
                        ($(if ($ev.sessionId) { [string]$ev.sessionId } else { "-" })), `
                        $proj) -ForegroundColor Green
                if (-not [string]::IsNullOrWhiteSpace([string]$ev.note)) {
                    Write-Host ("        note: {0}" -f ([string]$ev.note)) -ForegroundColor DarkGray
                }
            }
            "callback_consume_failed" {
                $tidFail = ""; try { $tidFail = [string]$ev.taskId } catch {}
                if ([string]::IsNullOrWhiteSpace($tidFail)) { $tidFail = "?" }
                Write-Host ("{0}  [hub] callback rejected task={1} file={2} proj={3}" `
                        -f $ts, $tidFail, ($(if ($ev.file) { [string]$ev.file } else { "-" })), $(if (-not [string]::IsNullOrWhiteSpace($proj)) { $proj } else { "-" })) -ForegroundColor Red
                if (-not [string]::IsNullOrWhiteSpace([string]$ev.error)) {
                    Write-Host ("        error: {0}" -f ([string]$ev.error)) -ForegroundColor DarkYellow
                }
            }
            "watchdog_dispatch" {
                Write-Host ("{0}  [scheduler] dispatched -> in_progress assignee={1} attempt={2} reason={3} task={4} proj={5}" `
                        -f $ts, ([string]$ev.assignee), ($(if ($ev.attempt -ne $null) { [string]$ev.attempt } else { "?" })), `
                        ($(if ($ev.reason) { [string]$ev.reason } else { "-" })), ([string]$ev.taskId), $proj) -ForegroundColor DarkCyan
            }
            "watchdog_review_auto" {
                Write-Host ("{0}  [reviewer] auto task={1} -> {2} proj={3}" `
                        -f $ts, ([string]$ev.taskId), ([string]$ev.status), $proj) -ForegroundColor Magenta
            }
            "watchdog_blocked_attempts" {
                Write-Host ("{0}  [scheduler] blocked max attempts task={1} proj={2}" -f $ts, ([string]$ev.taskId), $proj) -ForegroundColor Yellow
            }
            "hub_gate_advance" {
                Write-Host ("{0}  [hub] gate auto-advance in_progress->in_review tasks={1} proj={2}" `
                        -f $ts, [string]$ev.count, $proj) -ForegroundColor DarkGray
            }
            default {
                Write-Host ("{0}  [{1}] {2}" -f $ts, ([string]$ev.kind), ($ev | ConvertTo-Json -Compress -Depth 4)) -ForegroundColor Gray
            }
        }
    } catch {
        Write-Host ("[feed] malformed line skipped: {0}" -f ($_ | Out-String)) -ForegroundColor DarkYellow
    }
}

function Invoke-FollowFeed {
    Invoke-Init
    Ensure-Directory $RuntimeDir
    $filt = ""
    if (-not [string]::IsNullOrWhiteSpace([string]$Project)) {
        $filt = [string]$Project
    }

    if ($FeedNewWindow) {
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $scriptPath = Join-Path $Root 'cursor-autolook.ps1'
        if (-not (Test-Path -LiteralPath $psExe)) { throw "PowerShell executable not found: $psExe" }
        if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Script not found: $scriptPath" }
        $argList = @(
            '-NoExit', '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
            'follow-feed', '-FeedTail', ([string]$FeedTail)
        )
        if ($FeedOnce) { $argList += '-FeedOnce' }
        if (-not [string]::IsNullOrWhiteSpace($filt)) {
            $argList += '-Project'
            $argList += $filt
        }
        Start-Process -FilePath $psExe -WorkingDirectory $Root -ArgumentList $argList
        $hint = if ($FeedOnce) { 'replay once' } else { 'streaming (Ctrl+C to close)' }
        Write-Host ("[OK] Opened NEW PowerShell window: follow-feed ({0})." -f $hint) -ForegroundColor Green
        Write-Host "     If blocked by policy, run the same follow-feed command manually in Windows Terminal." -ForegroundColor DarkGray
        return
    }

    if ($FeedOnce) {
        if (-not (Test-Path -LiteralPath $InteractionFeedFile)) {
            Write-Host ("No interaction feed yet: {0} (dispatch a task or submit a callback first)." -f $InteractionFeedFile) -ForegroundColor Yellow
            return
        }
        if (-not [string]::IsNullOrWhiteSpace($filt)) {
            Write-Host ("Replay interaction-feed: file={0} projectFilter={1} lastLines={2}" `
                    -f $InteractionFeedFile, $filt, [int]$FeedTail) -ForegroundColor Cyan
        }
        else {
            Write-Host ("Replay interaction-feed: file={0} allProjects lastLines={1}" `
                    -f $InteractionFeedFile, [int]$FeedTail) -ForegroundColor Cyan
        }
        Write-Host "Legend: worker->hub = callback landed; hub consumed = routed to completion path; scheduler = watchdog dispatch;" -ForegroundColor DarkGray
        $lines = @(Get-Content -LiteralPath $InteractionFeedFile -Tail ([int]$FeedTail) -ErrorAction Stop)
        foreach ($line in $lines) {
            try {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $obj = ($line | ConvertFrom-Json -ErrorAction Stop)
                if (-not [string]::IsNullOrWhiteSpace($filt)) {
                    $op = ""; try { $op = [string]$obj.project } catch { $op = "" }
                    if ($op -ne $filt) { continue }
                }
                Format-InteractionFeedConsole $obj
            }
            catch {
                Write-Host ("[feed skip] $_") -ForegroundColor DarkYellow
            }
        }
        return
    }

    if (-not (Test-Path -LiteralPath $InteractionFeedFile)) {
        New-Item -ItemType File -Path $InteractionFeedFile -Force | Out-Null
    }
    if (-not [string]::IsNullOrWhiteSpace($filt)) {
        Write-Host ("Following interaction-feed: file={0} projectFilter={1} Tail={2} (Ctrl+C stops)" `
                -f $InteractionFeedFile, $filt, [int]$FeedTail) -ForegroundColor Cyan
    }
    else {
        Write-Host ("Following interaction-feed: file={0} allProjects Tail={1} (Ctrl+C stops)" `
                -f $InteractionFeedFile, [int]$FeedTail) -ForegroundColor Cyan
    }
    Write-Host "Legend: worker->hub = callback landed; hub consumed = routed to completion path; scheduler = watchdog dispatch;" -ForegroundColor DarkGray

    Get-Content -LiteralPath $InteractionFeedFile -Wait -Tail ([int]$FeedTail) | ForEach-Object {
        try {
            if ([string]::IsNullOrWhiteSpace($_)) { return }
            $obj = ($_ | ConvertFrom-Json -ErrorAction Stop)
            if (-not [string]::IsNullOrWhiteSpace($filt)) {
                $op = ""; try { $op = [string]$obj.project } catch { $op = "" }
                if ($op -ne $filt) { return }
            }
            Format-InteractionFeedConsole $obj
        }
        catch {
            Write-Host ("[feed skip] $_") -ForegroundColor DarkYellow
        }
    }
}
