#!/usr/bin/env bash
# Read-only Firstmate supervision model.
# Sourceable library used by bin/fm-supervise.sh and future displays.

fm_supervision_usage() {
  cat <<'USAGE'
Usage: fm-supervise.sh [--text|--json|--schema] [--include-ok] [--no-default-reminders] [--external-pr <url>] [--help]

Modes:
  --text                  print captain-facing checklist (default)
  --json                  print firstmate.supervision.v1 JSON
  --schema                print the v1 JSON schema and exit

Inputs:
  --external-pr <url>     include one extra GitHub PR reminder; repeatable
  --no-default-reminders  omit built-in default reminders such as Firstmate PR #68
  --include-ok            include low-priority OK/watch items in text output

Other:
  --help                  print usage
USAGE
}

fm_supervision_schema_json() {
  cat <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "firstmate.supervision.v1",
  "type": "object",
  "required": ["schema_version", "generated_at", "home", "read_only", "sources", "summary", "checklist", "tasks", "worktrees", "external_reminders"],
  "properties": {
    "schema_version": { "const": "firstmate.supervision.v1" },
    "generated_at": { "type": "string", "format": "date-time" },
    "home": { "type": "string" },
    "read_only": { "const": true },
    "sources": {
      "type": "object",
      "additionalProperties": {
        "type": "object",
        "required": ["ok", "detail"],
        "properties": {
          "ok": { "type": "boolean" },
          "detail": { "type": "string" }
        },
        "additionalProperties": false
      }
    },
    "summary": {
      "type": "object",
      "required": ["level", "tasks_total", "actions_total", "high_total", "medium_total", "github_state"],
      "properties": {
        "level": { "enum": ["ok", "watch", "action"] },
        "tasks_total": { "type": "integer", "minimum": 0 },
        "actions_total": { "type": "integer", "minimum": 0 },
        "high_total": { "type": "integer", "minimum": 0 },
        "medium_total": { "type": "integer", "minimum": 0 },
        "github_state": { "enum": ["ok", "partial", "unavailable", "skipped"] }
      },
      "additionalProperties": false
    },
    "checklist": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "severity", "owner", "action", "why", "task_id", "project", "pr_url", "evidence", "read_only_commands"],
        "properties": {
          "id": { "type": "string" },
          "severity": { "enum": ["high", "medium", "info"] },
          "owner": { "enum": ["captain", "firstmate", "worker", "external"] },
          "action": { "type": "string" },
          "why": { "type": "string" },
          "task_id": { "type": "string" },
          "project": { "type": "string" },
          "pr_url": { "type": "string" },
          "evidence": { "type": "array", "items": { "type": "string" } },
          "read_only_commands": { "type": "array", "items": { "type": "string" } }
        },
        "additionalProperties": false
      }
    },
    "tasks": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["id", "project", "kind", "mode", "yolo", "window", "window_live", "worktree", "branch", "dirty_count", "last_status", "turn_ended", "pr", "classification", "next", "evidence"],
        "properties": {
          "id": { "type": "string" },
          "project": { "type": "string" },
          "kind": { "enum": ["ship", "scout", "secondmate"] },
          "mode": { "type": "string" },
          "yolo": { "enum": ["on", "off"] },
          "window": { "type": "string" },
          "window_live": { "type": "boolean" },
          "worktree": { "type": "string" },
          "branch": { "type": "string" },
          "dirty_count": { "type": "integer", "minimum": 0 },
          "last_status": { "type": "string" },
          "turn_ended": { "type": "boolean" },
          "pr": {
            "type": "object",
            "required": ["url", "state", "ci_state", "mergeable_state"],
            "properties": {
              "url": { "type": "string" },
              "state": { "type": "string" },
              "ci_state": { "type": "string" },
              "mergeable_state": { "type": "string" }
            },
            "additionalProperties": false
          },
          "classification": { "type": "string" },
          "next": {
            "type": "object",
            "required": ["owner", "action"],
            "properties": {
              "owner": { "enum": ["captain", "firstmate", "worker", "external"] },
              "action": { "type": "string" }
            },
            "additionalProperties": false
          },
          "evidence": { "type": "array", "items": { "type": "string" } }
        },
        "additionalProperties": false
      }
    },
    "worktrees": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["path", "project", "branch", "dirty_count", "has_active_task", "classification", "next", "evidence"],
        "properties": {
          "path": { "type": "string" },
          "project": { "type": "string" },
          "branch": { "type": "string" },
          "dirty_count": { "type": "integer", "minimum": 0 },
          "has_active_task": { "type": "boolean" },
          "classification": { "type": "string" },
          "next": {
            "type": "object",
            "required": ["owner", "action"],
            "properties": {
              "owner": { "enum": ["captain", "firstmate", "worker", "external"] },
              "action": { "type": "string" }
            },
            "additionalProperties": false
          },
          "evidence": { "type": "array", "items": { "type": "string" } }
        },
        "additionalProperties": false
      }
    },
    "external_reminders": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["url", "state", "ci_state", "mergeable_state", "classification", "next", "evidence"],
        "properties": {
          "url": { "type": "string" },
          "state": { "type": "string" },
          "ci_state": { "type": "string" },
          "mergeable_state": { "type": "string" },
          "classification": { "type": "string" },
          "next": {
            "type": "object",
            "required": ["owner", "action"],
            "properties": {
              "owner": { "enum": ["captain", "firstmate", "worker", "external"] },
              "action": { "type": "string" }
            },
            "additionalProperties": false
          },
          "evidence": { "type": "array", "items": { "type": "string" } }
        },
        "additionalProperties": false
      }
    }
  },
  "additionalProperties": false
}
JSON
}

