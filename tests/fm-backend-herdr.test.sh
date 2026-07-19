#!/usr/bin/env bash
# Unit coverage for the experimental Herdr session backend.
# Every Herdr call is made through a deterministic fake; no live server is
# required for this suite.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by Herdr)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-herdr-tests)

make_fake_herdr() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_HERDR_LOG:?}
responses=${FM_HERDR_RESPONSES:?}
count_file="$responses/.count"
count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 ))
echo "$count" > "$count_file"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for arg in "$@"; do printf '\x1f%s' "$arg"; done
  printf '\n'
} >> "$log"
if [ -f "$responses/$count.exit" ]; then
  exit "$(cat "$responses/$count.exit")"
fi
[ ! -f "$responses/$count.out" ] || cat "$responses/$count.out"
exit 0
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

herdr_case() {
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/responses"
  : > "$dir/log"
  printf '%s %s %s\n' "$dir" "$dir/log" "$dir/responses"
}

test_selection_and_autodetect() {
  local config="$TMP_ROOT/config"
  mkdir -p "$config"
  FM_BACKEND_CONFIG_DIR="$config"; FM_BACKEND=''; TMUX=''; HERDR_ENV=''
  [ "$(fm_backend_name)" = tmux ] || fail "backend must default to tmux"
  printf 'herdr\n' > "$config/backend"
  [ "$(fm_backend_name)" = herdr ] || fail "config/backend did not select herdr"
  FM_BACKEND=tmux; TMUX=''; HERDR_ENV=1
  [ "$(fm_backend_name)" = tmux ] || fail "FM_BACKEND did not override auto-detect"
  FM_BACKEND_CONFIG_DIR="$TMP_ROOT/no-config"; FM_BACKEND=''; TMUX=''; HERDR_ENV=1
  [ "$(fm_backend_name)" = herdr ] || fail "HERDR_ENV=1 did not auto-detect herdr"
  TMUX=socket; HERDR_ENV=1
  [ "$(fm_backend_name)" = tmux ] || fail "TMUX did not win over nested HERDR_ENV"
  pass "Herdr selection honors explicit config/env and nested TMUX precedence"
}

test_backend_tool_gating() {
  [ "$(fm_backend_required_tools tmux)" = 'tmux treehouse' ] \
    || fail "tmux backend tool contract changed"
  [ "$(fm_backend_required_tools herdr)" = 'herdr jq treehouse' ] \
    || fail "Herdr backend does not require herdr, jq, and treehouse"
  if fm_backend_required_tools orca >/dev/null 2>&1; then
    fail "unsupported backend unexpectedly returned a tool contract"
  fi
  pass "bootstrap backend tool gating keeps Herdr dependencies opt-in"
}

