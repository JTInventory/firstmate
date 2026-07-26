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
  assert_contains "$path" 'Set `TASK_ID=parallel-direct-pr`, `FEATURE_REF=refs/heads/fm/parallel-direct-pr`, `BRANCH=fm/parallel-direct-pr`' \
    "$path_name lost task, feature, or branch initialization"
  assert_contains "$path" 'Derive `CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD)`' \
    "$path_name lost current symbolic branch derivation"
  assert_contains "$path" 'An attached branch must equal `BRANCH`; a detached `HEAD` is allowed only when `LEASE_CHECKPOINT` exists and step 3 proves an active rebase for the bound branch and base' \
    "$path_name lost bounded detached-HEAD recovery entry"
  assert_contains "$path" 'Otherwise append `blocked: direct-PR requires attached branch fm/parallel-direct-pr` and stop' \
    "$path_name lost initial branch-state blocker"
  assert_contains "$path" '`REPO_ID=$(git rev-parse --path-format=absolute --git-common-dir)`' \
    "$path_name lost repository identity initialization"
  assert_contains "$path" "LEASE_CHECKPOINT='$BRIEF_HOME/state/parallel-direct-pr.direct-pr-lease'" \
    "$path_name lost index-safe task checkpoint location"
  assert_contains "$path" '`LEASE_CHECKPOINT_TMP=$LEASE_CHECKPOINT.tmp.$$`' \
    "$path_name lost atomic temporary checkpoint path"
  assert_contains "$path" 'outside the project worktree and Git index' \
    "$path_name lost index-safe checkpoint contract"
  assert_contains "$path" 'A valid checkpoint must contain exactly `repo=`, `task=`, `feature_ref=`, `branch=`, `workflow=`, `expected=`, `default_oid=`, `pre_head=`, `post_head=`, and `phase=`' \
    "$path_name lost complete checkpoint binding"
  assert_contains "$path" 'Parse it only as data: read exactly one line for each literal key, split each line only at its first `=`, and assign `CHECKPOINT_REPO`, `CHECKPOINT_TASK`, `CHECKPOINT_FEATURE_REF`, `CHECKPOINT_BRANCH`, `CHECKPOINT_WORKFLOW`, `CHECKPOINT_EXPECTED`, `CHECKPOINT_DEFAULT_OID`, `CHECKPOINT_PRE_HEAD`, `CHECKPOINT_POST_HEAD`, and `CHECKPOINT_PHASE`; reject duplicate, missing, unknown, or invalid fields' \
    "$path_name lost safe checkpoint parsing"
  assert_contains "$path" 'Never source or eval checkpoint bytes' \
    "$path_name can execute checkpoint bytes"
  assert_contains "$path" 'After all validation, explicitly hydrate `REPO_ID=$CHECKPOINT_REPO`, `TASK_ID=$CHECKPOINT_TASK`, `FEATURE_REF=$CHECKPOINT_FEATURE_REF`, `BRANCH=$CHECKPOINT_BRANCH`, `WORKFLOW=$CHECKPOINT_WORKFLOW`, `EXPECTED=$CHECKPOINT_EXPECTED`, `DEFAULT_OID=$CHECKPOINT_DEFAULT_OID`, `PRE_HEAD=$CHECKPOINT_PRE_HEAD`, `POST_HEAD=$CHECKPOINT_POST_HEAD`, and `PHASE=$CHECKPOINT_PHASE` before any recovery action' \
    "$path_name lost checkpoint-to-variable hydration"
  assert_contains "$path" 'Fresh-shell rule: never rely on variables surviving a prior agent command call' \
    "$path_name depends on cross-command shell state"
  assert_contains "$path" 'Before every command invocation in steps 2-9, use that same invocation to repeat step 1 identity initialization and, when the checkpoint exists, this complete typed validation and hydration' \
    "$path_name lost per-invocation state hydration"
  assert_contains "$path" 'Before the checkpoint exists, a fresh invocation in steps 4-7 must also replay every earlier state-producing fetch or lookup needed by that step' \
    "$path_name lost pre-checkpoint fresh-shell reconstruction"
  assert_contains "$path" 'Reject a pre-existing checkpoint or temporary target that is a symlink, non-regular file, unexpectedly owned, or malformed by appending `blocked: direct-PR lease checkpoint invalid; refusing recovery` and stop' \
    "$path_name lost fail-closed checkpoint target validation"
  assert_contains "$path" 'Otherwise append `blocked: direct-PR lease checkpoint identity mismatch; refusing recovery` and stop' \
    "$path_name lost fail-closed checkpoint identity validation"
  assert_contains "$path" 'exit 0 supplies the remote OID, exit 2 means no matching ref, and any other status must append `blocked: direct-PR lease recovery lookup failed` and stop' \
    "$path_name lost explicit recovery lookup outcomes"
  assert_contains "$path" 'On recovery, branch on `PHASE` before inspecting `HEAD`, reflogs, or active-rebase metadata' \
    "$path_name lost phase-first recovery ordering"
  assert_contains "$path" 'Only when `PHASE=rebase-in-progress` may recovery inspect active-rebase metadata, `HEAD`, or reflogs' \
    "$path_name permits HEAD or reflog recovery outside rebase-in-progress"
  assert_contains "$path" 'In that rebase-in-progress branch, detect active rebase metadata before remote-movement cleanup' \
    "$path_name lost active-rebase-first recovery ordering"
  assert_contains "$path" 'An active rebase is valid only when metadata records `refs/heads/$BRANCH` as the original branch, `PRE_HEAD` as the original head, and `DEFAULT_OID` as the exact onto target' \
    "$path_name lost active-rebase branch, head, and onto proof"
  assert_contains "$path" 'Git'\''s expected detached `HEAD` is allowed only in that validated state, otherwise append `blocked: active direct-PR rebase metadata mismatch` and stop' \
    "$path_name lost active-rebase metadata blocker"
  assert_contains "$path" 'If the remote moved during that validated active rebase, retain `LEASE_CHECKPOINT` and its bound state, append `blocked: remote feature moved during active direct-PR rebase; checkpoint retained`, and stop without cleanup or restart' \
    "$path_name lost active-rebase remote-movement checkpoint retention"
  assert_contains "$path" 'If the remote moved with no active rebase, remove the validated checkpoint and its task-specific temporary artifacts, then restart safe validation' \
    "$path_name lost bounded non-active remote-movement cleanup"
  assert_contains "$path" 'With no active rebase, require attached `CURRENT_BRANCH == BRANCH`' \
    "$path_name lost attached-state recovery boundary"
  assert_contains "$path" 'When `HEAD == PRE_HEAD`, either atomically persist `PRE_HEAD` as `POST_HEAD` with `PHASE=ready-to-push` for a proven no-op where `DEFAULT_OID` is already an ancestor of `HEAD`, or safely restart `git rebase "$DEFAULT_OID"` and perform the same ready-state rewrite after it completes' \
    "$path_name lost no-active pre-head restart and no-op recovery"
  assert_contains "$path" 'When `HEAD` differs, accept completed rebase recovery only when the latest metadata-bound matching rebase finish is the newest branch reflog entry, that finish result OID equals current `HEAD`, no later branch movement exists, the recorded branch equals `BRANCH`, the matching rebase transition'\''s source OID equals `PRE_HEAD`, the matching rebase start names `DEFAULT_OID`, and `DEFAULT_OID` is an ancestor of `HEAD`' \
    "$path_name lost exact immutable completed-rebase proof"
  assert_contains "$path" 'If the source OID differs from `PRE_HEAD`, the finish result differs from `HEAD`, or any later branch movement exists, append `blocked: completed direct-PR rebase transition mismatch; refusing recovery` and stop' \
    "$path_name lost completed-rebase transition blocker"
  assert_contains "$path" 'Then atomically persist that exact `HEAD` as `POST_HEAD` with `PHASE=ready-to-push`' \
    "$path_name lost recoverable ready-state transition"
  assert_contains "$path" 'If that recovery rewrite fails, remove only the validated task-specific temporary artifact, append `blocked: direct-PR recovered ready checkpoint write failed`, and stop without pushing' \
    "$path_name lost fail-closed recovered ready-state rewrite"
  assert_contains "$path" 'If `PHASE=ready-to-push`, require `WORKFLOW=' \
    "$path_name lost direct ready-state publication branch"
  assert_contains "$path" 'then enter step 9 directly and execute its complete' \
    "$path_name does not route ready state directly to publication"
  assert_contains "$path" 'After any successful ready-state rewrite, start a fresh invocation with the required prelude and enter step 9' \
    "$path_name lost fresh-shell transition after rebase recovery"
  assert_contains "$path" 'Any other detached state or head, workflow, branch, repository, task, ref, or onto mismatch must append `blocked: direct-PR lease checkpoint state mismatch; refusing recovery` and stop' \
    "$path_name lost recovery state and onto mismatch blocker"
  assert_contains "$path" 'Do not rerun pre-rebase ancestry validation against rewritten `HEAD`' \
    "$path_name reruns invalid ancestry checks during recovery"
  assert_contains "$path" 'Set `DEFAULT_OID=$(git rev-parse refs/remotes/origin/$DEFAULT)` and `PRE_HEAD=$(git rev-parse HEAD)`' \
    "$path_name lost default and pre-rebase HEAD snapshots"
  assert_contains "$path" 'derive `CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD)` again, and require `CURRENT_BRANCH == BRANCH`; detached `HEAD` or mismatch must append `blocked: direct-PR branch changed before rebase` and stop' \
    "$path_name lost pre-rebase attached-branch validation"
  assert_contains "$path" 'Atomically write all ten bound fields through `LEASE_CHECKPOINT_TMP` with mode 0600, `workflow=' \
    "$path_name lost durable rebase-in-progress checkpoint"
  assert_contains "$path" 'Set `POST_HEAD=$(git rev-parse HEAD)`' \
    "$path_name lost publication HEAD snapshot"
  assert_contains "$path" 'derive `CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD)` again, and require `CURRENT_BRANCH == BRANCH`; detached `HEAD` or mismatch must append `blocked: direct-PR branch changed after rebase` and stop' \
    "$path_name lost post-rebase attached-branch validation"
  assert_contains "$path" 'preserving `repo=$REPO_ID`, `task=$TASK_ID`, `feature_ref=$FEATURE_REF`, `branch=$BRANCH`, `workflow=$WORKFLOW`, `expected=$EXPECTED`, `default_oid=$DEFAULT_OID`, and `pre_head=$PRE_HEAD`, while setting `post_head=$POST_HEAD` and `phase=ready-to-push`' \
    "$path_name lost ready-to-push identity and HEAD binding"
  assert_contains "$path" 'If this second write or rename fails, remove only the validated task-specific temporary artifact, append `blocked: direct-PR ready checkpoint write failed; recover from rebase-in-progress state`, and stop without pushing' \
    "$path_name lost fail-closed second checkpoint rewrite"
  assert_contains "$path" 'Before pushing, require `WORKFLOW=' \
    "$path_name lost pre-push branch and HEAD validation"
  assert_contains "$path" 'detached `HEAD` or mismatch must append `blocked: direct-PR publication state changed; refusing push` and stop' \
    "$path_name lost fail-closed publication-state validation"
  assert_contains "$path" 'A write or rename failure must remove only the validated task-specific temporary artifact, append `blocked: direct-PR lease checkpoint write failed`, and stop' \
    "$path_name lost atomic-write cleanup and blocker"
  assert_contains "$path" 'remove the validated checkpoint and its task-specific temporary artifacts, then restart safe validation' \
    "$path_name lost confirmed-remote-movement cleanup"
  assert_contains "$path" 'After either push succeeds, remove the validated checkpoint and its task-specific temporary artifacts' \
    "$path_name lost successful-publication checkpoint cleanup"
  assert_contains "$path" 'FEATURE_REF=refs/heads/fm/parallel-direct-pr' \
    "$path_name lost FEATURE_REF initialization"
  assert_contains "$path" 'If the remote still matches, resume only the validated active rebase' \
    "$path_name lost checkpoint remote-match validation"
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
  assert_contains "$path" 'Rebase onto the immutable `DEFAULT_OID` with `git rebase "$DEFAULT_OID"` and resolve ordinary conflicts' \
    "$path_name lost immutable-base conflict resolution"
  assert_contains "$path" 'git push --force-with-lease="$FEATURE_REF:$EXPECTED" origin "$POST_HEAD:$FEATURE_REF"' \
    "$path_name lost immutable publication OID and explicit lease"
  assert_contains "$path" 'retry that identical `git push --force-with-lease="$FEATURE_REF:$EXPECTED" origin "$POST_HEAD:$FEATURE_REF"`' \
    "$path_name lost identical immutable retry"
  assert_contains "$path" 'if the ancestry check fails, append `blocked: remote feature branch diverged; refusing to overwrite remote-only commits` and stop' \
    "$path_name lost fail-closed divergence blocker"
  for unsafe_checkpoint_form in \
    'source "$LEASE_CHECKPOINT"' \
    '. "$LEASE_CHECKPOINT"' \
    'eval "$(cat "$LEASE_CHECKPOINT")"' \
    'eval "$CHECKPOINT'; do
    if grep -Fq -- "$unsafe_checkpoint_form" <<<"$path"; then
      fail "$path_name executes checkpoint bytes with '$unsafe_checkpoint_form'"
    fi
  done
