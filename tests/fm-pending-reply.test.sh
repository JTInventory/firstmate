#!/usr/bin/env bash
# Parent-owned secondmate pending-reply guards (bin/fm-pending-reply-lib.sh).
#
# Reproduces the missed-report experience: a marked request is delivered, the
# target turn completes, and no correlated parent report arrives. The parent
# must notice without scraping conversation, send exactly one recovery repost,
# and escalate once if that recovery turn is also missed.
#
# Coverage:
#   1. Normal correlated reply resolves once
#   2. Completed turn with no report triggers one recovery only
#   3. Recovery reply resolves the original expectation
#   4. Second missed turn escalates once and remains durable
#   5. Transport success cannot masquerade as reply success
#   6. Unrelated events and stale correlation ids cannot resolve a request
#   7. Restart/compaction preserves the expectation and exact parent destination
#   8. Wrong-home reports are detected but do not silently acknowledge
#   9. Direct unmarked captain input creates no expectation
#  10. fm-send secondmate path embeds corr and creates durable pending records
#  11. Backend busy/idle observation works through the shared busy abstraction
#      used by Pi/Claude secondmate backends (no conversation scrape)
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
REPORT="$ROOT/bin/fm-secondmate-report.sh"
TMP_ROOT=$(fm_test_tmproot fm-pending-reply)

export FM_PENDING_REPLY_GRACE_SECS=0
export FM_SEND_SETTLE=0

# --- fixtures ---------------------------------------------------------------

make_stubs() {  # <dir> -> fakebin
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '\xe2\x94\x82 \xe2\x94\x82\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_parent() {  # <name> -> home
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

run_send() {
  local fb=$1 home=$2 log=$3; shift 3
  : > "$log"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    FM_PENDING_REPLY_GRACE_SECS=0 \
    "$SEND" "$@" 2>/dev/null
}

phase_of() {  # <state> <corr>
  fm_pending_reply_get "$(fm_pending_reply_path "$1" "$2")" phase
}

# --- tests ------------------------------------------------------------------

test_normal_correlated_reply_resolves_once() {
  local home state corr status rec
  home=$(setup_parent resolve-once)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=1000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "audit the ledger")
  fm_pending_reply_mark_delivered "$state" "$corr"
  status="$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "missing status must not resolve"
  fi
  printf 'done [corr=%s]: ledger clean\n' "$corr" > "$status"
  fm_pending_reply_try_resolve "$state" "$corr" || fail "correlated status should resolve"
  [ "$(phase_of "$state" "$corr")" = resolved ] || fail "phase should be resolved"
  # Idempotent second resolve.
  fm_pending_reply_try_resolve "$state" "$corr" || fail "second resolve must stay successful"
  [ "$(phase_of "$state" "$corr")" = resolved ] || fail "phase must remain resolved"
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ "$(fm_pending_reply_get "$rec" resolved_via)" = status ] \
    || fail "resolved_via should be status"
  pass "normal correlated reply resolves once (idempotent)"
}

test_completed_turn_no_report_triggers_one_recovery() {
  local home state corr hook_log rec
  home=$(setup_parent one-recovery)
  state="$home/state"
  hook_log="$TMP_ROOT/recovery-hook.log"
  : > "$hook_log"
  export FM_PENDING_REPLY_NOW=2000
  export FM_PENDING_REPLY_SEND_HOOK='printf "%s\t%s\n" >>"'"$hook_log"'"'
  # The hook above is wrong for eval form - use a function.
  # Invoked indirectly through FM_PENDING_REPLY_SEND_HOOK.
  # shellcheck disable=SC2329
  recovery_hook() {
    printf '%s\t%s\n' "$1" "$2" >> "$hook_log"
  }
  export -f recovery_hook
  export FM_PENDING_REPLY_SEND_HOOK='recovery_hook'

  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "status of phase 7")
  fm_pending_reply_mark_delivered "$state" "$corr"
  # Turn completes with no parent report (the Hi Bit missed-report shape).
  fm_pending_reply_observe_busy "$state" "$corr" busy
  fm_pending_reply_observe_busy "$state" "$corr" idle
  fm_pending_reply_send_recovery "$state" "$corr" \
    || fail "recovery should send after completed turn + grace"
  [ "$(phase_of "$state" "$corr")" = recovery_sent ] \
    || fail "phase should be recovery_sent, got $(phase_of "$state" "$corr")"
  [ -s "$hook_log" ] || fail "recovery hook should have been invoked once"
  # Second attempt must not re-send.
  if fm_pending_reply_send_recovery "$state" "$corr" 2>/dev/null; then
    fail "second recovery must refuse"
  fi
  lines=$(wc -l < "$hook_log" | tr -d ' ')
  [ "$lines" = 1 ] || fail "expected exactly one recovery send, got $lines"
  rec=$(fm_pending_reply_path "$state" "$corr")
  case "$(cat "$hook_log")" in
    *"corr=$corr"*) : ;;
    *) fail "recovery message must carry the original corr"$'\n'"$(cat "$hook_log")" ;;
  esac
  case "$(cat "$hook_log")" in
    *REPOST\ REQUIRED*) : ;;
    *) fail "recovery message must ask for a repost"$'\n'"$(cat "$hook_log")" ;;
  esac
  pass "completed turn with no report triggers exactly one recovery"
}

test_recovery_send_uses_strict_fm_target() {
  local dir fb log home state corr
  dir="$TMP_ROOT/recovery-strict-target"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"; : > "$log"
  home=$(setup_parent recovery-strict-target)
  state="$home/state"
  mkdir -p "$home/sm"
  touch "$state/.last-watcher-beat"
  fm_write_secondmate_meta "$state/hibit.meta" "$home/sm" "sess:fm-hibit"
  export FM_PENDING_REPLY_NOW=2400
  unset FM_PENDING_REPLY_SEND_HOOK
  corr=$(fm_pending_reply_create "$home" "$state" hibit "strict target recovery")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_SEND_LOG="$log" \
    fm_pending_reply_send_recovery "$state" "$corr" \
    || fail "real recovery send should route through the fork's strict fm-<id> target"
  [ "$(phase_of "$state" "$corr")" = recovery_sent ] \
    || fail "strict-target recovery should reach recovery_sent"
  case "$(cat "$log")" in
    *"corr=$corr"*) : ;;
    *) fail "strict-target recovery did not deliver the correlated repost" ;;
  esac
  pass "recovery send preserves the fork's strict fm-<id> target contract"
}

