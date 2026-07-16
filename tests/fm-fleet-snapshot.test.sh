#!/usr/bin/env bash
# Contract tests for the local-only fleet snapshot consumed by operator views.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot)
HOME_ROOT="$TMP_ROOT/home"
mkdir -p "$HOME_ROOT/data" "$HOME_ROOT/state" "$HOME_ROOT/projects"

write_fixture() {
  printf '%s\n' '# Fixture backlog' > "$HOME_ROOT/data/backlog.md"
  cat > "$HOME_ROOT/state/task-a.meta" <<EOF
window=firstmate:fm-task-a
worktree=$ROOT
project=firstmate
kind=ship
mode=no-mistakes
harness=codex
EOF
  printf '%s\n' 'working: fixture is active' > "$HOME_ROOT/state/task-a.status"
}

test_snapshot_contract_is_json_and_local() {
  local fakebin output
  fakebin=$(fm_fakebin "$TMP_ROOT")
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf 'unexpected GitHub call\n' >> "$FM_SNAPSHOT_NETWORK_LOG"
exit 1
SH
  chmod +x "$fakebin/gh-axi"
  export FM_SNAPSHOT_NETWORK_LOG="$TMP_ROOT/network.log"
  write_fixture
  output=$(PATH="$fakebin:$PATH" FM_HOME="$HOME_ROOT" FM_ROOT_OVERRIDE="$ROOT" "$SNAPSHOT" --json) || fail "fleet snapshot --json failed"
  printf '%s\n' "$output" | jq -e '.schema == "fm-fleet-snapshot.v1" and .read_only == true and (.tasks | length == 1) and .tasks[0].id == "task-a"' >/dev/null || fail "fleet snapshot contract is wrong: $output"
  assert_absent "$FM_SNAPSHOT_NETWORK_LOG" "local snapshot unexpectedly called GitHub"
  pass "fleet snapshot emits a bounded local-only JSON contract"
}

test_snapshot_help() {
  "$SNAPSHOT" --help | grep -Fq -- '--json' || fail "fleet snapshot help does not document --json"
  pass "fleet snapshot documents its machine-readable mode"
}

test_snapshot_contract_is_json_and_local
test_snapshot_help
