function Invoke-CurrentWorkflow {
    Invoke-Init
    $current = Get-CurrentWorkflow
    if (-not $current) {
        Write-Host "No current workflow marker found." -ForegroundColor Yellow
        return
    }
    Write-Host ("Current Workflow: {0}" -f $current.projectId) -ForegroundColor Cyan
    if ($current.PSObject.Properties.Name -contains "source") {
        Write-Host ("  source: {0}" -f $current.source)
    }
    if ($current.PSObject.Properties.Name -contains "updatedAt") {
        Write-Host ("  updatedAt: {0}" -f $current.updatedAt)
    }
}

function Invoke-AgentDone {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    if ([string]::IsNullOrWhiteSpace($TaskId)) { throw "Please provide -TaskId" }

    $file = Get-TaskFilePath -ProjectId $Project -TaskId $TaskId
    if (-not (Test-Path $file)) { throw "Task not found: $TaskId" }
    $task = Read-JsonFile -Path $file

    if ($task.status -eq "done") {
        Write-Host ("[SKIP] task already done: {0}" -f $TaskId) -ForegroundColor Yellow
        return
    }
    if ($task.status -eq "blocked") {
        throw "Task is blocked: $TaskId. Unblock it first before agent-done."
    }

    if (-not ($task.PSObject.Properties.Name -contains "notes")) {
        $task | Add-Member -NotePropertyName notes -NotePropertyValue @() -Force
    }
    $doneNote = if ([string]::IsNullOrWhiteSpace($Note)) { "AGENT-DONE: external agent reported completion." } else { "AGENT-DONE: $Note" }
    if (-not [string]::IsNullOrWhiteSpace($WorkerModel)) {
        if (-not ($task.PSObject.Properties.Name -contains "workerModel")) {
            $task | Add-Member -NotePropertyName workerModel -NotePropertyValue $null -Force
        }
        $task.workerModel = $WorkerModel
        $doneNote = $doneNote + (" model=" + $WorkerModel)
    }
    $effectiveCcSwitchModel = $CcSwitchModel
    if ([string]::IsNullOrWhiteSpace($effectiveCcSwitchModel)) {
        $effectiveCcSwitchModel = Resolve-CcSwitchCurrentModel -TraceId $TraceId -SessionId $SessionId
    }
    if (-not [string]::IsNullOrWhiteSpace($effectiveCcSwitchModel)) {
        if (-not ($task.PSObject.Properties.Name -contains "ccSwitchModel")) {
            $task | Add-Member -NotePropertyName ccSwitchModel -NotePropertyValue $null -Force
        }
        $task.ccSwitchModel = $effectiveCcSwitchModel
        $doneNote = $doneNote + (" ccswitch=" + $effectiveCcSwitchModel)
    }
    if (-not ($task.PSObject.Properties.Name -contains "callbackEvidence")) {
        $task | Add-Member -NotePropertyName callbackEvidence -NotePropertyValue @() -Force
    }
    $rateLimited = $doneNote -match "(?i)(429|rate\\s*limit|too\\s*many\\s*requests|quota\\s*exceeded)"
    if ($rateLimited -and (Is-OpenCodeAssignee -Assignee ([string]$task.assignee))) {
        Set-OpenCodeThrottle -BackoffSeconds $OpenCodeBackoffSeconds -Reason "OpenCode rate limited by provider feedback." -SourceTaskId ([string]$task.id)
        $doneNote = $doneNote + (" opencode_backoff=" + [string]$OpenCodeBackoffSeconds + "s")
    }
    $task.callbackEvidence += ([ordered]@{
        at = (Get-Timestamp)
        source = $(if ([string]::IsNullOrWhiteSpace($Source)) { "external" } else { $Source })
        traceId = $(if ([string]::IsNullOrWhiteSpace($TraceId)) { $null } else { $TraceId })
        sessionId = $(if ([string]::IsNullOrWhiteSpace($SessionId)) { $null } else { $SessionId })
        workerModel = $(if ([string]::IsNullOrWhiteSpace($WorkerModel)) { $null } else { $WorkerModel })
        ccSwitchModel = $(if ([string]::IsNullOrWhiteSpace($effectiveCcSwitchModel)) { $null } else { $effectiveCcSwitchModel })
    })
    $task.notes += ([ordered]@{
        at = (Get-Timestamp)
        text = $doneNote
    })
    $task.status = "in_review"
    if (-not ($task.PSObject.Properties.Name -contains "leaseUntil")) {
        $task | Add-Member -NotePropertyName leaseUntil -NotePropertyValue $null -Force
    }
    $task.leaseUntil = $null
    $task.updatedAt = (Get-Timestamp)
    Write-JsonFile -Path $file -Data $task
    Set-CurrentWorkflow -ProjectId $Project -Source "agent-done"
    Write-Host ("[OK] agent-done: {0} -> in_review" -f $TaskId) -ForegroundColor Green

    if ($AutoContinue) {
        $prevProject = $script:Project
        $prevTaskId = $script:TaskId
        $prevInterval = $script:Interval
        $prevMaxRounds = $script:MaxRounds
        $script:Project = $Project
        $script:TaskId = $TaskId
        Invoke-Review
        $script:Project = $Project
        $script:Interval = 1
        $script:MaxRounds = 1
        Invoke-Watchdog
        $script:Project = $prevProject
        $script:TaskId = $prevTaskId
        $script:Interval = $prevInterval
        $script:MaxRounds = $prevMaxRounds
    }
}

