#!/usr/bin/env bash
# Read-only Firstmate supervision model.
# Sourceable library used by bin/fm-supervise.sh and future displays.
FM_SUPERVISION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-tool-path-lib.sh
. "$FM_SUPERVISION_SCRIPT_DIR/fm-tool-path-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$FM_SUPERVISION_SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-numeric-lib.sh
. "$FM_SUPERVISION_SCRIPT_DIR/fm-numeric-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_SUPERVISION_SCRIPT_DIR/fm-backend.sh"

fm_supervision_usage() {
  cat <<'USAGE'
Usage: fm-supervise.sh [--text|--json|--schema] [--include-ok] [--no-default-reminders] [--external-pr <url>] [--help]

Modes:
  --text                  print captain-facing checklist (default)
  --json                  print firstmate.supervision.v1.1 JSON
  --schema                print the v1.1 JSON schema and exit

Inputs:
  --external-pr <url>     include one extra GitHub PR reminder; repeatable
  --no-default-reminders  omit built-in default reminders
  --include-ok            include low-priority OK/watch items in text output

Other:
  --help                  print usage
USAGE
}

fm_supervision_schema_json() {
  cat <<'JSON'
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "firstmate.supervision.v1.1",
  "type": "object",
  "required": ["schema_version", "generated_at", "home", "read_only", "sources", "summary", "backlog_consistency", "checklist", "tasks", "worktrees", "external_reminders"],
  "properties": {
    "schema_version": { "const": "firstmate.supervision.v1.1" },
    "generated_at": { "type": "string", "format": "date-time" },
    "home": { "type": "string" },
    "read_only": { "const": true },
    "sources": {
      "type": "object",
      "required": ["state", "backlog", "tmux", "treehouse", "git", "github", "watcher"],
      "additionalProperties": { "$ref": "#/$defs/source" }
    },
    "summary": {
      "type": "object",
      "required": ["level", "tasks_total", "actions_total", "high_total", "medium_total", "github_state", "watcher_state"],
      "properties": {
        "level": { "enum": ["ok", "watch", "action", "blocked"] },
        "tasks_total": { "type": "integer" },
        "actions_total": { "type": "integer" },
        "high_total": { "type": "integer" },
        "medium_total": { "type": "integer" },
        "github_state": { "enum": ["ok", "partial", "unavailable", "skipped"] },
        "watcher_state": { "enum": ["running", "unknown", "skipped"] }
      },
      "additionalProperties": false
    },
    "backlog_consistency": { "$ref": "#/$defs/backlog_consistency" },
    "checklist": { "type": "array", "items": { "$ref": "#/$defs/checklist_item" } },
    "tasks": { "type": "array", "items": { "$ref": "#/$defs/task" } },
    "worktrees": { "type": "array", "items": { "$ref": "#/$defs/worktree" } },
    "external_reminders": { "type": "array", "items": { "$ref": "#/$defs/external_reminder" } }
  },
  "$defs": {
    "source": {
      "type": "object",
      "required": ["ok", "detail"],
      "properties": {
        "ok": { "type": "boolean" },
        "detail": { "type": "string" }
      },
      "additionalProperties": false
    },
    "checklist_item": {
      "type": "object",
      "required": ["id", "severity", "owner", "action", "why", "task_id", "project", "pr_url", "evidence", "read_only_commands"],
      "properties": {
        "id": { "type": "string" },
        "severity": { "enum": ["high", "medium", "low", "info"] },
        "owner": { "enum": ["firstmate", "captain", "worker", "external", "unknown"] },
        "action": { "type": "string" },
        "why": { "type": "string" },
        "task_id": { "type": "string" },
        "project": { "type": "string" },
        "pr_url": { "type": "string" },
        "evidence": { "type": "array", "items": { "type": "string" } },
        "read_only_commands": { "type": "array", "items": { "type": "string" } }
      },
      "additionalProperties": false
    },
    "backlog_consistency": {
      "type": "object",
      "required": ["ok", "drift_count", "expected_exception_count", "checked_at", "findings", "expected_exceptions"],
      "properties": {
        "ok": { "type": "boolean" },
        "drift_count": { "type": "integer" },
        "expected_exception_count": { "type": "integer" },
        "checked_at": { "type": "string", "format": "date-time" },
        "findings": { "type": "array", "items": { "$ref": "#/$defs/backlog_finding" } },
        "expected_exceptions": { "type": "array", "items": { "$ref": "#/$defs/backlog_expected_exception" } }
      },
      "additionalProperties": false
    },
    "backlog_finding": {
      "type": "object",
      "required": ["category", "id", "severity", "detail", "owner", "evidence", "read_only_commands"],
      "properties": {
        "category": { "enum": ["duplicate-done", "meta-without-inflight", "inflight-without-meta", "inflight-pr-ready", "watchlist-adopted"] },
        "id": { "type": "string" },
        "severity": { "enum": ["high", "medium"] },
        "detail": { "type": "string" },
        "owner": { "const": "firstmate" },
        "evidence": { "type": "array", "items": { "type": "string" } },
        "read_only_commands": { "type": "array", "items": { "type": "string" } }
      },
      "additionalProperties": false
    },
    "backlog_expected_exception": {
      "type": "object",
      "required": ["category", "id", "reason", "evidence"],
      "properties": {
        "category": { "const": "meta-without-inflight" },
        "id": { "type": "string" },
        "reason": { "type": "string" },
        "evidence": { "type": "array", "items": { "type": "string" } }
      },
      "additionalProperties": false
    },
    "task": {
      "type": "object",
      "required": ["id", "project", "kind", "mode", "yolo", "harness", "route_profile", "route_harness", "route_model", "route_effort", "window", "window_live", "worktree", "branch", "recorded_branch", "dirty_count", "last_status", "turn_ended", "pr", "classification", "next", "evidence"],
      "properties": {
        "id": { "type": "string" },
        "project": { "type": "string" },
        "kind": { "type": "string" },
        "mode": { "type": "string" },
        "yolo": { "type": "string" },
        "harness": { "type": "string" },
        "route_profile": { "type": "string" },
        "route_harness": { "type": "string" },
        "route_model": { "type": "string" },
        "route_effort": { "type": "string" },
        "window": { "type": "string" },
        "window_live": { "type": "boolean" },
        "worktree": { "type": "string" },
        "branch": { "type": "string" },
        "recorded_branch": { "type": "string" },
        "dirty_count": { "type": "integer" },
        "last_status": { "type": "string" },
        "turn_ended": { "type": "boolean" },
        "pr": { "$ref": "#/$defs/pr" },
        "classification": { "type": "string" },
        "next": { "$ref": "#/$defs/next" },
        "evidence": { "type": "array", "items": { "type": "string" } }
      },
      "additionalProperties": false
    },
    "pr": {
      "type": "object",
      "required": ["url", "state", "ci_state", "mergeable_state"],
      "properties": {
        "url": { "type": "string" },
        "state": { "enum": ["none", "open", "merged", "closed", "unknown"] },
        "ci_state": { "enum": ["success", "failure", "error", "pending", "none", "unknown"] },
        "mergeable_state": { "type": "string" }
      },
      "additionalProperties": false
    },
    "next": {
      "type": "object",
      "required": ["owner", "action"],
      "properties": {
        "owner": { "enum": ["firstmate", "captain", "worker", "external", "unknown"] },
        "action": { "type": "string" }
      },
      "additionalProperties": false
    },
    "worktree": {
      "type": "object",
      "required": ["path", "project", "branch", "dirty_count", "has_active_task", "classification", "next", "evidence"],
      "properties": {
        "path": { "type": "string" },
        "project": { "type": "string" },
        "branch": { "type": "string" },
        "dirty_count": { "type": "integer" },
        "has_active_task": { "type": "boolean" },
        "classification": { "type": "string" },
        "next": { "$ref": "#/$defs/next" },
        "evidence": { "type": "array", "items": { "type": "string" } }
      },
      "additionalProperties": false
    },
    "external_reminder": {
      "type": "object",
      "required": ["url", "state", "ci_state", "mergeable_state", "classification", "next", "evidence"],
      "properties": {
        "url": { "type": "string" },
        "state": { "enum": ["open", "merged", "closed", "unknown"] },
        "ci_state": { "enum": ["success", "failure", "error", "pending", "none", "unknown"] },
        "mergeable_state": { "type": "string" },
        "classification": { "type": "string" },
        "next": { "$ref": "#/$defs/next" },
        "evidence": { "type": "array", "items": { "type": "string" } }
      },
      "additionalProperties": false
    }
  },
  "additionalProperties": false
}
JSON
}