test_recovery_attempt_is_never_reinjected() {
  local home state corr rec hook_log lines live_corr live_rec live_pid live_identity
  home=$(setup_parent recovery-at-most-once)
  state="$home/state"
  hook_log="$TMP_ROOT/recovery-at-most-once.log"
  : > "$hook_log"
  export FM_PENDING_REPLY_NOW=2500
  recovery_fail_hook() {
    printf 'attempted\n' >> "$hook_log"
    return 1
  }
  export -f recovery_fail_hook
  export FM_PENDING_REPLY_SEND_HOOK=recovery_fail_hook
  corr=$(fm_pending_reply_create "$home" "$state" hibit "at most once")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  if fm_pending_reply_send_recovery "$state" "$corr"; then
    fail "failed recovery transport should report failure"
  fi
  [ "$(phase_of "$state" "$corr")" = recovery_failed ] \
    || fail "failed recovery attempt should preserve failed delivery"
  [ -z "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" recovery_sent_epoch)" ] \
    || fail "failed recovery must not record a sent epoch"
  if fm_pending_reply_send_recovery "$state" "$corr" 2>/dev/null; then
    fail "committed recovery attempt must refuse reinjection"
  fi
  lines=$(wc -l < "$hook_log" | tr -d ' ')
  [ "$lines" = 1 ] || fail "recovery transport should be attempted once, got $lines"
  fm_pending_reply_maybe_escalate "$state" "$corr" \
    || fail "failed recovery delivery should escalate explicitly"
  grep -Fq "pending-reply-recovery-delivery-failed:" "$state/hibit.status" \
    || fail "failed recovery escalation should name delivery failure"
  live_corr=$(fm_pending_reply_create "$home" "$state" hibit "live recovery")
  fm_pending_reply_mark_delivered "$state" "$live_corr"
  fm_pending_reply_mark_turn_completed "$state" "$live_corr" request
  live_rec=$(fm_pending_reply_path "$state" "$live_corr")
  live_pid=${BASHPID:-$$}
  live_identity=$(fm_pending_reply_pid_identity "$live_pid") \
    || fail "live sender identity should be observable"
  fm_pending_reply_set "$live_rec" recovery_attempted_epoch 2500 || fail "live attempt precommit failed"
  fm_pending_reply_set "$live_rec" recovery_sender_pid "$live_pid" || fail "live sender pid commit failed"
  fm_pending_reply_set "$live_rec" recovery_sender_identity "$live_identity" \
    || fail "live sender identity commit failed"
  fm_pending_reply_set "$live_rec" phase recovery_sending || fail "live sending phase failed"
  fm_pending_reply_tick_one "$state" "$live_corr" unknown || fail "live recovery tick failed"
  [ "$(phase_of "$state" "$live_corr")" = recovery_sending ] \
    || fail "live recovery must remain in progress without elapsed-time inference"
  corr=$(fm_pending_reply_create "$home" "$state" hibit "crashed recovery")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  rec=$(fm_pending_reply_path "$state" "$corr")
  fm_pending_reply_set "$rec" recovery_attempted_epoch 2500 || fail "attempt precommit failed"
  fm_pending_reply_set "$rec" phase recovery_sending || fail "sending phase precommit failed"
  fm_pending_reply_tick_one "$state" "$corr" unknown || fail "recovery reconciliation failed"
  [ "$(phase_of "$state" "$corr")" = escalated ] \
    || fail "interrupted recovery attempt should escalate unknown delivery"
  [ "$(fm_pending_reply_get "$rec" recovery_delivery_outcome)" = unknown ] \
    || fail "interrupted recovery should preserve unknown delivery outcome"
  [ -z "$(fm_pending_reply_get "$rec" recovery_sent_epoch)" ] \
    || fail "unknown recovery must not record a sent epoch"
  grep -Fq "pending-reply-recovery-delivery-unknown:" "$state/hibit.status" \
    || fail "unknown recovery escalation should name delivery uncertainty"
  lines=$(wc -l < "$hook_log" | tr -d ' ')
  [ "$lines" = 1 ] || fail "reconciliation must not call recovery transport, got $lines attempts"
  unset FM_PENDING_REPLY_SEND_HOOK
  pass "recovery attempts reconcile without reinjection"
}

test_recovery_reply_resolves_original() {
  local home state corr hook_log
  home=$(setup_parent recovery-resolve)
  state="$home/state"
  hook_log="$TMP_ROOT/recovery-resolve-hook.log"
  : > "$hook_log"
  # Invoked indirectly through FM_PENDING_REPLY_SEND_HOOK.
  # shellcheck disable=SC2329
  recovery_hook() { printf '%s\n' "$2" >> "$hook_log"; }
  export -f recovery_hook
  export FM_PENDING_REPLY_SEND_HOOK='recovery_hook'
  export FM_PENDING_REPLY_NOW=3000

  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "phase 7 status")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  fm_pending_reply_send_recovery "$state" "$corr" || fail "recovery send failed"
  printf 'done [corr=%s]: phase 7 is Done (reposted)\n' "$corr" > "$state/hibit.status"
  fm_pending_reply_try_resolve "$state" "$corr" || fail "recovery reply should resolve original"
  [ "$(phase_of "$state" "$corr")" = resolved ] || fail "expected resolved after recovery reply"
  pass "recovery reply resolves the original expectation"
}

test_second_missed_turn_escalates_once_and_stays_durable() {
  local home state corr hook_log rec status_line escalations
  home=$(setup_parent escalate-once)
  state="$home/state"
  hook_log="$TMP_ROOT/escalate-hook.log"
  : > "$hook_log"
  # Invoked indirectly through FM_PENDING_REPLY_SEND_HOOK.
  # shellcheck disable=SC2329
  recovery_hook() { printf '%s\n' ok >> "$hook_log"; }
  export -f recovery_hook
  export FM_PENDING_REPLY_SEND_HOOK='recovery_hook'
  export FM_PENDING_REPLY_NOW=4000
  # Do not export STATE into the test process: fm-send resolves
  # FM_STATE_OVERRIDE/STATE from the environment and a leak breaks later cases.

  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "why is phase 7 stuck")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  fm_pending_reply_send_recovery "$state" "$corr" || fail "recovery send failed"
  # Recovery turn also completes with no correlated report.
  fm_pending_reply_mark_turn_completed "$state" "$corr" recovery
  fm_pending_reply_maybe_escalate "$state" "$corr" || fail "escalation should fire"
  [ "$(phase_of "$state" "$corr")" = escalated ] || fail "phase should be escalated"
  status_line=$(tail -1 "$state/hibit.status")
  case "$status_line" in
    blocked:*pending-reply-missed:*pending-reply-id=$corr*) : ;;
    *) fail "parent status should carry one blocked missed-report line"$'\n'"$status_line" ;;
  esac
  [ ! -s "$state/.wake-queue" ] || fail "direct escalation must not enqueue a duplicate check wake"
  # Second escalate must be a no-op (phase no longer recovery_sent).
  if fm_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null; then
    # Function returns 1 when phase is not recovery_sent - good.
    :
  fi
  [ "$(phase_of "$state" "$corr")" = escalated ] || fail "phase must stay escalated"
  escalations=$(grep -Fc "pending-reply-id=$corr" "$state/hibit.status")
  [ "$escalations" = 1 ] || fail "missed recovery should publish one escalation, got $escalations"
  # Durable record retained (never silently expired).
  rec=$(fm_pending_reply_path "$state" "$corr")
  [ -f "$rec" ] || fail "escalated record must remain on disk"
  [ "$(fm_pending_reply_get "$rec" parent_status)" = "$state/hibit.status" ] \
    || fail "parent destination must remain exact"
  # Unrelated status activity still does not resolve.
  printf 'working: unrelated churn\n' >> "$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "unrelated status must not resolve an escalated miss"
  fi
  [ "$(phase_of "$state" "$corr")" = escalated ] || fail "must remain escalated after unrelated status"
  pass "second missed turn escalates once and remains durable"
}

test_concurrent_escalation_publishes_once() {
  local home state corr rec escalations
  home=$(setup_parent concurrent-escalation)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=4250
  corr=$(fm_pending_reply_create "$home" "$state" hibit "concurrent miss")
  fm_pending_reply_mark_delivered "$state" "$corr" \
    || fail "concurrent-escalation: delivery setup failed"
  rec=$(fm_pending_reply_active_path "$state" "$corr")
  fm_pending_reply_set "$rec" recovery_delivery_outcome unknown \
    || fail "concurrent-escalation: outcome setup failed"
  fm_pending_reply_set "$rec" phase recovery_unknown \
    || fail "concurrent-escalation: phase setup failed"
  for _ in 1 2 3 4 5 6 7 8; do
    (
      fm_pending_reply_maybe_escalate "$state" "$corr" >/dev/null 2>&1 || true
    ) &
  done
  wait
  escalations=$(grep -Fc "pending-reply-id=$corr" "$state/hibit.status")
  [ "$escalations" = 1 ] \
    || fail "concurrent-escalation: expected one blocked line, got $escalations"
  [ "$(phase_of "$state" "$corr")" = escalated ] \
    || fail "concurrent-escalation: final phase must be escalated"
  pass "concurrent escalation publishes one blocked status"
}

test_incomplete_transaction_lock_is_reclaimed() {
  local home state corr lock
  home=$(setup_parent incomplete-lock)
  state="$home/state"
  corr=$(fm_pending_reply_create "$home" "$state" hibit "recover incomplete lock")
  fm_pending_reply_mark_delivered "$state" "$corr" \
    || fail "incomplete-lock: delivery setup failed"
  printf 'done [corr=%s]: lock recovered\n' "$corr" > "$state/hibit.status"
  lock=$(fm_pending_reply_txn_lock_path "$state" "$corr")
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  fm_pending_reply_try_resolve "$state" "$corr" \
    || fail "incomplete-lock: abandoned acquisition was not reclaimed"
  [ "$(phase_of "$state" "$corr")" = resolved ] \
    || fail "incomplete-lock: recovered transaction did not resolve"
  [ ! -e "$lock" ] || fail "incomplete-lock: lock remained after recovery"
  pass "incomplete transaction locks are reclaimed"
}

