param(
    [Parameter(Position = 0)]
    [ValidateSet("help", "init", "new-project", "new-task", "set-task", "status", "next", "check-ports", "reconcile", "watchdog", "quick-check")]
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
    [int]$Interval = 30,
    [int]$MaxRounds = 0,
    [int]$LeaseMinutes = 45
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSCommandPath
$RuntimeDir = Join-Path $Root "runtime"
$ProjectsDir = Join-Path $RuntimeDir "projects"
$PortsFile = Join-Path $RuntimeDir "ports.json"
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
        notes = @()
        createdAt = (Get-Timestamp)
        updatedAt = (Get-Timestamp)
    }

    Write-JsonFile -Path (Join-Path $tasksDir "$taskId.json") -Data $task
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
            if (-not ($task.PSObject.Properties.Name -contains "notes")) {
                $task | Add-Member -NotePropertyName notes -NotePropertyValue @() -Force
            }
            $task.notes += ([ordered]@{
                at = (Get-Timestamp)
                text = "WATCHDOG: stale lease expired, moved back to ready."
            })
            $task.updatedAt = (Get-Timestamp)
            Write-JsonFile -Path $file -Data $task
            $count++
        }
    }
    Write-Host "[OK] reconciled stale tasks: $count" -ForegroundColor Green
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
            Write-Host ("  [dispatch] {0} - {1}" -f $nextTask.id, $nextTask.title) -ForegroundColor DarkGray
            $file = Get-TaskFilePath -ProjectId $Project -TaskId $nextTask.id
            $task = Read-JsonFile -Path $file
            $task.status = "in_progress"
            if (-not ($task.PSObject.Properties.Name -contains "leaseUntil")) {
                $task | Add-Member -NotePropertyName leaseUntil -NotePropertyValue $null -Force
            }
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

function Show-Help {
    Write-Host ""
    Write-Host "Cursor Autolook — Cursor as execution hub" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Commands:"
    Write-Host "  init"
    Write-Host "  new-project -Name <name>"
    Write-Host "  new-task -Project <project-id> -Title <title> [-Assignee ...] [-Reviewer ...]"
    Write-Host "  set-task -Project <project-id> -TaskId <id> [-Status ready|in_progress|in_review|done|blocked] [-Note ...]"
    Write-Host "  status"
    Write-Host "  next -Project <project-id>"
    Write-Host "  reconcile -Project <project-id>"
    Write-Host "  watchdog -Project <project-id> [-Interval 30] [-MaxRounds 0] [-LeaseMinutes 45]"
    Write-Host "  check-ports"
    Write-Host "  quick-check"
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
    "check-ports" { Invoke-CheckPorts }
    "quick-check" { Invoke-QuickCheck }
    default       { Show-Help }
}
