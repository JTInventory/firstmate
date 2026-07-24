#!/usr/bin/env bash
# fm-fleet-snapshot.sh - read-only structured local fleet snapshot.
#
# `--json` emits schema fm-fleet-snapshot.v1. The command reads only the local
# backlog, state metadata, status events, and git worktree facts. It never calls
# GitHub, acquires the session lock, drains wakes, or writes a report.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

usage() {
  cat <<'USAGE'
Usage: fm-fleet-snapshot.sh [--json|--help]
       fm-fleet-snapshot.sh --backlog-title <task-id>

The default and --json modes print the read-only fm-fleet-snapshot.v1 JSON
contract. All sources are local to this Firstmate home.
--backlog-title prints the title from one canonical structured backlog row and
exits before task endpoint inspection.
USAGE
}

OUTPUT_MODE=json
case "${1:---json}" in
  --json) ;;
  --backlog-title)
    OUTPUT_MODE=backlog-title
    BACKLOG_TITLE_ID=${2:-}
    [ -n "$BACKLOG_TITLE_ID" ] || { usage >&2; exit 2; }
    ;;
  --help|-h) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

if [ "$OUTPUT_MODE" = backlog-title ]; then
  [ -f "$DATA/backlog.md" ] || exit 0
  awk -v id="$BACKLOG_TITLE_ID" '
    {
      prefix = "- [ ] " id " - "
      done_prefix = "- [x] " id " - "
      done_prefix_upper = "- [X] " id " - "
      bold_prefix = "- **" id "** - "
      if (index($0, prefix) == 1) title = substr($0, length(prefix) + 1)
      else if (index($0, done_prefix) == 1) title = substr($0, length(done_prefix) + 1)
      else if (index($0, done_prefix_upper) == 1) title = substr($0, length(done_prefix_upper) + 1)
      else if (index($0, bold_prefix) == 1) title = substr($0, length(bold_prefix) + 1)
      else next
      sub(/[[:space:]]+\(repo:[^)]*\).*/, "", title)
      sub(/[[:space:]]+blocked-by:.*/, "", title)
      print title
      exit
    }
  ' "$DATA/backlog.md"
  exit 0
fi

command -v jq >/dev/null 2>&1 || {
  printf '%s\n' 'fm-fleet-snapshot.sh: jq is required for the JSON contract' >&2
  exit 127
}

meta_value() {
  local file=$1 key=$2
  awk -F= -v key="$key" '$1 == key { value = substr($0, length(key) + 2) } END { print value }' "$file" 2>/dev/null
}

last_nonempty() {
  [ -f "$1" ] || return 0
  awk 'NF { line = $0 } END { print line }' "$1" 2>/dev/null
}

current_from_status() {
  local line=${1:-} verb detail
  [ -n "$line" ] || { printf '%s' 'unknown'; return; }
  verb=${line%%:*}
  detail=${line#*:}
  detail=${detail#"${detail%%[![:space:]]*}"}
  case "$verb" in
    working) printf 'working' ;;
    needs-decision) printf 'parked' ;;
    paused) [ -n "$detail" ] && printf 'paused' || printf 'unknown' ;;
    blocked) printf 'blocked' ;;
    done) printf 'done' ;;
    failed) printf 'failed' ;;
    *) printf 'unknown' ;;
  esac
}

json_tasks=''
shopt -s nullglob
meta_files=("$STATE"/*.meta)
if [ "${#meta_files[@]}" -gt 0 ]; then
  mapfile -t meta_files < <(printf '%s\n' "${meta_files[@]}" | sort)
fi
for meta in "${meta_files[@]}"; do
  id=$(basename "$meta" .meta)
  worktree=$(meta_value "$meta" worktree)
  project=$(meta_value "$meta" project)
  kind=$(meta_value "$meta" kind)
  mode=$(meta_value "$meta" mode)
  harness=$(meta_value "$meta" harness)
  status_line=$(last_nonempty "$STATE/$id.status" || true)
  current_line=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_CREW_STATE_NM_TIMEOUT=2 "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || true)
  current_state=$(printf '%s\n' "$current_line" | sed -n 's/^state: \([^[:space:]]*\).*$/\1/p')
  current_source=$(printf '%s\n' "$current_line" | sed -n 's/^state: [^·]*· source: \([^·]*\).*$/\1/p' | sed 's/[[:space:]]//g')
  if [ -z "$current_state" ]; then current_state=$(current_from_status "$status_line"); fi
  [ -n "$current_source" ] || current_source=none
  branch=unknown
  dirty_count=0
  if [ -d "$worktree" ] && git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    branch=$(git -C "$worktree" branch --show-current 2>/dev/null || true)
    [ -n "$branch" ] || branch=detached
    dirty_count=$(git -C "$worktree" status --porcelain --untracked-files=all 2>/dev/null | wc -l | tr -d ' ')
  fi
  pr_url=$(printf '%s\n' "$status_line" | grep -Eo 'https://github.com/[^[:space:])"]+/[^[:space:])"]+/pull/[0-9]+' | tail -1 || true)
  [ -n "$pr_url" ] || pr_url=none
  task=$(jq -cn \
    --arg id "$id" --arg project "$project" --arg kind "${kind:-ship}" \
    --arg mode "${mode:-unknown}" --arg harness "${harness:-unknown}" \
    --arg worktree "$worktree" --arg branch "$branch" \
    --arg status_line "$status_line" --arg current_state "$current_state" \
    --arg current_source "$current_source" --arg current_line "$current_line" \
    --arg pr_url "$pr_url" --arg dirty_count "$dirty_count" \
    '{id:$id,project:$project,kind:$kind,mode:$mode,harness:$harness,worktree:$worktree,branch:$branch,dirty_count:($dirty_count|tonumber),last_status:$status_line,current_state:{state:$current_state,source:$current_source,line:$current_line},pr_url:$pr_url}')
  if [ -n "$json_tasks" ]; then json_tasks="$json_tasks\n$task"; else json_tasks=$task; fi
done
if [ -n "$json_tasks" ]; then
  tasks_json=$(printf '%b\n' "$json_tasks" | jq -s '.')
else
  tasks_json='[]'
fi

if [ -f "$DATA/backlog.md" ]; then
  backlog_present=true
  backlog_records=$(awk '
    /^##[[:space:]]/ { section = $0; next }
    /[^[:space:]]/ { printf "%s\t%s\n", section, $0 }
  ' "$DATA/backlog.md" | jq -R -s '
    split("\n") | map(select(length > 0) | split("\t") | {section: .[0], line: (.[1:] | join("\t"))})
  ')
else
  backlog_present=false
  backlog_records='[]'
fi

generated=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
jq_backlog_path="$DATA/backlog.md"
jq -n \
  --arg schema 'fm-fleet-snapshot.v1' --arg generated "$generated" \
  --arg fm_home "$FM_HOME" --arg root "$ROOT" --arg data "$DATA" \
  --arg state "$STATE" --arg projects "$PROJECTS" --arg backlog_path "$jq_backlog_path" \
  --argjson backlog_present "$backlog_present" \
  --argjson backlog_records "$backlog_records" --argjson tasks "$tasks_json" \
  '{schema:$schema,generated:$generated,read_only:true,roots:{firstmate:$root,fm_home:$fm_home,data:$data,state:$state,projects:$projects},backlog:{path:$backlog_path,present:$backlog_present,records:$backlog_records},tasks:$tasks,summary:{tasks_total:($tasks|length),secondmates:([$tasks[] | select(.kind == "secondmate")] | length),states:([$tasks[].current_state.state] | group_by(.) | map({state:.[0],count:length}))}}'
