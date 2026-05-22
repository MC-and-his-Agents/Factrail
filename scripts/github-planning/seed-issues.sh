#!/usr/bin/env bash
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
PROJECT_TITLE="${PROJECT_TITLE:-Factrail Product & Engineering}"
SKIP_PROJECT_FIELDS="${SKIP_PROJECT_FIELDS:-0}"

repo_from_git() {
  local url owner_repo
  url="$(git remote get-url origin)"
  owner_repo="${url#git@github.com:}"
  owner_repo="${owner_repo#https://github.com/}"
  owner_repo="${owner_repo%.git}"
  printf '%s\n' "$owner_repo"
}

REPO="${REPO:-$(repo_from_git)}"
OWNER="${OWNER:-${REPO%%/*}}"
MAP_FILE="$(mktemp)"
CREATED_COUNT=0
REUSED_COUNT=0

cleanup() {
  rm -f "$MAP_FILE"
}
trap cleanup EXIT

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required. Install GitHub CLI first." >&2
  exit 1
fi

gh_api_retry() {
  local attempt=1
  local max_attempts=5
  local delay=2
  while true; do
    if gh api "$@"; then
      return 0
    fi
    if [[ "$attempt" -ge "$max_attempts" ]]; then
      return 1
    fi
    echo "GitHub API failed; retry $attempt/$max_attempts after ${delay}s..." >&2
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

project_json="$(gh project list --owner "$OWNER" --format json --limit 200 \
  | jq -c --arg title "$PROJECT_TITLE" '.projects[] | select(.title == $title)' || true)"
PROJECT_NUMBER="$(jq -r '.number // empty' <<<"$project_json")"
PROJECT_ID="$(jq -r '.id // empty' <<<"$project_json")"

if [[ -n "$PROJECT_NUMBER" ]]; then
  FIELD_JSON="$(gh project field-list "$PROJECT_NUMBER" --owner "$OWNER" --format json --limit 100)"
else
  FIELD_JSON='{"fields":[]}'
  echo "Project not found; issues will be created without Project item fields." >&2
fi

fetch_issue_cache() {
  gh_api_retry --paginate "repos/$REPO/issues?state=all&per_page=100" \
    | jq -s 'add | map(select(.pull_request | not) | {number, title, url: .html_url})'
}

ISSUE_CACHE="$(fetch_issue_cache)"

issue_lookup_json() {
  printf '%s\n' "$ISSUE_CACHE"
}

append_issue_cache() {
  local title="$1" url="$2" number="$3"
  ISSUE_CACHE="$(jq -c --arg title "$title" --arg url "$url" --argjson number "$number" '. + [{title:$title, url:$url, number:$number}]' <<<"$ISSUE_CACHE")"
}

record_issue() {
  local title="$1" url="$2" number="$3" state="${4:-reused}"
  printf '%s\t%s\t%s\t%s\n' "$title" "$url" "$number" "$state" >>"$MAP_FILE"
}

issue_url() {
  local title="$1"
  awk -F '\t' -v title="$title" '$1 == title { print $2; exit }' "$MAP_FILE"
}

issue_number() {
  local title="$1"
  awk -F '\t' -v title="$title" '$1 == title { print $3; exit }' "$MAP_FILE"
}

issue_created() {
  local title="$1"
  awk -F '\t' -v title="$title" '$1 == title { print $4; exit }' "$MAP_FILE"
}

write_body() {
  local body="$1" file="$2"
  printf '%s\n' "$body" >"$file"
}

milestone_number_by_title() {
  local title="$1"
  [[ -z "$title" ]] && return 0
  gh_api_retry "repos/$REPO/milestones?state=all&per_page=100" \
    | jq -r --arg title "$title" '.[] | select(.title == $title) | .number' | head -n 1
}

field_id() {
  local name="$1"
  jq -r --arg name "$name" '.fields[]? | select(.name == $name) | .id' <<<"$FIELD_JSON" | head -n 1
}

option_id() {
  local field="$1" option="$2"
  jq -r --arg field "$field" --arg option "$option" '.fields[]? | select(.name == $field) | .options[]? | select(.name == $option) | .id' <<<"$FIELD_JSON" | head -n 1
}

set_field() {
  local item_id="$1" field="$2" option="$3"
  local fid oid
  [[ -z "$PROJECT_ID" || -z "$item_id" || -z "$option" || "$option" == "N/A" ]] && return 0
  fid="$(field_id "$field")"
  oid="$(option_id "$field" "$option")"
  if [[ -z "$fid" || -z "$oid" ]]; then
    echo "skip project field: $field=$option"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY_RUN] gh project item-edit --field $field --option $option"
  else
    gh project item-edit --id "$item_id" --project-id "$PROJECT_ID" --field-id "$fid" --single-select-option-id "$oid" >/dev/null || true
  fi
}

add_to_project() {
  local url="$1" level="$2" work_type="$3" priority="$4" area="$5" provider="$6" data_layer="$7" trust="$8" source="$9" risk="${10}" target="${11}" status="${12}" confidence="${13:-}"
  local item_id
  [[ "$SKIP_PROJECT_FIELDS" == "1" ]] && return 0
  [[ -z "$PROJECT_NUMBER" ]] && return 0

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY_RUN] add to project: $url"
    return 0
  fi

  item_id="$(gh project item-add "$PROJECT_NUMBER" --owner "$OWNER" --url "$url" --format json --jq '.id' 2>/dev/null || true)"
  if [[ -z "$item_id" ]]; then
    echo "skip project add, item may already exist: $url"
    return 0
  fi

  set_field "$item_id" "Level" "$level"
  set_field "$item_id" "Work Type" "$work_type"
  set_field "$item_id" "Priority" "$priority"
  set_field "$item_id" "Area" "$area"
  set_field "$item_id" "Provider" "$provider"
  set_field "$item_id" "Data Layer" "$data_layer"
  set_field "$item_id" "Trust Level" "$trust"
  set_field "$item_id" "Source" "$source"
  set_field "$item_id" "Risk" "$risk"
  set_field "$item_id" "Target Version" "$target"
  set_field "$item_id" "Status" "$status"
  if [[ -n "$confidence" ]]; then
    set_field "$item_id" "Confidence" "$confidence"
  fi
}

