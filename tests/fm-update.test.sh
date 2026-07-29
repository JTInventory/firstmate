#!/usr/bin/env bash
# Tests for bin/fm-update.sh: fast-forward-only self-update of a running
# firstmate repo and every registered secondmate home.
#
# The guarantees under test mirror fm-fleet-sync.sh and prime directive #3:
#   - The running firstmate repo (on its default branch) fast-forwards from
#     origin; a leased secondmate home (detached HEAD on the default branch)
#     fast-forwards the same way.
#   - FAST-FORWARD ONLY: a dirty, diverged, offline, or wrong-branch target is
#     skipped and reported, never forced or stashed, so unlanded work survives.
#   - The update is a single-parent fast-forward (never a merge commit) and a
#     fast-forward of one worktree never disturbs another worktree's checkout
#     or the shared default branch.
#   - The caller-action summary is correct: reread-firstmate flips to yes only
#     when the instruction surface (AGENTS.md / bin / skills) changed, and
#     nudge-secondmates lists exactly the live secondmates that advanced.
#   - Secondmate homes resolve from both state/<id>.meta and the
#     data/secondmates.md registry, deduped, and the firstmate repo is never
#     re-processed as one of its own secondmates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/secondmate-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/secondmate-helpers.sh"

UPDATE_IMPL="$ROOT/bin/fm-update.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$ROOT/bin/fm-ff-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-secondmate-delivery-lib.sh
. "$ROOT/bin/fm-secondmate-delivery-lib.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)
fm_test_session_authority_fd "$TMP_ROOT"
mkdir -p "$TMP_ROOT"
UPDATE="$TMP_ROOT/fm-update-primary"
{
  printf '#!/usr/bin/env bash\n'
  printf 'cd "$FM_ROOT_OVERRIDE" || exit 1\n'
  printf 'exec %q "$@"\n' "$UPDATE_IMPL"
} > "$UPDATE"
chmod +x "$UPDATE"
UPDATE_TEST_PIDS=""

cleanup_update_tests() {
  local pid
  for pid in $UPDATE_TEST_PIDS; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_update_tests EXIT

# Build a fresh world: a bare origin seeded with one commit, a firstmate repo
# clone checked out on main, and a home dir with state/ and data/. Echoes the
# world dir. Files seeded: AGENTS.md, README.md, bin/tool.sh, a skill note.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  # Fresh watcher beacon keeps fm-guard quiet.
  touch "$w/home/state/.last-watcher-beat"

  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null

  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'r1\n' > "$w/seed/README.md"
  printf 'state/\ndata/\nconfig/\nprojects/\n' > "$w/seed/.gitignore"
  mkdir -p "$w/seed/bin" "$w/seed/.agents/skills"
  printf 'echo a\n' > "$w/seed/bin/tool.sh"
  printf 's1\n' > "$w/seed/.agents/skills/note.md"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm c1
  git -C "$w/seed" push -q origin main

  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  . "$ROOT/bin/fm-session-lock-lib.sh"
  local owner
  owner=$(fm_session_lock_owner)
  printf '%s\n' "$owner" > "$w/home/state/.lock"
  printf '%s\n' "$w/main" > "$w/home/state/.primary-checkout"
  fm_session_authority_write_file "$w/home/state/.session-authority" \
    "${owner%%|*}" "$owner" "$w/home" "$w/main"

  printf '%s\n' "$w"
}

new_protocol_migration_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/data"
  touch "$w/home/state/.last-watcher-beat"
  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  if [ -n "${FM_TEST_PREDECESSOR_BIN:-}" ]; then
    cp -R "$FM_TEST_PREDECESSOR_BIN" "$w/seed/bin"
  else
    cp -R "$ROOT/bin" "$w/seed/bin"
    sed "s/^FM_WATCHER_PROTOCOL_VERSION=.*/FM_WATCHER_PROTOCOL_VERSION='pending-reply-ticket-v2'/" \
      "$w/seed/bin/fm-watcher-protocol-lib.sh" \
      > "$w/seed/bin/fm-watcher-protocol-lib.sh.tmp"
    mv "$w/seed/bin/fm-watcher-protocol-lib.sh.tmp" \
      "$w/seed/bin/fm-watcher-protocol-lib.sh"
  fi
  cat > "$w/seed/bin/fm-update.sh" <<'SH'
#!/usr/bin/env bash
set -eu
ROOT=${FM_ROOT_OVERRIDE:?}
STATE=${FM_STATE_OVERRIDE:?}
HOME_DIR=${FM_HOME:?}
FM_WAKE_LIB_READ_ONLY=1
export FM_WAKE_LIB_READ_ONLY
. "$ROOT/bin/fm-wake-lib.sh"
locks=()
release_predecessor_locks() {
  local lock
  for lock in "${locks[@]}"; do
    fm_lock_release "$lock" || true
  done
}
trap release_predecessor_locks EXIT
while IFS= read -r lock; do
  mkdir -p "$(dirname "$lock")"
  fm_lock_try_acquire "$lock"
  locks+=("$lock")
done < <(fm_spawn_admission_lock_paths "$STATE")
git -C "$ROOT" fetch -q origin main
git -C "$ROOT" merge -q --ff-only origin/main
installed="$ROOT/bin/fm-update.sh"
for lock in "${locks[@]}"; do
  fm_lifecycle_admission_authorize_reexec "$lock" "$installed"
done
printf 'predecessor-installed-before-exec\n'
export FM_UPDATE_REEXECED=1
exec "$installed"
SH
  chmod +x "$w/seed/bin/fm-update.sh"
  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'state/\ndata/\nconfig/\nprojects/\n' > "$w/seed/.gitignore"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm protocol-v1
  git -C "$w/seed" push -q origin main
  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_session_lock_owner > "$w/home/state/.lock"
  printf '%s\n' "$w/main" > "$w/home/state/.primary-checkout"
  cp -R "$ROOT/bin/." "$w/seed/bin/"
  git -C "$w/seed" add bin
  git -C "$w/seed" commit -qm protocol-v3
  git -C "$w/seed" push -q origin main
  printf '%s\n' "$w"
}

# Add a secondmate home as a DETACHED worktree of the firstmate repo (matching
# how treehouse leases a secondmate home), plus its state meta. Args: world id.
add_sm() {
  local w=$1 id=$2
  git -C "$w/main" worktree add -q --detach "$w/$id" main
  {
    printf 'window=main:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'harness=codex\n'
    printf 'home=%s/%s\n' "$w" "$id"
    printf 'task=%s\n' "$id"
    printf 'endpoint_generation=endpoint-%s\n' "$id"
  } > "$w/home/state/$id.meta"
  printf '%s\n' "$id" > "$w/$id/.fm-secondmate-home"
}

# Advance origin by one commit. mode=instr changes the instruction surface
# (AGENTS.md, bin, skills) plus README; mode=readme changes only README.
bump_origin() {
  local w=$1 mode=$2
  git -C "$w/seed" pull -q origin main >/dev/null 2>&1 || true
  printf 'r-%s\n' "$mode" >> "$w/seed/README.md"
  if [ "$mode" = instr ]; then
    printf 'v2\n' > "$w/seed/AGENTS.md"
    printf 'echo b\n' > "$w/seed/bin/tool.sh"
    printf 's2\n' > "$w/seed/.agents/skills/note.md"
  fi
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm "bump-$mode"
  git -C "$w/seed" push -q origin main
}

run_update() {
  local w=$1 fakebin
  fakebin=$(make_fake_tmux "$w/update-fake")
  : >"$w/update-fake/tmux.log"
  : >"$w/update-fake/tmux.log.closed"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$w/update-fake/tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$w/update-fake/pane.txt" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>&1
}

ack_firstmate_reread() {
  local w=$1 generation fakebin
  generation=$(fm_update_obligation_generation \
    "$w/home/state/.watch-protocol-reread-required" "$w/main")
  fakebin=$(make_fake_tmux "$w/ack-firstmate-fake")
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$w/ack-firstmate-fake/tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$w/ack-firstmate-fake/pane.txt" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --ack-reread-firstmate "$generation" >/dev/null
}

ack_secondmate_nudge() {
  local w=$1 target=$2 generation fakebin
  generation=$(fm_update_obligation_generation \
    "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1")
  fakebin=$(make_fake_tmux "$w/ack-fake")
  : >"$w/ack-fake/tmux.log"
  : >"$w/ack-fake/tmux.log.closed"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_LOG="$w/ack-fake/tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$w/ack-fake/pane.txt" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --ack-secondmate-nudge "$target" "$generation" >/dev/null
}

