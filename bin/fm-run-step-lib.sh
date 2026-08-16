#!/usr/bin/env bash

fm_run_step_binding_path() {
  printf '%s/.run-step-incarnation-%s' "$STATE" "$1"
}

fm_run_step_binding_lock_release() {
  local lock=$1 acquired=$2
  if [ "$acquired" = 1 ]; then
    fm_lock_release "$lock"
  fi
}

fm_run_step_binding_validate() {
  local id=$1 run_id=$2 incarnation=$3 evidence lock owner acquired=0 stored_run
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$run_id" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  case "$incarnation" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  evidence=$(fm_run_step_binding_path "$id") || return 1
  lock=${FM_TASK_LOCK_PATH:-$STATE/.spawn-$id.lock}
  owner=${FM_TASK_LOCK_OWNER:-}
  if [ -n "$owner" ] && fm_lock_points_to_owner "$lock" "$owner"; then
    :
  else
    fm_lock_acquire_wait "$lock" || return 1
    acquired=1
  fi
  if [ ! -f "$evidence" ] || [ -L "$evidence" ]; then
    fm_run_step_binding_lock_release "$lock" "$acquired"
    return 1
  fi
  if stored_run=$(awk -F= -v task="$id" -v wanted_run="$run_id" -v inc="$incarnation" '
    BEGIN {
      allowed["schema"]=1; allowed["task_id"]=1; allowed["run_id"]=1
      allowed["spawn_incarnation"]=1; allowed["state"]=1
      valid=1
    }
    /^[^=]+=/ {
      key=$1
      if (!(key in allowed) || (key in seen)) valid=0
      seen[key]=1
      value=substr($0, index($0, "=") + 1)
      values[key]=value
      if (key == "schema" && value != "fm-jt-run-step-incarnation.v1") valid=0
      if (key == "task_id" && value != task) valid=0
      if (key == "run_id" && (value == "" || value != wanted_run)) valid=0
      if (key == "spawn_incarnation" && value != inc) valid=0
      if (key == "state" && value != "active") valid=0
      next
    }
    { valid=0 }
    END {
      if (!("schema" in seen) || !("task_id" in seen) || !("run_id" in seen) \
        || !("spawn_incarnation" in seen) || !("state" in seen)) valid=0
      if (valid) print values["run_id"]
      exit !valid
    }
  ' "$evidence" 2>/dev/null); then
    [ "$stored_run" = "$run_id" ]
    local status=$?
    fm_run_step_binding_lock_release "$lock" "$acquired"
    return "$status"
  fi
  fm_run_step_binding_lock_release "$lock" "$acquired"
  return 1
}

fm_run_step_binding_publish() {
  local id=$1 run_id=$2 incarnation=$3 evidence lock owner acquired=0 tmp status=0
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$run_id" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  case "$incarnation" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  evidence=$(fm_run_step_binding_path "$id") || return 1
  lock=${FM_TASK_LOCK_PATH:-$STATE/.spawn-$id.lock}
  owner=${FM_TASK_LOCK_OWNER:-}
  if [ -n "$owner" ] && fm_lock_points_to_owner "$lock" "$owner"; then
    :
  else
    fm_lock_acquire_wait "$lock" || return 1
    acquired=1
  fi
  if [ -e "$evidence" ] || [ -L "$evidence" ]; then
    [ -f "$evidence" ] && [ ! -L "$evidence" ] || status=1
  fi
  if [ "$status" = 0 ]; then
    tmp=$(mktemp "$STATE/.run-step-incarnation.$id.XXXXXX") || status=1
  fi
  if [ "$status" = 0 ]; then
    if ! printf 'schema=fm-jt-run-step-incarnation.v1\ntask_id=%s\nrun_id=%s\nspawn_incarnation=%s\nstate=active\n' \
      "$id" "$run_id" "$incarnation" > "$tmp" || ! mv -f "$tmp" "$evidence"; then
      rm -f "$tmp"
      status=1
    fi
  fi
  fm_run_step_binding_lock_release "$lock" "$acquired" || status=1
  return "$status"
}
