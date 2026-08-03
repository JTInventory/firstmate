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

test_broker_client_deadline_covers_connect_and_send() {
  local source first_timeout connect second_timeout send
  source=$(sed -n '/^def client(/,/^def parse_args/p' "$BROKER")
  first_timeout=$(printf '%s\n' "$source" | grep -n 'connection.settimeout(BROKER_REQUEST_TIMEOUT_SECONDS)' | head -1 | cut -d: -f1)
  connect=$(printf '%s\n' "$source" | grep -n 'connection.connect(' | head -1 | cut -d: -f1)
  second_timeout=$(printf '%s\n' "$source" | grep -n 'connection.settimeout(timeout)' | head -1 | cut -d: -f1)
  send=$(printf '%s\n' "$source" | grep -n 'connection.sendall' | head -1 | cut -d: -f1)
  [ -n "$first_timeout" ] && [ -n "$connect" ] && [ "$first_timeout" -lt "$connect" ] \
    || fail "broker client did not bound AF_UNIX connect"
  [ -n "$second_timeout" ] && [ -n "$send" ] && [ "$second_timeout" -lt "$send" ] \
    || fail "broker client did not bound request send"
  pass "broker client applies its deadline before connect and send"
}

test_broker_client_deadline_covers_connect_and_send

test_broker_client_deadline_is_behavioral() {
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import io
import sys
from types import SimpleNamespace

broker_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("session_authority_broker_deadline", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

broker.read_record = lambda _path: {"socket": "abstract:test"}
broker.connected_peer_matches_record = lambda _connection, _metadata: True

class FakeConnection:
    def __init__(self, mode):
        self.mode = mode
        self.timeouts = []

    def settimeout(self, value):
        self.timeouts.append(value)

    def connect(self, _address):
        if self.mode == "connect":
            raise TimeoutError("connect stalled")

    def sendall(self, _payload):
        raise TimeoutError("send stalled")

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

def run(mode, clock):
    connection = FakeConnection(mode)
    broker.socket.socket = lambda *_args: connection
    broker.time.monotonic = lambda: clock.pop(0)
    broker.sys.stdin = io.TextIOWrapper(io.BytesIO(b"body"))
    status = broker.client(SimpleNamespace(record="unused", kind="live"))
    if status != 1:
        raise SystemExit(f"{mode} stall returned {status}")
    return connection.timeouts

connect_timeouts = run("connect", [100.0])
if connect_timeouts != [broker.BROKER_REQUEST_TIMEOUT_SECONDS]:
    raise SystemExit(f"connect deadline missing: {connect_timeouts}")

send_timeouts = run("send", [100.0, 100.1])
if len(send_timeouts) != 2 or send_timeouts[1] <= 0:
    raise SystemExit(f"send deadline missing: {send_timeouts}")
PY
  then
    fail "broker connect/send deadline behavior regressed"
  fi
  pass "broker connect and send stalls honor the request deadline"
}

if [ "${FM_SESSION_AUTHORITY_BROKER_FOCUS:-}" = review-fixes ]; then
  test_broker_client_deadline_is_behavioral
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import sys
from pathlib import Path

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_watchdog", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

def unavailable(_pid):
    raise OSError("unreadable process identity")

broker.process_generation_for_recovery = unavailable
if broker.launch_process_state(42, "proc:start", "exe:identity", "/authority-exec.sh") != "unknown":
    raise SystemExit("watchdog treated inspection failure as process death")
PY
  then
    fail "broker watchdog did not retain an unknown launch state"
  fi
  pass "broker watchdog retains authority on launch inspection failure"
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_recovery", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

with TemporaryDirectory() as temporary:
    home = Path(temporary)
    record = home / "state" / ".session-authority-broker"
    record.parent.mkdir()
    record.write_text("forged\n", encoding="utf-8")
    metadata = {
        "home": str(home),
        "checkout": "/forged/checkout",
        "script": "/forged/checkout/bin/fm-session-authority-broker.py",
        "launch-script": str(home / "bin" / "fm-session-authority-exec.sh"),
    }
    broker.read_record_shape = lambda _path: metadata
    broker.stop_recorded_broker = lambda *_args: (_ for _ in ()).throw(
        AssertionError("forged broker path reached termination")
    )
    status = broker.recover_stale(SimpleNamespace(record=str(record)))
    if status != 1 or not record.exists():
        raise SystemExit("recovery accepted mutable broker script metadata")
PY
  then
    fail "stale recovery did not bind termination to the current broker script"
  fi
  pass "stale recovery rejects forged broker checkout metadata"
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_termination", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

generation = ("proc:broker", "exe:python")
broker.process_generation_for_recovery = lambda _pid: generation
broker.process_command = lambda _pid: [
    "python3",
    str(broker_path),
    "serve",
    "--state",
    "/other/state",
    "--home",
    "/other/home",
    "--checkout",
    str(broker_path.parent.parent),
    "--task",
    "other",
    "--launch-evidence-fd",
    "19",
    "--launch-script",
    "/other/home/bin/fm-session-authority-exec.sh",
]
if broker.stop_recorded_broker(
    42,
    generation,
    script=str(broker_path),
    state="/home/state",
    home="/home",
    checkout=str(broker_path.parent.parent),
    task="alpha",
    launch_script="/home/bin/fm-session-authority-exec.sh",
):
    raise SystemExit("termination accepted another home's broker argv")
PY
  then
    fail "broker termination did not validate the complete canonical argv"
  fi
  pass "stale recovery rejects another home's broker argv"
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_unlink", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

with TemporaryDirectory() as temporary:
    record = Path(temporary) / "record"
    record.write_text("replacement\n", encoding="utf-8")
    original_stat = os.stat_result((0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    current_stat = record.lstat()
    if broker.unlink_owned_record(
        record,
        {},
        expected_stat=original_stat,
    ):
        raise SystemExit("inode mismatch removed a replacement record")
    if not record.exists() or current_stat.st_ino == original_stat.st_ino:
        raise SystemExit("inode replacement fixture was not distinct")
PY
  then
    fail "stale record deletion did not reject an inode replacement"
  fi
  pass "stale record deletion rejects inode replacement"
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_quarantine", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

with TemporaryDirectory() as temporary:
    record = Path(temporary) / "record"
    metadata = {
        "version": "1",
        "pid": "2",
        "start": "proc:start",
        "identity": "exe:python",
        "socket": "abstract:record",
        "home": "/home",
        "checkout": "/checkout",
        "task": "task",
        "script": "/checkout/bin/fm-session-authority-broker.py",
        "uid": "0",
        "gid": "0",
        "launch-pid": "2",
        "launch-start": "proc:launch",
        "launch-identity": "exe:python",
        "launch-script": "/home/bin/fm-session-authority-exec.sh",
    }
    record.write_text(
        "".join(f"{key}={value}\n" for key, value in metadata.items()),
        encoding="utf-8",
    )
    record.chmod(0o600)
    original_stat = record.lstat()
    if not broker.unlink_owned_record(
        record,
        metadata,
        expected_stat=original_stat,
        quarantine_key=b"review-quarantine-key",
    ):
        raise SystemExit("owned record was not quarantined")
    if record.exists():
        raise SystemExit("owned record pathname remained after quarantine")
    quarantines = [
        candidate
        for candidate in record.parent.glob(f".{record.name}.recovery-*")
        if not candidate.name.endswith(broker.QUARANTINE_RECEIPT_SUFFIX)
        and not candidate.name.endswith(broker.QUARANTINE_PROOF_SUFFIX)
    ]
    if len(quarantines) != 1 or quarantines[0].lstat().st_ino != original_stat.st_ino:
        raise SystemExit("owned record inode was not retained atomically")
    if not broker.cleanup_recovery_quarantines(
        record,
        {
            "home": "/home",
            "checkout": "/checkout",
            "task": "task",
            "script": "/checkout/bin/fm-session-authority-broker.py",
            "launch-script": "/home/bin/fm-session-authority-exec.sh",
            "uid": "0",
            "gid": "0",
        },
        b"review-quarantine-key",
    ):
        raise SystemExit("owned record quarantine cleanup failed")
    if list(record.parent.glob(f".{record.name}.recovery-*")):
        raise SystemExit("owned record quarantine was not reclaimed")
    forged = record.parent / f".{record.name}.recovery-forged"
    forged.write_text("forged\n", encoding="utf-8")
    forged.chmod(0o600)
    if not broker.cleanup_recovery_quarantines(
        record,
        {"home": "/home"},
        b"review-quarantine-key",
    ) or not forged.exists():
        raise SystemExit("unproven quarantine was removed")
    forged.unlink()
PY
  then
    fail "stale record deletion did not use atomic quarantine"
  fi
  pass "stale record deletion uses atomic quarantine"
  if ! python3 - "$BROKER" <<'PY'
import importlib.util
import sys
from pathlib import Path
from tempfile import TemporaryDirectory

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker_lock", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

with TemporaryDirectory() as temporary:
    home = str(Path(temporary))
    address = broker.lock_manager_address(home, "task", b"review-lock-key")
    if not address.startswith("\0firstmate-session-lock-"):
        raise SystemExit("per-home lock manager did not use an abstract socket")
PY
  then
    fail "per-home serialization did not use a non-reopenable endpoint"
  fi
  pass "per-home serialization uses a non-reopenable endpoint"
  echo "# focused broker review-fix tests passed"
  exit 0
fi

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
    exec env FM_AGENT_ROLE=secondmate FM_AGENT_TASK=alpha \
      FM_AGENT_OWNER_HOME="$home" "$launch_script"
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
  python3 "$BROKER" supervise --state "$STATE" --home "$HOME_DIR" \
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

if ! python3 - "$BROKER" <<'PY'
import importlib.util
import os
import socket
import sys
import time
from pathlib import Path

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

left, right = socket.socketpair()
try:
    started = time.monotonic()
    try:
        broker.recv_exact(left, 1, started + 0.05)
    except TimeoutError:
        pass
    else:
        raise SystemExit("a partial broker request was not deadline bounded")
    if time.monotonic() - started > 1:
        raise SystemExit("broker request deadline was not hard bounded")
    start, identity = broker.process_generation(os.getpid())
    metadata = {
        "pid": str(os.getpid()),
        "uid": str(os.geteuid()),
        "gid": str(os.getegid()),
        "start": start,
        "identity": identity,
    }
    if not broker.connected_peer_matches_record(left, metadata):
        raise SystemExit("the connected peer generation did not match its record")
    metadata["start"] = "proc:stale"
    if broker.connected_peer_matches_record(left, metadata):
        raise SystemExit("a stale connected peer generation was accepted")
finally:
    left.close()
    right.close()
PY
then
  fail "the broker did not bound partial reads or authenticate the connected peer"
fi
pass "peer-credential broker bounds partial reads and revalidates connected generation"

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
broker.canonical = lambda value: value
broker.os.readlink = lambda path: home if path.endswith("/cwd") else "/usr/bin/python3"
broker.process_command = lambda pid: ["python3", script, "client"]
broker.process_generation = lambda pid: ("proc:x", "exe:x")
broker.process_environment = lambda pid: {
    42: {
        "FM_AGENT_ROLE": "secondmate",
        "FM_AGENT_TASK": "alpha",
        "FM_AGENT_OWNER_HOME": home,
    },
    43: {
        "FM_AGENT_ROLE": "secondmate",
        "FM_AGENT_TASK": "foreign",
        "FM_AGENT_OWNER_HOME": home,
    },
    44: {},
}[pid]
broker.parent_pid = lambda pid: {42: 43, 43: 44}[pid]

if broker.peer_is_authorized(
    42, uid=1000, gid=1000, home=home, task="alpha", script=script,
    launch_pid=44, launch_start="proc:x", launch_identity="exe:x",
    broker_uid=1000, broker_gid=1000
):
    raise SystemExit("a mismatched secondmate ancestor was accepted")
PY
then
  fail "the broker did not validate every secondmate ancestor scope"
fi
pass "peer-credential broker rejects mismatched secondmate ancestors"

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
for role in ("", "primary", "unknown"):
    broker.canonical = lambda value: value
    broker.os.readlink = lambda path: home if path.endswith("/cwd") else "/usr/bin/python3"
    broker.process_command = lambda pid: ["python3", script, "client"]
    broker.process_generation = lambda pid: ("proc:x", "exe:x")
    broker.process_environment = lambda pid, role=role: {
        42: {
            "FM_AGENT_ROLE": "secondmate",
            "FM_AGENT_TASK": "alpha",
            "FM_AGENT_OWNER_HOME": home,
        },
        43: {"FM_AGENT_ROLE": role},
        44: {
            "FM_AGENT_ROLE": "secondmate",
            "FM_AGENT_TASK": "alpha",
            "FM_AGENT_OWNER_HOME": home,
        },
    }[pid]
    broker.parent_pid = lambda pid: {42: 43, 43: 44}[pid]
    if broker.peer_is_authorized(
        42, uid=1000, gid=1000, home=home, task="alpha", script=script,
        launch_pid=44, launch_start="proc:x", launch_identity="exe:x",
        broker_uid=1000, broker_gid=1000
    ):
        raise SystemExit(f"an undeclared {role or 'empty'} ancestor was accepted")
PY
then
  fail "the broker accepted an undeclared ancestry gap"
fi
pass "peer-credential broker rejects empty, primary, and unknown ancestors"

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
broker.parent_pid = lambda pid: pid

def authorized(owner_home):
    broker.process_environment = lambda pid: {
        "FM_AGENT_ROLE": "secondmate",
        "FM_AGENT_TASK": "alpha",
        **({} if owner_home is None else {"FM_AGENT_OWNER_HOME": owner_home}),
    }
    return broker.peer_is_authorized(
        42, uid=1000, gid=1000, home=home, task="alpha", script=script,
        launch_pid=42, launch_start="proc:x", launch_identity="exe:x",
        broker_uid=1000, broker_gid=1000
    )

if not authorized(home):
    raise SystemExit("explicit absolute owner home was rejected")
if authorized(None):
    raise SystemExit("missing owner home was accepted")
if authorized("relative/home"):
    raise SystemExit("relative owner home was accepted")
PY
then
  fail "the broker did not enforce an explicit absolute owner home"
fi
pass "peer-credential broker rejects missing and relative owner homes"

if ! python3 - "$BROKER" "$BROKER_KEY" <<'PY'
import hashlib
import hmac
import importlib.util
import sys
from pathlib import Path

broker_path = Path(sys.argv[1]).resolve()
spec = importlib.util.spec_from_file_location("session_authority_broker", broker_path)
broker = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(broker)

root_key = bytes.fromhex(sys.argv[2])
body = b"durable-capability-boundary"
root_digest = hmac.new(root_key, body, hashlib.sha256).hexdigest()
scoped_key = broker.derive_broker_durable_key(
    root_key, task="alpha", home="/test/home", launch_pid=42,
    launch_start="proc:x", launch_identity="exe:x",
    launch_script="/test/home/bin/fm-session-authority-exec.sh"
)
scoped_digest = hmac.new(scoped_key, body, hashlib.sha256).hexdigest()
if scoped_digest == root_digest:
    raise SystemExit("broker durable capability reused the primary root")
if scoped_key == broker.derive_broker_durable_key(
    root_key, task="beta", home="/test/home", launch_pid=42,
    launch_start="proc:x", launch_identity="exe:x",
    launch_script="/test/home/bin/fm-session-authority-exec.sh"
):
    raise SystemExit("broker durable capability was not task-bound")
if scoped_key == broker.derive_broker_durable_key(
    root_key, task="alpha", home="/test/other", launch_pid=42,
    launch_start="proc:x", launch_identity="exe:x",
    launch_script="/test/home/bin/fm-session-authority-exec.sh"
):
    raise SystemExit("broker durable capability was not home-bound")
if scoped_key != broker.derive_broker_durable_key(
    root_key, task="alpha", home="/test/home", launch_pid=99,
    launch_start="proc:y", launch_identity="exe:other",
    launch_script="/test/home/bin/fm-session-authority-exec.sh"
):
    raise SystemExit("broker durable capability rotated with launch generation")
PY
then
  fail "the broker durable capability was not scoped to validated launch identity"
fi
pass "peer-credential broker derives a scoped durable capability"

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
