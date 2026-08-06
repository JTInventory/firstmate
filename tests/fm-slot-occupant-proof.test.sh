#!/usr/bin/env bash
# Pooled-slot disposal must inspect only the process bound to the task endpoint.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-slot-owner-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-slot-occupant-proof)
PROJECT="$TMP_ROOT/project"
WORKTREE="$TMP_ROOT/worktree"
HOME_DIR="$TMP_ROOT/home"
BG_PIDS=()

cleanup() {
  local pid
  for pid in "${BG_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup "$TMP_ROOT"
}
trap cleanup EXIT

mkdir -p "$HOME_DIR/state"
fm_git_worktree "$PROJECT" "$WORKTREE" slot-occupant-proof
fm_slot_stamp_write "$WORKTREE" task-a "$HOME_DIR" \
  || fail "could not stamp focused slot fixture"

(
  cd "$WORKTREE" || exit 1
  exec env FM_AGENT_TASK=task-a FM_AGENT_OWNER_HOME="$HOME_DIR" \
    FM_AGENT_ROLE=crewmate sleep 300
) >/dev/null 2>&1 &
SELF_PID=$!
BG_PIDS+=("$SELF_PID")

for _ in $(seq 1 50); do
  [ "$(readlink "/proc/$SELF_PID/cwd" 2>/dev/null || true)" = "$WORKTREE" ] && break
  sleep 0.02
done

REAL_PROC_CWD=$(declare -f fm_agent_proc_cwd | sed '1s/fm_agent_proc_cwd/_fm_real_agent_proc_cwd/')
eval "$REAL_PROC_CWD"
ENDPOINT_PID=$SELF_PID
fm_agent_proc_cwd() {
  # Exact endpoint proof must never consult an unrelated live process.
  [ "$1" = "$ENDPOINT_PID" ] || return 1
  _fm_real_agent_proc_cwd "$1"
}
fm_backend_foreground_process_pid() {
  [ "$1" = herdr ] && [ "$2" = lab:pane-a ] || return 1
  printf '%s' "$ENDPOINT_PID"
}

verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate live herdr lab:pane-a)
[ "$verdict" = dispose ] \
  || fail "an unrelated unreadable process blocked exact endpoint proof: $verdict"
pass "slot disposal scopes live-process proof to the exact backend endpoint"

(
  cd "$WORKTREE" || exit 1
  exec env FM_AGENT_TASK=foreign-task FM_AGENT_OWNER_HOME="$HOME_DIR" \
    FM_AGENT_ROLE=crewmate sleep 300
) >/dev/null 2>&1 &
ENDPOINT_PID=$!
BG_PIDS+=("$ENDPOINT_PID")
for _ in $(seq 1 50); do
  [ "$(readlink "/proc/$ENDPOINT_PID/cwd" 2>/dev/null || true)" = "$WORKTREE" ] && break
  sleep 0.02
done
verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate live herdr lab:pane-a)
case "$verdict" in
  "retain: the endpoint-bound process for task(s) foreign-task is running in the slot"*) ;;
  *) fail "a foreign endpoint-bound occupant did not retain the slot: $verdict" ;;
esac
pass "a foreign endpoint-bound occupant retains the durable lease"

fm_backend_foreground_process_pid() { return 1; }
verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate live herdr lab:pane-a)
[ "$verdict" = "retain: authoritative endpoint-occupant evidence is unavailable" ] \
  || fail "missing exact endpoint proof did not retain the durable lease: $verdict"
pass "missing exact endpoint proof retains the durable lease"

verdict=$(fm_slot_disposal_verdict "$HOME_DIR/state" task-a "$WORKTREE" \
  "$HOME_DIR" "$HOME_DIR" crewmate closed herdr lab:pane-a)
[ "$verdict" = dispose ] \
  || fail "a proven closed endpoint blocked clean disposal: $verdict"
pass "a proven closed endpoint needs no live-process census"

echo "# all fm-slot-occupant-proof tests passed"
