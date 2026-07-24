#!/usr/bin/env bash
# The secondmate from-firstmate marker must survive the Herdr send backend.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$ROOT/bin/fm-marker-lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-herdr-marker)

make_fake_herdr() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  status)
    printf '%s\n' '{"client":{"version":"0.7.4","protocol":14},"server":{"running":true}}'
    ;;
  pane)
    case "${2:-}" in
      get) printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2"}}}' ;;
      list) printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p2","tab_id":"w1:t2"}]}}' ;;
      send-text) printf '%s' "${4:-}" > "${FM_HERDR_SEND_LOG:?}" ;;
      send-keys) : ;;
      read) printf '>\n' ;;
    esac
    ;;
  tab)
    case "${2:-}" in
      list) printf '{"result":{"tabs":[{"tab_id":"w1:t2","label":"%s"}]}}\n' "${FM_HERDR_RECOVERY_LABEL:-fm-domain}" ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/herdr"
  printf '%s\n' "$fakebin"
}

dir="$TMP_ROOT/case"; home="$dir/home"; log="$dir/send.log"
mkdir -p "$home/state"
fm_write_secondmate_meta "$home/state/domain.meta" "$home" "lab:w1:p2"
printf '%s\n' 'backend=herdr' >> "$home/state/domain.meta"
fakebin=$(make_fake_herdr "$dir")

PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_HERDR_SEND_LOG="$log" \
  "$SEND" fm-domain "route through Herdr" >/dev/null 2>&1 \
  || fail "Herdr secondmate send failed"

expected="${FM_FROMFIRST_MARK}route through Herdr"
[ "$(cat "$log")" = "$expected" ] \
  || fail "Herdr secondmate send lost or changed the from-firstmate marker"
pass "fm-send preserves the secondmate marker through the Herdr backend"

recovery_home="$dir/recovery-home"
mkdir -p "$recovery_home/state"
cat > "$recovery_home/state/crash-a1b2c3d4e5.herdr-label" <<EOF
version=1
task_id=crash-a1b2c3d4e5
display_label=Crew - Crash recovery · a1b2c3d4e5
task_key=a1b2c3d4e5
herdr_home=$recovery_home
herdr_session=fmtest
herdr_workspace_id=w1
EOF
PATH="$fakebin:$PATH" FM_HOME="$recovery_home" FM_ROOT_OVERRIDE="$recovery_home" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_HERDR_SEND_LOG="$log" \
  FM_HERDR_RECOVERY_LABEL="Crew - Crash recovery · a1b2c3d4e5" \
  "$SEND" fm-crash-a1b2c3d4e5 "recover through Herdr" >/dev/null 2>&1 \
  || fail "journal-only Herdr send failed"
[ "$(cat "$log")" = "recover through Herdr" ] \
  || fail "journal-only send did not stay on the Herdr backend"
pass "fm-send keeps journal-only recovery on the Herdr backend"
