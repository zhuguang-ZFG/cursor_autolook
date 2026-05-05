param(
    [string]$AutoLookRoot = "",
    [string]$Project = "",
    [switch]$VisibleWindow,
    [ValidateRange(0, 600)]
    [int]$DelaySeconds = 45,
    [ValidateLength(1, 200)]
    [string]$TaskName = "CursorAutolook-ScheduleHubLogon",
    [switch]$Unregister
)

$ErrorActionPreference = "Stop"

if ([bool]$Unregister) {
    $t = Get-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue
    if (-not $t) {
        Write-Host "[OK] No task named '$TaskName' (nothing to remove)." -ForegroundColor Yellow
        exit 0
    }
    Unregister-ScheduledTask -TaskName $TaskName -TaskPath "\" -Confirm:$false | Out-Null
    Write-Host "[OK] Unregistered: $TaskName" -ForegroundColor Green
    exit 0
}

function Resolve-AutolookRoot {
    param([string]$Prefer)
    if (-not [string]::IsNullOrWhiteSpace($Prefer)) {
        $p = [string]$Prefer.TrimEnd('\')
        if (-not (Test-Path -LiteralPath (Join-Path $p "cursor-autolook.ps1"))) {
            throw "AUTOLOOK_ROOT invalid (missing cursor-autolook.ps1): $p"
        }
        return $p
    }
    $envRoot = [string]$env:AUTOLOOK_REPO
    if (-not [string]::IsNullOrWhiteSpace($envRoot)) {
        try { return (Resolve-AutolookRoot -Prefer $envRoot) }
        catch { }
    }
    $parent = Split-Path -Parent $PSScriptRoot
    if (Test-Path -LiteralPath (Join-Path $parent "cursor-autolook.ps1")) {
        return $parent
    }
    throw "Set -AutoLookRoot or env AUTOLOOK_REPO to repo root containing cursor-autolook.ps1"
}

$resolvedRoot = Resolve-AutolookRoot -Prefer $AutoLookRoot
$who = [string]$env:USERNAME
if ([string]::IsNullOrWhiteSpace($who)) {
    throw "USERNAME empty; cannot build logon trigger."
}

$psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$cli = Join-Path $resolvedRoot "cursor-autolook.ps1"
$fileQuoted = '"' + $cli.Replace('"', '""') + '"'

$tokens = New-Object System.Collections.ArrayList
[void]$tokens.AddRange(@(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $fileQuoted,
        "schedule-hub"
    ))

if (-not [bool]$VisibleWindow) {
    [void]$tokens.Add("-ScheduleBackground")
}

$projTrim = if ([string]::IsNullOrWhiteSpace($Project)) { "" } else { $Project.Trim() }
if (-not [string]::IsNullOrWhiteSpace($projTrim)) {
    [void]$tokens.Add("-Project")
    [void]$tokens.Add(('"' + $projTrim.Replace('"', '') + '"'))
}

$argumentLine = ($tokens -join " ")

Get-ScheduledTask -TaskName $TaskName -TaskPath "\" -ErrorAction SilentlyContinue |
    ForEach-Object { Unregister-ScheduledTask -TaskName $TaskName -TaskPath "\" -Confirm:$false | Out-Null }

$action = New-ScheduledTaskAction -Execute $psExe `
    -WorkingDirectory $resolvedRoot `
    -Argument $argumentLine

$trigger = New-ScheduledTaskTrigger -AtLogOn -User $who
if ([int]$DelaySeconds -gt 0) {
    try {
        $trigger.Delay = ("PT{0}S" -f [int]$DelaySeconds)
    }
    catch {
        Write-Host "[WARN] This OS might not honor trigger Delay; omit or upgrade. ($($_.Exception.Message))" -ForegroundColor Yellow
    }
}

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew

$principal = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Limited

Register-ScheduledTask `
    -TaskName $TaskName `
    -TaskPath "\" `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description ("Starts Cursor Autolook schedule-hub at logon. Repo: " + $resolvedRoot) `
    | Out-Null

Write-Host ""
Write-Host "[OK] Registered scheduled task: $TaskName" -ForegroundColor Green
Write-Host "     Trigger: at log on user $who" -ForegroundColor DarkCyan
if ([int]$DelaySeconds -gt 0) {
    Write-Host ("     Delay:   {0}s after logon" -f [int]$DelaySeconds) -ForegroundColor DarkCyan
}
Write-Host "     Repo:    $resolvedRoot" -ForegroundColor DarkGray
if ([string]::IsNullOrWhiteSpace($projTrim)) {
    Write-Host "     Project: (resolve at runtime via current-workflow / first project)" -ForegroundColor DarkGray
}
else {
    Write-Host "     Project: $projTrim" -ForegroundColor DarkGray
}
Write-Host ("     Hub UI: {0}" -f $(if ([bool]$VisibleWindow) { "visible watchdog window (-ScheduleBackground omitted)" } else { "hidden child host (-ScheduleBackground)" })) -ForegroundColor DarkGray
Write-Host ""
Write-Host ('Remove later: .\scripts\Register-AutolookLogonTask.ps1 -Unregister [-TaskName "' + $TaskName + '"]') -ForegroundColor DarkYellow
