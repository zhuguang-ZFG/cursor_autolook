param(
    [Parameter(Position = 0)]
    [string]$Project
)

$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent
$Cli = Join-Path $Root "cursor-autolook.ps1"
$resolver = Join-Path $PSScriptRoot "Resolve-AutolookProject.ps1"
$proj = & $resolver -PreferredProject $Project
Write-Host ("[Autolook] dashboard -Project {0}" -f $proj) -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File $Cli dashboard -Project $proj
