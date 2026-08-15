#!/usr/bin/env bash
# Focused behavior tests for inactive terminal-outcome replay.
set -u

# A crewmate's inherited environment is deliberately refused by the production
# helper. Re-exec the behavior suite once with a clean parent ancestry so its
# throwaway firstmate homes exercise the primary-only path.
if [ "${FM_INACTIVE_TEST_CLEAN:-0}" != 1 ]; then
  exec env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
    -u FM_PRIMARY_ATTESTATION FM_INACTIVE_TEST_CLEAN=1 /bin/bash "$0" "$@"
fi

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECON="$ROOT/bin/fm-inactive-reconcile.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-inactive-outcome)
trap fm_test_cleanup EXIT
CASE_DIR=
CASE_ROOT=
CASE_HOME=
CASE_FAKEBIN=
CASE_THREAD=
CASE_TOKEN=

new_case() {
  local name=$1 dir root home state fakebin
  dir="$TMP_ROOT/$name"
  root="$dir/root"
  home="$dir/home"
  state="$home/state"
  fakebin="$dir/fakebin"
  mkdir -p "$state" "$home/data" "$home/config" "$fakebin"
  git init -q -b main "$root"
  git -C "$root" commit -q --allow-empty -m init
  cp "$ROOT/AGENTS.md" "$root/AGENTS.md"
  mkdir -p "$root/bin" "$home/projects"
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
if [ "${FM_FAKE_CREW_STATE_SIGNAL:-0}" = 1 ]; then
  kill -TERM $$
fi
if [ "${FM_FAKE_CREW_STATE_EXIT:-0}" != 0 ]; then
  exit "$FM_FAKE_CREW_STATE_EXIT"
fi
key=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '_' | tr '[:lower:]' '[:upper:]')
var="FM_FAKE_CREW_STATE_$key"
printf '%s\n' "${!var:-${FM_FAKE_CREW_STATE:-state: unknown · source: none · fake default}}"
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *capture-pane*)
    case "$*" in
      *" -S -40"*) printf '%s\n' "${FM_FAKE_TMUX_CAPTURE:-idle prompt}" ;;
      *) : ;;
    esac
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
case "$*" in
  *"lstart="*|*"command="*) exec /usr/bin/ps "$@" ;;
  *"comm="*|*"args="*)
    if [ "$pid" = "${FM_FAKE_HARNESS_PID:-}" ]; then
      printf '%s\n' claude
    else
      printf '%s\n' bash
    fi
    ;;
  *"ppid="*) printf '%s\n' "${FM_FAKE_HARNESS_PID:-1}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  for tool in gh gh-axi curl; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_NETWORK_LOG:-}" ] || printf '%s %s\n' "$(basename "$0")" "$*" >> "$FM_NETWORK_LOG"
exit 97
SH
    chmod +x "$fakebin/$tool"
  done
  CASE_DIR=$dir
  CASE_ROOT=$root
  CASE_HOME=$home
  CASE_FAKEBIN=$fakebin
  CASE_THREAD="inactive-${name//[^A-Za-z0-9]/-}"
}

set_old_mtime() {
  if touch -d '2 minutes ago' "$@" 2>/dev/null; then
    return 0
  fi
  touch -t "$(date -v-2M '+%Y%m%d%H%M.%S')" "$@"
}

replace_field() {
  local file=$1 key=$2 value=$3 tmp
  tmp=$(mktemp "$file.edit.XXXXXX") || return 1
  awk -F= -v wanted="$key" -v replacement="$value" '
    $1 == wanted { print wanted "=" replacement; found=1; next }
    { print }
    END { if (!found) print wanted "=" replacement }
  ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$file"
}

direct_file_count() {
  local dir=$1 pattern=$2 file base count=0
  for file in "$dir"/*; do
    [ -f "$file" ] || continue
    base=${file##*/}
    case "$base" in $pattern) count=$((count + 1)) ;; esac
  done
  printf '%s' "$count"
}

direct_first_file() {
  local dir=$1 pattern=$2 file base
  for file in "$dir"/*; do
    [ -f "$file" ] || continue
    base=${file##*/}
    case "$base" in
      $pattern) printf '%s' "$file"; return 0 ;;
    esac
  done
  return 1
}

prepare_primary_proof() {
  local root=$1 home=$2 fakebin=$3 state="$home/state" token
  mkdir -p "$state" "$home/projects"
  if [ ! -f "$state/.primary-attestation" ]; then
    ( cd "$root" && env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
        -u FM_PRIMARY_ATTESTATION -u FM_ROOT -u STATE \
        FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$state" \
        CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" PATH="$fakebin:$PATH" \
        bash -c '. "$1"; fm_worker_primary_attestation_prepare' _ \
        "$ROOT/bin/fm-worker-isolation-lib.sh" ) || fail "primary proof setup failed"
  fi
  token=$(awk -F= '$1 == "token" {print substr($0, index($0, "=") + 1); exit}' \
    "$state/.primary-attestation")
  [ -n "$token" ] || fail "primary proof token was not persisted"
  printf '%s|codex:%s|fallback\n' "$$" "$CASE_THREAD" > "$state/.lock"
  CASE_TOKEN=$token
}

