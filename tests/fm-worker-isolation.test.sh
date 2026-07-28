#!/usr/bin/env bash
# Regression tests for task-worker isolation: the launched-agent home
# declaration, the refusals that depend on it, /proc as the method of record for
# an agent's working directory, pooled-slot ownership, and the resume-time
# re-assertion sweep.
#
# The defects these pin (all observed live, 2026-07-24/25):
#   - an audit worker inherited the primary's FM_HOME and took the primary's own
#     session-owner record, locking the real primary out of its home;
#   - a restore resumed every recorded agent session but resolved 17 of 17
#     worktrees back onto their origin repository, four into the primary
#     checkout, so the spawn-time isolation assertion did not survive;
#   - ten pooled slots were recorded by more than one task, and releasing one
#     task's lease reissued a slot a still-live paused task also held;
#   - a pane cwd field named the wrong process and reported an isolated worker
#     as living in the primary checkout.
#
# Kimi's launch declaration is asserted in tests/fm-kimi-harness.test.sh, which
# owns that adapter's readiness and delivery gates; the five adapters that need
# no readiness gate are driven end to end here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
LOCK="$ROOT/bin/fm-lock.sh"
SWEEP="$ROOT/bin/fm-isolation-sweep.sh"
NUDGE="$ROOT/bin/fm-sessionstart-nudge.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-isolation)

# Fixture agents are real long-lived processes, and the code under test finds
# them by scanning /proc for a declaration marker. Two hygiene rules follow.
#
# Every fixture id carries RUN_TAG, so a process leaked by an earlier run - a
# run killed outright, before its trap could fire - can never be mistaken for
# this run's agent. Without it a stale `sleep` answers a later lookup and the
# suite fails for a reason that is not in the diff.
#
# Every fixture process also carries FM_AGENT_TEST_RUN, so cleanup can find them
# all by marker rather than by bookkeeping. Recorded pids alone are not enough:
# a fixture started inside a command substitution registers its pid in a
# subshell that is already gone, and a parent/child fixture leaves the child
# behind when only the parent is signalled.
RUN_TAG=$$
BG_PIDS=()
worker_isolation_cleanup() {
  local pid entry marker
  set +e
  for pid in "${BG_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  for entry in /proc/[0-9]*; do
    [ -d "$entry" ] || continue
    pid=${entry#/proc/}
    marker=$( { tr '\0' '\n' < "$entry/environ"; } 2>/dev/null \
      | sed -n 's/^FM_AGENT_TEST_RUN=//p' | head -1)
    [ "$marker" = "$RUN_TAG" ] || continue
    kill -9 "$pid" 2>/dev/null
  done
  fm_test_cleanup
  return 0
}
trap worker_isolation_cleanup EXIT

# start_declared_agent <cwd> <task-id> <home> [role]: start a live process that
# carries the declaration bin/fm-spawn.sh injects, from <cwd>. Echoes its pid.
# The agent's own descriptors are detached from this function's stdout: a
# long-lived background process that inherits the write end of a caller's
# command substitution keeps that substitution blocked until the process exits.
start_declared_agent() {
  local cwd=$1 id=$2 home=$3 role=${4:-crewmate} pid
  ( cd "$cwd" \
    && FM_AGENT_ROLE="$role" FM_AGENT_TASK="$id" FM_AGENT_OWNER_HOME="$home" \
       FM_AGENT_TEST_RUN="$RUN_TAG" \
       exec sleep 300 ) >/dev/null 2>&1 </dev/null &
  pid=$!
  BG_PIDS+=("$pid")
  # Wait for the exec'd process to actually be in place before it is inspected.
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -e "/proc/$pid/cwd" ] && break
    sleep 0.05
    i=$((i + 1))
  done
  printf '%s\n' "$pid"
}

require_procfs() {
  [ -d /proc ] && [ -L "/proc/$$/cwd" ]
}

# --- A. the home declaration itself -----------------------------------------

test_crewmate_declaration_clears_every_inherited_home() {
  local prefix
  prefix=$( . "$ROOT/bin/fm-worker-isolation-lib.sh" \
    && fm_worker_launch_env_prefix crewmate task-a1 /home/cap/firstmate )
  [ "$prefix" = "FM_HOME= FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_LIFECYCLE_HOME= FM_LIFECYCLE_STATE= FM_LIFECYCLE_SCRIPT= FM_AGENT_ROLE=crewmate FM_AGENT_TASK='task-a1' FM_AGENT_OWNER_HOME='/home/cap/firstmate' " ] \
    || fail "crewmate declaration changed: $prefix"
  pass "a crewmate declaration clears every operational-home variable and names its owner"
}

test_secondmate_declaration_pins_only_its_own_home() {
  local prefix
  prefix=$( . "$ROOT/bin/fm-worker-isolation-lib.sh" \
    && fm_worker_launch_env_prefix secondmate dom-b2 /home/cap/homes/dom )
  [ "$prefix" = "FM_HOME='/home/cap/homes/dom' FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_LIFECYCLE_HOME= FM_LIFECYCLE_STATE= FM_LIFECYCLE_SCRIPT= FM_AGENT_ROLE=secondmate FM_AGENT_TASK='dom-b2' FM_AGENT_OWNER_HOME='/home/cap/homes/dom' " ] \
    || fail "secondmate declaration changed: $prefix"
  pass "a secondmate declaration pins its own home and clears every inherited override"
}

test_declaration_refuses_rather_than_emitting_a_partial_prefix() {
  local out status
  out=$( . "$ROOT/bin/fm-worker-isolation-lib.sh" \
    && fm_worker_launch_env_prefix auditor task-a3 /home/cap/firstmate 2>&1 )
  status=$?
  expect_code 1 "$status" "an unknown role must refuse"
  assert_contains "$out" "unknown agent role" "unknown role refusal lost its reason"

  out=$( . "$ROOT/bin/fm-worker-isolation-lib.sh" \
    && fm_worker_launch_env_prefix crewmate '' /home/cap/firstmate 2>&1 )
  status=$?
  expect_code 1 "$status" "an empty task id must refuse"

  out=$( . "$ROOT/bin/fm-worker-isolation-lib.sh" \
    && fm_worker_launch_env_prefix crewmate task-a3 relative/home 2>&1 )
  status=$?
  expect_code 1 "$status" "a relative owning home must refuse"
  assert_contains "$out" "absolute owning home" "relative-home refusal lost its reason"
  pass "an unbuildable declaration refuses instead of emitting a partial prefix"
}

# --- B. every verified harness launches with the declaration ----------------

make_launch_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
FAKE_TMUX_STATE=${FM_FAKE_TMUX_STATE:-}
[ -n "$FAKE_TMUX_STATE" ] || FAKE_TMUX_STATE="${TMPDIR:-/tmp}/fm-worker-isolation-tmux-state-$$"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  *"#{pane_pid}"*) printf '%s\n' "${FM_FAKE_PANE_PID:-}"; exit 0 ;;
esac
case "${1:-}" in
  # The stable-window-id enumeration. The duplicate-name check spawn runs first
  # asks for '#{window_name}' alone and must still answer nothing, or spawn
  # would refuse the launch as a duplicate.
  list-windows)
    case "$*" in
      *"#{window_id}"*) printf '%s\n' "${FM_FAKE_WINDOW_ID:-@42}" ;;
      *"#{window_name}"*) [ ! -s "$FAKE_TMUX_STATE" ] || cat "$FAKE_TMUX_STATE" ;;
    esac
    exit 0
    ;;
  display-message)
    case "$*" in
      *"#{window_name}"*) [ ! -f "$FAKE_TMUX_STATE" ] || cat "$FAKE_TMUX_STATE" ;;
      *) printf 'firstmate\n' ;;
    esac
    exit 0
    ;;
  has-session|new-session) exit 0 ;;
  kill-window)
    [ -z "${FM_FAKE_KILL_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_FAKE_KILL_LOG"
    : > "$FAKE_TMUX_STATE"
    exit 0
    ;;
  new-window)
    name=
    prev=
    for arg in "$@"; do
      if [ "$prev" = -n ]; then name=$arg; break; fi
      prev=$arg
    done
    [ -z "$name" ] || printf '%s\n' "$name" > "$FAKE_TMUX_STATE"
    printf '%s\n' "${FM_FAKE_WINDOW_ID:-@42}"
    exit 0
    ;;
  set-window-option) exit 0 ;;
  rename-window) printf '%s\n' "${@: -1}" > "$FAKE_TMUX_STATE"; exit 0 ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"; break; fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_launch_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_launch_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/tmux-window-name"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_launch_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

test_every_verified_harness_launches_with_its_home_declaration() {
  local harness id rec out status launch expected home_real
  for harness in claude codex opencode pi grok; do
    id="declared-$harness-b1"
    rec=$(make_launch_case "launch-$harness" "$id")
    read_launch_record "$rec"
    out=$(HOME="$HOME_DIR" GROK_HOME="$HOME_DIR/.grok" \
      FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
      FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$WT_DIR" \
      FM_FAKE_TMUX_STATE="$CASE_DIR/tmux-window-name" \
      FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
      PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --harness "$harness" 2>&1)
    status=$?
    expect_code 0 "$status" "$harness spawn should succeed"$'\n'"$out"
    launch=$(cat "$CASE_DIR/launch.log")
    home_real=$(cd "$HOME_DIR" && pwd -P)
    expected=$(fm_worker_env_prefix crewmate "$id" "$home_real")
    case "$launch" in
      "$expected"*) : ;;
      *) fail "$harness launch did not begin with the home declaration"$'\n'"expected prefix: $expected"$'\n'"actual: $launch" ;;
    esac
    assert_contains "$launch" "FM_HOME= " "$harness launch let the worker inherit FM_HOME"
  done
  pass "claude, codex, opencode, pi, and grok all launch with the crewmate home declaration"
}

