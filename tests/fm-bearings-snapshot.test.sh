#!/usr/bin/env bash
# Contract tests for the compact operator bearings projection.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-bearings-snapshot)
HOME_ROOT="$TMP_ROOT/home"
mkdir -p "$HOME_ROOT/data" "$HOME_ROOT/state" "$HOME_ROOT/projects"
printf '%s\n' '# Fixture backlog' > "$HOME_ROOT/data/backlog.md"
cat > "$HOME_ROOT/state/task-a.meta" <<EOF
window=firstmate:fm-task-a
worktree=$ROOT
project=firstmate
kind=ship
mode=no-mistakes
harness=codex
EOF
printf '%s\n' 'done: local fixture' > "$HOME_ROOT/state/task-a.status"

test_default_is_toon_and_local_only() {
  local fakebin output
  fakebin=$(fm_fakebin "$TMP_ROOT")
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'unexpected GitHub call\n' >> "$FM_BEARINGS_NETWORK_LOG"
exit 1
SH
  chmod +x "$fakebin/gh-axi"
  export FM_BEARINGS_NETWORK_LOG="$TMP_ROOT/network.log"
  output=$(PATH="$fakebin:$PATH" FM_HOME="$HOME_ROOT" FM_ROOT_OVERRIDE="$ROOT" "$BEARINGS") || fail "bearings default failed"
  assert_contains "$output" 'schema: fm-bearings-snapshot.v1' "bearings default is missing its schema"
  assert_contains "$output" 'prs: local-only' "bearings default is not explicitly local-only"
  assert_absent "$FM_BEARINGS_NETWORK_LOG" "bearings default unexpectedly called GitHub"
  pass "bearings defaults to a compact local-only TOON view"
}

test_include_prs_soft_fails() {
  local fakebin output
  fakebin=$(fm_fakebin "$TMP_ROOT/include")
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'remote unavailable\n' >&2
exit 1
SH
  chmod +x "$fakebin/gh-axi"
  output=$(PATH="$fakebin:$PATH" FM_HOME="$HOME_ROOT" FM_ROOT_OVERRIDE="$ROOT" "$BEARINGS" --json --include-prs) || fail "bearings include-prs hard-failed on remote failure"
  printf '%s\n' "$output" | jq -e '.schema == "fm-bearings-snapshot.v1" and .prs.mode == "include-prs" and .prs.state == "unavailable"' >/dev/null || fail "bearings did not preserve a valid soft-fail JSON result: $output"
  pass "bearings soft-fails unavailable remote PR data"
}

test_default_is_toon_and_local_only
test_include_prs_soft_fails
