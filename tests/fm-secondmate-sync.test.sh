#!/usr/bin/env bash
# Tests for the local-HEAD secondmate sync: every secondmate home tracks the
# PRIMARY firstmate checkout's current default-branch commit by a purely LOCAL
# fast-forward (no origin fetch). Two hook points drive it - bin/fm-spawn.sh
# (before launching a secondmate) and bin/fm-bootstrap.sh (a startup sweep of
# every live secondmate home) - and both share the ff machinery in
# bin/fm-ff-lib.sh.
#
# The guarantees under test:
#   - The shared ff helper, driven with a LOCAL commit base, advances a behind
#     home (updated), is a no-op on an already-current home (current, no nudge),
#     and refuses - leaving work untouched - on a dirty, diverged, or
#     in-flight (feature-branch) home.
#   - No origin fetch happens in the local-HEAD sync path.
#   - The bootstrap sweep fast-forwards every live secondmate home and reports a
#     nudge (NUDGE_SECONDMATES:) ONLY for a running secondmate whose instruction
#     surface actually changed; an already-current or readme-only home is never
#     nudged, a skipped home is reported as SECONDMATE_SYNC:, and a home with no
#     live metadata is never swept.
#   - Spawning a secondmate fast-forwards its worktree to the primary's HEAD
#     before launch, or warns and launches unchanged when the sync is skipped.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-ff-lib.sh
. "$ROOT/bin/fm-ff-lib.sh"

fm_ff_target_lock_acquire() { return 0; }
fm_ff_target_lock_release() { return 0; }
fm_backend_endpoint_generation() {
  printf 'endpoint-%s' "${2##*:fm-}"
}

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-secondmate-sync)
SYNC_PIDS=()
cleanup_secondmate_sync() {
  local pid
  for pid in "${SYNC_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_secondmate_sync EXIT

# --- world builders --------------------------------------------------------

# new_world <name>: a PRIMARY firstmate repo on `main` with one commit (the
# instruction surface seeded) and a home dir with state/ and data/. NO origin
# remote: the local-HEAD sync never needs one. Echoes the world dir.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps fm-guard quiet for the spawn path.
  touch "$w/home/state/.last-watcher-beat"

  git init -q -b main "$w/main"
  # Mirror the real repo: the gitignored operational dirs never dirty a worktree,
  # so a secondmate home's data/state/projects can never block its fast-forward.
  printf 'projects/\nstate/\ndata/\n.no-mistakes/\nconfig/crew-harness\n' > "$w/main/.gitignore"
  printf 'v1\n' > "$w/main/AGENTS.md"
  printf 'r1\n' > "$w/main/README.md"
  mkdir -p "$w/main/bin" "$w/main/.agents/skills"
  printf 'echo a\n' > "$w/main/bin/tool.sh"
  printf 'true\n' > "$w/main/bin/fm-worker-isolation-lib.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$w/main/bin/fm-isolation-sweep.sh"
  chmod +x "$w/main/bin/fm-isolation-sweep.sh"
  printf 'fm_secondmate_lifecycle_identity_matches() { return 0; }\n' > "$w/main/bin/fm-ff-lib.sh"
  printf 's1\n' > "$w/main/.agents/skills/note.md"
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm c1
  printf '%s\n' "$w"
}

# add_sm_worktree <w> <id> <commit>: a secondmate home as a DETACHED worktree of
# the primary at <commit>, plus its seed marker and a LIVE kind=secondmate meta
# (a window= makes it a running direct report).
add_sm_worktree() {
  local w=$1 id=$2 commit=$3
  git -C "$w/main" worktree add -q --detach "$w/$id" "$commit"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s/%s\n' "$w" "$id"
    printf 'task=%s\n' "$id"
    printf 'endpoint_generation=endpoint-%s\n' "$id"
    printf 'worktree=%s/%s\n' "$w" "$id"
    printf 'project=%s/main\n' "$w"
    printf 'harness=codex\n'
  } > "$w/home/state/$id.meta"
  (cd "$w/$id" && env FM_AGENT_ROLE=secondmate FM_AGENT_TASK="$id" \
    FM_AGENT_OWNER_HOME="$w/$id" sleep 300) >/dev/null 2>&1 </dev/null &
  SYNC_PIDS+=("$!")
}

