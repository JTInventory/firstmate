#!/usr/bin/env bash
set -u
set -o pipefail

run_id_from_output() {
  awk '
    function normalize(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      if (value ~ /^[A-Za-z0-9._:-]+$/) {
        parsed=value
      } else {
        invalid=1
      }
    }
    /^run:[[:space:]]*$/ {
      if (run_seen) invalid=1
      run_seen=1
      in_run=1
      next
    }
    /^[^[:space:]]/ { in_run=0 }
    in_run && /^[[:space:]]+id:[[:space:]]*/ {
      id_count++
      value=$0
      sub(/^[[:space:]]+id:[[:space:]]*/, "", value)
      normalize(value)
    }
    END {
      if (!run_seen || invalid || id_count != 1 || parsed == "") exit 1
      print parsed
    }
  ' "$1"
}

handoff_value() {
  local key=$1
  fm_nofollow_read "$FM_RUN_BINDING_HANDOFF" | awk -F= -v wanted="$key" \
    '$1 == wanted { print substr($0, index($0, "=") + 1); n++ } END { exit(n == 1 ? 0 : 1) }' \
    2>/dev/null
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
  local meta=$STATE/$FM_RUN_BINDING_TASK.meta incarnation state handoff contents
  FM_RUN_BINDING_METADATA_STATE=
  contents=$(fm_nofollow_read "$meta") || return 1
  incarnation=$(printf '%s\n' "$contents" | awk -F= '$1 == "spawn_incarnation" { print substr($0, index($0, "=") + 1); n++ } END { exit(n == 1 ? 0 : 1) }') || return 1
  state=$(printf '%s\n' "$contents" | awk -F= '$1 == "run_binding_state" { print substr($0, index($0, "=") + 1); n++ } END { exit(n == 1 ? 0 : 1) }') || return 1
  handoff=$(printf '%s\n' "$contents" | awk -F= '$1 == "run_binding_handoff" { print substr($0, index($0, "=") + 1); n++ } END { exit(n == 1 ? 0 : 1) }') || return 1
  [ "$incarnation" = "$FM_RUN_BINDING_INCARNATION" ] || return 1
  case "$state" in pending|staged|bound) ;; *) return 1 ;; esac
  [ "$handoff" = "${FM_RUN_BINDING_HANDOFF##*/}" ] || return 1
  FM_RUN_BINDING_METADATA_STATE=$state
}

