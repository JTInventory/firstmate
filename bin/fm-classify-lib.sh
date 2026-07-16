#!/usr/bin/env bash
# Shared wake classifier: the common source of truth for captain-relevant status
# tests and, for the always-on watcher, the provably-working predicate that makes
# no-verb wakes safe to absorb. Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# The one exception is the "provably working" predicate (crew_is_provably_working
# and its signal-path wrapper). It is NOT a pure status-file read: it reuses
# bin/fm-crew-state.sh, which may make a bounded no-mistakes call, to decide
# whether a crew that just stopped its turn shows positive evidence it is still
# working. Callers run it ONLY on the no-verb (turn-end / non-terminal stale)
# path, never on every wake, so the per-wake triage stays cheap.

# Directory of this library, used to locate the sibling fm-crew-state.sh reader.
# Resolved at source time from BASH_SOURCE so it works whether sourced by a
# bin/ script (which sets its own SCRIPT_DIR) or directly by a test.
_FM_CLASSIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_CLASSIFY_LIB_DIR="."

# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"

# Captain-relevant status verbs. A status line carrying any of these is work
# firstmate must see. Lines without these verbs are no-verb signals: the watcher
# absorbs them only with positive provably-working evidence, while the daemon uses
# its away-mode classification. FM_CAPTAIN_RE overrides the whole set when a home
# needs a custom verb vocabulary; absent, this default applies.
# paused: is intentionally absent: it is a declared external wait, not a
# captain-relevant wedge. U6 owns bounded re-surfacing after its review cadence.
FM_CLASSIFY_CAPTAIN_RE_DEFAULT='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'

# Shared declared external-wait vocabulary and cadence. U6 keeps this contract
# in one library so watcher and away-mode daemon cannot drift.
FM_CLASSIFY_PAUSED_VERB_DEFAULT='paused'
# shellcheck disable=SC2034 # Read by the watcher and daemon after sourcing this library.
FM_PAUSE_RESURFACE_SECS_DEFAULT=3600

# Normalize an all-digit value without Bash's leading-zero octal interpretation.
# Returns non-zero for malformed input; callers choose their safe default.
decimal_digits_or_zero() {  # <value>
  local value=$1 normalized
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  normalized=$(printf '%s' "$value" | sed 's/^0*//')
  [ -n "$normalized" ] || normalized=0
  printf '%s' "$normalized"
}

positive_seconds_or_default() {  # <value> <default>
  local value=$1 default=$2 normalized
  normalized=$(decimal_digits_or_zero "$value") || { printf '%s' "$default"; return; }
  [ "$normalized" = 0 ] && { printf '%s' "$default"; return; }
  printf '%s' "$normalized"
}

# Return the last non-blank line of a status file (empty if missing/blank).
last_status_line() {
  local f=$1
  [ -e "$f" ] || return 0
  grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -1
}

# 0 if the given (last) status line matches a captain-relevant verb.
status_is_captain_relevant() {
  local line=$1
  [ -n "$line" ] || return 1
  # A caller-provided FM_CAPTAIN_RE is an explicit policy override; the default
  # classifier keeps paused external waits out of the captain-relevant set.
  if [ "${FM_CAPTAIN_RE+x}" != x ]; then
    status_is_paused "$line" && return 1
  fi
  printf '%s' "$line" | grep -qiE "${FM_CAPTAIN_RE:-$FM_CLASSIFY_CAPTAIN_RE_DEFAULT}"
}