test_secondmate_child_receives_only_its_own_home() {
  local expected
  expected=$(fm_worker_env_prefix secondmate dom-b5 /homes/dom)
  case "$expected" in
    "FM_HOME='/homes/dom' "*) : ;;
    *) fail "secondmate declaration did not pin its own home first: $expected" ;;
  esac
  assert_not_contains "$expected" "FM_ROOT_OVERRIDE='" \
    "secondmate declaration passed an inherited root override through"
  pass "a secondmate child receives its own home and no inherited override"
}

# --- C. a declared worker is inert and refused -------------------------------

make_primary_home() {
  local dir=$1
  mkdir -p "$dir/bin" "$dir/state" "$dir/data" "$dir/config"
  fm_git_init_commit "$dir"
  printf '# agents\n' > "$dir/AGENTS.md"
  printf '%s\n' "$dir"
}

test_declared_worker_is_never_a_primary_scope_match() {
  # Named primary_home, not home: the sourced libraries carry their own `home`
  # local, and reusing the name here makes shellcheck read the two as one.
  local primary_home out
  primary_home=$(make_primary_home "$TMP_ROOT/scope-home")
  out=$( . "$ROOT/bin/fm-primary-scope-lib.sh" \
    && fm_primary_scope_matches "$primary_home" "$primary_home/state" && printf 'primary' || printf 'not-primary' )
  [ "$out" = primary ] || fail "the fixture is not recognized as a genuine primary at all"
  out=$( export FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w1 FM_AGENT_OWNER_HOME="$primary_home"
    . "$ROOT/bin/fm-primary-scope-lib.sh" \
    && fm_primary_scope_matches "$primary_home" "$primary_home/state" && printf 'primary' || printf 'not-primary' )
  [ "$out" = not-primary ] \
    || fail "a declared crewmate matched primary scope inside a genuine primary checkout"
  out=$( export FM_AGENT_ROLE=quartermaster FM_AGENT_TASK=w1 FM_AGENT_OWNER_HOME="$primary_home"
    . "$ROOT/bin/fm-primary-scope-lib.sh" \
    && fm_primary_scope_matches "$primary_home" "$primary_home/state" && printf 'primary' || printf 'not-primary' )
  [ "$out" = not-primary ] || fail "an unknown declared worker role matched primary scope"
  out=$( export FM_AGENT_ROLE= FM_AGENT_TASK=w1 FM_AGENT_OWNER_HOME=
    . "$ROOT/bin/fm-primary-scope-lib.sh" \
    && fm_primary_scope_matches "$primary_home" "$primary_home/state" && printf 'primary' || printf 'not-primary' )
  [ "$out" = not-primary ] || fail "a partial undeclared identity matched primary scope"
  printf 'trusted-task\n' > "$primary_home/.fm-secondmate-home"
  out=$( export FM_AGENT_ROLE=secondmate FM_AGENT_TASK=other-task FM_AGENT_OWNER_HOME="$primary_home"
    . "$ROOT/bin/fm-primary-scope-lib.sh" \
    && fm_primary_scope_matches "$primary_home" "$primary_home/state" && printf 'primary' || printf 'not-primary' )
  [ "$out" = not-primary ] || fail "a secondmate mismatched to its trusted marker matched primary scope"
  pass "primary scope rejects crewmates, unknown identities, partial identities, and mismatched secondmates"
}

test_project_local_startup_adapter_stays_inert_for_a_worker() {
  local out
  if [ ! -x "$NUDGE" ]; then
    pass "skip: this JT fork has no tracked session-start nudge adapter"
    return 0
  fi
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$ROOT" \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w2 FM_AGENT_OWNER_HOME="$ROOT" \
    "$NUDGE" 2>&1)
  [ -z "$out" ] || fail "the session-start nudge fired for a declared task worker: $out"
  pass "the tracked session-start adapter stays inert for a declared task worker"
}

test_worker_cannot_take_the_session_owner_record() {
  local home missing before out status
  home=$(make_primary_home "$TMP_ROOT/lock-home")
  printf '424242\n' > "$home/state/.lock"
  before=$(cat "$home/state/.lock")

  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w3 FM_AGENT_OWNER_HOME="$home" \
    "$LOCK" 2>&1)
  status=$?
  expect_code 1 "$status" "a declared task worker must not acquire the session lock"
  assert_contains "$out" "task worker" "the lock refusal did not name the worker declaration"
  [ "$(cat "$home/state/.lock")" = "$before" ] \
    || fail "the session owner record was rewritten by a task worker"

  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w3 FM_AGENT_OWNER_HOME="$home" \
    "$LOCK" status 2>&1)
  status=$?
  expect_code 0 "$status" "read-only lock status must stay available to a worker"
  missing="$TMP_ROOT/missing-lock-home"
  out=$(FM_ROOT_OVERRIDE="$missing" FM_HOME="$missing" \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w3 FM_AGENT_OWNER_HOME="$home" \
    "$LOCK" status 2>&1)
  status=$?
  expect_code 0 "$status" "read-only lock status must inspect a missing state path"
  [ ! -e "$missing" ] || fail "read-only lock status created a missing operational home"
  pass "a declared task worker is refused the session owner record and never rewrites it"
}

test_worker_cannot_spawn_or_tear_down() {
  local home out status
  home=$(make_primary_home "$TMP_ROOT/refuse-home")
  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w4 FM_AGENT_OWNER_HOME="$home" \
    "$SPAWN" some-task "$home" 2>&1)
  status=$?
  expect_code 1 "$status" "a declared task worker must not spawn"
  assert_contains "$out" "spawn refused" "the spawn refusal did not name the operation"

  out=$(FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w4 FM_AGENT_OWNER_HOME="$home" \
    "$TEARDOWN" some-task 2>&1)
  status=$?
  expect_code 1 "$status" "a declared task worker must not tear down"
  assert_contains "$out" "teardown refused" "the teardown refusal did not name the operation"
  pass "a declared task worker is refused both dispatch and teardown"
}

test_worker_cannot_run_direct_primary_mutators() {
  local home foreign out status script operation args
  home=$(make_primary_home "$TMP_ROOT/direct-mutator-owner")
  foreign="$TMP_ROOT/direct-mutator-foreign"
  mkdir -p "$foreign"

  while IFS='|' read -r script operation args; do
    status=0
    # shellcheck disable=SC2086
    out=$(FM_HOME="$foreign" FM_ROOT_OVERRIDE="$foreign" \
      FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w5 FM_AGENT_OWNER_HOME="$home" \
      "$ROOT/bin/$script" $args 2>&1) || status=$?
    expect_code 1 "$status" "$script must refuse a declared worker"
    assert_contains "$out" "$operation refused" "$script refusal lost its operation"
    [ ! -e "$foreign/state" ] || fail "$script resolved foreign state before refusal"
  done <<'ROWS'
fm-config-push.sh|config push|
fm-home-seed.sh|home seed|domain /tmp/worker-home alpha
fm-fleet-sync.sh|fleet sync|
fm-merge-local.sh|local merge|task
fm-watch-arm.sh|watch arm|--restart
fm-wake-drain.sh|wake drain|
fm-promote.sh|promote|task
fm-backlog-handoff.sh|backlog handoff|domain item
fm-brief.sh|brief|task alpha
fm-afk-launch.sh|afk|start
fm-watch.sh|watch|
fm-watch-session.sh|watch session|start
fm-send.sh|send|fm-task hello
ROWS

  while IFS='|' read -r script operation args; do
    status=0
    # shellcheck disable=SC2086
    out=$(FM_HOME="$foreign" FM_ROOT_OVERRIDE="$foreign" \
      FM_AGENT_ROLE=secondmate FM_AGENT_TASK=domain FM_AGENT_OWNER_HOME="$home" \
      "$ROOT/bin/$script" $args 2>&1) || status=$?
    expect_code 1 "$status" "$script must refuse a foreign-home secondmate"
    assert_contains "$out" "$operation refused" "$script secondmate refusal lost its operation"
  done <<'ROWS'
fm-config-push.sh|config push|
fm-home-seed.sh|home seed|domain /tmp/worker-home alpha
fm-fleet-sync.sh|fleet sync|
fm-merge-local.sh|local merge|task
fm-watch-arm.sh|watch arm|--restart
fm-wake-drain.sh|wake drain|
fm-promote.sh|promote|task
fm-backlog-handoff.sh|backlog handoff|domain item
fm-brief.sh|brief|task alpha
fm-afk-launch.sh|afk|start
fm-watch.sh|watch|
fm-watch-session.sh|watch session|start
fm-send.sh|send|fm-task hello
ROWS

  FM_HOME="$foreign" FM_ROOT_OVERRIDE="$foreign" \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w5 FM_AGENT_OWNER_HOME="$home" \
    "$ROOT/bin/fm-config-push.sh" --help >/dev/null \
    || fail "config push help was not kept read-only"
  FM_HOME="$foreign" FM_ROOT_OVERRIDE="$foreign" \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w5 FM_AGENT_OWNER_HOME="$home" \
    "$ROOT/bin/fm-home-seed.sh" validate >/dev/null \
    || fail "home seed validation was not kept read-only"
  FM_HOME="$foreign" FM_ROOT_OVERRIDE="$foreign" \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w5 FM_AGENT_OWNER_HOME="$home" \
    "$ROOT/bin/fm-fleet-sync.sh" --help >/dev/null \
    || fail "fleet sync help was not kept read-only"
  status=0
  out=$(FM_HOME="$foreign" FM_ROOT_OVERRIDE="$foreign" \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w5 FM_AGENT_OWNER_HOME="$home" \
    "$ROOT/bin/fm-afk-launch.sh" status 2>&1) || status=$?
  expect_code 0 "$status" "AFK status must remain read-only for a worker"
  assert_not_contains "$out" "refused" "AFK status was guarded as a mutation"
  [ ! -e "$foreign/state" ] || fail "AFK status created foreign state"
  status=0
  out=$(FM_HOME="$foreign" FM_ROOT_OVERRIDE="$foreign" \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=w5 FM_AGENT_OWNER_HOME="$home" \
    "$ROOT/bin/fm-watch-session.sh" status 2>&1) || status=$?
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ] \
    || fail "watch-session status did not remain available to a worker"
  assert_not_contains "$out" "refused" "watch-session status was guarded as a mutation"
  [ ! -e "$foreign/state" ] || fail "watch-session status created foreign state"
  pass "declared workers cannot run direct primary mutators"
}