test_stale_generation_reclaim_preserves_new_owner() {
  local home state corr lock log max_active
  home=$(setup_parent stale-generation-lock)
  state="$home/state"
  corr=4123456789abcdef
  lock=$(fm_pending_reply_txn_lock_path "$state" "$corr")
  mkdir -p "$lock"
  fm_pending_reply_txn_owner_write \
    "$lock/owner-stale-token" 99999999 dead-owner stale-token owned \
    || fail "stale-generation-lock: stale fixture setup failed"
  log="$home/critical.log"
  : > "$log"
  for _ in 1 2 3 4 5 6 7 8; do
    (
      local token
      fm_pending_reply_txn_lock_acquire "$state" "$corr" token \
        || exit 1
      printf '%s acquire\n' "$BASHPID" >> "$log"
      sleep 0.02
      printf '%s release\n' "$BASHPID" >> "$log"
      fm_pending_reply_txn_lock_release "$state" "$corr" "$token"
    ) &
  done
  wait || fail "stale-generation-lock: contender failed"
  max_active=$(awk '
    $2 == "acquire" { active++ }
    $2 == "release" { active-- }
    active > max { max=active }
    END { print max + 0 }
  ' "$log")
  [ "$max_active" = 1 ] \
    || fail "stale-generation-lock: concurrent owners entered ($max_active)"
  [ ! -e "$lock/owner-stale-token" ] \
    || fail "stale-generation-lock: stale generation remained"
  pass "stale generation reclaim preserves the live owner"
}

test_escalation_publication_failure_retries() {
  local home state corr rec target escalations
  home=$(setup_parent escalation-retry)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=4500
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "retry escalation")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_pending_reply_mark_turn_completed "$state" "$corr" request
  export FM_PENDING_REPLY_SEND_HOOK='true'
  fm_pending_reply_send_recovery "$state" "$corr" || fail "recovery send failed"
  fm_pending_reply_mark_turn_completed "$state" "$corr" recovery
  rec=$(fm_pending_reply_path "$state" "$corr")
  target="$state/escalation-target"
  mkdir -p "$target"
  fm_pending_reply_set "$rec" parent_status "$target" || fail "failed to set escalation target"
  if fm_pending_reply_maybe_escalate "$state" "$corr" 2>/dev/null; then
    fail "escalation should fail when its durable status cannot be written"
  fi
  [ "$(phase_of "$state" "$corr")" = recovery_sent ] \
    || fail "publication failure must leave escalation retryable"
  rmdir "$target"
  fm_pending_reply_maybe_escalate "$state" "$corr" || fail "escalation retry should succeed"
  [ "$(phase_of "$state" "$corr")" = escalated ] || fail "successful retry should commit escalation"
  escalations=$(grep -Fc "pending-reply-id=$corr" "$target")
  [ "$escalations" = 1 ] || fail "successful retry should publish exactly once, got $escalations"
  pass "failed escalation publication remains retryable and publishes once"
}

test_transport_success_is_not_reply_success() {
  local home state corr
  home=$(setup_parent transport-not-reply)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=5000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "ping")
  fm_pending_reply_mark_delivered "$state" "$corr" || fail "mark delivered failed"
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] \
    || fail "delivery must leave phase awaiting_report, got $(phase_of "$state" "$corr")"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "delivery alone must not resolve"
  fi
  pass "transport success cannot masquerade as reply success"
}

test_undelivered_records_are_scan_immutable() {
  (
    local home state sm_home corr rec before after
    home=$(setup_parent undelivered-scan)
    state="$home/state"
    sm_home="$home/sm"
    mkdir -p "$sm_home/state"
    # This fixture clock is intentionally scoped to the isolated subshell.
    # shellcheck disable=SC2030,SC2031
    export FM_PENDING_REPLY_NOW=5500
    corr=$(fm_pending_reply_create "$home" "$state" hibit "not delivered yet")
    rec=$(fm_pending_reply_path "$state" "$corr")
    printf 'done [corr=%s]: arrived too early\n' "$corr" > "$state/hibit.status"
    printf 'done [corr=%s]: wrong home too early\n' "$corr" > "$sm_home/state/hibit.status"
    fm_write_secondmate_meta "$state/hibit.meta" "$sm_home" "sess:fm-hibit"
    before=$(cat "$rec")
    if fm_pending_reply_try_resolve "$state" "$corr"; then
      fail "undelivered expectation must not resolve"
    fi
    fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" \
      || fail "undelivered wrong-home check should be inert"
    fm_pending_reply_tick_one "$state" "$corr" busy "$sm_home" \
      || fail "undelivered direct tick should be inert"
    fm_backend_busy_state() { fail "undelivered watcher tick must not probe the backend"; }
    fm_backend_capture() { fail "undelivered watcher tick must not capture the backend"; }
    fm_pending_reply_tick "$state" || fail "undelivered watcher tick should succeed"
    after=$(cat "$rec")
    [ "$after" = "$before" ] || fail "scan paths must not mutate an undelivered record"
    fm_pending_reply_mark_delivered "$state" "$corr" || fail "delivery marker should succeed"
    fm_pending_reply_tick_one "$state" "$corr" unknown "$sm_home" \
      || fail "delivered direct tick should succeed"
    [ "$(phase_of "$state" "$corr")" = resolved ] \
      || fail "correlated parent status should resolve after delivery"
  ) || fail "undelivered scan immutability regression failed"
  pass "undelivered records remain immutable across scan paths"
}

