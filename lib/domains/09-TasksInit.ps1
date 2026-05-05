function Contains-ApiNebula {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    return ($Text.ToLowerInvariant() -match "apinebula")
}

function Assert-ApiNebulaEscalationAllowed {
    param(
        [string]$ProjectId,
        [bool]$FallbackOnlyWhenAllFailed
    )
    if (-not $FallbackOnlyWhenAllFailed) { return }
    $tasks = @(Get-Tasks -ProjectId $ProjectId)
    $nonNebula = @($tasks | Where-Object { -not (Contains-ApiNebula -Text ([string]$_.assignee)) })
    if ($nonNebula.Count -eq 0) {
        throw "apinebula escalation denied: no prior non-apinebula attempts found in this project."
    }
    $activeNonNebula = @($nonNebula | Where-Object { $_.status -in @("ready", "in_progress", "in_review") })
    if ($activeNonNebula.Count -gt 0) {
        throw "apinebula escalation denied: non-apinebula tasks are still runnable/in-progress. Exhaust lower-cost models first."
    }
    $notBlocked = @($nonNebula | Where-Object { $_.status -ne "blocked" })
    if ($notBlocked.Count -gt 0) {
        throw "apinebula escalation denied: not all non-apinebula tasks are blocked."
    }
}
function Get-TaskFiles {
    param([string]$ProjectId)
    $p = Require-Project -ProjectId $ProjectId
    return @(Get-ChildItem -Path (Join-Path $p.Dir "tasks") -Filter "*.json" -ErrorAction SilentlyContinue)
}

function Get-Tasks {
    param([string]$ProjectId)
    $taskFiles = Get-TaskFiles -ProjectId $ProjectId
    $tasks = @()
    foreach ($tf in $taskFiles) {
        $tasks += Read-JsonFile -Path $tf.FullName
    }
    return @($tasks)
}

function Get-TaskFilePath {
    param(
        [string]$ProjectId,
        [string]$TaskId
    )
    $p = Require-Project -ProjectId $ProjectId
    return (Join-Path (Join-Path $p.Dir "tasks") "$TaskId.json")
}

function Get-ProjectWorkspace {
    param([string]$ProjectId)
    $p = Require-Project -ProjectId $ProjectId
    $proj = Read-JsonFile -Path $p.File
    if ($proj.PSObject.Properties.Name -contains "workspace" -and -not [string]::IsNullOrWhiteSpace([string]$proj.workspace)) {
        return [string]$proj.workspace
    }
    return $Root
}

function Resolve-ClaudeCount {
    param([string]$ProjectId)
    if ($ClaudeCount -ge 0) {
        if ($ClaudeCount -gt 6) { return 6 }
        return $ClaudeCount
    }
    $tasks = @(Get-Tasks -ProjectId $ProjectId)
    if ($tasks.Count -eq 0) { return 2 }
    $active = @($tasks | Where-Object { $_.status -in @("ready", "in_progress", "in_review") }).Count
    if ($active -le 1) { return 1 }
    if ($active -ge 6) { return 6 }
    return $active
}

