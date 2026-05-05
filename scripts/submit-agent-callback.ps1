param(
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [string]$Note = "external callback",
    [switch]$AutoContinue
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$runtime = Join-Path $root "runtime"
$callbacks = Join-Path $runtime "callbacks"
if (-not (Test-Path $callbacks)) { New-Item -ItemType Directory -Path $callbacks | Out-Null }

$payload = [ordered]@{
    project = $Project
    taskId = $TaskId
    note = $Note
    autoContinue = [bool]$AutoContinue
    createdAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
}

$name = "{0}-{1}.json" -f $Project, ([guid]::NewGuid().ToString("N").Substring(0, 8))
$path = Join-Path $callbacks $name
$payload | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
Write-Host ("[OK] callback queued: {0}" -f $path) -ForegroundColor Green
