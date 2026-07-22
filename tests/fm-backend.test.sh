#!/usr/bin/env bash
# Runtime backend P1 unit coverage. The fake tmux records dispatch calls so
# this suite proves the selector/metadata contract without requiring a live
# firstmate session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-tests)

# fm_backend_detect's cmux fallback (bundle id + process ancestry,
# docs/cmux-backend.md "Runtime auto-detection") consults uname, lsappinfo,
# and ps. FAKE_NONDARWIN_BIN pins uname to Linux so the whole fallback is
# deterministically inert for every assertion that expects NO detection,
# regardless of the ambient runtime this suite itself executes inside (a real
# cmux tab would otherwise leak a bundle-id or ancestry match into results).
FAKE_NONDARWIN_BIN="$TMP_ROOT/fake-nondarwin-bin"
mkdir -p "$FAKE_NONDARWIN_BIN"
printf '#!/bin/sh\necho Linux\n' > "$FAKE_NONDARWIN_BIN/uname"
chmod +x "$FAKE_NONDARWIN_BIN/uname"

# make_cmux_fallback_fakebin: PATH fakes for the DETECTING side of the cmux
# fallback - uname pinned to Darwin, lsappinfo echoing $FM_FAKE_LSAPPINFO_OUT
# (empty output mirrors the real lsappinfo's app-not-running behavior: prints
# nothing, exit 0), and a ps answering `-o ppid=/-o comm= -p <pid>` from the
# tab-separated "pid ppid comm" table file named by $FM_FAKE_PS_TABLE.
make_cmux_fallback_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin-cmux-fallback"
  mkdir -p "$fb"
  printf '#!/bin/sh\necho Darwin\n' > "$fb/uname"
  cat > "$fb/lsappinfo" <<'SH'
#!/bin/sh
[ -n "${FM_FAKE_LSAPPINFO_OUT:-}" ] && printf '%s\n' "$FM_FAKE_LSAPPINFO_OUT"
exit 0
SH
  cat > "$fb/ps" <<'SH'
#!/bin/sh
# supports exactly: ps -o ppid= -p <pid> / ps -o comm= -p <pid>
field=${2:-} pid=${4:-}
while IFS="	" read -r tpid tppid tcomm; do
  if [ "$tpid" = "$pid" ]; then
    case "$field" in
      ppid=) printf '%s\n' "$tppid" ;;
      comm=) printf '%s\n' "$tcomm" ;;
    esac
    exit 0
  fi
done < "${FM_FAKE_PS_TABLE:?}"
exit 1
SH
  chmod +x "$fb/uname" "$fb/lsappinfo" "$fb/ps"
  printf '%s\n' "$fb"
}

# The commit this branch started from - the P1 "current main" baseline.
resolve_base_ref() {
  local ref base
  for ref in main refs/heads/main origin/main refs/remotes/origin/main origin/HEAD refs/remotes/origin/HEAD; do
    if git -C "$ROOT" rev-parse --verify -q "$ref^{commit}" >/dev/null; then
      base=$(git -C "$ROOT" merge-base HEAD "$ref" 2>/dev/null) || continue
      [ -n "$base" ] || continue
      printf '%s\n' "$base"
      return 0
    fi
  done
  return 1
}
BASE_REF=$(resolve_base_ref) \
  || fail "fm-backend baseline requires local main or origin/main; fetch the default branch before running this test"

# --- shared: a pre-refactor bin/ shim --------------------------------------
#
# build_old_bin echoes a directory whose bin/ subdir holds the PRE-REFACTOR
# fm-send.sh, fm-peek.sh, fm-watch.sh, fm-spawn.sh, and fm-teardown.sh
# (extracted from BASE_REF), plus copies of every OTHER sibling script those
# five source - all unchanged by this task, so the copied files are exactly
# what BASE_REF would have used too. Copies keep BASH_SOURCE-based sibling
# resolution inside the synthetic tree on both macOS and Linux; symlinks make
# that resolution shell/platform-dependent. FM_ROOT_OVERRIDE pointed at this dir's
# root makes "$FM_ROOT/bin/fm-project-mode.sh" (etc.) resolve correctly.
# fm-backend.sh (and its bin/backends/ adapters) is the dispatcher every one
# of the five REFACTORED scripts sources; it must be a real, reachable file in
# the old bin/ too or `. "$SCRIPT_DIR/fm-backend.sh"` aborts under set -eu -
# hence it is a copied sibling, not an extracted-from-BASE_REF file: for a
# tmux-only conformance run the tmux adapter's behavior is what is under test,
# and that is unchanged by any later (e.g. non-tmux backend) addition to
# fm-backend.sh's own dispatch surface.
OLD_BIN_UNCHANGED_SIBLINGS="fm-gate-refuse-lib.sh fm-guard.sh fm-lock-lib.sh fm-tasks-axi-lib.sh fm-pr-lib.sh fm-tangle-lib.sh fm-tmux-lib.sh fm-composer-lib.sh fm-marker-lib.sh fm-wake-lib.sh fm-classify-lib.sh fm-supervision-lib.sh fm-ff-lib.sh fm-config-inherit-lib.sh fm-project-mode.sh fm-harness.sh fm-crew-state.sh fm-decision-hold.sh fm-backend.sh"
# A pull-request merge may add a new main-only dependency that the branch's older baseline does not have yet.
OLD_BIN_OPTIONAL_SIBLINGS="fm-pending-reply-lib.sh"
OLD_BIN_REFACTORED="fm-send.sh fm-peek.sh fm-watch.sh fm-spawn.sh fm-teardown.sh"

build_old_bin() {  # <name> -> echoes root dir (root/bin/<script> is the entry point)
  local name=$1 root bin f
  root="$TMP_ROOT/$name"
  bin="$root/bin"
  mkdir -p "$bin"
  for f in $OLD_BIN_UNCHANGED_SIBLINGS; do
    cp "$ROOT/bin/$f" "$bin/$f"
  done
  for f in $OLD_BIN_OPTIONAL_SIBLINGS; do
    [ -f "$ROOT/bin/$f" ] || continue
    cp "$ROOT/bin/$f" "$bin/$f"
  done
  cp -R "$ROOT/bin/backends" "$bin/backends"
  for f in $OLD_BIN_REFACTORED; do
    git -C "$ROOT" show "$BASE_REF:bin/$f" > "$bin/$f"
    chmod +x "$bin/$f"
  done
  printf '%s\n' "$root"
}

# --- fm-backend.sh unit tests ------------------------------------------------

