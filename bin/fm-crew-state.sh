#!/usr/bin/env bash
# fm-crew-state.sh - deterministic read of a crew's CURRENT state.
#
# Why this exists: state/<id>.status is an append-only, best-effort EVENT LOG.
# Crews append only wake-worthy transitions (done/needs-decision/paused/blocked/failed)
# and nothing when they silently resume, so `tail -1` of that log reports the
# last EVENT, not the current STATE. After firstmate resolves a needs-decision
# or blocked and the crew resumes (responds to the gate, the pipeline fixes, it
# re-validates), the log's last line stays stale. This helper never infers the
# current state from a tail of the log: it reads the authoritative source (a
# no-mistakes run-step attributed to this crew's branch and current code
# identity, else the pane busy-signature) and reconciles the possibly-stale log
# against it.
#
# The determinism lives entirely here - only run-step / pane / log reads plus
# fixed mapping logic, no heuristics and no LLM. Output is one stable, parseable,
# token-tight line firstmate can read every heartbeat:
#
#   state: <working|parked|paused|done|blocked|failed|unknown> · source: <run-step|pane|status-log|none> · <detail>
#
# Logic, in order:
#   1. Resolve worktree + backend target + kind from state/<id>.meta.
#   2. Matching no-mistakes run for this crew's branch AND current code identity,
#      active or terminal (from `axi status`, or the coarse `no-mistakes runs`
#      fallback)? Branch name alone is not enough: a historical run on a reused
#      branch whose head was rewritten or diverged must not be attributed.
#      A run matches when its head equals the worktree HEAD, or the worktree HEAD
#      is an ancestor of the run head (pipeline fix commits advanced the run on
#      the same line of history). Local work that advanced past the run head, or
#      diverged from it, invalidates attribution.
#      The run-step is AUTHORITATIVE: running/fixing -> working, ci -> working,
#      awaiting_approval/fix_review -> parked (with gate findings), terminal
#      passed/checks-passed -> done, failed/cancelled -> failed. A valid
#      paused: <reason> event paired with a gate-free parked awaiting_agent run is the
#      declared external-wait exception: report paused while retaining the
#      run-step source and parked gate detail.
#   3. Reconcile the status log: if its last line says needs-decision/paused/blocked but
#      the run-step shows the run moved on, the log is deterministically stale and
#      is flagged superseded. A genuinely parked run plus a needs-decision log
#      agree, and are reported as parked.
#   4. No run for this crew (pre-validation, or kind=scout): fall back to the
#      recorded backend busy state, then the pane busy-signature fallback + the
#      status log's last line.
#   5. Missing meta or torn-down worktree: report unknown · none. If no run is
#      attributed to this crew, a dead window also reports unknown · none rather
#      than trusting a stale status log.
#
# Read-only and side-effect free. Always exits 0 on a successful read regardless
# of state; exit 2 only on a usage error (no id).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tmux-lib.sh
. "$SCRIPT_DIR/fm-tmux-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-numeric-lib.sh
. "$SCRIPT_DIR/fm-numeric-lib.sh"

ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh <id>" >&2; exit 2; }

META="$STATE/$ID.meta"
LOG="$STATE/$ID.status"
NM_TIMEOUT=$(fm_nonnegative_integer_or_default "${FM_CREW_STATE_NM_TIMEOUT:-10}" 10 86400)
SEP=' · '

# Emit the one canonical line and exit 0. Detail is optional.
emit() {  # <state> <source> [detail]
  local line="state: $1${SEP}source: $2"
  [ -n "${3:-}" ] && line="$line${SEP}$3"
  printf '%s\n' "$line"
  exit 0
}

# --- meta resolution --------------------------------------------------------

[ -f "$META" ] || emit unknown none "no metadata for $ID"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
WIN=$(meta_value window)
KIND=$(meta_value kind)
[ -n "$KIND" ] || KIND=ship

# A torn-down (or never-created) worktree has no current state to read.
if [ -z "$WT" ] || [ ! -d "$WT" ]; then
  emit unknown none "worktree gone (torn down?)"
fi

# --- status log ------------------------------------------------------------

