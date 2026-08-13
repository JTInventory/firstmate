#!/usr/bin/env bash
# Scoped Herdr launch/teardown proof.
#
# The old real-lab presentation farm was removed with the frozen #91 surface.
# This successor keeps the useful boundary small and deterministic:
#
#   1. the installed Herdr is read-only preflighted through spawn's real
#      container-ensure gate;
#   2. a stateful provider double drives the surviving adapter end to end;
#   3. the exact workspace/tab/pane ids are checked on atomic run and close calls.
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

assert_meta_line() {
  local file=$1 line=$2 message=$3
  grep -Fx -- "$line" "$file" >/dev/null || fail "$message"
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
PRE_SESSION=firstmate
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

if env \
  FM_HOME="$PRE_HOME" \
  FM_ROOT_OVERRIDE="$ROOT" \
  HERDR_SESSION="$PRE_SESSION" \
  PATH="$ORIGINAL_PATH" \
  bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_version_check' \
  _ "$ROOT"; then
  pass "installed Herdr $PRE_VERSION protocol-$PRE_PROTOCOL accepts the isolated firstmate session without mutation"
else
  fail "isolated Herdr preflight unexpectedly refused: $PRE_STATUS"
fi

FAKE_ROOT="$TMP_ROOT/provider"
FAKE_BIN="$FAKE_ROOT/bin"
FAKE_STATE="$FAKE_ROOT/state.json"
FAKE_LOG="$FAKE_ROOT/herdr.log"
FAKE_HOME="$FAKE_ROOT/home"
PROJECT="$FAKE_ROOT/project"
SESSION=firstmate
mkdir -p "$FAKE_BIN" "$FAKE_HOME/state" "$FAKE_HOME/data" "$FAKE_HOME/config"
: > "$FAKE_LOG"
printf '%s\n' \
  '{"next":1,"workspaces":[{"workspace_id":"CAPTAIN","label":"CAPTAIN","focused":true,"active_tab_id":"w1"},{"workspace_id":"ws-focused","label":"focused","focused":false,"active_tab_id":"tab-focused"}],"tabs":[{"workspace_id":"CAPTAIN","tab_id":"w1","pane_id":"captain-pane","label":"CAPTAIN","focused":true},{"workspace_id":"ws-focused","tab_id":"tab-focused","pane_id":"pane-focused","label":"focused","focused":false}],"agent_status":{"captain-pane":"working"}}' \
  > "$FAKE_STATE"
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
    printf '%s\n' '{"schemas":{"request":{"oneOf":[{"properties":{"method":{"const":"pane.close"}}},{"properties":{"method":{"const":"tab.close"}}}]}}}'
    ;;
  'session list')
    printf '{"sessions":[{"name":"%s","default":false,"running":true,"socket_path":"/tmp/fm-herdr-presentation-e2e.sock"}]}\n' "${HERDR_SESSION:-firstmate-e2e}"
    ;;
  'api snapshot')
    jq '{result:{snapshot:{workspaces:.workspaces,tabs:.tabs,panes:[.tabs[] | {workspace_id,tab_id,pane_id,cwd:(.cwd // ""),foreground_cwd:(.cwd // "")}]}}}' "$state"
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
    response_workspace_id=$workspace_id
    response_tab_id=tab-seed
    response_pane_id=pane-seed
    create_cwd=$(value_after --cwd || true)
    jq --arg workspace "$workspace_id" --arg cwd "$create_cwd" \
      '.workspaces += [{"workspace_id":$workspace,"label":"firstmate","focused":false,"active_tab_id":"tab-seed"}] | .tabs += [{"workspace_id":$workspace,"tab_id":"tab-seed","pane_id":"pane-seed","cwd":$cwd,"label":"1","focused":false}]' \
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
    if [ "${FM_HERDR_STALE_WORKSPACE_RESPONSE:-0}" = 1 ]; then
      response_workspace_id=ws-focused
      response_tab_id=tab-focused
      response_pane_id=pane-focused
    fi
    jq -n --arg workspace "$response_workspace_id" --arg tab "$response_tab_id" \
      --arg pane "$response_pane_id" \
      '{result:{workspace:{workspace_id:$workspace},tab:{tab_id:$tab},root_pane:{pane_id:$pane}}}'
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
    create_cwd=$(value_after --cwd || true)
    jq --arg workspace "$workspace" --arg label "$label" --arg cwd "$create_cwd" '.tabs += [{"workspace_id":$workspace,"tab_id":"tab-task","pane_id":"pane-task","cwd":$cwd,"label":$label,"focused":false}] | .agent_status["pane-task"] = "working"' "$state" | save
    if [ "${FM_HERDR_FAIL_TAB_CREATE:-0}" = 1 ]; then
      exit 1
    fi
    if [ "${FM_HERDR_FAIL_TAB_CREATE:-0}" = 2 ]; then
      printf '%s\n' '{"result":{"tab":{"tab_id":"tab-seed"},"root_pane":{"pane_id":"pane-seed"}}}'
      exit 1
    fi
    if [ "${FM_HERDR_STALE_TAB_RESPONSE:-0}" = 1 ]; then
      printf '%s\n' '{"result":{"tab":{"tab_id":"tab-seed"},"root_pane":{"pane_id":"pane-seed"}}}'
    else
      printf '%s\n' '{"result":{"tab":{"tab_id":"tab-task"},"root_pane":{"pane_id":"pane-task"}}}'
    fi
    ;;
  'pane get')
    if jq -e --arg pane "$pane" '.tabs[]? | select(.pane_id == $pane)' "$state" >/dev/null; then
      jq --arg pane "$pane" '{result:{pane:(.tabs[] | select(.pane_id == $pane) | {workspace_id,tab_id,pane_id,foreground_cwd:"/tmp/fm-herdr-presentation-e2e-worktree"})}}' "$state"
    else
      printf '{"error":{"code":"pane_not_found","message":"pane not found"}}\n'
    fi
    ;;
  'pane process-info')
    process_pane=$(value_after --pane || true)
    printf '{"result":{"process_info":{"pane_id":"%s","foreground_processes":[{"pid":%s,"name":"agent"}]}}}\n' \
      "$process_pane" "${FM_HERDR_FAKE_PANE_PID:-$$}"
    ;;
  'pane close')
    pane=${args[2]:-}
    [ "${FM_HERDR_FAIL_CLOSE:-0}" = 1 ] && exit 1
    jq --arg pane "$pane" '.tabs |= map(select(.pane_id != $pane)) | del(.agent_status[$pane])' "$state" | save
    ;;
  'tab close')
    tab_id=${args[2]:-}
    [ "${FM_HERDR_FAIL_CLOSE:-0}" = 1 ] && exit 1
    jq --arg tab "$tab_id" '
      .tabs as $old
      | ($old | map(select(.tab_id == $tab)) | map(.workspace_id) | unique) as $workspaces
      | ($old | map(select(.tab_id == $tab)) | map(.pane_id)) as $panes
      | .tabs |= map(select(.tab_id != $tab))
      | reduce $workspaces[] as $workspace (.;
          if ([.tabs[] | select(.workspace_id == $workspace)] | length) == 0
          then .workspaces |= map(select(.workspace_id != $workspace))
          else .
          end)
      | .agent_status |= with_entries(select((.key as $pane | ($panes | index($pane))) == null))
    ' "$state" | save
    if [ "${FM_HERDR_MALFORMED_AFTER_CLOSE:-0}" = 1 ]; then
      : > "$state.malformed-after-close"
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
    text=${args[3]:-}
    if [[ "$text" == *"treehouse get"* ]] && [ -n "${FM_HERDR_FAKE_LEASE_PROOF:-}" ]; then
      printf '%s\n' "${FM_HERDR_FAKE_WORKTREE:?}" > "$FM_HERDR_FAKE_LEASE_PROOF"
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