test_backend_name_precedence() {
  local dir cfg
  dir="$TMP_ROOT/name-precedence"; cfg="$dir/config"
  mkdir -p "$cfg"

  # TMUX/HERDR_ENV/CMUX_WORKSPACE_ID explicitly unset in a subshell so this
  # stays deterministic regardless of the runtime this test suite itself
  # happens to execute inside (e.g. a real tmux pane, which is the normal case
  # for a captain's session).
  # fm_backend_name reads FM_BACKEND_CONFIG_DIR (bound once, at fm-backend.sh
  # source time, from FM_CONFIG_OVERRIDE); a later FM_CONFIG_OVERRIDE=... prefix
  # on the function call itself does not re-bind it, so these calls set
  # FM_BACKEND_CONFIG_DIR directly.
  [ "$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier; PATH="$FAKE_NONDARWIN_BIN:$PATH" FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)" = tmux ] \
    || fail "fm_backend_name should default to tmux with no env/config/detection markers"

  printf 'tmux\n' > "$cfg/backend"
  [ "$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)" = tmux ] \
    || fail "fm_backend_name should read config/backend"

  [ "$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; FM_BACKEND=tmux FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)" = tmux ] \
    || fail "FM_BACKEND env should win over config/backend"

  pass "fm_backend_name: FM_BACKEND env > config/backend > default tmux"
}

# fm_backend_detect: environment-marker runtime auto-detection (mirrors
# fm-harness.sh's detect_own layer). Every case explicitly controls TMUX,
# HERDR_ENV, and CMUX_WORKSPACE_ID - and, where no detection is expected, the
# cmux fallback inputs (__CFBundleIdentifier plus a non-Darwin uname fake) -
# so results never depend on the ambient shell this suite runs inside (a real
# tmux pane or cmux tab, both normal cases for a captain's session).
test_backend_detect_precedence() {
  local out

  if out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier; PATH="$FAKE_NONDARWIN_BIN:$PATH" fm_backend_detect); then
    fail "fm_backend_detect should return 1 (undetected) with no markers set, got '$out'"
  fi

  out=$(unset TMUX CMUX_WORKSPACE_ID; HERDR_ENV=1 fm_backend_detect) \
    || fail "fm_backend_detect should succeed when HERDR_ENV=1"
  [ "$out" = herdr ] || fail "fm_backend_detect should report herdr for HERDR_ENV=1 alone, got '$out'"

  out=$(unset HERDR_ENV CMUX_WORKSPACE_ID; TMUX='fake,1,0' fm_backend_detect) \
    || fail "fm_backend_detect should succeed when \$TMUX is set"
  [ "$out" = tmux ] || fail "fm_backend_detect should report tmux for \$TMUX alone, got '$out'"

  out=$(unset TMUX HERDR_ENV; CMUX_WORKSPACE_ID='fake-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed when CMUX_WORKSPACE_ID is set"
  [ "$out" = cmux ] || fail "fm_backend_detect should report cmux for CMUX_WORKSPACE_ID alone, got '$out'"

  # Nesting: tmux started inside a herdr pane carries BOTH markers. Innermost
  # (tmux) must win, since that is the surface firstmate is actually running on.
  out=$(unset CMUX_WORKSPACE_ID; TMUX='fake,1,0' HERDR_ENV=1 fm_backend_detect) \
    || fail "fm_backend_detect should succeed with both markers present"
  [ "$out" = tmux ] || fail "fm_backend_detect should resolve nesting innermost-first (tmux over herdr), got '$out'"

  # Nesting: tmux started inside a cmux-provided shell carries BOTH markers.
  # cmux is a terminal application, not a nestable multiplexer, so the
  # innermost multiplexer (tmux) must still win.
  out=$(unset HERDR_ENV; TMUX='fake,1,0' CMUX_WORKSPACE_ID='fake-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed with tmux and cmux markers present"
  [ "$out" = tmux ] || fail "fm_backend_detect should resolve nesting innermost-first (tmux over cmux), got '$out'"

  # Nesting: herdr started inside a cmux-provided shell carries BOTH markers.
  # Same reasoning: herdr (the innermost multiplexer) must win over cmux.
  out=$(unset TMUX; HERDR_ENV=1 CMUX_WORKSPACE_ID='fake-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed with herdr and cmux markers present"
  [ "$out" = herdr ] || fail "fm_backend_detect should resolve nesting innermost-first (herdr over cmux), got '$out'"

  # Pathological: all three markers present. tmux still wins (innermost of all).
  out=$(TMUX='fake,1,0' HERDR_ENV=1 CMUX_WORKSPACE_ID='fake-uuid' fm_backend_detect) \
    || fail "fm_backend_detect should succeed with all three markers present"
  [ "$out" = tmux ] || fail "fm_backend_detect should resolve nesting innermost-first with all three markers (tmux wins), got '$out'"

  pass "fm_backend_detect: no markers -> undetected, HERDR_ENV=1 -> herdr, \$TMUX -> tmux, CMUX_WORKSPACE_ID -> cmux, nested combinations resolve innermost-first"
}

# fm_backend_detect's cmux FALLBACK signals (docs/cmux-backend.md "Runtime
# auto-detection"): cmux's bundled claude wrapper strips every CMUX_* env var
# on its passthrough path, so a claude-under-cmux firstmate has no
# CMUX_WORKSPACE_ID; detection then falls back to __CFBundleIdentifier and,
# after that, a process-ancestry walk - macOS-only, and never outranking the
# $TMUX/HERDR_ENV innermost-first checks.
test_backend_detect_cmux_fallback_bundle_id() {
  local dir fb out
  dir="$TMP_ROOT/detect-fallback-bundle"; mkdir -p "$dir"
  fb=$(make_cmux_fallback_fakebin "$dir")

  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; PATH="$fb:$PATH" __CFBundleIdentifier='com.cmuxterm.app' fm_backend_detect) \
    || fail "fm_backend_detect should fall back to the cmux bundle id when CMUX_WORKSPACE_ID is absent"
  [ "$out" = cmux ] || fail "bundle-id fallback should report cmux, got '$out'"

  (
    unset TMUX HERDR_ENV CMUX_WORKSPACE_ID
    PATH="$fb:$PATH" __CFBundleIdentifier='com.cmuxterm.app' fm_backend_detect >/dev/null || exit 1
    [ "$FM_BACKEND_DETECT_SIGNAL" = bundle-id ] || exit 2
  ) || fail "bundle-id fallback should set FM_BACKEND_DETECT_SIGNAL=bundle-id (subshell exit $?)"

  # A foreign bundle id (an ordinary terminal app) must not match.
  if out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; PATH="$fb:$PATH" FM_FAKE_PS_TABLE="$dir/no-table" __CFBundleIdentifier='com.apple.Terminal' fm_backend_detect); then
    fail "a non-cmux __CFBundleIdentifier should not detect cmux, got '$out'"
  fi

  pass "fm_backend_detect: falls back to __CFBundleIdentifier=com.cmuxterm.app when CMUX_WORKSPACE_ID is absent (signal bundle-id; foreign bundle ids rejected)"
}

