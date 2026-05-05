$ErrorActionPreference = "Stop"

$Repo = Split-Path $PSScriptRoot -Parent
$Desktop = [Environment]::GetFolderPath("Desktop")
if ([string]::IsNullOrWhiteSpace($Desktop) -or -not (Test-Path -LiteralPath $Desktop)) {
    throw "Desktop folder not found."
}
$PsExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

function New-AutolookLnk {
    param(
        # Use ASCII-only file names so shell COM accepts paths reliably on all locales.
        [string]$Name,
        [string]$Arguments,
        [string]$WorkDir,
        [string]$DescriptionZh = ""
    )
    $shell = New-Object -ComObject WScript.Shell
    $path = Join-Path $Desktop $Name
    if (-not ($Name.EndsWith(".lnk", [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "Shortcut name must end with .lnk: $Name"
    }
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
    }
    $sc = $shell.CreateShortcut($path)
    $sc.TargetPath = $PsExe
    $sc.Arguments = $Arguments
    $sc.WorkingDirectory = $WorkDir
    $sc.IconLocation = "$PsExe,0"
    if (-not [string]::IsNullOrWhiteSpace($DescriptionZh)) {
        try { $sc.Description = $DescriptionZh } catch {}
    }
    $sc.Save()
    Write-Host ("[OK] {0}" -f $path)
}

$repoEsc = $Repo.Replace("'", "''")

$terminalCmd = "-NoExit -NoLogo -ExecutionPolicy Bypass -NoProfile -Command " +
    "& { Set-Location -LiteralPath '$repoEsc'; " +
    "Write-Host ''; " +
    "Write-Host '  Cursor Autolook - repo shell' -ForegroundColor Cyan; " +
    "Write-Host '  .\cursor-autolook.ps1           # interactive menu (default)'; " +
    "Write-Host '  .\cursor-autolook.ps1 help        # all commands'; " +
    "Write-Host '  .\cursor-autolook.ps1 status'; " +
    "Write-Host ''; }"

New-AutolookLnk -Name "CursorAutolook-Start.lnk" `
    -Arguments "-NoExit -NoLogo -ExecutionPolicy Bypass -NoProfile -File `"$Repo\cursor-autolook.ps1`" menu" `
    -WorkDir $Repo `
    -DescriptionZh "Cursor Autolook: interactive menu (recommended)"

New-AutolookLnk -Name "CursorAutolook-Schedule.lnk" `
    -Arguments "-ExecutionPolicy Bypass -NoProfile -File `"$Repo\cursor-autolook.ps1`" schedule" `
    -WorkDir $Repo `
    -DescriptionZh "Cursor Autolook: one-click schedule (go + watchdog in new window)"

New-AutolookLnk -Name "CursorAutolook-RepoShell.lnk" `
    -Arguments $terminalCmd `
    -WorkDir $Repo `
    -DescriptionZh "Cursor Autolook: fixed repo terminal for workflow commands"

New-AutolookLnk -Name "CursorAutolook-Help.lnk" `
    -Arguments "-ExecutionPolicy Bypass -NoProfile -File `"$Repo\cursor-autolook.ps1`" help" `
    -WorkDir $Repo `
    -DescriptionZh "Cursor Autolook: show CLI help"

New-AutolookLnk -Name "CursorAutolook-Doctor.lnk" `
    -Arguments "-ExecutionPolicy Bypass -NoProfile -File `"$Repo\cursor-autolook.ps1`" doctor" `
    -WorkDir $Repo `
    -DescriptionZh "Cursor Autolook: doctor / environment check"

New-AutolookLnk -Name "CursorAutolook-Dashboard.lnk" `
    -Arguments "-ExecutionPolicy Bypass -NoProfile -File `"$Repo\scripts\Launch-Dashboard.ps1`"" `
    -WorkDir $Repo `
    -DescriptionZh "Cursor Autolook: WT split dashboard (auto project)"

New-AutolookLnk -Name "CursorAutolook-AutomationHub.lnk" `
    -Arguments "-ExecutionPolicy Bypass -NoProfile -File `"$Repo\scripts\Launch-AutomationHub.ps1`"" `
    -WorkDir $Repo `
    -DescriptionZh "Cursor Autolook: automation-hub loop (auto project)"

New-AutolookLnk -Name "CursorAutolook-Watchdog.lnk" `
    -Arguments "-ExecutionPolicy Bypass -NoProfile -File `"$Repo\scripts\Launch-Watchdog.ps1`"" `
    -WorkDir $Repo `
    -DescriptionZh "Cursor Autolook: watchdog scheduler (auto project)"

Write-Host ""
Write-Host "Desktop shortcuts created under: $Desktop" -ForegroundColor Green
