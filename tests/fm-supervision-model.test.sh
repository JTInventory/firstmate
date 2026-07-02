#!/usr/bin/env bash
# Tests for the read-only fm-supervise model and CLI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MODEL="$ROOT/bin/fm-supervision-model.sh"
CLI="$ROOT/bin/fm-supervise.sh"
TMP_ROOT=$(fm_test_tmproot fm-supervision-model-tests)

assert_json_valid() {
  local json=$1 label=$2
  printf '%s\n' "$json" | python3 -m json.tool >/dev/null || fail "$label is not valid JSON"
}

assert_task_classification() {
  local json=$1 id=$2 expected=$3 label=$4
  FM_TEST_JSON=$json python3 - "$id" "$expected" <<'PY' || fail "$label"
import json
import os
import sys

task_id = sys.argv[1]
expected = sys.argv[2]
data = json.loads(os.environ["FM_TEST_JSON"])
for task in data["tasks"]:
    if task["id"] == task_id:
        actual = task["classification"]
        if actual != expected:
            raise SystemExit(f"{task_id}: expected {expected}, got {actual}")
        raise SystemExit(0)
raise SystemExit(f"{task_id}: task not found")
PY
}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/data" "$home/projects"
  printf '# backlog\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

write_fakebin() {
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *missing*) exit 1 ;;
  *list-panes*) exit 0 ;;
  *) printf 'fm-window\n' ;;
esac
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
[ "${TREEHOUSE_FAIL:-0}" = 1 ] && exit 1
printf 'ok\n'
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
[ "$1" = api ] && [ "$2" = GET ] || exit 2
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
  /repos/o/r/pulls/4|/repos/JTInventory/firstmate/pulls/76)
    printf 'state: open\nmerged: false\nmergeable_state: unstable\nhead:\n  sha: sh-none\n'
    ;;
  /repos/o/r/pulls/5)
    printf 'not parseable\n'
    ;;
  /repos/o/r/pulls/6)
    printf 'state: open\nmerged: false\nmergeable_state: clean\nhead:\n  sha: sh-actions-failure\n'
    ;;
  /repos/o/r/pulls/7)
    printf 'state: open\nmerged: false\nmergeable_state: clean\nhead:\n  sha: sh-actions-stale\n'
    ;;
  /repos/o/r/pulls/8)
    printf 'state: closed\nmerged: false\nmergeable_state: clean\nhead:\n  sha: sh-closed\n'
    ;;
  /repos/o/r/commits/sh-merged/status|/repos/o/r/commits/sh-success/status)
    printf 'state: success\ntotal_count: 1\n'
    ;;
  /repos/o/r/commits/sh-failure/status)
    printf 'state: failure\ntotal_count: 1\n'
    ;;
  /repos/o/r/commits/sh-actions-failure/status)
    printf 'state: pending\ntotal_count: 0\n'
    ;;
  /repos/o/r/commits/sh-actions-failure/check-runs)
    printf 'total_count: 1\ncheck_runs:\n- status: completed\n  conclusion: failure\n'
    ;;
  /repos/o/r/commits/sh-actions-stale/check-runs)
    printf 'total_count: 1\ncheck_runs:\n- status: completed\n  conclusion: stale\n'
    ;;
  */check-runs)
    printf 'total_count: 0\ncheck_runs: []\n'
    ;;
  /repos/o/r/commits/sh-none/status|/repos/o/r/commits/sh-actions-stale/status|/repos/o/r/commits/sh-closed/status|/repos/JTInventory/firstmate/commits/sh-none/status)
    printf 'state: pending\ntotal_count: 0\n'
    ;;
  *)
    exit 1
    ;;
esac
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/gh-axi"
}

write_meta() {
  local home=$1 id=$2 status=${3:-}
  shift 3 || true
  fm_write_meta "$home/state/$id.meta" "$@"
  [ -n "$status" ] && printf '%s\n' "$status" > "$home/state/$id.status"
}

run_json() {
  local home=$1 fakebin=$2
  PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" --json --no-default-reminders
}

test_model_is_sourceable_and_schema_is_json() {
  # shellcheck source=bin/fm-supervision-model.sh
  . "$MODEL" || fail "model should be sourceable"
  local out
  out=$("$CLI" --schema) || fail "schema command failed"
  # shellcheck disable=SC2016 # Dollar sign is literal JSON schema text.
  assert_contains "$out" '"$id": "firstmate.supervision.v1"' "schema id missing"
  assert_json_valid "$out" "schema"
  pass "model is sourceable and schema is valid JSON"
}

test_empty_home_is_read_only_valid_json() {
  local home fakebin before after out
  home=$(make_home empty)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  before=$(find "$home/state" "$home/data" -type f -print0 | sort -z | xargs -0 sha256sum)
  out=$(run_json "$home" "$fakebin") || fail "empty home json failed"
  after=$(find "$home/state" "$home/data" -type f -print0 | sort -z | xargs -0 sha256sum)
  [ "$before" = "$after" ] || fail "supervise wrote state or data files"
  assert_json_valid "$out" "empty home output"
  assert_contains "$out" '"read_only": true' "json should mark read-only"
  assert_contains "$out" '"actions_total": 0' "empty home should have no actions"
  pass "empty home produces valid read-only JSON"
}

