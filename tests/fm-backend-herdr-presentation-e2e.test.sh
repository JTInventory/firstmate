#!/usr/bin/env bash
# Scoped Herdr launch/teardown proof.
#
# The old real-lab presentation farm was removed with the frozen #91 surface.
# This successor keeps the useful boundary small and deterministic:
#
#   1. the installed Herdr is read-only preflighted through spawn's real
#      container-ensure gate;
#   2. a stateful provider double drives the surviving adapter end to end;
#   3. the exact workspace/pane ids are checked on atomic run and close calls.
#
# No command in this test targets the default Herdr session for mutation.
set -uEo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ORIGINAL_PATH=$PATH
TMP_ROOT=

unexpected_error() {
  local rc=$? line=$1 command=$2
  trap - ERR
  printf 'not ok - unexpected failure at line %s (exit %s): %s\n' \
    "$line" "$rc" "$command" >&2
  exit "$rc"
}

trap 'unexpected_error "$LINENO" "$BASH_COMMAND"' ERR

fail() {
  trap - ERR
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() { printf 'ok - %s\n' "$1"; }

cleanup() {
  trap - ERR
  if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
    rm -rf -- "$TMP_ROOT"
  fi
}
trap cleanup EXIT

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "$3 (missing: $2)" ;;
  esac
}

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: $2)" ;;
    *) ;;
  esac
}

assert_file_contains() {
  local file=$1 needle=$2 message=$3 contents
  contents=$(cat "$file" 2>/dev/null || true)
  assert_contains "$contents" "$needle" "$message"
}

make_project() {
  local project=$1
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# Herdr presentation E2E fixture\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm initial
}

capture_failure() {
  CAPTURED_OUTPUT=
  CAPTURED_STATUS=0
  if CAPTURED_OUTPUT=$("$@" 2>&1); then
    CAPTURED_STATUS=0
  else
    CAPTURED_STATUS=$?
  fi
  [ "$CAPTURED_STATUS" -ne 0 ] || return 1
  return 0
}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-presentation-e2e.XXXXXX")
PRE_HOME="$TMP_ROOT/preflight-home"
PRE_PROJECT="$TMP_ROOT/preflight-project"
PRE_SESSION="firstmate-preflight-$$"
mkdir -p "$PRE_HOME/data/preflight" "$PRE_HOME/config"
printf 'Preflight fixture.\n' > "$PRE_HOME/data/preflight/brief.md"
: > "$PRE_HOME/data/backlog.md"
make_project "$PRE_PROJECT"

command -v herdr >/dev/null 2>&1 || fail "installed Herdr CLI is required for the real preflight"
command -v jq >/dev/null 2>&1 || fail "jq is required for the real Herdr preflight"
PRE_STATUS=$(herdr status --json 2>&1) || fail "installed Herdr status failed: $PRE_STATUS"
PRE_SCHEMA=$(herdr api schema --json 2>&1) || fail "installed Herdr schema failed: $PRE_SCHEMA"
PRE_VERSION=$(printf '%s' "$PRE_STATUS" | jq -er '.client.version') \
  || fail "installed Herdr status omitted client.version: $PRE_STATUS"
PRE_PROTOCOL=$(printf '%s' "$PRE_STATUS" | jq -er '.client.protocol | numbers') \
  || fail "installed Herdr status omitted numeric client.protocol: $PRE_STATUS"
[ -n "$PRE_VERSION" ] \
  || fail "installed Herdr status omitted client.version: $PRE_STATUS"
[ "$PRE_PROTOCOL" -ge 16 ] \
  || fail "focused proof requires installed Herdr protocol >=16, found $PRE_PROTOCOL"
printf '%s' "$PRE_SCHEMA" | jq -e \
  '[.schemas.request.oneOf[]?.properties.method.const] | index("pane.close") != null' \
  >/dev/null || fail "installed Herdr schema omitted pane.close"
if printf '%s' "$PRE_SCHEMA" | jq -e \
  '[.schemas.request.oneOf[]?.properties.method.const] | index("pane.close_bound") != null' \
  >/dev/null; then
  fail "installed Herdr schema unexpectedly advertises pane.close_bound"
fi

