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

assert_backlog_consistency() {
  local json=$1 expected_ok=$2 expected_drift=$3 expected_exceptions=$4 label=$5
  FM_TEST_JSON=$json python3 - "$expected_ok" "$expected_drift" "$expected_exceptions" <<'PY' || fail "$label"
import json
import os
import sys

data = json.loads(os.environ["FM_TEST_JSON"])
backlog = data["backlog_consistency"]
expected_ok = sys.argv[1] == "true"
expected_drift = int(sys.argv[2])
expected_exceptions = int(sys.argv[3])
if backlog["ok"] != expected_ok:
    raise SystemExit(f"expected ok={expected_ok}, got {backlog['ok']}")
if backlog["drift_count"] != expected_drift:
    raise SystemExit(f"expected drift_count={expected_drift}, got {backlog['drift_count']}")
if backlog["expected_exception_count"] != expected_exceptions:
    raise SystemExit(
        f"expected expected_exception_count={expected_exceptions}, got {backlog['expected_exception_count']}"
    )
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
[ -z "${FM_FAKE_TREEHOUSE_DELAY:-}" ] || sleep "$FM_FAKE_TREEHOUSE_DELAY"
printf 'ok\n'
SH
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_CREW_STATE_LOG:-}" ] || printf '%s\n' "$1" >> "$FM_FAKE_CREW_STATE_LOG"
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none}"
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
  chmod +x "$fakebin/tmux" "$fakebin/treehouse" "$fakebin/fm-crew-state.sh" "$fakebin/gh-axi"
}

write_fake_herdr() {
  local fakebin=$1
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1" in
  status) printf '%s\n' '{"client":{"version":"0.7.4","protocol":14},"server":{"running":true}}' ;;
  pane) printf '%s\n' '{"result":{"pane":{"pane_id":"p1"}}}' ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/herdr"
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
  assert_contains "$out" '"$id": "firstmate.supervision.v1.1"' "schema id missing"
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
  assert_backlog_consistency "$out" true 0 0 "empty home should have clean backlog consistency"
  assert_contains "$out" '"actions_total": 0' "empty home should have no actions"
  pass "empty home produces valid read-only JSON"
}

test_injection_wedge_is_structured_in_json() {
  local home fakebin out before after
  home=$(make_home injection-wedge)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  printf 'fm away-mode inject WEDGED: 600s undelivered\nBuffered items: done: PR 1\n' > "$home/state/.subsuper-inject-wedged"
  before=$(find "$home/state" "$home/data" -type f -print0 | sort -z | xargs -0 sha256sum)
  out=$(run_json "$home" "$fakebin") || fail "wedge marker json failed"
  after=$(find "$home/state" "$home/data" -type f -print0 | sort -z | xargs -0 sha256sum)
  [ "$before" = "$after" ] || fail "supervise mutated state while reading wedge marker"
  assert_json_valid "$out" "wedge marker output"
  FM_TEST_JSON="$out" python3 - <<'PY' || fail "wedge marker checklist item was not structured"
import json, os
data = json.loads(os.environ["FM_TEST_JSON"])
items = [item for item in data["checklist"] if item["id"] == "supervision:inject-wedged"]
if len(items) != 1:
    raise SystemExit(f"expected one wedge item, got {len(items)}")
item = items[0]
if item["severity"] != "high" or item["owner"] != "firstmate":
    raise SystemExit(f"unexpected wedge item: {item}")
if "WEDGED" not in " ".join(item["evidence"]):
    raise SystemExit(f"marker evidence missing: {item}")
if data["summary"]["level"] != "action" or data["summary"]["high_total"] < 1:
    raise SystemExit(f"summary did not promote wedge: {data['summary']}")
PY
  pass "injection wedge is exposed as read-only structured supervision"
}

