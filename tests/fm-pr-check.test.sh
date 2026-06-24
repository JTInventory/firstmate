#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-check-tests.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$home"
}

count_key() {
  local key=$1 file=$2
  grep -c "^$key=" "$file" 2>/dev/null || true
}

test_pr_check_upserts_meta_fields() {
  local home meta
  home=$(make_home upsert)
  meta="$home/state/task.meta"
  cat > "$meta" <<EOF
kind=ship
nm_gate=on
nm_status=pending_scope_review
pr=https://old.example/pr/1
pr_source=direct
EOF

  FM_HOME="$home" "$PR_CHECK" task https://github.com/example/repo/pull/2 no-mistakes pr_recorded >/dev/null \
    || fail "fm-pr-check no-mistakes pr_recorded failed"
  [ "$(count_key pr "$meta")" = 1 ] || fail "pr key duplicated"
  [ "$(count_key pr_source "$meta")" = 1 ] || fail "pr_source key duplicated"
  [ "$(count_key nm_status "$meta")" = 1 ] || fail "nm_status key duplicated"
  grep -Fx 'pr=https://github.com/example/repo/pull/2' "$meta" >/dev/null || fail "pr not upserted"
  grep -Fx 'pr_source=no-mistakes' "$meta" >/dev/null || fail "pr_source not upserted"
  grep -Fx 'nm_status=pr_recorded' "$meta" >/dev/null || fail "conservative nm_status not recorded"
  pass "fm-pr-check upserts PR metadata without duplicates"
}

test_no_mistakes_passed_requires_explicit_status() {
  local home meta
  home=$(make_home passed)
  meta="$home/state/task.meta"
  cat > "$meta" <<EOF
kind=ship
nm_gate=on
nm_status=pending_scope_review
EOF

  FM_HOME="$home" "$PR_CHECK" task https://github.com/example/repo/pull/3 no-mistakes >/dev/null \
    || fail "fm-pr-check default no-mistakes failed"
  grep -Fx 'nm_status=pr_recorded' "$meta" >/dev/null || fail "no-mistakes default should be pr_recorded"
  grep -Fx 'nm_status=passed' "$meta" >/dev/null && fail "no-mistakes source alone marked passed"

  FM_HOME="$home" "$PR_CHECK" task https://github.com/example/repo/pull/3 no-mistakes passed >/dev/null \
    || fail "fm-pr-check explicit passed failed"
  grep -Fx 'nm_status=passed' "$meta" >/dev/null || fail "explicit passed status not recorded"
  pass "no-mistakes passed status must be explicit"
}

test_check_script_only_wakes_on_merged_pr() {
  local home check fakebin out
  home=$(make_home no-auto-chain)
  printf '%s\n' 'kind=ship' > "$home/state/task.meta"
  FM_HOME="$home" "$PR_CHECK" task https://github.com/example/repo/pull/4 direct >/dev/null \
    || fail "fm-pr-check direct failed"
  check="$home/state/task.check.sh"
  [ -x "$check" ] || chmod +x "$check"

  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_FAKE_PR_STATE:-OPEN}"
SH
  chmod +x "$fakebin/gh"

  out=$(PATH="$fakebin:$PATH" FM_FAKE_PR_STATE=OPEN bash "$check")
  [ -z "$out" ] || fail "check script woke before merge: $out"
  out=$(PATH="$fakebin:$PATH" FM_FAKE_PR_STATE=MERGED bash "$check")
  [ "$out" = "merged" ] || fail "check script did not wake on merge: $out"
  pass "fm-pr-check arms merge poll only, with no auto-chain"
}

test_pr_check_upserts_meta_fields
test_no_mistakes_passed_requires_explicit_status
test_check_script_only_wakes_on_merged_pr
