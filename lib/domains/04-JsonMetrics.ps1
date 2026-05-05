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