# bump_primary <w> <mode>: advance the PRIMARY's main branch by one local commit.
# instr changes the instruction surface (AGENTS.md, bin, skills) plus README;
# readme changes only README. No push - the sync follows the primary's local HEAD.
bump_primary() {
  local w=$1 mode=$2
  printf 'r-%s\n' "$mode" >> "$w/main/README.md"
  if [ "$mode" = instr ]; then
    printf 'v-%s\n' "$mode" > "$w/main/AGENTS.md"
    printf 'echo %s\n' "$mode" > "$w/main/bin/tool.sh"
    printf 's-%s\n' "$mode" > "$w/main/.agents/skills/note.md"
  fi
  git -C "$w/main" add -A
  git -C "$w/main" commit -qm "bump-$mode"
}

head_of() { git -C "$1" rev-parse HEAD; }

# run_ff <dir> <base>: drive the shared ff helper in THIS shell (output to a file,
# not a subshell, so FF_STATUS / FF_INSTR propagate). Sets FF_OUT to the printed
# status line. Uses allow_detached=yes, ignore_seed_marker=yes (the secondmate
# home contract).
FF_OUT=""
run_ff() {
  local dir=$1 base=$2 outfile="$TMP_ROOT/ff.out"
  ff_target "$dir" "secondmate sm" "$base" yes yes >"$outfile" 2>&1
  FF_OUT=$(cat "$outfile")
}