function Invoke-Init {
    Ensure-Directory $RuntimeDir
    Ensure-Directory $ProjectsDir
    if (-not (Test-Path $PortsFile)) {
        $ports = [ordered]@{
            owner = "cursor_autolook"
            reservedRange = @{
                start = $ReservedPortStart
                end = $ReservedPortEnd
            }
            knownConflictRange = @{
                start = $KnownConflictStart
                end = $KnownConflictEnd
            }
            defaults = @{
                hub = $ReservedPortStart
                api = ($ReservedPortStart + 1)
                dashboard = ($ReservedPortStart + 2)
                reviewer = ($ReservedPortStart + 3)
                opencode = ($ReservedPortStart + 4)
                deepseek = ($ReservedPortStart + 5)
                workerQueue = ($ReservedPortStart + 6)
                codex = ($ReservedPortStart + 7)
            }
            createdAt = (Get-Timestamp)
            updatedAt = (Get-Timestamp)
        }
        Write-JsonFile -Path $PortsFile -Data $ports
    } else {
        $ports = Read-JsonFile -Path $PortsFile
        $changed = $false
        if (-not ($ports.PSObject.Properties.Name -contains "defaults")) {
            $ports | Add-Member -NotePropertyName defaults -NotePropertyValue ([ordered]@{}) -Force
            $changed = $true
        }
        if (-not ($ports.defaults.PSObject.Properties.Name -contains "opencode")) {
            $ports.defaults | Add-Member -NotePropertyName opencode -NotePropertyValue ($ReservedPortStart + 4) -Force
            $changed = $true
        }
        if (-not ($ports.defaults.PSObject.Properties.Name -contains "deepseek")) {
            $ports.defaults | Add-Member -NotePropertyName deepseek -NotePropertyValue ($ReservedPortStart + 5) -Force
            $changed = $true
        }
        if (-not ($ports.defaults.PSObject.Properties.Name -contains "workerQueue")) {
            $ports.defaults | Add-Member -NotePropertyName workerQueue -NotePropertyValue ($ReservedPortStart + 6) -Force
            $changed = $true
        }
        if (-not ($ports.defaults.PSObject.Properties.Name -contains "codex")) {
            $ports.defaults | Add-Member -NotePropertyName codex -NotePropertyValue ($ReservedPortStart + 7) -Force
            $changed = $true
        }
        if ($changed) {
            $ports.updatedAt = (Get-Timestamp)
            Write-JsonFile -Path $PortsFile -Data $ports
        }
    }
    if (-not (Test-Path $MetricsFile)) {
        Save-Metrics -Metrics (Get-Metrics)
    }
    if (-not (Test-Path $RoutingFile)) {
        $routing = [ordered]@{
            version = 1
            strategy = "small-model-first-large-model-gate"
            expensiveProviderPolicy = [ordered]@{
                apinebula = [ordered]@{
                    enabled = $false
                    requireUserApproval = $true
                    fallbackOnlyWhenAllFailed = $true
                    note = "High token cost. Default disabled."
                }
            }
            byTaskType = [ordered]@{
                bugfix = [ordered]@{
                    assignee = "DeepSeek"
                    reviewer = "GitHub gpt-5-mini"
                    modelTier = "mid"
                    tokenPolicy = "strict"
                    fallbackAssignees = @("DeepSeek", "Cursor", "Claude", "OpenCode")
                }
                refactor = [ordered]@{
                    assignee = "OpenCode"
                    reviewer = "GitHub gpt-5-mini"
                    modelTier = "small"
                    tokenPolicy = "strict"
                    fallbackAssignees = @("OpenCode", "Ollama", "DeepSeek", "Cursor")
                }
                review = [ordered]@{
                    assignee = "Claude"
                    reviewer = "GitHub gpt-5-mini"
                    modelTier = "large"
                    tokenPolicy = "quality-first"
                    fallbackAssignees = @("Claude", "DeepSeek", "Cursor", "OpenCode")
                }
                general = [ordered]@{
                    assignee = "Ollama"
                    reviewer = "GitHub gpt-5-mini"
                    modelTier = "small"
                    tokenPolicy = "strict"
                    fallbackAssignees = @("Ollama", "Cursor", "DeepSeek", "OpenCode")
                }
            }
            updatedAt = (Get-Timestamp)
        }
        Write-JsonFile -Path $RoutingFile -Data $routing
    } else {
        $routing = Read-JsonFile -Path $RoutingFile
        $changed = $false
        if (-not ($routing.PSObject.Properties.Name -contains "expensiveProviderPolicy") -or -not $routing.expensiveProviderPolicy) {
            $routing | Add-Member -NotePropertyName expensiveProviderPolicy -NotePropertyValue ([pscustomobject]@{}) -Force
            $changed = $true
        }
        if (-not ($routing.expensiveProviderPolicy.PSObject.Properties.Name -contains "apinebula")) {
            $routing.expensiveProviderPolicy | Add-Member -NotePropertyName apinebula -NotePropertyValue ([pscustomobject]@{
                enabled = $false
                requireUserApproval = $true
                fallbackOnlyWhenAllFailed = $true
                note = "High token cost. Default disabled."
            }) -Force
            $changed = $true
        } else {
            $ap = $routing.expensiveProviderPolicy.apinebula
            if (-not ($ap.PSObject.Properties.Name -contains "fallbackOnlyWhenAllFailed")) {
                $ap | Add-Member -NotePropertyName fallbackOnlyWhenAllFailed -NotePropertyValue $true -Force
                $changed = $true
            }
        }
        foreach ($tt in @("bugfix", "refactor", "review", "general")) {
            if ($routing.PSObject.Properties.Name -contains "byTaskType" -and $routing.byTaskType.PSObject.Properties.Name -contains $tt) {
                $rt = $routing.byTaskType.$tt
                if (-not ($rt.PSObject.Properties.Name -contains "fallbackAssignees")) {
                    $fallback = Get-RouteFallbackAssignees -Route $rt -PrimaryAssignee ([string]$rt.assignee)
                    $rt | Add-Member -NotePropertyName fallbackAssignees -NotePropertyValue $fallback -Force
                    $changed = $true
                }
            }
        }
        if ($changed) {
            $routing.updatedAt = (Get-Timestamp)
            Write-JsonFile -Path $RoutingFile -Data $routing
        }
    }
    Ensure-Directory $PromptCacheDir
    Ensure-Directory $CallbacksDir
    Ensure-Directory $CallbacksProcessedDir
    Ensure-Directory $ReportsDir
    if (-not (Test-Path $DashboardLayoutFile)) {
        $layout = [ordered]@{
            version = 1
            mainOpsSplit = 0.78
            openCodeSplit = 0.38
            deepseekSplit = 0.66
            claudeStackSplit = 0.66
            lastProject = $null
            updatedAt = (Get-Timestamp)
        }
        Write-JsonFile -Path $DashboardLayoutFile -Data $layout
    }

    if (-not (Test-Path $SupervisorEvolutionFile)) {
        $evo = [ordered]@{
            version = 1
            stepApplied = 0
            maxSteps = 3
            minCacheSamples = 12
            cacheHitRateThreshold = $DefaultCacheHitRateThreshold
            includeStatusInHash = $true
            recentNotesCountInHash = 3
            updatedAt = (Get-Timestamp)
            history = @()
        }
        Write-JsonFile -Path $SupervisorEvolutionFile -Data $evo
    }
    foreach ($tt in @("general", "bugfix", "refactor", "review")) {
        Get-PromptPrefix -TaskType $tt | Out-Null
    }
    if ($Project) {
        Get-ProjectPrefixText -ProjectId $Project | Out-Null
    }
    Write-Host "[OK] runtime initialized at $RuntimeDir" -ForegroundColor Green
}

