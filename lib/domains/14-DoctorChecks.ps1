function Invoke-CheckPorts {
    Invoke-Init
    $ports = Read-JsonFile -Path $PortsFile
    $reservedStart = [int]$ports.reservedRange.start
    $reservedEnd = [int]$ports.reservedRange.end
    $conflictStart = [int]$ports.knownConflictRange.start
    $conflictEnd = [int]$ports.knownConflictRange.end

    Write-Host "Checking port policy..." -ForegroundColor Cyan
    Write-Host ("  reserved: {0}-{1}" -f $reservedStart, $reservedEnd)
    Write-Host ("  avoid:    {0}-{1}" -f $conflictStart, $conflictEnd)

    if (($reservedStart -le $conflictEnd) -and ($reservedEnd -ge $conflictStart)) {
        throw "Reserved port range overlaps with known conflict range."
    }

    $samplePorts = @(
        (Get-PortValue -Ports $ports -Name "hub" -Fallback $ReservedPortStart),
        (Get-PortValue -Ports $ports -Name "api" -Fallback ($ReservedPortStart + 1)),
        (Get-PortValue -Ports $ports -Name "dashboard" -Fallback ($ReservedPortStart + 2)),
        (Get-PortValue -Ports $ports -Name "reviewer" -Fallback ($ReservedPortStart + 3)),
        (Get-PortValue -Ports $ports -Name "opencode" -Fallback ($ReservedPortStart + 4)),
        (Get-PortValue -Ports $ports -Name "deepseek" -Fallback ($ReservedPortStart + 5)),
        (Get-PortValue -Ports $ports -Name "workerQueue" -Fallback ($ReservedPortStart + 6)),
        (Get-PortValue -Ports $ports -Name "codex" -Fallback ($ReservedPortStart + 7))
    )

    foreach ($p in $samplePorts) {
        if (($p -lt $reservedStart) -or ($p -gt $reservedEnd)) {
            throw "Default port $p is outside reserved range $reservedStart-$reservedEnd."
        }
        if (($p -ge $conflictStart) -and ($p -le $conflictEnd)) {
            throw "Default port $p conflicts with reserved range used by other repos."
        }
    }

    if ((@($samplePorts | Select-Object -Unique)).Count -ne $samplePorts.Count) {
        throw "Default ports contain duplicates. Please use unique isolated ports."
    }

    Write-Host "[OK] No overlap with autolook/deepseek_autolook port range." -ForegroundColor Green
}

function Invoke-ListCallbacks {
    Invoke-Init
    $files = @(Get-ChildItem -Path $CallbacksDir -Filter "*.json" -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    if ($files.Count -eq 0) {
        Write-Host "No pending callback files in runtime/callbacks." -ForegroundColor Yellow
        return
    }
    foreach ($f in $files) {
        try {
            $payload = Read-JsonFile -Path $f.FullName
            $proj = [string]$payload.project
            $tid = [string]$payload.taskId
            $ver = if ($payload.PSObject.Properties.Name -contains "schemaVersion") { [int]$payload.schemaVersion } else { 1 }
            $src = if ($payload.PSObject.Properties.Name -contains "source") { [string]$payload.source } else { "-" }
            Write-Host ("{0}  project={1}  task={2}  schema={3}  source={4}" -f $f.Name, $proj, $tid, $ver, $src)
        } catch {
            Write-Host ("{0}  invalid JSON: {1}" -f $f.Name, $_) -ForegroundColor Red
        }
    }
    Write-Host ("Total pending: {0}" -f $files.Count) -ForegroundColor Cyan
}

function Invoke-CcSwitchProviders {
    $audit = Join-Path $Root "scripts\audit_cc_switch_providers.py"
    if (-not (Test-Path $audit)) {
        throw "Missing audit script: $audit"
    }
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) {
        throw "python not found on PATH (required for ccswitch-providers)."
    }
    & python $audit
    if ($LASTEXITCODE -ne 0) {
        throw "audit_cc_switch_providers.py exited with code $LASTEXITCODE"
    }
}

