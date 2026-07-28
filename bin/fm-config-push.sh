#!/usr/bin/env bash
# Push declared inheritable local material to live secondmate homes.
# Usage: fm-config-push.sh [--help]
#
# Config-only convergence for mid-session changes such as config/crew-dispatch.json
# edits. This discovers live secondmate homes from complete state/*.meta
# lifecycle records and reuses the same
# propagate_inheritable_config machinery as bootstrap, but does not fast-forward
# tracked files. Changed config is delivered through the shared reread path.
# Warnings-only skips exit 0; propagation or reread delivery errors exit non-zero.
set -u

usage() {
  cat <<'EOF'
Usage: fm-config-push.sh [--help]

Push the primary firstmate home's declared inheritable local material into each
live secondmate home.

This is inheritance-only:
  - does not fast-forward tracked files
  - sends a CONFIG_REREAD pointer when inherited config changes
  - reports each live home and each inheritable item as pushed, unchanged,
    skipped, or error
  - exits non-zero for propagation, CONFIG_REREAD publication, or delivery errors

Live homes come from state/*.meta records with kind=secondmate.
Incomplete or ambiguous lifecycle records are refused.

Environment overrides follow the rest of firstmate:
  FM_HOME            active firstmate home
  FM_ROOT_OVERRIDE  firstmate repo root
  FM_STATE_OVERRIDE state dir
  FM_CONFIG_OVERRIDE config dir
EOF
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    echo "usage: fm-config-push.sh [--help]" >&2
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
fm_worker_refuse_primary_operation "config push" || exit 1
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="$FM_HOME/data"
SECONDMATES_MD="$DATA/secondmates.md"

[ -n "${FM_CONFIG_PUSH_NO_GUARD:-}" ] || "$SCRIPT_DIR/fm-guard.sh" || true

# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"

FM_CONFIG_PUSH_ADMISSION_LOCKS=()
fm_ff_target_lock_acquire() {
  local state_dir=$1 _label=${2:-target} target_home=${3:-} lock
  FM_CONFIG_PUSH_ADMISSION_LOCKS=()
  while IFS= read -r lock; do
    [ -n "$lock" ] || continue
    mkdir -p "$(dirname "$lock")" || return 1
    if ! fm_lock_try_acquire "$lock"; then
      fm_ff_target_lock_release
      return 1
    fi
    FM_CONFIG_PUSH_ADMISSION_LOCKS+=("$lock")
  done < <(fm_spawn_admission_lock_paths "$state_dir")
  if fm_spawn_legacy_task_lock_busy "$state_dir" \
    || ! fm_spawn_legacy_lifecycle_quiescent "$target_home" "$state_dir"; then
    fm_ff_target_lock_release
    return 1
  fi
}

fm_ff_target_lock_release() {
  local i
  for ((i=${#FM_CONFIG_PUSH_ADMISSION_LOCKS[@]} - 1; i >= 0; i--)); do
    fm_lock_release "${FM_CONFIG_PUSH_ADMISSION_LOCKS[$i]}" || true
  done
  FM_CONFIG_PUSH_ADMISSION_LOCKS=()
}

print_item_report() {
  local report=$1 item status reason
  while IFS=$'\t' read -r item status reason; do
    [ -n "$item" ] || continue
    if [ -n "$reason" ]; then
      printf '  %s: %s - %s\n' "$item" "$status" "$reason"
    else
      printf '  %s: %s\n' "$item" "$status"
    fi
  done < "$report"
}

records=$(mktemp "${TMPDIR:-/tmp}/fm-config-push-records.XXXXXX" 2>/dev/null) || exit 1
reports=""
# shellcheck disable=SC2317,SC2329 # Invoked by trap handlers below.
cleanup() {
  local report_file
  rm -f "$records"
  for report_file in $reports; do
    rm -f "$report_file"
  done
}
trap cleanup EXIT

live_secondmate_meta_records "$STATE" "$SECONDMATES_MD" > "$records"
if [ ! -s "$records" ]; then
  echo "config-push: no live secondmate homes found"
  exit 0
fi

echo "config-push: $CONFIG -> live secondmate homes"

config_push_locked() {
  local id=$1 home_real=$2 window=$3 endpoint_generation=$4 provider_identity=$5
  local home_lock report reread_out dirty rc=0
  fm_secondmate_lifecycle_identity_matches "$STATE" "$id" "$home_real" "$window" \
    "$endpoint_generation" "$provider_identity" || return 1
  printf 'secondmate %s (%s):\n' "$id" "$home_real"
  dirty=$(dirty_status "$home_real" yes || true)
  if [ -n "$dirty" ]; then
    echo "  home: dirty working tree - inheritance-only push continuing"
  fi
  [ -d "$home_real/state" ] || {
    echo "  home: error - state directory is missing"
    return 1
  }
  home_lock=$(fm_config_inherit_lock_path "$home_real") || {
    echo "  home: error - could not resolve per-home lock"
    return 1
  }
  fm_lock_acquire_wait "$home_lock" || {
    echo "  home: error - could not acquire per-home lock"
    return 1
  }
  if ! fm_secondmate_lifecycle_identity_matches "$STATE" "$id" "$home_real" "$window" \
    "$endpoint_generation" "$provider_identity"; then
    fm_lock_release "$home_lock" || true
    return 1
  fi
  if fm_config_reread_retry_queue_is_full "$FM_HOME" "$id"; then
    fm_config_reread_retry_pending "$id" "$home_real" || true
    if ! fm_secondmate_lifecycle_identity_matches "$STATE" "$id" "$home_real" "$window" \
      "$endpoint_generation" "$provider_identity" \
      || fm_config_reread_retry_queue_is_full "$FM_HOME" "$id"; then
      echo "  home: error - config reread retry queue is full or lifecycle changed"
      fm_lock_release "$home_lock" || true
      return 1
    fi
  fi
  report=$(mktemp "${TMPDIR:-/tmp}/fm-config-push-report.XXXXXX" 2>/dev/null) || {
    echo "  home: error - could not create report file"
    fm_lock_release "$home_lock" || true
    return 1
  }
  reports="$reports $report"
  if ! fm_secondmate_lifecycle_identity_matches "$STATE" "$id" "$home_real" "$window" \
    "$endpoint_generation" "$provider_identity"; then
    fm_lock_release "$home_lock" || true
    return 1
  fi
  if FM_CONFIG_INHERIT_REPORT="$report" \
    propagate_secondmate_inheritance "$FM_HOME" "$home_real" "$CONFIG" "$DATA"; then
    print_item_report "$report"
  else
    rc=1
    print_item_report "$report"
  fi
  if ! fm_secondmate_lifecycle_identity_matches "$STATE" "$id" "$home_real" "$window" \
    "$endpoint_generation" "$provider_identity"; then
    fm_lock_release "$home_lock" || true
    return 1
  fi
  if ! reread_out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
    FM_STATE_OVERRIDE="$STATE" \
    fm_config_send_reread_nudge "$id" "$home_real" "$report" 2>&1); then
    rc=1
    if [ -n "$reread_out" ]; then
      printf '%s\n' "$reread_out"
    else
      printf 'CONFIG_REREAD: secondmate %s: send failed: unknown error\n' "$id"
    fi
  elif [ -n "$reread_out" ]; then
    printf '%s\n' "$reread_out"
  fi
  fm_lock_release "$home_lock" || true
  return "$rc"
}

seen_homes=""
errors=0
while IFS='|' read -r id home window meta endpoint_generation provider_identity; do
  [ -n "$id" ] || continue
  if [ -z "$home" ]; then
    printf 'secondmate %s: skipped - no home= in %s and no registry home\n' "$id" "$meta"
    continue
  fi
  if ! validate_secondmate_home "$id" "$home"; then
    printf 'secondmate %s (%s): skipped - unsafe home: %s\n' "$id" "$home" "$VALIDATION_ERROR"
    continue
  fi
  home_real="$VALIDATED_HOME"
  case " $seen_homes " in
    *" $home_real "*)
      printf 'secondmate %s (%s): skipped - already processed for another live meta\n' "$id" "$home_real"
      continue
      ;;
  esac
  seen_homes="$seen_homes $home_real"

  fm_ff_locked_secondmate_action "$id" "$home_real" "secondmate $id" \
    config_push_locked "$window" "$endpoint_generation" "$provider_identity" || {
      echo "  home: error - lifecycle identity changed or lock is busy"
      errors=1
    }
done < "$records"

[ "$errors" -eq 0 ] || exit 1
exit 0