if capture_failure env \
  FM_HOME="$PRE_HOME" \
  FM_ROOT_OVERRIDE="$ROOT" \
  HERDR_SESSION="$PRE_SESSION" \
  PATH="$ORIGINAL_PATH" \
  bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure "$2"' \
  _ "$ROOT" "$PRE_PROJECT"; then
  [ "$CAPTURED_STATUS" -eq 1 ] || fail "Herdr preflight returned an unexpected exit $CAPTURED_STATUS"
  assert_contains "$CAPTURED_OUTPUT" \
    "error: herdr provider lacks atomic pane.close_bound(expected_pid); refusing a backend that cannot safely finish live task teardown" \
    "Herdr preflight did not explain the missing bound close capability: $CAPTURED_OUTPUT"
  pass "installed Herdr $PRE_VERSION protocol-$PRE_PROTOCOL preflight refuses before session mutation"
else
  fail "Herdr preflight did not refuse with the exact diagnostic (status $CAPTURED_STATUS): $CAPTURED_OUTPUT"
fi

FAKE_ROOT="$TMP_ROOT/provider"
FAKE_BIN="$FAKE_ROOT/bin"
FAKE_STATE="$FAKE_ROOT/state.json"
FAKE_LOG="$FAKE_ROOT/herdr.log"
FAKE_CLOSE_LOG="$FAKE_ROOT/close-bound.log"
FAKE_CLOSE="$FAKE_BIN/fake-close-bound"
FAKE_HOME="$FAKE_ROOT/home"
PROJECT="$FAKE_ROOT/project"
SESSION=firstmate-e2e
mkdir -p "$FAKE_BIN" "$FAKE_HOME/state" "$FAKE_HOME/data" "$FAKE_HOME/config"
: > "$FAKE_LOG"
: > "$FAKE_CLOSE_LOG"
printf '{"next":1,"workspaces":[{"workspace_id":"ws-focused","label":"focused","focused":true,"active_tab_id":"tab-focused"}],"tabs":[{"workspace_id":"ws-focused","tab_id":"tab-focused","pane_id":"pane-focused","label":"focused","focused":true}],"agent_status":{}}\n' > "$FAKE_STATE"
make_project "$PROJECT"

# This fake is a small provider model, not a second implementation of the
# adapter. It records every transport call and only exposes the response data
# the adapter reads. The focused workspace is deliberately unrelated to the
# task workspace, making guessed/focused cleanup observable.
cat > "$FAKE_BIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_HERDR_FAKE_STATE:?}
log=${FM_HERDR_FAKE_LOG:?}
cmd=${1:-}
sub=${2:-}
args=("$@")
printf '%s' "$cmd $sub" >> "$log"
for arg in "${args[@]:2}"; do
  printf '\t%s' "$arg" >> "$log"
done
printf '\n' >> "$log"

save() {
  local tmp="$state.tmp.$$"
  cat > "$tmp"
  mv -f -- "$tmp" "$state"
}

value_after() {
  local want=$1 previous= arg
  for arg in "${args[@]}"; do
    if [ "$previous" = "$want" ]; then
      printf '%s' "$arg"
      return 0
    fi
    previous=$arg
  done
  return 1
}