function Invoke-Doctor {
    $issues = 0
    Write-Host ""
    Write-Host "Autolook doctor — environment + queue sanity" -ForegroundColor Cyan
    Write-Host ""

    $domainsCheck = Join-Path $Root "lib\domains"
    $domainScripts = @(Get-ChildItem -LiteralPath $domainsCheck -Filter "*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
    if ($domainScripts.Count -eq 0) {
        $issues++
        Write-Host "[!!] lib\domains has no *.ps1 (expected modular core)" -ForegroundColor Red
    }
    $scriptFiles = @(
        (Join-Path $Root "cursor-autolook.ps1")
        (Join-Path $Root "lib\Autolook.Core.ps1")
    ) + @($domainScripts)
    foreach ($f in $scriptFiles) {
        $tokens = $null
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errs)
        if ($errs.Count -eq 0) {
            Write-Host ("[OK] syntax: {0}" -f $f) -ForegroundColor Green
        } else {
            $issues++
            Write-Host ("[!!] syntax errors in {0}" -f $f) -ForegroundColor Red
        }
    }

    try {
        Invoke-CheckPorts | Out-Null
        Write-Host "[OK] ports: no overlap with sibling repo ranges" -ForegroundColor Green
    } catch {
        $issues++
        Write-Host ("[!!] ports: {0}" -f $_) -ForegroundColor Red
    }

    Invoke-Init
    if (Test-Path $ProjectsDir) {
        Write-Host "[OK] runtime/projects exists" -ForegroundColor Green
    } else {
        $issues++
        Write-Host "[!!] runtime/projects missing (run init)" -ForegroundColor Red
    }

    if (Test-Path $WorkerQueueDir) {
        $wq = @(Get-ChildItem -Path $WorkerQueueDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
        Write-Host ("[OK] worker-queue snapshots: dir={0} files={1}" -f $WorkerQueueDir, $wq) -ForegroundColor Green
    } else {
        Write-Host "[--] worker-queue dir absent (until first worker-queue run)" -ForegroundColor DarkYellow
    }

    if (Test-Path -LiteralPath $InteractionFeedFile) {
        Write-Host ("[OK] CLI interaction feed exists: {0} (follow-feed to tail formatted lines)" -f $InteractionFeedFile) -ForegroundColor Green
    } else {
        Write-Host ("[--] interaction feed absent until first enqueue/dispatch/consume ({0})" -f $InteractionFeedFile) -ForegroundColor DarkYellow
    }

    if (Test-Path $CallbacksDir) {
        $pend = @(Get-ChildItem -Path $CallbacksDir -Filter "*.json" -File -ErrorAction SilentlyContinue).Count
        Write-Host ("[OK] callbacks dir: pending json files = {0}" -f $pend) -ForegroundColor Green
    } else {
        $issues++
        Write-Host "[!!] callbacks directory missing" -ForegroundColor Red
    }

    $cfgOllama = $null
    $cfgPath = Join-Path $RuntimeDir "autolook.config.json"
    if (Test-Path $cfgPath) {
        try {
            $ac = Read-JsonFile -Path $cfgPath
            if ($ac.PSObject.Properties.Name -contains "defaultOllamaModel") {
                $cfgOllama = [string]$ac.defaultOllamaModel
            }
        } catch {
            $issues++
            Write-Host ("[!!] autolook.config.json unreadable: {0}" -f $_) -ForegroundColor Red
        }
    }
    Write-Host ("Ollama: CLI default param = {0}" -f $OllamaModel) -ForegroundColor DarkGray
    if (-not [string]::IsNullOrWhiteSpace($cfgOllama)) {
        Write-Host ("       runtime/autolook.config.json defaultOllamaModel = {0} (used for new-task when -OllamaModel omitted)" -f $cfgOllama) -ForegroundColor DarkGray
    } else {
        Write-Host "       (no defaultOllamaModel in autolook.config.json)" -ForegroundColor DarkGray
    }

    $userHome = $env:USERPROFILE
    if (-not [string]::IsNullOrWhiteSpace($userHome)) {
        $db = Join-Path $userHome ".cc-switch\cc-switch.db"
        $router = Join-Path $userHome ".claude\hooks\cc-switch-router.config.json"
        $ccSettings = Join-Path $userHome ".cc-switch\settings.json"
        $ccLog = Join-Path $userHome ".cc-switch\logs\cc-switch.log"
        foreach ($pair in @(
                @("CC Switch DB", $db),
                @("CC Switch settings", $ccSettings),
                @("CC Switch router config", $router)
            )) {
            $label = $pair[0]
            $pth = $pair[1]
            if (Test-Path $pth) {
                Write-Host ("[OK] {0}: {1}" -f $label, $pth) -ForegroundColor Green
            } else {
                Write-Host ("[--] {0} not found: {1}" -f $label, $pth) -ForegroundColor DarkYellow
            }
        }
        if (Test-Path $ccLog) {
            Write-Host ("[OK] CC Switch log: {0}" -f $ccLog) -ForegroundColor Green
        } else {
            Write-Host ("[--] CC Switch log not found yet: {0}" -f $ccLog) -ForegroundColor DarkYellow
        }
    }

    $audit = Join-Path $Root "scripts\audit_cc_switch_providers.py"
    if (Test-Path $audit) {
        $py = Get-Command python -ErrorAction SilentlyContinue
        if ($py) {
            Write-Host "[OK] ccswitch-providers audit script + python available (run: ccswitch-providers)" -ForegroundColor Green
        } else {
            Write-Host "[--] python not on PATH; ccswitch-providers will not run" -ForegroundColor DarkYellow
        }
    } else {
        $issues++
        Write-Host "[!!] scripts/audit_cc_switch_providers.py missing" -ForegroundColor Red
    }

    Write-Host ""
    if ($issues -eq 0) {
        Write-Host "Doctor summary: no blocking issues detected." -ForegroundColor Green
    } else {
        Write-Host ("Doctor summary: {0} issue(s) — fix above before relying on automation." -f $issues) -ForegroundColor Yellow
        exit 1
    }
}

function Invoke-QuickCheck {
    $failed = 0
    $passed = 0
    Write-Host "Running quick self-check..." -ForegroundColor Cyan

    $domainsCheck = Join-Path $Root "lib\domains"
    $domainScripts = @(Get-ChildItem -LiteralPath $domainsCheck -Filter "*.ps1" -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
    $scriptFiles = @(
        (Join-Path $Root "cursor-autolook.ps1")
        (Join-Path $Root "lib\Autolook.Core.ps1")
    ) + @($domainScripts)
    foreach ($f in $scriptFiles) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -eq 0) { $passed++ } else { $failed++; Write-Host "  FAIL syntax: $f" -ForegroundColor Red }
    }

    try {
        Invoke-CheckPorts | Out-Null
        $passed++
    } catch {
        $failed++
        Write-Host "  FAIL ports: $_" -ForegroundColor Red
    }

    if (Test-Path $ProjectsDir) { $passed++ } else { $failed++; Write-Host "  FAIL runtime projects dir missing" -ForegroundColor Red }

    Write-Host ("Quick check: passed={0} failed={1}" -f $passed, $failed) -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Yellow" })
    if ($failed -gt 0) { exit 1 }
}