test_version_gate() {
  local lines dir log resp fb out status=0
  read -r dir log resp < <(herdr_case version)
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":14}}' > "$resp/1.out"
  fb=$(make_fake_herdr "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_version_check' "$ROOT" \
    || fail "protocol 14 should pass the Herdr version gate"
  assert_contains "$(cat "$log")" $'HERDR_SESSION=\x1fstatus\x1f--json' "bare version check changed its default invocation"
  assert_not_contains "$(cat "$log")" $'\x1f--session' "bare version check unexpectedly selected a target session"
  rm -f "$resp/1.out" "$resp/.count"
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":14}}' > "$resp/1.out"
  : > "$log"
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_version_check fmtest' "$ROOT" \
    || fail "session-aware protocol 14 should pass the Herdr version gate"
  assert_contains "$(cat "$log")" $'HERDR_SESSION=fmtest\x1fstatus\x1f--json\x1f--session\x1ffmtest' "target version check did not select the target session"
  rm -f "$resp/1.out" "$resp/.count"
  printf '%s\n' '{"client":{"version":"0.7.4foo","protocol":14}}' > "$resp/1.out"
  status=0
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_version_check' "$ROOT" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "suffixed Herdr version was accepted"
  rm -f "$resp/1.out" "$resp/.count"
  printf '%s\n' '{"client":{"version":"0.6.0","protocol":13}}' > "$resp/1.out"
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_version_check' "$ROOT" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "protocol 13 should be rejected"
  assert_contains "$out" "outside the verified 0.7.x range" "old client error omitted the required version range"
  rm -f "$resp/1.out" "$resp/.count"
  printf '%s\n' '{"client":{"version":"0.6.9","protocol":14}}' > "$resp/1.out"
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_version_check' "$ROOT" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "Herdr 0.6.x should be rejected even with protocol 14"
  rm -f "$resp/1.out" "$resp/.count"
  printf '%s\n' '{"client":{"version":"0.8.0","protocol":14}}' > "$resp/1.out"
  status=0
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_version_check' "$ROOT" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "Herdr 0.8.x should be rejected even with protocol 14"
  pass "Herdr version gate enforces 0.7.x and protocol 14+"
}

test_workspace_labels_and_container() {
  local lines dir log resp fb out live_pid status=0
  [ "$(FM_HOME="$ROOT" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT")" = firstmate ] \
    || fail "primary home label should be firstmate"
  dir="$TMP_ROOT/labels"; mkdir -p "$dir/home" "$dir/responses"
  printf 'sshhip-h7\n' > "$dir/home/.fm-secondmate-home"
  [ "$(FM_HOME="$dir/home" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_label' "$ROOT")" = 2ndmate-sshhip-h7 ] \
    || fail "secondmate home label did not include its id"

  read -r dir log resp < <(herdr_case container)
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":14}}' > "$resp/1.out"
  printf '%s\n' '{"server":{"running":true}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"workspaces":[]}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"workspace":{"workspace_id":"w1","label":"firstmate"}}}' > "$resp/4.out"
  fb=$(make_fake_herdr "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_container_ensure /tmp' "$ROOT")
  [ "$out" = fmtest:w1 ] || fail "container ensure returned '$out'"
  assert_contains "$(cat "$log")" $'\x1fworkspace\x1fcreate' "container ensure did not create a workspace"

  find "$resp" -maxdepth 1 -type f -delete
  : > "$log"
  printf '93\n' > "$resp/1.exit"
  status=0
  PATH="$fb:$PATH" FM_HOME="$dir/home" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_ensure fmtest /tmp' "$ROOT" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "workspace list failure was treated as an empty workspace list"
  assert_not_contains "$(cat "$log")" $'\x1fworkspace\x1fcreate' "workspace list failure proceeded to create"

  find "$resp" -maxdepth 1 -type f -delete
  mkdir -p "$dir/home/.fm-herdr-workspace.lock"
  printf '999999\n' > "$dir/home/.fm-herdr-workspace.lock/pid"
  printf '%s\n' '{"result":{"workspaces":[]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"workspace":{"workspace_id":"w2","label":"firstmate"}}}' > "$resp/2.out"
  : > "$resp/3.out"
  out=$(FM_HOME="$dir/home" PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" HERDR_SESSION=fmtest \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_workspace_ensure fmtest /tmp' "$ROOT")
  [ "$out" = w2 ] || fail "stale workspace lock was not recovered"
  [ ! -e "$dir/home/.fm-herdr-workspace.lock" ] || fail "workspace lock was not released after stale recovery"

  rm -rf "$dir/home/.fm-herdr-workspace.lock"
  mkdir -p "$dir/home/.fm-herdr-workspace.lock"
  status=0
  FM_HOME="$dir/home" PATH="$fb:$PATH" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_lock_owner_status "$FM_HOME/.fm-herdr-workspace.lock"' "$ROOT" \
    >/dev/null 2>&1 || status=$?
  [ "$status" -eq 0 ] || fail "ambiguous legacy workspace lock was treated as stale"
  [ -d "$dir/home/.fm-herdr-workspace.lock" ] || fail "ambiguous legacy workspace lock was removed"

  mkdir -p "$dir/home/.fm-herdr-workspace.lock"
  # PID 1 is not guaranteed to be a live, non-zombie process in CI containers.
  live_pid=$$
  printf '%s\n' "$live_pid" > "$dir/home/.fm-herdr-workspace.lock/pid"
  status=0
  FM_HOME="$dir/home" PATH="$fb:$PATH" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_lock_owner_status "$FM_HOME/.fm-herdr-workspace.lock"' "$ROOT" \
    >/dev/null 2>&1 || status=$?
  [ "$status" -eq 0 ] || fail "live legacy lock without pid-start was treated as stale"
  [ -d "$dir/home/.fm-herdr-workspace.lock" ] || fail "live legacy lock without pid-start was removed"
  pass "Herdr container ensure is version-gated and workspace-per-home"
}

test_task_and_target_primitives() {
  local lines dir log resp fb out status=0
  read -r dir log resp < <(herdr_case task)
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t1","label":"fm-dup"}]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1"}]}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1"}}}' > "$resp/3.out"
  printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}' > "$resp/4.out"
  fb=$(make_fake_herdr "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-dup /tmp' "$ROOT" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "duplicate Herdr tab label was not rejected"
  assert_contains "$out" "already exists" "duplicate label error was unclear"

  find "$resp" -maxdepth 1 -type f -delete
  : > "$log"
  printf '%s\n' '{}' > "$resp/1.out"
  status=0
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-invalid /tmp' "$ROOT" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "malformed tab list was treated as an empty list"
  assert_not_contains "$(cat "$log")" $'\x1ftab\x1fcreate' "malformed tab list proceeded to create a tab"

  find "$resp" -maxdepth 1 -type f -delete
  printf '%s\n' '{"result":{"tabs":[]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t2"},"root_pane":{"pane_id":"w1:p2"}}}' > "$resp/2.out"
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-new /tmp' "$ROOT")
  [ "$out" = 'w1:t2 w1:p2' ] || fail "create task returned '$out'"
  find "$resp" -maxdepth 1 -type f -delete
  printf '%s\n' '{"result":{"tabs":[]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t3"},"root_pane":{"pane_id":"w1:p3"}}}' > "$resp/2.out"
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task "$1" fm-seeded /tmp seeded' "$ROOT" $'fmtest:w1\tseeded')
  [ "$out" = 'w1:t3 w1:p3' ] || fail "seeded create task returned '$out'"
  assert_contains "$(cat "$log")" $'\x1f--workspace\x1fw1' "seeded workspace id was not stripped before tab listing"

  find "$resp" -maxdepth 1 -type f -delete
  printf '%s\n' '{"result":{"tabs":[]}}' > "$resp/1.out"
  printf '%s\n' '{"result":{"tab":{"tab_id":"w1:t4"}}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"tabs":[{"tab_id":"w1:t4","label":"fm-malformed"}]}}' > "$resp/3.out"
  : > "$resp/4.out"
  printf '%s\n' '{"result":{"tabs":[]}}' > "$resp/5.out"
  status=0
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_create_task fmtest:w1 fm-malformed /tmp' "$ROOT" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "malformed tab create output unexpectedly succeeded"
  assert_contains "$(cat "$log")" $'\x1ftab\x1fclose' "malformed tab create output left the created tab open"
  [ "$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_parse_target default:w1:p2; printf "%s|%s" "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE"' "$ROOT")" = 'default|w1:p2' ] \
    || fail "target parser did not split on the first colon"
  [ "$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_normalize_key C-c' "$ROOT")" = ctrl+c ] \
    || fail "key normalization failed"
  pass "Herdr task creation, duplicate protection, target parsing, and key mapping work"
}