function Invoke-CloseOpen {
    Invoke-Init
    $projectDirs = @()
    if (-not [string]::IsNullOrWhiteSpace($Project)) {
        $p = Require-Project -ProjectId $Project
        $projectDirs = @((Get-Item -Path $p.Dir))
    } else {
        $projectDirs = @(Get-ChildItem -Path $ProjectsDir -Directory -ErrorAction SilentlyContinue)
    }
    $closed = 0
    $skippedBlocked = 0
    foreach ($pd in $projectDirs) {
        $projId = $pd.Name
        $taskFiles = @(Get-ChildItem -Path (Join-Path $pd.FullName "tasks") -Filter "*.json" -ErrorAction SilentlyContinue)
        foreach ($tf in $taskFiles) {
            $t = Read-JsonFile -Path $tf.FullName
            if ($t.status -eq "done") { continue }
            if ($t.status -eq "blocked") { $skippedBlocked++; continue }
            $script:Project = $projId
            $script:TaskId = [string]$t.id
            $script:Note = "AUTO-CLOSE: one-click closure."
            $script:AutoContinue = $false
            Invoke-AgentDone
            $script:Project = $projId
            $script:TaskId = [string]$t.id
            Invoke-Review
            $closed++
        }
    }
    Write-Host ("[OK] close-open completed: closed={0} skippedBlocked={1}" -f $closed, $skippedBlocked) -ForegroundColor Green
}

