#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-nm-gate-tests.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

make_fake_tmux() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in
        '#S') printf '%s\n' test-session; exit 0 ;;
        '#{pane_current_path}') printf '%s\n' "$FM_FAKE_WT"; exit 0 ;;
      esac
    done
    printf '%s\n' test-session
    exit 0 ;;
  list-windows|new-window|send-keys|has-session|new-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_git_repo() {
  local path=$1
  git init -q "$path"
  git -C "$path" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

make_case() {
  local name=$1 line=$2 home project wt fakebin
  home="$TMP_ROOT/$name/home"
  project="$home/projects/app"
  wt="$TMP_ROOT/$name/wt"
  mkdir -p "$home/data/task/data" "$home/state" "$home/projects" "$project" "$wt"
  mkdir -p "$home/data"
  printf '%s\n' "$line" > "$home/data/projects.md"
  make_git_repo "$project"
  make_git_repo "$wt"
  printf 'brief\n' > "$home/data/task/brief.md"
  fakebin=$(make_fake_tmux "$TMP_ROOT/$name")
  printf '%s\t%s\t%s\n' "$home" "$wt" "$fakebin"
}

run_spawn_case() {
  local home=$1 wt=$2 fakebin=$3 kind_arg=${4:-}
  if [ -n "$kind_arg" ]; then
    PATH="$fakebin:$PATH" TMUX=1 FM_FAKE_WT="$wt" FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
      "$SPAWN" task projects/app codex "$kind_arg" >/dev/null
  else
    PATH="$fakebin:$PATH" TMUX=1 FM_FAKE_WT="$wt" FM_HOME="$home" FM_SPAWN_NO_GUARD=1 \
      "$SPAWN" task projects/app codex >/dev/null
  fi
}

test_ship_records_nm_gate_pending_scope_review() {
  local row home wt fakebin meta
  row=$(make_case ship '- app [direct-PR +nm-gate] - app (added 2026-06-24)')
  IFS=$'\t' read -r home wt fakebin <<EOF
$row
EOF
  run_spawn_case "$home" "$wt" "$fakebin"
  meta="$home/state/task.meta"
  grep -Fx 'mode=direct-PR' "$meta" >/dev/null || fail "mode missing"
  grep -Fx 'yolo=off' "$meta" >/dev/null || fail "yolo missing"
  grep -Fx 'nm_gate=on' "$meta" >/dev/null || fail "ship nm_gate=on missing"
  grep -Fx 'nm_status=pending_scope_review' "$meta" >/dev/null || fail "ship nm_status pending missing"
  pass "ship spawn records nm-gate pending scope review"
}

test_scout_records_nm_gate_off() {
  local row home wt fakebin meta
  row=$(make_case scout '- app [direct-PR +nm-gate] - app (added 2026-06-24)')
  IFS=$'\t' read -r home wt fakebin <<EOF
$row
EOF
  run_spawn_case "$home" "$wt" "$fakebin" --scout
  meta="$home/state/task.meta"
  grep -Fx 'kind=scout' "$meta" >/dev/null || fail "kind=scout missing"
  grep -Fx 'nm_gate=off' "$meta" >/dev/null || fail "scout nm_gate should be off"
  grep -Fx 'nm_status=not_applicable' "$meta" >/dev/null || fail "scout nm_status should be not_applicable"
  pass "scout spawn ignores nm-gate"
}

test_ship_records_nm_gate_pending_scope_review
test_scout_records_nm_gate_off