function Invoke-NewProject {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "Please provide -Name"
    }
    Invoke-Init
    $id = New-Slug -Value $Name
    $dir = Get-ProjectDir -ProjectId $id
    if (Test-Path $dir) {
        throw "Project already exists: $id"
    }

    Ensure-Directory $dir
    Ensure-Directory (Join-Path $dir "tasks")

    $project = [ordered]@{
        id = $id
        name = $Name
        status = "active"
        workspace = (Get-Location).Path
        createdAt = (Get-Timestamp)
        updatedAt = (Get-Timestamp)
    }

    Write-JsonFile -Path (Join-Path $dir "project.json") -Data $project
    Write-Host "[OK] project created: $id" -ForegroundColor Green
}

function Invoke-NewTask {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    if ([string]::IsNullOrWhiteSpace($Title)) { throw "Please provide -Title" }

    $p = Require-Project -ProjectId $Project
    $tasksDir = Join-Path $p.Dir "tasks"
    Ensure-Directory $tasksDir

    $resolvedTaskType = (Resolve-TaskType -RawType $TaskType -Title $Title)
    $finalAssignee = $Assignee
    $finalReviewer = $Reviewer
    $modelTier = "unset"
    $tokenPolicy = "unset"
    $routeSource = "manual"
    $fallbackAssignees = @($finalAssignee)
    if (-not $NoAutoRoute) {
        $route = Resolve-TaskRouting -ResolvedTaskType $resolvedTaskType
        if ($route) {
            # Keep explicit CLI overrides; only auto-fill defaults.
            if ([string]$finalAssignee -eq "DeepSeek" -and $route.PSObject.Properties.Name -contains "assignee") {
                $finalAssignee = [string]$route.assignee
            }
            if ([string]$finalReviewer -eq "GitHub gpt-5-mini" -and $route.PSObject.Properties.Name -contains "reviewer") {
                $finalReviewer = [string]$route.reviewer
            }
            if ($route.PSObject.Properties.Name -contains "modelTier") {
                $modelTier = [string]$route.modelTier
            }
            if ($route.PSObject.Properties.Name -contains "tokenPolicy") {
                $tokenPolicy = [string]$route.tokenPolicy
            }
            $fallbackAssignees = Get-RouteFallbackAssignees -Route $route -PrimaryAssignee $finalAssignee
            $routeSource = "routing.json"
        }
    }

    $routingCfg = Get-RoutingConfig
    $usesApiNebula = (Contains-ApiNebula -Text $finalAssignee) -or (Contains-ApiNebula -Text $finalReviewer)
    if ($usesApiNebula) {
        $policyEnabled = $false
        $policyRequireApproval = $true
        $policyFallbackOnlyWhenAllFailed = $true
        if ($routingCfg -and $routingCfg.PSObject.Properties.Name -contains "expensiveProviderPolicy") {
            $pp = $routingCfg.expensiveProviderPolicy
            if ($pp.PSObject.Properties.Name -contains "apinebula") {
                $ap = $pp.apinebula
                if ($ap.PSObject.Properties.Name -contains "enabled") { $policyEnabled = [bool]$ap.enabled }
                if ($ap.PSObject.Properties.Name -contains "requireUserApproval") { $policyRequireApproval = [bool]$ap.requireUserApproval }
                if ($ap.PSObject.Properties.Name -contains "fallbackOnlyWhenAllFailed") { $policyFallbackOnlyWhenAllFailed = [bool]$ap.fallbackOnlyWhenAllFailed }
            }
        }
        if (-not $policyEnabled) {
            throw "apinebula is disabled by routing policy (runtime/routing.json). Enable it explicitly and require user approval before use."
        }
        if ($policyRequireApproval -and -not $ApproveExpensive) {
            throw "apinebula requires explicit user approval. Re-run with -ApproveExpensive only after user confirmation."
        }
        Assert-ApiNebulaEscalationAllowed -ProjectId $Project -FallbackOnlyWhenAllFailed $policyFallbackOnlyWhenAllFailed
    }

    $resolvedWorkerModel = $WorkerModel
    if ([string]::IsNullOrWhiteSpace($resolvedWorkerModel) -and ([string]$finalAssignee).ToLowerInvariant() -eq "ollama") {
        $resolvedWorkerModel = $OllamaModel
    }
    $taskId = ([guid]::NewGuid().ToString("N")).Substring(0, 12)
    $task = [ordered]@{
        id = $taskId
        title = $Title
        status = "ready"
        assignee = $finalAssignee
        reviewer = $finalReviewer
        taskType = $resolvedTaskType
        modelTier = $modelTier
        tokenPolicy = $tokenPolicy
        routeSource = $routeSource
        workerModel = $(if ([string]::IsNullOrWhiteSpace($resolvedWorkerModel)) { $null } else { $resolvedWorkerModel })
        ccSwitchModel = $(if ([string]::IsNullOrWhiteSpace($CcSwitchModel)) { $null } else { $CcSwitchModel })
        fallbackAssignees = @($fallbackAssignees)
        requiredArtifacts = @(Parse-ListArg -Value $Artifacts)
        testCommand = $(if ([string]::IsNullOrWhiteSpace($TestCommand)) { $null } else { $TestCommand })
        maxAttempts = $(if ($MaxAttempts -lt 1) { 1 } else { $MaxAttempts })
        attemptCount = 0
        notes = @()
        dispatchEvidence = @()
        callbackEvidence = @()
        automation = [ordered]@{
            autoAdvanceOnGatePass = [bool]$AutoAdvanceOnGatePass
        }
        createdAt = (Get-Timestamp)
        updatedAt = (Get-Timestamp)
    }

    Write-JsonFile -Path (Join-Path $tasksDir "$taskId.json") -Data $task
    Add-MetricEvent -ProjectId $Project -EventType "created"
    $script:TaskId = $taskId
    Invoke-PrepBrief
    $wm = if ([string]::IsNullOrWhiteSpace([string]$task.workerModel)) { "-" } else { [string]$task.workerModel }
    Write-Host ("[OK] task created: {0} ({1}) assignee={2} reviewer={3} tier={4} model={5}" -f $taskId, $Title, $finalAssignee, $finalReviewer, $modelTier, $wm) -ForegroundColor Green
}

