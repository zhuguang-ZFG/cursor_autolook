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
        "ollama" { return "small" }
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