done
assert_contains "$PRE_PR_PATH" 'then enter step 9 directly and execute its complete initial-publication workflow: remote classification, bounded identical retry, lease-rejection cleanup and restart, checkpoint cleanup, PR opening, and the following single terminal completion or blocked status. Never perform only a bare push' \
  'initial ready-state recovery lost the complete publication workflow'
assert_contains "$POST_CONFLICT_PATH" 'then enter step 9 directly and execute its complete post-conflict publication workflow: remote classification, bounded identical retry, lease-rejection cleanup and restart, checkpoint cleanup, open-PR continuation, reconciliation completion, and the following single terminal completion or blocked status. Never perform only a bare push' \
  'post-conflict ready-state recovery lost the complete publication workflow'
assert_contains "$PRE_PR_PATH" '`WORKFLOW=initial-publication`' \
  'initial publication lost workflow initialization'
assert_contains "$PRE_PR_PATH" 'require `CHECKPOINT_WORKFLOW=initial-publication`' \
  'initial recovery accepts another workflow owner'
assert_contains "$PRE_PR_PATH" '`workflow=initial-publication`' \
  'initial checkpoint lost workflow binding'
assert_contains "$PRE_PR_PATH" 'The remote matches only when exit 0 supplies `EXPECTED`, or when exit 2 and `EXPECTED` is empty for this bound initial-publication workflow; every other exit 0 or 2 outcome is confirmed remote movement' \
  'initial recovery lost absent-ref and movement classification'
