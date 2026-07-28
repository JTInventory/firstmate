#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCOPE="$ROOT/bin/fm-scope-contract.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-scope-contract)

write_spec() {
  local path=$1
  printf 'AC-1\tThe requested behavior is demonstrated.\nAC-2\tExisting behavior remains compatible.\nNG-1\tDo not enable global enforcement.\n' > "$path"
}

test_scope_contract_renders_by_delivery_mode() {
  local dir spec brief
  dir="$TMP_ROOT/render"
  mkdir -p "$dir/home/data" "$dir/home/state" "$dir/home/config"
  spec="$dir/scope.tsv"
  write_spec "$spec"
  printf '%s\n' '- project-a [no-mistakes] - fixture' > "$dir/home/data/projects.md"

  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir/home" FM_DATA_OVERRIDE="$dir/home/data" \
    FM_STATE_OVERRIDE="$dir/home/state" "$BRIEF" task-a project-a --scope-contract "$spec" >/dev/null \
    || fail "scope-contract brief did not render"
  brief="$dir/home/data/task-a/brief.md"
  assert_grep '```firstmate-scope-contract-v1' "$brief" "scope data fence missing"
  assert_grep $'AC-1\tThe requested behavior is demonstrated.' "$brief" "acceptance row missing"
  assert_grep '# PR scope ledger (advisory)' "$brief" "PR-mode ledger guidance missing"
  assert_grep '| ID | Status | Evidence | Residual risk |' "$brief" "residual-risk ledger column missing"
  assert_grep 'This ledger is advisory' "$brief" "shadow-mode warning missing"
  assert_grep 'firstmate-scope-contract-v1' "$dir/home/data/task-a/scope-contract-enabled" "scope opt-in marker missing"

  mkdir -p "$dir/local/data" "$dir/local/state"
  printf '%s\n' '- project-b [local-only] - fixture' > "$dir/local/data/projects.md"
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir/local" FM_DATA_OVERRIDE="$dir/local/data" \
    FM_STATE_OVERRIDE="$dir/local/state" "$BRIEF" task-b project-b --scope-contract "$spec" >/dev/null \
    || fail "local-only scope-contract brief did not render"
  assert_grep '# Scope contract' "$dir/local/data/task-b/brief.md" "local-only AC/NG contract missing"
  assert_no_grep '# PR scope ledger' "$dir/local/data/task-b/brief.md" "local-only brief received PR ledger"
  pass "scope contracts render AC/NG everywhere and ledger guidance only for PR modes"
}

test_invalid_contracts_fail_before_spawn() {
  local dir spec brief rc
  dir="$TMP_ROOT/invalid"
  mkdir -p "$dir/home/data/task-a" "$dir/home/state"
  spec="$dir/bad.tsv"
  printf 'AC-1\tvalid\nAC-1\tduplicate\nNG-1\t{TODO}\n' > "$spec"
  set +e
  "$SCOPE" validate-spec "$spec" >"$dir/out" 2>"$dir/err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "duplicate and unresolved scope identifiers were accepted"

  set +e
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir/empty-home" FM_DATA_OVERRIDE="$dir/empty-home/data" \
    FM_STATE_OVERRIDE="$dir/empty-home/state" "$BRIEF" task-empty project-a --scope-contract= \
    >"$dir/empty.out" 2>"$dir/empty.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "empty --scope-contract option silently created a legacy brief"
  assert_grep 'scope-contract requires a value' "$dir/empty.err" "empty scope option diagnostic missing"

  brief="$dir/home/data/task-a/brief.md"
  cat > "$brief" <<'EOF'
```firstmate-scope-contract-v1
AC-1	valid
NG-1	valid
AC-1	duplicate
```
EOF
  set +e
  "$SCOPE" validate-brief "$brief" >"$dir/brief.out" 2>"$dir/brief.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "tampered brief scope contract was accepted"
  pass "duplicates and unresolved placeholders fail closed before spawn"
}

test_ledger_audit_is_advisory_and_treats_body_as_data() {
  local dir spec brief body out marker
  dir="$TMP_ROOT/audit"
  mkdir -p "$dir"
  spec="$dir/scope.tsv"
  brief="$dir/brief.md"
  body="$dir/body.md"
  marker="$dir/should-not-exist"
  write_spec "$spec"
  "$SCOPE" append-brief "$spec" "$brief" no-mistakes

  cat > "$body" <<EOF
| ID | Status | Evidence | Residual risk |
| AC-1 | covered | tests pass | none |
| AC-1 | covered | duplicate | none |
| AC-2 | violated | | |
| ZZ-9 | covered | \$(touch "$marker") | none |
EOF
  out=$("$SCOPE" audit-body "$brief" "$body") || fail "advisory audit blocked the caller"
  assert_contains "$out" $'scope-ledger-finding\tduplicate\tAC-1' "duplicate finding missing"
  assert_contains "$out" $'scope-ledger-finding\tempty-evidence\tAC-2' "empty-evidence finding missing"
  assert_contains "$out" $'scope-ledger-finding\tinvalid-status\tAC-2' "invalid-status finding missing"
  assert_contains "$out" $'scope-ledger-finding\tempty-residual-risk\tAC-2' "empty residual-risk finding missing"
  assert_contains "$out" $'scope-ledger-finding\tmissing\tNG-1' "missing finding missing"
  assert_contains "$out" $'scope-ledger-finding\tunknown\tZZ-9' "unknown finding missing"
  assert_absent "$marker" "PR body bytes executed as shell instructions"

  cat > "$body" <<'EOF'
| ID | Status | Evidence | Residual risk |
| AC-1 | covered | fixture one | none |
| AC-2 | not-applicable | fixture two | documented exception |
| NG-1 | out-of-scope | non-goal retained | none |
EOF
  out=$("$SCOPE" audit-body "$brief" "$body") || fail "complete advisory ledger failed"
  assert_contains "$out" $'scope-ledger\tpass\tfindings=0' "complete ledger did not pass"
  pass "PR ledger audit stays advisory, reports all finding classes, and never executes body text"
}

test_scope_contract_renders_by_delivery_mode
test_invalid_contracts_fail_before_spawn
test_ledger_audit_is_advisory_and_treats_body_as_data