# --- T1: main + secondmate behind, instruction change; FF, not a merge ------
# Combines the former T1 (fast-forward + reread + nudge signalling) and T2
# (the advance is a single-parent fast-forward, never a merge commit) into one
# world so both contracts are proven against the same update run.
test_updates_main_and_secondmate() {
  local w out
  w=$(new_world t1)
  add_sm "$w" sm1
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "secondmate fast-forwarded"
  assert_contains "$out" "reread-firstmate: yes" "instruction change triggers reread"
  assert_contains "$out" "restart-firstmate-watcher: no" "updated firstmate without a watcher needs no restart"
  assert_contains "$out" "restart-secondmate-watchers: none" "updated secondmate without a watcher needs no restart"
  assert_contains "$out" "nudge-secondmates: main:fm-sm1" "updated secondmate is nudged"
  fm_update_obligation_pending "$w/home/state/.watch-protocol-reread-required" "$w/main" \
    || fail "firstmate reread obligation was not retained for acknowledgement"
  fm_update_obligation_pending "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1" \
    || fail "secondmate nudge obligation was not retained for acknowledgement"

  # Fast-forward landed: HEAD == origin/main on both targets.
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$(git -C "$w/main" rev-parse origin/main)" ] \
    || fail "firstmate HEAD not at origin/main"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$(git -C "$w/sm1" rev-parse origin/main)" ] \
    || fail "secondmate HEAD not at origin/main"
  # Firstmate stays on its default branch; secondmate stays detached.
  [ "$(git -C "$w/main" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "firstmate left its default branch"
  git -C "$w/sm1" symbolic-ref -q HEAD >/dev/null \
    && fail "secondmate worktree is no longer detached"
  # A fast-forwarded tip has exactly one parent; a merge commit would have two.
  [ "$(git -C "$w/main" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "firstmate tip is not a single-parent fast-forward"
  [ "$(git -C "$w/sm1" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" -eq 2 ] \
    || fail "secondmate tip is not a single-parent fast-forward"
  pass "T1 main + secondmate fast-forward (single-parent), reread + nudge signalled"
}

# --- T3: README-only change does not trigger a reread ----------------------
test_reread_gate_is_instruction_only() {
  local w out
  w=$(new_world t3)
  add_sm "$w" sm1
  bump_origin "$w" readme

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " "firstmate still advanced"
  assert_contains "$out" "reread-firstmate: no" "non-instruction change skips reread"
  # The secondmate still advanced, so it is still nudged (update-based nudge).
  assert_contains "$out" "nudge-secondmates: main:fm-sm1" "advanced secondmate still nudged"
  pass "T3 reread gates on instruction surface, nudge on advancement"
}

# --- T4: dirty secondmate is skipped, its edit preserved -------------------
test_dirty_secondmate_skipped() {
  local w out
  w=$(new_world t4)
  add_sm "$w" sm1
  bump_origin "$w" instr
  printf 'uncommitted local edit\n' >> "$w/sm1/AGENTS.md"

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: dirty working tree" "dirty home skipped"
  assert_not_contains "$out" "fm-sm1" "skipped secondmate is not nudged"
  grep -q 'uncommitted local edit' "$w/sm1/AGENTS.md" \
    || fail "dirty edit was discarded"
  pass "T4 dirty secondmate skipped, local edit preserved"
}

# --- T5: diverged secondmate is skipped, its commit preserved --------------
test_diverged_secondmate_skipped() {
  local w out before
  w=$(new_world t5)
  add_sm "$w" sm1
  # Local commit on the secondmate's detached HEAD makes it diverge from origin.
  printf 'fork work\n' > "$w/sm1/AGENTS.md"
  git -C "$w/sm1" add -A
  git -C "$w/sm1" commit -qm local-work
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate sm1: skipped: diverged from origin/main" "diverged home skipped"
  assert_not_contains "$out" "fm-sm1" "diverged secondmate is not nudged"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "diverged secondmate HEAD moved (unlanded work at risk)"
  pass "T5 diverged secondmate skipped, local commit preserved"
}

# --- T6: idempotent; second run reports already current --------------------
test_idempotent_already_current() {
  local w out
  w=$(new_world t6)
  add_sm "$w" sm1
  bump_origin "$w" instr
  run_update "$w" >/dev/null   # first run advances both
  ack_firstmate_reread "$w"
  ack_secondmate_nudge "$w" main:fm-sm1

  out=$(run_update "$w")       # second run: nothing to do

  assert_contains "$out" "firstmate: already current" "firstmate already current"
  assert_contains "$out" "secondmate sm1: already current" "secondmate already current"
  assert_contains "$out" "reread-firstmate: no" "no reread when nothing changed"
  assert_contains "$out" "restart-firstmate-watcher: no" "current firstmate skips watcher restart"
  assert_contains "$out" "restart-secondmate-watchers: none" "current secondmate skips watcher restart"
  assert_contains "$out" "nudge-secondmates: none" "no nudge when nothing advanced"
  pass "T6 idempotent: a second run is a no-op"
}

# --- T7: registry backstop + dedup + self-exclusion, one world -------------
# One world carries every secondmate-resolution edge at once:
#   reg1 - registered in secondmates.md only, NO live meta (registry backstop);
#   sm1  - present in BOTH meta and the registry (must be processed exactly once);
#   selfish - a bogus registry line pointing the firstmate repo at itself.
# Asserts: reg1 is refused and is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out rc before_main before_sm
  w=$(new_world t7)
  add_sm "$w" sm1
  git -C "$w/main" worktree add -q --detach "$w/reg1" main
  printf 'reg1\n' > "$w/reg1/.fm-secondmate-home"
  {
    printf -- '- reg1 - domain supervisor (home: %s/reg1; scope: things; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- sm1 - dup (home: %s/sm1; scope: x; projects: p; added 2026-06-23)\n' "$w"
    printf -- '- selfish - self (home: %s/main; scope: x; projects: p; added 2026-06-23)\n' "$w"
  } > "$w/home/data/secondmates.md"
  bump_origin "$w" instr
  before_main=$(git -C "$w/main" rev-parse HEAD)
  before_sm=$(git -C "$w/sm1" rev-parse HEAD)

  rc=0
  out=$(run_update "$w" 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "registry-only lifecycle ambiguity returned success"
  assert_contains "$out" "secondmate reg1: refused: registry entry has no strict live lifecycle metadata" \
    "registry-only secondmate was not refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before_main" ] \
    || fail "primary advanced before lifecycle preflight refused"
  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before_sm" ] \
    || fail "live secondmate advanced before registry ambiguity refused"
  pass "T7 registry-only ambiguity refuses before every update mutation"
}