# Last non-empty status line, and its leading verb (the word before the colon).
log_last_line() {
  [ -f "$LOG" ] || return 1
  grep -v '^[[:space:]]*$' "$LOG" 2>/dev/null | tail -1
}
log_verb_of() {  # <line>
  local v=${1%%:*}
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}
log_note_of() {  # <line>
  case "$1" in
    *:*) local n=${1#*:}; printf '%s' "${n#"${n%%[![:space:]]*}"}" ;;
    *)   printf '%s' "$1" ;;
  esac
}

log_declares_pause() {
  [ "$(log_verb_of "$LOG_LINE")" = paused ] || return 1
  [[ "$(log_note_of "$LOG_LINE")" =~ [^[:space:]] ]]
}
# Map a status-log verb onto a canonical state for the fallback path. The
# paused verb is a declared external wait and remains distinct from actionable
# blocked.
map_log_state() {  # <line>
  local verb note
  verb=$(log_verb_of "$1")
  note=$(log_note_of "$1")
  case "$verb" in
    working)        echo working ;;
    needs-decision) echo parked ;;
    paused)         [[ "$note" =~ [^[:space:]] ]] && echo paused || echo unknown ;;
    blocked)        echo blocked ;;
    done)           echo "done" ;;
    failed)         echo failed ;;
    *)              echo unknown ;;
  esac
}

LOG_LINE=$(log_last_line || true)
LOG_VERB=$(log_verb_of "$LOG_LINE")

TASK_BACKEND=$(fm_backend_of_meta "$META")
fm_backend_validate "$TASK_BACKEND" >/dev/null 2>&1 || emit unknown none "unknown backend $TASK_BACKEND"

# pane_readable is consulted ONLY in the no-run fallback below. The run-step path
# stays authoritative regardless of pane liveness - judge by the run-step, not the
# shell - so a finished crew whose window has closed still reports its run-step
# state (e.g. done) instead of being masked as unknown.
pane_readable() {  # <target>
  fm_backend_pane_readable "$TASK_BACKEND" "$1"
}

# The P1 tmux adapter has no native semantic busy state, so it returns
# unknown and this falls back to the same six-line footer regex used before
# the abstraction. A future adapter can return busy/idle without changing the
# caller.
crew_pane_is_busy() {  # <target>
  local busy tail40
  busy=$(fm_backend_busy_state "$TASK_BACKEND" "$1" 2>/dev/null)
  case "$busy" in
    busy) return 0 ;;
    idle) return 1 ;;
  esac
  tail40=$(fm_backend_capture "$TASK_BACKEND" "$1" 40 2>/dev/null) || return 1
  printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 \
    | grep -qiE "${FM_BUSY_REGEX:-$FM_TMUX_BUSY_REGEX_DEFAULT}"
}

# --- no-mistakes run lookup (authoritative when a run matches this branch) --

trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
strip_quotes() {
  local s
  s=$(trim "${1:-}")
  case "$s" in
    \"*\") s=${s#\"}; s=${s%\"} ;;
  esac
  trim "$s"
}

# Bounded no-mistakes call in the worktree; stdout only, never fails the script.
HAVE_TIMEOUT=none
if command -v timeout >/dev/null 2>&1; then HAVE_TIMEOUT=timeout
elif command -v gtimeout >/dev/null 2>&1; then HAVE_TIMEOUT=gtimeout
elif command -v perl >/dev/null 2>&1; then HAVE_TIMEOUT=perl
fi
NM_DEADLINE=0
[ "$HAVE_TIMEOUT" = none ] || NM_DEADLINE=$(( SECONDS + NM_TIMEOUT ))
nm_run() {  # <args...>
  local remaining
  [ "$HAVE_TIMEOUT" = none ] && return 0
  remaining=$(( NM_DEADLINE - SECONDS ))
  [ "$remaining" -gt 0 ] || return 0
  case "$HAVE_TIMEOUT" in
    timeout)  ( cd "$WT" && timeout "$remaining" no-mistakes "$@" ) 2>/dev/null || true ;;
    gtimeout) ( cd "$WT" && gtimeout "$remaining" no-mistakes "$@" ) 2>/dev/null || true ;;
    perl)     ( cd "$WT" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$remaining" no-mistakes "$@" ) 2>/dev/null || true ;;
    *)        true ;;
  esac
}

