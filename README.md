# Cursor Autolook — Cursor 作为执行中枢

这是一个以 **Cursor Agent** 为中枢的多模型协作工作台。
目标是把多模型并行分析、单执行者写入、审查闭环这套方法，
迁移成以 Cursor 会话为核心的执行流程。

## 核心思路

- 并行分析，串行写入：允许多个模型做分析，但同一时刻只允许一个执行者落地改动。
- Cursor 为中枢：任务调度、执行指令、结果汇总都由 Cursor 会话驱动。
- 审查后完成：执行者不能自证完成，必须经过 reviewer 才能标记 done。
- 便宜优先：先用廉价模型做扫描，重推理和最终审查再升级模型。
- 端口隔离：本仓库固定使用 `16121-16160`，避开另外两仓常用段 `15921-15960`。

## 快速开始

```powershell
# 一键调度（推荐）：进工作流 + 另开窗口跑 watchdog，不占当前终端
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 schedule
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 schedule -Project my-project-id
# 一键调度（回调环）：新窗口 automation-hub
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 schedule-hub [-Project …]
# 登录后自动启动 schedule-hub（隐藏子进程；任务计划「当前用户登录时」触发）
powershell -ExecutionPolicy Bypass -File .\scripts\Register-AutolookLogonTask.ps1 [-AutoLookRoot D:\path\to\cursor_autolook] [-Project 项目ID] [-DelaySeconds 45] [-VisibleWindow]
powershell -ExecutionPolicy Bypass -File .\scripts\Register-AutolookLogonTask.ps1 -Unregister
# 仅进工作流上下文（无调度窗口）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 go [-Project …]
# 别名：go-watch / go-hub 与 schedule / schedule-hub 等价

# 查看帮助（或默认无参数时为交互菜单）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 help
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 menu

# 初始化本地状态目录
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 init

# 新建项目
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 new-project -Name my-project

# 新建任务
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 new-task -Project my-project -Title "学习仓库并给出风险点" -Assignee DeepSeek -Reviewer "GitHub gpt-5-mini"

# 新建带验收契约的任务（产物 + 测试命令 + 最大重试）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 new-task -Project my-project -Title "修复登录" -Artifacts "src/auth/login.ts,tests/auth.spec.ts" -TestCommand "npm test -- tests/auth.spec.ts" -MaxAttempts 3

# 指定任务类型（命中对应缓存模板）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 new-task -Project my-project -Title "重构用户模块" -TaskType refactor

# 查看状态
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 status

# 检查端口是否与其它仓冲突
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 check-ports

# 调和过期租约任务
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 reconcile -Project my-project

# 启动自动编排循环（watchdog）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 watchdog -Project my-project -Interval 20

# 启动命令行分屏中枢（Claude 窗格自动按任务量计算）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 dashboard -Project my-project

# 也可手动覆盖自动值
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 dashboard -Project my-project -ClaudeCount 4

# 执行自动审查决策（in_review -> done/ready）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 review -Project my-project -TaskId <task-id>

# 一键快速自检
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 quick-check

# 环境体检（端口、语法、回调队列、CC Switch 路径、可选配置提示）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 doctor

# 仅列出待消费的回调文件（不执行 consume）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 list-callbacks

# 命令行实时跟读对齐事件（写入 runtime/interaction-feed.jsonl；另开终端 tail 即可）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 follow-feed -Project my-project
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 follow-feed -Project my-project -FeedOnce -FeedTail 50

# 弹出新 PowerShell 窗口看 feed（持续滚动；加 -FeedOnce 则回放后仍保留窗口）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 follow-feed -Project my-project -FeedNewWindow
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 follow-feed -Project my-project -FeedNewWindow -FeedOnce -FeedTail 80
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 follow-feed -FeedTail 200

# CC Switch DB 与路由配置对照（需本机已安装 python）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 ccswitch-providers

# 本机隔离端口启动 Codex app-server（WebSocket JSON-RPC，给外挂客户端 / 另一个终端当「打工仔」）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 serve-codex

# 一键端到端闭环验证
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 e2e-check

# 查看产能指标
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 metrics

# 生成缓存友好的任务 brief（静态前缀 + 动态后缀）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 prep-brief -Project my-project -TaskId <task-id>

# 查看提示词缓存命中率
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 cache-stats

# 冻结项目级长前缀（高频复用上下文）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 set-project-prefix -Project my-project -ProjectPrefix "Core stack: React+Node; coding style: minimal diffs; tests required for behavior changes."

# 进入工作流上下文（一键输出 status/metrics/brief）
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 enter-workflow -Project my-project

# 更新任务状态
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 set-task -Project my-project -TaskId <task-id> -Status in_review
```

