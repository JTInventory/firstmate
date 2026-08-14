#!/usr/bin/env bash
# Focused behavior tests for inactive terminal-outcome replay.
set -u

# A crewmate's inherited environment is deliberately refused by the production
# helper. Re-exec the behavior suite once with a clean parent ancestry so its
# throwaway firstmate homes exercise the primary-only path.
if [ "${FM_INACTIVE_TEST_CLEAN:-0}" != 1 ]; then
  exec env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
    -u FM_PRIMARY_ATTESTATION FM_INACTIVE_TEST_CLEAN=1 bash "$0" "$@"
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
  local root=$1 home=$2 fakebin=$3
  if [ -d "$home/state" ] && [ ! -L "$home/state" ]; then
    prepare_primary_proof "$root" "$home" "$fakebin"
  fi
  ( cd "$root" && env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
      -u FM_ROOT -u STATE PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_PRIMARY_ATTESTATION="$CASE_TOKEN" \
      CODEX_THREAD_ID="$CASE_THREAD" FM_FAKE_HARNESS_PID="$$" "$DRAIN" )
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
  local dir root home fakebin state
  new_case portable-timeout
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" portable-x1 portable-inc
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" != --foreground ] || exit 91
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  export FM_FAKE_CREW_STATE_PORTABLE_X1='state: done · source: pane · portable timeout'
  scan "$root" "$home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "portable timeout runner did not reconcile the child"
  export FM_INACTIVE_OUTCOME_FORCE_PORTABLE_TIMEOUT=1
  export FM_FAKE_CREW_STATE_EXIT=7
  if scan "$root" "$home" "$fakebin" --startup >/dev/null 2>&1; then
    fail "portable timeout runner hid a non-zero child status"
  fi
  unset FM_FAKE_CREW_STATE_PORTABLE_X1 FM_FAKE_CREW_STATE_EXIT FM_INACTIVE_OUTCOME_FORCE_PORTABLE_TIMEOUT
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
  if scan "$root" "$home" "$fakebin" --startup >/dev/null 2>&1; then
    fail "portable timeout fallback allowed an expired child"
  fi
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
  local dir root home fakebin state
  new_case find-budget
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" find-budget-x1 find-budget-inc
  cat > "$fakebin/find" <<'SH'
#!/usr/bin/env bash
sleep 2
exit 0
SH
  chmod +x "$fakebin/find"
  export FM_INACTIVE_OUTCOME_BUDGET_SECS=1
  if scan "$root" "$home" "$fakebin" --startup >/dev/null 2>&1; then
    fail "slow find enumeration exceeded the scan budget without failing"
  fi
  [ ! -e "$state/.inactive-outcome-reconcile" ] || fail "budget-exhausted enumeration advanced the cadence marker"
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "budget-exhausted enumeration created a receipt"
  unset FM_INACTIVE_OUTCOME_BUDGET_SECS
  pass "inactive enumeration is bounded by the per-scan budget"
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
  printf 'schema=fm-inactive-outcome-claim.v1\nfingerprint=%s\nrow=1\t1\tcheck\tinactive-outcome:%s\told row\nstate=presenting\noutput_started=1\ncreated_epoch=1\n' \
    "$fingerprint" "$fingerprint" > "$state/terminal-outcomes/.$fingerprint.claim"
  printf '%s\n' "$row" > "$state/.wake-queue"
  drain "$root" "$home" "$fakebin" >"$dir/output-started.out" \
    || fail "drain did not recover an output-started claim"
  [ ! -s "$dir/output-started.out" ] || fail "output-started claim was printed a second time"
  [ -e "$state/terminal-outcomes/$fingerprint.presented" ] || fail "output-started claim did not acknowledge its receipt"
  [ ! -e "$state/terminal-outcomes/.$fingerprint.claim" ] || fail "output-started claim was not retired"
  pass "output-started inactive claims do not reprint after a drain crash"
}