fm_supervision_paths() {
  local script_dir root
  fm_normalize_tool_path
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="${FM_ROOT_OVERRIDE:-$(cd "$script_dir/.." && pwd)}"
  FM_SUPERVISION_ROOT="$root"
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
  local text=${1:-}
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
  local target=$1 backend=${2:-tmux}
  [ -n "$target" ] || return 1
  case "$backend" in
    herdr) fm_backend_pane_readable herdr "$target" ;;
    tmux)
      command -v tmux >/dev/null 2>&1 || return 1
      tmux display-message -p -t "$target" "#{window_name}" >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
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

fm_supervision_timeout_cmd() {
  if command -v timeout >/dev/null 2>&1; then
    printf 'timeout'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout'
  fi
}

fm_supervision_treehouse_status() {
  local project=$1 timeout_cmd
  [ -d "$project" ] || return 1
  command -v treehouse >/dev/null 2>&1 || return 1
  timeout_cmd=$(fm_supervision_timeout_cmd)
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
  local path=$1 timeout_cmd
  command -v gh-axi >/dev/null 2>&1 || return 127
  timeout_cmd=$(fm_supervision_timeout_cmd)
  if [ -n "$timeout_cmd" ]; then
    "$timeout_cmd" "${FM_SUPERVISE_GH_TIMEOUT:-5}" gh-axi api GET "$path" 2>/dev/null
  else
    gh-axi api GET "$path" 2>/dev/null
  fi
}

