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
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
key=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '_' | tr '[:lower:]' '[:upper:]')
var="FM_FAKE_CREW_STATE_$key"
printf '%s\n' "${!var:-${FM_FAKE_CREW_STATE:-state: unknown · source: none · fake default}}"
SH
  chmod +x "$fakebin/fm-crew-state.sh"
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
}

scan() {
  local root=$1 home=$2 fakebin=$3 startup=${4:-}
  env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME -u FM_PRIMARY_ATTESTATION \
    PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_SESSION_LOCK_BOOTSTRAP=1 \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_INACTIVE_OUTCOME_SECS=60 FM_INACTIVE_OUTCOME_BUDGET_SECS=10 \
    "$RECON" scan "$startup"
}

drain() {
  local root=$1 home=$2 fakebin=$3
  env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME -u FM_PRIMARY_ATTESTATION \
    PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_SESSION_LOCK_BOOTSTRAP=1 \
    FM_STATE_OVERRIDE="$home/state" "$DRAIN"
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
  touch -d '2 minutes ago' "$file" "$state/$id.status" "$state/$id.turn-ended"
}

receipt_count() {
  local state=$1 suffix=$2
  find "$state/terminal-outcomes" -maxdepth 1 -type f -name "*.$suffix" 2>/dev/null | wc -l | tr -d ' '
}

queue_count() {
  local state=$1
  [ -f "$state/.wake-queue" ] || { printf '0'; return 0; }
  awk -F '\t' '$3 == "check" && $4 ~ /^inactive-outcome:/ { n++ } END { print n + 0 }' \
    "$state/.wake-queue" 2>/dev/null
}

test_done_and_failed_are_replayed_once() {
  local dir root home fakebin state
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
  scan "$root" "$home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$state" pending)" = 2 ] || fail "rescan duplicated inactive outcome receipts"
  [ "$(queue_count "$state")" = 2 ] || fail "rescan duplicated inactive outcome wakes"
  drain "$root" "$home" "$fakebin" >/dev/null
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "drain did not acknowledge pending receipts"
  [ "$(receipt_count "$state" presented)" = 2 ] || fail "drain did not preserve two presented receipts"
  scan "$root" "$home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$state" presented)" = 2 ] || fail "presented receipts were replayed"
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
  unset FM_FAKE_CREW_STATE_PORTABLE_X1
  pass "inactive scan uses the portable timeout invocation"
}

