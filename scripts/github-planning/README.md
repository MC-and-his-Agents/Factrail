# Factrail GitHub Planning Setup

这些脚本用于初始化 Factrail 的 GitHub Issues / Projects 产品规划与开发管理模型。

## 前置检查

```bash
git rev-parse --is-inside-work-tree
git remote get-url origin
command -v gh
gh auth status
```

token 需要包含 `repo`、`project` 和 `workflow` scope。缺少 scope 时执行：

```bash
gh auth refresh -s repo -s project -s workflow
```

## 执行顺序

```bash
scripts/github-planning/setup-labels.sh
scripts/github-planning/setup-milestones.sh
scripts/github-planning/setup-project.sh
scripts/github-planning/seed-issues.sh
```

如果 GitHub Project GraphQL 写字段时网络不稳定，可以先只创建/复用 issues：

```bash
SKIP_PROJECT_FIELDS=1 scripts/github-planning/seed-issues.sh
```

## Dry run

```bash
DRY_RUN=1 scripts/github-planning/setup-labels.sh
DRY_RUN=1 scripts/github-planning/setup-milestones.sh
DRY_RUN=1 scripts/github-planning/setup-project.sh
DRY_RUN=1 scripts/github-planning/seed-issues.sh
```

## 幂等性

- 不删除已有 label、milestone、issue、project。
- label、milestone、project、issue 都先查重再创建。
- 已存在 issue 会复用，不会创建同名重复 issue。
- Project view 需要手工在 GitHub UI 中配置，详见 `docs/github-planning-model.md`。

## 手工项

GitHub Project v2 当前不能通过公开 CLI/API 稳定创建 views。请在 `Factrail Product & Engineering` Project 中手工创建：

- Roadmap
- Current Iteration
- Backlog
- FR Board
- Research Queue
- Architecture Decisions
- Risk Board
- Release Readiness

因为 `Factrail Product & Engineering` 是 organization-level Project，GitHub Actions 默认的 `GITHUB_TOKEN` 不能访问 Project v2。请创建 repository secret：

```text
PROJECTS_TOKEN
```

该 token 需要 `repo` 与 `project` scope，并且账号需要组织 Project 写权限。

更长期的组织级方案是使用 GitHub App，并授予 organization projects read/write 权限。
