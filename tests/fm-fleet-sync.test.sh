#!/usr/bin/env bash
# Behavior tests for fm-fleet-sync.sh drift handling.
#
# fm-fleet-sync fast-forwards a clone that is cleanly on its default branch. This
# suite pins the two behavioral additions on top of that:
#   - the one safe drift self-heals: a clean, detached HEAD that holds no unique
#     commits (it is an ancestor of origin/<default>) and whose <default> is free
#     to check out is re-attached and then fast-forwarded ("recovered:").
#   - every other off-default state is left untouched and reported as a loud,
#     quantified "STUCK: ... N commits behind ... - needs attention" warning
#     instead of a quiet skip.
# The pre-existing fast-forward / already-current / local-only / no-origin paths
# must be unchanged, and bootstrap must relay the new outcomes as FLEET_SYNC lines.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-fleet-sync-tests)
HOME_N=0

# --- fixtures ---------------------------------------------------------------

# new_home: fresh isolated FM_HOME with an empty projects/ dir. Each test gets its
# own so the whole-fleet form never sees another test's clones.
new_home() {
  HOME_N=$((HOME_N + 1))
  local h="$TMP_ROOT/home-$HOME_N"
  mkdir -p "$h/projects"
  printf '%s\n' "$h"
}

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

# build_pair <home> <name>: create projects/<name>, a clone of a fresh bare origin
# with one commit on main, plus a side "work-<name>" repo wired to that origin for
# advancing it later. Portable branch naming (no init -b) for older git.
build_pair() {
  local home=$1 name=$2 work remote clone remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  commit_file "$work" file.txt v0 C0

  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"
  git -C "$work" push -q -u origin main

  git clone --quiet "file://$remote_abs" "$clone"
  printf '%s\n' "$clone"
}

# advance_origin <home> <name> <msg>: push one more commit to <name>'s origin via
# its work repo, so the clone (until it fetches) is one commit behind origin/main.
advance_origin() {
  local home=$1 name=$2 msg=$3 work
  work="$home/work-$name"
  commit_file "$work" file.txt "$msg" "$msg"
  git -C "$work" push -q origin main
}

head_sha() { git -C "$1" rev-parse HEAD; }

git_common_dir() {
  local project=$1 dir
  dir=$(git -C "$project" rev-parse --git-common-dir)
  case "$dir" in
    /*) ;;
    *) dir="$project/$dir" ;;
  esac
  (cd "$dir" && pwd -P)
}

# run_sync <home> [args...]: run fleet-sync against an isolated home, stdout only.
run_sync() {
  local home=$1
  shift
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-sync.sh" "$@" 2>/dev/null
}

make_lsof_none() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/lsof"
}

make_lsof_live() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/lsof" <<'SH'
#!/usr/bin/env bash
printf 'git 1234 fmtest 3r REG 0,0 0 0 %s\n' "${*: -1}"
exit 0
SH
  chmod +x "$fakebin/lsof"
}

make_transient_git() {
  local fakebin=$1 clone=$2 counter real_git
  mkdir -p "$fakebin"
  counter="$fakebin/fetch-count"
  real_git=$(command -v git)
  cat > "$fakebin/git" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -C ] && [ "\${3:-}" = fetch ]; then
  if [ ! -e "$counter" ]; then
    touch "$counter"
    rm -f -- "$clone/.git/packed-refs.lock"
    echo "fatal: Unable to create '$clone/.git/packed-refs.lock': File exists" >&2
    exit 1
  fi
fi
exec "$real_git" "\$@"
SH
  chmod +x "$fakebin/git"
}

make_racing_mv() {
  local fakebin=$1 real_mv
  mkdir -p "$fakebin"
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
real_mv='$real_mv'
if [ "\$#" -eq 2 ] && [[ "\$1" == */packed-refs.lock ]]; then
  source="\$1"
  replacement="\$source.race"
  printf '%s\n' replacement > "\$replacement"
  "\$real_mv" -f "\$replacement" "\$source"
fi
exec "\$real_mv" "\$@"
SH
  chmod +x "$fakebin/mv"
}

build_packed_lock_case() {
  local home=$1 name=$2 clone work
  clone=$(build_pair "$home" "$name")
  work="$home/work-$name"
  # Give the clone a remote-tracking feature ref that the next --prune must
  # delete. Pack all refs so that deletion takes the packed-refs rewrite path.
  git -C "$work" checkout -q -b feature
  commit_file "$work" feature.txt feature FEATURE
  git -C "$work" push -q origin feature
  git -C "$work" checkout -q main
  git -C "$clone" fetch -q origin feature:refs/remotes/origin/feature
  git -C "$clone" branch --track feature origin/feature >/dev/null
  git -C "$clone" pack-refs --all
  git -C "$work" push -q origin --delete feature
  advance_origin "$home" "$name" C1
  touch "$clone/.git/packed-refs.lock"
  printf '%s\n' "$clone"
}

