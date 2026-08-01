#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: fm-bootstrap.sh
#          Detect: prints one line per actionable problem, or an explicit
#          BOOTSTRAP_INFO no-action fact for completed benign bootstrap work, and
#          exits 0.
#          Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)",
#                 "MISSING_MANUAL: <tool> (instructions: <url>)", "NEEDS_GH_AUTH",
#                 "BACKEND_INVALID: <name> (known: <names>)",
#                 "CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>",
#                 "FLEET_SYNC: <repo>: skipped|recovered|STUCK: <detail>",
#                 "PR_CHECK_MIGRATION: <private remediation>",
#                 "TANGLE: <remediation>",
#                 "ISOLATION: task <id> <collapse or ownership finding>",
#                 "SECONDMATE_SYNC: secondmate <id>: skipped: <reason>",
#                 "NUDGE_SECONDMATES: secondmate <id>: send failed: <reason>",
#                 "BOOTSTRAP_INFO: nudged fm-<id> with '<message>'",
#                 "SECONDMATE_LIVENESS: secondmate <id>: skipped: <reason>|respawn failed after <cause>: <reason>",
#                 "FMX: X mode on ..." or "FMX: X mode off ...".
#          When a RUNNING secondmate worktree is fast-forwarded to firstmate's
#          own current default-branch commit (a purely LOCAL fast-forward, never
#          an origin fetch) AND its loaded instruction surface (AGENTS.md, bin/,
#          or .agents/skills/) actually changed, bootstrap immediately nudges it
#          via FM_HOME=<active-home> bin/fm-send.sh fm-<id> so meta resolves the
#          current backend target and the standard from-firstmate marker is
#          applied. A successful send prints one BOOTSTRAP_INFO line with the
#          exact target and message sent; a failed send leaves an idempotent
#          retry marker under state/.secondmate-nudge-pending/ and prints an
#          actionable NUDGE_SECONDMATES line.
#          Already-current or no-instruction-change homes are silently left alone.
#          The secondmate sweep also propagates declared inherited local material
#          into each validated live secondmate home.
#          SECONDMATE_SYNC lines report actionable skipped local-HEAD syncs or
#          inheritance failures for live secondmate homes, plus quarantine
#          diagnostics for divergent shared captain-preference copies;
#          no-op/current and successful updates stay quiet.
#          SECONDMATE_LIVENESS lines report only actionable failures from the
#          recovery-grade state owned by bin/fm-backend.sh's
#          fm_backend_agent_state: skipped distinguishes an existing ambiguous
#          process, an unreadable target, and an unverified backend; respawn
#          failed names whether the endpoint was missing or agent-less.
#          Already-live and successfully relaunched secondmates are silent
#          unless FM_BOOTSTRAP_VERBOSE_FACTS=1 requests BOOTSTRAP_INFO facts.
#          An ISOLATION line means a task's process isolation is violated or
#          cannot be authoritatively proven. It is read-only, runs in
#          detect-only mode too, and never promotes a pane path to proof.
#          A TANGLE line means the firstmate primary checkout (FM_ROOT) is stranded
#          on a feature branch instead of its default branch - a crewmate's work
#          landed in the primary instead of its own worktree; restore it per the line.
#          treehouse is also MISSING when its installed version lacks
#          "treehouse get --lease" support.
#          no-mistakes is also MISSING when its installed version is older than
#          1.31.2.
#          tasks-axi and quota-axi are required bootstrap tools (same class as
#          lavish-axi). tasks-axi is also version and feature gated (0.1.1+
#          with update --archive-body and mv [<id>...]); an installed but
#          incompatible build reports MISSING like no-mistakes. A compatible
#          tasks-axi default backend is silent. quota-axi is required for the
#          agent-owned dispatch-profile array procedure in AGENTS.md section 4.
#          X mode is OPTIONAL and inert unless FM_HOME/.env has a non-empty
#          FMX_PAIRING_TOKEN. When opted in, bootstrap requires curl+jq, writes
#          the relay poll shim and 30s cadence config, and prints an FMX line.
#          Fleet sync fetches, fast-forwards safe default-branch states, reports
#          recovered and STUCK clone drift, and prunes gone local branches; it is
#          bounded by FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT when it is a non-empty
#          numeric override, while non-numeric values fall back to 20s.
#          When the override is unset or blank, the timeout is
#          max(20, 5 + 3 * origin-backed project clone count). A timed-out
#          refresh relays any completed fm-fleet-sync.sh output before the
#          aggregate timeout skip line with timeout and elapsed seconds.
#          Set FM_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#          Set FM_BOOTSTRAP_DETECT_ONLY=1 to skip the five MUTATING sweeps
#          (PR-check migration, secondmate_sync, secondmate_liveness_sweep,
#          x_mode_setup, fleet_sync) while still printing every read-only detect line
#          above; the TANGLE line switches to advisory-only wording with no
#          checkout command. Used by
#          fm-session-start.sh's read-only path when another live session holds
#          the fleet lock, so a second concurrent session never race-mutates
#          PR-check artifacts, secondmate homes, X-mode artifacts, project
#          clones, or repair instructions.
#          Unset/0 (the default) runs every sweep exactly as before - this flag
#          is purely additive.
#        fm-bootstrap.sh install <tool>...
#          Install the named tools (only ones the captain approved).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_MODE=${1:-bootstrap}
BOOTSTRAP_READ_ONLY=0
if [ "$BOOTSTRAP_MODE" != install ] && [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ]; then
  BOOTSTRAP_READ_ONLY=1
fi
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
if [ "$BOOTSTRAP_READ_ONLY" != 1 ]; then
  fm_worker_refuse_primary_operation "bootstrap" || exit 1
fi
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FM_WAKE_LIB_READ_ONLY=1
export FM_WAKE_LIB_READ_ONLY
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-delivery-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-secondmate-delivery-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-x-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
if [ "$BOOTSTRAP_READ_ONLY" != 1 ]; then
  # shellcheck source=bin/fm-watcher-protocol-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-watcher-protocol-lib.sh"
