#!/usr/bin/env bash
# Real AF_UNIX/SO_PEERCRED coverage for the per-home authority broker.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BROKER="$ROOT/bin/fm-session-authority-broker.py"
TMP_ROOT=$(fm_test_tmproot fm-session-authority-broker)
HOME_DIR="$TMP_ROOT/home"
FOREIGN_HOME="$TMP_ROOT/foreign"
STATE="$HOME_DIR/state"
RECORD="$STATE/.session-authority-broker"
BROKER_PID=
LAUNCH_PID=
REQUEST_FIFO=
REQUEST_SEQUENCE=0
BROKER_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

cleanup() {
  [ -z "$BROKER_PID" ] || kill "$BROKER_PID" 2>/dev/null || true
  [ -z "$BROKER_PID" ] || wait "$BROKER_PID" 2>/dev/null || true
  [ -z "$LAUNCH_PID" ] || kill "$LAUNCH_PID" 2>/dev/null || true
  [ -z "$LAUNCH_PID" ] || wait "$LAUNCH_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

test_process_start() {
  python3 - "$1" <<'PY'
import sys
from pathlib import Path

line = Path(f"/proc/{sys.argv[1]}/stat").read_text()
print(f"proc:{line[line.rfind(')') + 2:].split()[19]}")
PY
}

test_process_identity() {
  printf 'exe:%s' "$(readlink "/proc/$1/exe")"
}

prepare_launch() {
  local home=$1 launch_script
  local launch_start launch_identity receipt_body receipt_hmac
  launch_script="$home/bin/fm-session-authority-exec.sh"
  [ -z "$LAUNCH_PID" ] || kill "$LAUNCH_PID" 2>/dev/null || true
  [ -z "$LAUNCH_PID" ] || wait "$LAUNCH_PID" 2>/dev/null || true
  REQUEST_FIFO="$TMP_ROOT/requests-$REQUEST_SEQUENCE"
  REQUEST_SEQUENCE=$((REQUEST_SEQUENCE + 1))
  mkdir -p "$home/bin" "$home/state"
  rm -f "$REQUEST_FIFO"
  mkfifo "$REQUEST_FIFO"
  cat > "$launch_script" <<SH
#!/usr/bin/env bash
set -u
while :; do
  exec 7< "$REQUEST_FIFO"
  while IFS='|' read -r kind role request_home output <&7; do
    [ -n "\$output" ] || continue
    status=0
    (
      cd "\$request_home" || exit 1
      case "\$kind" in
        live|durable)
          printf 'fixed-public-test-body' | env \\
            FM_AGENT_ROLE="\$role" FM_AGENT_TASK=alpha \\
            FM_AGENT_OWNER_HOME="\$request_home" \\
            python3 "$BROKER" client --record "$RECORD" --kind "\$kind" >"\$output"
          ;;
        library)
          printf 'library-public-test-body' | env \\
            FM_HOME="\$request_home" FM_ROOT_OVERRIDE="$ROOT" \\
            FM_AGENT_ROLE="\$role" FM_AGENT_TASK=alpha \\
            FM_AGENT_OWNER_HOME="\$request_home" bash -c '
              . "\$1/bin/fm-session-lock-lib.sh"
              fm_session_authority_capability_present || exit 1
              fm_session_authority_hmac
            ' broker-library "$ROOT" >"\$output"
          ;;
        *)
          status=1
          ;;
      esac
    ) || status=1
    printf '%s\n' "\$status" > "\$output.status"
  done
  exec 7<&-