test_secondmate_primary_operations_require_its_declared_home() {
  local home foreign alias out status
  home=$(make_primary_home "$TMP_ROOT/secondmate-owner-home")
  foreign=$(make_primary_home "$TMP_ROOT/secondmate-foreign-home")
  printf '%s\n' domain > "$home/.fm-secondmate-home"
  alias="$TMP_ROOT/secondmate-owner-alias"
  ln -s "$home" "$alias"

  out=$(FM_HOME="$alias" FM_AGENT_ROLE=secondmate FM_AGENT_TASK=domain \
    FM_AGENT_OWNER_HOME="$home" bash -c \
    '. "$1/bin/fm-worker-isolation-lib.sh"; fm_worker_refuse_primary_operation lock' \
    _ "$ROOT" 2>&1)
  status=$?
  expect_code 0 "$status" "a canonical alias of a secondmate's declared home must remain usable"

  out=$(FM_ROOT_OVERRIDE="$foreign" FM_HOME="$foreign" \
    FM_AGENT_ROLE=secondmate FM_AGENT_TASK=domain FM_AGENT_OWNER_HOME="$home" \
    "$LOCK" 2>&1)
  status=$?
  expect_code 1 "$status" "a secondmate must not lock another operational home"
  assert_contains "$out" "secondmate" "the foreign-home lock refusal lost the declared role"
  [ ! -e "$foreign/state/.lock" ] || fail "a secondmate mutated a foreign session lock"

  out=$(FM_ROOT_OVERRIDE="$foreign" FM_HOME="$foreign" FM_SPAWN_NO_GUARD=1 \
    FM_AGENT_ROLE=secondmate FM_AGENT_TASK=domain FM_AGENT_OWNER_HOME="$home" \
    "$SPAWN" some-task "$foreign" 2>&1)
  status=$?
  expect_code 1 "$status" "a secondmate must not spawn from another operational home"
  assert_contains "$out" "spawn refused" "the foreign-home spawn refusal lost the operation"
  [ ! -e "$foreign/state/.spawn-some-task.lock" ] \
    || fail "a foreign-home secondmate reached spawn locking"

  out=$(FM_ROOT_OVERRIDE="$foreign" FM_HOME="$foreign" \
    FM_AGENT_ROLE=secondmate FM_AGENT_TASK=domain FM_AGENT_OWNER_HOME="$home" \
    "$TEARDOWN" some-task 2>&1)
  status=$?
  expect_code 1 "$status" "a secondmate must not tear down another operational home"
  assert_contains "$out" "teardown refused" "the foreign-home teardown refusal lost the operation"

  out=$(FM_HOME="$home" FM_AGENT_ROLE=secondmate FM_AGENT_TASK=other \
    FM_AGENT_OWNER_HOME="$home" bash -c \
    '. "$1/bin/fm-worker-isolation-lib.sh"; fm_worker_refuse_primary_operation lock' \
    _ "$ROOT" 2>&1)
  status=$?
  expect_code 1 "$status" "a secondmate task must match its trusted home marker"

  out=$(FM_HOME="$home" FM_AGENT_TASK=domain FM_AGENT_OWNER_HOME="$home" bash -c \
    '. "$1/bin/fm-worker-isolation-lib.sh"; fm_worker_refuse_primary_operation lock' \
    _ "$ROOT" 2>&1)
  status=$?
  expect_code 1 "$status" "a partial worker declaration must refuse primary operations"

  out=$(FM_HOME="$home" FM_AGENT_ROLE=quartermaster FM_AGENT_TASK=domain \
    FM_AGENT_OWNER_HOME="$home" bash -c \
    '. "$1/bin/fm-worker-isolation-lib.sh"; fm_worker_refuse_primary_operation lock' \
    _ "$ROOT" 2>&1)
  status=$?
  expect_code 1 "$status" "an unknown worker role must refuse primary operations"
  pass "a secondmate can operate only inside its declared canonical home"
}

# --- D. /proc is the method of record ---------------------------------------

test_proc_cwd_is_read_from_the_live_process() {
  local dir pid cwd
  require_procfs || { pass "skip: this host has no readable procfs for cwd proof"; return 0; }
  dir="$TMP_ROOT/proc-cwd"
  mkdir -p "$dir"
  pid=$(start_declared_agent "$dir" "proc-d1-$RUN_TAG" "$TMP_ROOT/proc-home")
  cwd=$( . "$ROOT/bin/fm-agent-cwd-lib.sh" && fm_agent_proc_cwd "$pid" )
  [ "$cwd" = "$(cd "$dir" && pwd -P)" ] \
    || fail "the process cwd was not read from /proc: $cwd"
  pass "an agent's working directory is read from the live process, not a record"
}

test_declared_agent_lookup_returns_the_root_most_process() {
  # Named root_pid, not root: the sourced library carries its own `root` local.
  local dir out root_pid child id
  require_procfs || { pass "skip: this host has no readable procfs for declaration lookup"; return 0; }
  dir="$TMP_ROOT/proc-root"
  id="proc-d2-$RUN_TAG"
  mkdir -p "$dir"
  ( cd "$dir" && FM_AGENT_ROLE=crewmate FM_AGENT_TASK="$id" \
      FM_AGENT_OWNER_HOME="$TMP_ROOT/proc-home" FM_AGENT_TEST_RUN="$RUN_TAG" \
      sh -c 'sleep 300' ) >/dev/null 2>&1 </dev/null &
  root_pid=$!
  BG_PIDS+=("$root_pid")
  sleep 0.5
  out=$( . "$ROOT/bin/fm-agent-cwd-lib.sh" \
    && fm_agent_root_pids_for_identity "$id" "$TMP_ROOT/proc-home" crewmate )
  [ -n "$out" ] || fail "the declared agent process was not found at all"
  child=$( . "$ROOT/bin/fm-agent-cwd-lib.sh" \
    && fm_agent_pids_for_identity "$id" "$TMP_ROOT/proc-home" crewmate | wc -l )
  [ "$child" -ge 2 ] || fail "the fixture did not produce a declared parent and child"
  [ "$out" = "$root_pid" ] \
    || fail "the lookup returned $out, not the root-most declared process $root_pid"
  pass "the declared-agent lookup returns the agent itself, not one of its subprocesses"
}

test_provider_process_id_matrix_is_explicit() {
  local out
  out=$( . "$ROOT/bin/fm-agent-cwd-lib.sh"
    for backend in herdr zellij cmux orca unknown; do
      if fm_agent_backend_shell_pid "$backend" "session:pane" >/dev/null 2>&1; then
        printf '%s-exposes-a-pid\n' "$backend"
      fi
    done )
  [ -z "$out" ] || fail "a provider with no verified per-pane process id claimed one: $out"
  out=$( . "$ROOT/bin/fm-agent-cwd-lib.sh" \
    && fm_agent_cwd_verdict '' '' '' herdr 'ses:pane' )
  case "$out" in
    unknown*) : ;;
    *) fail "a provider without a process id must report unknown, not a pane value: $out" ;;
  esac
  pass "providers with no verified per-pane process id report unknown instead of a pane value"
}

make_window_id_fakebin() {  # <dir>
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows)
    case "$*" in
      *"#{window_id}"*) printf '@7 fm-live\n' ;;
    esac
    exit 0
    ;;
  display-message)
    case "$*" in
      # The one honest answer: the pane of the window actually asked for.
      *"-t @7 "*) printf '4242\n' ;;
      # What real tmux does with a target it cannot resolve - it answers for the
      # ACTIVE CLIENT's window, which is firstmate's own pane.
      *) printf '9999\n' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# agent_cwd_call <fakebin> <function> [args...]: call one bin/fm-agent-cwd-lib.sh
# function with <fakebin> ahead of PATH, in a child shell so the fake provider
# never leaks into the rest of the suite.
agent_cwd_call() {
  local fakebin=$1
  shift
  PATH="$fakebin:$PATH" bash -c '. "$1/bin/fm-agent-cwd-lib.sh" || exit 1; shift; "$@"' \
    _ "$ROOT" "$@"
}

test_tmux_pane_pid_comes_from_the_stable_window_id() {
  local fakebin out
  fakebin=$(make_window_id_fakebin "$TMP_ROOT/window-id")
  out=$(agent_cwd_call "$fakebin" fm_agent_backend_shell_pid tmux 'firstmate:fm-live')
  [ "$out" = 4242 ] \
    || fail "the pane pid was not read through the window's stable id: $out"
  pass "a tmux pane pid is read through the window's stable id, not its name"
}

test_a_lost_window_name_never_answers_with_firstmates_own_pane() {
  local fakebin out status
  fakebin=$(make_window_id_fakebin "$TMP_ROOT/window-lost")
  out=$(agent_cwd_call "$fakebin" fm_agent_backend_shell_pid tmux 'firstmate:fm-renamed-away')
  status=$?
  expect_code 1 "$status" "a window name that resolves to nothing must not yield a pid"
  [ -z "$out" ] || fail "a lost window name answered with another window's pane pid: $out"
  out=$(agent_cwd_call "$fakebin" fm_agent_cwd_verdict '' '' '' tmux 'firstmate:fm-renamed-away')
  case "$out" in
    unknown*) : ;;
    *) fail "a lost window name produced a verdict instead of unknown: $out" ;;
  esac
  pass "a lost or renamed window reports unknown instead of firstmate's own pane"
}