test_delivery_confirmation_fallback_reconciles() {
  (
    local home state corr rec marker rc prepared_corr prepared_rec prepared_marker escalations
    local reported_corr reported_rec reported_marker
    home=$(setup_parent delivery-confirmation)
    state="$home/state"
    # This fixture clock is intentionally scoped to the isolated subshell.
    # shellcheck disable=SC2030,SC2031
    export FM_PENDING_REPLY_NOW=5750
    corr=$(fm_pending_reply_create "$home" "$state" hibit "confirmed delivery")
    rec=$(fm_pending_reply_path "$state" "$corr")
    fm_pending_reply_mark_delivered() { return 1; }
    if fm_pending_reply_confirm_delivery "$state" "$corr"; then
      fail "primary delivery commit failure should be reported"
    else
      rc=$?
    fi
    [ "$rc" = 2 ] || fail "durable fallback should return status 2, got $rc"
    marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$corr")
    [ -f "$marker" ] || fail "delivery confirmation fallback marker should persist"
    [ -z "$(fm_pending_reply_get "$rec" delivered_epoch)" ] \
      || fail "failed primary commit should leave delivered_epoch empty"
    . "$ROOT/bin/fm-pending-reply-lib.sh"
    fm_pending_reply_tick_one "$state" "$corr" unknown \
      || fail "watcher should reconcile the delivery marker"
    [ "$(fm_pending_reply_get "$rec" delivered_epoch)" = 5750 ] \
      || fail "watcher should restore the confirmed delivery epoch"
    [ ! -e "$marker" ] || fail "reconciled delivery marker should be removed"
    prepared_corr=$(fm_pending_reply_create "$home" "$state" hibit "prepared delivery")
    prepared_rec=$(fm_pending_reply_path "$state" "$prepared_corr")
    fm_pending_reply_prepare_delivery "$state" "$prepared_corr" \
      || fail "delivery preparation should persist before transport"
    fm_pending_reply_set "$prepared_rec" grace_secs 10 \
      || fail "delivery-unknown grace fixture should persist"
    prepared_marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$prepared_corr")
    [ -f "$prepared_marker" ] || fail "prepared delivery marker should persist"
    fm_pending_reply_tick_one "$state" "$prepared_corr" unknown \
      || fail "watcher should preserve interrupted delivery state"
    [ "$(phase_of "$state" "$prepared_corr")" = awaiting_report ] \
      || fail "attempted delivery should remain pending during bounded grace"
    [ -z "$(fm_pending_reply_get "$prepared_rec" delivered_epoch)" ] \
      || fail "attempted delivery must never be promoted without confirmation"
    [ -e "$prepared_marker" ] || fail "unknown delivery marker should remain durable"
    export FM_PENDING_REPLY_NOW=5760
    fm_pending_reply_write_delivery_confirmation \
      "$state" "$prepared_corr" attempted 5750 \
      || fail "orphaned attempt fixture should persist"
    fm_pending_reply_tick_one "$state" "$prepared_corr" unknown \
      || fail "orphaned delivery attempt should escalate"
    [ "$(phase_of "$state" "$prepared_corr")" = escalated ] \
      || fail "orphaned delivery attempt should become one durable escalation"
    [ -z "$(fm_pending_reply_get "$prepared_rec" delivered_epoch)" ] \
      || fail "delivery-unknown escalation must not manufacture delivery"
    grep -Fq "pending-reply-delivery-unknown:" "$state/hibit.status" \
      || fail "delivery uncertainty should use its distinct escalation"
    fm_pending_reply_tick_one "$state" "$prepared_corr" unknown \
      || fail "repeated delivery-unknown tick should be inert"
    escalations=$(grep -Fc "pending-reply-id=$prepared_corr" "$state/hibit.status")
    [ "$escalations" = 1 ] \
      || fail "delivery-unknown escalation should publish once, got $escalations"
    printf 'done [corr=%s]: late report proves delivery\n' "$prepared_corr" >> "$state/hibit.status"
    fm_pending_reply_tick "$state" || fail "watcher should accept a late delivery report"
    prepared_rec=$(fm_pending_reply_path "$state" "$prepared_corr")
    [ "$(phase_of "$state" "$prepared_corr")" = resolved ] \
      || fail "late report should resolve escalated delivery-unknown"
    [ "$(fm_pending_reply_get "$prepared_rec" delivered_epoch)" = 5760 ] \
      || fail "late report should provide delivery evidence"
    escalations=$(grep -Fc "pending-reply-id=$prepared_corr" "$state/hibit.status")
    [ "$escalations" = 1 ] || fail "late report must not re-escalate delivery-unknown"
    fm_pending_reply_tick "$state" || fail "resolved late report should remain idempotent"
    [ "$(phase_of "$state" "$prepared_corr")" = resolved ] \
      || fail "late report resolution should remain durable"
    export FM_PENDING_REPLY_NOW=5800
    reported_corr=$(fm_pending_reply_create "$home" "$state" hibit "reported delivery")
    reported_rec=$(fm_pending_reply_path "$state" "$reported_corr")
    fm_pending_reply_prepare_delivery "$state" "$reported_corr" \
      || fail "reported delivery attempt should persist"
    reported_marker=$(fm_pending_reply_delivery_confirmation_path "$state" "$reported_corr")
    printf 'done [corr=%s]: report proves delivery\n' "$reported_corr" >> "$state/hibit.status"
    fm_pending_reply_try_resolve "$state" "$reported_corr" \
      || fail "attempted delivery with a report should resolve directly"
    reported_rec=$(fm_pending_reply_path "$state" "$reported_corr")
    [ "$(phase_of "$state" "$reported_corr")" = resolved ] \
      || fail "correlated report should resolve attempted delivery"
    [ "$(fm_pending_reply_get "$reported_rec" delivered_epoch)" = 5800 ] \
      || fail "correlated report should provide delivery evidence"
    [ ! -e "$reported_marker" ] || fail "resolved delivery marker should be removed"
    fm_pending_reply_tick_one "$state" "$reported_corr" unknown \
      || fail "resolved attempted delivery should remain inert in watcher"
    if grep -Fq "pending-reply-id=$reported_corr" "$state/hibit.status"; then
      fail "reported attempted delivery must not escalate as delivery-unknown"
    fi
  ) || fail "delivery confirmation fallback regression failed"
  pass "delivery confirmation fallback reconciles durably"
}

test_unrelated_and_stale_corr_cannot_resolve() {
  local home state corr other
  home=$(setup_parent stale-corr)
  state="$home/state"
  # Reset the fixture clock after isolated subshell tests.
  # shellcheck disable=SC2031
  export FM_PENDING_REPLY_NOW=6000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "need answer")
  fm_pending_reply_mark_delivered "$state" "$corr"
  other=$(fm_pending_reply_new_id)
  printf 'done [corr=%s]: wrong token\n' "$other" > "$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "stale/wrong corr must not resolve"
  fi
  printf 'done [corr=%s0]: prefix collision\n' "$corr" >> "$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "longer correlation token must not resolve by prefix"
  fi
  [ -z "$(fm_pending_reply_extract_corr "corr=${corr}0")" ] \
    || fail "longer correlation token must not extract a 16-hex prefix"
  printf 'done [corr=%sg]: nonhex suffix\n' "$corr" >> "$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "nonhex-suffixed correlation token must not resolve by prefix"
  fi
  [ -z "$(fm_pending_reply_extract_corr "corr=${corr}g")" ] \
    || fail "nonhex-suffixed correlation token must not extract a 16-hex prefix"
  [ -z "$(fm_pending_reply_extract_corr "notcorr=${corr}")" ] \
    || fail "embedded correlation label must not extract as a token"
  printf 'working: still thinking\n' >> "$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "unrelated working line must not resolve"
  fi
  printf 'working [corr=%s]: still thinking\n' "$corr" >> "$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "correlated progress line must not resolve"
  fi
  printf 'done: finished without corr\n' >> "$state/hibit.status"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "status without corr must not resolve"
  fi
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] || fail "phase must stay awaiting_report"
  pass "unrelated events and stale correlation ids cannot resolve"
}

