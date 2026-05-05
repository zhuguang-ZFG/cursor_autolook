function Get-ProjectPrefixFile {
    param([string]$ProjectId)
    $projectCacheDir = Join-Path $PromptCacheDir $ProjectId
    Ensure-Directory $projectCacheDir
    return (Join-Path $projectCacheDir "project-prefix-v1.md")
}

function Get-ProjectPrefixText {
    param([string]$ProjectId)
    $pFile = Get-ProjectPrefixFile -ProjectId $ProjectId
    if (-not (Test-Path $pFile)) {
        $defaultPrefix = @"
Project invariant context:
- Keep changes scoped to stated task objectives.
- Reuse existing conventions and avoid broad rewrites.
- Prefer minimal token usage and concise outputs.
"@
        Set-Content -Path $pFile -Value $defaultPrefix -Encoding UTF8
    }
    return (Get-Content -Path $pFile -Raw)
}

function Invoke-SetProjectPrefix {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    if ([string]::IsNullOrWhiteSpace($ProjectPrefix)) { throw "Please provide -ProjectPrefix" }
    $pFile = Get-ProjectPrefixFile -ProjectId $Project
    Set-Content -Path $pFile -Value $ProjectPrefix -Encoding UTF8
    Write-Host "[OK] project prefix updated: $pFile" -ForegroundColor Green
}
