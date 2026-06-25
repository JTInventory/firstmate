#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODEL="$ROOT/bin/fm-supervision-model.sh"
CLI="$ROOT/bin/fm-supervise.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

assert_contains() {
  local haystack=$1 needle=$2 label=$3
  printf '%s\n' "$haystack" | grep -Fq "$needle" || fail "$label"
}

new_home() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-supervise.XXXXXX") || exit 1
  mkdir -p "$tmp/state" "$tmp/data" "$tmp/projects"
  printf '%s\n' "$tmp"
}

write_fakebin() {
  local dir=$1
  mkdir -p "$dir"
  cat >"$dir/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *missing*) exit 1 ;;
  *) printf 'fm-window\n' ;;
esac
SH
  cat >"$dir/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${TREEHOUSE_FAIL:-0}" = 1 ]; then
  exit 1
fi
printf 'ok\n'
SH
  cat >"$dir/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" != api ] || [ "$2" != GET ]; then
  exit 2
fi
case "$3" in
  /repos/o/r/pulls/1)
    printf 'state: closed\nmerged: true\nmergeable_state: clean\nhead:\n  sha: sh-merged\n'
    ;;
  /repos/o/r/pulls/2)
    printf 'state: open\nmerged: false\nmergeable_state: clean\nhead:\n  sha: sh-success\n'
    ;;
  /repos/o/r/pulls/3)
    printf 'state: open\nmerged: false\nmergeable_state: dirty\nhead:\n  sha: sh-failure\n'
    ;;
  /repos/o/r/pulls/4)
    printf 'state: open\nmerged: false\nmergeable_state: unstable\nhead:\n  sha: sh-none\n'
    ;;
  /repos/o/r/pulls/5)
    printf 'not parseable\n'
    ;;
  /repos/kunchenguid/firstmate/pulls/68)
    printf 'state: open\nmerged: false\nmergeable_state: unstable\nhead:\n  sha: sh-none\n'
    ;;
  /repos/o/r/commits/sh-merged/status)
    printf 'state: success\ntotal_count: 1\n'
    ;;
  /repos/o/r/commits/sh-success/status)
    printf 'state: success\ntotal_count: 1\n'
    ;;
  /repos/o/r/commits/sh-failure/status)
    printf 'state: failure\ntotal_count: 1\n'
    ;;
  /repos/o/r/commits/sh-none/status|/repos/kunchenguid/firstmate/commits/sh-none/status)
    printf 'state: pending\ntotal_count: 0\n'
    ;;
  *)
    exit 1
    ;;
esac
SH
  chmod +x "$dir/tmux" "$dir/treehouse" "$dir/gh-axi"
}

run_json() {
  local home=$1 fakebin=$2
  PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" --json --no-default-reminders
}

write_meta() {
  local home=$1 id=$2 body=$3 status=${4:-}
  printf '%s\n' "$body" >"$home/state/$id.meta"
  if [ -n "$status" ]; then
    printf '%s\n' "$status" >"$home/state/$id.status"
  fi
}

make_git_project() {
  local home=$1 name=${2:-demo}
  mkdir -p "$home/projects/$name"
  git -C "$home/projects/$name" init -q
}

# shellcheck source=bin/fm-supervision-model.sh
. "$MODEL" || fail "model should be sourceable"
pass "model is sourceable"