test_kill_requires_verified_absence() {
  local lines dir log resp fb status=0
  read -r dir log resp < <(herdr_case kill)
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":14}}' > "$resp/1.out"
  printf '%s\n' '{"server":{"running":true}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2"}}}' > "$resp/3.out"
  printf '93\n' > "$resp/4.exit"
  fb=$(make_fake_herdr "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_kill default:w1:p2' "$ROOT" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "Herdr kill swallowed pane-close failure"
  assert_not_contains "$(cat "$log")" $'\x1fserver' "Herdr target teardown unexpectedly started the server"

  find "$resp" -maxdepth 1 -type f -delete
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":14}}' > "$resp/1.out"
  printf '%s\n' '{"server":{"running":true}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2"}}}' > "$resp/3.out"
  : > "$resp/4.out"
  printf '%s\n' '{}' > "$resp/5.out"
  status=0
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_kill default:w1:p2' "$ROOT" >/dev/null 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "malformed pane list was treated as verified absence"
  pass "Herdr kill propagates close failures and avoids server creation"
}

test_capture_send_busy() {
  local lines dir log resp fb out
  read -r dir log resp < <(herdr_case capture)
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":14}}' > "$resp/1.out"
  printf '%s\n' '{"server":{"running":true}}' > "$resp/2.out"
  printf 'one\ntwo\nthree\n' > "$resp/3.out"
  fb=$(make_fake_herdr "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_capture default:w1:p2 2' "$ROOT")
  [ "$out" = $'two\nthree' ] || fail "capture did not trim the requested tail: '$out'"
  assert_contains "$(cat "$log")" $'\x1f--lines\x1f200' "small capture did not use the safe over-fetch"
  find "$resp" -maxdepth 1 -type f -delete
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":14}}' > "$resp/1.out"
  printf '%s\n' '{"server":{"running":true}}' > "$resp/2.out"
  printf '%s\n' '{"result":{"agent":{"agent_status":"working"}}}' > "$resp/3.out"
  [ "$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_busy_state default:w1:p2' "$ROOT")" = busy ] \
    || fail "working agent did not map to busy"
  pass "Herdr capture uses safe over-fetch and native busy state"
}

test_submit_retry_verdicts() {
  local lines dir log resp fb out
  read -r dir log resp < <(herdr_case submit)
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":14}}' > "$resp/1.out"
  printf '%s\n' '{"server":{"running":true}}' > "$resp/2.out"
  : > "$resp/3.out"
  printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}' > "$resp/4.out"
  printf '%s\n' '{"server":{"running":true}}' > "$resp/5.out"
  printf '%s\n' '{}' > "$resp/6.out"
  printf '%s\n' '{"result":{"agent":{"agent_status":"working"}}}' > "$resp/7.out"
  fb=$(make_fake_herdr "$dir")
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_SUBMIT_POLLS=1 FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 "$1" 2 0 0' "$ROOT" '*')
  [ "$out" = empty ] || fail "composer clear should report empty, got '$out'"
  assert_contains "$(cat "$log")" $'\x1fagent\x1fget' "submit acknowledgement did not inspect native agent state"
  assert_not_contains "$(cat "$log")" $'\x1fpane\x1fread' "native submit confirmation unexpectedly read the composer"
  find "$resp" -maxdepth 1 -type f -delete
  printf '%s\n' '{"client":{"version":"0.7.4","protocol":14}}' > "$resp/1.out"
  printf '%s\n' '{"server":{"running":true}}' > "$resp/2.out"
  : > "$resp/3.out"
  printf '%s\n' '{}' > "$resp/4.out"
  printf '%s\n' '{"server":{"running":true}}' > "$resp/5.out"
  printf '%s\n' '{}' > "$resp/6.out"
  printf '%s\n' '{"server":{"running":true}}' > "$resp/7.out"
  printf 'he\nllo\n' > "$resp/8.out"
  status=0
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit default:w1:p2 hello 1 0 0' "$ROOT") || status=$?
  [ "$status" -eq 0 ] && [ "$out" = pending ] || fail "wrapped composer text was not retained as pending"
  assert_contains "$(cat "$log")" $'\x1f--lines\x1f1' "submit acknowledgement did not inspect the composer row"
  pass "Herdr text submit uses native confirmation and safe composer fallback"
}

test_wait_for_working_classification() {
  local out
  out=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    seq_file=$(mktemp)
    trap "rm -f \"$seq_file\"" EXIT
    fm_backend_herdr_agent_status_raw() {
      n=$(( $(cat "$seq_file" 2>/dev/null || printf 0) + 1 ))
      printf "%s" "$n" > "$seq_file"
      case "$n" in
        1) printf idle ;;
        2) printf working ;;
      esac
    }
    FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0
    fm_backend_herdr_wait_for_working demo pane 0 2
  ' "$ROOT")
  [ "$out" = busy ] || fail "wait_for_working missed a later working transition: '$out'"
  out=$(bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_agent_status_raw() { printf blocked; }
    fm_backend_herdr_wait_for_working demo pane 0 1
  ' "$ROOT")
  [ "$out" = busy ] || fail "submit classification did not treat blocked as busy: '$out'"
  pass "Herdr wait_for_working samples native status and classifies blocked submits"
}