function Invoke-E2ECheck {
    Invoke-Init
    $testProject = "e2e-check-" + (Get-Date -Format "yyyyMMddHHmmss")
    $taskTitle = "e2e task"
    Write-Host "Running end-to-end check project: $testProject" -ForegroundColor Cyan

    $script:Name = $testProject
    Invoke-NewProject

    $script:Project = $testProject
    $script:Title = $taskTitle
    $script:TestCommand = "exit 0"
    $script:Artifacts = ""
    Invoke-NewTask

    $tasks = @(Get-Tasks -ProjectId $testProject)
    if ($tasks.Count -ne 1) { throw "E2E failed: task create failed" }
    $tid = $tasks[0].id

    $script:Project = $testProject
    $script:Interval = 1
    $script:MaxRounds = 1
    Invoke-Watchdog

    $script:TaskId = $tid
    $script:Status = "in_review"
    $script:Note = "looks good"
    Invoke-SetTask

    $script:TaskId = $tid
    Invoke-Review

    $final = Read-JsonFile -Path (Get-TaskFilePath -ProjectId $testProject -TaskId $tid)
    if ($final.status -ne "done") { throw "E2E failed: final status is $($final.status), expected done" }

    Write-Host "[OK] E2E check passed: ready -> in_progress -> in_review -> done" -ForegroundColor Green
}