workspace=$(value_after --workspace || true)
pane=${args[2]:-}
case "$cmd $sub" in
  'status --json')
    printf '{"client":{"version":"0.8.0-test","protocol":16},"server":{"running":true}}\n'
    ;;
  'api schema')
    if [ "${FM_HERDR_OMIT_TAB_CLOSE:-0}" = 1 ]; then
      printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"pane.close_bound"},"params":{"$ref":"#/schemas/request/$defs/PaneCloseBoundParams"}}}],"$defs":{"PaneCloseBoundParams":{"required":["pane_id","expected_pid","expected_start_time"],"properties":{"pane_id":{"type":"string"},"expected_pid":{"type":"integer"},"expected_start_time":{"type":"string"}}}}}}}'
    else
      printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"pane.close_bound"},"params":{"$ref":"#/schemas/request/$defs/PaneCloseBoundParams"}}},{"properties":{"method":{"const":"tab.close_bound"},"params":{"$ref":"#/schemas/request/$defs/TabCloseBoundParams"}}}],"$defs":{"PaneCloseBoundParams":{"required":["pane_id","expected_pid","expected_start_time"],"properties":{"pane_id":{"type":"string"},"expected_pid":{"type":"integer"},"expected_start_time":{"type":"string"}}},"TabCloseBoundParams":{"required":["workspace_id","tab_id","pane_id"],"properties":{"workspace_id":{"type":"string"},"tab_id":{"type":"string"},"pane_id":{"type":"string"}}}}}}}'
    fi
    ;;
  'session list')
    printf '{"sessions":[{"name":"%s","default":false,"running":true,"socket_path":"/tmp/fm-herdr-presentation-e2e.sock"}]}\n' "${HERDR_SESSION:-firstmate-e2e}"
    ;;
  'workspace list')
    if [ "${FM_HERDR_MALFORMED_WORKSPACE_LIST:-0}" = 1 ] \
      && [ -e "$state.malformed-workspace-list" ]; then
      printf '%s\n' '{"result":{}}'
      exit 0
    fi
    jq '{result:{workspaces:.workspaces}}' "$state"
    ;;
  'workspace create')
    workspace_id=${FM_HERDR_CREATE_WORKSPACE_ID:-ws-task}
    jq --arg workspace "$workspace_id" \
      '.workspaces += [{"workspace_id":$workspace,"label":"firstmate","focused":false,"active_tab_id":"tab-seed"}] | .tabs += [{"workspace_id":$workspace,"tab_id":"tab-seed","pane_id":"pane-seed","label":"1","focused":false}]' \
      "$state" | save
    if [ "${FM_HERDR_FAIL_WORKSPACE_CREATE:-0}" = 2 ]; then
      exit 1
    fi
    if [ "${FM_HERDR_FAIL_WORKSPACE_CREATE:-0}" = 3 ]; then
      : > "$state.malformed-workspace-list"
      exit 1
    fi
    if [ "${FM_HERDR_FAIL_WORKSPACE_CREATE:-0}" = 1 ]; then
      jq -n --arg workspace "$workspace_id" \
        '{result:{workspace:{workspace_id:$workspace},tab:{tab_id:"tab-seed"},root_pane:{pane_id:"pane-seed"}}}'
      exit 1
    fi
    jq -n --arg workspace "$workspace_id" \
      '{result:{workspace:{workspace_id:$workspace},tab:{tab_id:"tab-seed"},root_pane:{pane_id:"pane-seed"}}}'
    ;;
  'tab list')
    if [ "${FM_HERDR_MALFORMED_TAB_LIST:-0}" = 1 ]; then
      printf '%s\n' '{"result":{}}'
      exit 0
    fi
    if [ "${FM_HERDR_MALFORMED_AFTER_CLOSE:-0}" = 1 ] \
      && [ -e "$state.malformed-after-close" ]; then
      printf '%s\n' '{"result":{}}'
      exit 0
    fi
    jq --arg workspace "$workspace" '{result:{tabs:[.tabs[] | select(.workspace_id == $workspace)]}}' "$state"
    ;;
  'pane list')
    jq --arg workspace "$workspace" '{result:{panes:[.tabs[] | select(.workspace_id == $workspace) | {workspace_id,tab_id,pane_id}]}}' "$state"
    ;;
  'tab create')
    label=$(value_after --label || true)
    jq --arg workspace "$workspace" --arg label "$label" '.tabs += [{"workspace_id":$workspace,"tab_id":"tab-task","pane_id":"pane-task","label":$label,"focused":false}] | .agent_status["pane-task"] = "working"' "$state" | save
    if [ "${FM_HERDR_FAIL_TAB_CREATE:-0}" = 1 ]; then
      exit 1
    fi
    if [ "${FM_HERDR_FAIL_TAB_CREATE:-0}" = 2 ]; then
      printf '%s\n' '{"result":{"tab":{"tab_id":"tab-seed"},"root_pane":{"pane_id":"pane-seed"}}}'
      exit 1
    fi
    printf '%s\n' '{"result":{"tab":{"tab_id":"tab-task"},"root_pane":{"pane_id":"pane-task"}}}'
    ;;
  'pane get')
    if jq -e --arg pane "$pane" '.tabs[]? | select(.pane_id == $pane)' "$state" >/dev/null; then
      jq --arg pane "$pane" '{result:{pane:(.tabs[] | select(.pane_id == $pane) | {workspace_id,tab_id,pane_id,foreground_cwd:"/tmp/fm-herdr-presentation-e2e-worktree"})}}' "$state"
    else
      printf '{"error":{"code":"pane_not_found","message":"pane not found"}}\n'
    fi
    ;;
  'agent get')
    if [ "${FM_HERDR_UNSAFE_AGENT_STATE:-0}" = 1 ]; then
      printf '%s\n' '{"result":{"agent":{"agent_status":"unrecognized"}}}'
      exit 0
    fi
    agent_status=$(jq -r --arg pane "$pane" '.agent_status[$pane] // empty' "$state")
    if [ -n "$agent_status" ]; then
      printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "$agent_status"
    else
      printf '{"error":{"code":"agent_not_found","message":"agent not found"}}\n'
    fi
    ;;
  'pane run')
    if [ "${FM_HERDR_FAIL_RUN:-0}" = 1 ]; then
      exit 1
    fi
    :
    ;;
  'pane send-text')
    if [ "${FM_HERDR_FAIL_LITERAL:-0}" = 1 ]; then
      exit 1
    fi
    ;;
  'pane send-keys')
    if [ "${FM_HERDR_FAIL_KEY:-0}" = 1 ]; then
      exit 1
    fi
    ;;
  *)
    printf 'unexpected Herdr fake call: %s\n' "$cmd $sub" >&2
    exit 1
    ;;