# Scalar value of a TOON key in the captured run output ($RUN_OUT).
RUN_OUT=""
nm_field() {  # <key>
  printf '%s\n' "$RUN_OUT" | sed -n "s/^[[:space:]]*$1:[[:space:]]*\(.*\)/\1/p" | head -1
}
# Finding count from a findings[N]{...} table header; empty when none.
nm_findings_count() {
  printf '%s\n' "$RUN_OUT" | grep -oE 'findings\[[0-9]+\]' | head -1 | grep -oE '[0-9]+'
}
nm_gate_step_row() {
  local row step rest status findings
  row=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*,' | head -1)
  [ -n "$row" ] || return 0
  row=$(trim "$row")
  step=$(trim "${row%%,*}")
  rest=${row#*,}
  status=$(strip_quotes "$(trim "${rest%%,*}")")
  rest=${rest#*,}
  findings=$(trim "${rest%%,*}")
  printf '%s|%s|%s' "$step" "$status" "$findings"
}
nm_gate_status() {
  local s row
  s=$(printf '%s\n' "$RUN_OUT" | grep -E '^[[:space:]]*(status|state):[[:space:]]*"?(awaiting_approval|fix_review)"?[[:space:]]*$' | head -1)
  if [ -n "$s" ]; then
    s=$(strip_quotes "$(trim "${s#*:}")")
    printf '%s' "$s"
    return
  fi
  row=$(nm_gate_step_row)
  [ -n "$row" ] && { row=${row#*|}; printf '%s' "${row%%|*}"; }
}
nm_has_gate() {
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*gate:[[:space:]]*'
}
nm_gate_line_name() {
  local gate step
  gate=$(strip_quotes "$(nm_field gate)")
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  step=$(printf '%s\n' "$RUN_OUT" | sed -n '/^[[:space:]]*gate:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]*step:[[:space:]]*\(.*\)/\1/p' | head -1)
  step=$(strip_quotes "$step")
  [ -n "$step" ] && printf '%s' "$step"
}
nm_gate_name() {
  local gate row
  gate=$(nm_gate_line_name)
  [ -n "$gate" ] && { printf '%s' "$gate"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] && printf '%s' "${row%%|*}"
}
nm_gate_findings_count() {
  local f row rest
  f=$(nm_findings_count)
  [ -n "$f" ] && { printf '%s' "$f"; return; }
  row=$(nm_gate_step_row)
  [ -n "$row" ] || return 0
  rest=${row#*|}
  rest=${rest#*|}
  rest=${rest%%|*}
  case "$rest" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$rest"
}
nm_awaiting_agent_parked() {
  printf '%s\n' "$RUN_OUT" | grep -Eq '^[[:space:]]*awaiting_agent:[[:space:]]*"?parked([[:space:]]|"?$)'
}
log_reports_ci_ready() {
  [ "$LOG_VERB" = "done" ] || return 1
  case "$(log_note_of "$LOG_LINE")" in
    *PR*"checks green"*|*"checks green"*PR*) return 0 ;;
    *) return 1 ;;
  esac
}
# A no-mistakes run remains active after checks turn green while it waits for the
# captain's merge. The CI log is the durable distinction between that ready
# state and checks that are still running; the most recent marker wins.
nm_ci_checks_state() {
  local run_id log_tail marker
  run_id=$(strip_quotes "$(nm_field id)")
  [ -n "$run_id" ] || { printf 'unknown'; return; }
  log_tail=$(nm_run axi logs --step ci --run "$run_id") || true
  [ -n "$log_tail" ] || { printf 'unknown'; return; }
  marker=$(printf '%s\n' "$log_tail" | grep -E 'CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running|base branch advanced.*re-arming CI monitor timeout' | tail -1)
  case "$marker" in
    *"checks passed"*|*"no CI checks reported - still monitoring"*) printf 'green' ;;
    *"no CI checks reported yet"*|*"checks failed"*|*"issues detected"*|*"CI checks running"*|*"base branch advanced"*"re-arming CI monitor timeout"*) printf 'not-ready' ;;
    *) printf 'unknown' ;;
  esac
}
# Coarse fallback for cross-branch attribution. `no-mistakes axi status` (bare)
# reports the active-or-most-recent run for the CURRENT branch when one
# exists, else falls back to some other branch's run purely as informational
# display (verified empirically: querying a worktree with its own active run
# reliably returns that run, even under concurrent load from several other
# validating crews on the same underlying repo). A crew whose branch genuinely
# has no run yet therefore sees another branch's answer here.
#
# This fallback used to shell out to `no-mistakes axi` (bare, no subcommand)
# expecting a `runs[N]{id,branch,status,...}:` TOON table and re-query the
# matched id via `axi status --run <id>`. Verified against the real installed
# CLI (v1.32.2): the `axi` surface exposes only abort/logs/respond/run/status -
# there is no runs-listing subcommand under `axi` at all, so that table never
# appears and the lookup was silently dead code; whenever the bare `axi
# status` answer was not this crew's own branch, attribution always failed and
# the caller fell straight through to the pane/log fallback below. (The
# PRIMARY cause of the 2026-07 herdr false-surface incidents turned out to be
# a separate bug in bin/fm-watch.sh's stale_is_terminal precedence - see that
# file's history - but this cross-branch path was independently confirmed
# dead code and is worth having actually work.)
#
# The real run-listing command is the top-level `no-mistakes runs` (verified:
# `no-mistakes --help` lists it separately from `axi`). It is plain, human-
# oriented text - no run id, no JSON/TOON, newest-first, columns
# "<status> <branch> <short-sha> <date> [<pr-url>]" separated by runs of
# spaces (verified: no quoting, so splitting on the first two whitespace runs
# is exact) - but branch + coarse status is exactly what this predicate needs:
# is a run for THIS branch active right now. Echoes the first (most recent)
# matching row's status word (running/completed/cancelled/failed), or empty
# when the branch has no run within FM_CREW_STATE_RUNS_LIMIT rows.
nm_runs_status_for_branch() {  # <branch>
  local branch=$1 out row st rest br sha
  out=$(nm_run runs --limit "$FM_CREW_STATE_RUNS_LIMIT")
  [ -n "$out" ] || return 0
  while IFS= read -r row; do
    row=$(trim "$row")
    [ -n "$row" ] || continue
    st=${row%% *}
    rest=${row#* }
    rest=$(trim "$rest")
    br=${rest%% *}
    rest=${rest#* }
    rest=$(trim "$rest")
    sha=${rest%% *}
    if [ "$br" = "$branch" ]; then
      # Same code-identity rule as axi status: skip a same-branch row whose
      # short-sha does not match this worktree (rewritten or advanced tip).
      if ! nm_coarse_head_matches_worktree "$sha"; then
        continue
      fi
      printf '%s' "$st"
      return 0
    fi
    [ "$in_runs" = 1 ] || continue
    case "$row" in
      '') continue ;;
      [[:space:]]*) ;;
      *) break ;;
    esac
    row=$(trim "$row")
    case "$row" in
      *,*) ;;
      *) continue ;;
    esac
    id=${row%%,*}; id=$(strip_quotes "$id")
    rest=${row#*,}
    br=${rest%%,*}; br=$(strip_quotes "$br")
    if [ "$br" = "$branch" ]; then printf '%s\n' "$id"; break; fi
  done <<< "$list" | { IFS= read -r found || true; printf '%s' "$found"; }
}

# CREW_BRANCH is empty at detached HEAD (a just-spawned crew, or a scout's
# scratch worktree); with no branch there is no run to attribute to this crew.
CREW_BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD 2>/dev/null || true)

