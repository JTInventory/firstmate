#!/usr/bin/env bash
# Callable turn-end guard for main and secondmate primary homes.
#
# The guard must block only an in-flight primary when no live watcher is proved.
# Linked child crew/scout worktrees are exempt by git-dir/common-dir topology;
# a marked secondmate home is the one linked-home exception and is guarded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-turnend-guard.sh"
TMP_ROOT=$(fm_test_tmproot fm-turnend-guard)

make_primary_repo() {
  local dir=$1
  fm_git_init_commit "$dir"
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  : > "$dir/bin/fm-turnend-guard.sh"
  git -C "$dir" add AGENTS.md bin/fm-turnend-guard.sh
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'fixture files'
  printf '%s\n' "$dir"
}

make_secondmate_linked_home() {
  local base=$1 home=$2
  make_primary_repo "$base" >/dev/null
  git -C "$base" worktree add --quiet -b fm/turnend-secondmate-home "$home"
  printf 'sm-guard-1\n' > "$home/.fm-secondmate-home"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

run_guard() {
  local home=$1 payload=$2 status=0
  printf '%s' "$payload" | \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$GUARD" 2>&1 || status=$?
  return "$status"
}

test_main_primary_blocks_with_child_in_flight() {
  local home out status
  home=$(make_primary_repo "$TMP_ROOT/main-primary")
  : > "$home/state/child.meta"
  out=$(run_guard "$home" '{"stop_hook_active":false}'); status=$?
  expect_code 2 "$status" "main primary must block a blind turn while a child is in flight"
  assert_contains "$out" "TURN WOULD END BLIND" "main-primary guard lacked its alarm banner"
  assert_contains "$out" "bin/fm-watch-arm.sh" "main-primary guard lacked re-arm guidance"
  pass "fm-turnend-guard: main primary blocks a blind turn with in-flight work"
}

test_secondmate_primary_blocks_with_child_in_flight() {
  local home out status gd gcd
  home=$(make_secondmate_linked_home "$TMP_ROOT/secondmate-base" "$TMP_ROOT/secondmate-home")
  gd=$(git -C "$home" rev-parse --git-dir)
  gcd=$(git -C "$home" rev-parse --git-common-dir)
  [ "$gd" != "$gcd" ] || fail "secondmate home fixture must be a linked worktree"
  : > "$home/state/child.meta"
  out=$(run_guard "$home" '{"stop_hook_active":false}'); status=$?
  expect_code 2 "$status" "secondmate primary must block a blind turn with a child in flight"
  assert_contains "$out" "TURN WOULD END BLIND" "secondmate guard lacked its alarm banner"
  pass "fm-turnend-guard: marked linked secondmate home is guarded as its own primary"
}

test_secondmate_child_worktree_is_exempt() {
  local home child out status gd gcd
  home=$(make_secondmate_linked_home "$TMP_ROOT/child-base" "$TMP_ROOT/child-home")
  child="$TMP_ROOT/child-worktree"
  git -C "$home" worktree add --quiet -b fm/turnend-child "$child"
  gd=$(git -C "$child" rev-parse --git-dir)
  gcd=$(git -C "$child" rev-parse --git-common-dir)
  [ "$gd" != "$gcd" ] || fail "child fixture must be a linked worktree"
  [ ! -e "$child/.fm-secondmate-home" ] || fail "child worktree inherited secondmate marker"
  mkdir -p "$child/state"
  : > "$child/state/child.meta"
  out=$(run_guard "$child" '{"stop_hook_active":false}'); status=$?
  expect_code 0 "$status" "linked child crew worktree must be exempt"
  [ -z "$out" ] || fail "linked child worktree was not silent: $out"
  pass "fm-turnend-guard: linked child worktree is exempt by git-dir/common-dir topology"
}

test_idle_secondmate_is_silent() {
  local home out status
  home=$(make_secondmate_linked_home "$TMP_ROOT/idle-base" "$TMP_ROOT/idle-home")
  out=$(run_guard "$home" '{"stop_hook_active":false}'); status=$?
  expect_code 0 "$status" "idle secondmate must not false-positive"
  [ -z "$out" ] || fail "idle secondmate produced guard output: $out"
  pass "fm-turnend-guard: idle secondmate with empty queue is silent"
}

test_stop_hook_retry_is_allowed() {
  local home out status
  home=$(make_secondmate_linked_home "$TMP_ROOT/retry-base" "$TMP_ROOT/retry-home")
  : > "$home/state/child.meta"
  out=$(run_guard "$home" '{"stop_hook_active":true}'); status=$?
  expect_code 0 "$status" "a retry marked stop_hook_active must not block twice"
  [ -z "$out" ] || fail "loop-guarded retry produced output: $out"
  pass "fm-turnend-guard: stop_hook_active retry is allowed"
}

test_main_primary_blocks_with_child_in_flight
test_secondmate_primary_blocks_with_child_in_flight
test_secondmate_child_worktree_is_exempt
test_idle_secondmate_is_silent
test_stop_hook_retry_is_allowed
