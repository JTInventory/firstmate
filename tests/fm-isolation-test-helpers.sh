fm_session_test_authority_broker_present() {
  local broker=${FM_TEST_AUTHORITY_BROKER_PID:-}
  local fd=${FM_TEST_DURABLE_AUTHORITY_FD:-} live_fd=${FM_TEST_AUTHORITY_FD:-}
  local harness=${FM_TEST_AUTHORITY_HARNESS_PID:-}
  local expected_harness expected_exec caller_target broker_target
  [ "${FM_TEST_PROCESS:-0}" = 1 ] || return 1
  case "$broker" in ''|*[!0-9]*) return 1 ;; esac
  [ "$broker" != "$$" ] || return 1
  kill -0 "$broker" 2>/dev/null || return 1
  case "$harness" in ''|*[!0-9]*) return 1 ;; esac
  [ "$harness" != "$$" ] || return 1
  kill -0 "$harness" 2>/dev/null || return 1
  expected_harness=$(cd "$_FM_SESSION_LOCK_LIB_DIR/../tests" 2>/dev/null \
    && pwd -P)/fm-test-authority-broker.sh || return 1
  expected_exec="$_FM_SESSION_LOCK_LIB_DIR/fm-session-authority-exec.sh"
  [ "${FM_TEST_AUTHORITY_HARNESS:-0}" = 1 ] || return 1
  [ "${FM_TEST_AUTHORITY_HARNESS_SCRIPT:-}" = "$expected_harness" ] || return 1
  [ "${FM_TEST_AUTHORITY_EXEC_SCRIPT:-}" = "$expected_exec" ] || return 1
  fm_session_process_runs_script "$harness" "$expected_harness" || return 1
  [ "$(fm_session_process_environment_value "$harness" \
      FM_TEST_AUTHORITY_HARNESS 2>/dev/null || true)" = 1 ] || return 1
  [ "$(fm_session_parent_pid "$broker" 2>/dev/null || true)" = "$harness" ] || return 1
  fm_session_descriptor_channel_isolated "$fd" || return 1
  caller_target=$(fm_session_descriptor_identity "$$" "$fd") || return 1
  broker_target=$(fm_session_descriptor_identity "$broker" "$fd") || return 1
  [ "$caller_target" = "$broker_target" ] || return 1
  if ! fm_session_descriptor_channel_isolated "$live_fd"; then
    case "$live_fd" in ''|*[!0-9]*) return 1 ;; esac
    eval "exec ${live_fd}<&${fd}"
  fi
  fm_session_descriptor_channel_isolated "$live_fd"
}

fm_worker_test_authority_capability_present() {
  local live_fd durable_fd key live_identity test_live_identity
  [ "${FM_TEST_PROCESS:-0}" = 1 ] || return 1
  case "${FM_AGENT_ROLE:-}" in ""|primary) ;; *) return 1 ;; esac
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_session_test_authority_broker_present || return 1
  live_fd=${FM_SESSION_AUTHORITY_FD:-${FM_TEST_AUTHORITY_FD:-}}
  durable_fd=${FM_SESSION_AUTHORITY_DURABLE_FD:-${FM_TEST_DURABLE_AUTHORITY_FD:-}}
  fm_session_descriptor_channel_isolated "$live_fd" \
    && fm_session_descriptor_channel_isolated "$durable_fd" \
    && fm_session_exec_descriptor_isolation_durable || return 1
  live_identity=$(fm_session_descriptor_identity "$$" "$live_fd" 2>/dev/null) \
    || return 1
  test_live_identity=$(fm_session_descriptor_identity "$$" "$FM_TEST_AUTHORITY_FD" \
    2>/dev/null) || return 1
  if [ "$live_identity" != "$test_live_identity" ]; then
    [ -n "${FM_SESSION_AUTHORITY_BROKER_SCRIPT:-}" ] \
      && fm_session_authority_broker_present \
        "$FM_SESSION_AUTHORITY_BROKER_SCRIPT" || return 1
  fi
  [ "$(fm_session_descriptor_identity "$$" "$durable_fd" 2>/dev/null || true)" = \
    "$(fm_session_descriptor_identity "$$" "$FM_TEST_DURABLE_AUTHORITY_FD" 2>/dev/null || true)" ] \
    || return 1
  IFS= read -r key <&"$live_fd" || return 1
  [ "${#key}" -ge 64 ] || return 1
  case "$key" in *[!0-9a-f]*) return 1 ;; esac
  IFS= read -r key <&"$durable_fd" || return 1
  [ "${#key}" -ge 64 ] || return 1
  case "$key" in *[!0-9a-f]*) return 1 ;; esac
  FM_WORKER_TEST_AUTHORITY_FD=$live_fd
  FM_WORKER_TEST_DURABLE_AUTHORITY_FD=$durable_fd
}