metadata_staged_run_id() {
  local meta=$STATE/$FM_RUN_BINDING_TASK.meta result status contents
  contents=$(fm_nofollow_read "$meta") || return 75
  result=$(printf '%s\n' "$contents" | awk -F= -v inc="$FM_RUN_BINDING_INCARNATION" '
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
  ' 2>/dev/null)
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
      ' "$meta" | fm_nofollow_write "$tmp" \
        || ! fm_nofollow_rename "$tmp" "$meta"; then
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
  if [ -n "$old_owner" ] && fm_lock_points_to_owner "$FM_TASK_LOCK_PATH" "$old_owner"; then
    owner=$old_owner
  else
    fm_lock_acquire_wait "$FM_TASK_LOCK_PATH" || return 1
    acquired=1
    owner=$(fm_lock_link_owner "$FM_TASK_LOCK_PATH" 2>/dev/null) || status=1
  fi
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
          if [ "${FM_RUN_BINDING_METADATA_STATE:-}" = bound ]; then
            status=1
          elif staged_existing=$(metadata_staged_run_id 2>/dev/null); then
            [ "$staged_existing" = "$run_id" ] || status=1
          else
            staged_status=$?
            [ "${FM_RUN_BINDING_METADATA_STATE:-}" = pending ] && [ "$staged_status" = 75 ] || status=1
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
        fm_run_step_binding_deactivate \
          "$FM_RUN_BINDING_TASK" "$run_id" "$FM_RUN_BINDING_INCARNATION" || true
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

recover_staged_binding() {
  local staged old_owner owner acquired=0 status=0
  old_owner=${FM_TASK_LOCK_OWNER:-}
  if [ -n "$old_owner" ] && fm_lock_points_to_owner "$FM_TASK_LOCK_PATH" "$old_owner"; then
    owner=$old_owner
  else
    fm_lock_acquire_wait "$FM_TASK_LOCK_PATH" || return 1
    acquired=1
    owner=$(fm_lock_link_owner "$FM_TASK_LOCK_PATH" 2>/dev/null) || status=1
  fi
  if [ "$status" = 0 ]; then
    FM_TASK_LOCK_OWNER=$owner
    export FM_TASK_LOCK_OWNER
    if ! metadata_generation_valid; then
      status=1
    elif [ "${FM_RUN_BINDING_METADATA_STATE:-}" = staged ]; then
      staged=$(metadata_staged_run_id 2>/dev/null) || status=1
      [ "$status" -ne 0 ] || publish_run_id "$staged" || status=1
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

run_axi_proc_group_id() {
  local pid=$1 stat rest
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ -r "/proc/$pid/stat" ] || return 1
  stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
  rest=${stat##*) }
  set -- $rest
  [ "$#" -ge 3 ] || return 1
  printf '%s\n' "$3"
}

run_axi_child_group_is_current() {
  local child=$1 expected_start=$2 actual_start pgid
  actual_start=$(fm_pid_start "$child" 2>/dev/null) || return 1
  [ "$actual_start" = "$expected_start" ] || return 1
  pgid=$(run_axi_proc_group_id "$child") || return 1
  [ "$pgid" = "$child" ]
}

run_axi_group_member_identity() {
  local child=$1 entry pid stat rest start
  for entry in /proc/[0-9]*; do
    pid=${entry#/proc/}
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    [ "$pid" = "$child" ] && continue
    [ -r "$entry/stat" ] || continue
    stat=$(cat "$entry/stat" 2>/dev/null) || continue
    rest=${stat##*) }
    set -- $rest
    [ "$#" -ge 20 ] || continue
    [ "$3" = "$child" ] || continue
    start="proc:${20}"
    printf '%s|%s\n' "$pid" "$start"
    return 0
  done
  return 1
}

run_axi_group_member_is_current() {
  local child=$1 pid=$2 expected_start=$3 actual_start pgid
  actual_start=$(fm_pid_start "$pid" 2>/dev/null) || return 1
  [ "$actual_start" = "$expected_start" ] || return 1
  pgid=$(run_axi_proc_group_id "$pid") || return 1
  [ "$pgid" = "$child" ]
}

run_axi_stop_group() {
  local child=$1 expected_start=$2 member_pid=${3:-} member_start=${4:-} attempts=0
  case "$child" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$expected_start" ] || return 1
  if ! run_axi_child_group_is_current "$child" "$expected_start"; then
    if ! kill -0 -- "-$child" 2>/dev/null; then
      return 0
    fi
    run_axi_group_member_is_current "$child" "$member_pid" "$member_start" || return 1
  fi
  kill -TERM -- "-$child" 2>/dev/null || true
  while kill -0 -- "-$child" 2>/dev/null && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if kill -0 -- "-$child" 2>/dev/null; then
    if ! run_axi_child_group_is_current "$child" "$expected_start"; then
      run_axi_group_member_is_current "$child" "$member_pid" "$member_start" || return 1
    fi
    kill -KILL -- "-$child" 2>/dev/null || true
    attempts=0
    while kill -0 -- "-$child" 2>/dev/null && [ "$attempts" -lt 100 ]; do
      sleep 0.01
      attempts=$((attempts + 1))
    done
  fi
  ! kill -0 -- "-$child" 2>/dev/null
}

run_axi_abort_child() {
  local child=$1 expected_start=$2 member_pid=${3:-} member_start=${4:-} actual_start
  run_axi_stop_group "$child" "$expected_start" "$member_pid" "$member_start" || true
  if actual_start=$(fm_pid_start "$child" 2>/dev/null) \
    && [ "$actual_start" = "$expected_start" ]; then
    kill -TERM "$child" 2>/dev/null || true
    kill -KILL "$child" 2>/dev/null || true
  fi
  wait "$child" 2>/dev/null || true
}

run_axi() {
  local child child_start child_status=0 run_id published=0 startup_seen=0 tmpdir output_file
  local group_member group_member_pid='' group_member_start=''
  local startup_wait_secs startup_deadline total_wait_secs total_deadline now
  tmpdir=${FM_RUN_BINDING_TMP:-${TMPDIR:-/tmp}}
  output_file=$(mktemp "$tmpdir/.fm-run-step-output.XXXXXX") || return 1
  fm_nofollow_spawn_capture "$output_file" "$FM_RUN_BINDING_REAL" "$@" &
  child=$!
  case "$child" in ''|*[!0-9]*) rm -f "$output_file"; return 1 ;; esac
  child_start=$(fm_pid_start "$child" 2>/dev/null) || {
    wait "$child" 2>/dev/null || true
    cat "$output_file"
    rm -f "$output_file"
    return 1
  }
  startup_wait_secs=${FM_RUN_BINDING_STARTUP_WAIT_SECS:-30}
  case "$startup_wait_secs" in ''|*[!0-9]*|0) startup_wait_secs=30 ;; esac
  while [ "${startup_wait_secs#0}" != "$startup_wait_secs" ]; do
    startup_wait_secs=${startup_wait_secs#0}
  done
  [ -n "$startup_wait_secs" ] || startup_wait_secs=30
  case "${#startup_wait_secs}" in
    1|2) ;;
    3) [ "$startup_wait_secs" -le 300 ] || startup_wait_secs=300 ;;
    *) startup_wait_secs=300 ;;
  esac
  startup_deadline=$(( $(date +%s) + startup_wait_secs ))
  total_wait_secs=${FM_RUN_BINDING_TOTAL_WAIT_SECS:-3600}
  case "$total_wait_secs" in ''|*[!0-9]*|0) total_wait_secs=3600 ;; esac
  while [ "${total_wait_secs#0}" != "$total_wait_secs" ]; do
    total_wait_secs=${total_wait_secs#0}
  done
  [ -n "$total_wait_secs" ] || total_wait_secs=3600
  case "${#total_wait_secs}" in
    1|2|3) [ "$total_wait_secs" -le 3600 ] || total_wait_secs=3600 ;;
    4) [ "$total_wait_secs" -le 3600 ] || total_wait_secs=3600 ;;
    *) total_wait_secs=3600 ;;
  esac
  total_deadline=$(( $(date +%s) + total_wait_secs ))
  while kill -0 "$child" 2>/dev/null; do
    if [ -z "$group_member_pid" ] && group_member=$(run_axi_group_member_identity "$child"); then
      IFS='|' read -r group_member_pid group_member_start <<< "$group_member"
    fi
    if run_id=$(run_id_from_output "$output_file") && [ -n "$run_id" ]; then
      startup_seen=1
    fi
    now=$(date +%s)
    if [ "$now" -ge "$total_deadline" ]; then
      run_axi_abort_child "$child" "$child_start" "$group_member_pid" "$group_member_start"
      cat "$output_file"
      rm -f "$output_file"
      return 1
    fi
    if [ "$startup_seen" = 0 ] && [ "$now" -ge "$startup_deadline" ]; then
      run_axi_abort_child "$child" "$child_start" "$group_member_pid" "$group_member_start"
      cat "$output_file"
      rm -f "$output_file"
      return 1
    fi
    sleep 0.05
  done
  if ! run_axi_stop_group "$child" "$child_start" "$group_member_pid" "$group_member_start"; then
    cat "$output_file"
    rm -f "$output_file"
    return 1
  fi
  wait "$child" || child_status=$?
  run_id=
  if ! run_id=$(run_id_from_output "$output_file") || [ -z "$run_id" ]; then
    cat "$output_file"
    rm -f "$output_file"
    return 1
  fi
  if ! publish_run_id "$run_id"; then
    cat "$output_file"
    rm -f "$output_file"
    return 1
  fi
  published=1
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
    recover_staged_binding || return 1
    run_axi "$@"
  else
    "$FM_RUN_BINDING_REAL" "$@"
  fi
}

main "$@"