ensure_issue() {
  local title="$1" labels="$2" milestone="$3" body="$4"
  local level="$5" work_type="$6" priority="$7" area="$8" provider="$9" data_layer="${10}" trust="${11}" source="${12}" risk="${13}" target="${14}" status="${15}" confidence="${16:-}"
  local existing url number body_file

  existing="$(issue_lookup_json | jq -r --arg title "$title" '.[] | select(.title == $title) | [.url, .number] | @tsv' | head -n 1)"
  if [[ -n "$existing" ]]; then
    url="$(cut -f1 <<<"$existing")"
    number="$(cut -f2 <<<"$existing")"
    echo "exists issue: $title"
    REUSED_COUNT=$((REUSED_COUNT + 1))
    issue_state="reused"
  else
    echo "create issue: $title"
    if [[ "$DRY_RUN" == "1" ]]; then
      url="https://github.com/$REPO/issues/DRY_RUN"
      number="DRY_RUN"
    else
      local milestone_number response json_file
      milestone_number="$(milestone_number_by_title "$milestone")"
      json_file="$(mktemp)"
      jq -n \
        --arg title "$title" \
        --arg body "$body" \
        --arg labels "$labels" \
        --argjson milestone_number "${milestone_number:-0}" \
        '{title:$title, body:$body, labels:($labels | split(","))}
        + (if $milestone_number > 0 then {milestone:$milestone_number} else {} end)' >"$json_file"
      response="$(gh_api_retry -X POST "repos/$REPO/issues" -H "Content-Type: application/json" --input "$json_file")"
      rm -f "$json_file"
      url="$(jq -r '.html_url' <<<"$response")"
      number="$(jq -r '.number' <<<"$response")"
      append_issue_cache "$title" "$url" "$number"
    fi
    CREATED_COUNT=$((CREATED_COUNT + 1))
    issue_state="created"
  fi

  record_issue "$title" "$url" "$number" "$issue_state"
  add_to_project "$url" "$level" "$work_type" "$priority" "$area" "$provider" "$data_layer" "$trust" "$source" "$risk" "$target" "$status" "$confidence"
}

edit_issue_body_if_created() {
  local title="$1" body="$2" number
  [[ "$DRY_RUN" == "1" ]] && return 0
  [[ "$(issue_created "$title")" != "created" ]] && return 0
  number="$(issue_number "$title")"
  [[ -z "$number" || "$number" == "DRY_RUN" ]] && return 0
  local file
  file="$(mktemp)"
  jq -n --arg body "$body" '{body:$body}' >"$file"
  gh_api_retry -X PATCH "repos/$REPO/issues/$number" -H "Content-Type: application/json" --input "$file" >/dev/null
  rm -f "$file"
}

phase_body() {
  local goal="$1" in_scope="$2" out_scope="$3" exit_criteria="$4" fr_list="$5" risks="$6"
  cat <<EOF
## 目标

$goal

## In scope

$in_scope

## Out of scope

$out_scope

## Exit criteria

$exit_criteria

## FR 列表

$fr_list

## 风险

$risks
EOF
}

fr_body() {
  local phase="$1" problem="$2" scope="$3" data="$4" in_scope="$5" out_scope="$6" acceptance="$7" deps="$8" risks="$9" work_items="${10:-待补充。}"
  cat <<EOF
## 所属 Phase

$phase

## 用户/系统问题

$problem

## 功能范围

$scope

## 数据影响

$data

## In scope

$in_scope

## Out of scope

$out_scope

## Acceptance criteria

$acceptance

## 依赖

$deps

## 风险

$risks

## Work Items

$work_items
EOF
}

work_body() {
  local fr="$1" type="$2" description="$3" implementation="$4" acceptance="$5" tests="$6" deps="$7"
  cat <<EOF
## 所属 FR

$fr

## 工作类型

$type

## 任务描述

$description

## 实现建议

$implementation

## Acceptance criteria

$acceptance

## 测试要求

$tests

## 依赖

$deps
EOF
}

decision_body() {
  local decision="$1" context="$2" options="$3" chosen="$4" consequences="$5" followup="$6"
  cat <<EOF
## Decision

$decision

## Status

Accepted

## Context

$context

## Options considered

$options

## Chosen option

$chosen

## Consequences

$consequences

## Follow-up work

$followup
EOF
}

research_body() {
  local question="$1" decision="$2" targets="$3" deliverables="$4" criteria="$5"
  cat <<EOF
## 研究问题

$question

## 要解锁的决策

$decision

## 调研对象

$targets

## 输出物

$deliverables

## 判断标准

$criteria

## 结论

待调研后补充。

## Follow-up issues

待调研后创建或链接。
EOF
}

