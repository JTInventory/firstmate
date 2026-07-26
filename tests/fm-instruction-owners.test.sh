#!/usr/bin/env bash
# Contract coverage for instruction ownership in AGENTS.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AGENTS="$ROOT/AGENTS.md"
TMP_ROOT=$(fm_test_tmproot fm-instruction-owners)

for phrase in \
  'consult existing reports and established evidence' \
  'remaining bounded research inside it' \
  'unresolved uncertainty could materially change whether or what to build' \
  'relay it without a design-only scout' \
  'ask one concise implementation question when useful' \
  'never both present a likely-enough solution' \
  'overlap as a risk signal rather than an automatic reason to wait' \
  'independently implemented and validated' \
  'selected delivery path can reconcile ordinary rebases or conflicts' \
  'Serialize only for a true semantic dependency' \
  'shared mutable external state' \
  'incompatible concurrent migration' \
  'same-file editing alone is insufficient' \
  'genuine blockers remain durable'; do
  assert_grep "$phrase" "$AGENTS" "intake contract lost '$phrase'"
done

assert_grep 'dispatch isolated work immediately with no concurrency cap' "$AGENTS" \
  "intake contract lost unbounded safe parallel dispatch"
assert_grep 'captain explicitly requests a separate knowledge or design deliverable' "$AGENTS" \
  "intake contract lost captain-requested separate scouts"
assert_grep 'captain wants it shipped, promote the task in place' "$AGENTS" \
  "intake contract lost genuine scout promotion"
assert_grep 'the same crewmate owns direct-PR reconciliation' "$AGENTS" \
  "direct-PR conflict reconciliation lost its owner"
assert_grep 'after any reconciliation, rerun `fm-pr-check`' "$AGENTS" \
  "direct-PR reconciliation lost readiness verification"

for legacy_phrase in \
  'load `diagnostic-reasoning`' \
  'that is a scout task; dispatch it instead of doing the digging yourself' \
  '**Blocked:** touches the same files or subsystem' \
  'same repo plus overlapping area means serialize'; do
  if grep -Fq -- "$legacy_phrase" "$AGENTS"; then
    fail "legacy intake contract restored '$legacy_phrase'"
  fi
done

BRIEF_HOME="$TMP_ROOT/direct-pr-home"
mkdir -p "$BRIEF_HOME/data" "$BRIEF_HOME/state"
printf '%s\n' '- direct-project [direct-PR] - direct PR fixture (added 2026-07-26)' > "$BRIEF_HOME/data/projects.md"
FM_HOME="$BRIEF_HOME" "$ROOT/bin/fm-brief.sh" parallel-direct-pr direct-project >/dev/null \
  || fail "direct-PR brief scaffold failed"
DIRECT_PR_BRIEF="$BRIEF_HOME/data/parallel-direct-pr/brief.md"
PRE_PR_PATH=$(sed -n '/^Before initial direct-PR publication:/,/^If firstmate later tells you that parallel work made the open PR conflict/p' "$DIRECT_PR_BRIEF" | sed '$d')
POST_CONFLICT_PATH=$(sed -n '/^If firstmate later tells you that parallel work made the open PR conflict, you still own reconciliation:/,/^After opening or reconciling the PR/p' "$DIRECT_PR_BRIEF" | sed '$d')
for path_name in PRE_PR_PATH POST_CONFLICT_PATH; do
  path=${!path_name}
  assert_contains "$path" 'Resolve `DEFAULT` from `refs/remotes/origin/HEAD`' \
    "$path_name lost DEFAULT initialization"
  assert_contains "$path" 'set `FEATURE_REF=refs/heads/fm/parallel-direct-pr`' \
    "$path_name lost FEATURE_REF initialization"
  assert_contains "$path" 'git fetch origin "+refs/heads/$DEFAULT:refs/remotes/origin/$DEFAULT"' \
    "$path_name lost explicit default-ref fetch"
  assert_contains "$path" 'git ls-remote --exit-code origin "$FEATURE_REF"' \
    "$path_name lost remote feature lookup guard"
  assert_contains "$path" 'git fetch origin "+$FEATURE_REF:refs/remotes/origin/fm/parallel-direct-pr"' \
    "$path_name lost explicit feature-ref fetch"
  assert_contains "$path" 'EXPECTED=$(git rev-parse refs/remotes/origin/fm/parallel-direct-pr)' \
    "$path_name lost fetched feature OID snapshot"
  assert_contains "$path" 'git merge-base --is-ancestor "$EXPECTED" HEAD' \
    "$path_name lost feature-history ancestry guard"
  assert_contains "$path" 'blocked: remote feature branch diverged; refusing to overwrite remote-only commits' \
    "$path_name lost feature-history divergence blocker"
  assert_contains "$path" 'Rebase onto `origin/$DEFAULT` and resolve ordinary conflicts' \
    "$path_name lost conflict resolution"
  assert_contains "$path" 'git push --force-with-lease="$FEATURE_REF:$EXPECTED" origin "HEAD:$FEATURE_REF"' \
    "$path_name lost explicit lease and push refspec"
done
assert_contains "$PRE_PR_PATH" '0 means the feature ref exists, 2 means it is absent, and any other status is a lookup failure' \
  "pre-PR path lost distinct feature lookup outcomes"
assert_contains "$POST_CONFLICT_PATH" 'require exit 0; exit 2 means the published feature ref is missing, and any other status is a lookup failure' \
  "post-conflict path lost published feature lookup guard"
DONE_SIGNAL_COUNT=$(grep -Fc 'append `done: PR {url}`' "$DIRECT_PR_BRIEF")
[ "$DONE_SIGNAL_COUNT" -eq 1 ] \
  || fail "generated direct-PR brief must emit one completion signal"

pass "intake reuses evidence, reserves scouts for uncertainty, and parallelizes safe work"