test_backend_detect_cmux_fallback_requires_darwin() {
  local out
  if out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; PATH="$FAKE_NONDARWIN_BIN:$PATH" __CFBundleIdentifier='com.cmuxterm.app' fm_backend_detect); then
    fail "the cmux fallback must be macOS-only (cmux itself is), got '$out' on a non-Darwin uname"
  fi
  pass "fm_backend_detect: the cmux fallback signals are macOS-only (inert on a non-Darwin uname)"
}

# The false positive the innermost-first ordering must keep absorbing: a tmux
# server started from a cmux tab inherits __CFBundleIdentifier=com.cmuxterm.app
# into every pane (verified live, docs/cmux-backend.md), so the bundle-id
# fallback WILL match inside such panes - $TMUX winning first is what keeps
# the result correct. Same for a herdr pane whose server was started from a
# cmux tab.
test_backend_detect_cmux_fallback_tmux_nested_false_positive() {
  local dir fb out
  dir="$TMP_ROOT/detect-fallback-nested"; mkdir -p "$dir"
  fb=$(make_cmux_fallback_fakebin "$dir")

  out=$(unset HERDR_ENV CMUX_WORKSPACE_ID; PATH="$fb:$PATH" TMUX='fake,1,0' __CFBundleIdentifier='com.cmuxterm.app' fm_backend_detect) \
    || fail "fm_backend_detect should still succeed with \$TMUX plus an inherited cmux bundle id"
  [ "$out" = tmux ] || fail "\$TMUX must win over an inherited cmux bundle id (tmux-inside-cmux pane), got '$out'"

  out=$(unset TMUX CMUX_WORKSPACE_ID; PATH="$fb:$PATH" HERDR_ENV=1 __CFBundleIdentifier='com.cmuxterm.app' fm_backend_detect) \
    || fail "fm_backend_detect should still succeed with HERDR_ENV=1 plus an inherited cmux bundle id"
  [ "$out" = herdr ] || fail "HERDR_ENV=1 must win over an inherited cmux bundle id (herdr-inside-cmux pane), got '$out'"

  pass "fm_backend_detect: an inherited cmux bundle id never outranks \$TMUX or HERDR_ENV (tmux/herdr-inside-cmux false positive absorbed)"
}

test_backend_detect_cmux_fallback_ancestry_pid_match() {
  local dir fb table
  dir="$TMP_ROOT/detect-ancestry-pid"; mkdir -p "$dir"
  fb=$(make_cmux_fallback_fakebin "$dir")
  table="$dir/ps-table"
  # $$ is this test script's own pid - the walk starts there. The cmux app
  # pid (66666) is matched via the lsappinfo bundle-id resolution, with a
  # deliberately non-standard install path so only the pid can match.
  printf '%s\t77777\t/bin/zsh\n77777\t66666\t/usr/bin/login\n66666\t1\t/Users/x/Custom.app/Contents/MacOS/custom\n' "$$" > "$table"

  (
    unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier
    PATH="$fb:$PATH" FM_FAKE_PS_TABLE="$table" FM_FAKE_LSAPPINFO_OUT='"pid"=66666' fm_backend_detect >/dev/null || exit 1
    [ "$FM_BACKEND_DETECTED" = cmux ] || exit 2
    [ "$FM_BACKEND_DETECT_SIGNAL" = ancestry ] || exit 3
  ) || fail "ancestry fallback should detect cmux via the lsappinfo-resolved app pid (subshell exit $?)"

  pass "fm_backend_detect: ancestry fallback matches the lsappinfo-resolved (bundle-id) cmux app pid in the parent chain"
}

test_backend_detect_cmux_fallback_ancestry_comm_match() {
  local dir fb table
  dir="$TMP_ROOT/detect-ancestry-comm"; mkdir -p "$dir"
  fb=$(make_cmux_fallback_fakebin "$dir")
  table="$dir/ps-table"
  # lsappinfo resolves nothing (empty output, like the real one for a
  # non-running or non-GUI-visible app); the bundle-shaped comm path is the
  # remaining match, at a non-/Applications install location on purpose.
  printf '%s\t77777\t/bin/zsh\n77777\t66666\t/usr/bin/login\n66666\t1\t/Users/x/Applications/cmux.app/Contents/MacOS/cmux\n' "$$" > "$table"

  (
    unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier FM_FAKE_LSAPPINFO_OUT
    PATH="$fb:$PATH" FM_FAKE_PS_TABLE="$table" fm_backend_detect >/dev/null || exit 1
    [ "$FM_BACKEND_DETECTED" = cmux ] || exit 2
    [ "$FM_BACKEND_DETECT_SIGNAL" = ancestry ] || exit 3
  ) || fail "ancestry fallback should detect cmux via a bundle-shaped comm path when lsappinfo resolves nothing (subshell exit $?)"

  pass "fm_backend_detect: ancestry fallback matches a bundle-shaped cmux comm path at any install location when lsappinfo cannot resolve a pid"
}

# From inside tmux, ancestry can never reach cmux: the tmux server reparents
# to launchd (verified live - the reference machine's own tmux server, started
# from a cmux tab, has ppid 1), so the walk stops at ppid 1 undetected. This
# pins the walk's launchd stop as the structural guarantee behind that.
test_backend_detect_cmux_fallback_ancestry_stops_at_launchd() {
  local dir fb table out
  dir="$TMP_ROOT/detect-ancestry-stop"; mkdir -p "$dir"
  fb=$(make_cmux_fallback_fakebin "$dir")
  table="$dir/ps-table"
  printf '%s\t77777\t/bin/zsh\n77777\t1\ttmux\n' "$$" > "$table"

  if out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier FM_FAKE_LSAPPINFO_OUT; PATH="$fb:$PATH" FM_FAKE_PS_TABLE="$table" fm_backend_detect); then
    fail "ancestry fallback should stop undetected at a launchd-reparented chain, got '$out'"
  fi
  pass "fm_backend_detect: ancestry fallback stops undetected at launchd (a reparented tmux server never reaches cmux)"
}

