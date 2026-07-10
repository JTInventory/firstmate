#!/usr/bin/env bash
# Behavior tests for bin/fm-route.sh deterministic route decisions.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTE="$ROOT/bin/fm-route.sh"

run_route() {
  "$ROUTE" route-test alpha "$@" 2>&1
}

route_profile() {
  printf '%s\n' "$1" | awk -F= '$1=="profile"{print $2; exit}'
}

route_model() {
  printf '%s\n' "$1" | awk -F= '$1=="model"{print $2; exit}'
}

assert_profile() {
  local expected=$1 text=$2 out profile
  out=$(run_route --task-file "$text") || fail "route failed for $expected: $out"
  profile=$(route_profile "$out")
  [ "$profile" = "$expected" ] || fail "expected profile $expected, got $profile"$'\n'"$out"
}

assert_route_model() {
  local expected_profile=$1 expected_model=$2 text=$3 out profile model
  out=$(run_route --task-file "$text") || fail "route failed for $expected_profile/$expected_model: $out"
  profile=$(route_profile "$out")
  model=$(route_model "$out")
  [ "$profile" = "$expected_profile" ] || fail "expected profile $expected_profile, got $profile"$'\n'"$out"
  [ "$model" = "$expected_model" ] || fail "expected model $expected_model for $expected_profile, got $model"$'\n'"$out"
}

assert_profile_one_of() {
  local allowed=$1 text=$2 out profile
  out=$(run_route --task-file "$text") || fail "route failed for $allowed: $out"
  profile=$(route_profile "$out")
  case " $allowed " in
    *" $profile "*) : ;;
    *) fail "expected one of [$allowed], got $profile"$'\n'"$out" ;;
  esac
}

write_task() {
  local dir=$1 name=$2 body=$3 file
  file="$dir/$name.txt"
  printf '%s\n' "$body" > "$file"
  printf '%s\n' "$file"
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-route.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

prod=$(write_task "$tmp" prod 'Investigate production refresh on the 4187 follow-main serve lane.')
assert_profile critical "$prod"
pass "production refresh routes critical"
assert_route_model critical gpt-5.6-sol "$prod"
pass "critical route uses GPT-5.6 Sol"

auth=$(write_task "$tmp" auth 'Review Gmail auth token handling for mailbox proof.')
assert_profile critical "$auth"
pass "Gmail/auth/token routes critical"

money=$(write_task "$tmp" money 'Audit PPC, SellerSnap, and repricing budget behavior.')
assert_profile critical "$money"
pass "PPC/SellerSnap/repricing routes critical"

sec=$(write_task "$tmp" security 'Triage security vulnerability and PII exposure risk.')
assert_profile critical "$sec"
pass "security/vulnerability routes critical"

git_danger=$(write_task "$tmp" git-danger 'Plan git reset, force push, merge, delete, and prune cleanup.')
assert_profile critical "$git_danger"
pass "git reset/force/merge/delete/prune routes critical"

git_clean=$(write_task "$tmp" git-clean 'Run git clean on the task worktree.')
assert_profile critical "$git_clean"
pass "git clean routes critical"

docs_typo_cleanup=$(write_task "$tmp" docs-typo-cleanup 'read-only docs typo cleanup')
out=$(run_route --kind scout --task-file "$docs_typo_cleanup") || fail "docs typo cleanup route failed: $out"
profile=$(route_profile "$out")
[ "$profile" = cheap ] || fail "read-only docs typo cleanup should route cheap, got $profile"$'\n'"$out"
model=$(route_model "$out")
[ "$model" = gpt-5.6-luna ] || fail "read-only docs typo cleanup should use GPT-5.6 Luna, got $model"$'\n'"$out"
pass "read-only docs typo cleanup stays cheap"

cleanup_notes=$(write_task "$tmp" cleanup-notes 'cleanup notes')
assert_profile standard "$cleanup_notes"
pass "cleanup notes does not match git clean"

cleaner_wording=$(write_task "$tmp" cleaner-wording 'cleaner wording')
assert_profile standard "$cleaner_wording"
pass "cleaner wording does not match git clean"

out=$("$ROUTE" route-test bin/fm-spawn.sh 2>&1) || fail "Firstmate core route failed: $out"
assert_contains "$out" "profile=critical" "Firstmate core script did not route critical"
assert_contains "$out" "risk_flags=firstmate-core" "Firstmate core script did not record core risk"
pass "Firstmate core safety routes critical"

architecture=$(write_task "$tmp" architecture 'Create an architecture migration plan for the workflow.')
assert_profile deep "$architecture"
pass "architecture/migration routes deep"
assert_route_model deep gpt-5.6-sol "$architecture"
pass "deep route uses GPT-5.6 Sol"

docs_inventory=$(write_task "$tmp" docs 'Read-only docs inventory scout; summarize files only.')
out=$(run_route --kind scout --task-file "$docs_inventory") || fail "docs inventory route failed: $out"
profile=$(route_profile "$out")
case "$profile" in
  cheap|standard) : ;;
  *) fail "read-only docs inventory should be cheap or standard, got $profile"$'\n'"$out" ;;
esac
[ "$profile" != critical ] || fail "read-only docs inventory must not be critical"
pass "read-only docs inventory scout avoids critical"

ambiguous=$(write_task "$tmp" ambiguous 'Figure out what is going on here and make it better.')
assert_profile_one_of "standard deep" "$ambiguous"
pass "unknown ambiguous task is not cheap"
assert_route_model standard gpt-5.6-terra "$ambiguous"
pass "standard route uses GPT-5.6 Terra"

out=$(run_route --profile critical --task-file "$docs_inventory") || fail "manual critical upgrade failed: $out"
assert_contains "$out" "profile=critical" "manual critical upgrade did not set critical"
assert_contains "$out" "override=manual-profile" "manual critical upgrade did not record override"
pass "manual critical upgrade works"

if out=$(run_route --profile cheap --task-file "$prod"); then
  fail "risky cheap downgrade unexpectedly succeeded"$'\n'"$out"
else
  assert_contains "$out" "refusing risky downgrade" "risky cheap downgrade did not explain refusal"
fi
pass "risky cheap downgrade fails without captain override"

out=$(run_route --profile cheap --captain-downgrade-ok --task-file "$prod") \
  || fail "captain-approved risky cheap downgrade failed: $out"
assert_contains "$out" "profile=cheap" "captain-approved downgrade did not set cheap"
assert_contains "$out" "override=captain-downgrade" "captain-approved downgrade did not record override"
pass "risky cheap downgrade succeeds with captain override"

if out=$(run_route --harness unknown --task-file "$docs_inventory"); then
  fail "unknown harness unexpectedly succeeded"$'\n'"$out"
else
  assert_contains "$out" "unknown harness" "unknown harness failure was unclear"
fi
pass "unknown harness fails"

out=$(run_route --explain --task-file "$prod") || fail "explain route failed: $out"
assert_contains "$out" "route: critical because" "explain output missing route line"
pass "--explain prints captain-facing route line"
