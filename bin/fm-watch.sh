#!/usr/bin/env bash
# Firstmate watcher.
# Classifies supervision wakes in bash. In normal mode it absorbs benign wakes
# and keeps blocking; it queues and exits only for actionable wakes. The no-verb
# turn-end / non-terminal-stale path is absorb-only-when-provably-working: a wake
# is absorbed only when the crew shows POSITIVE evidence it is still working (an
# actively-running no-mistakes step, or a busy pane), and surfaced otherwise, so a
# crew that finishes (or stops and waits) without a captain-relevant status is
# never silently swallowed. While state/.afk exists, the daemon owns triage and
# this watcher queues and exits on every wake. Printed reason lines:
#   signal: <file>...      status/turn-end signals, surfaced when a listed status
#                          has a captain-relevant verb OR a no-verb signal's crew
#                          is not provably working, unless afk is active
#   stale: <window>        terminal stale pane, a non-terminal stale whose crew is
#                          not provably working (surfaced at once), a provably-
#                          working stale past the wedge threshold, or an expired
#                          paused external-wait recheck, unless afk active
#   check: <script>: <out> authenticated check output, always actionable
#   check: rejected unauthenticated state checks: <paths>
#                          unsafe state checks were refused without execution
#   check: rejected unauthenticated PR poll retirement receipts: <paths>
#                          invalid pending retirements were preserved without
#                          running a check or removing poll artifacts
#   heartbeat              fleet-scan backstop found an unsurfaced captain-relevant
#                          status, unless afk is active
# For normal supervision, re-arm after each printed reason by running
# bin/fm-watch-arm.sh through the harness's tracked background mechanism. Direct
# duplicate invocations of this script still no-op through the watcher singleton
# lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-worker-isolation-lib.sh
. "$SCRIPT_DIR/fm-worker-isolation-lib.sh"
fm_worker_refuse_primary_operation "watch" || exit 1
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
mkdir -p "$STATE"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# Shared wake classifier (captain-relevant verbs + signal/stale/heartbeat
# predicates), the SAME library the away-mode daemon uses, so the triage policy
# has one definition.
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# The watcher's poll loop is the tmux backend's event-source implementation:
# capture plus the existing hash/busy checks. Keep the wake policy unchanged.
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pane-idle-lib.sh
. "$SCRIPT_DIR/fm-pane-idle-lib.sh"
# shellcheck source=bin/fm-watch-events-lib.sh
. "$SCRIPT_DIR/fm-watch-events-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# Parent-owned secondmate missed-report guards: durable pending-reply
# expectations created by fm-send on marked secondmate requests. The tick is
# cheap when no records exist and never scrapes secondmate conversation.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-watcher-protocol-lib.sh
. "$SCRIPT_DIR/fm-watcher-protocol-lib.sh"

WATCH_LOCK="$STATE/.watch.lock"
WATCH_PATH="$SCRIPT_DIR/fm-watch.sh"
WATCHER_STALE_GRACE=${FM_WATCHER_STALE_GRACE:-${FM_GUARD_GRACE:-300}}

# Portable stat. macOS (BSD) stat uses `-f <fmt>`; Linux (GNU) stat uses `-c <fmt>`.
# Do NOT use the `stat -f <fmt> ... || stat -c <fmt> ...` fallback form: on Linux
# `stat -f` is *filesystem* stat and writes a partial filesystem dump ("File: ...",
# "Blocks: ...") to stdout before failing, so the fallback's correct output gets
# appended to that garbage. Arithmetic under `set -u` then aborts on the stray
# token (e.g. the word "File" read as an unset variable), which silently kills the
# watcher mid-cycle. Detect the platform once and pick the right form.
if [ "$(uname)" = Darwin ]; then
  stat_mtime() { stat -f %m "$1" 2>/dev/null; }        # epoch seconds of mtime
  stat_sig()   { stat -f '%z:%Fm' "$1" 2>/dev/null; }   # size:mtime signature
else
  stat_mtime() { stat -c %Y "$1" 2>/dev/null; }
  stat_sig()   { stat -c '%s:%Y' "$1" 2>/dev/null; }
fi

POLL=${FM_POLL:-15}                   # seconds between cycles
HEARTBEAT=${FM_HEARTBEAT:-600}        # base seconds between heartbeat scans
HEARTBEAT_MAX=${FM_HEARTBEAT_MAX:-7200}  # heartbeat backoff cap
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-300}  # seconds between *.check.sh sweeps
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}     # seconds allowed per *.check.sh
SIGNAL_GRACE=${FM_SIGNAL_GRACE:-30}   # seconds to linger after a signal so trailing
                                      # signals (a status write, then the same turn's
                                      # turn-end hook) coalesce into one wake
PANE_IDLE_INDEX_BUDGET_SECS=$(positive_seconds_or_default \
  "${FM_PANE_IDLE_INDEX_BUDGET_SECS:-1}" 1)
WAKE_QUEUE_STATUS_BUDGET_SECS=$(positive_seconds_or_default \
  "${FM_WAKE_QUEUE_STATUS_BUDGET_SECS:-1}" 1)
# Busy signatures per harness, OR-ed. Extend via env when new adapters are verified.
# claude/codex: "esc to interrupt"; opencode: "esc interrupt"; pi: "Working...";
# grok: "Ctrl+c:cancel" (the mid-turn cancel hint in grok's keybind bar, shown iff a
# turn is running; absent when idle - see the harness-adapters skill for verification;
# ASCII avoids the locale fragility of matching grok's braille spinner glyph directly).
BUSY_REGEX=${FM_BUSY_REGEX:-'esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'}
# Always-on wake triage: most wakes during a long crew validation are benign (a
# working: note or turn-end while a pipeline runs, a no-change heartbeat). Rather
# than wake firstmate's LLM for each, this watcher classifies every wake in bash
# and ABSORBS the benign majority - it advances the suppression marker, logs to a
# debug log, and keeps blocking WITHOUT enqueuing or exiting. The no-verb turn-end
# / non-terminal-stale path is absorb-only-when-provably-working: such a wake is
# absorbed ONLY while the crew shows positive evidence it is still working (an
# actively-running no-mistakes step, or a busy pane, via crew_is_provably_working
# over fm-crew-state.sh); a crew that stopped its turn with no running pipeline and
# no busy pane is SURFACED, so a finish reported only through interactive pane menus
# (no done: status) is never swallowed. An ACTIONABLE wake (a captain-relevant
# signal, a no-verb signal whose crew is not provably working, any check, a
# terminal stale, a not-provably-working stale, a provably-working stale past the
# threshold, or anything unknown) is written to the durable queue and exits, which
# is what wakes the LLM through the background-task completion. The same classifier
# (fm-classify-lib.sh) backs the away-mode daemon; while state/.afk exists the
# daemon owns triage, so this watcher reverts to one-shot (enqueue + exit on every
# wake) and never double-triages - and never runs the costly provably-working read.
STALE_ESCALATE_SECS=${FM_STALE_ESCALATE_SECS:-240}  # idle secs before a non-terminal stale escalates as a possible wedge
PAUSE_RESURFACE_SECS=$(positive_seconds_or_default \
  "${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}" \
  "$FM_PAUSE_RESURFACE_SECS_DEFAULT")
TRIAGE_LOG="$STATE/.watch-triage.log"
TRIAGE_LOG_MAX_BYTES=${FM_WATCH_TRIAGE_LOG_MAX_BYTES:-262144}

# afk_present: 0 while the away-mode flag exists. When set, the daemon wraps this
# watcher and owns triage, so the watcher must behave one-shot (enqueue + exit on
# every wake) and let the daemon classify - never absorb here, or the daemon's
# digest/injection layer would never see the wake.
afk_present() { [ -e "$STATE/.afk" ]; }

# Pause tracking is local to the existing watcher state directory. A pause marker
# stores its first-observed epoch; the recheck marker bounds authoritative
# run-state reads, and the re-surfaced marker prevents duplicate wakes in one
# cadence window.
pause_key() { printf '%s' "$1" | tr ':/.' '___'; }

pause_window_for_task() {  # <task>
  local task=$1 meta w
  for meta in "$STATE/$task.meta" "$STATE/$task.status.meta"; do
    [ -e "$meta" ] || continue
    w=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ -n "$w" ] && { printf '%s' "$w"; return; }
  done
}

pause_marker_record_status() {  # <status-file>
  local f=$1 task win key marker
  task=$(basename "$f"); task=${task%.status}
  win=$(pause_window_for_task "$task")
  [ -n "$win" ] || return 0
  key=$(pause_key "$win")
  marker="$STATE/.paused-$key"
  if ! grep -qE '^[0-9]+$' "$marker" 2>/dev/null; then
    date +%s > "$marker"
  fi
}

pause_tracking_clear() {  # <window>
  local key
  key=$(pause_key "$1")
  rm -f "$STATE/.paused-$key" "$STATE/.paused-rechecked-$key" \
    "$STATE/.paused-resurfaced-$key"
}

# Return paused/working/none for a stale window. Re-read authoritative crew state
# only on first sight and after the normal stale recheck interval; a stale pause
# cannot hide a resumed run indefinitely, while each poll remains cheap.
pause_state_class() {  # <window> <task>
  local win=$1 task=$2 key last recheck class age normalized
  key=$(pause_key "$win")
  last=$(last_status_line "$STATE/$task.status")
  if ! status_is_paused "$last"; then
    # A pause that ended must not carry its pre-pause wedge timer into the
    # ordinary stale path; a fresh timer will be initialized if the pane stays idle.
    if [ -e "$STATE/.paused-$key" ] || [ -e "$STATE/.paused-rechecked-$key" ] || [ -e "$STATE/.paused-resurfaced-$key" ]; then
      rm -f "$STATE/.stale-since-$key"
    fi
    pause_tracking_clear "$win"
    printf 'none'
    return
  fi
  recheck="$STATE/.paused-rechecked-$key"
  if [ -e "$STATE/.paused-$key" ]; then
    age=$(cat "$recheck" 2>/dev/null || true)
    case "$age" in
      ''|*[!0-9]*) ;;
      *)
        normalized=$(decimal_digits_or_zero "$age") || normalized=0
        if [ $(( $(date +%s) - normalized )) -lt "$STALE_ESCALATE_SECS" ]; then
          printf 'paused'
          return
        fi
        ;;
    esac
  fi
  class=$(crew_absorb_class "$task")
  case "$class" in
    paused)
      date +%s > "$recheck"
      printf 'paused'
      ;;
    *)
      # A timer that predates a declared pause must not immediately wedge-wake
      # after the pause ends; clear it only when pause tracking actually existed.
      if [ -e "$STATE/.paused-$key" ] || [ -e "$recheck" ] || [ -e "$STATE/.paused-resurfaced-$key" ]; then
        rm -f "$STATE/.stale-since-$key"
      fi
      pause_tracking_clear "$win"
      printf '%s' "$class"
      ;;
  esac
}