build_linked_packed_lock_case() {
  local home=$1 name=$2 clone linked common_dir
  clone=$(build_packed_lock_case "$home" "$name")
  common_dir=$(git_common_dir "$clone")
  rm -f "$common_dir/packed-refs.lock"
  git -C "$clone" checkout --detach --quiet
  linked="$home/projects/$name-linked"
  git -C "$clone" worktree add --quiet "$linked" main
  touch "$common_dir/packed-refs.lock"
  printf '%s\n' "$linked"
}

test_orphaned_stale_packed_refs_lock_recovers() {
  local home clone fakebin out err
  home=$(new_home)
  clone=$(build_packed_lock_case "$home" lock-stale)
  fakebin="$home/fakebin"; make_lsof_none "$fakebin"
  err="$home/err"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$PATH" \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=1 \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    "$ROOT/bin/fm-fleet-sync.sh" "$clone" 2>"$err")
  assert_contains "$out" 'lock-stale: recovered: removed a stale packed-refs lock' \
    "stale packed-refs lock recovery was not relayed on stdout"
  assert_grep 'removed provably-stale packed-refs lock' "$err" \
    "stale packed-refs lock removal was not explained"
  assert_absent "$clone/.git/packed-refs.lock" "stale packed-refs lock was not removed"
  [ "$(head_sha "$clone")" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "clone did not sync to origin/main after stale lock recovery"
  pass "fleet-sync removes only a provably-stale packed-refs.lock and syncs"
}

test_live_packed_refs_lock_is_never_removed() {
  local home clone fakebin out err
  home=$(new_home)
  clone=$(build_packed_lock_case "$home" lock-live)
  fakebin="$home/fakebin"; make_lsof_live "$fakebin"
  err="$home/err"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$PATH" \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=1 \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    "$ROOT/bin/fm-fleet-sync.sh" "$clone" 2>"$err")
  assert_contains "$out" 'lock-live: skipped: fetch failed' \
    "live packed-refs lock did not keep the existing fetch-failure behavior"
  assert_grep 'not provably stale' "$err" "live packed-refs lock refusal was not explained"
  [ -e "$clone/.git/packed-refs.lock" ] || fail "live packed-refs lock was removed"
  pass "fleet-sync never removes a live packed-refs.lock"
}

test_transient_packed_refs_lock_self_clears() {
  local home clone fakebin out err
  home=$(new_home)
  clone=$(build_packed_lock_case "$home" lock-transient)
  fakebin="$home/fakebin"; make_lsof_none "$fakebin"; make_transient_git "$fakebin" "$clone"
  err="$home/err"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$PATH" \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    "$ROOT/bin/fm-fleet-sync.sh" "$clone" 2>"$err")
  assert_contains "$out" 'lock-transient: recovered: packed-refs lock cleared on its own' \
    "transient packed-refs lock recovery was not relayed"
  assert_not_contains "$(cat "$err")" 'removed provably-stale packed-refs lock' \
    "transient lock was force-removed instead of retried"
  pass "fleet-sync retries a transient packed-refs lock without force-removing it"
}

test_linked_worktree_packed_refs_lock_recovers() {
  local home linked fakebin out common_lock
  home=$(new_home)
  linked=$(build_linked_packed_lock_case "$home" lock-linked)
  fakebin="$home/fakebin"; make_lsof_none "$fakebin"
  common_lock="$(git_common_dir "$linked")/packed-refs.lock"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$PATH" \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=1 \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    "$ROOT/bin/fm-fleet-sync.sh" "$linked" 2>/dev/null)
  assert_contains "$out" 'lock-linked-linked: recovered: removed a stale packed-refs lock' \
    "linked worktree lock recovery was not relayed"
  assert_absent "$common_lock" "linked worktree stale packed-refs lock was not removed"
  [ "$(head_sha "$linked")" = "$(git -C "$linked" rev-parse origin/main)" ] \
    || fail "linked worktree did not sync after stale lock recovery"
  pass "fleet-sync recovers packed-refs.lock from a linked worktree's common git dir"
}

test_racing_packed_refs_lock_is_left_in_place() {
  local home clone fakebin out err lock
  home=$(new_home)
  clone=$(build_packed_lock_case "$home" lock-race)
  fakebin="$home/fakebin"; make_lsof_none "$fakebin"; make_racing_mv "$fakebin"
  lock="$clone/.git/packed-refs.lock"
  err="$home/err"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$PATH" \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=1 \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=0 \
    "$ROOT/bin/fm-fleet-sync.sh" "$clone" 2>"$err")
  assert_contains "$out" 'lock-race: skipped: fetch failed' \
    "racing packed-refs lock did not remain blocked"
  assert_grep 'atomically quarantine' "$err" \
    "racing packed-refs lock refusal was not explained"
  assert_contains "$(cat "$lock")" replacement \
    "replacement packed-refs lock was removed by stale recovery"
  pass "fleet-sync leaves a replacement packed-refs lock after the atomic race check"
}

test_non_signature_fetch_failure_is_not_retried() {
  local home clone fakebin out err
  home=$(new_home)
  clone=$(build_pair "$home" lock-other)
  git -C "$clone" remote set-url origin "file://$home/missing.git"
  fakebin="$home/fakebin"; make_lsof_none "$fakebin"
  err="$home/err"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$fakebin:$PATH" \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=2 \
    FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=0 \
    "$ROOT/bin/fm-fleet-sync.sh" "$clone" 2>"$err")
  assert_contains "$out" 'lock-other: skipped: fetch failed' \
    "non-lock fetch failure was not reported"
  assert_not_contains "$(cat "$err")" 'waiting' \
    "non-packed-refs fetch failure was incorrectly retried"
  pass "fleet-sync does not retry unrelated fetch failures"
}

# --- tests ------------------------------------------------------------------

test_detached_clean_ancestor_recovers() {
  local home clone out before after
  home=$(new_home)
  clone=$(build_pair "$home" alpha)
  advance_origin "$home" alpha C1
  before=$(head_sha "$clone")
  # Detach at the clone's main (C0), an ancestor of the now-advanced origin/main.
  git -C "$clone" checkout --detach --quiet

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "alpha: recovered: re-attached main, synced" "detached-clean-ancestor reports recovered"
  assert_not_contains "$out" "STUCK" "recovered case is not flagged STUCK"
  [ "$(git -C "$clone" symbolic-ref --short HEAD 2>/dev/null)" = "main" ] \
    || fail "expected re-attach to main, HEAD still detached"
  after=$(head_sha "$clone")
  [ "$after" != "$before" ] || fail "expected fast-forward after re-attach, HEAD unchanged"
  [ "$after" = "$(git -C "$clone" rev-parse origin/main)" ] \
    || fail "expected HEAD at origin/main after recovery"
  pass "detached clean ancestor is re-attached and fast-forwarded (recovered)"
}

test_detached_unique_commit_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" beta)
  git -C "$clone" checkout --detach --quiet
  commit_file "$clone" extra.txt unique "local unique work"
  before=$(head_sha "$clone")
  advance_origin "$home" beta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "beta: STUCK:" "detached-with-unique-commit reports STUCK"
  assert_contains "$out" "unique commits" "STUCK names the unique-commit state"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  assert_not_contains "$out" "recovered" "unique-commit case is never recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "expected unique-commit detached HEAD left untouched"
  pass "detached HEAD with unique commits is reported STUCK and left untouched"
}

