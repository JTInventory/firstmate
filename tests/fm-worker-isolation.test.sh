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
# Every harness in FM_HARNESS_RE is driven end to end here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
LOCK="$ROOT/bin/fm-lock.sh"
AUTHORITY_EXEC="$ROOT/bin/fm-session-authority-exec.sh"
SWEEP="$ROOT/bin/fm-isolation-sweep.sh"
NUDGE="$ROOT/bin/fm-sessionstart-nudge.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-isolation)
fm_test_session_authority_fd "$TMP_ROOT"
unset NO_MISTAKES_GATE
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT
CODEX_THREAD_ID=fm-worker-isolation-fixture
export CODEX_THREAD_ID

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
  [ "$prefix" = "exec $FM_SESSION_AUTHORITY_FD>&-; FM_HOME= FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_LIFECYCLE_HOME= FM_LIFECYCLE_STATE= FM_LIFECYCLE_SCRIPT= FM_LOCK_PROCESS_TOKEN= FM_SESSION_AUTHORITY_FD= FM_SESSION_AUTHORITY_BROKER_PID= FM_SESSION_AUTHORITY_BROKER_START= FM_SESSION_AUTHORITY_BROKER_IDENTITY= FM_SESSION_AUTHORITY_BROKER_SCRIPT= FM_AGENT_ROLE=crewmate FM_AGENT_TASK='task-a1' FM_AGENT_OWNER_HOME='/home/cap/firstmate' " ] \
    || fail "crewmate declaration changed: $prefix"
  pass "a crewmate declaration clears every operational-home variable and names its owner"
}

test_secondmate_declaration_pins_only_its_own_home() {
  local prefix
  prefix=$( . "$ROOT/bin/fm-worker-isolation-lib.sh" \
    && fm_worker_launch_env_prefix secondmate dom-b2 /home/cap/homes/dom )
  [ "$prefix" = "FM_HOME='/home/cap/homes/dom' FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_LIFECYCLE_HOME= FM_LIFECYCLE_STATE= FM_LIFECYCLE_SCRIPT= FM_LOCK_PROCESS_TOKEN= FM_AGENT_ROLE=secondmate FM_AGENT_TASK='dom-b2' FM_AGENT_OWNER_HOME='/home/cap/homes/dom' " ] \
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
  show-options)
    target=
    while [ $# -gt 0 ]; do
      if [ "$1" = -t ]; then shift; target=${1:-}; break; fi
      shift
    done
    printf 'endpoint-%s\n' "${target##*:fm-}"
    exit 0
    ;;
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
  local name=$1 id=$2 case_dir home proj wt fakebin owner
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_launch_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  owner="$$|codex:$CODEX_THREAD_ID|fallback"
  printf '%s\n' "$owner" > "$home/state/.lock"
  printf '%s\n' "$ROOT" > "$home/state/.primary-checkout"
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_session_authority_write_file "$home/state/.session-authority" "$$" \
    "$owner" "$home" "$ROOT" || fail "could not create launch authority fixture"
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
    out=$(cd "$ROOT" && env -u NO_MISTAKES_GATE HOME="$HOME_DIR" GROK_HOME="$HOME_DIR/.grok" \
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
  local expected ticket_line wrapper_line
  expected=$(fm_worker_env_prefix secondmate dom-b5 /homes/dom)
  case "$expected" in
    "FM_HOME='/homes/dom' "*) : ;;
    *) fail "secondmate declaration did not pin its own home first: $expected" ;;
  esac
  assert_not_contains "$expected" "FM_ROOT_OVERRIDE='" \
    "secondmate declaration passed an inherited root override through"
  ticket_line=$(grep -n 'fm_session_enrollment_ticket_write' "$SPAWN" | tail -1 | cut -d: -f1)
  wrapper_line=$(grep -n 'LAUNCH="$WORKER_ENV_PREFIX$(shell_quote' "$SPAWN" | tail -1 | cut -d: -f1)
  [ -n "$ticket_line" ] && [ -n "$wrapper_line" ] && [ "$ticket_line" -lt "$wrapper_line" ] \
    || fail "secondmate launch did not issue enrollment before applying role and home to the wrapper"
  pass "a secondmate child receives its own home and no inherited override"
}

# --- C. a declared worker is inert and refused -------------------------------

make_primary_home() {
  local dir=$1 owner
  mkdir -p "$dir/bin" "$dir/state" "$dir/data" "$dir/config"
  fm_git_init_commit "$dir"
  git -C "$dir" branch -M main
  printf '# agents\n' > "$dir/AGENTS.md"
  owner="$$|codex:$CODEX_THREAD_ID|harness"
  printf '%s\n' "$owner" > "$dir/state/.lock"
  printf '%s\n' "$dir" > "$dir/state/.primary-checkout"
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_session_authority_write_file \
    "$dir/state/.session-authority" "$$" "$owner" "$dir" "$dir" \
    || fail "could not create primary session-authority fixture"
  printf '%s\n' "$dir"
}

test_declared_worker_is_never_a_primary_scope_match() {
  # Named primary_home, not home: the sourced libraries carry their own `home`
  # local, and reusing the name here makes shellcheck read the two as one.
  local primary_home out
  primary_home=$(make_primary_home "$TMP_ROOT/scope-home")
  out=$( cd "$primary_home" \
    && export FM_ROOT_OVERRIDE="$primary_home" FM_HOME="$primary_home" \
    && . "$ROOT/bin/fm-primary-scope-lib.sh" \
    && fm_primary_scope_matches "$primary_home" "$primary_home/state" \
    && printf 'primary' || printf 'not-primary' )
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

test_unbound_identity_has_no_primary_mutation_authority() {
  local out status
  status=0
  out=$(cd "$TMP_ROOT" && env -u FM_AGENT_ROLE -u FM_AGENT_TASK -u FM_AGENT_OWNER_HOME bash -c \
    '. "$1/bin/fm-worker-isolation-lib.sh"; fm_worker_refuse_primary_operation lock' \
    _ "$ROOT" 2>&1) || status=$?
  expect_code 1 "$status" "an identity outside the primary checkout must refuse mutation"
  assert_contains "$out" "primary identity is not bound" \
    "unbound primary refusal was not actionable"
  pass "an undeclared process outside the primary checkout has no mutation authority"
}

test_real_primary_needs_no_ambient_role() {
  local primary_home out status=0
  primary_home=$(make_primary_home "$TMP_ROOT/real-primary")
  out=$(cd "$primary_home" && env -u FM_AGENT_ROLE -u FM_AGENT_TASK \
    -u FM_AGENT_OWNER_HOME FM_ROOT_OVERRIDE="$primary_home" FM_HOME="$primary_home" \
    bash -c '. "$1/bin/fm-worker-isolation-lib.sh"; fm_worker_refuse_primary_operation lock' \
    _ "$ROOT" 2>&1) || status=$?
  expect_code 0 "$status" "a real primary checkout must work without an ambient role"
  [ -z "$out" ] || fail "real primary authority emitted unexpected output: $out"
  pass "real primary authority is proven by process and checkout identity"
}

test_fresh_primary_requires_durable_session_binding() {
  local primary_home out status=0
  primary_home=$(make_primary_home "$TMP_ROOT/fresh-primary")
  rm -rf "$primary_home/state"
  out=$(cd "$primary_home" && env -u FM_AGENT_ROLE -u FM_AGENT_TASK \
    -u FM_AGENT_OWNER_HOME FM_ROOT_OVERRIDE="$primary_home" FM_HOME="$primary_home" \
    bash -c '
      . "$1/bin/fm-worker-isolation-lib.sh"
      ps() {
        case "$*" in *"-o comm="*"-p $$"*) printf "codex\n" ;; *) command ps "$@" ;; esac
      }
      fm_worker_refuse_primary_operation lock
    ' \
    _ "$ROOT" 2>&1) || status=$?
  expect_code 1 "$status" "a process-name match must not create fresh primary authority"
  assert_contains "$out" "primary identity is not bound" \
    "fresh primary refusal lost its durable-binding reason"
  pass "fresh primary authority requires a durable session and checkout binding"
}

test_fresh_primary_session_lock_enrolls_atomically() {
  local primary_home out status=0
  primary_home=$(make_primary_home "$TMP_ROOT/fresh-enrollment")
  rm -rf "$primary_home/state"
  out=$(cd "$primary_home" && env -u FM_AGENT_ROLE -u FM_AGENT_TASK \
    -u FM_AGENT_OWNER_HOME FM_ROOT_OVERRIDE="$primary_home" FM_HOME="$primary_home" \
    "$AUTHORITY_EXEC" "$LOCK" 2>&1) || status=$?
  expect_code 0 "$status" "an empty primary home must enroll under the acquisition lock"
  assert_present "$primary_home/state/.lock" "fresh enrollment omitted the session lock"
  assert_present "$primary_home/state/.primary-checkout" \
    "fresh enrollment omitted the checkout binding"
  assert_present "$primary_home/state/.session-authority" \
    "fresh enrollment omitted exact process authority"
  pass "fresh primary enrollment publishes one bound authority transaction"
}

