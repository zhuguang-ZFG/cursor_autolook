function Invoke-Dashboard {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    Invoke-Init
    Set-CurrentWorkflow -ProjectId $Project -Source "dashboard"
    $resolvedClaudeCount = Resolve-ClaudeCount -ProjectId $Project
    if ($resolvedClaudeCount -lt 0 -or $resolvedClaudeCount -gt 6) {
        throw "ClaudeCount must be between 0 and 6."
    }

    $wt = Get-Command wt -ErrorAction SilentlyContinue
    if (-not $wt) {
        throw "Windows Terminal (wt) not found. Please install Windows Terminal first."
    }

    $rootEscaped = $Root.Replace("'", "''")
    $projectEscaped = $Project.Replace("'", "''")
    $ports = Read-JsonFile -Path $PortsFile
    $opencodePort = Get-PortValue -Ports $ports -Name "opencode" -Fallback ($ReservedPortStart + 4)
    $deepseekPort = Get-PortValue -Ports $ports -Name "deepseek" -Fallback ($ReservedPortStart + 5)
    $codexPort = Get-PortValue -Ports $ports -Name "codex" -Fallback ($ReservedPortStart + 7)

    if ($DashboardSinglePane) {
        $singleCmd = "cd '$rootEscaped'; Write-Host '=== Autolook dashboard (single-pane / 同窗) ===' -ForegroundColor Cyan; Write-Host 'Project: $projectEscaped' -ForegroundColor DarkCyan; Write-Host ('Sidecar: OpenCode port {0} | DeepSeek port {1} | Codex ws://127.0.0.1:{2}' -f $opencodePort, $deepseekPort, $codexPort) -ForegroundColor DarkGray; Write-Host 'Tip: refresh loop blocks input; press Ctrl+C to stop, then use THIS pane for watchdog / serve-codex / cursor agent / manual commands.' -ForegroundColor Yellow; Write-Host ''; powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 enter-workflow -Project '$projectEscaped'; Write-Host ''; while (`$true) { Clear-Host; Write-Host '=== Ops (single-pane) ===' -ForegroundColor Cyan; Write-Host 'Project: $projectEscaped' -ForegroundColor DarkCyan; Write-Host ''; powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 status; Write-Host ''; powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 metrics -Project '$projectEscaped'; Write-Host ''; Write-Host 'Callback bridge tick:' -ForegroundColor DarkCyan; powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 consume-callbacks; Write-Host ''; Write-Host 'Commands:' -ForegroundColor DarkCyan; Write-Host '  watchdog: powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 watchdog -Project $projectEscaped'; Write-Host '  serve-codex: powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 serve-codex -CodexServePort $codexPort'; Write-Host '  cache:    powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 cache-stats'; Write-Host '  review:   powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 review -Project $projectEscaped -TaskId TASK_ID'; Write-Host ''; if (Test-Path '.\runtime\alerts.log') { Write-Host 'Latest alerts:' -ForegroundColor Yellow; Get-Content '.\runtime\alerts.log' | Select-Object -Last 5 }; Start-Sleep -Seconds 8 }"
        $singleEncoded = New-EncodedCommand -ScriptText $singleCmd
        $wtArgsSingle = @("-w", "0", "new-tab", "--title", "Autolook-Single", "powershell", "-NoExit", "-EncodedCommand", $singleEncoded)
        & wt @wtArgsSingle | Out-Null
        Write-Host "[OK] single-pane dashboard: one WT tab 'Autolook-Single' (enter-workflow once, then ops loop; Ctrl+C -> same pane for manual work)" -ForegroundColor Green
        Write-Host "[INFO] No split panes and no extra Codex tab; start serve-codex yourself after Ctrl+C if needed." -ForegroundColor Yellow
        return
    }

    $topCmd = "cd '$rootEscaped'; Write-Host '=== Cursor Agent (主控/C位) ===' -ForegroundColor Cyan; if (Get-Command cursor -ErrorAction SilentlyContinue) { cursor agent } else { Write-Host 'cursor command not found, fallback to shell.' -ForegroundColor Yellow; powershell -NoExit }"
    $opsCmd = "cd '$rootEscaped'; while (`$true) { Clear-Host; Write-Host '=== Ops Console ===' -ForegroundColor Cyan; Write-Host 'Project: $projectEscaped' -ForegroundColor DarkCyan; Write-Host ''; powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 status; Write-Host ''; powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 metrics -Project '$projectEscaped'; Write-Host ''; Write-Host 'Callback bridge tick:' -ForegroundColor DarkCyan; powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 consume-callbacks; Write-Host ''; Write-Host 'Commands:' -ForegroundColor DarkCyan; Write-Host '  watchdog: powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 watchdog -Project $projectEscaped'; Write-Host '  cache:    powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 cache-stats'; Write-Host '  review:   powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 review -Project $projectEscaped -TaskId TASK_ID'; Write-Host ''; if (Test-Path '.\runtime\alerts.log') { Write-Host 'Latest alerts:' -ForegroundColor Yellow; Get-Content '.\runtime\alerts.log' | Select-Object -Last 5 }; Start-Sleep -Seconds 8 }"
    $bottomLeftCmd = "cd '$rootEscaped'; Write-Host '=== OpenCode ===' -ForegroundColor Cyan; Write-Host 'Isolated Port: $opencodePort' -ForegroundColor DarkCyan; if (Get-Command opencode -ErrorAction SilentlyContinue) { opencode --port $opencodePort } else { Write-Host 'opencode command not found.' -ForegroundColor Yellow; powershell -NoExit }"
    $deepseekCmd = "cd '$rootEscaped'; Write-Host '=== DeepSeek-TUI ===' -ForegroundColor Cyan; Write-Host 'Reserved Port: $deepseekPort (for sidecar/serve mode)' -ForegroundColor DarkCyan; if (Get-Command deepseek-tui -ErrorAction SilentlyContinue) { deepseek-tui --workspace '$rootEscaped' } elseif (Get-Command deepseek -ErrorAction SilentlyContinue) { deepseek } else { Write-Host 'deepseek/deepseek-tui command not found.' -ForegroundColor Yellow; powershell -NoExit }"
    $claudeCmds = @(
        "cd '$rootEscaped'; Write-Host '=== Claude-1 ===' -ForegroundColor Cyan; if (Get-Command claude -ErrorAction SilentlyContinue) { claude } else { Write-Host 'claude command not found.' -ForegroundColor Yellow; powershell -NoExit }",
        "cd '$rootEscaped'; Write-Host '=== Claude-2 ===' -ForegroundColor Cyan; if (Get-Command claude -ErrorAction SilentlyContinue) { claude } else { Write-Host 'claude command not found.' -ForegroundColor Yellow; powershell -NoExit }",
        "cd '$rootEscaped'; Write-Host '=== Claude-3 ===' -ForegroundColor Cyan; if (Get-Command claude -ErrorAction SilentlyContinue) { claude } else { Write-Host 'claude command not found.' -ForegroundColor Yellow; powershell -NoExit }",
        "cd '$rootEscaped'; Write-Host '=== Claude-4 ===' -ForegroundColor Cyan; if (Get-Command claude -ErrorAction SilentlyContinue) { claude } else { Write-Host 'claude command not found.' -ForegroundColor Yellow; powershell -NoExit }",
        "cd '$rootEscaped'; Write-Host '=== Claude-5 ===' -ForegroundColor Cyan; if (Get-Command claude -ErrorAction SilentlyContinue) { claude } else { Write-Host 'claude command not found.' -ForegroundColor Yellow; powershell -NoExit }",
        "cd '$rootEscaped'; Write-Host '=== Claude-6 ===' -ForegroundColor Cyan; if (Get-Command claude -ErrorAction SilentlyContinue) { claude } else { Write-Host 'claude command not found.' -ForegroundColor Yellow; powershell -NoExit }"
    )
    $codexDashboardCmd = "cd '$rootEscaped'; Write-Host '=== Codex App-Server (打工仔隔离口) ===' -ForegroundColor Cyan; Write-Host ('WS ws://127.0.0.1:{0}  |  Attach: codex --remote ws://127.0.0.1:{0}' -f $codexPort) -ForegroundColor DarkCyan; if (Get-Command codex -ErrorAction SilentlyContinue) { powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 serve-codex -CodexServePort $codexPort } else { Write-Host 'codex CLI not installed; skipping serve-codex. See README Codex section.' -ForegroundColor Yellow; powershell -NoExit }"
    $topEncoded = New-EncodedCommand -ScriptText $topCmd
    $opsEncoded = New-EncodedCommand -ScriptText $opsCmd
    $bottomLeftEncoded = New-EncodedCommand -ScriptText $bottomLeftCmd
    $deepseekEncoded = New-EncodedCommand -ScriptText $deepseekCmd
    $codexDashboardEncoded = New-EncodedCommand -ScriptText $codexDashboardCmd
    $claudeEncoded = @($claudeCmds | ForEach-Object { New-EncodedCommand -ScriptText $_ })

    # Stable layout:
    # Top: main control + ops
    # Bottom-left: OpenCode
    # Bottom-right: DeepSeek + dynamic Claude panes
    # Second tab (separate WT tab avoids breaking pane indexes used by Claude splits below):
    $wtArgs = @(
        "-w", "0", "new-tab", "--title", "Main-Control", "powershell", "-NoExit", "-EncodedCommand", $topEncoded,
        ";", "split-pane", "-H", "--size", "0.78", "--title", "Ops-Console", "powershell", "-NoExit", "-EncodedCommand", $opsEncoded,
        ";", "split-pane", "-V", "--size", "0.38", "--title", "OpenCode", "powershell", "-NoExit", "-EncodedCommand", $bottomLeftEncoded,
        ";", "focus-pane", "-t", "1",
        ";", "split-pane", "-H", "--size", "0.66", "--title", "DeepSeek-TUI", "powershell", "-NoExit", "-EncodedCommand", $deepseekEncoded
    )

    # DeepSeek pane index is 2 in this stable layout; stack Claude panes vertically there.
    for ($i = 0; $i -lt $resolvedClaudeCount; $i++) {
        $wtArgs += @(";", "focus-pane", "-t", "2")
        $wtArgs += @(";", "split-pane", "-V", "--size", "0.66", "--title", "Claude-$($i+1)", "powershell", "-NoExit", "-EncodedCommand", $claudeEncoded[$i])
    }

    $wtArgs += @(
        ";", "new-tab", "--title", "Codex-AppServer", "powershell", "-NoExit", "-EncodedCommand", $codexDashboardEncoded
    )

    & wt @wtArgs | Out-Null
    Write-Host "[OK] dashboard launched: Main tab (Main-Control + Ops + OpenCode + DeepSeek + Claude*$resolvedClaudeCount) + tab Codex-AppServer(ws://127.0.0.1:$codexPort)" -ForegroundColor Green
    Write-Host "[INFO] If you are not running inside Windows Terminal, this opens a separate WT window." -ForegroundColor Yellow
}
