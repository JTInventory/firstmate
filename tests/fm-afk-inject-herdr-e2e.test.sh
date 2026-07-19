#!/usr/bin/env bash
# Real Herdr AFK-inject coverage. It is intentionally gated and uses only a
# disposable fm-lab-* session; the captain's default session is never touched.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SESSION="fm-lab-afk-inject-$$"
STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-herdr-e2e.XXXXXX")
LOG_FILE="$STATE_DIR/submitted.log"
LOOP_SCRIPT="$STATE_DIR/supervisor-loop.sh"
PANE_ID=
TARGET=
: > "$LOG_FILE"

cleanup_all() {
  fm_herdr_lab_teardown "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$STATE_DIR"
}
trap cleanup_all EXIT

fm_herdr_lab_provision "$SESSION" >/dev/null || fail "could not provision the isolated Herdr lab"

export HERDR_SESSION="$SESSION"
export FM_HOME="$STATE_DIR" FM_STATE_OVERRIDE="$STATE_DIR"

# shellcheck source=bin/fm-supervise-daemon.sh
. "$DAEMON"
fm_backend_source herdr || fail "could not load the Herdr backend"

container_raw=$(fm_backend_herdr_container_ensure /tmp) || fail "could not ensure the lab workspace"
container=${container_raw%%$'\t'*}
seeded_tab=${container_raw#*$'\t'}
task_ids=$(fm_backend_herdr_create_task "$container" fm-afk-supervisor /tmp "$seeded_tab") \
  || fail "could not create the lab supervisor pane"
read -r _tab_id PANE_ID <<EOF
$task_ids
EOF
[ -n "$PANE_ID" ] || fail "lab supervisor task did not return a pane id"
TARGET="$SESSION:$PANE_ID"

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

fm_backend_herdr_send_text_line "$TARGET" "bash '$LOOP_SCRIPT' '$LOG_FILE'" \
  || fail "could not start the lab supervisor loop"
for _i in $(seq 1 50); do
  [ -e "${LOG_FILE}.ready" ] && break
  sleep 0.2
done
[ -e "${LOG_FILE}.ready" ] || fail "lab supervisor loop did not become ready"

afk_enter "$STATE_DIR"
FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" \
  FM_INJECT_CONFIRM_SLEEP=0.1 FM_INJECT_CONFIRM_RETRIES=3 \
  inject_msg "herdr afk e2e" "$STATE_DIR" \
  || fail "Herdr AFK injection did not confirm submission"

for _i in $(seq 1 30); do
  [ -s "$LOG_FILE" ] && break
  sleep 0.2
done
[ -s "$LOG_FILE" ] || fail "lab supervisor did not record the injected message"
hex=$(cut -f1 "$LOG_FILE")
case "$hex" in
  1f*) : ;;
  *) fail "injected Herdr payload did not preserve the JT sentinel (hex=$hex)" ;;
esac
grep -F 'herdr afk e2e' "$LOG_FILE" >/dev/null \
  || fail "lab supervisor recorded the wrong injected message"
pass "Herdr AFK injection uses the selected lab supervisor pane and send primitives"
