function Get-StandardBlockedReasonFromText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return "manualBlocked" }
    $t = $Text.ToLowerInvariant()
    if ($t -match "max attempts reached") { return "maxAttemptsReached" }
    if ($t -match "missing artifact") { return "missingArtifact" }
    if ($t -match "test command failed|test command exception") { return "testCommandFailed" }
    if ($t -match "429|rate\s*limit|too\s*many\s*requests|quota\s*exceeded") { return "rateLimited" }
    if ($t -match "chaos|inject") { return "chaosInjected" }
    if ($t -match "auto-review: issues found|acceptance") { return "acceptanceFailed" }
    if ($t -match "manual|blocked") { return "manualBlocked" }
    return "manualBlocked"
}

function Test-CcSwitchTruthVerified {
    param([object]$TaskData)
    if (-not ($TaskData.PSObject.Properties.Name -contains "ccSwitchModel")) { return $false }
    $ccModel = [string]$TaskData.ccSwitchModel
    if ([string]::IsNullOrWhiteSpace($ccModel)) { return $false }
    if (-not ($TaskData.PSObject.Properties.Name -contains "callbackEvidence")) { return $false }
    $events = @($TaskData.callbackEvidence)
    if ($events.Count -eq 0) { return $false }
    foreach ($ev in ($events | Select-Object -Last 5)) {
        $evModel = if ($ev.PSObject.Properties.Name -contains "ccSwitchModel") { [string]$ev.ccSwitchModel } else { "" }
        $evSource = if ($ev.PSObject.Properties.Name -contains "source") { [string]$ev.source } else { "" }
        $evTrace = if ($ev.PSObject.Properties.Name -contains "traceId") { [string]$ev.traceId } else { "" }
        $evSession = if ($ev.PSObject.Properties.Name -contains "sessionId") { [string]$ev.sessionId } else { "" }
        if ($evModel -eq $ccModel -and $evSource -eq "cc-switch" -and -not [string]::IsNullOrWhiteSpace($evTrace) -and -not [string]::IsNullOrWhiteSpace($evSession)) {
            return $true
        }
    }
    return $false
}

function Get-BlockedReason {
    param([object]$TaskData)
    if ($TaskData.PSObject.Properties.Name -contains "blockedReason" -and -not [string]::IsNullOrWhiteSpace([string]$TaskData.blockedReason)) {
        return [string]$TaskData.blockedReason
    }
    if ($TaskData.PSObject.Properties.Name -contains "dispatchEvidence") {
        $ev = @($TaskData.dispatchEvidence | Where-Object { $_.event -eq "blocked" } | Select-Object -Last 1)
        if ($ev.Count -gt 0 -and $ev[0].PSObject.Properties.Name -contains "reason") {
            return [string]$ev[0].reason
        }
    }
    if ($TaskData.PSObject.Properties.Name -contains "notes") {
        $txt = @($TaskData.notes | ForEach-Object { [string]$_.text }) -join " | "
        return (Get-StandardBlockedReasonFromText -Text $txt)
    }
    return "unknown"
}