# The auto-detect NOTICE must say when cmux was selected via a fallback
# signal, so a captain can tell a wrapper-stripped claude-under-cmux spawn
# apart from the primary-marker case.
test_backend_name_cmux_fallback_notice() {
  local dir cfg fb out errfile
  dir="$TMP_ROOT/name-fallback-notice"; cfg="$dir/config-empty"; mkdir -p "$cfg"
  fb=$(make_cmux_fallback_fakebin "$dir")
  errfile="$dir/err.txt"

  : > "$errfile"
  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID; PATH="$fb:$PATH" __CFBundleIdentifier='com.cmuxterm.app' FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = cmux ] || fail "fm_backend_name should auto-detect cmux via the bundle-id fallback, got '$out'"
  assert_contains "$(cat "$errfile")" "FALLBACK signal __CFBundleIdentifier" \
    "the fallback-detected cmux notice did not name the bundle-id fallback signal"
  assert_contains "$(cat "$errfile")" "EXPERIMENTAL cmux backend" \
    "the fallback-detected cmux notice lost the experimental warning"
  assert_contains "$(cat "$errfile")" "--backend tmux" \
    "the fallback-detected cmux notice lost the opt-out"

  # The primary-marker notice is unchanged: it names CMUX_WORKSPACE_ID and
  # carries no FALLBACK wording.
  : > "$errfile"
  out=$(unset TMUX HERDR_ENV; CMUX_WORKSPACE_ID='fake-uuid' FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = cmux ] || fail "fm_backend_name should auto-detect cmux from CMUX_WORKSPACE_ID, got '$out'"
  assert_contains "$(cat "$errfile")" "(CMUX_WORKSPACE_ID)" \
    "the primary-marker cmux notice no longer names CMUX_WORKSPACE_ID"
  case "$(cat "$errfile")" in
    *FALLBACK*) fail "the primary-marker cmux notice must not carry FALLBACK wording" ;;
  esac

  pass "fm_backend_name: a fallback-detected cmux prints a NOTICE naming the fallback signal; the primary-marker notice is unchanged"
}

# fm_backend_name's auto-detect step: fires only when FM_BACKEND/config/backend
# are both absent, selects between the three markers exactly as
# fm_backend_detect does, and is loud only when it selects herdr or cmux -
# never when it selects tmux (today's default-path behavior must stay
# byte-for-byte silent).
test_backend_name_autodetect_notice() {
  local dir cfg out errfile

  dir="$TMP_ROOT/name-autodetect"; cfg="$dir/config-empty"; mkdir -p "$cfg"
  errfile="$dir/err.txt"

  : > "$errfile"
  out=$(unset TMUX HERDR_ENV CMUX_WORKSPACE_ID __CFBundleIdentifier; PATH="$FAKE_NONDARWIN_BIN:$PATH" FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = tmux ] || fail "fm_backend_name should default to tmux with no detection markers, got '$out'"
  [ -s "$errfile" ] && fail "fm_backend_name must stay silent with no detection markers"$'\n'"$(cat "$errfile")"

  : > "$errfile"
  out=$(unset TMUX CMUX_WORKSPACE_ID; HERDR_ENV=1 FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = herdr ] || fail "fm_backend_name should auto-detect herdr from HERDR_ENV=1, got '$out'"
  assert_contains "$(cat "$errfile")" "EXPERIMENTAL herdr backend" \
    "fm_backend_name did not print a loud notice when auto-detecting herdr"
  assert_contains "$(cat "$errfile")" "config/backend" \
    "fm_backend_name's auto-detect notice did not name the opt-out"

  : > "$errfile"
  out=$(unset HERDR_ENV CMUX_WORKSPACE_ID; TMUX='fake,1,0' FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = tmux ] || fail "fm_backend_name should auto-detect tmux from \$TMUX, got '$out'"
  [ -s "$errfile" ] && fail "auto-detecting tmux must stay silent (today's unchanged default-path behavior)"$'\n'"$(cat "$errfile")"

  : > "$errfile"
  out=$(unset TMUX HERDR_ENV; CMUX_WORKSPACE_ID='fake-uuid' FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = cmux ] || fail "fm_backend_name should auto-detect cmux from CMUX_WORKSPACE_ID, got '$out'"
  assert_contains "$(cat "$errfile")" "EXPERIMENTAL cmux backend" \
    "fm_backend_name did not print a loud notice when auto-detecting cmux"
  assert_contains "$(cat "$errfile")" "config/backend" \
    "fm_backend_name's cmux auto-detect notice did not name the opt-out"
  assert_contains "$(cat "$errfile")" "--backend tmux" \
    "fm_backend_name's cmux auto-detect notice did not name the --backend tmux opt-out"

  : > "$errfile"
  out=$(unset CMUX_WORKSPACE_ID; TMUX='fake,1,0' HERDR_ENV=1 FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = tmux ] || fail "nested tmux-in-herdr should auto-detect tmux (innermost first), got '$out'"
  [ -s "$errfile" ] && fail "nested tmux-in-herdr auto-detect (result tmux) must stay silent"$'\n'"$(cat "$errfile")"

  : > "$errfile"
  out=$(unset HERDR_ENV; TMUX='fake,1,0' CMUX_WORKSPACE_ID='fake-uuid' FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name 2>"$errfile")
  [ "$out" = tmux ] || fail "nested tmux-in-cmux should auto-detect tmux (innermost first), got '$out'"
  [ -s "$errfile" ] && fail "nested tmux-in-cmux auto-detect (result tmux) must stay silent"$'\n'"$(cat "$errfile")"

  pass "fm_backend_name: auto-detect selects herdr or cmux (loud notice) or tmux (silent, including nested tmux-in-herdr/tmux-in-cmux)"
}