# --- T1: updated - a behind home fast-forwards to the primary's local HEAD ---
test_ff_updated() {
  local w c1 base
  w=$(new_world ff-updated)
  c1=$(head_of "$w/main")
  git -C "$w/main" worktree add -q --detach "$w/sm" "$c1"
  bump_primary "$w" instr
  base=$(primary_head_commit "$w/main")

  run_ff "$w/sm" "$base"

  [ "$FF_STATUS" = updated ] || fail "FF_STATUS: expected updated, got '$FF_STATUS'"
  assert_contains "$FF_OUT" "secondmate sm: updated " "updated home prints an advance line"
  assert_contains "$FF_INSTR" "AGENTS.md" "instruction change is recorded in FF_INSTR"
  [ "$(head_of "$w/sm")" = "$base" ] || fail "home did not advance to the primary's local HEAD"
  git -C "$w/sm" symbolic-ref -q HEAD >/dev/null && fail "home is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge would have two.
  [ "$(git -C "$w/sm" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "home tip is not a single-parent fast-forward"
  pass "T1 updated: a behind home fast-forwards to the primary's local HEAD"
}

# --- T2: current - already on the primary's HEAD is a no-op (no nudge) -------
test_ff_current() {
  local w base
  w=$(new_world ff-current)
  bump_primary "$w" instr
  base=$(primary_head_commit "$w/main")
  git -C "$w/main" worktree add -q --detach "$w/sm" "$base"

  run_ff "$w/sm" "$base"

  [ "$FF_STATUS" = current ] || fail "FF_STATUS: expected current, got '$FF_STATUS'"
  assert_contains "$FF_OUT" "secondmate sm: already current" "current home reports already current"
  [ -z "$FF_INSTR" ] || fail "a no-op must not report instruction changes (would trigger a nudge)"
  [ "$(head_of "$w/sm")" = "$base" ] || fail "current home HEAD moved"
  pass "T2 current: an already-current home is a no-op and reports no instruction change"
}

# --- T3: dirty - a home with uncommitted edits is skipped, edit preserved ----
test_ff_dirty() {
  local w c1 base before
  w=$(new_world ff-dirty)
  c1=$(head_of "$w/main")
  git -C "$w/main" worktree add -q --detach "$w/sm" "$c1"
  bump_primary "$w" instr
  base=$(primary_head_commit "$w/main")
  printf 'uncommitted local edit\n' >> "$w/sm/AGENTS.md"
  before=$(head_of "$w/sm")

  run_ff "$w/sm" "$base"

  [ "$FF_STATUS" = skipped ] || fail "FF_STATUS: expected skipped, got '$FF_STATUS'"
  assert_contains "$FF_OUT" "secondmate sm: skipped: dirty working tree" "dirty home is skipped"
  [ "$(head_of "$w/sm")" = "$before" ] || fail "dirty home HEAD moved"
  grep -q 'uncommitted local edit' "$w/sm/AGENTS.md" || fail "dirty edit was discarded"
  pass "T3 dirty: an uncommitted home is skipped, its edit preserved"
}

# --- T4: diverged - a home with its own commit is skipped, commit preserved --
test_ff_diverged() {
  local w c1 base before
  w=$(new_world ff-diverged)
  c1=$(head_of "$w/main")
  git -C "$w/main" worktree add -q --detach "$w/sm" "$c1"
  printf 'fork work\n' > "$w/sm/AGENTS.md"
  git -C "$w/sm" add -A
  git -C "$w/sm" commit -qm local-work
  before=$(head_of "$w/sm")
  bump_primary "$w" instr
  base=$(primary_head_commit "$w/main")

  run_ff "$w/sm" "$base"

  [ "$FF_STATUS" = skipped ] || fail "FF_STATUS: expected skipped, got '$FF_STATUS'"
  assert_contains "$FF_OUT" "secondmate sm: skipped: diverged from $base" "diverged home is skipped"
  [ "$(head_of "$w/sm")" = "$before" ] || fail "diverged home HEAD moved (unlanded work at risk)"
  pass "T4 diverged: a home that is not an ancestor of the primary's HEAD is skipped"
}

# --- T5: in-flight - a home on a feature branch is skipped, work preserved ----
# A secondmate home carrying its own in-flight work sits on a named feature
# branch, not a detached default-branch HEAD; the ff helper refuses to move it.
test_ff_inflight_feature_branch() {
  local w c1 base before
  w=$(new_world ff-inflight)
  c1=$(head_of "$w/main")
  git -C "$w/main" worktree add -q -b feature/wip "$w/sm" "$c1"
  printf 'work in progress\n' >> "$w/sm/README.md"
  git -C "$w/sm" add -A
  git -C "$w/sm" commit -qm wip
  before=$(head_of "$w/sm")
  bump_primary "$w" instr
  base=$(primary_head_commit "$w/main")

  run_ff "$w/sm" "$base"

  [ "$FF_STATUS" = skipped ] || fail "FF_STATUS: expected skipped, got '$FF_STATUS'"
  assert_contains "$FF_OUT" "secondmate sm: skipped: on feature/wip, expected main" \
    "a home on a feature branch is skipped"
  [ "$(head_of "$w/sm")" = "$before" ] || fail "in-flight home HEAD moved (work at risk)"
  pass "T5 in-flight: a home on a feature branch is skipped, its work preserved"
}

# --- T6: no origin fetch happens in the local-HEAD sync path -----------------
# A bare `git fetch` would need the network; the sync must never reach for it.
# Shadow git with a wrapper that records any `fetch` invocation, then drive the
# updated path and confirm the wrapper saw none.
test_no_fetch_in_local_path() {
  local w c1 base fakebin log real_git
  w=$(new_world ff-nofetch)
  c1=$(head_of "$w/main")
  git -C "$w/main" worktree add -q --detach "$w/sm" "$c1"
  bump_primary "$w" instr
  base=$(primary_head_commit "$w/main")

  fakebin="$w/fakebin"
  log="$w/fetch.log"
  real_git=$(command -v git)
  mkdir -p "$fakebin"
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = fetch ]; then printf 'FETCH\n' >> '$log'; fi
done
exec '$real_git' "\$@"
SH
  chmod +x "$fakebin/git"

  PATH="$fakebin:$BASE_PATH" run_ff "$w/sm" "$base"

  [ "$FF_STATUS" = updated ] || fail "FF_STATUS: expected updated, got '$FF_STATUS'"
  [ ! -f "$log" ] || fail "git fetch was invoked in the local-HEAD sync path: $(cat "$log")"
  pass "T6 no fetch: the local-HEAD sync never invokes git fetch"
}

