# shellcheck shell=bash
# Shared per-line cap for agent-facing digest lines.
# Usage: . bin/fm-line-cap-lib.sh; fm_cap_line "<line>" [<max>]

FM_LINE_CAP_DEFAULT=220
FM_LINE_CAP_SUFFIX=' [truncated]'

# fm_cap_line_var <line> [<max>]: put the capped value in FM_LINE_CAP_LINE.
# The caller can keep its own stream or aggregate policy; this helper only
# owns the cut and its marker.
fm_cap_line_var() {
  local line=$1 max=${2:-$FM_LINE_CAP_DEFAULT} keep
  if [ "${#line}" -le "$max" ]; then
    FM_LINE_CAP_LINE=$line
    return 0
  fi
  keep=$((max - ${#FM_LINE_CAP_SUFFIX}))
  [ "$keep" -ge 0 ] || keep=0
  FM_LINE_CAP_LINE="${line:0:$keep}$FM_LINE_CAP_SUFFIX"
}

# fm_cap_line <line> [<max>]: print the capped value.
fm_cap_line() {
  fm_cap_line_var "$@"
  printf '%s\n' "$FM_LINE_CAP_LINE"
}
