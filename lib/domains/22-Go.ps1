function Resolve-GoProjectId {
    $resolver = Join-Path $Root "scripts\Resolve-AutolookProject.ps1"
    if (-not (Test-Path -LiteralPath $resolver)) {
        throw "Missing $resolver"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$Project)) {
        return (& $resolver -PreferredProject ([string]$Project).Trim())
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
    Start-Process -FilePath $psExe -WorkingDirectory $Root `
        -ArgumentList @("-NoExit", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $cli,
        "watchdog", "-Project", $p, "-Interval", $iv)
    Write-Host "[go-watch] Watchdog opened in a new PowerShell window (Ctrl+C there to stop)." -ForegroundColor Green
}

function Invoke-GoHub {
    $cli = Join-Path $Root "cursor-autolook.ps1"
    if (-not (Test-Path -LiteralPath $cli)) {
        throw "Missing $cli"
    }
    Invoke-GoWorkflow
    $p = [string]$script:Project
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    Start-Process -FilePath $psExe -WorkingDirectory $Root `
        -ArgumentList @("-NoExit", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $cli,
        "automation-hub", "-Project", $p, "-Interval", "10")
    Write-Host "[go-hub] automation-hub opened in a new PowerShell window (Ctrl+C there to stop)." -ForegroundColor Green
}
