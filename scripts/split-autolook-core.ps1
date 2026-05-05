# Rebuild lib/domains/*.ps1 from a monolithic snapshot of the core PowerShell bundle.
# After modularization, the live lib/Autolook.Core.ps1 is only a loader; pass a merged snapshot explicitly.
#
# Usage (example):
#   powershell -File .\scripts\split-autolook-core.ps1 -SourceFile .\lib\Autolook.Core.bundle.ps1

param(
    [Parameter(Mandatory = $true)]
    [string]$SourceFile
)

$ErrorActionPreference = "Stop"
$resolvedSrc = Resolve-Path -LiteralPath $SourceFile | Select-Object -ExpandProperty Path
$src = [System.IO.File]::ReadAllLines($resolvedSrc)
$outRoot = Join-Path (Split-Path $PSScriptRoot -Parent) "lib\domains"
if (-not (Test-Path -LiteralPath $outRoot)) {
    New-Item -ItemType Directory -Path $outRoot | Out-Null
}

function Write-PairedRanges {
    param(
        [string]$RelativeName,
        [int[]]$StartEndPairs
    )
    if (($StartEndPairs.Count % 2) -ne 0) {
        throw "StartEndPairs must have even length: $RelativeName"
    }
    $allLines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $StartEndPairs.Count; $i += 2) {
        $start = $StartEndPairs[$i]
        $end = $StartEndPairs[$i + 1]
        foreach ($line in $src[($start - 1)..($end - 1)]) {
            [void]$allLines.Add($line)
        }
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    $full = Join-Path $outRoot $RelativeName
    [System.IO.File]::WriteAllLines($full, $allLines.ToArray(), $utf8NoBom)
}

# Line ranges correspond to commits that produced domains/ originally from a ~3500-line single file Core bundle.
$lists = @(
    @{ Name = "01-Common.ps1";            Pairs = @(1, 126) }
    @{ Name = "02-Feed.ps1";              Pairs = @(128, 294) }
    @{ Name = "03-Routing.ps1";           Pairs = @(296, 379, 407, 452) }
    @{ Name = "04-JsonMetrics.ps1";       Pairs = @(454, 529) }
    @{ Name = "05-BlockReason.ps1";       Pairs = @(3311, 3361) }
    @{ Name = "06-PromptSupervisor.ps1";  Pairs = @(531, 711) }
    @{ Name = "07-WorkerQueue.ps1";       Pairs = @(713, 940) }
    @{ Name = "08-ProjectPrefix.ps1";     Pairs = @(942, 970) }
    @{ Name = "09-TasksInit.ps1";         Pairs = @(380, 405, 1134, 1608, 972, 1019, 1610, 1717) }
    @{ Name = "10-PrepCacheAlerts.ps1";   Pairs = @(1021, 1132) }
    @{ Name = "11-Watchdog.ps1";          Pairs = @(1719, 1958) }
    @{ Name = "12-ReviewMetrics.ps1";     Pairs = @(1960, 2026) }
    @{ Name = "13-Dashboard.ps1";        Pairs = @(2028, 2105) }
    @{ Name = "14-DoctorChecks.ps1";      Pairs = @(2107, 2474, 2476, 2538, 2540, 2546) }
    @{ Name = "15-HubServe.ps1";         Pairs = @(2548, 2728) }
    @{ Name = "16-CcSwitchModel.ps1";    Pairs = @(3249, 3309) }
    @{ Name = "17-AgentCallbacks.ps1";   Pairs = @(2730, 2954) }
    @{ Name = "18-Evolution.ps1";        Pairs = @(2956, 3247) }
    @{ Name = "19-OpsReport.ps1";        Pairs = @(3363, 3499) }
    @{ Name = "20-Help.ps1";             Pairs = @(3501, 3562) }
)

foreach ($item in $lists) {
    Write-PairedRanges -RelativeName $item.Name -StartEndPairs $item.Pairs
}

Write-Host ("[OK] wrote {0} domain scripts under {1}" -f $lists.Count, $outRoot) -ForegroundColor Green