## 目录结构

```text
cursor-autolook.ps1                    # 入口：参数、路径常量、命令分发；点源 lib/Autolook.Core.ps1
lib/
  Autolook.Core.ps1                    # 装载器：按文件名顺序 dot-source lib/domains/*.ps1
  domains/                             # 按功能域拆分的实现脚本（文件名前缀序号即加载顺序）
    01-Common.ps1                      # JSON/时间戳/度量、端口取值、Throttle 等底座
    02-Feed.ps1 … 20-Help.ps1          # Feed、路由、Worker 队列、Watchdog、Hub、回调等
  worker-queue-viewer.html             # serve-worker-queue GET / 看板静态页（占位符 @@ESC_PROJ@@）
scripts/
  split-autolook-core.ps1              #（可选）参数 -SourceFile 指向合并快照 .ps1，按脚本内映射重建 lib/domains
multi-ai-routing-playbook.md           # 路由角色与提示词模板
runtime/
  projects/
    <project-id>/
      project.json
      tasks/
        <task-id>.json
```

## 推荐工作流

1. 用 `new-project` 创建一个项目上下文。
2. 用 `new-task` 放入 3-5 个可独立执行的任务。
3. 在 Cursor 中串行执行任务（一次只让一个任务处于 `in_progress`）。
4. 执行完成后标记 `in_review`，由 reviewer 复核。
5. reviewer 通过后改为 `done`，失败则回到 `ready` 或 `blocked`。
6. 若任务卡死，运行 `reconcile`；若想持续自动推进，运行 `watchdog`。
7. 需要自动判定时，运行 `review`；发布前用 `e2e-check` 做闭环验收。

## 命令说明

- `init`：初始化 `runtime` 状态目录。
- `new-project`：创建项目。
- `new-task`：创建任务。
- `new-task`：支持任务契约（`-Artifacts`、`-TestCommand`、`-MaxAttempts`）。
- `new-task`：支持任务类型模板（`-TaskType bugfix|refactor|review|general`，不传则自动识别）。
- `new-task`：`-AutoAdvanceOnGatePass` — 与 **`automation-hub -HubAutoAdvanceGate`** 联动，通过验收门后可自动进入 `in_review`（见下文「多智能体自动化中枢」）。
- `set-task`：更新任务状态和备注。
- `status`：输出项目与任务总览。
- `next`：挑选下一个可执行任务（`ready`）。
- `reconcile`：把过期 `in_progress`（租约超时）任务回退到 `ready`。
- `watchdog`：自动编排循环（调和 + 自动分派下一个 `ready` 任务）。
- `review`：自动审查决策（`in_review` -> `done/ready`）。
- `review`：自动审查决策 + 强制验收门（产物存在、测试命令通过）。
- `prep-brief`：按缓存策略生成任务 brief（尽量提高 token 缓存命中）。
- `cache-stats`：查看缓存命中/未命中统计与命中率。
- `set-project-prefix`：设置项目级长前缀（跨任务稳定复用上下文）。
- `enter-workflow`：一键注入工作流上下文（项目状态、指标、任务 brief）。
- `dashboard`：Windows Terminal 多窗格工作台（Cursor 主控 + Ops / 回调 tick + OpenCode + DeepSeek + Claude 队列）；并自动再开一个 **「Codex-AppServer」标签页** 执行 **`serve-codex`**（默认 `ws://127.0.0.1:16128`），未安装 `codex` CLI 时该标签会提示并保持空壳。仍会按任务量自动计算 Claude 数（`1-6`），可用 `-ClaudeCount` 覆盖（`0-6`）。
- `metrics`：查看累计吞吐指标（创建/分派/审查/完成/返工/阻断）。
- `check-ports`：检查当前端口规划是否与其它仓库冲突。
- `serve-codex`：在本机 **`127.0.0.1`** 启动 Codex **app-server**（默认 WebSocket 端口 **16128**，可 `-CodexServePort` 覆盖）。
- `quick-check`：一键快速健康检查（语法/端口/运行目录）。
- `doctor`：环境体检（语法、端口、`runtime` 目录、待处理回调数量、CC Switch 关键路径、Ollama 默认策略说明）。
- `list-callbacks`：列出 `runtime/callbacks` 下待消费 JSON（不执行 `consume-callbacks`）。
- `follow-feed`：在终端**持续**输出 `runtime/interaction-feed.jsonl`（新行格式化打印）。事件来源：`submit-agent-callback` 排队、watchdog **派发**、**consume-callbacks**、hub **门控推进**、自动 **review** 等。加 **`-FeedNewWindow`** 会 `Start-Process` **弹出新 PowerShell 窗口**（`-NoExit`）；**`-FeedOnce`** = 回放最近 `-FeedTail` 行后停在提示符不掉窗。
- `ccswitch-providers`：运行 `scripts/audit_cc_switch_providers.py`，核对 DB 与 `cc-switch-router.config.json`。
- `e2e-check`：一键端到端闭环验证（创建项目并跑完整状态流转）。
- `automation-hub`：多智能体编排主循环（回调消费 + 可选门控推进 + 单轮 watchdog）。
- `worker-queue`：导出 Sidecar 可用的任务队列 JSON（含 `nextStep` 指引与 `evidencePaths` 证据路径建议）。
- `serve-worker-queue`：本机只读 HTTP 查看/拉取同一快照。
- `kxnx-audit`：为 `D:\GIT\kxnx` 这类逆向工程仓库一键创建 8 个功能审查任务并自动跑完闭环。
- 可选：将仓库根目录的 `autolook.config.example.json` 复制为 `runtime/autolook.config.json` 并编辑 `defaultOllamaModel`；在未传 `-OllamaModel` 时，`new-task` 对 assignee=Ollama 会使用该默认值。

