#!/usr/bin/env bash
# Regression: watcher PID identity must not vary with the caller locale.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-lib-locale)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
if [ "${LC_ALL:-}" = C ]; then
  printf 'C-locale identity\n'
else
  printf 'ambient-locale identity\n'
fi
SH
chmod +x "$FAKEBIN/ps"
LIB="$ROOT/bin/fm-wake-lib.sh"
base=$(LC_ALL=C PATH="$FAKEBIN:$PATH" bash -c '. "$1"; fm_pid_identity 123' _ "$LIB")
other=$(LC_ALL=C.UTF-8 PATH="$FAKEBIN:$PATH" bash -c '. "$1"; fm_pid_identity 123' _ "$LIB")
assert_contains "$base" 'C-locale identity' 'baseline identity should use the C locale'
[ "$other" = "$base" ] || fail "PID identity changed with caller locale (got '$other', want '$base')"
pass 'fm_pid_identity pins ps output to the C locale'