function Invoke-ConsumeCallbacks {
    Invoke-Init
    $files = @(Get-ChildItem -Path $CallbacksDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    if ($files.Count -eq 0) {
        Write-Host "No callback files to consume." -ForegroundColor Yellow
        return
    }
    $ok = 0
    $failed = 0
    foreach ($f in $files) {
        try {
            $payload = Read-JsonFile -Path $f.FullName
            $schemaVersion = if ($payload.PSObject.Properties.Name -contains "schemaVersion") { [int]$payload.schemaVersion } else { 1 }
            if (-not ($payload.PSObject.Properties.Name -contains "project")) { throw "missing field: project" }
            if (-not ($payload.PSObject.Properties.Name -contains "taskId")) { throw "missing field: taskId" }
            if ($schemaVersion -ge 2) {
                if (-not ($payload.PSObject.Properties.Name -contains "source")) { throw "v2 missing field: source" }
                if (-not ($payload.PSObject.Properties.Name -contains "createdAt")) { throw "v2 missing field: createdAt" }
                $src = [string]$payload.source
                if ($src -eq "cc-switch") {
                    if (-not ($payload.PSObject.Properties.Name -contains "traceId") -or [string]::IsNullOrWhiteSpace([string]$payload.traceId)) { throw "v2 cc-switch callback missing traceId" }
                    if (-not ($payload.PSObject.Properties.Name -contains "sessionId") -or [string]::IsNullOrWhiteSpace([string]$payload.sessionId)) { throw "v2 cc-switch callback missing sessionId" }
                }
            }
            $script:Project = [string]$payload.project
            $script:TaskId = [string]$payload.taskId
            $script:Note = if ($payload.PSObject.Properties.Name -contains "note") { [string]$payload.note } else { "callback queue consumed" }
            $script:AutoContinue = $false
            if ($payload.PSObject.Properties.Name -contains "autoContinue") {
                $script:AutoContinue = [bool]$payload.autoContinue
            }
            $script:WorkerModel = $null
            if ($payload.PSObject.Properties.Name -contains "workerModel") {
                $script:WorkerModel = [string]$payload.workerModel
            }
            $script:CcSwitchModel = $null
            $script:Source = if ($payload.PSObject.Properties.Name -contains "source") { [string]$payload.source } else { "callback-queue" }
            $script:TraceId = if ($payload.PSObject.Properties.Name -contains "traceId") { [string]$payload.traceId } else { $null }
            $script:SessionId = if ($payload.PSObject.Properties.Name -contains "sessionId") { [string]$payload.sessionId } else { $null }
            $resolvedCcModel = Resolve-CcSwitchCurrentModel -TraceId $script:TraceId -SessionId $script:SessionId
            if (-not [string]::IsNullOrWhiteSpace($resolvedCcModel)) {
                $script:CcSwitchModel = $resolvedCcModel
            }             elseif ($payload.PSObject.Properties.Name -contains "ccSwitchModel" -and $script:Source -ne "cc-switch") {
                # fallback only for non-cc-switch sources; cc-switch source must be locally verifiable
                $script:CcSwitchModel = [string]$payload.ccSwitchModel
            }
            Invoke-AgentDone
            $ok++
            Write-InteractionFeedLine @{
                kind      = "callback_consumed"
                project   = [string]$script:Project
                taskId    = [string]$script:TaskId
                source    = [string]$script:Source
                note      = [string]$script:Note
                traceId   = if ([string]::IsNullOrWhiteSpace([string]$script:TraceId)) { $null } else { [string]$script:TraceId }
                sessionId = if ([string]::IsNullOrWhiteSpace([string]$script:SessionId)) { $null } else { [string]$script:SessionId }
            }
            Move-Item -Path $f.FullName -Destination (Join-Path $CallbacksProcessedDir ($f.BaseName + ".done.json")) -Force
        } catch {
            $failed++
            $errFile = Join-Path $CallbacksProcessedDir ($f.BaseName + ".error.txt")
            Set-Content -Path $errFile -Value ([string]$_) -Encoding UTF8
            Write-InteractionFeedLine @{
                kind = "callback_consume_failed"
                file = $f.Name
                error = ([string]($_.Exception.Message))
            }
            Move-Item -Path $f.FullName -Destination (Join-Path $CallbacksProcessedDir ($f.BaseName + ".failed.json")) -Force
        }
    }
    Write-Host ("[OK] consume-callbacks finished: ok={0} failed={1}" -f $ok, $failed) -ForegroundColor Green
}

function Invoke-WatchCallbacks {
    Invoke-Init
    $round = 0
    Write-Host ("Watching callbacks in {0} (interval={1}s, maxRounds={2})..." -f $CallbacksDir, $Interval, $MaxRounds) -ForegroundColor Cyan
    while ($true) {
        $round++
        $stamp = Get-Date -Format "HH:mm:ss"
        Write-Host ("[{0}] watch-callbacks round={1}" -f $stamp, $round) -ForegroundColor DarkCyan
        Invoke-ConsumeCallbacks

        if ($MaxRounds -gt 0 -and $round -ge $MaxRounds) {
            Write-Host ("watch-callbacks max rounds reached: {0}" -f $MaxRounds) -ForegroundColor Yellow
            break
        }
        Start-Sleep -Seconds $Interval
    }
}
