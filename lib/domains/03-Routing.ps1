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