ensure_issue "[Phase] v0.1 Local Codex Usage MVP" "level:phase,priority:p0,area:usage-accounting,provider:codex,source:self,risk:privacy,status:ready" "v0.1 Local Codex Usage MVP" "$(phase_body "跑通 scan -> normalize -> delta accounting -> price -> store -> report -> export，让 Factrail 成为本地 Codex usage 数据基础层的最小可用版本。" "Codex JSONL 扫描、核心归一化 schema、增量 usage accounting、pricing、本地 SQLite store、CLI report、JSON/CSV export、第三方许可归因。" "GUI；完整 realtime；Claude/OpenCode/OpenClaw adapter；tool/MCP/agent 精确归因；cloud sync。" "本地 Codex 会话可以被扫描、归一化、入库、计价、报表和导出；敏感原始内容默认只保留 pointer；fixture-based tests 覆盖关键路径。" "待 FR 创建后补充链接。" "隐私暴露、Codex JSONL schema drift、pricing source 变化、累积 token 转 delta 的边界。")" "Phase" "Product" "P0" "Usage Accounting" "Codex" "N/A" "N/A" "Self" "Privacy" "v0.1" "Ready" "Known"
ensure_issue "[Phase] v0.2 Project-level Analytics" "level:phase,priority:p1,area:reports,source:self,status:ready" "v0.2 Project-level Analytics" "$(phase_body "把本地 usage 数据提升到 project/workspace 维度，形成长期可查询的数据资产。" "project/workspace detection、git root mapping、cwd/session association、project-level reports、privacy-safe raw event pointers。" "完整 GUI；跨 provider adapter；realtime timeline；精细 item/tool/MCP attribution。" "可以按 project/workspace 查询 usage/cost/report，并能追溯到隐私安全的 raw event pointer。" "待后续规划。" "cwd 与 git root 关联不稳定、历史 session 缺少上下文、隐私边界。")" "Phase" "Product" "P1" "Reports" "N/A" "Derived" "N/A" "Self" "Privacy" "v0.2" "Ready" "Known"
ensure_issue "[Phase] v0.3 Realtime App-server Collector" "level:phase,priority:p1,area:app-server,provider:codex,source:openai-codex,risk:schema-drift,status:needs-research" "v0.3 Realtime App-server Collector" "$(phase_body "接入 openai/codex generated app-server schema，把实时执行事件归一化到 Factrail 数据层。" "generated app-server schema integration、stdio JSON-RPC client、thread/turn/item reducer、tokenUsage event capture、item lifecycle timeline。" "完整 GUI；非 Codex provider adapter；tool/MCP/agent 精确成本归因承诺。" "可以消费 Codex app-server 事件并生成 thread/turn/item timeline 与 tokenUsage 事件。" "待后续规划。" "openai/codex schema drift、reducer 状态机复杂度、realtime 性能。")" "Phase" "Product" "P1" "App Server" "Codex" "Raw" "Exact" "openai-codex" "Schema Drift" "v0.3" "Inbox" "Needs Research"
ensure_issue "[Phase] v0.4 Attribution Engine" "level:phase,priority:p1,area:attribution,trust:estimated,risk:attribution,status:needs-research" "v0.4 Attribution Engine" "$(phase_body "建立可信成本归因模型，明确 exact / estimated / unknown 的边界。" "turn-level exact attribution、item/tool/MCP-level estimated attribution、unknown bucket、confidence/method/explanation model。" "在 source 不支持时伪造 item/tool/MCP 精确归因；完整上层分析 GUI。" "每条 attribution record 都有 trust level、method、confidence 和 explanation；未知部分进入 unknown bucket。" "待后续规划。" "归因边界误导、source 缺失、估算方法可解释性。")" "Phase" "Product" "P1" "Attribution" "N/A" "Derived" "Estimated" "Self" "Attribution" "v0.4" "Inbox" "Needs Research"
ensure_issue "[Phase] v0.5 Multi-provider Foundation" "level:phase,priority:p2,area:governance,provider:generic,source:mixed,status:needs-research" "v0.5 Multi-provider Foundation" "$(phase_body "为 Claude Code、OpenCode、OpenClaw 等 provider 建立 adapter 基础，不改变 Factrail 数据层核心边界。" "provider adapter interface、Claude Code local adapter research or MVP、OpenCode/OpenClaw adapter research、provider capability matrix、cross-provider normalized reports。" "把 provider adapter 做成上层 GUI；跳过 normalized schema 自研；直接 fork 第三方项目作为主干。" "provider capability matrix 清晰，至少完成一个非 Codex adapter 的研究或 MVP，并能输出跨 provider normalized reports。" "待后续规划。" "provider 行为差异、license、schema drift、privacy。")" "Phase" "Product" "P2" "Governance" "Generic" "Normalized" "N/A" "Mixed" "License" "v0.5" "Inbox" "Needs Research"

P01="$(issue_url "[Phase] v0.1 Local Codex Usage MVP")"