esac
SH
chmod +x "$FAKE_BIN/herdr"

cat > "$FAKE_CLOSE" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_HERDR_FAKE_STATE:?}
log=${FM_HERDR_FAKE_CLOSE_LOG:?}
if [ "$#" -eq 5 ] && [ "$2" = --tab ]; then
  socket=$1
  workspace=$3
  tab=$4
  pane=$5
  printf '%s\t--tab\t%s\t%s\t%s\n' "$socket" "$workspace" "$tab" "$pane" >> "$log"
  [ "${FM_HERDR_FAIL_CLOSE_BOUND:-0}" = 1 ] && exit 1
  tmp="$state.tmp.$$"
  jq --arg workspace "$workspace" --arg tab "$tab" --arg pane "$pane" '
    .tabs |= map(select(.workspace_id != $workspace or .tab_id != $tab or .pane_id != $pane))
    | del(.agent_status[$pane])
    | if ([.tabs[] | select(.workspace_id == $workspace)] | length) == 0
      then .workspaces |= map(select(.workspace_id != $workspace))
      else .
      end
  ' "$state" > "$tmp"
  mv -f -- "$tmp" "$state"
  if [ "${FM_HERDR_MALFORMED_AFTER_CLOSE:-0}" = 1 ]; then
    : > "$state.malformed-after-close"
  fi
  exit 0
fi
[ "$#" -eq 5 ] && [ "$2" = --pane ] || exit 2
socket=$1
pane=$3
pid=$4
start=$5
printf '%s\t--pane\t%s\t%s\t%s\n' "$socket" "$pane" "$pid" "$start" >> "$log"
[ "${FM_HERDR_FAIL_CLOSE_BOUND:-0}" = 1 ] && exit 1
tmp="$state.tmp.$$"
jq --arg pane "$pane" '.tabs |= map(select(.pane_id != $pane)) | del(.agent_status[$pane])' "$state" > "$tmp"
mv -f -- "$tmp" "$state"
SH
chmod +x "$FAKE_CLOSE"

export FM_HERDR_FAKE_STATE="$FAKE_STATE"
export FM_HERDR_FAKE_LOG="$FAKE_LOG"
export FM_HERDR_FAKE_CLOSE_LOG="$FAKE_CLOSE_LOG"
export FM_BACKEND_HERDR_BOUND_CLOSE_HELPER="$FAKE_CLOSE"
export FM_HOME="$FAKE_HOME"
export FM_ROOT_OVERRIDE="$ROOT"
export HERDR_SESSION="$SESSION"
export PATH="$FAKE_BIN:$ORIGINAL_PATH"

# Source the production adapter once. Every call below uses its normal
# capability, workspace, target, atomic-run, and bound-close functions.
# shellcheck source=bin/backends/herdr.sh
# shellcheck disable=SC1091
. "$ROOT/bin/backends/herdr.sh"

export FM_HERDR_OMIT_TAB_CLOSE=1
if capture_failure fm_backend_herdr_version_check; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: herdr provider lacks atomic tab.close_bound(workspace_id,tab_id,pane_id); refusing a backend that cannot safely reconcile task-tab creation" \
    "missing tab.close_bound did not refuse before workspace use"
  pass "Herdr preflight refuses when bound task-tab reconciliation is unavailable"
else
  fail "missing tab.close_bound preflight returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi
unset FM_HERDR_OMIT_TAB_CLOSE

