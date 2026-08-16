#!/usr/bin/env bash
set -u

run_id_from_output() {
  awk '
    function emit(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      if (value ~ /^[A-Za-z0-9._:-]+$/) {
        print value
        exit
      }
    }
    /^[[:space:]]*run:[[:space:]]*$/ { in_run=1; next }
    /^[^[:space:]]/ { in_run=0 }
    in_run && /^[[:space:]]+id:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]+id:[[:space:]]*/, "", value)
      emit(value)
    }
    /^[[:space:]]*(run|run_id)[[:space:]]*[:=][[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*(run|run_id)[[:space:]]*[:=][[:space:]]*/, "", value)
      emit(value)
    }
  ' "$1"
}

handoff_value() {
  local key=$1
  awk -F= -v wanted="$key" '$1 == wanted { print substr($0, index($0, "=") + 1); n++ } END { exit(n == 1 ? 0 : 1) }' \
    "$FM_RUN_BINDING_HANDOFF" 2>/dev/null
}

handoff_valid() {
  local schema task incarnation state run_id
  [ -f "$FM_RUN_BINDING_HANDOFF" ] && [ ! -L "$FM_RUN_BINDING_HANDOFF" ] || return 1
  schema=$(handoff_value schema) || return 1
  task=$(handoff_value task_id) || return 1
  incarnation=$(handoff_value spawn_incarnation) || return 1
  state=$(handoff_value state) || return 1
  [ "$schema" = fm-jt-run-step-handoff.v1 ] || return 1
  [ "$task" = "$FM_RUN_BINDING_TASK" ] || return 1
  [ "$incarnation" = "$FM_RUN_BINDING_INCARNATION" ] || return 1
  case "$state" in pending) ;; bound)
    run_id=$(handoff_value run_id) || return 1
    case "$run_id" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
    ;;
    *) return 1 ;;
  esac
}

metadata_generation_valid() {
  local meta=$STATE/$FM_RUN_BINDING_TASK.meta incarnation state handoff
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  incarnation=$(awk -F= '$1 == "spawn_incarnation" { print substr($0, index($0, "=") + 1); n++ } END { exit(n == 1 ? 0 : 1) }' "$meta" 2>/dev/null) || return 1
  state=$(awk -F= '$1 == "run_binding_state" { print substr($0, index($0, "=") + 1); n++ } END { exit(n == 1 ? 0 : 1) }' "$meta" 2>/dev/null) || return 1
  handoff=$(awk -F= '$1 == "run_binding_handoff" { print substr($0, index($0, "=") + 1); n++ } END { exit(n == 1 ? 0 : 1) }' "$meta" 2>/dev/null) || return 1
  [ "$incarnation" = "$FM_RUN_BINDING_INCARNATION" ] || return 1
  case "$state" in pending|staged|bound) ;; *) return 1 ;; esac
  [ "$handoff" = "${FM_RUN_BINDING_HANDOFF##*/}" ]
}

metadata_staged_run_id() {
  local meta=$STATE/$FM_RUN_BINDING_TASK.meta result status
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 75
  result=$(awk -F= -v inc="$FM_RUN_BINDING_INCARNATION" '
    BEGIN { valid=1 }
    /^[^=]+=/ {
      key=$1
      if (key in seen) valid=0
      seen[key]=1
      value=substr($0, index($0, "=") + 1)
      if (key == "run_binding_state") { state=value; state_n++ }
      if (key == "run_id") { run_id=value; run_n++ }
      if (key == "spawn_incarnation") { stored_inc=value; inc_n++ }
      next
    }
    { valid=0 }
    END {
      if (!valid || state_n != 1 || run_n != 1 || inc_n != 1 \
        || state != "staged" || stored_inc != inc || run_id == "") exit 75
      print run_id
    }
  ' "$meta" 2>/dev/null)
  status=$?
  case "$status" in
    0)
      case "$result" in ''|*[!A-Za-z0-9._:-]*) return 75 ;; esac
      printf '%s\n' "$result"
      ;;
    75) return 75 ;;
    *) return 1 ;;
  esac
}

