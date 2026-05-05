function Invoke-OpsReport {
    Invoke-Init
    $taskFiles = Get-TaskHistoryFiles
    if ($taskFiles.Count -eq 0) {
        Write-Host "No task history found." -ForegroundColor Yellow
        return
    }

    $tasks = @($taskFiles | ForEach-Object { Read-JsonFile -Path $_.FullName })

    # Build project buckets from filesystem for accurate project id
    $projectDirs = @(Get-ChildItem -Path $ProjectsDir -Directory -ErrorAction SilentlyContinue)
    $generatedAt = (Get-Timestamp)
    $reportLines = New-Object System.Collections.ArrayList
    [void]$reportLines.Add("# Ops Report")
    [void]$reportLines.Add("")
    [void]$reportLines.Add(("GeneratedAt: {0}" -f $generatedAt))
    Write-Host "Ops Report" -ForegroundColor Cyan
    Write-Host ("GeneratedAt: {0}" -f $generatedAt) -ForegroundColor DarkGray

    foreach ($pd in $projectDirs) {
        $projId = $pd.Name
        if (-not [string]::IsNullOrWhiteSpace($Project) -and $Project -ne $projId) { continue }
        $pTaskFiles = @(Get-ChildItem -Path (Join-Path $pd.FullName "tasks") -Filter "*.json" -File -ErrorAction SilentlyContinue)
        if ($pTaskFiles.Count -eq 0) { continue }
        $pTasks = @($pTaskFiles | ForEach-Object { Read-JsonFile -Path $_.FullName })

        $total = $pTasks.Count
        $done = @($pTasks | Where-Object { $_.status -eq "done" }).Count
        $blocked = @($pTasks | Where-Object { $_.status -eq "blocked" }).Count
        $ready = @($pTasks | Where-Object { $_.status -eq "ready" }).Count
        $inProgress = @($pTasks | Where-Object { $_.status -eq "in_progress" }).Count
        $inReview = @($pTasks | Where-Object { $_.status -eq "in_review" }).Count
        $successRate = if ($total -gt 0) { [math]::Round(100.0 * $done / $total, 2) } else { 0 }
        $blockedRate = if ($total -gt 0) { [math]::Round(100.0 * $blocked / $total, 2) } else { 0 }

        $attemptValues = @($pTasks | ForEach-Object {
            if ($_.PSObject.Properties.Name -contains "attemptCount") { [int]$_.attemptCount } else { 0 }
        })
        $avgAttempts = if ($attemptValues.Count -gt 0) { [math]::Round(($attemptValues | Measure-Object -Average).Average, 2) } else { 0 }

        $switchTransitions = 0
        foreach ($t in $pTasks) {
            if (-not ($t.PSObject.Properties.Name -contains "dispatchEvidence")) { continue }
            $dispatches = @($t.dispatchEvidence | Where-Object { $_.event -eq "dispatch" })
            if ($dispatches.Count -lt 2) { continue }
            $assignees = @($dispatches | ForEach-Object { [string]$_.assignee })
            for ($i = 1; $i -lt $assignees.Count; $i++) {
                if ($assignees[$i] -ne $assignees[$i - 1]) { $switchTransitions++ }
            }
        }

        $blockedReasons = @{}
        $modelDone = @{}
        $modelActive = @{}
        $ccSwitchDone = @{}
        $modelCompareTotal = 0
        $modelCompareMatched = 0
        foreach ($t in @($pTasks | Where-Object { $_.status -eq "blocked" })) {
            $r = Get-BlockedReason -TaskData $t
            if (-not $blockedReasons.ContainsKey($r)) { $blockedReasons[$r] = 0 }
            $blockedReasons[$r] = [int]$blockedReasons[$r] + 1
        }
        foreach ($t in $pTasks) {
            $modelKey = if ($t.PSObject.Properties.Name -contains "workerModel" -and -not [string]::IsNullOrWhiteSpace([string]$t.workerModel)) { [string]$t.workerModel } else { [string]$t.assignee }
            $ccModelKey = $null
            if (Test-CcSwitchTruthVerified -TaskData $t) {
                $ccModelKey = [string]$t.ccSwitchModel
            }
            if ($t.status -eq "done") {
                if (-not $modelDone.ContainsKey($modelKey)) { $modelDone[$modelKey] = 0 }
                $modelDone[$modelKey] = [int]$modelDone[$modelKey] + 1
                if (-not [string]::IsNullOrWhiteSpace([string]$ccModelKey)) {
                    if (-not $ccSwitchDone.ContainsKey($ccModelKey)) { $ccSwitchDone[$ccModelKey] = 0 }
                    $ccSwitchDone[$ccModelKey] = [int]$ccSwitchDone[$ccModelKey] + 1
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$modelKey) -and -not [string]::IsNullOrWhiteSpace([string]$ccModelKey)) {
                    $modelCompareTotal++
                    if ($modelKey.ToLowerInvariant() -eq $ccModelKey.ToLowerInvariant()) {
                        $modelCompareMatched++
                    }
                }
            } elseif ($t.status -in @("ready", "in_progress", "in_review")) {
                if (-not $modelActive.ContainsKey($modelKey)) { $modelActive[$modelKey] = 0 }
                $modelActive[$modelKey] = [int]$modelActive[$modelKey] + 1
            }
        }
        $reasonText = if ($blockedReasons.Keys.Count -eq 0) {
            "(none)"
        } else {
            @($blockedReasons.Keys | Sort-Object | ForEach-Object { "{0}:{1}" -f $_, $blockedReasons[$_] }) -join ", "
        }
        $modelDoneText = if ($modelDone.Keys.Count -eq 0) {
            "(none)"
        } else {
            @($modelDone.Keys | Sort-Object | ForEach-Object { "{0}:{1}" -f $_, $modelDone[$_] }) -join ", "
        }
        $modelActiveText = if ($modelActive.Keys.Count -eq 0) {
            "(none)"
        } else {
            @($modelActive.Keys | Sort-Object | ForEach-Object { "{0}:{1}" -f $_, $modelActive[$_] }) -join ", "
        }
        $ccSwitchDoneText = if ($ccSwitchDone.Keys.Count -eq 0) {
            "(none)"
        } else {
            @($ccSwitchDone.Keys | Sort-Object | ForEach-Object { "{0}:{1}" -f $_, $ccSwitchDone[$_] }) -join ", "
        }
        $modelMatchRate = if ($modelCompareTotal -gt 0) { [math]::Round((100.0 * $modelCompareMatched / $modelCompareTotal), 2) } else { 0 }

        Write-Host ""
        Write-Host ("[{0}]" -f $projId) -ForegroundColor DarkCyan
        Write-Host ("  total={0} done={1} blocked={2} ready={3} in_progress={4} in_review={5}" -f $total, $done, $blocked, $ready, $inProgress, $inReview)
        Write-Host ("  successRate={0}% blockedRate={1}% avgAttempts={2}" -f $successRate, $blockedRate, $avgAttempts)
        Write-Host ("  fallbackSwitchTransitions={0}" -f $switchTransitions)
        Write-Host ("  blockedReasons={0}" -f $reasonText)
        Write-Host ("  modelDone(reported)={0}" -f $modelDoneText)
        Write-Host ("  modelDone(cc-switch)={0}" -f $ccSwitchDoneText)
        Write-Host ("  modelMatchRate={0}% ({1}/{2})" -f $modelMatchRate, $modelCompareMatched, $modelCompareTotal)
        Write-Host ("  modelActive={0}" -f $modelActiveText)
        [void]$reportLines.Add("")
        [void]$reportLines.Add(("## [{0}]" -f $projId))
        [void]$reportLines.Add(("total={0} done={1} blocked={2} ready={3} in_progress={4} in_review={5}" -f $total, $done, $blocked, $ready, $inProgress, $inReview))
        [void]$reportLines.Add(("successRate={0}% blockedRate={1}% avgAttempts={2}" -f $successRate, $blockedRate, $avgAttempts))
        [void]$reportLines.Add(("fallbackSwitchTransitions={0}" -f $switchTransitions))
        [void]$reportLines.Add(("blockedReasons={0}" -f $reasonText))
        [void]$reportLines.Add(("modelDone(reported)={0}" -f $modelDoneText))
        [void]$reportLines.Add(("modelDone(cc-switch)={0}" -f $ccSwitchDoneText))
        [void]$reportLines.Add(("modelMatchRate={0}% ({1}/{2})" -f $modelMatchRate, $modelCompareMatched, $modelCompareTotal))
        [void]$reportLines.Add(("modelActive={0}" -f $modelActiveText))
    }
    Ensure-Directory $ReportsDir
    $safeName = if ([string]::IsNullOrWhiteSpace($Project)) { "all-projects" } else { $Project }
    $safeName = ($safeName -replace "[^a-zA-Z0-9\\-_]", "_")
    $out = Join-Path $ReportsDir ("ops-report-{0}-{1}.md" -f $safeName, (Get-Date -Format "yyyyMMddHHmmss"))
    Set-Content -Path $out -Value (@($reportLines.ToArray()) -join [Environment]::NewLine) -Encoding UTF8
    Write-Host ("[OK] ops-report markdown: {0}" -f $out) -ForegroundColor Green
}
