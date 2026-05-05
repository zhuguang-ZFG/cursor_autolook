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