ensure_issue "[FR] Core Normalized Schema / 核心归一化数据模型" "level:fr,type:feature,priority:p0,area:core-schema,provider:generic,source:self,risk:schema-drift,status:ready" "v0.1 Local Codex Usage MVP" "$(fr_body "$P01" "不同 agent/provider 的执行事件需要落到稳定、可查询、可归因的数据模型。" "定义 Workspace / Project / Thread / Turn / Item、UsageEvent、CostEvent、AttributionRecord 等 v0.1 核心 schema。" "决定 normalized layer 与 derived layer 的长期契约，并约束 SQLite store、report、export 的字段。" "v0.1 normalized schema；schema version；raw pointer；usage/cost/attribution 基础结构。" "完整 multi-provider schema；GUI 专用 analytics model；伪造精确 item/tool/MCP attribution。" "schema 文档清楚；fixture 可以按 schema 校验；后续 store/report/export 可直接引用。" "Codex JSONL Scanner、Usage Accounting。" "schema drift、归因语义过度承诺。")" "FR" "Engineering" "P0" "Core Schema" "Generic" "Normalized" "N/A" "Self" "Schema Drift" "v0.1" "Ready" "Known"
ensure_issue "[FR] Codex JSONL Scanner / Codex 本地日志扫描" "level:fr,type:feature,priority:p0,area:codex-jsonl,provider:codex,source:self,risk:schema-drift,status:ready" "v0.1 Local Codex Usage MVP" "$(fr_body "$P01" "Factrail 需要本地优先地发现并读取 Codex JSONL 会话日志。" "发现 CODEX_HOME，扫描 sessions 与 archived_sessions 下的 JSONL，并输出 raw event pointer 与可归一化事件。" "直接影响 Raw layer、raw_event_pointers、scanner cache 和 privacy 边界。" "CODEX_HOME discovery；sessions/archived_sessions 扫描；JSONL 行级解析；错误隔离。" "realtime app-server；Claude/OpenCode/OpenClaw scanner；上传原始日志内容。" "默认路径可用；异常 JSONL 不阻断全量扫描；扫描结果可被 normalize 使用。" "Core Normalized Schema、Scanner Cache。" "Codex 路径变化、JSONL schema drift、隐私内容暴露。")" "FR" "Engineering" "P0" "Codex JSONL" "Codex" "Raw" "Exact" "Self" "Schema Drift" "v0.1" "Ready" "Known"
ensure_issue "[FR] Usage Accounting / Token 用量核算" "level:fr,type:feature,priority:p0,area:usage-accounting,provider:codex,source:mixed,risk:attribution,trust:exact,status:ready" "v0.1 Local Codex Usage MVP" "$(fr_body "$P01" "Codex token_count 事件里包含 cumulative usage，需要转成可计费、可汇总的 delta event。" "解析 token_count，处理 total_token_usage 与 last_token_usage，实现 cumulative -> delta accounting，并区分 exact / estimated / unknown。" "生成 UsageEvent，并为 CostEvent、report、export 提供可信输入。" "input/cached input/output/reasoning tokens；negative delta guard；duplicate delta guard。" "item/tool/MCP/agent 精确归因；非 Codex provider accounting。" "同一 session 重扫不会重复计数；负 delta 不产生伪精确数据；fixture 覆盖主要 token shape。" "Core Normalized Schema、Codex JSONL Scanner。" "token source 语义变化、重复扫描、归因误导。")" "FR" "Engineering" "P0" "Usage Accounting" "Codex" "Derived" "Exact" "Mixed" "Attribution" "v0.1" "Ready" "Known"
ensure_issue "[FR] Pricing Engine / 成本计算引擎" "level:fr,type:feature,priority:p0,area:pricing,source:ccusage,risk:pricing,status:ready" "v0.1 Local Codex Usage MVP" "$(fr_body "$P01" "usage 需要根据 model 与 token type 转换为可解释的 cost event。" "接入 LiteLLM pricing source，建立 offline pricing cache，并记录 pricing source/version。" "生成 CostEvent，影响 report/export 的成本字段。" "model price lookup；offline cache；unknown price 处理；pricing source/version 记录。" "自研完整 pricing database；无来源的精确成本承诺。" "已知 model 可计算成本；未知 model 进入 unknown；离线时可使用 cache。" "Usage Accounting。" "pricing source 变更、模型命名不一致。")" "FR" "Engineering" "P0" "Pricing" "Generic" "Derived" "Estimated" "ccusage" "Pricing" "v0.1" "Ready" "Known"
ensure_issue "[FR] Scanner Cache / 增量扫描缓存" "level:fr,type:feature,priority:p1,area:scanner-cache,source:codexbar,status:ready" "v0.1 Local Codex Usage MVP" "$(fr_body "$P01" "重复扫描本地日志时，需要避免重复解析和重复入库。" "使用 mtime / size / parsedBytes 设计增量 scanner cache。" "影响 scanner throughput、raw pointer、usage delta 的幂等性。" "文件级 cache；parsedBytes checkpoint；cache invalidation；异常恢复。" "复杂 distributed cache；云同步。" "重复执行 scan 只处理新增 bytes；文件变化可被检测；cache 损坏可重建。" "Codex JSONL Scanner、Usage Accounting。" "mtime 不可靠、文件截断、archive move。")" "FR" "Engineering" "P1" "Scanner Cache" "Codex" "Raw" "N/A" "CodexBar" "Performance" "v0.1" "Ready" "Known"
ensure_issue "[FR] SQLite Store / 本地长期存储" "level:fr,type:feature,priority:p0,area:sqlite-store,source:self,risk:privacy,status:ready" "v0.1 Local Codex Usage MVP" "$(fr_body "$P01" "Factrail 需要本地优先、长期可查询、最小敏感内容暴露的数据资产。" "设计 SQLite schema migration，写入 usage_events、cost_events、raw_event_pointers 等核心表。" "决定持久化 schema、migration 机制和 report/export 查询基础。" "SQLite schema；migration；insert/upsert；raw pointer 默认存储。" "DuckDB 主存储；云同步；存储完整敏感原文。" "scan 后数据可查询；migration 可重复执行；raw logs 默认只以 pointer 形式出现。" "Core Normalized Schema、Usage Accounting、Pricing Engine。" "隐私边界、migration 兼容性。")" "FR" "Engineering" "P0" "SQLite Store" "Generic" "Normalized" "N/A" "Self" "Privacy" "v0.1" "Ready" "Known"
ensure_issue "[FR] CLI Reports / 命令行报表" "level:fr,type:feature,priority:p1,area:reports,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(fr_body "$P01" "第一阶段不做完整 GUI，需要通过 CLI 产出可用报表。" "实现 factrail scan、report daily、report session、report model。" "消费 SQLite derived data，输出本地可读 usage/cost summary。" "daily/session/model 维度；unknown bucket；pricing source 提示。" "完整 GUI；复杂 BI analysis。" "CLI 命令稳定；报表可解释 exact/estimated/unknown；输出适合复制和审计。" "SQLite Store、Pricing Engine。" "报表误导、unknown 成本展示不清。")" "FR" "Engineering" "P1" "Reports" "Generic" "Derived" "N/A" "Self" "None" "v0.1" "Ready" "Known"
ensure_issue "[FR] Export / JSON 与 CSV 导出" "level:fr,type:feature,priority:p1,area:export,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(fr_body "$P01" "Factrail 的数据层需要可复用输出，供上层应用或分析工具消费。" "实现 JSON 与 CSV 导出，保留 trust level、source、raw pointer、pricing metadata。" "决定 Export layer 的字段和隐私边界。" "factrail export json；factrail export csv；schema version；privacy-safe output。" "完整 REST API；GUI download；导出敏感 raw content。" "导出可被外部工具读取；字段包含 source/trust/version；默认不输出敏感原文。" "SQLite Store、Core Normalized Schema。" "隐私泄露、字段不稳定。")" "FR" "Engineering" "P1" "Export" "Generic" "Export" "N/A" "Self" "Privacy" "v0.1" "Ready" "Known"
ensure_issue "[FR] Third-party Notice / 第三方许可归因" "level:fr,type:feature,priority:p1,area:governance,type:docs,source:mixed,risk:license,status:ready" "v0.1 Local Codex Usage MVP" "$(fr_body "$P01" "Factrail 会参考 ccusage、CodexBar、CodexMonitor 和 openai/codex，需要清晰记录借鉴边界与许可归因。" "创建 third_party/NOTICE.md，记录参考项目、许可证、使用方式和非 fork 主干原则。" "影响治理、license 风险和后续 contributor 理解。" "NOTICE 文档；参考边界；不 fork 说明。" "复制第三方代码作为主干；不记录来源。" "第三方来源、许可证和使用边界清晰；与 repo 文档一致。" "Research 与 Decision issues。" "license 风险、误读第三方边界。")" "FR" "Docs" "P1" "Governance" "N/A" "N/A" "N/A" "Mixed" "License" "v0.1" "Ready" "Known"