fi

fleet_sync_origin_backed_project_count() {
  local count proj
  count=0
  [ -d "$PROJECTS" ] || { echo 0; return 0; }
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || continue
    git -C "$proj" remote get-url origin >/dev/null 2>&1 || continue
    count=$((count + 1))
  done
  echo "$count"
}

fleet_sync_bootstrap_timeout() {
  local count timeout
  if [ -n "${FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-}" ]; then
    case "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" in
      *[!0-9]*) echo 20 ;;
      *) echo "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" ;;
    esac
    return 0
  fi

  count=$(fleet_sync_origin_backed_project_count)
  timeout=$((5 + (3 * count)))
  [ "$timeout" -ge 20 ] || timeout=20
  echo "$timeout"
}

fleet_sync_relay_filtered_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
      *': STUCK:'*) echo "FLEET_SYNC: $line" ;;
      *': recovered:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
}

fleet_sync_relay_all_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "FLEET_SYNC: $line"
  done < "$tmp"
}

fleet_sync() {
  [ -x "$FM_ROOT/bin/fm-fleet-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  timeout=$(fleet_sync_bootstrap_timeout)
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$FM_ROOT/bin/fm-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      fleet_sync_relay_all_output "$tmp"
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=${timeout}s elapsed=${elapsed}s)"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  fleet_sync_relay_filtered_output "$tmp"
  rm -f "$tmp"
}