# --- T9: firstmate repo on a feature branch is skipped ---------------------
test_firstmate_wrong_branch_skipped() {
  local w out before
  w=$(new_world t9)
  bump_origin "$w" instr
  # Simulate firstmate mid-shipping its own change: not on the default branch.
  git -C "$w/main" checkout -q -b feature/wip
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "primary identity is not bound" "off-default firstmate refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is refused before mutation"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "primary identity is not bound" "detached firstmate refused"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 detached firstmate is refused before mutation"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before before_main
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  before_main=$(git -C "$w/main" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "registry entry has no strict live lifecycle metadata" \
    "unsafe registry-only home refused"
  assert_contains "$out" "update made no changes" "unsafe home refusal was not fail-closed"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before_main" ] \
    || fail "primary advanced before unsafe registry-only identity was refused"
  pass "T11 unsafe registry-only home refuses every update mutation"
}

test_replays_interrupted_reread_and_nudge_obligations() {
  local w out
  w=$(new_world t12)
  add_sm "$w" sm1
  printf '%s\n' state/ >> "$(git -C "$w/sm1" rev-parse --git-path info/exclude)"
  mkdir -p "$w/sm1/state"
  printf '%s\n' pending-reply-ticket-v2 > "$w/home/state/.watch-protocol-reread-required"
  printf '%s\n' pending-reply-ticket-v2 > "$w/sm1/state/.watch-protocol-reread-required"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: already current" "retry keeps current firstmate"
  assert_contains "$out" "secondmate sm1: already current" "retry keeps current secondmate"
  assert_contains "$out" "reread-firstmate: yes" "retry replays firstmate reread"
  assert_contains "$out" "nudge-secondmates: main:fm-sm1" "retry replays secondmate nudge"
  fm_update_obligation_pending "$w/home/state/.watch-protocol-reread-required" "$w/main" \
    || fail "firstmate reread obligation cleared before acknowledgement"
  fm_update_obligation_pending "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1" \
    || fail "secondmate nudge obligation cleared before acknowledgement"

  ack_firstmate_reread "$w"
  ack_secondmate_nudge "$w" main:fm-sm1
  ! fm_update_obligation_pending "$w/home/state/.watch-protocol-reread-required" "$w/main" \
    || fail "firstmate reread acknowledgement did not clear obligation"
  ! fm_update_obligation_pending "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1" \
    || fail "secondmate nudge acknowledgement did not clear obligation"
  pass "T12 interrupted update obligations persist until acknowledged"
}

test_first_protocol_upgrade_requires_installed_updater_pass() {
  local w fakebin watcher arm out rc
  w=$(new_protocol_migration_world t13)
  fakebin="$w/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"

  (cd "$w/main" && exec env PATH="$fakebin:$PATH" FM_HOME="$w/home" \
    FM_ROOT_OVERRIDE="$w/main" FM_STATE_OVERRIDE="$w/home/state" \
    FM_POLL=5 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$w/main/bin/fm-watch.sh") >/dev/null 2>&1 &
  watcher=$!
  UPDATE_TEST_PIDS="$UPDATE_TEST_PIDS $watcher"
  for _ in $(seq 1 60); do
    [ "$(cat "$w/home/state/.watch.lock/pid" 2>/dev/null || true)" = "$watcher" ] \
      && [ "$(cat "$w/home/state/.watch.lock/pending-reply-protocol" 2>/dev/null || true)" = pending-reply-ticket-v2 ] \
      && break
    sleep 0.1
  done
  [ "$(cat "$w/home/state/.watch.lock/pending-reply-protocol" 2>/dev/null || true)" = pending-reply-ticket-v2 ] \
    || fail "migration fixture did not start the predecessor watcher"

  (cd "$w/main" && exec env PATH="$fakebin:$PATH" FM_HOME="$w/home" \
    FM_ROOT_OVERRIDE="$w/main" FM_STATE_OVERRIDE="$w/home/state" \
    FM_POLL=5 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$w/main/bin/fm-watch-arm.sh") >"$w/arm.out" &
  arm=$!
  UPDATE_TEST_PIDS="$UPDATE_TEST_PIDS $arm"
  for _ in $(seq 1 60); do
    [ "$(cat "$w/home/state/.watch-arm.lock/pid" 2>/dev/null || true)" = "$arm" ] && break
    sleep 0.1
  done
  [ "$(cat "$w/home/state/.watch-arm.lock/pid" 2>/dev/null || true)" = "$arm" ] \
    || fail "migration fixture did not attach a v1 follower"

  rc=0
  out=$(cd "$w/main" && PATH="$fakebin:$PATH" FM_HOME="$w/home" \
    FM_ROOT_OVERRIDE="$w/main" \
    FM_STATE_OVERRIDE="$w/home/state" "$w/main/bin/fm-update.sh" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "installed updater accepted the predecessor watcher"
  assert_contains "$out" "predecessor-installed-before-exec" \
    "predecessor did not install before its locked exec"
  assert_contains "$out" "watcher protocol restart could not be verified" \
    "installed updater did not run its live preflight after predecessor exec"
  [ "$(cat "$w/home/state/.watch-protocol-required" 2>/dev/null || true)" = pending-reply-ticket-v3 ] \
    || fail "first protocol upgrade did not publish the v3 fence"
  wait "$watcher" 2>/dev/null || true
  wait "$arm" 2>/dev/null || true
  pass "T13 predecessor install re-execs through the installed updater preflight"
}

test_acknowledgements_are_generation_bound() {
  local w old_generation new_generation out rc
  w=$(new_world t14)
  old_generation=$(git -C "$w/main" rev-parse HEAD)
  printf 'generation=%s\n' "$old_generation" > "$w/home/state/.watch-protocol-reread-required"
  bump_origin "$w" instr

  out=$(run_update "$w")
  new_generation=$(sed -n 's/^reread-firstmate-generation: //p' <<< "$out")
  [ -n "$new_generation" ] && [ "$new_generation" != "$old_generation" ] \
    || fail "new update generation was not reported"

  rc=0
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --ack-reread-firstmate "$old_generation" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "stale acknowledgement cleared a newer obligation"
  [ "$(fm_update_obligation_generation \
    "$w/home/state/.watch-protocol-reread-required" "$w/main")" = "$new_generation" ] \
    || fail "newer reread generation was not preserved"

  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --ack-reread-firstmate "$new_generation" >/dev/null
  pass "T14 stale acknowledgements cannot clear newer generations"
}

test_herdr_target_acknowledges_exact_live_meta() {
  local w out generation fakebin endpoint
  w=$(new_world t15)
  add_sm "$w" sm1
  sed -i 's/^window=.*/window=default:w1:p2/' "$w/home/state/sm1.meta"
  printf '%s\n' 'backend=herdr' 'herdr_session=default' \
    'herdr_workspace_id=workspace-1' 'herdr_tab_id=tab-1' \
    'herdr_pane_id=w1:p2' >> "$w/home/state/sm1.meta"
  endpoint=$(printf '%s' 'default|workspace-1|tab-1|w1:p2' | cksum \
    | awk '{printf "herdr-%s-%s", $1, $2}')
  sed -i "s/^endpoint_generation=.*/endpoint_generation=$endpoint/" \
    "$w/home/state/sm1.meta"
  bump_origin "$w" instr
  fakebin=$(make_fake_tmux "$w/update-fake")
cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"pane get w1:p2"*) printf '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"tab-1","tokens":{"firstmate_endpoint_generation":"%s"}}}}\n' "$FM_FAKE_HERDR_GENERATION" ;;
  *"tab get tab-1"*) printf '%s\n' '{"result":{"tab":{"tab_id":"tab-1","workspace_id":"workspace-1"}}}' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/herdr"

  : >"$w/update-fake/tmux.log"
  : >"$w/update-fake/tmux.log.closed"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_HERDR_GENERATION="$endpoint" \
    FM_FAKE_TMUX_LOG="$w/update-fake/tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$w/update-fake/pane.txt" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>&1)
  assert_contains "$out" "nudge-secondmates: default:w1:p2" "Herdr target is surfaced unchanged"
  generation=$(sed -n 's/^nudge-secondmate-generation: default:w1:p2|//p' <<< "$out")
  [ -n "$generation" ] || fail "Herdr target generation was not reported"
  PATH="$fakebin:$PATH" FM_FAKE_HERDR_GENERATION="$endpoint" \
    FM_FAKE_TMUX_LOG="$w/update-fake/tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$w/update-fake/pane.txt" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --ack-secondmate-nudge default:w1:p2 "$generation" >/dev/null
  ! fm_update_obligation_pending "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1" \
    || fail "Herdr target acknowledgement did not clear its obligation"
  pass "T15 Herdr acknowledgements resolve exact live metadata"
}

test_immutable_generations_preserve_prepared_and_newer_markers() {
  local w marker records generation_a generation_b generation_c fail_target failed rc
  w=$(new_world t16)
  marker="$w/home/state/.watch-protocol-reread-required"
  generation_a=$(git -C "$w/main" rev-parse HEAD)
  bump_origin "$w" readme
  generation_b=$(git -C "$w/seed" rev-parse HEAD)
  bump_origin "$w" readme
  generation_c=$(git -C "$w/seed" rev-parse HEAD)

  fm_update_obligation_write "$marker" "$generation_a"
  fm_update_obligation_write "$marker" "$generation_b"
  [ "$(fm_update_obligation_generation "$marker" "$w/main")" = "$generation_a" ] \
    || fail "prepared future generation became active before fast-forward"

  git -C "$w/main" fetch -q origin main
  git -C "$w/main" merge -q --ff-only origin/main
  [ "$(fm_update_obligation_generation "$marker" "$w/main")" = "$generation_b" ] \
    || fail "ancestor obligation was not selected after a later fast-forward"
  rc=0
  fm_update_obligation_ack "$marker" "$generation_a" "$w/main" || rc=$?
  [ "$rc" -ne 0 ] || fail "older generation acknowledged a newer checkout"

  records=$(fm_update_obligation_records_dir "$marker")
  fail_target="$records/$generation_b"
  failed="$w/ack-failed"
  rm() {
    if [ "${1:-}" = -f ] && [ "${2:-}" = "$fail_target" ] && [ ! -f "$failed" ]; then
      touch "$failed"
      return 1
    fi
    command rm "$@"
  }
  rc=0
  fm_update_obligation_ack "$marker" "$generation_b" "$w/main" || rc=$?
  unset -f rm
  [ "$rc" -ne 0 ] || fail "interrupted acknowledgement unexpectedly succeeded"
  [ "$(fm_update_obligation_generation "$marker" "$w/main")" = "$generation_b" ] \
    || fail "interrupted acknowledgement lost its retry generation"
  fm_update_obligation_ack "$marker" "$generation_b" "$w/main" \
    || fail "ancestor generation acknowledgement retry failed at $generation_c"
  ! fm_update_obligation_pending "$marker" "$w/main" \
    || fail "current acknowledgement left superseded generations"
  pass "T16 ancestor obligations remain acknowledgeable and retries are durable"
}

test_skipped_update_reports_existing_generation() {
  local w generation out
  w=$(new_world t17)
  generation=$(git -C "$w/main" rev-parse HEAD)
  printf 'generation=%s\n' "$generation" > "$w/home/state/.watch-protocol-reread-required"
  printf 'local edit\n' >> "$w/main/README.md"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: dirty working tree" "dirty update remains skipped"
  assert_contains "$out" "reread-firstmate: yes" "skipped update replays pending reread"
  assert_contains "$out" "reread-firstmate-generation: $generation" \
    "skipped update reports the existing generation"
  pass "T17 skipped updates retain acknowledgement generations"
}

test_future_legacy_generation_survives_concurrent_ack() {
  local w marker generation_a generation_c
  w=$(new_world t18)
  marker="$w/home/state/.watch-protocol-reread-required"
  generation_a=$(git -C "$w/main" rev-parse HEAD)
  bump_origin "$w" readme
  bump_origin "$w" readme
  generation_c=$(git -C "$w/seed" rev-parse HEAD)
  git -C "$w/main" fetch -q origin main

  fm_update_obligation_write "$marker" "$generation_a"
  printf 'generation=%s\n' "$generation_c" > "$marker"
  fm_update_obligation_ack "$marker" "$generation_a" "$w/main" \
    || fail "current acknowledgement rejected a prepared legacy generation"
  ! fm_update_obligation_pending "$marker" "$w/main" \
    || fail "future legacy generation became active before fast-forward"

  git -C "$w/main" merge -q --ff-only origin/main
  [ "$(fm_update_obligation_generation "$marker" "$w/main")" = "$generation_c" ] \
    || fail "future legacy generation was lost during concurrent acknowledgement"
  fm_update_obligation_ack "$marker" "$generation_c" "$w/main" \
    || fail "preserved future legacy generation could not be acknowledged"
  pass "T18 future legacy generations survive concurrent acknowledgements"
}

test_future_only_legacy_generation_updates_on_first_retry() {
  local w marker generation out
  w=$(new_world t19)
  marker="$w/home/state/.watch-protocol-reread-required"
  bump_origin "$w" readme
  generation=$(git -C "$w/seed" rev-parse HEAD)
  git -C "$w/main" fetch -q origin main
  printf 'generation=%s\n' "$generation" > "$marker"

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: updated " \
    "future-only legacy obligation does not block its first retry"
  assert_contains "$out" "reread-firstmate-generation: $generation" \
    "future-only legacy obligation activates after fast-forward"
  pass "T19 future-only legacy generations recover on the first retry"
}

test_update_refuses_workers_before_state_resolution() {
  local w owner foreign out rc
  w=$(new_world t20-worker-guard)
  owner="$w/owner"
  foreign="$w/foreign"
  mkdir -p "$owner" "$foreign"

  rc=0
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$foreign" \
    FM_AGENT_ROLE=crewmate FM_AGENT_TASK=worker FM_AGENT_OWNER_HOME="$owner" \
    "$UPDATE" --ack-reread-firstmate bogus 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "crewmate update acknowledgement was allowed"
  assert_contains "$out" "update refused" "crewmate update refusal lost its operation"
  [ ! -e "$foreign/state" ] || fail "crewmate update resolved foreign operational state"

  rc=0
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$foreign" \
    FM_AGENT_ROLE=secondmate FM_AGENT_TASK=domain FM_AGENT_OWNER_HOME="$owner" \
    "$UPDATE" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "foreign-home secondmate update was allowed"
  assert_contains "$out" "update refused" "secondmate update refusal lost its operation"
  [ ! -e "$foreign/state" ] || fail "secondmate update resolved foreign operational state"
  pass "T20 update refuses workers before state or acknowledgement mutation"
}

test_update_waits_for_legacy_admission_and_task_locks() {
  local w out before lock holder
  w=$(new_world t21)
  bump_origin "$w" readme
  before=$(git -C "$w/main" rev-parse HEAD)

  for lock in "$w/home/state/.spawn-admission.lock" "$w/home/state/.spawn-old-task.lock"; do
    (
      . "$ROOT/bin/fm-wake-lib.sh"
      fm_lock_try_acquire "$lock" || exit 1
      touch "$w/lock-ready"
      while [ ! -e "$w/release-lock" ]; do sleep 0.05; done
      fm_lock_release "$lock"
    ) &
    holder=$!
    UPDATE_TEST_PIDS="$UPDATE_TEST_PIDS $holder"
    while [ ! -e "$w/lock-ready" ]; do sleep 0.05; done
    out=$(run_update "$w")
    assert_contains "$out" "fleet lifecycle serialization is busy" \
      "update ignored a mixed-version lifecycle lock"
    [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
      || fail "update advanced while a mixed-version lifecycle lock was active"
    touch "$w/release-lock"
    wait "$holder"
    rm -f "$w/lock-ready" "$w/release-lock"
  done

  mkdir -p "$w/legacy"
  cat > "$w/legacy/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
while :; do sleep 1; done
SH
  chmod +x "$w/legacy/fm-spawn.sh"
  FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" "$w/legacy/fm-spawn.sh" &
  holder=$!
  UPDATE_TEST_PIDS="$UPDATE_TEST_PIDS $holder"
  while ! ps -p "$holder" -o command= 2>/dev/null | grep -F "$w/legacy/fm-spawn.sh" >/dev/null; do
    sleep 0.05
  done
  out=$(run_update "$w")
  assert_contains "$out" "fleet lifecycle serialization is busy" \
    "update ignored a legacy lifecycle process without an admission lock"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "update advanced while a lockless legacy lifecycle process was active"
  kill "$holder"
  wait "$holder" 2>/dev/null || true

  out=$(run_update "$w")
  assert_contains "$out" "firstmate: updated " \
    "update did not advance after mixed-version lifecycle locks released"
  pass "T21 update bridges legacy admission and task-only lifecycle locks"
}

test_update_ignores_legacy_lifecycle_process_for_another_home() {
  local w other out holder
  w=$(new_world t22)
  other="$w/other-home"
  mkdir -p "$other/state" "$w/legacy-other"
  bump_origin "$w" readme
  cat > "$w/legacy-other/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
while :; do sleep 1; done
SH
  chmod +x "$w/legacy-other/fm-teardown.sh"
  FM_HOME="$other" FM_STATE_OVERRIDE="$other/state" "$w/legacy-other/fm-teardown.sh" &
  holder=$!
  UPDATE_TEST_PIDS="$UPDATE_TEST_PIDS $holder"
  while ! ps -p "$holder" -o command= 2>/dev/null | grep -F "$w/legacy-other/fm-teardown.sh" >/dev/null; do
    sleep 0.05
  done
  out=$(run_update "$w")
  kill "$holder"
  wait "$holder" 2>/dev/null || true
  assert_contains "$out" "firstmate: updated " \
    "unrelated-home legacy lifecycle process starved update"
  pass "T22 update ignores legacy lifecycle work in another canonical home"
}

test_update_quiescence_catches_late_legacy_lifecycle_start() {
  local w out before holder launcher
  w=$(new_world t23)
  bump_origin "$w" readme
  before=$(git -C "$w/main" rev-parse HEAD)
  mkdir -p "$w/legacy-late"
  cat > "$w/legacy-late/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_TEST_LEGACY_READY"
while [ ! -e "$FM_TEST_LEGACY_RELEASE" ]; do sleep 0.02; done
SH
  chmod +x "$w/legacy-late/fm-spawn.sh"
  (
    while [ ! -e "$w/home/state/.locks/spawn-admission.lock" ]; do sleep 0.01; done
    sleep 0.05
    FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" \
      FM_TEST_LEGACY_READY="$w/legacy-late.ready" \
      FM_TEST_LEGACY_RELEASE="$w/legacy-late.release" \
      "$w/legacy-late/fm-spawn.sh"
  ) &
  launcher=$!
  UPDATE_TEST_PIDS="$UPDATE_TEST_PIDS $launcher"
  out=$(FM_LEGACY_LIFECYCLE_QUIESCENCE_PASSES=3 \
    FM_LEGACY_LIFECYCLE_QUIESCENCE_WAIT=0.2 run_update "$w")
  for _ in $(seq 1 50); do
    [ -e "$w/legacy-late.ready" ] && break
    sleep 0.02
  done
  [ -e "$w/legacy-late.ready" ] || fail "late legacy lifecycle process did not start"
  assert_contains "$out" "fleet lifecycle serialization is busy" \
    "update crossed a legacy lifecycle process that started after admission"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "update advanced after the late legacy lifecycle start"
  touch "$w/legacy-late.release"
  wait "$launcher" 2>/dev/null || true
  pass "T23 update requires a stable empty legacy lifecycle interval"
}

test_lifecycle_identity_uses_command_position_and_fail_closed_scope() {
  local w out holder rc script
  w=$(new_world t24)
  bump_origin "$w" readme
  mkdir -p "$w/legacy-argument" "$w/other-home"
  : > "$w/legacy-argument/fm-teardown.sh"
  bash -c 'while :; do sleep 1; done' "$w/legacy-argument/fm-teardown.sh" &
  holder=$!
  UPDATE_TEST_PIDS="$UPDATE_TEST_PIDS $holder"
  out=$(run_update "$w")
  kill "$holder"
  wait "$holder" 2>/dev/null || true
  assert_contains "$out" "firstmate: updated " \
    "an arbitrary lifecycle-script argument was treated as active lifecycle work"

  rc=0
  (
    FM_STATE_OVERRIDE="$w/helper-state"
    . "$ROOT/bin/fm-wake-lib.sh"
    ps() {
      case "$*" in
        *"eww -p 999"*) return 1 ;;
        *) command ps "$@" ;;
      esac
    }
    fm_spawn_legacy_process_matches_scope \
      999 "$w/legacy-argument/fm-teardown.sh" "$w/home" "$w/home/state"
  ) || rc=$?
  [ "$rc" -eq 2 ] || fail "unreadable lifecycle scope did not return unknown"

  script="$w/legacy-argument/fm-spawn.sh"
  cat > "$script" <<'SH'
#!/usr/bin/env bash
while :; do sleep 1; done
SH
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_script_from_argv bash --norc "$script"
    [ "$FM_LIFECYCLE_SCRIPT" = "$script" ]
    fm_lifecycle_script_from_argv env -u UNUSED bash --norc "$script"
    [ "$FM_LIFECYCLE_SCRIPT" = "$script" ]
    fm_lifecycle_script_from_argv env -a masked bash --norc "$script"
    [ "$FM_LIFECYCLE_SCRIPT" = "$script" ]
    ! fm_lifecycle_script_from_argv bash -c 'exit 0' "$script"
    ! fm_lifecycle_script_from_argv bash -- -x "$script"
  ) || fail "lifecycle command parser lost shell or env option grammar"

  bump_origin "$w" instr
  FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" \
    env -u UNUSED bash --norc "$script" &
  holder=$!
  UPDATE_TEST_PIDS="$UPDATE_TEST_PIDS $holder"
  out=$(run_update "$w")
  kill "$holder"
  wait "$holder" 2>/dev/null || true
  assert_contains "$out" "fleet lifecycle serialization is busy" \
    "shell or env options hid exact lifecycle work from the process bridge"

  FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" \
    bash -c 'exec -a masked bash --norc "$1"' _ "$script" &
  holder=$!
  UPDATE_TEST_PIDS="$UPDATE_TEST_PIDS $holder"
  out=$(run_update "$w")
  kill "$holder"
  wait "$holder" 2>/dev/null || true
  assert_contains "$out" "fleet lifecycle serialization is busy" \
    "rewritten argv0 hid exact lifecycle work from executable identity"

  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_process_environment() {
      FM_LIFECYCLE_ENVIRONMENT_SOURCE=proc
      FM_LIFECYCLE_ENVIRONMENT="FM_HOME=$w/other-home
FM_STATE_OVERRIDE=$w/home/state"
    }
    fm_spawn_legacy_process_matches_scope 999 "$script" "$w/home" "$w/home/state"
  ) || fail "exact target-state evidence was ignored when home evidence differed"

  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_process_environment() {
      FM_LIFECYCLE_ENVIRONMENT_SOURCE=proc
      FM_LIFECYCLE_ENVIRONMENT="FM_HOME=$w/home
FM_STATE_OVERRIDE=$w/other-home/state"
    }
    fm_spawn_legacy_process_matches_scope 999 "$script" "$w/home" "$w/home/state"
  ) || fail "conflicting lifecycle home and state evidence did not fail closed"

  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_process_environment() {
      FM_LIFECYCLE_ENVIRONMENT_SOURCE=proc
      FM_LIFECYCLE_ENVIRONMENT="FM_LIFECYCLE_HOME=$w/other-home
FM_HOME=$w/home
FM_LIFECYCLE_STATE=$w/other-home/state
FM_STATE_OVERRIDE=$w/home/state"
    }
    fm_spawn_legacy_process_matches_scope 999 "$script" "$w/home" "$w/home/state"
  ) || fail "conflicting same-axis lifecycle markers were allowed to override target evidence"

  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_process_environment() {
      FM_LIFECYCLE_ENVIRONMENT_SOURCE=proc
      FM_LIFECYCLE_ENVIRONMENT="FM_HOME=$w/other-home
FM_ROOT_OVERRIDE=$w/home"
    }
    fm_spawn_legacy_process_matches_scope 999 "$script" "$w/home" "$w/home/state"
  ) || fail "target root override was ignored when FM_HOME named another home"

  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_read_proc_argv() {
      FM_LIFECYCLE_ARGV=(bash --norc "$script")
    }
    fm_lifecycle_process_executable() { printf '%s\n' /bin/bash; }
    fm_lifecycle_process_script 999
    [ "$FM_LIFECYCLE_SCRIPT" = "$script" ]
  ) || fail "compatible executable and shell argv identity was rejected"

  rc=0
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_read_proc_argv() {
      FM_LIFECYCLE_ARGV=(fm-spawn.sh)
    }
    fm_lifecycle_process_executable() { printf '%s\n' /bin/sleep; }
    fm_lifecycle_process_script 999
  ) || rc=$?
  [ "$rc" -eq 3 ] || fail "argv0 lifecycle spoof was not rejected by executable identity"

  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_read_proc_argv() {
      FM_LIFECYCLE_ARGV=(masked --norc "$script")
    }
    fm_lifecycle_process_executable() { printf '%s\n' /bin/bash; }
    fm_lifecycle_process_script 999
    [ "$FM_LIFECYCLE_SCRIPT" = "$script" ]
  ) || fail "rewritten argv0 hid a lifecycle script from executable reconciliation"

  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_read_proc_argv() { return 1; }
    fm_lifecycle_process_live() { return 0; }
    fm_lifecycle_process_kernel_thread() { return 1; }
    fm_lifecycle_read_fallback_argv() {
      FM_LIFECYCLE_ARGV=(bash "$script" "later argument contains -c text")
    }
    fm_lifecycle_process_executable() { printf '%s\n' /bin/bash; }
    fm_lifecycle_process_script 999
    [ "$FM_LIFECYCLE_SCRIPT" = "$script" ]
  ) || fail "boundary-preserving fallback argv was not parsed by script position"

  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_read_proc_argv() { return 1; }
    fm_lifecycle_process_live() { return 0; }
    fm_lifecycle_process_kernel_thread() { return 1; }
    fm_lifecycle_read_fallback_argv() {
      FM_LIFECYCLE_ARGV=(editor "$script")
    }
    fm_lifecycle_process_executable() { printf '%s\n' /usr/bin/editor; }
    ! fm_lifecycle_process_script 999
  ) || fail "fallback argv invented lifecycle identity from an arbitrary argument"

  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_read_proc_argv() { return 2; }
    fm_lifecycle_process_live() { return 1; }
    ! fm_lifecycle_process_script 999
  ) || fail "a vanished process was treated as live identity uncertainty"

  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_read_proc_argv() { return 2; }
    fm_lifecycle_process_live() { return 0; }
    fm_lifecycle_process_kernel_thread() { return 0; }
    ! fm_lifecycle_process_script 999
  ) || fail "a kernel thread was treated as lifecycle identity uncertainty"

  rc=0
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_read_proc_argv() { return 2; }
    fm_lifecycle_process_live() { return 0; }
    fm_lifecycle_process_kernel_thread() { return 1; }
    fm_lifecycle_read_fallback_argv() { return 2; }
    fm_lifecycle_process_script 999
  ) || rc=$?
  [ "$rc" -eq 2 ] || fail "unresolved live process identity did not remain fail-closed"
  rc=0
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_read_proc_argv() { return 1; }
    fm_lifecycle_process_live() { return 0; }
    fm_lifecycle_process_kernel_thread() { return 1; }
    fm_lifecycle_read_fallback_argv() { return 2; }
    fm_lifecycle_process_script 999
  ) || rc=$?
  [ "$rc" -eq 2 ] || fail "missing proc argv and unavailable fallback were classified as unrelated"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_identity_result_busy 2
  ) || fail "live identity uncertainty was skipped by the lifecycle census"

  rc=0
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lifecycle_process_environment() {
      FM_LIFECYCLE_ENVIRONMENT_SOURCE=ps
      FM_LIFECYCLE_ENVIRONMENT="bash $script FM_HOME=$w/home with space"
    }
    fm_spawn_legacy_process_matches_scope \
      999 "$script" "$w/home with space" "$w/home with space/state"
  ) || rc=$?
  [ "$rc" -eq 2 ] || fail "boundary-losing fallback scope was classified as unrelated"
  pass "T24 lifecycle identity is positional and unreadable scope fails closed"
}

