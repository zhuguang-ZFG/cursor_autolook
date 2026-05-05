param(
    [Parameter(Position = 0)]
    [ValidateSet("help", "init", "new-project", "new-task", "set-task", "status", "next", "check-ports", "reconcile", "watchdog", "review", "dashboard", "quick-check", "e2e-check", "metrics", "prep-brief", "cache-stats", "set-project-prefix", "enter-workflow", "serve-deepseek", "serve-opencode", "current-workflow", "agent-done", "close-open", "consume-callbacks", "watch-callbacks", "dashboard-layout", "set-dashboard-layout", "evolve-dashboard-layout", "evolve-supervisor", "supervisor-evolution", "evolve-routing", "evolve-reliability")]
    [string]$Command = "help",

    [string]$Name,
    [string]$Project,
    [string]$Title,
    [ValidateSet("ready", "in_progress", "in_review", "done", "blocked")]
    [string]$Status,
    [string]$TaskId,
    [string]$Assignee = "DeepSeek",
    [string]$Reviewer = "GitHub gpt-5-mini",
    [string]$Note,
    [string]$Artifacts,
    [string]$TestCommand,
    [string]$TaskType,
    [string]$ProjectPrefix,
    [int]$Interval = 30,
    [int]$MaxRounds = 0,
    [int]$LeaseMinutes = 45,
    [int]$ClaudeCount = -1,
    [int]$MaxAttempts = 3,
    [switch]$AllowInsecure,
    [switch]$NoAutoRoute,
    [switch]$ApproveExpensive,
    [switch]$AutoContinue,
    [switch]$SkipLayoutEvolve,
    [switch]$LayoutAutoEvolve,
    [double]$DashboardMainOpsSplit = -1,
    [double]$DashboardOpenCodeSplit = -1,
    [double]$DashboardDeepseekSplit = -1,
    [double]$DashboardClaudeStackSplit = -1
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSCommandPath
$RuntimeDir = Join-Path $Root "runtime"
$ProjectsDir = Join-Path $RuntimeDir "projects"
$PortsFile = Join-Path $RuntimeDir "ports.json"
$MetricsFile = Join-Path $RuntimeDir "metrics.json"
$AlertsLogFile = Join-Path $RuntimeDir "alerts.log"
$PromptCacheDir = Join-Path $RuntimeDir "prompt-cache"
$CurrentWorkflowFile = Join-Path $RuntimeDir "current-workflow.json"
$RoutingFile = Join-Path $RuntimeDir "routing.json"
$CallbacksDir = Join-Path $RuntimeDir "callbacks"
$CallbacksProcessedDir = Join-Path $CallbacksDir "processed"
$DashboardLayoutFile = Join-Path $RuntimeDir "dashboard-layout.json"
$SupervisorEvolutionFile = Join-Path $RuntimeDir "supervisor-evolution.json"
$ReservedPortStart = 16121
$ReservedPortEnd = 16160
$KnownConflictStart = 15921
$KnownConflictEnd = 15960
$DefaultCacheHitRateThreshold = 30.0

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Get-Timestamp {
    return (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
}

function Parse-DateOrNull {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try {
        return [datetime]::Parse($Value)
    } catch {
        return $null
    }
}

function Get-PortValue {
    param(
        [object]$Ports,
        [string]$Name,
        [int]$Fallback
    )
    if ($Ports -and $Ports.PSObject.Properties.Name -contains "defaults") {
        $defs = $Ports.defaults
        if ($defs -and $defs.PSObject.Properties.Name -contains $Name) {
            return [int]$defs.$Name
        }
    }
    return $Fallback
}

function New-EncodedCommand {
    param([string]$ScriptText)
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($ScriptText)
    return [Convert]::ToBase64String($bytes)
}

function Set-CurrentWorkflow {
    param(
        [string]$ProjectId,
        [string]$Source = "manual"
    )
    if ([string]::IsNullOrWhiteSpace($ProjectId)) { return }
    Ensure-Directory $RuntimeDir
    $data = [ordered]@{
        projectId = $ProjectId
        source = $Source
        updatedAt = (Get-Timestamp)
    }
    Write-JsonFile -Path $CurrentWorkflowFile -Data $data
}

function Get-CurrentWorkflow {
    if (-not (Test-Path $CurrentWorkflowFile)) { return $null }
    return (Read-JsonFile -Path $CurrentWorkflowFile)
}

function Get-RoutingConfig {
    Invoke-Init
    if (-not (Test-Path $RoutingFile)) {
        return $null
    }
    return (Read-JsonFile -Path $RoutingFile)
}

function Resolve-TaskRouting {
    param([string]$ResolvedTaskType)
    $cfg = Get-RoutingConfig
    if (-not $cfg) { return $null }
    if (-not ($cfg.PSObject.Properties.Name -contains "byTaskType")) { return $null }
    $map = $cfg.byTaskType
    $tt = if ([string]::IsNullOrWhiteSpace($ResolvedTaskType)) { "general" } else { $ResolvedTaskType }
    if ($map.PSObject.Properties.Name -contains $tt) {
        return $map.$tt
    }
    if ($map.PSObject.Properties.Name -contains "general") {
        return $map.general
    }
    return $null
}

function Get-RouteFallbackAssignees {
    param(
        [object]$Route,
        [string]$PrimaryAssignee
    )
    $list = @()
    if ($Route -and $Route.PSObject.Properties.Name -contains "fallbackAssignees") {
        $list = @($Route.fallbackAssignees | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ([string]::IsNullOrWhiteSpace($PrimaryAssignee)) {
        return @($list | Select-Object -Unique)
    }
    if ($list.Count -eq 0) {
        return @($PrimaryAssignee)
    }
    $hasPrimary = @($list | Where-Object { $_ -eq $PrimaryAssignee }).Count -gt 0
    if (-not $hasPrimary) {
        $list = @($PrimaryAssignee) + $list
    }
    return @($list | Select-Object -Unique)
}

function Resolve-AssigneeForAttempt {
    param(
        [object]$TaskData,
        [int]$AttemptCount
    )
    $fallback = @()
    if ($TaskData.PSObject.Properties.Name -contains "fallbackAssignees") {
        $fallback = @($TaskData.fallbackAssignees | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    if ($fallback.Count -eq 0) {
        return [string]$TaskData.assignee
    }
    $idx = $AttemptCount
    if ($idx -lt 0) { $idx = 0 }
    if ($idx -ge $fallback.Count) { $idx = $fallback.Count - 1 }
    return [string]$fallback[$idx]
}

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

function Parse-ListArg {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Resolve-TaskType {
    param(
        [string]$RawType,
        [string]$Title
    )
    if (-not [string]::IsNullOrWhiteSpace($RawType)) {
        $v = $RawType.Trim().ToLowerInvariant()
        if ($v -in @("bugfix", "refactor", "review", "general")) { return $v }
    }
    $t = if ($Title) { $Title.ToLowerInvariant() } else { "" }
    if ($t -match "fix|bug|hotfix|crash|error") { return "bugfix" }
    if ($t -match "refactor|cleanup|restructure") { return "refactor" }
    if ($t -match "review|audit|check") { return "review" }
    return "general"
}

function New-Slug {
    param([string]$Value)
    $v = $Value.ToLowerInvariant()
    $v = $v -replace "[^a-z0-9\- ]", ""
    $v = $v -replace "\s+", "-"
    $v = $v.Trim("-")
    if ([string]::IsNullOrWhiteSpace($v)) { return "project" }
    return $v
}

function Get-ProjectDir {
    param([string]$ProjectId)
    return (Join-Path $ProjectsDir $ProjectId)
}

function Require-Project {
    param([string]$ProjectId)
    $dir = Get-ProjectDir -ProjectId $ProjectId
    $file = Join-Path $dir "project.json"
    if (-not (Test-Path $file)) {
        throw "Project not found: $ProjectId"
    }
    return @{ Dir = $dir; File = $file }
}

function Write-JsonFile {
    param(
        [string]$Path,
        [object]$Data
    )
    $json = $Data | ConvertTo-Json -Depth 10
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

function Read-JsonFile {
    param([string]$Path)
    return (Get-Content -Path $Path -Raw | ConvertFrom-Json)
}

function Get-Metrics {
    if (-not (Test-Path $MetricsFile)) {
        return [ordered]@{
            totals = @{
                created = 0
                dispatched = 0
                reviewed = 0
                done = 0
                requeued = 0
                blocked = 0
                cacheHit = 0
                cacheMiss = 0
            }
            projects = @{}
            updatedAt = (Get-Timestamp)
        }
    }
    return Read-JsonFile -Path $MetricsFile
}

function Save-Metrics {
    param([object]$Metrics)
    $Metrics.updatedAt = (Get-Timestamp)
    Write-JsonFile -Path $MetricsFile -Data $Metrics
}

function Get-MetricValue {
    param(
        [object]$Obj,
        [string]$Name
    )
    if ($Obj -and $Obj.PSObject.Properties.Name -contains $Name) {
        return [int]$Obj.$Name
    }
    return 0
}

function Add-MetricEvent {
    param(
        [string]$ProjectId,
        [string]$EventType
    )
    $m = Get-Metrics
    if (-not ($m.PSObject.Properties.Name -contains "projects")) {
        $m | Add-Member -NotePropertyName projects -NotePropertyValue ([pscustomobject]@{}) -Force
    }
    if (-not ($m.projects.PSObject.Properties.Name -contains $ProjectId)) {
        $m.projects | Add-Member -NotePropertyName $ProjectId -NotePropertyValue ([pscustomobject]@{
            created = 0; dispatched = 0; reviewed = 0; done = 0; requeued = 0; blocked = 0; cacheHit = 0; cacheMiss = 0
        }) -Force
    }
    if (-not ($m.totals.PSObject.Properties.Name -contains $EventType)) {
        $m.totals | Add-Member -NotePropertyName $EventType -NotePropertyValue 0 -Force
    }
    $projectMetrics = $m.projects.$ProjectId
    if (-not ($projectMetrics.PSObject.Properties.Name -contains $EventType)) {
        $projectMetrics | Add-Member -NotePropertyName $EventType -NotePropertyValue 0 -Force
    }
    $m.totals.$EventType = [int]$m.totals.$EventType + 1
    $projectMetrics.$EventType = [int]$projectMetrics.$EventType + 1
    Save-Metrics -Metrics $m
}

function Get-PromptPrefix {
    param([string]$TaskType = "general")
    Ensure-Directory $PromptCacheDir
    $type = Resolve-TaskType -RawType $TaskType -Title ""
    $file = Join-Path $PromptCacheDir ("static-prefix-{0}-v1.md" -f $type)
    if (-not (Test-Path $file)) {
        $prefix = switch ($type) {
            "bugfix" {@"
You are a bugfix worker in a cost-sensitive multi-agent workflow.
Rules:
1) Reproduce hypothesis quickly and isolate root cause.
2) Patch minimally; avoid broad refactors.
3) Add/adjust focused tests for regression proof.
4) Keep output concise and evidence-driven.
"@}
            "refactor" {@"
You are a refactor worker in a cost-sensitive multi-agent workflow.
Rules:
1) Preserve behavior; improve structure/readability.
2) Keep changes scoped and reversible.
3) Avoid hidden feature additions.
4) Provide concise rationale for changed boundaries.
"@}
            "review" {@"
You are a review worker in a cost-sensitive multi-agent workflow.
Rules:
1) Prioritize bugs, regressions, and missing tests.
2) Be concise and severity-oriented.
3) Do not rewrite design unless necessary.
4) Provide clear next actions.
"@}
            default {@"
You are a coding worker in a cost-sensitive multi-agent workflow.
Rules:
1) Keep output concise and actionable.
2) Reuse existing context; avoid repeating large unchanged explanations.
3) Provide only task-relevant findings and next steps.
4) Prefer minimal diffs and focused edits.
5) If uncertain, ask one concrete question.
"@}
        }
        Set-Content -Path $file -Value $prefix -Encoding UTF8
    }
    return [pscustomobject]@{
        type = $type
        file = $file
        text = (Get-Content -Path $file -Raw)
    }
}