# Explicit configuration (FM_BACKEND env or config/backend) always wins over
# runtime auto-detection, even when a detection marker points the other way.
test_backend_name_explicit_beats_detection() {
  local dir cfg out

  dir="$TMP_ROOT/name-explicit-beats-detect"
  cfg="$dir/config-tmux"; mkdir -p "$cfg"; printf 'tmux\n' > "$cfg/backend"
  mkdir -p "$dir/config-empty"

  # fm_backend_name reads FM_BACKEND_CONFIG_DIR (bound once, at fm-backend.sh
  # source time, from FM_CONFIG_OVERRIDE); a later FM_CONFIG_OVERRIDE=... prefix
  # on the function call itself does not re-bind it, so these calls set
  # FM_BACKEND_CONFIG_DIR directly to control which config dir is checked.
  out=$(unset TMUX; HERDR_ENV=1 FM_BACKEND=tmux FM_BACKEND_CONFIG_DIR="$dir/config-empty" fm_backend_name)
  [ "$out" = tmux ] || fail "FM_BACKEND=tmux should win over an ambient HERDR_ENV=1 auto-detect marker, got '$out'"

  out=$(unset TMUX; HERDR_ENV=1 FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)
  [ "$out" = tmux ] || fail "config/backend=tmux should win over an ambient HERDR_ENV=1 auto-detect marker, got '$out'"

  # The same opt-out must work for an ambient cmux auto-detect marker: a
  # captain who is running firstmate inside a cmux terminal but explicitly
  # wants tmux is never overridden by CMUX_WORKSPACE_ID.
  out=$(unset TMUX HERDR_ENV; CMUX_WORKSPACE_ID='fake-uuid' FM_BACKEND=tmux FM_BACKEND_CONFIG_DIR="$dir/config-empty" fm_backend_name)
  [ "$out" = tmux ] || fail "FM_BACKEND=tmux should win over an ambient CMUX_WORKSPACE_ID auto-detect marker, got '$out'"

  out=$(unset TMUX HERDR_ENV; CMUX_WORKSPACE_ID='fake-uuid' FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)
  [ "$out" = tmux ] || fail "config/backend=tmux should win over an ambient CMUX_WORKSPACE_ID auto-detect marker, got '$out'"

  pass "fm_backend_name: an explicit FM_BACKEND or config/backend setting always wins over runtime auto-detection, including an ambient cmux marker"
}

test_backend_validate_refuses_unknown() {
  fm_backend_validate tmux 2>/dev/null || fail "fm_backend_validate should accept tmux"
  fm_backend_validate orca 2>/dev/null || fail "fm_backend_validate should accept orca"
  local out
  # bogus names a backend with no adapter at all; tmux, herdr, zellij, orca,
  # and cmux are all known adapters and spawn-supported.
  out=$(fm_backend_validate bogus 2>&1) && fail "fm_backend_validate should refuse bogus (no such adapter)"
  assert_contains "$out" "unknown backend 'bogus'" "fm_backend_validate did not name the rejected backend"
  out=$(fm_backend_validate codex-app 2>&1) && fail "fm_backend_validate should refuse codex-app"
  assert_contains "$out" "unknown backend 'codex-app'" "fm_backend_validate accepted codex-app"
  out=$(fm_backend_validate "tmux herdr" 2>&1) && fail "fm_backend_validate should refuse a multi-token backend name"
  assert_contains "$out" "unknown backend 'tmux herdr'" "fm_backend_validate accepted a multi-token backend name"
  pass "fm_backend_validate: implemented adapters accepted, unknown and blocked codex-app backends refused loudly"
}