test_lifecycle_quiescence_clamps_timing_overrides() {
  local w log
  w=$(new_world t25)
  log="$w/quiescence-sleeps"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_spawn_legacy_lifecycle_process_busy() { return 1; }
    sleep() { printf '%s\n' "$1" >> "$log"; }
    FM_LEGACY_LIFECYCLE_QUIESCENCE_PASSES=999 \
      FM_LEGACY_LIFECYCLE_QUIESCENCE_WAIT=0.000001 \
      fm_spawn_legacy_lifecycle_quiescent "$w/home" "$w/home/state"
  ) || fail "clamped lifecycle quiescence refused an empty interval"
  [ "$(wc -l < "$log")" -eq 2 ] \
    || fail "unbounded quiescence pass override was accepted"
  [ "$(sort -u "$log")" = 0.1 ] \
    || fail "microscopic quiescence wait override was accepted"
  pass "T25 lifecycle quiescence timing stays within safe bounds"
}

test_secondmate_fast_forward_requires_lock_capability() {
  local w out rc
  w=$(new_world t26)
  add_sm "$w" sm1
  rc=0
  out=$(
    FM_ROOT="$w/main" FM_HOME="$w/home" bash -c '
      . "$1/bin/fm-ff-lib.sh"
      unset -f fm_ff_target_lock_acquire fm_ff_target_lock_release
      process_secondmate sm1 "$2" "" origin no
    ' _ "$ROOT" "$w/sm1" 2>&1
  ) || rc=$?
  [ "$rc" -ne 0 ] || fail "secondmate fast-forward proceeded without lifecycle lock capability"
  assert_contains "$out" "refused: lifecycle lock capability is unavailable" \
    "missing lifecycle lock capability did not explain the refusal"
  pass "T26 secondmate fast-forward requires lifecycle lock capability"
}