CORE_FR="$(issue_url "[FR] Core Normalized Schema / 核心归一化数据模型")"
SCAN_FR="$(issue_url "[FR] Codex JSONL Scanner / Codex 本地日志扫描")"
USAGE_FR="$(issue_url "[FR] Usage Accounting / Token 用量核算")"
PRICE_FR="$(issue_url "[FR] Pricing Engine / 成本计算引擎")"
CACHE_FR="$(issue_url "[FR] Scanner Cache / 增量扫描缓存")"
STORE_FR="$(issue_url "[FR] SQLite Store / 本地长期存储")"
REPORT_FR="$(issue_url "[FR] CLI Reports / 命令行报表")"
EXPORT_FR="$(issue_url "[FR] Export / JSON 与 CSV 导出")"
NOTICE_FR="$(issue_url "[FR] Third-party Notice / 第三方许可归因")"

ensure_issue "[Work Item] 定义 Workspace / Project / Thread / Turn / Item schema" "level:work-item,type:task,priority:p0,area:core-schema,source:self,risk:schema-drift,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$CORE_FR" "Engineering" "定义 Factrail v0.1 的核心实体 schema，包括 Workspace、Project、Thread、Turn、Item。" "优先写成 schema 文档和测试 fixture 可校验结构，避免绑定上层 GUI 假设。" "字段定义、关系、schema version 和最小 raw pointer 语义清楚。" "添加 fixture 或 schema validation 测试。" "无。")" "Work Item" "Engineering" "P0" "Core Schema" "Generic" "Normalized" "N/A" "Self" "Schema Drift" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 定义 UsageEvent / CostEvent / AttributionRecord schema" "level:work-item,type:task,priority:p0,area:core-schema,trust:estimated,source:self,risk:attribution,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$CORE_FR" "Engineering" "定义 UsageEvent、CostEvent、AttributionRecord 的字段、trust level 与 source 语义。" "明确 exact / estimated / unknown，AttributionRecord 不承诺来源不支持的精确性。" "schema 能表达 token、cost、method、confidence、explanation 和 unknown bucket。" "添加 schema fixture tests。" "Workspace/Project/Thread/Turn/Item schema。")" "Work Item" "Engineering" "P0" "Core Schema" "Generic" "Derived" "Estimated" "Self" "Attribution" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 实现 CODEX_HOME discovery" "level:work-item,type:task,priority:p0,area:codex-jsonl,provider:codex,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$SCAN_FR" "Engineering" "实现 CODEX_HOME discovery，默认识别 ~/.codex，并支持环境变量覆盖。" "将路径发现逻辑做成 scanner 的独立入口，便于测试。" "默认路径、环境变量路径、缺失路径都有清晰行为。" "添加临时目录 fixture tests。" "无。")" "Work Item" "Engineering" "P0" "Codex JSONL" "Codex" "Raw" "Exact" "Self" "None" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 扫描 ~/.codex/sessions/**/*.jsonl" "level:work-item,type:task,priority:p0,area:codex-jsonl,provider:codex,source:self,risk:schema-drift,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$SCAN_FR" "Engineering" "扫描 ~/.codex/sessions/**/*.jsonl 并输出行级 raw event pointer。" "使用 glob/walk，记录 path、line/byte offset、mtime、size。" "可发现 nested sessions JSONL；异常文件不中断扫描。" "添加 sessions fixture tests。" "CODEX_HOME discovery。")" "Work Item" "Engineering" "P0" "Codex JSONL" "Codex" "Raw" "Exact" "Self" "Schema Drift" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 扫描 ~/.codex/archived_sessions/**/*.jsonl" "level:work-item,type:task,priority:p1,area:codex-jsonl,provider:codex,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$SCAN_FR" "Engineering" "扫描 ~/.codex/archived_sessions/**/*.jsonl，保证历史会话也可进入数据层。" "与 sessions scanner 共享实现，保留 archive path metadata。" "archive 文件可被发现、解析并去重。" "添加 archived_sessions fixture tests。" "sessions scanner。")" "Work Item" "Engineering" "P1" "Codex JSONL" "Codex" "Raw" "Exact" "Self" "None" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 解析 payload.type == token_count" "level:work-item,type:task,priority:p0,area:usage-accounting,provider:codex,trust:exact,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$USAGE_FR" "Engineering" "解析 Codex JSONL 中 payload.type == token_count 的事件。" "只把明确 token_count 的 payload 送入 usage accounting，其他事件保留 raw pointer。" "token_count fixture 能解析为内部 usage input。" "添加 token_count fixture tests。" "Codex JSONL scanner。")" "Work Item" "Engineering" "P0" "Usage Accounting" "Codex" "Raw" "Exact" "Self" "None" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 处理 total_token_usage 与 last_token_usage" "level:work-item,type:task,priority:p0,area:usage-accounting,provider:codex,trust:exact,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$USAGE_FR" "Engineering" "处理 token_count payload 中 total_token_usage 与 last_token_usage 的差异。" "优先保留 source 语义，明确哪些字段是 cumulative，哪些字段可直接表达 last usage。" "两种 usage shape 都能被归一化。" "添加 total/last usage fixture tests。" "token_count parser。")" "Work Item" "Engineering" "P0" "Usage Accounting" "Codex" "Derived" "Exact" "Self" "None" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 实现 cumulative -> delta accounting" "level:work-item,type:task,priority:p0,area:usage-accounting,provider:codex,trust:exact,source:self,risk:attribution,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$USAGE_FR" "Engineering" "把 cumulative token usage 转换为幂等的 delta usage events。" "按 session/model/token type 维护上一计数，避免重扫重复计费。" "delta 结果可重放；重扫不重复增加 usage。" "添加 repeated scan fixture tests。" "total_token_usage parser。")" "Work Item" "Engineering" "P0" "Usage Accounting" "Codex" "Derived" "Exact" "Self" "Attribution" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 归一化 input / cached input / output / reasoning tokens" "level:work-item,type:task,priority:p0,area:usage-accounting,provider:codex,trust:exact,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$USAGE_FR" "Engineering" "归一化 input、cached input、output、reasoning tokens，保持字段命名稳定。" "保留 unknown token bucket，避免丢失未知字段。" "四类 token 可被 report/export 使用；未知字段不伪装为已知类型。" "添加 token type fixture tests。" "UsageEvent schema。")" "Work Item" "Engineering" "P0" "Usage Accounting" "Codex" "Normalized" "Exact" "Self" "None" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 实现 negative delta / duplicate delta guard" "level:work-item,type:task,priority:p0,area:usage-accounting,provider:codex,trust:exact,source:self,risk:attribution,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$USAGE_FR" "Engineering" "实现 negative delta 与 duplicate delta guard，防止伪造精确 usage。" "negative delta 进入异常或 unknown 处理；duplicate delta 不重复写入。" "异常路径可解释；不会生成错误的精确 cost。" "添加 negative/duplicate fixture tests。" "cumulative -> delta accounting。")" "Work Item" "Engineering" "P0" "Usage Accounting" "Codex" "Derived" "Exact" "Self" "Attribution" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 设计 mtime / size / parsedBytes scanner cache" "level:work-item,type:task,priority:p1,area:scanner-cache,source:codexbar,risk:performance,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$CACHE_FR" "Engineering" "设计并实现基于 mtime、size、parsedBytes 的 scanner cache。" "记录文件扫描 checkpoint，支持 append-only JSONL 的增量读取。" "重复扫描只处理新增内容；文件截断或变化会触发安全重扫。" "添加 cache fixture tests。" "Codex JSONL scanner。")" "Work Item" "Engineering" "P1" "Scanner Cache" "Codex" "Raw" "N/A" "CodexBar" "Performance" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 实现 LiteLLM pricing source" "level:work-item,type:task,priority:p0,area:pricing,source:ccusage,risk:pricing,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$PRICE_FR" "Engineering" "实现 LiteLLM pricing source lookup，用于 model/token type 成本计算。" "记录 pricing source 和版本或更新时间。" "已知 model 能查到价格；未知 model 明确为 unknown。" "添加 pricing lookup tests。" "UsageEvent schema。")" "Work Item" "Engineering" "P0" "Pricing" "Generic" "Derived" "Estimated" "ccusage" "Pricing" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 实现 offline pricing cache" "level:work-item,type:task,priority:p1,area:pricing,source:self,risk:pricing,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$PRICE_FR" "Engineering" "实现 offline pricing cache，让本地报表不依赖每次联网。" "cache 中保留来源、更新时间和失效提示。" "离线可计算已缓存模型；过期或缺失价格可解释。" "添加 offline cache tests。" "LiteLLM pricing source。")" "Work Item" "Engineering" "P1" "Pricing" "Generic" "Derived" "Estimated" "Self" "Pricing" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 设计 SQLite schema migration" "level:work-item,type:task,priority:p0,area:sqlite-store,source:self,risk:schema-drift,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$STORE_FR" "Engineering" "设计 SQLite schema migration 机制和 v0.1 初始 schema。" "保持 migration 可重复执行，记录 schema version。" "空库可初始化；已有库可检测 version；migration 失败有清楚错误。" "添加 migration tests。" "Core schema。")" "Work Item" "Engineering" "P0" "SQLite Store" "Generic" "Normalized" "N/A" "Self" "Schema Drift" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 写入 usage_events / cost_events / raw_event_pointers" "level:work-item,type:task,priority:p0,area:sqlite-store,source:self,risk:privacy,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$STORE_FR" "Engineering" "实现 usage_events、cost_events、raw_event_pointers 写入和幂等约束。" "使用稳定 key 避免重复写入；raw pointer 不默认存储敏感原文。" "scan 重跑不会重复写入；raw pointer 可追溯到来源文件。" "添加 store integration tests。" "SQLite migration、Usage Accounting、Pricing Engine。")" "Work Item" "Engineering" "P0" "SQLite Store" "Generic" "Normalized" "N/A" "Self" "Privacy" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 实现 factrail scan" "level:work-item,type:task,priority:p0,area:reports,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$REPORT_FR" "Engineering" "实现 factrail scan 命令，串联 scan -> normalize -> store。" "输出扫描摘要、错误摘要、写入计数和 unknown 计数。" "命令可在本地运行并写入 SQLite store。" "添加 CLI smoke tests。" "Scanner、Usage Accounting、SQLite Store。")" "Work Item" "Engineering" "P0" "Reports" "Codex" "Derived" "N/A" "Self" "None" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 实现 factrail report daily" "level:work-item,type:task,priority:p1,area:reports,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$REPORT_FR" "Engineering" "实现 factrail report daily，按日期汇总 usage 与 cost。" "展示 exact/estimated/unknown 区分和 pricing source。" "daily report 对 fixture 数据输出稳定。" "添加 snapshot 或 golden tests。" "SQLite Store、Pricing Engine。")" "Work Item" "Engineering" "P1" "Reports" "Generic" "Derived" "N/A" "Self" "None" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 实现 factrail report session" "level:work-item,type:task,priority:p1,area:reports,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$REPORT_FR" "Engineering" "实现 factrail report session，按 session/thread 汇总 usage 与 cost。" "保留 raw pointer 和 unknown bucket 提示。" "session report 可定位到对应 session。" "添加 report fixture tests。" "SQLite Store。")" "Work Item" "Engineering" "P1" "Reports" "Generic" "Derived" "N/A" "Self" "None" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 实现 factrail report model" "level:work-item,type:task,priority:p1,area:reports,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$REPORT_FR" "Engineering" "实现 factrail report model，按 model 汇总 usage 与 cost。" "未知 model 或未知 price 需要单独展示。" "model report 对多 model fixture 输出稳定。" "添加 model report tests。" "Pricing Engine。")" "Work Item" "Engineering" "P1" "Reports" "Generic" "Derived" "N/A" "Self" "None" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 实现 factrail export json" "level:work-item,type:task,priority:p1,area:export,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$EXPORT_FR" "Engineering" "实现 factrail export json，输出 schema version、events、trust/source metadata。" "默认不输出敏感 raw content，只输出 raw pointers。" "JSON 可被 jq 或下游程序消费。" "添加 JSON export tests。" "SQLite Store、Core schema。")" "Work Item" "Engineering" "P1" "Export" "Generic" "Export" "N/A" "Self" "Privacy" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 实现 factrail export csv" "level:work-item,type:task,priority:p1,area:export,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$EXPORT_FR" "Engineering" "实现 factrail export csv，输出 usage/cost/report 友好的列。" "CSV 字段保持稳定，包含 trust/source/pricing metadata。" "CSV 可被 spreadsheet 或 BI 工具读取。" "添加 CSV export tests。" "JSON export 字段定义。")" "Work Item" "Engineering" "P1" "Export" "Generic" "Export" "N/A" "Self" "Privacy" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 创建 third_party/NOTICE.md" "level:work-item,type:docs,priority:p1,area:governance,source:mixed,risk:license,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$NOTICE_FR" "Docs" "创建 third_party/NOTICE.md，记录 ccusage、CodexBar、CodexMonitor、openai/codex 的参考和许可边界。" "说明哪些是参考策略，哪些是协议事实源，哪些必须自研。" "NOTICE.md 存在且内容覆盖四个参考来源。" "文档检查。" "Research/Decision issues。")" "Work Item" "Docs" "P1" "Governance" "N/A" "N/A" "N/A" "Mixed" "License" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] 添加 fixture-based tests" "level:work-item,type:test,priority:p0,area:ci,provider:codex,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(work_body "$CORE_FR" "Test" "添加 fixture-based tests，覆盖 JSONL scanner、usage accounting、pricing、store、report、export 的关键路径。" "使用最小敏感 fixture，明确 schema version 和 token_count shape。" "关键路径有 fixture 覆盖；fixture 不包含真实敏感内容。" "新增或更新自动化测试。" "各 v0.1 FR。")" "Work Item" "Test" "P0" "CI" "Codex" "N/A" "N/A" "Self" "None" "v0.1" "Ready" "Known"