test_one_proc_walk_answers_every_task_in_a_sweep() {
  local dir dir_real index one two out
  require_procfs || { pass "skip: this host has no readable procfs for the process index"; return 0; }
  dir="$TMP_ROOT/proc-index"
  mkdir -p "$dir"
  dir_real=$(cd "$dir" && pwd -P)
  one="index-one-d6-$RUN_TAG"
  two="index-two-d6-$RUN_TAG"
  start_declared_agent "$dir" "$one" "$TMP_ROOT/proc-home" >/dev/null
  start_declared_agent "$dir" "$two" "$TMP_ROOT/proc-home" >/dev/null
  index=$( . "$ROOT/bin/fm-agent-cwd-lib.sh" && fm_agent_task_pid_index )
  assert_contains "$index" "$one" "the single process walk missed a declared task"
  assert_contains "$index" "$two" "the single process walk missed a declared task"
  out=$( . "$ROOT/bin/fm-agent-cwd-lib.sh" \
    && fm_agent_cwd_verdict "$two" "$TMP_ROOT/proc-home" crewmate '' '' "$index" )
  case "$out" in
    proc*"$dir_real") : ;;
    *) fail "a verdict taken from the shared index did not prove the process cwd: $out" ;;
  esac
  # An index with no entry for the task is a real answer, not a missing
  # argument: it must not silently fall back to a fresh walk that finds one.
  out=$( . "$ROOT/bin/fm-agent-cwd-lib.sh" \
    && fm_agent_cwd_verdict "$two" "$TMP_ROOT/proc-home" crewmate '' '' '' )
  case "$out" in
    unknown*) : ;;
    *) fail "an empty shared index was treated as no index at all: $out" ;;
  esac
  pass "one /proc walk answers every task in a sweep, and an empty index is a real answer"
}

test_spawn_settles_on_proc_evidence_over_a_lying_pane_path() {
  local rec id out status lying pid
  require_procfs || { pass "skip: this host has no readable procfs for spawn settle proof"; return 0; }
  id="settle-proc-d4-$RUN_TAG"
  rec=$(make_launch_case settle-proc "$id")
  read_launch_record "$rec"
  lying="$CASE_DIR/other-real-checkout"
  fm_git_init_commit "$lying"
  pid=$(start_declared_agent "$WT_DIR" "$id-shell" "$HOME_DIR")

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$lying" FM_FAKE_PANE_PID="$pid" \
    FM_FAKE_TMUX_STATE="$CASE_DIR/tmux-window-name" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness claude 2>&1)
  status=$?
  expect_code 0 "$status" "spawn should settle on the process evidence"$'\n'"$out"
  assert_grep "worktree=$(cd "$WT_DIR" && pwd -P)" "$HOME_DIR/state/$id.meta" \
    "spawn did not record the worktree proved by the agent process"
  assert_no_grep "worktree=$lying" "$HOME_DIR/state/$id.meta" \
    "spawn recorded the lying pane path as the worktree"
  pass "spawn settles on the process's own working directory, not a pane field that names another process"
}

# --- E. pooled-slot ownership -----------------------------------------------

make_slot_world() {
  local name=$1 world proj wt other
  world="$TMP_ROOT/$name"
  proj="$world/project"
  wt="$world/wt"
  other="$world/wt-other"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config"
  fm_git_worktree "$proj" "$wt" "slot-$name"
  git -C "$proj" worktree add --quiet -b "slot-$name-other" "$other"
  printf '%s\n' "$world|$proj|$wt|$other"
}

read_slot_world() {
  IFS='|' read -r WORLD PROJ_DIR WT_DIR OTHER_WT <<EOF
$1
EOF
}

slot_verdict() {  # <state> <id> <wt> <stamp-home> [role] [worker-home]
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_disposal_verdict "$1" "$2" "$3" "$4" "${6:-$4}" "${5:-crewmate}" )
}

test_slot_stamp_records_ownership_and_never_stamps_a_plain_checkout() {
  local rec task home
  rec=$(make_slot_world slot-stamp)
  read_slot_world "$rec"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-e1 "$WORLD/home" ) \
    || fail "a linked worktree could not be stamped"
  task=$( . "$ROOT/bin/fm-slot-owner-lib.sh" && fm_slot_stamp_field "$WT_DIR" task )
  [ "$task" = task-e1 ] || fail "the slot stamp did not record its task: $task"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" foreign-e1 "$WORLD/foreign-home" ) 2>/dev/null \
    && fail "a foreign owner replaced the slot stamp"
  task=$( . "$ROOT/bin/fm-slot-owner-lib.sh" && fm_slot_stamp_field "$WT_DIR" task )
  home=$( . "$ROOT/bin/fm-slot-owner-lib.sh" && fm_slot_stamp_field "$WT_DIR" home )
  [ "$task" = task-e1 ] && [ "$home" = "$WORLD/home" ] \
    || fail "a failed foreign claim changed the existing ownership stamp"
  [ -z "$(git -C "$WT_DIR" status --porcelain)" ] \
    || fail "the slot stamp dirtied the working tree"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$PROJ_DIR" task-e1 "$WORLD/home" ) 2>/dev/null \
    && fail "a plain checkout was stamped as a disposable slot"
  pass "slot ownership claims never replace another owner or stamp a plain checkout"
}

test_exact_stamp_clear_accepts_canonical_home_alias() {
  local rec alias stamp
  rec=$(make_slot_world slot-canonical-clear)
  read_slot_world "$rec"
  alias="$WORLD/home-alias"
  ln -s "$WORLD/home" "$alias"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-e1-alias "$WORLD/home" \
    && fm_slot_stamp_clear_exact "$WT_DIR" task-e1-alias "$alias" ) \
    || fail "exact stamp clear rejected a canonical owner-home alias"
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$WT_DIR" task || printf 'none' )
  [ "$stamp" = none ] || fail "canonical owner-home alias stranded an exact stamp"
  pass "exact ownership cleanup compares canonical home identity"
}

test_clean_ownership_disposes() {
  local rec verdict
  rec=$(make_slot_world slot-clean)
  read_slot_world "$rec"
  fm_write_meta "$WORLD/home/state/task-e2.meta" \
    "window=firstmate:fm-task-e2" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  # A busy home is the normal case: another task holding a DIFFERENT slot must
  # not retain this one, or the gate would leak every lease it ever inspects.
  fm_write_meta "$WORLD/home/state/neighbour-e2.meta" \
    "window=firstmate:fm-neighbour-e2" "worktree=$OTHER_WT" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-e2 "$WORLD/home" )
  verdict=$(slot_verdict "$WORLD/home/state" task-e2 "$WT_DIR" "$WORLD/home")
  [ "$verdict" = dispose ] || fail "clean ownership did not dispose: $verdict"
  pass "a slot this task alone records and stamps disposes normally"
}

test_malformed_or_partial_stamp_retains() {
  local rec verdict stamp_path
  rec=$(make_slot_world slot-malformed)
  read_slot_world "$rec"
  stamp_path=$( . "$ROOT/bin/fm-slot-owner-lib.sh" && fm_slot_stamp_path "$WT_DIR" )
  printf 'task=task-malformed\n' > "$stamp_path"
  verdict=$(slot_verdict "$WORLD/home/state" task-malformed "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: slot ownership stamp is present but malformed"*) ;;
    *) fail "partial ownership stamp did not retain: $verdict" ;;
  esac
  printf 'task=\nhome=%s\n' "$WORLD/home" > "$stamp_path"
  verdict=$(slot_verdict "$WORLD/home/state" task-malformed "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: slot ownership stamp is present but malformed"*) ;;
    *) fail "empty ownership stamp field did not retain: $verdict" ;;
  esac
  printf 'task=task-malformed\nhome=%s\ntask=task-malformed\n' "$WORLD/home" > "$stamp_path"
  if ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-malformed "$WORLD/home" ); then
    fail "duplicate ownership stamp fields were accepted by claim validation"
  fi
  if ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$WT_DIR" task >/dev/null ); then
    fail "duplicate ownership stamp fields were accepted by field validation"
  fi
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_clear_exact "$WT_DIR" task-malformed "$WORLD/home" ) \
    || fail "malformed exact clear did not retain safely"
  [ -e "$stamp_path" ] || fail "malformed exact clear removed ambiguous ownership evidence"
  printf 'task=task-malformed\nhome=%s\nforeign=value\n' "$WORLD/home" > "$stamp_path"
  verdict=$(slot_verdict "$WORLD/home/state" task-malformed "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: slot ownership stamp is present but malformed"*) ;;
    *) fail "extra ownership stamp fields did not retain: $verdict" ;;
  esac
  pass "present malformed, duplicate, partial, and extra ownership fields retain their slots"
}

test_unavailable_occupant_evidence_retains() {
  local rec verdict
  rec=$(make_slot_world slot-unknown-occupants)
  read_slot_world "$rec"
  fm_write_meta "$WORLD/home/state/task-unknown.meta" \
    "window=firstmate:fm-task-unknown" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-unknown "$WORLD/home" )
  verdict=$(
    . "$ROOT/bin/fm-slot-owner-lib.sh"
    fm_slot_live_occupant_tasks() { return 2; }
    fm_slot_disposal_verdict "$WORLD/home/state" task-unknown "$WT_DIR" "$WORLD/home" "$WORLD/home" crewmate
  )
  case "$verdict" in
    "retain: authoritative live-occupant evidence is unavailable"*) ;;
    *) fail "unavailable occupant evidence did not retain: $verdict" ;;
  esac
  pass "unavailable authoritative occupant evidence retains the slot"
}