test_detached_clean_ancestor_with_diverged_local_default_is_stuck_untouched() {
  local home clone out before local_main
  home=$(new_home)
  clone=$(build_pair "$home" beta-local-default)
  commit_file "$clone" local.txt local "local divergent main commit"
  local_main=$(git -C "$clone" rev-parse main)
  git -C "$clone" checkout --detach --quiet HEAD^
  before=$(head_sha "$clone")
  advance_origin "$home" beta-local-default C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "beta-local-default: STUCK:" "diverged local default reports STUCK"
  assert_contains "$out" "local main diverged from origin/main" "STUCK names the unsafe local default"
  assert_not_contains "$out" "recovered" "diverged local default is never recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "detached HEAD was moved"
  ! git -C "$clone" symbolic-ref -q HEAD >/dev/null || fail "clone re-attached to local default"
  [ "$(git -C "$clone" rev-parse main)" = "$local_main" ] || fail "local default branch was moved"
  pass "detached clean ancestor with diverged local default is reported STUCK and left untouched"
}

test_dirty_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" gamma)
  advance_origin "$home" gamma C1
  before=$(head_sha "$clone")
  printf 'uncommitted edit\n' >> "$clone/file.txt"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "gamma: STUCK:" "dirty clone reports STUCK"
  assert_contains "$out" "uncommitted changes" "STUCK names the dirty state"
  assert_contains "$out" "1 commits behind origin/main" "STUCK quantifies how far behind"
  [ "$(head_sha "$clone")" = "$before" ] || fail "dirty clone HEAD was moved"
  grep -q "uncommitted edit" "$clone/file.txt" || fail "dirty working-tree change was discarded"
  pass "dirty working tree is reported STUCK and left untouched"
}