export FM_HERDR_MALFORMED_TAB_LIST=1
if capture_failure fm_backend_herdr_create_task "$SESSION:ws-focused" "fm-herdr-uninspectable" "$PROJECT"; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: could not inspect Herdr task tabs in workspace ws-focused (session $SESSION)" \
    "malformed task-tab inventory did not refuse with a precise diagnostic"
  assert_not_contains "$(cat "$FAKE_LOG")" \
    $'tab create\t--workspace\tws-focused' \
    "malformed task-tab inventory was followed by a create attempt"
  pass "Herdr refuses an unverifiable task-tab inventory"
else
  fail "malformed task-tab inventory returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi
unset FM_HERDR_MALFORMED_TAB_LIST

WS_FAIL_HOME="$FAKE_ROOT/workspace-failure-home"
WS_FAIL_STATE="$FAKE_ROOT/workspace-failure-state.json"
WS_FAIL_PROJECT="$FAKE_ROOT/workspace-failure-project"
mkdir -p "$WS_FAIL_HOME/state" "$WS_FAIL_HOME/data" "$WS_FAIL_HOME/config"
printf '%s\n' \
  '{"next":1,"workspaces":[{"workspace_id":"ws-focused","label":"focused","focused":true,"active_tab_id":"tab-focused"}],"tabs":[{"workspace_id":"ws-focused","tab_id":"tab-focused","pane_id":"pane-focused","label":"focused","focused":true}],"agent_status":{}}' \
  > "$WS_FAIL_STATE"
make_project "$WS_FAIL_PROJECT"
export FM_HOME="$WS_FAIL_HOME"
export FM_HERDR_FAKE_STATE="$WS_FAIL_STATE"
export FM_HERDR_CREATE_WORKSPACE_ID=ws-failed
export FM_HERDR_FAIL_WORKSPACE_CREATE=1
if capture_failure fm_backend_herdr_container_ensure "$WS_FAIL_PROJECT"; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: Herdr workspace create failed for 'firstmate' in session '$SESSION'; exact workspace ws-failed was reconciled" \
    "mutated workspace creation did not report exact reconciliation"
  if jq -e '.workspaces[] | select(.workspace_id == "ws-failed")' "$WS_FAIL_STATE" >/dev/null; then
    fail "failed Herdr workspace creation left a half-created workspace"
  fi
  if find "$WS_FAIL_HOME/state" -maxdepth 1 -name '.herdr-workspace-create-uncertain.*' -print -quit | grep -q .; then
    fail "successfully reconciled Herdr workspace creation left uncertainty state"
  fi
  pass "Herdr workspace-create mutation is reconciled before refusal"
else
  fail "mutated workspace creation returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi
export FM_HERDR_FAIL_WORKSPACE_CREATE=2
if capture_failure fm_backend_herdr_container_ensure "$WS_FAIL_PROJECT"; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: Herdr workspace create failed for 'firstmate' in session '$SESSION'; exact workspace ws-failed was reconciled" \
    "unidentified workspace mutation was not reconciled from fresh inventory"
  if jq -e '.workspaces[] | select(.workspace_id == "ws-failed")' "$WS_FAIL_STATE" >/dev/null; then
    fail "unidentified workspace mutation left a half-created workspace"
  fi
  pass "Herdr reconciles a mutated workspace when provider output is empty"
else
  fail "unidentified workspace mutation returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi
export FM_HERDR_CREATE_WORKSPACE_ID=ws-uncertain
export FM_HERDR_FAIL_WORKSPACE_CREATE=3
export FM_HERDR_MALFORMED_WORKSPACE_LIST=1
if capture_failure fm_backend_herdr_container_ensure "$WS_FAIL_PROJECT"; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: Herdr workspace create failed for 'firstmate' in session '$SESSION'; cleanup uncertainty recorded" \
    "unverifiable workspace mutation did not persist cleanup uncertainty"
  WS_UNCERTAINTY=$(find "$WS_FAIL_HOME/state" -maxdepth 1 -name '.herdr-workspace-create-uncertain.*' -print -quit)
  [ -n "$WS_UNCERTAINTY" ] && [ -f "$WS_UNCERTAINTY" ] \
    || fail "unverifiable workspace mutation did not leave durable uncertainty state"
else
  fail "unverifiable workspace mutation returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi
