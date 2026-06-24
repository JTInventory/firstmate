#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-brief-nm-gate-tests.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

make_home() {
  local name=$1 line=$2 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$line" > "$home/data/projects.md"
  printf '%s\n' "$home"
}

test_direct_pr_old_behavior_unchanged() {
  local home brief
  home=$(make_home old-direct '- app [direct-PR] - app (added 2026-06-24)')
  FM_HOME="$home" "$BRIEF" task-old app >/dev/null || fail "old direct-PR brief failed"
  brief="$home/data/task-old/brief.md"

  grep -F 'This project ships **direct-PR**' "$brief" >/dev/null || fail "old direct-PR heading changed"
  grep -F 'push your branch and open a PR with `gh-axi`' "$brief" >/dev/null || fail "old direct-PR push/PR instruction missing"
  grep -F 'ready for Firstmate PR scope review' "$brief" >/dev/null && fail "old direct-PR brief got nm-gate scope-review text"
  pass "direct-PR old behavior remains unchanged"
}

test_nm_gate_worker_stops_at_scope_review() {
  local home brief
  home=$(make_home gated '- app [direct-PR +nm-gate] - app (added 2026-06-24)')
  FM_HOME="$home" "$BRIEF" task-gated app >/dev/null || fail "nm-gate brief failed"
  brief="$home/data/task-gated/brief.md"

  grep -F 'This project ships **direct-PR +nm-gate**' "$brief" >/dev/null || fail "nm-gate heading missing"
  grep -F 'ready for Firstmate PR scope review' "$brief" >/dev/null || fail "scope-review stop missing"
  grep -F 'Commit only if the task explicitly authorizes commits.' "$brief" >/dev/null || fail "commit guard missing"
  grep -F 'Do NOT run /no-mistakes. Do NOT push. Do NOT open a PR.' "$brief" >/dev/null || fail "worker no-push/no-pr/no-gate rule missing"
  grep -F 'push your branch and open a PR with `gh-axi`' "$brief" >/dev/null && fail "nm-gate brief still tells worker to push/open PR"
  pass "nm-gate worker brief stops at Firstmate scope review"
}

test_scout_ignores_nm_gate() {
  local home brief
  home=$(make_home scout '- app [direct-PR +nm-gate] - app (added 2026-06-24)')
  FM_HOME="$home" "$BRIEF" task-scout app --scout >/dev/null || fail "scout brief failed"
  brief="$home/data/task-scout/brief.md"

  grep -F 'This is a SCOUT task' "$brief" >/dev/null || fail "scout brief missing scout contract"
  grep -F 'no-mistakes' "$brief" >/dev/null && fail "scout brief mentioned no-mistakes"
  grep -F 'ready for Firstmate PR scope review' "$brief" >/dev/null && fail "scout brief got nm-gate delivery text"
  pass "scout briefs ignore nm-gate"
}

test_direct_pr_old_behavior_unchanged
test_nm_gate_worker_stops_at_scope_review
test_scout_ignores_nm_gate
