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

cleanup() {
  [ -z "$BROKER_PID" ] || kill "$BROKER_PID" 2>/dev/null || true
  [ -z "$BROKER_PID" ] || wait "$BROKER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$STATE" "$FOREIGN_HOME"
python3 "$BROKER" serve --state "$STATE" --home "$HOME_DIR" \
  --checkout "$ROOT" --task alpha >/dev/null 2>&1 &
BROKER_PID=$!

attempts=0
while [ "$attempts" -lt 100 ] && [ ! -f "$RECORD" ]; do
  kill -0 "$BROKER_PID" 2>/dev/null || fail "authority broker exited before publishing its record"
  sleep 0.02
  attempts=$((attempts + 1))
done
[ -f "$RECORD" ] && [ ! -L "$RECORD" ] \
  || fail "authority broker did not publish a private regular record"
[ "$(stat -c '%a' "$RECORD")" = 600 ] \
  || fail "authority broker record was not private"

broker_hmac() {
  local home=$1 role=$2 kind=$3
  (cd "$home" && printf 'fixed-public-test-body' | env \
    FM_AGENT_ROLE="$role" FM_AGENT_TASK=alpha FM_AGENT_OWNER_HOME="$home" \
    python3 "$BROKER" client --record "$RECORD" --kind "$kind")
}

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

library_live=$(cd "$HOME_DIR" && printf 'library-public-test-body' | env \
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_AGENT_ROLE=secondmate \
  FM_AGENT_TASK=alpha FM_AGENT_OWNER_HOME="$HOME_DIR" bash -c '
    . "$1/bin/fm-session-lock-lib.sh"
    fm_session_authority_capability_present || exit 1
    fm_session_authority_hmac
  ' broker-library "$ROOT") \
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
python3 "$BROKER" serve --state "$STATE" --home "$HOME_DIR" \
  --checkout "$ROOT" --task alpha >/dev/null 2>&1 &
BROKER_PID=$!
attempts=0
while [ "$attempts" -lt 100 ] && [ ! -f "$RECORD" ]; do
  kill -0 "$BROKER_PID" 2>/dev/null \
    || fail "long-home authority broker exited before publishing its record"
  sleep 0.02
  attempts=$((attempts + 1))
done
[ -f "$RECORD" ] && [ ! -L "$RECORD" ] \
  || fail "long-home authority broker did not publish a private regular record"
long_home_live=$(broker_hmac "$HOME_DIR" secondmate live) \
  || fail "same-home secondmate could not use authority from a long home"
[ "${#long_home_live}" -eq 64 ] \
  || fail "long-home authority broker returned a malformed digest"
pass "peer-credential broker supports homes beyond the filesystem socket path limit"

echo "# all fm-session-authority-broker tests passed"
