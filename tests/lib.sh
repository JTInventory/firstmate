#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export FM_TEST_PROCESS=1
export TMPDIR=${TMPDIR:-/tmp}
unset FM_AGENT_ROLE FM_AGENT_TASK FM_AGENT_OWNER_HOME
# shellcheck source=/dev/null
. "$ROOT/tests/fm-isolation-test-helpers.sh"

# --- ambient Herdr isolation ------------------------------------------------
#
# A captain who runs behavior tests from inside a live Herdr pane inherits
# HERDR_ENV=1 (and related pane ids). fm_backend_name then auto-selects the
# experimental herdr backend for any spawn that does not pin --backend/FM_BACKEND,
# and secondmate fixtures create real 2ndmate-* workspaces on the default
# session (cwd under /tmp/fm-behavior-tests...). Scrub ambient Herdr runtime
# markers here so single-file and suite runs stay hermetic. Opt-in real-lab
# tests re-export HERDR_SESSION (and may set FM_HERDR_E2E/FM_HERDR_SMOKE) after
# preparing a private fm-lab-* session; they never rely on the captain pane.
#
if [ "${FM_HERDR_ALLOW_AMBIENT:-0}" != 1 ]; then
  unset HERDR_ENV HERDR_SESSION HERDR_PANE_ID HERDR_TAB_ID \
    HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
  if [ -z "${FM_BACKEND:-}" ]; then
    export FM_BACKEND=tmux
  fi
fi

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT. The first call installs the cleanup trap. A test file that needs
# extra teardown (e.g. killing a daemon) should define its own EXIT trap and
# call fm_test_cleanup from inside it so registered dirs are still removed.

FM_TEST_CLEANUP_DIRS=()
FM_TEST_AUTHORITY_BROKER_PIDS=()

fm_test_authority_broker_ensure() {
  local broker=${FM_TEST_AUTHORITY_BROKER_PID:-}
  local fd=${FM_TEST_DURABLE_AUTHORITY_FD:-}
  local fixture_dir=${1:-${TMPDIR:-/tmp}}
  local caller_target broker_target fixture source_fd attempts=0 harness
  case "$broker" in ''|*[!0-9]*) broker= ;; esac
  case "$fd" in ''|*[!0-9]*) fd= ;; esac
  harness=${FM_TEST_AUTHORITY_HARNESS_PID:-}
  if [ -n "$broker" ] && [ -n "$fd" ] \
    && kill -0 "$broker" 2>/dev/null \
    && [ "${FM_TEST_AUTHORITY_HARNESS:-0}" = 1 ] \
    && case "$harness" in ''|*[!0-9]*) false ;; *) kill -0 "$harness" 2>/dev/null ;; esac \
    && [ "$(tr '\0' '\n' < "/proc/$harness/cmdline" 2>/dev/null | sed -n '2p')" = \
      "$ROOT/tests/fm-test-authority-broker.sh" ] \
    && [ "$(ps -o ppid= -p "$broker" 2>/dev/null | tr -d ' ')" = "$harness" ] \
    && caller_target=$(readlink "/proc/$$/fd/$fd" 2>/dev/null) \
    && broker_target=$(readlink "/proc/$broker/fd/$fd" 2>/dev/null) \
    && [ -n "$caller_target" ] && [ "$caller_target" = "$broker_target" ]; then
    return 0
  fi
  unset FM_TEST_AUTHORITY_BROKER_PID FM_TEST_AUTHORITY_OWNER_PID
  FM_TEST_AUTHORITY_FD=${FM_TEST_AUTHORITY_FD:-9}
  FM_TEST_DURABLE_AUTHORITY_FD=${FM_TEST_DURABLE_AUTHORITY_FD:-18}
  export FM_TEST_AUTHORITY_FD FM_TEST_DURABLE_AUTHORITY_FD
  source_fd=$FM_TEST_AUTHORITY_FD
  fixture="$fixture_dir/fm-test-authority-broker.$$.sh"
  cat > "$fixture" <<'SH'