test_fallback_argv_provider_fails_closed_without_boundaries() {
  local rc script
  script="/tmp/fm-spawn.sh"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    sysctl() {
      printf '\003\000\000\000/usr/bin/bash\000\000bash\000%s\000later argument\000' "$script"
    }
    fm_lifecycle_read_fallback_argv 999
    [ "${FM_LIFECYCLE_ARGV[0]}" = bash ] \
      && [ "${FM_LIFECYCLE_ARGV[1]}" = "$script" ] \
      && [ "${FM_LIFECYCLE_ARGV[2]}" = "later argument" ]
  ) || fail "kern.procargs2 fallback did not preserve argv boundaries"
  rc=0
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    sysctl() { return 1; }
    fm_lifecycle_read_fallback_argv 999
  ) || rc=$?
  [ "$rc" -eq 2 ] || fail "fallback argv provider guessed process identity without argument boundaries"
  pass "T27 fallback argv identity uses boundaries or refuses capability"
}

test_secondmate_lock_covers_recovery_callback() {
  local w rc
  w=$(new_world t28)
  mkdir -p "$w/sm1/state"
  printf 'sm1\n' > "$w/sm1/.fm-secondmate-home"
  rc=0
  (
    . "$ROOT/bin/fm-ff-lib.sh"
    FM_ROOT="$w/main"
    FM_HOME="$w/home"
    STATE="$w/home/state"
    lock_held=0
    resolve_path() { cd "$1" && pwd -P; }
    validate_secondmate_home() {
      VALIDATED_HOME=$(cd "$2" && pwd -P)
      return 0
    }
    fm_secondmate_lifecycle_identity_matches() { return 0; }
    fm_ff_target_lock_acquire() { lock_held=1; }
    fm_ff_target_lock_release() { lock_held=0; }
    ff_target() {
      [ "$lock_held" -eq 1 ] || return 1
      FF_STATUS=updated
      FF_INSTR=instructions
      FF_OBLIGATION_GENERATION=generation
    }
    fm_update_obligation_pending() { return 1; }
    fm_ff_after_target_update() {
      [ "$lock_held" -eq 1 ]
    }
    fm_ff_after_instruction_update() {
      [ "$lock_held" -eq 1 ]
    }
    process_secondmate sm1 "$w/sm1" main:fm-sm1 origin no endpoint-sm1
    [ "$lock_held" -eq 0 ]
  ) || rc=$?
  [ "$rc" -eq 0 ] || fail "secondmate lifecycle lock did not cover the recovery callback"
  pass "T28 secondmate lifecycle lock covers fast-forward and recovery callbacks"
}

test_locked_secondmate_action_revalidates_after_acquire() {
  local w callback_file rc
  w=$(new_world t29)
  mkdir -p "$w/sm1/state"
  printf 'sm1\n' > "$w/sm1/.fm-secondmate-home"
  callback_file="$w/callback-ran"
  rc=0
  (
    . "$ROOT/bin/fm-ff-lib.sh"
    validate_secondmate_home() {
      [ "$(cat "$2/.fm-secondmate-home" 2>/dev/null || true)" = "$1" ] || return 1
      VALIDATED_HOME=$(cd "$2" && pwd -P)
    }
    fm_ff_target_lock_acquire() {
      printf 'replacement\n' > "$w/sm1/.fm-secondmate-home"
    }
    fm_ff_target_lock_release() { :; }
    callback() { : > "$callback_file"; }
    fm_ff_locked_secondmate_action sm1 "$w/sm1" "secondmate sm1" callback
  ) || rc=$?
  [ "$rc" -ne 0 ] || fail "locked secondmate action accepted identity reuse during acquisition"
  [ ! -e "$callback_file" ] || fail "locked secondmate action mutated a reused home"
  pass "T29 locked secondmate actions revalidate identity after acquisition"
}

test_secondmate_acknowledgement_respects_lifecycle_lock() {
  local w generation lock rc=0 held_locks=()
  w=$(new_world t30)
  add_sm "$w" sm1
  generation=$(git -C "$w/sm1" rev-parse HEAD)
  mkdir -p "$w/sm1/state"
  printf 'generation=%s\n' "$generation" > "$w/sm1/state/.watch-protocol-reread-required"
  . "$ROOT/bin/fm-wake-lib.sh"
  while IFS= read -r lock; do
    mkdir -p "$(dirname "$lock")"
    fm_lock_try_acquire "$lock" || fail "could not hold update acknowledgement fixture lock"
    held_locks+=("$lock")
  done < <(fm_spawn_admission_lock_paths "$w/sm1/state")
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --ack-secondmate-nudge main:fm-sm1 "$generation" >/dev/null 2>&1 || rc=$?
  for lock in "${held_locks[@]}"; do
    fm_lock_release "$lock"
  done
  [ "$rc" -ne 0 ] || fail "secondmate acknowledgement crossed an active lifecycle lock"
  [ -f "$w/sm1/state/.watch-protocol-reread-required" ] \
    || fail "secondmate acknowledgement cleared a locked home's obligation"
  pass "T30 secondmate acknowledgement stays behind the lifecycle lock"
}

test_ambiguous_lifecycle_metadata_refuses_update() {
  local w out before foreign
  w=$(new_world t31)
  add_sm "$w" sm1
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr
  foreign="$w/recycled"
  mkdir -p "$foreign/state"
  printf 'home=%s\n' "$foreign" >> "$w/home/state/sm1.meta"

  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>&1)

  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "ambiguous lifecycle metadata authorized a secondmate update"
  [ ! -e "$foreign/state/.spawn-admission.lock" ] \
    && [ ! -e "$foreign/state/.locks" ] \
    || fail "ambiguous lifecycle metadata created a lock under an unvalidated home"
  assert_contains "$out" "ambiguous lifecycle metadata" \
    "ambiguous lifecycle metadata refusal was not reported"
  pass "T31 ambiguous lifecycle metadata refuses update mutations"
}

