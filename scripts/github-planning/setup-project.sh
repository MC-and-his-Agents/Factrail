#!/usr/bin/env bash
set -euo pipefail

DRY_RUN="${DRY_RUN:-0}"
PROJECT_TITLE="${PROJECT_TITLE:-Factrail Product & Engineering}"

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

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required. Install GitHub CLI first." >&2
  exit 1
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[DRY_RUN] would create or reuse Project: $PROJECT_TITLE"
  echo "[DRY_RUN] would create Project fields and link project to $REPO"
  exit 0
fi

owner_id="$(gh repo view "$REPO" --json owner --jq '.owner.id')"
repo_id="$(gh repo view "$REPO" --json id --jq '.id')"

project_json="$(gh project list --owner "$OWNER" --format json --limit 200 \
  | jq -c --arg title "$PROJECT_TITLE" '.projects[] | select(.title == $title)' || true)"

if [[ -z "$project_json" ]]; then
  echo "create project: $PROJECT_TITLE"
  gh project create --owner "$OWNER" --title "$PROJECT_TITLE" --format json >/dev/null
  project_json="$(gh project list --owner "$OWNER" --format json --limit 200 \
    | jq -c --arg title "$PROJECT_TITLE" '.projects[] | select(.title == $title)')"
else
  echo "exists project: $PROJECT_TITLE"
fi

PROJECT_ID="$(jq -r '.id' <<<"$project_json")"
PROJECT_NUMBER="$(jq -r '.number' <<<"$project_json")"
PROJECT_URL="$(jq -r '.url' <<<"$project_json")"

echo "project url: $PROJECT_URL"

link_query='
mutation($projectId: ID!, $repositoryId: ID!) {
  linkProjectV2ToRepository(input: { projectId: $projectId, repositoryId: $repositoryId }) {
    repository { id }
  }
}'

if gh api graphql --input <(jq -n --arg query "$link_query" --arg projectId "$PROJECT_ID" --arg repositoryId "$repo_id" '{query:$query, variables:{projectId:$projectId, repositoryId:$repositoryId}}') >/dev/null 2>&1; then
  echo "linked project to repository: $REPO"
else
  echo "TODO manual: link Project to repository if GitHub reports it is not linked." >&2
fi

fields_query='
query($projectId: ID!) {
  node(id: $projectId) {
    ... on ProjectV2 {
      fields(first: 100) {
        nodes {
          ... on ProjectV2FieldCommon { id name dataType }
          ... on ProjectV2SingleSelectField {
            id name dataType
            options { id name color description }
          }
        }
      }
    }
  }
}'

fetch_fields() {
  gh api graphql --input <(jq -n --arg query "$fields_query" --arg projectId "$PROJECT_ID" '{query:$query, variables:{projectId:$projectId}}')
}

make_options() {
  jq -n --arg color "${2:-GRAY}" '$ARGS.positional | map({name: ., color: $color, description: ""})' --args ${1}
}

field_id_by_name() {
  local name="$1"
  jq -r --arg name "$name" '.data.node.fields.nodes[]? | select(.name == $name) | .id' <<<"$FIELDS_JSON" | head -n 1
}

field_options_by_name() {
  local name="$1"
  jq -c --arg name "$name" '.data.node.fields.nodes[]? | select(.name == $name) | (.options // [])' <<<"$FIELDS_JSON"
}

merge_options() {
  local name="$1"
  local desired="$2"
  local existing
  existing="$(field_options_by_name "$name")"
  jq -c -n --argjson desired "$desired" --argjson existing "${existing:-[]}" '
    ($desired | map(.name) | unique) as $wanted
    | [
        $desired[] as $option
        | ($existing[]? | select(.name == $option.name) | .id) as $id
        | if $id then $option + {id: $id} else $option end
      ]
      + [
        $existing[]?
        | select(.name as $name | $wanted | index($name) | not)
        | {id, name, color, description}
      ]'
}

create_or_update_single_select() {
  local name="$1"
  local color="$2"
  shift 2
  local values=("$@")
  local args=()
  local desired merged field_id

  for value in "${values[@]}"; do
    args+=("$value")
  done

  desired="$(jq -n --arg color "$color" '$ARGS.positional | map({name: ., color: $color, description: ""})' --args "${args[@]}")"
  field_id="$(field_id_by_name "$name")"

  if [[ -z "$field_id" ]]; then
    echo "create field: $name"
    create_query='
mutation($projectId: ID!, $name: String!, $options: [ProjectV2SingleSelectFieldOptionInput!]) {
  createProjectV2Field(input: { projectId: $projectId, name: $name, dataType: SINGLE_SELECT, singleSelectOptions: $options }) {
    projectV2Field { ... on ProjectV2FieldCommon { id name } }
  }
}'
    gh api graphql --input <(jq -n --arg query "$create_query" --arg projectId "$PROJECT_ID" --arg name "$name" --argjson options "$desired" '{query:$query, variables:{projectId:$projectId, name:$name, options:$options}}') >/dev/null
  else
    echo "update/reuse field: $name"
    merged="$(merge_options "$name" "$desired")"
    update_query='
mutation($fieldId: ID!, $options: [ProjectV2SingleSelectFieldOptionInput!]) {
  updateProjectV2Field(input: { fieldId: $fieldId, singleSelectOptions: $options }) {
    projectV2Field { ... on ProjectV2FieldCommon { id name } }
  }
}'
    gh api graphql --input <(jq -n --arg query "$update_query" --arg fieldId "$field_id" --argjson options "$merged" '{query:$query, variables:{fieldId:$fieldId, options:$options}}') >/dev/null
  fi

  FIELDS_JSON="$(fetch_fields)"
}