test_husk_duplicate_is_replaced_after_creation() {
  local dir="$TMP_ROOT/husk" out log
  mkdir -p "$dir"
  log="$dir/log"
  out=$(FM_HOME="$dir" FM_HERDR_PRUNE_CLOSE="$dir/close" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_workspace_lock_acquire() { :; }
    fm_backend_herdr_workspace_lock_release() { :; }
    fm_backend_herdr_tab_ids_for_label() { printf "husk-tab"; }
    fm_backend_herdr_pane_for_tab() { printf "husk-pane"; }
    fm_backend_herdr_tab_is_husk() { return 0; }
    fm_backend_herdr_cli() {
      case "$*" in
        *"tab create"*) printf "%s" '\''{"result":{"tab":{"tab_id":"new-tab"},"root_pane":{"pane_id":"new-pane"}}}'\''; printf "\\n"; ;;
        *"tab list"*) printf "%s" '\''{"result":{"tabs":[{"tab_id":"new-tab","label":"fm-demo"}]}}'\''; printf "\\n"; ;;
        *"tab close"*) printf "closed\\n" >> "$FM_HERDR_TEST_LOG" ;;
      esac
    }
    fm_backend_herdr_create_task session:w1 fm-demo /tmp
  ' "$ROOT" 2>/dev/null)
  [ "$out" = 'new-tab new-pane' ] || fail "husk replacement returned '$out'"
  pass "Herdr replaces a confirmed husk only after creating the replacement"
}

