#!/usr/bin/env bash
# Unit tests for the shared composer classifier.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$ROOT/bin/fm-composer-lib.sh"

classify() { fm_composer_classify_content "$@"; }

test_bare_shell_prompts_are_unknown() {
  local glyph verdict
  for glyph in '>' '$' '%' '#'; do
    verdict=$(classify 0 "$glyph")
    [ "$verdict" = unknown ] || fail "bare shell glyph '$glyph' was '$verdict'"
  done
}

test_bordered_shell_prompt_is_empty() {
  local glyph verdict
  for glyph in '>' '$' '%' '#'; do
    verdict=$(classify 1 "$glyph")
    [ "$verdict" = empty ] || fail "bordered shell glyph '$glyph' was '$verdict'"
  done
}

test_agent_prompts_and_real_text() {
  [ "$(classify 0 '❯')" = empty ] || fail "bare claude prompt was not empty"
  [ "$(classify 0 '›')" = empty ] || fail "bare codex prompt was not empty"
  [ "$(classify 0 '❯ send this')" = pending ] || fail "typed prompt was not pending"
  [ "$(classify 1 'Type a message...' '^Type a message\.\.\.$')" = empty ] \
    || fail "idle placeholder was not empty"
}

test_bare_shell_prompts_are_unknown
test_bordered_shell_prompt_is_empty
test_agent_prompts_and_real_text
echo "# fm-composer-lib.test.sh: all assertions passed"