prepare_watcher_protocol() {
  local root=$1 home=$2 state=$3 pid_start pid_identity watch arm
  watch="$root/bin/fm-watch.sh"
  arm="$root/bin/fm-watch-arm.sh"
  pid_start=$(FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_start "$2"' _ "$ROOT" "$$")
  pid_identity=$(FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$$")
  mkdir -p "$state/.watch.lock" "$state/.watch-arm.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$watch" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$pid_start" > "$state/.watch.lock/pid-start"
  printf '%s\n' "$pid_identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' pending-reply-ticket-v3 > "$state/.watch.lock/pending-reply-protocol"
  printf '%s\n' "$$" > "$state/.watch-arm.lock/pid"
  printf '%s\n' "$home" > "$state/.watch-arm.lock/fm-home"
  printf '%s\n' "$arm" > "$state/.watch-arm.lock/owner-path"
  printf '%s\n' "$pid_start" > "$state/.watch-arm.lock/pid-start"
  printf '%s\n' "$pid_identity" > "$state/.watch-arm.lock/pid-identity"
}

scan() {
  local root=$1 home=$2 fakebin=$3 startup=${4:-}
  if [ -d "$home/state" ] && [ ! -L "$home/state" ]; then
    prepare_primary_proof "$root" "$home" "$fakebin"
  fi
  ( cd "$root" && env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
      -u FM_ROOT -u STATE PATH="$fakebin:$PATH" \
      FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      FM_PRIMARY_ATTESTATION="$CASE_TOKEN" CODEX_THREAD_ID="$CASE_THREAD" \
      FM_FAKE_HARNESS_PID="$$" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_INACTIVE_OUTCOME_SECS="${FM_INACTIVE_OUTCOME_SECS:-60}" \
      FM_INACTIVE_OUTCOME_BUDGET_SECS="${FM_INACTIVE_OUTCOME_BUDGET_SECS:-10}" \
      "$RECON" scan "$startup" )
}

drain() {
  local root=$1 home=$2 fakebin=$3 status generation=${FM_WAKE_DRAIN_GENERATION:-$$}
  [ "${4:-}" = no-generation ] && generation=
  if [ -d "$home/state" ] && [ ! -L "$home/state" ]; then
    prepare_primary_proof "$root" "$home" "$fakebin"
  fi
  ( cd "$root" && env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
      -u FM_ROOT -u STATE PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
      CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" \
      FM_WAKE_DRAIN_DEFER_ACK="${FM_WAKE_DRAIN_DEFER_ACK:-0}" \
      FM_WAKE_DRAIN_GENERATION="$generation" "$DRAIN" )
  status=$?
  [ "$status" = 0 ] || [ "$status" = 3 ] || return "$status"
}

recon_from_root() {
  local root=$1 fakebin=$2 home=$3 state=$4 previous=$PWD status
  shift 4
  cd "$root" || return 1
  env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
    -u FM_ROOT -u STATE PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" "$RECON" "$@"
  status=$?
  cd "$previous" || return 1
  return "$status"
}

write_meta() {
  local state=$1 id=$2 token=$3 kind=${4:-ship} backend=${5:-tmux} window
  window=${6:-tmux:fm-$id}
  local file="$state/$id.meta"
  fm_write_meta "$file" \
    "window=$window" "worktree=$state/work-$id" "project=$state/work-$id" \
    "harness=echo" "kind=$kind" "mode=$kind" "yolo=off" \
    "backend=$backend" "spawn_incarnation=$token"
  mkdir -p "$state/work-$id"
  printf 'working: fixture\n' > "$state/$id.status"
  : > "$state/$id.turn-ended"
  set_old_mtime "$file" "$state/$id.status" "$state/$id.turn-ended"
  case "$kind" in ship|scout) write_idle_proof "$state" "$id" "$backend" "$window" ;; esac
}

write_legacy_meta() {
  local state=$1 id=$2 kind=${3:-ship} backend=${4:-tmux} window
  window="tmux:fm-$id"
  fm_write_meta "$state/$id.meta" \
    "window=$window" "worktree=$state/work-$id" "project=$state/work-$id" \
    "harness=echo" "kind=$kind" "mode=$kind" "yolo=off" "backend=$backend"
  mkdir -p "$state/work-$id"
  printf 'working: fixture\n' > "$state/$id.status"
  : > "$state/$id.turn-ended"
  set_old_mtime "$state/$id.meta" "$state/$id.status" "$state/$id.turn-ended"
  write_idle_proof "$state" "$id" "$backend" "$window"
}

write_idle_proof() {
  local state=$1 id=$2 backend=$3 window=$4 hash
  if command -v md5 >/dev/null 2>&1; then
    hash=$(printf '%s' 'idle prompt' | md5 -q)
  else
    hash=$(printf '%s' 'idle prompt' | md5sum | awk '{print $1}')
  fi
  mkdir -p "$state/.pane-idle"
  printf '%s\n' "$hash" > "$state/.hash-$(printf '%s' "$window" | tr ':/.' '___')"
  printf '2\n' > "$state/.count-$(printf '%s' "$window" | tr ':/.' '___')"
  ( cd "$ROOT" && env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
      FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$CASE_HOME" FM_STATE_OVERRIDE="$state" \
      bash -c '. "$1/bin/fm-pane-idle-lib.sh"; fm_pane_idle_write "$2" "$3" "$4" "$5" "$6" "$7" "$8"' _ \
      "$ROOT" "$state" "$state/$id.meta" "$id" "$window" "$backend" "$hash" 2 ) \
    || fail "idle proof fixture could not be written"
}

receipt_value() {
  local file=$1 key=$2
  awk -F= -v wanted="$key" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' "$file"
}

receipt_fingerprint() {
  local value=$1 kind=${2:-ship}
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value|$kind" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$value|$kind" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

receipt_count() {
  local state=$1 suffix=$2
  direct_file_count "$state/terminal-outcomes" "*.$suffix"
}

queue_count() {
  local state=$1
  [ -f "$state/.wake-queue" ] || { printf '0'; return 0; }
  awk -F '\t' '$3 == "check" && $4 ~ /^inactive-outcome:/ { n++ } END { print n + 0 }' \
    "$state/.wake-queue" 2>/dev/null
}

test_done_and_failed_are_replayed_once() {
  local dir root home fakebin state rec task fingerprint drain_output
  new_case done-failed
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" done-x1 inc-done
  write_meta "$state" failed-x1 inc-failed
  export FM_FAKE_CREW_STATE_DONE_X1='state: done · source: pane · pane is quiet'
  export FM_FAKE_CREW_STATE_FAILED_X1='state: failed · source: run-step · checks failed'
  scan "$root" "$home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$state" pending)" = 2 ] || fail "done and failed outcomes did not create two pending receipts"
  [ "$(queue_count "$state")" = 2 ] || fail "done and failed outcomes did not create two wakes"
  for rec in "$state"/terminal-outcomes/*.pending; do
    task=$(receipt_value "$rec" task_id)
    fingerprint=$(basename "$rec" .pending)
    [ "$(receipt_value "$rec" schema)" = fm-jt-terminal-outcome.v1 ] || fail "receipt schema was not durable"
    [ "$(receipt_value "$rec" fingerprint)" = "$fingerprint" ] || fail "receipt fingerprint did not bind its filename"
    case "$task" in
      done-x1)
        [ "$(receipt_value "$rec" incarnation)" = inc-done ] || fail "done receipt used the wrong incarnation"
        [ "$(receipt_value "$rec" outcome)" = done ] || fail "done receipt outcome was incorrect"
        [ "$(receipt_value "$rec" terminal_snapshot)" = 'state: done · source: pane · pane is quiet' ] || fail "done receipt snapshot was not exact"
        [ "$fingerprint" = "$(receipt_fingerprint 'done-x1|inc-done|done|state: done · source: pane · pane is quiet')" ] || fail "done receipt fingerprint was not bound to its fields"
        ;;
      failed-x1)
        [ "$(receipt_value "$rec" incarnation)" = inc-failed ] || fail "failed receipt used the wrong incarnation"
        [ "$(receipt_value "$rec" outcome)" = failed ] || fail "failed receipt outcome was incorrect"
        [ "$(receipt_value "$rec" terminal_snapshot)" = 'state: failed · source: run-step · checks failed' ] || fail "failed receipt snapshot was not exact"
        [ "$fingerprint" = "$(receipt_fingerprint 'failed-x1|inc-failed|failed|state: failed · source: run-step · checks failed')" ] || fail "failed receipt fingerprint was not bound to its fields"
        ;;
      *) fail "receipt persisted an unexpected task id: $task" ;;
    esac
    [ "$(receipt_value "$rec" terminal_source)" != "" ] || fail "receipt lost terminal source"
    [ "$(receipt_value "$rec" terminal_snapshot)" != "" ] || fail "receipt lost terminal snapshot"
    [ "$(receipt_value "$rec" parent_home)" = "" ] || fail "firstmate receipt invented a parent route"
  done
  rec=$(direct_first_file "$state/terminal-outcomes" '*.pending')
  fingerprint=$(basename "$rec" .pending)
  if ( cd "$root" && env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
      -u FM_ROOT -u STATE PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$state" FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
      CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" \
      "$RECON" ack "inactive-outcome:$fingerprint" >/dev/null 2>&1 ); then
    fail "direct inactive acknowledgement bypassed the wake drain"
  fi
  [ -f "$rec" ] || fail "direct inactive acknowledgement removed its pending receipt"
  set_old_mtime "$state/.inactive-outcome-reconcile"
  scan "$root" "$home" "$fakebin" >/dev/null || fail "normal watcher cadence scan failed"
  scan "$root" "$home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$state" pending)" = 2 ] || fail "rescan duplicated inactive outcome receipts"
  [ "$(queue_count "$state")" = 2 ] || fail "rescan duplicated inactive outcome wakes"
  drain_output="$dir/drain.out"
  drain "$root" "$home" "$fakebin" >"$drain_output" \
    || fail "drain did not present done and failed outcomes"
  grep -F 'inactive-outcome:' "$drain_output" >/dev/null \
    || fail "drain did not emit the inactive outcome wake"
  grep -F 'task=done-x1' "$drain_output" >/dev/null \
    || fail "drain output omitted the done outcome"
  grep -F 'task=failed-x1' "$drain_output" >/dev/null \
    || fail "drain output omitted the failed outcome"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "drain did not acknowledge pending receipts"
  [ "$(receipt_count "$state" presented)" = 2 ] || fail "drain did not preserve two presented receipts"
  scan "$root" "$home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$state" presented)" = 2 ] || fail "presented receipts were replayed"
  [ "$(queue_count "$state")" = 0 ] || fail "presented receipts caused a duplicate wake on rescan"
  unset FM_FAKE_CREW_STATE_DONE_X1 FM_FAKE_CREW_STATE_FAILED_X1
  pass "done and failed inactive outcomes are replayed once and acknowledged on drain"
}

test_portable_timeout_runner_is_used() {
  local dir root home fakebin state timeout_log
  new_case portable-timeout
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  timeout_log="$dir/timeout.log"
  write_meta "$state" portable-x1 portable-inc
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TIMEOUT_LOG:?}"
[ "${1:-}" != --foreground ] || exit 91
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  export FM_FAKE_CREW_STATE_PORTABLE_X1='state: done · source: pane · portable timeout' FM_TIMEOUT_LOG="$timeout_log"
  scan "$root" "$home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "portable timeout runner did not reconcile the child"
  [ -s "$timeout_log" ] || fail "portable timeout command was not invoked"
  grep -F 'portable-x1' "$timeout_log" >/dev/null || fail "portable timeout runner did not receive the child command"
  export FM_INACTIVE_OUTCOME_FORCE_PORTABLE_TIMEOUT=1
  export FM_FAKE_CREW_STATE_EXIT=7
  if scan "$root" "$home" "$fakebin" --startup >/dev/null 2>&1; then
    fail "portable timeout runner hid a non-zero child status"
  fi
  unset FM_FAKE_CREW_STATE_PORTABLE_X1 FM_FAKE_CREW_STATE_EXIT FM_INACTIVE_OUTCOME_FORCE_PORTABLE_TIMEOUT FM_TIMEOUT_LOG
  pass "inactive scan uses the portable timeout invocation"
}

test_portable_timeout_preserves_signal_failure() {
  local dir root home fakebin state
  new_case portable-timeout-signal
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" signal-x1 signal-inc
  export FM_FAKE_CREW_STATE_SIGNAL=1 FM_INACTIVE_OUTCOME_FORCE_PORTABLE_TIMEOUT=1
  if scan "$root" "$home" "$fakebin" --startup >/dev/null 2>&1; then
    fail "portable timeout runner converted a signal failure into success"
  fi
  [ ! -e "$state/.inactive-outcome-reconcile" ] || fail "signal failure advanced the cadence marker"
  unset FM_FAKE_CREW_STATE_SIGNAL FM_INACTIVE_OUTCOME_FORCE_PORTABLE_TIMEOUT
  pass "portable timeout preserves signal failures"
}

test_portable_timeout_expires_child() {
  local dir root home fakebin state
  new_case portable-timeout-expiry
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" expiry-x1 expiry-inc
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
sleep 2
printf 'state: done · source: pane · should time out\n'
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  export FM_INACTIVE_OUTCOME_FORCE_PORTABLE_TIMEOUT=1 FM_INACTIVE_OUTCOME_BUDGET_SECS=1
  scan "$root" "$home" "$fakebin" --startup >/dev/null 2>&1 \
    || fail "portable timeout fallback killed the watcher"
  [ ! -e "$state/.inactive-outcome-reconcile" ] || fail "portable timeout expiry advanced the cadence marker"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "portable timeout expiry created a receipt"
  unset FM_INACTIVE_OUTCOME_FORCE_PORTABLE_TIMEOUT FM_INACTIVE_OUTCOME_BUDGET_SECS
  pass "portable timeout fallback propagates child expiry"
}

test_leading_zero_cadence_is_normalized() {
  local dir root home fakebin state
  new_case leading-zero-cadence
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" zero-x1 zero-inc
  export FM_FAKE_CREW_STATE_ZERO_X1='state: done · source: pane · leading zero'
  export FM_INACTIVE_OUTCOME_SECS=0080 FM_INACTIVE_OUTCOME_BUDGET_SECS=0010 FM_INACTIVE_OUTCOME_LOCK_WAIT_SECS=008
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "leading-zero cadence aborted the scan"
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "leading-zero cadence did not reconcile the child"
  unset FM_FAKE_CREW_STATE_ZERO_X1 FM_INACTIVE_OUTCOME_SECS FM_INACTIVE_OUTCOME_BUDGET_SECS FM_INACTIVE_OUTCOME_LOCK_WAIT_SECS
  pass "leading-zero cadence values are normalized before arithmetic"
}

test_oversized_cadence_is_clamped() {
  local dir root home fakebin state
  new_case oversized-cadence
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" oversized-x1 oversized-inc
  export FM_FAKE_CREW_STATE_OVERSIZED_X1='state: done · source: pane · oversized cadence'
  export FM_INACTIVE_OUTCOME_SECS=999999999999999999999999999999999999
  touch -t 200001010000 "$state/oversized-x1.meta" "$state/oversized-x1.status" \
    "$state/oversized-x1.turn-ended" || fail "could not age the oversized cadence fixture"
  touch -t 200001010000 "$state/.inactive-outcome-reconcile" \
    || fail "could not age the cadence marker"
  scan "$root" "$home" "$fakebin" >/dev/null \
    || fail "oversized cadence value prevented reconciliation"
  [ "$(receipt_count "$state" pending)" = 1 ] \
    || fail "oversized cadence value was not clamped before arithmetic"
  unset FM_FAKE_CREW_STATE_OVERSIZED_X1 FM_INACTIVE_OUTCOME_SECS
  pass "oversized decimal cadence values clamp before arithmetic"
}

test_find_failure_propagates_without_advancing_scan() {
  local dir root home fakebin state
  new_case find-failure
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" find-x1 find-inc
  cat > "$fakebin/find" <<'SH'
#!/usr/bin/env bash
exit 42
SH
  chmod +x "$fakebin/find"
  if scan "$root" "$home" "$fakebin" --startup >/dev/null 2>&1; then
    fail "find enumeration failure was reported as success"
  fi
  [ ! -e "$state/.inactive-outcome-reconcile" ] || fail "find failure advanced the cadence marker"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "find failure created a receipt"
  pass "find enumeration failures propagate and preserve retry state"
}

test_find_enumeration_respects_scan_budget() {
  local dir root home fakebin state find_log
  new_case find-budget
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  find_log="$dir/find.log"
  write_meta "$state" find-budget-x1 find-budget-inc
  cat > "$fakebin/find" <<'SH'
#!/usr/bin/env bash
: > "${FM_FIND_LOG:?}"
sleep 3
exit 0
SH
  chmod +x "$fakebin/find"
  export FM_INACTIVE_OUTCOME_BUDGET_SECS=2 FM_FIND_LOG="$find_log"
  scan "$root" "$home" "$fakebin" --startup >/dev/null 2>&1 \
    || fail "slow find enumeration terminated supervision instead of deferring"
  [ ! -e "$state/.inactive-outcome-reconcile" ] || fail "budget-exhausted enumeration advanced the cadence marker"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "budget-exhausted enumeration created a receipt"
  [ -e "$find_log" ] || fail "bounded scan did not invoke the find child"
  unset FM_INACTIVE_OUTCOME_BUDGET_SECS FM_FIND_LOG
  pass "inactive enumeration is bounded by the per-scan budget"
}

test_minimum_budget_preserves_direct_scan() {
  local dir root home fakebin state
  new_case minimum-direct-scan
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" minimum-x1 minimum-inc
  cat > "$fakebin/find" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$1/minimum-x1.meta"
SH
  chmod +x "$fakebin/find"
  export FM_FAKE_CREW_STATE_MINIMUM_X1='state: done · source: pane · minimum direct scan'
  export FM_INACTIVE_OUTCOME_BUDGET_SECS=1
  scan "$root" "$home" "$fakebin" --startup >/dev/null \
    || fail "minimum scan budget skipped the direct child scan"
  [ "$(receipt_count "$state" pending)" = 1 ] \
    || fail "minimum scan budget did not reconcile the direct child"
  unset FM_FAKE_CREW_STATE_MINIMUM_X1 FM_INACTIVE_OUTCOME_BUDGET_SECS
  pass "minimum scan budget preserves the direct child scan"
}

test_ack_recomputes_fingerprint_from_receipt_fields() {
  local dir root home fakebin state rec fingerprint field tampered
  for field in task_id incarnation outcome terminal_snapshot kind; do
    new_case "fingerprint-binding-$field"
    dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
    state="$home/state"
    write_meta "$state" fingerprint-x1 fingerprint-inc
    export FM_FAKE_CREW_STATE_FINGERPRINT_X1='state: done · source: pane · original snapshot'
    scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "fingerprint fixture scan failed for $field"
    rec=$(direct_first_file "$state/terminal-outcomes" '*.pending')
    fingerprint=$(basename "$rec" .pending)
    case "$field" in
      task_id) tampered=tampered-x1 ;;
      incarnation) tampered=tampered-inc ;;
      outcome) tampered=failed ;;
      terminal_snapshot) tampered='tampered snapshot' ;;
      kind) tampered=secondmate ;;
    esac
    replace_field "$rec" "$field" "$tampered"
    if drain "$root" "$home" "$fakebin" >/dev/null 2>&1; then
      fail "drain accepted a receipt whose $field no longer matched its fingerprint"
    fi
    [ -f "$rec" ] || fail "$field fingerprint mismatch removed the pending receipt"
    [ "$(queue_count "$state")" = 1 ] || fail "$field fingerprint mismatch did not preserve the wake for retry"
    [ "$(receipt_value "$rec" fingerprint)" = "$fingerprint" ] || fail "$field fixture changed its filename binding"
    unset FM_FAKE_CREW_STATE_FINGERPRINT_X1
  done
  pass "drain recomputes the receipt fingerprint from bound fields"
}

test_reserved_claim_recovers_to_a_new_wake_row() {
  local dir root home fakebin state fingerprint old_row new_row
  new_case claim-recovery
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  fingerprint=$(receipt_fingerprint 'claim-x1|claim-inc|done|state: done · source: pane · claim recovery')
  mkdir -p "$state/terminal-outcomes"
  fm_write_meta "$state/terminal-outcomes/$fingerprint.pending" \
    schema=fm-jt-terminal-outcome.v1 fingerprint="$fingerprint" task_id=claim-x1 \
    incarnation=claim-inc outcome=done terminal_source=pane \
    terminal_snapshot='state: done · source: pane · claim recovery' kind=ship
  old_row='1	1	check	inactive-outcome:'"$fingerprint"$'\told row'
  new_row='2	2	check	inactive-outcome:'"$fingerprint"$'\tnew row'
  printf 'schema=fm-inactive-outcome-claim.v1\nfingerprint=%s\nrow=%s\nstate=reserved\ncreated_epoch=1\n' \
    "$fingerprint" "$old_row" > "$state/terminal-outcomes/.$fingerprint.claim"
  printf '%s\n' "$new_row" > "$state/.wake-queue"
  drain "$root" "$home" "$fakebin" >/dev/null || fail "drain did not recover a reserved claim"
  [ -e "$state/terminal-outcomes/$fingerprint.presented" ] || fail "recovered claim did not present its receipt"
  [ ! -e "$state/terminal-outcomes/.$fingerprint.claim" ] || fail "recovered claim was not retired"
  pass "reserved inactive claims recover when the wake row is recreated"
}

test_presenting_claim_recovers_before_output() {
  local dir root home fakebin state fingerprint row
  new_case presenting-claim-recovery
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  fingerprint=$(receipt_fingerprint 'presenting-x1|presenting-inc|done|state: done · source: pane · presenting recovery')
  mkdir -p "$state/terminal-outcomes"
  fm_write_meta "$state/terminal-outcomes/$fingerprint.pending" \
    schema=fm-jt-terminal-outcome.v1 fingerprint="$fingerprint" task_id=presenting-x1 \
    incarnation=presenting-inc outcome=done terminal_source=pane \
    terminal_snapshot='state: done · source: pane · presenting recovery' kind=ship
  row='2	2	check	inactive-outcome:'"$fingerprint"$'\trecreated row'
  printf 'schema=fm-inactive-outcome-claim.v1\nfingerprint=%s\nrow=1\t1\tcheck\tinactive-outcome:%s\told row\nstate=presenting\ncreated_epoch=1\n' \
    "$fingerprint" "$fingerprint" > "$state/terminal-outcomes/.$fingerprint.claim"
  printf '%s\n' "$row" > "$state/.wake-queue"
  drain "$root" "$home" "$fakebin" >"$dir/presenting.out" \
    || fail "drain did not recover a presenting claim"
  grep -F 'recreated row' "$dir/presenting.out" >/dev/null \
    || fail "recovered presenting claim did not present the recreated wake"
  [ -e "$state/terminal-outcomes/$fingerprint.presented" ] || fail "recovered presenting claim did not present its receipt"
  [ ! -e "$state/terminal-outcomes/.$fingerprint.claim" ] || fail "recovered presenting claim was not retired"
  pass "presenting inactive claims recover before output"
}

test_output_started_claim_is_not_reprinted() {
  local dir root home fakebin state fingerprint row
  new_case output-started-claim
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  fingerprint=$(receipt_fingerprint 'output-started-x1|output-started-inc|done|state: done · source: pane · output started')
  mkdir -p "$state/terminal-outcomes"
  fm_write_meta "$state/terminal-outcomes/$fingerprint.pending" \
    schema=fm-jt-terminal-outcome.v1 fingerprint="$fingerprint" task_id=output-started-x1 \
    incarnation=output-started-inc outcome=done terminal_source=pane \
    terminal_snapshot='state: done · source: pane · output started' kind=ship
  row='2	2	check	inactive-outcome:'"$fingerprint"$'\tpost-output row'
  printf 'schema=fm-inactive-outcome-claim.v1\nfingerprint=%s\nrow=1\t1\tcheck\tinactive-outcome:%s\told row\nstate=presenting\noutput_started=1\noutput_complete=1\ncreated_epoch=1\n' \
    "$fingerprint" "$fingerprint" > "$state/terminal-outcomes/.$fingerprint.claim"
  printf '%s\n' "$row" > "$state/.wake-queue"
  drain "$root" "$home" "$fakebin" >"$dir/output-started.out" \
    || fail "drain did not recover an output-started claim"
  [ ! -s "$dir/output-started.out" ] || fail "output-started claim was printed a second time"
  [ "$(queue_count "$state")" = 1 ] || fail "output-started claim lost its retry wake"
  [ -e "$state/terminal-outcomes/.$fingerprint.claim" ] || fail "output-started claim was discarded"
  [ ! -e "$state/terminal-outcomes/$fingerprint.presented" ] || fail "output-started claim finalized without confirmation"
  pass "output-started inactive claims fail closed after a drain crash"
}

test_uncertain_output_claim_fails_closed() {
  local dir root home fakebin state fingerprint row
  new_case uncertain-output-claim
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  fingerprint=$(receipt_fingerprint 'uncertain-output-x1|uncertain-output-inc|done|state: done · source: pane · uncertain output')
  mkdir -p "$state/terminal-outcomes"
  fm_write_meta "$state/terminal-outcomes/$fingerprint.pending" \
    schema=fm-jt-terminal-outcome.v1 fingerprint="$fingerprint" task_id=uncertain-output-x1 \
    incarnation=uncertain-output-inc outcome=done terminal_source=pane \
    terminal_snapshot='state: done · source: pane · uncertain output' kind=ship
  row=$'2\t2\tcheck\tinactive-outcome:'"$fingerprint"$'\tuncertain output row'
  printf 'schema=fm-inactive-outcome-claim.v1\nfingerprint=%s\nrow=%s\nstate=presenting\noutput_started=1\noutput_emitted=1\noutput_complete=0\noutput_confirmed=0\ncreated_epoch=1\n' \
    "$fingerprint" "$row" > "$state/terminal-outcomes/.$fingerprint.claim"
  printf '%s\n' "$row" > "$state/.wake-queue"
  drain "$root" "$home" "$fakebin" >"$dir/uncertain-output.out" \
    || fail "uncertain output claim drain failed"
  [ ! -s "$dir/uncertain-output.out" ] || fail "uncertain output claim was reprinted"
  [ "$(queue_count "$state")" = 1 ] || fail "uncertain output claim lost its retry wake"
  [ -e "$state/terminal-outcomes/.$fingerprint.claim" ] || fail "uncertain output claim was discarded"
  [ "$(receipt_value "$state/terminal-outcomes/.$fingerprint.claim" output_confirmed)" = 0 ] \
    || fail "uncertain output claim was finalized without caller-visible confirmation"
  [ ! -e "$state/terminal-outcomes/$fingerprint.presented" ] \
    || fail "uncertain output claim was acknowledged"
  pass "uncertain output claims fail closed without reprinting"
}

test_presented_claim_is_acknowledged_in_deferred_drain() {
  local dir root home fakebin state fingerprint row
  new_case presented-claim-ack
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  fingerprint=$(receipt_fingerprint 'presented-x1|presented-inc|done|state: done · source: pane · presented claim')
  mkdir -p "$state/terminal-outcomes"
  fm_write_meta "$state/terminal-outcomes/$fingerprint.pending" \
    schema=fm-jt-terminal-outcome.v1 fingerprint="$fingerprint" task_id=presented-x1 \
    incarnation=presented-inc outcome=done terminal_source=pane \
    terminal_snapshot='state: done · source: pane · presented claim' kind=ship
  row=$'2\t2\tcheck\tinactive-outcome:'"$fingerprint"$'\tpresented claim row'
  printf 'schema=fm-inactive-outcome-claim.v1\nfingerprint=%s\nrow=%s\nstate=presented\noutput_started=1\noutput_complete=1\ndefer_ack=0\ncreated_epoch=1\n' \
    "$fingerprint" "$row" > "$state/terminal-outcomes/.$fingerprint.claim"
  printf '%s\n' "$row" > "$state/.wake-queue"
  if FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$$" \
    drain "$root" "$home" "$fakebin" >"$dir/presented-claim.out"; then
    fail "deferred drain accepted an incomplete presented claim"
  fi
  [ ! -s "$dir/presented-claim.out" ] || fail "deferred drain re-presented a completed claim"
  [ "$(queue_count "$state")" = 1 ] || fail "deferred drain consumed an incomplete presented claim"
  [ -e "$state/terminal-outcomes/.$fingerprint.claim" ] \
    || fail "deferred drain discarded an incomplete presented claim"
  [ ! -e "$state/terminal-outcomes/$fingerprint.reported" ] \
    || fail "deferred drain reported an incomplete presented claim"
  pass "deferred drains fail closed on incomplete presented claims"
}

test_pre_output_claim_retries_after_crash() {
  local dir root home fakebin state fingerprint row
  new_case pre-output-claim
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  fingerprint=$(receipt_fingerprint 'pre-output-x1|pre-output-inc|done|state: done · source: pane · pre-output')
  mkdir -p "$state/terminal-outcomes"
  fm_write_meta "$state/terminal-outcomes/$fingerprint.pending" \
    schema=fm-jt-terminal-outcome.v1 fingerprint="$fingerprint" task_id=pre-output-x1 \
    incarnation=pre-output-inc outcome=done terminal_source=pane \
    terminal_snapshot='state: done · source: pane · pre-output' kind=ship
  row=$'2\t2\tcheck\tinactive-outcome:'"$fingerprint"$'\tpre-output row'
  printf 'schema=fm-inactive-outcome-claim.v1\nfingerprint=%s\nrow=%s\nstate=presenting\noutput_started=1\ncreated_epoch=1\n' \
    "$fingerprint" "$row" > "$state/terminal-outcomes/.$fingerprint.claim"
  printf '%s\n' "$row" > "$state/.wake-queue"
  drain "$root" "$home" "$fakebin" >"$dir/pre-output.out" \
    || fail "pre-output claim did not recover"
  grep -F 'pre-output row' "$dir/pre-output.out" >/dev/null \
    || fail "pre-output claim was suppressed before successful emission"
  [ -e "$state/terminal-outcomes/$fingerprint.presented" ] \
    || fail "pre-output retry did not finalize the receipt"
  pass "pre-output claims retry until emission completes"
}

test_output_completion_failure_does_not_reprint() {
  local dir root home fakebin state fingerprint row
  new_case output-completion-failure
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  fingerprint=$(receipt_fingerprint 'output-failure-x1|output-failure-inc|done|state: done · source: pane · output failure' )
  mkdir -p "$state/terminal-outcomes"
  fm_write_meta "$state/terminal-outcomes/$fingerprint.pending" \
    schema=fm-jt-terminal-outcome.v1 fingerprint="$fingerprint" task_id=output-failure-x1 \
    incarnation=output-failure-inc outcome=done terminal_source=pane \
    terminal_snapshot='state: done · source: pane · output failure' kind=ship
  row=$'2\t2\tcheck\tinactive-outcome:'"$fingerprint"$'\toutput completion failure row'
  printf '%s\n' "$row" > "$state/.wake-queue"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
target="${!#}"
source="${@: -2:1}"
case "$target" in
  *.claim)
    if grep -Fqx 'output_complete=1' "$source" 2>/dev/null; then
      count=$(cat "${FM_FAIL_CLAIM_MOVE:?}" 2>/dev/null || printf '0')
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_FAIL_CLAIM_MOVE"
      if [ "$count" = 1 ]; then
        exit 91
      fi
    fi
    ;;
esac
exec /usr/bin/mv "$@"
SH
  chmod +x "$fakebin/mv"
  export FM_FAIL_CLAIM_MOVE="$dir/fail-claim-move"
  export FM_WAKE_DRAIN_DIRECT=1 FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$$"
  if drain "$root" "$home" "$fakebin" >"$dir/output-failure.out"; then
    fail "output completion failure was hidden"
  fi
  [ "$(grep -Fxc "$row" "$dir/output-failure.out")" = 1 ] \
    || fail "output completion failure lost or duplicated the emitted row"
  [ "$(receipt_count "$state" presented)" = 0 ] \
    || fail "output completion failure finalized the receipt"
  [ "$(receipt_count "$state" pending)" = 1 ] \
    || fail "output completion failure did not retain the receipt"
  [ "$(receipt_value "$state/terminal-outcomes/.$fingerprint.claim" output_started)" = 1 ] \
    || fail "output completion failure did not retain the emitted marker"
  [ "$(receipt_value "$state/terminal-outcomes/.$fingerprint.claim" output_emitted)" = 1 ] \
    || fail "output completion failure did not bind emission state"
  [ "$(receipt_value "$state/terminal-outcomes/.$fingerprint.claim" output_complete)" = 0 ] \
    || fail "output completion failure incorrectly persisted completion"
  drain "$root" "$home" "$fakebin" >"$dir/output-failure-retry.out" \
    || fail "output completion retry did not finalize the receipt"
  [ ! -s "$dir/output-failure-retry.out" ] \
    || fail "output completion retry reprinted the emitted row"
  [ "$(receipt_count "$state" presented)" = 1 ] \
    || fail "output completion retry did not finalize the receipt"
  [ "$(receipt_count "$state" pending)" = 0 ] \
    || fail "output completion retry left the receipt pending"
  [ ! -e "$state/terminal-outcomes/.$fingerprint.claim" ] \
    || fail "output completion retry left a stale claim"
  unset FM_FAIL_CLAIM_MOVE FM_WAKE_DRAIN_DIRECT FM_WAKE_DRAIN_DEFER_ACK FM_WAKE_DRAIN_GENERATION
  pass "post-output failures retry without duplicate presentation"
}

test_direct_drain_finalizes_after_successful_output() {
  local dir root home fakebin state fingerprint row
  new_case direct-success
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" direct-x1 direct-inc
  export FM_FAKE_CREW_STATE_DIRECT_X1='state: done · source: pane · direct presentation'
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "direct receipt setup failed"
  fingerprint=$(basename "$(direct_first_file "$state/terminal-outcomes" '*.pending')" .pending)
  row=$(awk -F '\t' -v key="inactive-outcome:$fingerprint" '$4 == key { print; exit }' "$state/.wake-queue")
  export FM_WAKE_DRAIN_DIRECT=1 FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$$"
  drain "$root" "$home" "$fakebin" >"$dir/direct.out" \
    || fail "direct drain did not finalize a successful presentation"
  grep -F "$row" "$dir/direct.out" >/dev/null || fail "direct drain did not emit the wake row"
  [ "$(receipt_count "$state" presented)" = 1 ] || fail "direct drain left the receipt unfinalized"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "direct drain left a pending receipt"
  [ "$(queue_count "$state")" = 0 ] || fail "direct drain left the wake queued"
  [ ! -e "$state/terminal-outcomes/.$fingerprint.claim" ] || fail "direct drain left a presentation claim"
  printf '%s\n' "$row" > "$state/.wake-queue"
  drain "$root" "$home" "$fakebin" >"$dir/direct-replay.out" \
    || fail "direct replay drain failed"
  [ ! -s "$dir/direct-replay.out" ] || fail "direct drain replayed a finalized receipt"
  unset FM_FAKE_CREW_STATE_DIRECT_X1 FM_WAKE_DRAIN_DIRECT FM_WAKE_DRAIN_DEFER_ACK FM_WAKE_DRAIN_GENERATION
  pass "direct inactive drains finalize successful output once"
}

test_standalone_drain_refuses_inactive_ack() {
  local dir root home fakebin state fingerprint row
  new_case standalone-no-generation
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" standalone-x1 standalone-inc
  export FM_FAKE_CREW_STATE_STANDALONE_X1='state: done · source: pane · standalone presentation'
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "standalone receipt setup failed"
  fingerprint=$(basename "$(direct_first_file "$state/terminal-outcomes" '*.pending')" .pending)
  row=$(awk -F '\t' -v key="inactive-outcome:$fingerprint" '$4 == key { print; exit }' "$state/.wake-queue")
  unset FM_WAKE_DRAIN_DIRECT FM_WAKE_DRAIN_DEFER_ACK FM_WAKE_DRAIN_GENERATION
  if drain "$root" "$home" "$fakebin" no-generation >"$dir/standalone.out"; then
    fail "standalone drain acknowledged an inactive outcome without generation"
  fi
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "standalone drain removed the pending receipt"
  [ "$(queue_count "$state")" = 1 ] || fail "standalone drain removed the wake row"
  grep -F "$row" "$state/.wake-queue" >/dev/null || fail "standalone drain did not restore the wake row"
  unset FM_FAKE_CREW_STATE_STANDALONE_X1
  pass "standalone drain refuses inactive acknowledgement"
}

test_finalized_receipt_rows_are_suppressed() {
  local dir root home fakebin state fingerprint row
  new_case finalized-row
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" finalized-x1 finalized-inc
  export FM_FAKE_CREW_STATE_FINALIZED_X1='state: done · source: pane · finalized row'
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "finalized receipt setup failed"
  fingerprint=$(basename "$(direct_first_file "$state/terminal-outcomes" '*.pending')" .pending)
  row=$(awk -F '\t' -v key="inactive-outcome:$fingerprint" '$4 == key { print; exit }' "$state/.wake-queue")
  drain "$root" "$home" "$fakebin" >/dev/null || fail "initial finalized receipt drain failed"
  printf '%s\n' "$row" > "$state/.wake-queue"
  drain "$root" "$home" "$fakebin" >"$dir/stale.out" \
    || fail "stale finalized receipt row was not safely suppressed"
  [ ! -s "$dir/stale.out" ] || fail "stale finalized receipt row was printed again"
  [ "$(receipt_count "$state" presented)" = 1 ] || fail "stale finalized receipt changed receipt state"
  [ ! -e "$state/terminal-outcomes/.$fingerprint.claim" ] || fail "stale finalized receipt left a claim"
  unset FM_FAKE_CREW_STATE_FINALIZED_X1
  pass "finalized receipt rows are suppressed after drain rollback"
}

test_drain_processes_bounded_batches() {
  local dir root home fakebin state first second remainder
  new_case drain-batch
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  first=$'1\t1\tcheck\tbatch-first\tfirst batch wake'
  second=$'1\t2\tcheck\tbatch-second\tsecond batch wake'
  printf '%s\n%s\n' "$first" "$second" > "$state/.wake-queue"
  export FM_WAKE_DRAIN_BATCH_ROWS=1
  drain "$root" "$home" "$fakebin" > "$dir/drain.out" \
    || fail "bounded wake drain failed"
  grep -Fqx "$first" "$dir/drain.out" || fail "bounded wake drain skipped its first row"
  ! grep -Fqx "$second" "$dir/drain.out" || fail "bounded wake drain processed beyond its batch"
  [ -f "$state/.wake-queue.cursor" ] || fail "bounded wake drain did not persist its offset"
  remainder=$(env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_queue_stream_from_offset "$FM_WAKE_QUEUE" "$(awk -F= '\''$1 == "offset" { print $2 }'\'' "$FM_WAKE_QUEUE.cursor")"' \
    _ "$ROOT" | sed '/^$/d')
  [ "$remainder" = "$second" ] || fail "bounded wake drain restored the wrong remainder"
  unset FM_WAKE_DRAIN_BATCH_ROWS
  drain "$root" "$home" "$fakebin" > "$dir/drain-remainder.out" \
    || fail "bounded wake drain did not resume its durable offset"
  grep -Fqx "$second" "$dir/drain-remainder.out" || fail "durable offset skipped the remainder"
  [ ! -e "$state/.wake-queue.cursor" ] || fail "durable offset was not cleared after drain completion"
  [ ! -s "$state/.wake-queue" ] || fail "bounded wake drain left processed rows queued"
  pass "wake drain restores unprocessed bounded batches"
}

test_malformed_finalized_receipt_fails_closed() {
  local dir root home fakebin state fingerprint row
  new_case malformed-finalized-receipt
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" malformed-finalized-x1 malformed-finalized-inc
  export FM_FAKE_CREW_STATE_MALFORMED_FINALIZED_X1='state: done · source: pane · malformed finalized'
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "malformed finalized receipt setup failed"
  fingerprint=$(basename "$(direct_first_file "$state/terminal-outcomes" '*.pending')" .pending)
  row=$(awk -F '\t' -v key="inactive-outcome:$fingerprint" '$4 == key { print; exit }' "$state/.wake-queue")
  drain "$root" "$home" "$fakebin" >/dev/null || fail "initial finalized receipt drain failed"
  replace_field "$state/terminal-outcomes/$fingerprint.presented" task_id tampered-finalized
  printf '%s\n' "$row" > "$state/.wake-queue"
  if drain "$root" "$home" "$fakebin" >"$dir/malformed-finalized.out" 2>&1; then
    fail "malformed finalized receipt was suppressed"
  fi
  [ "$(queue_count "$state")" = 1 ] || fail "malformed finalized receipt wake was consumed"
  [ "$(receipt_count "$state" presented)" = 1 ] || fail "malformed finalized receipt state disappeared"
  unset FM_FAKE_CREW_STATE_MALFORMED_FINALIZED_X1
  pass "malformed finalized receipts fail closed before wake suppression"
}

test_deferred_ack_retries_after_caller_crash() {
  local dir root home fakebin state fingerprint row replayed_row drain_output rec
  new_case deferred-ack
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" deferred-x1 deferred-inc
  export FM_FAKE_CREW_STATE_DEFERRED_X1='state: done · source: pane · deferred presentation'
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "deferred receipt setup failed"
  fingerprint=$(basename "$(direct_first_file "$state/terminal-outcomes" '*.pending')" .pending)
  row=$(awk -F '\t' -v key="inactive-outcome:$fingerprint" '$4 == key { print; exit }' "$state/.wake-queue")
  [ -n "$row" ] || fail "deferred receipt did not queue its wake"
  drain_output="$dir/deferred.out"
  export FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$$"
  if ! drain "$root" "$home" "$fakebin" >"$drain_output"; then
    fail "deferred wake drain failed"
  fi
  [ -f "$state/terminal-outcomes/$fingerprint.pending" ] || fail "deferred drain consumed the receipt before caller confirmation"
  [ ! -e "$state/terminal-outcomes/$fingerprint.presented" ] || fail "deferred drain finalized the receipt before caller confirmation"
  [ "$(receipt_value "$state/terminal-outcomes/.$fingerprint.claim" state)" = presenting ] \
    || fail "deferred drain did not retain the presentation claim"
  [ "$(receipt_value "$state/terminal-outcomes/.$fingerprint.claim" defer_ack)" = 1 ] \
    || fail "deferred drain did not mark the claim for caller confirmation"
  [ "$(receipt_value "$state/terminal-outcomes/.$fingerprint.claim" output_started)" = 1 ] \
    || fail "deferred drain did not persist the emitted handoff"
  [ "$(receipt_value "$state/terminal-outcomes/.$fingerprint.claim" output_complete)" = 1 ] \
    || fail "deferred drain did not persist output completion"
  replayed_row=$'2\t2\tcheck\tinactive-outcome:'"$fingerprint"$'\treplayed deferred row'
  printf '%s\n' "$replayed_row" > "$state/.wake-queue"
  drain "$root" "$home" "$fakebin" >"$dir/live-deferred.out" \
    || fail "live deferred claim drain failed"
  [ ! -s "$dir/live-deferred.out" ] || fail "live deferred claim was presented twice"
  [ "$(receipt_value "$state/terminal-outcomes/.$fingerprint.claim" row)" = "$row" ] \
    || fail "live deferred claim row was replaced by a replayed wake"
  [ -f "$state/terminal-outcomes/$fingerprint.pending" ] \
    || fail "live deferred claim was acknowledged before caller confirmation"
  replace_field "$state/terminal-outcomes/.$fingerprint.claim" defer_generation "$$"
  replace_field "$state/terminal-outcomes/.$fingerprint.claim" defer_generation_start proc:0
  rm -f "$state/deferred-x1.meta" "$state/deferred-x1.status" "$state/deferred-x1.turn-ended"
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "pending deferred receipt was not republished after caller crash"
  [ "$(queue_count "$state")" = 1 ] || fail "pending deferred receipt did not get a retry wake"
  row=$(awk -F '\t' -v key="inactive-outcome:$fingerprint" '$4 == key { print; exit }' "$state/.wake-queue")
  drain_output="$dir/retry.out"
  export FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$$"
  drain "$root" "$home" "$fakebin" >"$drain_output" \
    || fail "retry drain did not recover the deferred confirmation handoff"
  [ -e "$state/terminal-outcomes/$fingerprint.presented" ] || fail "retry drain did not recover the deferred receipt"
  [ ! -e "$state/terminal-outcomes/$fingerprint.pending" ] || fail "retry drain left the receipt pending"
  [ ! -e "$state/terminal-outcomes/.$fingerprint.claim" ] || fail "retry drain left the deferred claim"
  [ ! -s "$drain_output" ] || fail "retry drain re-presented an already emitted row"
  unset FM_WAKE_DRAIN_DEFER_ACK FM_WAKE_DRAIN_GENERATION FM_FAKE_CREW_STATE_DEFERRED_X1
  pass "deferred inactive receipts recover after caller crash"
}

test_deferred_output_completion_retries_before_confirmation() {
  local dir root home fakebin state fingerprint row
  new_case deferred-output-complete-retry
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  fingerprint=$(receipt_fingerprint 'deferred-retry-x1|deferred-retry-inc|done|state: done · source: pane · deferred output retry')
  mkdir -p "$state/terminal-outcomes"
  fm_write_meta "$state/terminal-outcomes/$fingerprint.pending" \
    schema=fm-jt-terminal-outcome.v1 fingerprint="$fingerprint" task_id=deferred-retry-x1 \
    incarnation=deferred-retry-inc outcome=done terminal_source=pane \
    terminal_snapshot='state: done · source: pane · deferred output retry' kind=ship
  row=$'2\t2\tcheck\tinactive-outcome:'"$fingerprint"$'\tdeferred output retry row'
  printf '%s\n' "$row" > "$state/.wake-queue"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
target="${!#}"
source="${@: -2:1}"
case "$target" in
  *.claim)
    if grep -Fqx 'output_complete=1' "$source" 2>/dev/null; then
      count=$(cat "${FM_FAIL_CLAIM_MOVE:?}" 2>/dev/null || printf '0')
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_FAIL_CLAIM_MOVE"
      if [ "$count" = 1 ]; then
        exit 91
      fi
    fi
    ;;
esac
exec /usr/bin/mv "$@"
SH
  chmod +x "$fakebin/mv"
  export FM_FAIL_CLAIM_MOVE="$dir/fail-claim-move"
  export FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$$"
  drain "$root" "$home" "$fakebin" >"$dir/deferred-retry.out" \
    || fail "deferred output-complete retry drain failed"
  [ "$(receipt_value "$state/terminal-outcomes/.$fingerprint.claim" state)" = presenting ] \
    || fail "deferred output-complete retry advanced the claim before confirmation"
  [ "$(receipt_value "$state/terminal-outcomes/.$fingerprint.claim" output_complete)" = 1 ] \
    || fail "deferred output-complete retry did not persist completion"
  [ -f "$state/terminal-outcomes/$fingerprint.pending" ] \
    || fail "deferred output-complete retry consumed the receipt early"
  [ ! -e "$state/terminal-outcomes/$fingerprint.presented" ] \
    || fail "deferred output-complete retry presented before confirmation"
  recon_from_root "$root" "$fakebin" "$home" "$state" \
      caller-output-complete "inactive-outcome:$fingerprint" "$row" \
    || fail "deferred output-complete retry rejected caller completion"
  recon_from_root "$root" "$fakebin" "$home" "$state" \
      confirm "inactive-outcome:$fingerprint" "$row" \
    || fail "deferred output-complete retry rejected caller confirmation"
  [ -e "$state/terminal-outcomes/$fingerprint.presented" ] \
    || fail "deferred output-complete retry did not finalize after confirmation"
  [ ! -e "$state/terminal-outcomes/.$fingerprint.claim" ] \
    || fail "deferred output-complete retry left a claim"
  unset FM_FAIL_CLAIM_MOVE FM_WAKE_DRAIN_DEFER_ACK FM_WAKE_DRAIN_GENERATION
  pass "deferred output completion retries before caller confirmation"
}

test_deferred_output_completion_failure_retains_emitted_row() {
  local dir root home fakebin state fingerprint row
  new_case deferred-output-complete-failure
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  fingerprint=$(receipt_fingerprint 'deferred-failure-x1|deferred-failure-inc|done|state: done · source: pane · deferred output failure')
  mkdir -p "$state/terminal-outcomes"
  fm_write_meta "$state/terminal-outcomes/$fingerprint.pending" \
    schema=fm-jt-terminal-outcome.v1 fingerprint="$fingerprint" task_id=deferred-failure-x1 \
    incarnation=deferred-failure-inc outcome=done terminal_source=pane \
    terminal_snapshot='state: done · source: pane · deferred output failure' kind=ship
  row=$'2\t2\tcheck\tinactive-outcome:'"$fingerprint"$'\tdeferred output failure row'
  printf '%s\n' "$row" > "$state/.wake-queue"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
target="${!#}"
source="${@: -2:1}"
case "$target" in
  *.claim)
    if grep -Fqx 'output_complete=1' "$source" 2>/dev/null; then
      count=$(cat "${FM_FAIL_CLAIM_MOVE:?}" 2>/dev/null || printf '0')
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_FAIL_CLAIM_MOVE"
      [ "$count" -le 2 ] || exec /usr/bin/mv "$@"
      exit 91
    fi
    ;;
esac
exec /usr/bin/mv "$@"
SH
  chmod +x "$fakebin/mv"
  export FM_FAIL_CLAIM_MOVE="$dir/fail-claim-move"
  export FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$$"
  if drain "$root" "$home" "$fakebin" >"$dir/deferred-failure.out"; then
    fail "deferred output-complete persistence failure was hidden"
  fi
  [ "$(grep -Fxc "$row" "$dir/deferred-failure.out")" = 1 ] \
    || fail "deferred output-complete failure duplicated or lost the emitted row"
  [ "$(queue_count "$state")" = 1 ] \
    || fail "deferred output-complete failure did not retain the wake row"
  [ "$(receipt_value "$state/terminal-outcomes/.$fingerprint.claim" output_started)" = 1 ] \
    || fail "deferred output-complete failure lost the emitted marker"
  [ "$(receipt_value "$state/terminal-outcomes/.$fingerprint.claim" output_emitted)" = 1 ] \
    || fail "deferred output-complete failure lost the emission state"
  [ "$(receipt_value "$state/terminal-outcomes/.$fingerprint.claim" output_complete)" = 0 ] \
    || fail "deferred output-complete failure persisted completion"
  replace_field "$state/terminal-outcomes/.$fingerprint.claim" defer_generation_start proc:0
  rm -f "$fakebin/mv"
  unset FM_FAIL_CLAIM_MOVE FM_WAKE_DRAIN_DEFER_ACK FM_WAKE_DRAIN_GENERATION
  drain "$root" "$home" "$fakebin" >"$dir/deferred-failure-retry.out" \
    || fail "deferred output-complete retry did not retain the emitted row"
  [ ! -s "$dir/deferred-failure-retry.out" ] \
    || fail "deferred output-complete retry reprinted the emitted row"
  [ ! -e "$state/terminal-outcomes/$fingerprint.presented" ] \
    || fail "deferred output-complete retry finalized without caller confirmation"
  [ -e "$state/terminal-outcomes/$fingerprint.pending" ] \
    || fail "deferred output-complete retry lost the receipt"
  [ "$(queue_count "$state")" = 1 ] \
    || fail "deferred output-complete retry lost the wake"
  pass "deferred output completion failures retain uncertain rows"
}

test_deferred_ack_confirms_after_caller_emission() {
  local dir root home fakebin state fingerprint row drain_output
  new_case deferred-confirm
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" deferred-confirm-x1 deferred-confirm-inc
  export FM_FAKE_CREW_STATE_DEFERRED_CONFIRM_X1='state: done · source: pane · deferred confirmation'
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "deferred confirmation setup failed"
  fingerprint=$(basename "$(direct_first_file "$state/terminal-outcomes" '*.pending')" .pending)
  row=$(awk -F '\t' -v key="inactive-outcome:$fingerprint" '$4 == key { print; exit }' "$state/.wake-queue")
  drain_output="$dir/deferred-confirm.out"
  export FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$$"
  drain "$root" "$home" "$fakebin" >"$drain_output" \
    || fail "deferred confirmation drain failed"
  printf '%s\n' "$(cat "$drain_output")" > "$dir/caller-visible.out"
  if env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
    -u FM_ROOT -u STATE PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" bash -c \
    'cd "$4"; "$1" caller-output-complete "$2" "$3"; status=$?; exit "$status"' _ "$RECON" \
    "inactive-outcome:$fingerprint" "$row" "$root"; then
    fail "foreign caller finalized a deferred receipt"
  fi
  recon_from_root "$root" "$fakebin" "$home" "$state" \
      caller-output-complete "inactive-outcome:$fingerprint" "$row" \
    || fail "caller output confirmation did not finalize the receipt"
  recon_from_root "$root" "$fakebin" "$home" "$state" \
      confirm "inactive-outcome:$fingerprint" "$row" \
    || fail "caller confirmation did not finalize the receipt"
  [ -e "$state/terminal-outcomes/$fingerprint.presented" ] \
    || fail "caller confirmation did not move the receipt"
  [ ! -e "$state/terminal-outcomes/$fingerprint.pending" ] \
    || fail "caller confirmation left the receipt pending"
  [ ! -e "$state/terminal-outcomes/.$fingerprint.claim" ] \
    || fail "caller confirmation left the claim"
  unset FM_WAKE_DRAIN_DEFER_ACK FM_WAKE_DRAIN_GENERATION FM_FAKE_CREW_STATE_DEFERRED_CONFIRM_X1
  pass "deferred inactive receipts finalize after caller emission"
}

test_deferred_ack_recovers_after_output_confirmation() {
  local dir root home fakebin state fingerprint row drain_output
  new_case deferred-output-recovery
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" deferred-output-recovery-x1 deferred-output-recovery-inc
  export FM_FAKE_CREW_STATE_DEFERRED_OUTPUT_RECOVERY_X1='state: done · source: pane · deferred output recovery'
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "deferred output recovery setup failed"
  fingerprint=$(basename "$(direct_first_file "$state/terminal-outcomes" '*.pending')" .pending)
  row=$(awk -F '\t' -v key="inactive-outcome:$fingerprint" '$4 == key { print; exit }' "$state/.wake-queue")
  export FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$$"
  drain "$root" "$home" "$fakebin" >"$dir/deferred-output-recovery.out" \
    || fail "deferred output recovery drain failed"
  recon_from_root "$root" "$fakebin" "$home" "$state" \
      caller-output-complete "inactive-outcome:$fingerprint" "$row" \
    || fail "caller output confirmation failed"
  replace_field "$state/terminal-outcomes/.$fingerprint.claim" defer_generation_start proc:0
  printf '%s\n' "$row" > "$state/.wake-queue"
  drain_output="$dir/deferred-output-recovery-retry.out"
  drain "$root" "$home" "$fakebin" >"$drain_output" \
    || fail "deferred output recovery retry failed"
  [ ! -s "$drain_output" ] || fail "confirmed output was presented again after caller crash"
  [ -e "$state/terminal-outcomes/$fingerprint.presented" ] \
    || fail "confirmed output was not acknowledged during recovery"
  [ ! -e "$state/terminal-outcomes/.$fingerprint.claim" ] \
    || fail "confirmed output left a recovery claim"
  unset FM_WAKE_DRAIN_DEFER_ACK FM_WAKE_DRAIN_GENERATION FM_FAKE_CREW_STATE_DEFERRED_OUTPUT_RECOVERY_X1
  pass "deferred inactive receipts recover confirmed output without replay"
}

test_pending_receipts_replay_after_child_scan_failure() {
  local dir root home fakebin state
  new_case pending-replay-after-failure
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" pending-replay-x1 pending-replay-inc
  export FM_FAKE_CREW_STATE_PENDING_REPLAY_X1='state: done · source: pane · pending replay'
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "pending replay setup failed"
  : > "$state/.wake-queue"
  export FM_FAKE_CREW_STATE_EXIT=19
  if scan "$root" "$home" "$fakebin" --startup >/dev/null 2>&1; then
    fail "child scan failure was reported as success during pending replay"
  fi
  [ "$(queue_count "$state")" = 1 ] || fail "pending receipt was not replayed after child scan failure"
  unset FM_FAKE_CREW_STATE_PENDING_REPLAY_X1 FM_FAKE_CREW_STATE_EXIT
  pass "pending receipts replay independently after child scan failure"
}

test_scan_failure_retries_without_advancing_cadence() {
  local dir root home fakebin state wake_dir wake_removed retry_out
  new_case scan-failure
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  wake_dir="$dir/wake"
  wake_removed="$dir/wake-removed"
  mkdir -p "$wake_dir"
  : > "$wake_dir/queue"
  write_meta "$state" first-x1 first-inc
  write_meta "$state" second-x1 second-inc
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FM_BREAK_QUEUE:-0}" = 1 ]; then
  if [ -e "${FM_BREAK_QUEUE_MARKER:-}" ]; then
    mv "${FM_WAKE_QUEUE_DIR}" "${FM_WAKE_QUEUE_REMOVED}"
  else
    : > "${FM_BREAK_QUEUE_MARKER}"
  fi
fi
printf 'state: done · source: pane · scan retry\n'
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  export FM_WAKE_QUEUE="$wake_dir/queue" FM_WAKE_QUEUE_LOCK="$wake_dir/lock"
  export FM_WAKE_QUEUE_DIR="$wake_dir" FM_WAKE_QUEUE_REMOVED="$wake_removed" \
    FM_BREAK_QUEUE_MARKER="$dir/scan-first" FM_BREAK_QUEUE=1
  scan "$root" "$home" "$fakebin" --startup >/dev/null 2>&1 \
    || fail "retryable wake publication contention stopped the scan"
  [ ! -e "$state/.inactive-outcome-reconcile" ] || fail "failed scan advanced the cadence marker"
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "receipt was created without publication-lock ownership"
  [ ! -e "$state"/.first-x1.inactive-state.* ] || fail "failed crew-state scan leaked its temporary output"
  [ ! -e "$state"/.second-x1.inactive-state.* ] || fail "failed crew-state scan leaked its temporary output"
  if ! grep -l '^task_id=first-x1$' "$state"/terminal-outcomes/*.pending >/dev/null 2>&1 \
    && ! grep -l '^task_id=second-x1$' "$state"/terminal-outcomes/*.pending >/dev/null 2>&1; then
    fail "a successfully published child receipt was not retained"
  fi
  case "$(cat "$state/.inactive-outcome-reconcile.cursor")" in
    first-x1|second-x1) ;;
    *) fail "cursor did not preserve the last successful child" ;;
  esac
  mv "$wake_removed" "$wake_dir"
  export FM_BREAK_QUEUE=0
  if ! retry_out=$(scan "$root" "$home" "$fakebin" --startup 2>&1); then
    fail "retry after child failure did not complete: $retry_out"
  fi
  [ "$(receipt_count "$state" pending)" = 2 ] || fail "failed child was skipped on retry"
  unset FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK FM_WAKE_QUEUE_DIR FM_WAKE_QUEUE_REMOVED FM_BREAK_QUEUE
  pass "scan failures preserve retry state and cadence"
}

test_state_paths_reject_symlinks_and_non_directories() {
  local dir root home fakebin state real_state
  new_case symlink-state
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  real_state="$dir/real-state"
  prepare_primary_proof "$root" "$home" "$fakebin"
  mv "$state" "$real_state"
  ln -s "$real_state" "$state"
  if scan "$root" "$home" "$fakebin" --startup >/dev/null 2>&1; then
    fail "symlinked state path was accepted"
  fi
  [ ! -e "$real_state/.inactive-outcome-reconcile" ] || fail "symlinked state received a cadence marker"

  new_case file-state
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  mv "$state" "$dir/state-directory"
  printf 'not a directory\n' > "$state"
  if scan "$root" "$home" "$fakebin" --startup >/dev/null 2>&1; then
    fail "non-directory state path was accepted"
  fi
  pass "inactive reconciliation rejects unsafe state paths"
}

test_reused_task_id_gets_new_fingerprint() {
  local dir root home fakebin state rec first_fp second_fp incarnation fingerprint
  new_case reused-id
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" reused-x1 incarnation-old
  export FM_FAKE_CREW_STATE_REUSED_X1='state: done · source: pane · first run quiet'
  scan "$root" "$home" "$fakebin" --startup >/dev/null
  replace_field "$state/reused-x1.meta" spawn_incarnation incarnation-new
  write_idle_proof "$state" reused-x1 tmux tmux:fm-reused-x1
  set_old_mtime "$state/reused-x1.meta"
  scan "$root" "$home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$state" pending)" = 2 ] || fail "reused task id did not create a new incarnation receipt"
  [ "$(queue_count "$state")" = 2 ] || fail "reused task id did not create a new fingerprinted wake"
  for rec in "$state"/terminal-outcomes/*.pending; do
    [ "$(receipt_value "$rec" task_id)" = reused-x1 ] || fail "reused task receipt lost its task id"
    incarnation=$(receipt_value "$rec" incarnation)
    case "$incarnation" in incarnation-old|incarnation-new) ;; *) fail "reused task receipt lost its incarnation" ;; esac
    [ "$(receipt_value "$rec" outcome)" = done ] || fail "reused task receipt lost its outcome"
    [ "$(receipt_value "$rec" terminal_snapshot)" = 'state: done · source: pane · first run quiet' ] || fail "reused task receipt snapshot was not exact"
    fingerprint=$(basename "$rec" .pending)
    [ "$fingerprint" = "$(receipt_fingerprint "reused-x1|$incarnation|done|state: done · source: pane · first run quiet")" ] || fail "reused task fingerprint was not bound to its fields"
  done
  first_fp=
  second_fp=
  for rec in "$state"/terminal-outcomes/*.pending; do
    if [ -z "$first_fp" ]; then
      first_fp=$(basename "$rec" .pending)
    else
      second_fp=$(basename "$rec" .pending)
    fi
  done
  [ -n "$first_fp" ] && [ -n "$second_fp" ] && [ "$first_fp" != "$second_fp" ] \
    || fail "reused task receipts did not retain distinct fingerprints"
  unset FM_FAKE_CREW_STATE_REUSED_X1
  pass "reused task ids are separated by the spawn incarnation"
}

test_spawn_publishes_incarnation_token() {
  local dir root home fakebin state project worktree tmux_state pane_pid out status meta token
  new_case spawn-contract
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  cp -a "$ROOT/bin/." "$root/bin/"
  project="$dir/project"
  worktree="$dir/worktree"
  tmux_state="$dir/tmux-window-name"
  git init -q -b main "$project"
  git -C "$project" commit -q --allow-empty -m init
  git -C "$project" worktree add -q --detach "$worktree"
  mkdir -p "$home/data/spawn-contract" "$home/projects" "$home/config"
  printf 'spawn contract brief\n' > "$home/data/spawn-contract/brief.md"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
  case "$*" in
    *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
    *"#{pane_pid}"*) printf '%s\n' "${FM_FAKE_PANE_PID:-}"; exit 0 ;;
    *"#{window_name}"*) cat "$FM_FAKE_TMUX_STATE"; exit 0 ;;
esac
case "${1:-}" in
  display-message|list-windows|has-session|new-session|send-keys|kill-window|set-window-option) exit 0 ;;
  new-window) printf '%s\n' '@42'; exit 0 ;;
  rename-window) printf '%s\n' "${@: -1}" > "$FM_FAKE_TMUX_STATE"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse"
  : > "$tmux_state"
  ( cd "$worktree" && exec sleep 30 ) >/dev/null 2>&1 &
  pane_pid=$!
  prepare_primary_proof "$root" "$home" "$fakebin"
  out=$(cd "$root" && env -u NO_MISTAKES_GATE -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
    -u FM_ROOT -u STATE PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_PANE_PATH="$worktree" FM_FAKE_PANE_PID="$pane_pid" FM_FAKE_TMUX_STATE="$tmux_state" TMUX=fake,1,0 \
    FM_SPAWN_WT_WAIT_SECS=3 "$root/bin/fm-spawn.sh" spawn-contract "$project" \
    --harness codex 2>&1)
  status=$?
  kill "$pane_pid" 2>/dev/null || true
  [ "$status" = 0 ] || fail "public fm-spawn path failed: $out"
  meta="$state/spawn-contract.meta"
  [ -f "$meta" ] || fail "public fm-spawn path did not publish metadata"
  token=$(receipt_value "$meta" spawn_incarnation)
  case "$token" in ''|legacy-unknown) fail "public fm-spawn path published no incarnation token" ;; esac
  grep -F 'spawn_incarnation=' "$meta" >/dev/null || fail "spawn metadata omitted its incarnation field"
  mkdir -p "$home/data/spawn-mismatch"
  printf 'spawn mismatch brief\n' > "$home/data/spawn-mismatch/brief.md"
  mv "$root/bin/fm-wake-lib.sh" "$root/bin/fm-wake-lib.real.sh"
  sed 's/^fm_lock_try_acquire() {/fm_original_lock_try_acquire() {/' \
    "$root/bin/fm-wake-lib.real.sh" > "$root/bin/fm-wake-lib.sh"
  cat >> "$root/bin/fm-wake-lib.sh" <<'SH'
fm_lock_try_acquire() {
  fm_original_lock_try_acquire "$@"
  local rc=$? owner
  if [ "$rc" = 0 ] && [ "$1" = "${FM_TEST_LOCK_PATH:?}" ]; then
    owner=$(fm_lock_link_owner "$1") || return 1
    printf 'wrong-incarnation\n' > "$owner/incarnation"
  fi
  return "$rc"
}
SH
  chmod +x "$root/bin/fm-wake-lib.sh"
  export FM_TEST_LOCK_PATH="$state/.spawn-spawn-mismatch.lock"
  out=$(cd "$root" && env -u NO_MISTAKES_GATE -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
    -u FM_ROOT -u STATE PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_PANE_PATH="$worktree" FM_FAKE_PANE_PID="$pane_pid" FM_FAKE_TMUX_STATE="$tmux_state" TMUX=fake,1,0 \
    FM_SPAWN_WT_WAIT_SECS=3 "$root/bin/fm-spawn.sh" spawn-mismatch "$project" \
    --harness codex 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "mismatched lock incarnation was accepted"
  [ ! -e "$state/spawn-mismatch.meta" ] || fail "mismatched lock incarnation published task metadata"
  unset FM_TEST_LOCK_PATH
  pass "public fm-spawn publishes the incarnation token in task metadata"
}

test_session_start_drains_before_inactive_scan() {
  local dir root home fakebin state out status wake_line inactive_line
  new_case session-start-wiring
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  cp -a "$ROOT/bin/." "$root/bin/"
  write_meta "$state" session-x1 session-inc
  export FM_FAKE_CREW_STATE_SESSION_X1='state: done · source: pane · session wiring'
  printf '1\t1\tsignal\ttask-before\tqueued before inactive scan\n' > "$state/.wake-queue"
  prepare_primary_proof "$root" "$home" "$fakebin"
  out=$(cd "$root" && env -u NO_MISTAKES_GATE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_INACTIVE_OUTCOME_SECS=60 FM_INACTIVE_OUTCOME_BUDGET_SECS=10 \
    FM_PRIMARY_ATTESTATION="$CASE_TOKEN" CODEX_THREAD_ID="$CASE_THREAD" \
    FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux "$root/bin/fm-session-start.sh" 2>&1)
  status=$?
  [ "$status" = 0 ] || fail "session-start integration path failed: $out"
  wake_line=$(printf '%s\n' "$out" | grep -n '^1[[:space:]]\+1[[:space:]]\+signal[[:space:]]\+task-before' | head -1 | cut -d: -f1)
  inactive_line=$(printf '%s\n' "$out" | grep -n 'queued inactive outcome: task=session-x1' | head -1 | cut -d: -f1)
  [ -n "$wake_line" ] && [ -n "$inactive_line" ] && [ "$wake_line" -lt "$inactive_line" ] \
    || fail "session-start did not drain the existing wake before inactive reconciliation"
  [ "$(awk -F '\t' '$4 == "task-before" { n++ } END { print n + 0 }' "$state/.wake-queue")" = 0 ] \
    || fail "session-start left the pre-existing wake queued"
  [ "$(queue_count "$state")" = 1 ] || fail "session-start did not queue exactly one inactive wake after draining"
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "session-start did not run inactive reconciliation"
  mv "$root/bin/fm-wake-drain.sh" "$root/bin/fm-wake-drain.real"
  cat > "$root/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
exit 23
SH
  chmod +x "$root/bin/fm-wake-drain.sh"
  out=$(cd "$root" && env -u NO_MISTAKES_GATE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_INACTIVE_OUTCOME_SECS=60 \
    FM_INACTIVE_OUTCOME_BUDGET_SECS=10 FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux \
    "$root/bin/fm-session-start.sh" 2>&1)
  status=$?
  [ "$status" = 0 ] || fail "session-start changed its always-zero reporting contract after drain failure"
  printf '%s\n' "$out" | grep -F 'inactive reconciliation skipped' >/dev/null \
    || fail "session-start did not report that inactive reconciliation was skipped after drain failure"
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "session-start scanned after a failed wake drain"
  [ "$(queue_count "$state")" = 1 ] || fail "session-start changed the queue after a failed wake drain"
  unset FM_FAKE_CREW_STATE_SESSION_X1
  pass "session-start drains existing wakes before inactive reconciliation"
}

test_session_start_generation_bound_replay() {
  local dir root home fakebin state out status
  new_case session-start-generation
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  cp -a "$ROOT/bin/." "$root/bin/"
  write_meta "$state" session-bound-x1 session-bound-inc
  export FM_FAKE_CREW_STATE_SESSION_BOUND_X1='state: done · source: pane · session generation'
  scan "$root" "$home" "$fakebin" --startup >/dev/null \
    || fail "session-start generation fixture did not queue an inactive outcome"
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "session-start generation fixture did not retain a pending receipt"
  out=$(cd "$root" && env -u NO_MISTAKES_GATE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_INACTIVE_OUTCOME_SECS=60 \
    FM_INACTIVE_OUTCOME_BUDGET_SECS=10 FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux \
    "$root/bin/fm-session-start.sh" 2>&1)
  status=$?
  [ "$status" = 0 ] || fail "session-start generation-bound replay failed: $out"
  printf '%s\n' "$out" | grep -F 'inactive-outcome:' >/dev/null \
    || fail "session-start did not emit the inactive row for caller confirmation"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "session-start did not acknowledge the generation-bound replay"
  [ "$(receipt_count "$state" presented)" = 1 ] || fail "session-start did not finalize the generation-bound replay"
  [ "$(queue_count "$state")" = 0 ] || fail "session-start left the generation-bound replay queued"
  unset FM_FAKE_CREW_STATE_SESSION_BOUND_X1
  pass "session-start acknowledges inactive outcomes through its generation"
}

test_watcher_runs_inactive_cadence() {
  local dir root home fakebin state out second_out status fingerprint
  new_case watcher-wiring
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  cp -a "$ROOT/bin/." "$root/bin/"
  write_meta "$state" watcher-x1 watcher-inc
  printf '1\t1\tsignal\ttask-before\tqueued before watcher scan\n' > "$state/.wake-queue"
  export FM_FAKE_CREW_STATE_WATCHER_X1='state: failed · source: pane · watcher wiring'
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}" ;;
  *"#{pane_pid}"*) printf '%s\n' "${FM_FAKE_HARNESS_PID:-$$}" ;;
  *"#{window_name}"*) printf '%s\n' firstmate ;;
  *capture-pane*) printf 'idle prompt\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  prepare_primary_proof "$root" "$home" "$fakebin"
  out=$(cd "$root" && env -u NO_MISTAKES_GATE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_INACTIVE_OUTCOME_SECS=60 FM_INACTIVE_OUTCOME_BUDGET_SECS=10 \
    FM_PRIMARY_ATTESTATION="$CASE_TOKEN" CODEX_THREAD_ID="$CASE_THREAD" \
    FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 FM_FAKE_PANE_PATH="$home" \
    FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCHER_HEARTBEAT=999999 \
    "$root/bin/fm-watch.sh" 2>&1)
  status=$?
  [ "$status" = 0 ] || fail "watcher cadence failed while surfacing the queued wake"
  printf '%s\n' "$out" | grep -F $'1\t1\tsignal\ttask-before\tqueued before watcher scan' >/dev/null \
    || fail "watcher did not surface the existing wake first"
  [ "$(awk -F '\t' '$4 == "task-before" { n++ } END { print n + 0 }' "$state/.wake-queue")" = 0 ] \
    || fail "watcher left the existing wake queued"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "watcher scanned inactive outcomes before draining the queued wake"

  second_out=$(cd "$root" && env -u NO_MISTAKES_GATE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_INACTIVE_OUTCOME_SECS=60 FM_INACTIVE_OUTCOME_BUDGET_SECS=10 \
    FM_PRIMARY_ATTESTATION="$CASE_TOKEN" CODEX_THREAD_ID="$CASE_THREAD" \
    FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 FM_FAKE_PANE_PATH="$home" \
    FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCHER_HEARTBEAT=999999 \
    "$root/bin/fm-watch.sh" 2>&1)
  status=$?
  [ "$status" = 0 ] || fail "watcher cadence failed while surfacing the inactive outcome wake"
  printf '%s\n' "$second_out" | grep -F 'inactive-outcome:' >/dev/null \
    || fail "watcher did not surface the exact inactive outcome wake in the scan turn"
  fingerprint=$(basename "$(direct_first_file "$state/terminal-outcomes" '*.pending')" .pending)
  ! printf '%s\n' "$second_out" | grep -F 'check: inactive terminal outcome replay queued' >/dev/null \
    || fail "watcher emitted a second generic inactive wake"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "watcher cadence did not acknowledge the inactive receipt"
  [ "$(receipt_count "$state" presented)" = 1 ] || fail "watcher cadence did not finalize the inactive receipt"
  [ "$(queue_count "$state")" = 0 ] || fail "watcher cadence did not consume the inactive outcome wake"
  [ ! -e "$state/terminal-outcomes/.$fingerprint.claim" ] || fail "watcher cadence left a presentation claim"

  write_meta "$state" watcher-failure-x1 watcher-failure-inc
  export FM_FAKE_CREW_STATE_WATCHER_FAILURE_X1='state: failed · source: pane · watcher output failure'
  rm -f "$state/.inactive-outcome-reconcile"
  mv "$root/bin/fm-wake-drain.sh" "$root/bin/fm-wake-drain.real"
  cat > "$root/bin/fm-wake-drain.sh" <<SH
#!/usr/bin/env bash
set -u
count_file="\${FM_STATE_OVERRIDE}/.drain-count"
count=\$(cat "\$count_file" 2>/dev/null || echo 0)
count=\$((count + 1))
printf '%s\n' "\$count" > "\$count_file"
if [ "\$count" = 2 ]; then
  exit 3
fi
exec "$root/bin/fm-wake-drain.real"
SH
  chmod +x "$root/bin/fm-wake-drain.sh"
  set +e
  ( cd "$root" && env -u NO_MISTAKES_GATE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
      PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_INACTIVE_OUTCOME_SECS=60 FM_INACTIVE_OUTCOME_BUDGET_SECS=10 \
      FM_PRIMARY_ATTESTATION="$CASE_TOKEN" CODEX_THREAD_ID="$CASE_THREAD" \
      FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 FM_FAKE_PANE_PATH="$home" \
      FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCHER_HEARTBEAT=999999 \
      "$root/bin/fm-watch.sh" ) > "$dir/failed-scan.out" 2>&1
  status=$?
  set -u
  [ "$status" = 3 ] || fail "watcher did not fail closed when the same-turn drain failed"
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "watcher failure fixture did not create one pending receipt"
  [ "$(queue_count "$state")" = 1 ] || fail "watcher failure fixture did not retain one wake"
  mv "$root/bin/fm-wake-drain.real" "$root/bin/fm-wake-drain.sh"
  set +e
  ( cd "$root" && env -u NO_MISTAKES_GATE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
      PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
      FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_INACTIVE_OUTCOME_SECS=60 \
      FM_INACTIVE_OUTCOME_BUDGET_SECS=10 FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
      CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 \
      FM_FAKE_PANE_PATH="$home" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      FM_WATCHER_HEARTBEAT=999999 "$root/bin/fm-watch.sh" ) | head -n 0
  status=${PIPESTATUS[0]}
  set -u
  [ "$status" -ne 0 ] || fail "watcher treated a broken presentation pipe as success"
  [ "$(receipt_count "$state" pending)" = 1 ] \
    || fail "watcher consumed the inactive receipt after presentation failure"
  [ -e "$state/terminal-outcomes/.$(basename "$(direct_first_file "$state/terminal-outcomes" '*.pending')" .pending).claim" ] \
    || fail "watcher did not retain a retryable presentation claim"
  unset FM_FAKE_CREW_STATE_WATCHER_X1 FM_FAKE_CREW_STATE_WATCHER_FAILURE_X1
  pass "watcher cadence gates acknowledgement on successful output"
}

test_surfaced_terminal_is_not_replayed() {
  local dir root home fakebin state out status
  new_case surfaced-terminal
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  cp -a "$ROOT/bin/." "$root/bin/"
  write_meta "$state" surfaced-x1 surfaced-inc
  printf 'done: surfaced terminal\n' > "$state/surfaced-x1.status"
  : > "$state/surfaced-x1.turn-ended"
  touch "$state/surfaced-x1.meta" "$state/surfaced-x1.status" "$state/surfaced-x1.turn-ended"
  export FM_FAKE_CREW_STATE_SURFACED_X1='state: done · source: pane · surfaced terminal'
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}" ;;
  *"#{pane_pid}"*) printf '%s\n' "${FM_FAKE_HARNESS_PID:-$$}" ;;
  *"#{window_name}"*) printf '%s\n' firstmate ;;
  *capture-pane*) printf 'idle prompt\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  prepare_primary_proof "$root" "$home" "$fakebin"
  out=$(cd "$root" && env -u NO_MISTAKES_GATE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_INACTIVE_OUTCOME_SECS=60 \
    FM_INACTIVE_OUTCOME_BUDGET_SECS=10 FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 \
    FM_FAKE_PANE_PATH="$home" FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCHER_HEARTBEAT=999999 "$root/bin/fm-watch.sh" 2>&1)
  status=$?
  [ "$status" = 0 ] || fail "watcher did not surface the terminal status: $out"
  [ -f "$state/.hb-surfaced-surfaced-x1" ] || fail "watcher did not persist the surfaced status"
  [ -f "$state/.hb-terminal-surfaced-surfaced-x1" ] || fail "watcher did not persist the incarnation-bound terminal marker"
  set_old_mtime "$state/surfaced-x1.meta" "$state/surfaced-x1.status" "$state/surfaced-x1.turn-ended"
  scan "$root" "$home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "already surfaced terminal outcome was replayed"
  [ "$(queue_count "$state")" = 0 ] || fail "already surfaced terminal outcome queued a wake"
  replace_field "$state/surfaced-x1.meta" spawn_incarnation resurfaced-inc
  write_idle_proof "$state" surfaced-x1 tmux tmux:fm-surfaced-x1
  set_old_mtime "$state/surfaced-x1.meta" "$state/surfaced-x1.status" "$state/surfaced-x1.turn-ended"
  scan "$root" "$home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "new incarnation was incorrectly suppressed by an old surface marker"
  [ "$(queue_count "$state")" = 1 ] || fail "new incarnation did not queue its inactive wake"
  unset FM_FAKE_CREW_STATE_SURFACED_X1
  pass "terminal replay suppression is bound to surfaced status and incarnation"
}

test_postpublication_uncertainty_is_not_replayed() {
  local dir root home fakebin state out status flag
  new_case postpublication-uncertainty
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  cp -a "$ROOT/bin/." "$root/bin/"
  write_meta "$state" postpublish-x1 postpublish-inc
  printf 'done: postpublication uncertainty\n' > "$state/postpublish-x1.status"
  : > "$state/postpublish-x1.turn-ended"
  touch "$state/postpublish-x1.meta" "$state/postpublish-x1.status" "$state/postpublish-x1.turn-ended"
  export FM_FAKE_CREW_STATE_POSTPUBLISH_X1='state: done · source: pane · postpublication uncertainty'
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}" ;;
  *"#{pane_pid}"*) printf '%s\n' "${FM_FAKE_HARNESS_PID:-$$}" ;;
  *"#{window_name}"*) printf '%s\n' firstmate ;;
  *capture-pane*) printf 'idle prompt\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  flag="$dir/fail-postpublication-mark"
  : > "$flag"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
source_file="${@: -2:1}"
target="${!#}"
if [ -e "${FM_TEST_FAIL_POSTPUBLICATION:-}" ] \
  && [[ "$target" == *.hb-surface-retry-* ]] \
  && grep -Fqx 'wake_published=1' "$source_file" 2>/dev/null; then
  rm -f "$FM_TEST_FAIL_POSTPUBLICATION"
  exit 91
fi
exec /usr/bin/mv "$@"
SH
  chmod +x "$fakebin/mv"
  export FM_TEST_FAIL_POSTPUBLICATION="$flag"
  prepare_primary_proof "$root" "$home" "$fakebin"
  set +e
  out=$(cd "$root" && env -u NO_MISTAKES_GATE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_INACTIVE_OUTCOME_SECS=60 \
    FM_INACTIVE_OUTCOME_BUDGET_SECS=10 FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 \
    FM_FAKE_PANE_PATH="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_WATCHER_HEARTBEAT=999999 "$root/bin/fm-watch.sh" 2>&1)
  status=$?
  set -u
  [ "$status" -ne 0 ] || fail "post-publication persistence failure was treated as success"
  [ "$(receipt_value "$state/.hb-surface-retry-postpublish-x1" wake_published)" = 2 ] \
    || fail "post-publication failure did not retain an uncertain retry state"
  [ "$(awk 'NF { n++ } END { print n + 0 }' "$state/.wake-queue")" = 1 ] \
    || fail "post-publication failure did not retain its wake"
  rm -f "$fakebin/mv"
  unset FM_TEST_FAIL_POSTPUBLICATION
  out=$(cd "$root" && env -u NO_MISTAKES_GATE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_INACTIVE_OUTCOME_SECS=60 \
    FM_INACTIVE_OUTCOME_BUDGET_SECS=10 FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 \
    FM_FAKE_PANE_PATH="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_WATCHER_HEARTBEAT=999999 "$root/bin/fm-watch.sh" 2>&1) \
    || fail "post-publication retry did not repair its wake"
  [ "$(awk 'NF { n++ } END { print n + 0 }' "$state/.wake-queue")" = 0 ] \
    || fail "post-publication retry left its wake queued"
  printf '%s\n' "$out" | grep -F 'signal' >/dev/null \
    || fail "post-publication retry did not surface its retained wake"
  unset FM_FAKE_CREW_STATE_POSTPUBLISH_X1
  pass "post-publication uncertainty suppresses duplicate wakes"
}

test_ordinary_terminal_wake_consumption_is_durable() {
  local dir root home fakebin state retry last out
  new_case ordinary-terminal-consumed
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  cp -a "$ROOT/bin/." "$root/bin/"
  write_meta "$state" ordinary-consumed-x1 ordinary-consumed-inc
  last='done: ordinary terminal consumed'
  printf '%s\n' "$last" > "$state/ordinary-consumed-x1.status"
  prepare_primary_proof "$root" "$home" "$fakebin"
  prepare_watcher_protocol "$root" "$home" "$state"
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    _FM_WORKER_ISOLATION_SNAPSHOT_READY=0 FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    PATH="$fakebin:$PATH" \
    bash -c 'cd "$1" || exit 1; . "$1/bin/fm-watch.sh"; surface_retry_write "$3" "$4" "$3" 2' _ \
    "$root" "$state" ordinary-consumed-x1 "$last" \
    || fail "ordinary terminal retry fixture was not written"
  retry="$state/.hb-surface-retry-ordinary-consumed-x1"
  [ "$(receipt_value "$retry" wake_published)" = 2 ] || fail "ordinary retry was not uncertain"
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    _FM_WORKER_ISOLATION_SNAPSHOT_READY=0 FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    PATH="$fakebin:$PATH" \
    bash -c 'cd "$1" || exit 1; . "$1/bin/fm-wake-lib.sh"; fm_wake_append signal "$3" terminal' _ \
    "$root" "$state" ordinary-consumed-x1 \
    || fail "ordinary terminal wake was not queued"
  drain "$root" "$home" "$fakebin" >/dev/null || fail "ordinary terminal wake drain failed"
  [ -f "$state/.hb-surface-consumed-ordinary-consumed-x1" ] \
    || fail "drain did not persist ordinary wake consumption"
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    _FM_WORKER_ISOLATION_SNAPSHOT_READY=0 FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    PATH="$fakebin:$PATH" \
    bash -c 'cd "$1" || exit 1; . "$1/bin/fm-watch.sh"; terminal_signal_suppressed "$2/ordinary-consumed-x1.status"' _ \
    "$root" "$state" ordinary-consumed-x1 \
    || fail "ordinary consumed wake was not recognized by watcher"
  [ -f "$state/.hb-terminal-surfaced-ordinary-consumed-x1" ] \
    || fail "ordinary consumed wake did not complete terminal surfacing"
  [ ! -e "$retry" ] || fail "ordinary consumed retry was not cleared"
  [ ! -e "$state/.hb-surface-consumed-ordinary-consumed-x1" ] \
    || fail "ordinary consumed marker was not cleared"
  pass "ordinary terminal wake consumption survives watcher crashes"
}

test_surface_marker_failure_is_retryable() {
  local dir root home fakebin state out status
  new_case surface-marker-failure
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  cp -a "$ROOT/bin/." "$root/bin/"
  write_meta "$state" surface-marker-x1 surface-marker-inc
  printf 'done: surface marker retry\n' > "$state/surface-marker-x1.status"
  : > "$state/surface-marker-x1.turn-ended"
  touch "$state/surface-marker-x1.meta" "$state/surface-marker-x1.status" "$state/surface-marker-x1.turn-ended"
  export FM_FAKE_CREW_STATE_SURFACE_MARKER_X1='state: working · source: pane · marker retry'
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}" ;;
  *"#{pane_pid}"*) printf '%s\n' "${FM_FAKE_HARNESS_PID:-$$}" ;;
  *"#{window_name}"*) printf '%s\n' firstmate ;;
  *capture-pane*) printf 'idle prompt\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
target="${!#}"
case "$target" in
  *.hb-terminal-surfaced-*) exit 91 ;;
esac
exec /usr/bin/mv "$@"
SH
  chmod +x "$fakebin/mv"
  prepare_primary_proof "$root" "$home" "$fakebin"
  set +e
  out=$(cd "$root" && env -u NO_MISTAKES_GATE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_INACTIVE_OUTCOME_SECS=60 \
    FM_INACTIVE_OUTCOME_BUDGET_SECS=10 FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 \
    FM_FAKE_PANE_PATH="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_WATCHER_HEARTBEAT=999999 "$root/bin/fm-watch.sh" 2>&1)
  status=$?
  set -u
  [ "$status" -ne 0 ] || fail "surface-marker failure was treated as success"
  [ -f "$state/.hb-surface-retry-surface-marker-x1" ] \
    || fail "surface-marker failure did not retain its retry transaction"
  [ "$(awk 'NF { n++ } END { print n + 0 }' "$state/.wake-queue")" -ge 1 ] \
    || fail "surface-marker failure did not retain its queued wake"
  export FM_FAKE_CREW_STATE_SURFACE_MARKER_X1='state: done · source: pane · marker retry'
  set +e
  out=$(scan "$root" "$home" "$fakebin" --startup 2>&1)
  status=$?
  set -u
  [ "$status" = 0 ] || fail "surface-marker retry suppression scan failed: $out"
  [ "$(receipt_count "$state" pending)" = 0 ] \
    || fail "unresolved surface-marker retry created a duplicate receipt"
  export FM_FAKE_CREW_STATE_SURFACE_MARKER_X1='state: working · source: pane · marker retry'
  printf 'done: surface marker newer\n' > "$state/surface-marker-x1.status"
  set +e
  out=$(cd "$root" && env -u NO_MISTAKES_GATE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_INACTIVE_OUTCOME_SECS=60 \
    FM_INACTIVE_OUTCOME_BUDGET_SECS=10 FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 \
    FM_FAKE_PANE_PATH="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_WATCHER_HEARTBEAT=999999 "$root/bin/fm-watch.sh" 2>&1)
  status=$?
  set -u
  [ "$status" -ne 0 ] || fail "stale surface-marker retry was repaired"
  [ -f "$state/.hb-surface-retry-surface-marker-x1" ] \
    || fail "stale surface-marker retry was discarded"
  printf 'done: surface marker retry\n' > "$state/surface-marker-x1.status"
  rm -f "$fakebin/mv"
  out=$(cd "$root" && env -u NO_MISTAKES_GATE -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_INACTIVE_OUTCOME_SECS=60 \
    FM_INACTIVE_OUTCOME_BUDGET_SECS=10 FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 \
    FM_FAKE_PANE_PATH="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 FM_WATCHER_HEARTBEAT=999999 "$root/bin/fm-watch.sh" 2>&1)
  status=$?
  [ "$status" = 0 ] || fail "surface-marker retry failed: $out"
  [ ! -e "$state/.hb-surface-retry-surface-marker-x1" ] \
    || fail "surface-marker retry transaction was not cleared"
  [ -f "$state/.hb-terminal-surfaced-surface-marker-x1" ] \
    || fail "surface-marker retry did not persist the terminal marker"
  [ "$(awk 'NF { n++ } END { print n + 0 }' "$state/.wake-queue")" = 0 ] \
    || fail "surface-marker retry left the wake queued"
  scan "$root" "$home" "$fakebin" --startup >/dev/null \
    || fail "surface-marker retry follow-up scan failed"
  [ "$(receipt_count "$state" pending)" = 0 ] \
    || fail "surface-marker retry caused an inactive receipt replay"
  unset FM_FAKE_CREW_STATE_SURFACE_MARKER_X1
  pass "surface-marker failures retain and repair their wake transaction"
}

test_legacy_metadata_uses_stable_fallback() {
  local dir root home fakebin state rec incarnation
  new_case legacy-fallback
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_legacy_meta "$state" legacy-x1
  export FM_FAKE_CREW_STATE_LEGACY_X1='state: done · source: pane · legacy quiet'
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "legacy metadata scan failed"
  rec=$(direct_first_file "$state/terminal-outcomes" '*.pending')
  [ -n "$rec" ] || fail "legacy metadata did not create a receipt"
  incarnation=$(receipt_value "$rec" incarnation)
  case "$incarnation" in legacy-*) ;; *) fail "legacy metadata lacked a documented fallback incarnation" ;; esac
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "legacy metadata rescan failed"
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "legacy fallback was not stable across rescans"
  unset FM_FAKE_CREW_STATE_LEGACY_X1
  pass "legacy metadata receives a stable fallback incarnation"
}

test_empty_spawn_incarnation_is_rejected() {
  local dir root home fakebin state
  new_case empty-spawn-incarnation
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" empty-inc-x1 empty-inc
  replace_field "$state/empty-inc-x1.meta" spawn_incarnation ''
  export FM_FAKE_CREW_STATE_EMPTY_INC_X1='state: done · source: pane · malformed incarnation'
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "empty incarnation scan failed"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "explicit empty incarnation used the legacy fallback"
  [ "$(queue_count "$state")" = 0 ] || fail "explicit empty incarnation created a wake"
  unset FM_FAKE_CREW_STATE_EMPTY_INC_X1
  pass "explicit empty spawn incarnations fail closed"
}

test_relaunch_and_teardown_races_recheck_under_spawn_lock() {
  local dir root home fakebin state holder scanner ready release
  new_case races
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" relaunch-x1 old-inc
  export FM_FAKE_CREW_STATE_RELAUNCH_X1='state: done · source: pane · relaunch race'
  ready="$dir/ready"
  release="$dir/release"
  prepare_primary_proof "$root" "$home" "$fakebin"
  (
    cd "$root" && env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
      -u FM_ROOT -u STATE FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      FM_PRIMARY_ATTESTATION="$CASE_TOKEN" CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" \
      PATH="$fakebin:$PATH" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2/.spawn-relaunch-x1.lock"; : > "$3"; while [ ! -e "$4" ]; do sleep 0.01; done; fm_lock_release "$2/.spawn-relaunch-x1.lock"' _ "$ROOT" "$state" "$ready" "$release"
  ) &
  holder=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.01; done
  scan "$root" "$home" "$fakebin" --startup >"$dir/relaunch.scan.out" 2>&1 &
  scanner=$!
  sleep 1
  replace_field "$state/relaunch-x1.meta" spawn_incarnation new-inc
  write_idle_proof "$state" relaunch-x1 tmux tmux:fm-relaunch-x1
  : > "$release"
  wait "$holder" || fail "spawn-lock relaunch fixture failed"
  wait "$scanner" || fail "relaunch reconciliation fixture failed"
  [ "$(direct_file_count "$state/terminal-outcomes" '*.pending')" = 0 ] \
    || fail "fresh relaunch was replayed before its quiet period"
  set_old_mtime "$state/relaunch-x1.meta"
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "aged relaunch reconciliation failed"
  grep -F 'incarnation=new-inc' "$state"/terminal-outcomes/*.pending >/dev/null || fail "relaunch race used stale incarnation"

  write_meta "$state" teardown-x1 teardown-inc
  export FM_FAKE_CREW_STATE_TEARDOWN_X1='state: done · source: pane · teardown race'
  ready="$dir/ready-teardown"
  release="$dir/release-teardown"
  (
    cd "$root" && env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
      -u FM_ROOT -u STATE FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      FM_PRIMARY_ATTESTATION="$CASE_TOKEN" CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" \
      PATH="$fakebin:$PATH" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2/.spawn-teardown-x1.lock"; : > "$3"; while [ ! -e "$4" ]; do sleep 0.01; done; fm_lock_release "$2/.spawn-teardown-x1.lock"' _ "$ROOT" "$state" "$ready" "$release"
  ) &
  holder=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.01; done
  scan "$root" "$home" "$fakebin" --startup >"$dir/teardown.scan.out" 2>&1 &
  scanner=$!
  sleep 1
  rm -f "$state/teardown-x1.meta" "$state/teardown-x1.status" "$state/teardown-x1.turn-ended"
  : > "$release"
  wait "$holder" || fail "spawn-lock teardown fixture failed"
  wait "$scanner" || fail "teardown reconciliation fixture failed"
  [ "$(direct_file_count "$state/terminal-outcomes" '*teardown-x1*.pending')" = 0 ] || fail "teardown race created a receipt after meta removal"
  unset FM_FAKE_CREW_STATE_RELAUNCH_X1 FM_FAKE_CREW_STATE_TEARDOWN_X1
  pass "relaunch and teardown races recheck metadata under the spawn lock"
}

test_parent_home_secondmate_records_are_skipped() {
  local dir root home fakebin state
  new_case parent-home-skip
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" parent-sm-x1 parent-inc secondmate
  export FM_FAKE_CREW_STATE_PARENT_SM_X1='state: done · source: pane · parent record'
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "parent-home scan failed"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "parent-home secondmate record was replayed"
  [ "$(queue_count "$state")" = 0 ] || fail "parent-home secondmate record queued a wake"
  unset FM_FAKE_CREW_STATE_PARENT_SM_X1
  pass "parent-home secondmate records stay outside inactive replay"
}

test_herdr_identity_and_default_captain_refusal() {
  local dir root home fakebin state herdr_log
  new_case herdr-identity
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  herdr_log="$dir/herdr.log"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_HERDR_LOG:?}"
case "$*" in
  *'status --json'*)
    if [ "${FM_FAKE_HERDR_DOWN:-0}" = 1 ]; then
      printf '{"server":{"running":false}}\n'
    else
      printf '{"server":{"running":true}}\n'
    fi
    ;;
  *' server'*) printf 'unexpected server start\n' >&2; exit 97 ;;
  *'pane read'*) printf 'idle prompt\n' ;;
  *'agent get'*) printf '{"result":{"agent":{"agent_status":"idle"}}}\n' ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  write_meta "$state" herdr-good good-inc ship herdr firstmate:pane-good
  printf 'herdr_session=firstmate\nherdr_workspace_id=ws\nherdr_tab_id=tab\nherdr_pane_id=pane\n' >> "$state/herdr-good.meta"
  printf 'herdr_session=default\n' >> "$state/herdr-good.meta"
  write_meta "$state" herdr-unique unique-inc ship herdr firstmate:pane
  printf 'herdr_session=firstmate\nherdr_workspace_id=ws\nherdr_tab_id=tab\nherdr_pane_id=pane\n' >> "$state/herdr-unique.meta"
  write_meta "$state" herdr-default default-inc ship herdr default:pane
  printf 'herdr_session=default\nherdr_workspace_id=ws\nherdr_tab_id=tab\nherdr_pane_id=pane\n' >> "$state/herdr-default.meta"
  write_meta "$state" herdr-captain captain-inc ship herdr CAPTAIN:pane
  printf 'herdr_session=CAPTAIN\nherdr_workspace_id=ws\nherdr_tab_id=tab\nherdr_pane_id=pane\n' >> "$state/herdr-captain.meta"
  set_old_mtime "$state/herdr-good.meta" "$state/herdr-unique.meta" \
    "$state/herdr-default.meta" "$state/herdr-captain.meta"
  export FM_FAKE_CREW_STATE_HERDR_GOOD='state: done · source: pane · dedicated session quiet'
  export FM_FAKE_CREW_STATE_HERDR_UNIQUE='state: done · source: pane · unique session quiet'
  export FM_FAKE_CREW_STATE_HERDR_DEFAULT='state: done · source: pane · must refuse'
  export FM_FAKE_CREW_STATE_HERDR_CAPTAIN='state: done · source: pane · must refuse'
  export FM_NETWORK_LOG="$dir/network.log" FM_HERDR_LOG="$herdr_log"
  PATH="$fakebin:$PATH" scan "$root" "$home" "$fakebin" --startup >/dev/null \
    || fail "Herdr identity scan failed"
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "Herdr duplicate identity was accepted or default/CAPTAIN were not refused"
  grep -l '^task_id=herdr-unique$' "$state"/terminal-outcomes/*.pending >/dev/null \
    || fail "unique Herdr identity was not accepted"
  [ ! -s "$dir/network.log" ] || fail "inactive reconciliation made a forge/network call"
  ! grep -E '(^| )server( |$)' "$herdr_log" >/dev/null \
    || fail "inactive reconciliation attempted to start Herdr"
  write_meta "$state" herdr-no-start no-start-inc ship herdr firstmate:pane-no-start
  printf 'herdr_session=firstmate\n' >> "$state/herdr-no-start.meta"
  export FM_FAKE_CREW_STATE_HERDR_NO_START='state: done · source: pane · no server start'
  export FM_FAKE_HERDR_DOWN=1
  PATH="$fakebin:$PATH" scan "$root" "$home" "$fakebin" --startup >/dev/null \
    || fail "Herdr no-server-start guard failed the read-only scan"
  ! grep -E '(^| )server( |$)' "$herdr_log" >/dev/null \
    || fail "Herdr no-server-start guard attempted a server command"
  unset FM_FAKE_CREW_STATE_HERDR_GOOD FM_FAKE_CREW_STATE_HERDR_UNIQUE \
    FM_FAKE_CREW_STATE_HERDR_DEFAULT FM_FAKE_CREW_STATE_HERDR_CAPTAIN \
    FM_FAKE_CREW_STATE_HERDR_NO_START FM_FAKE_HERDR_DOWN FM_NETWORK_LOG FM_HERDR_LOG
  pass "Herdr uses the dedicated firstmate identity and refuses default/CAPTAIN"
}

test_occupancy_unknown_is_not_terminal() {
  local dir root home fakebin state
  new_case occupancy-unknown
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" unknown-x1 unknown-inc
  export FM_FAKE_CREW_STATE_UNKNOWN_X1='state: unknown · source: none · occupancy unknown'
  scan "$root" "$home" "$fakebin" --startup >/dev/null \
    || fail "occupancy scan failed"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "occupancy unknown was treated as terminal"
  [ "$(queue_count "$state")" = 0 ] || fail "occupancy unknown created an actionable wake"
  unset FM_FAKE_CREW_STATE_UNKNOWN_X1
  pass "occupancy unknown remains non-terminal"
}

test_status_log_terminal_is_not_replayed() {
  local dir root home fakebin state
  new_case stale-status-log
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" stale-x1 stale-inc
  export FM_FAKE_CREW_STATE_STALE_X1='state: done · source: status-log · stale done event'
  scan "$root" "$home" "$fakebin" --startup >/dev/null \
    || fail "status-log scan failed"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "stale status-log done was treated as terminal"
  [ "$(queue_count "$state")" = 0 ] || fail "stale status-log done created an actionable wake"
  unset FM_FAKE_CREW_STATE_STALE_X1
  pass "status-log terminal output remains fail-closed"
}

test_pane_idle_proof_is_required_and_bound() {
  local dir root home fakebin state proof key
  new_case pane-idle-proof
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *capture-pane*) printf '%s\n' "${FM_FAKE_TMUX_CAPTURE:-idle prompt}" ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  write_meta "$state" pane-proof-x1 pane-proof-inc
  export FM_FAKE_CREW_STATE_PANE_PROOF_X1='state: done · source: pane · proof required'
  proof="$state/.pane-idle/pane-proof-x1"
  key=$(printf '%s' tmux:fm-pane-proof-x1 | tr ':/.' '___')
  rm -f "$proof"
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "missing pane-idle proof scan failed"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "missing pane-idle proof was accepted"
  write_idle_proof "$state" pane-proof-x1 tmux tmux:fm-pane-proof-x1
  replace_field "$proof" observed_epoch 1
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "stale pane-idle proof scan failed"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "stale pane-idle proof was accepted"
  write_idle_proof "$state" pane-proof-x1 tmux tmux:fm-pane-proof-x1
  printf '%s\n' 00000000000000000000000000000000 > "$state/.hash-$key"
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "changed pane-idle hash scan failed"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "changed pane-idle hash was accepted"
  write_idle_proof "$state" pane-proof-x1 tmux tmux:fm-pane-proof-x1
  replace_field "$state/pane-proof-x1.meta" spawn_incarnation pane-proof-inc-2
  set_old_mtime "$state/pane-proof-x1.meta"
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "mismatched incarnation scan failed"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "mismatched pane-idle incarnation was accepted"
  write_idle_proof "$state" pane-proof-x1 tmux tmux:fm-pane-proof-x1
  export FM_FAKE_TMUX_CAPTURE='Working...'
  export FM_BUSY_REGEX='Working\.\.\.'
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "busy pane-idle proof scan failed"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "busy pane-idle proof was accepted"
  export FM_FAKE_TMUX_CAPTURE='idle prompt'
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "valid pane-idle proof scan failed"
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "valid pane-idle proof was not accepted"
  unset FM_BUSY_REGEX FM_FAKE_TMUX_CAPTURE FM_FAKE_CREW_STATE_PANE_PROOF_X1
  pass "inactive replay requires a fresh identity-bound pane-idle proof"
}

test_pane_idle_publication_rechecks_under_lock() {
  local dir root home fakebin state count_file scan_status
  new_case pane-idle-publication-race
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  count_file="$dir/tmux-capture-count"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *capture-pane*)
    count=$(cat "${FM_FAKE_TMUX_COUNT_FILE:?}" 2>/dev/null || printf '0')
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_FAKE_TMUX_COUNT_FILE"
    if [ "$count" = 1 ]; then
      printf 'idle prompt\n'
    else
      printf 'Working...\n'
    fi
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  write_meta "$state" pane-race-x1 pane-race-inc
  export FM_FAKE_CREW_STATE_PANE_RACE_X1='state: done · source: pane · publication race'
  export FM_FAKE_TMUX_COUNT_FILE="$count_file"
  : > "$count_file"
  scan_status=0
  scan "$root" "$home" "$fakebin" --startup >/dev/null 2>&1 || scan_status=$?
  [ "$scan_status" = 0 ] || fail "publication-boundary pane retry was not reported as deferred"
  [ "$(cat "$count_file")" -ge 2 ] || fail "publication-boundary pane was not revalidated"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "busy publication-boundary pane created a receipt"
  [ "$(queue_count "$state")" = 0 ] || fail "busy publication-boundary pane created a wake"
  [ -e "$state/.inactive-outcome-find.pending" ] || [ -e "$state/.inactive-outcome-find.retry" ] \
    || fail "publication-boundary failure discarded the durable retry path"
  [ ! -e "$state/.inactive-outcome-reconcile" ] || fail "publication-boundary failure advanced the cadence marker"
  unset FM_FAKE_TMUX_COUNT_FILE FM_FAKE_CREW_STATE_PANE_RACE_X1
  pass "inactive receipt publication rechecks pane idleness under lock"
}

test_pane_idle_index_reclaims_retired_windows() {
  local dir root home fakebin state window key live_window live_key index_dir
  new_case pane-idle-index-retirement
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" retired-index-x1 retired-index-inc
  write_meta "$state" live-index-x2 live-index-inc ship tmux tmux:fm-live-index-x2
  window=tmux:fm-retired-index-x1
  live_window=tmux:fm-live-index-x2
  if command -v shasum >/dev/null 2>&1; then
    key=$(printf '%s' "$window" | shasum -a 256 | awk '{print $1}')
  else
    key=$(printf '%s' "$window" | sha256sum | awk '{print $1}')
  fi
  if command -v shasum >/dev/null 2>&1; then
    live_key=$(printf '%s' "$live_window" | shasum -a 256 | awk '{print $1}')
  else
    live_key=$(printf '%s' "$live_window" | sha256sum | awk '{print $1}')
  fi
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "initial pane-idle index scan failed"
  index_dir="$state/.inactive-outcome-pane-idle-index"
  [ -f "$index_dir/$key" ] || fail "initial pane-idle index entry was not published"
  [ -f "$index_dir/$live_key" ] || fail "complete current pane-idle snapshot omitted the live window"
  rm -f "$state/retired-index-x1.meta" "$state/retired-index-x1.status" "$state/retired-index-x1.turn-ended"
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "retired pane-idle index scan failed"
  [ ! -e "$index_dir/$key" ] || fail "retired pane-idle index entry was not reclaimed"
  [ -f "$index_dir/$live_key" ] || fail "retired-key reclamation removed the live snapshot entry"
  [ -f "$index_dir/.ready" ] || fail "pane-idle index did not publish a complete current snapshot"
  pass "pane-idle index reclaims retired windows after publication"
}

test_pane_idle_index_refreshes_changed_metadata() {
  local dir root home fakebin state
  new_case pane-idle-index-refresh
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" cached-index-x1 cached-index-inc
  env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '
      . "$1/bin/fm-pane-idle-lib.sh"
      fm_pane_idle_meta_index_build "$2" || exit 1
      [ "$(fm_pane_idle_meta_for_window "$2" tmux:fm-cached-index-x1)" = "$2/cached-index-x1.meta" ] || exit 1
      sleep 1
      printf "task=cached-index-x2\nwindow=tmux:fm-cached-index-x2\n" > "$2/cached-index-x2.meta"
      fm_pane_idle_meta_index_build "$2" || exit 1
      [ "$(fm_pane_idle_meta_for_window "$2" tmux:fm-cached-index-x2)" = "$2/cached-index-x2.meta" ]
    ' _ "$ROOT" "$state" \
    || fail "long-lived pane index did not refresh after metadata creation"
  pass "pane-idle index refreshes after metadata creation"
}

test_pane_idle_index_retries_metadata_stamp_race() {
  local dir root home fakebin state flag
  new_case pane-idle-index-race
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  flag="$dir/race.flag"
  printf 'window=tmux:fm-race-a\n' > "$state/race-a.meta"
  cat > "$fakebin/perl" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = - ] && [ "${2:-}" = "${FM_TEST_RACE_STATE:-}" ] \
  && [ ! -e "${FM_TEST_RACE_FLAG:-}" ]; then
  tmp=$(mktemp "${FM_TEST_RACE_DIR:?}/perl-output.XXXXXX")
  /usr/bin/perl "$@" > "$tmp"
  rc=$?
  printf 'window=tmux:fm-race-b\n' > "$FM_TEST_RACE_STATE/race-b.meta"
  cat "$tmp"
  rm -f "$tmp"
  : > "$FM_TEST_RACE_FLAG"
  exit "$rc"
fi
exec /usr/bin/perl "$@"
SH
  chmod +x "$fakebin/perl"
  env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_TEST_RACE_STATE="$state" FM_TEST_RACE_FLAG="$flag" FM_TEST_RACE_DIR="$dir" \
    PATH="$fakebin:$PATH" bash -c '
      . "$1/bin/fm-pane-idle-lib.sh"
      fm_pane_idle_meta_index_build "$2" || exit 1
      [ "$(fm_pane_idle_meta_for_window "$2" tmux:fm-race-b)" = "$2/race-b.meta" ]
    ' _ "$ROOT" "$state" \
    || fail "metadata stamp race published an incomplete pane-idle index"
  pass "pane-idle index retries metadata stamp races"
}

test_pane_idle_index_rejects_publication_stamp_race() {
  local dir root home fakebin state index key flag status
  new_case pane-idle-index-publication-race
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"; index="$state/index"; flag="$dir/publication-race.flag"
  mkdir -p "$index"
  write_meta "$state" publication-race-x1 publication-race-inc
  if command -v shasum >/dev/null 2>&1; then
    key=$(printf '%s' tmux:fm-publication-race-x1 | shasum -a 256 | awk '{print $1}')
  else
    key=$(printf '%s' tmux:fm-publication-race-x1 | sha256sum | awk '{print $1}')
  fi
  : > "$flag"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
source_file="${@: -2:1}"
target="${!#}"
if [ "$target" = "${FM_TEST_PUBLICATION_PATH:?}" ] && [ -e "${FM_TEST_PUBLICATION_FLAG:?}" ]; then
  rm -f "$FM_TEST_PUBLICATION_FLAG"
  printf 'window=tmux:fm-publication-race-x2\n' > "$FM_TEST_PUBLICATION_STATE/publication-race-x2.meta"
fi
exec /usr/bin/mv "$@"
SH
  chmod +x "$fakebin/mv"
  set +e
  env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_TEST_PUBLICATION_PATH="$index/$key" FM_TEST_PUBLICATION_FLAG="$flag" \
    FM_TEST_PUBLICATION_STATE="$state" PATH="$fakebin:$PATH" \
    bash -c '. "$1/bin/fm-pane-idle-lib.sh"; fm_pane_idle_meta_index_persist "$2" "$3"' _ \
    "$ROOT" "$state" "$index"
  status=$?
  set -u
  [ "$status" = 124 ] || fail "publication stamp race was accepted as current"
  [ ! -e "$index/.ready" ] || fail "publication stamp race left a ready marker"
  env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_TEST_PUBLICATION_PATH="$index/$key" FM_TEST_PUBLICATION_FLAG="$flag" \
    FM_TEST_PUBLICATION_STATE="$state" PATH="$fakebin:$PATH" bash -c \
    '. "$1/bin/fm-pane-idle-lib.sh"; fm_pane_idle_meta_index_persist "$2" "$3"' _ \
    "$ROOT" "$state" "$index" \
    || fail "pane-idle index did not recover after publication stamp race"
  [ -f "$index/.ready" ] || fail "recovered pane-idle index was not marked ready"
  pass "pane-idle publication validates final state stamps"
}

test_watcher_bounded_metadata_fail_closed() {
  local dir root home fakebin state status
  new_case watcher-bounded-metadata
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  cp -a "$ROOT/bin/." "$root/bin/"
  write_meta "$state" bounded-metadata-x1 bounded-metadata-inc
  prepare_primary_proof "$root" "$home" "$fakebin"
  set +e
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
    _FM_WORKER_ISOLATION_SNAPSHOT_READY=0 FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    PATH="$fakebin:$PATH" \
    bash -c '
      cd "$1" || exit 1
      . "$1/bin/fm-watch.sh"
      deadline=$(fm_pane_idle_now_ms)
      if window_kind tmux:fm-bounded-metadata-x1 "$deadline" >/dev/null; then exit 1; fi
      if window_backend tmux:fm-bounded-metadata-x1 "$deadline" >/dev/null; then exit 1; fi
      fresh_deadline=$(( $(fm_pane_idle_now_ms) + 1000 ))
      [ "$(recorded_windows "$fresh_deadline")" = tmux:fm-bounded-metadata-x1 ] || exit 1
      [ "$(window_kind tmux:fm-bounded-metadata-x1 "$fresh_deadline")" = ship ] || exit 1
      exit 0
    ' _ "$root"
  status=$?
  set -u
  [ "$status" = 0 ] || fail "bounded metadata lookup did not fail closed"
  pass "watcher refuses unresolved bounded metadata"
}

test_pane_idle_snapshot_reads_honor_deadline() {
  local dir root home fakebin state deadline status
  new_case pane-idle-snapshot-deadline
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" snapshot-deadline-x1 snapshot-deadline-inc
  cat > "$fakebin/perl" <<'SH'
#!/usr/bin/env bash
set -u
case "${2:-}" in
  */.pane-idle-meta-index/snapshot) sleep 2 ;;
esac
exec /usr/bin/perl "$@"
SH
  chmod +x "$fakebin/perl"
  set +e
  env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    PATH="$fakebin:$PATH" bash -c '
      . "$1/bin/fm-pane-idle-lib.sh"
      fm_pane_idle_meta_index_build "$2" || exit 1
      deadline=$(( $(fm_pane_idle_now_ms) + 1000 ))
      fm_pane_idle_meta_for_window "$2" tmux:fm-snapshot-deadline-x1 "$deadline" >/dev/null
    ' _ "$ROOT" "$state"
  status=$?
  set -u
  [ "$status" = 124 ] || fail "indexed snapshot lookup ignored its deadline"
  pass "pane-idle snapshot reads honor deadlines"
}

test_pane_idle_snapshot_compare_honors_deadline() {
  local dir root home fakebin state index deadline status
  new_case pane-idle-snapshot-compare-deadline
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"; index="$state/index"
  write_meta "$state" snapshot-compare-x1 snapshot-compare-inc
  mkdir -p "$index"
  cat > "$fakebin/cmp" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${FM_TEST_SLEEP_CMP:-0}" = 1 ]; then sleep 2; fi
exec /usr/bin/cmp "$@"
SH
  chmod +x "$fakebin/cmp"
  env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    PATH="$fakebin:$PATH" FM_TEST_SLEEP_CMP=0 bash -c '
      . "$1/bin/fm-pane-idle-lib.sh"
      fm_pane_idle_meta_index_persist "$2" "$3"
    ' _ "$ROOT" "$state" "$index" \
    || fail "could not create the baseline pane-idle snapshot"
  set +e
  env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    PATH="$fakebin:$PATH" FM_TEST_SLEEP_CMP=1 bash -c '
      . "$1/bin/fm-pane-idle-lib.sh"
      deadline=$(( $(fm_pane_idle_now_ms) + 1000 ))
      fm_pane_idle_meta_index_persist "$2" "$3" "$deadline"
    ' _ "$ROOT" "$state" "$index"
  status=$?
  set -u
  [ "$status" = 124 ] || fail "snapshot comparison ignored its deadline"
  pass "pane-idle snapshot comparisons honor deadlines"
}

test_pane_idle_lookup_propagates_deadline() {
  local dir root home fakebin state deadline status proof
  new_case pane-idle-lookup-deadline
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" deadline-x1 deadline-inc
  proof="$state/.pane-idle/deadline-x1"
  deadline=$(env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1/bin/fm-pane-idle-lib.sh"; fm_pane_idle_now_ms' _ "$ROOT" "$state") \
    || fail "could not create a pane-idle lookup deadline"
  set +e
  env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1/bin/fm-pane-idle-lib.sh"; fm_pane_idle_meta_for_window "$2" tmux:fm-deadline-x1 "$3"' \
    _ "$ROOT" "$state" "$deadline" >/dev/null 2>&1
  status=$?
  set -u
  [ "$status" = 124 ] || fail "pane-idle lookup ignored its deadline"
  env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1/bin/fm-pane-idle-lib.sh"; fm_pane_idle_clear_for_window "$2" tmux:fm-deadline-x1 "$3"' \
    _ "$ROOT" "$state" "$deadline" \
    || fail "deadline-limited pane-idle clear failed"
  [ -f "$proof" ] || fail "deadline-limited clear removed the idle proof"
  pass "pane-idle lookup and clear honor scan deadlines"
}

test_pane_idle_index_resumes_and_rejects_path_cursor() {
  local dir root home fakebin state progress output stamp
  new_case pane-idle-index-cursor
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  progress="$state/.pane-idle-meta-index"
  output="$state/cursor-output"
  write_meta "$state" cursor-a cursor-a-inc
  write_meta "$state" cursor-b cursor-b-inc
  mkdir -p "$progress"
  : > "$output"
  printf '%s\n%s\n' "$state/cursor-a.meta" "$state/cursor-b.meta" > "$progress/.scan.entries"
  printf 'complete\n' > "$progress/.scan.entries.complete"
  stamp=$(env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1/bin/fm-pane-idle-lib.sh"; fm_pane_idle_path_stamp "$2"' \
    _ "$ROOT" "$state") || fail "could not stamp the pane-idle metadata state"
  printf '%s\n' "$stamp" > "$progress/.scan.entries.stamp"
  printf '%s\n' "$state/cursor-a.meta" > "$progress/.scan.cursor"
  env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1/bin/fm-pane-idle-lib.sh"; fm_pane_idle_meta_index_collect "$2" "$3"' \
    _ "$ROOT" "$state" "$output" || fail "valid path cursor did not resume the pane-idle scan"
  [ ! -e "$progress/.scan.seen" ] || \
    ! grep -Fqx "$state/cursor-a.meta" "$progress/.scan.seen" \
    || fail "valid path cursor rescanned its completed metadata"
  grep -Fqx "$state/cursor-b.meta" "$progress/.scan.seen" \
    || fail "valid path cursor skipped the remaining metadata"

  new_case pane-idle-index-invalid-cursor
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  progress="$state/.pane-idle-meta-index"
  output="$state/cursor-output"
  write_meta "$state" invalid-a invalid-a-inc
  mkdir -p "$progress"
  : > "$output"
  printf '%s\n' "$state/invalid-a.meta" > "$progress/.scan.entries"
  printf 'complete\n' > "$progress/.scan.entries.complete"
  stamp=$(env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1/bin/fm-pane-idle-lib.sh"; fm_pane_idle_path_stamp "$2"' \
    _ "$ROOT" "$state") || fail "could not stamp the invalid cursor state"
  printf '%s\n' "$stamp" > "$progress/.scan.entries.stamp"
  printf '/tmp/unsafe-pane-idle.meta\n' > "$progress/.scan.cursor"
  if env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1/bin/fm-pane-idle-lib.sh"; fm_pane_idle_meta_index_collect "$2" "$3"' \
    _ "$ROOT" "$state" "$output"; then
    fail "unsafe path cursor was accepted"
  fi
  [ ! -s "$progress/.scan.seen" ] || fail "unsafe path cursor processed metadata"
  pass "pane-idle scan resumes valid path cursors and rejects unsafe cursors"
}

test_pane_idle_index_retries_partial_publication_idempotently() {
  local dir root home fakebin state progress output stamp
  local record_fields aggregate_lines
  new_case pane-idle-index-idempotency
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  progress="$state/.pane-idle-meta-index"
  output="$state/idempotent-output"
  write_meta "$state" idempotent-x1 idempotent-inc
  mkdir -p "$progress"
  : > "$output"
  printf '%s\n' "$state/idempotent-x1.meta" > "$progress/.scan.entries"
  printf 'complete\n' > "$progress/.scan.entries.complete"
  stamp=$(env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1/bin/fm-pane-idle-lib.sh"; fm_pane_idle_path_stamp "$2"' \
    _ "$ROOT" "$state") || fail "could not stamp the idempotency state"
  printf '%s\n' "$stamp" > "$progress/.scan.entries.stamp"
  env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1/bin/fm-pane-idle-lib.sh"; fm_pane_idle_meta_index_collect "$2" "$3"' \
    _ "$ROOT" "$state" "$output" || fail "initial pane-idle index build failed"
  rm -f "$progress/.scan.complete" "$progress/.scan.aggregate.complete" \
    "$progress/.scan.sorted" "$progress/.scan.sorted.complete"
  printf '%s\n' "$state/0.meta" > "$progress/.scan.cursor"
  printf '0\n' > "$progress/.scan.aggregate.cursor"
  env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1/bin/fm-pane-idle-lib.sh"; fm_pane_idle_meta_index_collect "$2" "$3"' \
    _ "$ROOT" "$state" "$output" || fail "partial pane-idle index retry failed"
  record_fields=$(tr -cd '\0' < "$progress/.scan.records" | wc -c | tr -d ' ')
  [ "$record_fields" = 3 ] || fail "partial retry duplicated the metadata record"
  [ "$(grep -Fxc "$state/idempotent-x1.meta" "$progress/.scan.seen")" = 1 ] \
    || fail "partial retry duplicated the seen marker"
  aggregate_lines=$(wc -l < "$progress/.scan.aggregate" | tr -d ' ')
  [ "$aggregate_lines" = 1 ] || fail "partial retry duplicated the aggregate mapping"
  pass "pane-idle partial publication retries without duplicate records"
}

test_secondmate_route_accepts_effective_state_overrides() {
  local dir root home fakebin child_home child_state effective_state pending_dir corr marker
  new_case secondmate-effective-state
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  child_home="$dir/secondmate-home"
  child_state="$child_home/state"
  effective_state="$dir/effective-state"
  pending_dir="$dir/effective-pending"
  marker="$child_state/.fm-jt-parent-route"
  mkdir -p "$child_state" "$child_home/data" "$child_home/config" "$effective_state"
  printf 'sm-effective\n' > "$child_home/.fm-secondmate-home"
  : > "$effective_state/sm-effective.status"
  corr=$(env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$effective_state" FM_PENDING_REPLY_DIR_OVERRIDE="$pending_dir" \
    bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_create "$2" "$3" sm-effective "effective state request"' \
    _ "$ROOT" "$home" "$effective_state") \
    || fail "effective-state pending record was not created"
  env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$effective_state" FM_PENDING_REPLY_DIR_OVERRIDE="$pending_dir" \
    bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_secondmate_route_write "$2" "$3" "$4" "$5" "$6"' \
    _ "$ROOT" "$child_home" "$home" "$effective_state" sm-effective "$corr" \
    || fail "effective-state secondmate route was rejected"
  [ -f "$marker" ] || fail "effective-state route marker was not written"
  [ "$(receipt_value "$marker" parent_status)" = "$effective_state/sm-effective.status" ] \
    || fail "effective-state route serialized the wrong parent status"
  env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$effective_state" FM_PENDING_REPLY_DIR_OVERRIDE="$pending_dir" \
    bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_secondmate_route_validate "$2" "$3" 2' \
    _ "$ROOT" "$child_home" "$corr" \
    || fail "effective-state secondmate route did not validate"
  unset FM_STATE_OVERRIDE FM_PENDING_REPLY_DIR_OVERRIDE
  pass "secondmate routes validate effective state and pending-reply overrides"
}

test_valid_secondmate_route_reports_parent_once() {
  local dir root home fakebin state child_home child_state parent_status corr rec outside send_out route_backup
  local outside_parent outside_parent_link other_parent fail_move_once
  local history_corr history_record history_status active_record active_backup
  new_case secondmate-route-valid
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  cp -a "$ROOT/bin/." "$root/bin/"
  child_home="$dir/secondmate-home"
  child_state="$child_home/state"
  mkdir -p "$child_state" "$child_state/terminal-outcomes" "$child_home/data" "$child_home/config" \
    "$state/pending-replies" "$state/pending-reply-history"
  printf 'sm-valid\n' > "$child_home/.fm-secondmate-home"
  write_meta "$state" sm-valid parent-inc secondmate tmux firstmate:fm-sm-valid
  printf 'home=%s\n' "$child_home" >> "$state/sm-valid.meta"
  write_meta "$child_state" child-x1 child-inc
  parent_status="$state/sm-valid.status"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{cursor_y}"*) printf '1\n' ;;
  *capture-pane*)
    case "$*" in
      *" -S -40"*) printf 'idle prompt\n' ;;
      *) : ;;
    esac
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  prepare_primary_proof "$root" "$home" "$fakebin"
  prepare_watcher_protocol "$root" "$home" "$state"
  send_out=$(cd "$root" && env -u NO_MISTAKES_GATE -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
    -u FM_ROOT -u STATE PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 "$root/bin/fm-send.sh" \
    fm-sm-valid "parent request" 2>&1) || fail "public fm-send route setup failed: $send_out"
  corr=$(basename "$(direct_first_file "$state/pending-replies" '*')")
  [ -n "$corr" ] || fail "public fm-send did not create a correlation record"
  export FM_FAKE_CREW_STATE_CHILD_X1='state: failed · source: pane · child quiet'
  scan "$root" "$child_home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$child_state" pending)" = 1 ] || fail "valid secondmate route did not create a pending receipt"
  rec=$(direct_first_file "$child_state/terminal-outcomes" '*.pending')
  [ "$(receipt_value "$rec" parent_task_id)" = sm-valid ] || fail "secondmate receipt did not persist its parent task identity"
  [ "$(receipt_value "$rec" parent_corr)" = "$corr" ] || fail "secondmate receipt did not persist its parent correlation"
  [ "$(receipt_value "$rec" parent_home)" = "$home" ] || fail "secondmate receipt did not persist its parent home"
  [ "$(receipt_value "$rec" parent_status)" = "$parent_status" ] || fail "secondmate receipt did not persist its parent status path"
  other_parent="$dir/other-parent"
  mkdir -p "$other_parent"
  replace_field "$state/pending-replies/$corr" parent_home "$other_parent"
  if drain "$root" "$child_home" "$fakebin" >/dev/null 2>&1; then
    fail "secondmate acknowledgement accepted a mismatched real parent home"
  fi
  [ "$(receipt_count "$child_state" pending)" = 1 ] || fail "mismatched real parent home consumed the pending receipt"
  replace_field "$state/pending-replies/$corr" parent_home "$home"
  route_backup="$dir/route-backup"
  mv "$child_state/.fm-jt-parent-route" "$route_backup"
  if drain "$root" "$child_home" "$fakebin" >/dev/null 2>&1; then
    fail "secondmate acknowledgement accepted a missing route marker"
  fi
  [ "$(receipt_count "$child_state" pending)" = 1 ] || fail "missing route marker consumed the pending receipt"
  ! grep -Fq "failed [corr=$corr]: inactive terminal outcome replayed: task=child-x1" "$parent_status" 2>/dev/null \
    || fail "missing route marker wrote parent status"
  mv "$route_backup" "$child_state/.fm-jt-parent-route"
  replace_field "$child_state/.fm-jt-parent-route" corr_id 1123456789abcdef
  if drain "$root" "$child_home" "$fakebin" >/dev/null 2>&1; then
    fail "secondmate acknowledgement accepted a mismatched route marker"
  fi
  [ "$(receipt_count "$child_state" pending)" = 1 ] || fail "mismatched route marker consumed the pending receipt"
  ! grep -Fq "failed [corr=$corr]: inactive terminal outcome replayed: task=child-x1" "$parent_status" 2>/dev/null \
    || fail "mismatched route marker wrote parent status"
  replace_field "$child_state/.fm-jt-parent-route" corr_id "$corr"
  active_record="$state/pending-replies/$corr"
  active_backup="$dir/active-record-backup"
  mkdir -p "$state/pending-reply-history"
  cp "$active_record" "$state/pending-reply-history/$corr"
  mv "$active_record" "$active_backup"
  ln -s "$active_backup" "$active_record"
  if drain "$root" "$child_home" "$fakebin" >/dev/null 2>&1; then
    fail "secondmate receipt validation fell through a symlinked active record"
  fi
  [ "$(receipt_count "$child_state" pending)" = 1 ] || fail "symlinked active record lost the pending receipt"
  rm -f "$active_record" "$state/pending-reply-history/$corr"
  mv "$active_backup" "$active_record"
  outside_parent="$dir/outside-parent"
  outside_parent_link="$dir/outside-parent-link"
  mkdir -p "$outside_parent/state"
  ln -s "$outside_parent" "$outside_parent_link"
  replace_field "$rec" parent_home "$outside_parent_link"
  if drain "$root" "$child_home" "$fakebin" >/dev/null 2>&1; then
    fail "secondmate acknowledgement accepted a symlinked parent home"
  fi
  [ ! -e "$outside_parent/state/pending-replies/.txn-$corr.lock" ] \
    || fail "secondmate acknowledgement acquired a transaction lock before path validation"
  replace_field "$rec" parent_home "$home"
  outside="$dir/outside-status"
  printf 'outside\n' > "$outside"
  rm -f "$parent_status"
  ln -s "$outside" "$parent_status"
  if drain "$root" "$child_home" "$fakebin" >/dev/null 2>&1; then
    fail "secondmate acknowledgement followed a parent status symlink"
  fi
  [ "$(receipt_count "$child_state" pending)" = 1 ] || fail "symlinked parent status lost the pending receipt"
  rm -f "$parent_status"
  fail_move_once="$dir/fail-mv-once"
  : > "$fail_move_once"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  case "$arg" in
    *.pending)
      if [ -e "${FM_TEST_FAIL_MOVE_ONCE:?}" ]; then
        rm -f "$FM_TEST_FAIL_MOVE_ONCE"
        exit 42
      fi
      ;;
  esac
done
exec /bin/mv "$@"
SH
  chmod +x "$fakebin/mv"
  export FM_TEST_FAIL_MOVE_ONCE="$fail_move_once"
  if drain "$root" "$child_home" "$fakebin" >/dev/null 2>&1; then
    fail "secondmate acknowledgement hid a receipt move failure"
  fi
  [ "$(receipt_count "$child_state" pending)" = 1 ] || fail "receipt move failure consumed the pending receipt"
  [ -f "$child_state/.fm-jt-parent-route" ] || fail "receipt move failure cleared the route before transition"
  rm -f "$fakebin/mv"
  if ! drain "$root" "$child_home" "$fakebin" >"$dir/second-drain.out" 2>&1; then
    cat "$dir/second-drain.out" >&2
    fail "valid secondmate route drain failed after symlink removal"
  fi
  ! grep -F 'inactive-outcome:' "$dir/second-drain.out" >/dev/null \
    || fail "already-recorded parent report was presented again"
  [ "$(receipt_count "$child_state" reported)" = 1 ] || fail "valid secondmate route was not reported"
  [ ! -e "$child_state/.fm-jt-parent-route" ] || fail "reported secondmate route was not cleared after its parent report"
  grep -F "failed [corr=$corr]: inactive terminal outcome replayed: task=child-x1" "$parent_status" >/dev/null \
    || fail "valid secondmate route did not append the correlated parent status"
  drain "$root" "$child_home" "$fakebin" >/dev/null
  [ "$(grep -Fc "failed [corr=$corr]: inactive terminal outcome replayed: task=child-x1" "$parent_status")" = 1 ] \
    || fail "secondmate parent report was duplicated"
  unset FM_TEST_FAIL_MOVE_ONCE

  printf 'sm-history\n' > "$child_home/.fm-secondmate-home"
  write_meta "$state" sm-history history-parent-inc secondmate tmux firstmate:fm-sm-history
  printf 'home=%s\n' "$child_home" >> "$state/sm-history.meta"
  history_status="$state/sm-history.status"
  prepare_primary_proof "$root" "$home" "$fakebin"
  send_out=$(cd "$root" && env -u NO_MISTAKES_GATE -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
    -u FM_ROOT -u STATE PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 "$root/bin/fm-send.sh" \
    fm-sm-history "history request" 2>&1) || fail "public fm-send history route setup failed: $send_out"
  history_corr=
  for history_record in "$state"/pending-replies/*; do
    [ -f "$history_record" ] || continue
    [ "$(basename "$history_record")" = "$corr" ] || history_corr=$(basename "$history_record")
  done
  [ -n "$history_corr" ] || fail "public fm-send did not create a distinct history correlation"
  history_record="$state/pending-replies/$history_corr"
  replace_field "$history_record" phase resolved
  (cd "$root" && env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_archive_terminal "$2" "$3"' \
    _ "$ROOT" "$state" "$history_corr") \
    || fail "parent terminal lifecycle did not archive the history record"
  [ -f "$state/pending-reply-history/$history_corr" ] || fail "parent history record was not archived"
  write_meta "$child_state" child-history-x1 child-history-inc
  export FM_FAKE_CREW_STATE_CHILD_HISTORY_X1='state: done · source: pane · history child quiet'
  scan "$root" "$child_home" "$fakebin" --startup \
    || fail "pending-reply-history route scan failed"
  [ "$(receipt_count "$child_state" pending)" = 1 ] || fail "pending-reply-history route did not create a pending receipt"
  rec=$(direct_first_file "$child_state/terminal-outcomes" '*.pending')
  [ "$(receipt_value "$rec" parent_corr)" = "$history_corr" ] \
    || fail "history route receipt used the wrong parent correlation"
  drain "$root" "$child_home" "$fakebin" >/dev/null \
    || fail "pending-reply-history route drain failed"
  [ "$(receipt_count "$child_state" reported)" = 2 ] || fail "history route receipt was not reported"
  [ ! -e "$child_state/.fm-jt-parent-route" ] || fail "history route marker was not cleared after presentation"
  ! grep -F 'inactive terminal outcome replayed: task=child-history-x1' "$history_status" >/dev/null 2>&1 \
    || fail "resolved history route appended a duplicate parent status"
  unset FM_FAKE_CREW_STATE_CHILD_X1 FM_FAKE_CREW_STATE_CHILD_HISTORY_X1
  pass "valid secondmate outcomes use the parent status correlation exactly once"
}

test_deferred_recorded_secondmate_finishes_without_output() {
  local dir root home fakebin state child_home child_state parent_status corr rec fingerprint line send_out
  new_case secondmate-recorded-deferred
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  cp -a "$ROOT/bin/." "$root/bin/"
  child_home="$dir/secondmate-home"
  child_state="$child_home/state"
  parent_status="$state/sm-recorded.status"
  mkdir -p "$child_state" "$child_state/terminal-outcomes" "$child_home/data" "$child_home/config" \
    "$state/pending-replies" "$state/pending-reply-history"
  printf 'sm-recorded\n' > "$child_home/.fm-secondmate-home"
  write_meta "$state" sm-recorded parent-inc secondmate tmux firstmate:fm-sm-recorded
  printf 'home=%s\n' "$child_home" >> "$state/sm-recorded.meta"
  write_meta "$child_state" child-recorded-x1 child-recorded-inc
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{cursor_y}"*) printf '1\n' ;;
  *capture-pane*)
    case "$*" in
      *" -S -40"*) printf 'idle prompt\n' ;;
      *) : ;;
    esac
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  prepare_primary_proof "$root" "$home" "$fakebin"
  prepare_watcher_protocol "$root" "$home" "$state"
  send_out=$(cd "$root" && env -u NO_MISTAKES_GATE -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
    -u FM_ROOT -u STATE PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 "$root/bin/fm-send.sh" \
    fm-sm-recorded "parent request" 2>&1) || fail "recorded secondmate route setup failed: $send_out"
  corr=$(basename "$(direct_first_file "$state/pending-replies" '*')")
  [ -n "$corr" ] || fail "recorded secondmate route did not create a correlation"
  export FM_FAKE_CREW_STATE_CHILD_RECORDED_X1='state: failed · source: pane · child already reported'
  scan "$root" "$child_home" "$fakebin" --startup >/dev/null \
    || fail "recorded secondmate scan failed"
  rec=$(direct_first_file "$child_state/terminal-outcomes" '*.pending')
  fingerprint=$(basename "$rec" .pending)
  line="failed [corr=$corr]: inactive terminal outcome replayed: task=child-recorded-x1 fingerprint=$fingerprint"
  printf '%s\n' "$line" >> "$parent_status"
  export FM_WAKE_DRAIN_DEFER_ACK=1 FM_WAKE_DRAIN_GENERATION="$$"
  drain "$root" "$child_home" "$fakebin" >"$dir/recorded-deferred.out" \
    || fail "recorded secondmate deferred drain failed"
  [ ! -s "$dir/recorded-deferred.out" ] \
    || fail "already-recorded secondmate receipt was presented to the caller"
  [ "$(receipt_count "$child_state" pending)" = 0 ] \
    || fail "already-recorded secondmate receipt remained pending"
  [ "$(receipt_count "$child_state" reported)" = 1 ] \
    || fail "already-recorded secondmate receipt was not finalized"
  [ "$(queue_count "$child_state")" = 0 ] \
    || fail "already-recorded secondmate wake remained queued"
  [ ! -e "$child_state/.fm-jt-parent-route" ] \
    || fail "already-recorded secondmate route was not cleared"
  [ "$(grep -Fc "$line" "$parent_status")" = 1 ] \
    || fail "already-recorded secondmate parent report was duplicated"
  unset FM_WAKE_DRAIN_DEFER_ACK FM_WAKE_DRAIN_GENERATION FM_FAKE_CREW_STATE_CHILD_RECORDED_X1
  pass "recorded secondmate reports finalize without caller output"
}

test_reported_secondmate_route_repair_after_crash() {
  local dir root home fakebin state child_home child_state parent_status corr fingerprint flag
  new_case secondmate-reported-route-repair
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  child_home="$dir/secondmate-home"
  child_state="$child_home/state"
  parent_status="$state/sm-reported.status"
  corr=0123456789abcdef
  mkdir -p "$child_state" "$child_state/terminal-outcomes" "$child_home/data" "$child_home/config" \
    "$state/pending-replies" "$state/pending-reply-history"
  printf 'sm-reported\n' > "$child_home/.fm-secondmate-home"
  fm_write_meta "$state/pending-replies/$corr" \
    schema=fm-pending-reply.v1 corr_id="$corr" task_id=sm-reported \
    parent_home="$home" parent_status="$parent_status" delivered_epoch=1 phase=awaiting_report
  env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_secondmate_route_write "$2" "$3" "$4" "$5" "$6"' \
    _ "$ROOT" "$child_home" "$home" "$state" sm-reported "$corr" \
    || fail "reported route fixture was not written"
  fingerprint=$(receipt_fingerprint 'child-reported-x1|child-reported-inc|failed|state: failed · source: pane · reported crash' secondmate)
  fm_write_meta "$child_state/terminal-outcomes/$fingerprint.reported" \
    schema=fm-jt-terminal-outcome.v1 fingerprint="$fingerprint" task_id=child-reported-x1 \
    incarnation=child-reported-inc outcome=failed terminal_source=pane \
    terminal_snapshot='state: failed · source: pane · reported crash' kind=secondmate \
    parent_task_id=sm-reported parent_home="$home" parent_status="$parent_status" parent_corr="$corr"
  flag="$dir/fail-route-clear-once"
  : > "$flag"
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  if [ "$arg" = "${FM_TEST_ROUTE_RM_PATH:-}" ] && [ -e "${FM_TEST_ROUTE_RM_ONCE:-}" ]; then
    /bin/rm -f "$FM_TEST_ROUTE_RM_ONCE"
    exit 42
  fi
done
exec /bin/rm "$@"
SH
  chmod +x "$fakebin/rm"
  export FM_TEST_ROUTE_RM_PATH="$child_state/.fm-jt-parent-route" FM_TEST_ROUTE_RM_ONCE="$flag"
  if scan "$root" "$child_home" "$fakebin" --startup >/dev/null 2>&1; then
    fail "reported route cleanup failure was hidden"
  fi
  [ -f "$child_state/terminal-outcomes/$fingerprint.reported" ] \
    || fail "reported receipt was lost during route cleanup failure"
  [ -e "$child_state/.fm-jt-parent-route" ] \
    || fail "route was removed before reported cleanup completed"
  rm -f "$fakebin/rm"
  unset FM_TEST_ROUTE_RM_PATH FM_TEST_ROUTE_RM_ONCE
  scan "$root" "$child_home" "$fakebin" --startup >/dev/null \
    || fail "reported route cleanup did not retry"
  [ ! -e "$child_state/.fm-jt-parent-route" ] \
    || fail "reported route remained after retry"
  pass "reported secondmate routes recover after receipt finalization crashes"
}

test_reported_route_repair_is_bounded() {
  local dir root home fakebin state fingerprint first second index
  new_case reported-route-repair-limit
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  mkdir -p "$state/terminal-outcomes"
  for index in 1 2 3; do
    fingerprint=$(receipt_fingerprint "reported-limit-x${index}|reported-limit-inc-${index}|done|reported limit ${index}")
    fm_write_meta "$state/terminal-outcomes/$fingerprint.reported" \
      schema=fm-jt-terminal-outcome.v1 fingerprint="$fingerprint" task_id="reported-limit-x${index}" \
      incarnation="reported-limit-inc-${index}" outcome=done terminal_source=pane \
      terminal_snapshot="reported limit ${index}" kind=ship
  done
  export FM_REPORTED_ROUTE_REPAIR_LIMIT=1
  scan "$root" "$home" "$fakebin" --startup >/dev/null \
    || fail "bounded reported-receipt maintenance failed on the first scan"
  first=$(cat "$state/.reported-secondmate-route-repair.cursor" 2>/dev/null || true)
  [ -n "$first" ] || fail "bounded reported-receipt maintenance did not persist a cursor"
  scan "$root" "$home" "$fakebin" --startup >/dev/null \
    || fail "bounded reported-receipt maintenance failed on the second scan"
  second=$(cat "$state/.reported-secondmate-route-repair.cursor" 2>/dev/null || true)
  [ -n "$second" ] && [ "$second" != "$first" ] \
    || fail "bounded reported-receipt maintenance did not advance incrementally"
  [ "$(receipt_count "$state" reported)" = 3 ] \
    || fail "bounded reported-receipt maintenance discarded durable receipts"
  unset FM_REPORTED_ROUTE_REPAIR_LIMIT
  pass "reported route maintenance advances through bounded receipt batches"
}

test_pending_receipt_republish_is_bounded() {
  local dir root home fakebin state fingerprint first second index
  new_case pending-receipt-republish-limit
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  mkdir -p "$state/terminal-outcomes"
  for index in 1 2 3; do
    write_meta "$state" "pending-limit-x${index}" "pending-limit-inc-${index}"
    fingerprint=$(receipt_fingerprint "pending-limit-x${index}|pending-limit-inc-${index}|done|pending limit ${index}")
    fm_write_meta "$state/terminal-outcomes/$fingerprint.pending" \
      schema=fm-jt-terminal-outcome.v1 fingerprint="$fingerprint" task_id="pending-limit-x${index}" \
      incarnation="pending-limit-inc-${index}" outcome=done terminal_source=pane \
      terminal_snapshot="pending limit ${index}" kind=ship
  done
  export FM_PENDING_RECEIPT_REPUBLISH_LIMIT=1
  scan "$root" "$home" "$fakebin" --startup >/dev/null \
    || fail "bounded pending-receipt maintenance failed on the first scan"
  first=$(cat "$state/.pending-receipt-republish.cursor" 2>/dev/null || true)
  [ -n "$first" ] || fail "bounded pending-receipt maintenance did not persist a cursor"
  [ "$(queue_count "$state")" = 1 ] || fail "bounded pending-receipt maintenance exceeded its first batch"
  scan "$root" "$home" "$fakebin" --startup >/dev/null \
    || fail "bounded pending-receipt maintenance failed on the second scan"
  second=$(cat "$state/.pending-receipt-republish.cursor" 2>/dev/null || true)
  [ -n "$second" ] && [ "$second" != "$first" ] \
    || fail "bounded pending-receipt maintenance did not rotate its cursor"
  [ "$(queue_count "$state")" = 2 ] || fail "bounded pending-receipt maintenance did not republish the next receipt"
  [ "$(receipt_count "$state" pending)" = 3 ] \
    || fail "bounded pending-receipt maintenance discarded durable receipts"
  unset FM_PENDING_RECEIPT_REPUBLISH_LIMIT
  pass "pending-receipt maintenance rotates bounded receipt batches"
}

test_secondmate_route_replacement_preserves_old_receipt() {
  local dir root home fakebin state child_home child_state parent_status corr_a corr_b rec send_out marker history_backup active_route_backup
  new_case secondmate-route-replacement
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  child_home="$dir/secondmate-home"
  child_state="$child_home/state"
  cp -a "$ROOT/bin/." "$root/bin/"
  mkdir -p "$child_state" "$child_home/data" "$child_home/config" "$state/pending-replies"
  printf 'sm-replace\n' > "$child_home/.fm-secondmate-home"
  write_meta "$state" sm-replace parent-replace-inc secondmate tmux firstmate:fm-sm-replace
  printf 'home=%s\n' "$child_home" >> "$state/sm-replace.meta"
  write_meta "$child_state" child-replace-x1 child-replace-inc
  parent_status="$state/sm-replace.status"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{cursor_y}"*) printf '1\n' ;;
  *capture-pane*)
    case "$*" in
      *" -S -40"*) printf 'idle prompt\n' ;;
      *) : ;;
    esac
    ;;
  *) : ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  prepare_primary_proof "$root" "$home" "$fakebin"
  prepare_watcher_protocol "$root" "$home" "$state"
  send_out=$(cd "$root" && env -u NO_MISTAKES_GATE -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
    -u FM_ROOT -u STATE PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 "$root/bin/fm-send.sh" \
    fm-sm-replace "first request" 2>&1) || fail "initial public route setup failed: $send_out"
  corr_a=$(basename "$(direct_first_file "$state/pending-replies" '*')")
  [ -n "$corr_a" ] || fail "initial route did not create a correlation"
  export FM_FAKE_CREW_STATE_CHILD_REPLACE_X1='state: done · source: pane · old route receipt'
  scan "$root" "$child_home" "$fakebin" --startup >/dev/null || fail "old route scan failed"
  rec=$(direct_first_file "$child_state/terminal-outcomes" '*.pending')
  [ -n "$rec" ] || fail "old route did not create a pending receipt"
  replace_field "$state/pending-replies/$corr_a" phase resolved
  prepare_primary_proof "$root" "$home" "$fakebin"
  send_out=$(cd "$root" && env -u NO_MISTAKES_GATE -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
    -u FM_ROOT -u STATE PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 "$root/bin/fm-send.sh" \
    fm-sm-replace "replacement request" 2>&1) || fail "replacement public route setup failed: $send_out"
  corr_b=
  for marker in "$state"/pending-replies/*; do
    [ -f "$marker" ] || continue
    [ "$(basename "$marker")" = "$corr_a" ] || corr_b=$(basename "$marker")
  done
  [ -n "$corr_b" ] || fail "replacement route did not create a new correlation"
  [ "$(receipt_value "$child_state/.fm-jt-parent-route" corr_id)" = "$corr_b" ] \
    || fail "replacement route did not publish the new correlation"
  replace_field "$state/pending-replies/$corr_b" phase awaiting_report
  replace_field "$state/pending-replies/$corr_b" delivered_epoch ''
  active_route_backup="$dir/active-route-backup"
  cp "$child_state/.fm-jt-parent-route" "$active_route_backup"
  replace_field "$child_state/.fm-jt-parent-route" parent_home "$dir/not-a-parent-home"
  : > "$child_state/.wake-queue"
  scan "$root" "$child_home" "$fakebin" --startup \
    || fail "malformed active route scan failed"
  [ "$(queue_count "$child_state")" = 0 ] \
    || fail "malformed active route fell through to history"
  [ "$(receipt_count "$child_state" pending)" = 1 ] \
    || fail "malformed active route consumed the old receipt"
  cp "$active_route_backup" "$child_state/.fm-jt-parent-route"
  history_backup="$dir/history-route-backup"
  [ -f "$child_state/.fm-jt-parent-route-history.$corr_a" ] \
    || fail "replacement route did not retain the old correlation history marker"
  cp "$child_state/.fm-jt-parent-route-history.$corr_a" "$history_backup"
  replace_field "$child_state/.fm-jt-parent-route-history.$corr_a" corr_id "$corr_b"
  : > "$child_state/.wake-queue"
  scan "$root" "$child_home" "$fakebin" --startup \
    || fail "mismatched history marker scan failed"
  [ "$(queue_count "$child_state")" = 0 ] \
    || fail "mismatched history marker created a wake for the wrong route"
  [ "$(receipt_count "$child_state" pending)" = 1 ] \
    || fail "mismatched history marker consumed the old receipt"
  cp "$history_backup" "$child_state/.fm-jt-parent-route-history.$corr_a"
  replace_field "$state/pending-replies/$corr_b" phase delivery_unknown
  : > "$child_state/.wake-queue"
  scan "$root" "$child_home" "$fakebin" --startup \
    || fail "delivery-unknown active route scan failed"
  [ "$(queue_count "$child_state")" = 1 ] \
    || fail "delivery-unknown active route blocked the matching history receipt"
  replace_field "$state/pending-replies/$corr_b" phase awaiting_report
  scan "$root" "$child_home" "$fakebin" --startup \
    || fail "pending old-route receipt was not reconciled after route replacement"
  [ "$(queue_count "$child_state")" = 1 ] \
    || fail "pending old-route receipt did not get a matching history wake"
  drain "$root" "$child_home" "$fakebin" >/dev/null \
    || fail "old receipt did not drain after route replacement"
  [ "$(receipt_count "$child_state" reported)" = 1 ] || fail "old route receipt was not reported"
  [ "$(receipt_value "$child_state/.fm-jt-parent-route" corr_id)" = "$corr_b" ] \
    || fail "old receipt cleanup removed the replacement route"
  [ ! -e "$child_state/.fm-jt-parent-route-history.$corr_a" ] \
    || fail "old route history was not retired after acknowledgement"
  unset FM_FAKE_CREW_STATE_CHILD_REPLACE_X1
  pass "secondmate route replacement preserves correlation-scoped old receipts"
}

test_undelivered_secondmate_route_cleanup_is_idempotent() {
  local dir root home fakebin state child_home child_state marker corr rec fail_rm_once valid_marker
  new_case secondmate-undelivered-cleanup
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  child_home="$dir/secondmate-home"
  child_state="$child_home/state"
  marker="$child_state/.fm-jt-parent-route"
  corr=0123456789abcdef
  mkdir -p "$child_state" "$child_home/data" "$child_home/config" "$state/pending-replies"
  printf 'sm-cleanup\n' > "$child_home/.fm-secondmate-home"
  fm_write_meta "$state/pending-replies/$corr" \
    schema=fm-pending-reply.v1 corr_id="$corr" task_id=sm-cleanup \
    parent_home="$home" parent_status="$state/sm-cleanup.status" phase=awaiting_report delivered_epoch=
  env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_secondmate_route_write "$2" "$3" "$4" "$5" "$6"' \
    _ "$ROOT" "$child_home" "$home" "$state" sm-cleanup "$corr" \
    || fail "undelivered route fixture was not written"
  [ -f "$marker" ] || fail "undelivered route fixture is missing"
  rec="$state/pending-replies/$corr"
  fail_rm_once="$dir/fail-undelivered-rm-once"
  : > "$fail_rm_once"
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  if [ "$arg" = "${FM_TEST_UNDELIVERED_RECORD:-}" ] && [ -e "${FM_TEST_UNDELIVERED_RM_ONCE:-}" ]; then
    /bin/rm -f "$FM_TEST_UNDELIVERED_RM_ONCE"
    exit 42
  fi
done
exec /bin/rm "$@"
SH
  chmod +x "$fakebin/rm"
  export FM_TEST_UNDELIVERED_RECORD="$rec" FM_TEST_UNDELIVERED_RM_ONCE="$fail_rm_once"
  if env PATH="$fakebin:$PATH" FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_discard_undelivered "$2" "$3"' \
    _ "$ROOT" "$state" "$corr"; then
    fail "undelivered record removal failure was hidden"
  fi
  [ -e "$rec" ] || fail "undelivered record was removed after a failed cleanup"
  [ -e "$marker" ] || fail "undelivered route was cleared before record removal"
  valid_marker=$(cat "$marker")
  printf 'malformed=route\n' > "$marker"
  if env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_secondmate_route_clear_undelivered "$2" "$3"' \
    _ "$ROOT" "$child_home" "$corr"; then
    fail "malformed undelivered route cleanup was treated as success"
  fi
  [ -e "$rec" ] || fail "malformed undelivered route cleanup removed the parent record"
  printf '%s\n' "$valid_marker" > "$marker"
  rm -f "$fakebin/rm"
  unset FM_TEST_UNDELIVERED_RECORD FM_TEST_UNDELIVERED_RM_ONCE
  env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_discard_undelivered "$2" "$3"' \
    _ "$ROOT" "$state" "$corr" \
    || fail "undelivered record cleanup did not retry"
  [ ! -e "$rec" ] || fail "undelivered record remained after retry"
  env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_secondmate_route_clear_undelivered "$2" "$3"' \
    _ "$ROOT" "$child_home" "$corr" \
    || fail "undelivered route cleanup rejected an already-removed record"
  [ ! -e "$marker" ] || fail "undelivered route cleanup left a stale marker"
  env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_secondmate_route_clear_undelivered "$2" "$3"' \
    _ "$ROOT" "$child_home" "$corr" \
    || fail "undelivered route cleanup was not idempotent"
  pass "undelivered secondmate route cleanup is safe and idempotent"
}

test_concurrent_secondmate_routes_are_rejected() {
  local dir root home fakebin state child_home child_state marker corr_one corr_two outside existing_real existing_link
  local existing_record record_backup existing_history history_backup clear_real clear_link
  new_case secondmate-route-concurrent
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  child_home="$dir/secondmate-home"
  child_state="$child_home/state"
  marker="$child_state/.fm-jt-parent-route"
  corr_one=0123456789abcdef
  corr_two=1123456789abcdef
  mkdir -p "$child_state" "$child_home/data" "$child_home/config" "$state/pending-replies"
  printf 'sm-concurrent\n' > "$child_home/.fm-secondmate-home"
  fm_write_meta "$state/pending-replies/$corr_one" \
    schema=fm-pending-reply.v1 corr_id="$corr_one" task_id=sm-concurrent \
    parent_home="$home" parent_status="$state/sm-concurrent.status" delivered_epoch=1 phase=awaiting_report
  fm_write_meta "$state/pending-replies/$corr_two" \
    schema=fm-pending-reply.v1 corr_id="$corr_two" task_id=sm-concurrent \
    parent_home="$home" parent_status="$state/sm-concurrent.status" delivered_epoch=1 phase=awaiting_report
  route_write() {
    env PATH="$fakebin:$PATH" FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$state" bash -c \
      '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_secondmate_route_write "$2" "$3" "$4" "$5" "$6"' \
      _ "$ROOT" "$child_home" "$home" "$state" sm-concurrent "$1"
  }
  mv "$child_home/.fm-secondmate-home" "$dir/secondmate-marker"
  ln -s "$dir/secondmate-marker" "$child_home/.fm-secondmate-home"
  if route_write "$corr_one"; then
    fail "symlinked secondmate home marker was accepted"
  fi
  rm -f "$child_home/.fm-secondmate-home"
  mv "$dir/secondmate-marker" "$child_home/.fm-secondmate-home"
  existing_real="$dir/existing-real-home"
  existing_link="$dir/existing-home-link"
  mkdir -p "$existing_real/state/pending-replies"
  fm_write_meta "$existing_real/state/pending-replies/$corr_one" \
    schema=fm-pending-reply.v1 corr_id="$corr_one" task_id=sm-concurrent \
    parent_home="$existing_real" parent_status="$existing_real/state/sm-concurrent.status" \
    delivered_epoch=1 phase=resolved
  ln -s "$existing_real" "$existing_link"
  printf 'schema=fm-jt-parent-route.v1\nsecondmate_id=sm-concurrent\nparent_home=%s\nparent_status=%s\ncorr_id=%s\n' \
    "$existing_link" "$existing_real/state/sm-concurrent.status" "$corr_one" > "$marker"
  if route_write "$corr_two"; then
    fail "existing secondmate home symlink was accepted during route replacement"
  fi
  rm -f "$marker"
  existing_record="$existing_real/state/pending-replies/$corr_one"
  record_backup="$dir/record-backup"
  mv "$existing_record" "$record_backup"
  ln -s "$record_backup" "$existing_record"
  printf 'schema=fm-jt-parent-route.v1\nsecondmate_id=sm-concurrent\nparent_home=%s\nparent_status=%s\ncorr_id=%s\n' \
    "$existing_real" "$existing_real/state/sm-concurrent.status" "$corr_one" > "$marker"
  if route_write "$corr_two"; then
    fail "symlinked active secondmate record was accepted during route replacement"
  fi
  rm -f "$marker" "$existing_record"
  mv "$record_backup" "$existing_record"
  existing_history="$existing_real/state/pending-reply-history/$corr_one"
  history_backup="$dir/history-backup"
  mkdir -p "$existing_real/state/pending-reply-history"
  mv "$existing_record" "$history_backup"
  ln -s "$history_backup" "$existing_history"
  printf 'schema=fm-jt-parent-route.v1\nsecondmate_id=sm-concurrent\nparent_home=%s\nparent_status=%s\ncorr_id=%s\n' \
    "$existing_real" "$existing_real/state/sm-concurrent.status" "$corr_one" > "$marker"
  if route_write "$corr_two"; then
    fail "symlinked history secondmate record was accepted during route replacement"
  fi
  rm -f "$marker" "$existing_history"
  mv "$history_backup" "$existing_record"
  route_write "$corr_one" || fail "initial secondmate route was not written"
  marker_before=$(cat "$marker")
  outside="$dir/temp-target"
  printf 'protected\n' > "$outside"
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  */.fm-jt-parent-route.XXXXXX)
    target="${1%.XXXXXX}blocked"
    rm -f "$target"
    ln -s "$FM_ROUTE_TEMP_TARGET" "$target"
    printf '%s\n' "$target"
    exit 0
    ;;
esac
exec /usr/bin/mktemp "$@"
SH
  chmod +x "$fakebin/mktemp"
  if env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH" FM_ROUTE_TEMP_TARGET="$outside" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_secondmate_route_write "$2" "$3" "$4" "$5" "$6"' \
    _ "$ROOT" "$child_home" "$home" "$state" sm-concurrent "$corr_two"; then
    fail "second route replaced an active route unexpectedly"
  fi
  [ "$(cat "$outside")" = protected ] || fail "route publication followed a pre-created temporary symlink"
  if route_write "$corr_two"; then
    fail "concurrent secondmate route was silently replaced"
  fi
  [ "$(cat "$marker")" = "$marker_before" ] || fail "concurrent route rejection changed the active marker"
  clear_real="$dir/clear-real"
  clear_link="$dir/clear-link"
  mkdir -p "$clear_real/state"
  printf 'schema=fm-jt-parent-route.v1\nsecondmate_id=sm-concurrent\nparent_home=%s\nparent_status=%s\ncorr_id=%s\n' \
    "$home" "$state/sm-concurrent.status" "$corr_one" > "$clear_real/state/.fm-jt-parent-route"
  ln -s "$clear_real" "$clear_link"
  if env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    bash -c '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_secondmate_route_clear "$2" "$3"' \
    _ "$ROOT" "$clear_link" "$corr_one"; then
    fail "route cleanup followed a symlinked secondmate home"
  fi
  [ -e "$clear_real/state/.fm-jt-parent-route" ] || fail "unsafe route cleanup removed the target marker"
  pass "concurrent secondmate routes fail closed without overwriting"
}

test_route_replacement_rejects_malformed_parent_record() {
  local dir root home fakebin state child_home child_state marker corr_one corr_two
  new_case malformed-route-replacement
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  child_home="$dir/secondmate-home"
  child_state="$child_home/state"
  marker="$child_state/.fm-jt-parent-route"
  corr_one=0123456789abcdef
  corr_two=1123456789abcdef
  mkdir -p "$child_state" "$child_home/data" "$child_home/config" \
    "$state/pending-replies"
  printf 'sm-malformed\n' > "$child_home/.fm-secondmate-home"
  fm_write_meta "$state/pending-replies/$corr_one" \
    schema=fm-pending-reply.v1 corr_id="$corr_one" task_id=sm-malformed \
    parent_home="$home" parent_status="$state/sm-malformed.status" \
    delivered_epoch=1 phase=resolved
  route_write() {
    env PATH="$fakebin:$PATH" FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c \
      '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_secondmate_route_write "$2" "$3" "$4" "$5" "$6"' \
      _ "$ROOT" "$child_home" "$home" "$state" sm-malformed "$1"
  }
  route_write "$corr_one" || fail "malformed replacement fixture route was not written"
  replace_field "$state/pending-replies/$corr_one" task_id wrong-task
  if route_write "$corr_two"; then
    fail "route replacement accepted a mismatched existing parent record"
  fi
  [ "$(receipt_value "$marker" corr_id)" = "$corr_one" ] \
    || fail "malformed parent record replacement changed the active route"
  [ ! -e "$child_state/.fm-jt-parent-route-history.$corr_one" ] \
    || fail "malformed parent record replacement archived an invalid route"
  pass "route replacement validates the complete existing parent record"
}

test_recovery_route_reuse_validates_parent_record() {
  local dir root home fakebin state child_home child_state marker corr
  new_case recovery-route-reuse
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  child_home="$dir/secondmate-home"
  child_state="$child_home/state"
  marker="$child_state/.fm-jt-parent-route"
  corr=0123456789abcdef
  mkdir -p "$child_state" "$child_home/data" "$child_home/config" "$state/pending-replies"
  printf 'sm-reuse\n' > "$child_home/.fm-secondmate-home"
  fm_write_meta "$state/pending-replies/$corr" \
    schema=fm-pending-reply.v1 corr_id="$corr" task_id=sm-reuse \
    parent_home="$home" parent_status="$state/sm-reuse.status" \
    delivered_epoch=1 phase=recovery_sending
  route_write() {
    env PATH="$fakebin:$PATH" FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" \
      FM_HOME="$home" FM_STATE_OVERRIDE="$state" bash -c \
      '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_secondmate_route_write "$2" "$3" "$4" "$5" "$6"' \
      _ "$ROOT" "$child_home" "$home" "$state" sm-reuse "$1"
  }
  route_write "$corr" || fail "recovery route fixture was not written"
  replace_field "$state/pending-replies/$corr" phase awaiting_report
  replace_field "$state/pending-replies/$corr" delivered_epoch ''
  route_write "$corr" || fail "undelivered same-route recovery was rejected"
  replace_field "$state/pending-replies/$corr" phase delivery_unknown
  route_write "$corr" || fail "delivery-unknown same-route recovery was rejected"
  replace_field "$state/pending-replies/$corr" phase recovery_sending
  replace_field "$state/pending-replies/$corr" delivered_epoch 1
  marker_before=$(cat "$marker")
  replace_field "$state/pending-replies/$corr" task_id wrong-task
  if route_write "$corr"; then
    fail "recovery route reuse accepted a mismatched parent record"
  fi
  [ "$(cat "$marker")" = "$marker_before" ] || fail "mismatched recovery route reuse changed the marker"
  if env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_corr_reusable "$2" "$3" sm-reuse' \
    _ "$ROOT" "$state" "$corr"; then
    fail "recovery resend reused a mismatched parent record"
  fi
  replace_field "$state/pending-replies/$corr" task_id sm-reuse
  printf 'task_id=sm-reuse\n' >> "$state/pending-replies/$corr"
  if route_write "$corr"; then
    fail "recovery route reuse accepted duplicate parent fields"
  fi
  if env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_corr_reusable "$2" "$3" sm-reuse' \
    _ "$ROOT" "$state" "$corr"; then
    fail "recovery resend reused duplicate parent fields"
  fi
  pass "recovery route reuse validates the complete parent record"
}

test_failed_record_removal_is_retryable() {
  local dir root home fakebin state child_home child_state marker flag rec corr
  new_case failed-record-cleanup
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  child_home="$dir/secondmate-home"
  child_state="$child_home/state"
  marker="$child_state/.fm-jt-parent-route"
  mkdir -p "$child_state" "$child_home/data" "$child_home/config" "$child_home/projects"
  printf 'sm-record-cleanup\n' > "$child_home/.fm-secondmate-home"
  prepare_primary_proof "$root" "$home" "$fakebin"
  prepare_watcher_protocol "$root" "$home" "$state"
  corr=$(env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_create "$2" "$3" sm-record-cleanup "cleanup request"' \
    _ "$ROOT" "$home" "$state") || fail "cleanup record was not created"
  env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_secondmate_route_write "$2" "$3" "$4" sm-record-cleanup "$5"' \
    _ "$ROOT" "$child_home" "$home" "$state" "$corr" \
    || fail "cleanup route was not written"
  rec="$state/pending-replies/$corr"
  flag="$dir/fail-record-remove-once"
  : > "$flag"
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  if [ "$arg" = "${FM_TEST_CLEANUP_RECORD:-}" ] && [ -e "${FM_TEST_CLEANUP_RECORD_ONCE:-}" ]; then
    /bin/rm -f "$FM_TEST_CLEANUP_RECORD_ONCE"
    exit 42
  fi
done
exec /bin/rm "$@"
SH
  chmod +x "$fakebin/rm"
  export FM_TEST_CLEANUP_RECORD="$rec" FM_TEST_CLEANUP_RECORD_ONCE="$flag"
  if env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" PATH="$fakebin:$PATH" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_schedule_undelivered_cleanup "$2" "$3" "$4" && fm_pending_reply_discard_undelivered "$2" "$3" 1' \
    _ "$ROOT" "$state" "$corr" "$child_home"; then
    fail "record removal failure was hidden"
  fi
  [ -f "$rec" ] || fail "record removal failure lost the parent record"
  [ -e "$marker" ] || fail "record removal failure cleared the route"
  [ -f "$rec.cleanup-meta" ] || fail "record removal failure was not durable"
  rm -f "$fakebin/rm"
  unset FM_TEST_CLEANUP_RECORD FM_TEST_CLEANUP_RECORD_ONCE
  env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_retry_undelivered_cleanup "$2" "$3"' \
    _ "$ROOT" "$state" "$rec.cleanup-meta" \
    || fail "record removal cleanup did not retry"
  [ ! -e "$rec" ] || fail "record removal cleanup left the parent record"
  [ ! -e "$marker" ] || fail "record removal cleanup left the route"
  [ ! -e "$rec.cleanup-meta" ] || fail "record removal cleanup left its retry marker"
  pass "failed record removal is durably retryable with its route"
}

test_failed_marked_send_restores_record_on_route_cleanup_failure() {
  local dir root home fakebin state child_home child_state marker flag rec corr send_out
  new_case failed-marked-cleanup
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  child_home="$dir/secondmate-home"
  child_state="$child_home/state"
  marker="$child_state/.fm-jt-parent-route"
  mkdir -p "$child_state" "$child_home/data" "$child_home/config" "$child_home/projects"
  cp -a "$ROOT/bin/." "$root/bin/"
  printf 'sm-cleanup\n' > "$child_home/.fm-secondmate-home"
  write_meta "$state" sm-cleanup cleanup-inc secondmate tmux firstmate:fm-sm-cleanup
  printf 'home=%s\n' "$child_home" >> "$state/sm-cleanup.meta"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
exit 1
SH
  chmod +x "$fakebin/tmux"
  flag="$dir/fail-route-clear-once"
  : > "$flag"
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  if [ "$arg" = "${FM_TEST_CLEANUP_ROUTE:-}" ] && [ -e "${FM_TEST_CLEANUP_ROUTE_ONCE:-}" ]; then
    /bin/rm -f "$FM_TEST_CLEANUP_ROUTE_ONCE"
    exit 42
  fi
done
exec /bin/rm "$@"
SH
  chmod +x "$fakebin/rm"
  prepare_primary_proof "$root" "$home" "$fakebin"
  prepare_watcher_protocol "$root" "$home" "$state"
  export FM_TEST_CLEANUP_ROUTE="$marker" FM_TEST_CLEANUP_ROUTE_ONCE="$flag"
  send_out=$(cd "$root" && env -u NO_MISTAKES_GATE -u FM_AGENT_ROLE -u FM_AGENT_TASK \
    -u FM_AGENT_OWNER_HOME -u FM_ROOT -u STATE -u FM_PENDING_REPLY_EXISTING_CORR \
    PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 "$root/bin/fm-send.sh" \
    fm-sm-cleanup "cleanup request" 2>&1) && fail "marked send cleanup failure was hidden"
  rec=$(direct_first_file "$state/pending-replies" '*')
  [ -f "$rec" ] || fail "route cleanup failure orphaned the parent expectation"
  corr=$(basename "$rec")
  [ "$(receipt_value "$marker" corr_id)" = "$corr" ] || fail "route cleanup failure changed the active route"
  [ ! -e "$rec.cleanup" ] || fail "route cleanup failure left a hidden record backup"
  rm -f "$fakebin/rm"
  unset FM_TEST_CLEANUP_ROUTE FM_TEST_CLEANUP_ROUTE_ONCE
  env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_discard_undelivered "$2" "$3" 1 && fm_pending_reply_secondmate_route_clear_undelivered "$4" "$3" && fm_pending_reply_finish_undelivered "$2" "$3"' \
    _ "$ROOT" "$state" "$corr" "$child_home" \
    || fail "marked send cleanup did not retry transactionally"
  [ ! -e "$rec" ] || fail "marked send cleanup retry left the parent record"
  [ ! -e "$marker" ] || fail "marked send cleanup retry left the route"
  pass "failed marked sends restore parent records across route cleanup failures"
}

test_failed_concurrent_send_discards_only_new_record() {
  local dir root home fakebin state child_home child_state marker old_corr send_out
  new_case failed-concurrent-send
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  cp -a "$ROOT/bin/." "$root/bin/"
  child_home="$dir/secondmate-home"
  child_state="$child_home/state"
  marker="$child_state/.fm-jt-parent-route"
  old_corr=0123456789abcdef
  mkdir -p "$child_state" "$child_home/data" "$child_home/config" "$child_home/projects" \
    "$state/pending-replies"
  printf 'sm-race\n' > "$child_home/.fm-secondmate-home"
  write_meta "$state" sm-race parent-race-inc secondmate tmux firstmate:fm-sm-race
  printf 'home=%s\n' "$child_home" >> "$state/sm-race.meta"
  fm_write_meta "$state/pending-replies/$old_corr" \
    schema=fm-pending-reply.v1 corr_id="$old_corr" task_id=sm-race \
    parent_home="$home" parent_status="$state/sm-race.status" \
    delivered_epoch=1 phase=awaiting_report
  env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_secondmate_route_write "$2" "$3" "$4" "$5" "$6"' \
    _ "$ROOT" "$child_home" "$home" "$state" sm-race "$old_corr" \
    || fail "existing concurrent route was not written"
  prepare_primary_proof "$root" "$home" "$fakebin"
  prepare_watcher_protocol "$root" "$home" "$state"
  send_out=$(cd "$root" && env -u NO_MISTAKES_GATE -u FM_AGENT_ROLE -u FM_AGENT_TASK \
    -u FM_AGENT_OWNER_HOME -u FM_ROOT -u STATE -u FM_PENDING_REPLY_EXISTING_CORR \
    PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 "$root/bin/fm-send.sh" \
    fm-sm-race "competing request" 2>&1) && fail "concurrent route bind unexpectedly succeeded"
  [ "$(direct_file_count "$state/pending-replies" '*')" = 1 ] \
    || fail "failed concurrent send left a new pending-reply record"
  [ -f "$state/pending-replies/$old_corr" ] \
    || fail "failed concurrent send discarded the unrelated active record"
  [ "$(receipt_value "$state/pending-replies/$old_corr" phase)" = awaiting_report ] \
    || fail "failed concurrent send changed the unrelated route phase"
  [ "$(receipt_value "$state/pending-replies/$old_corr" delivered_epoch)" = 1 ] \
    || fail "failed concurrent send changed the unrelated delivery state"
  [ "$(receipt_value "$child_state/.fm-jt-parent-route" corr_id)" = "$old_corr" ] \
    || fail "failed concurrent send replaced the unrelated active route"
  pass "failed concurrent send discards only its new undelivered record"
}

test_failed_marked_send_discards_never_bound_record() {
  local dir root home fakebin state child_home child_state send_out flag rec
  new_case failed-never-bound-send
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  child_home="$dir/unsafe-secondmate-home"
  child_state="$child_home/state"
  mkdir -p "$state/pending-replies" "$child_home/state-real" "$child_home/data" \
    "$child_home/config" "$child_home/projects"
  ln -s "$child_home/state-real" "$child_state"
  printf 'sm-never-bound\n' > "$child_home/.fm-secondmate-home"
  write_meta "$state" sm-never-bound never-bound-inc secondmate tmux firstmate:fm-sm-never-bound
  printf 'home=%s\n' "$child_home" >> "$state/sm-never-bound.meta"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
exit 1
SH
  chmod +x "$fakebin/tmux"
  prepare_primary_proof "$root" "$home" "$fakebin"
  prepare_watcher_protocol "$root" "$home" "$state"
  flag="$dir/never-bound-record-remove"
  : > "$flag"
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  case "$arg" in
    */pending-replies/*)
      case "$(basename "$arg")" in
        .*) ;;
        *)
          if [ -e "${FM_TEST_NEVER_BOUND_ONCE:-}" ]; then
            /bin/rm -f "$FM_TEST_NEVER_BOUND_ONCE"
            exit 42
          fi
          ;;
      esac
      ;;
  esac
done
exec /bin/rm "$@"
SH
  chmod +x "$fakebin/rm"
  export FM_TEST_NEVER_BOUND_ONCE="$flag"
  cp -a "$ROOT/bin/." "$root/bin/"
  send_out=$(cd "$root" && env -u NO_MISTAKES_GATE -u FM_AGENT_ROLE -u FM_AGENT_TASK \
    -u FM_AGENT_OWNER_HOME -u FM_ROOT -u STATE -u FM_PENDING_REPLY_EXISTING_CORR \
    PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
    CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" FM_BACKEND=tmux TMUX=fake,1,0 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_SEND_RETRIES=1 "$root/bin/fm-send.sh" \
    fm-sm-never-bound "never bound request" 2>&1) && fail "never-bound marked send unexpectedly succeeded"
  rec=
  for candidate in "$state/pending-replies"/*; do
    base=$(basename "$candidate")
    [ -f "$candidate" ] || continue
    [ "${#base}" = 16 ] || continue
    rec=$candidate
    break
  done
  [ -f "$rec" ] || fail "never-bound cleanup did not retain the failed record for retry"
  [ -f "$rec.cleanup-meta" ] || fail "never-bound cleanup did not persist repair metadata"
  [ ! -e "$child_state/.fm-jt-parent-route" ] \
    || fail "never-bound send installed a route through an unsafe state path"
  rm -f "$fakebin/rm"
  unset FM_TEST_NEVER_BOUND_ONCE
  rm -f "$child_state"
  mkdir -p "$child_state"
  env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_retry_undelivered_cleanup "$2" "$3"' \
    _ "$ROOT" "$state" "$rec.cleanup-meta" \
    || fail "never-bound cleanup did not retry after the unsafe state was repaired"
  [ ! -e "$rec" ] || fail "never-bound retry left the parent record"
  [ ! -e "$rec.cleanup-meta" ] || fail "never-bound retry left repair metadata"
  pass "failed marked sends discard expectations without a committed route"
}

test_drain_restores_only_unprocessed_rows() {
  local dir root home fakebin state first second
  new_case drain-rollback
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  first=$(receipt_fingerprint 'first-x1|first-inc|done|done')
  second=$(receipt_fingerprint 'second-x1|second-inc|failed|failed' secondmate)
  mkdir -p "$state/terminal-outcomes"
  fm_write_meta "$state/terminal-outcomes/$first.pending" \
    schema=fm-jt-terminal-outcome.v1 fingerprint="$first" task_id=first-x1 \
    incarnation=first-inc outcome=done terminal_source=pane terminal_snapshot=done kind=ship
  fm_write_meta "$state/terminal-outcomes/$second.pending" \
    schema=fm-jt-terminal-outcome.v1 fingerprint="$second" task_id=second-x1 \
    incarnation=second-inc outcome=failed terminal_source=pane terminal_snapshot=failed kind=secondmate
  printf 'sm-rollback\n' > "$home/.fm-secondmate-home"
  printf '1\t1\tcheck\tinactive-outcome:%s\tfirst\n2\t2\tcheck\tinactive-outcome:%s\tsecond\n' \
    "$first" "$second" > "$state/.wake-queue"
  if drain "$root" "$home" "$fakebin" >"$dir/drain.out" 2>&1; then
    fail "drain accepted a malformed secondmate route"
  fi
  [ -e "$state/terminal-outcomes/$first.presented" ] || fail "presented receipt was not acknowledged"
  [ ! -e "$state/terminal-outcomes/$first.pending" ] || fail "presented receipt remained pending"
  [ -e "$state/terminal-outcomes/$second.pending" ] || fail "failed receipt was lost"
  [ "$(awk -F '\t' '$4 == "inactive-outcome:'"$first"'" { n++ } END { print n + 0 }' "$state/.wake-queue")" = 0 ] \
    || fail "already-presented receipt was requeued"
  [ "$(awk -F '\t' '$4 == "inactive-outcome:'"$second"'" { n++ } END { print n + 0 }' "$state/.wake-queue")" = 1 ] \
    || fail "unprocessed receipt was not requeued"
  pass "drain rollback preserves only unprocessed inactive outcomes"
}

test_malformed_or_missing_secondmate_route_fails_closed() {
  local dir root home fakebin state child_home child_state parent_status other_home
  new_case secondmate-route
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  child_home="$dir/secondmate-home"
  child_state="$child_home/state"
  mkdir -p "$child_state" "$child_home/data" "$child_home/config"
  mkdir -p "$home/state/pending-replies"
  printf 'sm-x1\n' > "$child_home/.fm-secondmate-home"
  write_meta "$child_state" child-x1 child-inc
  export FM_FAKE_CREW_STATE_CHILD_X1='state: failed · source: pane · child quiet'
  scan "$root" "$child_home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$child_state" pending)" = 0 ] || fail "missing secondmate parent route was not fail-closed"
  parent_status="$home/state/parent-x1.status"
  printf 'schema=fm-jt-parent-route.v1\nparent_home=%s\nparent_status=%s\ninvalid=\n' "$home" "$parent_status" > "$child_state/.fm-jt-parent-route"
  scan "$root" "$child_home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$child_state" pending)" = 0 ] || fail "malformed secondmate parent route was not fail-closed"
  [ ! -e "$parent_status" ] || fail "malformed secondmate route wrote parent status"
  parent_status="$home/state/sm-x1.status"
  printf 'untouched\n' > "$parent_status"
  printf 'schema=fm-jt-parent-route.v1\nsecondmate_id=sm-x1\nparent_home=%s\nparent_status=%s\ncorr_id=0123456789abcdef\n' \
    "$home" "$parent_status" > "$child_state/.fm-jt-parent-route"
  fm_write_meta "$home/state/pending-replies/0123456789abcdef" \
    schema=wrong-schema corr_id=0123456789abcdef task_id=sm-x1 \
    parent_home="$home" parent_status="$parent_status" delivered_epoch=1 phase=awaiting_report
  scan "$root" "$child_home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$child_state" pending)" = 0 ] || fail "malformed parent schema was accepted"
  rm -f "$child_state/.fm-jt-parent-route"
  printf 'schema=fm-jt-parent-route.v1\nsecondmate_id=\nsecondmate_id=sm-x1\nparent_home=%s\nparent_status=%s\ncorr_id=0123456789abcdef\n' \
    "$home" "$parent_status" > "$child_state/.fm-jt-parent-route"
  fm_write_meta "$home/state/pending-replies/0123456789abcdef" \
    schema=fm-pending-reply.v1 corr_id=0123456789abcdef task_id=sm-x1 \
    parent_home="$home" parent_status="$parent_status" delivered_epoch=1 phase=awaiting_report
  scan "$root" "$child_home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$child_state" pending)" = 0 ] || fail "duplicate route fields were accepted"
  other_home="$dir/other-parent-home"
  mkdir -p "$other_home/state"
  rm -f "$child_state/.fm-jt-parent-route"
  parent_status="$other_home/state/sm-x1.status"
  printf 'untouched\n' > "$parent_status"
  printf 'schema=fm-jt-parent-route.v1\nsecondmate_id=sm-x1\nparent_home=%s\nparent_status=%s\ncorr_id=fedcba9876543210\n' \
    "$home" "$parent_status" > "$child_state/.fm-jt-parent-route"
  fm_write_meta "$home/state/pending-replies/fedcba9876543210" \
    schema=fm-pending-reply.v1 corr_id=fedcba9876543210 task_id=sm-x1 \
    parent_home="$home" parent_status="$parent_status" delivered_epoch=1 phase=awaiting_report
  scan "$root" "$child_home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$child_state" pending)" = 0 ] || fail "cross-home parent status was accepted"
  grep -Fx 'untouched' "$parent_status" >/dev/null || fail "cross-home route touched the other state path"
  rm -f "$child_home/.fm-jt-parent-route"
  rm -f "$child_home/.fm-secondmate-home"
  ln -s "$dir/missing-secondmate-marker" "$child_home/.fm-secondmate-home"
  printf 'schema=fm-jt-parent-route.v1\nsecondmate_id=sm-x1\nparent_home=%s\nparent_status=%s\ncorr_id=0123456789abcdef\n' \
    "$home" "$parent_status" > "$child_state/.fm-jt-parent-route"
  scan "$root" "$child_home" "$fakebin" --startup >/dev/null \
    || fail "dangling secondmate marker scan failed"
  [ "$(receipt_count "$child_state" pending)" = 0 ] || fail "dangling secondmate marker was treated as an ordinary home"
  unset FM_FAKE_CREW_STATE_CHILD_X1
  pass "malformed and missing secondmate parent routes fail closed without chat scraping"
}

test_done_and_failed_are_replayed_once
test_portable_timeout_runner_is_used
test_portable_timeout_preserves_signal_failure
test_portable_timeout_expires_child
test_leading_zero_cadence_is_normalized
test_oversized_cadence_is_clamped
test_find_failure_propagates_without_advancing_scan
test_find_enumeration_respects_scan_budget
test_minimum_budget_preserves_direct_scan
test_ack_recomputes_fingerprint_from_receipt_fields
test_reserved_claim_recovers_to_a_new_wake_row
test_presenting_claim_recovers_before_output
test_output_started_claim_is_not_reprinted
test_uncertain_output_claim_fails_closed
test_pre_output_claim_retries_after_crash
test_output_completion_failure_does_not_reprint
test_direct_drain_finalizes_after_successful_output
test_standalone_drain_refuses_inactive_ack
test_drain_processes_bounded_batches
test_finalized_receipt_rows_are_suppressed
test_malformed_finalized_receipt_fails_closed
test_presented_claim_is_acknowledged_in_deferred_drain
test_deferred_ack_retries_after_caller_crash
test_deferred_output_completion_retries_before_confirmation
test_deferred_output_completion_failure_retains_emitted_row
test_deferred_ack_confirms_after_caller_emission
test_deferred_ack_recovers_after_output_confirmation
test_pending_receipts_replay_after_child_scan_failure
test_scan_failure_retries_without_advancing_cadence
test_state_paths_reject_symlinks_and_non_directories
test_reused_task_id_gets_new_fingerprint
test_spawn_publishes_incarnation_token
test_session_start_drains_before_inactive_scan
test_session_start_generation_bound_replay
test_watcher_runs_inactive_cadence
test_surfaced_terminal_is_not_replayed
test_postpublication_uncertainty_is_not_replayed
test_ordinary_terminal_wake_consumption_is_durable
test_surface_marker_failure_is_retryable
test_legacy_metadata_uses_stable_fallback
test_empty_spawn_incarnation_is_rejected
test_relaunch_and_teardown_races_recheck_under_spawn_lock
test_parent_home_secondmate_records_are_skipped
test_herdr_identity_and_default_captain_refusal
test_occupancy_unknown_is_not_terminal
test_status_log_terminal_is_not_replayed
test_pane_idle_proof_is_required_and_bound
test_pane_idle_publication_rechecks_under_lock
test_pane_idle_index_reclaims_retired_windows
test_pane_idle_index_refreshes_changed_metadata
test_pane_idle_index_retries_metadata_stamp_race
test_pane_idle_index_rejects_publication_stamp_race
test_watcher_bounded_metadata_fail_closed
test_pane_idle_snapshot_reads_honor_deadline
test_pane_idle_snapshot_compare_honors_deadline
test_pane_idle_lookup_propagates_deadline
test_pane_idle_index_resumes_and_rejects_path_cursor
test_pane_idle_index_retries_partial_publication_idempotently
test_secondmate_route_accepts_effective_state_overrides
test_valid_secondmate_route_reports_parent_once
test_deferred_recorded_secondmate_finishes_without_output
test_reported_secondmate_route_repair_after_crash
test_reported_route_repair_is_bounded
test_pending_receipt_republish_is_bounded
test_secondmate_route_replacement_preserves_old_receipt
test_undelivered_secondmate_route_cleanup_is_idempotent
test_concurrent_secondmate_routes_are_rejected
test_route_replacement_rejects_malformed_parent_record
test_recovery_route_reuse_validates_parent_record
test_failed_record_removal_is_retryable
test_failed_marked_send_restores_record_on_route_cleanup_failure
test_failed_concurrent_send_discards_only_new_record
test_failed_marked_send_discards_never_bound_record
test_drain_restores_only_unprocessed_rows
test_malformed_or_missing_secondmate_route_fails_closed