assert_contains "$POST_CONFLICT_PATH" '`WORKFLOW=post-conflict`' \
  'post-conflict publication lost workflow initialization'
assert_contains "$POST_CONFLICT_PATH" 'require `CHECKPOINT_WORKFLOW=post-conflict`' \
  'post-conflict recovery accepts another workflow owner'
assert_contains "$POST_CONFLICT_PATH" '`workflow=post-conflict`' \
  'post-conflict checkpoint lost workflow binding'
assert_contains "$POST_CONFLICT_PATH" 'For this bound post-conflict workflow, the remote matches only when exit 0 supplies `EXPECTED`; exit 2 is confirmed remote deletion, and any different OID from exit 0 is confirmed remote movement' \
  'post-conflict recovery lost deletion and movement classification'
if grep -Fq -- 'then resume only `git push' "$DIRECT_PR_BRIEF"; then
  fail 'legacy bare-push-only recovery clause remains'
fi
PRE_PR_STEP9=$(printf '%s\n' "$PRE_PR_PATH" | sed -n '/^9\./,$p')
POST_CONFLICT_STEP9=$(printf '%s\n' "$POST_CONFLICT_PATH" | sed -n '/^9\./,$p')
for step_name in PRE_PR_STEP9 POST_CONFLICT_STEP9; do
  step=${!step_name}
  assert_contains "$step" 'derive `CURRENT_BRANCH=$(git symbolic-ref --quiet --short HEAD)` again, and require `CURRENT_BRANCH == BRANCH` and `$(git rev-parse HEAD) == POST_HEAD`; detached `HEAD` or mismatch must append `blocked: direct-PR publication state changed; refusing push` and stop' \
    "$step_name lost publication-state precondition"
  assert_contains "$step" 'exit 0 supplies the remote OID, exit 2 means' \
    "$step_name lost first retry lookup 0/2 outcomes"
  assert_contains "$step" 'any other status must append `blocked: remote feature retry lookup failed` and stop' \
    "$step_name lost first retry lookup failure outcome"
  assert_contains "$step" 'On movement, remove the validated checkpoint and its task-specific temporary artifacts and restart safe validation' \
    "$step_name lost lease-rejection cleanup and restart"
  assert_contains "$step" 'When unchanged, retry that identical `git push --force-with-lease="$FEATURE_REF:$EXPECTED" origin "$POST_HEAD:$FEATURE_REF"`' \
    "$step_name lost unchanged-remote bounded retry"
  assert_contains "$step" 'If the retry fails, run the same lookup once more with the same 0/2/other mapping: on any other status append `blocked: remote feature retry lookup failed` and stop; on confirmed movement remove the validated checkpoint and its task-specific temporary artifacts and restart safe validation; when unchanged, retain the checkpoint, append `blocked: direct-PR publication retry exhausted; checkpoint retained`, and stop' \
    "$step_name lost terminal second-retry outcomes"
  assert_contains "$step" 'After either push succeeds, remove the validated checkpoint and its task-specific temporary artifacts' \
    "$step_name lost successful publication cleanup"
