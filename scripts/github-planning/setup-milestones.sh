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

json_escape() {
  jq -Rn --arg value "$1" '$value'
}

run_api() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[DRY_RUN] gh api %s\n' "$*"
  else
    gh api "$@"
  fi
}

REPO="${REPO:-$(repo_from_git)}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required. Install GitHub CLI first." >&2
  exit 1
fi

milestones=(
  "v0.1 Local Codex Usage MVP|完成 scan -> normalize -> delta accounting -> price -> store -> report -> export；明确不做 GUI、完整 realtime、Claude/OpenCode/OpenClaw adapter、tool/MCP/agent 精确归因和 cloud sync。"
  "v0.2 Project-level Analytics|完成 project/workspace detection、git root mapping、cwd/session association、project-level reports、privacy-safe raw event pointers。"
  "v0.3 Realtime App-server Collector|完成 generated app-server schema integration、stdio JSON-RPC client、thread/turn/item reducer、tokenUsage event capture、item lifecycle timeline。"
  "v0.4 Attribution Engine|完成 turn-level exact attribution、item/tool/MCP-level estimated attribution、unknown bucket、confidence/method/explanation model。"
  "v0.5 Multi-provider Foundation|完成 provider adapter interface、Claude Code local adapter research or MVP、OpenCode/OpenClaw adapter research、provider capability matrix、cross-provider normalized reports。"
)

existing="$(gh api "repos/$REPO/milestones?state=all&per_page=100" --jq '.[].title')"

for spec in "${milestones[@]}"; do
  IFS='|' read -r title description <<<"$spec"
  if grep -Fxq "$title" <<<"$existing"; then
    echo "exists milestone: $title"
  else
    echo "create milestone: $title"
    run_api -X POST "repos/$REPO/milestones" \
      -H "Content-Type: application/json" \
      --input <(jq -n --arg title "$title" --arg description "$description" '{title:$title, description:$description}')
  fi
done