# 0 when a status line declares a non-empty known external dependency.
status_is_paused() {  # <status-line>
  local line=$1 verb reason
  [ -n "$line" ] || return 1
  case "$line" in
    *:*) ;;
    *) return 1 ;;
  esac
  verb=${line%%:*}
  verb="${verb#"${verb%%[![:space:]]*}"}"
  verb="${verb%"${verb##*[![:space:]]}"}"
  [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ] || return 1
  reason=${line#*:}
  reason="${reason#"${reason%%[![:space:]]*}"}"
  [ -n "$reason" ]
}

# Read the canonical crew-state line once and expose its stable state token.
# Unknown/unavailable reads remain explicit so callers can fail closed.
crew_state_value() {  # <id>
  local id=$1 line state
  [ -n "$id" ] || { printf 'unknown'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in
    state:*)
      state=${line#state: }
      state=${state%% *}
      [ -n "$state" ] && { printf '%s' "$state"; return; }
      ;;
  esac
  printf 'unknown'
}

# Return the recorded task kind for a status file. Older fixtures and homes may
# name metadata either <id>.meta or <id>.status.meta, so accept both forms.
status_file_kind() {  # <status-file>
  local f=$1 meta kind
  for meta in "${f%.status}.meta" "$f.meta"; do
    [ -e "$meta" ] || continue
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$kind" ] && { printf '%s' "$kind"; return; }
  done
  printf 'unknown'
}

# Read the canonical crew-state once and classify the two safe absorb reasons.
# This is intentionally separate from the captain-relevant status regex: a
# declared pause is expected idle work, while a stopped/unknown crew remains loud.
# Older/current-state fixtures may still expose a parked awaiting_agent run-step;
# combine that state with the task's valid paused event so the external-wait
# contract remains stable across the reconciliation boundary.
crew_absorb_class() {  # <id>
  local id=$1 line state src status_root last
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then
    printf 'paused'
    return
  fi
  if [ "$state" = parked ] && [[ "$line" == *"source: run-step"* && "$line" == *"parked at awaiting_agent"* ]]; then
    status_root=${FM_STATE_OVERRIDE:-${FM_HOME:-${_FM_CLASSIFY_LIB_DIR%/bin}}/state}
    last=$(last_status_line "$status_root/$id.status")
    if status_is_paused "$last"; then
      printf 'paused'
      return
    fi
  fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in run-step|pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 (benign) if every referenced signal belongs to a working or paused crew.
signal_crew_absorbable() {  # <file> ...
  local f base task last seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status) task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *) continue ;;
    esac
    [ -n "$task" ] || continue
    if [[ "$base" = *.status ]]; then
      last=$(last_status_line "$f")
      if status_is_paused "$last" && [ "$(status_file_kind "$f")" = secondmate ]; then
        return 1
      fi
    fi
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    case "$(crew_absorb_class "$task")" in
      working|paused) ;;
      *) return 1 ;;
    esac
  done
  [ -n "$seen" ] || return 1
  return 0
}

# task id from a tmux window name "<session>:fm-<id>" -> "<id>"
window_to_task() {
  local w=$1 t
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# 0 (actionable) if ANY status file listed in a "signal:" wake carries a
# captain-relevant last line; 1 otherwise. Pass the space-separated file list that
# follows the "signal:" prefix. Non-.status arguments (e.g. .turn-ended markers,
# which never carry a verb) are skipped. A 1 here is NOT "benign" on its own: a
# no-verb signal (a bare turn-end, a working: note) is only benign when the crew is
# also provably working (signal_crew_provably_working below); otherwise it surfaces.
signal_reason_is_actionable() {  # <file> ...
  local f last
  for f in "$@"; do
    [ -e "$f" ] || continue
    case "$f" in *.status) ;; *) continue ;; esac
    last=$(last_status_line "$f")
    [ -n "$last" ] || continue
    status_is_captain_relevant "$last" && return 0
  done
  return 1
}

# 0 if crew <id> shows POSITIVE evidence it is still working; 1 otherwise. This is
# the "provably working" predicate at the heart of absorb-only-when-provably-working:
# a no-verb turn-end or non-terminal stale wake is absorbed ONLY when this returns
# 0, and SURFACED otherwise (the crew may be done, waiting on a decision, or wedged).
#
# It reuses bin/fm-crew-state.sh rather than duplicating its run-step logic, and
# treats the crew as provably working in exactly two cases, both read straight from
# that helper's one canonical line ("state: <s> · source: <src> · <detail>"):
#   (a) state working from source run-step - the crew's no-mistakes run for its
#       branch is in an actively-running step (running/fixing/ci), NOT terminal,
#       parked, passed, or failed; OR
#   (b) state working from source pane     - the pane shows the harness busy
#       signature.
# Everything else - a terminal/parked/failed run, an idle pane that fell back to a
# stale "working:" status-log line (source status-log), a torn-down or unknown
# crew, or an unreadable verdict - is NOT provably working, so the wake surfaces.
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call, so this
# runs only on the no-verb path. FM_CREW_STATE_BIN lets tests stub the verdict.
crew_is_provably_working() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || return 1
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) return 1 ;; esac
  state=${line#state: }; state=${state%% *}
  [ "$state" = working ] || return 1
  src=${line#*source: }; src=${src%% *}
  case "$src" in
    run-step|pane) return 0 ;;
    *)             return 1 ;;
  esac
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list as signal_reason_is_actionable. Files are mapped to
# task ids by stripping the .status / .turn-ended suffix; a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
signal_crew_provably_working() {  # <file> ...
  local f base task seen=""
  for f in "$@"; do
    base=${f##*/}
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's last status line is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}

# Print "<file>\t<task>\t<last-line>" for every state/*.status whose last line is
# captain-relevant. This is the cheap fleet-scan both supervisors run as a
# catch-all backstop for a captain-relevant status the per-wake path might miss.
# No dedup is applied here: each consumer dedupes against its own seen-state (the
# daemon against .subsuper-seen-status-*, the watcher against .seen-* signatures).
scan_captain_relevant_statuses() {  # <state>
  local state=$1 f last task
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    last=$(last_status_line "$f")
    status_is_captain_relevant "$last" || continue
    task=$(basename "$f"); task="${task%.status}"
    printf '%s\t%s\t%s\n' "$f" "$task" "$last"
  done
  return 0
}