#!/usr/bin/env bash
set -u
while :; do sleep 60; done
SH
  chmod 700 "$fixture"
  broker_pid_file="$fixture.pid"
  (
    if [ "$source_fd" != 19 ]; then
      eval "exec 19<&$source_fd"
    fi
    exec env FM_TEST_PROCESS=1 FM_TEST_AUTHORITY_FD=19 \
      FM_TEST_DURABLE_AUTHORITY_FD=18 \
      FM_TEST_AUTHORITY_HARNESS=1 \
      FM_TEST_AUTHORITY_HARNESS_SCRIPT="$ROOT/tests/fm-test-authority-broker.sh" \
      FM_TEST_AUTHORITY_EXEC_SCRIPT="$ROOT/bin/fm-session-authority-exec.sh" \
      FM_TEST_AUTHORITY_BROKER_PID_FILE="$broker_pid_file" \
      "$ROOT/tests/fm-test-authority-broker.sh" \
      --authority-script "$ROOT/bin/fm-session-authority-exec.sh" "$fixture"
  ) >/dev/null 2>&1 &
  FM_TEST_AUTHORITY_HARNESS_PID=$!
  FM_TEST_AUTHORITY_HARNESS=1
  FM_TEST_AUTHORITY_HARNESS_SCRIPT="$ROOT/tests/fm-test-authority-broker.sh"
  FM_TEST_AUTHORITY_EXEC_SCRIPT="$ROOT/bin/fm-session-authority-exec.sh"
  export FM_TEST_AUTHORITY_HARNESS_PID FM_TEST_AUTHORITY_HARNESS
  export FM_TEST_AUTHORITY_HARNESS_SCRIPT FM_TEST_AUTHORITY_EXEC_SCRIPT
  FM_TEST_AUTHORITY_BROKER_PID=
  export FM_TEST_AUTHORITY_BROKER_PID
  while [ "$attempts" -lt 100 ]; do
    if [ -s "$broker_pid_file" ]; then
      FM_TEST_AUTHORITY_BROKER_PID=$(cat "$broker_pid_file")
      export FM_TEST_AUTHORITY_BROKER_PID
    fi
    case "$FM_TEST_AUTHORITY_BROKER_PID" in
      ''|*[!0-9]*) ;;
      *)
        if kill -0 "$FM_TEST_AUTHORITY_BROKER_PID" 2>/dev/null \
          && [ "$(tr '\0' '\n' < "/proc/$FM_TEST_AUTHORITY_BROKER_PID/cmdline" \
            2>/dev/null | sed -n '2p')" = "$fixture" ]; then
          FM_TEST_AUTHORITY_BROKER_PIDS+=("$FM_TEST_AUTHORITY_BROKER_PID")
          return 0
        fi
        ;;
    esac
    sleep 0.01
    attempts=$((attempts + 1))
  done
  return 1
}

fm_test_primary_authority_setup() {
  local fixture_dir=$1
  fm_test_session_authority_fd "$fixture_dir" \
    && fm_test_authority_broker_ensure "$fixture_dir" \
    || return 1
  # Real-Herdr fixtures invoke guarded commands in several child processes.
  # Keep their synthetic lock owner stable across those invocations while the
  # authority descriptors still prove that the test shell is the issuer.
  FM_TEST_SESSION_LOCK_STABLE_OWNER=1
  FM_TEST_AUTHORITY_OWNER_PID=$$
  export FM_TEST_SESSION_LOCK_STABLE_OWNER FM_TEST_AUTHORITY_OWNER_PID
}

fm_test_primary_identity_bind() {
  local root=$1 home=$2
  local state=${3:-$home/state}
  # shellcheck source=/dev/null
  . "$root/bin/fm-worker-isolation-lib.sh"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_STATE_OVERRIDE="$state" \
    fm_worker_test_primary_identity_bind "$root" "$home" "$state"
}

fm_test_cleanup() {
  local d
  local pid
  for pid in "${FM_TEST_AUTHORITY_BROKER_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
  fi
  FM_TEST_CLEANUP_DIRS+=("$root")
  printf '%s\n' "$root"
}