function Build-DynamicTaskSuffix {
    param(
        [string]$ProjectId,
        [object]$TaskData
    )
    $notes = @()
    if ($TaskData.PSObject.Properties.Name -contains "notes") {
        $notes = @($TaskData.notes | Select-Object -Last 3 | ForEach-Object { [string]$_.text })
    }
    $noteText = if ($notes.Count -gt 0) { $notes -join " | " } else { "(none)" }
    $artifacts = if ($TaskData.PSObject.Properties.Name -contains "requiredArtifacts") { @($TaskData.requiredArtifacts) } else { @() }
    $artifactsText = if ($artifacts.Count -gt 0) { $artifacts -join ", " } else { "(none)" }
    $testCmd = if ($TaskData.PSObject.Properties.Name -contains "testCommand" -and -not [string]::IsNullOrWhiteSpace([string]$TaskData.testCommand)) { [string]$TaskData.testCommand } else { "(none)" }

    return @"
Project: $ProjectId
TaskId: $($TaskData.id)
Title: $($TaskData.title)
Status: $($TaskData.status)
Assignee: $($TaskData.assignee)
Reviewer: $($TaskData.reviewer)
RequiredArtifacts: $artifactsText
TestCommand: $testCmd
RecentNotes: $noteText
"@
}

function Get-SupervisorEvolutionConfig {
    Invoke-Init
    if (-not (Test-Path $SupervisorEvolutionFile)) { return $null }
    return (Read-JsonFile -Path $SupervisorEvolutionFile)
}

function Build-DynamicTaskSuffixHash {
    param(
        [string]$ProjectId,
        [object]$TaskData,
        [bool]$IncludeStatusInHash,
        [int]$RecentNotesCountInHash
    )

    $notes = @()
    if ($TaskData.PSObject.Properties.Name -contains "notes") {
        $notes = @($TaskData.notes | Select-Object -Last $RecentNotesCountInHash | ForEach-Object { [string]$_.text })
    }
    $noteText = if ($notes.Count -gt 0) { $notes -join " | " } else { "(none)" }

    $artifacts = if ($TaskData.PSObject.Properties.Name -contains "requiredArtifacts") { @($TaskData.requiredArtifacts) } else { @() }
    $artifactsText = if ($artifacts.Count -gt 0) { $artifacts -join ", " } else { "(none)" }
    $testCmd = if ($TaskData.PSObject.Properties.Name -contains "testCommand" -and -not [string]::IsNullOrWhiteSpace([string]$TaskData.testCommand)) { [string]$TaskData.testCommand } else { "(none)" }

    $statusLine = ""
    if ($IncludeStatusInHash) {
        $statusLine = "Status: $($TaskData.status)`n"
    }

    return @"
Project: $ProjectId
TaskId: $($TaskData.id)
Title: $($TaskData.title)
$statusLine
Assignee: $($TaskData.assignee)
Reviewer: $($TaskData.reviewer)
RequiredArtifacts: $artifactsText
TestCommand: $testCmd
RecentNotes: $noteText
"@
}

