$ErrorActionPreference = "Stop"
$Desktop = [Environment]::GetFolderPath("Desktop")
if (-not (Test-Path -LiteralPath $Desktop)) { throw "Desktop not found." }

$keep = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($k in @(
        "CursorAutolook-Start.lnk",
        "CursorAutolook-RepoShell.lnk",
        "CursorAutolook-Help.lnk",
        "CursorAutolook-Doctor.lnk",
        "CursorAutolook-Dashboard.lnk",
        "CursorAutolook-AutomationHub.lnk",
        "CursorAutolook-Watchdog.lnk")) {
    [void]$keep.Add($k)
}

function Test-HasNonAscii([string]$s) {
    foreach ($ch in $s.ToCharArray()) {
        if ([int][char]$ch -gt 127) { return $true }
    }
    return $false
}

$removed = New-Object System.Collections.Generic.List[string]
foreach ($item in Get-ChildItem -LiteralPath $Desktop -Filter "*.lnk" -File) {
    $name = $item.Name
    if ($keep.Contains($name)) { continue }

    $drop = $false
    # Old naming: "Cursor Autolook - ..." or "Cursor Autolook · ..."
    if ($name.StartsWith("Cursor Autolook", [System.StringComparison]::OrdinalIgnoreCase)) {
        $drop = $true
    }
    if ($name.Contains([char]0x00B7)) {
        $drop = $true
    }
    # Any Autolook-related shortcut with non-ASCII in the file name (Explorer often shows mojibake)
    if (-not $drop -and ($name -match "Autolook") -and (Test-HasNonAscii $name)) {
        $drop = $true
    }
    # Debug leftovers
    if ($name -match '^(test-dash-en|lnk-prop-test|zzz-test-sc)\.lnk$') {
        $drop = $true
    }

    if (-not $drop) { continue }

    Remove-Item -LiteralPath $item.FullName -Force
    [void]$removed.Add($item.FullName)
}

if ($removed.Count -eq 0) {
    Write-Host "No garbled / legacy Autolook shortcuts found on desktop."
} else {
    Write-Host "Removed $($removed.Count) shortcut(s):" -ForegroundColor Yellow
    foreach ($p in $removed) { Write-Host "  $p" }
}