workspace_create_attempts=$(grep -c '^workspace create' "$FAKE_LOG" 2>/dev/null || true)
unset FM_HERDR_FAIL_WORKSPACE_CREATE
if capture_failure fm_backend_herdr_container_ensure "$WS_FAIL_PROJECT"; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: unresolved Herdr workspace creation uncertainty at $WS_UNCERTAINTY; refusing another workspace attempt" \
    "durable workspace uncertainty did not block a retry"
  workspace_create_attempts_after=$(grep -c '^workspace create' "$FAKE_LOG" 2>/dev/null || true)
  [ "$workspace_create_attempts_after" -eq "$workspace_create_attempts" ] \
    || fail "durable workspace uncertainty still attempted another workspace create"
  pass "Herdr refuses retry after an unidentified workspace mutation"
else
  fail "durable workspace uncertainty returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi
export FM_HOME="$FAKE_HOME"
export FM_HERDR_FAKE_STATE="$FAKE_STATE"
export FM_HERDR_CREATE_WORKSPACE_ID=ws-task
unset FM_HERDR_MALFORMED_WORKSPACE_LIST

CONTAINER=$(fm_backend_herdr_container_ensure "$PROJECT") \
  || fail "capability-complete Herdr fixture could not ensure its workspace"
EXPECTED_CONTAINER="$SESSION:ws-task"
CONTAINER_ID=${CONTAINER%%$'\t'*}
[ "$CONTAINER_ID" = "$EXPECTED_CONTAINER" ] \
  || fail "workspace ensure returned an unexpected endpoint container: $CONTAINER"

TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER_ID" "fm-herdr-e2e" "$PROJECT") \
  || fail "capability-complete Herdr fixture could not create the task tab"
read -r TASK_TAB TASK_PANE <<EOF
$TASK_IDS
EOF
if [ "$TASK_TAB" != tab-task ] || [ "$TASK_PANE" != pane-task ]; then
  fail "task creation did not return the provider's exact tab/pane ids: $TASK_IDS"
fi
META="$FAKE_HOME/state/herdr-e2e.meta"
printf '%s\n' \
  'backend=herdr' \
  "herdr_session=$SESSION" \
  'herdr_workspace_id=ws-task' \
  "herdr_tab_id=$TASK_TAB" \
  "herdr_pane_id=$TASK_PANE" > "$META"
# Resolve the target through the same metadata mapper used by fm-teardown and
# fm-send, rather than carrying a test-only guessed selector.
TARGET=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_target_of_meta "$2"' \
  _ "$ROOT" "$META") \
  || fail "could not resolve the task target from Herdr metadata"
[ "$TARGET" = "$SESSION:$TASK_PANE" ] \
  || fail "metadata resolved an unexpected Herdr target: $TARGET"

jq -e --arg pane "$TASK_PANE" --arg tab "$TASK_TAB" \
  '.tabs[] | select(.pane_id == $pane and .tab_id == $tab and .workspace_id == "ws-task")' \
  "$FAKE_STATE" >/dev/null \
  || fail "task endpoint was not bound to the recorded workspace/tab/pane"
pass "launch records the exact Herdr workspace, tab, and pane returned by the provider"

# Herdr pane.run is the atomic text+submit primitive. The task target is
# explicit; the unrelated focused pane is never consulted.
before_runs=$(grep -c '^pane run' "$FAKE_LOG" 2>/dev/null || true)
fm_backend_herdr_send_text_line "$TARGET" "treehouse get --lease --lease-holder herdr-e2e" \
  || fail "atomic pane.run submit failed for the exact task target"
after_runs=$(grep -c '^pane run' "$FAKE_LOG" 2>/dev/null || true)
[ "$after_runs" -eq $((before_runs + 1)) ] \
  || fail "atomic pane.run submit did not issue exactly one provider run"
assert_file_contains "$FAKE_LOG" \
  $'pane run\tpane-task\ttreehouse get --lease --lease-holder herdr-e2e' \
  "atomic submit did not target the exact task pane"
assert_not_contains "$(cat "$FAKE_LOG")" 'pane send-text' \
  "atomic submit fell back to an unsubmitted text call"
assert_not_contains "$(cat "$FAKE_LOG")" 'pane send-keys' \
  "atomic submit fell back to a separate Enter call"
pass "Herdr launch submit uses one atomic pane.run against the recorded pane"

