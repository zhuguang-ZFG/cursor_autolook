param(
    [Parameter(Position = 0)]
    [ValidateSet("menu", "go", "go-watch", "go-hub", "help", "init", "new-project", "new-task", "set-task", "status", "next", "check-ports", "reconcile", "watchdog", "review", "dashboard", "quick-check", "e2e-check", "stress-scheduler", "kxnx-audit", "automation-hub", "worker-queue", "serve-worker-queue", "follow-feed", "doctor", "list-callbacks", "ccswitch-providers", "metrics", "prep-brief", "cache-stats", "set-project-prefix", "enter-workflow", "serve-codex", "serve-deepseek", "serve-opencode", "current-workflow", "agent-done", "close-open", "consume-callbacks", "watch-callbacks", "evolve-supervisor", "supervisor-evolution", "evolve-routing", "evolve-reliability", "ops-report")]
    [string]$Command = "menu",

    [string]$Name,
    [string]$Project,
    [string]$Title,
    [ValidateSet("ready", "in_progress", "in_review", "done", "blocked")]
    [string]$Status,
    [string]$TaskId,
    [string]$Assignee = "DeepSeek",
    [string]$Reviewer = "GitHub gpt-5-mini",
    [string]$Note,
    [string]$Artifacts,
    [string]$TestCommand,
    [string]$TaskType,
    [string]$WorkerModel,
    [string]$CcSwitchModel,
    [string]$Source,
    [string]$TraceId,
    [string]$SessionId,
    [string]$ProjectPrefix,
    [string]$OllamaModel = "qwen3.5:9b",
    [int]$Interval = 30,
    [int]$MaxRounds = 0,
    [int]$LeaseMinutes = 45,
    [int]$ClaudeCount = -1,
    [int]$MaxAttempts = 3,
    [switch]$AllowInsecure,
    [switch]$NoAutoRoute,
    [switch]$ApproveExpensive,
    [switch]$AutoContinue,
    [switch]$SkipLayoutEvolve,
    [switch]$LayoutAutoEvolve,
    [double]$DashboardMainOpsSplit = -1,
    [double]$DashboardOpenCodeSplit = -1,
    [double]$DashboardDeepseekSplit = -1,
    [double]$DashboardClaudeStackSplit = -1,
    [int]$OpenCodeMaxParallel = 2,
    [int]$OpenCodeBackoffSeconds = 120,
    [ValidateRange(1, 24)]
    [int]$MaxConcurrentTasks = 1,
    [ValidateRange(1, 8)]
    [int]$LocalModelMaxParallel = 1,
    [ValidateRange(0, 512)]
    [int]$StressTasks = 0,
    [ValidateRange(0, 512)]
    [int]$StressLocalHeavyTasks = 0,
    [ValidateRange(0, 20000)]
    [int]$StressIterations = 0,
    [switch]$StressKeepProject,
    [switch]$AutoAdvanceOnGatePass,
    [switch]$HubAutoAdvanceGate,
    [switch]$SkipHubConsumeCallbacks,
    [ValidateRange(0, 100000)]
    [int]$HubMaxCycles = 0,
    [switch]$WorkerQueuePrepBrief,
    [ValidateRange(0, 65535)]
    [int]$WorkerQueueServePort = 0,
    [ValidateRange(0, 65535)]
    [int]$CodexServePort = 0,
    [switch]$DashboardSinglePane,
    [ValidateRange(1, 9999)]
    [int]$FeedTail = 100,
    [switch]$FeedOnce,
    [switch]$FeedNewWindow
)

$ErrorActionPreference = "Stop"
$Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$RuntimeDir = Join-Path $Root "runtime"
$ProjectsDir = Join-Path $RuntimeDir "projects"
$PortsFile = Join-Path $RuntimeDir "ports.json"
$MetricsFile = Join-Path $RuntimeDir "metrics.json"
$AlertsLogFile = Join-Path $RuntimeDir "alerts.log"
$PromptCacheDir = Join-Path $RuntimeDir "prompt-cache"
$CurrentWorkflowFile = Join-Path $RuntimeDir "current-workflow.json"
$RoutingFile = Join-Path $RuntimeDir "routing.json"
$CallbacksDir = Join-Path $RuntimeDir "callbacks"
$CallbacksProcessedDir = Join-Path $CallbacksDir "processed"
$WorkerQueueDir = Join-Path $RuntimeDir "worker-queue"
$DashboardLayoutFile = Join-Path $RuntimeDir "dashboard-layout.json"
$SupervisorEvolutionFile = Join-Path $RuntimeDir "supervisor-evolution.json"
$OpenCodeThrottleFile = Join-Path $RuntimeDir "opencode-throttle.json"
$ReportsDir = Join-Path $RuntimeDir "reports"
$InteractionFeedFile = Join-Path $RuntimeDir "interaction-feed.jsonl"
$ReservedPortStart = 16121
$ReservedPortEnd = 16160
$KnownConflictStart = 15921
$KnownConflictEnd = 15960
$DefaultCacheHitRateThreshold = 30.0

