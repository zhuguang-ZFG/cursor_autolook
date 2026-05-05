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
