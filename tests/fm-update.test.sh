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

UPDATE="$ROOT/bin/fm-update.sh"
# shellcheck source=bin/fm-ff-lib.sh
. "$ROOT/bin/fm-ff-lib.sh"

# Deterministic, isolated git identity for fixture commits.
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-update-tests)
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
  printf 'v1\n' > "$w/seed/AGENTS.md"
  printf 'state/\ndata/\nconfig/\nprojects/\n' > "$w/seed/.gitignore"
  git -C "$w/seed" add -A
  git -C "$w/seed" commit -qm protocol-v1
  git -C "$w/seed" push -q origin main
  git clone -q "$w/origin.git" "$w/main"
  git -C "$w/main" remote set-head origin main >/dev/null 2>&1 || true
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
    printf 'home=%s/%s\n' "$w" "$id"
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
  local w=$1
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" "$UPDATE" 2>/dev/null
}

ack_firstmate_reread() {
  local w=$1 generation
  generation=$(fm_update_obligation_generation \
    "$w/home/state/.watch-protocol-reread-required" "$w/main")
  FM_ROOT_OVERRIDE="$w/main" FM_HOME="$w/home" \
    "$UPDATE" --ack-reread-firstmate "$generation" >/dev/null
}

ack_secondmate_nudge() {
  local w=$1 target=$2 generation
  generation=$(fm_update_obligation_generation \
    "$w/sm1/state/.watch-protocol-reread-required" "$w/sm1")
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
# Asserts: reg1 advances but is NOT nudged (no live metadata); sm1 advances,
# is processed once, and IS nudged; the firstmate repo is never re-processed.
test_registry_backstop_dedup_and_self_exclusion() {
  local w out count
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

  out=$(run_update "$w")

  assert_contains "$out" "secondmate reg1: updated " "registry-only secondmate fast-forwarded"
  assert_contains "$out" "secondmate sm1: updated " "meta+registry secondmate fast-forwarded"
  count=$(printf '%s\n' "$out" | grep -c '^secondmate sm1:' || true)
  [ "$count" -eq 1 ] || fail "secondmate sm1 processed $count times, expected 1 (dedup across meta+registry)"
  assert_not_contains "$out" "secondmate selfish" "firstmate repo re-processed as its own secondmate"
  # sm1 has live metadata, so it is nudged; reg1 has none, so it is not. Pin the
  # nudge line exactly and confirm reg1 is absent from it (not from the whole
  # output, where 'secondmate reg1: updated' legitimately appears).
  local nudge_line
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_contains "$nudge_line" "main:fm-sm1" "live-meta secondmate is nudged"
  assert_not_contains "$nudge_line" "reg1" "registry-only secondmate without live metadata is not nudged"
  pass "T7 registry backstop resolves, dedups meta+registry, excludes the firstmate repo"
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

  assert_contains "$out" "firstmate: skipped: on feature/wip, expected main" "off-default firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "skipped firstmate HEAD moved"
  pass "T9 firstmate off its default branch is skipped, not forced"
}

test_firstmate_detached_head_skipped() {
  local w out before
  w=$(new_world t10)
  bump_origin "$w" instr
  git -C "$w/main" checkout -q --detach HEAD
  before=$(git -C "$w/main" rev-parse HEAD)

  out=$(run_update "$w")

  assert_contains "$out" "firstmate: skipped: detached HEAD, expected main" "detached firstmate skipped"
  assert_contains "$out" "reread-firstmate: no" "no reread when detached firstmate was skipped"
  [ "$(git -C "$w/main" rev-parse HEAD)" = "$before" ] \
    || fail "detached firstmate HEAD moved"
  pass "T10 firstmate detached HEAD is skipped"
}

test_unsafe_secondmate_home_skipped_before_git_update() {
  local w out bad before
  w=$(new_world t11)
  bad="$w/home/projects/bad"
  mkdir -p "$w/home/projects"
  git clone -q "$w/origin.git" "$bad"
  printf 'bad\n' > "$bad/.fm-secondmate-home"
  before=$(git -C "$bad" rev-parse HEAD)
  printf -- '- bad - bad home (home: %s; scope: x; projects: p; added 2026-06-23)\n' \
    "$bad" > "$w/home/data/secondmates.md"
  bump_origin "$w" instr

  out=$(run_update "$w")

  assert_contains "$out" "secondmate bad: skipped: unsafe home: secondmate home cannot be inside the active firstmate home" \
    "unsafe project-like home skipped"
  assert_contains "$out" "nudge-secondmates: none" "unsafe home is not nudged"
  [ "$(git -C "$bad" rev-parse HEAD)" = "$before" ] \
    || fail "unsafe secondmate home HEAD moved"
  pass "T11 unsafe secondmate home is not fast-forwarded"
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

  PATH="$fakebin:$PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_STATE_OVERRIDE="$w/home/state" FM_POLL=5 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$w/main/bin/fm-watch.sh" >/dev/null 2>&1 &
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

  PATH="$fakebin:$PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_STATE_OVERRIDE="$w/home/state" FM_POLL=5 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$w/main/bin/fm-watch-arm.sh" >"$w/arm.out" &
  arm=$!
  UPDATE_TEST_PIDS="$UPDATE_TEST_PIDS $arm"
  for _ in $(seq 1 60); do
    [ "$(cat "$w/home/state/.watch-arm.lock/pid" 2>/dev/null || true)" = "$arm" ] && break
    sleep 0.1
  done
  [ "$(cat "$w/home/state/.watch-arm.lock/pid" 2>/dev/null || true)" = "$arm" ] \
    || fail "migration fixture did not attach a v1 follower"

  rc=0
  # A v2 updater completed the install before the v3 updater learned to re-exec.
  out=$(PATH="$fakebin:$PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_UPDATE_REEXECED=1 \
    FM_STATE_OVERRIDE="$w/home/state" "$w/main/bin/fm-update.sh" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "predecessor updater did not install the new updater"
  assert_contains "$out" "firstmate: updated " "predecessor updater installed v3"

  rc=0
  PATH="$fakebin:$PATH" FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/main" \
    FM_STATE_OVERRIDE="$w/home/state" "$w/main/bin/fm-update.sh" >"$w/second-pass.out" 2>&1 || rc=$?
  out=$(cat "$w/second-pass.out")
  [ "$rc" -ne 0 ] || fail "installed updater accepted the predecessor watcher"
  assert_contains "$out" "watcher protocol restart could not be verified" \
    "installed updater enforces the required second pass"
  [ "$(cat "$w/home/state/.watch-protocol-required" 2>/dev/null || true)" = pending-reply-ticket-v3 ] \
    || fail "first protocol upgrade did not publish the v3 fence"
  wait "$watcher" 2>/dev/null || true
  wait "$arm" 2>/dev/null || true
  pass "T13 real predecessor requires the installed updater pass"
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
  local w out generation
  w=$(new_world t15)
  add_sm "$w" sm1
  sed -i 's/^window=.*/window=default:w1:p2/' "$w/home/state/sm1.meta"
  bump_origin "$w" instr

  out=$(run_update "$w")
  assert_contains "$out" "nudge-secondmates: default:w1:p2" "Herdr target is surfaced unchanged"
  generation=$(sed -n 's/^nudge-secondmate-generation: default:w1:p2|//p' <<< "$out")
  [ -n "$generation" ] || fail "Herdr target generation was not reported"
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
    assert_contains "$out" "firstmate: skipped: spawn or teardown is active" \
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
  assert_contains "$out" "firstmate: skipped: spawn or teardown is active" \
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
  assert_contains "$out" "firstmate: skipped: spawn or teardown is active" \
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
  assert_contains "$out" "firstmate: skipped: spawn or teardown is active" \
    "shell or env options hid exact lifecycle work from the process bridge"

  FM_HOME="$w/home" FM_STATE_OVERRIDE="$w/home/state" \
    bash -c 'exec -a masked bash --norc "$1"' _ "$script" &
  holder=$!
  UPDATE_TEST_PIDS="$UPDATE_TEST_PIDS $holder"
  out=$(run_update "$w")
  kill "$holder"
  wait "$holder" 2>/dev/null || true
  assert_contains "$out" "firstmate: skipped: spawn or teardown is active" \
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
      printf '\001\000\000\000/usr/bin/bash\000\000bash\000%s\000later argument\000' "$script"
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
    lock_held=0
    resolve_path() { cd "$1" && pwd -P; }
    validate_secondmate_home() {
      VALIDATED_HOME=$(cd "$2" && pwd -P)
      return 0
    }
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
    process_secondmate sm1 "$w/sm1" main:fm-sm1 origin no
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

echo "# all fm-update tests passed"