fm_supervision_check_runs_state() {
  local text
  text=$(cat)
  FM_SUPERVISION_CHECK_RUNS_TEXT=$text \
  python3 - <<'PY'
import json
import os
import re
import sys

text = os.environ.get("FM_SUPERVISION_CHECK_RUNS_TEXT", "")
if not text.strip():
    print("unknown\tunknown")
    raise SystemExit(0)

runs = []
total_count = None
try:
    data = json.loads(text)
    total_count = data.get("total_count")
    runs = data.get("check_runs") or []
except json.JSONDecodeError:
    match = re.search(r"(?m)^\s*total_count:\s*([0-9]+)\s*$", text)
    if match:
      total_count = int(match.group(1))
    statuses = re.findall(r"(?m)^\s*-?\s*status:\s*(\S+)\s*$", text)
    conclusions = re.findall(r"(?m)^\s*-?\s*conclusion:\s*(\S+)\s*$", text)
    for index, status in enumerate(statuses):
      conclusion = conclusions[index] if index < len(conclusions) else ""
      runs.append({"status": status, "conclusion": conclusion})

try:
    total = int(total_count)
except (TypeError, ValueError):
    total = len(runs) if runs else None

if total == 0:
    print("none\t0")
    raise SystemExit(0)
if not runs:
    print("unknown\t{}".format(total if total is not None else "unknown"))
    raise SystemExit(0)

failure_conclusions = {"failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale"}
pending = False
for run in runs:
    status = str(run.get("status") or "").lower()
    conclusion = run.get("conclusion")
    conclusion = "" if conclusion is None else str(conclusion).lower()
    if conclusion in failure_conclusions:
        print("failure\t{}".format(total if total is not None else len(runs)))
        raise SystemExit(0)
    if status != "completed" or conclusion in {"", "null"}:
        pending = True

if pending:
    print("pending\t{}".format(total if total is not None else len(runs)))
else:
    print("success\t{}".format(total if total is not None else len(runs)))
PY
}

fm_supervision_merge_ci_state() {
  local status_state=$1 status_count=$2 check_state=$3 check_count=$4 total
  if printf '%s\n%s\n' "$status_state" "$check_state" | grep -Eq '^(failure|error)$'; then
    printf 'failure\t%s' "$(fm_supervision_ci_total "$status_count" "$check_count")"
  elif printf '%s\n%s\n' "$status_state" "$check_state" | grep -Eq '^pending$'; then
    printf 'pending\t%s' "$(fm_supervision_ci_total "$status_count" "$check_count")"
  elif printf '%s\n%s\n' "$status_state" "$check_state" | grep -Eq '^unknown$'; then
    printf 'unknown\t%s' "$(fm_supervision_ci_total "$status_count" "$check_count")"
  elif printf '%s\n%s\n' "$status_state" "$check_state" | grep -Eq '^success$'; then
    printf 'success\t%s' "$(fm_supervision_ci_total "$status_count" "$check_count")"
  else
    total=$(fm_supervision_ci_total "$status_count" "$check_count")
    [ "$total" = 0 ] && printf 'none\t0' || printf 'unknown\t%s' "$total"
  fi
}

fm_supervision_ci_total() {
  local a=$1 b=$2 total=0 saw=false
  case "$a" in ''|unknown) : ;; *[!0-9]*) : ;; *) total=$((total + a)); saw=true ;; esac
  case "$b" in ''|unknown) : ;; *[!0-9]*) : ;; *) total=$((total + b)); saw=true ;; esac
  "$saw" && printf '%s' "$total" || printf 'unknown'
}

fm_supervision_gh_pr() {
  local url=$1 parsed repo number out state merged mergeable_state sha status_out checks_out checks_data ci_data ci_state total_count status_state status_count check_state check_count
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
  [ "$state" = closed ] && state=closed
  [ "$merged" = true ] && state=merged
  ci_state=unknown
  total_count=unknown
  if [ -n "$sha" ]; then
    status_state=unknown
    status_count=unknown
    status_out=$(fm_supervision_gh_api_get "/repos/$repo/commits/$sha/status") || status_out=
    if [ -n "$status_out" ]; then
      status_state=$(printf '%s\n' "$status_out" | fm_supervision_yaml_value state)
      status_count=$(printf '%s\n' "$status_out" | fm_supervision_yaml_value total_count)
      [ -n "$status_state" ] || status_state=unknown
      [ -n "$status_count" ] || status_count=unknown
      [ "$status_count" = 0 ] && status_state=none
    fi
    check_state=unknown
    check_count=unknown
    checks_out=$(fm_supervision_gh_api_get "/repos/$repo/commits/$sha/check-runs") || checks_out=
    if [ -n "$checks_out" ]; then
      checks_data=$(printf '%s\n' "$checks_out" | fm_supervision_check_runs_state)
      check_state=$(printf '%s' "$checks_data" | awk -F '\t' '{ print $1 }')
      check_count=$(printf '%s' "$checks_data" | awk -F '\t' '{ print $2 }')
    fi
    ci_data=$(fm_supervision_merge_ci_state "$status_state" "$status_count" "$check_state" "$check_count")
    ci_state=$(printf '%s' "$ci_data" | awk -F '\t' '{ print $1 }')
    total_count=$(printf '%s' "$ci_data" | awk -F '\t' '{ print $2 }')
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$state" "$ci_state" "${mergeable_state:-unknown}" "$repo" "${sha:-unknown}" "$total_count"
}