test_unclassified_live_process_retains() {
  local rec verdict
  require_procfs || { pass "skip: this host has no procfs for cwd failure proof"; return 0; }
  rec=$(make_slot_world slot-unclassified-process)
  read_slot_world "$rec"
  fm_write_meta "$WORLD/home/state/task-unclassified.meta" \
    "window=firstmate:fm-task-unclassified" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  verdict=$(
    . "$ROOT/bin/fm-slot-owner-lib.sh"
    fm_agent_proc_cwd() { return 1; }
    fm_slot_disposal_verdict "$WORLD/home/state" task-unclassified "$WT_DIR" \
      "$WORLD/home" "$WORLD/home" crewmate
  )
  [ "$verdict" = "retain: authoritative live-occupant evidence is unavailable" ] \
    || fail "an unclassified live process did not retain the slot: $verdict"
  pass "authoritative cwd failures retain the slot"
}

test_undeclared_in_slot_process_retains() {
  local rec verdict pid
  require_procfs || { pass "skip: this host has no readable procfs for undeclared occupant proof"; return 0; }
  rec=$(make_slot_world slot-undeclared-occupant)
  read_slot_world "$rec"
  fm_write_meta "$WORLD/home/state/task-undeclared.meta" \
    "window=firstmate:fm-task-undeclared" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  ( cd "$WT_DIR" \
    && env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME \
      FM_AGENT_TEST_RUN="$RUN_TAG" sleep 300 ) >/dev/null 2>&1 </dev/null &
  pid=$!
  BG_PIDS+=("$pid")
  for _ in $(seq 1 50); do
    [ "$(readlink "/proc/$pid/cwd" 2>/dev/null || true)" = "$WT_DIR" ] && break
    sleep 0.02
  done
  verdict=$(slot_verdict "$WORLD/home/state" task-undeclared "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: a live agent for task(s) unidentified-process-$pid is running in the slot"*) ;;
    *) fail "undeclared in-slot process did not retain: $verdict" ;;
  esac
  pass "an undeclared mixed-version process proven inside a slot retains it"
}

test_a_second_recorded_task_retains_the_slot() {
  local rec verdict
  rec=$(make_slot_world slot-shared)
  read_slot_world "$rec"
  fm_write_meta "$WORLD/home/state/task-e3.meta" \
    "window=firstmate:fm-task-e3" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  fm_write_meta "$WORLD/home/state/paused-e3.meta" \
    "window=firstmate:fm-paused-e3" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  verdict=$(slot_verdict "$WORLD/home/state" task-e3 "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: slot is also recorded by task(s) paused-e3"*) : ;;
    *) fail "a slot recorded by a second task did not retain: $verdict" ;;
  esac
  pass "a slot still recorded by another task - live, paused, or quarantined - retains its lease"
}

test_a_stamp_naming_another_task_retains_the_slot() {
  local rec verdict
  rec=$(make_slot_world slot-stale)
  read_slot_world "$rec"
  fm_write_meta "$WORLD/home/state/task-e4.meta" \
    "window=firstmate:fm-task-e4" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" reissued-e4 "$WORLD/home" )
  verdict=$(slot_verdict "$WORLD/home/state" task-e4 "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: slot ownership stamp names task reissued-e4"*) : ;;
    *) fail "stale metadata pointing at a reissued slot did not retain: $verdict" ;;
  esac
  pass "metadata pointing at a slot that was reissued is recognized as stale and retains the lease"
}

test_a_live_agent_of_another_task_retains_the_slot() {
  local rec verdict occupant
  require_procfs || { pass "skip: this host has no readable procfs for occupancy proof"; return 0; }
  rec=$(make_slot_world slot-occupied)
  read_slot_world "$rec"
  occupant="occupant-e5-$RUN_TAG"
  fm_write_meta "$WORLD/home/state/task-e5.meta" \
    "window=firstmate:fm-task-e5" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  start_declared_agent "$WT_DIR" "$occupant" "$WORLD/home" >/dev/null
  verdict=$(slot_verdict "$WORLD/home/state" task-e5 "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: a live agent for task(s) $occupant"*) : ;;
    *) fail "a slot occupied by another task's live agent did not retain: $verdict" ;;
  esac
  pass "a slot occupied by another task's live agent retains its lease"
}

test_same_task_in_another_home_or_role_retains_the_slot() {
  local rec verdict id
  require_procfs || { pass "skip: this host has no readable procfs for identity occupancy proof"; return 0; }
  rec=$(make_slot_world slot-same-task-foreign-identity)
  read_slot_world "$rec"
  id="same-task-e9-$RUN_TAG"
  start_declared_agent "$WT_DIR" "$id" "$WORLD/other-home" crewmate >/dev/null
  verdict=$(slot_verdict "$WORLD/home/state" "$id" "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: a live agent for task(s) $id"*) ;;
    *) fail "same task in another home did not retain the slot: $verdict" ;;
  esac
  rec=$(make_slot_world slot-same-task-foreign-role)
  read_slot_world "$rec"
  id="same-task-role-e9-$RUN_TAG"
  start_declared_agent "$WT_DIR" "$id" "$WORLD/home" secondmate >/dev/null
  verdict=$(slot_verdict "$WORLD/home/state" "$id" "$WT_DIR" "$WORLD/home" crewmate)
  case "$verdict" in
    "retain: a live agent for task(s) $id"*) ;;
    *) fail "same task and home with another role did not retain the slot: $verdict" ;;
  esac
  pass "live slot occupancy excludes only the exact task, home, and role identity"
}

test_a_relinquished_slot_is_releasable_by_its_remaining_holder() {
  # The exact reported leak sequence. B is the stamped true owner and paused A's
  # stale metadata also names the slot, so B retains and its own metadata goes.
  # If B's stamp outlived it, A's later teardown would retain on the stamp with
  # nothing left referencing the slot, and the pool would lose it forever.
  local rec verdict stamp
  rec=$(make_slot_world slot-relinquish)
  read_slot_world "$rec"
  fm_write_meta "$WORLD/home/state/owner-e7.meta" \
    "window=firstmate:fm-owner-e7" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  fm_write_meta "$WORLD/home/state/paused-e7.meta" \
    "window=firstmate:fm-paused-e7" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" owner-e7 "$WORLD/home" )

  verdict=$(slot_verdict "$WORLD/home/state" owner-e7 "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: slot is also recorded by task(s) paused-e7"*) : ;;
    *) fail "the stamped owner did not retain against the paused task's record: $verdict" ;;
  esac
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_relinquish "$WT_DIR" owner-e7 "$WORLD/home" "$verdict" )
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$WT_DIR" task || printf 'none' )
  [ "$stamp" = none ] \
    || fail "the retiring owner's own stamp outlived it and still names $stamp"
  rm -f "$WORLD/home/state/owner-e7.meta"

  verdict=$(slot_verdict "$WORLD/home/state" paused-e7 "$WT_DIR" "$WORLD/home")
  [ "$verdict" = dispose ] \
    || fail "the last holder could not release a slot nothing else references: $verdict"
  pass "a retiring owner gives up its own stamp so the remaining holder can still release the slot"
}

test_a_stamp_naming_another_task_survives_a_retain_and_still_blocks() {
  # The complementary case, and the reason the clear above is narrow. Here the
  # stamp names a THIRD task, so it is positive evidence the slot was reissued.
  # Clearing it would let the stale task dispose of a slot whose real occupant
  # merely has no live process right now - destroying preserved work.
  local rec verdict stamp
  rec=$(make_slot_world slot-preserve)
  read_slot_world "$rec"
  fm_write_meta "$WORLD/home/state/stale-e8.meta" \
    "window=firstmate:fm-stale-e8" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  fm_write_meta "$WORLD/home/state/other-e8.meta" \
    "window=firstmate:fm-other-e8" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" reissued-e8 "$WORLD/home" )

  verdict=$(slot_verdict "$WORLD/home/state" stale-e8 "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: slot is also recorded by task(s) other-e8"*) : ;;
    *) fail "the metadata conflict was not the retain reason under test: $verdict" ;;
  esac
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_relinquish "$WT_DIR" stale-e8 "$WORLD/home" "$verdict" )
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$WT_DIR" task || printf 'none' )
  [ "$stamp" = reissued-e8 ] \
    || fail "a stamp naming another task was cleared on retain: $stamp"
  rm -f "$WORLD/home/state/stale-e8.meta" "$WORLD/home/state/other-e8.meta"

  verdict=$(slot_verdict "$WORLD/home/state" stale-e8 "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: slot ownership stamp names task reissued-e8"*) : ;;
    *) fail "a preserved stamp stopped blocking disposal for a stale task: $verdict" ;;
  esac
  pass "a stamp naming another task survives a retain and still blocks that slot's disposal"
}

test_same_task_stamp_in_another_home_survives_relinquish() {
  local rec verdict stamp_home
  rec=$(make_slot_world slot-same-task-foreign-home)
  read_slot_world "$rec"
  mkdir -p "$WORLD/foreign-home"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" shared-e10 "$WORLD/foreign-home" ) \
    || fail "could not stamp the foreign-home same-task fixture"
  verdict="retain: slot is also recorded by task(s) paused-e10 in this home"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_relinquish "$WT_DIR" shared-e10 "$WORLD/home" "$verdict" )
  stamp_home=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$WT_DIR" home || printf 'none' )
  [ "$stamp_home" = "$WORLD/foreign-home" ] \
    || fail "same task id from another home cleared the foreign ownership stamp: $stamp_home"
  pass "relinquish clears only the exact task and canonical owner-home claim"
}

