function Resolve-GoProjectId {
    $resolver = Join-Path $Root "scripts\Resolve-AutolookProject.ps1"
    if (-not (Test-Path -LiteralPath $resolver)) {
        throw "Missing $resolver"
    }
    $explicit = [string]$Project
    if ([string]::IsNullOrWhiteSpace($explicit)) {
        try {
            $explicit = [string]$script:Project
        } catch {
            $explicit = ""
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($explicit)) {
        return (& $resolver -PreferredProject $explicit.Trim())
    }
    return (& $resolver)
}

function Invoke-GoWorkflow {
    try {
        $proj = Resolve-GoProjectId
    } catch {
        throw "go: $($_.Exception.Message)"
    }
    $script:Project = $proj
    Write-Host ("[go] enter-workflow -Project {0}" -f $proj) -ForegroundColor Cyan
    Invoke-EnterWorkflow
}

function Invoke-GoWatch {
    $cli = Join-Path $Root "cursor-autolook.ps1"
    if (-not (Test-Path -LiteralPath $cli)) {
        throw "Missing $cli"
    }
    Invoke-GoWorkflow
    $p = [string]$script:Project
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $iv = [string][int]$Interval
    $childArgs = @()
    if (-not [bool]$ScheduleBackground) {
        $childArgs += "-NoExit"
    }
    $childArgs += @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $cli,
        "watchdog", "-Project", $p, "-Interval", $iv)
    $sp = @{
        FilePath         = $psExe
        WorkingDirectory = $Root
        ArgumentList     = $childArgs
    }
    if ([bool]$ScheduleBackground) {
        $sp["WindowStyle"] = "Hidden"
    }
    Start-Process @sp
    $where = if ([bool]$ScheduleBackground) { "hidden background host" } else { "a new PowerShell window (Ctrl+C there to stop)" }
    Write-Host ("[schedule / go-watch] Watchdog started in {0}." -f $where) -ForegroundColor Green
}

function Invoke-GoHub {
    $cli = Join-Path $Root "cursor-autolook.ps1"
    if (-not (Test-Path -LiteralPath $cli)) {
        throw "Missing $cli"
    }
    Invoke-GoWorkflow
    $p = [string]$script:Project
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $hubArgs = @()
    if (-not [bool]$ScheduleBackground) {
        $hubArgs += "-NoExit"
    }
    $hubArgs += @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $cli,
        "automation-hub", "-Project", $p, "-Interval", "10")
    $spHub = @{
        FilePath         = $psExe
        WorkingDirectory = $Root
        ArgumentList     = $hubArgs
    }
    if ([bool]$ScheduleBackground) {
        $spHub["WindowStyle"] = "Hidden"
    }
    Start-Process @spHub
    $hubWhere = if ([bool]$ScheduleBackground) { "hidden background host" } else { "a new PowerShell window (Ctrl+C there to stop)" }
    Write-Host ("[schedule-hub / go-hub] automation-hub started in {0}." -f $hubWhere) -ForegroundColor Green
    if ([bool]$ScheduleBackground) {
        Write-Host "  Tip: stop with Task Manager -> find powershell.exe child running cursor-autolook automation-hub, or: Get-Process powershell | Stop-Process (careful)." -ForegroundColor DarkGray
    }
}