export FM_HERDR_FAKE_STATE="$FAKE_STATE"
export FM_HERDR_FAKE_LOG="$FAKE_LOG"
export FM_HOME="$FAKE_HOME"
export FM_ROOT_OVERRIDE="$ROOT"
export HERDR_SESSION="$SESSION"
export PATH="$FAKE_BIN:$ORIGINAL_PATH"

# Source the production adapter once. Every call below uses its normal
# capability, workspace, target, atomic-run, and identity-checked close paths.
# shellcheck source=bin/backends/herdr.sh
# shellcheck disable=SC1091
. "$ROOT/bin/backends/herdr.sh"

SPAWN_HOME="$FAKE_ROOT/spawn-home"
SPAWN_STATE="$SPAWN_HOME/state"
SPAWN_PROJECT="$FAKE_ROOT/spawn-project"
SPAWN_WORKTREE="$FAKE_ROOT/spawn-worktree"
SPAWN_BIN="$FAKE_ROOT/spawn-bin"
SPAWN_PRIMARY_ROOT="$FAKE_ROOT/spawn-primary"
SPAWN_FAKE_STATE="$FAKE_ROOT/spawn-state.json"
SPAWN_LOG="$FAKE_ROOT/spawn-herdr.log"
SPAWN_FAKE_HARNESS_PID=7913
SPAWN_FAKE_HARNESS_START=herdr-spawn-test-start
SPAWN_ATTESTATION_TOKEN=herdr-spawn-test-token
mkdir -p "$SPAWN_HOME/data/real-herdr-e2e" "$SPAWN_HOME/config" "$SPAWN_HOME/projects" \
  "$SPAWN_STATE" "$SPAWN_BIN" "$SPAWN_PRIMARY_ROOT"