test_backend_source_shell_portable() {
  local out status
  # zsh does not word-split unquoted expansions; sourcing fm-backend.sh from
  # an interactive zsh session must still recognize known backend names.
  if command -v zsh >/dev/null 2>&1; then
    zsh -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source herdr && whence -w fm_backend_herdr_capture >/dev/null" 2>/dev/null \
      || fail "zsh: fm_backend_source herdr should load the adapter when sourced"
    out=$(zsh -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source bogus" 2>&1) \
      && fail "zsh: fm_backend_source bogus should fail"
    assert_contains "$out" "unknown backend 'bogus'" \
      "zsh: fm_backend_source did not reject bogus with the expected error"
    pass "zsh: fm_backend_source recognizes known backends and rejects unknown ones"
  else
    pass "zsh: shell-portable backend matching skipped (zsh not found)"
  fi

  bash -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source herdr && declare -F fm_backend_herdr_capture >/dev/null" 2>/dev/null \
    || fail "bash: fm_backend_source herdr should load the adapter when sourced"
  out=$(bash -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source bogus" 2>&1) \
    && fail "bash: fm_backend_source bogus should fail"
  assert_contains "$out" "unknown backend 'bogus'" \
    "bash: fm_backend_source did not reject bogus with the expected error"
  pass "bash: fm_backend_source recognizes known backends and rejects unknown ones"
}

test_backend_validate_spawn_accepts_orca() {
  local out
  fm_backend_validate_spawn tmux 2>/dev/null || fail "fm_backend_validate_spawn should accept tmux"
  fm_backend_validate_spawn herdr 2>/dev/null || fail "fm_backend_validate_spawn should accept herdr"
  fm_backend_validate_spawn zellij 2>/dev/null || fail "fm_backend_validate_spawn should accept zellij"
  fm_backend_validate_spawn orca 2>/dev/null || fail "fm_backend_validate_spawn should accept orca"
  fm_backend_validate_spawn cmux 2>/dev/null || fail "fm_backend_validate_spawn should accept cmux"
  out=$(fm_backend_validate_spawn bogus 2>&1) && fail "fm_backend_validate_spawn should still refuse unknown backends"
  assert_contains "$out" "unknown backend 'bogus'" "fm_backend_validate_spawn did not preserve unknown-backend validation"
  out=$(fm_backend_validate_spawn codex-app 2>&1) && fail "fm_backend_validate_spawn should refuse codex-app"
  assert_contains "$out" "unknown backend 'codex-app'" "fm_backend_validate_spawn accepted codex-app"
  out=$(fm_backend_validate_spawn "tmux herdr" 2>&1) && fail "fm_backend_validate_spawn should refuse a multi-token backend name"
  assert_contains "$out" "unknown backend 'tmux herdr'" "fm_backend_validate_spawn accepted a multi-token backend name"
  pass "fm_backend_validate_spawn: all implemented lifecycle backends are spawn-supported"
}

test_meta_get_and_backend_of_meta() {
  local meta=$TMP_ROOT/meta-get.meta
  fm_write_meta "$meta" "window=firstmate:fm-x1" "harness=claude"
  [ "$(fm_meta_get "$meta" window)" = "firstmate:fm-x1" ] || fail "fm_meta_get did not read window="
  [ "$(fm_meta_get "$meta" missing)" = "" ] || fail "fm_meta_get should print nothing for an absent key"
  [ "$(fm_backend_of_meta "$meta")" = tmux ] || fail "fm_backend_of_meta should default absent backend= to tmux"

  printf 'backend=tmux\n' >> "$meta"
  [ "$(fm_backend_of_meta "$meta")" = tmux ] || fail "fm_backend_of_meta should read an explicit backend=tmux"

  pass "fm_meta_get / fm_backend_of_meta: read key=value, default backend to tmux"
}

test_resolve_selector_three_forms() {
  local state=$TMP_ROOT/resolve-state fakebin out
  mkdir -p "$state"
  fm_write_meta "$state/task1.meta" "window=firstmate:fm-task1"
  fm_write_meta "$state/dotfiles-d6.meta" "window=default:wA:p2" "backend=herdr"
  fm_write_meta "$state/fm-turnend-all-harnesses-v9.meta" "window=default:wB:p3" "backend=herdr"

  [ "$(fm_backend_resolve_selector 'sess:win' "$state")" = "sess:win" ] \
    || fail "explicit session:window should be used as-is"

  [ "$(fm_backend_resolve_selector 'dotfiles-d6' "$state")" = "default:wA:p2" ] \
    || fail "bare non-fm task id should resolve through exact metadata"
  [ "$(fm_backend_of_selector 'dotfiles-d6' 'default:wA:p2' "$state")" = herdr ] \
    || fail "bare non-fm task id should use its recorded backend"
  [ "$(fm_backend_expected_label_of_selector 'dotfiles-d6' "$state")" = "fm-dotfiles-d6" ] \
    || fail "bare non-fm task id should report the spawned fm-<id> label"

  [ "$(fm_backend_resolve_selector 'fm-turnend-all-harnesses-v9' "$state")" = "default:wB:p3" ] \
    || fail "exact fm-* task id should resolve through its exact metadata"
  [ "$(fm_backend_of_selector 'fm-turnend-all-harnesses-v9' 'default:wB:p3' "$state")" = herdr ] \
    || fail "exact fm-* task id should use exact metadata without stripping fm-"
  [ "$(fm_backend_expected_label_of_selector 'fm-turnend-all-harnesses-v9' "$state")" = "fm-fm-turnend-all-harnesses-v9" ] \
    || fail "exact fm-* task id should report the spawned fm-<id> label"

  [ "$(fm_backend_resolve_selector 'fm-task1' "$state")" = "firstmate:fm-task1" ] \
    || fail "legacy fm-<id> label should resolve through <id>.meta's window="
  [ "$(fm_backend_expected_label_of_selector 'fm-task1' "$state")" = "fm-task1" ] \
    || fail "legacy fm-<id> label should preserve its backend label"

  out=$(fm_backend_resolve_selector 'fm-missing' "$state" 2>&1) && fail "fm-<id> with no meta should fail"
  assert_contains "$out" "no metadata for fm-missing" "missing-meta error text changed"

  fakebin="$TMP_ROOT/resolve-fakebin"; mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_TMUX_LOG:?}
{ printf 'tmux'; for arg in "$@"; do printf '\x1f%s' "$arg"; done; printf '\n'; } >> "$log"
case "${1:-}" in
  has-session)
    [ "${FM_FAKE_TMUX_NO_SESSION:-0}" = 1 ] && exit 1
    ;;
  new-session)
    [ "${FM_FAKE_TMUX_NEW_SESSION_FAIL:-0}" = 1 ] && exit 1
    ;;
  list-windows)
    for arg in "$@"; do
      if [ "$arg" = '#{window_id}|#{session_name}:#{window_name}' ]; then
        [ "${FM_FAKE_TMUX_LIST_FAIL:-0}" = 1 ] && exit 1
        if [ "${FM_FAKE_TMUX_WINDOW_MISSING:-0}" = 1 ]; then
          printf '@1|firstmate:other\n'
        else
          printf '@1|firstmate:fm-demo\n'
        fi
        exit 0
      fi
    done
    printf 'firstmate:adhoc\n'
    ;;
  capture-pane) printf 'captured line\n' ;;
  display-message)
    for arg in "$@"; do
      case "$arg" in
        *pane_id*) printf 'pane-1\n'; exit 0 ;;
        *cursor_y*) printf '0\n'; exit 0 ;;
        '#S') printf 'firstmate\n'; exit 0 ;;
        *pane_current_path*) printf '/tmp/worktree\n'; exit 0 ;;
        *window_name*) printf 'fm-demo\n'; exit 0 ;;
      esac
    done
    printf 'firstmate\n' ;;
  kill-window)
    [ "${FM_FAKE_TMUX_KILL_FAIL:-0}" = 1 ] && exit 1
    ;;
  *) ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_selection_and_metadata() {
  local config="$TMP_ROOT/config" meta="$TMP_ROOT/task.meta"
  mkdir -p "$config"
  FM_BACKEND_CONFIG_DIR="$config"

  [ "$(FM_BACKEND='' fm_backend_name)" = tmux ] || fail "backend should default to tmux"
  printf '\n tmux \n' > "$config/backend"
  [ "$(FM_BACKEND='' fm_backend_name)" = tmux ] || fail "config/backend was not selected"
  [ "$(FM_BACKEND=tmux fm_backend_name)" = tmux ] || fail "FM_BACKEND did not override config/backend"

  fm_write_meta "$meta" "window=firstmate:fm-demo" "harness=codex"
  [ "$(fm_backend_of_meta "$meta")" = tmux ] || fail "missing backend= must mean tmux"
  printf 'backend=tmux\n' >> "$meta"
  [ "$(fm_backend_of_meta "$meta")" = tmux ] || fail "explicit backend=tmux was not read"

  fm_backend_validate tmux || fail "tmux should be known"
  fm_backend_validate herdr || fail "Herdr should be accepted as the experimental opt-in backend"
  pass "backend selection precedence, metadata default, and known/unknown validation"
}