test_teardown_retires_a_contested_lease_even_with_force() {
  local rec fakebin out status stamp
  rec=$(make_slot_world slot-teardown)
  read_slot_world "$rec"
  fakebin=$(fm_fakebin "$WORLD/fake")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_TREEHOUSE_LOG"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" tmux gh-axi gh
  : > "$WORLD/treehouse.log"
  fm_write_meta "$WORLD/home/state/task-e6.meta" \
    "window=firstmate:fm-task-e6" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off"
  fm_write_meta "$WORLD/home/state/quarantined-e6.meta" \
    "window=firstmate:fm-quarantined-e6" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-e6 "$WORLD/home" ) \
    || fail "the contested-slot fixture could not be stamped"

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD/home" \
    FM_STATE_OVERRIDE="$WORLD/home/state" FM_DATA_OVERRIDE="$WORLD/home/data" \
    FM_CONFIG_OVERRIDE="$WORLD/home/config" \
    FM_FAKE_TREEHOUSE_LOG="$WORLD/treehouse.log" \
    PATH="$fakebin:$PATH" \
    "$TEARDOWN" task-e6 --force 2>&1)
  status=$?
  expect_code 0 "$status" "teardown should complete while retiring the contested lease"$'\n'"$out"
  assert_contains "$out" "lease RETAINED" "teardown did not report the retained lease"
  assert_contains "$out" "quarantined-e6" "teardown did not name the other holder"
  assert_contains "$out" "retained on disk" "the completion line did not report the retained slot"
  [ ! -s "$WORLD/treehouse.log" ] \
    || fail "teardown returned a contested slot to the pool: $(cat "$WORLD/treehouse.log")"
  assert_present "$WT_DIR" "teardown removed a contested worktree"
  [ "$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)" = "slot-slot-teardown" ] \
    || fail "teardown moved a contested worktree off its branch"
  assert_absent "$WORLD/home/state/task-e6.meta" "teardown did not clear its own records"
  assert_present "$WORLD/home/state/quarantined-e6.meta" "teardown cleared the other holder's record"
  # This path DID complete and delete its own records, so its stamp must not
  # outlive it, or the slot could never be released again.
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$WT_DIR" task || printf 'none' )
  [ "$stamp" = none ] \
    || fail "a completed teardown left its own ownership stamp behind: $stamp"
  pass "teardown retires a contested lease, leaves the slot untouched, and --force does not waive it"
}

test_retained_stamp_survives_failed_metadata_retirement() {
  local rec fakebin out status stamp git_dir
  rec=$(make_slot_world slot-retain-failure)
  read_slot_world "$rec"
  fakebin=$(fm_fakebin "$WORLD/fake")
  fm_fake_exit0 "$fakebin" tmux gh-axi gh treehouse
  fm_write_meta "$WORLD/home/state/task-e11.meta" \
    "window=firstmate:fm-task-e11" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=scout" "mode=direct-PR" "yolo=off"
  fm_write_meta "$WORLD/home/state/paused-e11.meta" \
    "window=firstmate:fm-paused-e11" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-e11 "$WORLD/home" ) \
    || fail "failed-retirement fixture could not be stamped"
  git_dir=$(git -C "$WT_DIR" rev-parse --path-format=absolute --git-common-dir)
  git --git-dir="$git_dir" update-ref refs/firstmate/direct-pr/task-e11/base HEAD
  mkdir -p "$git_dir/refs/firstmate/direct-pr/task-e11/base.lock"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD/home" \
    FM_STATE_OVERRIDE="$WORLD/home/state" FM_DATA_OVERRIDE="$WORLD/home/data" \
    FM_CONFIG_OVERRIDE="$WORLD/home/config" PATH="$fakebin:$PATH" \
    "$TEARDOWN" task-e11 --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "metadata-retirement failure unexpectedly completed"$'\n'"$out"
  assert_present "$WORLD/home/state/task-e11.meta" "failed metadata retirement removed task metadata"
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$WT_DIR" task || printf 'none' )
  [ "$stamp" = task-e11 ] \
    || fail "failed metadata retirement cleared ownership evidence: $stamp"
  pass "retained ownership evidence survives incomplete lifecycle metadata retirement"
}

test_stamp_survives_failed_pool_return() {
  local rec fakebin out status stamp branch
  rec=$(make_slot_world slot-return-failure)
  read_slot_world "$rec"
  fakebin=$(fm_fakebin "$WORLD/fake")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
target=${3:-}
git_dir=$(git -C "$target" rev-parse --absolute-git-dir)
[ ! -e "$git_dir/fm-slot-owner" ] || exit 19
common_dir=$(git -C "$target" rev-parse --git-common-dir)
case "$common_dir" in /*) ;; *) common_dir="$target/$common_dir" ;; esac
claim="$common_dir/fm-slot-return-claims/${git_dir##*/}.claim"
[ -f "$claim" ] || exit 20
grep -Fx 'task=task-e12' "$claim" >/dev/null || exit 21
grep -Fx 'lease_holder=task-e12' "$claim" >/dev/null || exit 22
exit 17
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" tmux gh-axi gh
  fm_write_meta "$WORLD/home/state/task-e12.meta" \
    "window=firstmate:fm-task-e12" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-e12 "$WORLD/home" ) \
    || fail "failed-return fixture could not be stamped"
  branch=$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)
  mkdir -p "$WT_DIR/.claude" "$WT_DIR/.opencode/plugins"
  printf '{}\n' > "$WT_DIR/.claude/settings.local.json"
  printf 'hook\n' > "$WT_DIR/.opencode/plugins/fm-turn-end.js"
  printf 'hook\n' > "$WT_DIR/.fm-grok-turnend"

  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD/home" \
    FM_STATE_OVERRIDE="$WORLD/home/state" FM_DATA_OVERRIDE="$WORLD/home/data" \
    FM_CONFIG_OVERRIDE="$WORLD/home/config" PATH="$fakebin:$PATH" \
    "$TEARDOWN" task-e12 --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "failed pool return unexpectedly completed"$'\n'"$out"
  assert_present "$WORLD/home/state/task-e12.meta" "failed pool return removed task metadata"
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_return_claim_record "$WT_DIR" \
    && printf '%s' "$FM_SLOT_RETURN_CLAIM_TASK" || printf 'none' )
  [ "$stamp" = task-e12 ] || fail "failed pool return cleared transition evidence: $stamp"
  [ -L "$(git -C "$WT_DIR" rev-parse --absolute-git-dir)/fm-slot-owner" ] \
    || fail "failed pool return did not leave mixed-version refusal evidence"
  [ "$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)" = "$branch" ] \
    || fail "failed pool return changed the retry branch identity"
  assert_present "$WT_DIR/.claude/settings.local.json" "failed pool return removed the Claude hook"
  assert_present "$WT_DIR/.opencode/plugins/fm-turn-end.js" "failed pool return removed the OpenCode hook"
  assert_present "$WT_DIR/.fm-grok-turnend" "failed pool return removed the Grok hook"
  pass "ownership evidence survives until pooled return succeeds"
}

test_successful_pool_return_never_mutates_reused_slot() {
  local rec fakebin out status stamp
  rec=$(make_slot_world slot-post-return-reuse)
  read_slot_world "$rec"
  fakebin=$(fm_fakebin "$WORLD/fake")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
target=${3:-}
git_dir=$(git -C "$target" rev-parse --absolute-git-dir)
[ ! -e "$git_dir/fm-slot-owner" ] || exit 19
common_dir=$(git -C "$target" rev-parse --git-common-dir)
case "$common_dir" in /*) ;; *) common_dir="$target/$common_dir" ;; esac
claim="$common_dir/fm-slot-return-claims/${git_dir##*/}.claim"
[ -f "$claim" ] || exit 20
grep -Fx 'task=task-reuse' "$claim" >/dev/null || exit 21
grep -Fx 'lease_holder=task-reuse' "$claim" >/dev/null || exit 22
git -C "$FM_REUSE_PROJECT" worktree remove --force "$target"
git -C "$FM_REUSE_PROJECT" worktree add --quiet -b replacement-owner "$target"
mkdir -p "$target/.claude" "$target/.opencode/plugins"
printf 'replacement\n' > "$target/.claude/settings.local.json"
printf 'replacement\n' > "$target/.opencode/plugins/fm-turn-end.js"
printf 'replacement\n' > "$target/.fm-grok-turnend"
git_dir=$(git -C "$target" rev-parse --absolute-git-dir)
printf 'task=replacement\nhome=%s\n' "$FM_REUSE_HOME" > "$git_dir/fm-slot-owner"
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" tmux gh-axi gh
  fm_write_meta "$WORLD/home/state/task-reuse.meta" \
    "window=firstmate:fm-task-reuse" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-reuse "$WORLD/home" )
  set +e
  out=$(cd "$WORLD" && env -u NO_MISTAKES_GATE FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD/home" \
    FM_STATE_OVERRIDE="$WORLD/home/state" FM_DATA_OVERRIDE="$WORLD/home/data" \
    FM_CONFIG_OVERRIDE="$WORLD/home/config" FM_REUSE_PROJECT="$PROJ_DIR" \
    FM_REUSE_HOME="$WORLD/replacement-home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" task-reuse --force 2>&1)
  status=$?
  set -e
  expect_code 0 "$status" "teardown failed after the pool reused its returned slot"$'\n'"$out"
  [ "$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)" = replacement-owner ] \
    || fail "teardown changed the replacement owner's branch after return"
  assert_present "$WT_DIR/.claude/settings.local.json" "teardown removed the replacement Claude hook"
  assert_present "$WT_DIR/.opencode/plugins/fm-turn-end.js" "teardown removed the replacement OpenCode hook"
  assert_present "$WT_DIR/.fm-grok-turnend" "teardown removed the replacement Grok hook"
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$WT_DIR" task || printf none )
  [ "$stamp" = replacement ] || fail "teardown cleared replacement ownership after return: $stamp"
  pass "successful pool return never mutates a slot after reuse"
}