test_caller_marker_cannot_replace_exact_session_authority() {
  local primary_home sleeper owner out status=0
  primary_home=$(make_primary_home "$TMP_ROOT/exact-session-authority")
  sleep 60 & sleeper=$!
  owner="$sleeper|codex:forged-thread|harness"
  printf '%s\n' "$owner" > "$primary_home/state/.lock"
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_session_authority_write_file "$primary_home/state/.session-authority" \
    "$sleeper" "$owner" "$primary_home" "$primary_home" \
    || fail "could not create foreign live authority fixture"
  out=$(cd "$primary_home" && CODEX_THREAD_ID=forged-thread \
    FM_SESSION_AUTHORITY_FD=999 \
    FM_ROOT_OVERRIDE="$primary_home" FM_HOME="$primary_home" \
    bash -c '. "$1/bin/fm-worker-isolation-lib.sh"; fm_worker_refuse_primary_operation lock' \
    _ "$ROOT" 2>&1) || status=$?
  kill "$sleeper" 2>/dev/null || true
  wait "$sleeper" 2>/dev/null || true
  expect_code 1 "$status" "a caller-controlled thread marker must not replace exact authority"
  assert_contains "$out" "primary identity is not bound" \
    "foreign exact authority refusal lost its reason"
  pass "primary authority requires the recorded process tuple in current ancestry"
}

run_reparented_lock_attempt() {
  local case_dir=$1 primary_home=$2 child attempts=0
  mkdir -p "$case_dir"
  perl -MPOSIX -e '
    my ($dir, $home, $authority_exec, $lock) = @ARGV;
    my $pid = fork();
    die "fork failed" unless defined $pid;
    if ($pid) {
      select undef, undef, undef, 0.01 until -f "$dir/initial-parent";
      exit 0;
    }
    open my $child_file, ">", "$dir/child" or die $!;
    print {$child_file} "$$\n";
    close $child_file;
    my $initial = getppid();
    open my $initial_file, ">", "$dir/initial-parent" or die $!;
    print {$initial_file} "$initial\n";
    close $initial_file;
    select undef, undef, undef, 0.02 while getppid() == $initial;
    open my $final_file, ">", "$dir/final-parent" or die $!;
    print {$final_file} getppid() . "\n";
    close $final_file;
    POSIX::setsid() >= 0 or die "setsid failed";
    open my $session_file, ">", "$dir/session" or die $!;
    print {$session_file} getpgrp(0) . "\n";
    close $session_file;
    open my $key_file, ">", "$dir/forged-key" or die $!;
    print {$key_file} "f" x 96;
    close $key_file;
    open my $key_read, "<", "$dir/forged-key" or die $!;
    POSIX::dup2(fileno($key_read), 7) >= 0 or die "dup2 failed";
    $0 = "codex";
    delete @ENV{qw(FM_AGENT_TASK FM_AGENT_OWNER_HOME)};
    @ENV{qw(FM_AGENT_ROLE FM_SESSION_AUTHORITY_FD FM_ROOT_OVERRIDE FM_HOME
      FM_SESSION_AUTHORITY_BROKER_PID FM_SESSION_AUTHORITY_BROKER_START
      FM_SESSION_AUTHORITY_BROKER_IDENTITY)}
      = ("primary", "7", $home, $home, "$$", "proc:1", "exe:/bin/bash");
    open STDOUT, ">", "$dir/output" or die $!;
    open STDERR, ">&", \*STDOUT or die $!;
    my $rc = system($authority_exec, $lock);
    my $status = $rc == -1 ? 127 : $rc >> 8;
    open my $status_file, ">", "$dir/status" or die $!;
    print {$status_file} "$status\n";
    close $status_file;
    exit 0;
  ' "$case_dir" "$primary_home" "$AUTHORITY_EXEC" "$LOCK"
  child=$(cat "$case_dir/child")
  BG_PIDS+=("$child")
  while [ "$attempts" -lt 250 ]; do
    [ -f "$case_dir/status" ] && break
    sleep 0.02
    attempts=$((attempts + 1))
  done
  assert_present "$case_dir/status" "the reparented worker did not finish enrollment"
}

test_reparented_markerless_process_has_no_fresh_primary_authority() {
  local primary_home case_dir child session initial_parent final_parent status out
  primary_home=$(make_primary_home "$TMP_ROOT/reparented-primary")
  rm -rf "$primary_home/state"
  case_dir="$TMP_ROOT/reparented-enrollment"
  run_reparented_lock_attempt "$case_dir" "$primary_home"
  initial_parent=$(cat "$case_dir/initial-parent")
  final_parent=$(cat "$case_dir/final-parent")
  child=$(cat "$case_dir/child")
  session=$(cat "$case_dir/session")
  [ "$initial_parent" != "$final_parent" ] || fail "the enrollment worker was not reparented"
  [ "$child" = "$session" ] || fail "the reparented worker did not create its own session"
  status=$(cat "$case_dir/status")
  out=$(cat "$case_dir/output")
  expect_code 1 "$status" "a reparented markerless process must not create primary authority"
  assert_contains "$out" "trusted session enrollment capability is missing or invalid" \
    "reparented enrollment refusal lost its capability reason"
  assert_absent "$primary_home/state/.lock" \
    "reparented direct enrollment published a session lock"
  assert_absent "$primary_home/state/.primary-checkout" \
    "reparented direct enrollment published a checkout binding"
  assert_absent "$primary_home/state/.session-authority" \
    "reparented direct enrollment published session authority"
  pass "a real reparented worker cannot mint enrollment by clearing and forging identity"
}

test_reparented_worker_cannot_trigger_forged_authority_recovery() {
  local primary_home case_dir before_lock before_authority status out txn
  primary_home=$(make_primary_home "$TMP_ROOT/reparented-recovery-primary")
  before_lock=$(cat "$primary_home/state/.lock")
  before_authority=$(cat "$primary_home/state/.session-authority")
  txn="$primary_home/state/.session-authority-transaction"
  mkdir "$txn"
  printf '%s\n' ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff \
    > "$txn/key"
  printf '%s\n' forged > "$txn/manifest"
  printf '%s\n' ready > "$txn/ready"
  case_dir="$TMP_ROOT/reparented-recovery"
  run_reparented_lock_attempt "$case_dir" "$primary_home"
  status=$(cat "$case_dir/status")
  out=$(cat "$case_dir/output")
  expect_code 1 "$status" "a reparented worker must not trigger transaction recovery"
  assert_contains "$out" "trusted session enrollment capability is missing or invalid" \
    "forged recovery was inspected before independent authorization"
  [ "$(cat "$primary_home/state/.lock")" = "$before_lock" ] \
    || fail "forged recovery changed the session lock"
  [ "$(cat "$primary_home/state/.session-authority")" = "$before_authority" ] \
    || fail "forged recovery changed session authority"
  assert_present "$txn" "unauthorized recovery removed forged transaction evidence"
  pass "recovery authorizes the broker before reading transaction material"
}

test_foreign_session_lock_defeats_primary_topology() {
  local primary_home out status=0
  primary_home=$(make_primary_home "$TMP_ROOT/foreign-primary-lock")
  printf '%s\n' '999999|codex:foreign-thread|fallback' > "$primary_home/state/.lock"
  out=$(cd "$primary_home" && env -u FM_AGENT_ROLE -u FM_AGENT_TASK \
    -u FM_AGENT_OWNER_HOME FM_ROOT_OVERRIDE="$primary_home" FM_HOME="$primary_home" \
    bash -c '. "$1/bin/fm-worker-isolation-lib.sh"; fm_worker_refuse_primary_operation lock' \
    _ "$ROOT" 2>&1) || status=$?
  expect_code 1 "$status" "a foreign #82 session lock must defeat primary topology"
  assert_contains "$out" "primary identity is not bound" \
    "foreign session-lock refusal lost its authority reason"
  pass "primary authority respects the home session-lock owner"
}

test_linked_main_worktree_can_prove_primary_authority() {
  local repo primary out status=0
  repo="$TMP_ROOT/linked-primary-repo"
  primary="$TMP_ROOT/linked-primary"
  fm_git_init_commit "$repo"
  git -C "$repo" branch -M seed
  git -C "$repo" worktree add -q -b main "$primary"
  mkdir -p "$primary/state" "$primary/bin"
  printf '# agents\n' > "$primary/AGENTS.md"
  printf '%s|codex:%s|fallback\n' "$$" "$CODEX_THREAD_ID" > "$primary/state/.lock"
  printf '%s\n' "$primary" > "$primary/state/.primary-checkout"
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_session_authority_write_file "$primary/state/.session-authority" "$$" \
    "$$|codex:$CODEX_THREAD_ID|fallback" "$primary" "$primary" \
    || fail "could not create linked primary authority fixture"
  out=$(cd "$primary" && env -u FM_AGENT_ROLE -u FM_AGENT_TASK \
    -u FM_AGENT_OWNER_HOME FM_ROOT_OVERRIDE="$primary" FM_HOME="$primary" \
    bash -c '
      . "$1/bin/fm-worker-isolation-lib.sh"
      ps() {
        case "$*" in *"-o comm="*"-p $$"*) printf "codex\n" ;; *) command ps "$@" ;; esac
      }
      fm_worker_refuse_primary_operation lock
    ' \
    _ "$ROOT" 2>&1) || status=$?
  expect_code 0 "$status" "a linked main worktree must prove primary authority"
  [ -z "$out" ] || fail "linked primary authority emitted unexpected output: $out"
  pass "a linked main worktree can prove primary authority"
}

