# Cursor-Centric Multi-AI Routing Playbook

## Principles

- Parallel analysis, serial execution.
- At any moment, only one assignee has write authority.
- Cursor session is the orchestrator and final integration point.
- Workers cannot self-certify completion; reviewer decides `done`.
- Cheap-first, quality-gated escalation.
- Port isolation by repo: `cursor_autolook` uses `16121-16160`, never reuse `15921-15960`.

## Role Mapping

- `DeepSeek`
  - 初轮仓库学习
  - 方案草拟
  - 可执行改动

- `LongCat-Flash-Thinking-2601`
  - 任务拆解
  - 风险推演
  - 复杂权衡建议

- `GitHub gpt-5-mini`
  - 快速审查
  - 简化检查
  - 回归风险提示

- `GitHub claude-haiku-4.5`
  - 轻量复核
  - 问题定位

- `qwen3.5:9b` / `gemma4:e4b`
  - 目录浏览
  - 简报总结
  - 低风险辅助任务

## Cursor 中枢执行模板

### 1) 初始学习

```text
学习这个仓库并回答：
1. 系统目标
2. 核心模块
3. 最大风险
4. 不改代码，只做分析
```

### 2) 计划拆解

```text
把任务拆成最小可执行步骤：
1. 目标
2. 约束
3. 最小方案
4. 失败点
5. 不执行，只给方案
```

### 3) 执行

```text
现在执行：
1. 先读相关文件
2. 只改与任务直接相关内容
3. 给出变更说明
4. 不确定时提出具体问题
```

### 4) 审查

```text
审查这个改动：
1. 明显 bug
2. 回归风险
3. 缺失测试
4. 只列问题，不重写方案
```

## Status Machine

- `ready` -> `in_progress` -> `in_review` -> `done`
- 异常路径：
  - `in_progress` -> `blocked`
  - `in_review` -> `ready` (返工)
- 中枢守护：
  - `watchdog` 自动分派下一个 `ready`
  - `reconcile` 自动回收租约过期的 `in_progress`
  - `review` 自动把 `in_review` 判定为 `done/ready`

## Do Not

- 不要让多个模型同时写同一个目标文件。
- 不要让本地小模型做最终质量判断。
- 不要在无审查的情况下直接标记 `done`。