$InternalPath = Join-Path $Root "lib\Autolook.Core.ps1"
if (-not (Test-Path -LiteralPath $InternalPath)) {
    throw "Missing implementation fragment: $InternalPath"
}
. $InternalPath

switch ($Command) {
    "menu"        { Invoke-SimpleMenu }
    "go"          { Invoke-GoWorkflow }
    "go-watch"    { Invoke-GoWatch }
    "go-hub"      { Invoke-GoHub }
    "help"        { Show-Help }
    "init"        { Invoke-Init }
    "new-project" { Invoke-NewProject }
    "new-task"    {
        $savedOllama = $OllamaModel
        if (-not $PSBoundParameters.ContainsKey('OllamaModel')) {
            $cfgPath = Join-Path $RuntimeDir "autolook.config.json"
            if (Test-Path $cfgPath) {
                try {
                    $ac = Read-JsonFile -Path $cfgPath
                    if ($ac.PSObject.Properties.Name -contains "defaultOllamaModel") {
                        $m = [string]$ac.defaultOllamaModel
                        if (-not [string]::IsNullOrWhiteSpace($m)) { $script:OllamaModel = $m }
                    }
                } catch {
                    throw "Invalid autolook.config.json: $_"
                }
            }
        }
        try {
            Invoke-NewTask
        } finally {
            $script:OllamaModel = $savedOllama
        }
    }
    "set-task"    { Invoke-SetTask }
    "agent-done"  { Invoke-AgentDone }
    "close-open"  { Invoke-CloseOpen }
    "consume-callbacks" { Invoke-ConsumeCallbacks }
    "follow-feed"       { Invoke-FollowFeed }
    "watch-callbacks" { Invoke-WatchCallbacks }
    "status"      { Invoke-Status }
    "next"        { Invoke-Next }
    "reconcile"   { Invoke-Reconcile }
    "watchdog"    { Invoke-Watchdog }
    "review"      { Invoke-Review }
    "prep-brief"  { Invoke-PrepBrief }
    "cache-stats" { Invoke-CacheStats }
    "set-project-prefix" { Invoke-SetProjectPrefix }
    "enter-workflow" { Invoke-EnterWorkflow }
    "current-workflow" { Invoke-CurrentWorkflow }
    "dashboard"   { Invoke-Dashboard }
    "evolve-supervisor" { Invoke-EvolveSupervisor }
    "evolve-routing" { Invoke-EvolveRouting }
    "evolve-reliability" { Invoke-EvolveReliability }
    "ops-report" { Invoke-OpsReport }
    "supervisor-evolution" { Invoke-SupervisorEvolutionStatus }
    "serve-codex" { Invoke-ServeCodex }
    "serve-deepseek" { Invoke-ServeDeepSeek }
    "serve-opencode" { Invoke-ServeOpenCode }
    "metrics"     { Invoke-Metrics }
    "check-ports" { Invoke-CheckPorts }
    "quick-check" { Invoke-QuickCheck }
    "e2e-check"   { Invoke-E2ECheck }
    "stress-scheduler" { Invoke-StressScheduler }
    "kxnx-audit" { Invoke-KxnxAudit }
    "automation-hub" { Invoke-AutomationHub }
    "worker-queue" { Invoke-WorkerQueueSnapshot }
    "serve-worker-queue" { Invoke-ServeWorkerQueue }
    "doctor"      { Invoke-Doctor }
    "list-callbacks" { Invoke-ListCallbacks }
    "ccswitch-providers" { Invoke-CcSwitchProviders }
    default       { Show-Help }
}