test_registered_secondmate_is_expected_backlog_exception() {
  local home fakebin sm_home out
  home=$(make_home backlog-secondmate)
  fakebin="$home/fakebin"
  sm_home="$home/secondmate-home"
  mkdir -p "$sm_home"
  write_fakebin "$fakebin"
  cat > "$home/data/backlog.md" <<MD
## Secondmate Backlogs
- secondmate-ops - ops tooling (home: $sm_home; scope: firstmate ops; projects: firstmate; added 2026-07-09)

## Done
MD
  printf -- '- secondmate-ops - ops tooling (home: %s; scope: firstmate ops; projects: firstmate; added 2026-07-09)\n' "$sm_home" > "$home/data/secondmates.md"
  fm_write_meta "$home/state/secondmate-ops.meta" \
    "window=fm-secondmate-ops" \
    "worktree=$sm_home" \
    "home=$sm_home" \
    "project=firstmate" \
    "kind=secondmate" \
    "mode=secondmate"
  out=$(run_json "$home" "$fakebin") || fail "registered secondmate backlog json failed"
  assert_json_valid "$out" "registered secondmate backlog output"
  assert_backlog_consistency "$out" true 0 1 "registered secondmate should be an expected exception"
  assert_contains "$out" '"expected_exceptions": [' "expected exception array should be present"
  assert_contains "$out" '"id": "secondmate-ops"' "expected exception should name the secondmate"
  assert_not_contains "$out" '"backlog:secondmate-ops:meta-without-inflight"' "expected exception should not create checklist drift"
  pass "registered secondmate backlog exception is structured but not drift"
}

test_backlog_drift_is_structured_in_json() {
  local home fakebin out
  home=$(make_home backlog-drift)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  cat > "$home/data/backlog.md" <<'MD'
## In flight
- [ ] active-task - Active work (repo: demo, since 2026-07-09)

## Done
MD
  fm_write_meta "$home/state/stale-task.meta" \
    "window=fm-stale-task" \
    "worktree=$home/worktrees/stale-task" \
    "project=demo" \
    "kind=ship" \
    "mode=direct-PR"
  out=$(run_json "$home" "$fakebin") || fail "backlog drift json failed"
  assert_json_valid "$out" "backlog drift output"
  assert_backlog_consistency "$out" false 2 0 "ordinary backlog drift should be exposed"
  assert_contains "$out" '"category": "meta-without-inflight"' "meta-only drift category should be structured"
  assert_contains "$out" '"category": "inflight-without-meta"' "missing-meta drift category should be structured"
  assert_contains "$out" '"level": "action"' "high-severity backlog drift should raise summary level"
  assert_contains "$out" '"backlog:active-task:inflight-without-meta"' "backlog drift should create checklist item"
  pass "ordinary backlog drift is exposed in supervision JSON"
}