function Invoke-StressScheduler {
    Invoke-Init
    $nTotal = if ([int]$StressTasks -ge 2) { [int]$StressTasks } else { 12 }
    if ($nTotal -gt 64) {
        throw "stress-scheduler: -StressTasks too large (>64). Lower the count."
    }
    $nLocalHeavy = if ([int]$StressLocalHeavyTasks -gt 0) {
        [math]::Min([int]$StressLocalHeavyTasks, $nTotal)
    } else {
        [math]::Min(6, $nTotal)
    }
    $iterLimit = if ([int]$StressIterations -gt 0) { [int]$StressIterations } else { 450 }

    $savedConcurrent = $MaxConcurrentTasks
    $savedLocalCap = $LocalModelMaxParallel
    $savedInterval = $Interval
    $savedMaxRounds = $MaxRounds
    try {
        if ([int]$savedConcurrent -le 1) {
            $script:MaxConcurrentTasks = 4
        }
        $script:LocalModelMaxParallel = 1
        $script:Interval = 0
        $script:MaxRounds = 1

        $testProject = "stress-sched-" + (Get-Date -Format "yyyyMMddHHmmss")
        Write-Host ""
        Write-Host ("Scheduling stress — project={0} tasks={1} general(ollama-heavy)={2} maxConcurrentTasks={3} LocalModelMaxParallel={4}" -f `
                $testProject, $nTotal, $nLocalHeavy, [int]$MaxConcurrentTasks, [int]$LocalModelMaxParallel) -ForegroundColor Cyan

        $script:Name = $testProject
        Invoke-NewProject

        for ($i = 1; $i -le $nTotal; $i++) {
            $tt = if ($i -le $nLocalHeavy) { "general" } else { "bugfix" }
            $script:Project = $testProject
            $script:Title = ("sched stress {0}/{1} ({2})" -f $i, $nTotal, $tt)
            $script:TaskType = $tt
            $script:TestCommand = "exit 0"
            $script:Artifacts = ""
            Invoke-NewTask
        }

        $peakOllama = 0
        $peakRunning = 0
        for ($step = 1; $step -le $iterLimit; $step++) {
            $script:Project = $testProject

            foreach ($t in @(Get-Tasks -ProjectId $testProject | Where-Object { $_.status -eq "in_progress" })) {
                $tid = [string]$t.id
                $script:Project = $testProject
                $script:TaskId = $tid
                $script:Status = "in_review"
                $script:Note = "stress: synthetic completion"
                Invoke-SetTask
            }

            $script:Project = $testProject
            Invoke-Watchdog

            $tasksNow = @(Get-Tasks -ProjectId $testProject)
            $runningTasks = @($tasksNow | Where-Object { $_.status -eq "in_progress" })
            $peakRunning = [math]::Max([int]$peakRunning, [int]$runningTasks.Count)
            $ollNow = @( $runningTasks | Where-Object { Is-OllamaAssignee -Assignee ([string]$_.assignee) } ).Count
            $peakOllama = [math]::Max([int]$peakOllama, [int]$ollNow)
            if ($ollNow -gt [int]$LocalModelMaxParallel) {
                throw ("stress-scheduler: concurrent Ollama assignees={0} exceeds LocalModelMaxParallel={1}" -f $ollNow, [int]$LocalModelMaxParallel)
            }

            $open = @( $tasksNow | Where-Object { $_.status -notin @("done", "blocked") } ).Count
            if ($open -eq 0) {
                Write-Host ("[OK] Stress finished in {0} scheduling step(s)." -f $step) -ForegroundColor Green
                break
            }
            if ($step -eq $iterLimit) {
                throw ("stress-scheduler: iteration budget exhausted ({0}) with unfinished tasks={1}." -f $iterLimit, $open)
            }
        }

        Write-Host ("[OK] Scheduling stress peaks: concurrentRunning={0} concurrentOllama={1}" -f $peakRunning, $peakOllama) -ForegroundColor DarkCyan

        if (-not $StressKeepProject) {
            Remove-ProjectFilesForStressOrThrow -ProjectId $testProject
        } else {
            Write-Host ("[info] Stress project retained: {0}" -f $testProject) -ForegroundColor Yellow
        }
    } finally {
        $script:MaxConcurrentTasks = $savedConcurrent
        $script:LocalModelMaxParallel = $savedLocalCap
        $script:Interval = $savedInterval
        $script:MaxRounds = $savedMaxRounds
    }
}
function Invoke-KxnxAudit {
    Invoke-Init
    $workspace = (Get-Location).Path
    $marker = Join-Path $workspace "kx"
    if (-not (Test-Path $marker)) {
        Write-Host ("[WARN] kx marker not found under workspace: {0}" -f $workspace) -ForegroundColor Yellow
        Write-Host "       continue anyway (you may be auditing another repo layout)." -ForegroundColor Yellow
    }
    $proj = "kxnx-real-audit-" + (Get-Date -Format "yyyyMMddHHmmss")
    Write-Host ("Starting kxnx audit workflow: project={0} workspace={1}" -f $proj, $workspace) -ForegroundColor Cyan

    $savedName = $script:Name
    $savedProject = $script:Project
    $savedTitle = $script:Title
    $savedTaskType = $script:TaskType
    $savedTestCommand = $script:TestCommand
    $savedArtifacts = $script:Artifacts
    $savedAutoAdvance = $script:AutoAdvanceOnGatePass
    try {
        $script:Name = $proj
        Invoke-NewProject
        $templates = @(
            @{ title = "stack-and-runtime-audit"; taskType = "review" },
            @{ title = "core-modules-and-taskflow-audit"; taskType = "general" },
            @{ title = "api-and-local-service-audit"; taskType = "bugfix" },
            @{ title = "data-model-and-persistence-audit"; taskType = "refactor" },
            @{ title = "auth-permission-security-audit"; taskType = "review" },
            @{ title = "async-queue-and-scheduler-audit"; taskType = "general" },
            @{ title = "external-integration-config-audit"; taskType = "bugfix" },
            @{ title = "test-system-gap-audit"; taskType = "refactor" }
        )
        foreach ($tpl in $templates) {
            $script:Project = $proj
            $script:Title = [string]$tpl.title
            $script:TaskType = [string]$tpl.taskType
            $script:TestCommand = "exit 0"
            $script:Artifacts = ""
            $script:AutoAdvanceOnGatePass = $true
            Invoke-NewTask
        }
        $script:Project = $proj
        $script:WorkerQueuePrepBrief = $true
        Invoke-WorkerQueueSnapshot
        $script:HubAutoAdvanceGate = $true
        $script:SkipHubConsumeCallbacks = $false
        $script:HubMaxCycles = 60
        $script:Interval = 0
        $script:MaxConcurrentTasks = 4
        $script:LocalModelMaxParallel = 1
        Invoke-AutomationHub
        $script:Project = $proj
        Invoke-OpsReport
        Write-Host ("[OK] kxnx-audit done: {0}" -f $proj) -ForegroundColor Green
    } finally {
        $script:Name = $savedName
        $script:Project = $savedProject
        $script:Title = $savedTitle
        $script:TaskType = $savedTaskType
        $script:TestCommand = $savedTestCommand
        $script:Artifacts = $savedArtifacts
        $script:AutoAdvanceOnGatePass = $savedAutoAdvance
    }
}
function Remove-ProjectFilesForStressOrThrow {
    param([string]$ProjectId)
    $dir = Join-Path $ProjectsDir $ProjectId
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
}