function Invoke-EvolveSupervisor {
    Invoke-Init
    $evo = Get-SupervisorEvolutionConfig
    if (-not $evo) { throw "Missing supervisor evolution config." }

    $m = Get-Metrics
    $cacheHit = Get-MetricValue -Obj $m.totals -Name "cacheHit"
    $cacheMiss = Get-MetricValue -Obj $m.totals -Name "cacheMiss"
    $total = [int]$cacheHit + [int]$cacheMiss

    if ($total -lt [int]$evo.minCacheSamples) {
        Write-Host ("[SKIP] not enough cache samples: samples={0}, min={1}" -f $total, $evo.minCacheSamples) -ForegroundColor Yellow
        return
    }

    $hitRate = [math]::Round((100.0 * [double]$cacheHit / [double]$total), 2)
    $threshold = $evo.cacheHitRateThreshold

    Write-Host ("[Evolve] cacheHitRate={0}% (threshold={1}%), samples={2}" -f $hitRate, $threshold, $total) -ForegroundColor Cyan

    if ($hitRate -ge [double]$threshold) {
        Write-Host "[Evolve] cache hit rate is OK. No evolution applied." -ForegroundColor Green
        return
    }

    if ([int]$evo.stepApplied -ge [int]$evo.maxSteps) {
        Write-Host ("[Evolve] max steps reached: stepApplied={0}" -f $evo.stepApplied) -ForegroundColor Yellow
        return
    }

    $nextStep = [int]$evo.stepApplied
    $newHistory = @([string]::Format("[{0}] cacheHitRate={1}% hit< {2}% -> evolve step {3}", (Get-Timestamp), $hitRate, $threshold, $nextStep))
    $evo.history = @($evo.history + $newHistory)

    # Bounded evolution strategy:
    # step 0: reduce cache key sensitivity to status changes
    # step 1: reduce cache key sensitivity to notes (use only latest 1 note)
    # step 2: stop including notes (RecentNotesCount=0) in cache key
    switch ($nextStep) {
        0 {
            $evo.includeStatusInHash = $false
            break
        }
        1 {
            $evo.recentNotesCountInHash = 1
            break
        }
        2 {
            $evo.recentNotesCountInHash = 0
            break
        }
        default {
            Write-Host ("[Evolve] no rule for step {0}" -f $nextStep) -ForegroundColor Yellow
            return
        }
    }

    $evo.stepApplied = [int]$evo.stepApplied + 1
    $evo.updatedAt = (Get-Timestamp)
    Write-JsonFile -Path $SupervisorEvolutionFile -Data $evo
    Write-Host ("[OK] supervisor evolution applied: stepApplied={0}" -f $evo.stepApplied) -ForegroundColor Green
}

function Get-TaskCacheFile {
    param(
        [string]$ProjectId,
        [string]$TaskId
    )
    $projectCacheDir = Join-Path $PromptCacheDir $ProjectId
    Ensure-Directory $projectCacheDir
    return (Join-Path $projectCacheDir "$TaskId.cache.json")
}

function Get-ProjectPrefixFile {
    param([string]$ProjectId)
    $projectCacheDir = Join-Path $PromptCacheDir $ProjectId
    Ensure-Directory $projectCacheDir
    return (Join-Path $projectCacheDir "project-prefix-v1.md")
}

function Get-ProjectPrefixText {
    param([string]$ProjectId)
    $pFile = Get-ProjectPrefixFile -ProjectId $ProjectId
    if (-not (Test-Path $pFile)) {
        $defaultPrefix = @"
Project invariant context:
- Keep changes scoped to stated task objectives.
- Reuse existing conventions and avoid broad rewrites.
- Prefer minimal token usage and concise outputs.
"@
        Set-Content -Path $pFile -Value $defaultPrefix -Encoding UTF8
    }
    return (Get-Content -Path $pFile -Raw)
}

function Invoke-SetProjectPrefix {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    if ([string]::IsNullOrWhiteSpace($ProjectPrefix)) { throw "Please provide -ProjectPrefix" }
    $pFile = Get-ProjectPrefixFile -ProjectId $Project
    Set-Content -Path $pFile -Value $ProjectPrefix -Encoding UTF8
    Write-Host "[OK] project prefix updated: $pFile" -ForegroundColor Green
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

function Invoke-PrepBrief {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    if ([string]::IsNullOrWhiteSpace($TaskId)) { throw "Please provide -TaskId" }
    $taskFile = Get-TaskFilePath -ProjectId $Project -TaskId $TaskId
    if (-not (Test-Path $taskFile)) { throw "Task not found: $TaskId" }

    Ensure-Directory $PromptCacheDir
    $task = Read-JsonFile -Path $taskFile
    $taskType = if ($task.PSObject.Properties.Name -contains "taskType") { [string]$task.taskType } else { "general" }
    $prefixObj = Get-PromptPrefix -TaskType $taskType
    $projectPrefix = Get-ProjectPrefixText -ProjectId $Project
    $dynamicPrompt = Build-DynamicTaskSuffix -ProjectId $Project -TaskData $task
    $evo = Get-SupervisorEvolutionConfig
    $includeStatusInHash = [bool]$evo.includeStatusInHash
    $recentNotesCountInHash = [int]$evo.recentNotesCountInHash
    $dynamicHash = Build-DynamicTaskSuffixHash -ProjectId $Project -TaskData $task -IncludeStatusInHash $includeStatusInHash -RecentNotesCountInHash $recentNotesCountInHash
    $keySource = ($dynamicHash + "`n" + $prefixObj.text + "`n" + $projectPrefix)
    $hash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($keySource))) -Algorithm SHA256).Hash
    $cacheFile = Get-TaskCacheFile -ProjectId $Project -TaskId $TaskId
    $briefFile = Join-Path (Split-Path -Parent $cacheFile) "$TaskId.brief.md"

    $hit = $false
    if (Test-Path $cacheFile) {
        $cached = Read-JsonFile -Path $cacheFile
        if ($cached.PSObject.Properties.Name -contains "hash" -and [string]$cached.hash -eq $hash) {
            $hit = $true
        }
    }

    if ($hit) {
        Add-MetricEvent -ProjectId $Project -EventType "cacheHit"
        Write-Host "[CACHE HIT] brief unchanged: $briefFile" -ForegroundColor Green
    } else {
        $brief = $projectPrefix + "`n`n---`n`n" + $prefixObj.text + "`n`n---`n`n" + $dynamicPrompt
        Set-Content -Path $briefFile -Value $brief -Encoding UTF8
        Write-JsonFile -Path $cacheFile -Data ([ordered]@{
            hash = $hash
            taskType = $prefixObj.type
            projectPrefixFile = (Get-ProjectPrefixFile -ProjectId $Project)
            briefPath = $briefFile
            updatedAt = (Get-Timestamp)
        })
        Add-MetricEvent -ProjectId $Project -EventType "cacheMiss"
        Write-Host "[CACHE MISS] brief regenerated: $briefFile" -ForegroundColor Yellow
    }
}

function Invoke-CacheStats {
    $m = Get-Metrics
    $cacheHit = Get-MetricValue -Obj $m.totals -Name "cacheHit"
    $cacheMiss = Get-MetricValue -Obj $m.totals -Name "cacheMiss"
    Write-Host ""
    Write-Host "Prompt Cache Stats" -ForegroundColor Cyan
    Write-Host ("  cacheHit={0} cacheMiss={1}" -f $cacheHit, $cacheMiss)
    $total = [int]$cacheHit + [int]$cacheMiss
    if ($total -gt 0) {
        $ratio = [math]::Round((100.0 * [double]$cacheHit / [double]$total), 2)
        Write-Host ("  hitRate={0}%" -f $ratio)
        $threshold = Get-CacheHitRateThreshold
        Write-Host ("  threshold={0}%" -f $threshold)
        Maybe-AlertLowCacheHitRate -HitRate $ratio -Total $total
    } else {
        Write-Host "  hitRate=N/A"
    }
}

function Send-Alert {
    param(
        [string]$Level,
        [string]$ProjectId,
        [string]$TaskId,
        [string]$Message
    )
    Ensure-Directory $RuntimeDir
    $line = "[{0}] [{1}] project={2} task={3} {4}" -f (Get-Timestamp), $Level, $ProjectId, $TaskId, $Message
    Add-Content -Path $AlertsLogFile -Value $line -Encoding UTF8
    $webhook = $env:AUTOLOOK_ALERT_WEBHOOK
    if (-not [string]::IsNullOrWhiteSpace($webhook)) {
        try {
            $payload = @{ text = $line } | ConvertTo-Json
            Invoke-RestMethod -Method Post -Uri $webhook -ContentType "application/json" -Body $payload | Out-Null
        } catch {
            Add-Content -Path $AlertsLogFile -Value ("[{0}] [WARN] webhook send failed: {1}" -f (Get-Timestamp), $_) -Encoding UTF8
        }
    }
}

function Get-CacheHitRateThreshold {
    $raw = $env:AUTOLOOK_CACHE_HITRATE_THRESHOLD
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $DefaultCacheHitRateThreshold
    }
    $value = 0.0
    if ([double]::TryParse($raw, [ref]$value)) {
        if ($value -lt 0) { return 0.0 }
        if ($value -gt 100) { return 100.0 }
        return $value
    }
    return $DefaultCacheHitRateThreshold
}