function Invoke-SetTask {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    if ([string]::IsNullOrWhiteSpace($TaskId)) { throw "Please provide -TaskId" }

    $p = Require-Project -ProjectId $Project
    $file = Join-Path (Join-Path $p.Dir "tasks") "$TaskId.json"
    if (-not (Test-Path $file)) { throw "Task not found: $TaskId" }

    $task = Read-JsonFile -Path $file
    if ($Status -eq "in_progress") {
        $tasks = Get-Tasks -ProjectId $Project
        $otherRunning = @($tasks | Where-Object { $_.status -eq "in_progress" -and $_.id -ne $TaskId })
        if ($otherRunning.Count -ge [int]$MaxConcurrentTasks) {
            $runningIds = @($otherRunning | ForEach-Object { $_.id }) -join ", "
            throw ("in_progress cap reached (MaxConcurrentTasks={0}). Current: {1}" -f [int]$MaxConcurrentTasks, $runningIds)
        }
        if (-not $task.leaseUntil) {
            $task | Add-Member -NotePropertyName leaseUntil -NotePropertyValue $null -Force
        }
        $task.leaseUntil = (Get-Date).AddMinutes($LeaseMinutes).ToString("yyyy-MM-ddTHH:mm:ssK")
    }
    if ($Status -ne "in_progress" -and $task.PSObject.Properties.Name -contains "leaseUntil") {
        $task.leaseUntil = $null
    }
    if ($Status) { $task.status = $Status }
    if (-not [string]::IsNullOrWhiteSpace($Note)) {
        $entry = [ordered]@{
            at = (Get-Timestamp)
            text = $Note
        }
        $task.notes += $entry
    }
    if ($Status -eq "blocked") {
        $blockedText = if (-not [string]::IsNullOrWhiteSpace($Note)) { $Note } else {
            if ($task.PSObject.Properties.Name -contains "notes") { @($task.notes | ForEach-Object { [string]$_.text }) -join " | " } else { "" }
        }
        if (-not ($task.PSObject.Properties.Name -contains "blockedReason")) {
            $task | Add-Member -NotePropertyName blockedReason -NotePropertyValue $null -Force
        }
        $task.blockedReason = Get-StandardBlockedReasonFromText -Text $blockedText
    }
    $task.updatedAt = (Get-Timestamp)

    Write-JsonFile -Path $file -Data $task
    Invoke-PrepBrief
    Write-Host "[OK] task updated: $TaskId -> $($task.status)" -ForegroundColor Green
}

