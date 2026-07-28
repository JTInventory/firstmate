#!/usr/bin/env bash
# Self-update a running firstmate and its secondmates to the latest origin.
#
# Mechanical half of the /updatefirstmate skill. Fast-forwards the running
# firstmate repo's default branch from origin, then fast-forwards every
# registered secondmate home (each a treehouse worktree of this same repo, or
# a standalone clone) the same way. FAST-FORWARD ONLY, exactly like
# fm-fleet-sync.sh: never force, never create a merge commit, never stash;
# advance a target only when it is a clean fast-forward, otherwise skip and
# report. A tracked-files fast-forward never touches the gitignored operational
# dirs (data/, state/, config/, projects/, .no-mistakes/), so a secondmate's
# in-flight work is never disrupted. Worktrees of this repo share one object
# store, so a single fetch refreshes them all; standalone-clone homes are
# fetched on their own. Secondmate homes are leased at a detached HEAD on the
# default branch, so a fast-forward there advances HEAD only and never touches
# any other worktree's checkout or the shared `main` branch.
#
# The fast-forward mechanics live in bin/fm-ff-lib.sh (base_mode "origin" here);
# the same library drives the local-HEAD secondmate sync used by fm-spawn.sh and
# fm-bootstrap.sh, so there is one ff implementation, not several.
#
# It does NOT re-read AGENTS.md or nudge secondmates itself - those are LLM /
# tmux actions the skill performs. The script's job is the safe git mechanics
# plus a parseable summary telling the caller what to do next:
#   - one status line per target (updated/already current/skipped)
#   - reread-firstmate: yes|no    (did the running firstmate's instructions change)
#   - restart-firstmate-watcher: yes|no
#   - restart-secondmate-watchers: <window-targets...>|none
#   - nudge-secondmates: <window-targets...>|none   (updated live secondmates to nudge)
#
# Usage: fm-update.sh [--help|--ack-reread-firstmate <generation>|--ack-secondmate-nudge <target> <generation>|--deliver-secondmate-nudge <target> <generation>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
fm_worker_refuse_primary_operation "update" || exit 1
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SECONDMATES_MD="$FM_HOME/data/secondmates.md"
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-watcher-protocol-lib.sh
. "$SCRIPT_DIR/fm-watcher-protocol-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-delivery-lib.sh
. "$SCRIPT_DIR/fm-secondmate-delivery-lib.sh"

"$SCRIPT_DIR/fm-guard.sh" || true

FM_UPDATE_ADMISSION_LOCKS=()

fm_ff_target_lock_acquire() {
  local state_dir=$1 _label=${2:-target} target_home=${3:-} lock
  FM_UPDATE_ADMISSION_LOCKS=()
  while IFS= read -r lock; do
    [ -n "$lock" ] || continue
    mkdir -p "$(dirname "$lock")" || return 1
    if ! fm_lock_try_acquire "$lock"; then
      fm_ff_target_lock_release
      return 1
    fi
    FM_UPDATE_ADMISSION_LOCKS+=("$lock")
  done < <(fm_spawn_admission_lock_paths "$state_dir")
  if fm_spawn_legacy_task_lock_busy "$state_dir"; then
    fm_ff_target_lock_release
    return 1
  fi
  if ! fm_spawn_legacy_lifecycle_quiescent "$target_home" "$state_dir"; then
    fm_ff_target_lock_release
    return 1
  fi
}

