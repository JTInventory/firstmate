#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRESENT="$ROOT/bin/fm-pr-present.sh"
MERGE="$ROOT/bin/fm-pr-merge.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-presented-head.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() { echo "not ok - $*" >&2; exit 1; }
pass() { echo "ok - $*"; }

make_case() {
  local name=$1 head=${2:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa} dir
  dir="$TMP/$name"; mkdir -p "$dir/bin" "$dir/state"
  printf 'branch=codex/task-x1\nworktree=%s\n' "$dir" > "$dir/state/task-x1.meta"
  cat > "$dir/bin/fm-pr-check" <<'SH'
#!/usr/bin/env bash
meta="$FM_STATE_OVERRIDE/$1.meta"
sed '/^pr=/d;/^pr_head=/d' "$meta" > "$meta.tmp"
printf 'pr=%s\npr_head=%s\n' "$2" "$FAKE_HEAD" >> "$meta.tmp"
chmod 0600 "$meta.tmp"
mv "$meta.tmp" "$meta"
SH
  cat > "$dir/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1 $2 $3" = 'api GET /repos/JTInventory/firstmate/pulls/47' ]; then
  head=$(printf '%s' "$FAKE_FORGE_HEAD" | base64 | tr -d '\n')
  base_ref=$(printf '%s' "${FAKE_FORGE_BASE_REF:-main}" | base64 | tr -d '\n')
  base=$(printf '%s' "$FAKE_FORGE_BASE" | base64 | tr -d '\n')
  repo=$(printf '%s' JTInventory/firstmate | base64 | tr -d '\n')
  ref=$(printf '%s' codex/task-x1 | base64 | tr -d '\n')
  printf 'head_b64: %s\nbase_ref_b64: %s\nbase_b64: %s\nhead_repo_b64: %s\nhead_ref_b64: %s\n' \
    "$head" "$base_ref" "$base" "$repo" "$ref"
elif [ "$1 $2 $3" = 'api PUT /repos/JTInventory/firstmate/pulls/47/merge' ]; then
  exit "${FAKE_PUT_FAIL:-0}"
fi
SH
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'direct-gh %s\n' "$*" >> "$GH_LOG"
exit 97
SH
  chmod +x "$dir/bin/fm-pr-check" "$dir/bin/gh-axi" "$dir/bin/gh"
  printf '%s\n' "$head" > "$dir/head"
  printf '%s\n' cccccccccccccccccccccccccccccccccccccccc > "$dir/base"
  printf '%s\n' "$dir"
}

run_present() {
  local dir=$1
  PATH="$dir/bin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_PR_CHECK_BIN="$dir/bin/fm-pr-check" FAKE_HEAD="$(cat "$dir/head")" \
    FAKE_FORGE_HEAD="$(cat "$dir/head")" FAKE_FORGE_BASE="$(cat "$dir/base")" \
    GH_LOG="$dir/gh.log" \
    "$PRESENT" task-x1 https://github.com/JTInventory/firstmate/pull/47
}

run_merge() {
  local dir=$1 approved_head approved_nonce
  shift
  approved_head=${FAKE_APPROVED_HEAD:-$(sed -n 's/^presented_pr_head=//p' "$dir/state/task-x1.pr-presentation")}
  approved_nonce=${FAKE_APPROVED_NONCE:-$(sed -n 's/^presentation_nonce=//p' "$dir/state/task-x1.pr-presentation")}
  PATH="$dir/bin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_PR_CHECK_BIN="$dir/bin/fm-pr-check" FAKE_HEAD="$FAKE_FORGE_HEAD" \
    FAKE_FORGE_BASE="${FAKE_FORGE_BASE:-$(cat "$dir/base")}" \
    FAKE_FORGE_BASE_REF="${FAKE_FORGE_BASE_REF:-main}" \
    FAKE_PUT_FAIL="${FAKE_PUT_FAIL:-0}" GH_LOG="$dir/gh.log" FM_CAPTAIN_APPROVED_MERGE=1 \
    FM_CAPTAIN_APPROVED_PR_HEAD="$approved_head" \
    FM_CAPTAIN_APPROVED_PRESENTATION_NONCE="$approved_nonce" \
    "$MERGE" task-x1 https://github.com/JTInventory/firstmate/pull/47 "$@"
}

