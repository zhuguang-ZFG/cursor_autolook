param(
    [Parameter(Position = 0)]
    [string]$Project,
    [int]$Interval = 30
)

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
$Cli = Join-Path $Root "cursor-autolook.ps1"
$resolver = Join-Path $PSScriptRoot "Resolve-AutolookProject.ps1"
$proj = & $resolver -PreferredProject $Project
Write-Host ("[Autolook] watchdog -Project {0} -Interval {1}" -f $proj, $Interval) -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $Cli watchdog -Project $proj -Interval $Interval