test_primary_role_cannot_override_worker_ancestry() {
  local primary_home out status
  primary_home=$(make_primary_home "$TMP_ROOT/asserted-primary")
  status=0
  out=$(FM_AGENT_ROLE=crewmate FM_AGENT_TASK=worker-a \
    FM_AGENT_OWNER_HOME="$primary_home" bash -c '
      cd "$1"
      FM_AGENT_ROLE=primary FM_AGENT_TASK= FM_AGENT_OWNER_HOME= \
        bash -c ". \"$2/bin/fm-worker-isolation-lib.sh\"; fm_worker_refuse_primary_operation lock"
    ' _ "$primary_home" "$ROOT" 2>&1) || status=$?
  expect_code 1 "$status" "a worker ancestor must defeat a self-asserted primary role"
  assert_contains "$out" "primary identity is not bound" \
    "self-asserted primary refusal was not actionable"
  pass "primary authority is bound to process ancestry and checkout scope"
}

test_primary_authority_refuses_unreadable_ancestry() {
  local primary_home out status=0
  primary_home=$(make_primary_home "$TMP_ROOT/unreadable-ancestry")
  out=$(cd "$primary_home" && FM_ROOT_OVERRIDE="$primary_home" FM_HOME="$primary_home" \
    bash -c '
      . "$1/bin/fm-worker-isolation-lib.sh"
      fm_worker_process_environment() { return 1; }
      fm_worker_refuse_primary_operation lock
    ' _ "$ROOT" 2>&1) || status=$?
  expect_code 1 "$status" "unreadable ancestry must not authorize a primary"
  assert_contains "$out" "primary identity is not bound" \
    "unreadable ancestry refusal lost its authority reason"
  pass "primary authority fails closed when ancestry cannot be read"
}

test_stale_session_lock_reaches_verified_recovery() {
  local primary_home out status=0 sleeper owner
  primary_home=$(make_primary_home "$TMP_ROOT/stale-primary-lock")
  sleep 60 & sleeper=$!
  owner="$sleeper|codex:stale-thread|harness"
  printf '%s\n' "$owner" > "$primary_home/state/.lock"
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_session_authority_write_file "$primary_home/state/.session-authority" \
    "$sleeper" "$owner" "$primary_home" "$primary_home" \
    || fail "could not create stale authority fixture"
  kill "$sleeper"
  wait "$sleeper" 2>/dev/null || true
  out=$(cd "$primary_home" && FM_ROOT_OVERRIDE="$primary_home" FM_HOME="$primary_home" \
    "$AUTHORITY_EXEC" "$LOCK" 2>&1) || status=$?
  expect_code 0 "$status" "a provably stale session lock must reach verified recovery"
  assert_contains "$out" "lock acquired" "stale session-lock recovery did not complete"
  pass "primary authority permits only verified stale session-lock recovery"
}

test_unregistered_cross_home_primary_is_refused() {
  local root home out status=0
  root=$(make_primary_home "$TMP_ROOT/cross-home-root")
  home=$(make_primary_home "$TMP_ROOT/cross-home-owner")
  rm -f "$home/state/.primary-checkout" "$home/state/.lock"
  out=$(cd "$root" && FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    bash -c '. "$1/bin/fm-worker-isolation-lib.sh"; fm_worker_refuse_primary_operation "session lock acquisition"' \
    _ "$ROOT" 2>&1) || status=$?
  expect_code 1 "$status" "unregistered unrelated checkouts must not claim a fresh home"
  pass "fresh cross-home authority requires shared registered Git topology"
}

test_binding_failure_never_installs_new_session_owner() {
  local primary_home out status=0
  primary_home=$(make_primary_home "$TMP_ROOT/atomic-session-binding")
  rm -f "$primary_home/state/.lock" "$primary_home/state/.primary-checkout"
  mkdir "$primary_home/state/.primary-checkout"
  out=$(cd "$primary_home" && FM_ROOT_OVERRIDE="$primary_home" FM_HOME="$primary_home" \
    "$AUTHORITY_EXEC" "$LOCK" 2>&1) || status=$?
  expect_code 1 "$status" "invalid checkout binding must refuse lock acquisition"
  assert_absent "$primary_home/state/.lock" \
    "binding failure left a newly installed session owner"
  pass "session owner publication waits for a valid checkout binding"
}

test_binding_publication_is_verified_before_commit() {
  local home fakebin real_mv out status=0
  home=$(make_primary_home "$TMP_ROOT/binding-publication-verification")
  rm -rf "$home/state"
  fakebin="$TMP_ROOT/binding-publication-fakebin"
  mkdir -p "$fakebin"
  real_mv=$(command -v mv)
  printf '%s\n' '#!/usr/bin/env bash' \
    '"$FM_REAL_MV" "$@" || exit $?' \
    'destination=${@: -1}' \
    '[ "$destination" != "$FM_CORRUPT_BINDING" ] || printf "corrupt\n" > "$destination"' \
    > "$fakebin/mv"
  chmod +x "$fakebin/mv"
  out=$(cd "$home" && PATH="$fakebin:$PATH" FM_REAL_MV="$real_mv" \
    FM_CORRUPT_BINDING="$home/state/.primary-checkout" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    "$AUTHORITY_EXEC" "$LOCK" 2>&1) || status=$?
  expect_code 1 "$status" "corrupt published binding must fail before commit"
  assert_contains "$out" "session authority publication is incomplete" \
    "binding publication failure lost its transaction reason"
  assert_present "$home/state/.session-authority-transaction" \
    "binding publication failure deleted recovery evidence"
  assert_absent "$home/state/.lock" \
    "binding publication failure left a new session lock installed"
  pass "normal authority commit verifies the published binding digest"
}

test_procargs2_parser_separates_argv_and_environment() {
  local valid malformed calls snapshots out status=0
  valid="$TMP_ROOT/procargs-valid.bin"
  malformed="$TMP_ROOT/procargs-malformed.bin"
  calls="$TMP_ROOT/procargs-calls"
  snapshots="$TMP_ROOT/procargs-snapshots"
  mkdir -p "$snapshots"
  : > "$calls"
  printf 'preserved\n' > "$TMP_ROOT/fd-eight"
  printf '\003\000\000\000/bin/bash\000\000bash\000\000\000FM_AGENT_ROLE=crewmate\000X=1\000' \
    > "$valid"
  printf '\001\000\000\000/bin/bash\000bash\000not-an-environment-record\000' \
    > "$malformed"
  out=$(TMPDIR="$snapshots" bash -c '
    . "$1/bin/fm-procargs-lib.sh"
    DUMP=$2
    CALLS=$3
    exec 8< "$4"
    exec 9> "$5"
    fm_procargs2_dump() { printf "call\n" >> "$CALLS"; command cat "$DUMP"; }
    fm_procargs2_read 1
    IFS= read -r preserved <&8
    printf "%s\n" preserved >&9
    printf "%s|%s|%s\n" "${FM_PROCARGS_ARGV[*]}" \
      "${FM_PROCARGS_ENV[0]}" "${FM_PROCARGS_ENV[1]}"
  ' _ "$ROOT" "$valid" "$calls" "$TMP_ROOT/fd-eight" "$TMP_ROOT/fd-nine") || status=$?
  expect_code 0 "$status" "valid procargs2 fixture must parse"
  [ "$out" = "bash  |FM_AGENT_ROLE=crewmate|X=1" ] \
    || fail "procargs2 argv/environment boundary was wrong: $out"
  [ "$(wc -l < "$calls" | tr -d ' ')" -eq 1 ] \
    || fail "procargs2 parser read more than one process snapshot"
  [ -z "$(find "$snapshots" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "procargs2 parser left a named process snapshot on disk"
  [ "$(cat "$TMP_ROOT/fd-nine")" = preserved ] \
    || fail "procargs2 parser clobbered a caller-owned descriptor"
  if TMPDIR="$snapshots" bash -c '
    . "$1/bin/fm-procargs-lib.sh"
    DUMP=$2
    fm_procargs2_dump() { command cat "$DUMP"; }
    fm_procargs2_read 1
  ' _ "$ROOT" "$malformed"; then
    fail "malformed procargs2 record was accepted"
  fi
  pass "one procargs2 snapshot handles valid and malformed records"
}

write_session_authority_recovery_manifest() {
  local txn=$1 body hmac
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_session_random_hex 48 > "$txn/key" || return 1
  chmod 600 "$txn/key" || return 1
  body=$(printf 'version=2\nold-lock=%s\nold-binding=%s\nold-authority=%s\nnew-lock=sha256:%064d\nnew-binding=sha256:%064d\nnew-authority=sha256:%064d\n' \
    "$(session_test_signature "$txn/old-lock")" \
    "$(session_test_signature "$txn/old-binding")" \
    "$(session_test_signature "$txn/old-authority")" 0 0 0)
  hmac=$(printf '%s\n' "$body" \
    | fm_session_hmac_sha256_key_file "$txn/key") || return 1
  printf '%s\nhmac=%s\n' "$body" "$hmac" > "$txn/manifest"
}

session_test_signature() {
  local file=$1 digest
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '%s\n' absent
  else
    digest=$(fm_session_sha256_file "$file") || return 1
    printf 'sha256:%s\n' "$digest"
  fi
}

test_session_authority_recovery_retains_unverified_backup() {
  local home fakebin out status=0
  home=$(make_primary_home "$TMP_ROOT/session-authority-recovery")
  printf '%s\n' "$home" > "$home/state/.primary-checkout"
  mkdir "$home/state/.session-authority-transaction"
  cp "$home/state/.lock" "$home/state/.session-authority-transaction/old-lock"
  cp "$home/state/.primary-checkout" \
    "$home/state/.session-authority-transaction/old-binding"
  write_session_authority_recovery_manifest \
    "$home/state/.session-authority-transaction"
  printf 'ready\n' > "$home/state/.session-authority-transaction/ready"
  fakebin="$TMP_ROOT/session-authority-fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/cp" <<'SH'
#!/usr/bin/env bash
printf 'corrupt\n' > "${@: -1}"
SH
  chmod +x "$fakebin/cp"
  out=$(cd "$home" && PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    "$AUTHORITY_EXEC" "$LOCK" 2>&1) || status=$?
  expect_code 1 "$status" "unverified session-authority recovery must fail closed"
  [ -d "$home/state/.session-authority-transaction" ] \
    || fail "unverified session-authority recovery destroyed its backup"
  assert_contains "$out" "recovery could not be verified" \
    "unverified session-authority recovery was not actionable"
  pass "session-authority recovery retains backups until byte verification"
}

test_session_authority_recovery_precedes_current_tuple_validation() {
  local home txn out status=0
  home=$(make_primary_home "$TMP_ROOT/session-authority-mixed-recovery")
  txn="$home/state/.session-authority-transaction"
  mkdir "$txn"
  cp "$home/state/.lock" "$txn/old-lock"
  cp "$home/state/.primary-checkout" "$txn/old-binding"
  cp "$home/state/.session-authority" "$txn/old-authority"
  write_session_authority_recovery_manifest "$txn"
  printf '%s\n' ready > "$txn/ready"
  printf '%s\n' '999999|codex:foreign|fallback' > "$home/state/.lock"
  printf '%s\n' 'invalid-authority' > "$home/state/.session-authority"
  out=$(cd "$home" && env -u FM_SESSION_AUTHORITY_FD \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    "$AUTHORITY_EXEC" "$LOCK" 2>&1) || status=$?
  expect_code 1 "$status" "launcher-key loss must not prevent transaction recovery"
  assert_absent "$txn" "verified authority recovery left its transaction behind"
  [ "$(cat "$home/state/.lock")" != '999999|codex:foreign|fallback' ] \
    || fail "durable-key recovery did not restore the saved lock"
  pass "session authority transaction recovery survives launcher-key loss"
}

issue_secondmate_enrollment() {
  local issuer=$1 home=$2 task=$3 owner ready release attempts=0
  owner=$(cat "$issuer/state/.lock") || return 1
  printf '%s\n' "$ROOT" > "$issuer/state/.primary-checkout" || return 1
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_session_authority_write_file \
    "$issuer/state/.session-authority" "$$" "$owner" "$issuer" "$ROOT" || return 1
  ready="$home/state/.session-authority-enrollment.ready"
  release="$home/state/.session-authority-enrollment.release"
  (
    cd "$ROOT" || exit 1
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$issuer" \
      "$AUTHORITY_EXEC" bash -c '
        . "$1/bin/fm-session-lock-lib.sh"
        owner=$FM_SESSION_AUTHORITY_BROKER_PID
        printf "%s\n" "$owner" > "$2/state/.lock"
        printf "%s\n" "$1" > "$2/state/.primary-checkout"
        fm_session_authority_write_file "$2/state/.session-authority" \
          "$FM_SESSION_AUTHORITY_BROKER_PID" "$owner" "$2" "$1" \
          && fm_session_enrollment_ticket_write "$3" "$4" "$5" "$2" \
          && : > "$6" || exit 1
        while [ ! -e "$7" ]; do sleep 0.02; done
      ' _ "$ROOT" "$issuer" "$home/state/.session-authority-enrollment" \
        "$task" "$home" "$ready" "$release"
  ) >/dev/null 2>&1 &
  ENROLLMENT_ISSUER_PID=$!
  BG_PIDS+=("$ENROLLMENT_ISSUER_PID")
  while [ "$attempts" -lt 250 ]; do
    [ -f "$ready" ] && return 0
    kill -0 "$ENROLLMENT_ISSUER_PID" 2>/dev/null || return 1
    sleep 0.02
    attempts=$((attempts + 1))
  done
  return 1
}

test_secondmate_authority_delegation_uses_no_node() {
  local issuer home fakebin out status=0
  issuer=$(make_primary_home "$TMP_ROOT/secondmate-authority-issuer")
  home="$TMP_ROOT/secondmate-authority-delegation"
  mkdir -p "$home/state"
  fm_git_init_commit "$home"
  git -C "$home" branch -M main
  printf '%s\n' domain > "$home/.fm-secondmate-home"
  issue_secondmate_enrollment "$issuer" "$home" domain \
    || fail "could not issue fresh secondmate enrollment"
  fakebin="$TMP_ROOT/no-node"
  mkdir -p "$fakebin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$fakebin/node"
  chmod +x "$fakebin/node"
  out=$(cd "$home" && env -u FM_SESSION_AUTHORITY_FD \
    -u FM_SESSION_AUTHORITY_BROKER_PID -u FM_SESSION_AUTHORITY_BROKER_START \
    -u FM_SESSION_AUTHORITY_BROKER_IDENTITY -u FM_SESSION_AUTHORITY_BROKER_SCRIPT \
    PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_AGENT_ROLE=secondmate \
    FM_AGENT_TASK=domain FM_AGENT_OWNER_HOME="$home" \
    "$AUTHORITY_EXEC" "$LOCK" 2>&1) || status=$?
  expect_code 0 "$status" "a declared secondmate must acquire its session lock"
  assert_contains "$out" "lock acquired" \
    "secondmate authority delegation did not reach lock acquisition"
  assert_absent "$home/state/.session-authority-enrollment" \
    "secondmate enrollment ticket remained reusable"
  : > "$home/state/.session-authority-enrollment.release"
  wait "$ENROLLMENT_ISSUER_PID" 2>/dev/null || true
  pass "secondmate lock acquisition preserves delegated authority without Node"
}

test_forged_key_cannot_issue_secondmate_enrollment() {
  local issuer home key ticket
  issuer=$(make_primary_home "$TMP_ROOT/forged-secondmate-issuer")
  home="$TMP_ROOT/forged-secondmate-home"
  ticket="$home/state/.session-authority-enrollment"
  key="$TMP_ROOT/forged-secondmate-key"
  mkdir -p "$home/state"
  printf '%s\n' domain > "$home/.fm-secondmate-home"
  printf '%096d' 0 > "$key"
  (
    exec 7<"$key"
    FM_SESSION_AUTHORITY_FD=7
    export FM_SESSION_AUTHORITY_FD
    unset FM_SESSION_AUTHORITY_BROKER_PID FM_SESSION_AUTHORITY_BROKER_START
    unset FM_SESSION_AUTHORITY_BROKER_IDENTITY FM_SESSION_AUTHORITY_BROKER_SCRIPT
    . "$ROOT/bin/fm-session-lock-lib.sh"
    ! fm_session_enrollment_ticket_write "$ticket" domain "$home" "$issuer"
  ) || fail "a forged descriptor issued a secondmate enrollment ticket"
  assert_absent "$ticket" "forged secondmate enrollment left a reusable ticket"
  pass "secondmate enrollment tickets require the live issuer authority key"
}

test_fresh_enrollment_requires_external_capability() {
  local home out status=0
  home=$(make_primary_home "$TMP_ROOT/fresh-capability-required")
  rm -rf "$home/state"
  out=$(cd "$home" && env -u FM_SESSION_AUTHORITY_FD \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$LOCK" 2>&1) || status=$?
  expect_code 1 "$status" "fresh enrollment without an external capability must fail"
  assert_absent "$home/state/.lock" "capability-free enrollment published a lock"
  assert_contains "$out" "broker is missing or invalid" \
    "capability-free enrollment refusal lost its reason"
  pass "fresh enrollment requires independently supplied authority capability"
}

test_non_git_cross_home_enrollment_is_refused() {
  local root home out status=0
  root=$(make_primary_home "$TMP_ROOT/non-git-cross-root")
  home="$TMP_ROOT/non-git-cross-home"
  mkdir -p "$home"
  out=$(cd "$root" && FM_ROOT_OVERRIDE="$root" FM_HOME="$home" "$LOCK" 2>&1) \
    || status=$?
  expect_code 1 "$status" "a non-Git cross-home path must not enroll"
  assert_absent "$home/state/.lock" "non-Git cross-home enrollment published a lock"
  pass "fresh cross-home enrollment requires authoritative Git topology"
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
  local home foreign alias out status foreign_before
  home=$(make_primary_home "$TMP_ROOT/secondmate-owner-home")
  foreign=$(make_primary_home "$TMP_ROOT/secondmate-foreign-home")
  foreign_before=$(cat "$foreign/state/.lock")
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
  [ "$(cat "$foreign/state/.lock")" = "$foreign_before" ] \
    || fail "a secondmate mutated a foreign session lock"

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

test_unreadable_agent_candidate_is_indexed_as_unproven() {
  local out
  out=$(bash -c '
    . "$1/bin/fm-agent-cwd-lib.sh"
    fm_agent_environ() { return 1; }
    ps() {
      case " $* " in
        *" -p $$ "*) printf "codex\n" ;;
        *) return 1 ;;
      esac
    }
    fm_agent_task_pid_index
  ' _ "$ROOT" 2>/dev/null || true)
  assert_contains "$out" $'__FM_UNPROVEN__\t__FM_UNPROVEN__\tunreadable' \
    "an unreadable candidate agent disappeared from the process census"
  pass "unreadable candidate agents remain visible as unproven"
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

  out=$(cd "$ROOT" && env -u NO_MISTAKES_GATE FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
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
  local name=$1 world proj wt other owner
  world="$TMP_ROOT/$name"
  proj="$world/project"
  wt="$world/wt"
  other="$world/wt-other"
  mkdir -p "$world/home/state" "$world/home/data" "$world/home/config"
  owner="$$|codex:$CODEX_THREAD_ID|fallback"
  printf '%s\n' "$owner" > "$world/home/state/.lock"
  printf '%s\n' "$ROOT" > "$world/home/state/.primary-checkout"
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_session_authority_write_file "$world/home/state/.session-authority" "$$" \
    "$owner" "$world/home" "$ROOT" || fail "could not create slot authority fixture"
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

write_current_meta() {
  local file=$1 task=$2 home=$3 generation=$4
  shift 4
  fm_write_meta "$file" "$@" \
    "task=$task" "home=$home" "endpoint_generation=$generation"
}

make_generation_tmux() {
  local fakebin=$1 generation=$2 log=${3:-}
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show-options ]; then
  printf '%s\n' '$generation'
elif [ -n '$log' ]; then
  printf '%s\n' "\$*" >> '$log'
fi
exit 0
SH
  chmod +x "$fakebin/tmux"
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

test_missing_stamp_retains() {
  local rec verdict
  rec=$(make_slot_world slot-missing-stamp)
  read_slot_world "$rec"
  fm_write_meta "$WORLD/home/state/task-missing.meta" \
    "window=firstmate:fm-task-missing" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  verdict=$(slot_verdict "$WORLD/home/state" task-missing "$WT_DIR" "$WORLD/home")
  assert_contains "$verdict" "retain: slot ownership stamp is missing" \
    "unstamped pooled slot was authorized for disposal"
  pass "missing ownership stamps retain pooled slots"
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
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-unclassified "$WORLD/home" )
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
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-undeclared "$WORLD/home" )
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

test_ambiguous_sibling_scope_metadata_retains_the_slot() {
  local rec verdict sibling
  rec=$(make_slot_world slot-ambiguous-sibling)
  read_slot_world "$rec"
  fm_write_meta "$WORLD/home/state/task-scope.meta" \
    "window=firstmate:fm-task-scope" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  sibling="$WORLD/home/state/paused-scope.meta"
  fm_write_meta "$sibling" \
    "window=firstmate:fm-paused-scope" "worktree=$WT_DIR" "worktree=$PROJ_DIR" \
    "project=$PROJ_DIR" "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  verdict=$(slot_verdict "$WORLD/home/state" task-scope "$WT_DIR" "$WORLD/home")
  assert_contains "$verdict" "paused-scope (scope metadata unproven)" \
    "conflicting duplicate sibling worktree metadata did not retain"
  fm_write_meta "$sibling" \
    "window=firstmate:fm-paused-scope" "worktree=" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  verdict=$(slot_verdict "$WORLD/home/state" task-scope "$WT_DIR" "$WORLD/home")
  assert_contains "$verdict" "paused-scope (scope metadata unproven)" \
    "empty sibling worktree metadata did not retain"
  rm -f "$sibling"
  ln -s "$WORLD/missing-meta" "$sibling"
  verdict=$(slot_verdict "$WORLD/home/state" task-scope "$WT_DIR" "$WORLD/home")
  assert_contains "$verdict" "paused-scope (scope metadata unproven)" \
    "unreadable sibling metadata did not retain"
  pass "ambiguous sibling scope metadata retains pooled-slot ownership"
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
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-e5 "$WORLD/home" )
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
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" "$id" "$WORLD/home" )
  start_declared_agent "$WT_DIR" "$id" "$WORLD/other-home" crewmate >/dev/null
  verdict=$(slot_verdict "$WORLD/home/state" "$id" "$WT_DIR" "$WORLD/home")
  case "$verdict" in
    "retain: a live agent for task(s) $id"*) ;;
    *) fail "same task in another home did not retain the slot: $verdict" ;;
  esac
  rec=$(make_slot_world slot-same-task-foreign-role)
  read_slot_world "$rec"
  id="same-task-role-e9-$RUN_TAG"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" "$id" "$WORLD/home" )
  start_declared_agent "$WT_DIR" "$id" "$WORLD/home" secondmate >/dev/null
  verdict=$(slot_verdict "$WORLD/home/state" "$id" "$WT_DIR" "$WORLD/home" crewmate)
  case "$verdict" in
    "retain: a live agent for task(s) $id"*) ;;
    *) fail "same task and home with another role did not retain the slot: $verdict" ;;
  esac
  pass "live slot occupancy excludes only the exact task, home, and role identity"
}

test_a_relinquished_slot_requires_remaining_ownership_proof() {
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
  assert_contains "$verdict" "retain: slot ownership stamp is missing" \
    "an unstamped remaining holder was allowed to release the slot"
  pass "a retiring owner cannot grant unstamped disposal authority to a remaining holder"
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

test_relinquish_retires_exact_transition_artifacts() {
  local rec claim legacy stamp
  rec=$(make_slot_world slot-transition-relinquish)
  read_slot_world "$rec"
  (
    . "$ROOT/bin/fm-slot-owner-lib.sh"
    fm_slot_stamp_write "$WT_DIR" transition-owner "$WORLD/home"
    fm_slot_stamp_stage_return "$WT_DIR" transition-owner "$WORLD/home" \
      "$WORLD/home/state" transition-owner
    claim=$FM_SLOT_RETURN_CLAIM
    legacy=$FM_SLOT_RETURN_LEGACY
    fm_slot_stamp_relinquish "$WT_DIR" transition-owner "$WORLD/home" \
      "retain: slot is also recorded by task(s) paused-owner in this home"
    [ ! -e "$claim" ] && [ ! -e "$legacy" ] && [ ! -L "$claim" ] && [ ! -L "$legacy" ]
  ) || fail "exact same-task transition artifacts survived relinquish"
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$WT_DIR" task || printf none )
  [ "$stamp" = none ] || fail "exact transition stamp survived relinquish"
  pass "relinquish retires exact transition claim, owner, and stamp together"
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
  fm_fake_exit0 "$fakebin" gh-axi gh
  make_generation_tmux "$fakebin" endpoint-task-e6
  : > "$WORLD/treehouse.log"
  write_current_meta "$WORLD/home/state/task-e6.meta" task-e6 "$WORLD/home" endpoint-task-e6 \
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
  fm_fake_exit0 "$fakebin" gh-axi gh treehouse
  make_generation_tmux "$fakebin" endpoint-task-e11
  write_current_meta "$WORLD/home/state/task-e11.meta" task-e11 "$WORLD/home" endpoint-task-e11 \
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
if [ "${1:-}" = return ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'treehouse return [--if-lease-holder HOLDER]'
  exit 0
fi
target=${3:-}
git_dir=$(git -C "$target" rev-parse --absolute-git-dir)
[ -f "$git_dir/fm-slot-owner" ] || exit 19
grep -Fx 'task=task-e12' "$git_dir/fm-slot-owner" >/dev/null || exit 23
common_dir=$(git -C "$target" rev-parse --git-common-dir)
case "$common_dir" in /*) ;; *) common_dir="$target/$common_dir" ;; esac
claim="$common_dir/fm-slot-return-claims/${git_dir##*/}.claim"
[ -f "$claim" ] || exit 20
grep -Fx 'task=task-e12' "$claim" >/dev/null || exit 21
grep -Fx 'lease_holder=task-e12' "$claim" >/dev/null || exit 22
exit 17
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh-axi gh
  make_generation_tmux "$fakebin" endpoint-task-e12
  write_current_meta "$WORLD/home/state/task-e12.meta" task-e12 "$WORLD/home" endpoint-task-e12 \
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
  [ -f "$(git -C "$WT_DIR" rev-parse --absolute-git-dir)/fm-slot-owner" ] \
    || fail "failed pool return did not leave legacy-visible ownership evidence"
  [ "$(git -C "$WT_DIR" rev-parse --abbrev-ref HEAD)" = "$branch" ] \
    || fail "failed pool return changed the retry branch identity"
  assert_present "$WT_DIR/.claude/settings.local.json" "failed pool return removed the Claude hook"
  assert_present "$WT_DIR/.opencode/plugins/fm-turn-end.js" "failed pool return removed the OpenCode hook"
  assert_present "$WT_DIR/.fm-grok-turnend" "failed pool return removed the Grok hook"
  pass "ownership evidence survives until pooled return succeeds"
}

test_return_transition_never_uses_a_worktree_path() {
  local rec collision claim legacy
  rec=$(make_slot_world slot-return-path-collision)
  read_slot_world "$rec"
  collision="$WT_DIR/.fm-slot-return-owner"
  printf 'tracked user data\n' > "$collision"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-collision "$WORLD/home" \
    && fm_slot_stamp_stage_return "$WT_DIR" task-collision "$WORLD/home" \
      "$WORLD/home/state" task-collision \
    && claim=$FM_SLOT_RETURN_CLAIM \
    && legacy=$FM_SLOT_RETURN_LEGACY \
    && [ "$legacy" != "$collision" ] \
    && fm_slot_stamp_finalize_return "$claim" "$legacy" ) \
    || fail "return transition could not use collision-free global state"
  [ "$(cat "$collision")" = "tracked user data" ] \
    || fail "return transition changed a worktree path"
  pass "return transitions never repurpose worktree paths"
}

test_successful_pool_return_never_mutates_reused_slot() {
  local rec fakebin out status stamp
  rec=$(make_slot_world slot-post-return-reuse)
  read_slot_world "$rec"
  fakebin=$(fm_fakebin "$WORLD/fake")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'treehouse return [--if-lease-holder HOLDER]'
  exit 0
fi
target=${3:-}
git_dir=$(git -C "$target" rev-parse --absolute-git-dir)
[ -f "$git_dir/fm-slot-owner" ] || exit 19
grep -Fx 'task=task-reuse' "$git_dir/fm-slot-owner" >/dev/null || exit 23
common_dir=$(git -C "$target" rev-parse --git-common-dir)
case "$common_dir" in /*) ;; *) common_dir="$target/$common_dir" ;; esac
claim="$common_dir/fm-slot-return-claims/${git_dir##*/}.claim"
[ -f "$claim" ] || exit 20
grep -Fx 'task=task-reuse' "$claim" >/dev/null || exit 21
grep -Fx 'lease_holder=task-reuse' "$claim" >/dev/null || exit 22
transition=$(readlink "$git_dir/fm-slot-owner" 2>/dev/null || true)
[ -n "$transition" ] || exit 24
rm -f "$transition"
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
  fm_fake_exit0 "$fakebin" gh-axi gh
  make_generation_tmux "$fakebin" endpoint-task-reuse
  write_current_meta "$WORLD/home/state/task-reuse.meta" task-reuse "$WORLD/home" endpoint-task-reuse \
    "window=firstmate:fm-task-reuse" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-reuse "$WORLD/home" )
  set +e
  out=$(cd "$ROOT" && env -u NO_MISTAKES_GATE FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD/home" \
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

test_failed_pool_return_never_restores_over_a_reused_slot() {
  local rec fakebin out status stamp
  rec=$(make_slot_world slot-failed-return-reuse)
  read_slot_world "$rec"
  fakebin=$(fm_fakebin "$WORLD/fake")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'treehouse return [--if-lease-holder HOLDER]'
  exit 0
fi
target=${3:-}
git -C "$FM_REUSE_PROJECT" worktree remove --force "$target"
git -C "$FM_REUSE_PROJECT" worktree add --quiet -b failed-return-replacement "$target"
git_dir=$(git -C "$target" rev-parse --absolute-git-dir)
printf 'task=replacement\nhome=%s\n' "$FM_REUSE_HOME" > "$git_dir/fm-slot-owner"
exit 17
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh-axi gh
  make_generation_tmux "$fakebin" endpoint-task-failed-reuse
  write_current_meta "$WORLD/home/state/task-failed-reuse.meta" task-failed-reuse "$WORLD/home" endpoint-task-failed-reuse \
    "window=firstmate:fm-task-failed-reuse" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-failed-reuse "$WORLD/home" )
  set +e
  out=$(cd "$ROOT" && env -u NO_MISTAKES_GATE FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD/home" \
    FM_STATE_OVERRIDE="$WORLD/home/state" FM_DATA_OVERRIDE="$WORLD/home/data" \
    FM_CONFIG_OVERRIDE="$WORLD/home/config" FM_REUSE_PROJECT="$PROJ_DIR" \
    FM_REUSE_HOME="$WORLD/replacement-home" PATH="$fakebin:$PATH" \
    "$TEARDOWN" task-failed-reuse --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "failed reused-slot return unexpectedly succeeded"$'\n'"$out"
  stamp=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_field "$WT_DIR" task || printf none )
  [ "$stamp" = replacement ] \
    || fail "failed return restored stale ownership over replacement: $stamp"
  pass "failed returns never restore ownership over reused slots"
}

