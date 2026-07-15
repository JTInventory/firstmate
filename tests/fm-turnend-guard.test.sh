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
  printf '/.fm-secondmate-home\n' > "$dir/.gitignore"
  : > "$dir/bin/fm-turnend-guard.sh"
  git -C "$dir" add .gitignore AGENTS.md bin/fm-turnend-guard.sh
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

make_path_without_jq() {
  local dir=$1 tool
  mkdir -p "$dir"
  for tool in bash cat date dirname git mkdir ps stat uname; do
    ln -s "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s\n' "$dir"
}

run_guard() {
  local home=$1 payload=$2 status=0
  printf '%s' "$payload" | \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$GUARD" 2>&1 || status=$?
  return "$status"
}

run_guard_with_path() {
  local path=$1 home=$2 payload=$3 status=0
  printf '%s' "$payload" | \
    PATH="$path" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$GUARD" 2>&1 || status=$?
  return "$status"
}

run_guard_with_path_nul() {
  local path=$1 home=$2 payload=$3 status=0
  printf '%s\0' "$payload" | \
    PATH="$path" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
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
  git -C "$home" check-ignore -q .fm-secondmate-home || fail "secondmate marker is not ignored"
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
  git -C "$child" check-ignore -q .fm-secondmate-home || fail "child worktree did not inherit marker ignore rule"
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

test_malformed_stop_payload_blocks_primary() {
  local home out status
  home=$(make_primary_repo "$TMP_ROOT/malformed-primary")
  : > "$home/state/child.meta"
  out=$(run_guard "$home" '{"stop_hook_active":'); status=$?
  expect_code 2 "$status" "malformed stop payload must not bypass an in-flight primary guard"
  assert_contains "$out" "TURN WOULD END BLIND" "malformed payload guard lacked its alarm banner"
  if command -v jq >/dev/null 2>&1; then
    out=$(run_guard "$home" '{}{"stop_hook_active":true}'); status=$?
    expect_code 2 "$status" "jq path must reject multi-document stop payload"
    assert_contains "$out" "TURN WOULD END BLIND" "multi-document payload guard lacked its alarm banner"
    out=$(run_guard "$home" '{"stop_hook_active":false,"stop_hook_active":true}'); status=$?
    expect_code 2 "$status" "jq path must reject duplicate stop_hook_active keys"
    assert_contains "$out" "TURN WOULD END BLIND" "duplicate-key payload guard lacked its alarm banner"
  fi
  pass "fm-turnend-guard: malformed stop payload fails closed for an unproved primary"
}

test_missing_jq_blocks_primary_with_in_flight() {
  local home path out status
  home=$(make_primary_repo "$TMP_ROOT/missing-jq-primary")
  path=$(make_path_without_jq "$TMP_ROOT/path-without-jq")
  : > "$home/state/child.meta"
  out=$(run_guard_with_path "$path" "$home" '{"stop_hook_active":false}'); status=$?
  expect_code 2 "$status" "missing jq must not bypass an in-flight primary guard"
  assert_contains "$out" "TURN WOULD END BLIND" "missing jq guard lacked its alarm banner"
  pass "fm-turnend-guard: missing jq fails closed for an unproved primary"
}

test_missing_jq_preserves_stop_hook_retry() {
  local home path out status
  home=$(make_primary_repo "$TMP_ROOT/missing-jq-retry")
  path=$(make_path_without_jq "$TMP_ROOT/path-without-jq-retry")
  : > "$home/state/child.meta"
  out=$(run_guard_with_path "$path" "$home" '{"note":"café","stop_hook_active":true}'); status=$?
  expect_code 0 "$status" "missing jq fallback must preserve valid UTF-8 string values"
  [ -z "$out" ] || fail "missing jq valid UTF-8 payload produced guard output: $out"
  out=$(run_guard_with_path "$path" "$home" '{"session_id":"a\u0062c","stop_hook_active":true}'); status=$?
  expect_code 0 "$status" "missing jq fallback must preserve valid escaped string values"
  [ -z "$out" ] || fail "missing jq escaped-value payload produced guard output: $out"
  out=$(run_guard_with_path "$path" "$home" '{ "session_id": "abc", "details": { "attempt": 1, "retriable": true }, "stop_hook_active": true, "hook_event_name": "Stop" }'); status=$?
  expect_code 0 "$status" "missing jq fallback must preserve stop_hook_active retry exemption"
  [ -z "$out" ] || fail "missing jq retry produced guard output: $out"
  pass "fm-turnend-guard: missing jq fallback preserves retry with additional fields"
}

test_missing_jq_rejects_invalid_stop_payload() {
  local home path out status
  home=$(make_primary_repo "$TMP_ROOT/missing-jq-invalid")
  path=$(make_path_without_jq "$TMP_ROOT/path-without-jq-invalid")
  : > "$home/state/child.meta"
  out=$(run_guard_with_path "$path" "$home" '{"session_id":"abc","stop_hook_active":true'); status=$?
  expect_code 2 "$status" "missing jq fallback must reject malformed stop payload"
  assert_contains "$out" "TURN WOULD END BLIND" "invalid fallback payload guard lacked its alarm banner"
  out=$(run_guard_with_path "$path" "$home" $'{"note":"\xff","stop_hook_active":true}'); status=$?
  expect_code 2 "$status" "missing jq fallback must reject invalid UTF-8"
  assert_contains "$out" "TURN WOULD END BLIND" "invalid UTF-8 fallback payload guard lacked its alarm banner"
  out=$(run_guard_with_path "$path" "$home" '[{"stop_hook_active":true}]'); status=$?
  expect_code 2 "$status" "missing jq fallback must reject non-object stop payload"
  assert_contains "$out" "TURN WOULD END BLIND" "non-object fallback payload guard lacked its alarm banner"
  out=$(run_guard_with_path_nul "$path" "$home" '{"stop_hook_active":true}'); status=$?
  expect_code 2 "$status" "missing jq fallback must reject NUL-terminated stop payload"
  assert_contains "$out" "TURN WOULD END BLIND" "NUL-terminated fallback payload guard lacked its alarm banner"
  out=$(run_guard_with_path "$path" "$home" '{"stop_hook_act\u0069ve":false,"stop_hook_active":true}'); status=$?
  expect_code 2 "$status" "missing jq fallback must reject escaped stop_hook_active keys"
  assert_contains "$out" "TURN WOULD END BLIND" "escaped duplicate-key fallback guard lacked its alarm banner"
  out=$(run_guard_with_path "$path" "$home" $'{"stop_hook_active":true\v}'); status=$?
  expect_code 2 "$status" "missing jq fallback must reject vertical-tab whitespace"
  assert_contains "$out" "TURN WOULD END BLIND" "vertical-tab fallback payload guard lacked its alarm banner"
  out=$(run_guard_with_path "$path" "$home" $'{"stop_hook_active":true\f}'); status=$?
  expect_code 2 "$status" "missing jq fallback must reject form-feed whitespace"
  assert_contains "$out" "TURN WOULD END BLIND" "form-feed fallback payload guard lacked its alarm banner"
  pass "fm-turnend-guard: missing jq fallback rejects invalid stop payloads"
}

test_main_primary_blocks_with_child_in_flight
test_secondmate_primary_blocks_with_child_in_flight
test_secondmate_child_worktree_is_exempt
test_idle_secondmate_is_silent
test_stop_hook_retry_is_allowed
test_malformed_stop_payload_blocks_primary
test_missing_jq_blocks_primary_with_in_flight
test_missing_jq_preserves_stop_hook_retry
test_missing_jq_rejects_invalid_stop_payload