test_scan_failure_retries_without_advancing_cadence() {
  local dir root home fakebin state wake_dir wake_removed
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
  if scan "$root" "$home" "$fakebin" --startup >/dev/null 2>&1; then
    fail "child scan failure was reported as success"
  fi
  [ ! -e "$state/.inactive-outcome-reconcile" ] || fail "failed scan advanced the cadence marker"
  [ "$(receipt_count "$state" pending)" = 2 ] || fail "durable receipts were not retained across wake publication failure"
  [ ! -e "$state"/.first-x1.inactive-state.* ] || fail "failed crew-state scan leaked its temporary output"
  [ ! -e "$state"/.second-x1.inactive-state.* ] || fail "failed crew-state scan leaked its temporary output"
  grep -l '^task_id=first-x1$' "$state"/terminal-outcomes/*.pending >/dev/null \
    || fail "first child receipt was not retained"
  grep -l '^task_id=second-x1$' "$state"/terminal-outcomes/*.pending >/dev/null \
    || fail "second child receipt was not retained"
  case "$(cat "$state/.inactive-outcome-reconcile.cursor")" in
    first-x1|second-x1) ;;
    *) fail "cursor did not preserve the last successful child" ;;
  esac
  mv "$wake_removed" "$wake_dir"
  export FM_BREAK_QUEUE=0
  scan "$root" "$home" "$fakebin" --startup >/dev/null || fail "retry after child failure did not complete"
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

test_watcher_runs_inactive_cadence() {
  local dir root home fakebin state out status wake_line inactive_line
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
  capture-pane) : ;;
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
  [ "$status" = 0 ] || fail "watcher cadence failed while surfacing the inactive outcome wake"
  printf '%s\n' "$out" | grep -F 'check: inactive terminal outcome replay queued' >/dev/null \
    || fail "watcher did not surface the inactive reconciliation result"
  wake_line=$(printf '%s\n' "$out" | grep -n '^1[[:space:]]\+1[[:space:]]\+signal[[:space:]]\+task-before' | head -1 | cut -d: -f1)
  inactive_line=$(printf '%s\n' "$out" | grep -n 'check: inactive terminal outcome replay queued' | head -1 | cut -d: -f1)
  [ -n "$wake_line" ] && [ -n "$inactive_line" ] && [ "$wake_line" -lt "$inactive_line" ] \
    || fail "watcher did not drain the existing wake before inactive reconciliation"
  [ "$(awk -F '\t' '$4 == "task-before" { n++ } END { print n + 0 }' "$state/.wake-queue")" = 0 ] \
    || fail "watcher left the existing wake queued"
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "watcher cadence did not create the inactive receipt"
  [ "$(queue_count "$state")" = 1 ] || fail "watcher cadence did not retain exactly one inactive outcome wake"
  unset FM_FAKE_CREW_STATE_WATCHER_X1
  pass "watcher cadence runs inactive reconciliation and surfaces its wake"
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
  local dir root home fakebin state
  new_case herdr-identity
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" herdr-good good-inc ship herdr firstmate:pane
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
  export FM_NETWORK_LOG="$dir/network.log"
  PATH="$fakebin:$PATH" scan "$root" "$home" "$fakebin" --startup >/dev/null \
    || fail "Herdr identity scan failed"
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "Herdr duplicate identity was accepted or default/CAPTAIN were not refused"
  grep -l '^task_id=herdr-unique$' "$state"/terminal-outcomes/*.pending >/dev/null \
    || fail "unique Herdr identity was not accepted"
  [ ! -s "$dir/network.log" ] || fail "inactive reconciliation made a forge/network call"
  unset FM_FAKE_CREW_STATE_HERDR_GOOD FM_FAKE_CREW_STATE_HERDR_UNIQUE \
    FM_FAKE_CREW_STATE_HERDR_DEFAULT FM_FAKE_CREW_STATE_HERDR_CAPTAIN FM_NETWORK_LOG
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

test_valid_secondmate_route_reports_parent_once() {
  local dir root home fakebin state child_home child_state parent_status corr rec outside send_out
  local outside_parent outside_parent_link
  local history_corr history_record history_status active_record active_backup
  new_case secondmate-route-valid
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  cp -a "$ROOT/bin/." "$root/bin/"
  child_home="$dir/secondmate-home"
  child_state="$child_home/state"
  mkdir -p "$child_state" "$child_home/data" "$child_home/config" \
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
  *capture-pane*) : ;;
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
  if ! drain "$root" "$child_home" "$fakebin" >"$dir/second-drain.out" 2>&1; then
    cat "$dir/second-drain.out" >&2
    fail "valid secondmate route drain failed after symlink removal"
  fi
  [ "$(receipt_count "$child_state" reported)" = 1 ] || fail "valid secondmate route was not reported"
  [ ! -e "$child_state/.fm-jt-parent-route" ] || fail "reported secondmate route was not cleared after its parent report"
  grep -F "failed [corr=$corr]: inactive terminal outcome replayed: task=child-x1" "$parent_status" >/dev/null \
    || fail "valid secondmate route did not append the correlated parent status"
  drain "$root" "$child_home" "$fakebin" >/dev/null
  [ "$(grep -Fc "failed [corr=$corr]: inactive terminal outcome replayed: task=child-x1" "$parent_status")" = 1 ] \
    || fail "secondmate parent report was duplicated"

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

test_secondmate_route_replacement_preserves_old_receipt() {
  local dir root home fakebin state child_home child_state parent_status corr_a corr_b rec send_out marker
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
  *capture-pane*) : ;;
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
  local dir root home fakebin state child_home child_state parent_status
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
test_find_failure_propagates_without_advancing_scan
test_find_enumeration_respects_scan_budget
test_ack_recomputes_fingerprint_from_receipt_fields
test_reserved_claim_recovers_to_a_new_wake_row
test_presenting_claim_recovers_before_output
test_output_started_claim_is_not_reprinted
test_scan_failure_retries_without_advancing_cadence
test_state_paths_reject_symlinks_and_non_directories
test_reused_task_id_gets_new_fingerprint
test_spawn_publishes_incarnation_token
test_session_start_drains_before_inactive_scan
test_watcher_runs_inactive_cadence
test_legacy_metadata_uses_stable_fallback
test_empty_spawn_incarnation_is_rejected
test_relaunch_and_teardown_races_recheck_under_spawn_lock
test_parent_home_secondmate_records_are_skipped
test_herdr_identity_and_default_captain_refusal
test_occupancy_unknown_is_not_terminal
test_status_log_terminal_is_not_replayed
test_valid_secondmate_route_reports_parent_once
test_secondmate_route_replacement_preserves_old_receipt
test_concurrent_secondmate_routes_are_rejected
test_drain_restores_only_unprocessed_rows
test_malformed_or_missing_secondmate_route_fails_closed