test_create_task_cleans_up_after_postcreate_failure() {
  local dir log out status=0
  dir="$TMP_ROOT/postcreate-cleanup"; log="$dir/log"
  mkdir -p "$dir"
  out=$(FM_HOME="$dir" FM_HERDR_TEST_LOG="$log" FM_HERDR_TEST_CREATED="$dir/created" FM_HERDR_TEST_CLOSED="$dir/closed" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_workspace_lock_acquire() { :; }
    fm_backend_herdr_workspace_lock_release() { :; }
    fm_backend_herdr_workspace_prune_seeded_default_tab() { return 1; }
    fm_backend_herdr_cli() {
      case "$*" in
        *"tab create"*) : > "$FM_HERDR_TEST_CREATED"; printf "%s" '\''{"result":{"root_pane":{"pane_id":"new-pane"}}}'\'' ;;
        *"tab close"*) printf "%s\n" "$*" >> "$FM_HERDR_TEST_LOG"; : > "$FM_HERDR_TEST_CLOSED" ;;
        *"tab list"*) if [ -e "$FM_HERDR_TEST_CLOSED" ] || [ ! -e "$FM_HERDR_TEST_CREATED" ]; then printf "%s" '\''{"result":{"tabs":[]}}'\''; else printf "%s" '\''{"result":{"tabs":[{"tab_id":"new-tab","label":"fm-demo"}]}}'\''; fi ;;
      esac
    }
    fm_backend_herdr_create_task session:w1 fm-demo /tmp
  ' "$ROOT" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "seed-prune failure unexpectedly succeeded"
  assert_contains "$(cat "$log")" "tab close new-tab" "post-create failure did not close the created tab"

  : > "$log"
  status=0
  out=$(FM_HOME="$dir" FM_HERDR_TEST_LOG="$log" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_workspace_lock_acquire() { :; }
    fm_backend_herdr_workspace_lock_release() { :; }
    fm_backend_herdr_tab_ids_for_label() { printf "husk-tab"; }
    fm_backend_herdr_pane_for_tab() { printf "husk-pane"; }
    fm_backend_herdr_tab_is_husk() { return 0; }
    fm_backend_herdr_cli() {
      case "$*" in
        *"tab create"*) printf "%s" '\''{"result":{"tab":{"tab_id":"new-tab"},"root_pane":{"pane_id":"new-pane"}}}'\'' ;;
        *"tab close"*) printf "%s\n" "$*" >> "$FM_HERDR_TEST_LOG" ;;
        *"tab list"*) printf "%s" '\''{}'\'' ;;
      esac
    }
    fm_backend_herdr_create_task session:w1 fm-demo /tmp
  ' "$ROOT" 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "malformed husk verification unexpectedly succeeded"
  assert_contains "$(cat "$log")" "tab close new-tab" "malformed husk response did not close the created tab"
  pass "Herdr create cleanup closes tabs after post-create failures"
}