test_committed_return_claim_reconciles_after_cleanup_crash() {
  local rec
  rec=$(make_slot_world committed-return-reconcile)
  read_slot_world "$rec"
  (
    local claim legacy marker
    . "$ROOT/bin/fm-slot-owner-lib.sh"
    fm_slot_stamp_write "$WT_DIR" old-task "$WORLD/home"
    fm_slot_stamp_stage_return \
      "$WT_DIR" old-task "$WORLD/home" "$WORLD/home/state" old-task
    claim=$FM_SLOT_RETURN_CLAIM
    legacy=$FM_SLOT_RETURN_LEGACY
    fm_slot_stamp_mark_return_committed "$claim" "$legacy"
    marker=$(fm_slot_stamp_committed_return_path "$claim")
    [ -f "$claim" ] && [ -f "$legacy" ] && [ -f "$marker" ]
    fm_slot_stamp_write "$WT_DIR" new-task "$WORLD/home"
    [ ! -e "$claim" ] && [ ! -e "$legacy" ] && [ ! -e "$marker" ]
    [ "$(fm_slot_stamp_field "$WT_DIR" task)" = new-task ]
  ) || fail "committed return cleanup did not reconcile after a crash"
  pass "committed return claims reconcile before pooled-slot reuse"
}

test_committed_return_cleanup_retries_after_legacy_unlink() {
  local rec
  rec=$(make_slot_world committed-return-retry)
  read_slot_world "$rec"
  (
    local claim legacy marker
    . "$ROOT/bin/fm-slot-owner-lib.sh"
    fm_slot_stamp_write "$WT_DIR" old-task "$WORLD/home"
    fm_slot_stamp_stage_return \
      "$WT_DIR" old-task "$WORLD/home" "$WORLD/home/state" old-task
    claim=$FM_SLOT_RETURN_CLAIM
    legacy=$FM_SLOT_RETURN_LEGACY
    fm_slot_stamp_mark_return_committed "$claim" "$legacy"
    marker=$(fm_slot_stamp_committed_return_path "$claim")
    rm -f "$legacy"
    fm_slot_stamp_write "$WT_DIR" new-task "$WORLD/home"
    [ ! -e "$claim" ] && [ ! -e "$marker" ]
    [ "$(fm_slot_stamp_field "$WT_DIR" task)" = new-task ]
  ) || fail "committed return cleanup could not resume after legacy removal"
  pass "committed return cleanup is restart-safe"
}