test_acknowledgement_requires_locked_strict_preflight() {
  local w generation marker rc=0
  w=$(new_world t31-ack-preflight)
  add_sm "$w" sm1
  generation=$(git -C "$w/main" rev-parse HEAD)
  marker="$w/home/state/.watch-protocol-reread-required"
  fm_update_obligation_write "$marker" "$generation"
  printf 'home=%s/recycled\n' "$w" >> "$w/home/state/sm1.meta"
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --ack-reread-firstmate "$generation" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "acknowledgement bypassed strict lifecycle preflight"
  fm_update_obligation_pending "$marker" "$w/main" \
    || fail "failed lifecycle preflight cleared the reread obligation"
  pass "update acknowledgements stay behind locked strict preflight"
}

test_reexec_lock_reentry_requires_complete_identity() {
  local w lock helper
  w=$(new_world t31-reexec-lock)
  lock="$w/home/state/.reexec-test.lock"
  mkdir -p "$w/bin"
  helper="$w/bin/fm-update.sh"
  cp "$ROOT/tests/fixtures/fm-lock-reexec-helper.sh" "$helper"
  chmod +x "$helper"
  "$helper" "$ROOT" "$lock" \
    || fail "complete reexec identity could not safely reenter its symlink lock"
  pass "reexec lock ownership verifies PID, start, identity, token, and symlink"
}

test_live_endpoint_generation_mismatch_refuses_lifecycle_identity() {
  local w rc=0
  w=$(new_world t31-live-generation)
  add_sm "$w" sm1
  (
    fm_backend_endpoint_generation() { printf 'recycled'; }
    fm_secondmate_lifecycle_identity_matches "$w/home/state" sm1 "$w/sm1" \
      main:fm-sm1 endpoint-sm1 tmux:main:fm-sm1
  ) || rc=$?
  [ "$rc" -ne 0 ] || fail "recycled live endpoint generation matched stale metadata"
  pass "live endpoint generation mismatches refuse lifecycle identity"
}

test_live_generation_preflight_preserves_primary() {
  local w before out rc=0
  w=$(new_world t31-live-preflight)
  add_sm "$w" sm1
  bump_origin "$w" instr
  before=$(git -C "$w/main" rev-parse HEAD)
  sed -i 's/^endpoint_generation=.*/endpoint_generation=stale-endpoint/' \
    "$w/home/state/sm1.meta"
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "stale live endpoint generation passed update preflight"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "primary advanced before stale endpoint generation was refused"
  assert_contains "$out" "live endpoint generation" \
    "stale endpoint preflight did not report the lifecycle mismatch"
  pass "live endpoint generation is proven before any update mutation"
}

test_corrupt_kind_preflight_preserves_primary() {
  local w before out rc=0
  w=$(new_world t31-corrupt-kind)
  add_sm "$w" sm1
  bump_origin "$w" instr
  before=$(git -C "$w/main" rev-parse HEAD)
  sed -i 's/^kind=secondmate$/kind=corrupt/' "$w/home/state/sm1.meta"
  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "corrupt lifecycle kind passed update preflight"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "primary advanced before corrupt lifecycle kind was refused"
  assert_contains "$out" "invalid lifecycle kind metadata" \
    "corrupt lifecycle kind refusal was not reported"
  pass "corrupt lifecycle records are refused before any update mutation"
}

test_secondmate_delivery_is_one_locked_generation_transaction() {
  local w generation fakebin out lock
  w=$(new_world t32)
  add_sm "$w" sm1
  generation=$(git -C "$w/sm1" rev-parse HEAD)
  mkdir -p "$w/sm1/state"
  fm_update_obligation_write \
    "$w/sm1/state/.watch-protocol-reread-required" "$generation"
  fakebin=$(make_fake_tmux "$w/send-fake")
  lock="$w/sm1/state/.spawn-admission.lock"

  out=$(cd "$w" && env -u NO_MISTAKES_GATE PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    FM_FAKE_TMUX_LOG="$w/send-fake/tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$w/send-fake/pane.txt" \
    FM_FAKE_REQUIRED_LOCK="$lock" FM_SEND_SETTLE=0 \
    "$UPDATE" --deliver-secondmate-nudge main:fm-sm1 "$generation")

  assert_contains "$out" "delivered-secondmate-nudge: main:fm-sm1" \
    "locked secondmate delivery did not report completion"
  fm_update_obligation_pending \
    "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1" \
    && fail "locked secondmate delivery did not acknowledge its generation"
  grep -qx 'state=complete' \
    "$w/home/state/.secondmate-nudge-delivered/sm1/$generation" \
    || fail "completed secondmate delivery did not retain its terminal receipt"
  pass "T32 secondmate delivery sends and acknowledges under one lifecycle lock"
}

test_secondmate_delivery_uses_recorded_exact_tmux_pane() {
  local w generation fakebin out runtime resolved meta legacy_meta foreign_meta
  local ownership_meta ownership_fakebin
  w=$(new_world t32-exact-pane)
  add_sm "$w" sm1
  sed -i 's/^window=.*/window=@42/' "$w/home/state/sm1.meta"
  printf 'tmux_pane_id=%%42\n' >> "$w/home/state/sm1.meta"
  generation=$(git -C "$w/sm1" rev-parse HEAD)
  fakebin=$(make_fake_tmux "$w/exact-pane-send-fake")
  runtime="$w/exact-pane-send-runtime"
  local PATH="$fakebin:$PATH"
  local FM_FAKE_TMUX_LOG="$w/exact-pane-send-fake/tmux.log"
  local FM_FAKE_TMUX_CAPTURE="$w/exact-pane-send-fake/pane.txt"
  local FM_FAKE_ENDPOINT_GENERATION=endpoint-sm1
  export PATH FM_FAKE_TMUX_LOG FM_FAKE_TMUX_CAPTURE
  export FM_FAKE_ENDPOINT_GENERATION
  mkdir -p "$runtime"
  cat > "$runtime/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' \
  "${FM_SEND_BOUND_BACKEND:-}" "${FM_SEND_BOUND_TARGET:-}" "$1" \
  > "$FM_TEST_SEND_LOG"
. "$FM_TEST_PENDING_LIB"
fm_pending_reply_confirm_delivery \
  "$FM_STATE_OVERRIDE" "$FM_PENDING_REPLY_EXISTING_CORR"
SH
  chmod +x "$runtime/fm-send.sh"

  out=$(cd "$w/main" && PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    FM_FAKE_TMUX_LOG="$w/exact-pane-send-fake/tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$w/exact-pane-send-fake/pane.txt" \
    FM_FAKE_ENDPOINT_GENERATION=endpoint-sm1 \
    FM_TEST_SEND_LOG="$w/exact-pane-send.log" \
    FM_TEST_PENDING_LIB="$ROOT/bin/fm-pending-reply-lib.sh" \
    _FM_SECONDMATE_DELIVERY_LIB_DIR="$runtime" \
    fm_secondmate_delivery_send_locked \
      "$w/home/state" "$w/home" sm1 "$w/sm1" @42 endpoint-sm1 "" \
      update-nudge "$generation" "exact pane delivery")
  [ -z "$out" ] || fail "exact-pane delivery emitted unexpected output: $out"
  [ "$(cat "$w/exact-pane-send.log")" = 'tmux|%42|fm-sm1' ] \
    || fail "secondmate delivery did not bind fm-send to the recorded exact pane"
  resolved=$(fm_backend_resolve_selector_with_backend \
    fm-sm1 "$w/home/state")
  [ "$resolved" = $'tmux\t%42' ] \
    || fail "fm-send selector resolution did not retain the exact tmux pane"
  meta="$w/home/state/sm1.meta"
  sed -i '/^tmux_pane_id=/d;/^endpoint_generation=/d;/^task=/d' "$meta"
  sed -i 's/^window=.*/window=firstmate:fm-sm1/' "$meta"
  mkdir "$meta.endpoint-migration.lock"
  touch -t 200001010000 "$meta.endpoint-migration.lock"
  resolved=$(
    fm_backend_tmux_legacy_process_pid() { printf '%s' "$$"; }
    fm_harness_pid_alive() { return 0; }
    fm_agent_proc_cwd() { printf '%s' "$w/sm1"; }
    fm_agent_environ() {
      printf 'FM_AGENT_TASK=sm1\nFM_AGENT_OWNER_HOME=%s\nFM_AGENT_ROLE=secondmate\n' \
        "$w/sm1"
    }
    fm_backend_resolve_selector_with_backend fm-sm1 "$w/home/state"
  )
  [ "$resolved" = $'tmux\t%42' ] \
    || fail "pre-port tmux metadata did not migrate to its exact live pane"
  [ ! -e "$meta.endpoint-migration.lock" ] \
    && [ ! -L "$meta.endpoint-migration.lock" ] \
    || fail "legacy tmux migration left its recovered lifecycle lock behind"
  [ "$(grep -c '^window=@42$' "$meta")" -eq 1 ] \
    && [ "$(grep -c '^tmux_pane_id=%42$' "$meta")" -eq 1 ] \
    && [ "$(grep -c '^endpoint_generation=fm-legacy-' "$meta")" -eq 1 ] \
    && [ "$(grep -c '^task=sm1$' "$meta")" -eq 1 ] \
    || fail "pre-port tmux metadata migration was incomplete or ambiguous"
  foreign_meta="$w/home/state/foreign.meta"
  mkdir -p "$w/foreign"
  printf 'foreign\n' > "$w/foreign/.fm-secondmate-home"
  {
    printf 'window=firstmate:fm-foreign\n'
    printf 'kind=secondmate\n'
    printf 'harness=codex\n'
    printf 'home=%s/foreign\n' "$w"
  } > "$foreign_meta"
  if (
    fm_backend_tmux_legacy_process_pid() { printf '%s' "$$"; }
    fm_harness_pid_alive() { return 0; }
    fm_agent_proc_cwd() { printf '%s' "$w/foreign"; }
    fm_agent_environ() {
      printf 'FM_AGENT_TASK=foreign\nFM_AGENT_OWNER_HOME=%s\nFM_AGENT_ROLE=secondmate\n' \
        "$w/foreign"
    }
    fm_backend_resolve_selector_with_backend fm-foreign "$w/home/state"
  ) >/dev/null 2>&1; then
    fail "legacy migration rebound a pane already owned by another task"
  fi
  [ "$(grep -c '^tmux_pane_id=' "$foreign_meta")" -eq 0 ] \
    && [ "$(grep -c '^endpoint_generation=' "$foreign_meta")" -eq 0 ] \
    || fail "foreign legacy metadata was partially rebound"
  ownership_meta="$w/home/state/ownership.meta"
  mkdir -p "$w/ownership"
  printf 'ownership\n' > "$w/ownership/.fm-secondmate-home"
  {
    printf 'window=firstmate:fm-ownership\n'
    printf 'kind=secondmate\n'
    printf 'harness=codex\n'
    printf 'home=%s/ownership\n' "$w"
  } > "$ownership_meta"
  ownership_fakebin=$(make_fake_tmux "$w/ownership-fake")
  if (
    PATH="$ownership_fakebin:$PATH"
    FM_FAKE_TMUX_LOG="$w/ownership-fake/tmux.log"
    export PATH FM_FAKE_TMUX_LOG
    fm_backend_tmux_legacy_process_pid() { printf '%s' "$$"; }
    fm_harness_pid_alive() { return 0; }
    fm_agent_proc_cwd() { printf '%s' "$w/sm1"; }
    fm_agent_environ() {
      printf 'FM_AGENT_TASK=ownership\nFM_AGENT_OWNER_HOME=%s\nFM_AGENT_ROLE=secondmate\n' \
        "$w/ownership"
    }
    fm_backend_resolve_selector_with_backend fm-ownership "$w/home/state"
  ) >/dev/null 2>&1; then
    fail "legacy migration accepted a harness from another task home"
  fi
  [ ! -e "$w/ownership-fake/tmux.log.endpoint-generation" ] \
    || fail "legacy ownership refusal mutated the pane generation"
  [ "$(grep -c '^tmux_pane_id=' "$ownership_meta")" -eq 0 ] \
    && [ "$(grep -c '^endpoint_generation=' "$ownership_meta")" -eq 0 ] \
    || fail "unowned legacy metadata was partially migrated"
  legacy_meta="$w/home/state/legacy-ambiguous.meta"
  printf 'window=firstmate:fm-legacy-ambiguous\nkind=secondmate\n' \
    > "$legacy_meta"
  if FM_FAKE_PANE_ID=$'%42\n%43' \
    fm_backend_resolve_selector_with_backend \
      fm-legacy-ambiguous "$w/home/state" >/dev/null 2>&1; then
    fail "pre-port tmux migration accepted an ambiguous multi-pane window"
  fi
  [ "$(grep -c '^tmux_pane_id=' "$legacy_meta")" -eq 0 ] \
    && [ "$(grep -c '^endpoint_generation=' "$legacy_meta")" -eq 0 ] \
    || fail "ambiguous pre-port tmux metadata was partially migrated"
  printf 'tmux_pane_id=%%43\n' >> "$meta"
  ! fm_backend_resolve_selector_with_backend fm-sm1 "$w/home/state" \
    >/dev/null 2>&1 \
    || fail "ordinary selector accepted duplicate tmux pane metadata"
  sed -i '$d' "$meta"
  sed -i 's/^tmux_pane_id=.*/tmux_pane_id=42/' "$meta"
  ! fm_backend_resolve_selector_with_backend fm-sm1 "$w/home/state" \
    >/dev/null 2>&1 \
    || fail "ordinary selector accepted malformed tmux pane metadata"
  sed -i 's/^tmux_pane_id=.*/tmux_pane_id=%42/' "$meta"
  sed -i 's/^window=.*/window=@43/' "$meta"
  ! fm_backend_resolve_selector_with_backend fm-sm1 "$w/home/state" \
    >/dev/null 2>&1 \
    || fail "ordinary selector accepted a pane outside the recorded window"
  sed -i 's/^window=.*/window=@42/' "$meta"
  sed -i 's/^endpoint_generation=.*/endpoint_generation=recycled/' "$meta"
  ! fm_backend_resolve_selector_with_backend fm-sm1 "$w/home/state" \
    >/dev/null 2>&1 \
    || fail "ordinary selector accepted a recycled tmux pane generation"
  pass "T32a secondmate delivery stays bound to its exact tmux pane"
}