create_number_field() {
  local name="$1"
  local field_id
  field_id="$(field_id_by_name "$name")"
  if [[ -n "$field_id" ]]; then
    echo "exists field: $name"
    return
  fi
  echo "create field: $name"
  create_query='
mutation($projectId: ID!, $name: String!) {
  createProjectV2Field(input: { projectId: $projectId, name: $name, dataType: NUMBER }) {
    projectV2Field { ... on ProjectV2FieldCommon { id name } }
  }
}'
  gh api graphql --input <(jq -n --arg query "$create_query" --arg projectId "$PROJECT_ID" --arg name "$name" '{query:$query, variables:{projectId:$projectId, name:$name}}') >/dev/null
  FIELDS_JSON="$(fetch_fields)"
}

create_iteration_field() {
  local name="$1"
  local field_id
  field_id="$(field_id_by_name "$name")"
  if [[ -n "$field_id" ]]; then
    echo "exists field: $name"
    return
  fi
  echo "create field: $name"
  create_query='
mutation($projectId: ID!, $name: String!) {
  createProjectV2Field(input: {
    projectId: $projectId,
    name: $name,
    dataType: ITERATION,
    iterationConfiguration: {
      startDate: "2026-05-25",
      duration: 14,
      iterations: [{ title: "Iteration 1", startDate: "2026-05-25", duration: 14 }]
    }
  }) {
    projectV2Field { ... on ProjectV2FieldCommon { id name } }
  }
}'
  if gh api graphql --input <(jq -n --arg query "$create_query" --arg projectId "$PROJECT_ID" --arg name "$name" '{query:$query, variables:{projectId:$projectId, name:$name}}') >/dev/null; then
    FIELDS_JSON="$(fetch_fields)"
  else
    echo "TODO manual: create Iteration field '$name' in Project UI." >&2
  fi
}

FIELDS_JSON="$(fetch_fields)"

create_or_update_single_select "Status" "GRAY" "Inbox" "Ready" "In Progress" "In Review" "Blocked" "Done" "Dropped"
create_or_update_single_select "Priority" "RED" "P0" "P1" "P2" "P3"
create_or_update_single_select "Level" "PURPLE" "Phase" "FR" "Work Item"
create_or_update_single_select "Work Type" "BLUE" "Product" "Engineering" "Research" "Decision" "Design" "Maintenance" "Docs" "Test"
create_or_update_single_select "Area" "GREEN" "Core Schema" "Codex JSONL" "Scanner Cache" "Usage Accounting" "Pricing" "SQLite Store" "Reports" "App Server" "Attribution" "Export" "Docs" "CI" "Governance"
create_or_update_single_select "Provider" "BLUE" "Codex" "Claude" "OpenCode" "OpenClaw" "Generic" "N/A"
create_or_update_single_select "Data Layer" "GREEN" "Raw" "Normalized" "Derived" "Export" "N/A"
create_or_update_single_select "Trust Level" "YELLOW" "Exact" "Estimated" "Unknown" "N/A"
create_or_update_single_select "Source" "PURPLE" "Self" "ccusage" "CodexBar" "CodexMonitor" "openai-codex" "Mixed" "N/A"
create_or_update_single_select "Risk" "ORANGE" "Schema Drift" "Privacy" "Performance" "Pricing" "Attribution" "License" "None"
create_or_update_single_select "Target Version" "PINK" "v0.1" "v0.2" "v0.3" "v0.4" "v0.5" "Later"
create_or_update_single_select "Confidence" "YELLOW" "Known" "Needs Research" "Risky"
create_number_field "Estimate"
create_iteration_field "Iteration"

cat <<EOF
Project setup complete.
Project URL: $PROJECT_URL
Project number: $PROJECT_NUMBER

TODO manual: create Project views in GitHub UI:
- Roadmap
- Current Iteration
- Backlog
- FR Board
- Research Queue
- Architecture Decisions
- Risk Board
- Release Readiness
EOF