test_foreign_committed_return_holder_blocks_reuse() {
  local rec
  rec=$(make_slot_world foreign-committed-holder)
  read_slot_world "$rec"
  (
    local claim legacy marker
    . "$ROOT/bin/fm-slot-owner-lib.sh"
    fm_slot_stamp_write "$WT_DIR" old-task "$WORLD/home"
    fm_slot_stamp_stage_return \
      "$WT_DIR" old-task "$WORLD/home" "$WORLD/home/state" old-task
    claim=$FM_SLOT_RETURN_CLAIM
    legacy=$FM_SLOT_RETURN_LEGACY
    marker=$(fm_slot_stamp_committed_return_path "$claim")
    printf 'task=old-task\nhome=%s\nlease_holder=foreign-task\n' \
      "$WORLD/home" > "$marker"
    rm -f "$claim"
    ! fm_slot_stamp_write "$WT_DIR" new-task "$WORLD/home"
    [ -f "$marker" ] && [ -f "$legacy" ]
  ) || fail "foreign committed-return holder was erased during reconciliation"
  pass "foreign committed-return holders block pooled-slot reuse"
}

test_manual_reclaim_has_no_task_identity_exemption() {
  local rec pid occupants
  rec=$(make_slot_world manual-reclaim-occupant)
  read_slot_world "$rec"
  pid=$(start_declared_agent "$WT_DIR" __manual-reclaim__ "$WORLD/home")
  occupants=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_manual_reclaim_occupants "$WT_DIR" )
  assert_contains "$occupants" "__manual-reclaim__" \
    "manual reclaim excluded a live task that matched its old sentinel identity"
  kill "$pid" 2>/dev/null || true
  pass "manual reclaim never exempts a live task identity"
}

