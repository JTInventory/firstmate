#!/usr/bin/env bash
# Shared read-only backlog/state drift audit helpers.

fm_backlog_audit_task_lines() {
  local backlog=$1
  awk '
    function task_id(line, rest, id) {
      rest = line
      sub(/^[[:space:]]*-[[:space:]]+/, "", rest)
      sub(/^\[[ xX]\][[:space:]]+/, "", rest)
      if (rest ~ /^\*\*/) {
        sub(/^\*\*/, "", rest)
        id = rest
        sub(/\*\*.*/, "", id)
        return id
      }
      id = rest
      sub(/[[:space:]].*/, "", id)
      return id
    }
    /^##[[:space:]]+/ {
      section = $0
      sub(/^##[[:space:]]+/, "", section)
      next
    }
    /^[[:space:]]*-[[:space:]]+/ {
      id = task_id($0)
      if (id != "") {
        print section "\t" id "\t" $0
      }
    }
  ' "$backlog"
}

fm_backlog_audit_secondmate_registry_lines() {
  local registry=$1
  awk '
    function secondmate_id(line, rest, id) {
      rest = line
      sub(/^[[:space:]]*-[[:space:]]+/, "", rest)
      id = rest
      sub(/[[:space:]].*/, "", id)
      return id
    }
    /^[[:space:]]*-[[:space:]]+/ {
      id = secondmate_id($0)
      if (id != "") {
        print id "\t" $0
      }
    }
  ' "$registry"
}

fm_backlog_audit_looks_pr_ready_or_merged() {
  local line=$1
  case "$line" in
    *"PR ready"*|*"checks green"*|*"merged"*|*"MERGED"*)
      return 0
      ;;
  esac
  return 1
}

fm_backlog_audit_meta_kind() {
  local meta=$1
  awk -F= '$1 == "kind" { print $2; exit }' "$meta"
}

fm_backlog_audit_severity() {
  case "$1" in
    duplicate-done|inflight-without-meta) printf 'high' ;;
    *) printf 'medium' ;;
  esac
}

fm_backlog_audit_collect() {
  local data=$1 state=$2
  local backlog="$data/backlog.md"
  local section id line meta category detail evidence severity reason

  declare -A fm_ba_inflight=()
  declare -A fm_ba_done=()
  declare -A fm_ba_watchlist=()
  declare -A fm_ba_secondmate_backlog=()
  declare -A fm_ba_secondmate_registry=()

  while IFS=$'\t' read -r section id line; do
    case "$section" in
      "In flight") fm_ba_inflight["$id"]=$line ;;
      "Done") fm_ba_done["$id"]=$line ;;
      "Watchlist") fm_ba_watchlist["$id"]=$line ;;
      "Secondmate Backlogs") fm_ba_secondmate_backlog["$id"]=$line ;;
    esac
  done < <(fm_backlog_audit_task_lines "$backlog")

  if [ -f "$data/secondmates.md" ]; then
    while IFS=$'\t' read -r id line; do
      fm_ba_secondmate_registry["$id"]=$line
    done < <(fm_backlog_audit_secondmate_registry_lines "$data/secondmates.md")
  fi

  for id in "${!fm_ba_inflight[@]}"; do
    if [ -n "${fm_ba_done[$id]+set}" ]; then
      category=duplicate-done
      detail="$id listed in both In flight and Done"
      severity=$(fm_backlog_audit_severity "$category")
      evidence="backlog In flight and Done both contain $id"
      printf 'finding\t%s\t%s\t%s\t%s\t%s\n' "$category" "$id" "$severity" "$detail" "$evidence"
    fi
    if [ ! -f "$state/$id.meta" ]; then
      category=inflight-without-meta
      detail="$id is In flight but has no state meta"
      severity=$(fm_backlog_audit_severity "$category")
      evidence="backlog section=In flight; missing meta=$state/$id.meta"
      printf 'finding\t%s\t%s\t%s\t%s\t%s\n' "$category" "$id" "$severity" "$detail" "$evidence"
    fi
    if fm_backlog_audit_looks_pr_ready_or_merged "${fm_ba_inflight[$id]}"; then
      category=inflight-pr-ready
      detail="$id is still In flight but looks PR-ready or merged"
      severity=$(fm_backlog_audit_severity "$category")
      evidence="backlog line=${fm_ba_inflight[$id]}"
      printf 'finding\t%s\t%s\t%s\t%s\t%s\n' "$category" "$id" "$severity" "$detail" "$evidence"
    fi
  done

  if [ -d "$state" ]; then
    shopt -s nullglob
    for meta in "$state"/*.meta; do
      id=$(basename "$meta" .meta)
      if [ -z "${fm_ba_inflight[$id]+set}" ]; then
        if [ "$(fm_backlog_audit_meta_kind "$meta")" = "secondmate" ]; then
          if [ -n "${fm_ba_secondmate_backlog[$id]+set}" ] || [ -n "${fm_ba_secondmate_registry[$id]+set}" ]; then
            reason="registered in data/secondmates.md or ## Secondmate Backlogs; expected persistent inventory"
            evidence="meta=$meta; secondmate registry=present"
            printf 'exception\tmeta-without-inflight\t%s\t%s\t%s\n' "$id" "$reason" "$evidence"
          else
            category="meta-without-inflight"
            detail="$id has unregistered secondmate state meta and is not in In flight"
            severity=$(fm_backlog_audit_severity "$category")
            evidence="meta=$meta; secondmate registry=absent"
            printf 'finding\t%s\t%s\t%s\t%s\t%s\n' "$category" "$id" "$severity" "$detail" "$evidence"
          fi
        else
          category="meta-without-inflight"
          detail="$id has state meta but is not in In flight"
          severity=$(fm_backlog_audit_severity "$category")
          evidence="meta=$meta; backlog section=absent"
          printf 'finding\t%s\t%s\t%s\t%s\t%s\n' "$category" "$id" "$severity" "$detail" "$evidence"
        fi
      fi
    done
    shopt -u nullglob
  fi

  for id in "${!fm_ba_watchlist[@]}"; do
    if [ -n "${fm_ba_inflight[$id]+set}" ]; then
      category=watchlist-adopted
      detail="$id is still on Watchlist but already listed In flight"
      severity=$(fm_backlog_audit_severity "$category")
      evidence="backlog sections=Watchlist,In flight"
      printf 'finding\t%s\t%s\t%s\t%s\t%s\n' "$category" "$id" "$severity" "$detail" "$evidence"
    elif [ -f "$state/$id.meta" ]; then
      category=watchlist-adopted
      detail="$id is still on Watchlist but already has local state meta"
      severity=$(fm_backlog_audit_severity "$category")
      evidence="backlog section=Watchlist; meta=$state/$id.meta"
      printf 'finding\t%s\t%s\t%s\t%s\t%s\n' "$category" "$id" "$severity" "$detail" "$evidence"
    fi
  done
}