test_present_receipt_is_immutable_across_poll_refresh() {
  local dir; dir=$(make_case immutable)
  run_present "$dir" >/dev/null || fail 'presentation failed'
  grep -qxF 'presented_pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$dir/state/task-x1.pr-presentation" || fail 'presented head missing'
  grep -qxF 'presented_pr_base_ref=main' "$dir/state/task-x1.pr-presentation" || fail 'presented base branch missing'
  grep -qxF 'presented_pr_base=cccccccccccccccccccccccccccccccccccccccc' "$dir/state/task-x1.pr-presentation" || fail 'presented base missing'
  grep -Eq '^presentation_nonce=[0-9a-f]{32}$' "$dir/state/task-x1.pr-presentation" || fail 'unique presentation nonce missing'
  FM_STATE_OVERRIDE="$dir/state" FAKE_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    "$dir/bin/fm-pr-check" task-x1 https://github.com/JTInventory/firstmate/pull/47
  grep -qxF 'presented_pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$dir/state/task-x1.pr-presentation" || fail 'ordinary poll rewrote presentation receipt'
  pass 'ordinary PR refresh cannot rewrite the presented head'
}

test_merge_binds_atomic_api_to_presented_head() {
  local dir; dir=$(make_case unchanged)
  run_present "$dir" >/dev/null || fail 'presentation failed'
  FAKE_FORGE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_merge "$dir" >/dev/null || fail 'unchanged head merge failed'
  grep -q '^api PUT /repos/JTInventory/firstmate/pulls/47/merge ' "$dir/gh.log" || fail 'merge API did not use gh-axi with protected fields'
  [ ! -e "$dir/state/task-x1.pr-presentation" ] || fail 'successful merge retained its consumed approval receipt'
  pass 'merge uses the forge atomic expected-head primitive'
}

test_changed_head_invalidates_approval_and_never_calls_put() {
  local dir rc; dir=$(make_case changed)
  run_present "$dir" >/dev/null || fail 'presentation failed'
  set +e
  FAKE_APPROVED_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    FAKE_FORGE_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    run_merge "$dir" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'changed head was accepted'
  ! grep -q '^api PUT ' "$dir/gh.log" || fail 'stale approval reached merge API'
  [ ! -e "$dir/state/task-x1.pr-presentation" ] || fail 'stale presentation receipt was retained'
  pass 'changed head invalidates approval before merge mutation'
}

test_missing_or_malformed_receipt_and_yolo_refuse() {
  local dir rc
  dir=$(make_case missing)
  set +e; FAKE_FORGE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa FM_YOLO=1 run_merge "$dir" >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail 'yolo bypassed missing presentation'
  printf 'version=firstmate-pr-presentation-v2\npr=https://github.com/JTInventory/firstmate/pull/47\npresented_pr_head=bad\n' > "$dir/state/task-x1.pr-presentation"
  chmod 0600 "$dir/state/task-x1.pr-presentation"
  set +e; FAKE_FORGE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_merge "$dir" >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail 'malformed receipt was accepted'
  cat > "$dir/state/task-x1.pr-presentation" <<'EOF'
firstmate-pr-presentation-v1
pr=https://github.com/JTInventory/firstmate/pull/47
presented_pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
  chmod 0600 "$dir/state/task-x1.pr-presentation"
  set +e; FAKE_APPROVED_NONCE=11111111111111111111111111111111 \
    FAKE_FORGE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_merge "$dir" >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -ne 0 ] || fail 'cleanup-only v1 receipt authorized a merge'
  [ ! -e "$dir/gh.log" ] || ! grep -q '^api PUT ' "$dir/gh.log" || fail 'refused receipt reached merge API'
  pass 'missing and malformed receipts fail closed even in yolo mode'
}