fm_worker_test_primary_identity_lock_acquire() {
  local broker=${FM_TEST_AUTHORITY_BROKER_PID:-} tmp lock owner attempts=0
  case "$broker" in ''|*[!0-9]*) return 1 ;; esac
  tmp=$(fm_worker_canonical_path "${TMPDIR:-/tmp}") || return 1
  [ -d "$tmp" ] && [ ! -L "$tmp" ] || return 1
  lock="$tmp/.fm-test-primary-identity-$broker.lock"
  owner=${BASHPID:-$$}
  while [ "$attempts" -lt 500 ]; do
    if mkdir "$lock" 2>/dev/null; then
      chmod 700 "$lock" \
        && printf '%s\n' "$owner" > "$lock/owner" || {
          rm -f "$lock/owner"
          rmdir "$lock" 2>/dev/null || true
          return 1
        }
      FM_WORKER_TEST_PRIMARY_IDENTITY_LOCK=$lock
      return 0
    fi
    if [ -e "$lock" ] || [ -L "$lock" ]; then
      [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
    fi
    sleep 0.01
    attempts=$((attempts + 1))
  done
  return 1
}

fm_worker_test_primary_identity_lock_release() {
  local lock=${FM_WORKER_TEST_PRIMARY_IDENTITY_LOCK:-} owner=${BASHPID:-$$}
  [ -n "$lock" ] && [ -d "$lock" ] && [ ! -L "$lock" ] \
    && [ -f "$lock/owner" ] && [ ! -L "$lock/owner" ] \
    && [ "$(cat "$lock/owner" 2>/dev/null)" = "$owner" ] || return 1
  rm -f "$lock/owner" && rmdir "$lock" || return 1
  FM_WORKER_TEST_PRIMARY_IDENTITY_LOCK=
}

fm_test_authority_live_binding_write() {
  local state=$1 pid=$2 file key digest start identity descriptor body
  file="$state/.session-authority-live"
  start=$(fm_session_process_start "$pid") || return 1
  identity=$(fm_session_process_identity "$pid") || return 1
  descriptor=$(fm_session_descriptor_identity "$pid" 9) || return 1
  IFS= read -r key <&9 || return 1
  digest=$(printf '%s\n' "$key" | sha256sum 2>/dev/null) || return 1
  digest=${digest%% *}
  body=$(printf 'version=1\npid=%s\nstart=%s\nidentity=%s\nfd=9\ndescriptor=%s\nkey-sha256=%s\n' \
    "$pid" "$start" "$identity" "$descriptor" "$digest") || return 1
  fm_session_authority_record_write "$file" "$body"
}

fm_worker_test_primary_identity_bind() {
  local root=$1 home=$2 state=${3:-$2/state} binding lock authority owner broker authority_pid
  local binding_tmp lock_tmp authority_tmp
  binding="$state/.primary-checkout"
  lock="$state/.lock"
  authority="$state/.session-authority"
  broker=${FM_TEST_AUTHORITY_BROKER_PID:-}
  case "$broker" in ''|*[!0-9]*) return 1 ;; esac
  authority_pid=${FM_TEST_PRIMARY_AUTHORITY_PID:-$broker}
  case "$authority_pid" in ''|*[!0-9]*) return 1 ;; esac
  owner=${FM_TEST_AUTHORITY_OWNER_PID:-$$}
  if [ -e "$binding" ] || [ -L "$binding" ] \
    || [ -e "$lock" ] || [ -L "$lock" ] \
    || [ -e "$authority" ] || [ -L "$authority" ]; then
    if [ -f "$binding" ] && [ ! -L "$binding" ] \
      && [ "$(cat "$binding" 2>/dev/null)" = "$root" ] \
      && [ -f "$lock" ] && [ ! -L "$lock" ] \
      && [ "$(cat "$lock" 2>/dev/null)" = "$owner" ] \
      && fm_session_authority_read "$authority" \
      && { [ "$FM_SESSION_AUTHORITY_PID" = "$authority_pid" ] \
        || fm_session_authority_is_current_ancestor "$authority"; } \
      && [ "$FM_SESSION_AUTHORITY_OWNER" = "$owner" ] \
      && [ "$FM_SESSION_AUTHORITY_HOME" = "$home" ] \
      && [ "$FM_SESSION_AUTHORITY_CHECKOUT" = "$root" ]; then
      if [ ! -f "$state/.session-authority-live" ] \
        || ! fm_session_authority_record_validate \
          "$state/.session-authority-live" 8; then
        fm_test_authority_live_binding_write "$state" "$authority_pid" || return 1
      fi
      return 0
    fi
    return 1
  fi
  mkdir -p "$state" && [ -d "$state" ] && [ ! -L "$state" ] || return 1
  binding_tmp=$(command -p mktemp "$state/.primary-checkout.XXXXXX") || return 1
  lock_tmp=$(command -p mktemp "$state/.lock.XXXXXX") || {
    rm -f "$binding_tmp"
    return 1
  }
  authority_tmp=$(command -p mktemp "$state/.session-authority.XXXXXX") || {
    rm -f "$binding_tmp" "$lock_tmp"
    return 1
  }
  chmod 600 "$binding_tmp" "$lock_tmp" "$authority_tmp" \
    && printf '%s\n' "$root" > "$binding_tmp" \
    && printf '%s\n' "$owner" > "$lock_tmp" \
    && fm_session_authority_write_file \
      "$authority_tmp" "$authority_pid" "$owner" "$home" "$root" \
    && mv "$binding_tmp" "$binding" \
    && mv "$lock_tmp" "$lock" \
    && mv "$authority_tmp" "$authority" \
    && fm_test_authority_live_binding_write "$state" "$authority_pid" || {
      rm -f "$binding_tmp" "$lock_tmp" "$authority_tmp"
      return 1
    }
}