out=$("$CLI" --schema) || fail "schema command failed"
assert_contains "$out" 'firstmate.supervision.v1' "schema missing id"
pass "schema prints v1 id"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
before=$(find "$home/state" "$home/data" -type f | sort)
out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" --json --no-default-reminders) || fail "empty json failed"
after=$(find "$home/state" "$home/data" -type f | sort)
[ "$before" = "$after" ] || fail "command wrote runtime files"
assert_contains "$out" '"read_only": true' "json not marked read-only"
assert_contains "$out" '"actions_total": 0' "empty home should have no actions"
pass "empty home stays read-only"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
write_meta "$home" live $'project=demo\nwindow=live' 'working: still running'
out=$(run_json "$home" "$fakebin") || fail "running json failed"
assert_contains "$out" '"classification": "running"' "live worker should be running"
assert_contains "$out" '"actions_total": 0' "running worker should not be high action"
pass "live working status is routine"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
write_meta "$home" merged $'project=demo\nwindow=live\npr=https://github.com/o/r/pull/1' 'done: PR https://github.com/o/r/pull/1 checks green'
out=$(run_json "$home" "$fakebin") || fail "merged json failed"
assert_contains "$out" 'merged_pr_live_worker' "merged PR live worker not classified"
assert_contains "$out" '"owner": "firstmate"' "merged PR owner should be firstmate"
pass "merged PR with live worker is high action"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
write_meta "$home" green $'project=demo\nwindow=live\npr=https://github.com/o/r/pull/2' 'done: PR https://github.com/o/r/pull/2 checks green'
out=$(run_json "$home" "$fakebin") || fail "green json failed"
assert_contains "$out" 'pr_open_ci_green' "green PR not classified"
assert_contains "$out" '"owner": "captain"' "green PR owner should be captain by default"
assert_contains "$out" '"mergeable_state": "clean"' "task PR mergeable state should be preserved"
pass "open PR with green CI is captain action"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
write_meta "$home" failci $'project=demo\nwindow=live\npr=https://github.com/o/r/pull/3' 'working: fixing'
out=$(run_json "$home" "$fakebin") || fail "failure json failed"
assert_contains "$out" 'pr_open_ci_failing' "failing PR not classified"
assert_contains "$out" '"owner": "worker"' "failing PR owner should be worker"
pass "open PR with failing CI is worker action"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
write_meta "$home" noci $'project=demo\nwindow=live\npr=https://github.com/o/r/pull/4' 'done: PR https://github.com/o/r/pull/4'
out=$(run_json "$home" "$fakebin") || fail "no-ci json failed"
assert_contains "$out" '"ci_state": "none"' "CI with total_count 0 should be none"
printf '%s\n' "$out" | grep -Fq 'pr_open_ci_green' && fail "ci none treated as green"
pass "open PR with no CI is not green"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
write_meta "$home" directnoci $'project=demo\nwindow=live\nmode=direct-PR\npr=https://github.com/o/r/pull/4' 'done: PR https://github.com/o/r/pull/4'
out=$(run_json "$home" "$fakebin") || fail "direct PR no-ci json failed"
assert_contains "$out" 'direct_pr_open_no_ci_ready' "direct-PR no-CI PR should be ready for review"
assert_contains "$out" '"owner": "captain"' "direct-PR no-CI PR owner should be captain by default"
assert_contains "$out" '"mergeable_state": "unstable"' "direct-PR no-CI mergeable state should be preserved"
pass "direct-PR open PR with no CI is captain action"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
write_meta "$home" done $'project=demo\nwindow=live\nmode=no-mistakes' 'done: implementation complete'
out=$(run_json "$home" "$fakebin") || fail "done no PR json failed"
assert_contains "$out" 'worker_done_no_pr' "done with no PR not classified"
pass "done status without PR is action"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
make_git_project "$home"
printf 'dirty\n' >"$home/projects/demo/dirty.txt"
out=$(run_json "$home" "$fakebin") || fail "dirty worktree json failed"
assert_contains "$out" 'dirty_worktree_no_active_task' "dirty worktree not classified"
pass "dirty worktree without meta is action"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
write_meta "$home" missing $'project=demo\nwindow=missing' 'working: vanished'
out=$(run_json "$home" "$fakebin") || fail "missing window json failed"
assert_contains "$out" 'missing_window_existing_meta' "missing tmux window not classified"
pass "missing tmux window is action"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
write_meta "$home" stale $'project=demo\nwindow=live\nworktree=/tmp/definitely-missing-firstmate-worktree' 'working: started'
out=$(run_json "$home" "$fakebin") || fail "stale json failed"
assert_contains "$out" 'stale_treehouse_state' "missing recorded worktree not classified stale"
pass "missing recorded worktree is stale"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
make_git_project "$home"
write_meta "$home" th $'project=demo\nwindow=live' 'working: started'
out=$(TREEHOUSE_FAIL=1 PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" --json --no-default-reminders) || fail "treehouse failure json failed"
assert_contains "$out" '"treehouse": { "ok": false' "treehouse failure should mark source false"
pass "treehouse failure is surfaced"

home=$(new_home)
write_meta "$home" ghmiss $'project=demo\nwindow=live\npr=https://github.com/o/r/pull/2' 'working: started'
out=$(PATH="/usr/bin:/bin" FM_HOME="$home" "$CLI" --json --no-default-reminders) || fail "missing gh-axi should not fail"
assert_contains "$out" '"github": { "ok": false' "missing gh-axi should mark GitHub false"
assert_contains "$out" '"state": "unknown"' "missing gh-axi should make PR unknown"
pass "missing gh-axi is unknown data"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
write_meta "$home" invalid $'project=demo\nwindow=live\npr=https://github.com/o/r/pull/5' 'working: started'
out=$(run_json "$home" "$fakebin") || fail "invalid GitHub output should not fail"
assert_contains "$out" '"github_state": "partial"' "invalid GitHub output should be partial"
assert_contains "$out" '"state": "unknown"' "invalid GitHub output should be unknown"
pass "invalid GitHub output does not crash"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" --json) || fail "external reminder json failed"
assert_contains "$out" 'external_open_ci_none' "default external PR 68 not classified"
pass "default external reminder is present"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
write_meta "$home" compat $'project=demo\nwindow=live\npr=https://github.com/o/r/pull/3\npr=https://github.com/o/r/pull/2' 'done: PR ready checks green'
out=$(run_json "$home" "$fakebin") || fail "compat json failed"
assert_contains "$out" '"kind": "ship"' "missing kind should default to ship"
assert_contains "$out" '"mode": "no-mistakes"' "missing mode should default to no-mistakes"
assert_contains "$out" '"yolo": "off"' "missing yolo should default to off"
assert_contains "$out" '"url": "https://github.com/o/r/pull/2"' "duplicate pr lines should use last value"
assert_contains "$out" 'pr_open_ci_green' "duplicate PR last value should drive classification"
pass "older meta defaults and duplicate PR are compatible"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" --text --no-default-reminders) || fail "text output failed"
assert_contains "$out" 'Firstmate supervision - read-only' "text should show read-only posture"
assert_contains "$out" 'No changes made.' "text should end with no changes made"
pass "text output makes read-only posture obvious"

home=$(new_home)
fakebin="$home/fakebin"
write_fakebin "$fakebin"
write_meta "$home" live $'project=demo\nwindow=live' 'working: still running'
out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" --text --include-ok --no-default-reminders) || fail "include-ok text failed"
assert_contains "$out" 'worker(s) are running normally' "include-ok should show routine running workers"
pass "include-ok shows low-priority watch items"

printf 'all fm-supervision-model tests passed\n'