handle_paused_stale() {  # <window> <task> <hash>
  local win=$1 task=$2 h=$3 key marker resurfaced now age resurfaced_age reason
  key=$(pause_key "$win")
  marker="$STATE/.paused-$key"
  printf '%s' "$h" > "$STATE/.stale-$key"
  rm -f "$STATE/.stale-since-$key"
  if ! grep -qE '^[0-9]+$' "$marker" 2>/dev/null; then
    date +%s > "$marker"
  fi
  now=$(date +%s)
  marker_epoch=$(cat "$marker" 2>/dev/null || true)
  case "$marker_epoch" in
    ''|*[!0-9]*) marker_epoch=$now ;;
    *) marker_epoch=$(decimal_digits_or_zero "$marker_epoch") ;;
  esac
  age=$(( now - marker_epoch ))
  resurfaced="$STATE/.paused-resurfaced-$key"
  resurfaced_age=$(age_of "$resurfaced")
  if [ "$age" -ge "$PAUSE_RESURFACE_SECS" ] && [ "$resurfaced_age" -ge "$PAUSE_RESURFACE_SECS" ]; then
    reason="stale: $win (paused ${age}s, awaiting external; recheck the declared wait)"
    fm_wake_append stale "$win" "$reason" || exit 1
    printf '%s' "$now" > "$resurfaced"
    printf '%s' "$now" > "$marker"
    wake "$reason"
  fi
  triage_log "absorbed stale (paused, awaiting external, age ${age}s): $win"
}


# Append one line to the triage debug log explaining an absorbed (benign) wake,
# size-capped so a long benign stretch cannot grow it without bound. Best-effort:
# a logging hiccup never affects supervision.
triage_log() {
  local sz
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$TRIAGE_LOG" 2>/dev/null || return 0
  sz=$(wc -c < "$TRIAGE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$sz" in ''|*[!0-9]*) return 0 ;; esac
  if [ "$sz" -ge "$TRIAGE_LOG_MAX_BYTES" ]; then
    tail -n 2000 "$TRIAGE_LOG" > "$TRIAGE_LOG.tmp" 2>/dev/null && mv -f "$TRIAGE_LOG.tmp" "$TRIAGE_LOG" 2>/dev/null
    rm -f "$TRIAGE_LOG.tmp" 2>/dev/null || true
  fi
}

hash_pane() {
  fm_pane_idle_hash
}