test_non_default_branch_is_stuck_untouched() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" delta)
  git -C "$clone" checkout -q -b feature
  advance_origin "$home" delta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "delta: STUCK: on branch feature" "non-default branch reports STUCK with branch name"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  assert_not_contains "$out" "recovered" "named branch is never auto-changed"
  [ "$(git -C "$clone" symbolic-ref --short HEAD)" = "feature" ] || fail "named branch checkout was changed"
  pass "non-default named branch is reported STUCK and left untouched"
}

test_diverged_is_stuck_untouched() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" epsilon)
  # Local main gains its own commit; origin advances down a different line.
  commit_file "$clone" local.txt local "local divergent commit"
  before=$(head_sha "$clone")
  advance_origin "$home" epsilon C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "epsilon: STUCK:" "diverged clone reports STUCK"
  assert_contains "$out" "diverged main" "STUCK names the diverged state"
  assert_contains "$out" "commits behind origin/main - needs attention" "STUCK is quantified"
  [ "$(head_sha "$clone")" = "$before" ] || fail "diverged clone was moved"
  pass "diverged default branch is reported STUCK and left untouched"
}

test_on_default_clean_behind_fast_forwards() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" zeta)
  advance_origin "$home" zeta C1

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "zeta: synced" "on-default clean behind fast-forwards as before"
  assert_not_contains "$out" "recovered" "ordinary fast-forward is not labelled recovered"
  assert_not_contains "$out" "STUCK" "ordinary fast-forward is not flagged STUCK"
  [ "$(head_sha "$clone")" = "$(git -C "$clone" rev-parse origin/main)" ] || fail "clone was not fast-forwarded"
  pass "on-default clean behind clone still fast-forwards"
}

test_already_current_unchanged() {
  local home clone out before
  home=$(new_home)
  clone=$(build_pair "$home" eta)
  before=$(head_sha "$clone")

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "eta: already current" "already-current clone reports unchanged"
  assert_not_contains "$out" "STUCK" "already-current is not flagged STUCK"
  assert_not_contains "$out" "recovered" "already-current is not labelled recovered"
  [ "$(head_sha "$clone")" = "$before" ] || fail "already-current clone was moved"
  pass "already-current clone is reported unchanged"
}

test_no_origin_skipped() {
  local home clone out
  home=$(new_home)
  clone="$home/projects/theta"
  git init -q "$clone"
  git -C "$clone" symbolic-ref HEAD refs/heads/main
  commit_file "$clone" file.txt v0 C0

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "theta: skipped: no origin remote" "no-origin clone is skipped as before"
  assert_not_contains "$out" "STUCK" "no-origin skip is not escalated to STUCK"
  pass "no-origin clone is skipped (benign), not flagged STUCK"
}

test_local_only_skipped() {
  local home clone out
  home=$(new_home)
  clone=$(build_pair "$home" iota)
  advance_origin "$home" iota C1
  mkdir -p "$home/data"
  printf -- '- iota [local-only] - test project (added 2026-06-27)\n' > "$home/data/projects.md"

  out=$(run_sync "$home" "$clone")

  assert_contains "$out" "iota: skipped: local-only project" "local-only clone is skipped as before"
  assert_not_contains "$out" "STUCK" "local-only skip is not escalated to STUCK"
  pass "local-only clone is skipped (benign), not flagged STUCK"
}

test_single_project_by_bare_name_resolves() {
  local home out
  home=$(new_home)
  build_pair "$home" kappa >/dev/null
  advance_origin "$home" kappa C1

  out=$(run_sync "$home" "kappa")

  assert_contains "$out" "kappa: synced" "bare project name resolves against the home's projects dir"
  pass "single-project form accepts a bare project name"
}