ensure_issue "[Work Item] Research: ccusage Codex parser migration boundary" "level:work-item,type:research,status:needs-research,priority:p1,area:usage-accounting,source:ccusage,risk:license" "v0.1 Local Codex Usage MVP" "$(research_body "ccusage 的 Codex parser 哪些策略可参考，哪些不能迁移为 Factrail 主干？" "确定 usage/cost/token accounting 的参考边界与自研实现边界。" "ccusage parser、pricing/accounting 相关实现、license。" "研究笔记；可参考策略清单；不能复制或必须自研的边界；follow-up Work Items。" "不 fork ccusage；不复制不兼容代码；能解释 Factrail 自研部分。")" "Work Item" "Research" "P1" "Usage Accounting" "Codex" "N/A" "Estimated" "ccusage" "License" "v0.1" "Inbox" "Needs Research"
ensure_issue "[Work Item] Research: CodexBar incremental scanner algorithm" "level:work-item,type:research,status:needs-research,priority:p1,area:scanner-cache,source:codexbar,risk:performance" "v0.1 Local Codex Usage MVP" "$(research_body "CodexBar 的 scanner/cache/provider strategy 中哪些增量扫描策略适合 Factrail？" "确定 mtime / size / parsedBytes cache 的实现边界。" "CodexBar scanner/cache/provider strategy。" "算法摘要；适配建议；风险；follow-up Work Items。" "能支持本地 JSONL 增量扫描，且不引入不必要的 app 层耦合。")" "Work Item" "Research" "P1" "Scanner Cache" "Codex" "Raw" "N/A" "CodexBar" "Performance" "v0.1" "Inbox" "Needs Research"
ensure_issue "[Work Item] Research: CodexMonitor app-server reducer architecture" "level:work-item,type:research,status:needs-research,priority:p2,area:app-server,source:codexmonitor,risk:schema-drift" "v0.3 Realtime App-server Collector" "$(research_body "CodexMonitor 的 realtime app-server/timeline reducer 架构哪些部分适合 Factrail v0.3？" "确定 app-server collector 与 timeline reducer 的边界。" "CodexMonitor app-server、timeline reducer、token usage capture。" "架构笔记；reducer state model；与 Factrail schema 的映射建议。" "能复用思路但不把 Factrail 变成上层 GUI/app。")" "Work Item" "Research" "P2" "App Server" "Codex" "Raw" "N/A" "CodexMonitor" "Schema Drift" "v0.3" "Inbox" "Needs Research"
ensure_issue "[Work Item] Research: openai/codex app-server schema generation" "level:work-item,type:research,status:needs-research,priority:p1,area:app-server,provider:codex,source:openai-codex,risk:schema-drift" "v0.3 Realtime App-server Collector" "$(research_body "openai/codex generated app-server schema 如何作为协议事实源接入 Factrail？" "确定 v0.3 是否直接消费 generated schema，以及 schema drift 检测方式。" "openai/codex app-server schema generation、stdio JSON-RPC schema、tokenUsage event。" "schema generation 流程；Factrail integration plan；drift guard 建议。" "不 fork openai/codex；把它作为协议事实源；Factrail 保持 normalized schema 自研。")" "Work Item" "Research" "P1" "App Server" "Codex" "Raw" "Exact" "openai-codex" "Schema Drift" "v0.3" "Inbox" "Needs Research"
ensure_issue "[Work Item] Research: SQLite vs DuckDB for local store" "level:work-item,type:research,status:needs-research,priority:p1,area:sqlite-store,source:self,risk:performance" "v0.1 Local Codex Usage MVP" "$(research_body "v0.1 local store 为什么选择 SQLite，而不是 DuckDB？" "确认本地长期存储和查询性能的技术选择。" "SQLite、DuckDB、本地优先数据层需求。" "对比表；推荐方案；迁移可能性；性能和维护风险。" "v0.1 能稳定落地；长期查询资产可演进；不提前引入过重依赖。")" "Work Item" "Research" "P1" "SQLite Store" "Generic" "Normalized" "N/A" "Self" "Performance" "v0.1" "Inbox" "Needs Research"
ensure_issue "[Work Item] Research: item/tool/MCP token attribution limits" "level:work-item,type:research,status:needs-research,priority:p0,area:attribution,trust:estimated,source:mixed,risk:attribution" "v0.4 Attribution Engine" "$(research_body "在 Codex 与其他 provider 的 source 数据中，item/tool/MCP token attribution 的精确边界在哪里？" "确定 exact / estimated / unknown 的归因策略和不能承诺的精确性。" "Codex token_count、app-server events、ccusage、CodexMonitor、provider capability matrix。" "归因限制说明；trust level rule；unknown bucket 规则；follow-up FR/Work Items。" "不伪造精确性；每条估算都有 method/confidence/explanation。")" "Work Item" "Research" "P0" "Attribution" "Generic" "Derived" "Estimated" "Mixed" "Attribution" "v0.4" "Inbox" "Needs Research"