test_atomic_forge_rejection_invalidates_approval() {
  local dir rc; dir=$(make_case atomic-race)
  run_present "$dir" >/dev/null || fail 'presentation failed'
  set +e
  FAKE_PUT_FAIL=1 FAKE_FORGE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_merge "$dir" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'forge TOCTOU rejection was accepted'
  grep -q '^api PUT /repos/JTInventory/firstmate/pulls/47/merge ' "$dir/gh.log" || fail 'atomic request omitted presented SHA'
  [ ! -e "$dir/state/task-x1.pr-presentation" ] || fail 'rejected atomic merge retained approval'
  pass 'forge-side head race invalidates approval after atomic rejection'
}

test_approval_is_bound_to_the_presented_head() {
  local dir rc; dir=$(make_case approval-binding)
  run_present "$dir" >/dev/null || fail 'presentation failed'
  set +e
  FAKE_APPROVED_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    FAKE_FORGE_HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    run_merge "$dir" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'approval for a different presentation was accepted'
  [ ! -e "$dir/gh.log" ] || ! grep -q '^api PUT ' "$dir/gh.log" \
    || fail 'mismatched approval reached the merge API'
  grep -qxF 'presented_pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
    "$dir/state/task-x1.pr-presentation" \
    || fail 'mismatched approval invalidated the receipt it did not own'
  pass 'merge approval is bound to the exact presented head'
}

test_approval_is_bound_to_unique_presentation_and_base() {
  local dir old_nonce rc
  dir=$(make_case nonce-base)
  run_present "$dir" >/dev/null || fail 'initial presentation failed'
  old_nonce=$(sed -n 's/^presentation_nonce=//p' "$dir/state/task-x1.pr-presentation")
  run_present "$dir" >/dev/null || fail 'replacement presentation failed'
  set +e
  FAKE_APPROVED_NONCE="$old_nonce" \
    FAKE_FORGE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    run_merge "$dir" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'approval for a replaced presentation was accepted'
  grep -qxF "presentation_nonce=$old_nonce" "$dir/state/task-x1.pr-presentation" \
    && fail 'replacement presentation reused its nonce'

  run_present "$dir" >/dev/null || fail 'base-change presentation failed'
  set +e
  FAKE_FORGE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    FAKE_FORGE_BASE_REF=release \
    run_merge "$dir" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'changed base was accepted'
  ! grep -q '^api PUT ' "$dir/gh.log" \
    || fail 'stale base approval reached merge API'
  pass 'approval binds a unique URL head and base presentation'
}

test_concurrent_presentation_waits_for_receipt_consumption() {
  local dir merge_pid present_pid rc
  dir=$(make_case serialization)
  run_present "$dir" >/dev/null || fail 'presentation failed'
  cat > "$dir/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "$1 $2 $3" = 'api GET /repos/JTInventory/firstmate/pulls/47' ]; then
  head=$(printf '%s' "$FAKE_FORGE_HEAD" | base64 | tr -d '\n')
  base_ref=$(printf '%s' "${FAKE_FORGE_BASE_REF:-main}" | base64 | tr -d '\n')
  base=$(printf '%s' "$FAKE_FORGE_BASE" | base64 | tr -d '\n')
  repo=$(printf '%s' JTInventory/firstmate | base64 | tr -d '\n')
  ref=$(printf '%s' codex/task-x1 | base64 | tr -d '\n')
  printf 'head_b64: %s\nbase_ref_b64: %s\nbase_b64: %s\nhead_repo_b64: %s\nhead_ref_b64: %s\n' \
    "$head" "$base_ref" "$base" "$repo" "$ref"
  if [ -n "${GH_GET_READY:-}" ]; then
    : > "$GH_GET_READY"
    while [ ! -e "$GH_GET_RELEASE" ]; do sleep 0.02; done
  fi
fi
SH
  chmod +x "$dir/bin/gh-axi"
  GH_GET_READY="$dir/get-ready" GH_GET_RELEASE="$dir/get-release" \
    FAKE_FORGE_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa run_merge "$dir" >/dev/null &
  merge_pid=$!
  while [ ! -e "$dir/get-ready" ]; do sleep 0.02; done
  printf '%s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb > "$dir/head"
  run_present "$dir" >"$dir/present.out" &
  present_pid=$!
  sleep 0.1
  kill -0 "$present_pid" 2>/dev/null \
    || fail 'concurrent presentation replaced a receipt while merge owned it'
  : > "$dir/get-release"
  wait "$merge_pid" || fail 'serialized merge failed'
  wait "$present_pid" || fail 'presentation did not continue after merge released receipt'
  grep -qxF 'presented_pr_head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    "$dir/state/task-x1.pr-presentation" \
    || fail 'new presentation was deleted by stale merge invalidation'
  rc=$(grep -c '^api PUT ' "$dir/gh.log")
  [ "$rc" -eq 1 ] || fail 'serialized merge did not issue exactly one mutation'
  pass 'receipt replacement and consumption are serialized'
}