# --- T7: sweep advances a readme-only home but does NOT nudge it -------------
test_sweep_nudge_requires_instruction_change() {
  local w c1 base
  w=$(new_world sweep-gate)
  c1=$(head_of "$w/main")
  add_sm_worktree "$w" sm-r "$c1"
  bump_primary "$w" readme
  base=$(primary_head_commit "$w/main")

  FM_ROOT="$w/main" FM_HOME="$w/home"
  FF_NUDGE_WINDOWS=""
  FF_SEEN_HOMES=""
  sweep_live_secondmate_metas "$w/home/state" "$base" yes >/dev/null

  [ -z "$FF_NUDGE_WINDOWS" ] \
    || fail "readme-only advance must not nudge, got: '$FF_NUDGE_WINDOWS'"
  [ "$(head_of "$w/sm-r")" = "$base" ] \
    || fail "home should still fast-forward even when it is not nudged"
  pass "T7 sweep nudges on a real instruction change only, but still fast-forwards"
}

# --- T8: bootstrap sweeps live homes, nudges only the real instruction change -
make_fake_toolchain() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  fm_fake_exit0 "$fakebin" node gh-axi chrome-devtools-axi lavish-axi
  cat >"$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show-options ]; then
  target=
  while [ $# -gt 0 ]; do
    if [ "$1" = -t ]; then shift; target=${1:-}; break; fi
    shift
  done
  printf 'endpoint-%s\n' "${target##*:fm-}"
fi
if [ "${1:-}" = new-window ]; then
  printf '@9\n'
fi
if [ "${1:-}" = display-message ]; then
  case "${*: -1}" in
    '#{window_name}') printf 'fm-sm\n' ;;
    '#{pane_id}') printf '%%9\n' ;;
  esac
fi
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.31.2 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

