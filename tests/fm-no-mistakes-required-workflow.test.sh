#!/usr/bin/env bash
# Behavior guard for the Require no-mistakes workflow source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

workflow="$ROOT/.github/workflows/no-mistakes-required.yml"

assert_grep "pull-requests: read" "$workflow" \
  "Require no-mistakes workflow cannot read the live PR body"
assert_grep "GH_TOKEN: \${{ github.token }}" "$workflow" \
  "Require no-mistakes workflow does not pass a GitHub token to gh"
assert_grep "gh api \"repos/\${GITHUB_REPOSITORY}/pulls/\${PR_NUMBER}\" --jq .body" "$workflow" \
  "Require no-mistakes workflow does not retry against the live PR body"
assert_grep "Found no-mistakes signature in live PR #\${PR_NUMBER} body." "$workflow" \
  "Require no-mistakes workflow does not report live body success"
assert_grep "Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)" "$workflow" \
  "Require no-mistakes workflow lost the no-mistakes marker"

pass "Require no-mistakes workflow retries against live PR body"
