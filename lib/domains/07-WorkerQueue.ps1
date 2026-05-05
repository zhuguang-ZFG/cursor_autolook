function Get-TaskCacheFile {
    param(
        [string]$ProjectId,
        [string]$TaskId
    )
    $projectCacheDir = Join-Path $PromptCacheDir $ProjectId
    Ensure-Directory $projectCacheDir
    return (Join-Path $projectCacheDir "$TaskId.cache.json")
}

function Get-CachedBriefPathForTask {
    param(
        [string]$ProjectId,
        [string]$TaskId
    )
    $cacheFile = Get-TaskCacheFile -ProjectId $ProjectId -TaskId $TaskId
    if (Test-Path $cacheFile) {
        $cached = Read-JsonFile -Path $cacheFile
        if ($cached.PSObject.Properties.Name -contains "briefPath") {
            $bp = [string]$cached.briefPath
            if (-not [string]::IsNullOrWhiteSpace($bp) -and (Test-Path -LiteralPath $bp)) {
                return $bp
            }
        }
    }
    $fallbackBrief = Join-Path (Split-Path -Parent $cacheFile) "$TaskId.brief.md"
    if (Test-Path -LiteralPath $fallbackBrief) {
        return $fallbackBrief
    }
    return $null
}

function Test-TaskAutoAdvanceOnGatePass {
    param([object]$TaskData)
    if (-not $TaskData -or -not ($TaskData.PSObject.Properties.Name -contains "automation")) {
        return $false
    }
    $a = $TaskData.automation
    if (-not $a -or -not ($a.PSObject.Properties.Name -contains "autoAdvanceOnGatePass")) {
        return $false
    }
    return [bool]$a.autoAdvanceOnGatePass
}

function Invoke-TryAutoAdvanceEligibleInProgressTasks {
    param([string]$ProjectId)
    $advanced = 0
    $tasks = @(Get-Tasks -ProjectId $ProjectId | Where-Object { $_.status -eq "in_progress" })
    foreach ($t in $tasks) {
        $file = Get-TaskFilePath -ProjectId $ProjectId -TaskId ([string]$t.id)
        $task = Read-JsonFile -Path $file
        if (-not (Test-TaskAutoAdvanceOnGatePass -TaskData $task)) {
            continue
        }
        $gate = Invoke-AcceptanceGate -ProjectId $ProjectId -TaskData $task
        if (-not [bool]$gate.passed) {
            continue
        }
        $script:Project = $ProjectId
        $script:TaskId = [string]$task.id
        $script:Status = "in_review"
        $script:Note = "HUB:AUTO_ADVANCE Gate pass (artifacts/tests). Ready for auto-review."
        Invoke-SetTask
        $advanced++
    }
    return $advanced
}