# A provider transport failure is also named, so a failed atomic submit never
# degrades into an empty status-1 result.
export FM_HERDR_FAIL_RUN=1
if capture_failure fm_backend_herdr_send_text_line "$TARGET" "atomic-failure-probe"; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: Herdr atomic pane.run submit failed for target '$TARGET'" \
    "atomic pane.run failure did not print its exact target"
  pass "Herdr atomic submit failure reports a precise fail-closed reason"
else
  case "$CAPTURED_STATUS" in
    1) fail "atomic pane.run failure was silent: $CAPTURED_OUTPUT" ;;
    2) fail "atomic pane.run failure capture itself failed without a diagnostic" ;;
    *) fail "atomic pane.run failure returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT" ;;
  esac
fi
unset FM_HERDR_FAIL_RUN

export FM_HERDR_FAIL_LITERAL=1
if capture_failure fm_backend_herdr_send_literal "$TARGET" "launch-literal-probe"; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: Herdr pane.send-text failed for target '$TARGET'" \
    "literal launch failure did not print its exact target"
  pass "Herdr literal launch failure reports a precise fail-closed reason"
else
  fail "literal launch failure was silent or returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi
unset FM_HERDR_FAIL_LITERAL

export FM_HERDR_FAIL_KEY=1
if capture_failure fm_backend_herdr_send_key "$TARGET" Enter; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: Herdr pane.send-keys failed for target '$TARGET' (key 'enter')" \
    "key launch failure did not print its exact target"
  pass "Herdr launch submit-key failure reports a precise fail-closed reason"
else
  fail "launch submit-key failure was silent or returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi
unset FM_HERDR_FAIL_KEY

# Bound teardown receives the exact pane plus the process identity. The fake
# close helper removes only that pane; the unrelated focused pane must remain.
if capture_failure fm_backend_herdr_kill "$TARGET"; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: Herdr teardown target '$TARGET' lacks bound process identity" \
    "missing process identity did not refuse with a precise diagnostic"
  pass "Herdr teardown refuses a live target without process identity"
else
  fail "missing process identity returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi

export FM_HERDR_UNSAFE_AGENT_STATE=1
if capture_failure fm_backend_herdr_kill "$TARGET" 4242 start-4242; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: Herdr teardown target '$TARGET' has unsafe agent state 'unknown'" \
    "unsafe agent state did not refuse with a precise diagnostic"
  pass "Herdr teardown refuses an unrecognized agent state"
else
  fail "unsafe agent state returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi
unset FM_HERDR_UNSAFE_AGENT_STATE

export FM_HERDR_FAIL_CLOSE_BOUND=1
if capture_failure fm_backend_herdr_kill "$TARGET" 4242 start-4242; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: Herdr bound pane.close_bound failed for target '$TARGET'" \
    "bound teardown failure did not print its exact target"
  pass "Herdr bound teardown failure reports a precise fail-closed reason"
else
  case "$CAPTURED_STATUS" in
    1) fail "bound teardown failure was silent: $CAPTURED_OUTPUT" ;;
    2) fail "bound teardown failure capture itself failed without a diagnostic" ;;
    *) fail "bound teardown failure returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT" ;;
  esac
fi
unset FM_HERDR_FAIL_CLOSE_BOUND

fm_backend_herdr_kill "$TARGET" 4242 start-4242 \
  || fail "bound Herdr teardown failed for the recorded live task endpoint"
assert_file_contains "$FAKE_CLOSE_LOG" \
  $'/tmp/fm-herdr-presentation-e2e.sock\t--pane\tpane-task\t4242\tstart-4242' \
  "bound teardown did not receive the exact pane/process identity"
jq -e '.tabs[] | select(.pane_id == "pane-focused" and .workspace_id == "ws-focused")' \
  "$FAKE_STATE" >/dev/null \
  || fail "bound teardown touched the unrelated focused workspace/pane"
if jq -e '.tabs[] | select(.pane_id == "pane-task")' "$FAKE_STATE" >/dev/null; then
  fail "bound teardown left the recorded task pane alive"
fi
assert_not_contains "$(cat "$FAKE_LOG")" 'pane close' \
  "teardown used unbound pane.close instead of pane.close_bound"
pass "Herdr teardown closes only the exact recorded pane with bound process identity"