ensure_issue "[Work Item] Decision: Use GitHub Issues as source of truth" "level:work-item,type:decision,priority:p0,area:governance,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(decision_body "Factrail 使用 GitHub Issues 作为产品规划和开发管理的 source of truth。" "Factrail 需要可追踪、可审计、可与 PR/CI 关联的开发管理模型。" "独立文档；外部任务系统；GitHub Issues + Project。" "采用 GitHub Issues + Project + Milestones，Issue 保存工作事实，Project 提供多视角计划板。" "所有非 trivial PR 必须关联 Issue；Project fields 维护计划状态。" "维护 issue templates、project fields、docs 和 triage workflow。")" "Work Item" "Decision" "P0" "Governance" "N/A" "N/A" "N/A" "Self" "None" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] Decision: Do not fork ccusage/CodexBar/CodexMonitor as main trunk" "level:work-item,type:decision,priority:p0,area:governance,source:mixed,risk:license,status:ready" "v0.1 Local Codex Usage MVP" "$(decision_body "Factrail 不把 ccusage、CodexBar、CodexMonitor fork 为主干。" "这些项目提供有价值参考，但 Factrail 的 attribution engine、normalized schema、SQLite store、project analytics 必须自研。" "直接 fork；复制关键实现；参考策略并自研。" "参考 usage/cost/token accounting、scanner/cache/provider strategy、realtime reducer architecture，但主干实现保持自研。" "需要 third_party/NOTICE.md 记录来源和边界。" "创建 NOTICE；研究 issues 输出可参考边界。")" "Work Item" "Decision" "P0" "Governance" "N/A" "N/A" "N/A" "Mixed" "License" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] Decision: Use openai/codex generated app-server schema" "level:work-item,type:decision,priority:p1,area:app-server,provider:codex,source:openai-codex,risk:schema-drift,status:ready" "v0.3 Realtime App-server Collector" "$(decision_body "v0.3 使用 openai/codex generated app-server schema 作为协议事实源。" "Factrail 不 fork openai/codex，但需要保持 Codex realtime collector 与事实协议一致。" "手写协议；fork openai/codex；消费 generated schema。" "把 openai/codex 作为事实源，Factrail 自研 normalized schema 与 reducer。" "需要 schema drift guard 和 integration research。" "完成 openai/codex schema generation research。")" "Work Item" "Decision" "P1" "App Server" "Codex" "Raw" "Exact" "openai-codex" "Schema Drift" "v0.3" "Ready" "Known"
ensure_issue "[Work Item] Decision: Store raw logs as pointers by default" "level:work-item,type:decision,priority:p0,area:sqlite-store,source:self,risk:privacy,status:ready" "v0.1 Local Codex Usage MVP" "$(decision_body "Factrail 默认只存储 raw logs pointers，不存储完整敏感原文。" "项目目标要求本地优先、最小敏感内容暴露、长期可查询数据资产。" "存完整 raw logs；只存 normalized events；存 raw pointer + normalized/derived events。" "默认存 raw_event_pointers，并保留可追溯能力。" "报表和导出默认不包含敏感原文；需要清楚文档化 privacy boundary。" "在 schema、store、export 中落实 raw pointer 规则。")" "Work Item" "Decision" "P0" "SQLite Store" "Generic" "Raw" "N/A" "Self" "Privacy" "v0.1" "Ready" "Known"
ensure_issue "[Work Item] Decision: Mark item/tool/MCP attribution as estimated unless source is exact" "level:work-item,type:decision,priority:p0,area:attribution,trust:estimated,source:self,risk:attribution,status:ready" "v0.4 Attribution Engine" "$(decision_body "tool/MCP/agent 级成本归因必须区分 exact / estimated / unknown；source 不支持时默认 estimated 或 unknown。" "Factrail 的价值是可信、可归因、可复用的数据层，不能伪造精确性。" "强行拆分为 exact；全部 unknown；按 source 能力区分 trust level。" "除非 source 明确提供 exact attribution，否则 item/tool/MCP 归因标记为 estimated 或 unknown。" "用户会看到 method/confidence/explanation；report/export 需要展示 trust level。" "完成 attribution limits research，并在 schema 中落实 trust level。")" "Work Item" "Decision" "P0" "Attribution" "Generic" "Derived" "Estimated" "Self" "Attribution" "v0.4" "Ready" "Known"
ensure_issue "[Work Item] Decision: v0.1 excludes GUI and full realtime" "level:work-item,type:decision,priority:p0,area:governance,source:self,status:ready" "v0.1 Local Codex Usage MVP" "$(decision_body "v0.1 明确排除 GUI 和完整 realtime。" "第一阶段目标是 scan -> normalize -> store -> report -> export，核心是数据基础层。" "提前做 GUI；提前做完整 realtime；先跑通本地 Codex Usage MVP。" "v0.1 只做 CLI/report/export 和本地数据层，realtime 放到 v0.3。" "v0.1 issue 和 PR 不应塞入 GUI 工作。" "在 Phase issue、docs 和 labels 中保持边界一致。")" "Work Item" "Decision" "P0" "Governance" "N/A" "N/A" "N/A" "Self" "None" "v0.1" "Ready" "Known"