fm_ff_target_lock_release() {
  local i
  for ((i=${#FM_UPDATE_ADMISSION_LOCKS[@]} - 1; i >= 0; i--)); do
    fm_lock_release "${FM_UPDATE_ADMISSION_LOCKS[$i]}" || true
  done
  FM_UPDATE_ADMISSION_LOCKS=()
}

trap fm_ff_target_lock_release EXIT

usage() {
  echo "usage: fm-update.sh [--help|--ack-reread-firstmate <generation>|--ack-secondmate-nudge <target> <generation>|--deliver-secondmate-nudge <target> <generation>]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi

update_live_secondmate_identity_matches() {
  local id=$1 expected=$2 target=$3 endpoint_generation=$4 provider_identity=${5:-}
  fm_secondmate_lifecycle_identity_matches "$STATE" "$id" "$expected" \
    "$target" "$endpoint_generation" "$provider_identity"
}

ack_secondmate_nudge_locked() {
  local id=$1 home=$2 target=$3 generation=$4 endpoint_generation=$5
  local provider_identity=${6:-} marker
  update_live_secondmate_identity_matches "$id" "$home" "$target" \
    "$endpoint_generation" "$provider_identity" || return 1
  marker="$home/state/.watch-protocol-reread-required"
  fm_update_obligation_ack "$marker" "$generation" "$home" || {
    echo "secondmate nudge acknowledgement: generation mismatch for $target" >&2
    return 1
  }
  echo "acknowledged-secondmate-nudge: $target"
}

ack_secondmate_nudge() {
  local target=$1 generation=$2 id="" record_id candidate home window meta
  local endpoint_generation record_generation provider_identity record_provider matches=0
  home=""
  endpoint_generation=
  while IFS='|' read -r record_id candidate window meta record_generation record_provider; do
    if [ "$window" = "$target" ]; then
      matches=$((matches + 1))
      id=$record_id
      home=$candidate
      endpoint_generation=$record_generation
      provider_identity=$record_provider
    fi
  done < <(live_secondmate_meta_records "$STATE" "$SECONDMATES_MD")
  [ "$matches" -eq 1 ] || {
    echo "secondmate nudge acknowledgement: target is not uniquely live: $target" >&2
    return 1
  }
  validate_secondmate_home "$id" "$home" || {
    echo "secondmate nudge acknowledgement: unsafe home for $target: $VALIDATION_ERROR" >&2
    return 1
  }
  fm_ff_locked_secondmate_action "$id" "$VALIDATED_HOME" "secondmate $id" \
    ack_secondmate_nudge_locked "$target" "$generation" "$endpoint_generation" \
      "$provider_identity" || {
      echo "secondmate nudge acknowledgement: lifecycle identity changed or lock is busy for $target" >&2
      return 1
    }
}

deliver_secondmate_nudge_locked() {
  local id=$1 home=$2 target=$3 generation=$4 endpoint_generation=$5
  local provider_identity=$6 marker receipt
  update_live_secondmate_identity_matches "$id" "$home" "$target" \
    "$endpoint_generation" "$provider_identity" || return 1
  marker="$home/state/.watch-protocol-reread-required"
  [ "$(fm_update_obligation_generation "$marker" "$home" 2>/dev/null || true)" = "$generation" ] || {
    echo "secondmate nudge delivery: generation mismatch for $target" >&2
    return 1
  }
  fm_secondmate_delivery_send_locked "$STATE" "$FM_HOME" "$id" "$home" "$target" \
    "$endpoint_generation" "$provider_identity" update-nudge "$generation" \
    'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.' \
    || return $?
  receipt=$FM_SECONDMATE_DELIVERY_RECEIPT
  update_live_secondmate_identity_matches "$id" "$home" "$target" \
    "$endpoint_generation" "$provider_identity" || return 1
  fm_update_obligation_ack "$marker" "$generation" "$home" || return 1
  fm_secondmate_delivery_finish "$receipt" || return 1
  echo "delivered-secondmate-nudge: $target"
}

deliver_secondmate_nudge() {
  local target=$1 generation=$2 id= record_id home= candidate window meta
  local endpoint_generation= record_generation provider_identity= record_provider matches=0
  while IFS='|' read -r record_id candidate window meta record_generation record_provider; do
    [ "$window" = "$target" ] || continue
    matches=$((matches + 1))
    id=$record_id
    home=$candidate
    endpoint_generation=$record_generation
    provider_identity=$record_provider
  done < <(live_secondmate_meta_records "$STATE" "$SECONDMATES_MD")
  [ "$matches" -eq 1 ] || {
    echo "secondmate nudge delivery: target is not uniquely live: $target" >&2
    return 1
  }
  validate_secondmate_home "$id" "$home" || {
    echo "secondmate nudge delivery: unsafe home for $target: $VALIDATION_ERROR" >&2
    return 1
  }
  fm_ff_locked_secondmate_action "$id" "$VALIDATED_HOME" "secondmate $id" \
    deliver_secondmate_nudge_locked "$target" "$generation" "$endpoint_generation" \
      "$provider_identity" || {
      echo "secondmate nudge delivery: lifecycle identity changed or lock is busy for $target" >&2
      return 1
    }
}

case "${1:-}" in
  --ack-reread-firstmate)
    [ $# -eq 2 ] || { usage; exit 1; }
    fm_update_obligation_ack "$(fm_watcher_protocol_reread_marker "$STATE")" "$2" "$FM_ROOT" || {
      echo "firstmate reread acknowledgement: generation mismatch" >&2
      exit 1
    }
    echo "acknowledged-reread-firstmate: yes"
    exit 0
    ;;
  --ack-secondmate-nudge)
    [ $# -eq 3 ] || { usage; exit 1; }
    ack_secondmate_nudge "$2" "$3"
    exit $?
    ;;
  --deliver-secondmate-nudge)
    [ $# -eq 3 ] || { usage; exit 1; }
    deliver_secondmate_nudge "$2" "$3"
    exit $?
    ;;
  '')
    ;;
  *)
    usage
    exit 1
    ;;
esac

# --- main firstmate repo ---------------------------------------------------

reread_firstmate="no"
reread_firstmate_generation=""
restart_firstmate_watcher="no"
reread_marker=$(fm_watcher_protocol_reread_marker "$STATE")
fm_update_obligation_pending "$reread_marker" "$FM_ROOT" && reread_firstmate="yes"
if fm_ff_target_lock_acquire "$STATE" firstmate "$FM_HOME"; then
  ff_target "$FM_ROOT" "firstmate" origin no no "$reread_marker" instructions
  fm_ff_target_lock_release
else
  FF_STATUS=skipped
  FF_OBLIGATION_GENERATION=
  echo "firstmate: skipped: spawn or teardown is active"
fi
reread_firstmate_generation=$FF_OBLIGATION_GENERATION
if [ "$FF_STATUS" = "updated" ]; then
  installed_update="$FM_ROOT/bin/fm-update.sh"
  script_root=$(cd "$SCRIPT_DIR/.." && pwd -P)
  root_real=$(cd "$FM_ROOT" && pwd -P)
  if [ "${FM_UPDATE_REEXECED:-0}" != 1 ] \
    && [ "$script_root" = "$root_real" ] \
    && [ -x "$installed_update" ]; then
    export FM_UPDATE_REEXECED=1
    export FM_HOME
    export FM_ROOT_OVERRIDE="$FM_ROOT"
    export FM_STATE_OVERRIDE="$STATE"
    exec "$installed_update"
  fi
fi
fm_update_obligation_pending "$reread_marker" "$FM_ROOT" && reread_firstmate="yes"
if ! fm_watcher_protocol_restart_if_required "$FM_HOME" "$STATE" "$FM_ROOT"; then
  echo "firstmate: skipped: watcher protocol restart could not be verified" >&2
  exit 1
fi
if [ "$FM_WATCHER_PROTOCOL_RESTARTED" -eq 1 ]; then
  restart_firstmate_watcher="yes"
fi

# --- secondmates -----------------------------------------------------------
# An updated live secondmate is nudged whenever it advanced (nudge_requires_instr
# is "no" here): /updatefirstmate's nudge is a gentle re-read steer, kept on the
# same condition it has always used.

FF_NUDGE_WINDOWS=""
FF_NUDGE_GENERATIONS=""
FF_SEEN_HOMES=""
restart_secondmate_watchers=""

fm_ff_after_target_update() {
  local id=$1 home=$2 window=$3 endpoint_generation=$4 provider_identity=${5:-}
  [ -n "$window" ] || return 0
  update_live_secondmate_identity_matches "$id" "$home" "$window" \
    "$endpoint_generation" "$provider_identity" || return 1
  if ! fm_watcher_protocol_restart_if_required "$home" "$home/state" "$home"; then
    echo "secondmate $id: skipped: watcher protocol restart could not be verified" >&2
    return 1
  fi
  if [ "$FM_WATCHER_PROTOCOL_RESTARTED" -eq 1 ]; then
    restart_secondmate_watchers="$restart_secondmate_watchers $window"
  fi
}

# Live direct reports first: state/<id>.meta with kind=secondmate carries the
# authoritative home= path.
sweep_live_secondmate_metas "$STATE" origin no

# Registry backstop: a secondmate registered in data/secondmates.md but without
# a live meta (e.g. between restarts) is still its persistent on-disk home.
if [ -f "$SECONDMATES_MD" ]; then
  while IFS= read -r line; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    id=$(printf '%s\n' "$line" | sed -n 's/^- \([^ ][^ ]*\) - .*/\1/p')
    home=$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;]*\);.*/\1/p' | sed 's/[[:space:]]*$//')
    [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || continue
    process_secondmate "$id" "$home" "" origin no
  done < "$SECONDMATES_MD"
fi
unset -f fm_ff_after_target_update

# --- caller action summary -------------------------------------------------

echo "reread-firstmate: $reread_firstmate"
echo "reread-firstmate-generation: ${reread_firstmate_generation:-none}"
echo "restart-firstmate-watcher: $restart_firstmate_watcher"
echo "restart-secondmate-watchers:${restart_secondmate_watchers:- none}"
echo "nudge-secondmates:${FF_NUDGE_WINDOWS:- none}"
while IFS='|' read -r target generation; do
  [ -n "$target" ] || continue
  echo "nudge-secondmate-generation: $target|$generation"
done <<< "$FF_NUDGE_GENERATIONS"