# A post-capability tab-create failure must not become an empty exit 1. The
# adapter emits a reason that names the exact workspace/session and the failed
# operation. It leaves the durable home workspace usable for later recovery.
export FM_HERDR_FAIL_TAB_CREATE=1
if capture_failure fm_backend_herdr_create_task "$CONTAINER_ID" "fm-herdr-failed" "$PROJECT"; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: could not create Herdr task tab 'fm-herdr-failed' in workspace ws-task (session $SESSION)" \
    "failed tab creation did not print a precise fail-closed reason"
  pass "Herdr task-tab failure reports a precise fail-closed reason"
else
  case "$CAPTURED_STATUS" in
    1) fail "Herdr task-tab failure was silent: $CAPTURED_OUTPUT" ;;
    2) fail "Herdr task-tab failure capture itself failed without a diagnostic" ;;
    *) fail "Herdr task-tab failure returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT" ;;
  esac
fi
assert_file_contains "$FAKE_CLOSE_LOG" \
  $'/tmp/fm-herdr-presentation-e2e.sock\t--tab\tws-task\ttab-task\tpane-task' \
  "failed task-tab mutation was not reconciled through the exact bound tab endpoint"
if jq -e '.tabs[] | select(.workspace_id == "ws-task" and .label == "fm-herdr-failed")' "$FAKE_STATE" >/dev/null; then
  fail "failed Herdr task-tab mutation left a half-created task endpoint"
fi
jq -e '([.tabs[] | select(.workspace_id == "ws-task")] | . as $tabs | ($tabs | length) == 1 and $tabs[0].tab_id == "tab-seed")' "$FAKE_STATE" >/dev/null \
  || fail "failed Herdr task-tab mutation did not leave only the durable seeded workspace tab"
pass "Herdr task-tab failure reconciles a provider mutation without a half-created task endpoint"

export FM_HERDR_FAIL_TAB_CREATE=2
if capture_failure fm_backend_herdr_create_task "$CONTAINER_ID" "fm-herdr-stale-ids" "$PROJECT"; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: could not create Herdr task tab 'fm-herdr-stale-ids' in workspace ws-task (session $SESSION)" \
    "stale provider ids did not produce the normal precise failure diagnostic"
  if jq -e '.tabs[] | select(.workspace_id == "ws-task" and .label == "fm-herdr-stale-ids")' "$FAKE_STATE" >/dev/null; then
    fail "stale provider ids left the failed task tab alive"
  fi
  if jq -e '.tabs[] | select(.workspace_id == "ws-task" and .tab_id == "tab-seed")' "$FAKE_STATE" >/dev/null; then
    :
  else
    fail "stale provider ids caused the durable seed tab to be closed"
  fi
  assert_not_contains "$(cat "$FAKE_CLOSE_LOG")" \
    $'--tab\tws-task\ttab-seed\tpane-seed' \
    "stale provider ids caused a destructive close of the seed tab"
  pass "Herdr reconciles stale task-create ids through fresh identity"
else
  fail "stale provider ids returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi
unset FM_HERDR_FAIL_TAB_CREATE

export FM_HERDR_FAIL_TAB_CREATE=1
export FM_HERDR_MALFORMED_AFTER_CLOSE=1
if capture_failure fm_backend_herdr_create_task "$CONTAINER_ID" "fm-herdr-unverified-cleanup" "$PROJECT"; then
  assert_contains "$CAPTURED_OUTPUT" \
    $'cleanup-uncertain\tfirstmate-e2e:ws-task\tfm-herdr-unverified-cleanup' \
    "unverifiable post-close inventory did not report cleanup uncertainty"
  assert_contains "$CAPTURED_OUTPUT" \
    "error: could not reconcile Herdr task tab 'fm-herdr-unverified-cleanup' in workspace ws-task (session $SESSION); refusing with cleanup uncertainty" \
    "unverifiable post-close inventory did not refuse loudly"
  if jq -e '.tabs[] | select(.workspace_id == "ws-task" and .label == "fm-herdr-unverified-cleanup")' "$FAKE_STATE" >/dev/null; then
    fail "unverifiable post-close inventory left the failed task tab alive"
  fi
  pass "Herdr refuses when post-close task-tab absence cannot be verified"
else
  fail "unverifiable post-close inventory returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi
unset FM_HERDR_FAIL_TAB_CREATE FM_HERDR_MALFORMED_AFTER_CLOSE
rm -f -- "$FAKE_STATE.malformed-after-close"

printf 'ok - scoped Herdr presentation launch/teardown proof completed\n'
