function Invoke-SimpleMenu {
    $resolver = Join-Path $Root "scripts\Resolve-AutolookProject.ps1"
    function Get-OrAskProject {
        param([string]$Prompt = "Project id (Enter=auto pick)")
        $raw = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            return (& $resolver -PreferredProject $raw.Trim())
        }
        return (& $resolver)
    }

    while ($true) {
        Write-Host ""
        Write-Host "======== Cursor Autolook ========" -ForegroundColor Cyan
        Write-Host " 1  Doctor"
        Write-Host " 2  Init (runtime folder)"
        Write-Host " 3  New project"
        Write-Host " 4  New task"
        Write-Host " 5  Status"
        Write-Host " 6  Set active project (enter-workflow)"
        Write-Host "*  ONE-CLICK SCHEDULE (new PS window, non-blocking):"
        Write-Host "12  schedule        -> go + watchdog"
        Write-Host "13  schedule-hub    -> go + automation-hub"
        Write-Host " 7  Dashboard (Windows Terminal)"
        Write-Host " 8  Automation hub (this terminal)"
        Write-Host " 9  Watchdog (this terminal)"
        Write-Host "10  Consume callbacks"
        Write-Host "11  Full command list (help)"
        Write-Host " 0  Exit"
        Write-Host "--------------------------------" -ForegroundColor DarkGray

        $choice = [string](Read-Host "Pick a number").Trim()

        if ($choice -eq "0") {
            Write-Host "Bye." -ForegroundColor DarkGray
            return
        }
        elseif ($choice -eq "1") {
            Invoke-Doctor
        }
        elseif ($choice -eq "2") {
            Invoke-Init
        }
        elseif ($choice -eq "3") {
            $n = Read-Host "New project display name"
            if ([string]::IsNullOrWhiteSpace($n)) {
                Write-Host "Skipped." -ForegroundColor Yellow
                continue
            }
            $script:Name = $n.Trim()
            Invoke-NewProject
        }
        elseif ($choice -eq "4") {
            try {
                $proj = Get-OrAskProject
            } catch {
                Write-Host $_ -ForegroundColor Red
                $manualId = Read-Host "Project id (folder name under runtime\projects)"
                if ([string]::IsNullOrWhiteSpace($manualId)) { continue }
                $proj = (& $resolver -PreferredProject $manualId.Trim())
            }
            $tit = Read-Host "Task title"
            if ([string]::IsNullOrWhiteSpace($tit)) {
                Write-Host "Cancelled." -ForegroundColor Yellow
                continue
            }
            $script:Project = $proj
            $script:Title = $tit.Trim()

            $savedOllama = $script:OllamaModel
            $cfgPath = Join-Path $RuntimeDir "autolook.config.json"
            if (Test-Path -LiteralPath $cfgPath) {
                try {
                    $ac = Read-JsonFile -Path $cfgPath
                    if ($ac.PSObject.Properties.Name -contains "defaultOllamaModel") {
                        $m = [string]$ac.defaultOllamaModel
                        if (-not [string]::IsNullOrWhiteSpace($m)) { $script:OllamaModel = $m }
                    }
                } catch {}
            }
            try {
                Invoke-NewTask
            } finally {
                $script:OllamaModel = $savedOllama
            }
        }
        elseif ($choice -eq "5") {
            Invoke-Status
        }
        elseif ($choice -eq "6") {
            try {
                $proj = Get-OrAskProject "Project id (Enter=auto)"
            } catch {
                Write-Host $_ -ForegroundColor Red
                continue
            }
            $script:Project = $proj
            Invoke-EnterWorkflow
        }
        elseif ($choice -eq "12") {
            try {
                $proj = Get-OrAskProject
            } catch {
                Write-Host $_ -ForegroundColor Red
                continue
            }
            $script:Project = $proj
            Invoke-GoWatch
        }
        elseif ($choice -eq "13") {
            try {
                $proj = Get-OrAskProject
            } catch {
                Write-Host $_ -ForegroundColor Red
                continue
            }
            $script:Project = $proj
            Invoke-GoHub
        }
        elseif ($choice -eq "7") {
            try {
                $proj = Get-OrAskProject
            } catch {
                Write-Host $_ -ForegroundColor Red
                continue
            }
            $script:Project = $proj
            Invoke-Dashboard
        }
        elseif ($choice -eq "8") {
            try {
                $proj = Get-OrAskProject
            } catch {
                Write-Host $_ -ForegroundColor Red
                continue
            }
            $script:Project = $proj
            $script:Interval = 10
            Invoke-AutomationHub
        }
        elseif ($choice -eq "9") {
            try {
                $proj = Get-OrAskProject
            } catch {
                Write-Host $_ -ForegroundColor Red
                continue
            }
            $script:Project = $proj
            Invoke-Watchdog
        }
        elseif ($choice -eq "10") {
            Invoke-ConsumeCallbacks
        }
        elseif ($choice -eq "11") {
            Show-Help
        }
        else {
            Write-Host "Invalid choice; use 0-13 (or see list above)." -ForegroundColor Yellow
        }
    }
}