function Build-WorkerQueueNextStep {
    param(
        [string]$ProjectId,
        [object]$TaskData,
        [string]$BriefPath,
        [bool]$AutoAdvanceOnGatePass,
        [string]$CallbackCommandExample
    )
    $st = [string]$TaskData.status
    $primary = "unknown"
    $hints = [System.Collections.Generic.List[string]]::new()
    $channels = [System.Collections.Generic.List[string]]::new()
    $seq = New-Object System.Collections.ArrayList
    $hubScript = Join-Path $Root "cursor-autolook.ps1"

    if ($st -eq "ready") {
        $primary = "wait_dispatch"
        [void]$hints.Add("Wait until watchdog/automation-hub assigns this task and moves it to in_progress.")
        [void]$channels.Add("watchdog_dispatch")
        [void]$seq.Add([ordered]@{
            order = 1
            action = "run_or_attach_automation_hub"
            detail = ("powershell -ExecutionPolicy Bypass -File `"{0}`" automation-hub -Project `"{1}`"" -f $hubScript, $ProjectId)
        })
    }
    elseif ($st -eq "in_progress") {
        [void]$channels.Add("callback_queue_agent_done")
        [void]$seq.Add([ordered]@{
            order = 1
            action = "execute_as_assignee"
            detail = ("assignee={0}; follow briefPath in workspace." -f [string]$TaskData.assignee)
        })
        [void]$seq.Add([ordered]@{
            order = 2
            action = "submit_callback_payload"
            detail = $CallbackCommandExample
        })
        if ($AutoAdvanceOnGatePass) {
            $primary = "execute_then_gate_automation_or_callback"
            [void]$hints.Add("If requiredArtifacts + TestCommand already pass, automation-hub (-HubAutoAdvanceGate) can move this to in_review without enqueueing a callback.")
            [void]$channels.Add("automation_hub_acceptance_gate")
            [void]$seq.Add([ordered]@{
                order = 3
                action = "or_rely_on_running_hub_gate"
                detail = "Ensure automation-hub is running with -HubAutoAdvanceGate when using gate automation."
            })
        }
        else {
            $primary = "execute_then_callback"
            [void]$hints.Add("After work completes, enqueue completion via submit-agent-callback.ps1 or use agent-done from this repo.")
        }
    }
    elseif ($st -eq "in_review") {
        $primary = "wait_auto_review"
        [void]$hints.Add("watchdog/automation-hub auto-review combines note keywords with the acceptance gate; override with manual review if needed.")
        [void]$channels.Add("watchdog_auto_review")
        [void]$seq.Add([ordered]@{
            order = 1
            action = "manual_review_cli_optional"
            detail = ("powershell -ExecutionPolicy Bypass -File `"{0}`" review -Project `"{1}`" -TaskId `"{2}`"" -f $hubScript, $ProjectId, [string]$TaskData.id)
        })
    }

    return [ordered]@{
        primaryNextAction = $primary
        actionHints = @($hints)
        automationChannels = @($channels)
        suggestedSequence = @($seq.ToArray())
        briefPath = $BriefPath
    }
}

function Get-EvidencePathsForTask {
    param(
        [string]$TaskType,
        [string]$TaskTitle
    )
    $tt = if ([string]::IsNullOrWhiteSpace($TaskType)) { "general" } else { $TaskType.ToLowerInvariant() }
    $base = @("README.md", "kx/tools/dump_agent/decompiled_java", "kx/decompiled")
    $extra = @()
    switch ($tt) {
        "review" {
            $extra += @("kx/tools/dump_agent/README.md", "kx/decompiled/DUMP_DECOMPILE_STATUS.md")
        }
        "refactor" {
            $extra += @("kx/tools/dump_agent/decompiled_java/com/kvenjoy/drawsoft/lib/data/Storage.java", "kx/tools/dump_agent/decompiled_java/com/kenjoy/kenjoycnc/model/Settings.java")
        }
        "bugfix" {
            $extra += @("kx/tools/dump_agent/decompiled_java/com/kenjoy/kenjoycnc/a", "kx/tools/dump_agent/decompiled_java/com/kvenjoy/drawsoft/lib/e/a")
        }
        default {
            $extra += @("kx/tools/dump_agent/decompiled_java/com/kenjoy/kenjoycnc", "kx/decompiled/kdraw_jar_resources/processer.json")
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($TaskTitle)) {
        $t = $TaskTitle.ToLowerInvariant()
        if ($t -match "api|接口|service|http") {
            $extra += @("kx/tools/dump_agent/decompiled_java/com/kenjoy/kenjoycnc/a")
        }
        if ($t -match "auth|login|鉴权|权限|安全") {
            $extra += @("kx/tools/dump_agent/decompiled_java/com/kenjoy/kenjoycnc/net/a.java", "kx/tools/dump_agent/decompiled_java/com/kenjoy/kenjoycnc/a/c.java")
        }
    }
    return @($base + $extra | Select-Object -Unique)
}

function Get-WorkerQueueSnapshotObject {
    param(
        [string]$ProjectId,
        [bool]$PrepBrief
    )
    $p = Require-Project -ProjectId $ProjectId
    $proj = Read-JsonFile -Path $p.File
    $workspace = if ($proj.PSObject.Properties.Name -contains "workspace") { [string]$proj.workspace } else { $Root }

    $targeting = @("ready", "in_progress", "in_review")
    $tasks = @(Get-Tasks -ProjectId $ProjectId | Where-Object { $_.status -in $targeting } | Sort-Object createdAt)

    $rows = New-Object System.Collections.ArrayList
    foreach ($t in $tasks) {
        $tid = [string]$t.id
        if ($PrepBrief) {
            $script:Project = $ProjectId
            $script:TaskId = $tid
            try {
                Invoke-PrepBrief
            } catch {
                Write-Host ("  [worker-queue] prep-brief skipped for {0}: {1}" -f $tid, $_) -ForegroundColor DarkYellow
            }
        }
        $briefPath = Get-CachedBriefPathForTask -ProjectId $ProjectId -TaskId $tid
        $aa = Test-TaskAutoAdvanceOnGatePass -TaskData $t
        $cb = ("powershell -ExecutionPolicy Bypass -File `"{0}`" -Project `"{1}`" -TaskId `"{2}`"" -f (Join-Path $Root "scripts\submit-agent-callback.ps1"), $ProjectId, $tid)
        $next = Build-WorkerQueueNextStep -ProjectId $ProjectId -TaskData $t -BriefPath $briefPath -AutoAdvanceOnGatePass $aa -CallbackCommandExample $cb

        [void]$rows.Add([ordered]@{
            id = $tid
            status = [string]$t.status
            title = [string]$t.title
            assignee = [string]$t.assignee
            reviewer = [string]$t.reviewer
            workerModel = if ($t.PSObject.Properties.Name -contains "workerModel") { $t.workerModel } else { $null }
            taskType = if ($t.PSObject.Properties.Name -contains "taskType") { [string]$t.taskType } else { "general" }
            testCommand = if ($t.PSObject.Properties.Name -contains "testCommand") { $t.testCommand } else { $null }
            autoAdvanceOnGatePass = [bool]$aa
            briefPath = $briefPath
            callbackHint = $cb
            evidencePaths = @(Get-EvidencePathsForTask -TaskType ([string]$t.taskType) -TaskTitle ([string]$t.title))
            nextStep = $next
        })
    }

    return [ordered]@{
        projectId = $ProjectId
        workspace = $workspace
        updatedAt = (Get-Timestamp)
        taskCount = $rows.Count
        tasks = @($rows.ToArray())
    }
}
