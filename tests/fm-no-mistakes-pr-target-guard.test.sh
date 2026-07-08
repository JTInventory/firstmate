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

set_branch_tracking() {
  local repo=$1 branch=$2 remote=$3 merge_ref=$4
  git -C "$repo" checkout -q -B "$branch"
  git -C "$repo" config "branch.$branch.remote" "$remote"
  git -C "$repo" config "branch.$branch.merge" "$merge_ref"
}

status_fakebin() {
  local name=$1 remote=$2 fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/$name-status")
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = status ]; then
  printf '    repo:  /tmp/firstmate\n'
  printf '  remote:  $remote\n'
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s\n' "$fakebin"
}

run_guard() {
  local repo=$1 out=$2 err=$3
  (cd "$repo" && "$ROOT/bin/fm-no-mistakes-pr-target-guard.sh" >"$out" 2>"$err")
}

run_guard_with_fakebin() {
  local repo=$1 fakebin=$2 out=$3 err=$4
  (cd "$repo" && PATH="$fakebin:$PATH" "$ROOT/bin/fm-no-mistakes-pr-target-guard.sh" >"$out" 2>"$err")
}

test_accepts_captain_fork_origin_and_gate() {
  local repo="$TMP_ROOT/pass" out="$TMP_ROOT/pass.out" err="$TMP_ROOT/pass.err"
  make_repo "$repo" "https://github.com/JTInventory/firstmate"
  add_gate_remote "$repo" "git@github.com:JTInventory/firstmate.git"

  run_guard "$repo" "$out" "$err" || fail "guard rejected the captain fork target: $(cat "$err")"
  assert_grep "ok: PR target repo jtinventory/firstmate verified" "$out" "guard did not report verified target"
  pass "PR target guard accepts captain fork origin and no-mistakes gate"
}

test_accepts_controlled_fork_origin_fetch_with_safe_delivery_proof() {
  local repo="$TMP_ROOT/controlled-pass" fakebin out="$TMP_ROOT/controlled-pass.out" err="$TMP_ROOT/controlled-pass.err"
  make_repo "$repo" "https://github.com/kunchenguid/firstmate"
  git -C "$repo" remote add fork "https://github.com/JTInventory/firstmate"
  git -C "$repo" remote set-url --push origin "https://github.com/JTInventory/firstmate"
  set_branch_tracking "$repo" main fork refs/heads/main
  add_gate_remote "$repo" "git@github.com:JTInventory/firstmate.git"
  fakebin=$(status_fakebin controlled-pass "https://github.com/JTInventory/firstmate")

  run_guard_with_fakebin "$repo" "$fakebin" "$out" "$err" || fail "guard rejected controlled-fork target proof: $(cat "$err")"
  assert_grep "ok: PR target repo jtinventory/firstmate verified" "$out" "guard did not report verified controlled-fork target"
  pass "PR target guard accepts controlled fork with safe delivery proof"
}

test_rejects_controlled_fork_origin_fetch_without_safe_origin_push() {
  local repo="$TMP_ROOT/controlled-missing-push" fakebin out="$TMP_ROOT/controlled-missing-push.out" err="$TMP_ROOT/controlled-missing-push.err"
  make_repo "$repo" "https://github.com/kunchenguid/firstmate"
  git -C "$repo" remote add fork "https://github.com/JTInventory/firstmate"
  set_branch_tracking "$repo" main fork refs/heads/main
  add_gate_remote "$repo" "git@github.com:JTInventory/firstmate.git"
  fakebin=$(status_fakebin controlled-missing-push "https://github.com/JTInventory/firstmate")

  if run_guard_with_fakebin "$repo" "$fakebin" "$out" "$err"; then
    fail "guard accepted controlled-fork shape without safe origin push target"
  fi
  assert_grep "blocked: direct origin push would target upstream remote.origin.pushurl=https://github.com/kunchenguid/firstmate" "$err" \
    "guard did not explain direct origin push hazard"
  pass "PR target guard rejects controlled fork without safe origin push target"
}