test_ordinary_teardown_acquires_admission_before_task_lock() {
  local rec fakebin ready holder out status stamp
  rec=$(make_slot_world slot-lock-order)
  read_slot_world "$rec"
  fakebin=$(fm_fakebin "$WORLD/fake")
  fm_fake_exit0 "$fakebin" tmux gh-axi gh treehouse
  ready="$WORLD/locks.ready"
  fm_write_meta "$WORLD/home/state/task-e13.meta" \
    "window=firstmate:fm-task-e13" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-e13 "$WORLD/home" ) \
    || fail "lock-order fixture could not be stamped"
  (
    exec env FM_STATE_OVERRIDE="$WORLD/home/state" bash -c '
      . "$1/bin/fm-wake-lib.sh"
      admission=$(fm_spawn_admission_lock_path "$STATE")
      mkdir -p "$(dirname "$admission")"
      fm_lock_try_acquire "$admission" || exit 1
      fm_lock_try_acquire "$STATE/.spawn-task-e13.lock" || exit 1
      : > "$2"
      cleanup() {
        trap - EXIT TERM INT
        fm_lock_release "$STATE/.spawn-task-e13.lock"
        fm_lock_release "$admission"
        exit 0
      }
      trap cleanup EXIT TERM INT
      while :; do sleep 1; done
    ' _ "$ROOT" "$ready"
  ) >/dev/null 2>&1 &
  holder=$!
  for _ in $(seq 1 50); do
    [ -e "$ready" ] && break
    sleep 0.02
  done
  [ -e "$ready" ] || fail "lock-order holder did not start"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD/home" \
    FM_STATE_OVERRIDE="$WORLD/home/state" FM_DATA_OVERRIDE="$WORLD/home/data" \
    FM_CONFIG_OVERRIDE="$WORLD/home/config" PATH="$fakebin:$PATH" \
    "$TEARDOWN" task-e13 --force 2>&1)
  status=$?
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$status" -ne 0 ] || fail "ordinary teardown crossed active spawn admission"$'\n'"$out"
  assert_contains "$out" "spawn is already publishing work in $WORLD/home/state" \
    "ordinary teardown checked its task lock before home admission"
  assert_present "$WORLD/home/state/task-e13.meta" "admission refusal removed task metadata"
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$WT_DIR" task || printf 'none' )
  [ "$stamp" = task-e13 ] || fail "admission refusal cleared ownership evidence"
  pass "ordinary teardown acquires home admission before its task lock"
}

test_ordinary_teardown_refuses_ambiguous_disposal_before_mutation() {
  local rec fakebin out status stamp log
  rec=$(make_slot_world slot-ambiguous-disposal)
  read_slot_world "$rec"
  fakebin=$(fm_fakebin "$WORLD/fake")
  log="$WORLD/tmux.log"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" gh-axi gh
  mkdir -p "$WORLD/corrupt-project"
  fm_write_meta "$WORLD/home/state/task-e14.meta" \
    "window=firstmate:fm-task-e14" "worktree=$WT_DIR" \
    "project=$WORLD/corrupt-project" "harness=claude" "kind=scout" \
    "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-e14 "$WORLD/home" ) \
    || fail "ambiguous-disposal fixture could not be stamped"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD/home" \
    FM_STATE_OVERRIDE="$WORLD/home/state" FM_DATA_OVERRIDE="$WORLD/home/data" \
    FM_CONFIG_OVERRIDE="$WORLD/home/config" PATH="$fakebin:/usr/bin:/bin" \
    "$TEARDOWN" task-e14 --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "ordinary teardown accepted ambiguous disposal classification"
  assert_contains "$out" "unknown git worktree registration" \
    "ambiguous disposal refusal lost its classification"
  [ ! -s "$log" ] || fail "ambiguous disposal preflight closed the endpoint"
  assert_present "$WORLD/home/state/task-e14.meta" \
    "ambiguous disposal preflight removed task metadata"
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$WT_DIR" task || printf 'none' )
  [ "$stamp" = task-e14 ] || fail "ambiguous disposal preflight changed ownership evidence"
  pass "ordinary teardown refuses ambiguous disposal before lifecycle mutation"
}

# --- F. restore-time re-assertion -------------------------------------------

make_sweep_home() {
  local name=$1 world
  world="$TMP_ROOT/$name"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config"
  fm_git_worktree "$world/project" "$world/wt" "sweep-$name"
  printf '%s\n' "$world"
}

run_sweep() {  # <world>
  FM_ROOT_OVERRIDE="$1/project" FM_HOME="$1/home" \
    FM_STATE_OVERRIDE="$1/home/state" "$SWEEP" 2>&1
}

test_sweep_reports_a_worktree_that_collapsed_onto_the_primary_checkout() {
  local world out id
  require_procfs || { pass "skip: this host has no readable procfs for the resume sweep"; return 0; }
  world=$(make_sweep_home sweep-collapsed)
  id="task-f1-$RUN_TAG"
  fm_write_meta "$world/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$world/wt" "project=$world/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  start_declared_agent "$world/project" "$id" "$world/home" >/dev/null
  out=$(run_sweep "$world")
  assert_contains "$out" "ISOLATION: task $id collapsed onto the primary checkout" \
    "the resume sweep did not report a collapsed worktree"
  pass "the resume sweep re-asserts isolation and reports a worktree that collapsed onto the primary checkout"
}

test_sweep_is_silent_for_a_correctly_isolated_worker() {
  local world out id
  require_procfs || { pass "skip: this host has no readable procfs for the resume sweep"; return 0; }
  world=$(make_sweep_home sweep-isolated)
  id="task-f2-$RUN_TAG"
  fm_write_meta "$world/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$world/wt" "project=$world/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  start_declared_agent "$world/wt" "$id" "$world/home" >/dev/null
  # Captured with stderr folded in: the sweep scans every process on the host,
  # and a /proc entry it may not read must stay silent rather than surfacing a
  # permission error as if it were a finding.
  out=$(run_sweep "$world")
  [ -z "$out" ] || fail "the resume sweep reported a correctly isolated worker: $out"
  pass "the resume sweep stays silent for a worker that is genuinely in its worktree"
}

test_sweep_never_promotes_a_pane_path_to_evidence() {
  local world out
  world=$(make_sweep_home sweep-hint)
  fm_write_meta "$world/home/state/task-f3.meta" \
    "window=firstmate:fm-task-f3" "worktree=$world/wt" "project=$world/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  out=$(run_sweep "$world")
  assert_contains "$out" "ISOLATION: task task-f3 is unproven" \
    "an unprovable task did not produce an actionable isolation finding"
  out=$(FM_ISOLATION_VERBOSE=1 run_sweep "$world")
  assert_contains "$out" "ISOLATION: task task-f3 is unproven" \
    "verbose mode hid the required isolation finding"
  pass "an unprovable task produces an actionable finding without trusting its pane path"
}

test_sweep_reports_corrupt_scope_metadata() {
  local world out
  world=$(make_sweep_home sweep-corrupt-scope)
  fm_write_meta "$world/home/state/task-corrupt.meta" \
    "window=firstmate:fm-task-corrupt" "worktree=" "project=$world/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  out=$(run_sweep "$world")
  assert_contains "$out" "ISOLATION: task task-corrupt has corrupt scope metadata" \
    "empty worktree metadata was silently skipped"
  fm_write_meta "$world/home/state/task-corrupt.meta" \
    "window=firstmate:fm-task-corrupt" "worktree=$world/wt" "worktree=$world/project" \
    "project=$world/project" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  out=$(run_sweep "$world")
  assert_contains "$out" "worktree must appear exactly once" \
    "duplicate worktree metadata was silently accepted"
  fm_write_meta "$world/home/state/task-corrupt.meta" \
    "window=firstmate:fm-task-corrupt" "worktree=$world/wt" "project=$world/project" \
    "harness=claude" "kind=secondmate" "mode=secondmate" "yolo=off" "home="
  out=$(run_sweep "$world")
  assert_contains "$out" "home must be one non-empty absolute path" \
    "empty secondmate home metadata was silently skipped"
  pass "the isolation sweep reports corrupt worktree and secondmate-home scope metadata"
}

test_sweep_reports_an_agent_declared_for_another_home() {
  local world out id
  require_procfs || { pass "skip: this host has no readable procfs for the resume sweep"; return 0; }
  world=$(make_sweep_home sweep-foreign)
  id="task-f4-$RUN_TAG"
  fm_write_meta "$world/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$world/wt" "project=$world/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  mkdir -p "$world/other-home"
  start_declared_agent "$world/wt" "$id" "$world/other-home" >/dev/null
  out=$(run_sweep "$world")
  assert_contains "$out" "ISOLATION: task $id has conflicting worker identity" \
    "the resume sweep did not report an agent declared for another home"
  pass "the resume sweep reports an agent that declares another home as its owner"
}

test_sweep_ignores_an_unrelated_complete_identity_with_the_same_task_id() {
  local world out id unrelated
  require_procfs || { pass "skip: this host has no readable procfs for same-id isolation proof"; return 0; }
  world=$(make_sweep_home sweep-unrelated-same-id)
  unrelated="$world/unrelated"
  mkdir -p "$unrelated" "$world/other-home"
  id="task-f9-$RUN_TAG"
  fm_write_meta "$world/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$world/wt" "project=$world/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  start_declared_agent "$unrelated" "$id" "$world/other-home" secondmate >/dev/null
  out=$(run_sweep "$world")
  assert_contains "$out" "ISOLATION: task $id is unproven" \
    "an unrelated complete identity suppressed the task's unproven finding"
  out=$(FM_ISOLATION_VERBOSE=1 run_sweep "$world")
  assert_contains "$out" "ISOLATION: task $id is unproven" \
    "an unrelated same-id identity suppressed conservative provider fallback"
  pass "the resume sweep preserves complete identity and ignores unrelated same-id agents"
}

