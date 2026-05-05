param(
    [Parameter(Position = 0)]
    [string]$Project,
    [int]$Interval = 10
)

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
$Cli = Join-Path $Root "cursor-autolook.ps1"
$resolver = Join-Path $PSScriptRoot "Resolve-AutolookProject.ps1"
$proj = & $resolver -PreferredProject $Project
Write-Host ("[Autolook] automation-hub -Project {0} -Interval {1}" -f $proj, $Interval) -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $Cli automation-hub -Project $proj -Interval $Interval
