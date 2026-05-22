#!/usr/bin/env bash
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"

repo_from_git() {
  local url owner_repo
  url="$(git remote get-url origin)"
  owner_repo="${url#git@github.com:}"
  owner_repo="${owner_repo#https://github.com/}"
  owner_repo="${owner_repo%.git}"
  printf '%s\n' "$owner_repo"
}

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY_RUN] %q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

REPO="${REPO:-$(repo_from_git)}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required. Install GitHub CLI first." >&2
  exit 1
fi

color_for_group() {
  case "$1" in
    level) printf '5319e7' ;;
    type) printf '1d76db' ;;
    priority) printf 'd93f0b' ;;
    area) printf '0e8a16' ;;
    provider) printf '006b75' ;;
    source) printf '7057ff' ;;
    risk) printf 'b60205' ;;
    trust) printf 'fbca04' ;;
    status) printf 'c2e0c6' ;;
    *) printf 'ededed' ;;
  esac
}

labels=(
  "level:phase|level|Phase issue"
  "level:fr|level|Feature Requirement issue"
  "level:work-item|level|Executable work item"
  "type:feature|type|Feature requirement"
  "type:task|type|Task"
  "type:bug|type|Bug"
  "type:research|type|Research"
  "type:decision|type|Decision record"
  "type:chore|type|Chore"
  "type:docs|type|Documentation"
  "type:test|type|Test work"
  "priority:p0|priority|Priority P0"
  "priority:p1|priority|Priority P1"
  "priority:p2|priority|Priority P2"
  "priority:p3|priority|Priority P3"
  "area:core-schema|area|Core schema"
  "area:codex-jsonl|area|Codex JSONL"
  "area:scanner-cache|area|Scanner cache"
  "area:usage-accounting|area|Usage accounting"
  "area:pricing|area|Pricing"
  "area:sqlite-store|area|SQLite store"
  "area:reports|area|Reports"
  "area:app-server|area|App server"
  "area:attribution|area|Attribution"
  "area:export|area|Export"
  "area:docs|area|Docs"
  "area:ci|area|CI"
  "area:governance|area|Governance"
  "provider:codex|provider|Codex provider"
  "provider:claude|provider|Claude provider"
  "provider:opencode|provider|OpenCode provider"
  "provider:openclaw|provider|OpenClaw provider"
  "provider:generic|provider|Generic provider"
  "source:ccusage|source|ccusage reference"
  "source:codexbar|source|CodexBar reference"
  "source:codexmonitor|source|CodexMonitor reference"
  "source:openai-codex|source|openai/codex fact source"
  "source:self|source|Self-authored implementation"
  "source:mixed|source|Mixed sources"
  "risk:schema-drift|risk|Schema drift risk"
  "risk:privacy|risk|Privacy risk"
  "risk:performance|risk|Performance risk"
  "risk:pricing|risk|Pricing risk"
  "risk:attribution|risk|Attribution risk"
  "risk:license|risk|License risk"
  "trust:exact|trust|Exact accounting"
  "trust:estimated|trust|Estimated accounting"
  "trust:unknown|trust|Unknown accounting"
  "status:blocked|status|Blocked"
  "status:needs-research|status|Needs research"
  "status:ready|status|Ready"
)

existing="$(gh label list --repo "$REPO" --limit 500 --json name --jq '.[].name')"

for spec in "${labels[@]}"; do
  IFS='|' read -r name group description <<<"$spec"
  if grep -Fxq "$name" <<<"$existing"; then
    echo "exists label: $name"
  else
    echo "create label: $name"
    run gh label create "$name" --repo "$REPO" --color "$(color_for_group "$group")" --description "$description"
  fi
done