function Maybe-AlertLowCacheHitRate {
    param(
        [double]$HitRate,
        [int]$Total
    )
    if ($Total -le 0) { return }
    $threshold = Get-CacheHitRateThreshold
    if ($HitRate -lt $threshold) {
        Send-Alert -Level "WARN" -ProjectId "all" -TaskId "-" -Message ("Cache hit rate {0}% is below threshold {1}% (samples={2})" -f $HitRate, $threshold, $Total)
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
                    fallbackAssignees = @("DeepSeek", "Cursor", "OpenCode")
                }
                refactor = [ordered]@{
                    assignee = "OpenCode"
                    reviewer = "GitHub gpt-5-mini"
                    modelTier = "small"
                    tokenPolicy = "strict"
                    fallbackAssignees = @("OpenCode", "DeepSeek", "Cursor")
                }
                review = [ordered]@{
                    assignee = "Claude"
                    reviewer = "GitHub gpt-5-mini"
                    modelTier = "large"
                    tokenPolicy = "quality-first"
                    fallbackAssignees = @("Claude", "DeepSeek", "Cursor")
                }
                general = [ordered]@{
                    assignee = "Cursor"
                    reviewer = "GitHub gpt-5-mini"
                    modelTier = "small"
                    tokenPolicy = "strict"
                    fallbackAssignees = @("Cursor", "DeepSeek", "OpenCode")
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
        fallbackAssignees = @($fallbackAssignees)
        requiredArtifacts = @(Parse-ListArg -Value $Artifacts)
        testCommand = $(if ([string]::IsNullOrWhiteSpace($TestCommand)) { $null } else { $TestCommand })
        maxAttempts = $(if ($MaxAttempts -lt 1) { 1 } else { $MaxAttempts })
        attemptCount = 0
        notes = @()
        dispatchEvidence = @()
        createdAt = (Get-Timestamp)
        updatedAt = (Get-Timestamp)
    }

    Write-JsonFile -Path (Join-Path $tasksDir "$taskId.json") -Data $task
    Add-MetricEvent -ProjectId $Project -EventType "created"
    $script:TaskId = $taskId
    Invoke-PrepBrief
    Write-Host ("[OK] task created: {0} ({1}) assignee={2} reviewer={3} tier={4}" -f $taskId, $Title, $finalAssignee, $finalReviewer, $modelTier) -ForegroundColor Green
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
        if ($otherRunning.Count -gt 0) {
            $runningIds = @($otherRunning | ForEach-Object { $_.id }) -join ", "
            throw "Single-writer lock: already in_progress task(s): $runningIds"
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
        Write-Host ("  - hub/api/dashboard/reviewer: {0}/{1}/{2}/{3}" -f $hubPort, $apiPort, $dashboardPort, $reviewerPort)
        Write-Host ("  - opencode/deepseek: {0}/{1}" -f $opencodePort, $deepseekPort)
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

function Invoke-Watchdog {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    Set-CurrentWorkflow -ProjectId $Project -Source "watchdog"
    $round = 0
    Write-Host "Starting watchdog for project '$Project' (interval=${Interval}s, maxRounds=$MaxRounds)..." -ForegroundColor Cyan
    while ($true) {
        $round++
        $stamp = Get-Date -Format "HH:mm:ss"
        Invoke-Reconcile
        $tasks = Get-Tasks -ProjectId $Project
        $ready = @($tasks | Where-Object { $_.status -eq "ready" } | Sort-Object createdAt)
        $running = @($tasks | Where-Object { $_.status -eq "in_progress" })
        $review = @($tasks | Where-Object { $_.status -eq "in_review" })
        $done = @($tasks | Where-Object { $_.status -eq "done" })
        $blocked = @($tasks | Where-Object { $_.status -eq "blocked" })
        Write-Host "[$stamp] round=$round ready=$($ready.Count) running=$($running.Count) in_review=$($review.Count) done=$($done.Count) blocked=$($blocked.Count)" -ForegroundColor DarkCyan

        if ($running.Count -eq 0 -and $ready.Count -gt 0) {
            $nextTask = $ready[0]
            $maxAttempts = if ($nextTask.PSObject.Properties.Name -contains "maxAttempts") { [int]$nextTask.maxAttempts } else { 3 }
            $attemptCount = if ($nextTask.PSObject.Properties.Name -contains "attemptCount") { [int]$nextTask.attemptCount } else { 0 }
            if ($attemptCount -ge $maxAttempts) {
                $file = Get-TaskFilePath -ProjectId $Project -TaskId $nextTask.id
                $task = Read-JsonFile -Path $file
                $task.status = "blocked"
                if (-not ($task.PSObject.Properties.Name -contains "notes")) {
                    $task | Add-Member -NotePropertyName notes -NotePropertyValue @() -Force
                }
                $task.notes += ([ordered]@{
                    at = (Get-Timestamp)
                    text = "WATCHDOG: blocked after max attempts reached."
                })
                if (-not ($task.PSObject.Properties.Name -contains "dispatchEvidence")) {
                    $task | Add-Member -NotePropertyName dispatchEvidence -NotePropertyValue @() -Force
                }
                $task.dispatchEvidence += ([ordered]@{
                    at = (Get-Timestamp)
                    event = "blocked"
                    reason = "maxAttemptsReached"
                    attemptCount = $attemptCount
                    maxAttempts = $maxAttempts
                    fallbackAssignees = if ($task.PSObject.Properties.Name -contains "fallbackAssignees") { @($task.fallbackAssignees) } else { @() }
                })
                $task.updatedAt = (Get-Timestamp)
                Write-JsonFile -Path $file -Data $task
                Add-MetricEvent -ProjectId $Project -EventType "blocked"
                Send-Alert -Level "ERROR" -ProjectId $Project -TaskId $nextTask.id -Message "Task blocked after max attempts reached."
                Write-Host ("  [blocked] {0} max attempts reached ({1})" -f $nextTask.id, $maxAttempts) -ForegroundColor Yellow
            } else {
            Write-Host ("  [dispatch] {0} - {1}" -f $nextTask.id, $nextTask.title) -ForegroundColor DarkGray
            $file = Get-TaskFilePath -ProjectId $Project -TaskId $nextTask.id
            $task = Read-JsonFile -Path $file
            $task.status = "in_progress"
            $chosenAssignee = Resolve-AssigneeForAttempt -TaskData $task -AttemptCount $attemptCount
            if (-not [string]::IsNullOrWhiteSpace($chosenAssignee)) {
                $task.assignee = $chosenAssignee
            }
            if (-not ($task.PSObject.Properties.Name -contains "leaseUntil")) {
                $task | Add-Member -NotePropertyName leaseUntil -NotePropertyValue $null -Force
            }
            if (-not ($task.PSObject.Properties.Name -contains "attemptCount")) {
                $task | Add-Member -NotePropertyName attemptCount -NotePropertyValue 0 -Force
            }
            $task.attemptCount = [int]$task.attemptCount + 1
            $task.leaseUntil = (Get-Date).AddMinutes($LeaseMinutes).ToString("yyyy-MM-ddTHH:mm:ssK")
            if (-not ($task.PSObject.Properties.Name -contains "notes")) {
                $task | Add-Member -NotePropertyName notes -NotePropertyValue @() -Force
            }
            if (-not ($task.PSObject.Properties.Name -contains "dispatchEvidence")) {
                $task | Add-Member -NotePropertyName dispatchEvidence -NotePropertyValue @() -Force
            }
            $task.notes += ([ordered]@{
                at = (Get-Timestamp)
                text = ("WATCHDOG: auto-dispatched by Cursor hub. assignee={0} attempt={1}/{2}" -f $task.assignee, $task.attemptCount, $maxAttempts)
            })
            $task.dispatchEvidence += ([ordered]@{
                at = (Get-Timestamp)
                event = "dispatch"
                assignee = [string]$task.assignee
                attemptCount = [int]$task.attemptCount
                maxAttempts = [int]$maxAttempts
                leaseUntil = [string]$task.leaseUntil
                fallbackAssignees = if ($task.PSObject.Properties.Name -contains "fallbackAssignees") { @($task.fallbackAssignees) } else { @() }
            })
            $task.updatedAt = (Get-Timestamp)
            Write-JsonFile -Path $file -Data $task
            Add-MetricEvent -ProjectId $Project -EventType "dispatched"
            }
        }

        # Auto review gate: in_review -> done/ready
        foreach ($t in $review) {
            $file = Get-TaskFilePath -ProjectId $Project -TaskId $t.id
            $task = Read-JsonFile -Path $file
            if (-not ($task.PSObject.Properties.Name -contains "notes")) {
                $task | Add-Member -NotePropertyName notes -NotePropertyValue @() -Force
            }
            $text = @($task.notes | ForEach-Object { [string]$_.text }) -join " "
            $acceptance = Invoke-AcceptanceGate -ProjectId $Project -TaskData $task
            $hasIssueKeywords = $text -match "(?i)(fail|bug|missing|regression|blocked)"
            if ($hasIssueKeywords -or -not $acceptance.passed) {
                $task.status = "ready"
                $task.notes += ([ordered]@{
                    at = (Get-Timestamp)
                    text = "AUTO-REVIEW: issues found, moved back to ready. " + (@($acceptance.reasons) -join "; ")
                })
                Add-MetricEvent -ProjectId $Project -EventType "requeued"
            } else {
                $task.status = "done"
                $task.notes += ([ordered]@{
                    at = (Get-Timestamp)
                    text = "AUTO-REVIEW: passed, moved to done."
                })
                Add-MetricEvent -ProjectId $Project -EventType "done"
            }
            Add-MetricEvent -ProjectId $Project -EventType "reviewed"
            if (-not ($task.PSObject.Properties.Name -contains "leaseUntil")) {
                $task | Add-Member -NotePropertyName leaseUntil -NotePropertyValue $null -Force
            }
            $task.leaseUntil = $null
            $task.updatedAt = (Get-Timestamp)
            Write-JsonFile -Path $file -Data $task
            Write-Host ("  [review] {0} -> {1}" -f $t.id, $task.status) -ForegroundColor DarkGray
        }

        if ($MaxRounds -gt 0 -and $round -ge $MaxRounds) {
            Write-Host "Max rounds reached: $MaxRounds" -ForegroundColor Yellow
            break
        }

        if ($ready.Count -eq 0 -and $running.Count -eq 0 -and $review.Count -eq 0) {
            Write-Host "No runnable tasks left. Watchdog exit." -ForegroundColor Green
            break
        }
        Start-Sleep -Seconds $Interval
    }
}

function Invoke-Review {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    if ([string]::IsNullOrWhiteSpace($TaskId)) { throw "Please provide -TaskId" }
    $file = Get-TaskFilePath -ProjectId $Project -TaskId $TaskId
    if (-not (Test-Path $file)) { throw "Task not found: $TaskId" }
    $task = Read-JsonFile -Path $file
    if ($task.status -ne "in_review") { throw "Task is not in_review: $TaskId" }
    if (-not ($task.PSObject.Properties.Name -contains "notes")) {
        $task | Add-Member -NotePropertyName notes -NotePropertyValue @() -Force
    }
    $text = @($task.notes | ForEach-Object { [string]$_.text }) -join " "
    $acceptance = Invoke-AcceptanceGate -ProjectId $Project -TaskData $task
    $hasIssueKeywords = $text -match "(?i)(fail|bug|missing|regression|blocked)"
    if ($hasIssueKeywords -or -not $acceptance.passed) {
        $task.status = "ready"
        $task.notes += ([ordered]@{ at = (Get-Timestamp); text = "AUTO-REVIEW: issues found, moved back to ready. " + (@($acceptance.reasons) -join "; ") })
        Add-MetricEvent -ProjectId $Project -EventType "requeued"
    } else {
        $task.status = "done"
        $task.notes += ([ordered]@{ at = (Get-Timestamp); text = "AUTO-REVIEW: passed, moved to done." })
        Add-MetricEvent -ProjectId $Project -EventType "done"
    }
    Add-MetricEvent -ProjectId $Project -EventType "reviewed"
    if (-not ($task.PSObject.Properties.Name -contains "leaseUntil")) {
        $task | Add-Member -NotePropertyName leaseUntil -NotePropertyValue $null -Force
    }
    $task.leaseUntil = $null
    $task.updatedAt = (Get-Timestamp)
    Write-JsonFile -Path $file -Data $task
    Write-Host "[OK] review decision: $TaskId -> $($task.status)" -ForegroundColor Green
}

function Invoke-Metrics {
    $m = Get-Metrics
    $created = Get-MetricValue -Obj $m.totals -Name "created"
    $dispatched = Get-MetricValue -Obj $m.totals -Name "dispatched"
    $reviewed = Get-MetricValue -Obj $m.totals -Name "reviewed"
    $done = Get-MetricValue -Obj $m.totals -Name "done"
    $requeued = Get-MetricValue -Obj $m.totals -Name "requeued"
    $blocked = Get-MetricValue -Obj $m.totals -Name "blocked"
    $cacheHit = Get-MetricValue -Obj $m.totals -Name "cacheHit"
    $cacheMiss = Get-MetricValue -Obj $m.totals -Name "cacheMiss"
    Write-Host ""
    Write-Host "Metrics Totals" -ForegroundColor Cyan
    Write-Host ("  created={0} dispatched={1} reviewed={2} done={3} requeued={4} blocked={5}" -f
        $created, $dispatched, $reviewed, $done, $requeued, $blocked)
    Write-Host ("  cacheHit={0} cacheMiss={1}" -f $cacheHit, $cacheMiss)
    $cacheTotal = [int]$cacheHit + [int]$cacheMiss
    if ($cacheTotal -gt 0) {
        $cacheRatio = [math]::Round((100.0 * [double]$cacheHit / [double]$cacheTotal), 2)
        $threshold = Get-CacheHitRateThreshold
        Write-Host ("  cacheHitRate={0}% (threshold={1}%)" -f $cacheRatio, $threshold)
        Maybe-AlertLowCacheHitRate -HitRate $cacheRatio -Total $cacheTotal
    }
    Write-Host ("  updatedAt={0}" -f $m.updatedAt) -ForegroundColor DarkGray
    if ($Project) {
        if ($m.projects.PSObject.Properties.Name -contains $Project) {
            $p = $m.projects.$Project
            Write-Host ""
            Write-Host ("Project Metrics [{0}]" -f $Project) -ForegroundColor Cyan
            Write-Host ("  created={0} dispatched={1} reviewed={2} done={3} requeued={4} blocked={5}" -f
                $p.created, $p.dispatched, $p.reviewed, $p.done, $p.requeued, $p.blocked)
        } else {
            Write-Host ("No metrics for project: {0}" -f $Project) -ForegroundColor Yellow
        }
    }
}

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

    $topCmd = "cd '$rootEscaped'; Write-Host '=== Cursor Agent (主控/C位) ===' -ForegroundColor Cyan; if (Get-Command cursor -ErrorAction SilentlyContinue) { cursor agent } else { Write-Host 'cursor command not found, fallback to shell.' -ForegroundColor Yellow; powershell -NoExit }"
    $opsCmd = "cd '$rootEscaped'; while (`$true) { Clear-Host; Write-Host '=== Ops Console ===' -ForegroundColor Cyan; Write-Host 'Project: $projectEscaped' -ForegroundColor DarkCyan; Write-Host ''; powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 status; Write-Host ''; powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 metrics -Project '$projectEscaped'; Write-Host ''; Write-Host 'Callback bridge tick:' -ForegroundColor DarkCyan; powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 consume-callbacks; Write-Host ''; Write-Host 'Commands:' -ForegroundColor DarkCyan; Write-Host '  watchdog: powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 watchdog -Project $projectEscaped'; Write-Host '  cache:    powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 cache-stats'; Write-Host '  review:   powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 review -Project $projectEscaped -TaskId <id>'; Write-Host ''; if (Test-Path '.\runtime\alerts.log') { Write-Host 'Latest alerts:' -ForegroundColor Yellow; Get-Content '.\runtime\alerts.log' | Select-Object -Last 5 }; Start-Sleep -Seconds 8 }"
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
    $topEncoded = New-EncodedCommand -ScriptText $topCmd
    $opsEncoded = New-EncodedCommand -ScriptText $opsCmd
    $bottomLeftEncoded = New-EncodedCommand -ScriptText $bottomLeftCmd
    $deepseekEncoded = New-EncodedCommand -ScriptText $deepseekCmd
    $claudeEncoded = @($claudeCmds | ForEach-Object { New-EncodedCommand -ScriptText $_ })

    # Stable layout:
    # Top: main control + ops
    # Bottom-left: OpenCode
    # Bottom-right: DeepSeek + dynamic Claude panes
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

    & wt @wtArgs | Out-Null
    Write-Host "[OK] dashboard launched: Main-Control + Ops(with callback tick) + OpenCode + DeepSeek+Claude($resolvedClaudeCount)" -ForegroundColor Green
    Write-Host "[INFO] If you are not running inside Windows Terminal, this opens a separate WT window." -ForegroundColor Yellow
}

function Invoke-CheckPorts {
    Invoke-Init
    $ports = Read-JsonFile -Path $PortsFile
    $reservedStart = [int]$ports.reservedRange.start
    $reservedEnd = [int]$ports.reservedRange.end
    $conflictStart = [int]$ports.knownConflictRange.start
    $conflictEnd = [int]$ports.knownConflictRange.end

    Write-Host "Checking port policy..." -ForegroundColor Cyan
    Write-Host ("  reserved: {0}-{1}" -f $reservedStart, $reservedEnd)
    Write-Host ("  avoid:    {0}-{1}" -f $conflictStart, $conflictEnd)

    if (($reservedStart -le $conflictEnd) -and ($reservedEnd -ge $conflictStart)) {
        throw "Reserved port range overlaps with known conflict range."
    }

    $samplePorts = @(
        (Get-PortValue -Ports $ports -Name "hub" -Fallback $ReservedPortStart),
        (Get-PortValue -Ports $ports -Name "api" -Fallback ($ReservedPortStart + 1)),
        (Get-PortValue -Ports $ports -Name "dashboard" -Fallback ($ReservedPortStart + 2)),
        (Get-PortValue -Ports $ports -Name "reviewer" -Fallback ($ReservedPortStart + 3)),
        (Get-PortValue -Ports $ports -Name "opencode" -Fallback ($ReservedPortStart + 4)),
        (Get-PortValue -Ports $ports -Name "deepseek" -Fallback ($ReservedPortStart + 5))
    )

    foreach ($p in $samplePorts) {
        if (($p -lt $reservedStart) -or ($p -gt $reservedEnd)) {
            throw "Default port $p is outside reserved range $reservedStart-$reservedEnd."
        }
        if (($p -ge $conflictStart) -and ($p -le $conflictEnd)) {
            throw "Default port $p conflicts with reserved range used by other repos."
        }
    }

    if ((@($samplePorts | Select-Object -Unique)).Count -ne $samplePorts.Count) {
        throw "Default ports contain duplicates. Please use unique isolated ports."
    }

    Write-Host "[OK] No overlap with autolook/deepseek_autolook port range." -ForegroundColor Green
}

function Invoke-QuickCheck {
    $failed = 0
    $passed = 0
    Write-Host "Running quick self-check..." -ForegroundColor Cyan

    $scriptFiles = @(
        (Join-Path $Root "cursor-autolook.ps1")
    )
    foreach ($f in $scriptFiles) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -eq 0) { $passed++ } else { $failed++; Write-Host "  FAIL syntax: $f" -ForegroundColor Red }
    }

    try {
        Invoke-CheckPorts | Out-Null
        $passed++
    } catch {
        $failed++
        Write-Host "  FAIL ports: $_" -ForegroundColor Red
    }

    if (Test-Path $ProjectsDir) { $passed++ } else { $failed++; Write-Host "  FAIL runtime projects dir missing" -ForegroundColor Red }

    Write-Host ("Quick check: passed={0} failed={1}" -f $passed, $failed) -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Yellow" })
    if ($failed -gt 0) { exit 1 }
}

