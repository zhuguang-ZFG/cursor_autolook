param(
    [Parameter(Mandatory = $true)][string]$Project,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [string]$Note = "external callback",
    [string]$WorkerModel,
    [string]$CcSwitchModel,
    [string]$Source = "cc-switch",
    [string]$TraceId,
    [string]$SessionId,
    [switch]$AutoContinue
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$runtime = Join-Path $root "runtime"
$callbacks = Join-Path $runtime "callbacks"
if (-not (Test-Path $callbacks)) { New-Item -ItemType Directory -Path $callbacks | Out-Null }

$effectiveTraceId = $TraceId
$effectiveSessionId = $SessionId
if ($Source -eq "cc-switch") {
    if ([string]::IsNullOrWhiteSpace($effectiveTraceId)) { $effectiveTraceId = ("auto-trace-" + [guid]::NewGuid().ToString("N").Substring(0, 8)) }
    if ([string]::IsNullOrWhiteSpace($effectiveSessionId)) { $effectiveSessionId = ("auto-session-" + [guid]::NewGuid().ToString("N").Substring(0, 8)) }
}

$resolvedCcSwitchModel = $null
if ([string]::IsNullOrWhiteSpace($CcSwitchModel)) {
    $userHome = [Environment]::GetFolderPath("UserProfile")
    $logPath = Join-Path $userHome ".cc-switch\logs\cc-switch.log"
    $settingsPath = Join-Path $userHome ".cc-switch\settings.json"
    $routerConfigPath = Join-Path $userHome ".claude\hooks\cc-switch-router.config.json"
    try {
        $requireContextMatch = (-not [string]::IsNullOrWhiteSpace($effectiveTraceId)) -or (-not [string]::IsNullOrWhiteSpace($effectiveSessionId))
        if (Test-Path $logPath) {
            $tail = @(Get-Content -Path $logPath -Tail 1200 -ErrorAction SilentlyContinue)
            $hasTrace = -not [string]::IsNullOrWhiteSpace($effectiveTraceId)
            $hasSession = -not [string]::IsNullOrWhiteSpace($effectiveSessionId)
            for ($i = $tail.Count - 1; $i -ge 0; $i--) {
                $line = [string]$tail[$i]
                if ($line -match "\[Claude\].*\(model=([^)]+)\)") {
                    $m = [string]$Matches[1]
                    if (-not [string]::IsNullOrWhiteSpace($m)) {
                        if ($hasTrace -or $hasSession) {
                            $start = [Math]::Max(0, $i - 3)
                            $end = [Math]::Min($tail.Count - 1, $i + 3)
                            $window = (@($tail[$start..$end]) -join "`n")
                            $traceOk = (-not $hasTrace) -or ($window -match [regex]::Escape($effectiveTraceId))
                            $sessionOk = (-not $hasSession) -or ($window -match [regex]::Escape($effectiveSessionId))
                            if (-not ($traceOk -and $sessionOk)) { continue }
                        }
                        $resolvedCcSwitchModel = $m.Trim()
                        break
                    }
                }
            }
        }
        if ($requireContextMatch -and [string]::IsNullOrWhiteSpace($resolvedCcSwitchModel)) {
            # strong truth mode: context provided but not found in logs -> keep null
        } elseif ([string]::IsNullOrWhiteSpace($resolvedCcSwitchModel) -and (Test-Path $settingsPath) -and (Test-Path $routerConfigPath)) {
            $settings = Get-Content -Path $settingsPath -Raw | ConvertFrom-Json
            $providerId = [string]$settings.currentProviderClaude
            $cfg = Get-Content -Path $routerConfigPath -Raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace($providerId) -and $cfg -and $cfg.providers) {
                foreach ($pn in $cfg.providers.PSObject.Properties.Name) {
                    $p = $cfg.providers.$pn
                    if ([string]$p.id -eq $providerId -and -not [string]::IsNullOrWhiteSpace([string]$p.name)) {
                        $resolvedCcSwitchModel = [string]$p.name
                        break
                    }
                }
            }
        }
    } catch {}
}

$payload = [ordered]@{
    schemaVersion = 2
    project = $Project
    taskId = $TaskId
    note = $Note
    workerModel = $(if ([string]::IsNullOrWhiteSpace($WorkerModel)) { $null } else { $WorkerModel })
    ccSwitchModel = $(if ([string]::IsNullOrWhiteSpace($CcSwitchModel)) { $resolvedCcSwitchModel } else { $CcSwitchModel })
    source = $(if ([string]::IsNullOrWhiteSpace($Source)) { "external" } else { $Source })
    traceId = $(if ([string]::IsNullOrWhiteSpace($effectiveTraceId)) { $null } else { $effectiveTraceId })
    sessionId = $(if ([string]::IsNullOrWhiteSpace($effectiveSessionId)) { $null } else { $effectiveSessionId })
    autoContinue = [bool]$AutoContinue
    createdAt = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
}

$name = "{0}-{1}.json" -f $Project, ([guid]::NewGuid().ToString("N").Substring(0, 8))
$path = Join-Path $callbacks $name
$payload | ConvertTo-Json -Depth 8 | Set-Content -Path $path -Encoding UTF8
Write-Host ("[OK] callback queued: {0}" -f $path) -ForegroundColor Green

try {
    $feedPath = Join-Path $runtime "interaction-feed.jsonl"
    if (-not (Test-Path $runtime)) {
        New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    }
    $feedRow = @{
        ts        = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")
        kind      = "callback_queued"
        project   = $Project
        taskId    = $TaskId
        source    = [string]$payload.source
        file      = (Split-Path -Leaf $path)
        traceId   = $payload.traceId
        sessionId = $payload.sessionId
        note      = $Note
    }
    ($feedRow | ConvertTo-Json -Compress -Depth 6) | Add-Content -Path $feedPath -Encoding UTF8
} catch { }
