#!/usr/bin/env bash
# Regression: a green no-mistakes CI monitor means the PR is ready for review.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-crew-state-ci-ready)
fm_git_identity fmtest fmtest@example.invalid
CASE="$TMP_ROOT/case"
mkdir -p "$CASE/state" "$CASE/fakebin" "$CASE/wt"
git -C "$CASE/wt" init -q
git -C "$CASE/wt" commit -q --allow-empty -m init
git -C "$CASE/wt" checkout -q -b fm/green-ci

cat > "$CASE/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = axi ] || exit 0
shift
case "${1:-}" in
  status) cat <<'TOON'
run:
  id: "01GREEN"
  branch: fm/green-ci
  status: running
  pr: "https://github.com/JTInventory/firstmate/pull/49"
  findings: none
  steps[1]{step,status,findings,duration_ms}:
    ci,running,0,0
TOON
    ;;
  logs) printf '%s\n' 'all CI checks passed - still monitoring until merged or closed' ;;
esac
SH
cat > "$CASE/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
SH
chmod +x "$CASE/fakebin/no-mistakes" "$CASE/fakebin/tmux"
fm_write_meta "$CASE/state/green-ci.meta" "window=fm:fm-green-ci" "worktree=$CASE/wt" "kind=ship"

out=$(PATH="$CASE/fakebin:$PATH" FM_STATE_OVERRIDE="$CASE/state" "$CREW_STATE" green-ci)
assert_contains "$out" 'state: done' 'green CI monitor must surface PR readiness'
assert_contains "$out" 'source: run-step' 'green CI monitor must remain run-step sourced'
assert_contains "$out" 'checks green' 'green CI monitor must name the ready state'
assert_not_contains "$out" 'state: working' 'green CI monitor must not appear as ongoing validation'
pass 'green CI monitor surfaces PR readiness without a crew status line'