fr_links="$(cat <<EOF
- $CORE_FR
- $SCAN_FR
- $USAGE_FR
- $PRICE_FR
- $CACHE_FR
- $STORE_FR
- $REPORT_FR
- $EXPORT_FR
- $NOTICE_FR
EOF
)"

edit_issue_body_if_created "[Phase] v0.1 Local Codex Usage MVP" "$(phase_body "跑通 scan -> normalize -> delta accounting -> price -> store -> report -> export，让 Factrail 成为本地 Codex usage 数据基础层的最小可用版本。" "Codex JSONL 扫描、核心归一化 schema、增量 usage accounting、pricing、本地 SQLite store、CLI report、JSON/CSV export、第三方许可归因。" "GUI；完整 realtime；Claude/OpenCode/OpenClaw adapter；tool/MCP/agent 精确归因；cloud sync。" "本地 Codex 会话可以被扫描、归一化、入库、计价、报表和导出；敏感原始内容默认只保留 pointer；fixture-based tests 覆盖关键路径。" "$fr_links" "隐私暴露、Codex JSONL schema drift、pricing source 变化、累积 token 转 delta 的边界。")"

cat <<EOF
Issue seed complete.
Created issues: $CREATED_COUNT
Reused issues: $REUSED_COUNT
Project number: ${PROJECT_NUMBER:-not found}
EOF
