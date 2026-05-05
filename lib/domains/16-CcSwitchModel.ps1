function Resolve-CcSwitchCurrentModel {
    param(
        [string]$TraceId,
        [string]$SessionId
    )
    $userHome = [Environment]::GetFolderPath("UserProfile")
    $logPath = Join-Path $userHome ".cc-switch\logs\cc-switch.log"
    $requireContextMatch = (-not [string]::IsNullOrWhiteSpace($TraceId)) -or (-not [string]::IsNullOrWhiteSpace($SessionId))
    if (Test-Path $logPath) {
        try {
            $tail = @(Get-Content -Path $logPath -Tail 1200 -ErrorAction SilentlyContinue)
            $hasTrace = -not [string]::IsNullOrWhiteSpace($TraceId)
            $hasSession = -not [string]::IsNullOrWhiteSpace($SessionId)
            for ($i = $tail.Count - 1; $i -ge 0; $i--) {
                $line = [string]$tail[$i]
                if ($line -match "\[Claude\].*\(model=([^)]+)\)") {
                    $m = [string]$Matches[1]
                    if (-not [string]::IsNullOrWhiteSpace($m)) {
                        if ($hasTrace -or $hasSession) {
                            $start = [Math]::Max(0, $i - 3)
                            $end = [Math]::Min($tail.Count - 1, $i + 3)
                            $window = (@($tail[$start..$end]) -join "`n")
                            $traceOk = (-not $hasTrace) -or ($window -match [regex]::Escape($TraceId))
                            $sessionOk = (-not $hasSession) -or ($window -match [regex]::Escape($SessionId))
                            if (-not ($traceOk -and $sessionOk)) { continue }
                        }
                        return $m.Trim()
                    }
                }
            }
        } catch {
        }
    }
    if ($requireContextMatch) {
        # For strong truth mode, do not fallback to provider name when trace/session did not match log context.
        return $null
    }
    $settingsPath = Join-Path $userHome ".cc-switch\settings.json"
    $routerConfigPath = Join-Path $userHome ".claude\hooks\cc-switch-router.config.json"
    try {
        if ((Test-Path $settingsPath) -and (Test-Path $routerConfigPath)) {
            $settings = Read-JsonFile -Path $settingsPath
            $providerId = if ($settings.PSObject.Properties.Name -contains "currentProviderClaude") { [string]$settings.currentProviderClaude } else { $null }
            if (-not [string]::IsNullOrWhiteSpace($providerId)) {
                $cfg = Read-JsonFile -Path $routerConfigPath
                if ($cfg -and ($cfg.PSObject.Properties.Name -contains "providers")) {
                    foreach ($pn in $cfg.providers.PSObject.Properties.Name) {
                        $p = $cfg.providers.$pn
                        if ($p -and $p.PSObject.Properties.Name -contains "id" -and [string]$p.id -eq $providerId) {
                            if ($p.PSObject.Properties.Name -contains "name" -and -not [string]::IsNullOrWhiteSpace([string]$p.name)) {
                                return [string]$p.name
                            }
                        }
                    }
                }
            }
        }
    } catch {
    }
    return $null
}