test_malformed_committed_return_marker_blocks_reuse() {
  local rec
  rec=$(make_slot_world malformed-committed-return)
  read_slot_world "$rec"
  (
    local claim legacy marker
    . "$ROOT/bin/fm-slot-owner-lib.sh"
    fm_slot_stamp_write "$WT_DIR" old-task "$WORLD/home"
    fm_slot_stamp_stage_return \
      "$WT_DIR" old-task "$WORLD/home" "$WORLD/home/state" old-task
    claim=$FM_SLOT_RETURN_CLAIM
    legacy=$FM_SLOT_RETURN_LEGACY
    marker=$(fm_slot_stamp_committed_return_path "$claim")
    printf 'malformed\n' > "$marker"
    rm -f "$claim"
    ! fm_slot_stamp_write "$WT_DIR" new-task "$WORLD/home"
    [ -f "$marker" ] && [ -f "$legacy" ]
  ) || fail "malformed committed-return evidence was reconciled or erased"
  pass "pooled-slot reuse validates committed-return schema before reconciliation"
}

test_foreign_transition_holder_retains_before_mutation() {
  local rec claim verdict
  rec=$(make_slot_world slot-foreign-transition-holder)
  read_slot_world "$rec"
  claim=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_return_claim_path "$WT_DIR" )
  mkdir -p "${claim%/*}"
  printf 'task=task-holder\nhome=%s\nlease_holder=foreign-holder\n' \
    "$WORLD/home" > "$claim"
  verdict=$( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_disposal_verdict "$WORLD/home/state" task-holder "$WT_DIR" \
      "$WORLD/home" "$WORLD/home" crewmate )
  assert_contains "$verdict" "transition lease holder foreign-holder, not task-holder" \
    "foreign transition holder passed disposal preflight"
  pass "foreign transition holders retain before teardown mutation"
}