function Invoke-Status {
    if (-not (Test-Path $ProjectsDir)) {
        Write-Host "No runtime state. Run: cursor-autolook.ps1 init" -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "Port Plan" -ForegroundColor Cyan
    if (Test-Path $PortsFile) {
        $ports = Read-JsonFile -Path $PortsFile
        Write-Host ("  - reserved: {0}-{1}" -f $ports.reservedRange.start, $ports.reservedRange.end)
        Write-Host ("  - avoid:    {0}-{1}" -f $ports.knownConflictRange.start, $ports.knownConflictRange.end)
        $hubPort = Get-PortValue -Ports $ports -Name "hub" -Fallback $ReservedPortStart
        $apiPort = Get-PortValue -Ports $ports -Name "api" -Fallback ($ReservedPortStart + 1)
        $dashboardPort = Get-PortValue -Ports $ports -Name "dashboard" -Fallback ($ReservedPortStart + 2)
        $reviewerPort = Get-PortValue -Ports $ports -Name "reviewer" -Fallback ($ReservedPortStart + 3)
        $opencodePort = Get-PortValue -Ports $ports -Name "opencode" -Fallback ($ReservedPortStart + 4)
        $deepseekPort = Get-PortValue -Ports $ports -Name "deepseek" -Fallback ($ReservedPortStart + 5)
        $workerQueuePort = Get-PortValue -Ports $ports -Name "workerQueue" -Fallback ($ReservedPortStart + 6)
        $codexPort = Get-PortValue -Ports $ports -Name "codex" -Fallback ($ReservedPortStart + 7)
        Write-Host ("  - hub/api/dashboard/reviewer: {0}/{1}/{2}/{3}" -f $hubPort, $apiPort, $dashboardPort, $reviewerPort)
        Write-Host ("  - opencode/deepseek/worker-queue-http: {0}/{1}/{2}" -f $opencodePort, $deepseekPort, $workerQueuePort)
        Write-Host ("  - codex app-server (ws): {0}" -f $codexPort)
    } else {
        Write-Host ("  - reserved: {0}-{1}" -f $ReservedPortStart, $ReservedPortEnd)
        Write-Host ("  - avoid:    {0}-{1}" -f $KnownConflictStart, $KnownConflictEnd)
    }
    $currentWorkflow = Get-CurrentWorkflow
    if ($currentWorkflow -and $currentWorkflow.PSObject.Properties.Name -contains "projectId") {
        Write-Host ("Current Workflow: {0} (source={1})" -f $currentWorkflow.projectId, $currentWorkflow.source) -ForegroundColor DarkCyan
    }

    $projectDirs = Get-ChildItem -Path $ProjectsDir -Directory -ErrorAction SilentlyContinue
    if (-not $projectDirs) {
        Write-Host "No projects yet." -ForegroundColor Yellow
        return
    }

    foreach ($d in $projectDirs) {
        $projectFile = Join-Path $d.FullName "project.json"
        if (-not (Test-Path $projectFile)) { continue }

        $proj = Read-JsonFile -Path $projectFile
        $taskFiles = Get-ChildItem -Path (Join-Path $d.FullName "tasks") -Filter "*.json" -ErrorAction SilentlyContinue
        $tasks = @()
        foreach ($tf in $taskFiles) {
            $tasks += Read-JsonFile -Path $tf.FullName
        }

        Write-Host ""
        Write-Host "[$($proj.id)] $($proj.name) ($($proj.status))" -ForegroundColor Cyan
        if (-not $tasks -or $tasks.Count -eq 0) {
            Write-Host "  - no tasks" -ForegroundColor DarkGray
            continue
        }

        $groups = $tasks | Group-Object -Property status
        foreach ($g in $groups) {
            Write-Host ("  - {0}: {1}" -f $g.Name, $g.Count)
        }
        $running = @($tasks | Where-Object { $_.status -eq "in_progress" })
        if ($running.Count -gt 0) {
            Write-Host "  - running:"
            foreach ($r in $running) {
                $lease = if ($r.PSObject.Properties.Name -contains "leaseUntil" -and $r.leaseUntil) { $r.leaseUntil } else { "-" }
                Write-Host ("    * {0} ({1}) leaseUntil={2}" -f $r.id, $r.title, $lease) -ForegroundColor DarkGray
            }
        }
    }
}
function Invoke-EnterWorkflow {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    $p = Require-Project -ProjectId $Project
    Set-CurrentWorkflow -ProjectId $Project -Source "enter-workflow"
    $proj = Read-JsonFile -Path $p.File
    $workspace = if ($proj.PSObject.Properties.Name -contains "workspace") { [string]$proj.workspace } else { $Root }

    Write-Host ""
    Write-Host "=== Workflow Context Bootstrap ===" -ForegroundColor Cyan
    Write-Host ("Project:   {0}" -f $Project)
    Write-Host ("Workspace: {0}" -f $workspace)

    Write-Host ""
    Write-Host "--- Status ---" -ForegroundColor DarkCyan
    $script:Project = $Project
    Invoke-Status

    Write-Host ""
    Write-Host "--- Metrics ---" -ForegroundColor DarkCyan
    $script:Project = $Project
    Invoke-Metrics

    $targetTaskId = $TaskId
    if ([string]::IsNullOrWhiteSpace($targetTaskId)) {
        $tasks = @(Get-Tasks -ProjectId $Project | Where-Object { $_.status -in @("in_progress", "ready", "in_review") } | Sort-Object createdAt)
        if ($tasks.Count -gt 0) {
            $targetTaskId = [string]$tasks[0].id
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($targetTaskId)) {
        Write-Host ""
        Write-Host "--- Brief ---" -ForegroundColor DarkCyan
        $script:Project = $Project
        $script:TaskId = $targetTaskId
        Invoke-PrepBrief
        $cacheFile = Get-TaskCacheFile -ProjectId $Project -TaskId $targetTaskId
        if (Test-Path $cacheFile) {
            $cache = Read-JsonFile -Path $cacheFile
            if ($cache.PSObject.Properties.Name -contains "briefPath") {
                Write-Host ("Brief file: {0}" -f [string]$cache.briefPath) -ForegroundColor Green
            }
        }
    } else {
        Write-Host ""
        Write-Host "No runnable task found for brief bootstrap. Pass -TaskId to target a task." -ForegroundColor Yellow
    }
}
function Invoke-Next {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    $p = Require-Project -ProjectId $Project
    $taskFiles = Get-ChildItem -Path (Join-Path $p.Dir "tasks") -Filter "*.json" -ErrorAction SilentlyContinue
    if (-not $taskFiles) {
        Write-Host "No tasks in project: $Project" -ForegroundColor Yellow
        return
    }

    $tasks = @()
    foreach ($tf in $taskFiles) {
        $tasks += Read-JsonFile -Path $tf.FullName
    }

    $next = $tasks | Where-Object { $_.status -eq "ready" } | Sort-Object createdAt | Select-Object -First 1
    if (-not $next) {
        Write-Host "No ready task in project: $Project" -ForegroundColor Yellow
        return
    }

    Write-Host "Next Task:" -ForegroundColor Green
    Write-Host "  id:       $($next.id)"
    Write-Host "  title:    $($next.title)"
    Write-Host "  assignee: $($next.assignee)"
    Write-Host "  reviewer: $($next.reviewer)"
    Write-Host "  status:   $($next.status)"
}

function Invoke-Reconcile {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    $tasks = Get-Tasks -ProjectId $Project
    $now = Get-Date
    $count = 0
    foreach ($t in $tasks) {
        if ($t.status -ne "in_progress") { continue }
        if (-not ($t.PSObject.Properties.Name -contains "leaseUntil")) { continue }
        if (-not $t.leaseUntil) { continue }
        $lease = Parse-DateOrNull -Value ([string]$t.leaseUntil)
        if ($lease -and $lease -lt $now) {
            $file = Get-TaskFilePath -ProjectId $Project -TaskId $t.id
            $task = Read-JsonFile -Path $file
            $task.status = "ready"
            if (-not ($task.PSObject.Properties.Name -contains "leaseUntil")) {
                $task | Add-Member -NotePropertyName leaseUntil -NotePropertyValue $null -Force
            }
            $task.leaseUntil = $null
            if (-not ($task.PSObject.Properties.Name -contains "attemptCount")) {
                $task | Add-Member -NotePropertyName attemptCount -NotePropertyValue 0 -Force
            }
            $task.attemptCount = [int]$task.attemptCount + 1
            if (-not ($task.PSObject.Properties.Name -contains "notes")) {
                $task | Add-Member -NotePropertyName notes -NotePropertyValue @() -Force
            }
            $task.notes += ([ordered]@{
                at = (Get-Timestamp)
                text = "WATCHDOG: stale lease expired, moved back to ready."
            })
            $task.updatedAt = (Get-Timestamp)
            Write-JsonFile -Path $file -Data $task
            Add-MetricEvent -ProjectId $Project -EventType "requeued"
            $count++
        }
    }
    Write-Host "[OK] reconciled stale tasks: $count" -ForegroundColor Green
}

function Invoke-AcceptanceGate {
    param(
        [string]$ProjectId,
        [object]$TaskData
    )
    $result = [ordered]@{
        passed = $true
        reasons = @()
    }

    $workspace = Get-ProjectWorkspace -ProjectId $ProjectId
    $artifacts = @()
    if ($TaskData.PSObject.Properties.Name -contains "requiredArtifacts") {
        $artifacts = @($TaskData.requiredArtifacts)
    }
    foreach ($a in $artifacts) {
        $full = Join-Path $workspace ([string]$a)
        if (-not (Test-Path $full)) {
            $result.passed = $false
            $result.reasons += "missing artifact: $a"
        }
    }

    $cmd = $null
    if ($TaskData.PSObject.Properties.Name -contains "testCommand") {
        $cmd = [string]$TaskData.testCommand
    }
    if (-not [string]::IsNullOrWhiteSpace($cmd)) {
        try {
            & powershell -NoProfile -Command $cmd
            if ($LASTEXITCODE -ne 0) {
                $result.passed = $false
                $result.reasons += "test command failed: $cmd"
            }
        } catch {
            $result.passed = $false
            $result.reasons += "test command exception: $cmd"
        }
    }

    return $result
}
