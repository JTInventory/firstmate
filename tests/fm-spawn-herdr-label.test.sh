#!/usr/bin/env bash
# Spawn behavior tests for Herdr display labels, metadata, and crash journal.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-label)

make_herdr_spawn_fake() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
state=${FM_FAKE_HERDR_STATE:?}
log=${FM_FAKE_HERDR_LOG:?}
printf '%s\n' "$*" >> "$log"
cmd=${1:-}; sub=${2:-}
case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "workspace list")
    if [ -f "$state/workspace" ]; then
      printf '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate"}]}}\n'
    else
      printf '{"result":{"workspaces":[]}}\n'
    fi
    ;;
  "workspace create")
    touch "$state/workspace"
    printf '{"result":{"workspace":{"workspace_id":"w1","label":"firstmate"},"root_pane":{"pane_id":"w1:p0"}}}\n'
    ;;
  "tab list")
    if [ -f "$state/task-label" ]; then
      label=$(cat "$state/task-label")
      printf '{"result":{"tabs":[{"tab_id":"w1:t1","label":"%s","workspace_id":"w1"}]}}\n' "$label"
    else
      printf '{"result":{"tabs":[]}}\n'
    fi
    ;;
  "tab create")
    label=
    args=("$@")
    for ((i=0; i<${#args[@]}; i++)); do
      [ "${args[$i]}" != --label ] || label=${args[$((i+1))]:-}
    done
    if [ -f "${FM_FAKE_LABEL_JOURNAL:?}" ]; then
      printf 'present\n' > "$state/journal-at-create"
    fi
    printf '%s\n' "$label" > "$state/task-label"
    if [ "${FM_FAKE_FAIL_AFTER_CREATE:-0}" = 1 ]; then
      exit 1
    fi
    printf '{"result":{"tab":{"tab_id":"w1:t1"},"root_pane":{"pane_id":"w1:p1"}}}\n'
    ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"w1:p1","foreground_cwd":"%s"}}}\n' "${FM_FAKE_WORKTREE:?}"
    ;;
  "pane run"|"pane send-text"|"pane send-keys")
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects" "$case_dir/herdr-state"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief\n' > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fakebin=$(make_herdr_spawn_fake "$case_dir/fake")
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 HERDR_SESSION=fmtest \
    FM_FAKE_HERDR_STATE="$CASE_DIR/herdr-state" FM_FAKE_HERDR_LOG="$CASE_DIR/herdr.log" \
    FM_FAKE_LABEL_JOURNAL="$HOME_DIR/state/$id.herdr-label" FM_FAKE_WORKTREE="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --backend herdr "$@" 2>&1
}

test_spawn_publishes_journal_before_create_then_atomic_meta() {
  local rec id out status meta
  id=herdr-label-c1db
  rec=$(make_case success "$id")
  read_case "$rec"
  out=$(run_spawn "$id" --scout --display-title "Herdr labels")
  status=$?
  expect_code 0 "$status" "Herdr display-label spawn should succeed (output: $out)"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "display_label=Scout - Herdr labels · c1db" "$meta" "meta missing persisted display label"
  assert_grep "task_key=c1db" "$meta" "meta missing task key"
  assert_grep "herdr_tab_id=w1:t1" "$meta" "meta missing response-derived tab id"
  assert_grep "herdr_pane_id=w1:p1" "$meta" "meta missing response-derived pane id"
  assert_grep "present" "$CASE_DIR/herdr-state/journal-at-create" "label journal was not present before tab create"
  assert_absent "$HOME_DIR/state/$id.herdr-label" "label journal should retire only after final metadata publication"
  assert_grep "--label Scout - Herdr labels · c1db --no-focus" "$CASE_DIR/herdr.log" "Herdr tab did not use the display label"
  pass "fm-spawn Herdr: journal precedes create; final metadata persists label, key, and exact ids"
}

test_lost_create_response_keeps_recovery_journal() {
  local rec id out status journal
  id=herdr-crash-be28
  rec=$(make_case crash "$id")
  read_case "$rec"
  set +e
  out=$(FM_FAKE_FAIL_AFTER_CREATE=1 run_spawn "$id" --display-title "UI Design")
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "simulated create-response loss should fail spawn"
  journal="$HOME_DIR/state/$id.herdr-label"
  assert_present "$journal" "pre-create journal was lost after create-response failure"
  assert_grep "display_label=Crew - UI Design · be28" "$journal" "recovery journal lost exact created label"
  assert_absent "$HOME_DIR/state/$id.meta" "failed spawn must not publish final metadata"
  pass "fm-spawn Herdr: a create/final-meta crash gap remains exactly correlated by the journal"
}

test_spawn_publishes_journal_before_create_then_atomic_meta
test_lost_create_response_keeps_recovery_journal

echo "# all fm-spawn-herdr-label tests passed"