test_secondmate_delivery_refuses_recycled_endpoint_ack() {
  local w generation fakebin lock rc=0
  w=$(new_world t33)
  add_sm "$w" sm1
  generation=$(git -C "$w/sm1" rev-parse HEAD)
  mkdir -p "$w/sm1/state"
  fm_update_obligation_write \
    "$w/sm1/state/.watch-protocol-reread-required" "$generation"
  fakebin=$(make_fake_tmux "$w/recycle-fake")
  lock="$w/sm1/state/.spawn-admission.lock"

  (cd "$w" && env -u NO_MISTAKES_GATE PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    FM_FAKE_TMUX_LOG="$w/recycle-fake/tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$w/recycle-fake/pane.txt" \
    FM_FAKE_REQUIRED_LOCK="$lock" \
    FM_FAKE_REPLACE_META_ON_SEND="$w/home/state/sm1.meta" \
    FM_SEND_SETTLE=0 "$UPDATE" --deliver-secondmate-nudge \
    main:fm-sm1 "$generation" >/dev/null 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "delivery acknowledged a recycled endpoint generation"
  fm_update_obligation_pending \
    "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1" \
    || fail "recycled endpoint cleared the durable nudge obligation"
  pass "T33 secondmate delivery refuses acknowledgement after endpoint reuse"
}

test_duplicate_provider_fields_refuse_lifecycle_mutation() {
  local w before out
  w=$(new_world t34)
  add_sm "$w" sm1
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr
  {
    printf 'backend=herdr\n'
    printf 'backend=herdr\n'
    printf 'herdr_session=session-a\n'
    printf 'herdr_workspace_id=workspace-a\n'
    printf 'herdr_tab_id=tab-a\n'
    printf 'herdr_pane_id=pane-a\n'
  } >> "$w/home/state/sm1.meta"

  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>&1)

  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "duplicate provider fields authorized a secondmate update"
  assert_contains "$out" "ambiguous lifecycle metadata" \
    "duplicate provider fields did not produce a lifecycle refusal"
  pass "T34 duplicate provider fields refuse lifecycle mutations"
}