test_ordinary_teardown_acquires_admission_before_task_lock() {
  local rec fakebin ready holder out status stamp
  rec=$(make_slot_world slot-lock-order)
  read_slot_world "$rec"
  fakebin=$(fm_fakebin "$WORLD/fake")
  fm_fake_exit0 "$fakebin" gh-axi gh treehouse
  make_generation_tmux "$fakebin" endpoint-task-e13
  ready="$WORLD/locks.ready"
  write_current_meta "$WORLD/home/state/task-e13.meta" task-e13 "$WORLD/home" endpoint-task-e13 \
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
  assert_contains "$out" "spawn or an older lifecycle operation is still changing $WORLD/home/state" \
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
if [ "\${1:-}" = show-options ]; then
  printf '%s\n' endpoint-task-e14
  exit 0
fi
printf '%s\n' "\$*" >> "$log"
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" gh-axi gh
  mkdir -p "$WORLD/corrupt-project"
  write_current_meta "$WORLD/home/state/task-e14.meta" task-e14 "$WORLD/home" endpoint-task-e14 \
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

test_teardown_refuses_duplicate_core_metadata_before_mutation() {
  local rec fakebin log key out status
  rec=$(make_slot_world teardown-duplicate-core)
  read_slot_world "$rec"
  fakebin=$(fm_fakebin "$WORLD/fake")
  log="$WORLD/tmux.log"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" gh-axi gh treehouse
  for key in worktree window project kind home; do
    write_current_meta "$WORLD/home/state/task-core.meta" task-core "$WORLD/home" endpoint-task-core \
      "window=firstmate:fm-task-core" "worktree=$WT_DIR" "project=$PROJ_DIR" \
      "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
    case "$key" in
      worktree) printf 'worktree=%s\n' "$PROJ_DIR" >> "$WORLD/home/state/task-core.meta" ;;
      window) printf 'window=other:fm-task-core\n' >> "$WORLD/home/state/task-core.meta" ;;
      project) printf 'project=%s\n' "$WT_DIR" >> "$WORLD/home/state/task-core.meta" ;;
      kind) printf 'kind=scout\n' >> "$WORLD/home/state/task-core.meta" ;;
      home)
        printf 'home=%s\nhome=%s\n' "$WORLD/home" "$WORLD/other-home" \
          >> "$WORLD/home/state/task-core.meta"
        ;;
    esac
    set +e
    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD/home" \
      FM_STATE_OVERRIDE="$WORLD/home/state" FM_DATA_OVERRIDE="$WORLD/home/data" \
      FM_CONFIG_OVERRIDE="$WORLD/home/config" PATH="$fakebin:$PATH" \
      "$TEARDOWN" task-core --force 2>&1)
    status=$?
    set -e
    [ "$status" -ne 0 ] || fail "teardown accepted duplicate $key metadata"
    assert_contains "$out" "$key=" "duplicate $key refusal did not identify the field"
    [ -e "$WORLD/home/state/task-core.meta" ] \
      || fail "duplicate $key metadata was removed"
    [ ! -s "$log" ] || fail "duplicate $key metadata authorized endpoint mutation"
  done
  pass "teardown resolves every core metadata field before lifecycle mutation"
}

test_teardown_refuses_stale_endpoint_generation_before_mutation() {
  local rec fakebin log out status
  rec=$(make_slot_world teardown-stale-endpoint)
  read_slot_world "$rec"
  fakebin=$(fm_fakebin "$WORLD/fake")
  log="$WORLD/tmux.log"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\${1:-}" in
  show-options) printf '%s\n' endpoint-recycled ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" gh-axi gh treehouse
  write_current_meta "$WORLD/home/state/task-stale.meta" task-stale "$WORLD/home" endpoint-original \
    "window=firstmate:fm-task-stale" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD/home" \
    FM_STATE_OVERRIDE="$WORLD/home/state" FM_DATA_OVERRIDE="$WORLD/home/data" \
    FM_CONFIG_OVERRIDE="$WORLD/home/config" PATH="$fakebin:$PATH" \
    "$TEARDOWN" task-stale --force 2>&1)
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "teardown accepted a recycled endpoint generation"
  assert_contains "$out" "endpoint generation is stale or cannot be verified" \
    "stale endpoint refusal lost its reason"
  assert_no_grep 'kill-window' "$log" \
    "stale endpoint generation authorized endpoint mutation"
  assert_present "$WORLD/home/state/task-stale.meta" \
    "stale endpoint generation removed task metadata"
  pass "teardown binds endpoint mutation to the recorded generation"
}

test_staged_endpoint_close_is_not_provider_proof() {
  local rec fakebin key record out status=0
  rec=$(make_slot_world teardown-staged-close)
  read_slot_world "$rec"
  fakebin=$(fm_fakebin "$WORLD/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" gh-axi gh treehouse
  write_current_meta "$WORLD/home/state/task-stage.meta" task-stage "$WORLD/home" endpoint-stage \
    "window=firstmate:fm-task-stage" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=scout" "mode=no-mistakes" "yolo=off"
  key=$(printf '%s' 'tmux|firstmate:fm-task-stage|endpoint-stage' \
    | cksum | awk '{printf "%s-%s", $1, $2}')
  record="$WORLD/home/state/.teardown-transactions/task-stage/closing-endpoints/$key"
  mkdir -p "${record%/*}"
  printf '%s\n%s\n%s\n' tmux firstmate:fm-task-stage endpoint-stage > "$record"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD/home" \
    FM_STATE_OVERRIDE="$WORLD/home/state" FM_DATA_OVERRIDE="$WORLD/home/data" \
    FM_CONFIG_OVERRIDE="$WORLD/home/config" PATH="$fakebin:$PATH" \
    "$TEARDOWN" task-stage --force 2>&1) || status=$?
  expect_code 1 "$status" "a pre-close stage record must not prove endpoint closure"
  assert_present "$WORLD/home/state/task-stage.meta" \
    "ambiguous staged close removed task metadata"
  pass "only a post-provider receipt proves endpoint closure"
}

test_receipt_validation_rejects_symlinked_stage_and_malformed_sibling() {
  local txn outside key binding receipt status=0 ID META TEARDOWN_TXN_DIR
  txn="$TMP_ROOT/receipt-validation"
  outside="$TMP_ROOT/receipt-stage-outside"
  ID=task-receipt
  META="$txn/task-receipt.meta"
  TEARDOWN_TXN_DIR="$txn"
  mkdir -p "$txn/closed-endpoints" "$outside"
  printf 'meta\n' > "$META"
  printf 'task=%s\nmeta=%s\nchecksum=1 1\ngeneration=endpoint-proof\nhome=%s\n' \
    "$ID" "$META" "$TMP_ROOT" > "$txn/identity"
  key=$(printf '%s' 'tmux|firstmate:fm-task-receipt|endpoint-proof' \
    | cksum | awk '{printf "%s-%s", $1, $2}')
  printf '%s\n%s\n%s\n' tmux firstmate:fm-task-receipt endpoint-proof > "$outside/$key"
  ln -s "$outside" "$txn/closing-endpoints"
  binding=$(cksum "$txn/identity" | awk '{print $1 " " $2}')
  receipt="$txn/closed-endpoints/$key"
  printf '%s\n%s\n%s\ntransaction=%s\n' \
    tmux firstmate:fm-task-receipt endpoint-proof "$binding" > "$receipt"
  eval "$(awk '
    /^teardown_transaction_receipt_binding\(\)/ { emit=1 }
    /^META=/ { emit=0 }
    emit { print }
  ' "$ROOT/bin/fm-teardown.sh")"
  fm_backend_validate() { [ "$1" = tmux ]; }
  teardown_transaction_crossed_irreversible_boundary || status=$?
  expect_code 2 "$status" "a symlinked staging parent must invalidate its receipt"
  rm "$txn/closing-endpoints"
  mkdir "$txn/closing-endpoints"
  cp "$outside/$key" "$txn/closing-endpoints/$key"
  printf '%s\n' malformed > "$txn/closed-endpoints/malformed-sibling"
  status=0
  teardown_transaction_crossed_irreversible_boundary || status=$?
  expect_code 2 "$status" "a malformed receipt sibling must invalidate the complete set"
  rm "$txn/closed-endpoints/malformed-sibling" "$receipt"
  status=0
  teardown_transaction_receipts_complete || status=$?
  expect_code 1 "$status" "a staged close without its receipt must invalidate commit recovery"
  pass "receipt validation rejects symlinked, malformed, and incomplete proof sets"
}

test_normal_teardown_validates_receipts_before_commit() {
  local receipt_line commit_line
  receipt_line=$(grep -n '^teardown_transaction_receipts_complete || {' "$TEARDOWN" \
    | tail -n 1 | cut -d: -f1)
  commit_line=$(grep -n '^TEARDOWN_COMMIT_TMP=' "$TEARDOWN" | tail -n 1 | cut -d: -f1)
  [ -n "$receipt_line" ] && [ -n "$commit_line" ] \
    && [ "$receipt_line" -lt "$commit_line" ] \
    || fail "normal teardown can commit before complete receipt validation"
  pass "normal teardown validates every receipt before commit and evidence removal"
}

test_teardown_finishes_fallible_cleanup_before_provider_boundaries() {
  local rec fakebin log out status stamp
  rec=$(make_slot_world teardown-live-transaction)
  read_slot_world "$rec"
  fakebin=$(fm_fakebin "$WORLD/fake")
  log="$WORLD/tmux.log"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\${1:-}" in
  show-options) printf '%s\n' endpoint-live ;;
  kill-window)
    [ ! -e "\$FM_ORDER_STATE/task-live.meta" ] || exit 22
    printf '%s\n' close >> "$log"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'treehouse return [--if-lease-holder HOLDER]'
  exit 0