fm_supervision_project_path() {
  local project=$1 candidate
  [ -n "$project" ] || return 1
  case "$project" in
    /*)
      [ -d "$project" ] || return 1
      printf '%s' "$project"
      ;;
    *)
      candidate="$FM_SUPERVISION_PROJECTS/$project"
      [ -d "$candidate" ] || return 1
      printf '%s' "$candidate"
      ;;
  esac
}

fm_supervision_path_age() {
  local path=$1 m
  [ -e "$path" ] || {
    printf '999999'
    return 1
  }
  if [ "$(uname)" = Darwin ]; then
    m=$(stat -f %m "$path" 2>/dev/null) || m=
  else
    m=$(stat -c %Y "$path" 2>/dev/null) || m=
  fi
  [ -n "$m" ] || {
    printf '999999'
    return 1
  }
  printf '%s' "$(( $(date +%s) - m ))"
}

fm_supervision_pid_alive() {
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

fm_supervision_watcher_status() {
  local task_count=$1 lock="$FM_SUPERVISION_STATE/.watch.lock" beat="$FM_SUPERVISION_STATE/.last-watcher-beat"
  local grace=${FM_GUARD_GRACE:-300} pid lock_home lock_path age state ok detail
  if [ "$task_count" -eq 0 ]; then
    printf 'true\tskipped\tno active task metadata; watcher proof not required'
    return 0
  fi
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  lock_home=$(cat "$lock/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$lock/watcher-path" 2>/dev/null || true)
  age=$(fm_supervision_path_age "$beat" 2>/dev/null || printf '999999')
  ok=false
  state=unknown
  detail="watcher not proved for this home; use bin/fm-watch-arm.sh or bin/fm-watch-session.sh --status for live proof"
  if [ "$lock_home" = "$FM_SUPERVISION_HOME" ] && [ "$lock_path" = "$FM_SUPERVISION_ROOT/bin/fm-watch.sh" ] && [ "$age" -lt "$grace" ]; then
    if fm_supervision_pid_alive "$pid"; then
      ok=true
      state=running
      detail="watch lock and fresh beacon proved locally"
    else
      detail="fresh watcher beacon but pid not visible from this environment; treat as unknown, not proved down"
    fi
  elif [ "$age" -lt "$grace" ]; then
    detail="fresh watcher beacon exists, but lock does not prove this home/path"
  fi
  printf '%s\t%s\t%s' "$ok" "$state" "$detail"
}

fm_supervision_status_is_paused() {
  local reason
  case "$1" in
    paused:*) reason=${1#paused:} ;;
    *) return 1 ;;
  esac
  [[ "$reason" =~ [^[:space:]] ]]
}

fm_supervision_paused_reconciliation() {  # <id> <remaining seconds>
  local id=$1 remaining=$2 line state source
  [ "$remaining" -gt 0 ] || { printf 'unknown\tnone'; return 0; }
  line=$(FM_CREW_STATE_NM_TIMEOUT="$remaining" "$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'unknown\tnone'; return 0 ;; esac
  state=${line#state: }; state=${state%% *}
  source=${line#*source: }; source=${source%% *}
  printf '%s\t%s' "$state" "$source"
}

fm_supervision_pause_reconcile_seconds() {
  fm_nonnegative_integer_or_default "${FM_SUPERVISION_PAUSE_RECONCILE_SECS:-5}" 5 86400
}

fm_supervision_classify_task() {
  local id=$1 kind=$2 mode=$3 yolo=$4 window_live=$5 worktree=$6 last_status=$7 pr_url=$8 pr_state=$9 ci_state=${10} scout_report_exists=${11:-false} paused_is_current=${12:-true}
  local classification=running severity=info owner=worker action="Monitor worker progress." why="Worker has no captain-facing status yet."
  # Classification order is part of the public supervision contract: completed
  # scout reports require a done status, and live secondmates are persistent
  # direct reports unless they have a fresh captain-relevant status.
  if [ "$kind" = scout ] && [ "$scout_report_exists" = true ] && printf '%s\n' "$last_status" | grep -q '^done:'; then
    classification=scout_report_ready
    severity=medium
    owner=firstmate
    action="Tear down the scout; its report exists."
    why="Scout report exists at data/$id/report.md."
  elif [ -n "$worktree" ] && [ ! -e "$worktree" ]; then
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
  elif [ "$kind" = secondmate ] && [ "$window_live" = true ] && printf '%s\n' "$last_status" | grep -q '^blocked:'; then
    classification=worker_blocked
    severity=high
    owner=captain
    action="Resolve the worker blocker."
    why="$last_status"
  elif [ "$kind" = secondmate ] && [ "$window_live" = true ] && printf '%s\n' "$last_status" | grep -q '^needs-decision:'; then
    classification=worker_needs_decision
    severity=high
    owner=captain
    action="Make the requested decision."
    why="$last_status"
  elif [ "$kind" = secondmate ] && [ "$window_live" = true ] && printf '%s\n' "$last_status" | grep -q '^failed:'; then
    classification=worker_failed
    severity=high
    owner=firstmate
    action="Inspect the worker failure and decide the next step."
    why="$last_status"
  elif [ "$kind" = secondmate ] && [ "$window_live" = true ] && printf '%s\n' "$last_status" | grep -q '^done:'; then
    classification=secondmate_response_ready
    severity=medium
    owner=firstmate
    action="Read or relay the secondmate response; keep the secondmate live."
    why="$last_status"
  elif [ "$kind" = secondmate ] && [ "$window_live" = true ] && [ "$paused_is_current" = true ] && fm_supervision_status_is_paused "$last_status"; then
    classification=worker_external_wait
    severity=medium
    owner=external
    action="Review the declared external wait before continuing."
    why="$last_status"
  elif [ "$kind" = secondmate ] && [ "$window_live" = true ]; then
    classification=persistent_secondmate_idle
    severity=info
    owner=firstmate
    action="Keep the persistent secondmate live."
    why="Secondmate meta represents a persistent direct report, not a PR worker."
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
    why="The direct-PR task has an open PR with no CI statuses and the worker reported done."
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
  elif [ "$paused_is_current" = true ] && fm_supervision_status_is_paused "$last_status"; then
    classification=worker_external_wait
    severity=medium
    owner=external
    action="Review the declared external wait before continuing."
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
  # shellcheck source=bin/fm-backlog-audit-lib.sh
  . "$FM_SUPERVISION_ROOT/bin/fm-backlog-audit-lib.sh"
  local records="" source_records="" checklist_records="" task_records="" worktree_records="" external_records="" backlog_records=""
  local state_ok=true backlog_ok=true tmux_ok=true treehouse_ok=true git_ok=true github_ok=true github_detail="gh-axi api GET only"
  local task_count=0 checklist_count=0 high_count=0 medium_count=0 github_state=ok watcher_state=skipped watcher_ok=true watcher_detail=
  local referenced_worktrees="|"
  local meta id project project_status_path kind mode yolo harness route_profile route_harness route_model route_effort window backend worktree recorded_branch branch dirty_count last_status classification_status paused_is_current pause_reconcile_remaining pause_reconcile_started pause_reconcile_used pause_reconciliation pause_state pause_source turn_ended pr_url pr_data pr_state ci_state mergeable_state
  local class_data classification severity owner action why evidence line status_pr pause_reconcile_secs window_live scout_report_exists treehouse_failed=false

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
    pause_reconcile_secs=$(fm_supervision_pause_reconcile_seconds)
    pause_reconcile_used=0
    for meta in "$FM_SUPERVISION_STATE"/*.meta; do
      [ -e "$meta" ] || continue
      treehouse_failed=false
      id=$(basename "$meta" .meta)
      project=$(fm_supervision_meta_value "$meta" project)
      kind=$(fm_supervision_meta_value "$meta" kind); [ -n "$kind" ] || kind=ship
      mode=$(fm_supervision_meta_value "$meta" mode); [ -n "$mode" ] || mode=no-mistakes
      yolo=$(fm_supervision_meta_value "$meta" yolo); [ -n "$yolo" ] || yolo=off
      backend=$(fm_supervision_meta_value "$meta" backend); [ -n "$backend" ] || backend=tmux
      harness=$(fm_supervision_meta_value "$meta" harness); [ -n "$harness" ] || harness=unknown
      route_profile=$(fm_supervision_meta_value "$meta" route_profile); [ -n "$route_profile" ] || route_profile=unknown
      route_harness=$(fm_supervision_meta_value "$meta" route_harness); [ -n "$route_harness" ] || route_harness=unknown
      route_model=$(fm_supervision_meta_value "$meta" route_model); [ -n "$route_model" ] || route_model=unknown
      route_effort=$(fm_supervision_meta_value "$meta" route_effort); [ -n "$route_effort" ] || route_effort=unknown
      window=$(fm_supervision_meta_value "$meta" window)
      worktree=$(fm_supervision_meta_value "$meta" worktree)
      recorded_branch=$(fm_supervision_meta_value "$meta" branch); [ -n "$recorded_branch" ] || recorded_branch=unknown
      [ -n "$worktree" ] && referenced_worktrees="$referenced_worktrees$worktree|"
      last_status=$(fm_supervision_last_status "$FM_SUPERVISION_STATE/$id.status")
      classification_status=$last_status
      status_pr=$(fm_supervision_status_pr_url "$last_status")
      paused_is_current=true
      if fm_supervision_status_is_paused "$last_status"; then
        pause_reconcile_remaining=$(( pause_reconcile_secs - pause_reconcile_used ))
        pause_reconcile_started=$SECONDS
        pause_reconciliation=$(fm_supervision_paused_reconciliation "$id" "$pause_reconcile_remaining")
        pause_reconcile_used=$(( pause_reconcile_used + SECONDS - pause_reconcile_started ))
        pause_state=${pause_reconciliation%%$'\t'*}
        pause_source=${pause_reconciliation#*$'\t'}
        case "$pause_source:$pause_state" in
          run-step:working|pane:working) paused_is_current=false ;;
          run-step:done) paused_is_current=false; classification_status="done: authoritative run completed" ;;
          run-step:failed) paused_is_current=false; classification_status="failed: authoritative run failed" ;;
          run-step:parked) paused_is_current=false; classification_status="needs-decision: authoritative run awaits captain decision" ;;
        esac
      fi
      turn_ended=false
      [ -e "$FM_SUPERVISION_STATE/$id.turn-ended" ] && turn_ended=true
      pr_url=$(fm_supervision_meta_value "$meta" pr)
      [ -n "$pr_url" ] || pr_url=$status_pr
      if fm_supervision_window_live "$window" "$backend"; then window_live=true; else window_live=false; fi
      scout_report_exists=false
      [ "$kind" = scout ] && [ -f "$FM_SUPERVISION_DATA/$id/report.md" ] && scout_report_exists=true
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
      project_status_path=$(fm_supervision_project_path "$project" 2>/dev/null || true)
      if [ -n "$project_status_path" ]; then
        if ! fm_supervision_treehouse_status "$project_status_path"; then
          treehouse_failed=true
          treehouse_ok=false
        fi
      fi
      class_data=$(fm_supervision_classify_task "$id" "$kind" "$mode" "$yolo" "$window_live" "$worktree" "$classification_status" "$pr_url" "$pr_state" "$ci_state" "$scout_report_exists" "$paused_is_current")
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
      line=$(printf 'task\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$(fm_supervision_field "$id")" "$(fm_supervision_field "$project")" "$(fm_supervision_field "$kind")" \
        "$(fm_supervision_field "$mode")" "$(fm_supervision_field "$yolo")" "$(fm_supervision_field "$harness")" \
        "$(fm_supervision_field "$route_profile")" "$(fm_supervision_field "$route_harness")" "$(fm_supervision_field "$route_model")" "$(fm_supervision_field "$route_effort")" \
        "$(fm_supervision_field "$window")" "$window_live" "$(fm_supervision_field "$worktree")" "$(fm_supervision_field "$branch")" "$(fm_supervision_field "$recorded_branch")" "$dirty_count" \
        "$(fm_supervision_field "$last_status")" "$turn_ended" "$(fm_supervision_field "$pr_url")" \
        "$pr_state" "$ci_state" "$mergeable_state" "$classification" "$severity" "$owner" "$(fm_supervision_field "$action")" "$(fm_supervision_field "$evidence")")
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

  # A failed away-mode injection is durable local supervision truth. Surface
  # it through the existing read-only checklist contract without attempting
  # recovery or mutating the marker.
  local wedge_marker="$FM_SUPERVISION_STATE/.subsuper-inject-wedged"
  if [ -s "$wedge_marker" ]; then
    local wedge_detail=""
    IFS= read -r wedge_detail < "$wedge_marker" 2>/dev/null || true
    line=$(fm_supervision_checklist_record \
      "supervision:inject-wedged" high firstmate \
      "Review the local wedge marker and restore the supervisor injection path before relying on away-mode silence." \
      "The away-mode daemon could not confirm an escalation submit after the configured defer window." \
      "" "" "" "marker=$wedge_marker; detail=$wedge_detail")
    fm_supervision_line_append checklist_records "$line"
    checklist_count=$((checklist_count + 1))
    high_count=$((high_count + 1))
  fi

  local watcher_data
  watcher_data=$(fm_supervision_watcher_status "$task_count")
  watcher_ok=$(printf '%s' "$watcher_data" | awk -F '\t' '{ print $1 }')
  watcher_state=$(printf '%s' "$watcher_data" | awk -F '\t' '{ print $2 }')
  watcher_detail=$(printf '%s' "$watcher_data" | awk -F '\t' '{ print $3 }')
  if [ "$task_count" -gt 0 ] && [ "$watcher_state" = unknown ]; then
    line=$(fm_supervision_checklist_record "watcher:unconfirmed" medium firstmate "Verify watcher liveness with the guarded arm/session commands before relying on silence." "$watcher_detail" "" "" "" "$watcher_detail")
    fm_supervision_line_append checklist_records "$line"
    checklist_count=$((checklist_count + 1))
    medium_count=$((medium_count + 1))
  fi

  if [ "$backlog_ok" = true ]; then
    local ba_kind ba_category ba_id ba_severity ba_detail ba_evidence ba_reason ba_action ba_why
    while IFS=$'\t' read -r ba_kind ba_category ba_id ba_severity ba_detail ba_evidence; do
      [ -n "$ba_kind" ] || continue
      case "$ba_kind" in
        finding)
          line=$(printf 'backlog_finding\t%s\t%s\t%s\t%s\t%s' \
            "$(fm_supervision_field "$ba_category")" "$(fm_supervision_field "$ba_id")" "$(fm_supervision_field "$ba_severity")" \
            "$(fm_supervision_field "$ba_detail")" "$(fm_supervision_field "$ba_evidence")")
          fm_supervision_line_append backlog_records "$line"
          ba_action="Reconcile backlog/state drift for $ba_id."
          ba_why="Backlog audit reports $ba_category."
          line=$(fm_supervision_checklist_record "backlog:$ba_id:$ba_category" "$ba_severity" firstmate "$ba_action" "$ba_why" "$ba_id" "" "" "$ba_evidence")
          fm_supervision_line_append checklist_records "$line"
          checklist_count=$((checklist_count + 1))
          [ "$ba_severity" = high ] && high_count=$((high_count + 1))
          [ "$ba_severity" = medium ] && medium_count=$((medium_count + 1))
          ;;
        exception)
          ba_reason=$ba_severity
          line=$(printf 'backlog_exception\t%s\t%s\t%s\t%s' \
            "$(fm_supervision_field "$ba_category")" "$(fm_supervision_field "$ba_id")" "$(fm_supervision_field "$ba_reason")" \
            "$(fm_supervision_field "$ba_detail")")
          fm_supervision_line_append backlog_records "$line"
          ;;
      esac
    done < <(fm_backlog_audit_collect "$FM_SUPERVISION_DATA" "$FM_SUPERVISION_STATE")
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
    reminders=${FM_SUPERVISE_DEFAULT_REMINDERS:-}
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
  source_records=$(printf 'source\tstate\t%s\t%s\nsource\tbacklog\t%s\t%s\nsource\ttmux\t%s\t%s\nsource\ttreehouse\t%s\t%s\nsource\tgit\t%s\t%s\nsource\tgithub\t%s\t%s\nsource\twatcher\t%s\t%s' \
    "$state_ok" "state/meta/status read only" \
    "$backlog_ok" "data/backlog.md read only" \
    "$tmux_ok" "tmux display-message only" \
    "$treehouse_ok" "treehouse status only" \
    "$git_ok" "git branch/status/worktree reads only" \
    "$github_ok" "$github_detail" \
    "$watcher_ok" "$watcher_detail")
  records=$source_records
  [ -n "$task_records" ] && records="$records"$'\n'"$task_records"
  [ -n "$worktree_records" ] && records="$records"$'\n'"$worktree_records"
  [ -n "$external_records" ] && records="$records"$'\n'"$external_records"
  [ -n "$backlog_records" ] && records="$records"$'\n'"$backlog_records"
  [ -n "$checklist_records" ] && records="$records"$'\n'"$checklist_records"
  records="$records"$'\n'"summary	$level	$task_count	$checklist_count	$high_count	$medium_count	$github_state	$watcher_state"
  printf '%s\n' "$records"
}

fm_supervision_emit_json() {
  fm_supervision_paths
  local generated_at source_lines="" task_lines="" worktree_lines="" external_lines="" checklist_lines="" backlog_finding_lines="" backlog_exception_lines="" summary_line="" line kind
  generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind=${line%%$'\t'*}
    case "$kind" in
      source) fm_supervision_line_append source_lines "$line" ;;
      task) fm_supervision_line_append task_lines "$line" ;;
      worktree) fm_supervision_line_append worktree_lines "$line" ;;
      external) fm_supervision_line_append external_lines "$line" ;;
      backlog_finding) fm_supervision_line_append backlog_finding_lines "$line" ;;
      backlog_exception) fm_supervision_line_append backlog_exception_lines "$line" ;;
      checklist) fm_supervision_line_append checklist_lines "$line" ;;
      summary) summary_line=$line ;;
    esac
  done

  local s_level=ok s_tasks=0 s_actions=0 s_high=0 s_medium=0 s_github=skipped s_watcher=skipped
  if [ -n "$summary_line" ]; then
    IFS=$'\t' read -r _ s_level s_tasks s_actions s_high s_medium s_github s_watcher <<EOF
$summary_line
EOF
  fi

  printf '{\n'
  printf '  "schema_version": "firstmate.supervision.v1.1",\n'
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
  printf '  "summary": { "level": "%s", "tasks_total": %s, "actions_total": %s, "high_total": %s, "medium_total": %s, "github_state": "%s", "watcher_state": "%s" },\n' \
    "$(fm_supervision_json_escape "$s_level")" "$s_tasks" "$s_actions" "$s_high" "$s_medium" "$(fm_supervision_json_escape "$s_github")" "$(fm_supervision_json_escape "$s_watcher")"

  local drift_count=0 exception_count=0
  if [ -n "$backlog_finding_lines" ]; then
    drift_count=$(printf '%s\n' "$backlog_finding_lines" | awk 'NF { count++ } END { print count + 0 }')
  fi
  if [ -n "$backlog_exception_lines" ]; then
    exception_count=$(printf '%s\n' "$backlog_exception_lines" | awk 'NF { count++ } END { print count + 0 }')
  fi
  printf '  "backlog_consistency": {\n'
  if [ "$drift_count" -eq 0 ]; then
    printf '    "ok": true,\n'
  else
    printf '    "ok": false,\n'
  fi
  printf '    "drift_count": %s,\n' "$drift_count"
  printf '    "expected_exception_count": %s,\n' "$exception_count"
  printf '    "checked_at": "%s",\n' "$(fm_supervision_json_escape "$generated_at")"
  printf '    "findings": ['
  array_first=true
  local bf_category bf_id bf_severity bf_detail bf_evidence
  while IFS=$'\t' read -r _ bf_category bf_id bf_severity bf_detail bf_evidence; do
    [ -n "$bf_category" ] || continue
    if [ "$array_first" = true ]; then printf '\n'; array_first=false; else printf ',\n'; fi
    printf '      { "category": "%s", "id": "%s", "severity": "%s", "detail": "%s", "owner": "firstmate", "evidence": ["%s"], "read_only_commands": ["bin/fm-supervise.sh --json --no-default-reminders", "bin/fm-backlog-audit.sh"] }' \
      "$(fm_supervision_json_escape "$bf_category")" "$(fm_supervision_json_escape "$bf_id")" "$(fm_supervision_json_escape "$bf_severity")" \
      "$(fm_supervision_json_escape "$bf_detail")" "$(fm_supervision_json_escape "$bf_evidence")"
  done <<EOF
$backlog_finding_lines
EOF
  if [ "$array_first" = true ]; then printf '],\n'; else printf '\n    ],\n'; fi
  printf '    "expected_exceptions": ['
  array_first=true
  local be_category be_id be_reason be_evidence
  while IFS=$'\t' read -r _ be_category be_id be_reason be_evidence; do
    [ -n "$be_category" ] || continue
    if [ "$array_first" = true ]; then printf '\n'; array_first=false; else printf ',\n'; fi
    printf '      { "category": "%s", "id": "%s", "reason": "%s", "evidence": ["%s"] }' \
      "$(fm_supervision_json_escape "$be_category")" "$(fm_supervision_json_escape "$be_id")" \
      "$(fm_supervision_json_escape "$be_reason")" "$(fm_supervision_json_escape "$be_evidence")"
  done <<EOF
$backlog_exception_lines
EOF
  if [ "$array_first" = true ]; then printf ']\n'; else printf '\n    ]\n'; fi
  printf '  },\n'

  printf '  "checklist": ['
  local array_first=true cid sev cowner caction why ctask_id cproject cpr_url cevidence
  while IFS=$'\t' read -r _ cid sev cowner caction why ctask_id cproject cpr_url cevidence; do
    [ -n "$cid" ] || continue
    if [ "$array_first" = true ]; then printf '\n'; array_first=false; else printf ',\n'; fi
    printf '    { "id": "%s", "severity": "%s", "owner": "%s", "action": "%s", "why": "%s", "task_id": "%s", "project": "%s", "pr_url": "%s", "evidence": ["%s"], "read_only_commands": [] }' \
      "$(fm_supervision_json_escape "$cid")" "$(fm_supervision_json_escape "$sev")" "$(fm_supervision_json_escape "$cowner")" \
      "$(fm_supervision_json_escape "$caction")" "$(fm_supervision_json_escape "$why")" "$(fm_supervision_json_escape "$ctask_id")" \
      "$(fm_supervision_json_escape "$cproject")" "$(fm_supervision_json_escape "$cpr_url")" "$(fm_supervision_json_escape "$cevidence")"
  done <<EOF
$checklist_lines
EOF
  if [ "$array_first" = true ]; then printf '],\n'; else printf '\n  ],\n'; fi

  printf '  "tasks": ['
  array_first=true
  local tid tproject tkind tmode tyolo tharness troute_profile troute_harness troute_model troute_effort twindow twindow_live tworktree tbranch trecorded_branch tdirty tstatus tturn tpr tpr_state tci tmerge tclass _tsev towner taction tevidence
  while IFS=$'\t' read -r _ tid tproject tkind tmode tyolo tharness troute_profile troute_harness troute_model troute_effort twindow twindow_live tworktree tbranch trecorded_branch tdirty tstatus tturn tpr tpr_state tci tmerge tclass _tsev towner taction tevidence; do
    [ -n "$tid" ] || continue
    if [ "$array_first" = true ]; then printf '\n'; array_first=false; else printf ',\n'; fi
    printf '    { "id": "%s", "project": "%s", "kind": "%s", "mode": "%s", "yolo": "%s", "harness": "%s", "route_profile": "%s", "route_harness": "%s", "route_model": "%s", "route_effort": "%s", "window": "%s", "window_live": %s, "worktree": "%s", "branch": "%s", "recorded_branch": "%s", "dirty_count": %s, "last_status": "%s", "turn_ended": %s, "pr": { "url": "%s", "state": "%s", "ci_state": "%s", "mergeable_state": "%s" }, "classification": "%s", "next": { "owner": "%s", "action": "%s" }, "evidence": ["%s"] }' \
      "$(fm_supervision_json_escape "$tid")" "$(fm_supervision_json_escape "$tproject")" "$(fm_supervision_json_escape "$tkind")" \
      "$(fm_supervision_json_escape "$tmode")" "$(fm_supervision_json_escape "$tyolo")" "$(fm_supervision_json_escape "$tharness")" \
      "$(fm_supervision_json_escape "$troute_profile")" "$(fm_supervision_json_escape "$troute_harness")" "$(fm_supervision_json_escape "$troute_model")" "$(fm_supervision_json_escape "$troute_effort")" \
      "$(fm_supervision_json_escape "$twindow")" "$(fm_supervision_bool "$twindow_live")" "$(fm_supervision_json_escape "$tworktree")" "$(fm_supervision_json_escape "$tbranch")" "$(fm_supervision_json_escape "$trecorded_branch")" "${tdirty:-0}" \
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
  local generated_at include_ok checklist_lines="" source_lines="" task_lines="" summary_line="" line kind
  generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  include_ok=${FM_SUPERVISE_INCLUDE_OK:-0}
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind=${line%%$'\t'*}
    case "$kind" in
      checklist) fm_supervision_line_append checklist_lines "$line" ;;
      source) fm_supervision_line_append source_lines "$line" ;;
      task) fm_supervision_line_append task_lines "$line" ;;
      summary) summary_line=$line ;;
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
    [ -n "$why" ] && [ "$why" != none ] && printf '   Why: %s\n' "$why"
    if [ -n "$pr_url" ] && [ "$pr_url" != none ]; then
      printf '   PR: %s\n' "$pr_url"
    fi
    [ -n "$evidence" ] && [ "$evidence" != none ] && printf '   Evidence: %s\n' "$evidence"
    printf '\n'
  done <<EOF
$checklist_lines
EOF
  if [ "$index" -eq 0 ]; then
    printf 'No immediate action items.\n\n'
  fi

  local gh_ok=true gh_detail="" watcher_ok=true watcher_detail=""
  while IFS=$'\t' read -r _ name ok detail; do
    case "$name" in
      github) gh_ok=$ok; gh_detail=$detail ;;
      watcher) watcher_ok=$ok; watcher_detail=$detail ;;
    esac
  done <<EOF
$source_lines
EOF
  printf 'Watch\n'
  if [ "$gh_ok" = false ]; then
    printf '%s\n' "- GitHub unavailable; PR states are unknown. $gh_detail"
  else
    printf '%s\n' '- GitHub readable through gh-axi.'
  fi
  if [ "$watcher_ok" = false ]; then
    printf '%s\n' "- Watcher liveness not proved from this environment. $watcher_detail"
  fi
  local running=0
  while IFS=$'\t' read -r _ _id _project _kind _mode _yolo _harness _route_profile _route_harness _route_model _route_effort _window _window_live _worktree _branch _recorded_branch _dirty_count _last_status _turn_ended _pr_url _pr_state _ci_state _mergeable_state class _severity _owner _action _evidence; do
    case "$class" in
      running|persistent_secondmate_idle) running=$((running + 1)) ;;
    esac
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