test_seed_prune_is_exact_and_fail_closed() {
  local dir="$TMP_ROOT/prune" out
  mkdir -p "$dir"
  out=$(FM_HOME="$dir" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_cli() {
      case "$*" in
        *"tab list"*) if [ -e "$FM_HERDR_PRUNE_CLOSE" ]; then printf "%s" '\''{"result":{"tabs":[{"tab_id":"task","label":"fm-live"}]}}'\''; else printf "%s" '\''{"result":{"tabs":[{"tab_id":"seed","label":"1"},{"tab_id":"task","label":"fm-live"}]}}'\''; fi ;;
        *"tab close"*) : > "$FM_HERDR_PRUNE_CLOSE" ;;
      esac
    }
    fm_backend_herdr_pane_for_tab() { printf seed-pane; }
    fm_backend_herdr_pane_agent_state() { printf live; }
    fm_backend_herdr_workspace_prune_seeded_default_tab demo w1 seed
  ' "$ROOT")
  [ -z "$out" ] || fail "live seeded tab was pruned: $out"
  out=$(FM_HOME="$dir" FM_HERDR_PRUNE_CLOSE="$dir/close" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_cli() {
      case "$*" in
        *"tab list"*) if [ -e "$FM_HERDR_PRUNE_CLOSE" ]; then printf "%s" '\''{"result":{"tabs":[{"tab_id":"task","label":"fm-live"}]}}'\''; else printf "%s" '\''{"result":{"tabs":[{"tab_id":"seed","label":"1"},{"tab_id":"task","label":"fm-live"}]}}'\''; fi ;;
        *"tab close"*) : > "$FM_HERDR_PRUNE_CLOSE" ;;
      esac
    }
    fm_backend_herdr_pane_for_tab() { printf seed-pane; }
    fm_backend_herdr_pane_agent_state() { printf no-agent; }
    fm_backend_herdr_workspace_prune_seeded_default_tab demo w1 seed
  ' "$ROOT")
  [ -e "$dir/close" ] || fail "confirmed seed husk was not pruned"
  out=$(FM_HOME="$dir" FM_HERDR_PRUNE_CLOSE="$dir/close-no-pane" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_cli() {
      case "$*" in
        *"tab list"*) if [ -e "$FM_HERDR_PRUNE_CLOSE" ]; then printf "%s" '\''{"result":{"tabs":[{"tab_id":"task","label":"fm-live"}]}}'\''; else printf "%s" '\''{"result":{"tabs":[{"tab_id":"seed","label":"1"},{"tab_id":"task","label":"fm-live"}]}}'\''; fi ;;
        *"tab close"*) : > "$FM_HERDR_PRUNE_CLOSE" ;;
      esac
    }
    fm_backend_herdr_pane_for_tab() { :; }
    fm_backend_herdr_workspace_prune_seeded_default_tab demo w1 seed
  ' "$ROOT")
  [ -e "$dir/close-no-pane" ] || fail "dead seeded tab without a pane was not pruned"
  pass "Herdr seed pruning closes and verifies the exact seeded tab"
}

