#!/usr/bin/env bash
# Behavior tests for task metadata/worktree branch identity checks.
#
# A reused Treehouse pane can keep state/<old-id>.meta while the worktree has
# moved on to fm/<new-id>. Helpers that record PRs, review diffs, or tear down
# work must refuse that stale identity instead of acting on the old task.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
REVIEW_DIFF="$ROOT/bin/fm-review-diff.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-identity)

make_case() {
  local name=$1 current_id=$2 meta_id=$3 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"

  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"--json headRefName"*) printf '%s\n' "fm/$current_id"; exit 0 ;;
  *) printf '%s\n' "OPEN"; exit 0 ;;
esac
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh" "$fakebin/treehouse" "$fakebin/tmux"

  git init -q --bare "$case_dir/origin.git"
  git -C "$case_dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$case_dir/origin.git" "$case_dir/_seed" 2>/dev/null
  git -C "$case_dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$case_dir/_seed" push -q origin main
  rm -rf "$case_dir/_seed"

  git clone -q "$case_dir/origin.git" "$case_dir/project"
  git -C "$case_dir/project" remote set-head origin main 2>/dev/null || true
  git -C "$case_dir/project" worktree add -q -b "fm/$current_id" "$case_dir/wt" main
  git -C "$case_dir/wt" push -q origin "fm/$current_id"
  git -C "$case_dir/project" fetch -q origin

  touch "$case_dir/state/.last-watcher-beat"
  fm_write_meta "$case_dir/state/$meta_id.meta" \
    "window=fm-$meta_id" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=direct-PR"

  printf '%s\n' "$case_dir"
}

run_pr_check() {
  local case_dir=$1 id=$2 url=$3
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" "$id" "$url" 2>&1
}

run_review_diff() {
  local case_dir=$1 id=$2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$REVIEW_DIFF" "$id" --stat 2>&1
}

run_teardown() {
  local case_dir=$1 id=$2
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" 2>&1
}

test_pr_check_refuses_stale_task_meta() {
  local case_dir rc out url
  case_dir=$(make_case pr-check new-task old-task)
  url=https://github.com/example/repo/pull/12

  set +e
  out=$(run_pr_check "$case_dir" old-task "$url")
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check should refuse stale task metadata"
  assert_contains "$out" "task identity mismatch" "pr-check did not explain the stale task identity"
  assert_no_grep "pr=$url" "$case_dir/state/old-task.meta" "pr-check wrote PR URL to stale meta"
  assert_absent "$case_dir/state/old-task.check.sh" "pr-check armed a merge poll for stale meta"
  pass "fm-pr-check refuses stale task metadata before recording a PR"
}

test_pr_check_records_matching_task_meta() {
  local case_dir out url
  case_dir=$(make_case pr-check-match same-task same-task)
  url=https://github.com/example/repo/pull/13

  out=$(run_pr_check "$case_dir" same-task "$url") || fail "pr-check should accept matching task metadata: $out"

  assert_contains "$out" "armed: state/same-task.check.sh polls $url" "pr-check did not arm the merge poll"
  assert_grep "pr=$url" "$case_dir/state/same-task.meta" "pr-check did not record PR URL for matching meta"
  assert_present "$case_dir/state/same-task.check.sh" "pr-check did not write check script for matching meta"
  pass "fm-pr-check records a PR when task id, branch, and PR head match"
}

test_review_diff_refuses_stale_task_meta() {
  local case_dir rc out
  case_dir=$(make_case review-diff new-task old-task)

  set +e
  out=$(run_review_diff "$case_dir" old-task)
  rc=$?
  set -e

  expect_code 1 "$rc" "review-diff should refuse stale task metadata"
  assert_contains "$out" "task identity mismatch" "review-diff did not explain the stale task identity"
  pass "fm-review-diff refuses stale task metadata instead of reviewing the wrong branch"
}

test_teardown_refuses_stale_task_meta() {
  local case_dir rc out
  case_dir=$(make_case teardown new-task old-task)

  set +e
  out=$(run_teardown "$case_dir" old-task)
  rc=$?
  set -e

  expect_code 1 "$rc" "teardown should refuse stale task metadata"
  assert_contains "$out" "task identity mismatch" "teardown did not explain the stale task identity"
  assert_present "$case_dir/state/old-task.meta" "teardown removed stale meta after refusing"
  pass "fm-teardown refuses stale task metadata before returning a reused worktree"
}

test_pr_check_refuses_stale_task_meta
test_pr_check_records_matching_task_meta
test_review_diff_refuses_stale_task_meta
test_teardown_refuses_stale_task_meta
