# Cursor Autolook — Cursor 作为执行中枢

这是一个以 **Cursor Agent** 为中枢的多模型协作工作台。
目标是把多模型并行分析、单执行者写入、审查闭环这套方法，
迁移成以 Cursor 会话为核心的执行流程。

## 核心思路

- 并行分析，串行写入：允许多个模型做分析，但同一时刻只允许一个执行者落地改动。
- Cursor 为中枢：任务调度、执行指令、结果汇总都由 Cursor 会话驱动。
- 审查后完成：执行者不能自证完成，必须经过 reviewer 才能标记 done。
- 便宜优先：先用廉价模型做扫描，重推理和最终审查再升级模型。

## 快速开始

```powershell
# 查看帮助
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1

# 初始化本地状态目录
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 init

# 新建项目
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 new-project -Name my-project

# 新建任务
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 new-task -Project my-project -Title "学习仓库并给出风险点" -Assignee DeepSeek -Reviewer "GitHub gpt-5-mini"

# 查看状态
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 status

# 更新任务状态
powershell -ExecutionPolicy Bypass -File .\cursor-autolook.ps1 set-task -Project my-project -TaskId <task-id> -Status in_review
```

## 目录结构

```text
cursor-autolook.ps1                    # 顶层入口（Cursor 中枢）
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

## 命令说明

- `init`：初始化 `runtime` 状态目录。
- `new-project`：创建项目。
- `new-task`：创建任务。
- `set-task`：更新任务状态和备注。
- `status`：输出项目与任务总览。
- `next`：挑选下一个可执行任务（`ready`）。

## 仓库地址

目标远端仓库：
[`https://github.com/zhuguang-ZFG/cursor_autolook.git`](https://github.com/zhuguang-ZFG/cursor_autolook.git)

根据公开页面，该仓库当前显示为空仓库，可直接推送此版本：
[`https://github.com/zhuguang-ZFG/cursor_autolook`](https://github.com/zhuguang-ZFG/cursor_autolook)
