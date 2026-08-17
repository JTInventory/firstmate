#!/usr/bin/env bash

_FM_RUN_STEP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-safe-io-lib.sh
. "$_FM_RUN_STEP_LIB_DIR/fm-safe-io-lib.sh"

fm_run_step_binding_path() {
  printf '%s/.run-step-incarnation-%s' "$STATE" "$1"
}

fm_run_step_binding_lock_release() {
  local lock=$1 acquired=$2
  if [ "$acquired" = 1 ]; then
    fm_lock_release "$lock"
  fi
}

fm_run_step_binding_read_state() {
  local evidence=$1 id=$2 incarnation=$3 expected_state=$4 stored_run status
  [ -f "$evidence" ] && [ ! -L "$evidence" ] || return 75
  case "$expected_state" in active|staged) ;; *) return 75 ;; esac
  stored_run=$(awk -F= -v task="$id" -v inc="$incarnation" -v expected_state="$expected_state" '
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
      if (key == "run_id" && value == "") valid=0
      if (key == "spawn_incarnation" && value != inc) valid=0
      if (key == "state" && value != expected_state) valid=0
      next
    }
    { valid=0 }
    END {
      if (!("schema" in seen) || !("task_id" in seen) || !("run_id" in seen) \
        || !("spawn_incarnation" in seen) || !("state" in seen)) valid=0
      if (valid) print values["run_id"]
      else exit 75
    }
  ' "$evidence" 2>/dev/null)
  status=$?
  [ "$status" = 0 ] || return "$status"
  case "$stored_run" in ''|*[!A-Za-z0-9._:-]*) return 75 ;; esac
  printf '%s\n' "$stored_run"
}

fm_run_step_binding_read_variant() {
  local id=$1 incarnation=$2 expected_state=$3 evidence lock owner acquired=0 stored_run status
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 75 ;; esac
  case "$incarnation" in ''|*[!A-Za-z0-9._:-]*) return 75 ;; esac
  evidence=$(fm_run_step_binding_path "$id") || return 1
  if [ "${FM_RUN_STEP_READ_ONLY:-0}" = 1 ]; then
    fm_run_step_binding_read_state "$evidence" "$id" "$incarnation" "$expected_state"
    return $?
  fi
  lock=${FM_TASK_LOCK_PATH:-$STATE/.spawn-$id.lock}
  owner=${FM_TASK_LOCK_OWNER:-}
  if [ -n "$owner" ] && fm_lock_points_to_owner "$lock" "$owner"; then
    :
  else
    fm_lock_acquire_wait "$lock" || return 1
    acquired=1
  fi
  stored_run=$(fm_run_step_binding_read_state "$evidence" "$id" "$incarnation" "$expected_state")
  status=$?
  fm_run_step_binding_lock_release "$lock" "$acquired" || return 1
  [ "$status" = 0 ] || return "$status"
  printf '%s\n' "$stored_run"
}

fm_run_step_binding_read() {
  fm_run_step_binding_read_variant "$1" "$2" active
}

fm_run_step_binding_staged_read() {
  fm_run_step_binding_read_variant "$1" "$2" staged
}

fm_run_step_binding_metadata_validate() {
  local id=$1 run_id=$2 incarnation=$3 meta result
  meta="$STATE/$id.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 75
  result=$(awk -F= -v run_id="$run_id" -v inc="$incarnation" '
    BEGIN { invalid=0 }
    /^[^=]+=/ {
      key=$1
      value=substr($0, index($0, "=") + 1)
      if (key == "run_binding_state") { state=value; state_n++ }
      if (key == "run_id") { stored_run=value; run_n++ }
      if (key == "spawn_incarnation") { stored_inc=value; inc_n++ }
      next
    }
    { invalid=1 }
    END {
      if (state_n == 0 && !invalid) { print "legacy"; exit 0 }
      if (!invalid && state_n == 1 && run_n == 1 && inc_n == 1 \
        && state == "bound" && stored_run == run_id && stored_inc == inc) {
        print "bound"
        exit 0
      }
      print "invalid"
    }
  ' "$meta" 2>/dev/null) || return 1
  case "$result" in
    legacy|bound) return 0 ;;
    *) return 75 ;;
  esac
}

fm_run_step_binding_validate() {
  local id=$1 run_id=$2 incarnation=$3 stored_run
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 75 ;; esac
  case "$run_id" in ''|*[!A-Za-z0-9._:-]*) return 75 ;; esac
  case "$incarnation" in ''|*[!A-Za-z0-9._:-]*) return 75 ;; esac
  stored_run=$(fm_run_step_binding_read "$id" "$incarnation") || return $?
  [ "$stored_run" = "$run_id" ] || return 75
  fm_run_step_binding_metadata_validate "$id" "$run_id" "$incarnation"
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
    status=1
  fi
  if [ "$status" = 0 ]; then
    tmp=$(mktemp "$STATE/.run-step-incarnation.$id.XXXXXX") || status=1
  fi
  if [ "$status" = 0 ]; then
    if ! printf 'schema=fm-jt-run-step-incarnation.v1\ntask_id=%s\nrun_id=%s\nspawn_incarnation=%s\nstate=staged\n' \
      "$id" "$run_id" "$incarnation" | fm_nofollow_write "$tmp" \
      || ! mv -f "$tmp" "$evidence"; then
      rm -f "$tmp"
      status=1
    fi
  fi
  fm_run_step_binding_lock_release "$lock" "$acquired" || status=1
  return "$status"
}

fm_run_step_binding_activate() {
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
  if [ ! -f "$evidence" ] || [ -L "$evidence" ]; then
    status=1
  else
    tmp=$(mktemp "$STATE/.run-step-incarnation.$id.XXXXXX") || status=1
    if [ "$status" = 0 ]; then
      if ! awk -F= -v task="$id" -v run_id="$run_id" -v inc="$incarnation" '
        BEGIN { valid=1 }
        /^[^=]+=/ {
          key=$1
          if (key in seen) valid=0
          seen[key]=1
          value=substr($0, index($0, "=") + 1)
          if (key == "schema" && value != "fm-jt-run-step-incarnation.v1") valid=0
          if (key == "task_id" && value != task) valid=0
          if (key == "run_id" && value != run_id) valid=0
          if (key == "spawn_incarnation" && value != inc) valid=0
          if (key == "state") {
            if (value != "staged") valid=0
            print "state=active"
            next
          }
          print
          next
        }
        { valid=0 }
        END {
          if (!("schema" in seen) || !("task_id" in seen) || !("run_id" in seen) \
            || !("spawn_incarnation" in seen) || !("state" in seen)) valid=0
          exit(valid ? 0 : 1)
        }
      ' "$evidence" | fm_nofollow_write "$tmp" \
        || ! mv -f "$tmp" "$evidence"; then
        rm -f "$tmp"
        status=1
      fi
    fi
  fi
  fm_run_step_binding_lock_release "$lock" "$acquired" || status=1
  return "$status"
}