done
SH
  chmod 700 "$launch_script"
  (
    cd "$home" || exit 1
    exec "$launch_script"
  ) >/dev/null 2>&1 &
  LAUNCH_PID=$!
  launch_start=$(test_process_start "$LAUNCH_PID") \
    || fail "authenticated launch fixture did not start"
  launch_identity=$(test_process_identity "$LAUNCH_PID") \
    || fail "authenticated launch fixture has no executable identity"
  receipt_body=$(printf 'version=1\ntask=alpha\nhome=%s\npid=%s\nstart=%s\nidentity=%s' \
    "$home" "$LAUNCH_PID" "$launch_start" "$launch_identity")
  receipt_body="${receipt_body}"$'\n'
  receipt_hmac=$(BROKER_KEY="$BROKER_KEY" RECEIPT_BODY="$receipt_body" \
    python3 -c 'import hashlib, hmac, os; print(hmac.new(bytes.fromhex(os.environ["BROKER_KEY"]), os.environ["RECEIPT_BODY"].encode(), hashlib.sha256).hexdigest())')
  printf '%sauthority-hmac=%s\n' "$receipt_body" "$receipt_hmac" \
    > "$home/state/.session-authority-launch"
  LAUNCH_SCRIPT="$launch_script"
}

start_broker() {
  local evidence_fd receipt_b64 attempts=0
  receipt_b64=$(openssl base64 -A < "$HOME_DIR/state/.session-authority-launch") \
    || fail "could not encode authenticated launch evidence"
  exec {evidence_fd}< <(printf '%s\n%s\n' "$BROKER_KEY" "$receipt_b64")
  python3 "$BROKER" serve --state "$STATE" --home "$HOME_DIR" \
    --checkout "$ROOT" --task alpha --launch-evidence-fd "$evidence_fd" \
    --launch-script "$LAUNCH_SCRIPT" >/dev/null 2>&1 &
  BROKER_PID=$!
  eval "exec ${evidence_fd}<&-"
  while [ "$attempts" -lt 100 ] && [ ! -f "$RECORD" ]; do
    kill -0 "$BROKER_PID" 2>/dev/null \
      || fail "authority broker exited before publishing its record"
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] \
    || fail "authority broker did not publish a private regular record"
}

broker_hmac() {
  local home=$1 role=$2 kind=$3 output status attempts=0
  output="$TMP_ROOT/request-${BASHPID:-$$}-$REQUEST_SEQUENCE"
  REQUEST_SEQUENCE=$((REQUEST_SEQUENCE + 1))
  printf '%s|%s|%s|%s\n' "$kind" "$role" "$home" "$output" > "$REQUEST_FIFO"
  while [ "$attempts" -lt 100 ]; do
    if [ -f "$output.status" ]; then
      status=$(cat "$output.status")
      [ "$status" = 0 ] || return 1
      cat "$output"
      return 0
    fi
    sleep 0.02
    attempts=$((attempts + 1))
  done
  return 1
}

broker_direct_hmac() {
  local home=$1 role=$2 kind=$3
  (cd "$home" && printf 'fixed-public-test-body' | env \
    FM_AGENT_ROLE="$role" FM_AGENT_TASK=alpha FM_AGENT_OWNER_HOME="$home" \
    python3 "$BROKER" client --record "$RECORD" --kind "$kind")
}

broker_library_hmac() {
  broker_hmac "$HOME_DIR" secondmate library
}

mkdir -p "$STATE" "$FOREIGN_HOME"
prepare_launch "$HOME_DIR"
start_broker
[ "$(stat -c '%a' "$RECORD")" = 600 ] \
  || fail "authority broker record was not private"

live=$(broker_hmac "$HOME_DIR" secondmate live) \
  || fail "same-home secondmate could not use live broker authority"
durable_one=$(broker_hmac "$HOME_DIR" secondmate durable) \
  || fail "same-home secondmate could not use durable broker authority"
durable_two=$(broker_hmac "$HOME_DIR" secondmate durable) \
  || fail "same-home durable authority was not reusable"
case "$live:$durable_one" in
  *[!0-9a-f:]*|:*|*::*|*:) fail "authority broker returned a malformed digest" ;;
esac
[ "${#live}" -eq 64 ] && [ "${#durable_one}" -eq 64 ] \
  && [ "$live" != "$durable_one" ] && [ "$durable_one" = "$durable_two" ] \
  || fail "broker did not retain separate live and durable in-memory authority"
