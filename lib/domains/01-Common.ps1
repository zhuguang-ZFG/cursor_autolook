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

function Is-OpenCodeAssignee {
    param([string]$Assignee)
    if ([string]::IsNullOrWhiteSpace($Assignee)) { return $false }
    return ([string]$Assignee).ToLowerInvariant().Contains("opencode")
}

function Get-OpenCodeThrottle {
    if (-not (Test-Path $OpenCodeThrottleFile)) {
        return [ordered]@{
            active = $false
            until = $null
            reason = $null
            sourceTaskId = $null
            updatedAt = $null
        }
    }
    $s = Read-JsonFile -Path $OpenCodeThrottleFile
    $until = if ($s.PSObject.Properties.Name -contains "until") { Parse-DateOrNull -Value ([string]$s.until) } else { $null }
    $isActive = $false
    if ($until -and $until -gt (Get-Date)) { $isActive = $true }
    return [ordered]@{
        active = $isActive
        until = if ($until) { $until.ToString("yyyy-MM-ddTHH:mm:ssK") } else { $null }
        reason = if ($s.PSObject.Properties.Name -contains "reason") { [string]$s.reason } else { $null }
        sourceTaskId = if ($s.PSObject.Properties.Name -contains "sourceTaskId") { [string]$s.sourceTaskId } else { $null }
        updatedAt = if ($s.PSObject.Properties.Name -contains "updatedAt") { [string]$s.updatedAt } else { $null }
    }
}

function Set-OpenCodeThrottle {
    param(
        [int]$BackoffSeconds,
        [string]$Reason,
        [string]$SourceTaskId
    )
    $until = (Get-Date).AddSeconds($BackoffSeconds)
    $data = [ordered]@{
        until = $until.ToString("yyyy-MM-ddTHH:mm:ssK")
        reason = $Reason
        sourceTaskId = $SourceTaskId
        updatedAt = (Get-Timestamp)
    }
    Write-JsonFile -Path $OpenCodeThrottleFile -Data $data
}

function Resolve-OpenCodeFallbackAssignee {
    param([object]$TaskData)
    $candidates = @()
    if ($TaskData.PSObject.Properties.Name -contains "fallbackAssignees") {
        $candidates += @($TaskData.fallbackAssignees | ForEach-Object { [string]$_ })
    }
    if ($TaskData.PSObject.Properties.Name -contains "assignee") {
        $candidates += @([string]$TaskData.assignee)
    }
    $candidates += @("DeepSeek", "Cursor", "Claude")
    foreach ($a in $candidates) {
        if ([string]::IsNullOrWhiteSpace($a)) { continue }
        if (-not (Is-OpenCodeAssignee -Assignee $a)) { return [string]$a }
    }
    return $null
}

function Is-OllamaAssignee {
    param([string]$Assignee)
    if ([string]::IsNullOrWhiteSpace($Assignee)) { return $false }
    return ([string]$Assignee).Trim().Equals("Ollama", [StringComparison]::OrdinalIgnoreCase)
}

function Resolve-OllamaFallbackAssignee {
    param([object]$TaskData)
    $candidates = @()
    if ($TaskData.PSObject.Properties.Name -contains "fallbackAssignees") {
        $candidates += @($TaskData.fallbackAssignees | ForEach-Object { [string]$_ })
    }
    if ($TaskData.PSObject.Properties.Name -contains "assignee") {
        $candidates += @([string]$TaskData.assignee)
    }
    $candidates += @("Cursor", "DeepSeek", "OpenCode", "Claude")
    foreach ($a in $candidates) {
        if ([string]::IsNullOrWhiteSpace($a)) { continue }
        if (-not (Is-OllamaAssignee -Assignee $a)) { return [string]$a }
    }
    return $null
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