test_restart_preserves_expectation_and_parent_destination() {
  local home state corr rec parent_status parent_home
  home=$(setup_parent restart)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=7000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "survive restart")
  fm_pending_reply_mark_delivered "$state" "$corr"
  rec=$(fm_pending_reply_path "$state" "$corr")
  parent_status=$(fm_pending_reply_get "$rec" parent_status)
  parent_home=$(fm_pending_reply_get "$rec" parent_home)
  # Simulate process restart: re-source library and re-read the same record.
  # shellcheck source=bin/fm-pending-reply-lib.sh
  . "$ROOT/bin/fm-pending-reply-lib.sh"
  [ -f "$rec" ] || fail "record must survive restart"
  [ "$(fm_pending_reply_get "$rec" parent_status)" = "$parent_status" ] \
    || fail "parent_status must be stable across restart"
  [ "$(fm_pending_reply_get "$rec" parent_home)" = "$parent_home" ] \
    || fail "parent_home must be stable across restart"
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] || fail "phase preserved"
  # Compaction-safe: destination is absolute path fields, not chat memory.
  case "$parent_status" in
    /*.status) : ;;
    *) fail "parent_status should be an absolute status path, got $parent_status" ;;
  esac
  pass "restart preserves expectation and exact parent destination"
}

test_wrong_home_detected_not_acknowledged() {
  local home state sm_home corr rec hits
  home=$(setup_parent wrong-home)
  state="$home/state"
  sm_home="$TMP_ROOT/sm-home-$RANDOM"
  mkdir -p "$sm_home/state"
  export FM_PENDING_REPLY_NOW=8000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "report to parent")
  fm_pending_reply_mark_delivered "$state" "$corr"
  # Historical incident shape: report written under the secondmate home.
  printf 'done [corr=%s]: stranded in self-home\n' "$corr" > "$sm_home/state/hibit.status"
  fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" \
    || fail "wrong-home detect should succeed"
  rec=$(fm_pending_reply_path "$state" "$corr")
  hits=$(fm_pending_reply_get "$rec" wrong_home_hits)
  [ "$hits" = 1 ] || fail "first wrong-home sighting should count once, got $hits"
  fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" \
    || fail "repeated wrong-home detect should succeed"
  hits=$(fm_pending_reply_get "$rec" wrong_home_hits)
  [ "$hits" = 1 ] || fail "unchanged wrong-home history should remain one hit, got $hits"
  printf 'done [corr=%s]: second stranded report\n' "$corr" >> "$sm_home/state/hibit.status"
  fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" \
    || fail "new wrong-home sighting detect should succeed"
  hits=$(fm_pending_reply_get "$rec" wrong_home_hits)
  [ "$hits" = 2 ] || fail "distinct wrong-home reports should each count once, got $hits"
  fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" \
    || fail "repeated distinct wrong-home detect should succeed"
  hits=$(fm_pending_reply_get "$rec" wrong_home_hits)
  [ "$hits" = 2 ] || fail "repeated polling should preserve two distinct hits, got $hits"
  [ "$(phase_of "$state" "$corr")" = awaiting_report ] \
    || fail "wrong-home must not silently acknowledge (phase=$(phase_of "$state" "$corr"))"
  if fm_pending_reply_try_resolve "$state" "$corr"; then
    fail "wrong-home status must not resolve via parent path"
  fi
  pass "wrong-home reports are detected but do not silently acknowledge"
}

test_unmarked_captain_input_creates_no_expectation() {
  local dir fb log home rc pending_count
  dir="$TMP_ROOT/unmarked"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_parent unmarked)
  # Crewmate target stays unmarked and creates no pending-reply record.
  fm_write_meta "$home/state/build.meta" \
    "window=sess:fm-build" "worktree=$home/wt" "project=$home/p" \
    "harness=echo" "kind=ship" "mode=no-mistakes" "yolo=off"
  run_send "$fb" "$home" "$log" "fm-build" "captain says hello"; rc=$?
  expect_code 0 "$rc" "unmarked crewmate send should succeed"
  [ "$(cat "$log")" = "captain says hello" ] \
    || fail "crewmate send should stay unmarked"$'\n'"$(cat "$log" | od -An -c)"
  pending_count=$(find "$home/state/pending-replies" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$pending_count" = 0 ] || fail "unmarked input must create no pending-reply records (got $pending_count)"
  pass "direct unmarked captain input creates no expectation"
}

test_fm_send_marked_secondmate_creates_pending_and_embeds_corr() {
  local dir fb log home rc got corr rec
  dir="$TMP_ROOT/send-pending"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_parent send-pending)
  fm_write_secondmate_meta "$home/state/hibit.meta" "$home/sm" "sess:fm-hibit"
  run_send "$fb" "$home" "$log" "fm-hibit" "audit the build"; rc=$?
  expect_code 0 "$rc" "secondmate send should succeed"
  got=$(cat "$log")
  case "$got" in
    "$FM_FROMFIRST_MARK"corr=*) : ;;
    *) fail "secondmate send must embed marker+corr"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  corr=$(fm_pending_reply_extract_corr "$got")
  [ "${#corr}" -eq 16 ] || fail "corr id should be 16 hex chars, got '$corr'"
  rec=$(fm_pending_reply_path "$home/state" "$corr")
  [ -f "$rec" ] || fail "pending-reply record must exist after marked send"
  [ "$(fm_pending_reply_get "$rec" phase)" = awaiting_report ] \
    || fail "phase should be awaiting_report after delivery"
  [ -n "$(fm_pending_reply_get "$rec" delivered_epoch)" ] \
    || fail "delivered_epoch must be set after successful send"
  [ "$(fm_pending_reply_get "$rec" task_id)" = hibit ] \
    || fail "task_id must match secondmate id"
  pass "fm-send marked secondmate path creates pending and embeds corr"
}

test_document_pointer_resolves() {
  local home state corr
  home=$(setup_parent doc-pointer)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=9000
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "deep audit")
  fm_pending_reply_mark_delivered "$state" "$corr"
  printf 'done [corr=%s]: see data/hibit/report.md\n' "$corr" > "$state/hibit.status"
  fm_pending_reply_try_resolve "$state" "$corr" || fail "document pointer status should resolve"
  [ "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" resolved_via)" = document ] \
    || fail "resolved_via should be document"
  pass "status-pointed document resolves the expectation"
}

test_helper_report_resolves() {
  local home state corr
  home=$(setup_parent helper)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=9100
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "quick answer")
  fm_pending_reply_mark_delivered "$state" "$corr"
  "$REPORT" "$state/hibit.status" "done" "$corr" "all good" \
    || fail "helper report failed"
  fm_pending_reply_try_resolve "$state" "$corr" || fail "helper report should resolve"
  [ "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" resolved_via)" = helper ] \
    || fail "resolved_via should be helper"
  pass "optional helper report resolves without being required for correctness"
}

test_busy_idle_observation_via_backend_abstraction() {
  local home state corr
  home=$(setup_parent busy-idle)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=9200
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "backend turn")
  fm_pending_reply_mark_delivered "$state" "$corr"
  # Simulates Pi/Claude secondmate busy_state from fm_backend_busy_state without
  # reading conversation text (herdr native idle/busy or tmux unknown fallback).
  fm_pending_reply_observe_busy "$state" "$corr" unknown
  [ -z "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" request_turn_completed_epoch)" ] \
    || fail "unknown busy_state must not prove turn completion"
  fm_pending_reply_observe_busy "$state" "$corr" busy
  fm_pending_reply_observe_busy "$state" "$corr" idle
  [ -n "$(fm_pending_reply_get "$(fm_pending_reply_path "$state" "$corr")" request_turn_completed_epoch)" ] \
    || fail "busy->idle must prove turn completion"
  pass "backend busy/idle observation covers Pi/Claude paths without conversation scrape"
}

test_unknown_backend_state_uses_capture_fallback() {
  local backend
  for backend in tmux zellij; do
    (
      local home state corr rec sm_home
      home=$(setup_parent "fallback-$backend")
      state="$home/state"
      sm_home="$home/sm"
      mkdir -p "$sm_home/state"
      export FM_PENDING_REPLY_GRACE_SECS=10
      # These fixture overrides are intentionally scoped to the isolated subshell.
      # shellcheck disable=SC2030,SC2031
      export FM_PENDING_REPLY_NOW=10000
      corr=$(fm_pending_reply_create "$home" "$state" "hibit" "$backend fallback")
      fm_pending_reply_mark_delivered "$state" "$corr"
      fm_write_secondmate_meta "$state/hibit.meta" "$sm_home" "session:fm-hibit"
      [ "$backend" = tmux ] || printf 'backend=%s\n' "$backend" >> "$state/hibit.meta"
      fm_backend_busy_state() { printf 'unknown'; }
      fm_backend_capture() { printf '%s' "$FM_PENDING_TEST_CAPTURE"; }
      # Invoked indirectly through FM_PENDING_REPLY_SEND_HOOK.
      # shellcheck disable=SC2329
      recovery_hook() { :; }
      # This hook override is intentionally scoped to the isolated subshell.
      # shellcheck disable=SC2030,SC2031
      export FM_PENDING_REPLY_SEND_HOOK=recovery_hook
      export FM_PENDING_TEST_CAPTURE='idle footer'
      fm_pending_reply_tick "$state"
      rec=$(fm_pending_reply_path "$state" "$corr")
      [ -z "$(fm_pending_reply_get "$rec" request_turn_completed_epoch)" ] \
        || fail "$backend fallback must not accept stale idle before grace"
      # Continue advancing the subshell-local fixture clock.
      # shellcheck disable=SC2030,SC2031
      export FM_PENDING_REPLY_NOW=10010
      fm_pending_reply_tick "$state"
      [ "$(phase_of "$state" "$corr")" = recovery_sent ] \
        || fail "$backend fallback idle should trigger recovery after grace"
      export FM_PENDING_REPLY_NOW=10011
      export FM_PENDING_TEST_CAPTURE='Working...'
      fm_pending_reply_tick "$state"
      export FM_PENDING_REPLY_NOW=10012
      export FM_PENDING_TEST_CAPTURE='idle footer'
      fm_pending_reply_tick "$state"
      [ "$(phase_of "$state" "$corr")" = escalated ] \
        || fail "$backend capture busy-to-idle should complete recovery turn"
    ) || fail "$backend unknown-state capture fallback failed"
  done
  pass "tmux and zellij unknown states use bounded capture fallback"
}

test_tick_skips_terminal_and_reuses_target_observation() {
  (
    local home state open1 open2 resolved escalated rec probe_log probes scan_log scans snapshot
    home=$(setup_parent observation-cache)
    state="$home/state"
    probe_log="$home/backend-probes.log"
    scan_log="$home/status-scans.log"
    : > "$probe_log"
    : > "$scan_log"
    # This fixture clock is intentionally scoped to the isolated subshell.
    # shellcheck disable=SC2030,SC2031
    export FM_PENDING_REPLY_NOW=10100
    open1=$(fm_pending_reply_create "$home" "$state" hibit "first open request")
    open2=$(fm_pending_reply_create "$home" "$state" hibit "second open request")
    fm_pending_reply_mark_delivered "$state" "$open1"
    fm_pending_reply_mark_delivered "$state" "$open2"
    resolved=$(fm_pending_reply_create "$home" "$state" resolved "resolved request")
    fm_pending_reply_mark_delivered "$state" "$resolved"
    printf 'done [corr=%s]: complete\n' "$resolved" > "$state/resolved.status"
    fm_pending_reply_try_resolve "$state" "$resolved" || fail "resolved fixture should resolve"
    [ ! -e "$(fm_pending_reply_active_path "$state" "$resolved")" ] \
      || fail "resolved fixture should leave the active scan directory"
    [ -f "$(fm_pending_reply_history_dir "$state")/$resolved" ] \
      || fail "resolved fixture should remain in durable history"
    escalated=$(fm_pending_reply_create "$home" "$state" escalated "escalated request")
    fm_pending_reply_mark_delivered "$state" "$escalated"
    rec=$(fm_pending_reply_path "$state" "$escalated")
    fm_pending_reply_set "$rec" phase escalated || fail "escalated fixture should transition"
    mkdir -p "$home/escalated/state"
    printf 'done [corr=%s]: wrong home\n' "$escalated" > "$home/escalated/state/escalated.status"
    fm_write_secondmate_meta "$state/hibit.meta" "$home/hibit" "sess:fm-hibit"
    fm_write_secondmate_meta "$state/resolved.meta" "$home/resolved" "sess:fm-resolved"
    fm_write_secondmate_meta "$state/escalated.meta" "$home/escalated" "sess:fm-escalated"
    fm_backend_busy_state() {
      printf '%s\t%s\n' "$1" "$2" >> "$probe_log"
      printf 'busy'
    }
    fm_backend_capture() { fail "native busy observations should not capture"; }
    fm_pending_reply_find_resolve_line() {
      local status_file=$1 corr=$2 line
      printf '%s\t%s\n' "$status_file" "$corr" >> "$scan_log"
      [ -f "$status_file" ] || return 0
      while IFS= read -r line || [ -n "$line" ]; do
        fm_pending_reply_line_resolves "$line" "$corr" || continue
        printf '%s' "$line"
        return 0
      done < "$status_file"
      return 0
    }
    fm_pending_reply_tick "$state"
    probes=$(wc -l < "$probe_log" | tr -d ' ')
    [ "$probes" = 1 ] || fail "two open records for one target should use one probe, got $probes"
    rec=$(fm_pending_reply_path "$state" "$open1")
    [ "$(fm_pending_reply_get "$rec" turn_seen_busy)" = 1 ] \
      || fail "cached observation should update the first open record"
    rec=$(fm_pending_reply_path "$state" "$open2")
    [ "$(fm_pending_reply_get "$rec" turn_seen_busy)" = 1 ] \
      || fail "cached observation should update the second open record"
    rec=$(fm_pending_reply_path "$state" "$escalated")
    snapshot=$(fm_pending_reply_get "$rec" wrong_home_scan_signature)
    [ -n "$snapshot" ] || fail "wrong-home scan should persist its file-set signature"
    fm_pending_reply_tick "$state"
    scans=$(wc -l < "$scan_log" | tr -d ' ')
    [ "$scans" = 3 ] \
      || fail "unchanged records should scan two open and one escalated status only once, got $scans"
    [ "$(fm_pending_reply_get "$rec" wrong_home_scan_signature)" = "$snapshot" ] \
      || fail "unchanged wrong-home logs should retain their scan signature"
  ) || fail "terminal-skip and observation-cache regression failed"
  pass "tick skips terminal records and reuses target observations"
}

test_partial_resolution_reconciles_after_restart() {
  local home state corr rec history
  home=$(setup_parent partial-resolution)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=10150
  corr=$(fm_pending_reply_create "$home" "$state" hibit "restart resolution")
  fm_pending_reply_mark_delivered "$state" "$corr"
  rec=$(fm_pending_reply_active_path "$state" "$corr")
  fm_pending_reply_set "$rec" resolved_epoch 10150 || fail "partial resolved epoch should persist"
  fm_pending_reply_set "$rec" resolved_via status || fail "partial resolved route should persist"
  fm_pending_reply_tick "$state" || fail "restart tick should reconcile partial resolution"
  history="$(fm_pending_reply_history_dir "$state")/$corr"
  [ ! -e "$rec" ] || fail "reconciled resolution should leave the active scan directory"
  [ -f "$history" ] || fail "reconciled resolution should retain durable history"
  [ "$(fm_pending_reply_get "$history" phase)" = resolved ] \
    || fail "reconciled resolution should commit terminal phase last"
  pass "partial resolution reconciles and archives after restart"
}

test_correlations_reuse_only_for_matching_open_task() {
  local dir fb log home state got corr1 corr2 corr3 rec
  dir="$TMP_ROOT/corr-reuse"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); log="$dir/send.log"
  home=$(setup_parent corr-reuse)
  state="$home/state"
  fm_write_secondmate_meta "$state/domain.meta" "$home/domain" "sess:fm-domain"
  fm_write_secondmate_meta "$state/other.meta" "$home/other" "sess:fm-other"
  run_send "$fb" "$home" "$log" fm-domain "first request" || fail "first marked send failed"
  got=$(cat "$log")
  corr1=$(fm_pending_reply_extract_corr "$got")
  export FM_PENDING_REPLY_EXISTING_CORR=$corr1
  run_send "$fb" "$home" "$log" fm-other "forwarded request" || fail "cross-task send failed"
  unset FM_PENDING_REPLY_EXISTING_CORR
  corr2=$(fm_pending_reply_extract_corr "$(cat "$log")")
  [ -n "$corr2" ] && [ "$corr2" != "$corr1" ] \
    || fail "cross-task send must receive a new correlation"
  rec=$(fm_pending_reply_path "$state" "$corr2")
  [ "$(fm_pending_reply_get "$rec" task_id)" = other ] \
    || fail "cross-task expectation must belong to the new target"
  printf 'done [corr=%s]: complete\n' "$corr1" > "$state/domain.status"
  fm_pending_reply_try_resolve "$state" "$corr1" || fail "first expectation should resolve"
  run_send "$fb" "$home" "$log" fm-domain "${FM_FROMFIRST_MARK}corr=${corr1} follow-up" \
    || fail "resolved-correlation follow-up failed"
  corr3=$(fm_pending_reply_extract_corr "$(cat "$log")")
  [ -n "$corr3" ] && [ "$corr3" != "$corr1" ] \
    || fail "resolved correlation must not guard a new send"
  rec=$(fm_pending_reply_path "$state" "$corr3")
  [ "$(fm_pending_reply_get "$rec" task_id)" = domain ] \
    || fail "replacement expectation must belong to the current target"
  pass "correlations are reused only for matching open task records"
}

test_tick_end_to_end_missed_then_escalate() {
  local home state corr hook_log sm_home
  home=$(setup_parent tick-e2e)
  state="$home/state"
  sm_home="$home/sm"
  mkdir -p "$sm_home/state"
  hook_log="$TMP_ROOT/tick-hook.log"
  : > "$hook_log"
  recovery_hook() { printf 'recovered\n' >> "$hook_log"; }
  export -f recovery_hook
  # Reset hook and clock fixtures after isolated subshell tests.
  # shellcheck disable=SC2031
  export FM_PENDING_REPLY_SEND_HOOK='recovery_hook'
  # shellcheck disable=SC2031
  export FM_PENDING_REPLY_NOW=9300

  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "e2e miss")
  fm_pending_reply_mark_delivered "$state" "$corr"
  fm_write_secondmate_meta "$state/hibit.meta" "$sm_home" "sess:fm-hibit"
  # Override backend busy via direct tick_one (backend may be unknown in hermetic home).
  fm_pending_reply_tick_one "$state" "$corr" busy "$sm_home"
  fm_pending_reply_tick_one "$state" "$corr" idle "$sm_home"
  [ "$(phase_of "$state" "$corr")" = recovery_sent ] \
    || fail "tick should send recovery after idle+grace, got $(phase_of "$state" "$corr")"
  [ -s "$hook_log" ] || fail "recovery should have been sent via tick"
  # Recovery turn completes empty.
  fm_pending_reply_tick_one "$state" "$corr" busy "$sm_home"
  fm_pending_reply_tick_one "$state" "$corr" idle "$sm_home"
  [ "$(phase_of "$state" "$corr")" = escalated ] \
    || fail "tick should escalate after second miss, got $(phase_of "$state" "$corr")"
  # Expired age must not erase the unresolved record.
  export FM_PENDING_REPLY_NOW=999999
  fm_pending_reply_tick_one "$state" "$corr" idle "$sm_home"
  [ -f "$(fm_pending_reply_path "$state" "$corr")" ] \
    || fail "expiration must never silently erase an unresolved reply"
  [ "$(phase_of "$state" "$corr")" = escalated ] || fail "must stay escalated"
  pass "tick end-to-end: miss -> one recovery -> escalate -> durable"
}

test_failed_send_discards_undelivered_expectation() {
  local home state corr
  home=$(setup_parent discard)
  state="$home/state"
  export FM_PENDING_REPLY_NOW=9400
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "never lands")
  # Not delivered: discard is allowed.
  fm_pending_reply_discard_undelivered "$state" "$corr" || fail "discard undelivered failed"
  [ ! -f "$(fm_pending_reply_path "$state" "$corr")" ] \
    || fail "undelivered record should be removed"
  # Delivered records must not be discarded by this path.
  corr=$(fm_pending_reply_create "$home" "$state" "hibit" "landed")
  fm_pending_reply_mark_delivered "$state" "$corr"
  if fm_pending_reply_discard_undelivered "$state" "$corr" 2>/dev/null; then
    fail "delivered record must not be discarded"
  fi
  [ -f "$(fm_pending_reply_path "$state" "$corr")" ] || fail "delivered record must remain"
  pass "failed transport discards undelivered expectation only"
}

test_force_retirement_receipts_are_source_bound() {
  local home_a home_b state_a state_b retained corr_a corr_b rec_a rec_b source_a source_b receipt_b
  home_a=$(setup_parent retirement-source-a)
  home_b=$(setup_parent retirement-source-b)
  state_a="$home_a/state"
  state_b="$home_b/state"
  retained="$TMP_ROOT/retirement-retained/state"
  mkdir -p "$retained"
  corr_a=$(fm_pending_reply_create "$home_a" "$state_a" duplicate "source a")
  corr_b=$(fm_pending_reply_create "$home_b" "$state_b" duplicate "source b")
  rec_a=$(fm_pending_reply_active_path "$state_a" "$corr_a")
  rec_b=$(fm_pending_reply_active_path "$state_b" "$corr_b")
  fm_pending_reply_set "$rec_a" phase escalated || fail "source a phase setup failed"
  fm_pending_reply_set "$rec_b" phase escalated || fail "source b phase setup failed"
  source_a=$(fm_pending_reply_source_identity "$state_a")
  source_b=$(fm_pending_reply_source_identity "$state_b")
  fm_pending_reply_stage_force_retire_task "$state_a" duplicate "$retained" \
    || fail "source a retirement staging failed"
  fm_pending_reply_stage_force_retire_task "$state_b" duplicate "$retained" \
    || fail "source b retirement staging failed"
  receipt_b=$(fm_pending_reply_handoff_path "$retained" "$source_b" "$corr_b")
  fm_pending_reply_finalize_force_retire_task "$state_a" duplicate "$retained" "$source_a" \
    || fail "source a retirement finalization failed"
  [ -f "$(fm_pending_reply_history_dir "$retained")/$corr_a" ] \
    || fail "source a history was not finalized"
  [ ! -f "$(fm_pending_reply_history_dir "$retained")/$corr_b" ] \
    || fail "source a finalizer claimed source b history"
  [ -f "$receipt_b" ] || fail "source b receipt was consumed by source a finalizer"
  fm_pending_reply_finalize_force_retire_task "$state_b" duplicate "$retained" "$source_b" \
    || fail "source b retirement finalization failed"
  [ -f "$(fm_pending_reply_history_dir "$retained")/$corr_b" ] \
    || fail "source b history was not finalized"
  pass "forced-retirement receipts remain bound to their source state"
}

test_staged_resolution_promotes_before_receipt_cleanup() {
  (
    local home state retained corr rec source receipt history
    home=$(setup_parent staged-resolution-order)
    state="$home/state"
    retained="$TMP_ROOT/staged-resolution-retained/state"
    mkdir -p "$retained"
    corr=$(fm_pending_reply_create "$home" "$state" hibit "late reply")
    fm_pending_reply_mark_delivered "$state" "$corr" \
      || fail "staged-resolution-order: delivery setup failed"
    rec=$(fm_pending_reply_active_path "$state" "$corr")
    fm_pending_reply_set "$rec" phase escalated \
      || fail "staged-resolution-order: phase setup failed"
    source=$(fm_pending_reply_source_identity "$state")
    fm_pending_reply_stage_force_retire_task "$state" hibit "$retained" \
      || fail "staged-resolution-order: retirement staging failed"
    receipt=$(fm_pending_reply_handoff_path "$retained" "$source" "$corr")
    [ -f "$receipt" ] || fail "staged-resolution-order: forced receipt was not staged"
    printf 'done [corr=%s]: arrived during teardown\n' "$corr" > "$state/hibit.status"
    fm_pending_reply_prepare_resolved_handoff() { return 1; }
    if fm_pending_reply_try_resolve "$state" "$corr"; then
      fail "staged-resolution-order: injected receipt failure should propagate"
    fi
    history="$(fm_pending_reply_history_dir "$retained")/$corr"
    [ -f "$history" ] \
      || fail "staged-resolution-order: retained history was not committed first"
    [ "$(fm_pending_reply_get "$history" phase)" = resolved ] \
      || fail "staged-resolution-order: retained history lost the resolution"
    [ ! -f "$rec" ] \
      || fail "staged-resolution-order: source remained after retained commit"
    rm -f "$receipt"
    fm_pending_reply_finalize_force_retire_task "$state" hibit "$retained" "$source" \
      || fail "staged-resolution-order: finalizer rejected receipt-free retained history"
  ) || fail "staged resolved-history ordering regression failed"
  pass "staged resolution commits retained history before receipt cleanup"
}

test_staging_reconciles_already_archived_nested_resolution() {
  local home state retained corr source history
  home=$(setup_parent staged-resolution-reconcile)
  state="$home/state"
  retained="$TMP_ROOT/staged-resolution-reconcile-retained/state"
  mkdir -p "$retained"
  corr=$(fm_pending_reply_create "$home" "$state" nested "resolved before stage commit")
  fm_pending_reply_mark_delivered "$state" "$corr" \
    || fail "staged-resolution-reconcile: delivery setup failed"
  printf 'done [corr=%s]: won staging race\n' "$corr" > "$state/nested.status"
  fm_pending_reply_try_resolve "$state" "$corr" \
    || fail "staged-resolution-reconcile: resolution setup failed"
  source=$(fm_pending_reply_source_identity "$state")
  fm_pending_reply_stage_force_retire_task "$state" nested "$retained" \
    || fail "staged-resolution-reconcile: staging did not reconcile history"
  history="$(fm_pending_reply_history_dir "$retained")/$corr"
  [ -f "$history" ] \
    || fail "staged-resolution-reconcile: resolved history stayed in nested state"
  [ ! -f "$(fm_pending_reply_history_dir "$state")/$corr" ] \
    || fail "staged-resolution-reconcile: local resolved history was not migrated"
  fm_pending_reply_finalize_force_retire_task "$state" nested "$retained" "$source" \
    || fail "staged-resolution-reconcile: migrated history was not finalizable"
  pass "staging reconciles a resolution that won the lock race"
}

test_wrong_home_scan_preserves_staged_transaction() {
  local home state retained sm_home corr rec source token detector
  home=$(setup_parent wrong-home-stage-lock)
  state="$home/state"
  retained="$TMP_ROOT/wrong-home-stage-retained/state"
  sm_home="$TMP_ROOT/wrong-home-stage-secondmate"
  mkdir -p "$retained" "$sm_home/state"
  corr=$(fm_pending_reply_create "$home" "$state" hibit "diagnostic writer lock")
  fm_pending_reply_mark_delivered "$state" "$corr" \
    || fail "wrong-home-stage-lock: delivery setup failed"
  rec=$(fm_pending_reply_active_path "$state" "$corr")
  source=$(fm_pending_reply_source_identity "$state")
  printf 'done [corr=%s]: wrong home\n' "$corr" > "$sm_home/state/hibit.status"
  fm_pending_reply_txn_lock_acquire "$state" "$corr" token \
    || fail "wrong-home-stage-lock: could not hold transaction lock"
  fm_pending_reply_detect_wrong_home "$state" "$corr" "$sm_home" &
  detector=$!
  sleep 0.1
  fm_pending_reply_set_retirement_stage \
    "$rec" 123 "$retained" escalated "$source" \
    || fail "wrong-home-stage-lock: staging setup failed"
  fm_pending_reply_txn_lock_release "$state" "$corr" "$token" \
    || fail "wrong-home-stage-lock: could not release transaction lock"
  wait "$detector" || fail "wrong-home-stage-lock: detector failed"
  [ "$(fm_pending_reply_get "$rec" retirement_history_state)" = "$retained" ] \
    || fail "wrong-home-stage-lock: diagnostic write erased staged history"
  [ "$(fm_pending_reply_get "$rec" retirement_source_state)" = "$source" ] \
    || fail "wrong-home-stage-lock: diagnostic write erased staged source"
  pass "wrong-home diagnostics serialize with retirement staging"
}

test_finalizer_rechecks_late_resolution_under_lock() {
  local home state retained corr rec source history receipt
  home=$(setup_parent finalizer-late-resolution)
  state="$home/state"
  retained="$TMP_ROOT/finalizer-late-resolution-retained/state"
  mkdir -p "$retained"
  corr=$(fm_pending_reply_create "$home" "$state" hibit "resolve during finalization")
  fm_pending_reply_mark_delivered "$state" "$corr" \
    || fail "finalizer-late-resolution: delivery setup failed"
  rec=$(fm_pending_reply_active_path "$state" "$corr")
  fm_pending_reply_set "$rec" phase escalated \
    || fail "finalizer-late-resolution: phase setup failed"
  source=$(fm_pending_reply_source_identity "$state")
  fm_pending_reply_stage_force_retire_task "$state" hibit "$retained" \
    || fail "finalizer-late-resolution: staging failed"
  printf 'done [corr=%s]: final report\n' "$corr" > "$state/hibit.status"
  fm_pending_reply_finalize_force_retire_task "$state" hibit "$retained" "$source" \
    || fail "finalizer-late-resolution: finalization failed"
  history="$(fm_pending_reply_history_dir "$retained")/$corr"
  receipt=$(fm_pending_reply_handoff_path "$retained" "$source" "$corr")
  [ "$(fm_pending_reply_get "$history" phase)" = resolved ] \
    || fail "finalizer-late-resolution: retired receipt beat late resolution"
  [ ! -f "$rec" ] || fail "finalizer-late-resolution: active record remained"
  [ ! -f "$receipt" ] || fail "finalizer-late-resolution: receipt remained"
  pass "finalization rechecks late resolution under correlation lock"
}

test_finalizer_recovers_cleared_history_marker_with_active_record() {
  local home state retained corr rec source receipt history
  home=$(setup_parent finalizer-cleared-marker)
  state="$home/state"
  retained="$TMP_ROOT/finalizer-cleared-marker-retained/state"
  mkdir -p "$retained"
  corr=$(fm_pending_reply_create "$home" "$state" hibit "retry cleared marker")
  rec=$(fm_pending_reply_active_path "$state" "$corr")
  fm_pending_reply_set "$rec" phase escalated \
    || fail "finalizer-cleared-marker: phase setup failed"
  source=$(fm_pending_reply_source_identity "$state")
  fm_pending_reply_stage_force_retire_task "$state" hibit "$retained" \
    || fail "finalizer-cleared-marker: staging failed"
  receipt=$(fm_pending_reply_handoff_path "$retained" "$source" "$corr")
  history="$(fm_pending_reply_history_dir "$retained")/$corr"
  mv "$receipt" "$history"
  fm_pending_reply_clear_retirement_stage "$history" \
    || fail "finalizer-cleared-marker: crash fixture setup failed"
  fm_pending_reply_finalize_force_retire_task "$state" hibit "$retained" "$source" \
    || fail "finalizer-cleared-marker: retry rejected durable history"
  [ ! -f "$rec" ] || fail "finalizer-cleared-marker: active record remained"
  [ "$(fm_pending_reply_get "$history" phase)" = retired ] \
    || fail "finalizer-cleared-marker: durable history was lost"
  pass "finalization recovers cleared history markers"
}

test_finalizer_preserves_report_on_resolution_archive_failure() {
  (
    local home state retained corr rec source receipt
    home=$(setup_parent finalizer-resolution-failure)
    state="$home/state"
    retained="$TMP_ROOT/finalizer-resolution-failure-retained/state"
    mkdir -p "$retained"
    corr=$(fm_pending_reply_create "$home" "$state" hibit "preserve failed resolution")
    fm_pending_reply_mark_delivered "$state" "$corr" \
      || fail "finalizer-resolution-failure: delivery setup failed"
    rec=$(fm_pending_reply_active_path "$state" "$corr")
    fm_pending_reply_set "$rec" phase escalated \
      || fail "finalizer-resolution-failure: phase setup failed"
    source=$(fm_pending_reply_source_identity "$state")
    fm_pending_reply_stage_force_retire_task "$state" hibit "$retained" \
      || fail "finalizer-resolution-failure: staging failed"
    receipt=$(fm_pending_reply_handoff_path "$retained" "$source" "$corr")
    printf 'done [corr=%s]: preserve me\n' "$corr" > "$state/hibit.status"
    fm_pending_reply_archive_resolved() { return 1; }
    if fm_pending_reply_finalize_force_retire_task "$state" hibit "$retained" "$source"; then
      fail "finalizer-resolution-failure: archive failure was suppressed"
    fi
    [ -f "$rec" ] || fail "finalizer-resolution-failure: active evidence was deleted"
    [ "$(fm_pending_reply_get "$rec" phase)" = resolved ] \
      || fail "finalizer-resolution-failure: report evidence was not persisted"
    [ -f "$receipt" ] || fail "finalizer-resolution-failure: retirement receipt was consumed"
  ) || fail "finalizer resolution failure regression failed"
  pass "finalization preserves reports when resolution archival fails"
}

# --- run --------------------------------------------------------------------

test_normal_correlated_reply_resolves_once
test_completed_turn_no_report_triggers_one_recovery
test_recovery_send_uses_strict_fm_target
test_recovery_attempt_is_never_reinjected
test_recovery_reply_resolves_original
test_second_missed_turn_escalates_once_and_stays_durable
test_concurrent_escalation_publishes_once
test_incomplete_transaction_lock_is_reclaimed
test_stale_generation_reclaim_preserves_new_owner
test_escalation_publication_failure_retries
test_transport_success_is_not_reply_success
test_undelivered_records_are_scan_immutable
test_delivery_confirmation_fallback_reconciles
test_unrelated_and_stale_corr_cannot_resolve
test_restart_preserves_expectation_and_parent_destination
test_wrong_home_detected_not_acknowledged
test_unmarked_captain_input_creates_no_expectation
test_fm_send_marked_secondmate_creates_pending_and_embeds_corr
test_document_pointer_resolves
test_helper_report_resolves
test_busy_idle_observation_via_backend_abstraction
test_unknown_backend_state_uses_capture_fallback
test_tick_skips_terminal_and_reuses_target_observation
test_partial_resolution_reconciles_after_restart
test_correlations_reuse_only_for_matching_open_task
test_tick_end_to_end_missed_then_escalate
test_failed_send_discards_undelivered_expectation
test_force_retirement_receipts_are_source_bound
test_staged_resolution_promotes_before_receipt_cleanup
test_staging_reconciles_already_archived_nested_resolution
test_wrong_home_scan_preserves_staged_transaction
test_finalizer_rechecks_late_resolution_under_lock
test_finalizer_recovers_cleared_history_marker_with_active_record
test_finalizer_preserves_report_on_resolution_archive_failure

printf 'ok - all pending-reply tests passed\n'