test_bootstrap_sweep_nudges_only_instruction_change() {
  local w c1 c2 c3 fakebin out nudge_line
  w=$(new_world boot-sweep)
  c1=$(head_of "$w/main")
  add_sm_worktree "$w" sm-instr "$c1"        # behind by an instruction change
  bump_primary "$w" instr
  c2=$(head_of "$w/main")
  add_sm_worktree "$w" sm-readme "$c2"       # behind by a readme-only change
  bump_primary "$w" readme
  c3=$(head_of "$w/main")
  add_sm_worktree "$w" sm-current "$c3"      # already on the primary's HEAD
  # A home with NO live meta must never be swept (live = a running direct report).
  git -C "$w/main" worktree add -q --detach "$w/sm-nonlive" "$c1"
  printf 'sm-nonlive\n' > "$w/sm-nonlive/.fm-secondmate-home"

  fakebin=$(make_fake_toolchain "$w")
  out=$(env -u NO_MISTAKES_GATE PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" \
    FM_ROOT_OVERRIDE="$w/main" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  nudge_line=$(printf '%s\n' "$out" | grep '^BOOTSTRAP_INFO: nudged ' || true)
  [ -n "$nudge_line" ] || fail "no successful bootstrap nudge line emitted (got: $out)"
  assert_contains "$nudge_line" "fm-sm-instr" "instruction-changed running secondmate is nudged"
  assert_not_contains "$nudge_line" "sm-readme" "readme-only advance is not nudged"
  assert_not_contains "$nudge_line" "sm-current" "already-current secondmate is not nudged"

  # Every live home advanced to the primary's HEAD; the already-current one stayed.
  [ "$(head_of "$w/sm-instr")" = "$c3" ] || fail "sm-instr not at primary HEAD"
  [ "$(head_of "$w/sm-readme")" = "$c3" ] || fail "sm-readme not at primary HEAD"
  [ "$(head_of "$w/sm-current")" = "$c3" ] || fail "sm-current moved off primary HEAD"
  # The non-live home is never touched by the bootstrap sweep.
  [ "$(head_of "$w/sm-nonlive")" = "$c1" ] || fail "a home with no live meta was swept"
  pass "T8 bootstrap sweeps live homes, nudges only the running real-instruction-change secondmate"
}

# --- T9: bootstrap surfaces a skipped dirty live secondmate home --------------
test_bootstrap_sweep_surfaces_skipped_home() {
  local w c1 base before fakebin out skip_line
  w=$(new_world boot-skip)
  c1=$(head_of "$w/main")
  add_sm_worktree "$w" sm-dirty "$c1"
  bump_primary "$w" instr
  base=$(primary_head_commit "$w/main")
  printf 'uncommitted local edit\n' >> "$w/sm-dirty/AGENTS.md"
  before=$(head_of "$w/sm-dirty")

  fakebin=$(make_fake_toolchain "$w")
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  skip_line=$(printf '%s\n' "$out" | grep '^SECONDMATE_SYNC: secondmate sm-dirty: skipped:' || true)
  [ -n "$skip_line" ] || fail "no SECONDMATE_SYNC skip line emitted (got: $out)"
  assert_contains "$skip_line" "dirty working tree" "dirty skipped home reports the actionable reason"
  [ "$(head_of "$w/sm-dirty")" = "$before" ] || fail "dirty home HEAD moved"
  [ "$(head_of "$w/main")" = "$base" ] || fail "primary HEAD changed during bootstrap"
  grep -q 'uncommitted local edit' "$w/sm-dirty/AGENTS.md" || fail "dirty edit was discarded"
  pass "T9 bootstrap surfaces a skipped dirty live secondmate home"
}

test_bootstrap_retry_clears_child_obligation() {
  local w commit fakebin out count pending
  w=$(new_world boot-retry)
  commit=$(head_of "$w/main")
  add_sm_worktree "$w" sm-retry "$commit"
  mkdir -p "$w/sm-retry/state" "$w/home/state/.secondmate-nudge-pending"
  printf 'generation=%s\n' "$commit" > "$w/sm-retry/state/.watch-protocol-reread-required"
  pending="$w/home/state/.secondmate-nudge-pending/sm-retry.pending"
  {
    printf 'id=sm-retry\n'
    printf 'selector=fm-sm-retry\n'
    printf 'home=%s/sm-retry\n' "$w"
    printf 'window=firstmate:fm-sm-retry\n'
    printf 'endpoint_generation=endpoint-sm-retry\n'
    printf 'commit=%s\n' "$commit"
    printf 'instructions=AGENTS.md\n'
    printf 'message=firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.\n'
  } > "$pending"

  fakebin=$(make_fake_toolchain "$w")
  out=$(env -u NO_MISTAKES_GATE PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" \
    FM_ROOT_OVERRIDE="$w/main" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  count=$(printf '%s\n' "$out" | grep -c '^BOOTSTRAP_INFO: nudged fm-sm-retry ' || true)
  [ "$count" -eq 1 ] || fail "retried nudge was delivered $count times"
  [ ! -f "$pending" ] || fail "parent retry marker survived successful delivery"
  ! fm_update_obligation_pending \
    "$w/sm-retry/state/.watch-protocol-reread-required" "$w/sm-retry" \
    || fail "child reread obligation survived successful retry delivery"
  pass "T10 bootstrap retry clears the matching child obligation"
}

test_bootstrap_retry_respects_secondmate_lifecycle_lock() {
  local w commit fakebin out pending lock held_locks=()
  w=$(new_world boot-retry-lock)
  commit=$(head_of "$w/main")
  add_sm_worktree "$w" sm-retry-lock "$commit"
  mkdir -p "$w/sm-retry-lock/state" "$w/home/state/.secondmate-nudge-pending"
  printf 'generation=%s\n' "$commit" > "$w/sm-retry-lock/state/.watch-protocol-reread-required"
  pending="$w/home/state/.secondmate-nudge-pending/sm-retry-lock.pending"
  {
    printf 'id=sm-retry-lock\n'
    printf 'selector=fm-sm-retry-lock\n'
    printf 'home=%s/sm-retry-lock\n' "$w"
    printf 'window=firstmate:fm-sm-retry-lock\n'
    printf 'endpoint_generation=endpoint-sm-retry-lock\n'
    printf 'commit=%s\n' "$commit"
    printf 'instructions=AGENTS.md\n'
    printf 'message=firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.\n'
  } > "$pending"
  . "$ROOT/bin/fm-wake-lib.sh"
  while IFS= read -r lock; do
    mkdir -p "$(dirname "$lock")"
    fm_lock_try_acquire "$lock" || fail "could not hold bootstrap lifecycle fixture lock"
    held_locks+=("$lock")
  done < <(fm_spawn_admission_lock_paths "$w/sm-retry-lock/state")
  fakebin=$(make_fake_toolchain "$w")
  out=$(env -u NO_MISTAKES_GATE PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" \
    FM_ROOT_OVERRIDE="$w/main" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  for lock in "${held_locks[@]}"; do
    fm_lock_release "$lock"
  done
  [ -f "$pending" ] || fail "bootstrap removed a retry marker while lifecycle lock was held"
  fm_update_obligation_pending \
    "$w/sm-retry-lock/state/.watch-protocol-reread-required" "$w/sm-retry-lock" \
    || fail "bootstrap acknowledged child reread state while lifecycle lock was held"
  assert_contains "$out" "lifecycle identity changed or lock is busy" \
    "bootstrap did not report locked retry recovery"
  pass "bootstrap retry recovery keeps markers and acknowledgements behind the lifecycle lock"
}

test_bootstrap_retry_retains_delivery_until_acknowledged() {
  local w commit stale fakebin pending receipt out sends obligation
  w=$(new_world boot-retry-ack-failure)
  git -C "$w/main" commit --allow-empty -qm second
  commit=$(head_of "$w/main")
  stale=$(git -C "$w/main" rev-parse "$commit^")
  add_sm_worktree "$w" sm-ack "$commit"
  mkdir -p "$w/sm-ack/state" "$w/home/state/.secondmate-nudge-pending"
  obligation="$w/sm-ack/state/.watch-protocol-reread-required"
  fm_update_obligation_write "$obligation" "$stale"
  pending="$w/home/state/.secondmate-nudge-pending/sm-ack.pending"
  {
    printf 'id=sm-ack\n'
    printf 'selector=fm-sm-ack\n'
    printf 'home=%s/sm-ack\n' "$w"
    printf 'window=firstmate:fm-sm-ack\n'
    printf 'endpoint_generation=endpoint-sm-ack\n'
    printf 'commit=%s\n' "$commit"
    printf 'instructions=AGENTS.md\n'
    printf 'message=firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.\n'
  } > "$pending"
  fakebin=$(make_fake_toolchain "$w")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show-options ]; then
  printf '%s\n' endpoint-sm-ack
  exit 0
fi
printf '%s\n' "$*" >> "${FM_FAKE_TMUX_LOG:?}"
exit 0
SH
  chmod +x "$fakebin/tmux"
  out=$(env -u NO_MISTAKES_GATE PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" \
    FM_ROOT_OVERRIDE="$w/main" FM_FAKE_TMUX_LOG="$w/tmux.log" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  [ -f "$pending" ] || fail "acknowledgement failure removed the retry marker"
  receipt="$w/home/state/.secondmate-nudge-delivered/sm-ack/$commit"
  [ -f "$receipt" ] || fail "acknowledgement failure removed the delivery receipt"
  fm_update_obligation_pending \
    "$obligation" "$w/sm-ack" \
    || fail "acknowledgement failure removed the child obligation"
  rm -f "$obligation.generations/$stale"
  out=$(env -u NO_MISTAKES_GATE PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" \
    FM_ROOT_OVERRIDE="$w/main" FM_FAKE_TMUX_LOG="$w/tmux.log" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  [ ! -e "$pending" ] && grep -qx 'state=complete' "$receipt" \
    || fail "acknowledgement retry did not retain terminal delivery state"
  fm_update_obligation_pending "$obligation" "$w/sm-ack" \
    && fail "terminal cleanup recreated an acknowledged child obligation"
  sends=$(grep -Fc 'firstmate was updated to the latest' "$w/tmux.log" 2>/dev/null || true)
  [ "$sends" -eq 1 ] || fail "acknowledgement retry sent the request $sends times"
  pass "bootstrap reconciles receipt cleanup after the obligation is already gone"
}

test_bootstrap_refuses_ambiguous_lifecycle_metadata() {
  local w c1 before fakebin out rc
  w=$(new_world boot-ambiguous)
  c1=$(head_of "$w/main")
  add_sm_worktree "$w" sm-ambiguous "$c1"
  bump_primary "$w" instr
  before=$(head_of "$w/sm-ambiguous")
  printf 'endpoint_generation=recycled\n' >> "$w/home/state/sm-ambiguous.meta"
  fakebin=$(make_fake_toolchain "$w")

  rc=0
  out=$(env -u NO_MISTAKES_GATE PATH="$fakebin:$BASE_PATH" FM_HOME="$w/home" \
    FM_ROOT_OVERRIDE="$w/main" "$ROOT/bin/fm-bootstrap.sh" 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "bootstrap accepted ambiguous lifecycle metadata"
  [ "$(head_of "$w/sm-ambiguous")" = "$before" ] \
    || fail "bootstrap advanced a home with ambiguous lifecycle metadata"
  assert_contains "$out" "ambiguous lifecycle metadata" \
    "bootstrap did not report ambiguous lifecycle metadata"
  pass "bootstrap refuses ambiguous lifecycle metadata before mutation"
}

# --- T11: spawning a secondmate fast-forwards its worktree before launch ------
test_spawn_fast_forwards_before_launch() {
  local w c1 c2 fakebin rc
  w=$(new_world spawn-ff)
  c1=$(head_of "$w/main")
  git -C "$w/main" worktree add -q --detach "$w/sm" "$c1"
  printf 'sm\n' > "$w/sm/.fm-secondmate-home"
  mkdir -p "$w/sm/data"
  printf 'charter\n' > "$w/sm/data/charter.md"
  bump_primary "$w" instr
  c2=$(head_of "$w/main")
  [ "$(head_of "$w/sm")" = "$c1" ] || fail "precondition: home should start behind the primary"

  fakebin=$(make_fake_toolchain "$w")

  rc=0
  env -u NO_MISTAKES_GATE PATH="$fakebin:$BASE_PATH" TMUX='' \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    FM_STATE_OVERRIDE="$w/home/state" FM_DATA_OVERRIDE="$w/home/data" \
    FM_PROJECTS_OVERRIDE="$w/home/projects" FM_CONFIG_OVERRIDE="$w/home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" sm "$w/sm" codex --secondmate >/dev/null 2>&1 || rc=$?

  [ "$rc" -eq 0 ] || fail "capability-complete secondmate spawn failed"
  [ "$(head_of "$w/sm")" = "$c2" ] \
    || fail "spawn did not fast-forward the secondmate worktree to the primary's HEAD"
  pass "T10 spawn fast-forwards a secondmate worktree to the primary's local HEAD before launch"
}

# --- T11: spawn refuses when pre-launch sync is skipped -----------------------
test_spawn_refuses_when_sync_skipped_before_launch() {
  local w c1 before fakebin err rc
  w=$(new_world spawn-skip)
  c1=$(head_of "$w/main")
  git -C "$w/main" worktree add -q --detach "$w/sm" "$c1"
  printf 'sm\n' > "$w/sm/.fm-secondmate-home"
  mkdir -p "$w/sm/data"
  printf 'charter\n' > "$w/sm/data/charter.md"
  bump_primary "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm/AGENTS.md"
  before=$(head_of "$w/sm")

  fakebin="$w/fakebin"
  err="$w/spawn.err"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"

  rc=0
  env -u NO_MISTAKES_GATE PATH="$fakebin:$BASE_PATH" TMUX='' \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    FM_STATE_OVERRIDE="$w/home/state" FM_DATA_OVERRIDE="$w/home/data" \
    FM_PROJECTS_OVERRIDE="$w/home/projects" FM_CONFIG_OVERRIDE="$w/home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" sm "$w/sm" codex --secondmate >/dev/null 2>"$err" || rc=$?

  [ "$rc" -ne 0 ] || fail "dirty secondmate home launched after sync refusal"
  assert_contains "$(cat "$err")" \
    "error: secondmate sm sync skipped before launch: dirty working tree" \
    "spawn refusal reports the skipped sync reason"
  [ "$(head_of "$w/sm")" = "$before" ] || fail "dirty spawn home HEAD moved"
  grep -q 'uncommitted local edit' "$w/sm/AGENTS.md" || fail "dirty spawn edit was discarded"
  pass "T11 spawn refuses when pre-launch sync is skipped"
}

test_ff_updated
test_ff_current
test_ff_dirty
test_ff_diverged
test_ff_inflight_feature_branch
test_no_fetch_in_local_path
test_sweep_nudge_requires_instruction_change
test_bootstrap_sweep_nudges_only_instruction_change
test_bootstrap_sweep_surfaces_skipped_home
test_bootstrap_retry_clears_child_obligation
test_bootstrap_retry_respects_secondmate_lifecycle_lock
test_bootstrap_retry_retains_delivery_until_acknowledged
test_bootstrap_refuses_ambiguous_lifecycle_metadata
test_spawn_fast_forwards_before_launch
test_spawn_refuses_when_sync_skipped_before_launch

echo "# all fm-secondmate-sync tests passed"