test_task_classifications_and_route_metadata() {
  local home fakebin out
  home=$(make_home tasks)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  write_meta "$home" live 'working: still running' \
    "project=demo" "window=live" "kind=ship" "mode=direct-PR" "yolo=off" \
    "harness=codex" "route_profile=critical" "route_harness=codex" "route_model=gpt-5.6-sol" "route_effort=medium" \
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
  assert_contains "$out" '"route_model": "gpt-5.6-sol"' "route model should be preserved"
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

test_live_secondmate_done_status_surfaces_response() {
  local home fakebin out
  home=$(make_home secondmate-done)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  write_meta "$home" secondmate-answer 'done: report written to data/answer.md' \
    "project=firstmate" "window=live" "kind=secondmate" "mode=secondmate" \
    "pr=https://github.com/o/r/pull/1"
  out=$(run_json "$home" "$fakebin") || fail "secondmate done json failed"
  assert_json_valid "$out" "secondmate done output"
  assert_task_classification "$out" secondmate-answer secondmate_response_ready "live secondmate done status should surface response"
  assert_contains "$out" 'secondmate-answer:secondmate_response_ready' "secondmate done response should create a checklist item"
  assert_contains "$out" 'Read or relay the secondmate response; keep the secondmate live.' "secondmate done response should not ask to close the secondmate"
  assert_not_contains "$out" 'secondmate-answer:persistent_secondmate_idle' "secondmate done response should not be hidden as idle"
  pass "live secondmate done statuses surface without retiring the secondmate"
}

test_paused_status_is_an_external_wait() {
  local home fakebin out
  home=$(make_home paused)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  write_meta "$home" paused-worker 'paused: waiting for vendor response' \
    "project=demo" "window=live" "kind=ship" "mode=direct-PR"
  write_meta "$home" paused-secondmate 'paused: waiting for captain confirmation' \
    "project=firstmate" "window=live" "kind=secondmate" "mode=secondmate"
  out=$(run_json "$home" "$fakebin") || fail "paused status json failed"
  assert_json_valid "$out" "paused status output"
  assert_task_classification "$out" paused-worker worker_external_wait "paused worker should not be reported as running"
  assert_task_classification "$out" paused-secondmate worker_external_wait "paused secondmate should not be reported as idle"
  assert_contains "$out" '"owner": "external", "action": "Review the declared external wait before continuing."' "paused wait should show external review action"
  assert_contains "$out" 'paused: waiting for vendor response' "paused reason should be preserved"
  pass "paused statuses are explicit external waits"
}

test_paused_status_requires_reason() {
  local home fakebin out
  home=$(make_home paused-empty)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  write_meta "$home" paused-bare 'paused:' \
    "project=demo" "window=live" "kind=ship" "mode=direct-PR"
  write_meta "$home" paused-whitespace 'paused:    ' \
    "project=demo" "window=live" "kind=ship" "mode=direct-PR"
  write_meta "$home" secondmate-paused-bare 'paused:' \
    "project=firstmate" "window=live" "kind=secondmate" "mode=secondmate"
  write_meta "$home" secondmate-paused-whitespace 'paused:    ' \
    "project=firstmate" "window=live" "kind=secondmate" "mode=secondmate"
  out=$(run_json "$home" "$fakebin") || fail "empty paused status json failed"
  assert_json_valid "$out" "empty paused status output"
  assert_task_classification "$out" paused-bare running "bare paused worker should remain running"
  assert_task_classification "$out" paused-whitespace running "whitespace paused worker should remain running"
  assert_task_classification "$out" secondmate-paused-bare persistent_secondmate_idle "bare paused secondmate should remain idle"
  assert_task_classification "$out" secondmate-paused-whitespace persistent_secondmate_idle "whitespace paused secondmate should remain idle"
  assert_not_contains "$out" 'worker_external_wait' "empty paused reasons never become external waits"
  pass "paused statuses require a non-whitespace reason"
}

test_paused_status_superseded_by_active_run() {
  local home fakebin out
  home=$(make_home paused-superseded)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  write_meta "$home" paused-resumed 'paused: waiting for vendor response' \
    "project=demo" "window=live" "kind=ship" "mode=direct-PR"
  out=$(FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' run_json "$home" "$fakebin") || fail "superseded paused status json failed"
  assert_json_valid "$out" "superseded paused status output"
  assert_task_classification "$out" paused-resumed running "active matched run should supersede paused status"
  assert_not_contains "$out" 'paused-resumed:worker_external_wait' "active matched run should not remain an external wait"
  pass "active run supersedes paused status"
}

test_paused_status_superseded_by_terminal_run() {
  local home fakebin out
  home=$(make_home paused-terminal)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  write_meta "$home" paused-terminal 'paused: waiting for vendor response' \
    "project=demo" "window=live" "kind=ship" "mode=no-mistakes"
  out=$(FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed' run_json "$home" "$fakebin") || fail "terminal paused status json failed"
  assert_json_valid "$out" "terminal paused status output"
  assert_task_classification "$out" paused-terminal worker_failed "terminal matched run should surface its failure"
  assert_not_contains "$out" 'paused-terminal:worker_external_wait' "terminal run should not remain an external wait"
  pass "terminal run supersedes paused status"
}

test_terminal_pause_keeps_status_pr_url() {
  local home fakebin out
  home=$(make_home paused-terminal-pr)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  write_meta "$home" paused-terminal-pr 'paused: waiting for vendor response; PR https://github.com/o/r/pull/2' \
    "project=demo" "window=live" "kind=ship" "mode=no-mistakes"
  out=$(FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE='state: done · source: run-step · run completed' run_json "$home" "$fakebin") || fail "terminal paused PR json failed"
  assert_json_valid "$out" "terminal paused PR output"
  assert_task_classification "$out" paused-terminal-pr pr_open_ci_green "terminal run should retain the paused status PR URL"
  assert_contains "$out" '"pr_url": "https://github.com/o/r/pull/2"' "terminal run should preserve the paused status PR URL"
  pass "terminal pause reconciliation preserves status PR URL"
}

test_paused_status_superseded_by_parked_run() {
  local home fakebin out
  home=$(make_home paused-parked)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  write_meta "$home" paused-parked 'paused: waiting for vendor response' \
    "project=demo" "window=live" "kind=ship" "mode=no-mistakes"
  out=$(FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review (ask-user: captain decision)' run_json "$home" "$fakebin") || fail "parked paused status json failed"
  assert_json_valid "$out" "parked paused status output"
  assert_task_classification "$out" paused-parked worker_needs_decision "parked matched run should surface a captain decision"
  assert_contains "$out" 'paused-parked:worker_needs_decision' "parked run should create a captain-owned checklist item"
  assert_contains "$out" '"owner": "captain", "action": "Make the requested decision."' "parked run should retain the captain decision action"
  assert_not_contains "$out" 'paused-parked:worker_external_wait' "parked run should not remain an external wait"
  pass "parked run supersedes paused status"
}

test_paused_reconciliation_has_a_fleet_budget() {
  local home fakebin log out
  home=$(make_home paused-budget)
  fakebin="$home/fakebin"
  log="$home/crew-state.log"
  write_fakebin "$fakebin"
  write_meta "$home" paused-budget 'paused: waiting for vendor response' \
    "project=demo" "window=live" "kind=ship" "mode=no-mistakes"
  out=$(FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE_LOG="$log" FM_SUPERVISION_PAUSE_RECONCILE_SECS=0 run_json "$home" "$fakebin") || fail "paused budget json failed"
  assert_json_valid "$out" "paused budget output"
  assert_task_classification "$out" paused-budget worker_external_wait "unreconciled pause remains visible"
  [ ! -e "$log" ] || fail "exhausted pause budget should skip crew-state reads"
  pass "paused reconciliation has a fleet budget"
}

test_paused_reconciliation_ignores_prior_task_delay() {
  local home fakebin project out
  home=$(make_home paused-prior-delay)
  fakebin="$home/fakebin"
  project="$home/projects/slow-project"
  mkdir -p "$project"
  write_fakebin "$fakebin"
  write_meta "$home" a-slow 'working: checking remote state' \
    "project=$project" "window=live" "kind=ship" "mode=no-mistakes"
  write_meta "$home" z-paused 'paused: waiting for vendor response' \
    "project=demo" "window=live" "kind=ship" "mode=no-mistakes"
  out=$(FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE='state: done · source: run-step · run completed' FM_FAKE_TREEHOUSE_DELAY=2 FM_SUPERVISION_PAUSE_RECONCILE_SECS=1 run_json "$home" "$fakebin") \
    || fail "prior task delay should not exhaust paused reconciliation budget"
  assert_json_valid "$out" "prior task delay output"
  assert_task_classification "$out" z-paused worker_done_no_pr "paused reconciliation should retain its budget after an earlier slow task"
  assert_not_contains "$out" 'z-paused:worker_external_wait' "later paused worker should reconcile after earlier slow task"
  pass "paused reconciliation ignores prior non-paused task delay"
}

test_paused_reconciliation_invalid_budget_uses_default() {
  local home fakebin out
  home=$(make_home paused-invalid-budget)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  write_meta "$home" paused-invalid-budget 'paused: waiting for vendor response' \
    "project=demo" "window=live" "kind=ship" "mode=no-mistakes"
  out=$(FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE='state: done · source: run-step · run completed' FM_SUPERVISION_PAUSE_RECONCILE_SECS=5s run_json "$home" "$fakebin") || fail "invalid paused budget should not abort supervision"
  assert_json_valid "$out" "invalid paused budget output"
  assert_task_classification "$out" paused-invalid-budget worker_done_no_pr "invalid paused budget should use the default reconciliation budget"
  pass "invalid paused reconciliation budget uses default"
}

test_paused_reconciliation_oversized_budget_uses_default() {
  local home fakebin out
  home=$(make_home paused-oversized-budget)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  write_meta "$home" paused-oversized-budget 'paused: waiting for vendor response' \
    "project=demo" "window=live" "kind=ship" "mode=no-mistakes"
  out=$(FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_FAKE_CREW_STATE='state: done · source: run-step · run completed' FM_SUPERVISION_PAUSE_RECONCILE_SECS=9999999999999999999 run_json "$home" "$fakebin") || fail "oversized paused budget should not abort supervision"
  assert_json_valid "$out" "oversized paused budget output"
  assert_task_classification "$out" paused-oversized-budget worker_done_no_pr "oversized paused budget should use the default reconciliation budget"
  pass "oversized paused reconciliation budget uses default"
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

test_scout_report_requires_done_status() {
  local home fakebin out kind
  home=$(make_home scout-report-not-terminal)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  for kind in working blocked decision failed; do
    mkdir -p "$home/data/scout-$kind"
    printf 'findings\n' > "$home/data/scout-$kind/report.md"
  done
  write_meta "$home" scout-working 'working: still investigating' \
    "project=demo" "window=live" "kind=scout" "mode=no-mistakes"
  write_meta "$home" scout-blocked 'blocked: needs source fixture' \
    "project=demo" "window=live" "kind=scout" "mode=no-mistakes"
  write_meta "$home" scout-decision 'needs-decision: choose scope' \
    "project=demo" "window=live" "kind=scout" "mode=no-mistakes"
  write_meta "$home" scout-failed 'failed: repro broke' \
    "project=demo" "window=live" "kind=scout" "mode=no-mistakes"
  : > "$home/state/scout-working.turn-ended"
  out=$(run_json "$home" "$fakebin") || fail "scout non-terminal report json failed"
  assert_json_valid "$out" "scout non-terminal report output"
  assert_task_classification "$out" scout-working running "working scout with report and turn-ended should not be ready"
  assert_task_classification "$out" scout-blocked worker_blocked "blocked scout with report should not be ready"
  assert_task_classification "$out" scout-decision worker_needs_decision "needs-decision scout with report should not be ready"
  assert_task_classification "$out" scout-failed worker_failed "failed scout with report should not be ready"
  assert_not_contains "$out" 'scout-working:scout_report_ready' "working scout report should not produce teardown action"
  assert_not_contains "$out" 'scout-blocked:scout_report_ready' "blocked scout report should not produce teardown action"
  assert_not_contains "$out" 'scout-decision:scout_report_ready' "needs-decision scout report should not produce teardown action"
  assert_not_contains "$out" 'scout-failed:scout_report_ready' "failed scout report should not produce teardown action"
  pass "scout reports require an explicit done status before teardown classification"
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

test_herdr_only_fleet_reports_backend_health() {
  local home fakebin out
  home=$(make_home herdr-only)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  rm -f "$fakebin/tmux"
  write_fake_herdr "$fakebin"
  write_meta "$home" herdr-live 'working: still running' "project=demo" "window=default:p1" "backend=herdr" "worktree=$home"
  out=$(PATH="$fakebin:/usr/bin:/bin" FM_HOME="$home" "$CLI" --json --no-default-reminders) || fail "Herdr-only supervision json failed"
  FM_TEST_JSON=$out python3 - <<'PY' || fail "Herdr-only fleet reported the wrong source health"
import json
import os

sources = json.loads(os.environ["FM_TEST_JSON"])["sources"]
if sources["tmux"]["ok"] is not True:
    raise SystemExit("tmux should not be unhealthy when no active task uses it")
if sources["herdr"]["ok"] is not True:
    raise SystemExit(f"Herdr source was unhealthy: {sources['herdr']}")
PY
  pass "Herdr-only supervision reports backend-aware source health"
}

test_noninteractive_path_discovers_home_nvm_axi() {
  local home nodebin out
  home=$(make_home noninteractive-nvm)
  nodebin="$home/.nvm/versions/node/v22.22.2/bin"
  write_fakebin "$nodebin"

  out=$(HOME="$home" PATH="/usr/bin:/bin" FM_HOME="$home" "$CLI" --json --no-default-reminders) \
    || fail "non-interactive NVM discovery failed"
  assert_contains "$out" '"github": { "ok": true' "HOME NVM gh-axi should be discovered"
  assert_contains "$out" '"github_state": "ok"' "non-interactive GitHub state should be ok"
  assert_not_contains "$out" 'gh-axi missing' "non-interactive PATH should be normalized"
  pass "non-interactive PATH discovers HOME NVM Axi tools"
}

test_text_output_and_watcher_source() {
  local home fakebin out
  home=$(make_home text)
  fakebin="$home/fakebin"
  write_fakebin "$fakebin"
  write_meta "$home" live 'working: still running' "project=demo" "window=live"
  write_meta "$home" secondmate-idle 'working: idle' "project=firstmate" "window=live" "kind=secondmate" "mode=secondmate"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" --text --include-ok --no-default-reminders) || fail "text output failed"
  assert_contains "$out" 'Firstmate supervision - read-only' "text should show read-only posture"
  assert_contains "$out" '2 worker(s) are running normally' "include-ok should show routine workers and persistent secondmates"
  assert_contains "$out" 'No changes made.' "text should end with no changes made"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$CLI" --json --no-default-reminders) || fail "watcher source json failed"
  assert_contains "$out" '"watcher_state": "unknown"' "watcher state should be explicit when sandbox/process visibility is incomplete"
  assert_contains "$out" '"watcher": { "ok": false' "watcher source should be false without proof"
  pass "text output and watcher source are explicit"
}

test_model_is_sourceable_and_schema_is_json
test_empty_home_is_read_only_valid_json
test_injection_wedge_is_structured_in_json
test_registered_secondmate_is_expected_backlog_exception
test_backlog_drift_is_structured_in_json
test_task_classifications_and_route_metadata
test_live_secondmates_ignore_seed_pr_terminal_state
test_live_secondmate_done_status_surfaces_response
test_paused_status_is_an_external_wait
test_paused_status_requires_reason
test_paused_status_superseded_by_active_run
test_paused_status_superseded_by_terminal_run
test_paused_reconciliation_invalid_budget_uses_default
test_paused_reconciliation_oversized_budget_uses_default
test_terminal_pause_keeps_status_pr_url
test_paused_status_superseded_by_parked_run
test_paused_reconciliation_has_a_fleet_budget
test_paused_reconciliation_ignores_prior_task_delay
test_completed_scout_with_report_is_not_pr_worker
test_scout_report_requires_done_status
test_local_failure_paths_degrade_to_actions_or_unknown
test_absolute_project_meta_runs_treehouse_status
test_github_missing_and_external_reminders_do_not_fail
test_noninteractive_path_discovers_home_nvm_axi
test_herdr_only_fleet_reports_backend_health
test_text_output_and_watcher_source

printf 'all fm-supervision-model tests passed\n'
