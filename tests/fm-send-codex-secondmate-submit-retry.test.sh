#!/usr/bin/env bash
# fm-send delayed submit retry for marked Codex secondmate text.
#
# PR29 made marked Codex secondmate text wait longer before the first Enter, but
# the recurring live failure showed the text could still remain in the composer
# after the generic fast Enter retries. A later manual `tmux send-keys ... Enter`
# submitted that already-typed text. These tests pin the narrow follow-up:
# only marked Codex secondmate sends get one delayed final Enter after the normal
# retry loop reports pending. Crewmates and non-Codex secondmates keep the shared
# generic retry behavior.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-codex-sm-submit-retry)

make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" > "$FM_SEND_LOG"
      exit 0
    fi
    if [ "${1:-}" = Enter ]; then
      count=0
      [ -f "$FM_ENTER_COUNT" ] && count=$(cat "$FM_ENTER_COUNT")
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_ENTER_COUNT"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '0\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    count=0
    [ -f "$FM_ENTER_COUNT" ] && count=$(cat "$FM_ENTER_COUNT")
    if [ "$count" -ge "${FM_EMPTY_AFTER_ENTER:-1}" ]; then
      printf '\xe2\x94\x82 \xe2\x94\x82\n'
    else
      printf '\xe2\x94\x82 pending typed text \xe2\x94\x82\n'
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$FM_SLEEP_LOG"
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_case() {  # <name> <harness> <kind> -> echoes dir
  local name=$1 harness=$2 kind=$3 dir home
  dir="$TMP_ROOT/$name-$RANDOM"
  home="$dir/home"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/target.meta" \
    "window=sess:fm-target" \
    "harness=$harness" \
    "kind=$kind"
  printf '%s\n' "$dir"
}

run_send() {  # <dir> <empty-after-enter> -- <args...>
  local dir=$1 empty_after=$2 fb home log enters sleeps err rc
  shift 2
  fb=$(make_stubs "$dir")
  home="$dir/home"
  log="$dir/send.log"
  enters="$dir/enter.count"
  sleeps="$dir/sleep.log"
  err="$dir/stderr.log"
  : > "$log"; : > "$sleeps"; : > "$err"; printf '0\n' > "$enters"
  env PATH="$fb:$PATH" \
    FM_ROOT_OVERRIDE="$home" FM_HOME="$home" \
    FM_SEND_LOG="$log" FM_ENTER_COUNT="$enters" FM_SLEEP_LOG="$sleeps" \
    FM_EMPTY_AFTER_ENTER="$empty_after" \
    FM_SEND_RETRIES=3 FM_SEND_SLEEP=0.4 FM_SEND_SETTLE=0 \
    "$SEND" "$@" 2>"$err"; rc=$?
  printf '%s\n' "$rc"
}

test_codex_secondmate_gets_delayed_final_enter() {
  local dir rc got count
  dir=$(setup_case codex-sm codex secondmate)
  rc=$(run_send "$dir" 4 fm-target "check the queue")
  expect_code 0 "$rc" "codex secondmate should submit on delayed final Enter"
  count=$(cat "$dir/enter.count")
  [ "$count" = 4 ] || fail "codex secondmate: expected 4 Enter attempts, got $count"
  got=$(cat "$dir/send.log")
  case "$got" in
    "$FM_FROMFIRST_MARK"check\ the\ queue) : ;;
    *) fail "codex secondmate: expected marker+text"$'\n'"--- bytes ---"$'\n'"$(printf '%s' "$got" | od -An -c)" ;;
  esac
  assert_contains "$(cat "$dir/sleep.log")" "1.2" "codex secondmate delayed retry should sleep before the final Enter"
  pass "fm-send: marked Codex secondmate text gets one delayed final Enter"
}

test_codex_crewmate_keeps_generic_retry_behavior() {
  local dir rc count
  dir=$(setup_case codex-crew codex ship)
  rc=$(run_send "$dir" 4 fm-target "check the queue")
  expect_code 1 "$rc" "codex crewmate should not get secondmate-only delayed retry"
  count=$(cat "$dir/enter.count")
  [ "$count" = 3 ] || fail "codex crewmate: expected 3 generic Enter attempts, got $count"
  assert_contains "$(cat "$dir/stderr.log")" "Enter swallowed" "codex crewmate pending composer should still fail"
  pass "fm-send: Codex crewmates keep the generic submit retry behavior"
}

test_non_codex_secondmate_keeps_generic_retry_behavior() {
  local dir rc count
  dir=$(setup_case claude-sm claude secondmate)
  rc=$(run_send "$dir" 4 fm-target "check the queue")
  expect_code 1 "$rc" "non-Codex secondmate should not get Codex-only delayed retry"
  count=$(cat "$dir/enter.count")
  [ "$count" = 3 ] || fail "non-Codex secondmate: expected 3 generic Enter attempts, got $count"
  assert_contains "$(cat "$dir/stderr.log")" "Enter swallowed" "non-Codex secondmate pending composer should still fail"
  pass "fm-send: non-Codex secondmates keep the generic submit retry behavior"
}

test_codex_secondmate_gets_delayed_final_enter
test_codex_crewmate_keeps_generic_retry_behavior
test_non_codex_secondmate_keeps_generic_retry_behavior
