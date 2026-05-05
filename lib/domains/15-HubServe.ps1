function Invoke-AutomationHub {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    Invoke-Init
    Set-CurrentWorkflow -ProjectId $Project -Source "automation-hub"
    $consume = -not $SkipHubConsumeCallbacks
    $cycle = 0
    Write-Host ""
    $hubCapText = if ([int]$HubMaxCycles -eq 0) { "until-idle" } else { [string]$HubMaxCycles }
    Write-Host ("Automation hub - project={0} interval={1}s hubMaxCycles={2} consumeCallbacks={3} autoAdvanceGate={4} MaxConcurrentTasks={5} LocalModelMaxParallel={6}" -f `
            $Project, $Interval, $hubCapText, $consume, [bool]$HubAutoAdvanceGate, [int]$MaxConcurrentTasks, [int]$LocalModelMaxParallel) -ForegroundColor Cyan

    $savedMaxRounds = $MaxRounds
    try {
        while ($true) {
            $cycle++
            if ([int]$HubMaxCycles -gt 0 -and $cycle -gt [int]$HubMaxCycles) {
                Write-Host ("Hub stopping: reached HubMaxCycles={0}" -f $HubMaxCycles) -ForegroundColor Yellow
                break
            }

            if ($consume) {
                Invoke-ConsumeCallbacks
            }

            if ($HubAutoAdvanceGate) {
                $adv = Invoke-TryAutoAdvanceEligibleInProgressTasks -ProjectId $Project
                if ($adv -gt 0) {
                    Write-Host ("  [hub] auto-advanced in_progress -> in_review: {0} task(s)" -f $adv) -ForegroundColor DarkCyan
                    Write-InteractionFeedLine @{ kind = "hub_gate_advance"; project = $Project; count = [int]$adv }
                }
            }

            $script:MaxRounds = 1
            Invoke-Watchdog

            $post = @(Get-Tasks -ProjectId $Project | Where-Object { $_.status -notin @("done", "blocked") })
            if ($post.Count -eq 0) {
                Write-Host "[OK] Automation hub idle: no ready/in_progress/in_review work left." -ForegroundColor Green
                break
            }
            Write-Host ("[hub cycle {0}] remaining active tasks={1}" -f $cycle, $post.Count) -ForegroundColor DarkGray

            if ([int]$Interval -gt 0) {
                Start-Sleep -Seconds $Interval
            } else {
                Start-Sleep -Milliseconds 50
            }
        }
    } finally {
        $script:MaxRounds = $savedMaxRounds
    }
}

function Invoke-WorkerQueueSnapshot {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    Invoke-Init
    Ensure-Directory $WorkerQueueDir
    $out = Get-WorkerQueueSnapshotObject -ProjectId $Project -PrepBrief $WorkerQueuePrepBrief
    $outFile = Join-Path $WorkerQueueDir ("{0}.json" -f $Project)
    Write-JsonFile -Path $outFile -Data $out
    Write-Host ("[OK] worker-queue snapshot: {0} ({1} tasks)" -f $outFile, $out.taskCount) -ForegroundColor Green
}

function Invoke-ServeWorkerQueue {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    Invoke-Init
    $ports = Read-JsonFile -Path $PortsFile
    $port = if ([int]$WorkerQueueServePort -gt 0) {
        [int]$WorkerQueueServePort
    } else {
        [int](Get-PortValue -Ports $ports -Name "workerQueue" -Fallback ($ReservedPortStart + 6))
    }
    $prefix = ("http://127.0.0.1:{0}/" -f $port)
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)
    $listener.Start()
    Write-Host ("Read-only worker-queue HTTP at {0} (project={1}, Ctrl+C to stop)" -f $prefix, $Project) -ForegroundColor Green
    Write-Host "  GET /                 visual board (status + pipeline + task cards, auto-refresh)" -ForegroundColor DarkGray
    Write-Host "  GET /api/worker-queue.json   live JSON snapshot" -ForegroundColor DarkGray
    try {
        while ($listener.IsListening) {
            $ctx = $listener.GetContext()
            $req = $ctx.Request
            $res = $ctx.Response
            $path = $req.Url.AbsolutePath.ToLowerInvariant()
            try {
                if ($path -eq "/api/worker-queue.json") {
                    $snap = Get-WorkerQueueSnapshotObject -ProjectId $Project -PrepBrief $WorkerQueuePrepBrief
                    $json = ($snap | ConvertTo-Json -Depth 12)
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                    $res.ContentType = "application/json; charset=utf-8"
                    $res.StatusCode = 200
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                elseif ($path -eq "/" -or $path -eq "/index.html") {
                    $escProj = [System.Net.WebUtility]::HtmlEncode($Project)
                    $tplPath = Join-Path $Root "lib\worker-queue-viewer.html"
                    if (-not (Test-Path -LiteralPath $tplPath)) {
                        throw ("worker-queue viewer template missing: {0}" -f $tplPath)
                    }
                    $htmlRaw = [System.IO.File]::ReadAllText($tplPath, [System.Text.UTF8Encoding]::new($false))
                    $html = $htmlRaw.Replace("@@ESC_PROJ@@", $escProj)
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
                    $res.ContentType = "text/html; charset=utf-8"
                    $res.StatusCode = 200
                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                }
                else {
                    $res.StatusCode = 404
                    $msg = [System.Text.Encoding]::UTF8.GetBytes("not found")
                    $res.OutputStream.Write($msg, 0, $msg.Length)
                }
            } finally {
                $res.Close()
            }
        }
    } finally {
        $listener.Stop()
        $listener.Close()
    }
}

function Invoke-ServeDeepSeek {
    Invoke-Init
    $ports = Read-JsonFile -Path $PortsFile
    $deepseekPort = Get-PortValue -Ports $ports -Name "deepseek" -Fallback ($ReservedPortStart + 5)
    Write-Host ("Starting DeepSeek runtime API on isolated port {0}..." -f $deepseekPort) -ForegroundColor Cyan
    if (-not (Get-Command deepseek-tui -ErrorAction SilentlyContinue)) {
        throw "deepseek-tui command not found."
    }
    & deepseek-tui serve --http --host 127.0.0.1 --port $deepseekPort
}

function Invoke-ServeOpenCode {
    Invoke-Init
    $ports = Read-JsonFile -Path $PortsFile
    $opencodePort = Get-PortValue -Ports $ports -Name "opencode" -Fallback ($ReservedPortStart + 4)
    Write-Host ("Starting OpenCode headless server on isolated port {0}..." -f $opencodePort) -ForegroundColor Cyan
    if (-not (Get-Command opencode -ErrorAction SilentlyContinue)) {
        throw "opencode command not found."
    }
    $serverPassword = [string]$env:OPENCODE_SERVER_PASSWORD
    if ([string]::IsNullOrWhiteSpace($serverPassword) -and -not $AllowInsecure) {
        throw "OPENCODE_SERVER_PASSWORD is not set. Refusing insecure startup. Use -AllowInsecure to override for local temporary testing."
    }
    if ([string]::IsNullOrWhiteSpace($serverPassword) -and $AllowInsecure) {
        Write-Host "[WARN] OPENCODE_SERVER_PASSWORD is not set, starting insecure server by explicit override." -ForegroundColor Yellow
    }
    & opencode serve --hostname 127.0.0.1 --port $opencodePort
}

function Invoke-ServeCodex {
    Invoke-Init
    if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
        throw "codex CLI not found on PATH. Install OpenAI Codex CLI (https://developers.openai.com/codex/cli/) and retry."
    }
    $ports = Read-JsonFile -Path $PortsFile
    $port = if ([int]$CodexServePort -gt 0) {
        [int]$CodexServePort
    } else {
        [int](Get-PortValue -Ports $ports -Name "codex" -Fallback ($ReservedPortStart + 7))
    }
    $listen = ("ws://127.0.0.1:{0}" -f $port)
    $codexArgs = @("app-server", "--listen", $listen)
    $tokenFile = [string]$env:AUTOLOOK_CODEX_WS_TOKEN_FILE
    if (-not [string]::IsNullOrWhiteSpace($tokenFile)) {
        if (-not (Test-Path -LiteralPath $tokenFile)) {
            throw ("AUTOLOOK_CODEX_WS_TOKEN_FILE path not found: {0}" -f $tokenFile)
        }
        $fullTok = (Resolve-Path -LiteralPath $tokenFile).Path
        $codexArgs += @("--ws-auth", "capability-token", "--ws-token-file", $fullTok)
        Write-Host "[OK] WebSocket auth: capability-token from AUTOLOOK_CODEX_WS_TOKEN_FILE" -ForegroundColor DarkCyan
    } else {
        Write-Host "[INFO] Loopback WS has no token file (set AUTOLOOK_CODEX_WS_TOKEN_FILE for --ws-auth). See Codex app-server docs." -ForegroundColor DarkYellow
    }
    Write-Host ("Starting Codex app-server (JSON-RPC over WebSocket) on {0}" -f $listen) -ForegroundColor Cyan
    Write-Host ("  Health probe: http://127.0.0.1:{0}/healthz (omit Origin header)" -f $port) -ForegroundColor DarkGray
    Write-Host ("  Remote TUI attach (example): codex --remote {0}" -f $listen) -ForegroundColor DarkGray
    Write-Host "  Transport is experimental per upstream; use Codex SDK for CI-style jobs." -ForegroundColor DarkGray
    & codex @codexArgs
}
