param(
    [Parameter(Position = 0)]
    [ValidateSet("help", "init", "new-project", "new-task", "set-task", "status", "next", "check-ports", "reconcile", "watchdog", "review", "dashboard", "quick-check", "e2e-check", "metrics")]
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
    [int]$Interval = 30,
    [int]$MaxRounds = 0,
    [int]$LeaseMinutes = 45,
    [int]$ClaudeCount = -1,
    [int]$MaxAttempts = 3
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSCommandPath
$RuntimeDir = Join-Path $Root "runtime"
$ProjectsDir = Join-Path $RuntimeDir "projects"
$PortsFile = Join-Path $RuntimeDir "ports.json"
$MetricsFile = Join-Path $RuntimeDir "metrics.json"
$AlertsLogFile = Join-Path $RuntimeDir "alerts.log"
$ReservedPortStart = 16121
$ReservedPortEnd = 16160
$KnownConflictStart = 15921
$KnownConflictEnd = 15960

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Get-Timestamp {
    return (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
}

function Parse-ListArg {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
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
            created = 0; dispatched = 0; reviewed = 0; done = 0; requeued = 0; blocked = 0
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
            }
            createdAt = (Get-Timestamp)
            updatedAt = (Get-Timestamp)
        }
        Write-JsonFile -Path $PortsFile -Data $ports
    }
    if (-not (Test-Path $MetricsFile)) {
        Save-Metrics -Metrics (Get-Metrics)
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

    $taskId = ([guid]::NewGuid().ToString("N")).Substring(0, 12)
    $task = [ordered]@{
        id = $taskId
        title = $Title
        status = "ready"
        assignee = $Assignee
        reviewer = $Reviewer
        requiredArtifacts = @(Parse-ListArg -Value $Artifacts)
        testCommand = $(if ([string]::IsNullOrWhiteSpace($TestCommand)) { $null } else { $TestCommand })
        maxAttempts = $(if ($MaxAttempts -lt 1) { 1 } else { $MaxAttempts })
        attemptCount = 0
        notes = @()
        createdAt = (Get-Timestamp)
        updatedAt = (Get-Timestamp)
    }

    Write-JsonFile -Path (Join-Path $tasksDir "$taskId.json") -Data $task
    Add-MetricEvent -ProjectId $Project -EventType "created"
    Write-Host "[OK] task created: $taskId ($Title)" -ForegroundColor Green
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
        Write-Host ("  - hub/api/dashboard/reviewer: {0}/{1}/{2}/{3}" -f $ports.defaults.hub, $ports.defaults.api, $ports.defaults.dashboard, $ports.defaults.reviewer)
    } else {
        Write-Host ("  - reserved: {0}-{1}" -f $ReservedPortStart, $ReservedPortEnd)
        Write-Host ("  - avoid:    {0}-{1}" -f $KnownConflictStart, $KnownConflictEnd)
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
        $lease = $null
        if ([datetime]::TryParse([string]$t.leaseUntil, [ref]$lease) -and $lease -lt $now) {
            $file = Get-TaskFilePath -ProjectId $Project -TaskId $t.id
            $task = Read-JsonFile -Path $file
            $task.status = "ready"
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
            $task.notes += ([ordered]@{
                at = (Get-Timestamp)
                text = "WATCHDOG: auto-dispatched by Cursor hub."
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
    $task.leaseUntil = $null
    $task.updatedAt = (Get-Timestamp)
    Write-JsonFile -Path $file -Data $task
    Write-Host "[OK] review decision: $TaskId -> $($task.status)" -ForegroundColor Green
}

function Invoke-Metrics {
    $m = Get-Metrics
    Write-Host ""
    Write-Host "Metrics Totals" -ForegroundColor Cyan
    Write-Host ("  created={0} dispatched={1} reviewed={2} done={3} requeued={4} blocked={5}" -f
        $m.totals.created, $m.totals.dispatched, $m.totals.reviewed, $m.totals.done, $m.totals.requeued, $m.totals.blocked)
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

    $topCmd = "cd '$rootEscaped'; Write-Host '=== Cursor Agent (主控/C位) ===' -ForegroundColor Cyan; if (Get-Command cursor -ErrorAction SilentlyContinue) { cursor agent } else { Write-Host 'cursor command not found, fallback to shell.' -ForegroundColor Yellow; powershell -NoExit }"
    $bottomLeftCmd = "cd '$rootEscaped'; Write-Host '=== OpenCode ===' -ForegroundColor Cyan; if (Get-Command opencode -ErrorAction SilentlyContinue) { opencode } else { Write-Host 'opencode command not found.' -ForegroundColor Yellow; powershell -NoExit }"
    $deepseekCmd = "cd '$rootEscaped'; Write-Host '=== DeepSeek-TUI ===' -ForegroundColor Cyan; if (Get-Command deepseek -ErrorAction SilentlyContinue) { deepseek } else { Write-Host 'deepseek command not found.' -ForegroundColor Yellow; powershell -NoExit }"
    $claudeCmds = @(
        "cd '$rootEscaped'; Write-Host '=== Claude-1 ===' -ForegroundColor Cyan; if (Get-Command claude -ErrorAction SilentlyContinue) { claude } else { Write-Host 'claude command not found.' -ForegroundColor Yellow; powershell -NoExit }",
        "cd '$rootEscaped'; Write-Host '=== Claude-2 ===' -ForegroundColor Cyan; if (Get-Command claude -ErrorAction SilentlyContinue) { claude } else { Write-Host 'claude command not found.' -ForegroundColor Yellow; powershell -NoExit }",
        "cd '$rootEscaped'; Write-Host '=== Claude-3 ===' -ForegroundColor Cyan; if (Get-Command claude -ErrorAction SilentlyContinue) { claude } else { Write-Host 'claude command not found.' -ForegroundColor Yellow; powershell -NoExit }",
        "cd '$rootEscaped'; Write-Host '=== Claude-4 ===' -ForegroundColor Cyan; if (Get-Command claude -ErrorAction SilentlyContinue) { claude } else { Write-Host 'claude command not found.' -ForegroundColor Yellow; powershell -NoExit }",
        "cd '$rootEscaped'; Write-Host '=== Claude-5 ===' -ForegroundColor Cyan; if (Get-Command claude -ErrorAction SilentlyContinue) { claude } else { Write-Host 'claude command not found.' -ForegroundColor Yellow; powershell -NoExit }",
        "cd '$rootEscaped'; Write-Host '=== Claude-6 ===' -ForegroundColor Cyan; if (Get-Command claude -ErrorAction SilentlyContinue) { claude } else { Write-Host 'claude command not found.' -ForegroundColor Yellow; powershell -NoExit }"
    )

    # Layout (similar to user screenshot):
    # Top: main control pane (Cursor Agent)
    # Bottom-left: OpenCode
    # Bottom-right: vertical queue (DeepSeek + dynamic Claude panes)
    $wtArgs = @(
        "-w", "0", "new-tab", "--title", "Main-Control", "powershell", "-NoExit", "-Command", $topCmd,
        ";", "split-pane", "-V", "--size", "0.38", "--title", "OpenCode", "powershell", "-NoExit", "-Command", $bottomLeftCmd,
        ";", "focus-pane", "-t", "1",
        ";", "split-pane", "-H", "--size", "0.66", "--title", "DeepSeek-TUI", "powershell", "-NoExit", "-Command", $deepseekCmd
    )

    # Right column starts at pane index 2; stack Claude panes vertically there.
    for ($i = 0; $i -lt $resolvedClaudeCount; $i++) {
        $wtArgs += @(";", "focus-pane", "-t", "2")
        $wtArgs += @(";", "split-pane", "-V", "--size", "0.66", "--title", "Claude-$($i+1)", "powershell", "-NoExit", "-Command", $claudeCmds[$i])
    }

    & wt @wtArgs | Out-Null
    Write-Host "[OK] dashboard launched: top=Main-Control, bottom-left=OpenCode, right-column=DeepSeek+Claude($resolvedClaudeCount)" -ForegroundColor Green
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
        [int]$ports.defaults.hub,
        [int]$ports.defaults.api,
        [int]$ports.defaults.dashboard,
        [int]$ports.defaults.reviewer
    )

    foreach ($p in $samplePorts) {
        if (($p -ge $conflictStart) -and ($p -le $conflictEnd)) {
            throw "Default port $p conflicts with reserved range used by other repos."
        }
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

function Show-Help {
    Write-Host ""
    Write-Host "Cursor Autolook — Cursor as execution hub" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  init"
    Write-Host "  new-project -Name <name>"
    Write-Host "  new-task -Project <project-id> -Title <title> [-Assignee ...] [-Reviewer ...] [-Artifacts a,b] [-TestCommand ...] [-MaxAttempts N]"
    Write-Host "  set-task -Project <project-id> -TaskId <id> [-Status ready|in_progress|in_review|done|blocked] [-Note ...]"
    Write-Host "  status"
    Write-Host "  next -Project <project-id>"
    Write-Host "  reconcile -Project <project-id>"
    Write-Host "  watchdog -Project <project-id> [-Interval 30] [-MaxRounds 0] [-LeaseMinutes 45]"
    Write-Host "  review -Project <project-id> -TaskId <id>"
    Write-Host "  dashboard -Project <project-id> [-ClaudeCount N]   # top main + bottom-left opencode + right stack"
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
    "status"      { Invoke-Status }
    "next"        { Invoke-Next }
    "reconcile"   { Invoke-Reconcile }
    "watchdog"    { Invoke-Watchdog }
    "review"      { Invoke-Review }
    "dashboard"   { Invoke-Dashboard }
    "metrics"     { Invoke-Metrics }
    "check-ports" { Invoke-CheckPorts }
    "quick-check" { Invoke-QuickCheck }
    "e2e-check"   { Invoke-E2ECheck }
    default       { Show-Help }
}