cp -a "$ROOT/bin" "$SPAWN_PRIMARY_ROOT/bin"
cp "$ROOT/AGENTS.md" "$SPAWN_PRIMARY_ROOT/AGENTS.md"
git -C "$SPAWN_PRIMARY_ROOT" init -q
git -C "$SPAWN_PRIMARY_ROOT" add AGENTS.md bin
git -C "$SPAWN_PRIMARY_ROOT" -c user.name='Firstmate Tests' \
  -c user.email='tests@example.invalid' commit -qm initial
printf 'real spawn brief\n' > "$SPAWN_HOME/data/real-herdr-e2e/brief.md"
printf '%s\n' '- spawn-project [direct-PR] - Herdr spawn fixture' > "$SPAWN_HOME/data/projects.md"
: > "$SPAWN_HOME/data/backlog.md"
make_project "$SPAWN_PROJECT"
git -C "$SPAWN_PROJECT" worktree add -q --detach "$SPAWN_WORKTREE"
ln -s "$FAKE_BIN/herdr" "$SPAWN_BIN/herdr"
cat > "$SPAWN_BIN/ps" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"comm="*|*"args="*)
    pid="${@: -1}"
    if [ "$pid" = "${FM_FAKE_HARNESS_PID:?}" ]; then
      case "$*" in
        *"comm="*) printf 'codex\n' ;;
        *) printf 'codex --test\n' ;;
      esac
    else
      printf 'bash\n'
    fi
    ;;
  *"ppid="*) printf '%s\n' "${FM_FAKE_HARNESS_PID:?}" ;;
  *"lstart="*) printf '%s\n' "${FM_FAKE_HARNESS_START:?}" ;;
  *) exec /usr/bin/ps "$@" ;;
esac
SH
chmod +x "$SPAWN_BIN/ps"
printf 'root=%s\ntoken=%s\nharness_pid=%s\nharness_start=%s\n' \
  "$SPAWN_PRIMARY_ROOT" "$SPAWN_ATTESTATION_TOKEN" "$SPAWN_FAKE_HARNESS_PID" \
  "$SPAWN_FAKE_HARNESS_START" > "$SPAWN_STATE/.primary-attestation"
printf '%s\n' \
  "$SPAWN_FAKE_HARNESS_PID|codex:herdr-spawn-test|fallback" > "$SPAWN_STATE/.lock"