test_rejects_parent_origin_target() {
  local repo="$TMP_ROOT/parent-origin" out="$TMP_ROOT/parent-origin.out" err="$TMP_ROOT/parent-origin.err"
  make_repo "$repo" "https://github.com/kunchenguid/firstmate"

  if run_guard "$repo" "$out" "$err"; then
    fail "guard accepted parent origin target"
  fi
  assert_grep "blocked: remote.origin.url=https://github.com/kunchenguid/firstmate is upstream without controlled-fork proof" "$err" \
    "guard did not explain parent origin target"
  pass "PR target guard rejects parent origin target"
}

test_rejects_parent_origin_target_when_branch_tracks_upstream() {
  local repo="$TMP_ROOT/parent-branch-origin" fakebin out="$TMP_ROOT/parent-branch-origin.out" err="$TMP_ROOT/parent-branch-origin.err"
  make_repo "$repo" "https://github.com/kunchenguid/firstmate"
  git -C "$repo" remote add fork "https://github.com/JTInventory/firstmate"
  git -C "$repo" remote set-url --push origin "https://github.com/JTInventory/firstmate"
  set_branch_tracking "$repo" main origin refs/heads/main
  add_gate_remote "$repo" "git@github.com:JTInventory/firstmate.git"
  fakebin=$(status_fakebin parent-branch-origin "https://github.com/JTInventory/firstmate")

  if run_guard_with_fakebin "$repo" "$fakebin" "$out" "$err"; then
    fail "guard accepted upstream branch remote without controlled-fork proof"
  fi
  assert_grep "blocked: remote.origin.url=https://github.com/kunchenguid/firstmate is upstream without controlled-fork proof" "$err" \
    "guard did not explain upstream branch remote proof failure"
  pass "PR target guard rejects upstream branch remote without controlled-fork proof"
}

