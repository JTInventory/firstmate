#!/usr/bin/env bash
# Behavior tests for fm-no-mistakes-pr-target-guard.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-target-guard-tests)

make_repo() {
  local dir=$1 origin_url=$2
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$origin_url"
}

add_gate_remote() {
  local repo=$1 gate_origin=$2 gate
  gate="$TMP_ROOT/gate-$(basename "$repo").git"
  git init --bare -q "$gate"
  git --git-dir="$gate" config remote.origin.url "$gate_origin"
  git -C "$repo" remote add no-mistakes "$gate"
}

run_guard() {
  local repo=$1 out=$2 err=$3
  (cd "$repo" && "$ROOT/bin/fm-no-mistakes-pr-target-guard.sh" >"$out" 2>"$err")
}

test_accepts_captain_fork_origin_and_gate() {
  local repo="$TMP_ROOT/pass" out="$TMP_ROOT/pass.out" err="$TMP_ROOT/pass.err"
  make_repo "$repo" "https://github.com/JTInventory/firstmate"
  add_gate_remote "$repo" "git@github.com:JTInventory/firstmate.git"

  run_guard "$repo" "$out" "$err" || fail "guard rejected the captain fork target: $(cat "$err")"
  assert_grep "ok: PR target repo jtinventory/firstmate verified" "$out" "guard did not report verified target"
  pass "PR target guard accepts captain fork origin and no-mistakes gate"
}

test_rejects_parent_origin_target() {
  local repo="$TMP_ROOT/parent-origin" out="$TMP_ROOT/parent-origin.out" err="$TMP_ROOT/parent-origin.err"
  make_repo "$repo" "https://github.com/kunchenguid/firstmate"

  if run_guard "$repo" "$out" "$err"; then
    fail "guard accepted parent origin target"
  fi
  assert_grep "blocked: would target upstream remote.origin.url=https://github.com/kunchenguid/firstmate" "$err" \
    "guard did not explain parent origin target"
  pass "PR target guard rejects parent origin target"
}

test_rejects_parent_pushurl_target() {
  local repo="$TMP_ROOT/parent-pushurl" out="$TMP_ROOT/parent-pushurl.out" err="$TMP_ROOT/parent-pushurl.err"
  make_repo "$repo" "https://github.com/JTInventory/firstmate"
  git -C "$repo" remote set-url --push origin "https://github.com/kunchenguid/firstmate"

  if run_guard "$repo" "$out" "$err"; then
    fail "guard accepted parent push URL target"
  fi
  assert_grep "blocked: would target upstream remote.origin.pushurl=https://github.com/kunchenguid/firstmate" "$err" \
    "guard did not explain parent push URL target"
  pass "PR target guard rejects parent origin push URL target"
}

test_rejects_parent_no_mistakes_gate_target() {
  local repo="$TMP_ROOT/parent-gate" out="$TMP_ROOT/parent-gate.out" err="$TMP_ROOT/parent-gate.err"
  make_repo "$repo" "https://github.com/JTInventory/firstmate"
  add_gate_remote "$repo" "https://github.com/kunchenguid/firstmate"

  if run_guard "$repo" "$out" "$err"; then
    fail "guard accepted parent no-mistakes gate target"
  fi
  assert_grep "blocked: would target upstream no-mistakes gate remote.origin.url=https://github.com/kunchenguid/firstmate" "$err" \
    "guard did not explain parent no-mistakes gate target"
  pass "PR target guard rejects parent no-mistakes gate target"
}

test_rejects_parent_no_mistakes_status_target() {
  local repo="$TMP_ROOT/parent-status" fakebin out="$TMP_ROOT/parent-status.out" err="$TMP_ROOT/parent-status.err"
  make_repo "$repo" "https://github.com/JTInventory/firstmate"
  fakebin=$(fm_fakebin "$TMP_ROOT/status-fakebin")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  printf '    repo:  /tmp/firstmate\n'
  printf '  remote:  https://github.com/kunchenguid/firstmate\n'
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/no-mistakes"

  if (cd "$repo" && PATH="$fakebin:$PATH" "$ROOT/bin/fm-no-mistakes-pr-target-guard.sh" >"$out" 2>"$err"); then
    fail "guard accepted parent no-mistakes status target"
  fi
  assert_grep "blocked: would target upstream no-mistakes status remote=https://github.com/kunchenguid/firstmate" "$err" \
    "guard did not explain parent no-mistakes status target"
  pass "PR target guard rejects parent no-mistakes status target"
}

test_accepts_captain_fork_origin_and_gate
test_rejects_parent_origin_target
test_rejects_parent_pushurl_target
test_rejects_parent_no_mistakes_gate_target
test_rejects_parent_no_mistakes_status_target