function Invoke-E2ECheck {
    Invoke-Init
    $testProject = "e2e-check-" + (Get-Date -Format "yyyyMMddHHmmss")
    $taskTitle = "e2e task"
    Write-Host "Running end-to-end check project: $testProject" -ForegroundColor Cyan

    $script:Name = $testProject
    Invoke-NewProject

    $script:Project = $testProject
    $script:Title = $taskTitle
    $script:TestCommand = "exit 0"
    $script:Artifacts = ""
    Invoke-NewTask

    $tasks = @(Get-Tasks -ProjectId $testProject)
    if ($tasks.Count -ne 1) { throw "E2E failed: task create failed" }
    $tid = $tasks[0].id

    $script:Project = $testProject
    $script:Interval = 1
    $script:MaxRounds = 1
    Invoke-Watchdog

    $script:TaskId = $tid
    $script:Status = "in_review"
    $script:Note = "looks good"
    Invoke-SetTask

    $script:TaskId = $tid
    Invoke-Review

    $final = Read-JsonFile -Path (Get-TaskFilePath -ProjectId $testProject -TaskId $tid)
    if ($final.status -ne "done") { throw "E2E failed: final status is $($final.status), expected done" }

    Write-Host "[OK] E2E check passed: ready -> in_progress -> in_review -> done" -ForegroundColor Green
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
            if (-not ($payload.PSObject.Properties.Name -contains "project")) { throw "missing field: project" }
            if (-not ($payload.PSObject.Properties.Name -contains "taskId")) { throw "missing field: taskId" }
            $script:Project = [string]$payload.project
            $script:TaskId = [string]$payload.taskId
            $script:Note = if ($payload.PSObject.Properties.Name -contains "note") { [string]$payload.note } else { "callback queue consumed" }
            $script:AutoContinue = $false
            if ($payload.PSObject.Properties.Name -contains "autoContinue") {
                $script:AutoContinue = [bool]$payload.autoContinue
            }
            Invoke-AgentDone
            $ok++
            Move-Item -Path $f.FullName -Destination (Join-Path $CallbacksProcessedDir ($f.BaseName + ".done.json")) -Force
        } catch {
            $failed++
            $errFile = Join-Path $CallbacksProcessedDir ($f.BaseName + ".error.txt")
            Set-Content -Path $errFile -Value ([string]$_) -Encoding UTF8
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

function Invoke-SupervisorEvolutionStatus {
    Invoke-Init
    $evo = Get-SupervisorEvolutionConfig
    Write-Host "Supervisor Evolution" -ForegroundColor Cyan
    Write-Host ("  stepApplied={0}/{1}" -f $evo.stepApplied, $evo.maxSteps)
    Write-Host ("  includeStatusInHash={0}" -f $evo.includeStatusInHash)
    Write-Host ("  recentNotesCountInHash={0}" -f $evo.recentNotesCountInHash)
    Write-Host ("  minCacheSamples={0}" -f $evo.minCacheSamples)
    Write-Host ("  cacheHitRateThreshold={0}" -f $evo.cacheHitRateThreshold)
    Write-Host ("  updatedAt={0}" -f $evo.updatedAt) -ForegroundColor DarkGray
    if ($evo.history -and @($evo.history).Count -gt 0) {
        Write-Host "  history:" -ForegroundColor DarkCyan
        foreach ($h in @($evo.history | Select-Object -Last 5)) {
            Write-Host ("    - {0}" -f [string]$h)
        }
    }
}

function Get-AgentDefaultTier {
    param([string]$Assignee)
    $name = if ($Assignee) { $Assignee.ToLowerInvariant() } else { "" }
    switch ($name) {
        "cursor" { return "small" }
        "opencode" { return "small" }
        "deepseek" { return "mid" }
        "claude" { return "large" }
        "apinebula" { return "xlarge" }
        default { return "mid" }
    }
}

function Get-TaskOutcomePenalty {
    param([object]$TaskData)
    $reworkPenalty = 0
    if ($TaskData.PSObject.Properties.Name -contains "attemptCount") {
        $attempts = [int]$TaskData.attemptCount
        if ($attempts -gt 1) {
            $reworkPenalty += ($attempts - 1)
        }
    }
    if ($TaskData.PSObject.Properties.Name -contains "notes") {
        $texts = @($TaskData.notes | ForEach-Object { [string]$_.text })
        $reworkPenalty += @($texts | Where-Object { $_ -match "AUTO-REVIEW: issues found" }).Count
    }
    return $reworkPenalty
}

function Get-TaskHistoryFiles {
    $taskFiles = @()
    $projectDirs = @(Get-ChildItem -Path $ProjectsDir -Directory -ErrorAction SilentlyContinue)
    foreach ($pd in $projectDirs) {
        $taskDir = Join-Path $pd.FullName "tasks"
        if (Test-Path $taskDir) {
            $taskFiles += @(Get-ChildItem -Path $taskDir -Filter "*.json" -File -ErrorAction SilentlyContinue)
        }
    }
    return @($taskFiles)
}

function Invoke-EvolveRouting {
    Invoke-Init
    $routing = Read-JsonFile -Path $RoutingFile
    $evo = Get-SupervisorEvolutionConfig

    if (-not ($evo.PSObject.Properties.Name -contains "routingEvolution")) {
        $evo | Add-Member -NotePropertyName routingEvolution -NotePropertyValue ([pscustomobject]@{
            minSamplesPerTaskType = 2
            minScoreDelta = 2
            maxAdjustmentsPerRun = 2
            updatedAt = (Get-Timestamp)
            history = @()
        }) -Force
        Write-JsonFile -Path $SupervisorEvolutionFile -Data $evo
    }

    $cfg = $evo.routingEvolution
    $taskFiles = @()
    $projectDirs = @(Get-ChildItem -Path $ProjectsDir -Directory -ErrorAction SilentlyContinue)
    foreach ($pd in $projectDirs) {
        $taskDir = Join-Path $pd.FullName "tasks"
        if (Test-Path $taskDir) {
            $taskFiles += @(Get-ChildItem -Path $taskDir -Filter "*.json" -File -ErrorAction SilentlyContinue)
        }
    }
    if ($taskFiles.Count -eq 0) {
        Write-Host "[SKIP] no task history for routing evolution." -ForegroundColor Yellow
        return
    }

    $taskStats = @{}
    foreach ($tf in $taskFiles) {
        $task = Read-JsonFile -Path $tf.FullName
        $taskType = if ($task.PSObject.Properties.Name -contains "taskType") { [string]$task.taskType } else { "general" }
        $assignee = if ($task.PSObject.Properties.Name -contains "assignee") { [string]$task.assignee } else { "" }
        $status = if ($task.PSObject.Properties.Name -contains "status") { [string]$task.status } else { "" }

        if ([string]::IsNullOrWhiteSpace($assignee)) { continue }
        if (Contains-ApiNebula -Text $assignee) { continue }
        if ($status -notin @("done", "blocked")) { continue }

        if (-not $taskStats.ContainsKey($taskType)) {
            $taskStats[$taskType] = @{}
        }
        if (-not $taskStats[$taskType].ContainsKey($assignee)) {
            $taskStats[$taskType][$assignee] = [ordered]@{ samples = 0; done = 0; blocked = 0; score = 0 }
        }

        $row = $taskStats[$taskType][$assignee]
        $row.samples = [int]$row.samples + 1
        if ($status -eq "done") {
            $row.done = [int]$row.done + 1
            $row.score = [int]$row.score + 2
        } elseif ($status -eq "blocked") {
            $row.blocked = [int]$row.blocked + 1
            $row.score = [int]$row.score - 3
        }
    }

    $adjustments = 0
    $routeTouched = $false
    $historyLines = @()
    foreach ($taskType in @("bugfix", "refactor", "review", "general")) {
        if (-not $taskStats.ContainsKey($taskType)) { continue }
        $agentTable = $taskStats[$taskType]
        $candidates = @($agentTable.Keys | ForEach-Object {
            $r = $agentTable[$_]
            [pscustomobject]@{
                assignee = [string]$_
                samples = [int]$r.samples
                done = [int]$r.done
                blocked = [int]$r.blocked
                score = [int]$r.score
            }
        } | Where-Object { $_.samples -ge [int]$cfg.minSamplesPerTaskType } | Sort-Object score, done, samples -Descending)

        if ($candidates.Count -eq 0) { continue }
        $best = $candidates[0]
        $current = $routing.byTaskType.$taskType
        $currentAssignee = [string]$current.assignee
        $fallbackRank = @($candidates | Select-Object -ExpandProperty assignee)
        if ($fallbackRank.Count -gt 0) {
            $current.fallbackAssignees = @($fallbackRank | Select-Object -First 4)
            $routeTouched = $true
        }

        $currentCandidate = $candidates | Where-Object { $_.assignee -eq $currentAssignee } | Select-Object -First 1
        $currentScore = if ($currentCandidate) { [int]$currentCandidate.score } else { -999 }
        $delta = [int]$best.score - [int]$currentScore

        if ($best.assignee -ne $currentAssignee -and $delta -ge [int]$cfg.minScoreDelta -and $adjustments -lt [int]$cfg.maxAdjustmentsPerRun) {
            $current.assignee = $best.assignee
            $current.modelTier = Get-AgentDefaultTier -Assignee $best.assignee
            $adjustments++
            $routeTouched = $true
            $historyLines += ("[{0}] taskType={1} assignee {2} -> {3} (score delta={4}, samples={5})" -f (Get-Timestamp), $taskType, $currentAssignee, $best.assignee, $delta, $best.samples)
        }
    }

    if (-not $routeTouched) {
        Write-Host "[EvolveRouting] no bounded routing change applied." -ForegroundColor Yellow
        return
    }

    $routing.updatedAt = (Get-Timestamp)
    Write-JsonFile -Path $RoutingFile -Data $routing
    $cfg.updatedAt = (Get-Timestamp)
    $cfg.history = @($cfg.history + $historyLines)
    $evo.updatedAt = (Get-Timestamp)
    Write-JsonFile -Path $SupervisorEvolutionFile -Data $evo
    Write-Host ("[OK] routing evolution applied: adjustments={0}" -f $adjustments) -ForegroundColor Green
    foreach ($line in $historyLines) {
        Write-Host ("  - {0}" -f $line) -ForegroundColor DarkCyan
    }
}

function Invoke-EvolveReliability {
    Invoke-Init
    $routing = Read-JsonFile -Path $RoutingFile
    $evo = Get-SupervisorEvolutionConfig

    if (-not ($evo.PSObject.Properties.Name -contains "reliabilityEvolution")) {
        $evo | Add-Member -NotePropertyName reliabilityEvolution -NotePropertyValue ([pscustomobject]@{
            minSamplesPerReviewer = 2
            minScoreDelta = 2
            maxAdjustmentsPerRun = 2
            updatedAt = (Get-Timestamp)
            history = @()
        }) -Force
        Write-JsonFile -Path $SupervisorEvolutionFile -Data $evo
    }

    $cfg = $evo.reliabilityEvolution
    $taskFiles = Get-TaskHistoryFiles
    if ($taskFiles.Count -eq 0) {
        Write-Host "[SKIP] no task history for reliability evolution." -ForegroundColor Yellow
        return
    }

    $reviewerStats = @{}
    $assigneeStats = @{}

    foreach ($tf in $taskFiles) {
        $task = Read-JsonFile -Path $tf.FullName
        $taskType = if ($task.PSObject.Properties.Name -contains "taskType") { [string]$task.taskType } else { "general" }
        $status = if ($task.PSObject.Properties.Name -contains "status") { [string]$task.status } else { "" }
        if ($status -notin @("done", "blocked")) { continue }

        $penalty = Get-TaskOutcomePenalty -TaskData $task
        $baseScore = if ($status -eq "done") { 2 } else { -3 }
        $finalScore = $baseScore - $penalty

        $assignee = if ($task.PSObject.Properties.Name -contains "assignee") { [string]$task.assignee } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($assignee) -and -not (Contains-ApiNebula -Text $assignee)) {
            if (-not $assigneeStats.ContainsKey($assignee)) {
                $assigneeStats[$assignee] = [ordered]@{ samples = 0; done = 0; blocked = 0; rework = 0; score = 0 }
            }
            $a = $assigneeStats[$assignee]
            $a.samples = [int]$a.samples + 1
            if ($status -eq "done") { $a.done = [int]$a.done + 1 } else { $a.blocked = [int]$a.blocked + 1 }
            $a.rework = [int]$a.rework + $penalty
            $a.score = [int]$a.score + $finalScore
        }

        $reviewer = if ($task.PSObject.Properties.Name -contains "reviewer") { [string]$task.reviewer } else { "" }
        if ([string]::IsNullOrWhiteSpace($reviewer) -or (Contains-ApiNebula -Text $reviewer)) { continue }
        if (-not $reviewerStats.ContainsKey($taskType)) {
            $reviewerStats[$taskType] = @{}
        }
        if (-not $reviewerStats[$taskType].ContainsKey($reviewer)) {
            $reviewerStats[$taskType][$reviewer] = [ordered]@{ samples = 0; done = 0; blocked = 0; rework = 0; score = 0 }
        }
        $r = $reviewerStats[$taskType][$reviewer]
        $r.samples = [int]$r.samples + 1
        if ($status -eq "done") { $r.done = [int]$r.done + 1 } else { $r.blocked = [int]$r.blocked + 1 }
        $r.rework = [int]$r.rework + $penalty
        $r.score = [int]$r.score + $finalScore
    }

    $adjustments = 0
    $historyLines = @()
    foreach ($taskType in @("bugfix", "refactor", "review", "general")) {
        if (-not $reviewerStats.ContainsKey($taskType)) { continue }
        $table = $reviewerStats[$taskType]
        $candidates = @($table.Keys | ForEach-Object {
            $row = $table[$_]
            [pscustomobject]@{
                reviewer = [string]$_
                samples = [int]$row.samples
                done = [int]$row.done
                blocked = [int]$row.blocked
                rework = [int]$row.rework
                score = [int]$row.score
            }
        } | Where-Object { $_.samples -ge [int]$cfg.minSamplesPerReviewer } | Sort-Object score, done, samples -Descending)

        if ($candidates.Count -eq 0) { continue }
        $best = $candidates[0]
        $current = $routing.byTaskType.$taskType
        $currentReviewer = [string]$current.reviewer
        $currentCandidate = $candidates | Where-Object { $_.reviewer -eq $currentReviewer } | Select-Object -First 1
        $currentScore = if ($currentCandidate) { [int]$currentCandidate.score } else { -999 }
        $delta = [int]$best.score - [int]$currentScore

        if ($best.reviewer -ne $currentReviewer -and $delta -ge [int]$cfg.minScoreDelta -and $adjustments -lt [int]$cfg.maxAdjustmentsPerRun) {
            $current.reviewer = $best.reviewer
            $adjustments++
            $historyLines += ("[{0}] taskType={1} reviewer {2} -> {3} (score delta={4}, samples={5})" -f (Get-Timestamp), $taskType, $currentReviewer, $best.reviewer, $delta, $best.samples)
        }
    }

    if ($adjustments -gt 0) {
        $routing.updatedAt = (Get-Timestamp)
        Write-JsonFile -Path $RoutingFile -Data $routing
        $cfg.updatedAt = (Get-Timestamp)
        $cfg.history = @($cfg.history + $historyLines)
        $evo.updatedAt = (Get-Timestamp)
        Write-JsonFile -Path $SupervisorEvolutionFile -Data $evo
        Write-Host ("[OK] reliability evolution applied: adjustments={0}" -f $adjustments) -ForegroundColor Green
        foreach ($line in $historyLines) {
            Write-Host ("  - {0}" -f $line) -ForegroundColor DarkCyan
        }
    } else {
        Write-Host "[EvolveReliability] no bounded reviewer change applied." -ForegroundColor Yellow
    }

    Write-Host "Agent Reliability Snapshot" -ForegroundColor Cyan
    foreach ($name in @($assigneeStats.Keys | Sort-Object)) {
        $row = $assigneeStats[$name]
        Write-Host ("  {0}: score={1} samples={2} done={3} blocked={4} rework={5}" -f $name, $row.score, $row.samples, $row.done, $row.blocked, $row.rework) -ForegroundColor DarkGray
    }
}