## 调度并发与本地模型

- `watchdog` 支持 **`-MaxConcurrentTasks`**（默认 `1`）：大于 1 时允许多个任务同时处于 `in_progress`（便于云侧/多窗格并行）。
- **`-LocalModelMaxParallel`**（默认 `1`）：对 **assignee 为 `Ollama`（本地）** 的任务做硬上限；超限则按 `fallbackAssignees` **自动改派**为非 Ollama；若无可用回退则本轮对该任务 **等待**（`[wait] Local model serialized`）。
- **`stress-scheduler`**：生成一批 `general`（偏 Ollama）+ `bugfix`（DeepSeek）的合成任务，在短时间内循环 `watchdog`，并断言 **任意时刻最多 1 个 Ollama 在跑**，同时记录 `concurrentRunning` 峰值。默认跑完会删掉临时项目目录（可用 `-StressKeepProject` 保留排查）。

```powershell
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 stress-scheduler
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 stress-scheduler -StressTasks 16 -StressLocalHeavyTasks 8 -StressIterations 600
```

## Codex 作为隔离端口的「打工仔」

OpenAI **Codex CLI** 支持 `codex app-server --listen ws://127.0.0.1:端口`（JSON-RPC over WebSocket，上游标注为实验能力）。本仓库已对齐 **`16121–16160`** 段，默认 **Codex 占 `16128`**（`runtime/ports.json` → `defaults.codex`）。

```powershell
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 serve-codex
# 覆盖端口
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 serve-codex -CodexServePort 18090
```

- 另开终端可 **`codex --remote ws://127.0.0.1:16128`** 挂上同一进程（以你本机 Codex 版本文档为准）。
- 需要 WS 鉴权时，设置环境变量 **`AUTOLOOK_CODEX_WS_TOKEN_FILE`** 指向 token 文件，将自动附加 `--ws-auth capability-token --ws-token-file ...`。
- **说明**：`cursor_autolook` 只负责 **固定端口 + 拉起进程**；任务状态机仍通过 **`automation-hub` / `worker-queue` / `submit-agent-callback`** 等与中枢同步。批量/CI 场景官方更推荐 **Codex SDK**，与「长期挂一个 app-server」场景不同。

## 多智能体自动化中枢（automation-hub）

把 **`consume-callbacks`（外挂智能体收口）**、可选 **验收门驱动的自动推进**、以及 **单轮 `watchdog`（调度+自动审查）** 串在一个循环里，适合做「人机混合」的长期值守进程。