done
assert_contains "$PRE_PR_STEP9" 'Treat the remote as unchanged only when exit 0 supplies `EXPECTED`, or when exit 2 and `EXPECTED` is empty; every other exit 0 or 2 outcome is confirmed remote movement' \
  'initial retry lookup lost absent-ref classification'
assert_contains "$POST_CONFLICT_STEP9" 'Treat the remote as unchanged only when exit 0 supplies `EXPECTED`; a different OID or exit 2 is confirmed remote movement' \
  'post-conflict retry lookup lost deletion classification'
assert_contains "$PRE_PR_STEP9" 'Push with `git push --force-with-lease="$FEATURE_REF:$EXPECTED" origin "$POST_HEAD:$FEATURE_REF"`' \
  "initial publication step lost guarded push"
assert_contains "$PRE_PR_STEP9" 'then open the PR with `gh-axi`' \
  "initial publication step lost post-push PR creation"
assert_contains "$POST_CONFLICT_STEP9" 'Update the open PR with `git push --force-with-lease="$FEATURE_REF:$EXPECTED" origin "$POST_HEAD:$FEATURE_REF"`' \
  "post-conflict publication step lost guarded push"
assert_contains "$POST_CONFLICT_STEP9" 'only then is reconciliation complete' \
  "post-conflict publication step lost completion boundary"
