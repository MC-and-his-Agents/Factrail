# Factrail GitHub Planning Model

## 核心原则

Issue = 工作事实。所有目标、需求、任务、研究、决策和缺陷都必须有可追踪的 Issue。

Project = 多视角计划板。Project 用字段、过滤器和视图表达路线图、当前迭代、风险、研究队列和发布就绪状态。

Milestone = Phase 发布边界。Milestone 不表示 sprint，而表示一个阶段性产品目标或版本边界。

FR = Feature Requirement。FR 是可交付功能要求，连接 Phase 与具体 Work Item。

Work Item = 可执行任务。Work Item 是实现、调研、决策、Bug、Chore、Docs 或 Test 的最小可推进单位。

## 层级

```text
Phase
  FR
    Work Item
```

GitHub 映射：

- Phase = Milestone + `[Phase]` 顶层 Issue。
- FR = `[FR]` Issue，挂到对应 Phase。不能使用 sub-issue 时，在正文中维护父级链接。
- Work Item = `[Work Item]` Issue，挂到对应 FR。不能使用 sub-issue 时，在正文中维护父级链接。

## Phase 使用方式

Phase 用来描述阶段目标、版本边界、范围、排除项、退出标准、FR 列表和主要风险。

Factrail 当前 Phase：

- `v0.1 Local Codex Usage MVP`
- `v0.2 Project-level Analytics`
- `v0.3 Realtime App-server Collector`
- `v0.4 Attribution Engine`
- `v0.5 Multi-provider Foundation`

## FR 使用方式

FR 必须说明用户或系统问题、功能范围、数据影响、验收标准、依赖和风险。

FR 不应直接承载所有实现细节。实现、测试、调研和决策应拆成 Work Item。

## Work Item 使用方式

Work Item 必须能被一个执行者在明确边界内推进。每个 Work Item 至少要有所属 FR、工作类型、任务描述、验收标准和测试要求。

研究型 Work Item 必须有输出物和判断标准。决策型 Work Item 必须记录选项、选择、后果和后续工作。

## Project fields

Project 名称：`Factrail Product & Engineering`

字段规划：

| Field | Type | Values |
| --- | --- | --- |
| Status | Single select | Inbox, Ready, In Progress, In Review, Blocked, Done, Dropped |
| Priority | Single select | P0, P1, P2, P3 |
| Level | Single select | Phase, FR, Work Item |
| Work Type | Single select | Product, Engineering, Research, Decision, Design, Maintenance, Docs, Test |
| Area | Single select | Core Schema, Codex JSONL, Scanner Cache, Usage Accounting, Pricing, SQLite Store, Reports, App Server, Attribution, Export, Docs, CI, Governance |
| Provider | Single select | Codex, Claude, OpenCode, OpenClaw, Generic, N/A |
| Data Layer | Single select | Raw, Normalized, Derived, Export, N/A |
| Trust Level | Single select | Exact, Estimated, Unknown, N/A |
| Source | Single select | Self, ccusage, CodexBar, CodexMonitor, openai-codex, Mixed, N/A |
| Risk | Single select | Schema Drift, Privacy, Performance, Pricing, Attribution, License, None |
| Target Version | Single select | v0.1, v0.2, v0.3, v0.4, v0.5, Later |
| Confidence | Single select | Known, Needs Research, Risky |
| Estimate | Number | 数字估算 |
| Iteration | Iteration | Project iteration |

## Labels

Label 用来支持 GitHub 原生过滤和自动化触发，不替代 Project fields。

主要分组：

- `level:*`
- `type:*`
- `priority:*`
- `area:*`
- `provider:*`
- `source:*`
- `risk:*`
- `trust:*`
- `status:*`

## Views

GitHub Project v2 当前 CLI/API 不能稳定创建 view。请在 GitHub UI 中为 `Factrail Product & Engineering` 创建以下 views：

### Roadmap

