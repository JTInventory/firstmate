#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh route evidence integration.
#
# The fake tmux reports a controlled pane cwd after `treehouse get`, so these
# tests exercise the real spawn success path without opening windows.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-route)
SPAWN="$ROOT/bin/fm-spawn.sh"

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

make_case() {
  local label=$1 home proj wt fakebin
  home="$TMP_ROOT/$label-home"
  proj="$TMP_ROOT/$label-alpha"
  wt="$TMP_ROOT/$label-wt"
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/$label-fake")
  mkdir -p "$home/data" "$home/state" "$home/projects" "$home/config"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf '%s\n' "- $(basename "$proj") [direct-PR] - alpha fixture (added 2026-06-25)" > "$home/data/projects.md"
  fm_git_init_commit "$proj"
  git -C "$proj" worktree add -q --detach "$wt" >/dev/null 2>&1
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

run_spawn_case() {
  local home=$1 id=$2 proj=$3 wt=$4 fakebin=$5
  shift 5
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$@" 2>&1
}

test_ordinary_spawn_records_route_fields() {
  local home proj wt fakebin id out status meta brief
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case ordinary)
EOF
  id=route-ordinary-aa1
  mkdir -p "$home/data/$id"
  brief="$home/data/$id/brief.md"
  printf '%s\n' 'Investigate production refresh on 4187 and keep state/meta truthful.' > "$brief"

  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 0 "$status" "ordinary routed spawn should succeed"
  assert_contains "$out" "spawned $id harness=codex" "ordinary spawn should launch route harness"
  meta="$home/state/$id.meta"
  assert_grep "route_profile=critical" "$meta" "ordinary spawn did not record route profile"
  assert_grep "route_harness=codex" "$meta" "ordinary spawn did not record route harness"
  assert_grep "route_model=gpt-5.5" "$meta" "ordinary spawn did not record route model"
  assert_grep "route_effort=medium" "$meta" "ordinary spawn did not record route effort"
  assert_grep "route_override=none" "$meta" "ordinary spawn did not record route override"
  assert_grep "route_risk_flags=production,firstmate-core" "$meta" "ordinary spawn did not record route risk flags"
  assert_grep "# Route" "$brief" "ordinary spawn did not add route block to brief"
  assert_grep "route: critical because" "$brief" "ordinary spawn brief route summary missing"
  pass "ordinary spawn records route evidence and appends a brief route block"
}

test_manual_harness_override_records_manual_route() {
  local home proj wt fakebin id out status meta
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case manual)
EOF
  id=route-manual-bb2
  mkdir -p "$home/data/$id"
  printf '%s\n' 'Investigate production refresh on 4187.' > "$home/data/$id/brief.md"

  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin" claude); status=$?
  expect_code 0 "$status" "manual harness spawn should still succeed"
  assert_contains "$out" "spawned $id harness=claude" "manual harness override did not launch selected harness"
  meta="$home/state/$id.meta"
  assert_grep "harness=claude" "$meta" "manual spawn did not preserve operational harness"
  assert_grep "route_profile=manual" "$meta" "manual spawn did not record manual route profile"
  assert_grep "route_harness=claude" "$meta" "manual spawn did not record selected harness"
  assert_grep "route_override=manual-harness" "$meta" "manual spawn did not record manual override"
  assert_no_grep "route_profile=cheap" "$meta" "manual override must not silently record a cheap route"
  pass "manual harness override preserves behavior and records manual route evidence"
}

test_raw_launch_command_records_raw_route() {
  local home proj wt fakebin id out status meta
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case raw)
EOF
  id=route-raw-cc3
  mkdir -p "$home/data/$id"
  printf '%s\n' 'Adapter verification.' > "$home/data/$id/brief.md"

  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin" 'CUSTOM=1 /bin/echo launch'); status=$?
  expect_code 0 "$status" "raw launch command should still succeed"
  assert_contains "$out" "spawned $id harness=echo" "raw launch did not preserve parsed harness"
  meta="$home/state/$id.meta"
  assert_grep "harness=echo" "$meta" "raw launch did not record operational harness"
  assert_grep "route_profile=manual" "$meta" "raw launch did not record manual route profile"
  assert_grep "route_harness=echo" "$meta" "raw launch did not record parsed route harness"
  assert_grep "route_override=raw-launch" "$meta" "raw launch did not record raw override"
  pass "raw launch command is not blocked and records raw route evidence"
}

test_jt_direct_pr_spawn_appends_pr_intake_governor() {
  local home proj wt fakebin id out status brief
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case jt-pr-intake)
EOF
  id=jt-replenishment-proof-loop-dd4
  mkdir -p "$home/data/$id"
  brief="$home/data/$id/brief.md"
  printf '%s\n' 'Fix the JT Control Room Replenishment proof loop before opening another PR.' > "$brief"

  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 0 "$status" "JT direct-PR spawn should succeed"
  assert_contains "$out" "spawned $id harness=codex" "JT direct-PR spawn did not launch"
  assert_grep "<!-- firstmate:jt-pr-intake-governor:start -->" "$brief" \
    "JT direct-PR brief missing intake-governor marker"
  assert_grep "# JT PR Intake Governor" "$brief" \
    "JT direct-PR brief missing intake-governor heading"
  assert_grep "- Problem category:" "$brief" "JT intake missing problem category field"
  assert_grep "- Priority (P0-P4):" "$brief" "JT intake missing priority field"
  assert_grep "- Verification gate:" "$brief" "JT intake missing verification gate field"
  assert_grep "Do not open a PR until this intake is answered." "$brief" \
    "JT intake missing direct PR stop rule"
  pass "JT direct-PR spawns receive the PR Intake Governor brief gate"
}

test_unsafe_task_ids_are_rejected_before_spawn() {
  local home proj wt fakebin id out status
  IFS='|' read -r home proj wt fakebin <<EOF
$(make_case unsafe-id)
EOF

  id='bad;touch pwn'
  mkdir -p "$home/data/$id"
  printf '%s\n' 'Unsafe id should not launch.' > "$home/data/$id/brief.md"
  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 2 "$status" "spawn unsafe metachar id should fail"
  assert_contains "$out" "unsafe task id" "spawn did not explain metachar id rejection"
  assert_absent "$home/state/$id.meta" "unsafe metachar id must not record meta"

  id='../evil'
  out=$(run_spawn_case "$home" "$id" "$proj" "$wt" "$fakebin"); status=$?
  expect_code 2 "$status" "spawn path-traversal id should fail"
  assert_contains "$out" "unsafe task id" "spawn did not explain path traversal id rejection"

  pass "unsafe task ids are rejected before spawn side effects"
}

test_ordinary_spawn_records_route_fields
test_manual_harness_override_records_manual_route
test_raw_launch_command_records_raw_route
test_jt_direct_pr_spawn_appends_pr_intake_governor
test_unsafe_task_ids_are_rejected_before_spawn
