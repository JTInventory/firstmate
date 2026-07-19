#!/usr/bin/env bash
# Real Herdr-lab proof for the secondmate from-firstmate marker.
#
# JT #73 does not yet make Pi's extension resource part of the secondmate
# launch shape, so this test uses the same small terminal composer used by the
# Herdr AFK lab test. It still exercises the production fm-send target
# resolution, marker transformation, Herdr pane send, and Enter submission
# against a live isolated Herdr session. Direct terminal input is sent through
# the lab helper and must remain unmarked.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_HERDR_E2E:-0}" != 1 ] && [ "${FM_SEND_MARKER_HERDR_E2E:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_E2E=1 or FM_SEND_MARKER_HERDR_E2E=1 to run the real Herdr secondmate-marker lab e2e"
  exit 0
fi

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the Herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all 1; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SESSION="fm-lab-send-secondmate-marker-$$"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-marker-e2e.XXXXXX")
HOME_DIR="$TMP_ROOT/secondmate-home"
PROJECT="$TMP_ROOT/project"
LOG_FILE="$TMP_ROOT/submitted.log"
LOOP_SCRIPT="$TMP_ROOT/composer-loop.sh"
ID='marker-lab'
REQUEST='FM_MARKER_HERDR_E2E exact-id request'
DIRECT='FM_MARKER_HERDR_DIRECT captain input'
PANE_ID=
TARGET=

cleanup_all() {
  local rc=${1:-$?}
  trap - EXIT
  [ -z "$TARGET" ] || fm_backend_herdr_kill "$TARGET" >/dev/null 2>&1 || true
  herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1 || rc=1
  rm -rf "$TMP_ROOT" || rc=1
  return "$rc"
}
on_exit() { local rc=$?; cleanup_all "$rc"; exit "$?"; }
trap on_exit EXIT

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config" "$HOME_DIR/projects" "$PROJECT"
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

export HERDR_SESSION="$SESSION"
export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state"
fm_backend_source herdr || fail "could not load the Herdr backend"

cat > "$LOOP_SCRIPT" <<'LOOP'
#!/usr/bin/env bash
set -u
log=$1
old_stty=$(stty -g 2>/dev/null || true)
[ -z "$old_stty" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() { [ -z "$old_stty" ] || stty "$old_stty" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
buf=
redraw() { printf '\r\033[K> %s' "$buf"; }
submit() {
  local hex
  hex=$(printf '%s' "$buf" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\n' "$hex" "$buf" >> "$log"
  buf=
  printf '\r\033[K\n'
  redraw
}
redraw
: > "${log}.ready"
while IFS= read -r -n 1 ch; do
  if [ -z "$ch" ] || [ "$ch" = $'\r' ] || [ "$ch" = $'\n' ]; then
    submit
  elif [ "$ch" = $'\177' ] || [ "$ch" = $'\b' ]; then
    buf=${buf%?}; redraw
  else
    buf="${buf}${ch}"; redraw
  fi
done
LOOP
chmod +x "$LOOP_SCRIPT"

container_raw=$(fm_backend_herdr_container_ensure "$PROJECT") || fail "could not ensure the isolated Herdr workspace"
container=${container_raw%%$'\t'*}
seeded_tab=${container_raw#*$'\t'}
task_ids=$(fm_backend_herdr_create_task "$container" "fm-$ID" "$PROJECT" "$seeded_tab") \
  || fail "could not create the isolated secondmate-shaped Herdr pane"
read -r _tab_id PANE_ID <<EOF
$task_ids
EOF
[ -n "$PANE_ID" ] || fail "Herdr lab task did not return a pane id"
TARGET="$SESSION:$PANE_ID"

# Current JT selector semantics use the recorded fm-<id> task label. The
# secondmate kind is the routing boundary that owns the marker transformation.
cat > "$HOME_DIR/state/$ID.meta" <<EOF
window=$TARGET
backend=herdr
kind=secondmate
herdr_session=$SESSION
herdr_pane_id=$PANE_ID
harness=lab
EOF

fm_backend_herdr_send_text_line "$TARGET" "bash '$LOOP_SCRIPT' '$LOG_FILE'" \
  || fail "could not start the lab composer loop"
for _i in $(seq 1 50); do
  [ -e "${LOG_FILE}.ready" ] && break
  sleep 0.2
done
[ -e "${LOG_FILE}.ready" ] || fail "lab composer loop did not become ready"

FM_ROOT_OVERRIDE="$ROOT" FM_GATE_REFUSE_BYPASS=1 FM_SEND_SETTLE=0 FM_SEND_SLEEP=0.1 \
  "$ROOT/bin/fm-send.sh" "fm-$ID" "$REQUEST" >/dev/null \
  || fail "fm-send did not submit the marked Herdr request"
for _i in $(seq 1 50); do
  grep -F "$REQUEST" "$LOG_FILE" >/dev/null 2>&1 && break
  sleep 0.2
done
marked_line=$(grep -F -- "$REQUEST" "$LOG_FILE" 2>/dev/null | head -n 1 || true)
marked_hex=${marked_line%%$'\t'*}
marked_text=${marked_line#*$'\t'}
expected_hex=$(printf '%s' "${FM_FROMFIRST_MARK}${REQUEST}" | od -An -tx1 | tr -d ' \n')
marked_count=$(grep -F -- "$REQUEST" "$LOG_FILE" 2>/dev/null | wc -l | tr -d '[:space:]')
submission_count=$(wc -l < "$LOG_FILE" | tr -d '[:space:]')
[ "$marked_count" = 1 ] && [ "$submission_count" = 1 ] \
  && [ "$marked_text" = "${FM_FROMFIRST_MARK}${REQUEST}" ] && [ "$marked_hex" = "$expected_hex" ] \
  || fail "fm-send did not deliver exactly one terminal-safe marker through Herdr (expected=$expected_hex got=$marked_hex; text=$(printf '%s' "$marked_text" | od -An -tx1 | tr -d ' \\n'); log=$(od -An -tx1 "$LOG_FILE" 2>/dev/null | tr -d ' \\n'); pane=$(fm_backend_herdr_capture "$TARGET" 40 2>/dev/null || true))"
pass "real Herdr lab: secondmate fm-send delivers exactly one from-firstmate marker"

"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane send-text "$PANE_ID" "$DIRECT" >/dev/null \
  || fail "direct lab input send failed"
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane send-keys "$PANE_ID" enter >/dev/null \
  || fail "direct lab input submit failed"
for _i in $(seq 1 50); do
  direct_line=$(grep -F -- "$DIRECT" "$LOG_FILE" 2>/dev/null | head -n 1 || true)
  direct_hex=${direct_line%%$'\t'*}
  [ -n "$direct_hex" ] && break
  sleep 0.2
done
expected_direct_hex=$(printf '%s' "$DIRECT" | od -An -tx1 | tr -d ' \n')
[ "$direct_hex" = "$expected_direct_hex" ] \
  || fail "direct captain input was changed or marked through the Herdr lab (expected=$expected_direct_hex got=$direct_hex)"
pass "real Herdr lab: direct captain input remains unmarked"

cleanup_all 0
exit $?