test_task_classifications_and_route_metadata() {
  local home fakebin out
  home=$(make_home tasks)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  write_meta "$home" live 'working: still running' \
    "project=demo" "window=live" "kind=ship" "mode=direct-PR" "yolo=off" \
    "harness=codex" "route_profile=critical" "route_harness=codex" "route_model=gpt-5.5" "route_effort=medium" \
    "branch=fm/live"
  write_meta "$home" merged 'done: PR https://github.com/o/r/pull/1 checks green' \
    "project=demo" "window=live" "pr=https://github.com/o/r/pull/1"
  write_meta "$home" green 'done: PR https://github.com/o/r/pull/2 checks green' \
    "project=demo" "window=live" "pr=https://github.com/o/r/pull/2"
  write_meta "$home" failci 'working: fixing' \
    "project=demo" "window=live" "pr=https://github.com/o/r/pull/3"
  write_meta "$home" directnoci 'done: PR https://github.com/o/r/pull/4' \
    "project=demo" "window=live" "mode=direct-PR" "pr=https://github.com/o/r/pull/4"
  write_meta "$home" actionsfail 'done: PR https://github.com/o/r/pull/6' \
    "project=demo" "window=live" "mode=direct-PR" "pr=https://github.com/o/r/pull/6"
  write_meta "$home" actionsstale 'done: PR https://github.com/o/r/pull/7' \
    "project=demo" "window=live" "mode=direct-PR" "pr=https://github.com/o/r/pull/7"
  out=$(run_json "$home" "$fakebin") || fail "task json failed"
  assert_json_valid "$out" "task output"
  assert_contains "$out" '"classification": "running"' "live worker should be running"
  assert_contains "$out" '"route_profile": "critical"' "route profile should be preserved"
  assert_contains "$out" '"route_model": "gpt-5.5"' "route model should be preserved"
  assert_contains "$out" '"recorded_branch": "fm/live"' "recorded branch should be preserved"
  assert_contains "$out" 'merged_pr_live_worker' "merged PR live worker not classified"
  assert_contains "$out" 'pr_open_ci_green' "green PR not classified"
  assert_contains "$out" 'pr_open_ci_failing' "failing PR not classified"
  assert_contains "$out" 'direct_pr_open_no_ci_ready' "direct-PR no-CI PR should be ready for review"
  assert_contains "$out" '"url": "https://github.com/o/r/pull/6", "state": "open", "ci_state": "failure"' "Actions check-runs should affect CI state"
  assert_contains "$out" '"url": "https://github.com/o/r/pull/7", "state": "open", "ci_state": "failure"' "stale Actions check-runs should not be green"
  pass "task classifications preserve current route metadata"
}

test_live_secondmates_ignore_seed_pr_terminal_state() {
  local home fakebin out
  home=$(make_home secondmate-pr-history)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  write_meta "$home" secondmate-merged 'working: idle' \
    "project=firstmate" "window=live" "kind=secondmate" "mode=secondmate" \
    "pr=https://github.com/o/r/pull/1"
  write_meta "$home" secondmate-closed 'working: idle' \
    "project=firstmate" "window=live" "kind=secondmate" "mode=secondmate" \
    "pr=https://github.com/o/r/pull/8"
  out=$(run_json "$home" "$fakebin") || fail "secondmate seed PR json failed"
  assert_json_valid "$out" "secondmate seed PR output"
  assert_task_classification "$out" secondmate-merged persistent_secondmate_idle "merged seed PR should not close a live secondmate"
  assert_task_classification "$out" secondmate-closed persistent_secondmate_idle "closed seed PR should not close a live secondmate"
  assert_not_contains "$out" 'secondmate-merged:merged_pr_live_worker' "merged seed PR should not create a close recommendation"
  assert_not_contains "$out" 'Close the worker after confirming the PR is merged.' "secondmate seed PR should not use ordinary PR-worker close action"
  pass "live idle secondmates ignore terminal seed PR history"
}