test_spawn_rejects_unknown_selection() {
  local config="$TMP_ROOT/spawn-selection-config" out
  mkdir -p "$config"

  out=$(FM_SPAWN_NO_GUARD=1 FM_BACKEND=orca "$ROOT/bin/fm-spawn.sh" 2>&1) \
    && fail "FM_BACKEND=orca should stop spawn before argument/project validation"
  assert_contains "$out" "unknown backend 'orca'" "FM_BACKEND refusal did not name the backend"

  printf 'orca\n' > "$config/backend"
  out=$(FM_SPAWN_NO_GUARD=1 FM_BACKEND='' FM_CONFIG_OVERRIDE="$config" \
    "$ROOT/bin/fm-spawn.sh" 2>&1) \
    && fail "config/backend=orca should stop spawn before argument/project validation"
  assert_contains "$out" "unknown backend 'orca'" "config/backend refusal did not name the backend"

  out=$(FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" --backend orca 2>&1) \
    && fail "--backend orca should stop spawn before argument/project validation"
  assert_contains "$out" "unknown backend 'orca'" "--backend refusal did not name the backend"
  pass "fm-spawn refuses unknown backends from FM_BACKEND, config/backend, and --backend"
}

test_selector_and_dispatch() {
  local dir fakebin log state out
  dir="$TMP_ROOT/dispatch"; mkdir -p "$dir/state"
  fakebin=$(make_fake_tmux "$dir")
  log="$dir/tmux.log"; : > "$log"
  state="$dir/state"
  fm_write_meta "$state/demo.meta" "window=firstmate:fm-demo"
  fm_write_meta "$state/foo.meta" "window=firstmate:fm-foo"
  fm_write_meta "$state/fm-foo.meta" "window=firstmate:fm-fm-foo"

  [ "$(fm_backend_resolve_selector sess:win "$state")" = sess:win ] \
    || fail "explicit session:window selector changed"
  [ "$(fm_backend_resolve_selector fm-demo "$state")" = firstmate:fm-demo ] \
    || fail "fm-<id> selector did not use metadata"
  [ "$(fm_backend_resolve_selector fm-foo "$state")" = firstmate:fm-foo ] \
    || fail "fm-<id> selector did not retain its stripped-id meaning"
  [ "$(fm_backend_resolve_selector fm-fm-foo "$state")" = firstmate:fm-fm-foo ] \
    || fail "fm-prefixed task id was not addressable through its canonical selector"
  out=$(PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" fm_backend_resolve_selector adhoc "$state")
  [ "$out" = firstmate:adhoc ] || fail "bare selector did not use fake tmux inventory"

  out=$(PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" fm_backend_capture tmux firstmate:fm-demo 12)
  [ "$out" = 'captured line' ] || fail "capture dispatch returned '$out'"
  PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" fm_backend_send_key tmux firstmate:fm-demo Escape \
    || fail "send-key dispatch failed"
  PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" fm_backend_pane_readable tmux firstmate:fm-demo \
    || fail "pane-readable dispatch failed"
  PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" fm_backend_kill tmux firstmate:fm-demo \
    || fail "kill dispatch failed"
  assert_contains "$(cat "$log")" $'\x1f''capture-pane' "capture did not reach fake tmux"
  assert_contains "$(cat "$log")" $'\x1f''Escape' "send-key did not reach fake tmux"
  assert_contains "$(cat "$log")" $'\x1f''kill-window' "kill did not reach fake tmux"
  pass "selector resolution and capture/key/readability/kill dispatch use tmux adapter"
}

test_selector_recovers_precreate_herdr_journal() {
  local state out resolution
  state="$TMP_ROOT/herdr-recovery/state"
  mkdir -p "$state"
  fm_write_meta "$state/exact-c1db.meta" "window=stale:w0:p0" "backend=herdr" \
    "herdr_session=fmtest" "herdr_workspace_id=w-second" \
    "herdr_tab_id=w1:t1" "herdr_pane_id=w1:p1" \
    "display_label=Crew - Exact recovery · c1db" "task_key=c1db" \
    "home=$TMP_ROOT/secondmate-home"
  fm_write_meta "$state/stale-d2e3.meta" "window=stale:w0:p0" "backend=herdr" \
    "herdr_session=fmtest" "herdr_workspace_id=w-second" \
    "herdr_tab_id=w-old:t1" "herdr_pane_id=w-old:p1" \
    "display_label=Crew - Stale recovery · d2e3" "task_key=d2e3" \
    "home=$TMP_ROOT/secondmate-home"
  fm_write_meta "$state/legacy-e3f4.meta" "window=stale:w0:p0" "backend=herdr" \
    "herdr_session=fmtest" "herdr_workspace_id=w-second" \
    "herdr_tab_id=w-gone:t1" "herdr_pane_id=w-gone:p1" \
    "display_label=Crew - Missing display · e3f4" "task_key=e3f4" \
    "home=$TMP_ROOT/secondmate-home"
  printf 'version=1\ntask_id=crash-c1db\ndisplay_label=Crew - Crash recovery · c1db\ntask_key=c1db\nherdr_home=%s\nherdr_session=fmtest\nherdr_workspace_id=w-second\n' \
    "$TMP_ROOT/secondmate-home" \
    > "$state/crash-c1db.herdr-label"
  fm_backend_source herdr || fail "Herdr backend could not be loaded"
  fm_backend_pane_readable() {
    [ "$1" = herdr ] && [ "$2" = fmtest:w1:p1 ]
  }
  fm_backend_list_live() {
    [ "$1" = herdr ] || return 1
    [ "$FM_STATE_OVERRIDE" = "$state" ] || return 1
    case "${3:-}" in
      w-second)
        [ "$2" = fmtest ] || return 1
        [ "$FM_HOME" = "$TMP_ROOT/secondmate-home" ] || return 1
        printf 'fmtest:w1:p2\tfm-stale-d2e3\tCrew - Stale recovery · d2e3\n'
        printf 'fmtest:w1:p5\tfm-stale-d2e3\tfm-stale-d2e3\n'
        printf 'fmtest:w1:p3\tfm-crash-c1db\tCrew - Crash recovery · c1db\n'
        printf 'fmtest:w1:p7\tfm-crash-c1db\tfm-crash-c1db\n'
        printf 'fmtest:w1:p6\tfm-legacy-e3f4\tfm-legacy-e3f4\n'
        ;;
      '')
        printf 'fmtest:w1:p4\tfm-legacy-z9\tfm-legacy-z9\n'
        ;;
      *) return 1 ;;
    esac
  }
  resolution=$(fm_backend_resolve_selector_with_backend exact-c1db "$state") \
    || fail "readable exact Herdr ids did not resolve"
  [ "$resolution" = $'herdr\tfmtest:w1:p1' ] \
    || fail "readable exact Herdr ids were not preferred: '$resolution'"
  resolution=$(fm_backend_resolve_selector_with_backend stale-d2e3 "$state") \
    || fail "stale exact Herdr ids did not fall back through live inventory"
  [ "$resolution" = $'herdr\tfmtest:w1:p2' ] \
    || fail "stale exact Herdr ids did not recover by display label: '$resolution'"
  resolution=$(fm_backend_resolve_selector_with_backend legacy-e3f4 "$state") \
    || fail "stale Herdr ids did not use final legacy fallback"
  [ "$resolution" = $'herdr\tfmtest:w1:p6' ] \
    || fail "final legacy Herdr fallback resolved incorrectly: '$resolution'"
  out=$(HERDR_SESSION=fmtest fm_backend_resolve_selector crash-c1db "$state") \
    || fail "bare task id did not recover through the Herdr journal"
  [ "$out" = fmtest:w1:p3 ] || fail "recovered Herdr target mismatch: '$out'"
  out=$(HERDR_SESSION=fmtest fm_backend_resolve_selector fm-crash-c1db "$state") \
    || fail "legacy fm-<id> selector did not recover through the Herdr journal"
  [ "$out" = fmtest:w1:p3 ] || fail "legacy recovered Herdr target mismatch: '$out'"
  resolution=$(HERDR_SESSION=fmtest fm_backend_resolve_selector_with_backend fm-crash-c1db "$state") \
    || fail "journal-only selector did not return backend-aware recovery"
  [ "$resolution" = $'herdr\tfmtest:w1:p3' ] || fail "journal-only selector lost Herdr backend routing: '$resolution'"
  resolution=$(FM_BACKEND=herdr HERDR_SESSION=fmtest \
    fm_backend_resolve_selector_with_backend fm-legacy-z9 "$state") \
    || fail "legacy-only Herdr tab was not discovered through live inventory"
  [ "$resolution" = $'herdr\tfmtest:w1:p4' ] \
    || fail "legacy-only Herdr tab resolved incorrectly: '$resolution'"
  pass "selector recovery retains Herdr routing and persisted workspace identity"
}