test_event_capability_uses_named_session() {
  local lines dir log resp fb
  read -r dir log resp < <(herdr_case events-capability)
  printf '%s\n' '{"client":{"protocol":16}}' > "$resp/1.out"
  printf '%s\n' 'events.subscribe pane.agent_status_changed' > "$resp/2.out"
  fb=$(make_fake_herdr "$dir")
  PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    FM_BACKEND_HERDR_EVENT_READER="$dir/reader" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_events_capable named-session' "$ROOT" \
    || fail "named-session event capability probe failed"
  assert_contains "$(cat "$log")" $'HERDR_SESSION=named-session\x1fstatus\x1f--json\x1f--session\x1fnamed-session' \
    "event capability status probe ignored the named session"
  assert_contains "$(cat "$log")" $'HERDR_SESSION=named-session\x1fapi\x1fschema\x1f--json\x1f--session\x1fnamed-session' \
    "event capability schema probe ignored the named session"
  find "$resp" -maxdepth 1 -type f -delete
  printf '%s\n' '{"sessions":[{"name":"named-session","socket_path":"named-socket"}]}' > "$resp/1.out"
  : > "$log"
  out=$(PATH="$fb:$PATH" FM_HERDR_LOG="$log" FM_HERDR_RESPONSES="$resp" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_socket_path named-session' "$ROOT")
  [ "$out" = named-socket ] || fail "named-session socket lookup returned '$out'"
  assert_contains "$(cat "$log")" $'HERDR_SESSION=named-session\x1fsession\x1flist\x1f--json\x1f--session\x1fnamed-session' \
    "socket lookup ignored the named session"
  pass "Herdr event capability probes use the explicit session"
}

test_eventwait_returns_fresh_blocked_transition() {
  local dir="$TMP_ROOT/eventwait" state reader out
  mkdir -p "$dir" "$dir/state"
  state="$dir/state"
  reader="$dir/reader"
  cat > "$reader" <<'SH'
#!/usr/bin/env bash
printf '@subscribed\n'
printf 'pane-1\tworkspace-1\tblocked\tclaude\n'
SH
  chmod +x "$reader"
  out=$(FM_HOME="$dir" FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED=1 \
    FM_BACKEND_HERDR_EVENT_READER="$reader" bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_socket_path() { printf fake-socket; }
      fm_backend_herdr_agent_status_raw() { :; }
      record=$(fm_backend_herdr_wait_transition demo 2 "$1" demo:pane-1) || exit $?
      fm_backend_herdr_commit_transition "$1" demo "$record"
      printf "%s" "$record"
    ' "$ROOT" "$state")
  [ "$out" = $'pane-1\tworkspace-1\t\tblocked\tclaude' ] \
    || fail "eventwait returned '$out'"
  [ -e "$state/.herdr-escalated-demo_pane-1" ] || fail "blocked edge was not deduped"
  pass "Herdr eventwait returns and records a fresh blocked transition"
}

test_dispatch_and_meta_routing() {
  local state="$TMP_ROOT/dispatch-state" meta
  mkdir -p "$state"
  fm_write_meta "$state/task.meta" 'window=default:w1:p2' 'backend=herdr'
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_validate herdr || fail "Herdr should be a known backend"
  [ "$(fm_backend_of_meta "$state/task.meta")" = herdr ] || fail "meta backend was not read"
  [ "$(fm_backend_resolve_selector fm-task "$state")" = default:w1:p2 ] || fail "selector target changed"
  meta=$(fm_backend_meta_for_window default:w1:p2 "$state")
  [ "$meta" = "$state/task.meta" ] || fail "window metadata lookup failed"
  pass "backend dispatch accepts Herdr and preserves opaque session:pane targets"
}

test_selection_and_autodetect
test_backend_tool_gating
test_version_gate
test_workspace_labels_and_container
test_task_and_target_primitives
test_kill_requires_verified_absence
test_capture_send_busy
test_submit_retry_verdicts
test_wait_for_working_classification
test_husk_duplicate_is_replaced_after_creation
test_create_task_cleans_up_after_postcreate_failure
test_seed_prune_is_exact_and_fail_closed
test_event_capability_uses_named_session
test_eventwait_returns_fresh_blocked_transition
test_dispatch_and_meta_routing