- Layout: Roadmap
- Filter: `Level = Phase OR Level = FR`
- Group by: `Target Version`
- Visible fields: `Status`, `Priority`, `Target Version`, `Owner`

### Current Iteration

- Layout: Board
- Filter: `Iteration = @current`
- Group by: `Status`
- Visible fields: `Priority`, `Area`, `Estimate`, `Owner`

### Backlog

- Layout: Table
- Filter: `Status = Inbox OR Status = Ready`
- Group by: `Area`
- Sort: `Priority asc`

### FR Board

- Layout: Board
- Filter: `Level = FR`
- Group by: `Status`
- Visible fields: `Phase`, `Priority`, `Area`, `Target Version`

### Research Queue

- Layout: Table
- Filter: `Work Type = Research AND Status != Done`
- Group by: `Source`
- Visible fields: `Area`, `Risk`, `Confidence`, `Owner`

### Architecture Decisions

- Layout: Table
- Filter: `Work Type = Decision`
- Group by: `Area`
- Visible fields: `Status`, `Area`, `Risk`, `Source`, `Target Version`

### Risk Board

- Layout: Board
- Filter: `Risk != None AND Status != Done`
- Group by: `Risk`

### Release Readiness

- Layout: Table
- Filter: `Target Version = v0.1 OR Milestone = v0.1 Local Codex Usage MVP`
- Group by: `Status`
- Visible fields: `Priority`, `Owner`, `Estimate`, `Risk`

## Definition of Ready

- 问题清楚
- scope 清楚
- acceptance criteria 清楚
- Area 已设置
- Priority 已设置
- Target Version 已设置
- 没有未解决 blocker

## Definition of Done

- PR merged 或 decision recorded
- tests added/updated, if applicable
- docs updated, if user-visible
- schema migration documented, if applicable
- follow-up issues created, if scope was cut

## 每周节奏

- 周初：清理 Inbox，确认 Ready 项，更新 Current Iteration。
- 周中：检查 Blocked、Risk Board 和 Research Queue，补齐决策输出。
- 周末：按 Phase/FR 回顾 Done 项，检查 Release Readiness，补创建 follow-up issues。

## PR 规则

- 非 trivial PR 必须关联 issue
- Feature PR 必须对应 FR 或 Work Item
- Bug PR 必须包含 reproduction 或 regression test
- Schema PR 必须说明 migration impact
- Pricing PR 必须说明 pricing source/version
- Attribution PR 必须说明 exact / estimated / unknown 边界

## 反模式

- 不要把所有事情都写成 Work Item，缺少 Phase/FR 层
- 不要用 milestone 表示 sprint
- 不要用 label 替代所有 Project fields
- 不要让 Research issue 没有输出
- 不要在 PR 里做没有 issue 的架构变更
- 不要把 GUI 提前塞进 v0.1
- 不要承诺 tool/MCP/agent 精确归因，除非 source 明确支持

## 自动化

`.github/workflows/project-triage.yml` 会在新 issue 或 PR 创建后尝试加入 `Factrail Product & Engineering` Project，并根据 labels 设置 `Level`、`Priority`、`Work Type`。

`Factrail Product & Engineering` 是 organization-level Project。GitHub 官方文档说明 `GITHUB_TOKEN` 只具备 repository-level 访问能力，不能访问 Projects。因此这个 workflow 需要一个名为 `PROJECTS_TOKEN` 的 repository secret，或后续改成 GitHub App installation token。

PAT 方案下，token 需要 `repo` 与 `project` scope；组织 Project 还需要账号有对应组织权限。

```bash
gh auth refresh -s repo -s project
```

## 初始化脚本

脚本位于 `scripts/github-planning/`：

- `setup-labels.sh`
- `setup-milestones.sh`
- `setup-project.sh`
- `seed-issues.sh`

所有脚本支持 `DRY_RUN=1`，会从当前 Git remote 自动推导 `OWNER/REPO`，并且不删除已有 GitHub 资源。