pass "peer-credential broker retains separate live and durable authority"

if broker_direct_hmac "$HOME_DIR" secondmate live >/dev/null 2>&1; then
  fail "a same-home caller without authenticated launch ancestry used broker authority"
fi
pass "peer-credential broker rejects forgeable same-home client metadata"

if broker_hmac "$FOREIGN_HOME" secondmate live >/dev/null 2>&1; then
  fail "cross-home secondmate used another home's authority broker"
fi
pass "peer-credential broker rejects a cross-home secondmate"

if broker_hmac "$HOME_DIR" crewmate live >/dev/null 2>&1; then
  fail "declared crewmate used secondmate authority"
fi
if (cd "$HOME_DIR" && FM_AGENT_ROLE=crewmate FM_AGENT_TASK=nested \
    FM_AGENT_OWNER_HOME="$HOME_DIR" bash -c '
      printf fixed-public-test-body | env FM_AGENT_ROLE=secondmate \
        FM_AGENT_TASK=alpha FM_AGENT_OWNER_HOME="$1" \
        python3 "$2" client --record "$3" --kind live
    ' broker-test "$HOME_DIR" "$BROKER" "$RECORD") >/dev/null 2>&1; then
  fail "crewmate ancestor forged a secondmate broker request"
fi
pass "peer-credential broker rejects crewmate callers and forged descendants"

if ! python3 - "$BROKER" <<'PY'
import importlib.util
import sys
from pathlib import Path

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

home = "/test/home"
script = str(broker_path)

def canonical(value):
    return script if value == script else home

broker.canonical = canonical
broker.os.readlink = lambda path: home if path.endswith("/cwd") else "/usr/bin/python3"
broker.process_command = lambda pid: ["python3", script, "client"]
broker.process_start = lambda pid: "proc:x"
broker.process_identity = lambda pid: "exe:x"
broker.process_environment = lambda pid: {
    "FM_AGENT_ROLE": "secondmate",
    "FM_AGENT_TASK": "alpha",
    "FM_AGENT_OWNER_HOME": home,
}
broker.parent_pid = lambda pid: pid + 1

if broker.peer_is_authorized(
    42, uid=1000, gid=1000, home=home, task="alpha", script=script,
    launch_pid=999, launch_start="proc:x", launch_identity="exe:x",
    broker_uid=1000, broker_gid=1000
):
    raise SystemExit("bounded ancestry walk authorized without reaching the launch process")
PY
then
  fail "the broker authorized a bounded ancestry walk that never reached the launch process"
fi
pass "peer-credential broker fails closed when ancestry depth is exhausted"

library_live=$(broker_library_hmac) \
  || fail "session-lock library did not adopt the peer-credential broker"
[ "${#library_live}" -eq 64 ] \
  || fail "session-lock library returned a malformed broker digest"
pass "session-lock library adopts the peer-credential authority channel"

kill "$BROKER_PID" 2>/dev/null || true
wait "$BROKER_PID" 2>/dev/null || true
BROKER_PID=
LONG_COMPONENT=home-$(printf '%080d' 0)
HOME_DIR="$TMP_ROOT/$LONG_COMPONENT"
STATE="$HOME_DIR/state"
RECORD="$STATE/.session-authority-broker"
LONG_SOCKET="$STATE/.session-authority-broker.sock"
mkdir -p "$STATE"
[ "${#LONG_SOCKET}" -ge 108 ] \
  || fail "long-home broker fixture did not exceed the Linux filesystem socket limit"
prepare_launch "$HOME_DIR"
start_broker
long_home_live=$(broker_hmac "$HOME_DIR" secondmate live) \
  || fail "same-home secondmate could not use authority from a long home"
[ "${#long_home_live}" -eq 64 ] \
  || fail "long-home authority broker returned a malformed digest"
pass "peer-credential broker supports homes beyond the filesystem socket path limit"

echo "# all fm-session-authority-broker tests passed"
