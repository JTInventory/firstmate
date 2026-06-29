#!/usr/bin/env bash
# Tests for bin/fm-backlog-audit.sh's read-only backlog/state drift checks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUDIT="$ROOT/bin/fm-backlog-audit.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-audit-tests)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

write_backlog() {
  local home=$1
  cat > "$home/data/backlog.md"
}

write_meta() {
  local home=$1 id=$2
  fm_write_meta "$home/state/$id.meta" \
    "window=fm-$id" \
    "worktree=$home/worktrees/$id" \
    "project=$home/projects/demo" \
    "kind=ship" \
    "mode=direct-PR"
}

run_audit() {
  local home=$1 out=$2 rc
  set +e
  FM_HOME="$home" "$AUDIT" > "$out" 2>&1
  rc=$?
  printf '%s\n' "$rc"
}

test_clean_backlog_passes() {
  local home out rc
  home=$(make_home clean)
  write_backlog "$home" <<'MD'
## In flight
- [ ] alpha-task - Active work (repo: demo, since 2026-06-29)

## Queued
- [ ] beta-task - Later work (repo: demo)

## Done
- [x] old-task - Shipped work - https://github.com/example/repo/pull/1 (merged 2026-06-28)

## Watchlist
- [ ] external-task - Follow upstream PR
MD
  write_meta "$home" alpha-task
  out="$home/out.txt"
  rc=$(run_audit "$home" "$out")
  expect_code 0 "$rc" "clean backlog audit"
  assert_contains "$(cat "$out")" "No backlog/state drift found." "clean audit reports no drift"
  pass "clean backlog/state audit passes"
}

test_detects_required_drift_cases() {
  local home out rc
  home=$(make_home drift)
  write_backlog "$home" <<'MD'
## In flight
- [ ] dup-task - Active and also done (repo: demo, since 2026-06-29)
- [ ] no-meta-task - Missing meta file (repo: demo, since 2026-06-29)
- [ ] pr-ready-task - PR ready https://github.com/example/repo/pull/2 (repo: demo, since 2026-06-29)
- **bold-task** - Bold in-flight item form (repo: demo, since 2026-06-29)

## Done
- [x] dup-task - Active and also done - https://github.com/example/repo/pull/1 (merged 2026-06-28)

## Watchlist
- [ ] watched-task - Track until adopted locally
MD
  write_meta "$home" dup-task
  write_meta "$home" meta-only-task
  write_meta "$home" watched-task
  write_meta "$home" pr-ready-task
  write_meta "$home" bold-task
  out="$home/out.txt"
  rc=$(run_audit "$home" "$out")
  expect_code 1 "$rc" "drift backlog audit"
  assert_contains "$(cat "$out")" "duplicate-done: dup-task listed in both In flight and Done" "duplicate done drift reported"
  assert_contains "$(cat "$out")" "meta-without-inflight: meta-only-task has state meta but is not in In flight" "meta-only drift reported"
  assert_contains "$(cat "$out")" "inflight-without-meta: no-meta-task is In flight but has no state meta" "missing meta drift reported"
  assert_contains "$(cat "$out")" "inflight-pr-ready: pr-ready-task is still In flight but looks PR-ready or merged" "PR-ready drift reported"
  assert_contains "$(cat "$out")" "watchlist-adopted: watched-task is still on Watchlist but already has local state meta" "watchlist adoption drift reported"
  assert_not_contains "$(cat "$out")" "inflight-without-meta: bold-task" "bold in-flight form is parsed"
  pass "required backlog/state drift cases are reported"
}

test_audit_is_read_only() {
  local home out before after rc
  home=$(make_home readonly)
  write_backlog "$home" <<'MD'
## In flight
- [ ] no-meta-task - Missing meta file (repo: demo, since 2026-06-29)

## Done
MD
  out="$home/out.txt"
  before=$(find "$home" -type f -print0 | sort -z | xargs -0 sha256sum)
  rc=$(run_audit "$home" "$out")
  expect_code 1 "$rc" "read-only audit with drift"
  after=$(find "$home" -type f ! -name out.txt -print0 | sort -z | xargs -0 sha256sum)
  [ "$before" = "$after" ] || fail "audit modified home files"
  pass "backlog audit is read-only"
}

test_clean_backlog_passes
test_detects_required_drift_cases
test_audit_is_read_only