: > "$SPAWN_LOG"
cp "$FAKE_STATE" "$SPAWN_FAKE_STATE"
SPAWN_CAPTAIN_BEFORE=$(jq -c '[ (.workspaces[] | select(.workspace_id == "CAPTAIN")), (.tabs[] | select(.workspace_id == "CAPTAIN" and .tab_id == "w1")), .agent_status["captain-pane"] ]' "$SPAWN_FAKE_STATE")

run_real_herdr_spawn() {
  local requested_session=$1
  local -a spawn_env
  spawn_env=(
    -u NO_MISTAKES_GATE
    FM_HOME="$SPAWN_HOME"
    FM_STATE_OVERRIDE="$SPAWN_STATE"
    FM_DATA_OVERRIDE="$SPAWN_HOME/data"
    FM_PROJECTS_OVERRIDE="$SPAWN_HOME/projects"
    FM_CONFIG_OVERRIDE="$SPAWN_HOME/config"
    CODEX_THREAD_ID=herdr-spawn-test
    FM_PRIMARY_ATTESTATION="$SPAWN_ATTESTATION_TOKEN"
    FM_FAKE_HARNESS_PID="$SPAWN_FAKE_HARNESS_PID"
    FM_FAKE_HARNESS_START="$SPAWN_FAKE_HARNESS_START"
    FM_HERDR_FAKE_STATE="$SPAWN_FAKE_STATE"
    FM_HERDR_FAKE_LOG="$SPAWN_LOG"
    FM_HERDR_FAKE_LEASE_PROOF="$SPAWN_STATE/.real-herdr-e2e.spawn-worktree"
    FM_HERDR_FAKE_WORKTREE="$SPAWN_WORKTREE"
    FM_SPAWN_NO_GUARD=1
    FM_SPAWN_WT_WAIT_SECS=2
    PATH="$SPAWN_BIN:$ORIGINAL_PATH"
  )
  if [ -n "$requested_session" ]; then
    spawn_env+=("HERDR_SESSION=$requested_session")
  else
    spawn_env=(-u HERDR_SESSION "${spawn_env[@]}")
  fi
  SPAWN_CAPTURED_OUTPUT=$(cd "$SPAWN_PRIMARY_ROOT" && env "${spawn_env[@]}" \
    FM_ROOT_OVERRIDE="$SPAWN_PRIMARY_ROOT" \
    "$SPAWN_PRIMARY_ROOT/bin/fm-spawn.sh" real-herdr-e2e "$SPAWN_PROJECT" \
    --backend herdr --harness 'echo herdr spawn proof' 2>&1)
  SPAWN_CAPTURED_STATUS=$?
  return "$SPAWN_CAPTURED_STATUS"
}

if run_real_herdr_spawn default; then
  fail "real Herdr spawn accepted the captain-owned default session"
else
  assert_contains "$SPAWN_CAPTURED_OUTPUT" \
    "error: normal Herdr crew dispatch cannot target the captain-owned default session" \
    "real Herdr spawn did not refuse the captain-owned default session"
  pass "real Herdr spawn refuses the captain-owned default session before mutation"
fi

run_real_herdr_spawn "" || fail "real Herdr spawn failed: $SPAWN_CAPTURED_OUTPUT"
SPAWN_META="$SPAWN_STATE/real-herdr-e2e.meta"
[ -f "$SPAWN_META" ] || fail "real Herdr spawn did not publish task metadata"
assert_contains "$(cat "$SPAWN_META")" $'backend=herdr\n' \
  "real Herdr spawn metadata omitted backend=herdr"
assert_meta_line "$SPAWN_META" 'herdr_session=firstmate' \
  "real Herdr spawn did not record session=firstmate"
assert_meta_line "$SPAWN_META" 'herdr_workspace_id=ws-task' \
  "real Herdr spawn did not record the exact workspace id"
assert_meta_line "$SPAWN_META" 'herdr_tab_id=tab-task' \
  "real Herdr spawn did not record the exact tab id"
assert_meta_line "$SPAWN_META" 'herdr_pane_id=pane-task' \
  "real Herdr spawn did not record the exact pane id"
[ "$(grep '^window=' "$SPAWN_META")" = 'window=firstmate:pane-task' ] \
  || fail "real Herdr spawn recorded an unexpected target: $(grep '^window=' "$SPAWN_META")"