# 0 if the active axi-status run's head field matches this worktree's code
# identity. Branch match is a precondition (caller). Rules:
#   - missing/empty head field: cannot bind; reject the run
#   - equal commits (short or full SHA): match
#   - worktree HEAD is an ancestor of run head: match (pipeline fix commits on
#     the same history advanced the run tip)
#   - run head is a strict ancestor of worktree HEAD: no match (local work
#     advanced outside the run)
#   - diverged / run head not in this worktree: no match (rewritten branch tip)
nm_run_head_matches_worktree() {
  local run_head local_full run_full
  run_head=$(strip_quotes "$(nm_field head)")
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$WT" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  if git -C "$WT" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Coarse runs-list rows are "<status> <branch> <short-sha> ...". 0 if the short
# sha for this branch row matches the worktree head under the same rules as
# nm_run_head_matches_worktree (equal, or local is ancestor of run tip).
nm_coarse_head_matches_worktree() {  # <short-sha>
  local run_head=$1 local_full run_full
  [ -n "$run_head" ] || return 1
  local_full=$(git -C "$WT" rev-parse HEAD 2>/dev/null) || return 1
  run_full=$(git -C "$WT" rev-parse --verify "${run_head}^{commit}" 2>/dev/null) || return 1
  [ "$run_full" = "$local_full" ] && return 0
  if git -C "$WT" merge-base --is-ancestor "$local_full" "$run_full" 2>/dev/null; then
    return 0
  fi
  return 1
}

HAVE_RUN=0
# Scouts and secondmates never drive a no-mistakes validation of their own
# worktree, so skip the lookup for them and read state from pane/log directly.
if [ "$KIND" = ship ] && [ -n "$CREW_BRANCH" ] && command -v no-mistakes >/dev/null 2>&1; then
  RUN_OUT=$(nm_run axi status)
  if [ -n "$RUN_OUT" ]; then
    run_branch=$(strip_quotes "$(nm_field branch)")
    if [ -n "$run_branch" ] && [ "$run_branch" = "$CREW_BRANCH" ] && nm_run_head_matches_worktree; then
      HAVE_RUN=1
    else
      # The active-or-most-recent run is for another branch, or same branch with
      # a rewritten/diverged head (the CLI is alive and answered; only the
      # attribution missed) - try the coarse fallback.
      # Deliberately nested inside `[ -n "$RUN_OUT" ]`: an empty/timed-out
      # primary call means the CLI itself did not respond, so retrying it
      # immediately with a second bounded call would just double the wait
      # for no better answer.
      COARSE_STATUS=$(nm_runs_status_for_branch "$CREW_BRANCH")
      if [ -n "$COARSE_STATUS" ]; then
        HAVE_RUN=1
        RUN_SOURCE=coarse
      fi
    fi
  fi
fi

# --- run-step authoritative path -------------------------------------------

if [ "$HAVE_RUN" = 1 ]; then
  status=$(strip_quotes "$(nm_field status)")
  outcome=$(strip_quotes "$(nm_field outcome)")
  awaiting_agent_parked=0
  nm_awaiting_agent_parked && awaiting_agent_parked=1
  gate_status=$(nm_gate_status)
  has_gate=0
  nm_has_gate && has_gate=1
  awaiting_agent_external_park=0
  if [ "$awaiting_agent_parked" = 1 ] && \
    [ "$status" != running ] && [ "$status" != fixing ] && [ "$status" != ci ] && \
    [ "$status" != awaiting_approval ] && [ "$status" != fix_review ] && \
    [ -z "$gate_status" ] && [ "$has_gate" = 0 ]; then
    awaiting_agent_external_park=1
  fi

  RUN_STATE=working
  RUN_DETAIL=""
  if [ -n "$outcome" ]; then
    case "$outcome" in
      passed)        RUN_STATE="done"; RUN_DETAIL="run passed: PR merged/closed" ;;
      checks-passed) RUN_STATE="done"; RUN_DETAIL="checks green: PR ready for review" ;;
      failed)        RUN_STATE=failed; RUN_DETAIL="run failed" ;;
      cancelled)     RUN_STATE=failed; RUN_DETAIL="run cancelled" ;;
      *)             RUN_STATE=unknown; RUN_DETAIL="outcome: $outcome" ;;
    esac
  elif [ "$awaiting_agent_external_park" = 1 ] || [ "$status" = awaiting_approval ] || [ "$status" = fix_review ] || [ -n "$gate_status" ] || [ "$has_gate" = 1 ]; then
    if [ "$has_gate" = 1 ]; then
      gate=$(nm_gate_line_name)
    else
      gate=$(nm_gate_name)
    fi
    [ -n "$gate" ] || gate=$status
    [ -n "$gate" ] || gate=gate
    RUN_STATE=parked
    if [ "$awaiting_agent_external_park" = 1 ]; then
      RUN_DETAIL="parked at awaiting_agent"
      [ -n "$gate" ] && [ "$gate" != awaiting_agent ] && RUN_DETAIL="$RUN_DETAIL${SEP}gate $gate"
    else
      RUN_DETAIL="parked at $gate"
    fi
    fcount=$(nm_gate_findings_count)
    [ -n "$fcount" ] && RUN_DETAIL="$RUN_DETAIL: $fcount finding(s)"
    if printf '%s\n' "$RUN_OUT" | grep -q 'ask-user'; then
      RUN_DETAIL="$RUN_DETAIL (ask-user: captain decision)"
    fi
  else
    case "$status" in
      ci)             RUN_STATE=working; RUN_DETAIL="ci running" ;;
      running|fixing) RUN_STATE=working; RUN_DETAIL="validating ($status)" ;;
      completed)      RUN_STATE="done"; RUN_DETAIL="run completed" ;;
      failed)         RUN_STATE=failed;  RUN_DETAIL="run failed" ;;
      cancelled)      RUN_STATE=failed;  RUN_DETAIL="run cancelled" ;;
      "")             RUN_STATE=working; RUN_DETAIL="run active" ;;
      *)              RUN_STATE=working; RUN_DETAIL="run active ($status)" ;;
    esac
  fi

  if [ "$RUN_STATE" = working ] && nm_ci_is_monitoring; then
    if test "$(nm_ci_checks_state)" = "green"; then
      RUN_STATE="done"
      RUN_DETAIL="checks green: PR ready for review (still monitoring for merge/close)"
    fi
  fi
  if [ "$RUN_STATE" = working ] && log_reports_ci_ready; then
    emit "done" status-log "$(log_note_of "$LOG_LINE")${SEP}run still monitoring PR"
  fi

  # A parked gate is normally a captain decision. When the crew explicitly
  # declared a non-empty paused reason paired with a gate-free awaiting_agent,
  # the parked run-step is the authoritative shape of an external wait and
  # must not become a wedge/nag.
  # Active running/fixing/ci states remain working and retain authority over a
  # stale paused event.
  if [ "$RUN_STATE" = parked ] && [ "$awaiting_agent_external_park" = 1 ] && log_declares_pause; then
    RUN_STATE=paused
    RUN_DETAIL="$RUN_DETAIL${SEP}declared external wait"
  fi

  # Reconcile the status log. A needs-decision/paused/blocked log line that the run-step
  # has moved past (anything but a genuinely parked run or its declared external
  # wait exception) is deterministically stale: the gate resolved and the run
  # resumed or finished.
  case "$LOG_VERB" in
    needs-decision|paused|blocked)
      if [ "$RUN_STATE" != parked ] && [ "$RUN_STATE" != paused ]; then
        if [ "$RUN_STATE" = working ]; then
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded by active run"
        else
          RUN_DETAIL="$RUN_DETAIL${SEP}status-log superseded (run $RUN_STATE)"
        fi
      fi
      ;;
  esac

  emit "$RUN_STATE" run-step "$RUN_DETAIL"
fi

# --- fallback: no run attributed to this crew ------------------------------
# The run-step path above already handled any crew with a run, regardless of pane
# liveness, so a finished-but-pane-closed crew never reaches here. Down here there
# is no run to consult, so a dead/unreadable window means the crew is gone: report
# unknown rather than trusting a possibly-stale status log as the current state.
[ -n "$WIN" ] || emit unknown none "no window recorded"
pane_readable "$WIN" || emit unknown none "window gone: $WIN"

# Secondmates idle on their own watcher (idle pane = healthy), so the busy
# signature is not meaningful for them; read their state from the status log only.
if [ "$KIND" != secondmate ] && crew_pane_is_busy "$WIN"; then
  emit working pane "harness busy"
fi

if [ -n "$LOG_VERB" ]; then
  emit "$(map_log_state "$LOG_LINE")" status-log "$(log_note_of "$LOG_LINE")"
fi

emit unknown none "no current-state source available"
