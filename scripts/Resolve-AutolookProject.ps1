param(
    [Parameter(Position = 0)]
    [string]$PreferredProject
)

$ErrorActionPreference = "Stop"

$Root = Split-Path $PSScriptRoot -Parent
$Runtime = Join-Path $Root "runtime"
$ProjectsDir = Join-Path $Runtime "projects"
$CurrentFile = Join-Path $Runtime "current-workflow.json"

if (-not [string]::IsNullOrWhiteSpace($PreferredProject)) {
    $pdir = Join-Path $ProjectsDir $PreferredProject
    $pjson = Join-Path $pdir "project.json"
    if (-not (Test-Path -LiteralPath $pjson)) {
        throw "Project not found: $PreferredProject (expected $pjson)"
    }
    return $PreferredProject
}

if (Test-Path -LiteralPath $CurrentFile) {
    try {
        $cw = Get-Content -LiteralPath $CurrentFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cw -and ($cw.PSObject.Properties.Name -contains "projectId")) {
            $id = [string]$cw.projectId
            if (-not [string]::IsNullOrWhiteSpace($id)) {
                $pjson = Join-Path (Join-Path $ProjectsDir $id) "project.json"
                if (Test-Path -LiteralPath $pjson) { return $id }
            }
        }
    } catch {}
}

if (Test-Path -LiteralPath $ProjectsDir) {
    $first = Get-ChildItem -LiteralPath $ProjectsDir -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name |
        Select-Object -First 1
    if ($first) {
        $candidate = $first.Name
        $pjson = Join-Path (Join-Path $ProjectsDir $candidate) "project.json"
        if (Test-Path -LiteralPath $pjson) { return $candidate }
    }
}

throw @"
No usable project.

Do this once:
  cd `"$Root`"
  .\cursor-autolook.ps1 init
  .\cursor-autolook.ps1 new-project -Name my-work

Or set workflow:
  .\cursor-autolook.ps1 enter-workflow -Project YOUR_PROJECT_ID
"@
