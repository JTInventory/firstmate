#!/usr/bin/env bash
# Unit coverage for the destructive-operation guard in fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by Herdr lab)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-herdr-lab-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
TRIPWIRES="$TMP_ROOT/tripwires"
LOG="$TMP_ROOT/herdr.log"
mkdir -p "$FAKE_STATE" "$TRIPWIRES"
printf '%s\n' '/tmp/default.sock' > "$FAKE_STATE/default-socket"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
state=${FM_FAKE_HERDR_STATE:?}
log=${FM_FAKE_HERDR_LOG:?}
printf '%s\n' "$*" >> "$log"
last=
previous=
for arg in "$@"; do previous=$last; last=$arg; done
[ "$previous" = --session ] || { echo 'fake herdr: missing trailing --session' >&2; exit 90; }
session=$last
lab=absent
[ ! -f "$state/$session" ] || lab=$(cat "$state/$session")
case "${1:-} ${2:-}" in
  'session list')
    socket=$(cat "$state/default-socket")
    if [ "$lab" = absent ] || [ "$lab" = deleted ]; then
      jq -nc --arg socket "$socket" '{sessions:[{default:true,name:"default",running:true,socket_path:$socket}]}'
    else
      running=false; [ "$lab" = running ] && running=true
      jq -nc --arg socket "$socket" --arg name "$session" --argjson running "$running" \
        '{sessions:[{default:true,name:"default",running:true,socket_path:$socket},{default:false,name:$name,running:$running,socket_path:("/tmp/" + $name + ".sock")}]}'
    fi
    ;;
  'server '*) printf '%s\n' running > "$state/$session" ;;
  'status --json')
    [ "$lab" = running ] && printf '%s\n' '{"server":{"running":true}}' || printf '%s\n' '{"server":{"running":false}}'
    ;;
  'session stop') printf '%s\n' stopped > "$state/$session" ;;
  'session delete')
    [ "${FM_FAKE_HERDR_DELETE_FAIL:-0}" = 1 ] && exit 93
    printf '%s\n' deleted > "$state/$session"
    ;;
  *) printf '%s\n' '{"ok":true}' ;;
esac
SH
chmod +x "$FAKEBIN/herdr"

run_fake() {
  PATH="$FAKEBIN:$PATH" FM_FAKE_HERDR_STATE="$FAKE_STATE" FM_FAKE_HERDR_LOG="$LOG" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" "$@"
}

# shellcheck source=bin/fm-herdr-lab.sh
. "$ROOT/bin/fm-herdr-lab.sh"

test_names_fail_closed() {
  local status=0 name
  fm_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "default must not be a lab session name"
  status=0
  fm_herdr_lab_validate_name arbitrary >/dev/null 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "non-lab names must be rejected"
  name=$(fm_herdr_lab_name smoke)
  [[ "$name" = fm-lab-smoke-* ]] || fail "generated lab name '$name' lacks the required prefix"
  pass "Herdr lab names are scoped to fm-lab-* and reject default"
}

test_guarded_lifecycle() {
  local name="fm-lab-unit-$$" status=0
  : > "$LOG"
  run_fake fm_herdr_lab_provision "$name" || fail "lab provision failed"
  [ -f "$TRIPWIRES/$name.fleet-state.json" ] || fail "provision did not create a fleet tripwire"
  run_fake fm_herdr_lab_cli "$name" workspace list >/dev/null || fail "safe lab command failed"
  run_fake fm_herdr_lab_cli "$name" server >/dev/null 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "bare server operation was not rejected"
  status=0
  run_fake fm_herdr_lab_cli "$name" session delete "$name" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "direct session delete was not rejected"
  status=0
  run_fake fm_herdr_lab_cli "$name" status --session default >/dev/null 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "caller-supplied session was not rejected"
  run_fake fm_herdr_lab_teardown "$name" || fail "guarded teardown failed"
  [ ! -e "$TRIPWIRES/$name.fleet-state.json" ] || fail "successful teardown left its tripwire"
  pass "Herdr lab lifecycle uses trailing session scoping and guarded teardown"
}

test_missing_tripwire_blocks_destruction() {
  local name="fm-lab-no-tripwire-$$" before after status=0
  : > "$LOG"
  before=$(wc -l < "$LOG")
  run_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "missing tripwire should refuse teardown"
  after=$(wc -l < "$LOG")
  [ "$before" = "$after" ] || fail "missing tripwire made a Herdr call"
  pass "Herdr lab refuses destructive operations without ownership evidence"
}

test_default_is_never_destructive() {
  local status=0
  run_fake fm_herdr_lab_stop default >/dev/null 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "stop default should fail closed"
  status=0
  run_fake fm_herdr_lab_teardown default >/dev/null 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "teardown default should fail closed"
  pass "Herdr lab never stops or deletes the default session"
}

test_names_fail_closed
test_guarded_lifecycle
test_missing_tripwire_blocks_destruction
test_default_is_never_destructive
