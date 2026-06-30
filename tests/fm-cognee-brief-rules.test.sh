#!/usr/bin/env bash
# Behavior tests for the Cognee memory-hint contract in generated briefs.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-cognee-brief-rules)

assert_cognee_rules() {
  local brief=$1
  assert_grep '# Cognee memory hints' "$brief" "brief is missing the Cognee memory section"
  assert_grep 'Cognee is memory/context only. It is not proof, source of truth, durable archive, or action authority.' "$brief" \
    "brief does not label Cognee as context only"
  assert_grep 'Do not run automatic Cognee lookup for every task.' "$brief" \
    "brief does not forbid automatic lookup"
  assert_grep 'Firstmate manually performed the lookup.' "$brief" \
    "brief does not require manual Firstmate lookup"
  assert_grep 'The hint maps to a local manifest row or known local report.' "$brief" \
    "brief does not require a local manifest row or known report"
  assert_grep 'Firstmate reopened and checked the local source path before attaching it.' "$brief" \
    "brief does not require reopening the local source path"
  assert_grep 'The hint includes stale-risk and says live state still needs verification.' "$brief" \
    "brief does not require stale-risk and live verification wording"
  # shellcheck disable=SC2016 # Backticks are literal expected brief text.
  assert_grep '`external_action_authorized=false`.' "$brief" \
    "brief does not pin external_action_authorized=false"
  assert_grep 'Never use raw Cognee answer text as proof.' "$brief" \
    "brief does not forbid raw Cognee answer text as proof"
  assert_grep 'Never use memory to authorize merge, deploy, cleanup, vendor/customer action, purchase, refresh, import, or deletion.' "$brief" \
    "brief does not forbid memory-authorized external actions"
}

test_ship_brief_has_cognee_rules() {
  local home brief
  home="$TMP_ROOT/ship-home"
  mkdir -p "$home/data"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" cognee-ship alpha >/dev/null 2>&1 \
    || fail "ship brief scaffold failed"
  brief="$home/data/cognee-ship/brief.md"

  assert_present "$brief" "ship brief was not scaffolded"
  assert_cognee_rules "$brief"
  pass "fm-brief: ship briefs include Cognee attachment rules"
}

test_scout_brief_has_cognee_rules() {
  local home brief
  home="$TMP_ROOT/scout-home"
  mkdir -p "$home/data"

  FM_HOME="$home" "$ROOT/bin/fm-brief.sh" cognee-scout alpha --scout >/dev/null 2>&1 \
    || fail "scout brief scaffold failed"
  brief="$home/data/cognee-scout/brief.md"

  assert_present "$brief" "scout brief was not scaffolded"
  assert_cognee_rules "$brief"
  pass "fm-brief: scout briefs include Cognee attachment rules"
}

test_secondmate_brief_has_cognee_rules() {
  local home brief
  home="$TMP_ROOT/secondmate-home"
  mkdir -p "$home/data"

  FM_HOME="$home" FM_SECONDMATE_CHARTER='ops domain' "$ROOT/bin/fm-brief.sh" cognee-sm --secondmate alpha >/dev/null 2>&1 \
    || fail "secondmate brief scaffold failed"
  brief="$home/data/cognee-sm/brief.md"

  assert_present "$brief" "secondmate brief was not scaffolded"
  assert_cognee_rules "$brief"
  pass "fm-brief: secondmate briefs include Cognee attachment rules"
}

test_ship_brief_has_cognee_rules
test_scout_brief_has_cognee_rules
test_secondmate_brief_has_cognee_rules