fm_test_session_authority_fd() {
  local dir=$1 key durable_key inherited_fd inherited_durable_fd
  mkdir -p "$dir"
  key=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
  inherited_fd=${FM_TEST_AUTHORITY_FD:-}
  inherited_durable_fd=${FM_TEST_DURABLE_AUTHORITY_FD:-}
  if [ -n "$inherited_fd" ] && [ -n "$inherited_durable_fd" ]; then
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-session-lock-lib.sh"
    FM_SESSION_AUTHORITY_FD=$inherited_fd
    FM_SESSION_AUTHORITY_DURABLE_FD=$inherited_durable_fd
    if fm_session_authority_capability_present \
      && fm_session_authority_durable_capability_present; then
      export FM_SESSION_AUTHORITY_FD FM_SESSION_AUTHORITY_DURABLE_FD
      return 0
    fi
    unset FM_SESSION_AUTHORITY_FD FM_SESSION_AUTHORITY_DURABLE_FD
  fi
  if ( : <&9 ) 2>/dev/null || ( : <&18 ) 2>/dev/null; then
    FM_SESSION_AUTHORITY_FD=9
    FM_SESSION_AUTHORITY_DURABLE_FD=18
    export FM_SESSION_AUTHORITY_FD FM_SESSION_AUTHORITY_DURABLE_FD
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-session-lock-lib.sh"
    fm_session_authority_capability_present \
      && fm_session_authority_durable_capability_present || {
        echo "test setup: authority descriptors are already in use" >&2
        return 1
    }
    return 0
  fi
  durable_key=fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
  exec 9< <(while :; do printf '%s\n' "$key"; done)
  exec 18< <(while :; do printf '%s\n' "$durable_key"; done)
  FM_SESSION_AUTHORITY_FD=9
  FM_SESSION_AUTHORITY_DURABLE_FD=18
  export FM_SESSION_AUTHORITY_FD FM_SESSION_AUTHORITY_DURABLE_FD
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-session-lock-lib.sh"
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    if [ "$tool" = tmux ]; then
      cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show-options ]; then
  target=
  while [ $# -gt 0 ]; do
    if [ "$1" = -t ]; then shift; target=${1:-}; break; fi
    shift
  done
  printf 'endpoint-%s\n' "${target##*:fm-}"
fi
exit 0
SH
    elif [ "$tool" = treehouse ]; then
      cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ]; then
  printf '%s\n' "${FM_FAKE_TREEHOUSE_RESULT:-${FM_FAKE_PANE_PATH:-${FM_FAKE_WORKTREE:-}}}"
fi
exit 0
SH
    else
      cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    fi
    chmod +x "$fakebin/$tool"
  done
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects]: write the standard
# kind=secondmate meta block used across the secondmate suites. window defaults
# to firstmate:fm-<basename-of-home-dir's parent id>? No - window is explicit;
# defaults to firstmate:fm-domain and projects to alpha to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 window=${3:-} projects=${4:-alpha}
  local id
  id=$(basename "$file" .meta)
  [ -n "$window" ] || window="firstmate:fm-$id"
  fm_write_meta "$file" \
    "window=$window" \
    "worktree=$home" \
    "project=$home" \
    "harness=echo" \
    "kind=secondmate" \
    "task=$id" \
    "endpoint_generation=endpoint-$id" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- launched-agent home declaration ----------------------------------------

# fm_worker_env_prefix <role> <task-id> <home>: the exact home declaration
# bin/fm-spawn.sh prepends to every launch command. Composed from the one owner
# (bin/fm-worker-isolation-lib.sh) so a test pinning a HARNESS TEMPLATE does not
# also re-pin the declaration; tests/fm-worker-isolation.test.sh pins the
# declaration's own bytes.
fm_worker_env_prefix() {
  ( . "$ROOT/bin/fm-worker-isolation-lib.sh" && fm_worker_launch_env_prefix "$@" )
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