test_prepared_delivery_transaction_is_never_resent() {
  local w generation receipt correlation provider target fakebin out rc=0
  w=$(new_world t35)
  add_sm "$w" sm1
  generation=$(git -C "$w/sm1" rev-parse HEAD)
  target=main:fm-sm1
  provider="tmux:$target"
  mkdir -p "$w/sm1/state"
  fm_update_obligation_write \
    "$w/sm1/state/.watch-protocol-reread-required" "$generation"
  receipt="$w/home/state/.secondmate-nudge-delivered/sm1/$generation"
  mkdir -p "${receipt%/*}"
  correlation=$(FM_PENDING_REPLY_NOW=100 \
    fm_pending_reply_create "$w/home" "$w/home/state" sm1 \
      'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.')
  fm_pending_reply_set "$(fm_pending_reply_path "$w/home/state" "$correlation")" \
    fm_delivery_transaction \
    "$(printf '%s' "update-nudge|sm1|$w/sm1|$target|endpoint-sm1|$provider|$generation|$(printf '%s' 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.' | cksum | awk '{printf "%s-%s", $1, $2}')" \
      | cksum | awk '{printf "%s-%s", $1, $2}')"
  fm_pending_reply_prepare_delivery "$w/home/state" "$correlation"
  fm_secondmate_delivery_receipt_write "$receipt" update-nudge sm1 "$w/sm1" \
    "$target" endpoint-sm1 "$generation" "$provider" "$correlation" \
    "$(printf '%s' 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.' \
      | cksum | awk '{printf "%s-%s", $1, $2}')" prepared
  fakebin=$(make_fake_tmux "$w/prepared-fake")

  out=$(cd "$w" && env -u NO_MISTAKES_GATE PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    FM_FAKE_TMUX_LOG="$w/prepared-fake/tmux.log" \
    "$UPDATE" --deliver-secondmate-nudge "$target" "$generation" 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "indeterminate prepared delivery was acknowledged"
  assert_contains "$out" "delivery is indeterminate" \
    "prepared delivery transaction did not fail closed"
  [ ! -s "$w/prepared-fake/tmux.log" ] \
    || fail "prepared delivery transaction was sent again"
  fm_update_obligation_pending \
    "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1" \
    || fail "prepared delivery recovery cleared the obligation without delivery proof"
  pass "T35 prepared delivery transactions remain pending without delivery proof"
}

test_do_not_resend_delivery_is_acknowledged_once() {
  local w generation target fakebin out sends
  w=$(new_world t36)
  add_sm "$w" sm1
  generation=$(git -C "$w/sm1" rev-parse HEAD)
  target=main:fm-sm1
  mkdir -p "$w/sm1/state"
  fm_update_obligation_write \
    "$w/sm1/state/.watch-protocol-reread-required" "$generation"
  fakebin=$(make_fake_tmux "$w/do-not-resend-fake")
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ -f "$arg" ] || continue
  if grep -q '^schema=fm-pending-reply.v1$' "$arg" 2>/dev/null \
    && grep -Eq '^delivered_epoch=[0-9]+$' "$arg" 2>/dev/null \
    && [ ! -e "${FM_FAKE_MV_ONCE:?}" ]; then
    : > "$FM_FAKE_MV_ONCE"
    exit 1
  fi
done
exec /bin/mv "$@"
SH
  chmod +x "$fakebin/mv"

  out=$(cd "$w" && env -u NO_MISTAKES_GATE PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    FM_FAKE_TMUX_LOG="$w/do-not-resend-fake/tmux.log" \
    FM_FAKE_TMUX_CAPTURE="$w/do-not-resend-fake/pane.txt" FM_SEND_SETTLE=0 \
    FM_FAKE_MV_ONCE="$w/do-not-resend-fake/mv-once" \
    "$UPDATE" --deliver-secondmate-nudge "$target" "$generation")

  assert_contains "$out" "delivered-secondmate-nudge: $target" \
    "confirmed delivery failure was not classified as do-not-resend"
  sends=$(grep -Fc 'firstmate was updated to the latest' \
    "$w/do-not-resend-fake/tmux.log" 2>/dev/null || true)
  [ "$sends" -eq 1 ] || fail "do-not-resend delivery was typed $sends times"
  fm_update_obligation_pending \
    "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1" \
    && fail "do-not-resend delivery left a duplicate retry obligation"
  pass "T36 do-not-resend delivery outcomes are acknowledged once"
}

test_conflicting_herdr_window_refuses_lifecycle_mutation() {
  local w before out
  w=$(new_world t37)
  add_sm "$w" sm1
  before=$(git -C "$w/sm1" rev-parse HEAD)
  bump_origin "$w" instr
  {
    printf 'backend=herdr\n'
    printf 'herdr_session=session-a\n'
    printf 'herdr_workspace_id=workspace-a\n'
    printf 'herdr_tab_id=tab-a\n'
    printf 'herdr_pane_id=pane-a\n'
  } >> "$w/home/state/sm1.meta"

  out=$(FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>&1)

  [ "$(git -C "$w/sm1" rev-parse HEAD)" = "$before" ] \
    || fail "conflicting Herdr window authorized a secondmate update"
  assert_contains "$out" "conflicting Herdr endpoint representations" \
    "conflicting Herdr window did not produce a lifecycle refusal"
  pass "T37 conflicting Herdr endpoint representations refuse lifecycle mutation"
}

test_ambiguous_delivery_bindings_refuse_without_send() {
  local w generation target provider signature corr fakebin rc=0
  w=$(new_world t38)
  add_sm "$w" sm1
  generation=$(git -C "$w/sm1" rev-parse HEAD)
  target=main:fm-sm1
  provider="tmux:$target"
  mkdir -p "$w/sm1/state"
  fm_update_obligation_write \
    "$w/sm1/state/.watch-protocol-reread-required" "$generation"
  signature=$(printf '%s' \
    "update-nudge|sm1|$w/sm1|$target|endpoint-sm1|$provider|$generation|$(printf '%s' 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.' | cksum | awk '{printf "%s-%s", $1, $2}')" \
    | cksum | awk '{printf "%s-%s", $1, $2}')
  for corr in one two; do
    corr=$(fm_pending_reply_create "$w/home" "$w/home/state" sm1 \
      'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.')
    fm_pending_reply_set "$(fm_pending_reply_path "$w/home/state" "$corr")" \
      fm_delivery_transaction "$signature"
  done
  fakebin=$(make_fake_tmux "$w/ambiguous-binding-fake")
  (cd "$w" && env -u NO_MISTAKES_GATE PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    FM_FAKE_TMUX_LOG="$w/ambiguous-binding-fake/tmux.log" \
    "$UPDATE" --deliver-secondmate-nudge "$target" "$generation" \
    >/dev/null 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "ambiguous delivery bindings were accepted"
  [ ! -s "$w/ambiguous-binding-fake/tmux.log" ] \
    || fail "ambiguous delivery bindings caused a send"
  fm_update_obligation_pending \
    "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1" \
    || fail "ambiguous delivery bindings cleared the obligation"
  pass "T38 ambiguous delivery bindings refuse without sending"
}

test_delivery_prepare_failure_rolls_back_receipt_and_binding() {
  local w generation target fakebin receipt rc=0 bindings
  w=$(new_world t39)
  add_sm "$w" sm1
  generation=$(git -C "$w/sm1" rev-parse HEAD)
  target=main:fm-sm1
  mkdir -p "$w/sm1/state"
  fm_update_obligation_write \
    "$w/sm1/state/.watch-protocol-reread-required" "$generation"
  fakebin=$(make_fake_tmux "$w/prepare-failure-fake")
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ -f "$arg" ] || continue
  if grep -Eq '^attempted=[0-9]+$' "$arg" 2>/dev/null \
    && [ ! -e "${FM_FAKE_PREPARE_FAILED:?}" ]; then
    : > "$FM_FAKE_PREPARE_FAILED"
    exit 1
  fi
done
exec /bin/mv "$@"
SH
  chmod +x "$fakebin/mv"
  (cd "$w" && env -u NO_MISTAKES_GATE PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    FM_FAKE_TMUX_LOG="$w/prepare-failure-fake/tmux.log" \
    FM_FAKE_PREPARE_FAILED="$w/prepare-failure-fake/failed" \
    "$UPDATE" --deliver-secondmate-nudge "$target" "$generation" \
    >/dev/null 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "delivery preparation failure unexpectedly succeeded"
  receipt="$w/home/state/.secondmate-nudge-delivered/sm1/$generation"
  [ ! -e "$receipt" ] && [ ! -L "$receipt" ] \
    || fail "delivery preparation failure left an orphan receipt"
  bindings=$(grep -l '^fm_delivery_transaction=' \
    "$w/home/state/pending-replies"/* 2>/dev/null || true)
  [ -z "$bindings" ] || fail "delivery preparation failure left a bound pending record"
  [ ! -s "$w/prepare-failure-fake/tmux.log" ] \
    || fail "delivery preparation failure reached transport"
  pass "T39 delivery preparation rollback leaves no orphan transaction"
}

test_confirmed_receipt_reconciles_after_obligation_cleanup_crash() {
  local w generation target provider signature correlation receipt fakebin out sends
  w=$(new_world t40)
  add_sm "$w" sm1
  generation=$(git -C "$w/sm1" rev-parse HEAD)
  target=main:fm-sm1
  provider="tmux:$target"
  signature=$(printf '%s' \
    "update-nudge|sm1|$w/sm1|$target|endpoint-sm1|$provider|$generation|$(printf '%s' 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.' | cksum | awk '{printf "%s-%s", $1, $2}')" \
    | cksum | awk '{printf "%s-%s", $1, $2}')
  correlation=$(fm_pending_reply_create "$w/home" "$w/home/state" sm1 \
    'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.')
  fm_pending_reply_set "$(fm_pending_reply_path "$w/home/state" "$correlation")" \
    fm_delivery_transaction "$signature"
  fm_pending_reply_prepare_delivery "$w/home/state" "$correlation"
  fm_pending_reply_mark_delivered "$w/home/state" "$correlation" 100
  receipt="$w/home/state/.secondmate-nudge-delivered/sm1/$generation"
  fm_secondmate_delivery_receipt_write "$receipt" update-nudge sm1 "$w/sm1" \
    "$target" endpoint-sm1 "$generation" "$provider" "$correlation" \
    "$(printf '%s' 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.' \
      | cksum | awk '{printf "%s-%s", $1, $2}')" finalizing
  mkdir -p "$(fm_pending_reply_history_dir "$w/home/state")"
  mv "$(fm_pending_reply_active_path "$w/home/state" "$correlation")" \
    "$(fm_pending_reply_history_dir "$w/home/state")/$correlation"
  fakebin=$(make_fake_tmux "$w/terminal-cleanup-fake")
  out=$(cd "$w" && env -u NO_MISTAKES_GATE PATH="$fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    FM_FAKE_TMUX_LOG="$w/terminal-cleanup-fake/tmux.log" \
    "$UPDATE" --deliver-secondmate-nudge "$target" "$generation")
  assert_contains "$out" "delivered-secondmate-nudge: $target" \
    "confirmed orphan receipt did not reconcile"
  grep -qx 'state=complete' "$receipt" \
    || fail "confirmed orphan receipt did not become a terminal tombstone"
  sends=$(grep -Fc 'firstmate was updated to the latest' \
    "$w/terminal-cleanup-fake/tmux.log" 2>/dev/null || true)
  [ "$sends" -eq 0 ] || fail "orphan receipt recovery resent the request"
  pass "update reconciles confirmed receipts after obligation cleanup crashes"
}

if [ "${FM_UPDATE_FOCUS:-}" = exact-pane-delivery ]; then
  test_secondmate_delivery_uses_recorded_exact_tmux_pane
  echo "# focused exact-pane delivery tests passed"
  exit 0
fi

test_updates_main_and_secondmate
test_reread_gate_is_instruction_only
test_dirty_secondmate_skipped
test_diverged_secondmate_skipped
test_idempotent_already_current
test_registry_backstop_dedup_and_self_exclusion
test_firstmate_wrong_branch_skipped
test_firstmate_detached_head_skipped
test_unsafe_secondmate_home_skipped_before_git_update
test_replays_interrupted_reread_and_nudge_obligations
test_first_protocol_upgrade_requires_installed_updater_pass
test_acknowledgements_are_generation_bound
test_herdr_target_acknowledges_exact_live_meta
test_immutable_generations_preserve_prepared_and_newer_markers
test_skipped_update_reports_existing_generation
test_future_legacy_generation_survives_concurrent_ack
test_future_only_legacy_generation_updates_on_first_retry
test_update_refuses_workers_before_state_resolution
test_update_waits_for_legacy_admission_and_task_locks
test_update_ignores_legacy_lifecycle_process_for_another_home
test_update_quiescence_catches_late_legacy_lifecycle_start
test_lifecycle_identity_uses_command_position_and_fail_closed_scope
test_lifecycle_quiescence_clamps_timing_overrides
test_secondmate_fast_forward_requires_lock_capability
test_fallback_argv_provider_fails_closed_without_boundaries
test_secondmate_lock_covers_recovery_callback
test_locked_secondmate_action_revalidates_after_acquire
test_secondmate_acknowledgement_respects_lifecycle_lock
test_ambiguous_lifecycle_metadata_refuses_update
test_acknowledgement_requires_locked_strict_preflight
test_reexec_lock_reentry_requires_complete_identity
test_live_endpoint_generation_mismatch_refuses_lifecycle_identity
test_live_generation_preflight_preserves_primary
test_corrupt_kind_preflight_preserves_primary
test_secondmate_delivery_is_one_locked_generation_transaction
test_secondmate_delivery_uses_recorded_exact_tmux_pane
test_secondmate_delivery_refuses_recycled_endpoint_ack
test_duplicate_provider_fields_refuse_lifecycle_mutation
test_prepared_delivery_transaction_is_never_resent
test_do_not_resend_delivery_is_acknowledged_once
test_conflicting_herdr_window_refuses_lifecycle_mutation
test_ambiguous_delivery_bindings_refuse_without_send
test_delivery_prepare_failure_rolls_back_receipt_and_binding
test_confirmed_receipt_reconciles_after_obligation_cleanup_crash

echo "# all fm-update tests passed"