meta_set_run_binding_state() {
  local desired_state=$1 run_id=$2 meta tmp status=0 owner acquired=0
  case "$desired_state" in staged|bound) ;; *) return 1 ;; esac
  meta="$STATE/$FM_RUN_BINDING_TASK.meta"
  owner=${FM_TASK_LOCK_OWNER:-}
  if [ -n "$owner" ] && fm_lock_points_to_owner "$FM_TASK_LOCK_PATH" "$owner"; then
    :
  else
    fm_lock_acquire_wait "$FM_TASK_LOCK_PATH" || return 1
    acquired=1
  fi
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    status=1
  elif ! metadata_generation_valid; then
    status=1
  else
    tmp=$(mktemp "$STATE/.${FM_RUN_BINDING_TASK}.meta-run-binding.XXXXXX") || status=1
    if [ "$status" = 0 ]; then
      if ! awk -v run_id="$run_id" -v desired_state="$desired_state" '
        /^run_binding_state=/ { print "run_binding_state=" desired_state; print "run_id=" run_id; found=1; next }
        /^run_id=/ { next }
        { print }
        END { exit(found ? 0 : 1) }
      ' "$meta" > "$tmp" || ! mv -f "$tmp" "$meta"; then
        rm -f "$tmp"
        status=1
      fi
    fi
  fi
  if [ "$acquired" = 1 ]; then
    fm_lock_release "$FM_TASK_LOCK_PATH" || status=1
  fi
  return "$status"
}

meta_stage_run_id() {
  meta_set_run_binding_state staged "$1"
}

meta_bind_run_id() {
  meta_set_run_binding_state bound "$1"
}

publish_run_id() {
  local run_id=$1 existing staged_existing status=0 existing_status staged_status owner old_owner acquired=0 \
    evidence existing_active=0 existing_staged=0
  case "$run_id" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  old_owner=${FM_TASK_LOCK_OWNER:-}
  fm_lock_acquire_wait "$FM_TASK_LOCK_PATH" || return 1
  acquired=1
  owner=$(fm_lock_link_owner "$FM_TASK_LOCK_PATH" 2>/dev/null) || status=1
  if [ "$status" = 0 ]; then
    FM_TASK_LOCK_OWNER=$owner
    export FM_TASK_LOCK_OWNER
    handoff_valid || status=1
    metadata_generation_valid || status=1
  fi
  if [ "$status" = 0 ]; then
    if existing=$(fm_run_step_binding_read "$FM_RUN_BINDING_TASK" "$FM_RUN_BINDING_INCARNATION" 2>/dev/null); then
      if [ "$existing" = "$run_id" ]; then
        existing_active=1
      else
        status=1
      fi
    else
      existing_status=$?
      if [ "$existing_status" = 75 ]; then
        evidence=$(fm_run_step_binding_path "$FM_RUN_BINDING_TASK") || status=1
        if [ "$status" = 0 ] && { [ -e "$evidence" ] || [ -L "$evidence" ]; }; then
          if staged_existing=$(fm_run_step_binding_staged_read \
            "$FM_RUN_BINDING_TASK" "$FM_RUN_BINDING_INCARNATION" 2>/dev/null); then
            if [ "$staged_existing" = "$run_id" ]; then
              existing_staged=1
            else
              status=1
            fi
          else
            status=1
          fi
        elif [ "$status" = 0 ]; then
          if staged_existing=$(metadata_staged_run_id 2>/dev/null); then
            [ "$staged_existing" = "$run_id" ] || status=1
          else
            staged_status=$?
            [ "$staged_status" = 75 ] || status=1
          fi
        fi
      else
        status=1
      fi
    fi
  fi
  if [ "$status" = 0 ]; then
    if [ "$existing_active" = 1 ]; then
      meta_bind_run_id "$run_id" || status=1
    else
      if [ "$existing_staged" = 0 ]; then
        if ! meta_stage_run_id "$run_id"; then
          status=1
        elif ! fm_run_step_binding_publish "$FM_RUN_BINDING_TASK" "$run_id" "$FM_RUN_BINDING_INCARNATION"; then
          status=1
        fi
      fi
      if [ "$status" = 0 ] && ! fm_run_step_binding_activate \
        "$FM_RUN_BINDING_TASK" "$run_id" "$FM_RUN_BINDING_INCARNATION"; then
        status=1
      fi
      if [ "$status" = 0 ] && ! meta_bind_run_id "$run_id"; then
        status=1
      fi
    fi
  fi
  if [ "$acquired" = 1 ]; then
    fm_lock_release "$FM_TASK_LOCK_PATH" || status=1
  fi
  if [ -n "$old_owner" ]; then
    FM_TASK_LOCK_OWNER=$old_owner
    export FM_TASK_LOCK_OWNER
  else
    unset FM_TASK_LOCK_OWNER
  fi
  return "$status"
}