test_presentation_lock_wait_is_bounded_and_terminal_errors_propagate() {
  local rc
  set +e
  FM_PR_PRESENTATION_LOCK_ATTEMPTS=2 bash -c '
    . "$1"
    fm_lock_try_acquire() { return 1; }
    fm_pr_presentation_lock_acquire ignored
  ' bash "$ROOT/bin/fm-pr-lib.sh"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail 'busy presentation lock did not stop after its bounded retry budget'

  set +e
  bash -c '
    . "$1"
    fm_lock_try_acquire() { return 2; }
    fm_pr_presentation_lock_acquire ignored
  ' bash "$ROOT/bin/fm-pr-lib.sh"
  rc=$?
  set -e
  [ "$rc" -eq 2 ] || fail 'unsafe presentation lock result was retried or rewritten'
  pass 'presentation lock waits are bounded and terminal errors propagate'
}

test_gitlab_presentation_remains_unsupported_without_side_effect() {
  local dir rc; dir=$(make_case gitlab)
  set +e
  PATH="$dir/bin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_PR_CHECK_BIN="$dir/bin/fm-pr-check" \
    "$PRESENT" task-x1 https://gitlab.com/group/repo/-/merge_requests/47 >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'GitLab presentation was accepted as GitHub approval proof'
  [ ! -e "$dir/state/task-x1.pr-presentation" ] || fail 'GitLab refusal created a presentation receipt'
  pass 'GitLab polling compatibility is unchanged and presentation stays GitHub-only'
}

test_receipt_inode_swap_is_refused() {
  local dir rc receipt swap
  dir=$(make_case inode-swap)
  receipt="$dir/state/task-x1.pr-presentation"
  swap="$dir/state/swap-receipt"
  cat > "$receipt" <<'EOF'
firstmate-pr-presentation-v2
pr=https://github.com/JTInventory/firstmate/pull/47
presented_pr_head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
presented_pr_base_ref=main
presented_pr_base=cccccccccccccccccccccccccccccccccccccccc
presentation_nonce=11111111111111111111111111111111
EOF
  cat > "$swap" <<'EOF'
firstmate-pr-presentation-v2
pr=https://github.com/JTInventory/firstmate/pull/47
presented_pr_head=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
presented_pr_base_ref=main
presented_pr_base=cccccccccccccccccccccccccccccccccccccccc
presentation_nonce=22222222222222222222222222222222
EOF
  chmod 0600 "$receipt" "$swap"
  set +e
  RECEIPT_FILE="$receipt" SWAP_FILE="$swap" bash -c '
    . "$1"
    fm_pr_private_fd_valid() { mv -f -- "$SWAP_FILE" "$RECEIPT_FILE"; return 0; }
    fm_pr_presentation_parse "$RECEIPT_FILE"
  ' bash "$ROOT/bin/fm-pr-lib.sh" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail 'receipt inode swap was accepted'
  pass 'presentation parsing refuses a stat/open inode swap'
}

test_present_receipt_is_immutable_across_poll_refresh
test_merge_binds_atomic_api_to_presented_head
test_changed_head_invalidates_approval_and_never_calls_put
test_missing_or_malformed_receipt_and_yolo_refuse
test_atomic_forge_rejection_invalidates_approval
test_approval_is_bound_to_the_presented_head
test_approval_is_bound_to_unique_presentation_and_base
test_concurrent_presentation_waits_for_receipt_consumption
test_presentation_lock_wait_is_bounded_and_terminal_errors_propagate
test_gitlab_presentation_remains_unsupported_without_side_effect
test_receipt_inode_swap_is_refused
