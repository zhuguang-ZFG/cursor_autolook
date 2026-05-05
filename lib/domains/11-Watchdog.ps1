function Invoke-Watchdog {
    if ([string]::IsNullOrWhiteSpace($Project)) { throw "Please provide -Project" }
    Set-CurrentWorkflow -ProjectId $Project -Source "watchdog"
    $round = 0
    Write-Host ("Starting watchdog for project '{0}' (interval={1}s, maxRounds={2}, MaxConcurrentTasks={3}, LocalModelMaxParallel={4})..." -f `
            $Project, $Interval, $MaxRounds, $MaxConcurrentTasks, $LocalModelMaxParallel) -ForegroundColor Cyan
    while ($true) {
        $round++
        $stamp = Get-Date -Format "HH:mm:ss"
        Invoke-Reconcile
        $tasks = Get-Tasks -ProjectId $Project
        $ready = @($tasks | Where-Object { $_.status -eq "ready" } | Sort-Object createdAt)
        $running = @($tasks | Where-Object { $_.status -eq "in_progress" })
        $review = @($tasks | Where-Object { $_.status -eq "in_review" })
        $done = @($tasks | Where-Object { $_.status -eq "done" })
        $blocked = @($tasks | Where-Object { $_.status -eq "blocked" })
        Write-Host "[$stamp] round=$round ready=$($ready.Count) running=$($running.Count) in_review=$($review.Count) done=$($done.Count) blocked=$($blocked.Count)" -ForegroundColor DarkCyan

        $dispatchPasses = 0
        while ($true) {
            $dispatchPasses++
            if ($dispatchPasses -gt 128) {
                throw "WATCHDOG: dispatch loop exceeded safety limit (possible scheduling bug)."
            }
            $tasks = Get-Tasks -ProjectId $Project
            $ready = @($tasks | Where-Object { $_.status -eq "ready" } | Sort-Object createdAt)
            $running = @($tasks | Where-Object { $_.status -eq "in_progress" })
            if ($running.Count -ge [int]$MaxConcurrentTasks) { break }
            if ($ready.Count -eq 0) { break }

            $madeDispatchProgress = $false
            foreach ($nextTask in $ready) {
                $tasks = Get-Tasks -ProjectId $Project
                $runningNow = @($tasks | Where-Object { $_.status -eq "in_progress" })
                if ($runningNow.Count -ge [int]$MaxConcurrentTasks) { break }

                $maxAttempts = if ($nextTask.PSObject.Properties.Name -contains "maxAttempts") { [int]$nextTask.maxAttempts } else { 3 }
                $attemptCount = if ($nextTask.PSObject.Properties.Name -contains "attemptCount") { [int]$nextTask.attemptCount } else { 0 }
                if ($attemptCount -ge $maxAttempts) {
                    $file = Get-TaskFilePath -ProjectId $Project -TaskId $nextTask.id
                    $task = Read-JsonFile -Path $file
                    $task.status = "blocked"
                    if (-not ($task.PSObject.Properties.Name -contains "notes")) {
                        $task | Add-Member -NotePropertyName notes -NotePropertyValue @() -Force
                    }
                    $task.notes += ([ordered]@{
                        at = (Get-Timestamp)
                        text = "WATCHDOG: blocked after max attempts reached."
                    })
                    if (-not ($task.PSObject.Properties.Name -contains "dispatchEvidence")) {
                        $task | Add-Member -NotePropertyName dispatchEvidence -NotePropertyValue @() -Force
                    }
                    $task.dispatchEvidence += ([ordered]@{
                        at = (Get-Timestamp)
                        event = "blocked"
                        reason = "maxAttemptsReached"
                        attemptCount = $attemptCount
                        maxAttempts = $maxAttempts
                        fallbackAssignees = if ($task.PSObject.Properties.Name -contains "fallbackAssignees") { @($task.fallbackAssignees) } else { @() }
                    })
                    if (-not ($task.PSObject.Properties.Name -contains "blockedReason")) {
                        $task | Add-Member -NotePropertyName blockedReason -NotePropertyValue $null -Force
                    }
                    $task.blockedReason = "maxAttemptsReached"
                    $task.updatedAt = (Get-Timestamp)
                    Write-JsonFile -Path $file -Data $task
                    Add-MetricEvent -ProjectId $Project -EventType "blocked"
                    Send-Alert -Level "ERROR" -ProjectId $Project -TaskId $nextTask.id -Message "Task blocked after max attempts reached."
                    Write-Host ("  [blocked] {0} max attempts reached ({1})" -f $nextTask.id, $maxAttempts) -ForegroundColor Yellow
                    Write-InteractionFeedLine @{ kind = "watchdog_blocked_attempts"; project = $Project; taskId = [string]$nextTask.id }
                    $madeDispatchProgress = $true
                    break
                }

                Write-Host ("  [dispatch] {0} - {1}" -f $nextTask.id, $nextTask.title) -ForegroundColor DarkGray
                $file = Get-TaskFilePath -ProjectId $Project -TaskId $nextTask.id
                $task = Read-JsonFile -Path $file
                $chosenAssignee = Resolve-AssigneeForAttempt -TaskData $task -AttemptCount $attemptCount
                $throttle = Get-OpenCodeThrottle
                $activeOpenCode = @($tasks | Where-Object { $_.status -eq "in_progress" -and (Is-OpenCodeAssignee -Assignee ([string]$_.assignee)) }).Count
                $dispatchReason = "normal"

                if (Is-OpenCodeAssignee -Assignee ([string]$chosenAssignee)) {
                    if ([int]$activeOpenCode -ge [int]$OpenCodeMaxParallel) {
                        $fallbackAssignee = Resolve-OpenCodeFallbackAssignee -TaskData $task
                        if (-not [string]::IsNullOrWhiteSpace($fallbackAssignee)) {
                            $chosenAssignee = $fallbackAssignee
                            $dispatchReason = "opencode_parallel_cap_fallback"
                        } else {
                            Write-Host ("  [wait] {0} OpenCode parallel cap reached ({1}) and no fallback available." -f $task.id, $OpenCodeMaxParallel) -ForegroundColor Yellow
                            $chosenAssignee = $null
                        }
                    } elseif ([bool]$throttle.active) {
                        $fallbackAssignee = Resolve-OpenCodeFallbackAssignee -TaskData $task
                        if (-not [string]::IsNullOrWhiteSpace($fallbackAssignee)) {
                            $chosenAssignee = $fallbackAssignee
                            $dispatchReason = "opencode_rate_limit_fallback"
                        } else {
                            Write-Host ("  [wait] {0} OpenCode backoff until {1}; no fallback available." -f $task.id, $throttle.until) -ForegroundColor Yellow
                            $chosenAssignee = $null
                        }
                    }
                }

                if ((-not [string]::IsNullOrWhiteSpace([string]$chosenAssignee)) -and (Is-OllamaAssignee -Assignee ([string]$chosenAssignee))) {
                    $activeOllama = @($tasks | Where-Object { $_.status -eq "in_progress" -and (Is-OllamaAssignee -Assignee ([string]$_.assignee)) }).Count
                    if ([int]$activeOllama -ge [int]$LocalModelMaxParallel) {
                        $fallbackAssignee = Resolve-OllamaFallbackAssignee -TaskData $task
                        if (-not [string]::IsNullOrWhiteSpace($fallbackAssignee)) {
                            $chosenAssignee = $fallbackAssignee
                            $dispatchReason = "local_model_serial_fallback"
                        } else {
                            Write-Host ("  [wait] {0} Local model serialized (cap={1}); no fallback available." -f $task.id, $LocalModelMaxParallel) -ForegroundColor Yellow
                            $chosenAssignee = $null
                        }
                    }
                }

                if ([string]::IsNullOrWhiteSpace($chosenAssignee)) {
                    continue
                }

                $task.status = "in_progress"
                $task.assignee = [string]$chosenAssignee
                if (-not ($task.PSObject.Properties.Name -contains "leaseUntil")) {
                    $task | Add-Member -NotePropertyName leaseUntil -NotePropertyValue $null -Force
                }
                if (-not ($task.PSObject.Properties.Name -contains "attemptCount")) {
                    $task | Add-Member -NotePropertyName attemptCount -NotePropertyValue 0 -Force
                }
                $task.attemptCount = [int]$task.attemptCount + 1
                $task.leaseUntil = (Get-Date).AddMinutes($LeaseMinutes).ToString("yyyy-MM-ddTHH:mm:ssK")
                if (-not ($task.PSObject.Properties.Name -contains "notes")) {
                    $task | Add-Member -NotePropertyName notes -NotePropertyValue @() -Force
                }
                if (-not ($task.PSObject.Properties.Name -contains "dispatchEvidence")) {
                    $task | Add-Member -NotePropertyName dispatchEvidence -NotePropertyValue @() -Force
                }
                $task.notes += ([ordered]@{
                    at = (Get-Timestamp)
                    text = ("WATCHDOG: auto-dispatched by Cursor hub. assignee={0} attempt={1}/{2} reason={3}" -f $task.assignee, $task.attemptCount, $maxAttempts, $dispatchReason)
                })
                $task.dispatchEvidence += ([ordered]@{
                    at = (Get-Timestamp)
                    event = "dispatch"
                    assignee = [string]$task.assignee
                    attemptCount = [int]$task.attemptCount
                    maxAttempts = [int]$maxAttempts
                    leaseUntil = [string]$task.leaseUntil
                    reason = $dispatchReason
                    fallbackAssignees = if ($task.PSObject.Properties.Name -contains "fallbackAssignees") { @($task.fallbackAssignees) } else { @() }
                })
                $task.updatedAt = (Get-Timestamp)
                Write-JsonFile -Path $file -Data $task
                Add-MetricEvent -ProjectId $Project -EventType "dispatched"
                Write-InteractionFeedLine @{
                    kind     = "watchdog_dispatch"
                    project  = $Project
                    taskId   = [string]$task.id
                    title    = ([string]$task.title)
                    assignee = ([string]$task.assignee)
                    attempt  = [int]$task.attemptCount
                    reason   = $dispatchReason
                }

                $snap = @(Get-Tasks -ProjectId $Project | Where-Object { $_.status -eq "in_progress" -and (Is-OllamaAssignee -Assignee ([string]$_.assignee)) }).Count
                if ($snap -gt [int]$LocalModelMaxParallel) {
                    throw "WATCHDOG invariant: concurrent Ollama assignees exceeded LocalModelMaxParallel ($snap > $LocalModelMaxParallel)."
                }

                $madeDispatchProgress = $true
                break
            }

            if (-not $madeDispatchProgress) {
                break
            }
        }

        $tasks = Get-Tasks -ProjectId $Project
        $ready = @($tasks | Where-Object { $_.status -eq "ready" })
        $running = @($tasks | Where-Object { $_.status -eq "in_progress" })
        $review = @($tasks | Where-Object { $_.status -eq "in_review" })
        $done = @($tasks | Where-Object { $_.status -eq "done" })
        $blocked = @($tasks | Where-Object { $_.status -eq "blocked" })

        # Auto review gate: in_review -> done/ready
        foreach ($t in $review) {
            $file = Get-TaskFilePath -ProjectId $Project -TaskId $t.id
            $task = Read-JsonFile -Path $file
            if (-not ($task.PSObject.Properties.Name -contains "notes")) {
                $task | Add-Member -NotePropertyName notes -NotePropertyValue @() -Force
            }
            $text = @($task.notes | ForEach-Object { [string]$_.text }) -join " "
            $acceptance = Invoke-AcceptanceGate -ProjectId $Project -TaskData $task
            $hasIssueKeywords = $text -match "(?i)(fail|bug|missing|regression|blocked|429|rate\\s*limit|too\\s*many\\s*requests|quota\\s*exceeded)"
            if ($hasIssueKeywords -or -not $acceptance.passed) {
                $task.status = "ready"
                $task.notes += ([ordered]@{
                    at = (Get-Timestamp)
                    text = "AUTO-REVIEW: issues found, moved back to ready. " + (@($acceptance.reasons) -join "; ")
                })
                Add-MetricEvent -ProjectId $Project -EventType "requeued"
            } else {
                $task.status = "done"
                $task.notes += ([ordered]@{
                    at = (Get-Timestamp)
                    text = "AUTO-REVIEW: passed, moved to done."
                })
                Add-MetricEvent -ProjectId $Project -EventType "done"
            }
            Add-MetricEvent -ProjectId $Project -EventType "reviewed"
            if (-not ($task.PSObject.Properties.Name -contains "leaseUntil")) {
                $task | Add-Member -NotePropertyName leaseUntil -NotePropertyValue $null -Force
            }
            $task.leaseUntil = $null
            $task.updatedAt = (Get-Timestamp)
            Write-JsonFile -Path $file -Data $task
            Write-Host ("  [review] {0} -> {1}" -f $t.id, $task.status) -ForegroundColor DarkGray
            Write-InteractionFeedLine @{
                kind        = "watchdog_review_auto"
                project     = $Project
                taskId      = [string]$t.id
                status      = ([string]$task.status)
                acceptance  = if ($acceptance.passed) { "pass" } else { "fail" }
            }
        }

        if ($MaxRounds -gt 0 -and $round -ge $MaxRounds) {
            Write-Host "Max rounds reached: $MaxRounds" -ForegroundColor Yellow
            break
        }

        if ($ready.Count -eq 0 -and $running.Count -eq 0 -and $review.Count -eq 0) {
            Write-Host "No runnable tasks left. Watchdog exit." -ForegroundColor Green
            break
        }
        Start-Sleep -Seconds $Interval
    }
}