function Show-Help {
    Write-Host ""
    Write-Host "Cursor Autolook — Cursor as execution hub" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  init"
    Write-Host "  new-project -Name <name>"
    Write-Host "  new-task -Project <project-id> -Title <title> [-TaskType bugfix|refactor|review|general] [-Assignee ...] [-Reviewer ...] [-Artifacts a,b] [-TestCommand ...] [-MaxAttempts N]"
    Write-Host "           [-NoAutoRoute]                            # disable model routing for this task"
    Write-Host "           [-ApproveExpensive]                       # required when policy demands explicit approval"
    Write-Host "  set-task -Project <project-id> -TaskId <id> [-Status ready|in_progress|in_review|done|blocked] [-Note ...]"
    Write-Host "  agent-done -Project <project-id> -TaskId <id> [-Note ...] [-AutoContinue]"
    Write-Host "  close-open [-Project <project-id>]                 # one-click close non-blocked open tasks"
    Write-Host "  consume-callbacks                                  # consume runtime/callbacks/*.json queue"
    Write-Host "  watch-callbacks [-Interval 30] [-MaxRounds 0]     # continuously consume callback queue"
    Write-Host "  status"
    Write-Host "  next -Project <project-id>"
    Write-Host "  reconcile -Project <project-id>"
    Write-Host "  watchdog -Project <project-id> [-Interval 30] [-MaxRounds 0] [-LeaseMinutes 45]"
    Write-Host "  review -Project <project-id> -TaskId <id>"
    Write-Host "  prep-brief -Project <project-id> -TaskId <id>     # build cache-friendly prompt brief"
    Write-Host "  cache-stats                                        # prompt cache hit/miss stats"
    Write-Host "  set-project-prefix -Project <project-id> -ProjectPrefix <text>"
    Write-Host "  enter-workflow -Project <project-id> [-TaskId <id>]   # bootstrap status/metrics/brief"
    Write-Host "  current-workflow                                   # show active workflow marker"
    Write-Host "  routing config: runtime/routing.json               # task routing + expensive provider policy"
    Write-Host "                                                     # apinebula: default disabled; require approval; only when others all blocked"
    Write-Host "  dashboard -Project <project-id> [-ClaudeCount N]   # top main + bottom-left opencode + right stack"
    Write-Host "  evolve-supervisor                                  # bounded cache-key evolution from runtime evidence"
    Write-Host "  evolve-routing                                     # bounded assignee/modelTier evolution from task outcomes"
    Write-Host "  evolve-reliability                                 # bounded reviewer evolution + agent reliability snapshot"
    Write-Host "  supervisor-evolution                               # show evolution config and recent steps"
    Write-Host "  serve-deepseek                                      # start deepseek runtime api on isolated port"
    Write-Host "  serve-opencode [-AllowInsecure]                     # start opencode headless server on isolated port"
    Write-Host "  metrics [-Project <project-id>]"
    Write-Host "  check-ports"
    Write-Host "  quick-check"
    Write-Host "  e2e-check"
    Write-Host ""
}

