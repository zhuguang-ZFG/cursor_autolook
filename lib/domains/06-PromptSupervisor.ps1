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
    $ur = ""
    if ($TaskData.PSObject.Properties.Name -contains "userRequest" -and -not [string]::IsNullOrWhiteSpace([string]$TaskData.userRequest)) {
        $ur = [string]$TaskData.userRequest
    }
    $userReqText = if ([string]::IsNullOrWhiteSpace($ur)) { "(none)" } else { $ur }

    return @"
Project: $ProjectId
TaskId: $($TaskData.id)
Title: $($TaskData.title)
Status: $($TaskData.status)
Assignee: $($TaskData.assignee)
Reviewer: $($TaskData.reviewer)
UserRequest: $userReqText
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
    $ur = ""
    if ($TaskData.PSObject.Properties.Name -contains "userRequest" -and -not [string]::IsNullOrWhiteSpace([string]$TaskData.userRequest)) {
        $ur = [string]$TaskData.userRequest
    }
    $userReqText = if ([string]::IsNullOrWhiteSpace($ur)) { "(none)" } else { $ur }

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
UserRequest: $userReqText
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
    $newHistory = @([string]::Format("[{0}] cacheHitRate={1}% hit below {2}% -> evolve step {3}", (Get-Timestamp), $hitRate, $threshold, $nextStep))
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