test_completed_scout_with_report_is_not_pr_worker() {
  local home fakebin out
  home=$(make_home scout-report)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  mkdir -p "$home/data/scout-done" "$home/data/scout-closed-pr" "$home/data/scout-missing-worktree"
  printf 'findings\n' > "$home/data/scout-done/report.md"
  printf 'findings\n' > "$home/data/scout-closed-pr/report.md"
  printf 'findings\n' > "$home/data/scout-missing-worktree/report.md"
  write_meta "$home" scout-done 'done: report written' \
    "project=demo" "window=live" "kind=scout" "mode=no-mistakes" \
    "branch=fm/scout-done"
  write_meta "$home" scout-closed-pr 'done: report written' \
    "project=demo" "window=live" "kind=scout" "mode=no-mistakes" \
    "branch=fm/scout-closed-pr" "pr=https://github.com/o/r/pull/8"
  write_meta "$home" scout-missing-worktree 'done: report written' \
    "project=demo" "window=missing" "kind=scout" "mode=no-mistakes" \
    "branch=fm/scout-missing-worktree" "worktree=$home/projects/demo/.treehouse/scout-missing-worktree"
  out=$(run_json "$home" "$fakebin") || fail "scout report json failed"
  assert_json_valid "$out" "scout report output"
  assert_task_classification "$out" scout-done scout_report_ready "completed scout with no PR should classify by report"
  assert_task_classification "$out" scout-closed-pr scout_report_ready "completed scout with closed PR metadata should classify by report"
  assert_task_classification "$out" scout-missing-worktree scout_report_ready "completed scout with missing worktree should classify by report"
  assert_not_contains "$out" 'scout-done:worker_done_no_pr' "completed scout report should not be a no-PR worker"
  assert_not_contains "$out" 'scout-closed-pr:merged_pr_live_worker' "completed scout report should not be a PR worker"
  assert_not_contains "$out" 'scout-missing-worktree:stale_treehouse_state' "completed scout report should not be stale treehouse state"
  pass "completed scouts with reports classify as scout teardown work"
}

test_local_failure_paths_degrade_to_actions_or_unknown() {
  local home fakebin out
  home=$(make_home failures)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  write_meta "$home" missing 'working: vanished' "project=demo" "window=missing"
  write_meta "$home" stale 'working: started' "project=demo" "window=live" "worktree=/tmp/definitely-missing-firstmate-worktree"
  write_meta "$home" invalid 'working: started' "project=demo" "window=live" "pr=https://github.com/o/r/pull/5"
  out=$(run_json "$home" "$fakebin") || fail "failure path json failed"
  assert_contains "$out" 'missing_window_existing_meta' "missing tmux window not classified"
  assert_contains "$out" 'stale_treehouse_state' "missing recorded worktree not classified"
  assert_contains "$out" '"github_state": "partial"' "invalid GitHub output should be partial"
  assert_contains "$out" '"state": "unknown"' "invalid GitHub output should become unknown"
  pass "local failure paths are surfaced without crashing"
}

test_absolute_project_meta_runs_treehouse_status() {
  local home fakebin out project
  home=$(make_home absolute-project)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  project="$home/projects/demo"
  mkdir -p "$project"
  write_meta "$home" absolute 'working: still running' "project=$project" "window=live"
  out=$(PATH="$fakebin:$PATH" TREEHOUSE_FAIL=1 FM_HOME="$home" "$CLI" --json --no-default-reminders) \
    || fail "absolute project json failed"
  assert_contains "$out" 'stale_treehouse_state' "absolute project meta should run treehouse status"
  pass "absolute project meta runs treehouse status"
}

test_github_missing_and_external_reminders_do_not_fail() {
  local home fakebin out
  home=$(make_home github-missing)
  write_meta "$home" ghmiss 'working: started' "project=demo" "window=live" "pr=https://github.com/o/r/pull/2"
  out=$(PATH="/usr/bin:/bin" FM_HOME="$home" "$CLI" --json --no-default-reminders) || fail "missing gh-axi should not fail"
  assert_contains "$out" '"github": { "ok": false' "missing gh-axi should mark GitHub false"
  assert_contains "$out" '"state": "unknown"' "missing gh-axi should make PR unknown"

  home=$(make_home external)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" --json --no-default-reminders --external-pr https://github.com/JTInventory/firstmate/pull/76) || fail "external reminder json failed"
  assert_contains "$out" 'external_open_ci_none' "external no-CI PR should be classified"
  pass "GitHub failures degrade to unknown and external reminders work"
}

test_text_output_and_watcher_source() {
  local home fakebin out
  home=$(make_home text)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  write_meta "$home" live 'working: still running' "project=demo" "window=live"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" --text --include-ok --no-default-reminders) || fail "text output failed"
  assert_contains "$out" 'Firstmate supervision - read-only' "text should show read-only posture"
  assert_contains "$out" 'worker(s) are running normally' "include-ok should show routine workers"
  assert_contains "$out" 'No changes made.' "text should end with no changes made"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" --json --no-default-reminders) || fail "watcher source json failed"
  assert_contains "$out" '"watcher_state": "unknown"' "watcher state should be explicit when sandbox/process visibility is incomplete"
  assert_contains "$out" '"watcher": { "ok": false' "watcher source should be false without proof"
  pass "text output and watcher source are explicit"
}

test_model_is_sourceable_and_schema_is_json
test_empty_home_is_read_only_valid_json
test_task_classifications_and_route_metadata
test_live_secondmates_ignore_seed_pr_terminal_state
test_completed_scout_with_report_is_not_pr_worker
test_local_failure_paths_degrade_to_actions_or_unknown
test_absolute_project_meta_runs_treehouse_status
test_github_missing_and_external_reminders_do_not_fail
test_text_output_and_watcher_source

printf 'all fm-supervision-model tests passed\n'
