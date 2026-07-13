#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)
make_case() {
  local d=$1; mkdir -p "$d/fakebin" "$d/home/state"
  cat > "$d/fakebin/tmux" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' 'other:ambiguous'; exit 0 ;;
  send-keys|display-message|capture-pane) exit 0 ;;
esac
exit 0
EOF
  chmod +x "$d/fakebin/tmux"
}
test_unresolvable_bare_target_refuses() {
  local d="$TMP_ROOT/ambiguous" rc
  make_case "$d"
  set +e
  PATH="$d/fakebin:$PATH" FM_ROOT_OVERRIDE="$d/home" FM_HOME="$d/home" "$SEND" ambiguous hello 2>"$d/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "ambiguous bare target must fail"
  grep -q 'not resolvable' "$d/err" || fail "missing actionable unresolved-target error"
  pass "fm-send refuses unresolved bare targets"
}
test_unresolvable_bare_target_refuses