test_backend_failures_propagate() {
  local dir fakebin log out
  dir="$TMP_ROOT/failures"; mkdir -p "$dir"
  fakebin=$(make_fake_tmux "$dir")
  log="$dir/tmux.log"; : > "$log"

  if PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" FM_FAKE_TMUX_KILL_FAIL=1 \
    fm_backend_kill tmux firstmate:fm-demo; then
    fail "kill failure was swallowed by the tmux adapter"
  fi

  if out=$(PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" FM_FAKE_TMUX_NO_SESSION=1 \
    FM_FAKE_TMUX_NEW_SESSION_FAIL=1 TMUX='' fm_backend_container_ensure tmux /tmp); then
    fail "new-session failure was swallowed by container ensure"
  fi
  assert_contains "$(cat "$log")" $'\x1f''new-session' \
    "container ensure did not attempt new-session after has-session failed"
  if PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" FM_FAKE_TMUX_KILL_FAIL=1 \
    fm_backend_kill tmux firstmate:fm-demo; then
    fail "kill failure was swallowed while the target was still present"
  fi
  PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" FM_FAKE_TMUX_KILL_FAIL=1 \
    FM_FAKE_TMUX_WINDOW_MISSING=1 fm_backend_kill tmux firstmate:fm-demo \
    || fail "already-absent target was not idempotent"
  if PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" FM_FAKE_TMUX_KILL_FAIL=1 \
    FM_FAKE_TMUX_LIST_FAIL=1 fm_backend_kill tmux firstmate:fm-demo; then
    fail "tmux inventory failure was treated as an absent target"
  fi
  pass "tmux adapter propagates kill and container-creation failures"
}

test_teardown_preserves_state_on_kill_failure() {
  local dir fakebin fake_root log project state treehouse_log worktree out
  dir="$TMP_ROOT/teardown-kill-failure"
  fake_root="$dir/root"
  project="$dir/project"
  state="$fake_root/state"
  worktree="$dir/worktree"
  mkdir -p "$fake_root/bin/backends" "$state"
  fakebin=$(make_fake_tmux "$dir")
  log="$dir/tmux.log"
  treehouse_log="$dir/treehouse.log"
  : > "$log"
  : > "$treehouse_log"
  fm_git_worktree "$project" "$worktree" kill-fail
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/treehouse"

  ln -s "$ROOT/bin/fm-teardown.sh" "$fake_root/bin/fm-teardown.sh"
  ln -s "$ROOT/bin/fm-backend.sh" "$fake_root/bin/fm-backend.sh"
  ln -s "$ROOT/bin/backends/tmux.sh" "$fake_root/bin/backends/tmux.sh"
  ln -s "$ROOT/bin/fm-tmux-lib.sh" "$fake_root/bin/fm-tmux-lib.sh"
  ln -s "$ROOT/bin/fm-tool-path-lib.sh" "$fake_root/bin/fm-tool-path-lib.sh"
  cp "$ROOT/bin/fm-gate-refuse-lib.sh" "$fake_root/bin/fm-gate-refuse-lib.sh"
  cat > "$fake_root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_root/bin/fm-guard.sh"
  cat > "$fake_root/bin/fm-fleet-sync.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_root/bin/fm-fleet-sync.sh"
  cat > "$fake_root/bin/fm-tasks-axi-lib.sh" <<'SH'
fm_tasks_axi_backend_available() { return 1; }
SH
  cat > "$fake_root/bin/fm-task-identity-lib.sh" <<'SH'
fm_assert_task_branch_matches_meta() { return 0; }
SH

  fm_write_meta "$state/kill-fail.meta" \
    "window=firstmate:fm-demo" \
    "worktree=$worktree" \
    "project=$project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working\n' > "$state/kill-fail.status"

  if out=$(cd "$fake_root" && PATH="$fakebin:$PATH" FM_HOME="$fake_root" \
    FM_ROOT_OVERRIDE="$fake_root" FM_STATE_OVERRIDE="$state" \
    FM_TMUX_LOG="$log" FM_TREEHOUSE_LOG="$treehouse_log" \
    FM_FAKE_TMUX_KILL_FAIL=1 \
    "$fake_root/bin/fm-teardown.sh" kill-fail --force 2>&1); then
    fail "teardown swallowed a backend kill failure"
  fi
  assert_contains "$out" \
    "REFUSED: could not kill task kill-fail window firstmate:fm-demo; refusing to delete task state" \
    "teardown did not report the failed backend kill"
  [ -f "$state/kill-fail.meta" ] || fail "teardown deleted metadata after kill failure"
  [ -f "$state/kill-fail.status" ] || fail "teardown deleted status after kill failure"
  [ -d "$worktree" ] || fail "teardown removed the worktree after kill failure"
  assert_contains "$(git -C "$project" worktree list --porcelain)" \
    "worktree $worktree" "teardown unregistered the worktree after kill failure"
  git -C "$project" show-ref --verify --quiet refs/heads/kill-fail \
    || fail "teardown deleted the task branch after kill failure"
  [ ! -s "$treehouse_log" ] || fail "teardown returned the worktree before killing its endpoint"
  pass "teardown preserves task state when backend kill fails"
}

test_selection_and_metadata
test_spawn_rejects_unknown_selection
test_selector_and_dispatch
test_selector_recovers_precreate_herdr_journal
test_backend_failures_propagate
test_teardown_preserves_state_on_kill_failure