run_axi() {
  local output child child_status=0 run_id published=0 tmpdir output_file
  tmpdir=${FM_RUN_BINDING_TMP:-${TMPDIR:-/tmp}}
  output_file=$(mktemp "$tmpdir/.fm-run-step-output.XXXXXX") || return 1
  "$FM_RUN_BINDING_REAL" "$@" >"$output_file" 2>&1 &
  child=$!
  while kill -0 "$child" 2>/dev/null; do
    if run_id=$(run_id_from_output "$output_file") && [ -n "$run_id" ]; then
      if ! publish_run_id "$run_id"; then
        kill "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
        cat "$output_file"
        rm -f "$output_file"
        return 1
      fi
      published=1
      break
    fi
    sleep 0.05
  done
  wait "$child" || child_status=$?
  if [ "$published" = 0 ] && run_id=$(run_id_from_output "$output_file") && [ -n "$run_id" ]; then
    if publish_run_id "$run_id"; then
      published=1
    fi
  fi
  cat "$output_file"
  rm -f "$output_file"
  [ "$published" = 1 ] || return 1
  return "$child_status"
}

main() {
  local command_name=${1:-}
  shift || true
  [ "$command_name" = wrap ] || return 2
  [ -n "${FM_RUN_BINDING_ROOT:-}" ] || return 1
  [ -n "${FM_RUN_BINDING_STATE:-}" ] || return 1
  [ -n "${FM_RUN_BINDING_TASK:-}" ] || return 1
  [ -n "${FM_RUN_BINDING_INCARNATION:-}" ] || return 1
  [ -n "${FM_RUN_BINDING_HANDOFF:-}" ] || return 1
  FM_ROOT=$FM_RUN_BINDING_ROOT
  FM_HOME=${FM_RUN_BINDING_HOME:-$FM_ROOT}
  STATE=$FM_RUN_BINDING_STATE
  FM_TASK_LOCK_PATH=$STATE/.spawn-$FM_RUN_BINDING_TASK.lock
  FM_SESSION_LOCK_BOOTSTRAP=1
  export FM_ROOT FM_HOME STATE FM_TASK_LOCK_PATH FM_SESSION_LOCK_BOOTSTRAP
  . "$FM_ROOT/bin/fm-wake-lib.sh"
  . "$FM_ROOT/bin/fm-run-step-lib.sh"
  FM_RUN_BINDING_REAL=${1:-}
  shift || true
  [ -x "$FM_RUN_BINDING_REAL" ] || return 1
  if [ "${1:-}" = axi ] && [ "${2:-}" = run ]; then
    run_axi "$@"
  else
    "$FM_RUN_BINDING_REAL" "$@"
  fi
}

main "$@"