fm_supervision_paths() {
  local script_dir root
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="${FM_ROOT_OVERRIDE:-$(cd "$script_dir/.." && pwd)}"
  FM_SUPERVISION_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$root}}"
  FM_SUPERVISION_STATE="${FM_STATE_OVERRIDE:-$FM_SUPERVISION_HOME/state}"
  FM_SUPERVISION_DATA="${FM_DATA_OVERRIDE:-$FM_SUPERVISION_HOME/data}"
  FM_SUPERVISION_PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_SUPERVISION_HOME/projects}"
}

fm_supervision_field() {
  local value=${1:-}
  value=${value//$'\t'/ }
  value=${value//$'\r'/ }
  value=${value//$'\n'/ }
  [ -n "$value" ] || value=none
  printf '%s' "$value"
}

fm_supervision_line_append() {
  local __var=$1 line=$2 current
  current=${!__var-}
  if [ -n "$current" ]; then
    printf -v "$__var" '%s\n%s' "$current" "$line"
  else
    printf -v "$__var" '%s' "$line"
  fi
}

fm_supervision_meta_value() {
  local meta_file=$1 key=$2
  [ -f "$meta_file" ] || return 0
  awk -F= -v key="$key" '$1 == key { value = substr($0, length(key) + 2) } END { print value }' "$meta_file" 2>/dev/null
}

fm_supervision_last_status() {
  local status_file=$1
  [ -f "$status_file" ] || return 0
  awk 'NF { line = $0 } END { print line }' "$status_file" 2>/dev/null
}

fm_supervision_status_pr_url() {
  local text=$1
  printf '%s\n' "$text" | grep -Eo 'https://github.com/[^[:space:])"]+/[^[:space:])"]+/pull/[0-9]+' | tail -1
}

fm_supervision_json_escape() {
  local value=${1:-}
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\b'/\\b}
  value=${value//$'\f'/\\f}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

fm_supervision_bool() {
  case ${1:-} in
    true|1|yes) printf 'true' ;;
    *) printf 'false' ;;
  esac
}

fm_supervision_window_live() {
  local target=$1
  [ -n "$target" ] || return 1
  command -v tmux >/dev/null 2>&1 || return 1
  tmux display-message -p -t "$target" "#{window_name}" >/dev/null 2>&1
}

fm_supervision_worktree_dirty_count() {
  local path=$1
  [ -d "$path" ] || {
    printf '0'
    return 1
  }
  git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    printf '0'
    return 1
  }
  git -C "$path" status --porcelain --untracked-files=all 2>/dev/null | wc -l | tr -d ' '
}

fm_supervision_branch() {
  local path=$1 branch
  [ -d "$path" ] || return 1
  branch=$(git -C "$path" branch --show-current 2>/dev/null) || branch=
  if [ -n "$branch" ]; then
    printf '%s' "$branch"
  elif git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'detached'
  else
    return 1
  fi
}

fm_supervision_worktree_list() {
  local project=$1
  [ -d "$project/.git" ] || [ -f "$project/.git" ] || return 1
  git -C "$project" worktree list --porcelain 2>/dev/null | awk '/^worktree / { sub(/^worktree /, ""); print }'
}

fm_supervision_treehouse_status() {
  local project=$1 timeout_cmd=
  [ -d "$project" ] || return 1
  command -v treehouse >/dev/null 2>&1 || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  fi
  if [ -n "$timeout_cmd" ]; then
    (cd "$project" && "$timeout_cmd" "${FM_SUPERVISE_TREEHOUSE_TIMEOUT:-5}" treehouse status >/dev/null 2>&1)
  else
    (cd "$project" && treehouse status >/dev/null 2>&1)
  fi
}

fm_supervision_pr_from_url() {
  local url=$1
  printf '%s\n' "$url" | sed -n 's#^https://github.com/\([^/][^/]*\)/\([^/][^/]*\)/pull/\([0-9][0-9]*\).*#\1/\2 \3#p'
}

fm_supervision_yaml_value() {
  local key=$1
  awk -F': ' -v key="$key" '$1 == key { gsub(/^"|"$/, "", $2); print $2; exit }'
}

fm_supervision_yaml_nested_head_sha() {
  awk '
    /^head:/ { in_head = 1; next }
    /^[^[:space:]]/ && in_head { in_head = 0 }
    in_head && /^[[:space:]]+sha:/ { sub(/^[[:space:]]+sha:[[:space:]]*/, ""); print; exit }
  '
}

fm_supervision_gh_api_get() {
  local path=$1 timeout_cmd=
  command -v gh-axi >/dev/null 2>&1 || return 127
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd=gtimeout
  fi
  if [ -n "$timeout_cmd" ]; then
    "$timeout_cmd" "${FM_SUPERVISE_GH_TIMEOUT:-5}" gh-axi api GET "$path" 2>/dev/null
  else
    gh-axi api GET "$path" 2>/dev/null
  fi
}

fm_supervision_gh_pr() {
  local url=$1 parsed repo number out state merged mergeable_state sha status_out ci_state total_count
  parsed=$(fm_supervision_pr_from_url "$url") || return 1
  [ -n "$parsed" ] || return 1
  repo=${parsed% *}
  number=${parsed##* }
  out=$(fm_supervision_gh_api_get "/repos/$repo/pulls/$number") || return 1
  state=$(printf '%s\n' "$out" | fm_supervision_yaml_value state)
  merged=$(printf '%s\n' "$out" | fm_supervision_yaml_value merged)
  mergeable_state=$(printf '%s\n' "$out" | fm_supervision_yaml_value mergeable_state)
  sha=$(printf '%s\n' "$out" | fm_supervision_yaml_nested_head_sha)
  [ -n "$state" ] || return 1
  if [ "$merged" = "true" ]; then
    state=merged
  fi
  ci_state=unknown
  total_count=
  if [ -n "$sha" ]; then
    status_out=$(fm_supervision_gh_api_get "/repos/$repo/commits/$sha/status") || status_out=
    if [ -n "$status_out" ]; then
      ci_state=$(printf '%s\n' "$status_out" | fm_supervision_yaml_value state)
      total_count=$(printf '%s\n' "$status_out" | fm_supervision_yaml_value total_count)
      [ -n "$ci_state" ] || ci_state=unknown
      if [ "$total_count" = "0" ]; then
        ci_state=none
      fi
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$state" "$ci_state" "${mergeable_state:-unknown}" "$repo" "$sha" "${total_count:-unknown}"
}

fm_supervision_classify_task() {
  local id=$1 kind=$2 mode=$3 yolo=$4 window_live=$5 worktree=$6 last_status=$7 pr_url=$8 pr_state=$9 ci_state=${10}
  local classification=running severity=info owner=worker action="Monitor worker progress." why="Worker has no captain-facing status yet."
  if [ -n "$worktree" ] && [ ! -e "$worktree" ]; then
    classification=stale_treehouse_state
    severity=high
    owner=firstmate
    action="Reconcile treehouse state before sending or closing the worker."
    why="Recorded worktree path is missing."
  elif [ "$window_live" = false ] && [ "$kind" = secondmate ]; then
    classification=missing_window_existing_meta
    severity=high
    owner=firstmate
    action="Respawn or retire the secondmate only after checking its home."
    why="Task meta exists but the recorded tmux window is missing."
  elif [ "$window_live" = false ] && [ -n "$id" ]; then
    classification=missing_window_existing_meta
    severity=high
    owner=firstmate
    action="Reconcile task from meta, status, treehouse, and git before taking next action."
    why="Task meta exists but the recorded tmux window is missing."
  elif [ "$pr_state" = merged ] && [ "$window_live" = true ]; then
    classification=merged_pr_live_worker
    severity=high
    owner=firstmate
    action="Close the worker after confirming the PR is merged."
    why="The PR is merged and the worker window is still live."
  elif [ "$pr_state" = open ] && [ "$ci_state" = success ] && printf '%s\n' "$last_status" | grep -qiE 'done:|checks green|PR ready'; then
    classification=pr_open_ci_green
    severity=high
    if [ "$yolo" = on ]; then owner=firstmate; else owner=captain; fi
    action="Review and merge when approved."
    why="The PR is open, CI is green, and the worker reported done."
  elif [ "$pr_state" = open ] && [ "$mode" = direct-PR ] && [ "$ci_state" = none ] && printf '%s\n' "$last_status" | grep -qiE 'done:|PR ready'; then
    classification=direct_pr_open_no_ci_ready
    severity=high
    if [ "$yolo" = on ]; then owner=firstmate; else owner=captain; fi
    action="Review and merge when approved."
    why="The direct-PR task skips validation, the PR is open, and the worker reported done."
  elif [ "$pr_state" = open ] && printf '%s\n' "$ci_state" | grep -Eq '^(failure|error)$'; then
    classification=pr_open_ci_failing
    severity=high
    owner=worker
    action="Ask worker to fix failing CI."
    why="The PR is open and CI is failing."
  elif printf '%s\n' "$last_status" | grep -q '^done:' && [ -z "$pr_url" ] && [ "$mode" = local-only ] && printf '%s\n' "$last_status" | grep -qi 'ready in branch'; then
    classification=local_only_ready_for_review
    severity=medium
    owner=firstmate
    action="Review the local branch diff."
    why="The local-only worker reported a ready branch."
  elif printf '%s\n' "$last_status" | grep -q '^done:' && [ -z "$pr_url" ] && { [ "$mode" = no-mistakes ] || [ "$mode" = direct-PR ]; }; then
    classification=worker_done_no_pr
    severity=medium
    owner=firstmate
    if [ "$mode" = no-mistakes ]; then
      action="Start validation or ask worker for PR evidence."
    else
      action="Ask worker for the PR URL or confirm local-only mode."
    fi
    why="The worker reported done but no PR URL is recorded."
  elif printf '%s\n' "$last_status" | grep -q '^blocked:'; then
    classification=worker_blocked
    severity=high
    owner=captain
    action="Resolve the worker blocker."
    why="$last_status"
  elif printf '%s\n' "$last_status" | grep -q '^needs-decision:'; then
    classification=worker_needs_decision
    severity=high
    owner=captain
    action="Make the requested decision."
    why="$last_status"
  elif printf '%s\n' "$last_status" | grep -q '^failed:'; then
    classification=worker_failed
    severity=high
    owner=firstmate
    action="Inspect the worker failure and decide the next step."
    why="$last_status"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$classification" "$severity" "$owner" "$action" "$why"
}

fm_supervision_external_classification() {
  local url=$1 state=$2 ci_state=$3
  local classification severity owner action why
  if [ "$state" = open ] && [ "$ci_state" = none ]; then
    classification=external_open_ci_none
    severity=medium
    owner=captain
    action="Review when ready; do not treat as CI-green."
    why="The PR is open and no CI statuses are configured."
  elif [ "$state" = open ] && [ "$ci_state" = success ]; then
    classification=external_open_ci_green
    severity=medium
    owner=captain
    action="Review when ready."
    why="The PR is open and CI is green."
  elif [ "$state" = unknown ]; then
    classification=external_pr_unknown
    severity=medium
    owner=firstmate
    action="Use local state only; GitHub state is unknown."
    why="GitHub could not be read for $url."
  else
    classification=external_pr_watch
    severity=info
    owner=external
    action="No immediate action."
    why="External PR state is $state."
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$classification" "$severity" "$owner" "$action" "$why"
}

fm_supervision_checklist_record() {
  local id=$1 severity=$2 owner=$3 action=$4 why=$5 task_id=$6 project=$7 pr_url=$8 evidence=$9
  printf 'checklist\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(fm_supervision_field "$id")" "$(fm_supervision_field "$severity")" "$(fm_supervision_field "$owner")" \
    "$(fm_supervision_field "$action")" "$(fm_supervision_field "$why")" "$(fm_supervision_field "$task_id")" \
    "$(fm_supervision_field "$project")" "$(fm_supervision_field "$pr_url")" "$(fm_supervision_field "$evidence")"
}

fm_supervision_collect() {
  fm_supervision_paths
  local records= source_records= checklist_records= task_records= worktree_records= external_records=
  local state_ok=true backlog_ok=true tmux_ok=true treehouse_ok=true git_ok=true github_ok=true github_detail="gh-axi api GET only"
  local task_count=0 checklist_count=0 high_count=0 medium_count=0 github_state=ok
  local referenced_worktrees="|"
  local meta id project kind mode yolo window worktree branch dirty_count last_status turn_ended pr_url pr_data pr_state ci_state mergeable_state
  local class_data classification severity owner action why evidence line status_pr window_live treehouse_failed=false

  [ -d "$FM_SUPERVISION_STATE" ] || state_ok=false
  [ -f "$FM_SUPERVISION_DATA/backlog.md" ] || backlog_ok=false
  command -v tmux >/dev/null 2>&1 || tmux_ok=false
  command -v treehouse >/dev/null 2>&1 || treehouse_ok=false
  command -v git >/dev/null 2>&1 || git_ok=false
  if ! command -v gh-axi >/dev/null 2>&1; then
    github_ok=false
    github_detail="gh-axi missing; PR states unknown"
    github_state=unavailable
  fi

  if [ -d "$FM_SUPERVISION_STATE" ]; then
    for meta in "$FM_SUPERVISION_STATE"/*.meta; do
      [ -e "$meta" ] || continue
      treehouse_failed=false
      id=$(basename "$meta" .meta)
      project=$(fm_supervision_meta_value "$meta" project)
      kind=$(fm_supervision_meta_value "$meta" kind); [ -n "$kind" ] || kind=ship
      mode=$(fm_supervision_meta_value "$meta" mode); [ -n "$mode" ] || mode=no-mistakes
      yolo=$(fm_supervision_meta_value "$meta" yolo); [ -n "$yolo" ] || yolo=off
      window=$(fm_supervision_meta_value "$meta" window)
      worktree=$(fm_supervision_meta_value "$meta" worktree)
      [ -n "$worktree" ] && referenced_worktrees="$referenced_worktrees$worktree|"
      last_status=$(fm_supervision_last_status "$FM_SUPERVISION_STATE/$id.status")
      turn_ended=false
      [ -e "$FM_SUPERVISION_STATE/$id.turn-ended" ] && turn_ended=true
      pr_url=$(fm_supervision_meta_value "$meta" pr)
      status_pr=$(fm_supervision_status_pr_url "$last_status")
      [ -n "$pr_url" ] || pr_url=$status_pr
      if fm_supervision_window_live "$window"; then window_live=true; else window_live=false; fi
      branch=$(fm_supervision_branch "$worktree" 2>/dev/null) || branch=unknown
      dirty_count=$(fm_supervision_worktree_dirty_count "$worktree" 2>/dev/null) || dirty_count=0
      pr_state=none
      ci_state=none
      mergeable_state=unknown
      if [ -n "$pr_url" ]; then
        if pr_data=$(fm_supervision_gh_pr "$pr_url"); then
          pr_state=$(printf '%s' "$pr_data" | awk -F '\t' '{ print $1 }')
          ci_state=$(printf '%s' "$pr_data" | awk -F '\t' '{ print $2 }')
          mergeable_state=$(printf '%s' "$pr_data" | awk -F '\t' '{ print $3 }')
        else
          pr_state=unknown
          ci_state=unknown
          mergeable_state=unknown
          github_ok=false
          github_state=partial
          github_detail="one or more PR reads failed; affected PR states unknown"
        fi
      fi
      if [ -n "$project" ] && [ -d "$FM_SUPERVISION_PROJECTS/$project" ]; then
        if ! fm_supervision_treehouse_status "$FM_SUPERVISION_PROJECTS/$project"; then
          treehouse_failed=true
          treehouse_ok=false
        fi
      fi
      class_data=$(fm_supervision_classify_task "$id" "$kind" "$mode" "$yolo" "$window_live" "$worktree" "$last_status" "$pr_url" "$pr_state" "$ci_state")
      classification=$(printf '%s' "$class_data" | awk -F '\t' '{ print $1 }')
      severity=$(printf '%s' "$class_data" | awk -F '\t' '{ print $2 }')
      owner=$(printf '%s' "$class_data" | awk -F '\t' '{ print $3 }')
      action=$(printf '%s' "$class_data" | awk -F '\t' '{ print $4 }')
      why=$(printf '%s' "$class_data" | awk -F '\t' '{ print $5 }')
      if [ "$treehouse_failed" = true ] && [ "$classification" = running ]; then
        classification=stale_treehouse_state
        severity=high
        owner=firstmate
        action="Reconcile treehouse state before sending or closing the worker."
        why="treehouse status failed for the project."
      fi
      evidence="meta=$(basename "$meta"); status=${last_status:-none}; window_live=$window_live; pr_state=$pr_state; ci_state=$ci_state; mergeable_state=$mergeable_state"
      line=$(printf 'task\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$(fm_supervision_field "$id")" "$(fm_supervision_field "$project")" "$(fm_supervision_field "$kind")" \
        "$(fm_supervision_field "$mode")" "$(fm_supervision_field "$yolo")" "$(fm_supervision_field "$window")" \
        "$window_live" "$(fm_supervision_field "$worktree")" "$(fm_supervision_field "$branch")" "$dirty_count" \
        "$(fm_supervision_field "$last_status")" "$turn_ended" "$(fm_supervision_field "$pr_url")" \
        "$pr_state" "$ci_state" "$mergeable_state" "$classification" "$severity" "$owner" "$(fm_supervision_field "$action")" \
        "$(fm_supervision_field "$evidence")")
      fm_supervision_line_append task_records "$line"
      task_count=$((task_count + 1))
      if [ "$severity" != info ]; then
        line=$(fm_supervision_checklist_record "$id:$classification" "$severity" "$owner" "$action" "$why" "$id" "$project" "$pr_url" "$evidence")
        fm_supervision_line_append checklist_records "$line"
        checklist_count=$((checklist_count + 1))
        [ "$severity" = high ] && high_count=$((high_count + 1))
        [ "$severity" = medium ] && medium_count=$((medium_count + 1))
      fi
    done
  fi

  if [ -d "$FM_SUPERVISION_PROJECTS" ]; then
    local project_dir wt has_meta wt_branch wt_dirty wt_class wt_severity wt_owner wt_action wt_evidence
    for project_dir in "$FM_SUPERVISION_PROJECTS"/*; do
      [ -d "$project_dir" ] || continue
      project=$(basename "$project_dir")
      while IFS= read -r wt; do
        [ -n "$wt" ] || continue
        has_meta=false
        case "$referenced_worktrees" in *"|$wt|"*) has_meta=true ;; esac
        wt_branch=$(fm_supervision_branch "$wt" 2>/dev/null) || wt_branch=unknown
        wt_dirty=$(fm_supervision_worktree_dirty_count "$wt" 2>/dev/null) || wt_dirty=0
        wt_class=clean_worktree
        wt_severity=info
        wt_owner=firstmate
        wt_action="No immediate action."
        if [ "$has_meta" = false ] && [ "$wt_dirty" -gt 0 ]; then
          wt_class=dirty_worktree_no_active_task
          wt_severity=medium
          wt_action="Reconcile this worktree before cleanup."
        fi
        wt_evidence="dirty_count=$wt_dirty; has_active_task=$has_meta"
        line=$(printf 'worktree\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
          "$(fm_supervision_field "$wt")" "$(fm_supervision_field "$project")" "$(fm_supervision_field "$wt_branch")" \
          "$wt_dirty" "$has_meta" "$wt_class" "$wt_severity" "$wt_owner" "$(fm_supervision_field "$wt_action")" \
          "$(fm_supervision_field "$wt_evidence")")
        fm_supervision_line_append worktree_records "$line"
        if [ "$wt_severity" != info ]; then
          line=$(fm_supervision_checklist_record "worktree:$project:$wt_class" "$wt_severity" "$wt_owner" "$wt_action" "A dirty worktree is not tied to active task meta." "" "$project" "" "$wt_evidence")
          fm_supervision_line_append checklist_records "$line"
          checklist_count=$((checklist_count + 1))
          medium_count=$((medium_count + 1))
        fi
      done <<EOF
$(fm_supervision_worktree_list "$project_dir" 2>/dev/null)
EOF
    done
  fi

  local reminders reminder parsed_ext ext_data ext_state ext_ci ext_merge ext_class_data ext_class ext_severity ext_owner ext_action ext_why ext_evidence
  reminders=
  if [ "${FM_SUPERVISE_DEFAULT_REMINDERS_ENABLED:-1}" = 1 ]; then
    reminders=${FM_SUPERVISE_DEFAULT_REMINDERS:-https://github.com/kunchenguid/firstmate/pull/68}
  fi
  reminders="${reminders:+$reminders }${FM_SUPERVISE_EXTERNAL_PRS:-}"
  # shellcheck disable=SC2086 # Reminder URLs are space-separated by design.
  for reminder in $reminders; do
    [ -n "$reminder" ] || continue
    ext_state=unknown
    ext_ci=unknown
    ext_merge=unknown
    ext_evidence="GitHub unavailable"
    if ext_data=$(fm_supervision_gh_pr "$reminder"); then
      ext_state=$(printf '%s' "$ext_data" | awk -F '\t' '{ print $1 }')
      ext_ci=$(printf '%s' "$ext_data" | awk -F '\t' '{ print $2 }')
      ext_merge=$(printf '%s' "$ext_data" | awk -F '\t' '{ print $3 }')
      parsed_ext=$(printf '%s' "$ext_data" | awk -F '\t' '{ print "repo=" $4 "; sha=" $5 "; status_total_count=" $6 }')
      ext_evidence=$parsed_ext
    else
      github_ok=false
      if [ "$github_state" = ok ]; then github_state=partial; fi
      github_detail="one or more PR reads failed; affected PR states unknown"
    fi
    ext_class_data=$(fm_supervision_external_classification "$reminder" "$ext_state" "$ext_ci")
    ext_class=$(printf '%s' "$ext_class_data" | awk -F '\t' '{ print $1 }')
    ext_severity=$(printf '%s' "$ext_class_data" | awk -F '\t' '{ print $2 }')
    ext_owner=$(printf '%s' "$ext_class_data" | awk -F '\t' '{ print $3 }')
    ext_action=$(printf '%s' "$ext_class_data" | awk -F '\t' '{ print $4 }')
    ext_why=$(printf '%s' "$ext_class_data" | awk -F '\t' '{ print $5 }')
    line=$(printf 'external\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
      "$(fm_supervision_field "$reminder")" "$ext_state" "$ext_ci" "$(fm_supervision_field "$ext_merge")" \
      "$ext_class" "$ext_severity" "$ext_owner" "$(fm_supervision_field "$ext_action")" "$(fm_supervision_field "$ext_evidence")")
    fm_supervision_line_append external_records "$line"
    if [ "$ext_severity" != info ]; then
      line=$(fm_supervision_checklist_record "external:$reminder" "$ext_severity" "$ext_owner" "$ext_action" "$ext_why" "" "" "$reminder" "$ext_evidence")
      fm_supervision_line_append checklist_records "$line"
      checklist_count=$((checklist_count + 1))
      [ "$ext_severity" = high ] && high_count=$((high_count + 1))
      [ "$ext_severity" = medium ] && medium_count=$((medium_count + 1))
    fi
  done

  if [ "$github_ok" = false ] && [ "$github_state" = ok ]; then github_state=unavailable; fi
  local level=ok
  if [ "$high_count" -gt 0 ]; then level=action
  elif [ "$medium_count" -gt 0 ]; then level=watch
  fi
  source_records=$(printf 'source\tstate\t%s\t%s\nsource\tbacklog\t%s\t%s\nsource\ttmux\t%s\t%s\nsource\ttreehouse\t%s\t%s\nsource\tgit\t%s\t%s\nsource\tgithub\t%s\t%s' \
    "$state_ok" "state/meta/status read only" \
    "$backlog_ok" "data/backlog.md read only" \
    "$tmux_ok" "tmux display-message only" \
    "$treehouse_ok" "treehouse status only" \
    "$git_ok" "git branch/status/worktree reads only" \
    "$github_ok" "$github_detail")
  records=$source_records
  [ -n "$task_records" ] && records="$records"$'\n'"$task_records"
  [ -n "$worktree_records" ] && records="$records"$'\n'"$worktree_records"
  [ -n "$external_records" ] && records="$records"$'\n'"$external_records"
  [ -n "$checklist_records" ] && records="$records"$'\n'"$checklist_records"
  records="$records"$'\n'"summary	$level	$task_count	$checklist_count	$high_count	$medium_count	$github_state"
  printf '%s\n' "$records"
}

fm_supervision_emit_json() {
  fm_supervision_paths
  local generated_at
  generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local source_lines= task_lines= worktree_lines= external_lines= checklist_lines= summary_line=
  local line kind
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind=${line%%$'\t'*}
    case "$kind" in
      source) fm_supervision_line_append source_lines "$line" ;;
      task) fm_supervision_line_append task_lines "$line" ;;
      worktree) fm_supervision_line_append worktree_lines "$line" ;;
      external) fm_supervision_line_append external_lines "$line" ;;
      checklist) fm_supervision_line_append checklist_lines "$line" ;;
      summary) summary_line=$line ;;
    esac
  done

  local s_level=ok s_tasks=0 s_actions=0 s_high=0 s_medium=0 s_github=skipped
  if [ -n "$summary_line" ]; then
    IFS=$'\t' read -r _ s_level s_tasks s_actions s_high s_medium s_github <<EOF
$summary_line
EOF
  fi

  printf '{\n'
  printf '  "schema_version": "firstmate.supervision.v1",\n'
  printf '  "generated_at": "%s",\n' "$(fm_supervision_json_escape "$generated_at")"
  printf '  "home": "%s",\n' "$(fm_supervision_json_escape "$FM_SUPERVISION_HOME")"
  printf '  "read_only": true,\n'
  printf '  "sources": {\n'
  local first=true name ok detail
  while IFS=$'\t' read -r _ name ok detail; do
    [ -n "$name" ] || continue
    if [ "$first" = true ]; then first=false; else printf ',\n'; fi
    printf '    "%s": { "ok": %s, "detail": "%s" }' "$(fm_supervision_json_escape "$name")" "$(fm_supervision_bool "$ok")" "$(fm_supervision_json_escape "$detail")"
  done <<EOF
$source_lines
EOF
  printf '\n  },\n'
  printf '  "summary": { "level": "%s", "tasks_total": %s, "actions_total": %s, "high_total": %s, "medium_total": %s, "github_state": "%s" },\n' \
    "$(fm_supervision_json_escape "$s_level")" "$s_tasks" "$s_actions" "$s_high" "$s_medium" "$(fm_supervision_json_escape "$s_github")"
  printf '  "checklist": ['
  local cid sev owner action why task_id project pr_url evidence array_first=true
  while IFS=$'\t' read -r _ cid sev owner action why task_id project pr_url evidence; do
    [ -n "$cid" ] || continue
    if [ "$array_first" = true ]; then printf '\n'; array_first=false; else printf ',\n'; fi
    printf '    { "id": "%s", "severity": "%s", "owner": "%s", "action": "%s", "why": "%s", "task_id": "%s", "project": "%s", "pr_url": "%s", "evidence": ["%s"], "read_only_commands": [] }' \
      "$(fm_supervision_json_escape "$cid")" "$(fm_supervision_json_escape "$sev")" "$(fm_supervision_json_escape "$owner")" \
      "$(fm_supervision_json_escape "$action")" "$(fm_supervision_json_escape "$why")" "$(fm_supervision_json_escape "$task_id")" \
      "$(fm_supervision_json_escape "$project")" "$(fm_supervision_json_escape "$pr_url")" "$(fm_supervision_json_escape "$evidence")"
  done <<EOF
$checklist_lines
EOF
  if [ "$array_first" = true ]; then printf '],\n'; else printf '\n  ],\n'; fi

  printf '  "tasks": ['
  array_first=true
  local tid tproject tkind tmode tyolo twindow twindow_live tworktree tbranch tdirty tstatus tturn tpr tpr_state tci tmerge tclass _tsev towner taction tevidence
  while IFS=$'\t' read -r _ tid tproject tkind tmode tyolo twindow twindow_live tworktree tbranch tdirty tstatus tturn tpr tpr_state tci tmerge tclass _tsev towner taction tevidence; do
    [ -n "$tid" ] || continue
    if [ "$array_first" = true ]; then printf '\n'; array_first=false; else printf ',\n'; fi
    printf '    { "id": "%s", "project": "%s", "kind": "%s", "mode": "%s", "yolo": "%s", "window": "%s", "window_live": %s, "worktree": "%s", "branch": "%s", "dirty_count": %s, "last_status": "%s", "turn_ended": %s, "pr": { "url": "%s", "state": "%s", "ci_state": "%s", "mergeable_state": "%s" }, "classification": "%s", "next": { "owner": "%s", "action": "%s" }, "evidence": ["%s"] }' \
      "$(fm_supervision_json_escape "$tid")" "$(fm_supervision_json_escape "$tproject")" "$(fm_supervision_json_escape "$tkind")" \
      "$(fm_supervision_json_escape "$tmode")" "$(fm_supervision_json_escape "$tyolo")" "$(fm_supervision_json_escape "$twindow")" \
      "$(fm_supervision_bool "$twindow_live")" "$(fm_supervision_json_escape "$tworktree")" "$(fm_supervision_json_escape "$tbranch")" "${tdirty:-0}" \
      "$(fm_supervision_json_escape "$tstatus")" "$(fm_supervision_bool "$tturn")" "$(fm_supervision_json_escape "$tpr")" \
      "$(fm_supervision_json_escape "$tpr_state")" "$(fm_supervision_json_escape "$tci")" "$(fm_supervision_json_escape "$tmerge")" "$(fm_supervision_json_escape "$tclass")" \
      "$(fm_supervision_json_escape "$towner")" "$(fm_supervision_json_escape "$taction")" "$(fm_supervision_json_escape "$tevidence")"
  done <<EOF
$task_lines
EOF
  if [ "$array_first" = true ]; then printf '],\n'; else printf '\n  ],\n'; fi

  printf '  "worktrees": ['
  array_first=true
  local wpath wproject wbranch wdirty whas wclass _wsev wowner waction wevidence
  while IFS=$'\t' read -r _ wpath wproject wbranch wdirty whas wclass _wsev wowner waction wevidence; do
    [ -n "$wpath" ] || continue
    if [ "$array_first" = true ]; then printf '\n'; array_first=false; else printf ',\n'; fi
    printf '    { "path": "%s", "project": "%s", "branch": "%s", "dirty_count": %s, "has_active_task": %s, "classification": "%s", "next": { "owner": "%s", "action": "%s" }, "evidence": ["%s"] }' \
      "$(fm_supervision_json_escape "$wpath")" "$(fm_supervision_json_escape "$wproject")" "$(fm_supervision_json_escape "$wbranch")" \
      "${wdirty:-0}" "$(fm_supervision_bool "$whas")" "$(fm_supervision_json_escape "$wclass")" "$(fm_supervision_json_escape "$wowner")" \
      "$(fm_supervision_json_escape "$waction")" "$(fm_supervision_json_escape "$wevidence")"
  done <<EOF
$worktree_lines
EOF
  if [ "$array_first" = true ]; then printf '],\n'; else printf '\n  ],\n'; fi

  printf '  "external_reminders": ['
  array_first=true
  local eurl estate eci emerge eclass _esev eowner eaction eevidence
  while IFS=$'\t' read -r _ eurl estate eci emerge eclass _esev eowner eaction eevidence; do
    [ -n "$eurl" ] || continue
    if [ "$array_first" = true ]; then printf '\n'; array_first=false; else printf ',\n'; fi
    printf '    { "url": "%s", "state": "%s", "ci_state": "%s", "mergeable_state": "%s", "classification": "%s", "next": { "owner": "%s", "action": "%s" }, "evidence": ["%s"] }' \
      "$(fm_supervision_json_escape "$eurl")" "$(fm_supervision_json_escape "$estate")" "$(fm_supervision_json_escape "$eci")" \
      "$(fm_supervision_json_escape "$emerge")" "$(fm_supervision_json_escape "$eclass")" "$(fm_supervision_json_escape "$eowner")" \
      "$(fm_supervision_json_escape "$eaction")" "$(fm_supervision_json_escape "$eevidence")"
  done <<EOF
$external_lines
EOF
  if [ "$array_first" = true ]; then printf ']\n'; else printf '\n  ]\n'; fi
  printf '}\n'
}

fm_supervision_emit_text() {
  local generated_at include_ok
  generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  include_ok=${FM_SUPERVISE_INCLUDE_OK:-0}
  local checklist_lines= source_lines= task_lines= line kind
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind=${line%%$'\t'*}
    case "$kind" in
      checklist) fm_supervision_line_append checklist_lines "$line" ;;
      source) fm_supervision_line_append source_lines "$line" ;;
      task) fm_supervision_line_append task_lines "$line" ;;
    esac
  done
  printf 'Firstmate supervision - read-only - %s\n\n' "$generated_at"
  printf 'Action checklist\n'
  local index=0 cid sev owner action why _task_id _project pr_url evidence
  while IFS=$'\t' read -r _ cid sev owner action why _task_id _project pr_url evidence; do
    [ -n "$cid" ] || continue
    if [ "$sev" = info ] && [ "$include_ok" != 1 ]; then
      continue
    fi
    index=$((index + 1))
    printf '%s. %s %s - %s\n' "$index" "$(printf '%s' "$sev" | tr '[:lower:]' '[:upper:]')" "$owner" "$action"
    [ -n "$why" ] && printf '   Why: %s\n' "$why"
    if [ -n "$pr_url" ] && [ "$pr_url" != none ]; then
      printf '   PR: %s\n' "$pr_url"
    fi
    [ -n "$evidence" ] && printf '   Evidence: %s\n' "$evidence"
    printf '\n'
  done <<EOF
$checklist_lines
EOF
  if [ "$index" -eq 0 ]; then
    printf 'No immediate action items.\n\n'
  fi
  local gh_ok=true gh_detail=
  while IFS=$'\t' read -r _ name ok detail; do
    [ "$name" = github ] || continue
    gh_ok=$ok
    gh_detail=$detail
  done <<EOF
$source_lines
EOF
  printf 'Watch\n'
  if [ "$gh_ok" = false ]; then
    printf '%s\n' "- GitHub unavailable; PR states are unknown. $gh_detail"
  else
    printf '%s\n' '- GitHub readable through gh-axi.'
  fi
  local running=0
  while IFS=$'\t' read -r _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ _ class _ _ _ _; do
    [ "$class" = running ] && running=$((running + 1))
  done <<EOF
$task_lines
EOF
  if [ "$running" -gt 0 ] || [ "$include_ok" = 1 ]; then
    printf '%s\n' "- $running worker(s) are running normally."
  fi
  printf '\nNo changes made.\n'
}

fm_supervision_collect_and_emit() {
  local mode=${1:-text}
  case "$mode" in
    schema) fm_supervision_schema_json ;;
    json) fm_supervision_collect | fm_supervision_emit_json ;;
    text) fm_supervision_collect | fm_supervision_emit_text ;;
    *) return 2 ;;
  esac
}