SPAWN_CAPTAIN_AFTER=$(jq -c '[ (.workspaces[] | select(.workspace_id == "CAPTAIN")), (.tabs[] | select(.workspace_id == "CAPTAIN" and .tab_id == "w1")), .agent_status["captain-pane"] ]' "$SPAWN_FAKE_STATE")
[ "$SPAWN_CAPTAIN_AFTER" = "$SPAWN_CAPTAIN_BEFORE" ] \
  || fail "real Herdr spawn changed the protected CAPTAIN/w1 state"
assert_not_contains "$(cat "$SPAWN_LOG")" 'CAPTAIN' \
  "real Herdr spawn addressed the protected CAPTAIN workspace"
assert_not_contains "$(cat "$SPAWN_LOG")" 'w1' \
  "real Herdr spawn addressed the protected w1 tab"
pass "real Herdr spawn records firstmate and exact workspace/tab/pane without touching CAPTAIN/w1"

unset HERDR_SESSION
[ "$(fm_backend_herdr_session)" = firstmate ] \
  || fail "normal Herdr dispatch did not default to the isolated firstmate session"
export HERDR_SESSION=default
if capture_failure fm_backend_herdr_session; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: normal Herdr crew dispatch cannot target the captain-owned default session" \
    "normal Herdr dispatch did not refuse the captain-owned default session"
  pass "normal Herdr dispatch refuses an explicit default-session target"
else
  fail "normal Herdr dispatch accepted the captain-owned default session"
fi
export HERDR_SESSION="$SESSION"
if fm_backend_herdr_version_check; then
  pass "Herdr preflight permits the isolated firstmate session without bound-close methods"
else
  fail "isolated firstmate preflight unexpectedly refused: $CAPTURED_OUTPUT"
fi

jq '.agent_status["captain-pane"] = "working"' "$FAKE_STATE" > "$FAKE_STATE.tmp"
mv -f -- "$FAKE_STATE.tmp" "$FAKE_STATE"
export HERDR_SESSION=default
if capture_failure fm_backend_herdr_kill "default:captain-pane" 4242 start-4242; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: Herdr unbound pane.close is forbidden outside dedicated session 'firstmate'" \
    "default-session teardown did not refuse before mutation"
  assert_not_contains "$(cat "$FAKE_LOG")" $'pane close\tcaptain-pane' \
    "default-session teardown attempted an unbound pane close"
  jq -e '.tabs[] | select(.workspace_id == "CAPTAIN" and .tab_id == "w1" and .pane_id == "captain-pane")' \
    "$FAKE_STATE" >/dev/null \
    || fail "default-session teardown removed the protected CAPTAIN/w1 target"
  pass "Herdr refuses unbound teardown before mutating the captain-owned CAPTAIN/w1 target"
else
  fail "default-session teardown returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi
export HERDR_SESSION="$SESSION"

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
    "error: Herdr workspace create failed for 'firstmate' in session '$SESSION'; exact workspace ws-uncertain was reconciled" \
    "malformed workspace-list output did not fall back to exact snapshot reconciliation"
  if jq -e '.workspaces[] | select(.workspace_id == "ws-uncertain")' "$WS_FAIL_STATE" >/dev/null; then
    fail "malformed workspace-list output left a half-created workspace"
  fi
  pass "Herdr reconciles workspace creation from an exact provider snapshot"
else
  fail "malformed workspace-list mutation returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi
unset FM_HERDR_FAIL_WORKSPACE_CREATE FM_HERDR_CREATE_WORKSPACE_ID FM_HERDR_MALFORMED_WORKSPACE_LIST
rm -f -- "$WS_FAIL_STATE.malformed-workspace-list"
export FM_HERDR_CREATE_WORKSPACE_ID=ws-success-stale
export FM_HERDR_STALE_WORKSPACE_RESPONSE=1
if capture_failure fm_backend_herdr_container_ensure "$WS_FAIL_PROJECT"; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: Herdr workspace create failed for 'firstmate' in session '$SESSION'; exact workspace ws-success-stale was reconciled" \
    "stale workspace-create ids did not refuse after provider verification"
  if jq -e '.workspaces[] | select(.workspace_id == "ws-success-stale")' "$WS_FAIL_STATE" >/dev/null; then
    fail "stale workspace-create ids left the created workspace alive"
  fi
  pass "Herdr refuses and reconciles a zero-exit workspace-create identity mismatch"