- **`automation-hub`**：默认每轮执行 `consume-callbacks` →（可选）`HubAutoAdvanceGate` → **`watchdog -MaxRounds 1`**。无活跃任务时自动退出。
  - **`-HubMaxCycles N`**：`N=0`（默认）表示一直跑到队列闲置；`N>0` 表示最多跑 N 轮（便于冒烟 / CI）。
  - **`-SkipHubConsumeCallbacks`**：跳过回调消费（只做调度与审查）。
  - **`-HubAutoAdvanceGate`**：对已派工任务，若 JSON 里 `automation.autoAdvanceOnGatePass=true`，且 **`Invoke-AcceptanceGate`（产物 + `TestCommand`）通过**，则中枢自动 `in_progress` → `in_review`，下一轮子由 `watchdog` 自动审查收口 **`done`**。  
    - **务必谨慎**：只对「可由测试/产物客观判定」的任务打开；新建任务可加 **`-AutoAdvanceOnGatePass`**。
  - 与其它参数组合：可提高 **`-MaxConcurrentTasks`** 以并行调度云侧执行体，同时用 **`-LocalModelMaxParallel 1`** 将 **Ollama** 固定在单路并行。

```powershell
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 automation-hub -Project MYPROJ -Interval 15 -HubAutoAdvanceGate -MaxConcurrentTasks 4 -LocalModelMaxParallel 1

powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 automation-hub -Project MYPROJ -SkipHubConsumeCallbacks -HubMaxCycles 120
```

- **`worker-queue`**：导出 **`runtime/worker-queue/<PROJECT>.json`**。除 `briefPath`、`autoAdvanceOnGatePass`、`callbackHint` 外，每条任务带 **`nextStep`**：
  - **`primaryNextAction`**：机器可读阶段（如 `wait_dispatch`、`execute_then_callback`、`execute_then_gate_automation_or_callback`、`wait_auto_review`）。
  - **`actionHints`** / **`automationChannels`** / **`suggestedSequence`**：给人看的说明、可走的中枢通道、推荐顺序（含示例命令行）。
  - **`evidencePaths`**：按 `taskType` 与标题规则生成的建议证据目录/文件，帮助审查任务快速聚焦代码位置。
- **`serve-worker-queue`**：在本机 **`127.0.0.1`** 起 **只读** HTTP（无额外依赖），每次请求即时生成与 `worker-queue` 相同结构的 JSON。
  - 默认端口取 **`runtime/ports.json` → `defaults.workerQueue`（16127）**；可用 **`-WorkerQueueServePort`** 覆盖。
  - **`GET /`**：可视化看板（状态计数、派发流水线说明、任务卡片含 `nextStep`/`callbackHint`，约 4s 自动刷新；底部可展开原始 JSON）；**`GET /api/worker-queue.json`**：JSON。

```powershell
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 worker-queue -Project MYPROJ -WorkerQueuePrepBrief

powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 serve-worker-queue -Project MYPROJ

powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 serve-worker-queue -Project MYPROJ -WorkerQueueServePort 18080 -WorkerQueuePrepBrief
```

## 无人化能力现状

- 已实现：自动调度、自动回收、自动审查、验收门、失败重试上限熔断（超限 `blocked`）。
- 已实现：告警钩子（写入 `runtime/alerts.log`，可选 `AUTOLOOK_ALERT_WEBHOOK` 推送）。
- 已实现：提示词缓存（静态前缀 + 动态后缀哈希，记录 `cacheHit/cacheMiss`）。
- 已实现：按任务类型的缓存模板版本化（`bugfix/refactor/review/general`）。
- 已实现：项目级长前缀冻结（`project-prefix-v1.md`）。
- 已实现：命中率阈值告警（默认 `<30%` 触发，可用 `AUTOLOOK_CACHE_HITRATE_THRESHOLD` 调整）。
- 已实现：`ops-report` 自动写入 `runtime/reports/ops-report-<project>-<timestamp>.md` 便于归档。

## 端口规划

- 本仓保留端口段：`16121-16160`
- 避让端口段：`15921-15960`（`autolook` / `deepseek_autolook` 已占用）
- 默认分配：
  - hub: `16121`
  - api: `16122`
  - dashboard: `16123`
  - reviewer: `16124`
  - opencode: `16125`
  - deepseek: `16126`
  - worker-queue HTTP（`serve-worker-queue`）: `16127`
  - Codex app-server WebSocket（`serve-codex`）: `16128`

## 仓库地址

目标远端仓库：
[`https://github.com/zhuguang-ZFG/cursor_autolook.git`](https://github.com/zhuguang-ZFG/cursor_autolook.git)

根据公开页面，该仓库当前显示为空仓库，可直接推送此版本：
[`https://github.com/zhuguang-ZFG/cursor_autolook`](https://github.com/zhuguang-ZFG/cursor_autolook)