assert_contains "$PRE_PR_PATH" '0 means the feature ref exists, 2 means it is absent, and any other status is a lookup failure' \
  "pre-PR path lost distinct feature lookup outcomes"
assert_contains "$PRE_PR_PATH" 'any other status is a lookup failure that must append `blocked: remote feature lookup failed` and stop' \
  "pre-PR path lost lookup-failure blocker"
assert_contains "$PRE_PR_PATH" 'set `EXPECTED=`' \
  "pre-PR path lost absent-feature lease initialization"
assert_contains "$PRE_PR_PATH" 'After either push succeeds, remove the validated checkpoint and its task-specific temporary artifacts, then open the PR with `gh-axi`' \
  "pre-PR path can open a PR before safe publication"
assert_contains "$POST_CONFLICT_PATH" 'require exit 0; exit 2 means the published feature ref is missing, and any other status is a lookup failure' \
  "post-conflict path lost published feature lookup guard"
assert_contains "$POST_CONFLICT_PATH" 'append `blocked: published remote feature lookup failed` and stop for either case' \
  "post-conflict path lost published-feature blocker"
assert_contains "$POST_CONFLICT_PATH" 'After either push succeeds, remove the validated checkpoint and its task-specific temporary artifacts; only then is reconciliation complete' \
  "post-conflict path can complete before safe publication"
assert_grep "Stay inside this worktree except for the status file and the task-specific Firstmate checkpoint at '$BRIEF_HOME/state/parallel-direct-pr.direct-pr-lease'; modify nothing else outside it." "$DIRECT_PR_BRIEF" \
  "generated direct-PR brief lost its bounded state-path exception"
DONE_SIGNAL_COUNT=$(grep -Fc 'append `done: PR {url}`' "$DIRECT_PR_BRIEF")
[ "$DONE_SIGNAL_COUNT" -eq 1 ] \
  || fail "generated direct-PR brief must emit one completion signal"
assert_grep 'After opening or reconciling the PR, append `done: PR {url}` to the status file and stop.' "$DIRECT_PR_BRIEF" \
  "generated direct-PR brief lost terminal completion boundary"

pass "intake reuses evidence, reserves scouts for uncertainty, and parallelizes safe work"