else
  fail "stale workspace-create ids returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi
unset FM_HERDR_CREATE_WORKSPACE_ID FM_HERDR_STALE_WORKSPACE_RESPONSE
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

# Teardown requires process identity before it can close a live pane.
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

# A PID mismatch on the recorded pane refuses and leaves the pane alive.
export FM_HERDR_FAKE_PANE_PID=$$
if capture_failure fm_backend_herdr_kill "$TARGET" 4242 start-4242; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: Herdr safe pane close failed identity verification or mutation for target '$TARGET'" \
    "mismatched PID teardown did not refuse with a precise diagnostic"
  if jq -e '.tabs[] | select(.pane_id == "pane-task")' "$FAKE_STATE" >/dev/null; then
    pass "Herdr teardown refuses a mismatched PID without closing the pane"
  else
    fail "mismatched PID teardown removed the recorded pane"
  fi
else
  fail "mismatched PID teardown returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi

EXPECTED_PID=$$
EXPECTED_START=$(fm_backend_herdr_proc_start_time "$EXPECTED_PID") \
  || fail "could not read the focused test process start time"
fm_backend_herdr_kill "$TARGET" "$EXPECTED_PID" "$EXPECTED_START" \
  || fail "identity-checked Herdr teardown failed for the recorded live task endpoint"
assert_file_contains "$FAKE_LOG" \
  $'pane close\tpane-task\t--session\tfirstmate' \
  "identity-checked teardown did not close the exact firstmate pane"
jq -e '.tabs[] | select(.pane_id == "pane-focused" and .workspace_id == "ws-focused")' \
  "$FAKE_STATE" >/dev/null \
  || fail "identity-checked teardown touched the unrelated focused workspace/pane"
if jq -e '.tabs[] | select(.pane_id == "pane-task")' "$FAKE_STATE" >/dev/null; then
  fail "identity-checked teardown left the recorded task pane alive"
fi
pass "Herdr teardown closes only the exact recorded firstmate pane after PID/start-time proof"

: > "$FAKE_LOG"
export FM_HERDR_STALE_TAB_RESPONSE=1
if capture_failure fm_backend_herdr_create_task "$CONTAINER_ID" "fm-herdr-stale-success" "$PROJECT"; then
  assert_contains "$CAPTURED_OUTPUT" \
    "error: Herdr task tab 'fm-herdr-stale-success' returned an unverified provider identity in workspace ws-task (session $SESSION)" \
    "stale task-create ids did not refuse after provider verification"
  if jq -e '.tabs[] | select(.workspace_id == "ws-task" and .label == "fm-herdr-stale-success")' "$FAKE_STATE" >/dev/null; then
    fail "stale task-create ids left the created task tab alive"
  fi
  jq -e '.tabs[] | select(.workspace_id == "ws-task" and .tab_id == "tab-seed")' "$FAKE_STATE" >/dev/null \
    || fail "stale task-create ids caused the durable seed tab to disappear"
  pass "Herdr refuses and reconciles a zero-exit task-create identity mismatch"
else
  fail "stale task-create ids returned unexpected status $CAPTURED_STATUS: $CAPTURED_OUTPUT"
fi
unset FM_HERDR_STALE_TAB_RESPONSE

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
assert_file_contains "$FAKE_LOG" \
  $'tab close\ttab-task\t--session\tfirstmate' \
  "failed task-tab mutation was not reconciled through the exact firstmate tab endpoint"
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
  assert_not_contains "$(cat "$FAKE_LOG")" \
    $'tab close\ttab-seed\t--session\tfirstmate' \
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
    "cleanup-uncertain"$'\t'"$SESSION:ws-task"$'\t'"fm-herdr-unverified-cleanup" \
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