switch ($Command) {
    "init"        { Invoke-Init }
    "new-project" { Invoke-NewProject }
    "new-task"    { Invoke-NewTask }
    "set-task"    { Invoke-SetTask }
    "agent-done"  { Invoke-AgentDone }
    "close-open"  { Invoke-CloseOpen }
    "consume-callbacks" { Invoke-ConsumeCallbacks }
    "watch-callbacks" { Invoke-WatchCallbacks }
    "status"      { Invoke-Status }
    "next"        { Invoke-Next }
    "reconcile"   { Invoke-Reconcile }
    "watchdog"    { Invoke-Watchdog }
    "review"      { Invoke-Review }
    "prep-brief"  { Invoke-PrepBrief }
    "cache-stats" { Invoke-CacheStats }
    "set-project-prefix" { Invoke-SetProjectPrefix }
    "enter-workflow" { Invoke-EnterWorkflow }
    "current-workflow" { Invoke-CurrentWorkflow }
    "dashboard"   { Invoke-Dashboard }
    "evolve-supervisor" { Invoke-EvolveSupervisor }
    "evolve-routing" { Invoke-EvolveRouting }
    "evolve-reliability" { Invoke-EvolveReliability }
    "supervisor-evolution" { Invoke-SupervisorEvolutionStatus }
    "serve-deepseek" { Invoke-ServeDeepSeek }
    "serve-opencode" { Invoke-ServeOpenCode }
    "metrics"     { Invoke-Metrics }
    "check-ports" { Invoke-CheckPorts }
    "quick-check" { Invoke-QuickCheck }
    "e2e-check"   { Invoke-E2ECheck }
    default       { Show-Help }
}