test_reused_task_id_gets_new_fingerprint() {
  local dir root home fakebin state
  new_case reused-id
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" reused-x1 incarnation-old
  export FM_FAKE_CREW_STATE_REUSED_X1='state: done · source: pane · first run quiet'
  scan "$root" "$home" "$fakebin" --startup >/dev/null
  sed -i 's/^spawn_incarnation=.*/spawn_incarnation=incarnation-new/' "$state/reused-x1.meta"
  touch -d '2 minutes ago' "$state/reused-x1.meta"
  scan "$root" "$home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$state" pending)" = 2 ] || fail "reused task id did not create a new incarnation receipt"
  [ "$(queue_count "$state")" = 2 ] || fail "reused task id did not create a new fingerprinted wake"
  unset FM_FAKE_CREW_STATE_REUSED_X1
  pass "reused task ids are separated by the spawn incarnation"
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
  (
    FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2/.spawn-relaunch-x1.lock"; : > "$3"; while [ ! -e "$4" ]; do sleep 0.01; done; fm_lock_release "$2/.spawn-relaunch-x1.lock"' _ "$ROOT" "$state" "$ready" "$release"
  ) &
  holder=$!
  for _ in $(seq 1 100); do [ -e "$ready" ] && break; sleep 0.01; done
  scan "$root" "$home" "$fakebin" --startup >"$dir/relaunch.scan.out" 2>&1 &
  scanner=$!
  sleep 1
  sed -i 's/^spawn_incarnation=.*/spawn_incarnation=new-inc/' "$state/relaunch-x1.meta"
  : > "$release"
  wait "$holder" || fail "spawn-lock relaunch fixture failed"
  wait "$scanner" || fail "relaunch reconciliation fixture failed"
  grep -F 'incarnation=new-inc' "$state"/terminal-outcomes/*.pending >/dev/null || fail "relaunch race used stale incarnation"

  write_meta "$state" teardown-x1 teardown-inc
  export FM_FAKE_CREW_STATE_TEARDOWN_X1='state: done · source: pane · teardown race'
  ready="$dir/ready-teardown"
  release="$dir/release-teardown"
  (
    FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2/.spawn-teardown-x1.lock"; : > "$3"; while [ ! -e "$4" ]; do sleep 0.01; done; fm_lock_release "$2/.spawn-teardown-x1.lock"' _ "$ROOT" "$state" "$ready" "$release"
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
  [ "$(find "$state/terminal-outcomes" -type f -name '*teardown-x1*.pending' 2>/dev/null | wc -l | tr -d ' ')" = 0 ] || fail "teardown race created a receipt after meta removal"
  unset FM_FAKE_CREW_STATE_RELAUNCH_X1 FM_FAKE_CREW_STATE_TEARDOWN_X1
  pass "relaunch and teardown races recheck metadata under the spawn lock"
}

test_herdr_identity_and_default_captain_refusal() {
  local dir root home fakebin state
  new_case herdr-identity
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" herdr-good good-inc ship herdr firstmate:pane
  printf 'herdr_session=firstmate\nherdr_workspace_id=ws\nherdr_tab_id=tab\nherdr_pane_id=pane\n' >> "$state/herdr-good.meta"
  write_meta "$state" herdr-default default-inc ship herdr default:pane
  printf 'herdr_session=default\nherdr_workspace_id=ws\nherdr_tab_id=tab\nherdr_pane_id=pane\n' >> "$state/herdr-default.meta"
  write_meta "$state" herdr-captain captain-inc ship herdr CAPTAIN:pane
  printf 'herdr_session=CAPTAIN\nherdr_workspace_id=ws\nherdr_tab_id=tab\nherdr_pane_id=pane\n' >> "$state/herdr-captain.meta"
  touch -d '2 minutes ago' "$state/herdr-good.meta" "$state/herdr-default.meta" "$state/herdr-captain.meta"
  export FM_FAKE_CREW_STATE_HERDR_GOOD='state: done · source: pane · dedicated session quiet'
  export FM_FAKE_CREW_STATE_HERDR_DEFAULT='state: done · source: pane · must refuse'
  export FM_FAKE_CREW_STATE_HERDR_CAPTAIN='state: done · source: pane · must refuse'
  export FM_NETWORK_LOG="$dir/network.log"
  PATH="$fakebin:$PATH" scan "$root" "$home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$state" pending)" = 1 ] || fail "Herdr dedicated session was not accepted while default/CAPTAIN were refused"
  [ ! -s "$dir/network.log" ] || fail "inactive reconciliation made a forge/network call"
  unset FM_FAKE_CREW_STATE_HERDR_GOOD FM_FAKE_CREW_STATE_HERDR_DEFAULT FM_FAKE_CREW_STATE_HERDR_CAPTAIN FM_NETWORK_LOG
  pass "Herdr uses the dedicated firstmate identity and refuses default/CAPTAIN"
}

test_occupancy_unknown_is_not_terminal() {
  local dir root home fakebin state
  new_case occupancy-unknown
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  write_meta "$state" unknown-x1 unknown-inc
  export FM_FAKE_CREW_STATE_UNKNOWN_X1='state: unknown · source: none · occupancy unknown'
  scan "$root" "$home" "$fakebin" --startup >/dev/null
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
  scan "$root" "$home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$state" pending)" = 0 ] || fail "stale status-log done was treated as terminal"
  [ "$(queue_count "$state")" = 0 ] || fail "stale status-log done created an actionable wake"
  unset FM_FAKE_CREW_STATE_STALE_X1
  pass "status-log terminal output remains fail-closed"
}

test_valid_secondmate_route_reports_parent_once() {
  local dir root home fakebin state child_home child_state parent_status corr rec
  new_case secondmate-route-valid
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  child_home="$dir/secondmate-home"
  child_state="$child_home/state"
  mkdir -p "$child_state" "$child_home/data" "$child_home/config" "$state/pending-replies"
  printf 'sm-valid\n' > "$child_home/.fm-secondmate-home"
  write_meta "$child_state" child-x1 child-inc
  corr=0123456789abcdef
  parent_status="$state/sm-valid.status"
  rec="$state/pending-replies/$corr"
  fm_write_meta "$rec" \
    schema=fm-pending-reply.v1 corr_id="$corr" task_id=sm-valid \
    parent_home="$home" parent_status="$parent_status" delivered_epoch=1 phase=awaiting_report
  export FM_FAKE_CREW_STATE_CHILD_X1='state: failed · source: pane · child quiet'
  printf 'schema=fm-jt-parent-route.v1\nsecondmate_id=sm-valid\nparent_home=%s\nparent_status=%s\ncorr_id=%s\n' \
    "$home" "$parent_status" "$corr" > "$child_state/.fm-jt-parent-route"
  scan "$root" "$child_home" "$fakebin" --startup >/dev/null
  [ "$(receipt_count "$child_state" pending)" = 1 ] || fail "valid secondmate route did not create a pending receipt"
  drain "$root" "$child_home" "$fakebin" >/dev/null
  [ "$(receipt_count "$child_state" reported)" = 1 ] || fail "valid secondmate route was not reported"
  [ ! -e "$child_state/.fm-jt-parent-route" ] || fail "reported secondmate route remained installed"
  grep -F "failed [corr=$corr]: inactive terminal outcome replayed: task=child-x1" "$parent_status" >/dev/null \
    || fail "valid secondmate route did not append the correlated parent status"
  drain "$root" "$child_home" "$fakebin" >/dev/null
  [ "$(grep -Fc "failed [corr=$corr]: inactive terminal outcome replayed: task=child-x1" "$parent_status")" = 1 ] \
    || fail "secondmate parent report was duplicated"
  unset FM_FAKE_CREW_STATE_CHILD_X1
  pass "valid secondmate outcomes use the parent status correlation exactly once"
}

test_concurrent_secondmate_routes_are_rejected() {
  local dir root home fakebin state child_home child_state marker corr_one corr_two
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
    env FM_SESSION_LOCK_BOOTSTRAP=1 FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
      FM_STATE_OVERRIDE="$state" bash -c \
      '. "$1/bin/fm-pending-reply-lib.sh"; fm_pending_reply_secondmate_route_write "$2" "$3" "$4" "$5" "$6"' \
      _ "$ROOT" "$child_home" "$home" "$state" sm-concurrent "$1"
  }
  route_write "$corr_one" || fail "initial secondmate route was not written"
  marker_before=$(cat "$marker")
  if route_write "$corr_two"; then
    fail "concurrent secondmate route was silently replaced"
  fi
  [ "$(cat "$marker")" = "$marker_before" ] || fail "concurrent route rejection changed the active marker"
  pass "concurrent secondmate routes fail closed without overwriting"
}

test_drain_restores_only_unprocessed_rows() {
  local dir root home fakebin state first second
  new_case drain-rollback
  dir=$CASE_DIR; root=$CASE_ROOT; home=$CASE_HOME; fakebin=$CASE_FAKEBIN
  state="$home/state"
  first=1111111111111111
  second=2222222222222222
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
  unset FM_FAKE_CREW_STATE_CHILD_X1
  pass "malformed and missing secondmate parent routes fail closed without chat scraping"
}

test_done_and_failed_are_replayed_once
test_portable_timeout_runner_is_used
test_reused_task_id_gets_new_fingerprint
test_relaunch_and_teardown_races_recheck_under_spawn_lock
test_herdr_identity_and_default_captain_refusal
test_occupancy_unknown_is_not_terminal
test_status_log_terminal_is_not_replayed
test_valid_secondmate_route_reports_parent_once
test_concurrent_secondmate_routes_are_rejected
test_drain_restores_only_unprocessed_rows
test_malformed_or_missing_secondmate_route_fails_closed