test_spawn_claim_abort_clears_only_a_new_exact_claim() {
  local rec id out status home_real stamp
  id="claim-abort-g1-$RUN_TAG"
  rec=$(make_launch_case claim-abort "$id")
  read_launch_record "$rec"
  cat > "$FAKEBIN_DIR/mktemp" <<'SH'
#!/usr/bin/env bash
case "$*" in *".meta."*) exit 1 ;; esac
exec /usr/bin/mktemp "$@"
SH
  chmod +x "$FAKEBIN_DIR/mktemp"
  : > "$CASE_DIR/kill.log"
  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_TMUX_STATE="$CASE_DIR/tmux-window-name" FM_FAKE_KILL_LOG="$CASE_DIR/kill.log" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness claude 2>&1)
  status=$?
  set -e
  expect_code 1 "$status" "spawn should abort when metadata publication cannot start"
  if stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" && fm_slot_stamp_field "$WT_DIR" task 2>/dev/null); then
    fail "an aborted spawn left its newly-created claim behind: $stamp"
  fi
  assert_grep 'kill-window' "$CASE_DIR/kill.log" "aborted spawn did not close its new endpoint"

  home_real=$(cd "$HOME_DIR" && pwd -P)
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" && fm_slot_stamp_write "$WT_DIR" "$id" "$home_real" ) \
    || fail "could not install the preexisting exact claim fixture"
  : > "$CASE_DIR/kill.log"
  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_TMUX_STATE="$CASE_DIR/tmux-window-name" FM_FAKE_KILL_LOG="$CASE_DIR/kill.log" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness claude 2>&1)
  status=$?
  set -e
  expect_code 1 "$status" "idempotent-claim spawn should reach the metadata abort"
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" && fm_slot_stamp_field "$WT_DIR" task )
  [ "$stamp" = "$id" ] || fail "abort cleared a preexisting idempotent claim"
  pass "spawn abort clears only a claim newly created by that invocation"
}

test_spawn_refuses_a_foreign_claim_before_slot_mutation() {
  local rec id out status stamp exclude
  id="foreign-claim-g2-$RUN_TAG"
  rec=$(make_launch_case foreign-claim "$id")
  read_launch_record "$rec"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" foreign-g2 "$CASE_DIR/foreign-home" ) \
    || fail "could not install foreign claim fixture"
  : > "$CASE_DIR/kill.log"
  set +e
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_TMUX_STATE="$CASE_DIR/tmux-window-name" FM_FAKE_KILL_LOG="$CASE_DIR/kill.log" \
    FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --harness claude 2>&1)
  status=$?
  set -e
  expect_code 1 "$status" "spawn must refuse a foreign slot claim"
  assert_contains "$out" "could not claim pooled-slot ownership" "foreign claim refusal lost its reason"
  [ ! -e "$WT_DIR/.claude/settings.local.json" ] || fail "spawn mutated hooks before refusing the foreign claim"
  exclude=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  ! grep -qxF '.claude/settings.local.json' "$exclude" 2>/dev/null \
    || fail "spawn mutated the slot exclude file before refusing the foreign claim"
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" && fm_slot_stamp_field "$WT_DIR" task )
  [ "$stamp" = foreign-g2 ] || fail "foreign claim was cleared or replaced"
  assert_grep 'kill-window' "$CASE_DIR/kill.log" "foreign claim refusal did not close the new endpoint"
  pass "spawn claims immediately and a foreign owner leaves the contested slot untouched"
}

test_sweep_is_silent_for_a_healthy_secondmate() {
  # A secondmate is deliberately launched declaring its OWN home while its
  # record lives in the launching primary's state directory. Judging that
  # declaration against the sweeping home would print an actionable, wrong
  # "stop this worker" line on every session start in any fleet that has one.
  local world out id sub_home
  require_procfs || { pass "skip: this host has no readable procfs for the resume sweep"; return 0; }
  world=$(make_sweep_home sweep-secondmate)
  id="dom-f5-$RUN_TAG"
  sub_home="$world/secondmate-home"
  mkdir -p "$sub_home/state"
  fm_write_secondmate_meta "$world/home/state/$id.meta" "$sub_home" "firstmate:fm-$id"
  start_declared_agent "$sub_home" "$id" "$sub_home" secondmate >/dev/null
  out=$(run_sweep "$world")
  [ -z "$out" ] || fail "the resume sweep reported a healthy live secondmate: $out"
  pass "the resume sweep stays silent for a secondmate that declares its own home"
}

test_sweep_still_reports_a_secondmate_running_for_a_foreign_home() {
  local world out id sub_home
  require_procfs || { pass "skip: this host has no readable procfs for the resume sweep"; return 0; }
  world=$(make_sweep_home sweep-secondmate-foreign)
  id="dom-f6-$RUN_TAG"
  sub_home="$world/secondmate-home"
  mkdir -p "$sub_home/state" "$world/other-home"
  fm_write_secondmate_meta "$world/home/state/$id.meta" "$sub_home" "firstmate:fm-$id"
  start_declared_agent "$sub_home" "$id" "$world/other-home" secondmate >/dev/null
  out=$(run_sweep "$world")
  assert_contains "$out" "ISOLATION: task $id has conflicting worker identity" \
    "the resume sweep excused a secondmate declaring a home its record does not name"
  pass "the resume sweep still reports a secondmate whose declared home is not the one it owns"
}

test_sweep_reports_a_worker_declared_with_the_wrong_role() {
  local world out id
  require_procfs || { pass "skip: this host has no readable procfs for wrong-role proof"; return 0; }
  world=$(make_sweep_home sweep-wrong-role)
  id="task-f8-$RUN_TAG"
  fm_write_meta "$world/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$world/wt" "project=$world/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  start_declared_agent "$world/wt" "$id" "$world/home" secondmate >/dev/null
  out=$(run_sweep "$world")
  assert_contains "$out" "ISOLATION: task $id has conflicting worker identity" \
    "the sweep did not report a worker whose role conflicts with its task record"
  assert_contains "$out" "role=secondmate" \
    "the wrong-role finding did not report the declared role"
  pass "the resume sweep reports a task declaration with the wrong role"
}

test_sweep_evaluates_every_matching_root_process() {
  local world out id
  require_procfs || { pass "skip: this host has no readable procfs for duplicate-root proof"; return 0; }
  world=$(make_sweep_home sweep-duplicate-roots)
  id="task-f7-$RUN_TAG"
  fm_write_meta "$world/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$world/wt" "project=$world/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  start_declared_agent "$world/wt" "$id" "$world/home" >/dev/null
  start_declared_agent "$world/project" "$id" "$world/home" >/dev/null
  out=$(run_sweep "$world")
  assert_contains "$out" "ISOLATION: task $id collapsed onto the primary checkout" \
    "the sweep hid a collapsed duplicate root behind the healthy root"
  pass "the resume sweep evaluates every root process for the complete worker identity"
}

test_crewmate_declaration_clears_every_inherited_home
test_secondmate_declaration_pins_only_its_own_home
test_declaration_refuses_rather_than_emitting_a_partial_prefix
test_every_verified_harness_launches_with_its_home_declaration
test_secondmate_child_receives_only_its_own_home
test_declared_worker_is_never_a_primary_scope_match
test_project_local_startup_adapter_stays_inert_for_a_worker
test_worker_cannot_take_the_session_owner_record
test_worker_cannot_spawn_or_tear_down
test_worker_cannot_run_direct_primary_mutators
test_secondmate_primary_operations_require_its_declared_home
test_proc_cwd_is_read_from_the_live_process
test_declared_agent_lookup_returns_the_root_most_process
test_provider_process_id_matrix_is_explicit
test_tmux_pane_pid_comes_from_the_stable_window_id
test_a_lost_window_name_never_answers_with_firstmates_own_pane
test_one_proc_walk_answers_every_task_in_a_sweep
test_spawn_settles_on_proc_evidence_over_a_lying_pane_path
test_slot_stamp_records_ownership_and_never_stamps_a_plain_checkout
test_exact_stamp_clear_accepts_canonical_home_alias
test_clean_ownership_disposes
test_malformed_or_partial_stamp_retains
test_unavailable_occupant_evidence_retains
test_unclassified_live_process_retains
test_undeclared_in_slot_process_retains
test_a_second_recorded_task_retains_the_slot
test_a_stamp_naming_another_task_retains_the_slot
test_a_live_agent_of_another_task_retains_the_slot
test_same_task_in_another_home_or_role_retains_the_slot
test_a_relinquished_slot_is_releasable_by_its_remaining_holder
test_a_stamp_naming_another_task_survives_a_retain_and_still_blocks
test_same_task_stamp_in_another_home_survives_relinquish
test_teardown_retires_a_contested_lease_even_with_force
test_retained_stamp_survives_failed_metadata_retirement
test_stamp_survives_failed_pool_return
test_successful_pool_return_never_mutates_reused_slot
test_ordinary_teardown_acquires_admission_before_task_lock
test_ordinary_teardown_refuses_ambiguous_disposal_before_mutation
test_sweep_reports_a_worktree_that_collapsed_onto_the_primary_checkout
test_sweep_is_silent_for_a_correctly_isolated_worker
test_sweep_never_promotes_a_pane_path_to_evidence
test_sweep_reports_corrupt_scope_metadata
test_sweep_reports_an_agent_declared_for_another_home
test_sweep_ignores_an_unrelated_complete_identity_with_the_same_task_id
test_sweep_is_silent_for_a_healthy_secondmate
test_sweep_still_reports_a_secondmate_running_for_a_foreign_home
test_sweep_evaluates_every_matching_root_process
test_sweep_reports_a_worker_declared_with_the_wrong_role
test_spawn_claim_abort_clears_only_a_new_exact_claim
test_spawn_refuses_a_foreign_claim_before_slot_mutation

echo "# all fm-worker-isolation tests passed"