window_kind() {
  local w=$1 deadline_ms=${2:-} meta_hint=${3:-} meta mw kind kind_count
  if [ -n "$meta_hint" ]; then
    meta=$meta_hint
  elif [ -n "$deadline_ms" ]; then
    if [ "${FM_PANE_IDLE_META_INDEX_BUILT:-0}" = 1 ]; then
      meta=$(fm_pane_idle_meta_for_window_bounded "$STATE" "$w" "$deadline_ms" 2>/dev/null) || return 1
    else
      meta=$(fm_pane_idle_meta_for_window_direct "$STATE" "$w" "$deadline_ms" 2>/dev/null) || return 1
    fi
    if [ -z "$meta" ]; then
      return 1
    fi
  else
    for meta in "$STATE"/*.meta; do
      [ -e "$meta" ] || continue
      mw=$(grep '^window=' "$meta" | cut -d= -f2- || true)
      [ "$mw" = "$w" ] || continue
      kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
      [ -n "$kind" ] || kind=ship
      echo "$kind"
      return 0
    done
    echo unknown
    return 0
  fi
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  kind_count=$(grep -c '^kind=' "$meta" 2>/dev/null || true)
  case "$kind_count" in
    0) printf 'ship\n'; return 0 ;;
    1)
      kind=$(grep '^kind=' "$meta" | cut -d= -f2- || true)
      case "$kind" in
        ship|scout|secondmate) printf '%s\n' "$kind"; return 0 ;;
        *) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

window_backend_from_meta() {
  local meta=$1 backend_count backend session window
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  backend_count=$(grep -c '^backend=' "$meta" 2>/dev/null || true)
  case "$backend_count" in
    0) printf 'tmux'; return 0 ;;
    1) backend=$(grep '^backend=' "$meta" | cut -d= -f2-) || return 1 ;;
    *) return 1 ;;
  esac
  case "$backend" in
    tmux) printf '%s' "$backend" ;;
    herdr)
      session=$(fm_pane_idle_meta_value_unique "$meta" herdr_session 2>/dev/null) || return 1
      [ "$session" = firstmate ] || return 1
      window=$(fm_pane_idle_meta_value_unique "$meta" window 2>/dev/null) || return 1
      case "$window" in firstmate:*) printf '%s' "$backend" ;; *) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
}

window_backend() {  # <window>
  local w=$1 deadline_ms=${2:-} meta_hint=${3:-} meta
  if [ -n "$meta_hint" ]; then
    meta=$meta_hint
    window_backend_from_meta "$meta"
    return $?
  elif [ -n "$deadline_ms" ]; then
    if [ "${FM_PANE_IDLE_META_INDEX_BUILT:-0}" = 1 ]; then
      meta=$(fm_pane_idle_meta_for_window_bounded "$STATE" "$w" "$deadline_ms" 2>/dev/null) || return 1
    else
      meta=$(fm_pane_idle_meta_for_window_direct "$STATE" "$w" "$deadline_ms" 2>/dev/null) || return 1
    fi
    if [ -z "$meta" ]; then
      return 1
    fi
    window_backend_from_meta "$meta"
    return $?
  fi
  meta=$(fm_backend_meta_for_window "$w" "$STATE" 2>/dev/null || true)
  [ -n "$meta" ] || return 1
  window_backend_from_meta "$meta"
}

recorded_windows() {
  local deadline_ms=${1:-} meta w seen=
  if [ -n "$deadline_ms" ]; then
    if [ "${FM_PANE_IDLE_META_INDEX_BUILT:-0}" = 1 ] \
      && [ -f "${FM_PANE_IDLE_META_INDEX_SNAPSHOT:-}" ] \
      && [ ! -L "${FM_PANE_IDLE_META_INDEX_SNAPSHOT:-}" ]; then
      fm_pane_idle_meta_index_windows_from_snapshot \
        "$FM_PANE_IDLE_META_INDEX_SNAPSHOT" "$deadline_ms"
    else
      return 124
    fi
    return $?
  fi
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    w=$(grep '^window=' "$meta" | cut -d= -f2- || true)
    [ -n "$w" ] || continue
    case "$seen" in
      *"|$w|"*) continue ;;
    esac
    seen="$seen|$w|"
    printf '%s\n' "$w"
  done
}

watch_window_scan_prepare() {
  local source=$1 cursor_path="$STATE/.watch-window.cursor" source_path="$STATE/.watch-window.source"
  local current tmp
  [ ! -L "$cursor_path" ] && [ ! -L "$source_path" ] || return 1
  current=$(cat "$source_path" 2>/dev/null || true)
  if [ "$current" != "$source" ]; then
    rm -f "$cursor_path" || return 1
    tmp=$(mktemp "$source_path.XXXXXX") || return 1
    [ -f "$tmp" ] && [ ! -L "$tmp" ] || { rm -f "$tmp"; return 1; }
    if ! printf '%s\n' "$source" > "$tmp" || [ -L "$source_path" ] \
      || ! mv -f "$tmp" "$source_path"; then
      rm -f "$tmp"
      return 1
    fi
  fi
  FM_WATCH_WINDOW_CURSOR=$(cat "$cursor_path" 2>/dev/null || true)
  if [ "$FM_WATCH_WINDOW_CURSOR" = EOF ]; then
    rm -f "$cursor_path" || return 1
    FM_WATCH_WINDOW_CURSOR=
  fi
  case "$FM_WATCH_WINDOW_CURSOR" in
    ''|*[!0-9]*)
      if [ -n "$FM_WATCH_WINDOW_CURSOR" ]; then
        rm -f "$cursor_path" || return 1
      fi
      FM_WATCH_WINDOW_CURSOR=
      ;;
  esac
}

watch_window_scan_advance() {
  local cursor=$1
  case "$cursor" in ''|*$'\r'*|*$'\n'*|*$'\t'*) return 1 ;; esac
  fm_pane_idle_meta_index_cursor_write "$STATE/.watch-window.cursor" "$cursor" || return 1
  FM_WATCH_WINDOW_CURSOR=$cursor
}

event_wait_herdr() {
  local timeout=$1 w backend session first_session='' record rc=0 pane_id to agent window meta task reason
  local event_scan_deadline windows_tmp windows_status=0 event_cursor event_source
  local event_cursor_path="$STATE/.herdr-window.cursor" event_source_path="$STATE/.herdr-window.source"
  local event_window_cursor event_meta
  local -a windows=()
  event_scan_deadline=$(( $(fm_pane_idle_now_ms) + PANE_IDLE_INDEX_BUDGET_SECS * 1000 ))
  [ "${FM_PANE_IDLE_META_INDEX_BUILT:-0}" = 1 ] \
    && [ -f "${FM_PANE_IDLE_META_INDEX_SNAPSHOT:-}" ] \
    && [ ! -L "${FM_PANE_IDLE_META_INDEX_SNAPSHOT:-}" ] || return 2
  event_source="snapshot:${FM_PANE_IDLE_META_INDEX_STATE_STAMP}"
  event_cursor=$(cat "$event_source_path" 2>/dev/null || true)
  if [ "$event_cursor" != "$event_source" ]; then
    rm -f "$event_cursor_path" || return 2
    printf '%s\n' "$event_source" > "$event_source_path" || return 2
  fi
  event_window_cursor=$(cat "$event_cursor_path" 2>/dev/null || true)
  if [ "$event_window_cursor" = EOF ]; then
    rm -f "$event_cursor_path" || return 2
    event_window_cursor=0
  fi
  case "$event_window_cursor" in ''|*[!0-9]*) event_window_cursor=0 ;; esac
  windows_tmp=$(mktemp "$STATE/.herdr-windows.XXXXXX") || return 2
  [ -f "$windows_tmp" ] && [ ! -L "$windows_tmp" ] || { rm -f "$windows_tmp"; return 2; }
  fm_pane_idle_meta_index_windows_from_snapshot_resumable \
    "$FM_PANE_IDLE_META_INDEX_SNAPSHOT" "$event_window_cursor" \
    "$event_scan_deadline" > "$windows_tmp" || windows_status=$?
  case "$windows_status" in
    0) ;;
    124) ;;
    *) rm -f "$windows_tmp"; return 1 ;;
  esac
  while IFS= read -r -d '' event_window_cursor \
    && IFS= read -r -d '' w \
    && IFS= read -r -d '' event_meta; do
    [ "$(fm_pane_idle_now_ms)" -lt "$event_scan_deadline" ] || {
      rm -f "$windows_tmp"
      return 2
    }
    if [ -z "$w" ]; then
      fm_pane_idle_meta_index_cursor_write "$event_cursor_path" "$event_window_cursor" || {
        rm -f "$windows_tmp"
        return 2
      }
      continue
    fi
    backend=$(window_backend "$w" "$event_scan_deadline" "$event_meta") || continue
    fm_pane_idle_meta_index_cursor_write "$event_cursor_path" "$event_window_cursor" || {
      rm -f "$windows_tmp"
      return 2
    }
    [ "$backend" = herdr ] || continue
    session=${w%%:*}
    [ -n "$session" ] && [ "$session" != "$w" ] || continue
    if [ -z "$first_session" ]; then
      first_session=$session
    fi
    [ "$session" = "$first_session" ] || continue
    windows+=("$w")
  done < "$windows_tmp"
  rm -f "$windows_tmp" || return 2
  if [ "$windows_status" = 0 ]; then
    fm_pane_idle_meta_index_cursor_write "$event_cursor_path" EOF || return 2
  fi
  [ "${#windows[@]}" -gt 0 ] || return 2
  fm_watch_herdr_events_capable "$first_session" || return 2

  record=$(fm_watch_wait_herdr_transition "$STATE" "$timeout" "${windows[@]}") || rc=$?
  case "$rc" in
    0)
      pane_id=$(fm_transition_pane_id "$record")
      to=$(fm_transition_to_status "$record")
      agent=$(fm_transition_agent "$record")
      window="$first_session:$pane_id"
      meta=$(fm_backend_meta_for_window "$window" "$STATE" 2>/dev/null || true)
      if [ -n "$meta" ]; then
        task=$(basename "$meta" .meta)
      else
        task="$window"
      fi
      reason="check: Herdr transition $window -> $to${agent:+ ($agent)}"
      fm_wake_append check "$task" "$reason" || return 1
      fm_backend_commit_transition herdr "$STATE" "$first_session" "$record" || return 1
      wake "$reason"
      ;;
    1) return 0 ;;
    2) return 2 ;;
    *) return "$rc" ;;
  esac
}

# Exit reporting a wake. Consecutive heartbeats with no other wake in between
# mean an idle fleet, so the heartbeat interval backs off exponentially
# (base * 2^streak, capped at HEARTBEAT_MAX); any real wake resets the cadence.
wake() {
  local wake_output=$1 row _epoch _seq _kind _key _payload confirm_status
  case "$1" in
    heartbeat*) echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak" ;;
    *) echo 0 > "$STATE/.heartbeat-streak" ;;
  esac
  printf '%s\n' "$wake_output" || exit 1
  while IFS= read -r row || [ -n "$row" ]; do
    IFS=$(printf '\t') read -r _epoch _seq _kind _key _payload <<< "$row"
    case "$_key" in
      inactive-outcome:*)
        "$SCRIPT_DIR/fm-inactive-reconcile.sh" caller-output-complete \
          "$_key" "$row" "$WATCHER_PID" >/dev/null 2>&1 || exit 1
        confirm_status=0
        "$SCRIPT_DIR/fm-inactive-reconcile.sh" confirm "$_key" "$row" >/dev/null 2>&1 || confirm_status=$?
        [ "$confirm_status" = 0 ] || [ "$confirm_status" = 1 ] || exit "$confirm_status"
        ;;
    esac
  done <<< "$wake_output"
  exit 0
}

# Check and heartbeat cadence must survive actionable exits and restarts: the
# watcher may be relaunched before in-memory counters reach their threshold on a
# busy fleet. Persist the schedule as file mtimes instead.
age_of() {  # seconds since file mtime; "due immediately" if missing
  local f=$1 m
  m=$(stat_mtime "$f") || { echo 999999; return; }
  echo $(( $(date +%s) - m ))
}

# Layer 2 + 3 signal scan: status files and turn-end markers. Each file is
# compared against a persisted size:mtime signature (.seen-*) rather than
# mtime-vs-a-startup-touch, so signals that land while no watcher is running
# are caught by the next one, and same-second writes cannot slip through a
# strict -nt comparison. Pure read: prints one "<seen-file>\t<sig>\t<file>"
# line per changed file. .seen-* is updated only after the wake is either
# surfaced or intentionally absorbed, so a watcher killed mid-cycle never
# swallows a signal.
scan_signals() {
  local f sig sf
  for f in "$STATE"/*.status "$STATE"/*.turn-ended; do
    [ -e "$f" ] || continue
    sig=$(stat_sig "$f") || continue
    sf="$STATE/.seen-$(basename "$f" | tr '.' '_')"
    if [ "$sig" != "$(cat "$sf" 2>/dev/null)" ]; then
      printf '%s\t%s\t%s\n' "$sf" "$sig" "$f"
    fi
  done
  return 0
}

run_check_process() {
  local c=$1
  shift
  if [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v timeout >/dev/null 2>&1; then
    exec timeout "$CHECK_TIMEOUT" bash "$c" "$@"
  elif [ "${FM_CHECK_FORCE_FALLBACK:-0}" != 1 ] && command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout "$CHECK_TIMEOUT" bash "$c" "$@"
  else
    # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
    exec perl -e 'my $t = shift; my $owned = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0) unless $owned; exec @ARGV } my $group = $owned ? getpgrp(0) : $pid; my $stop = sub { $SIG{HUP} = $SIG{INT} = $SIG{TERM} = "IGNORE"; kill "TERM", -$group; select undef, undef, undef, 0.2; kill "KILL", -$group; waitpid $pid, 0; exit 124 }; local $SIG{ALRM} = $stop; local $SIG{HUP} = $stop; local $SIG{INT} = $stop; local $SIG{TERM} = $stop; alarm $t; waitpid $pid, 0; exit($? >> 8)' "$CHECK_TIMEOUT" "${FM_CHECK_OWNED_GROUP:-0}" bash "$c" "$@"
  fi
}

run_check() {
  ( run_check_process "$@" ) 2>/dev/null || true
}

FM_ACTIVE_CHECK_PID=
FM_ACTIVE_CHECK_PGID=
FM_CHECK_OUTPUT=
FM_CHECK_RESULT=
FM_CHECK_SIGNAL_PENDING=

fm_check_output_cleanup() {
  [ -z "$FM_CHECK_OUTPUT" ] || rm -f -- "$FM_CHECK_OUTPUT"
  FM_CHECK_OUTPUT=
}

fm_active_check_stop() {
  local pid=${FM_ACTIVE_CHECK_PID:-} pgid=${FM_ACTIVE_CHECK_PGID:-} i
  [ -n "$pid" ] || [ -n "$pgid" ] || return 0
  [ -z "$pgid" ] || kill -TERM -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  [ -z "$pgid" ] || kill -KILL -- "-$pgid" 2>/dev/null || true
  [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
  [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
  i=0
  while [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ -n "$pgid" ] && kill -0 -- "-$pgid" 2>/dev/null; then
    return 1
  fi
  FM_ACTIVE_CHECK_PID=
  FM_ACTIVE_CHECK_PGID=
}

run_check_capture() {
  local pgid
  fm_check_output_cleanup
  FM_CHECK_RESULT=
  FM_CHECK_OUTPUT=$(mktemp "$STATE/.fm-check-output.XXXXXX") || return 1
  chmod 0600 "$FM_CHECK_OUTPUT" || { fm_check_output_cleanup; return 1; }
  FM_CHECK_SIGNAL_PENDING=
  trap 'FM_CHECK_SIGNAL_PENDING=1' HUP INT TERM
  set -m
  ( FM_CHECK_OWNED_GROUP=1 run_check_process "$@" ) > "$FM_CHECK_OUTPUT" 2>/dev/null &
  FM_ACTIVE_CHECK_PID=$!
  FM_ACTIVE_CHECK_PGID=$FM_ACTIVE_CHECK_PID
  set +m
  pgid=$(ps -o pgid= -p "$FM_ACTIVE_CHECK_PID" 2>/dev/null | tr -d '[:space:]')
  trap 'exit 1' HUP INT TERM
  if [ -n "$pgid" ] && [ "$pgid" != "$FM_ACTIVE_CHECK_PGID" ]; then
    fm_active_check_stop || true
    fm_check_output_cleanup
    return 1
  fi
  [ -z "$FM_CHECK_SIGNAL_PENDING" ] || exit 1
  wait "$FM_ACTIVE_CHECK_PID" 2>/dev/null || true
  FM_ACTIVE_CHECK_PID=
  fm_active_check_stop || return 1
  FM_CHECK_RESULT=$(cat "$FM_CHECK_OUTPUT" 2>/dev/null || true)
  fm_check_output_cleanup
}

# Surfaced-marker bookkeeping for the heartbeat backstop. The watcher records the
# captain-relevant status line it SURFACED (woke firstmate for) in
# .hb-surfaced-<task>, the watcher's analogue of the daemon's
# .subsuper-seen-status. Unlike .seen-* (a size:mtime signature advanced on BOTH
# surface and absorb), .hb-surfaced is advanced ONLY on surface, so the heartbeat
# fleet-scan can tell apart a captain-relevant status that already woke firstmate
# from one that has not - the latter being a per-wake-path miss it must surface.
_hb_surfaced_path() { printf '%s/.hb-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"; }
_hb_terminal_surfaced_path() { printf '%s/.hb-terminal-surfaced-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"; }
_hb_surface_retry_path() { printf '%s/.hb-surface-retry-%s' "$STATE" "$(printf '%s' "$1" | tr ':/.' '___')"; }

surface_meta_value() {
  awk -F= -v wanted="$2" '$1 == wanted { print substr($0, index($0, "=") + 1); exit }' "$1" 2>/dev/null
}

surface_meta_value_unique() {
  awk -F= -v wanted="$2" '
    $1 == wanted { value=substr($0, index($0, "=") + 1); count++ }
    END { if (count == 1) { print value; exit 0 } if (count == 0) exit 1; exit 2 }
  ' "$1" 2>/dev/null
}

mark_terminal_surfaced_snapshot() {
  local task=$1 last=$2 spawn_incarnation=$3 tasktmp=$4 window=$5 worktree=$6
  local marker tmp
  case "$(status_line_verb "$last")" in
    done|failed) ;;
    *) return 0 ;;
  esac
  marker=$(_hb_terminal_surfaced_path "$task")
  tmp=$(mktemp "$STATE/.hb-terminal-surfaced.XXXXXX") || return 1
  if ! printf 'schema=fm-hb-terminal-surfaced.v1\nsnapshot=%s\nspawn_incarnation=%s\ntasktmp=%s\nwindow=%s\nworktree=%s\n' \
    "$last" "$spawn_incarnation" "$tasktmp" "$window" "$worktree" > "$tmp" \
    || ! mv -f "$tmp" "$marker"; then
    rm -f "$tmp"
    return 1
  fi
}

mark_terminal_surfaced() {
  local task=$1 last=$2 meta spawn_incarnation tasktmp window worktree rc
  case "$(status_line_verb "$last")" in
    done|failed) ;;
    *) return 0 ;;
  esac
  meta="$STATE/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  spawn_incarnation=
  if spawn_incarnation=$(surface_meta_value_unique "$meta" spawn_incarnation); then
    :
  else
    rc=$?
    [ "$rc" = 1 ] || [ "$rc" = 2 ] || return 1
    spawn_incarnation=
  fi
  tasktmp=$(surface_meta_value "$meta" tasktmp)
  window=$(surface_meta_value "$meta" window)
  worktree=$(surface_meta_value "$meta" worktree)
  mark_terminal_surfaced_snapshot "$task" "$last" "$spawn_incarnation" \
    "$tasktmp" "$window" "$worktree"
}

surface_retry_valid() {
  awk -F= '
    BEGIN {
      allowed["schema"]=1; allowed["task"]=1; allowed["snapshot"]=1
      allowed["spawn_incarnation"]=1; allowed["tasktmp"]=1
      allowed["window"]=1; allowed["worktree"]=1; allowed["wake_key"]=1
      allowed["wake_published"]=1
      required["schema"]=1; required["task"]=1; required["snapshot"]=1
      required["spawn_incarnation"]=1; required["tasktmp"]=1
      required["window"]=1; required["worktree"]=1; required["wake_key"]=1
      required["wake_published"]=1
      valid=1
    }
    /^[^=]+=/ {
      key=$1
      if (!(key in allowed) || (key in seen)) valid=0
      seen[key]=1
      values[key]=substr($0, index($0, "=") + 1)
      next
    }
    { valid=0 }
    END {
      for (key in required) if (!(key in seen)) valid=0
      exit !(valid && values["schema"] == "fm-hb-surface-retry.v1" && values["task"] != "" && values["snapshot"] != "" && values["wake_key"] != "" && values["wake_published"] ~ /^[012]$/)
    }
  ' "$1" 2>/dev/null
}

surface_retry_matches_current() {
  local retry=$1 task=$2 last=$3 meta="$STATE/$2.meta" current_spawn saved_spawn
  local current_tasktmp current_window current_worktree rc
  surface_retry_valid "$retry" || return 1
  [ "$(surface_meta_value_unique "$retry" task 2>/dev/null)" = "$task" ] || return 1
  [ "$(surface_meta_value_unique "$retry" snapshot 2>/dev/null)" = "$last" ] || return 1
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  saved_spawn=$(surface_meta_value_unique "$retry" spawn_incarnation 2>/dev/null) || return 1
  if current_spawn=$(surface_meta_value_unique "$meta" spawn_incarnation 2>/dev/null); then
    [ "$saved_spawn" = "$current_spawn" ] || return 1
    return 0
  fi
  rc=$?
  [ "$rc" = 1 ] || return 1
  [ -z "$saved_spawn" ] || return 1
  current_tasktmp=$(surface_meta_value "$meta" tasktmp)
  current_window=$(surface_meta_value "$meta" window)
  current_worktree=$(surface_meta_value "$meta" worktree)
  [ "$(surface_meta_value_unique "$retry" tasktmp 2>/dev/null)" = "$current_tasktmp" ] || return 1
  [ "$(surface_meta_value_unique "$retry" window 2>/dev/null)" = "$current_window" ] || return 1
  [ "$(surface_meta_value_unique "$retry" worktree 2>/dev/null)" = "$current_worktree" ] || return 1
}

surface_retry_write() {
  local task=$1 last=$2 wake_key=$3 wake_published=${4:-1}
  local meta="$STATE/$1.meta" retry tmp spawn_incarnation tasktmp window worktree rc
  case "$wake_published" in 0|1|2) ;; *) return 1 ;; esac
  spawn_incarnation= tasktmp= window= worktree=
  if [ -f "$meta" ] && [ ! -L "$meta" ]; then
    if spawn_incarnation=$(surface_meta_value_unique "$meta" spawn_incarnation); then
      :
    else
      rc=$?
      [ "$rc" = 1 ] || [ "$rc" = 2 ] || return 1
      spawn_incarnation=
    fi
    tasktmp=$(surface_meta_value "$meta" tasktmp)
    window=$(surface_meta_value "$meta" window)
    worktree=$(surface_meta_value "$meta" worktree)
  fi
  retry=$(_hb_surface_retry_path "$task")
  if [ -e "$retry" ]; then
    [ -f "$retry" ] && [ ! -L "$retry" ] && surface_retry_valid "$retry" || return 1
    if surface_retry_matches_current "$retry" "$task" "$last"; then
      [ "$(surface_meta_value_unique "$retry" wake_key 2>/dev/null)" = "$wake_key" ] || return 2
    fi
  fi
  tmp=$(mktemp "$STATE/.hb-surface-retry.XXXXXX") || return 1
  if ! printf 'schema=fm-hb-surface-retry.v1\ntask=%s\nsnapshot=%s\nspawn_incarnation=%s\ntasktmp=%s\nwindow=%s\nworktree=%s\nwake_key=%s\nwake_published=%s\n' \
    "$task" "$last" "$spawn_incarnation" "$tasktmp" "$window" "$worktree" "$wake_key" "$wake_published" > "$tmp" \
    || ! mv -f "$tmp" "$retry"; then
    rm -f "$tmp"
    return 1
  fi
}

surface_retry_mark_published() {
  local task=$1 last=$2 wake_key=$3 retry tmp line seen=0
  retry=$(_hb_surface_retry_path "$task")
  surface_retry_matches_current "$retry" "$task" "$last" || return 1
  [ "$(surface_meta_value_unique "$retry" wake_key 2>/dev/null)" = "$wake_key" ] || return 1
  tmp=$(mktemp "$STATE/.hb-surface-retry.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      wake_published=*) printf 'wake_published=1\n'; seen=1 ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$retry" > "$tmp" || { rm -f "$tmp"; return 1; }
  [ "$seen" = 1 ] || printf 'wake_published=1\n' >> "$tmp"
  [ ! -L "$retry" ] || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$retry" || { rm -f "$tmp"; return 1; }
}

surface_retry_complete_consumed() {
  local retry=$1 task=$2 last=$3 spawn_incarnation=$4 tasktmp=$5 window=$6 worktree=$7
  local marker tmp
  mark_terminal_surfaced_snapshot "$task" "$last" "$spawn_incarnation" \
    "$tasktmp" "$window" "$worktree" || return 2
  marker=$(_hb_surfaced_path "$task")
  tmp=$(mktemp "$STATE/.hb-surfaced.XXXXXX") || return 2
  if ! printf '%s' "$last" > "$tmp" || ! mv -f "$tmp" "$marker"; then
    rm -f "$tmp"
    return 2
  fi
  surface_retry_matches_current "$retry" "$task" "$last" || return 2
  rm -f "$retry" || return 2
  return 0
}

surface_retry_ordinary_consumed() {
  local retry=$1 task=$2 last=$3 wake_key=$4 marker spawn_incarnation
  [ "$wake_key" = "$task" ] || return 1
  marker=$(fm_wake_surface_consumed_path "$task")
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  awk -F= '
    BEGIN {
      allowed["schema"]=1; allowed["task"]=1; allowed["wake_key"]=1
      allowed["snapshot"]=1; allowed["spawn_incarnation"]=1
      required["schema"]=1; required["task"]=1; required["wake_key"]=1
      required["snapshot"]=1; required["spawn_incarnation"]=1
      valid=1
    }
    /^[^=]+=/ {
      key=$1
      if (!(key in allowed) || (key in seen)) valid=0
      seen[key]=1
      values[key]=substr($0, index($0, "=") + 1)
      next
    }
    { valid=0 }
    END {
      for (key in required) if (!(key in seen)) valid=0
      exit !(valid && values["schema"] == "fm-hb-surface-consumed.v1")
    }
  ' "$marker" 2>/dev/null || return 2
  [ "$(surface_meta_value_unique "$marker" task 2>/dev/null)" = "$task" ] || return 2
  [ "$(surface_meta_value_unique "$marker" wake_key 2>/dev/null)" = "$wake_key" ] || return 2
  [ "$(surface_meta_value_unique "$marker" snapshot 2>/dev/null)" = "$last" ] || return 1
  spawn_incarnation=$(surface_meta_value_unique "$retry" spawn_incarnation 2>/dev/null) || return 2
  [ "$(surface_meta_value_unique "$marker" spawn_incarnation 2>/dev/null)" = "$spawn_incarnation" ] || return 1
  surface_retry_complete_consumed "$retry" "$task" "$last" \
    "$spawn_incarnation" \
    "$(surface_meta_value_unique "$retry" tasktmp 2>/dev/null)" \
    "$(surface_meta_value_unique "$retry" window 2>/dev/null)" \
    "$(surface_meta_value_unique "$retry" worktree 2>/dev/null)" || return $?
  rm -f "$marker" || return 2
  return 0
}

surface_retry_receipt_consumed() {
  local retry=$1 task=$2 last=$3 wake_key=$4 fp rec suffix outcome expected_incarnation
  local spawn_incarnation tasktmp window worktree
  case "$wake_key" in
    inactive-outcome:*) fp=${wake_key#inactive-outcome:} ;;
    *) surface_retry_ordinary_consumed "$retry" "$task" "$last" "$wake_key"; return $? ;;
  esac
  case "$fp" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  surface_retry_matches_current "$retry" "$task" "$last" || return 1
  spawn_incarnation=$(surface_meta_value_unique "$retry" spawn_incarnation 2>/dev/null) || return 2
  tasktmp=$(surface_meta_value_unique "$retry" tasktmp 2>/dev/null) || return 2
  window=$(surface_meta_value_unique "$retry" window 2>/dev/null) || return 2
  worktree=$(surface_meta_value_unique "$retry" worktree 2>/dev/null) || return 2
  outcome=${last%%:*}
  expected_incarnation=$(surface_replay_incarnation "$task") || return 2
  for suffix in presented reported; do
    rec="$STATE/terminal-outcomes/$fp.$suffix"
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    [ "$(surface_meta_value_unique "$rec" schema 2>/dev/null)" = fm-jt-terminal-outcome.v1 ] || return 2
    [ "$(surface_meta_value_unique "$rec" fingerprint 2>/dev/null)" = "$fp" ] || return 2
    [ "$(surface_meta_value_unique "$rec" task_id 2>/dev/null)" = "$task" ] || return 2
    [ "$(surface_meta_value_unique "$rec" incarnation 2>/dev/null)" = "$expected_incarnation" ] || continue
    [ "$(surface_meta_value_unique "$rec" outcome 2>/dev/null)" = "$outcome" ] || continue
    [ "$(surface_meta_value_unique "$rec" terminal_snapshot 2>/dev/null)" = "$last" ] || continue
    surface_retry_complete_consumed "$retry" "$task" "$last" "$spawn_incarnation" \
      "$tasktmp" "$window" "$worktree"
    return $?
  done
  return 1
}

surface_retry_wake_state() {
  local wake_key=$1 status wake_deadline remaining
  [ -e "$FM_WAKE_QUEUE" ] || return 1
  [ -f "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ] || return 2
  wake_deadline=$(( $(fm_pane_idle_now_ms) + WAKE_QUEUE_STATUS_BUDGET_SECS * 1000 ))
  remaining=$(fm_pane_idle_budget_secs "$wake_deadline") || return 2
  if fm_pane_idle_run_bounded_child "$remaining" perl - "$FM_WAKE_QUEUE" "$wake_key" <<'PERL'
use strict;
use warnings;
my ($path, $wanted) = @ARGV;
open(my $fh, '<', $path) or exit 2;
while (defined(my $line = <$fh>)) {
  my @fields = split(/\t/, $line, -1);
  exit 0 if defined($fields[3]) && $fields[3] eq $wanted;
}
close($fh) or exit 2;
exit 1;
PERL
  then
    return 0
  else
    status=$?
  fi
  [ "$status" = 1 ] && return 1
  return 2
}

surface_retry_published_current() {
  local retry=$1 task=$2 last=$3 wake_key=$4 published
  if [ -L "$retry" ] || [ -e "$retry" ]; then
    [ -f "$retry" ] && [ ! -L "$retry" ] && surface_retry_valid "$retry" || return 2
  else
    return 1
  fi
  surface_retry_matches_current "$retry" "$task" "$last" || return 1
  [ "$(surface_meta_value_unique "$retry" wake_key 2>/dev/null)" = "$wake_key" ] || return 2
  published=$(surface_meta_value_unique "$retry" wake_published 2>/dev/null) || return 2
  case "$published" in
    1) return 0 ;;
    2)
      surface_retry_wake_state "$wake_key"
      case "$?" in
        0) surface_retry_mark_published "$task" "$last" "$wake_key" || return 2; return 0 ;;
        1) surface_retry_receipt_consumed "$retry" "$task" "$last" "$wake_key"; return $? ;;
        *) return 2 ;;
      esac
      ;;
    0) ;;
    *) return 2 ;;
  esac
  surface_retry_wake_state "$wake_key"
  case "$?" in
    0) surface_retry_mark_published "$task" "$last" "$wake_key" || return 2; return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

surface_hash_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  else
    return 1
  fi
}

surface_replay_incarnation() {
  local task=$1 meta="$STATE/$1.meta" token tasktmp window worktree seed digest rc
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  if token=$(surface_meta_value_unique "$meta" spawn_incarnation); then
    case "$token" in ''|legacy-unknown|*[!A-Za-z0-9._:-]*) return 1 ;; esac
    printf '%s' "$token"
    return 0
  fi
  rc=$?
  [ "$rc" = 1 ] || return 1
  tasktmp=$(surface_meta_value "$meta" tasktmp)
  window=$(surface_meta_value "$meta" window)
  worktree=$(surface_meta_value "$meta" worktree)
  if [ -n "$tasktmp" ]; then
    seed="legacy|tasktmp=$tasktmp"
  else
    seed="legacy|window=$window|worktree=$worktree"
  fi
  digest=$(surface_hash_text "$seed") || return 1
  printf 'legacy-%s' "${digest:0:32}"
}

surface_retry_repair() {
  local retry task last spawn_incarnation tasktmp window worktree wake_key
  local status=0 status_file sig sf marker tmp
  for retry in "$STATE"/.hb-surface-retry-*; do
    [ -e "$retry" ] || continue
    [ -f "$retry" ] && [ ! -L "$retry" ] && surface_retry_valid "$retry" || { status=1; continue; }
    task=$(surface_meta_value "$retry" task)
    last=$(surface_meta_value "$retry" snapshot)
    spawn_incarnation=$(surface_meta_value "$retry" spawn_incarnation)
    tasktmp=$(surface_meta_value "$retry" tasktmp)
    window=$(surface_meta_value "$retry" window)
    worktree=$(surface_meta_value "$retry" worktree)
    if ! surface_retry_matches_current "$retry" "$task" "$last"; then
      status=1
      continue
    fi
    case "$(surface_meta_value_unique "$retry" wake_published 2>/dev/null || true)" in
      1) ;;
      2)
        wake_key=$(surface_meta_value_unique "$retry" wake_key 2>/dev/null) || { status=1; continue; }
        surface_retry_wake_state "$wake_key"
        case "$?" in
          0) surface_retry_mark_published "$task" "$last" "$wake_key" || { status=1; continue; } ;;
          1)
            surface_retry_receipt_consumed "$retry" "$task" "$last" "$wake_key"
            case "$?" in 0|1) continue ;; *) status=1; continue ;; esac
            ;;
          *) status=1; continue ;;
        esac
        ;;
      0) continue ;;
      *) status=1; continue ;;
    esac
    if ! mark_terminal_surfaced_snapshot "$task" "$last" "$spawn_incarnation" \
      "$tasktmp" "$window" "$worktree"; then
      status=1
      continue
    fi
    marker=$(_hb_surfaced_path "$task")
    tmp=$(mktemp "$STATE/.hb-surfaced.XXXXXX") || { status=1; continue; }
    if ! printf '%s' "$last" > "$tmp" || ! mv -f "$tmp" "$marker"; then
      rm -f "$tmp"
      status=1
      continue
    fi
    status_file="$STATE/$task.status"
    if [ -f "$status_file" ] && [ ! -L "$status_file" ] \
      && [ "$(last_status_line "$status_file")" = "$last" ]; then
      sig=$(stat_sig "$status_file") || { status=1; continue; }
      sf="$STATE/.seen-$(basename "$status_file" | tr '.' '_')"
      printf '%s' "$sig" > "$sf" || { status=1; continue; }
    fi
    if ! surface_retry_matches_current "$retry" "$task" "$last"; then
      status=1
      continue
    fi
    rm -f "$retry" || status=1
  done
  return "$status"
}

# Record a status file's captain-relevant last line as surfaced (no-op for a
# non-captain-relevant or empty status). Call AFTER the wake is enqueued, so the
# enqueue-before-suppress ordering holds for this marker too.
mark_surfaced() {  # <status-file>
  local f=$1 wake_key=${2:-} task last retry marker tmp
  task=$(basename "$f"); task="${task%.status}"
  [ -n "$wake_key" ] || wake_key=$task
  last=$(last_status_line "$f")
  [ -n "$last" ] || return 0
  status_is_captain_relevant "$last" || return 0
  surface_retry_write "$task" "$last" "$wake_key" 1 || return 1
  retry=$(_hb_surface_retry_path "$task")
  mark_terminal_surfaced "$task" "$last" || return 1
  marker=$(_hb_surfaced_path "$task")
  tmp=$(mktemp "$STATE/.hb-surfaced.XXXXXX") || return 1
  if ! printf '%s' "$last" > "$tmp" || ! mv -f "$tmp" "$marker"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$retry" || return 1
}

# Mark every current captain-relevant status as surfaced. Called after the
# heartbeat backstop enqueues its wake, so the same statuses are not re-surfaced
# by the next heartbeat.
mark_all_captain_relevant_surfaced() {
  local f status=0
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    mark_surfaced "$f" || status=1
  done < <(scan_captain_relevant_statuses "$STATE")
  return "$status"
}

surface_signal_transaction() {
  local pending=$1 reason=$2 sf sig f task last terminal status=0 suppressed
  FM_SURFACE_PUBLISHED=0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  while IFS=$(printf '\t') read -r sf sig f; do
    [ -n "$sf" ] || continue
    suppressed=0
    terminal_signal_suppressed "$f" || suppressed=$?
    case "$suppressed" in
      0)
        printf '%s' "$sig" > "$sf" || status=1
        [ "$status" = 0 ] || break
        continue
        ;;
      1) ;;
      *) status=1; break ;;
    esac
    task=$(basename "$f"); task=${task%.status}
    last=$(last_status_line "$f")
    terminal=0
    case "$last" in done:*|failed:*) terminal=1 ;; esac
    if [ "$terminal" = 1 ]; then
      surface_retry_write "$task" "$last" "$task" 2 || { status=1; break; }
    fi
    if ! fm_wake_append_locked signal "$task" "$reason"; then
      status=1
      break
    fi
    if [ "$terminal" = 1 ]; then
      surface_retry_mark_published "$task" "$last" "$task" || { status=1; break; }
    fi
    FM_SURFACE_PUBLISHED=1
    if ! mark_surfaced "$f" || ! printf '%s' "$sig" > "$sf"; then
      status=1
      break
    fi
    if status_is_paused "$(last_status_line "$f")" && [ "$(status_file_kind "$f")" = secondmate ]; then
      pause_marker_record_status "$f" || status=1
    fi
    [ "$status" = 0 ] || break
  done <<< "$pending"
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
  return "$status"
}

terminal_surface_marker_current() {
  local task=$1 meta="$STATE/$1.meta" status_file="$STATE/$1.status"
  local marker="$STATE/.hb-terminal-surfaced-$(printf '%s' "$1" | tr ':/.' '___')"
  local last saved_snapshot saved_spawn current_spawn rc
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  [ -f "$status_file" ] && [ ! -L "$status_file" ] || return 1
  marker=$(printf '%s' "$marker")
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 1
  [ "$(surface_meta_value_unique "$marker" schema 2>/dev/null)" = fm-hb-terminal-surfaced.v1 ] || return 1
  last=$(last_status_line "$status_file")
  case "$last" in done:*|failed:*) ;; *) return 1 ;; esac
  saved_snapshot=$(surface_meta_value_unique "$marker" snapshot 2>/dev/null) || return 1
  [ "$saved_snapshot" = "$last" ] || return 1
  saved_spawn=$(surface_meta_value_unique "$marker" spawn_incarnation 2>/dev/null) || return 1
  if current_spawn=$(surface_meta_value_unique "$meta" spawn_incarnation 2>/dev/null); then
    [ "$saved_spawn" = "$current_spawn" ] || return 1
    return 0
  fi
  rc=$?
  [ "$rc" = 1 ] || return 1
  [ -z "$saved_spawn" ] || return 1
  [ "$(surface_meta_value_unique "$marker" tasktmp 2>/dev/null)" = "$(surface_meta_value "$meta" tasktmp)" ] || return 1
  [ "$(surface_meta_value_unique "$marker" window 2>/dev/null)" = "$(surface_meta_value "$meta" window)" ] || return 1
  [ "$(surface_meta_value_unique "$marker" worktree 2>/dev/null)" = "$(surface_meta_value "$meta" worktree)" ] || return 1
}

inactive_replay_queued_for_task() {
  local task=$1 last outcome fp rec expected_incarnation queue_deadline queue_match rc
  [ -e "$FM_WAKE_QUEUE" ] || return 1
  [ -f "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ] || return 2
  last=$(last_status_line "$STATE/$task.status") || return 2
  outcome=${last%%:*}
  case "$outcome" in done|failed) ;; *) return 1 ;; esac
  expected_incarnation=$(surface_replay_incarnation "$task") || return 2
  queue_deadline=$(( $(fm_pane_idle_now_ms) + WAKE_QUEUE_STATUS_BUDGET_SECS * 1000 ))
  queue_match=$(fm_pane_idle_run_bounded_perl "$queue_deadline" "$FM_WAKE_QUEUE" "$task" <<'PERL'
use strict;
use warnings;
my ($queue, $task) = @ARGV;
open(my $fh, '<', $queue) or exit 2;
my $needle = "task=$task ";
while (defined(my $line = <$fh>)) {
  chomp $line;
  my @fields = split(/\t/, $line, 5);
  @fields == 5 or exit 2;
  next unless $fields[2] eq 'check';
  next unless $fields[3] =~ /\Ainactive-outcome:(.*)\z/;
  my $fp = $1;
  $fp ne '' && $fp =~ /\A[A-Fa-f0-9]+\z/ or exit 2;
  next unless index($fields[4], $needle) >= 0;
  print $fp or exit 2;
  close($fh) or exit 2;
  exit 0;
}
close($fh) or exit 2;
exit 1;
PERL
  )
  rc=$?
  case "$rc" in
    0) fp=$queue_match ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
  for rec in "$STATE/terminal-outcomes/$fp.pending" \
    "$STATE/terminal-outcomes/$fp.presented" "$STATE/terminal-outcomes/$fp.reported"; do
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    [ "$(surface_meta_value_unique "$rec" schema 2>/dev/null)" = fm-jt-terminal-outcome.v1 ] || return 2
    [ "$(surface_meta_value_unique "$rec" fingerprint 2>/dev/null)" = "$fp" ] || return 2
    [ "$(surface_meta_value_unique "$rec" task_id 2>/dev/null)" = "$task" ] || return 2
    [ "$(surface_meta_value_unique "$rec" incarnation 2>/dev/null)" = "$expected_incarnation" ] || continue
    [ "$(surface_meta_value_unique "$rec" outcome 2>/dev/null)" = "$outcome" ] || continue
    [ "$(surface_meta_value_unique "$rec" terminal_snapshot 2>/dev/null)" = "$last" ] || continue
    return 0
  done
  return 1
}

terminal_signal_suppressed() {
  local f=$1 task last retry retry_status marker_status replay_status retry_wake_key
  last=$(last_status_line "$f")
  case "$last" in
    done:*|failed:*) ;;
    *) return 1 ;;
  esac
  task=$(basename "$f" .status)
  terminal_surface_marker_current "$task" || marker_status=$?
  case "${marker_status:-0}" in
    0) return 0 ;;
    1) ;;
    *) return 2 ;;
  esac
  inactive_replay_queued_for_task "$task" || replay_status=$?
  case "${replay_status:-0}" in
    0) return 0 ;;
    1) ;;
    *) return 2 ;;
  esac
  retry=$(_hb_surface_retry_path "$task")
  retry_wake_key=$(surface_meta_value_unique "$retry" wake_key 2>/dev/null || true)
  surface_retry_published_current "$retry" "$task" "$last" "${retry_wake_key:-$task}" || retry_status=$?
  case "${retry_status:-0}" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

surface_terminal_stale_transaction() {
  local w=$1 h=$2 status=0 task last terminal=0 marker_status=0 replay_status=0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  task=$(window_to_task "$w")
  marker_status=0
  terminal_surface_marker_current "$task" || marker_status=$?
  if [ "$marker_status" = 0 ]; then
    fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
    return 2
  fi
  replay_status=0
  inactive_replay_queued_for_task "$task" || replay_status=$?
  case "$replay_status" in
    0)
      fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
      return 2
      ;;
    1) ;;
    *)
      fm_lock_release "$FM_WAKE_QUEUE_LOCK" || true
      return 2
      ;;
  esac
  last=$(last_status_line "$STATE/$task.status")
  case "$last" in done:*|failed:*) terminal=1 ;; esac
  if [ "$terminal" = 1 ]; then
    surface_retry_write "$task" "$last" "$w" 2 || status=1
  fi
  [ "$status" = 0 ] && fm_wake_append_locked stale "$w" "stale: $w" || status=1
  if [ "$status" = 0 ] && [ "$terminal" = 1 ]; then
    surface_retry_mark_published "$task" "$last" "$w" || status=1
  fi
  if [ "$status" = 0 ]; then
    mark_surfaced "$STATE/$(window_to_task "$w").status" "$w" || status=1
  fi
  if [ "$status" = 0 ]; then
    printf '%s' "$h" > "$STATE/.stale-$(printf '%s' "$w" | tr ':/.' '___')" || status=1
    rm -f "$STATE/.stale-since-$(printf '%s' "$w" | tr ':/.' '___')" || status=1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
  return "$status"
}

surface_heartbeat_transaction() {
  local status=0
  fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || return 1
  fm_wake_append_locked heartbeat heartbeat heartbeat || status=1
  if [ "$status" = 0 ]; then
    mark_all_captain_relevant_surfaced || status=1
  fi
  fm_lock_release "$FM_WAKE_QUEUE_LOCK" || status=1
  return "$status"
}

# Cheap heartbeat fleet-scan (the always-on twin of the daemon's catch-all). 0 if
# any captain-relevant status has NOT already been surfaced to firstmate (its
# content differs from the .hb-surfaced-<task> marker). Pure detect, no side
# effects: the caller enqueues first, then marks surfaced. Because every
# captain-relevant signal/stale already marks itself surfaced when it wakes
# firstmate, this normally finds nothing and the heartbeat is absorbed; it
# surfaces only a captain-relevant status the per-wake path absorbed by mistake -
# the fail-safe backstop.
heartbeat_scan_finds_actionable() {
  local f task last surfaced
  while IFS=$(printf '\t') read -r f task last; do
    [ -n "$f" ] || continue
    surfaced=$(cat "$(_hb_surfaced_path "$task")" 2>/dev/null || true)
    [ "$surfaced" = "$last" ] && continue
    return 0
  done < <(scan_captain_relevant_statuses "$STATE")
  return 1
}

# Unit tests source this file to exercise the bounded check runner. Runtime
# migration, lock acquisition, and the supervision loop must remain inert then.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

# Replace or quarantine checks created by older versions before acquiring the
# watcher lock or enumerating any runnable check. Migration never executes the
# legacy check files.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || {
  echo "watcher: PR check migration blocked; refusing to execute state checks" >&2
  exit 1
}

if ! fm_lock_try_acquire "$WATCH_LOCK"; then
  BEAT="$STATE/.last-watcher-beat"
  if [ -n "${FM_LOCK_HELD_PID:-}" ]; then
    if [ -e "$BEAT" ]; then
      beat_age=$(fm_path_age "$BEAT")
      if [ "$beat_age" -ge "$WATCHER_STALE_GRACE" ]; then
        echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but heartbeat is stale for ${beat_age}s (>${WATCHER_STALE_GRACE}s); inspect or stop that watcher before re-arming." >&2
        exit 1
      fi
    elif [ "$(fm_path_age "$WATCH_LOCK")" -ge "$WATCHER_STALE_GRACE" ]; then
      echo "watcher: lock held by live pid $FM_LOCK_HELD_PID but no heartbeat exists; inspect or stop that watcher before re-arming." >&2
      exit 1
    fi
    echo "watcher: already running pid $FM_LOCK_HELD_PID"
  else
    echo "watcher: already running"
  fi
  exit 0
fi
watcher_cleanup() {
  fm_active_check_stop || return 1
  fm_check_output_cleanup
  fm_custom_check_snapshot_cleanup
  fm_lock_release "$WATCH_LOCK"
}
trap watcher_cleanup EXIT
trap 'exit 1' HUP INT TERM
WATCHER_PID=${BASHPID:-$$}
printf '%s\n' "$FM_HOME" > "$WATCH_LOCK/fm-home" || true
printf '%s\n' "$WATCH_PATH" > "$WATCH_LOCK/watcher-path" || true
fm_pid_identity "$WATCHER_PID" > "$WATCH_LOCK/pid-identity" 2>/dev/null || true
fm_watcher_protocol_acknowledge "$STATE" "$FM_HOME" "$WATCH_PATH" || exit 1

surface_retry_repair || exit 1

[ -e "$STATE/.last-heartbeat" ] || touch "$STATE/.last-heartbeat"

# A merged poll may have queued its terminal wake and then lost the process
# between receipt publication and fixed-path removal. Finish only validated,
# identity-bound retirement receipts before any check can run.
if ! fm_pr_poll_retirement_recover_all "$STATE" "$SCRIPT_DIR/fm-pr-poll.sh"; then
  reason="check: rejected unauthenticated PR poll retirement receipts:$FM_PR_POLL_RETIREMENT_REJECTED"
  fm_wake_append check pr-poll-retirement "$reason" || exit 1
  touch "$STATE/.last-check"
  wake "$reason"
fi

while :; do
  # Self-eviction: if the singleton lock no longer names this process, a second
  # watcher has taken over (e.g. a transient duplicate from a racy arm). Stand
  # down so the rightful singleton continues alone. The EXIT trap's release
  # no-ops because the lock pid is not ours, so the survivor's lock is untouched.
  # This makes any duplicate self-resolve within one poll instead of persisting
  # and doubling every wake.
  if [ "$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)" != "$WATCHER_PID" ]; then
    exit 0
  fi

  # Liveness beacon for fm-guard.sh: a fresh mtime here means a watcher is
  # alive. Supervision scripts warn when this goes stale with tasks in flight.
  touch "$STATE/.last-watcher-beat"

  drain_output=
  drain_status=0
  drain_output=$(FM_WAKE_DRAIN_DIRECT=0 FM_WAKE_DRAIN_DEFER_ACK=1 \
    FM_WAKE_DRAIN_GENERATION="$WATCHER_PID" "$SCRIPT_DIR/fm-wake-drain.sh") \
    || drain_status=$?
  case "$drain_status" in
    0) [ -n "$drain_output" ] && wake "$drain_output" ;;
    3) exit 3 ;;
    *) exit "$drain_status" ;;
  esac

  # Parent-owned secondmate pending-reply reconciliation: resolve correlated
  # parent reports, observe backend busy/idle turn completion, send one recovery
  # repost after grace, and escalate once if the recovery turn is also missed.
  # No conversation scraping; unresolved records are never silently expired.
  fm_pending_reply_tick "$STATE" || true

  # The helper owns its bounded cadence and receipt idempotence. A non-empty
  # result means it appended an inactive-outcome wake, so surface that wake in
  # this watcher turn without probing panes or scraping secondmate chat here.
  if ! inactive_out=$("$SCRIPT_DIR/fm-inactive-reconcile.sh" scan 2>&1); then
    printf '%s\n' "$inactive_out" >&2
    exit 1
  fi
  if [ -n "$inactive_out" ]; then
    inactive_drain_output=
    inactive_drain_status=0
    inactive_drain_output=$(FM_WAKE_DRAIN_DIRECT=0 FM_WAKE_DRAIN_DEFER_ACK=1 \
      FM_WAKE_DRAIN_GENERATION="$WATCHER_PID" "$SCRIPT_DIR/fm-wake-drain.sh") \
      || inactive_drain_status=$?
    case "$inactive_drain_status" in
      0)
        [ -n "$inactive_drain_output" ] || exit 1
        wake "$inactive_drain_output"
        ;;
      3) exit 3 ;;
      *) exit "$inactive_drain_status" ;;
    esac
  fi

  # Slow per-task checks (firstmate writes these, e.g. a merged-PR poll).
  # Time-based via .last-check mtime so the cadence survives watcher restarts.
  # Evaluated BEFORE the signal scan: wake() exits the cycle, so a check placed
  # after the signal scan would be starved whenever a chatty sibling crewmate
  # keeps producing signals - the slow poll (e.g. merge detection) would then
  # never run until the fleet went quiet. Checks are due only every
  # CHECK_INTERVAL, so most cycles skip this block and fall straight through.
  if [ "$(age_of "$STATE/.last-check")" -ge "$CHECK_INTERVAL" ]; then
    rejected_checks=
    for c in "$STATE"/*.check.sh; do
      [ -e "$c" ] || continue
      is_pr_poll=0
      if [ "$(basename "$c")" = x-watch.check.sh ]; then
        if fmx_poll_shim_valid "$c" "$FM_HOME" "$FM_ROOT" \
          && [ -f "$FM_ROOT/bin/fm-x-poll.sh" ] && [ ! -L "$FM_ROOT/bin/fm-x-poll.sh" ]; then
          FM_HOME="$FM_HOME" run_check_capture "$FM_ROOT/bin/fm-x-poll.sh" || exit 1
          out=$FM_CHECK_RESULT
        else
          rejected_checks="$rejected_checks $c"
          continue
        fi
      else
        id=$(basename "$c" .check.sh)
        if fm_pr_poll_snapshot_capture "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh"; then
          is_pr_poll=1
          provider=$FM_PR_POLL_SNAPSHOT_PROVIDER
          url=$FM_PR_POLL_SNAPSHOT_URL
          host=$FM_PR_POLL_SNAPSHOT_HOST
          path=$FM_PR_POLL_SNAPSHOT_PATH
          number=$FM_PR_POLL_SNAPSHOT_NUMBER
          run_check_capture "$SCRIPT_DIR/fm-pr-poll.sh" --validated \
            "$provider" "$url" "$host" "$path" "$number" || exit 1
          out=$FM_CHECK_RESULT
        elif fm_custom_check_snapshot_prepare "$STATE" "$id"; then
          custom_snapshot=$FM_CUSTOM_CHECK_SNAPSHOT
          run_check_capture "$custom_snapshot" || exit 1
          out=$FM_CHECK_RESULT
          fm_custom_check_snapshot_cleanup
        else
          fm_custom_check_snapshot_cleanup
          rejected_checks="$rejected_checks $c"
          continue
        fi
      fi
      if [ -n "$out" ]; then
        reason="check: $c: $out"
        fm_wake_append check "$c" "$reason" || exit 1
        if [ "$is_pr_poll" -eq 1 ] && [ "$out" = merged ]; then
          if fm_pr_poll_retirement_publish "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" "$out"; then
            fm_pr_poll_retirement_recover_one "$STATE" "$id" "$SCRIPT_DIR/fm-pr-poll.sh" \
              || triage_log "merged PR poll retirement remains recoverable for $id"
          else
            triage_log "merged PR poll retirement deferred because its canonical snapshot changed for $id"
          fi
        fi
        touch "$STATE/.last-check"
        wake "$reason"
      fi
    done
    if [ -n "$rejected_checks" ]; then
      reason="check: rejected unauthenticated state checks:$rejected_checks"
      fm_wake_append check unauthenticated-state-checks "$reason" || exit 1
      touch "$STATE/.last-check"
      wake "$reason"
    fi
    touch "$STATE/.last-check"
  fi

  drain_output=
  drain_status=0
  drain_output=$(FM_WAKE_DRAIN_DIRECT=0 FM_WAKE_DRAIN_DEFER_ACK=1 \
    FM_WAKE_DRAIN_GENERATION="$WATCHER_PID" "$SCRIPT_DIR/fm-wake-drain.sh") \
    || drain_status=$?
  case "$drain_status" in
    0) [ -n "$drain_output" ] && wake "$drain_output" ;;
    3) exit 3 ;;
    *) exit "$drain_status" ;;
  esac

  # On the first changed signal, linger one grace period and re-scan before
  # classifying: a crewmate's final status write and the same turn's turn-end
  # hook land seconds apart, and reporting them as separate actionable wakes
  # costs a full firstmate turn each. The re-scan also picks up a newer
  # signature for an already-pending file (last write wins below).
  pending=$(scan_signals)
  if [ -n "$pending" ]; then
    sleep "$SIGNAL_GRACE"
    pending=$(printf '%s\n%s' "$pending" "$(scan_signals)")
    files=""
    while IFS=$(printf '\t') read -r sf sig f; do
      [ -n "$sf" ] || continue
      case " $files " in *" $f "*) ;; *) files="$files $f" ;; esac
    done <<EOF
$pending
EOF
    reason="signal:$files"
    # Triage: a signal is ACTIONABLE when any of these holds (cheapest first):
    #   - the away-mode daemon owns triage (afk) and wants every wake;
    #   - any status file carries a captain-relevant verb;
    #   - or it is a no-verb wake (a bare turn-end, a working: note) whose crew is
    #     NOT provably working - the crew stopped its turn with no actively-running
    #     pipeline and no busy pane, so it may be done (even via an interactive menu
    #     that wrote no done: status), waiting on a decision, or wedged. Absorbing
    #     such a turn-end is exactly the swallowed-finish this change guards against.
    # Actionable -> enqueue, advance .seen-* markers, exit. Benign (a no-verb wake
    # whose crew IS provably working) in always-on mode -> advance the markers so it
    # will not re-fire, log, and keep blocking without enqueuing. The provably-working
    # check is the only costly one (it may run a bounded no-mistakes call), so the ||
    # ordering evaluates it ONLY for a non-afk, no-captain-verb signal.
    # shellcheck disable=SC2086  # $files is a space-separated status-path list (ids carry no spaces)
    if afk_present || signal_reason_is_actionable $files || ! signal_crew_absorbable $files; then
      surface_signal_transaction "$pending" "$reason" || exit 1
      [ "$FM_SURFACE_PUBLISHED" = 1 ] && wake "$reason"
    else
      while IFS=$(printf '\t') read -r sf sig f; do
        [ -n "$sf" ] || continue
        printf '%s' "$sig" > "$sf"
      done <<EOF
$pending
EOF
      triage_log "absorbed benign $reason"
    fi
  fi

  # Layer 1 backbone: pane staleness. Two consecutive identical hashes with no busy
  # signature means the crewmate finished, is waiting, or is wedged. Each distinct
  # stale hash is surfaced, absorbed, or timed toward escalation once (.stale-*
  # remembers the hash already classified).
  pane_idle_index_deadline=$(( $(fm_pane_idle_now_ms) + PANE_IDLE_INDEX_BUDGET_SECS * 1000 ))
  pane_idle_index_status=0
  fm_pane_idle_meta_index_build "$STATE" "$pane_idle_index_deadline" || pane_idle_index_status=$?
  case "$pane_idle_index_status" in
    0) ;;
    124) ;;
    *) exit "$pane_idle_index_status" ;;
  esac
  pane_idle_scan_deadline=$(( $(fm_pane_idle_now_ms) + PANE_IDLE_INDEX_BUDGET_SECS * 1000 ))
  window_scan_stream=$(mktemp "$STATE/.watch-window-stream.XXXXXX") || exit 1
  [ -f "$window_scan_stream" ] && [ ! -L "$window_scan_stream" ] || exit 1
  window_scan_status=0
  if [ "$FM_PANE_IDLE_META_INDEX_BUILT" = 1 ] \
    && [ -f "${FM_PANE_IDLE_META_INDEX_SNAPSHOT:-}" ] \
    && [ ! -L "${FM_PANE_IDLE_META_INDEX_SNAPSHOT:-}" ]; then
    window_scan_source="snapshot:${FM_PANE_IDLE_META_INDEX_STATE_STAMP}"
    watch_window_scan_prepare "$window_scan_source" || exit 1
    fm_pane_idle_meta_index_windows_from_snapshot_resumable \
      "$FM_PANE_IDLE_META_INDEX_SNAPSHOT" "${FM_WATCH_WINDOW_CURSOR:-0}" \
      "$pane_idle_scan_deadline" > "$window_scan_stream" || window_scan_status=$?
  else
    window_scan_stamp=$(cat "$STATE/.pane-idle-meta-index/.scan.entries.stamp" 2>/dev/null || true)
    window_scan_source="entries:${window_scan_stamp:-unknown}"
    watch_window_scan_prepare "$window_scan_source" || exit 1
    fm_pane_idle_meta_index_windows_direct_resumable "$STATE" \
      "${FM_WATCH_WINDOW_CURSOR:-}" "$pane_idle_scan_deadline" > "$window_scan_stream" \
      || window_scan_status=$?
  fi
  case "$window_scan_status" in
    0|124) ;;
    *) rm -f "$window_scan_stream"; exit "$window_scan_status" ;;
  esac
  window_scan_complete=1
  while IFS= read -r -d '' window_scan_cursor \
    && IFS= read -r -d '' w \
    && IFS= read -r -d '' window_meta; do
    if [ -z "$w" ]; then
      watch_window_scan_advance "$window_scan_cursor" || exit 1
      continue
    fi
    kind=
    kind=$(window_kind "$w" "$pane_idle_scan_deadline" "$window_meta") || {
      window_scan_complete=0
      break
    }
    if [ "$kind" = secondmate ]; then
      key=$(printf '%s' "$w" | tr ':/.' '___')
      if [ ! -e "$STATE/.paused-$key" ]; then
        watch_window_scan_advance "$window_scan_cursor" || exit 1
        continue
      fi
    fi
    backend=$(window_backend "$w" "$pane_idle_scan_deadline" "$window_meta") || {
      window_scan_complete=0
      break
    }
    if ! tail40=$(fm_backend_capture "$backend" "$w" 40 2>/dev/null); then
      reason="check: backend capture failed for $w (backend=$backend); inspect the runtime endpoint and task metadata"
      fm_wake_append check "$w" "$reason" || exit 1
      wake "$reason"
    fi
    h=$(printf '%s' "$tail40" | hash_pane)
    key=$(printf '%s' "$w" | tr ':/.' '___')
    hf="$STATE/.hash-$key"
    cf="$STATE/.count-$key"
    sf="$STATE/.stale-$key"
    ssf="$STATE/.stale-since-$key"
    prev=$(cat "$hf" 2>/dev/null || true)
    if [ "$h" = "$prev" ]; then
      n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
      echo "$n" > "$cf"
      if [ "$n" -ge 2 ] && ! printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -6 | grep -qiE "$BUSY_REGEX"; then
        if [ "$kind" != secondmate ]; then
          idle_meta=$window_meta
          if [ -n "$idle_meta" ]; then
            idle_task=${idle_meta##*/}
            idle_task=${idle_task%.meta}
            idle_backend=$(fm_backend_of_meta "$idle_meta")
            if ! fm_pane_idle_write "$STATE" "$idle_meta" "$idle_task" "$w" "$idle_backend" "$h" "$n"; then
              fm_pane_idle_clear "$STATE" "$idle_task" || true
              fm_pane_idle_meta_index_build "$STATE" "$pane_idle_scan_deadline" force || true
              refreshed_idle_meta=$(fm_pane_idle_meta_for_window_bounded "$STATE" "$w" \
                "$pane_idle_scan_deadline" 2>/dev/null || true)
              if [ -n "$refreshed_idle_meta" ] && [ -f "$refreshed_idle_meta" ] \
                && [ ! -L "$refreshed_idle_meta" ]; then
                refreshed_idle_task=${refreshed_idle_meta##*/}
                refreshed_idle_task=${refreshed_idle_task%.meta}
                refreshed_idle_backend=$(fm_backend_of_meta "$refreshed_idle_meta")
                fm_pane_idle_write "$STATE" "$refreshed_idle_meta" "$refreshed_idle_task" \
                  "$w" "$refreshed_idle_backend" "$h" "$n" \
                  || fm_pane_idle_clear "$STATE" "$refreshed_idle_task" || true
              fi
            fi
          else
            fm_pane_idle_clear_for_window "$STATE" "$w" "$pane_idle_scan_deadline" || true
          fi
        fi
        if ! afk_present; then
          task=$(window_to_task "$w")
          if [ "$(pause_state_class "$w" "$task")" = paused ]; then
            handle_paused_stale "$w" "$task" "$h"
            watch_window_scan_advance "$window_scan_cursor" || exit 1
            continue
          fi
        fi
        if afk_present; then
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            fm_wake_append stale "$w" "stale: $w" || exit 1
            printf '%s' "$h" > "$sf"
            wake "stale: $w"
          fi
        elif stale_is_terminal "$w" "$STATE"; then
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            terminal_surface_status=0
            surface_terminal_stale_transaction "$w" "$h" || terminal_surface_status=$?
            case "$terminal_surface_status" in
              0) ;;
              2)
                watch_window_scan_advance "$window_scan_cursor" || exit 1
                continue
                ;;
              *) exit "$terminal_surface_status" ;;
            esac
            rm -f "$ssf" || exit 1
            wake "stale: $w"
          fi
        else
          if [ "$(cat "$sf" 2>/dev/null || true)" != "$h" ]; then
            if crew_is_provably_working "$(window_to_task "$w")"; then
              printf '%s' "$h" > "$sf"
              date +%s > "$ssf"
              triage_log "absorbed non-terminal stale (provably working): $w"
            else
              fm_wake_append stale "$w" "stale: $w" || exit 1
              printf '%s' "$h" > "$sf"
              rm -f "$ssf"
              wake "stale: $w"
            fi
          else
            since=$(cat "$ssf" 2>/dev/null || true)
            case "$since" in
              ''|*[!0-9]*)
                date +%s > "$ssf"
                triage_log "absorbed non-terminal stale timer reset: $w"
                ;;
              *)
                age=$(( $(date +%s) - since ))
                if [ "$age" -ge "$STALE_ESCALATE_SECS" ]; then
                  fm_wake_append stale "$w" "stale: $w (idle ${age}s, possible wedge)" || exit 1
                  rm -f "$ssf"
                  wake "stale: $w (idle ${age}s, possible wedge)"
                fi
                ;;
            esac
          fi
        fi
      else
        fm_pane_idle_clear_for_window "$STATE" "$w" "$pane_idle_scan_deadline" || exit 1
        if [ "$n" -ge 2 ]; then
          pause_tracking_clear "$w"
        fi
        rm -f "$ssf"
      fi
    else
      printf '%s' "$h" > "$hf"
      echo 0 > "$cf"
      fm_pane_idle_clear_for_window "$STATE" "$w" "$pane_idle_scan_deadline" || exit 1
      if [ -n "$prev" ]; then
        pause_tracking_clear "$w"
      fi
      rm -f "$ssf"
    fi
    watch_window_scan_advance "$window_scan_cursor" || exit 1
  done < "$window_scan_stream"
  if [ "$window_scan_status" = 0 ] && [ "$window_scan_complete" = 1 ]; then
    watch_window_scan_advance EOF || exit 1
  fi
  rm -f "$window_scan_stream" || exit 1

  # Heartbeat: the watcher runs a cheap fleet-scan at a regular cadence no matter
  # what. Time-based via .last-heartbeat mtime; interval doubles per consecutive
  # no-change heartbeat (idle fleet) up to HEARTBEAT_MAX, and resets on any
  # surfaced non-heartbeat wake.
  streak=$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)
  [ "$streak" -gt 12 ] && streak=12
  hb=$(( HEARTBEAT * (1 << streak) ))
  [ "$hb" -gt "$HEARTBEAT_MAX" ] && hb=$HEARTBEAT_MAX
  if [ "$(age_of "$STATE/.last-heartbeat")" -ge "$hb" ]; then
    # Triage: in always-on mode a heartbeat is benign unless the cheap fleet-scan
    # turns up a captain-relevant status the per-wake path missed. Absorb the
    # no-change case (advance the schedule and back off exactly as wake() would,
    # without exiting); the away-mode daemon, when present, owns triage and wants
    # every heartbeat.
    if afk_present; then
      surface_heartbeat_transaction || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    elif heartbeat_scan_finds_actionable; then
      # Backstop: a captain-relevant status the per-wake path absorbed by mistake.
      # Enqueue first, then mark every captain-relevant status surfaced so the next
      # heartbeat does not re-fire them (enqueue-before-suppress preserved).
      surface_heartbeat_transaction || exit 1
      touch "$STATE/.last-heartbeat"
      wake "heartbeat"
    else
      touch "$STATE/.last-heartbeat"
      echo $(( $(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0) + 1 )) > "$STATE/.heartbeat-streak"
      triage_log "absorbed heartbeat (no captain-relevant change)"
    fi
  fi

  event_wait_herdr "$POLL"
  event_rc=$?
  case "$event_rc" in
    0) continue ;;
    2) sleep "$POLL" ;;
    *) exit "$event_rc" ;;
  esac
done