test_rejects_parent_second_origin_target() {
  local repo="$TMP_ROOT/parent-second-origin" out="$TMP_ROOT/parent-second-origin.out" err="$TMP_ROOT/parent-second-origin.err"
  make_repo "$repo" "https://github.com/JTInventory/firstmate"
  git -C "$repo" remote set-url --add origin "https://github.com/kunchenguid/firstmate"

  if run_guard "$repo" "$out" "$err"; then
    fail "guard accepted parent second origin target"
  fi
  assert_grep "blocked: remote.origin.url=https://github.com/kunchenguid/firstmate is upstream without controlled-fork proof" "$err" \
    "guard did not explain parent second origin target"
  pass "PR target guard rejects parent second origin target"
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

test_rejects_parent_second_pushurl_target() {
  local repo="$TMP_ROOT/parent-second-pushurl" out="$TMP_ROOT/parent-second-pushurl.out" err="$TMP_ROOT/parent-second-pushurl.err"
  make_repo "$repo" "https://github.com/JTInventory/firstmate"
  git -C "$repo" remote set-url --push origin "https://github.com/JTInventory/firstmate"
  git -C "$repo" remote set-url --add --push origin "https://github.com/kunchenguid/firstmate"

  if run_guard "$repo" "$out" "$err"; then
    fail "guard accepted parent second push URL target"
  fi
  assert_grep "blocked: would target upstream remote.origin.pushurl=https://github.com/kunchenguid/firstmate" "$err" \
    "guard did not explain parent second push URL target"
  pass "PR target guard rejects parent second origin push URL target"
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

test_rejects_parent_second_no_mistakes_gate_target() {
  local repo="$TMP_ROOT/parent-second-gate" out="$TMP_ROOT/parent-second-gate.out" err="$TMP_ROOT/parent-second-gate.err" gate
  make_repo "$repo" "https://github.com/JTInventory/firstmate"
  add_gate_remote "$repo" "https://github.com/JTInventory/firstmate"
  gate=$(git -C "$repo" remote get-url no-mistakes)
  git --git-dir="$gate" config --add remote.origin.url "https://github.com/kunchenguid/firstmate"

  if run_guard "$repo" "$out" "$err"; then
    fail "guard accepted parent second no-mistakes gate target"
  fi
  assert_grep "blocked: would target upstream no-mistakes gate remote.origin.url=https://github.com/kunchenguid/firstmate" "$err" \
    "guard did not explain parent second no-mistakes gate target"
  pass "PR target guard rejects parent second no-mistakes gate target"
}

test_rejects_local_no_mistakes_gate_without_target() {
  local repo="$TMP_ROOT/gate-without-target" gate="$TMP_ROOT/gate-without-target.git" out="$TMP_ROOT/gate-without-target.out" err="$TMP_ROOT/gate-without-target.err"
  make_repo "$repo" "https://github.com/JTInventory/firstmate"
  git init --bare -q "$gate"
  git -C "$repo" remote add no-mistakes "$gate"

  if run_guard "$repo" "$out" "$err"; then
    fail "guard accepted local no-mistakes gate without target"
  fi
  assert_grep "blocked: cannot verify PR target no-mistakes gate=$gate because remote.origin.url and remote.origin.pushurl are missing" "$err" \
    "guard did not explain missing local no-mistakes gate target"
  pass "PR target guard rejects local no-mistakes gate without target"
}

test_accepts_captain_fork_nonlocal_no_mistakes_remote() {
  local repo="$TMP_ROOT/pass-nonlocal-no-mistakes" out="$TMP_ROOT/pass-nonlocal-no-mistakes.out" err="$TMP_ROOT/pass-nonlocal-no-mistakes.err"
  make_repo "$repo" "https://github.com/JTInventory/firstmate"
  git -C "$repo" remote add no-mistakes "git@github.com:JTInventory/firstmate.git"

  run_guard "$repo" "$out" "$err" || fail "guard rejected captain fork no-mistakes remote: $(cat "$err")"
  assert_grep "ok: PR target repo jtinventory/firstmate verified" "$out" "guard did not report verified nonlocal no-mistakes target"
  pass "PR target guard accepts captain fork nonlocal no-mistakes remote"
}

test_rejects_parent_nonlocal_no_mistakes_remote() {
  local repo="$TMP_ROOT/parent-nonlocal-no-mistakes" out="$TMP_ROOT/parent-nonlocal-no-mistakes.out" err="$TMP_ROOT/parent-nonlocal-no-mistakes.err"
  make_repo "$repo" "https://github.com/JTInventory/firstmate"
  git -C "$repo" remote add no-mistakes "https://github.com/kunchenguid/firstmate"

  if run_guard "$repo" "$out" "$err"; then
    fail "guard accepted parent nonlocal no-mistakes remote"
  fi
  assert_grep "blocked: would target upstream remote.no-mistakes.url=https://github.com/kunchenguid/firstmate" "$err" \
    "guard did not explain parent nonlocal no-mistakes remote"
  pass "PR target guard rejects parent nonlocal no-mistakes remote"
}

test_rejects_parent_nonlocal_no_mistakes_pushurl() {
  local repo="$TMP_ROOT/parent-nonlocal-no-mistakes-pushurl" out="$TMP_ROOT/parent-nonlocal-no-mistakes-pushurl.out" err="$TMP_ROOT/parent-nonlocal-no-mistakes-pushurl.err"
  make_repo "$repo" "https://github.com/JTInventory/firstmate"
  git -C "$repo" remote add no-mistakes "https://github.com/JTInventory/firstmate"
  git -C "$repo" remote set-url --push no-mistakes "https://github.com/JTInventory/firstmate"
  git -C "$repo" remote set-url --add --push no-mistakes "https://github.com/kunchenguid/firstmate"

  if run_guard "$repo" "$out" "$err"; then
    fail "guard accepted parent nonlocal no-mistakes push URL"
  fi
  assert_grep "blocked: would target upstream remote.no-mistakes.pushurl=https://github.com/kunchenguid/firstmate" "$err" \
    "guard did not explain parent nonlocal no-mistakes push URL"
  pass "PR target guard rejects parent nonlocal no-mistakes push URL"
}

test_rejects_expected_target_override_to_parent() {
  local repo="$TMP_ROOT/parent-expected-override" out="$TMP_ROOT/parent-expected-override.out" err="$TMP_ROOT/parent-expected-override.err"
  make_repo "$repo" "https://github.com/kunchenguid/firstmate"

  if (cd "$repo" && FM_FIRSTMATE_PR_TARGET_REPO="kunchenguid/firstmate" "$ROOT/bin/fm-no-mistakes-pr-target-guard.sh" >"$out" 2>"$err"); then
    fail "guard accepted parent target through expected repo override"
  fi
  assert_grep "blocked: unsupported expected PR target kunchenguid/firstmate, only jtinventory/firstmate is allowed" "$err" \
    "guard did not explain expected target override"
  pass "PR target guard rejects parent expected target override"
}

test_rejects_expected_target_argument_to_parent() {
  local repo="$TMP_ROOT/parent-expected-argument" out="$TMP_ROOT/parent-expected-argument.out" err="$TMP_ROOT/parent-expected-argument.err"
  make_repo "$repo" "https://github.com/kunchenguid/firstmate"

  if (cd "$repo" && "$ROOT/bin/fm-no-mistakes-pr-target-guard.sh" "kunchenguid/firstmate" >"$out" 2>"$err"); then
    fail "guard accepted parent target through expected repo argument"
  fi
  assert_grep "blocked: unsupported expected PR target kunchenguid/firstmate, only jtinventory/firstmate is allowed" "$err" \
    "guard did not explain expected target argument"
  pass "PR target guard rejects parent expected target argument"
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

test_rejects_parent_no_mistakes_status_in_controlled_fork() {
  local repo="$TMP_ROOT/controlled-parent-status" fakebin out="$TMP_ROOT/controlled-parent-status.out" err="$TMP_ROOT/controlled-parent-status.err"
  make_repo "$repo" "https://github.com/kunchenguid/firstmate"
  git -C "$repo" remote add fork "https://github.com/JTInventory/firstmate"
  git -C "$repo" remote set-url --push origin "https://github.com/JTInventory/firstmate"
  set_branch_tracking "$repo" main fork refs/heads/main
  add_gate_remote "$repo" "git@github.com:JTInventory/firstmate.git"
  fakebin=$(status_fakebin controlled-parent-status "https://github.com/kunchenguid/firstmate")

  if run_guard_with_fakebin "$repo" "$fakebin" "$out" "$err"; then
    fail "guard accepted parent no-mistakes status target in controlled fork"
  fi
  assert_grep "blocked: would target upstream no-mistakes status remote=https://github.com/kunchenguid/firstmate" "$err" \
    "guard did not explain parent no-mistakes status target in controlled fork"
  pass "PR target guard rejects parent no-mistakes status in controlled fork"
}

test_accepts_captain_fork_origin_and_gate
test_accepts_controlled_fork_origin_fetch_with_safe_delivery_proof
test_rejects_controlled_fork_origin_fetch_without_safe_origin_push
test_rejects_parent_origin_target
test_rejects_parent_origin_target_when_branch_tracks_upstream
test_rejects_parent_second_origin_target
test_rejects_parent_pushurl_target
test_rejects_parent_second_pushurl_target
test_rejects_parent_no_mistakes_gate_target
test_rejects_parent_second_no_mistakes_gate_target
test_rejects_local_no_mistakes_gate_without_target
test_accepts_captain_fork_nonlocal_no_mistakes_remote
test_rejects_parent_nonlocal_no_mistakes_remote
test_rejects_parent_nonlocal_no_mistakes_pushurl
test_rejects_expected_target_override_to_parent
test_rejects_expected_target_argument_to_parent
test_rejects_parent_no_mistakes_status_target
test_rejects_parent_no_mistakes_status_in_controlled_fork