fi
[ -n "$(find "$FM_ORDER_STATE/.teardown-transactions/task-live/closed-endpoints" \
  -type f -print -quit 2>/dev/null)" ] || exit 23
printf '%s\n' return >> "$FM_ORDER_LOG"
exit 0
SH
  chmod +x "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh-axi gh
  write_current_meta "$WORLD/home/state/task-live.meta" task-live "$WORLD/home" endpoint-live \
    "window=firstmate:fm-task-live" "worktree=$WT_DIR" "project=$PROJ_DIR" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  ( . "$ROOT/bin/fm-slot-owner-lib.sh" \
    && fm_slot_stamp_write "$WT_DIR" task-live "$WORLD/home" ) \
    || fail "live transaction fixture could not be stamped"
  set +e
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$WORLD/home" \
    FM_STATE_OVERRIDE="$WORLD/home/state" FM_DATA_OVERRIDE="$WORLD/home/data" \
    FM_CONFIG_OVERRIDE="$WORLD/home/config" FM_ORDER_STATE="$WORLD/home/state" \
    FM_ORDER_LOG="$log" PATH="$fakebin:$PATH" \
    "$TEARDOWN" task-live --force 2>&1)
  status=$?
  set -e
  expect_code 0 "$status" "recoverable live-endpoint teardown failed"$'\n'"$out"
  [ "$(grep -E '^(close|return)$' "$log" | tr '\n' ' ')" = "close return " ] \
    || fail "provider boundaries ran out of order: $(cat "$log")"
  assert_absent "$WORLD/home/state/task-live.meta" \
    "successful teardown retained task metadata"
  pass "teardown completes fallible cleanup before endpoint close and return"
}

test_verification_capture_includes_lifecycle_clears() {
  local doc prefix count
  doc="$ROOT/docs/verification/worker-isolation.md"
  prefix='FM_CONFIG_OVERRIDE= FM_LIFECYCLE_HOME= FM_LIFECYCLE_STATE= FM_LIFECYCLE_SCRIPT='
  count=$(grep -Fc "$prefix" "$doc" 2>/dev/null || true)
  [ "$count" -eq 7 ] \
    || fail "worker-isolation verification has $count lifecycle-clear captures, expected 7"
  pass "worker-isolation verification captures the complete launch prefix"
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
    FM_STATE_OVERRIDE="$1/home/state" "$SWEEP" 2>&1 || true
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
  fm_write_meta "$world/home/state/task-corrupt.meta" \
    "window=firstmate:fm-task-corrupt" "worktree=$world/wt" "project=$world/project" \
    "harness=claude" "kind=ship" "kind=secondmate" "mode=no-mistakes" "yolo=off"
  out=$(run_sweep "$world")
  assert_contains "$out" "kind must appear exactly once" \
    "duplicate kind metadata was silently accepted"
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
  out=$(cd "$ROOT" && env -u NO_MISTAKES_GATE FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
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
  out=$(cd "$ROOT" && env -u NO_MISTAKES_GATE FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
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
  out=$(cd "$ROOT" && env -u NO_MISTAKES_GATE FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
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

test_sweep_reports_collapsed_conflict_alongside_correct_worker() {
  local world out id
  require_procfs || { pass "skip: this host has no readable procfs for collapsed-conflict proof"; return 0; }
  world=$(make_sweep_home sweep-collapsed-conflict)
  id="task-f10-$RUN_TAG"
  fm_write_meta "$world/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$world/wt" "project=$world/project" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "yolo=off"
  start_declared_agent "$world/wt" "$id" "$world/home" crewmate >/dev/null
  start_declared_agent "$world/project" "$id" "$world/home" secondmate >/dev/null
  out=$(run_sweep "$world")
  assert_contains "$out" "ISOLATION: task $id has conflicting worker identity" \
    "a correct worker hid a wrong-role process collapsed into primary"
  assert_contains "$out" "role=secondmate" \
    "the collapsed conflicting identity lost its wrong role"
  pass "the sweep reports collapsed conflicts even beside a correct worker"
}

test_crewmate_declaration_clears_every_inherited_home
test_secondmate_declaration_pins_only_its_own_home
test_declaration_refuses_rather_than_emitting_a_partial_prefix
test_every_verified_harness_launches_with_its_home_declaration
test_secondmate_child_receives_only_its_own_home
test_declared_worker_is_never_a_primary_scope_match
test_unbound_identity_has_no_primary_mutation_authority
test_real_primary_needs_no_ambient_role
test_fresh_primary_requires_durable_session_binding
test_fresh_primary_session_lock_enrolls_atomically
test_caller_marker_cannot_replace_exact_session_authority
test_reparented_markerless_process_has_no_fresh_primary_authority
test_reparented_worker_cannot_trigger_forged_authority_recovery
test_foreign_session_lock_defeats_primary_topology
test_linked_main_worktree_can_prove_primary_authority
test_primary_role_cannot_override_worker_ancestry
test_primary_authority_refuses_unreadable_ancestry
test_stale_session_lock_reaches_verified_recovery
test_unregistered_cross_home_primary_is_refused
test_binding_failure_never_installs_new_session_owner
test_binding_publication_is_verified_before_commit
test_procargs2_parser_separates_argv_and_environment
test_session_authority_recovery_retains_unverified_backup
test_session_authority_recovery_precedes_current_tuple_validation
test_fresh_enrollment_requires_external_capability
test_secondmate_authority_delegation_uses_no_node
test_forged_key_cannot_issue_secondmate_enrollment
test_non_git_cross_home_enrollment_is_refused
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
test_unreadable_agent_candidate_is_indexed_as_unproven
test_spawn_settles_on_proc_evidence_over_a_lying_pane_path
test_slot_stamp_records_ownership_and_never_stamps_a_plain_checkout
test_exact_stamp_clear_accepts_canonical_home_alias
test_clean_ownership_disposes
test_malformed_or_partial_stamp_retains
test_missing_stamp_retains
test_unavailable_occupant_evidence_retains
test_unclassified_live_process_retains
test_undeclared_in_slot_process_retains
test_a_second_recorded_task_retains_the_slot
test_ambiguous_sibling_scope_metadata_retains_the_slot
test_a_stamp_naming_another_task_retains_the_slot
test_a_live_agent_of_another_task_retains_the_slot
test_same_task_in_another_home_or_role_retains_the_slot
test_a_relinquished_slot_requires_remaining_ownership_proof
test_a_stamp_naming_another_task_survives_a_retain_and_still_blocks
test_same_task_stamp_in_another_home_survives_relinquish
test_relinquish_retires_exact_transition_artifacts
test_teardown_retires_a_contested_lease_even_with_force
test_retained_stamp_survives_failed_metadata_retirement
test_stamp_survives_failed_pool_return
test_return_transition_never_uses_a_worktree_path
test_successful_pool_return_never_mutates_reused_slot
test_failed_pool_return_never_restores_over_a_reused_slot
test_committed_return_claim_reconciles_after_cleanup_crash
test_committed_return_cleanup_retries_after_legacy_unlink
test_foreign_committed_return_holder_blocks_reuse
test_malformed_committed_return_marker_blocks_reuse
test_manual_reclaim_has_no_task_identity_exemption
test_foreign_transition_holder_retains_before_mutation
test_ordinary_teardown_acquires_admission_before_task_lock
test_ordinary_teardown_refuses_ambiguous_disposal_before_mutation
test_teardown_refuses_duplicate_core_metadata_before_mutation
test_teardown_refuses_stale_endpoint_generation_before_mutation
test_staged_endpoint_close_is_not_provider_proof
test_receipt_validation_rejects_symlinked_stage_and_malformed_sibling
test_normal_teardown_validates_receipts_before_commit
test_teardown_finishes_fallible_cleanup_before_provider_boundaries
test_verification_capture_includes_lifecycle_clears
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
test_sweep_reports_collapsed_conflict_alongside_correct_worker
test_spawn_claim_abort_clears_only_a_new_exact_claim
test_spawn_refuses_a_foreign_claim_before_slot_mutation

echo "# all fm-worker-isolation tests passed"