secondmate_sync() {
  local -a bootstrap_admission_locks=()
  fm_ff_target_lock_acquire() {
    local state_dir=$1 _label=${2:-target} target_home=${3:-}
    fm_lifecycle_admission_acquire bootstrap_admission_locks \
      "$state_dir" "$target_home" "${BASHPID:-$$}"
  }
  fm_ff_target_lock_release() {
    fm_lifecycle_admission_release bootstrap_admission_locks
  }
  # Local-HEAD secondmate sync: fast-forward every LIVE secondmate home
  # to the primary checkout's current default-branch commit. Purely LOCAL - no
  # fetch, no origin dependency: a linked-worktree home already holds the primary's
  # commit (fm-ff-lib.sh), while a standalone clone without it is skipped until
  # /updatefirstmate refreshes it from origin. Startup sends reread nudges only
  # for RUNNING secondmates whose instruction surface (AGENTS.md, bin/, or
  # .agents/skills/) actually changed, so a secondmate already on the primary's
  # version is never disturbed (AGENTS.md bootstrap + supervision). Unlike
  # /updatefirstmate, startup owns the live-convergence send itself because it is
  # a deterministic locked sweep and can report success as BOOTSTRAP_INFO while
  # preserving failed sends as NUDGE_SECONDMATES retry markers.
  [ -d "$STATE" ] || return 0
  local primary_head
  if ! primary_head=$(primary_head_commit "$FM_ROOT"); then
    local meta id
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      grep -q '^kind=secondmate' "$meta" 2>/dev/null || continue
      id=$(basename "$meta" .meta)
      echo "SECONDMATE_SYNC: secondmate $id: skipped: primary default-branch commit cannot be resolved"
    done
    return 0
  fi
  FF_NUDGE_WINDOWS=""
  FF_NUDGE_GENERATIONS=""
  FF_SEEN_HOMES=""
  SECOND_MATE_NUDGE_MESSAGE='firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
  SECOND_MATE_NUDGE_PENDING_DIR="$STATE/.secondmate-nudge-pending"

  secondmate_nudge_marker_path() {
    case "$1" in
      *[!/A-Za-z0-9._-]*|""|*/*) return 1 ;;
    esac
    printf '%s/%s.pending' "$SECOND_MATE_NUDGE_PENDING_DIR" "$1"
  }

  secondmate_write_nudge_marker() {
    local id=$1 home=$2 window=$3 endpoint_generation=$4 commit=$5 instr=$6
    local selector marker tmp parent
    selector="fm-$id"
    marker=$(secondmate_nudge_marker_path "$id") || return 1
    parent=${marker%/*}
    mkdir -p "$parent" || return 1
    tmp=$(mktemp "$parent/.nudge.XXXXXX" 2>/dev/null) || return 1
    {
      printf 'id=%s\n' "$id"
      printf 'selector=%s\n' "$selector"
      printf 'home=%s\n' "$home"
      printf 'window=%s\n' "$window"
      printf 'endpoint_generation=%s\n' "$endpoint_generation"
      printf 'commit=%s\n' "$commit"
      printf 'instructions=%s\n' "$instr"
      printf 'message=%s\n' "$SECOND_MATE_NUDGE_MESSAGE"
    } > "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$marker" || { rm -f "$tmp"; return 1; }
  }

  secondmate_locked_identity_matches() {
    local id=$1 expected=$2 window=$3 endpoint_generation=$4 provider_identity=${5:-}
    fm_secondmate_lifecycle_identity_matches "$STATE" "$id" "$expected" \
      "$window" "$endpoint_generation" "$provider_identity"
  }

  secondmate_send_nudge() {
    local id=$1 home=$2 window=$3 endpoint_generation=$4 provider_identity=$5 commit=$6 instr=$7
    local selector marker receipt
    secondmate_locked_identity_matches "$id" "$home" "$window" \
      "$endpoint_generation" "$provider_identity" || return 1
    selector="fm-$id"
    marker=$(secondmate_nudge_marker_path "$id") || {
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: unsafe id"
      return 0
    }
    if ! secondmate_write_nudge_marker "$id" "$home" "$window" \
      "$endpoint_generation" "$commit" "$instr"; then
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: cannot record retry marker"
      return 0
    fi
    secondmate_locked_identity_matches "$id" "$home" "$window" \
      "$endpoint_generation" "$provider_identity" || return 1
    if fm_secondmate_delivery_send_locked "$STATE" "$FM_HOME" "$id" "$home" "$window" \
      "$endpoint_generation" "$provider_identity" update-nudge "$commit" \
      "$SECOND_MATE_NUDGE_MESSAGE"; then
      receipt=$FM_SECONDMATE_DELIVERY_RECEIPT
      secondmate_locked_identity_matches "$id" "$home" "$window" \
        "$endpoint_generation" "$provider_identity" || return 1
      fm_secondmate_delivery_finalize_update "$receipt" \
        "$home/state/.watch-protocol-reread-required" "$commit" "$home" "$marker" \
        || return 1
      echo "BOOTSTRAP_INFO: nudged $selector with '$SECOND_MATE_NUDGE_MESSAGE'"
    else
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: delivery is unconfirmed"
    fi
  }

  fm_ff_after_target_update() {
    local id=$1 home=$2 window=$3 endpoint_generation=$4 provider_identity=${5:-}
    secondmate_locked_identity_matches "$id" "$home" "$window" \
      "$endpoint_generation" "$provider_identity" || return 1
    if ! fm_watcher_protocol_restart_if_required "$home" "$home/state" "$home"; then
      echo "SECONDMATE_SYNC: secondmate $id: skipped: watcher protocol restart could not be verified"
      return 1
    fi
    if [ "$FM_WATCHER_PROTOCOL_RESTARTED" -eq 1 ]; then
      echo "BOOTSTRAP_INFO: restarted and verified fm-$id watcher"
    fi
  }

  fm_ff_after_instruction_update() {
    local id=$1 home=$2 window=$3 instr=$4 endpoint_generation=$5
    local provider_identity=${6:-}
    secondmate_locked_identity_matches "$id" "$home" "$window" \
      "$endpoint_generation" "$provider_identity" || return 1
    secondmate_send_nudge "$id" "$home" "$window" "$endpoint_generation" \
      "$provider_identity" "$primary_head" "$instr"
  }

  secondmate_retry_pending_nudge_locked() {
    local id=$1 home=$2 marker=$3 selector=$4 commit=$5 window=$6
    local endpoint_generation=$7 provider_identity receipt
    secondmate_locked_identity_matches "$id" "$home" "$window" \
      "$endpoint_generation" || return 1
    provider_identity=$FM_SECONDMATE_META_PROVIDER_IDENTITY
    [ "$(git -C "$home" rev-parse HEAD 2>/dev/null || true)" = "$commit" ] || return 1
    if fm_secondmate_delivery_send_locked "$STATE" "$FM_HOME" "$id" "$home" "$window" \
      "$endpoint_generation" "$provider_identity" update-nudge "$commit" \
      "$SECOND_MATE_NUDGE_MESSAGE"; then
      receipt=$FM_SECONDMATE_DELIVERY_RECEIPT
      secondmate_locked_identity_matches "$id" "$home" "$window" \
        "$endpoint_generation" "$provider_identity" || return 1
      fm_secondmate_delivery_finalize_update "$receipt" \
        "$home/state/.watch-protocol-reread-required" "$commit" "$home" "$marker" \
        || return 1
      echo "BOOTSTRAP_INFO: nudged $selector with '$SECOND_MATE_NUDGE_MESSAGE'"
    else
      echo "NUDGE_SECONDMATES: secondmate $id: send failed: delivery is unconfirmed"
    fi
  }

  secondmate_retry_marker_read() {
    local marker=$1 key count
    [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
    [ "$(wc -l < "$marker" | tr -d ' ')" -eq 8 ] || return 1
    for key in id selector home window endpoint_generation commit instructions message; do
      count=$(grep -c "^${key}=" "$marker" 2>/dev/null || true)
      [ "$count" -eq 1 ] || return 1
    done
    RETRY_ID=$(sed -n 's/^id=//p' "$marker")
    RETRY_SELECTOR=$(sed -n 's/^selector=//p' "$marker")
    RETRY_HOME=$(sed -n 's/^home=//p' "$marker")
    RETRY_WINDOW=$(sed -n 's/^window=//p' "$marker")
    RETRY_ENDPOINT_GENERATION=$(sed -n 's/^endpoint_generation=//p' "$marker")
    RETRY_COMMIT=$(sed -n 's/^commit=//p' "$marker")
    RETRY_MESSAGE=$(sed -n 's/^message=//p' "$marker")
    [ -n "$RETRY_ID" ] && [ -n "$RETRY_SELECTOR" ] && [ -n "$RETRY_HOME" ] \
      && [ -n "$RETRY_WINDOW" ] && [ -n "$RETRY_ENDPOINT_GENERATION" ] \
      && [ -n "$RETRY_COMMIT" ] && [ -n "$RETRY_MESSAGE" ]
  }

  secondmate_retry_pending_nudges() {
    local marker id selector home commit message window endpoint_generation
    local expected_marker home_real head
    [ -d "$SECOND_MATE_NUDGE_PENDING_DIR" ] || return 0
    for marker in "$SECOND_MATE_NUDGE_PENDING_DIR"/*.pending; do
      [ -f "$marker" ] || continue
      if ! secondmate_retry_marker_read "$marker"; then
        echo "NUDGE_SECONDMATES: secondmate unknown: send failed: retry marker is ambiguous"
        continue
      fi
      id=$RETRY_ID
      if ! expected_marker=$(secondmate_nudge_marker_path "$id"); then
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker has unsafe id"
        continue
      fi
      [ "$expected_marker" = "$marker" ] || {
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry marker filename mismatch"
        continue
      }
      selector=$RETRY_SELECTOR
      home=$RETRY_HOME
      window=$RETRY_WINDOW
      endpoint_generation=$RETRY_ENDPOINT_GENERATION
      commit=$RETRY_COMMIT
      message=$RETRY_MESSAGE
      [ "$selector" = "fm-$id" ] || {
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker selector mismatch"
        continue
      }
      [ "$message" = "$SECOND_MATE_NUDGE_MESSAGE" ] || {
        echo "NUDGE_SECONDMATES: secondmate ${id:-unknown}: send failed: retry marker message mismatch"
        continue
      }
      if ! validate_secondmate_home "$id" "$home"; then
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry target home unsafe: $VALIDATION_ERROR"
        continue
      fi
      home_real="$VALIDATED_HOME"
      if ! secondmate_locked_identity_matches "$id" "$home_real" "$window" \
        "$endpoint_generation"; then
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry target lifecycle changed"
        continue
      fi
      head=$(git -C "$home_real" rev-parse HEAD 2>/dev/null || true)
      [ -n "$head" ] && [ "$head" = "$commit" ] || {
        echo "NUDGE_SECONDMATES: secondmate $id: send failed: retry target is not at recorded instruction commit"
        continue
      }
      fm_ff_locked_secondmate_action "$id" "$home_real" "secondmate $id" \
        secondmate_retry_pending_nudge_locked "$marker" "$selector" "$commit" \
        "$window" "$endpoint_generation" \
        || echo "NUDGE_SECONDMATES: secondmate $id: send failed: lifecycle identity changed or lock is busy"
    done
  }

  local tmp line
  secondmate_retry_pending_nudges
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-secondmate-sync.XXXXXX" 2>/dev/null) || return 0
  local sync_status=0
  sweep_live_secondmate_metas "$STATE" "$primary_head" yes "$DATA/secondmates.md" >"$tmp" \
    || sync_status=$?
  while IFS= read -r line; do
    case "$line" in
      secondmate\ *': skipped:'*) echo "SECONDMATE_SYNC: $line" ;;
      BOOTSTRAP_INFO:\ *) echo "$line" ;;
      NUDGE_SECONDMATES:\ *) echo "$line" ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  if [ "$sync_status" -ne 0 ]; then
    fm_ff_target_lock_release
    unset -f fm_ff_after_instruction_update fm_ff_after_target_update \
      fm_ff_target_lock_acquire fm_ff_target_lock_release
    return "$sync_status"
  fi
  unset -f fm_ff_after_instruction_update fm_ff_after_target_update
  # Inheritance propagation: push the primary-authoritative local inheritance
  # surface into every VALIDATED live secondmate home swept above.
  # FF_SEEN_HOMES is exactly that set, and fm-config-inherit-lib.sh owns the
  # declared config items plus data/captain-shared.md.
  # After a successful push that changes allowlisted config/* for an already-
  # running home, send its literal-content reread instruction pointer so the
  # live agent does not keep applying stale defaults. Spawn/respawn already
  # re-reads at launch and needs no redundant nudge unless files changed after launch.
  secondmate_propagate_locked() {
    local id=$1 home_real=$2 window=$3 endpoint_generation=$4 provider_identity=$5
    local reread_skip_pending=$6
    local home_lock report reread_out
    secondmate_locked_identity_matches "$id" "$home_real" "$window" \
      "$endpoint_generation" "$provider_identity" || return 1
    home_lock=$(fm_config_inherit_lock_path "$home_real") || {
      echo "CONFIG_REREAD: secondmate $id: send failed: could not resolve per-home lock"
      return 1
    }
    fm_lock_acquire_wait "$home_lock" || {
      echo "CONFIG_REREAD: secondmate $id: send failed: could not acquire per-home lock"
      return 1
    }
    if ! secondmate_locked_identity_matches "$id" "$home_real" "$window" \
      "$endpoint_generation" "$provider_identity"; then
      fm_lock_release "$home_lock" || true
      return 1
    fi
    if [ "$reread_skip_pending" -eq 0 ] \
      && fm_config_reread_retry_queue_is_full "$FM_HOME" "$id"; then
      fm_config_reread_retry_pending "$id" "$home_real" "$window" \
        "$endpoint_generation" "$provider_identity" || true
      if fm_config_reread_retry_queue_is_full "$FM_HOME" "$id"; then
        echo "CONFIG_REREAD: secondmate $id: send failed: retry instruction queue is full"
        fm_lock_release "$home_lock" || true
        return 1
      fi
    fi
    report=$(mktemp "${TMPDIR:-/tmp}/fm-bootstrap-inherit.XXXXXX" 2>/dev/null) || {
      echo "SECONDMATE_SYNC: secondmate $id: skipped: inheritance failed"
      fm_lock_release "$home_lock" || true
      return 1
    }
    if FM_CONFIG_INHERIT_REPORT="$report" \
      propagate_secondmate_inheritance "$FM_HOME" "$home_real" "$CONFIG" "$DATA"; then
      :
    else
      echo "SECONDMATE_SYNC: secondmate $id: skipped: inheritance failed"
    fi
    if ! secondmate_locked_identity_matches "$id" "$home_real" "$window" \
      "$endpoint_generation" "$provider_identity"; then
      rm -f "$report"
      fm_lock_release "$home_lock" || true
      return 1
    fi
    if ! reread_out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" \
      FM_STATE_OVERRIDE="$STATE" \
      FM_CONFIG_REREAD_SKIP_PENDING="$reread_skip_pending" \
      fm_config_send_reread_nudge "$id" "$home_real" "$report" "$window" \
        "$endpoint_generation" "$provider_identity" 2>&1); then
      if [ -n "$reread_out" ]; then
        printf '%s\n' "$reread_out"
      else
        echo "CONFIG_REREAD: secondmate $id: send failed: unknown error"
      fi
    elif [ -n "$reread_out" ]; then
      printf '%s\n' "$reread_out"
    fi
    rm -f "$report"
    fm_lock_release "$home_lock" || true
  }

  local id home window endpoint_generation provider_identity home_real
  local propagated_homes reread_skip_pending
  propagated_homes=""
  SECONDMATE_RESPAWNED_IDS=${SECONDMATE_RESPAWNED_IDS:-}
  while IFS='|' read -r id home window _meta endpoint_generation provider_identity; do
    validate_secondmate_home "$id" "$home" || continue
    home_real="$VALIDATED_HOME"
    case " $FF_SEEN_HOMES " in
      *" $home_real "*) ;;
      *) continue ;;
    esac
    case " $propagated_homes " in
      *" $home_real "*) continue ;;
    esac
    propagated_homes="$propagated_homes $home_real"
    reread_skip_pending=0
    case " $SECONDMATE_RESPAWNED_IDS " in
      *" $id "*) reread_skip_pending=1 ;;
    esac
    fm_ff_locked_secondmate_action "$id" "$home_real" "secondmate $id" \
      secondmate_propagate_locked "$window" "$endpoint_generation" \
        "$provider_identity" "$reread_skip_pending" \
      || echo "SECONDMATE_SYNC: secondmate $id: skipped: lifecycle identity changed or lock is busy"
  done < <(live_secondmate_meta_records "$STATE" "$DATA/secondmates.md")
  fm_ff_target_lock_release
  unset -f fm_ff_target_lock_acquire fm_ff_target_lock_release
  return 0
}

secondmate_liveness_sweep() {
  # Idempotent secondmate liveness guarantee - SESSION START ONLY. The detailed
  # state machine and its only recovery-authorizing states are owned by
  # fm_backend_agent_state. A missing tmux pane is not enough: tmux must prove
  # the window or session absent. This preserves duplicate prevention for
  # existing ambiguous processes and every transiently unreadable target while
  # adding the missing-session path the original bare-shell and Herdr-husk sweep
  # lacked.
  # A meta with no window remains owned by secondmate-provisioning recovery.
  # Secondmate homes never contain kind=secondmate meta, so this is naturally a
  # primary-only no-op there. Mid-session liveness remains explicitly out of
  # scope and requires a separate periodic signal.
  [ -d "$STATE" ] || return 0
  local meta id home window endpoint_generation provider_identity
  local -a liveness_admission_locks=()
  fm_ff_target_lock_acquire() {
    local state_dir=$1 _label=${2:-target} target_home=${3:-}
    local lock existing primary_task seen
    liveness_admission_locks=()
    for seen in "$state_dir" "$STATE"; do
      while IFS= read -r lock; do
        [ -n "$lock" ] || continue
        for existing in "${liveness_admission_locks[@]}"; do
          [ "$existing" != "$lock" ] || continue 2
        done
        mkdir -p "$(dirname "$lock")" || {
          fm_ff_target_lock_release
          return 1
        }
        if fm_lifecycle_admission_lock_owned_by_process "$lock"; then
          continue
        fi
        if ! fm_lock_try_acquire "$lock"; then
          fm_ff_target_lock_release
          return 1
        fi
        liveness_admission_locks+=("$lock")
      done < <(fm_spawn_admission_lock_paths "$seen")
    done
    primary_task="$STATE/.spawn-${LIVENESS_LOCK_ID:?}.lock"
    if ! fm_lock_try_acquire "$primary_task"; then
      fm_ff_target_lock_release
      return 1
    fi
    liveness_admission_locks+=("$primary_task")
    if fm_spawn_legacy_task_lock_busy_except "$STATE" "$primary_task" \
      || fm_spawn_legacy_task_lock_busy "$state_dir" \
      || ! fm_spawn_legacy_lifecycle_quiescent "$FM_HOME" "$STATE" \
        "${BASHPID:-$$}" \
      || ! fm_spawn_legacy_lifecycle_quiescent "$target_home" "$state_dir" \
        "${BASHPID:-$$}"; then
      fm_ff_target_lock_release
      return 1
    fi
  }
  fm_ff_target_lock_release() {
    local i
    for ((i=${#liveness_admission_locks[@]} - 1; i >= 0; i--)); do
      fm_lock_release "${liveness_admission_locks[$i]}" || true
    done
    liveness_admission_locks=()
  }
  secondmate_liveness_locked() {
    local id=$1 locked_home=$2 expected_window=$3 expected_generation=$4
    local expected_provider=$5 harness backend target agent_state out out_file cause owner_pid owner_identity
    fm_secondmate_lifecycle_record_matches "$STATE" "$id" "$locked_home" \
      "$expected_window" "$expected_generation" "$expected_provider" || return 1
    harness=$FM_SECONDMATE_META_HARNESS
    backend=$FM_SECONDMATE_META_BACKEND
    target=$FM_SECONDMATE_META_TARGET
    agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || agent_state=unreadable
    case "$agent_state" in
      alive)
        fm_secondmate_live_endpoint_matches || return 1
        [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" != 1 ] \
          || echo "BOOTSTRAP_INFO: secondmate $id already live (backend=$backend)"
        ;;
      dead|missing)
        fm_secondmate_lifecycle_record_matches "$STATE" "$id" "$locked_home" \
          "$expected_window" "$expected_generation" "$expected_provider" || return 1
        if [ "$agent_state" = dead ]; then
          fm_secondmate_live_endpoint_matches || return 1
          cause="confirmed agent absence on existing endpoint"
          fm_backend_kill "$backend" "$target" 2>/dev/null || true
        else
          cause="recorded endpoint confidently missing"
        fi
        owner_pid=${BASHPID:-$$}
        owner_identity=$(fm_pid_identity "$owner_pid") || return 1
        out_file=$(mktemp "${TMPDIR:-/tmp}/fm-secondmate-respawn.XXXXXX") || return 1
        if FM_SPAWN_NO_GUARD=1 FM_SPAWN_PRELOCK_OWNER_PID="$owner_pid" \
          FM_SPAWN_PRELOCK_OWNER_IDENTITY="$owner_identity" \
          FM_SPAWN_PRELOCK_TASK_ID="$id" \
          "$FM_ROOT/bin/fm-spawn.sh" "$id" --secondmate >"$out_file" 2>&1; then
          SECONDMATE_RESPAWNED_IDS="$SECONDMATE_RESPAWNED_IDS $id"
          [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" != 1 ] \
            || echo "BOOTSTRAP_INFO: secondmate $id relaunched after $cause (backend=$backend)"
        else
          out=$(cat "$out_file" 2>/dev/null || true)
          echo "SECONDMATE_LIVENESS: secondmate $id: respawn failed after $cause: $(first_line "$out")"
        fi
        rm -f "$out_file"
        ;;
      ambiguous) echo "SECONDMATE_LIVENESS: secondmate $id: skipped: existing endpoint has ambiguous agent process (backend=$backend)" ;;
      unreadable) echo "SECONDMATE_LIVENESS: secondmate $id: skipped: endpoint probe unreadable (backend=$backend)" ;;
      *) echo "SECONDMATE_LIVENESS: secondmate $id: skipped: agent recovery classifier unverified (backend=$backend)" ;;
    esac
  }
  SECONDMATE_RESPAWNED_IDS=""
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    if ! fm_secondmate_lifecycle_meta_read "$meta" "$id"; then
      echo "SECONDMATE_LIVENESS: secondmate $id: refused: ${FM_SECONDMATE_META_ERROR:-ambiguous lifecycle metadata}"
      continue
    fi
    home=$FM_SECONDMATE_META_HOME
    window=$FM_SECONDMATE_META_WINDOW
    endpoint_generation=$FM_SECONDMATE_META_ENDPOINT_GENERATION
    provider_identity=$FM_SECONDMATE_META_PROVIDER_IDENTITY
    if ! validate_secondmate_home "$id" "$home"; then
      echo "SECONDMATE_LIVENESS: secondmate $id: refused: unsafe lifecycle home"
      continue
    fi
    LIVENESS_LOCK_ID=$id
    fm_ff_locked_secondmate_action "$id" "$VALIDATED_HOME" "secondmate $id" \
      secondmate_liveness_locked "$window" "$endpoint_generation" "$provider_identity" \
      || echo "SECONDMATE_LIVENESS: secondmate $id: refused: lifecycle identity changed or lock is busy"
    unset LIVENESS_LOCK_ID
  done
  unset -f fm_ff_target_lock_acquire fm_ff_target_lock_release secondmate_liveness_locked
  return 0
}

install_cmd() {
  case "$1" in
    tmux|node|git|gh|curl|jq|orca|zellij) echo "brew install $1  # or the platform's package manager" ;;
    cmux) echo "brew install --cask cmux  # or see https://cmux.com" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    no-mistakes) echo "curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi|lavish-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    tasks-axi|quota-axi) echo "npm install -g $1" ;;
    *) return 1 ;;
  esac
}

manual_install_url() {
  case "$1" in
    herdr) echo "https://herdr.dev" ;;
    *) return 1 ;;
  esac
}

missing_tool_diagnostic() {
  local tool=$1 instructions
  if instructions=$(manual_install_url "$tool"); then
    echo "MISSING_MANUAL: $tool (instructions: $instructions)"
    return 0
  fi
  echo "MISSING: $tool (install: $(install_cmd "$tool"))"
}

# Required-tool detection follows the RESOLVED backend, not a one-size default:
# a universal toolchain every home needs plus the backend-specific delta owned by
# fm_backend_required_tools (bin/fm-backend.sh). So a herdr/zellij/cmux home is
# never told tmux is missing, and only orca drops treehouse. A backend value with
# no verified dependency set is reported before the universal checks continue.
COMMON_TOOLS="node git gh no-mistakes gh-axi chrome-devtools-axi lavish-axi tasks-axi quota-axi"
BACKEND=$(fm_backend_name)
BACKEND_VALID=1
if ! BACKEND_TOOLS=$(fm_backend_required_tools "$BACKEND"); then
  BACKEND_VALID=0
  BACKEND_TOOLS=""
fi
TOOLS="$BACKEND_TOOLS $COMMON_TOOLS"
NO_MISTAKES_MIN_MAJOR=1
NO_MISTAKES_MIN_MINOR=31
NO_MISTAKES_MIN_PATCH=2

treehouse_supports_lease() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'
}

no_mistakes_version_parts() {
  local output
  command -v no-mistakes >/dev/null 2>&1 || return 1
  output=$(no-mistakes --version 2>/dev/null) || return 1
  printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1
}

no_mistakes_compatible() {
  local parts major minor patch extra
  parts=$(no_mistakes_version_parts) || return 1
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  [ "$major" -gt "$NO_MISTAKES_MIN_MAJOR" ] && return 0
  [ "$major" -eq "$NO_MISTAKES_MIN_MAJOR" ] || return 1
  [ "$minor" -gt "$NO_MISTAKES_MIN_MINOR" ] && return 0
  [ "$minor" -eq "$NO_MISTAKES_MIN_MINOR" ] || return 1
  [ "$patch" -ge "$NO_MISTAKES_MIN_PATCH" ]
}

x_mode_write_if_changed() {
  local dest=$1 content=$2 mode=$3 parent tmp parent_device current_mode
  parent=${dest%/*}
  [ "$parent" != "$dest" ] || return 1
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    parent_device=$(stat -f %d "$parent" 2>/dev/null) || return 1
  else
    parent_device=$(stat -c %d "$parent" 2>/dev/null) || return 1
  fi
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    fmx_single_link_file_valid "$dest" "$parent_device" || return 1
    if [ "$(uname)" = Darwin ]; then
      current_mode=$(stat -f %Lp "$dest" 2>/dev/null) || return 1
    else
      current_mode=$(stat -c %a "$dest" 2>/dev/null) || return 1
    fi
    if [ "$current_mode" = "$mode" ] && cmp -s "$dest" <(printf '%s\n' "$content"); then
      return 0
    fi
  fi
  tmp=$(umask 077; mktemp "$parent/.fm-x-mode.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$content" > "$tmp" \
    || ! chmod "$mode" "$tmp" \
    || ! fmx_single_link_file_mode_valid "$tmp" "$mode" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if { [ -e "$dest" ] || [ -L "$dest" ]; } \
    && ! fmx_single_link_file_valid "$dest" "$parent_device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fmx_single_link_file_mode_valid "$dest" "$mode" "$parent_device" \
    || ! cmp -s "$dest" <(printf '%s\n' "$content"); then
    rm -f -- "$dest"
    return 1
  fi
}

x_mode_artifact_present() {
  [ -e "$1" ] || [ -L "$1" ]
}

x_mode_remove_artifact() {
  local artifact=$1 parent=${1%/*}
  x_mode_artifact_present "$artifact" || return 0
  [ -d "$parent" ] && [ ! -L "$parent" ] || return 1
  rm -f -- "$artifact" 2>/dev/null || return 1
  ! x_mode_artifact_present "$artifact"
}

# X mode (opt-in): when this home's .env carries a non-empty FMX_PAIRING_TOKEN,
# wire the relay poll into the existing authenticated watcher dispatch.
# Drops two idempotent, gitignored artifacts:
#   state/x-watch.check.sh - byte-static identity shim; the watcher validates
#                            its bytes and invokes bin/fm-x-poll.sh directly
#   config/x-mode.env      - exports FM_CHECK_INTERVAL=30, sourced by the watcher
#                            arm so only an X instance polls at the 30s cadence
# On opt-out (no token, or empty) it removes any such artifacts so the instance
# reverts to the default 300s no-poll behavior. Absent a token AND with no leftover
# artifacts it is a complete no-op (nothing written, nothing printed), so a non-X
# user sees zero change. Prints one confirmation line on opt-in, and one on opt-out
# only when it actually removed artifacts. It never touches the watcher itself;
# applying a cadence transition to a running watcher is the caller's job via
# the emitted harness-aware supervision repair instruction.
x_mode_setup() {
  local env_file token shim cadence shim_body cadence_body tool missing
  env_file="$FM_HOME/.env"
  shim="$STATE/x-watch.check.sh"
  cadence="$CONFIG/x-mode.env"

  token=
  [ -f "$env_file" ] && token=$(fmx_env_get FMX_PAIRING_TOKEN "$env_file")

  x_mode_remove_artifacts() {
    local failed=0
    x_mode_remove_artifact "$shim" || failed=1
    x_mode_remove_artifact "$cadence" || failed=1
    [ "$failed" -eq 0 ]
  }

  x_mode_supervision_repair() {
    local out
    out=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --repair-line 2>/dev/null) \
      || out='repair missing watcher supervision according to the session-start operating block.'
    printf '%s\n' "$out"
  }

  if [ -z "$token" ]; then
    # Opt-out (or never opted in): drop any X artifacts; stay silent unless we
    # actually removed something.
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - removed relay poll shim and 30s cadence; default cadence applies on the next supervision cycle; $(x_mode_supervision_repair)"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence"
      fi
    fi
    return 0
  fi

  missing=0
  for tool in curl jq; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "MISSING: $tool (install: $(install_cmd "$tool"))"
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    if x_mode_artifact_present "$shim" || x_mode_artifact_present "$cadence"; then
      if x_mode_remove_artifacts; then
        echo "FMX: X mode off - missing relay poll dependencies; install them and rerun bootstrap"
      else
        echo "FMX: X mode off - failed to remove relay poll shim or 30s cadence after missing relay poll dependencies"
      fi
    fi
    return 0
  fi

  fmx_arm_failed() {
    if x_mode_remove_artifacts; then
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence"
    else
      echo "FMX: X mode off - failed to arm relay poll shim or 30s cadence; stale artifacts remain"
    fi
  }

  mkdir -p "$STATE" "$CONFIG" 2>/dev/null || { fmx_arm_failed; return 0; }

  shim_body=$(fmx_poll_shim_content "$FM_HOME" "$FM_ROOT")
  x_mode_write_if_changed "$shim" "$shim_body" 700 || { fmx_arm_failed; return 0; }
  fmx_poll_shim_valid "$shim" "$FM_HOME" "$FM_ROOT" \
    || { fmx_arm_failed; return 0; }

  cadence_body=$(cat <<'EOF'
# Auto-generated by fm-bootstrap.sh - X mode watcher cadence.
# Source this before the active harness protocol starts a watcher process so
# fm-watch.sh polls the X check every 30s. Non-X instances have no such file and
# keep the default 300s cadence.
export FM_CHECK_INTERVAL=30
EOF
)
  x_mode_write_if_changed "$cadence" "$cadence_body" 600 || { fmx_arm_failed; return 0; }

  echo "FMX: X mode on - relay poll armed via state/x-watch.check.sh; 30s watcher cadence in config/x-mode.env"
}

crew_dispatch_validate() {
  local file err
  file="$CONFIG/crew-dispatch.json"
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "MISSING: jq (install: $(install_cmd jq))"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON"
    return 0
  fi
  err=$(jq -r '
    def verified($h): ["claude","codex","opencode","pi","grok"] | index($h);
    def effort_ok($h; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "codex" then (["low","medium","high","xhigh"] | index($e))
      elif $h == "grok" then (["low","medium","high"] | index($e))
      elif $h == "pi" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "opencode" then false
      else true
      end;
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    def configured_profiles:
      ([(.rules // [])[]? | profiles(.use?)[]?]
        + (if has("default") then [profiles(.default)[]?] else [] end));
    def malformed_optional_fields($items):
      ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
      or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)));
    def bad_efforts:
      configured_profiles
      | map({h: .harness, e: .effort})
      | map(select(.e != null))
      | map(select((.h | type) == "string" and verified(.h)))
      | map(select(. as $p | effort_ok($p.h; $p.e) | not))
      | map("\(.h):\(.e)")
      | unique;
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
    elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
    elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
    elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
    elif malformed_optional_fields([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile model and effort must be non-empty strings when present"
    elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
    elif [(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | length > 0 then
      "unknown select: " + ([ (.rules // [])[]? | .select? // empty | select(. != "quota-balanced") ] | unique | join(", "))
    elif has("default") and ((.default | type) != "object" and (.default | type) != "array") then "default must be a profile object or non-empty profile array"
    elif has("default") and ((.default | type) == "array" and (.default | length) == 0) then "default needs at least one profile"
    elif has("default") and ([profiles(.default)[]? | select(type != "object")] | length) > 0 then "each default profile must be an object"
    elif has("default") and ([profiles(.default)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default profile needs harness"
    elif has("default") and malformed_optional_fields([profiles(.default)[]?]) then "default profile model and effort must be non-empty strings when present"
    else
      (configured_profiles
        | map(.harness)
        | map(select(. != null))
        | map(select(. as $h | verified($h) | not))
        | unique) as $bad_harnesses
      | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
        elif (bad_efforts | length) > 0 then "invalid effort: " + (bad_efforts | join(", "))
        else empty
        end
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - $err"
    return 0
  fi
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
    jq -r '
    def profile($p):
      ($p.harness | tostring)
      + (if ($p.model? != null) then "/" + ($p.model | tostring)
         elif ($p.effort? != null) then "/default"
         else "" end)
      + (if ($p.effort? != null) then "/" + ($p.effort | tostring) else "" end);
    def profile_set($value; $selector):
      if ($value | type) == "array" then
        (($selector // "quota-balanced") + "[" + ([$value[] | profile(.)] | join(", ")) + "]")
      else profile($value)
      end;
    (["BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json"]
      + [(.rules // [])[]? | "BOOTSTRAP_INFO: crew dispatch rule: " + (.when | tostring) + " -> " + profile_set(.use; .select?)]
      + (if has("default") then ["BOOTSTRAP_INFO: crew dispatch default: " + profile_set(.default; null)] else [] end))
    | .[]
  ' "$file"
  fi
}

FM_BOOTSTRAP_FLEET_LOCKS=()
bootstrap_locks_release() {
  local status=$?
  fm_lifecycle_admission_release FM_BOOTSTRAP_FLEET_LOCKS
  return "$status"
}
trap bootstrap_locks_release EXIT
if [ "$BOOTSTRAP_READ_ONLY" != 1 ]; then
  fm_lifecycle_admission_acquire FM_BOOTSTRAP_FLEET_LOCKS \
    "$STATE" "$FM_HOME" "${BASHPID:-$$}" || {
    echo "REFUSED: fleet lifecycle serialization is busy; bootstrap made no changes" >&2
    exit 1
  }
fi

isolation_status=0
"$SCRIPT_DIR/fm-isolation-sweep.sh" 2>/dev/null || isolation_status=$?
if [ "$isolation_status" -ne 0 ] && [ "$BOOTSTRAP_READ_ONLY" != 1 ]; then
  echo "REFUSED: worker isolation is unproven; bootstrap remains read-only until every ISOLATION finding is resolved" >&2
  exit 1
fi
if ! fm_secondmate_lifecycle_preflight "$STATE" "$DATA/secondmates.md" "$BOOTSTRAP_READ_ONLY"; then
  if [ "$BOOTSTRAP_READ_ONLY" != 1 ]; then
    echo "REFUSED: secondmate lifecycle identity is ambiguous; bootstrap remains read-only" >&2
    exit 1
  fi
fi

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: fm-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    if ! cmd=$(install_cmd "$t"); then
      instructions=$(manual_install_url "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
      echo "error: $t requires manual installation (instructions: $instructions)" >&2
      exit 1
    fi
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

# This is the first mutating sweep at a locked session boundary. It pauses an
# identity-matched watcher, holds its lock, and neutralizes legacy PR checks
# before any tool detection or later bootstrap mutation can leave old artifacts
# runnable. Detect-only sessions never touch state.
if [ "$BOOTSTRAP_READ_ONLY" != 1 ]; then
  "$SCRIPT_DIR/fm-pr-check-migrate.sh" || true
fi

if [ "$BACKEND_VALID" -eq 0 ]; then
  echo "BACKEND_INVALID: $BACKEND (known: $FM_BACKEND_KNOWN)"
fi
for t in $BACKEND_TOOLS; do
  fm_backend_required_tool_available "$BACKEND" "$t" \
    || missing_tool_diagnostic "$t"
done
for t in $COMMON_TOOLS; do
  command -v "$t" >/dev/null || missing_tool_diagnostic "$t"
done
# The treehouse lease-support upgrade check is only relevant when the resolved
# backend actually requires treehouse (every backend except orca, which owns its
# own worktrees); an orca home must not be told to upgrade a provider it never uses.
if fm_backend_list_contains "$TOOLS" treehouse \
  && command -v treehouse >/dev/null 2>&1 && ! treehouse_supports_lease; then
  echo "MISSING: treehouse (install: $(install_cmd treehouse))"
fi
if command -v no-mistakes >/dev/null 2>&1 && ! no_mistakes_compatible; then
  echo "MISSING: no-mistakes (install: $(install_cmd no-mistakes))"
fi
if command -v tasks-axi >/dev/null 2>&1 && ! fm_tasks_axi_compatible; then
  echo "MISSING: tasks-axi (install: $(install_cmd tasks-axi))"
fi
gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
# Worktree-tangle check: the firstmate primary checkout (FM_ROOT) must sit on its
# default branch, not a feature branch (see fm-tangle-lib.sh). Scoped to the
# primary only; detached-HEAD worktrees and secondmate homes never trip it.
# Worker-isolation sweep: the spawn-time assertion does not survive a restore,
# so every session re-establishes it from live process evidence. Read-only, so
# it runs in detect-only mode too. bin/fm-isolation-sweep.sh owns the evidence
# discipline and the exact ISOLATION line shapes.
tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" 2>/dev/null || true)
if [ -n "$tangle_branch" ]; then
  tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
  if [ "$BOOTSTRAP_READ_ONLY" = 1 ]; then
    echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - read-only session must leave restore work to the session holding the fleet lock"
  else
    echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $FM_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
  fi
fi
crew=
[ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] && [ -n "$crew" ] && [ "$crew" != "default" ]; then
  echo "BOOTSTRAP_INFO: crew harness override active: $crew"
fi
crew_dispatch_validate
if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] \
  && ! fm_backlog_backend_manual "$CONFIG" && fm_tasks_axi_compatible; then
  echo "BOOTSTRAP_INFO: tasks-axi available"
fi
if [ "$BOOTSTRAP_READ_ONLY" != 1 ]; then
  secondmate_liveness_sweep
  secondmate_sync || exit 1
  x_mode_setup
  fleet_sync
fi
exit 0