test_single_project_by_bare_name_ignores_cwd_shadow() {
  local home cwd out
  home=$(new_home)
  build_pair "$home" mu >/dev/null
  advance_origin "$home" mu C1
  cwd="$home/shadow"
  mkdir -p "$cwd/mu"

  out=$(cd "$cwd" && run_sync "$home" "mu")

  assert_contains "$out" "mu: synced" "bare project name prefers the home's projects dir"
  assert_not_contains "$out" "skipped: not a git repo" "bare project name ignores a cwd shadow directory"
  pass "single-project bare name resolution is not cwd-sensitive"
}

test_single_project_by_projects_relative_name_resolves() {
  local home out
  home=$(new_home)
  build_pair "$home" lambda >/dev/null
  advance_origin "$home" lambda C1

  out=$(run_sync "$home" "projects/lambda")

  assert_contains "$out" "lambda: synced" "projects/<name> form resolves against the home's projects dir"
  pass "single-project form accepts a projects/<name> relative name"
}

test_single_project_by_projects_relative_name_ignores_cwd_shadow() {
  local home cwd out
  home=$(new_home)
  build_pair "$home" nu >/dev/null
  advance_origin "$home" nu C1
  cwd="$home/shadow"
  mkdir -p "$cwd/projects/nu"

  out=$(cd "$cwd" && run_sync "$home" "projects/nu")

  assert_contains "$out" "nu: synced" "projects/<name> form prefers the home's projects dir"
  assert_not_contains "$out" "skipped: not a git repo" "projects/<name> form ignores a cwd shadow directory"
  pass "single-project projects/<name> resolution is not cwd-sensitive"
}

test_single_project_unresolvable_name_still_skips() {
  local home out
  home=$(new_home)

  out=$(run_sync "$home" "does-not-exist")

  assert_contains "$out" "skipped: not a directory" "an unresolvable name still hits the existing not-a-directory skip"
  pass "single-project form leaves a genuinely bad name unresolved"
}

test_whole_fleet_form() {
  local home behind current out
  home=$(new_home)
  behind=$(build_pair "$home" fleet-behind)
  advance_origin "$home" fleet-behind C1
  current=$(build_pair "$home" fleet-current)

  # Whole-fleet form: no project-dir argument.
  out=$(run_sync "$home")

  assert_contains "$out" "fleet-behind: synced" "whole-fleet form syncs a behind clone"
  assert_contains "$out" "fleet-current: already current" "whole-fleet form reports a current clone"
  : "$behind $current"
  pass "whole-fleet form processes every clone under projects/"
}

test_bootstrap_relays_recovered_and_stuck() {
  local home stuck rec out
  home=$(new_home)
  # A clone we will leave STUCK (dirty), and one that self-heals (detached-clean-ancestor).
  stuck=$(build_pair "$home" stuck-clone)
  advance_origin "$home" stuck-clone C1
  printf 'dirty\n' >> "$stuck/file.txt"
  rec=$(build_pair "$home" rec-clone)
  advance_origin "$home" rec-clone C1
  git -C "$rec" checkout --detach --quiet

  # Full bootstrap: no state/ dir -> secondmate sync no-ops; no .env -> X mode off.
  # We only assert the fleet-sync relay lines; other detect lines are irrelevant.
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_contains "$out" "FLEET_SYNC: stuck-clone: STUCK:" "bootstrap relays the STUCK outcome"
  assert_contains "$out" "FLEET_SYNC: rec-clone: recovered:" "bootstrap relays the recovered outcome"
  pass "bootstrap relays recovered: and STUCK: fleet-sync outcomes"
}

test_detached_clean_ancestor_recovers
test_detached_unique_commit_is_stuck_untouched
test_detached_clean_ancestor_with_diverged_local_default_is_stuck_untouched
test_dirty_is_stuck_untouched
test_non_default_branch_is_stuck_untouched
test_diverged_is_stuck_untouched
test_on_default_clean_behind_fast_forwards
test_already_current_unchanged
test_no_origin_skipped
test_local_only_skipped
test_single_project_by_bare_name_resolves
test_single_project_by_bare_name_ignores_cwd_shadow
test_single_project_by_projects_relative_name_resolves
test_single_project_by_projects_relative_name_ignores_cwd_shadow
test_single_project_unresolvable_name_still_skips
test_whole_fleet_form
test_bootstrap_relays_recovered_and_stuck
test_orphaned_stale_packed_refs_lock_recovers
test_live_packed_refs_lock_is_never_removed
test_transient_packed_refs_lock_self_clears
test_linked_worktree_packed_refs_lock_recovers
test_racing_packed_refs_lock_is_left_in_place
test_non_signature_fetch_failure_is_not_retried
