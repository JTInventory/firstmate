#!/usr/bin/env bash
# bin/backends/herdr.sh - experimental Herdr session-provider adapter.
#
# Herdr is a session provider only. Treehouse remains the worktree provider,
# just as it does for tmux. This JT port targets Herdr protocol >=14 and the
# 0.7.x CLI. Event waits are optional and fail closed unless protocol 16 and
# the verified event schema are present; AFK/supervisor injection uses the
# adapter's pane send and read primitives when Herdr is selected.
#
# Default container shape (D4, decided empirically - see
# herdr-verification-p2.md "Task container shape", refined by
# docs/herdr-backend.md "Default task container shape"): ONE herdr workspace PER
# FIRSTMATE HOME (the primary, and each secondmate, gets its own), ONE herdr TAB
# per task inside its home's workspace. An optional, default-off presentation
# flag creates a disposable workspace for a clean fresh task instead. That
# workspace is a non-authoritative visual projection containing only the normal
# task pane. Its random token and journal never authorize lookup, adoption,
# reuse, closure, deletion, task ownership, or endpoint selection. Ambiguous or
# recovered launches use the default flat home workspace when duplicate-agent
# risk is independently absent. Target resolution stays parallel to the tmux
# adapter in both layouts.
# Projected create, move, and cleanup operations capture the named session's
# exact active workspace and tab. Herdr 0.7.4's last-pane close can focus an
# unrelated neighbor, so projected cleanup serializes and restores only the
# exact pre-close tab id, while refusing to close the active tab itself.
#
# Target string shape: "<herdr-session>:<pane-id>", e.g. "default:w1:p2" (the
# pane id itself contains a colon; the session is always the FIRST field, the
# remainder is the whole pane id - fm_backend_herdr_parse_target splits on the
# first colon only). This is the value stored in a herdr task's meta window=
# field and is what fm_backend_resolve_selector already returns unchanged for
# exact task-id, legacy fm-<id>, and explicit backend-target forms (that
# function has no herdr-specific logic; it just returns meta's window=
# verbatim).
#
# Authoritative task recovery/orphan discovery (ids may not deterministically match live state
# after a server restart in a differently-configured session; see the
# verification doc) uses LABEL matching (fm-<id> tab labels), never trusts a
# stored pane id blindly: fm_backend_herdr_list_live. The presentation journal
# is deliberately excluded from that path.
#
# Requires: herdr (CLI + socket), jq (JSON parsing). Bootstrap detects these
# through fm_backend_required_tools only when herdr is the resolved backend;
# this adapter also gates them again before spawning.

FM_BACKEND_HERDR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_HERDR_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_BACKEND_HERDR_MIN_PROTOCOL=14
FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL=16
FM_BACKEND_HERDR_SECONDMATE_MARKER=.fm-secondmate-home
FM_BACKEND_HERDR_HOME_TOKEN=firstmate_home
FM_BACKEND_HERDR_ESCALATED_PREFIX=.herdr-escalated-
FM_BACKEND_HERDR_VERSION_VERIFIED=0
FM_BACKEND_HERDR_VERSION_VERIFIED_SESSION=
FM_BACKEND_HERDR_LOCK_WAIT_ATTEMPTS=${FM_BACKEND_HERDR_LOCK_WAIT_ATTEMPTS:-100}

# shellcheck source=bin/fm-transition-lib.sh
. "$FM_BACKEND_HERDR_ROOT/bin/fm-transition-lib.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$FM_BACKEND_HERDR_ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-task-label-lib.sh
. "$FM_BACKEND_HERDR_ROOT/bin/fm-task-label-lib.sh"

FM_BACKEND_HERDR_MIN_PROTOCOL=14
# events.subscribe (the native pane.agent_status_changed push stream) and its
# subscription_event schema first shipped at protocol 16 (verified: herdr
# 0.7.3). Below this, or with the events surface absent from `herdr api schema`,
# the event fast-path fails closed to the watcher's poll loop
# (fm_backend_herdr_events_capable). Distinct from FM_BACKEND_HERDR_MIN_PROTOCOL
# (14): the adapter's spawn/capture/send primitives work on 14, only the push
# subscriber needs 16.
FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL=16
# workspace.move first appears in the protocol-16 schema.
# The installed CLI does not expose it as a workspace subcommand, so the
# presentation path uses one narrowly whitelisted raw-socket request after
# verifying the exact method and parameter schema.
FM_BACKEND_HERDR_MIN_WORKSPACE_MOVE_PROTOCOL=16
# Per-pane escalation dedupe marker prefix, under the state dir. One marker per
# window (keyed like the watcher's own .stale-<key>): set when a ->blocked edge
# is enqueued, cleared on any working edge, so exactly one wake fires per
# ->blocked edge and a reconnect level-reconcile never re-delivers a still-
# blocked pane. Mirrors bin/fm-watch.sh's .stale-<key> naming.
FM_BACKEND_HERDR_ESCALATED_PREFIX=".herdr-escalated-"
# .fm-secondmate-home is written by bin/fm-home-seed.sh (AGENTS.md section 6)
# at a seeded secondmate home's root, containing exactly that secondmate's id.
# The primary firstmate home never carries this marker.
FM_BACKEND_HERDR_SECONDMATE_MARKER=".fm-secondmate-home"
# The default-off presentation projection is intentionally separate from the
# authoritative task endpoint record.
# A per-task journal lives under state/ as <id>.herdr-presentation and records
# only the attempted projection's random correlator.
# No send, capture, kill, recovery, Treehouse, or ownership path reads it.
FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX=".herdr-presentation"

# fm_backend_herdr_workspace_label: the per-firstmate-HOME herdr workspace
# label (docs/herdr-backend.md "Default task container shape"). The PRIMARY home (no
# secondmate marker) resolves to the constant "firstmate", byte-identical to
# every pre-existing task's recorded label - no forced migration. A SECONDMATE
# home resolves to "2ndmate-<secondmate-id>", so its tasks land in their own
# workspace, obviously distinguishable from the primary's (and from every
# other secondmate's) in herdr's spaces sidebar. Read fresh from FM_HOME on
# every call rather than cached at source time: FM_HOME is the home's own
# durable identity, not env plumbing threaded through a call chain, so the
# label is automatically stable across every respawn/recovery for the life of
# that home. fm-spawn.sh briefly shadows FM_HOME to a secondmate's own home
# when the PRIMARY spawns that secondmate (its own process's FM_HOME still
# names the primary at that point) - see fm-spawn.sh's herdr case arm.
fm_backend_herdr_workspace_label() {
  local marker="$FM_HOME/$FM_BACKEND_HERDR_SECONDMATE_MARKER" id
  if [ -f "$marker" ]; then
    id=$(tr -d '[:space:]' < "$marker" 2>/dev/null)
    [ -n "$id" ] && { printf '2ndmate-%s' "$id"; return 0; }
  fi
  printf 'firstmate'
}

# Herdr 0.7.x has ambient environment support, but the CLI can silently route
# to another running server when only HERDR_SESSION is set. Keep the env marker
# for compatibility and always append the explicit session flag.
fm_backend_herdr_cli() {  # <session> <herdr args...>
  local session=$1
  shift
  HERDR_SESSION="$session" herdr "$@" --session "$session"
}

fm_backend_herdr_tool_check() {
  command -v herdr >/dev/null 2>&1 || {
    echo "error: backend=herdr selected but the 'herdr' CLI is not installed (https://herdr.dev; dual-licensed AGPL-3.0-or-later/commercial)" >&2
    return 1
  }
  command -v jq >/dev/null 2>&1 || {
    echo "error: backend=herdr selected but 'jq' is not installed (required for Herdr JSON output)" >&2
    return 1
  }
}

fm_backend_herdr_version_check() {
  local session=${1:-}
  [ -n "$session" ] && [ "$FM_BACKEND_HERDR_VERSION_VERIFIED_SESSION" = "$session" ] && return 0
  fm_backend_herdr_tool_check || return 1
  local out protocol version
  if [ -n "$session" ]; then
    out=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null) || {
      echo "error: Herdr status --json failed for session '$session'; is Herdr available?" >&2
      return 1
    }
  else
    out=$(herdr status --json 2>/dev/null) || {
      echo "error: Herdr status --json failed for the default session; is Herdr installed correctly?" >&2
      return 1
    }
  fi
  [ -n "$out" ] || {
    echo "error: Herdr status --json failed for ${session:-the default session}; is Herdr installed correctly?" >&2
    return 1
  }
  protocol=$(printf '%s' "$out" | jq -r '.client.protocol // empty' 2>/dev/null)
  version=$(printf '%s' "$out" | jq -r '.client.version // empty' 2>/dev/null)
  local version_tail
  case "$version" in
    0.7.*) version_tail=${version#0.7.} ;;
    *) version_tail= ;;
  esac
  case "$version_tail" in
    ''|*[!0-9]*)
      echo "error: Herdr client version ${version:-unknown} is outside the verified 0.7.x range" >&2
      return 1
      ;;
  esac
  case "$protocol" in
    ''|*[!0-9]*)
      echo "error: could not read Herdr client protocol; refusing an unverified build" >&2
      return 1
      ;;
  esac
  if [ "$protocol" -lt "$FM_BACKEND_HERDR_MIN_PROTOCOL" ]; then
    echo "error: Herdr protocol $protocol (version ${version:-unknown}) is older than the verified minimum $FM_BACKEND_HERDR_MIN_PROTOCOL" >&2
    return 1
  fi
  if [ -n "$session" ]; then
    FM_BACKEND_HERDR_VERSION_VERIFIED_SESSION=$session
  else
    FM_BACKEND_HERDR_VERSION_VERIFIED=1
  fi
}

fm_backend_herdr_home_identity() {
  local home=$FM_HOME
  if [ -d "$home" ]; then
    home=$(cd "$home" 2>/dev/null && pwd -P) || return 1
  fi
  command -v sha256sum >/dev/null 2>&1 || return 1
  printf '%s' "$home" | sha256sum | cut -d' ' -f1
}

fm_backend_herdr_session() {
  printf '%s' "${HERDR_SESSION:-default}"
}

# fm_backend_herdr_projection_id: generate a compact 128-bit base64url token.
# The token is a non-adversarial visual correlator, never destructive
# authority.
fm_backend_herdr_projection_id() {
  local token
  token=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null \
    | base64 \
    | tr '+/' '-_' \
    | tr -d '=\r\n') || return 1
  [ "${#token}" -eq 22 ] || return 1
  case "$token" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  printf '%s' "$token"
}

fm_backend_herdr_projection_journal_path() {  # <state-dir> <task-id>
  printf '%s/%s%s' "$1" "$2" "$FM_BACKEND_HERDR_PRESENTATION_JOURNAL_SUFFIX"
}

# fm_backend_herdr_projection_journal_create: atomically publish the
# non-authoritative attempt journal before any projection workspace create.
# A hard-link publication in the same state directory gives create-if-absent
# semantics, so concurrent attempts cannot overwrite each other's token.
fm_backend_herdr_projection_journal_create() {  # <state-dir> <task-id>
  local state=$1 id=$2 journal token tmp
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*)
      echo "error: invalid task id for herdr presentation journal" >&2
      return 1
      ;;
  esac
  mkdir -p "$state" || return 1
  journal=$(fm_backend_herdr_projection_journal_path "$state" "$id")
  if [ -e "$journal" ] || [ -L "$journal" ]; then
    echo "error: herdr presentation journal already exists for $id; refusing a concurrent or repeated projected create" >&2
    return 1
  fi
  token=$(fm_backend_herdr_projection_id) || {
    echo "error: could not generate a 128-bit herdr presentation projection id" >&2
    return 1
  }
  tmp=$(mktemp "$state/.${id}.herdr-presentation.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  if ! {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$id"
    printf 'projection_id=%s\n' "$token"
  } > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! ln "$tmp" "$journal" 2>/dev/null; then
    rm -f "$tmp"
    echo "error: herdr presentation journal appeared concurrently for $id; refusing projected create" >&2
    return 1
  fi
  rm -f "$tmp"
  printf '%s' "$token"
}

# fm_backend_herdr_projection_journal_token: validate and read a projection
# journal without sourcing it as shell code.
fm_backend_herdr_projection_journal_token() {  # <journal> <task-id>
  local journal=$1 id=$2 version recorded_id token lines
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  lines=$(wc -l < "$journal" 2>/dev/null | tr -d '[:space:]')
  [ "$lines" = 3 ] || return 1
  version=$(grep '^version=' "$journal" 2>/dev/null | cut -d= -f2- || true)
  recorded_id=$(grep '^task_id=' "$journal" 2>/dev/null | cut -d= -f2- || true)
  token=$(grep '^projection_id=' "$journal" 2>/dev/null | cut -d= -f2- || true)
  [ "$version" = 1 ] && [ "$recorded_id" = "$id" ] && [ "${#token}" -eq 22 ] || return 1
  case "$token" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  printf '%s' "$token"
}

# fm_backend_herdr_projection_concise_task_label: strip redundant owner
# prefixes from a task id used only in the presentation workspace label.
# Removes firstmate/, 2ndmate-<id>/, and a presentation-level fm- owner
# prefix when present. The ordinary task tab remains fm-<id> and is not
# built by this helper.
fm_backend_herdr_projection_concise_task_label() {  # <task-id>
  local task=$1
  case "$task" in
    firstmate/*) task=${task#firstmate/} ;;
    2ndmate-*/*) task=${task#*/} ;;
  esac
  case "$task" in
    fm-*) task=${task#fm-} ;;
  esac
  printf '%s' "$task"
}

# fm_backend_herdr_projection_workspace_label: presentation-only child label.
# Format is literal U+2514 BOX DRAWINGS LIGHT UP AND RIGHT, one space, the
# concise task label, then the unchanged · p:<full-22-char-token> suffix.
# Labels and tokens remain non-authoritative correlators only.
fm_backend_herdr_projection_workspace_label() {  # <task-id> <projection-id>
  printf '└ %s · p:%s' "$(fm_backend_herdr_projection_concise_task_label "$1")" "$2"
}

# fm_backend_herdr_presentation_session_lock_path: one machine-private lock
# path per live named Herdr session/socket, shared across every Firstmate home
# that uses that session.
# The path is never under any one home's state/ and secondmates never write the
# primary home. Returns non-zero when the named session's socket cannot be
# resolved unambiguously.
fm_backend_herdr_presentation_lock_namespace() {
  printf '%s' '/tmp/firstmate-herdr-presentation'
}

fm_backend_herdr_presentation_lock_namespace_mode() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%Lp' "$1" 2>/dev/null
  else
    stat -c '%a' "$1" 2>/dev/null
  fi
}

fm_backend_herdr_presentation_lock_namespace_uid() {
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    stat -f '%u' "$1" 2>/dev/null
  else
    stat -c '%u' "$1" 2>/dev/null
  fi
}

fm_backend_herdr_presentation_lock_namespace_valid() {
  local dir=$1 expected_uid owner mode
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  expected_uid=$(id -u 2>/dev/null) || return 1
  owner=$(fm_backend_herdr_presentation_lock_namespace_uid "$dir") || return 1
  mode=$(fm_backend_herdr_presentation_lock_namespace_mode "$dir") || return 1
  [ "$owner" = "$expected_uid" ] && [ "$mode" = 700 ]
}

# Resolve the one verified running named-session socket path as an absolute
# string. Requires JSON string type and non-empty length (jq -r is never used:
# it would turn JSON null into the literal string "null"). Canonicalizes the
# parent directory when that directory exists so symlink parents such as /tmp
# -> /private/tmp cannot yield two lock identities for the same socket.
fm_backend_herdr_presentation_session_socket_path() {  # <session>
  local session=$1 sessions socket sock_dir sock_base
  [ -n "$session" ] || return 1
  sessions=$(fm_backend_herdr_cli "$session" session list --json 2>/dev/null) || return 1
  socket=$(printf '%s' "$sessions" | jq -er --arg want "$session" '
    [.sessions[]?
      | select(.name == $want and .running == true)
      | select((.socket_path | type) == "string")
      | select((.socket_path | length) > 0)
      | .socket_path]
    | if length == 1 then .[0] else empty end
  ' 2>/dev/null) || return 1
  [ -n "$socket" ] || return 1
  case "$socket" in
    /*) ;;
    *) return 1 ;;
  esac
  sock_dir=$(dirname "$socket")
  sock_base=$(basename "$socket")
  [ -n "$sock_dir" ] && [ -n "$sock_base" ] || return 1
  if [ -d "$sock_dir" ]; then
    sock_dir=$(cd "$sock_dir" 2>/dev/null && pwd -P) || return 1
    socket="$sock_dir/$sock_base"
  fi
  printf '%s' "$socket"
}

fm_backend_herdr_presentation_session_lock_path() {  # <session>
  local session=$1 socket key dir hash
  [ -n "$session" ] || return 1
  socket=$(fm_backend_herdr_presentation_session_socket_path "$session") || return 1
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s\0%s' "$session" "$socket" | shasum -a 256 2>/dev/null | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s\0%s' "$session" "$socket" | sha256sum 2>/dev/null | awk '{print $1}')
  else
    return 1
  fi
  [ -n "$hash" ] || return 1
  key=${hash:0:32}
  dir=$(fm_backend_herdr_presentation_lock_namespace) || return 1
  [ -n "$dir" ] || return 1
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    if ! mkdir -m 700 "$dir" 2>/dev/null; then
      fm_backend_herdr_presentation_lock_namespace_valid "$dir" || return 1
    fi
  fi
  fm_backend_herdr_presentation_lock_namespace_valid "$dir" || return 1
  printf '%s/order-%s.lock' "$dir" "$key"
}

# fm_backend_herdr_projection_focus_snapshot: print the exact active
# workspace and tab ids as one tab-separated record.
# Presentation mutations use this read-only snapshot as their sole focus
# restoration authority.
# Labels, workspace order, and ambient client state are never focus authority.
fm_backend_herdr_projection_focus_snapshot() {  # <session>
  local session=$1 list snapshot workspace tab tabs
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  snapshot=$(printf '%s' "$list" | jq -r '
    [.result.workspaces[]? | select(.focused == true)]
    | select(length == 1)
    | .[0]
    | select((.workspace_id | type) == "string" and (.workspace_id | length) > 0)
    | select((.active_tab_id | type) == "string" and (.active_tab_id | length) > 0)
    | [.workspace_id, .active_tab_id]
    | @tsv
  ' 2>/dev/null) || return 1
  [ -n "$snapshot" ] || return 1
  workspace=${snapshot%%$'\t'*}
  tab=${snapshot#*$'\t'}
  [ -n "$workspace" ] && [ -n "$tab" ] && [ "$workspace" != "$tab" ] || return 1
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$workspace" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e --arg tab "$tab" '
    (.result.tabs | type) == "array"
    and ([.result.tabs[] | select(.focused == true)] | length) == 1
    and ([.result.tabs[] | select(.focused == true)][0].tab_id == $tab)
  ' >/dev/null 2>&1 || return 1
  printf '%s\t%s' "$workspace" "$tab"
}

# fm_backend_herdr_projection_focus_restore: verify that one presentation
# mutation preserved the exact active workspace and tab captured immediately
# before it.
# Herdr 0.7.4's pane.close can focus an unrelated neighboring workspace when
# it removes a non-focused workspace's last pane.
# A single tab.focus on the exact response-independent pre-operation tab id
# restores both the workspace and tab atomically.
fm_backend_herdr_projection_focus_restore() {  # <session> <snapshot> <operation>
  local session=$1 before=$2 operation=$3 workspace tab after info restored
  [ -n "$before" ] || {
    echo "warning: herdr presentation $operation had no unambiguous pre-operation focus snapshot" >&2
    return 1
  }
  after=$(fm_backend_herdr_projection_focus_snapshot "$session") || after=
  [ "$after" != "$before" ] || return 0
  workspace=${before%%$'\t'*}
  tab=${before#*$'\t'}
  info=$(fm_backend_herdr_cli "$session" tab get "$tab" 2>/dev/null) || {
    echo "warning: herdr presentation $operation changed focus and the exact prior tab could not be verified for restoration" >&2
    return 1
  }
  if ! printf '%s' "$info" | jq -e --arg workspace "$workspace" --arg tab "$tab" '
    .result.tab.workspace_id == $workspace and .result.tab.tab_id == $tab
  ' >/dev/null 2>&1; then
    echo "warning: herdr presentation $operation changed focus and the exact prior tab response was ambiguous" >&2
    return 1
  fi
  fm_backend_herdr_cli "$session" tab focus "$tab" >/dev/null 2>&1 || {
    echo "warning: herdr presentation $operation changed focus and exact-tab restoration failed" >&2
    return 1
  }
  restored=$(fm_backend_herdr_projection_focus_snapshot "$session") || restored=
  if [ "$restored" != "$before" ]; then
    echo "warning: herdr presentation $operation did not restore the exact prior workspace and tab" >&2
    return 1
  fi
  return 0
}

# fm_backend_herdr_projection_close_pane_focus_preserving: close one exact
# response-derived projection pane without leaving the captain focused
# anywhere else.
# If the target belongs to the active tab, exact tab preservation is
# impossible, so cleanup refuses instead of changing focus.
fm_backend_herdr_projection_close_pane_focus_preserving() {  # <session> <pane-id>
  local session=$1 pane_id=$2 before active_tab info target_pane target_tab close_status
  [ -n "$pane_id" ] || return 0
  before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "warning: herdr presentation cleanup could not capture exact active workspace and tab; refusing focus-unsafe pane close" >&2
    return 1
  }
  active_tab=${before#*$'\t'}
  info=$(fm_backend_herdr_cli "$session" pane get "$pane_id" 2>/dev/null) || {
    echo "warning: herdr presentation cleanup could not verify the exact pane; refusing focus-unsafe pane close" >&2
    return 1
  }
  target_pane=$(printf '%s' "$info" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  target_tab=$(printf '%s' "$info" | jq -r '.result.pane.tab_id // empty' 2>/dev/null)
  if [ "$target_pane" != "$pane_id" ] || [ -z "$target_tab" ]; then
    echo "warning: herdr presentation cleanup received an ambiguous exact-pane response; refusing focus-unsafe pane close" >&2
    return 1
  fi
  if [ "$target_tab" = "$active_tab" ]; then
    echo "warning: herdr presentation cleanup target is the captain's active tab; refusing a close that cannot preserve focus" >&2
    return 1
  fi
  if fm_backend_herdr_cli "$session" pane close "$pane_id" >/dev/null 2>&1; then
    close_status=0
  else
    close_status=$?
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$before" "pane close" || true
  return "$close_status"
}

# fm_backend_herdr_projection_order_best_effort: place the exact workspace id
# returned by THIS projected create immediately after its owning parent's
# contiguous child block and before the next parent.
#
# <parent-label> is the owning FM_HOME label (firstmate or 2ndmate-<id>).
# New-format └ ... · p:<token> children and, for compatibility only, already
# adjacent old-format firstmate/... or 2ndmate-<id>/... projections may extend
# the block read-only; they are never renamed or moved.
#
# This is presentation-only and always returns success.
# Every unavailable, ambiguous, failed, or unverifiable ordering step prints a
# warning and leaves the safely-created worker running in Herdr's current
# order.
# It never looks up a task endpoint, adopts or reuses a workspace, retries an
# ambiguous move, or calls any close/delete/rename primitive.
# The sole move target is <created-workspace-id>, captured directly from the
# current workspace-create response.
# After a successful move, every pre-existing workspace id sequence excluding
# the new id must be byte-identical to the pre-move sequence.
fm_backend_herdr_projection_order_best_effort() {  # <session> <created-workspace-id> <parent-label>
  local session=$1 created=$2 parent=$3 list analysis current desired protocol schema socket mover response move_status focus_before
  local before_existing after_existing
  [ -n "$parent" ] || {
    echo "warning: herdr presentation ordering missing owning parent label; leaving worker in Herdr's current order" >&2
    return 0
  }
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    echo "warning: herdr presentation ordering could not list workspaces; leaving worker in Herdr's current order" >&2
    return 0
  }
  analysis=$(printf '%s' "$list" | jq -c --arg created "$created" --arg parent "$parent" '
    def is_parent:
      (.label | type) == "string" and .label == $parent;
    def is_top_level_parent:
      (.label | type) == "string"
      and ((.label == "firstmate") or (.label | test("^2ndmate-[^/]+$")));
    def is_new_child:
      (.label | type) == "string"
      and (.label | test("^└ .+ · p:[A-Za-z0-9_-]{22}$"));
    def is_legacy_child:
      (.label | type) == "string"
      and (.label | test("^(firstmate|2ndmate-[^/]+)/.+ · p:[A-Za-z0-9_-]{22}$"));
    def is_legacy_child_for($owner):
      is_legacy_child and (.label | startswith($owner + "/"));
    def is_child_for($owner):
      is_new_child or is_legacy_child_for($owner);
    (.result.workspaces // null) as $spaces
    | select(($spaces | type) == "array" and ($spaces | length) > 0)
    | ([range(0; $spaces | length) | select($spaces[.].workspace_id == $created)]) as $matches
    | select(($matches | length) == 1)
    | ($matches[0]) as $current
    | select($current == (($spaces | length) - 1))
    | ([range(0; $spaces | length) | select($spaces[.] | is_parent)]) as $parents
    | select(($parents | length) == 1)
    | ($parents[0]) as $pidx
    | select($pidx < $current)
    | (
        reduce range($pidx + 1; $current) as $i (
          0;
          if ($spaces[$i] | is_child_for($parent)) and (. == ($i - $pidx - 1))
          then . + 1
          else .
          end
        )
      ) as $block
    | (reduce range($pidx + 1 + $block; $current) as $i (
        {valid: true, active_parent: null};
        if .valid == false then .
        elif ($spaces[$i] | is_top_level_parent) then
          .active_parent = $spaces[$i].label
        elif ($spaces[$i] | is_new_child) then
          if .active_parent == null then .valid = false else . end
        elif ($spaces[$i] | is_legacy_child) then
          .active_parent as $owner
          | if $owner == null then
              .valid = false
            elif (($spaces[$i] | is_legacy_child_for($owner)) | not) then
              .valid = false
            else
              .
            end
        else
          .active_parent = null
        end
      )) as $remainder
    | select($remainder.valid == true)
    | {
        current: $current,
        desired: ($pidx + 1 + $block),
        parent_index: $pidx,
        existing: [$spaces[] | select(.workspace_id != $created) | .workspace_id]
      }
  ' 2>/dev/null) || analysis=
  [ -n "$analysis" ] || {
    echo "warning: herdr presentation ordering found an ambiguous workspace layout; leaving worker in Herdr's current order" >&2
    return 0
  }
  current=$(printf '%s' "$analysis" | jq -r '.current // empty' 2>/dev/null)
  desired=$(printf '%s' "$analysis" | jq -r '.desired // empty' 2>/dev/null)
  case "$current:$desired" in
    *[!0-9:]*)
      echo "warning: herdr presentation ordering could not parse the target position; leaving worker in Herdr's current order" >&2
      return 0
      ;;
  esac
  [ "$current" != "$desired" ] || return 0

  command -v python3 >/dev/null 2>&1 || {
    echo "warning: herdr presentation ordering requires python3; leaving worker in Herdr's current order" >&2
    return 0
  }
  protocol=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.client.protocol // empty' 2>/dev/null)
  case "$protocol" in
    ''|*[!0-9]*)
      echo "warning: herdr presentation ordering could not verify the client protocol; leaving worker in Herdr's current order" >&2
      return 0
      ;;
  esac
  if [ "$protocol" -lt "$FM_BACKEND_HERDR_MIN_WORKSPACE_MOVE_PROTOCOL" ]; then
    echo "warning: herdr presentation ordering needs protocol $FM_BACKEND_HERDR_MIN_WORKSPACE_MOVE_PROTOCOL or newer; leaving worker in Herdr's current order" >&2
    return 0
  fi
  schema=$(fm_backend_herdr_cli "$session" api schema --json 2>/dev/null) || {
    echo "warning: herdr presentation ordering could not read the API schema; leaving worker in Herdr's current order" >&2
    return 0
  }
  if ! printf '%s' "$schema" | jq -e '
    any(.schemas.request.oneOf[]?; .properties.method.const == "workspace.move")
    and .schemas.request["$defs"].WorkspaceMoveParams.required == ["workspace_id", "insert_index"]
    and .schemas.request["$defs"].WorkspaceMoveParams.properties.insert_index.type == "integer"
  ' >/dev/null 2>&1; then
    echo "warning: herdr presentation ordering API support is unavailable or ambiguous; leaving worker in Herdr's current order" >&2
    return 0
  fi
  socket=$(fm_backend_herdr_presentation_session_socket_path "$session") || {
    echo "warning: herdr presentation ordering found an ambiguous named session socket; leaving worker in Herdr's current order" >&2
    return 0
  }

  mover=${FM_BACKEND_HERDR_WORKSPACE_MOVER:-$FM_BACKEND_HERDR_ROOT/bin/backends/herdr-workspace-move.py}
  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "warning: herdr presentation ordering could not capture exact active workspace and tab; leaving worker in Herdr's current order" >&2
    return 0
  }
  if response=$("$mover" "$socket" "$created" "$desired" 2>/dev/null); then
    move_status=0
  else
    move_status=$?
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "workspace move" || true
  if [ "$move_status" -ne 0 ]; then
    echo "warning: herdr presentation workspace move failed or had an ambiguous response; leaving worker running without cleanup" >&2
    return 0
  fi
  if ! printf '%s' "$response" | jq -e --arg created "$created" --arg parent "$parent" --argjson desired "$desired" '
    .result.type == "workspace_list"
    and (.result.workspaces | type) == "array"
    and .result.workspaces[$desired].workspace_id == $created
    and ([.result.workspaces[] | select(.label == $parent)] | length) == 1
    and (
      [range(0; .result.workspaces | length) as $i
        | select(.result.workspaces[$i].label == $parent)
        | $i][0] < $desired
    )
  ' >/dev/null 2>&1; then
    echo "warning: herdr presentation workspace move returned an unverifiable order; leaving worker running without cleanup" >&2
    return 0
  fi

  before_existing=$(printf '%s' "$analysis" | jq -c '.existing' 2>/dev/null)
  after_existing=$(printf '%s' "$response" | jq -c --arg created "$created" '[.result.workspaces[] | select(.workspace_id != $created) | .workspace_id]' 2>/dev/null)
  if [ "$after_existing" != "$before_existing" ]; then
    echo "warning: herdr presentation workspace move did not preserve relative order; leaving worker running without cleanup" >&2
  fi
  return 0
}

# fm_backend_herdr_server_ensure: start the herdr server for <session>
# headless (no TUI client) if not already running, mirroring tmux's `tmux
# has-session || tmux new-session -d`. Verified: a bare socket CLI call does
# NOT auto-start the server, so this must run before any workspace/tab/pane
# call. Bounded poll for the server to report running.
fm_backend_herdr_server_ensure() {  # <session>
  local session=$1 running out i
  running=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
  [ "$running" = "true" ] && return 0
  ( fm_backend_herdr_cli "$session" server >/dev/null 2>&1 & ) || return 1
  for i in $(seq 1 20); do
    running=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
    [ "$running" = "true" ] && return 0
    sleep 0.5
  done
  echo "error: herdr server for session '$session' did not report running within 10s" >&2
  return 1
}

fm_backend_herdr_lock_discard() {
  local lock=$1 owner owner_dir owner_name
  owner_dir=$(dirname "$lock")
  if [ -L "$lock" ]; then
    owner=$(readlink "$lock" 2>/dev/null || true)
    rm -f "$lock"
    owner_name=$(basename "$owner")
    case "$owner" in "$owner_dir"/*)
      case "$owner_name" in .fm-herdr-*.owner.*) rm -f "$owner" ;; esac
      ;;
    esac
  elif [ -d "$lock" ]; then
    rm -f "$lock/pid" "$lock/pid-start"
    rmdir "$lock" 2>/dev/null || true
  else
    rm -f "$lock"
  fi
}

# fm_backend_herdr_workspace_prune_seeded_default_tab: close EXACTLY
# <seeded_tab_id>, the auto-created default tab id that THIS SAME
# fm_backend_herdr_workspace_ensure call captured straight from its own
# `workspace create` response (never re-derived from a label pattern at
# create_task time - see the incident note below). Best-effort: a failure
# here never fails the caller, mirroring the fm_backend_herdr_kill `|| true`
# contract.
#
# Live-fire incident fix (2026-07-02): the prior implementation
# (fm_backend_herdr_workspace_prune_default_tabs, removed) re-derived
# "prunable" at create_task time from a pure label heuristic - exactly one
# tab, labeled "1" - run against whatever workspace fm_backend_herdr_workspace_find
# had just resolved. Herdr enforces no label uniqueness (docs/herdr-backend.md
# "Label collisions") and derives an unlabeled workspace's DISPLAYED label from
# its pane cwd's basename, so a captain launching herdr directly inside a
# directory named "firstmate" produces a workspace that looks byte-identical,
# by label alone, to firstmate's own auto-created container - one tab, label
# "1". workspace_find adopted that pre-existing (captain-owned, LIVE) workspace
# by the label match, the heuristic matched too, and the very next spawn
# closed the captain's own live pane 27ms after creating its task tab. The
# fix is structural, not another heuristic: only a workspace THIS SAME
# fm_backend_herdr_workspace_ensure call just created carries a non-empty
# seeded_tab_id at all (see FM_BACKEND_HERDR_WS_SEEDED_TAB_ID below); an
# ADOPTED workspace's seeded_tab_id is always empty, so create_task never
# calls this function for one, regardless of how its tabs happen to be
# labeled.
#
# Defense in depth on top of that gate (not the primary safety mechanism):
# re-verify <seeded_tab_id> is still present, still carries label "1" (a
# human could have renamed or repurposed it in the interim), and refuse to
# close it if its pane hosts an actively working agent per herdr's own
# agent-state detection (`agent get`) - belt-and-suspenders against any other
# unforeseen path landing a live agent in a tab this function was about to
# close.
#
# Verified real-herdr behavior (not modeled by the canned-response fake-CLI
# unit tests; modeled by make_herdr_statefake): closing a workspace's LAST
# remaining tab deletes the whole workspace, not just the tab. So this must
# never run while the seeded default tab is still the ONLY tab in the
# workspace - callers only invoke it once at least one other (real task) tab
# exists alongside it, never right after workspace creation - and this
# function independently re-checks the tab count as a second layer.
fm_backend_herdr_workspace_prune_seeded_default_tab() {  # <session> <workspace_id> <seeded_tab_id> [focus-preserving]
  local session=$1 wsid=$2 tab_id=$3 close_mode=${4:-direct} tabs tab_count current_label pane_id agent_out agent_status
  [ -n "$tab_id" ] || return 0
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 0
  tab_count=$(printf '%s' "$tabs" | jq -r '.result.tabs? // [] | length' 2>/dev/null)
  case "$tab_count" in ''|*[!0-9]*|0|1) return 0 ;; esac
  current_label=$(printf '%s' "$tabs" | jq -r --arg t "$tab_id" '.result.tabs[]? | select(.tab_id == $t) | .label' 2>/dev/null)
  [ "$current_label" = "1" ] || return 0
  pane_id=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || return 0
  [ -n "$pane_id" ] || return 0
  agent_out=$(fm_backend_herdr_cli "$session" agent get "$pane_id" 2>/dev/null)
  agent_status=$(printf '%s' "$agent_out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  [ "$agent_status" = working ] && return 0
  if [ "$close_mode" = focus-preserving ]; then
    fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$pane_id"
  else
    fm_backend_herdr_cli "$session" pane close "$pane_id" >/dev/null 2>&1 || true
  fi
}

# fm_backend_herdr_workspace_ensure: this HOME's persistent workspace inside
# <session>, creating it in <cwd> if absent. Must be called as a PLAIN
# STATEMENT, never through command substitution ($(...)) - it communicates
# through these globals, not solely through stdout, and a command
# substitution forks a subshell that would discard them:
#   FM_BACKEND_HERDR_WS_ID          - the resolved workspace_id (also echoed,
#                                      for callers that only need the id)
#   FM_BACKEND_HERDR_WS_SEEDED_TAB_ID - non-empty ONLY when THIS call just
#                                      CREATED the workspace: the tab_id of
#                                      the auto-created default tab herdr
#                                      seeded it with, read straight from the
#                                      `workspace create` response's
#                                      `.result.tab.tab_id` (verified
#                                      empirically against the real binary -
#                                      no follow-up tab-list call needed).
#                                      Empty whenever this call instead
#                                      ADOPTED a pre-existing workspace
#                                      (fm_backend_herdr_workspace_find
#                                      matched by label - docs/herdr-backend.md
#                                      "Label collisions": that match can
#                                      never distinguish an explicitly
#                                      `--label`-created workspace from one
#                                      whose label only coincidentally
#                                      matches this home's own, e.g. a
#                                      cwd-basename-derived label). An
#                                      ADOPTED workspace's tabs are NEVER
#                                      inspected or identified as prunable by
#                                      this function, no matter what they are
#                                      labeled - see
#                                      fm_backend_herdr_workspace_prune_seeded_default_tab.
# --no-focus (docs/herdr-backend.md "Focus behavior"): verified that workspace
# create does NOT focus by default once at least one workspace already exists
# in the session, matching pre-existing (flagless) behavior; the ONE exception
# is the very first workspace ever created in a brand-new session, which
# focuses regardless of --no-focus (herdr always needs something focused to
# attach to). --no-focus is passed unconditionally anyway, for defense in
# depth and because it is a no-op in the already-safe case.
fm_backend_herdr_workspace_ensure() {  # <session> <cwd>
  local session=$1 cwd=$2 wsid out label
  FM_BACKEND_HERDR_WS_ID=""
  FM_BACKEND_HERDR_WS_SEEDED_TAB_ID=""
  wsid=$(fm_backend_herdr_workspace_find "$session")
  if [ -n "$wsid" ]; then
    FM_BACKEND_HERDR_WS_ID=$wsid
    printf '%s' "$wsid"
    return 0
  fi
  [ "$state" != live ] || return 0
  [ "$state" = no-agent ] || [ "$state" = dead ] || return 0
  fm_backend_herdr_tab_close_exact "$session" "$wsid" "$seeded"
}

fm_backend_herdr_pane_for_tab() {  # <session> <workspace> <tab>
  local session=$1 wsid=$2 tab_id=$3 panes
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e '
    (.result | type) == "object"
    and (.result.panes | type) == "array"
    and all(.result.panes[]; type == "object" and (.pane_id | type) == "string" and (.tab_id | type) == "string")
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$panes" | jq -r --arg tab "$tab_id" \
    '.result.panes[]? | select(.tab_id == $tab) | .pane_id' 2>/dev/null | head -1
}

fm_backend_herdr_tab_id_for_label() {  # <session> <workspace> <label>
  local session=$1 wsid=$2 label=$3 tabs
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -r --arg want "$label" '
    if (.result | type) != "object" or (.result.tabs | type) != "array" then
      error("invalid tab list response")
    elif any(.result.tabs[]; type != "object" or (.tab_id | type) != "string" or (.label | type) != "string") then
      error("invalid tab entry")
    else
      [.result.tabs[] | select(.label == $want) | .tab_id] as $matches
      | if ($matches | length) == 1 then $matches[0] elif ($matches | length) == 0 then empty else error("multiple matching tabs") end
    end
  ' 2>/dev/null
}

fm_backend_herdr_tab_ids_for_label() {  # <session> <workspace> <label>
  local session=$1 wsid=$2 label=$3 tabs
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e '
    (.result | type) == "object"
    and (.result.tabs | type) == "array"
    and all(.result.tabs[]; type == "object" and (.tab_id | type) == "string" and (.label | type) == "string")
  ' >/dev/null 2>&1 || return 1
  printf '%s' "$tabs" | jq -r --arg want "$label" '.result.tabs[] | select(.label == $want) | .tab_id' 2>/dev/null
}

fm_backend_herdr_tab_absent() {  # <session> <workspace> <tab>
  local session=$1 wsid=$2 tab_id=$3 tabs
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e --arg tabid "$tab_id" '
    (.result | type) == "object"
    and (.result.tabs | type) == "array"
    and all(.result.tabs[]; type == "object" and (.tab_id | type) == "string" and (.label | type) == "string")
    and all(.result.tabs[]; .tab_id != $tabid)
  ' >/dev/null 2>&1
}

fm_backend_herdr_tab_close_exact() {  # <session> <workspace> <tab>
  local session=$1 wsid=$2 tab_id=$3
  [ -n "$tab_id" ] || return 1
  fm_backend_herdr_cli "$session" tab close "$tab_id" >/dev/null 2>&1 || return 1
  fm_backend_herdr_tab_absent "$session" "$wsid" "$tab_id"
}

fm_backend_herdr_tab_close_by_label() {  # <session> <workspace> <label>
  local session=$1 wsid=$2 label=$3 tab_id
  tab_id=$(fm_backend_herdr_tab_id_for_label "$session" "$wsid" "$label") || return 1
  [ -n "$tab_id" ] || return 1
  fm_backend_herdr_cli "$session" tab close "$tab_id" >/dev/null 2>&1 || return 1
  fm_backend_herdr_tab_absent "$session" "$wsid" "$tab_id"
}

fm_backend_herdr_cleanup_created_tab() {  # <session> <workspace> <label> <tab> <existing-tabs>
  local session=$1 wsid=$2 label=$3 tab_id=$4 existing=$5 tabs candidate
  local -a new_tabs=()
  if [ -n "$tab_id" ]; then
    fm_backend_herdr_tab_close_exact "$session" "$wsid" "$tab_id"
    return $?
  fi
  tabs=$(fm_backend_herdr_tab_ids_for_label "$session" "$wsid" "$label") || return 1
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    printf '%s\n' "$existing" | grep -Fqx -- "$candidate" && continue
    new_tabs+=("$candidate")
  done <<EOF
$tabs
EOF
  case "${#new_tabs[@]}" in
    0) return 1 ;;
    1) fm_backend_herdr_tab_close_exact "$session" "$wsid" "${new_tabs[0]}" ;;
    *) return 1 ;;
  esac
}

# Classify a pane without creating a server or mutating Herdr. Error responses
# are intentionally read from stderr: Herdr reports pane_not_found and
# agent_not_found there on real installs. Unknown shapes always fail closed.
fm_backend_herdr_pane_agent_state() {  # <session> <pane> -> dead|no-agent|live|unknown
  local session=$1 pane_id=$2 out code echoed status
  out=$(fm_backend_herdr_cli "$session" pane get "$pane_id" 2>&1) || true
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
  if [ -n "$code" ]; then
    [ "$code" = pane_not_found ] && printf dead || printf unknown
    return 0
  fi
  echoed=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  [ "$echoed" = "$pane_id" ] || { printf unknown; return 0; }
  out=$(fm_backend_herdr_cli "$session" agent get "$pane_id" 2>&1) || true
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
  if [ -n "$code" ]; then
    [ "$code" = agent_not_found ] && printf no-agent || printf unknown
    return 0
  fi
  status=$(printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  case "$status" in
    working|idle|done|blocked) printf live ;;
    *) printf unknown ;;
  esac
}

fm_backend_herdr_tab_is_husk() {  # <session> <pane>
  case "$(fm_backend_herdr_pane_agent_state "$1" "$2")" in
    dead|no-agent) return 0 ;;
    *) return 1 ;;
  esac
}

fm_backend_herdr_agent_alive() {  # <target> -> alive|dead|unknown
  fm_backend_herdr_parse_target "$1" || { printf unknown; return 0; }
  case "$(fm_backend_herdr_pane_agent_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")" in
    dead|no-agent) printf dead ;;
    live) printf alive ;;
    *) printf unknown ;;
  esac
}

# fm_backend_herdr_create_task: create the task's tab (one pane) in
# <container> ("session:workspace_id"). Herdr does NOT enforce label
# uniqueness itself (verified: two tabs can share a label), so the duplicate
# check is ours, mirroring tmux's manual check.
#
# A same-labeled tab already existing no longer means an automatic refusal:
# herdr persists and restores its whole session layout (workspaces/tabs/
# panes) across a server restart, including a reboot, and a restored fm-<id>
# task tab comes back a HUSK - a dead pane, or (today, and unconditionally
# once a future `resume_agents_on_restore = false` config ships) a plain
# agent-less shell sitting in the saved cwd, never the crewmate that used to
# be there. Before this fix, every fleet respawn after such a restart needed
# the operator to manually close each husk pane first before firstmate could
# spawn into it again. fm_backend_herdr_tab_is_husk classifies the existing
# tab's pane conservatively (dead or no-agent only; anything live or
# ambiguous refuses exactly as before) and, when it is a confirmed husk,
# this function CLOSES AND REPLACES it instead of refusing.
#
# Ordering is deliberate: the REPLACEMENT tab is created FIRST, and the husk
# is closed only AFTER that succeeds - never the reverse. Closing a
# workspace's LAST remaining tab deletes the whole workspace on real herdr
# (docs/herdr-backend.md "Default workspace lifecycle"), and a session-restore husk
# can legitimately be that workspace's only tab (e.g. its own seeded default
# tab was already pruned, long before the restart, by a prior real task tab
# existing alongside it). Herdr's lack of label-uniqueness enforcement is
# exactly what makes this safe: the new and the husk tab can briefly share
# the same label with no error, so the workspace never drops to zero tabs.
# This mirrors fm_backend_herdr_workspace_prune_seeded_default_tab's own
# create-before-close safety argument.
#
# --no-focus: verified tab create never focuses by default regardless of
# sibling tabs, so this is defense in depth rather than a behavior change.
# <seeded_default_tab_id> (4th arg, may be empty) is exactly the value
# fm_backend_herdr_workspace_ensure captured as FM_BACKEND_HERDR_WS_SEEDED_TAB_ID
# for THIS SAME container - non-empty only when this spawn's own
# container_ensure call just created the workspace. Once the real task tab
# above is created, this is the ONLY input that may trigger a prune, and it is
# passed by the caller, never re-derived here from tab list contents or
# labels (the live-fire self-kill fix - see
# fm_backend_herdr_workspace_prune_seeded_default_tab for the incident and
# the safety argument). An ADOPTED workspace's caller always passes an empty
# 4th arg, so this function never even queries for a prune candidate in that
# case. Echoes "<tab_id> <pane_id>" on success.
fm_backend_herdr_create_task() {  # <container> <label> <cwd> <seeded_default_tab_id>
  local container=$1 label=$2 cwd=$3 seeded_tab_id=${4:-} session wsid list dup_tabs dup dup_pane dup_tab_ids out tab_id pane_id remaining_dup_tabs
  session=${container%%:*}
  wsid=${container#*:}
  list=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  dup_tabs=$(printf '%s' "$list" | jq -r --arg want "$label" 'if (.result.tabs | type) == "array" then .result.tabs[] | select(.label == $want) | .tab_id else error("missing result.tabs") end' 2>/dev/null) || {
    echo "error: could not parse herdr tab list output for workspace $wsid (session $session)" >&2
    return 1
  }
  dup_tab_ids=""
  if [ -n "$dup_tabs" ]; then
    while IFS= read -r dup; do
      [ -n "$dup" ] || continue
      dup_pane=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$dup")
      if [ -z "$dup_pane" ] || ! fm_backend_herdr_tab_is_husk "$session" "$dup_pane"; then
        echo "error: herdr tab '$label' already exists in workspace $wsid (session $session)" >&2
        return 1
      fi
      dup_tab_ids="${dup_tab_ids}${dup}"$'\n'
    done <<EOF
$dup_tabs
EOF
  fi
  out=$(fm_backend_herdr_cli "$session" tab create --workspace "$wsid" --cwd "$cwd" --label "$label" --no-focus 2>/dev/null) || return 1
  tab_id=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  pane_id=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$tab_id" ] || [ -z "$pane_id" ]; then
    echo "error: could not parse tab/pane id from herdr tab create output" >&2
    return 1
  fi
  [ -z "$seeded_tab_id" ] || fm_backend_herdr_workspace_prune_seeded_default_tab "$session" "$wsid" "$seeded_tab_id"
  if [ -n "$dup_tab_ids" ]; then
    while IFS= read -r dup; do
      [ -n "$dup" ] || continue
      fm_backend_herdr_cli "$session" tab close "$dup" >/dev/null 2>&1 || true
    done <<EOF
$dup_tab_ids
EOF
    list=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || {
      echo "error: could not verify herdr husk removal for tab '$label' in workspace $wsid (session $session)" >&2
      return 1
    }
    if ! printf '%s' "$list" | jq -e '(.result.tabs | type) == "array"' >/dev/null 2>&1; then
      echo "error: could not parse herdr tab list output for workspace $wsid (session $session)" >&2
      return 1
    fi
    remaining_dup_tabs=$(printf '%s' "$list" | jq -r --arg want "$label" --arg replacement "$tab_id" \
      '.result.tabs[]? | select(.label == $want and .tab_id != $replacement) | .tab_id' 2>/dev/null)
    remaining_dup_tabs=${remaining_dup_tabs//$'\n'/ }
    if [ -n "$remaining_dup_tabs" ]; then
      echo "error: failed to remove preexisting herdr tab(s) $remaining_dup_tabs for label '$label' in workspace $wsid (session $session)" >&2
      return 1
    fi
  fi
  printf '%s %s' "$tab_id" "$pane_id"
}

# fm_backend_herdr_projection_create_task: create one disposable presentation
# workspace and its normal fm-<id> task tab without looking up, adopting, or
# reusing any existing workspace.
# The caller must atomically publish the projection journal first.
# This function sets exact response-derived globals and prints nothing:
#   FM_BACKEND_HERDR_PROJECTION_SESSION
#   FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID
#   FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID
#   FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID
#   FM_BACKEND_HERDR_PROJECTION_TAB_ID
#   FM_BACKEND_HERDR_PROJECTION_PANE_ID
#   FM_BACKEND_HERDR_PROJECTION_CLEANUP_SAFE
# CLEANUP_SAFE becomes 1 only after both creates returned complete exact IDs.
# A missing, failed, or malformed create response stays ambiguous and grants no
# cleanup authority.
fm_backend_herdr_projection_create_task() {  # <cwd> <workspace-label> <task-label>
  local cwd=$1 workspace_label=$2 task_label=$3 session out tabs panes tab_count pane_count focus_before
  FM_BACKEND_HERDR_PROJECTION_SESSION=""
  FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID=""
  FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID=""
  FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID=""
  FM_BACKEND_HERDR_PROJECTION_TAB_ID=""
  FM_BACKEND_HERDR_PROJECTION_PANE_ID=""
  FM_BACKEND_HERDR_PROJECTION_CLEANUP_SAFE=0

  fm_backend_herdr_version_check || return 1
  session=$(fm_backend_herdr_session)
  fm_backend_herdr_server_ensure "$session" || return 1
  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "error: herdr presentation workspace create could not capture exact active workspace and tab; refusing a focus-unsafe projection" >&2
    return 1
  }
  if out=$(fm_backend_herdr_cli "$session" workspace create --cwd "$cwd" --label "$workspace_label" --no-focus 2>/dev/null); then
    :
  else
    fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "workspace create" || true
    echo "error: herdr presentation workspace create failed ambiguously; leaving its journal quarantined" >&2
    return 1
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "workspace create" || {
    echo "error: herdr presentation workspace create did not preserve exact active focus; leaving its journal quarantined" >&2
    return 1
  }
  # shellcheck disable=SC2034  # caller consumes the response-derived global
  FM_BACKEND_HERDR_PROJECTION_SESSION=$session
  FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
  FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" ] \
     || [ -z "$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID" ] \
     || [ -z "$FM_BACKEND_HERDR_PROJECTION_SEEDED_PANE_ID" ]; then
    echo "error: herdr presentation workspace create returned incomplete IDs; leaving its journal quarantined" >&2
    return 1
  fi

  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "error: herdr presentation task-tab create could not capture exact active workspace and tab; refusing a focus-unsafe projection" >&2
    return 1
  }
  if out=$(fm_backend_herdr_cli "$session" tab create \
    --workspace "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" \
    --cwd "$cwd" --label "$task_label" --no-focus 2>/dev/null); then
    :
  else
    fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "task-tab create" || true
    echo "error: herdr presentation task-tab create failed ambiguously; leaving its journal quarantined" >&2
    return 1
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "task-tab create" || {
    echo "error: herdr presentation task-tab create did not preserve exact active focus; leaving its journal quarantined" >&2
    return 1
  }
  FM_BACKEND_HERDR_PROJECTION_TAB_ID=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  FM_BACKEND_HERDR_PROJECTION_PANE_ID=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" ] || [ -z "$FM_BACKEND_HERDR_PROJECTION_PANE_ID" ]; then
    echo "error: herdr presentation task-tab create returned incomplete IDs; leaving its journal quarantined" >&2
    return 1
  fi
  # shellcheck disable=SC2034  # caller consumes the same-process cleanup gate
  FM_BACKEND_HERDR_PROJECTION_CLEANUP_SAFE=1
  focus_before=$(fm_backend_herdr_projection_focus_snapshot "$session") || {
    echo "error: herdr presentation seeded-tab prune could not capture exact active workspace and tab; refusing a focus-unsafe prune" >&2
    return 1
  }
  if ! fm_backend_herdr_workspace_prune_seeded_default_tab \
    "$session" \
    "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" \
    "$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID" \
    focus-preserving; then
    echo "error: herdr presentation seeded-tab prune refused a focus-unsafe close; leaving its journal quarantined" >&2
    return 1
  fi
  fm_backend_herdr_projection_focus_restore "$session" "$focus_before" "seeded-tab prune" || {
    echo "error: herdr presentation seeded-tab prune did not preserve exact active focus; leaving its journal quarantined" >&2
    return 1
  }

  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" 2>/dev/null) || {
    echo "error: could not verify the disposable herdr presentation workspace shape" >&2
    return 1
  }
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$FM_BACKEND_HERDR_PROJECTION_WORKSPACE_ID" 2>/dev/null) || {
    echo "error: could not verify the disposable herdr presentation pane shape" >&2
    return 1
  }
  if ! printf '%s' "$tabs" | jq -e '(.result.tabs | type) == "array"' >/dev/null 2>&1 \
     || ! printf '%s' "$panes" | jq -e '(.result.panes | type) == "array"' >/dev/null 2>&1; then
    echo "error: could not parse the disposable herdr presentation workspace shape" >&2
    return 1
  fi
  tab_count=$(printf '%s' "$tabs" | jq -r '.result.tabs | length' 2>/dev/null)
  pane_count=$(printf '%s' "$panes" | jq -r '.result.panes | length' 2>/dev/null)
  if [ "$tab_count" != 1 ] || [ "$pane_count" != 1 ] \
     || ! printf '%s' "$tabs" | jq -e --arg task "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" \
       --arg seeded "$FM_BACKEND_HERDR_PROJECTION_SEEDED_TAB_ID" \
       '.result.tabs[0].tab_id == $task and ([.result.tabs[] | select(.tab_id == $seeded)] | length) == 0' >/dev/null 2>&1 \
     || ! printf '%s' "$panes" | jq -e --arg pane "$FM_BACKEND_HERDR_PROJECTION_PANE_ID" \
       --arg tab "$FM_BACKEND_HERDR_PROJECTION_TAB_ID" \
       '.result.panes[0].pane_id == $pane and .result.panes[0].tab_id == $tab' >/dev/null 2>&1; then
    echo "error: disposable herdr presentation workspace did not converge to exactly one task pane" >&2
    return 1
  fi
  return 0
}

# fm_backend_herdr_projection_cleanup_exact: same-process abort cleanup for a
# projection whose create calls returned complete exact IDs.
# It performs no lookup and never calls workspace close.
fm_backend_herdr_projection_cleanup_exact() {  # <session> <task-pane> <seeded-pane>
  local session=$1 task_pane=$2 seeded_pane=$3
  [ -z "$task_pane" ] || fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$task_pane" || true
  if [ -n "$seeded_pane" ] && [ "$seeded_pane" != "$task_pane" ]; then
    fm_backend_herdr_projection_close_pane_focus_preserving "$session" "$seeded_pane" || true
  fi
}

# fm_backend_herdr_projection_recovery_allows_flat: inspect an existing
# journal's exact token matches without adopting, reusing, renaming, closing,
# or deleting anything.
# Missing matches safely degrade to the normal flat workspace.
# One or more matches allow flat fallback only when every pane is positively
# dead or agent-free; a live or unknown pane refuses a duplicate launch.
fm_backend_herdr_projection_recovery_allows_flat() {  # <session> <journal> <task-id>
  local session=$1 journal=$2 id=$3 token list wsids count wsid panes pane_ids pane state
  token=$(fm_backend_herdr_projection_journal_token "$journal" "$id") || {
    echo "error: malformed herdr presentation journal for $id; refusing duplicate launch" >&2
    return 1
  }
  fm_backend_herdr_server_ensure "$session" || {
    echo "error: could not inspect the quarantined herdr presentation for $id; refusing duplicate launch" >&2
    return 1
  }
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || {
    echo "error: could not list herdr workspaces while inspecting the quarantined presentation for $id" >&2
    return 1
  }
  if ! printf '%s' "$list" | jq -e '(.result.workspaces | type) == "array"' >/dev/null 2>&1; then
    echo "error: could not parse herdr workspaces while inspecting the quarantined presentation for $id" >&2
    return 1
  fi
  wsids=$(printf '%s' "$list" | jq -r --arg suffix " · p:$token" \
    '.result.workspaces[]? | select((.label | type) == "string" and (.label | endswith($suffix))) | .workspace_id' 2>/dev/null)
  count=$(printf '%s\n' "$wsids" | awk 'NF { n += 1 } END { print n + 0 }')
  if [ "$count" -eq 0 ]; then
    echo "warning: no exact herdr presentation token match for $id; leaving any stale space untouched and spawning flat" >&2
    return 0
  fi
  if [ "$count" -gt 1 ]; then
    echo "warning: $count exact herdr presentation token matches for $id are quarantined; inspecting only for duplicate-agent risk" >&2
  fi
  while IFS= read -r wsid; do
    [ -n "$wsid" ] || continue
    panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || {
      echo "error: could not inspect herdr presentation workspace $wsid for $id; refusing duplicate launch" >&2
      return 1
    }
    if ! printf '%s' "$panes" | jq -e '(.result.panes | type) == "array"' >/dev/null 2>&1; then
      echo "error: could not parse herdr presentation workspace $wsid for $id; refusing duplicate launch" >&2
      return 1
    fi
    pane_ids=$(printf '%s' "$panes" | jq -r '.result.panes[]? | .pane_id' 2>/dev/null)
    while IFS= read -r pane; do
      [ -n "$pane" ] || continue
      state=$(fm_backend_herdr_pane_agent_state "$session" "$pane")
      case "$state" in
        dead|no-agent) : ;;
        live|unknown)
          echo "error: quarantined herdr presentation for $id has a $state pane; refusing duplicate launch" >&2
          return 1
          ;;
      esac
    done <<EOF
$pane_ids
EOF
  done <<EOF
$wsids
EOF
  echo "warning: quarantined herdr presentation for $id is dead or agent-free; leaving it untouched and spawning flat" >&2
  return 0
}

# fm_backend_herdr_projection_endpoint_matches_journal: read-only correlation
# for retiring a successful projection journal after normal exact-pane
# teardown.
# Exactly one token-bearing workspace must match the endpoint workspace.
# This verdict never authorizes a Herdr mutation.
fm_backend_herdr_projection_endpoint_matches_journal() {  # <session> <workspace-id> <journal> <task-id>
  local session=$1 workspace_id=$2 journal=$3 id=$4 token list matches
  token=$(fm_backend_herdr_projection_journal_token "$journal" "$id") || return 1
  list=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  printf '%s' "$list" | jq -e '(.result.workspaces | type) == "array"' >/dev/null 2>&1 || return 1
  matches=$(printf '%s' "$list" | jq -r --arg suffix " · p:$token" \
    '.result.workspaces[]? | select((.label | type) == "string" and (.label | endswith($suffix))) | .workspace_id' 2>/dev/null)
  [ "$matches" = "$workspace_id" ]
}

# fm_backend_herdr_parse_target: split "<session>:<pane_id>" (pane_id itself
# contains a colon, e.g. "w1:p2") on the FIRST colon only. Sets
# FM_BACKEND_HERDR_SESSION and FM_BACKEND_HERDR_PANE for the caller.
fm_backend_herdr_parse_target() {  # <target>
  local target=$1
  FM_BACKEND_HERDR_SESSION=${target%%:*}
  FM_BACKEND_HERDR_PANE=${target#*:}
  [ -n "$FM_BACKEND_HERDR_SESSION" ] && [ -n "$FM_BACKEND_HERDR_PANE" ] \
    && [ "$FM_BACKEND_HERDR_PANE" != "$target" ]
}

fm_backend_herdr_target_ready() {
  fm_backend_herdr_parse_target "$1" || return 1
  fm_backend_herdr_version_check "$FM_BACKEND_HERDR_SESSION" || return 1
  fm_backend_herdr_server_available "$FM_BACKEND_HERDR_SESSION"
}

fm_backend_herdr_pane_readable() {
  fm_backend_herdr_target_ready "$1" || return 1
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane get "$FM_BACKEND_HERDR_PANE" >/dev/null 2>&1
}

fm_backend_herdr_current_path() {
  fm_backend_herdr_target_ready "$1" || return 0
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane get "$FM_BACKEND_HERDR_PANE" 2>/dev/null \
    | jq -r '.result.pane.foreground_cwd // empty' 2>/dev/null
}

fm_backend_herdr_send_text_line() {
  fm_backend_herdr_target_ready "$1" || return 1
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane run "$FM_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

fm_backend_herdr_send_literal() {
  fm_backend_herdr_target_ready "$1" || return 1
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane send-text "$FM_BACKEND_HERDR_PANE" "$2" >/dev/null 2>&1
}

fm_backend_herdr_normalize_key() {
  case "$1" in
    Enter|enter) printf enter ;;
    Escape|escape|Esc|esc) printf escape ;;
    C-c|c-c|ctrl+c|Ctrl+C) printf ctrl+c ;;
    *) printf '%s' "$1" ;;
  esac
}

fm_backend_herdr_send_key() {
  fm_backend_herdr_target_ready "$1" || return 1
  local key
  key=$(fm_backend_herdr_normalize_key "$2")
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane send-keys "$FM_BACKEND_HERDR_PANE" "$key" >/dev/null 2>&1
}

fm_backend_herdr_submit_enter() { fm_backend_herdr_send_key "$1" Enter; }

fm_backend_herdr_capture() {  # <target> <lines>
  fm_backend_herdr_target_ready "$1" || return 1
  local lines=${2:-40} fetch out
  case "$lines" in ''|*[!0-9]*) lines=40 ;; esac
  fetch=$lines
  [ "$fetch" -ge 200 ] 2>/dev/null || fetch=200
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane read "$FM_BACKEND_HERDR_PANE" \
    --source recent --lines "$fetch" 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

fm_backend_herdr_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 i=0 verdict baseline confirm_sleep
  fm_backend_herdr_parse_target "$target" || { printf unknown; return 0; }
  fm_backend_herdr_send_literal "$target" "$text" || { printf send-failed; return 0; }
  sleep "$settle"
  baseline=$(fm_backend_herdr_classify_submit_agent_status \
    "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")")
  confirm_sleep=$(fm_backend_herdr_submit_confirm_budget "$sleep_s")
  while :; do
    fm_backend_herdr_send_key "$target" Enter || true
    if [ "$baseline" = idle ]; then
      verdict=$(fm_backend_herdr_wait_for_working "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" \
        "$confirm_sleep" "${FM_BACKEND_HERDR_SUBMIT_POLLS:-6}")
    else
      sleep "$sleep_s"
      verdict=$(fm_backend_herdr_composer_state "$target")
    fi
    case "$verdict" in
      busy|empty) printf empty; return 0 ;;
      unknown) printf unknown; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || { printf pending; return 0; }
  done
}

fm_backend_herdr_capture_ansi() {  # <target> <lines>
  fm_backend_herdr_target_ready "$1" || return 1
  local lines=${2:-40} fetch out
  case "$lines" in ''|*[!0-9]*) lines=40 ;; esac
  fetch=$lines
  [ "$fetch" -ge 200 ] 2>/dev/null || fetch=200
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane read "$FM_BACKEND_HERDR_PANE" \
    --source recent --lines "$fetch" --format ansi 2>/dev/null) || return 1
  printf '%s' "$out" | tail -n "$lines"
}

# Shared composer classification for Herdr. Herdr has no cursor-row query, but
# its visible source is the current composer row; ANSI is retained so the shared
# ghost extractor can distinguish a suggestion from typed input. A bare shell
# prompt is deliberately unknown, never an injection-safe empty composer.
fm_backend_herdr_composer_state() {  # <target> [text] -> empty|pending|unknown
  local target=$1 line plain stripped bordered=0 out
  fm_backend_herdr_parse_target "$target" || { printf unknown; return 0; }
  fm_backend_herdr_target_ready "$target" || { printf unknown; return 0; }
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane read "$FM_BACKEND_HERDR_PANE" \
    --source visible --lines 1 --format ansi 2>/dev/null) || { printf unknown; return 0; }
  line=$(printf '%s\n' "$out" | tail -n 1)
  plain=$(printf '%s\n' "$line" | fm_composer_strip_ansi)
  plain="${plain#"${plain%%[![:space:]]*}"}"
  plain="${plain%"${plain##*[![:space:]]}"}"
  case "$plain" in
    '│'*'│'|'┃'*'┃'|'|'*'|') bordered=1 ;;
  esac
  stripped=$(printf '%s\n' "$line" | fm_composer_strip_ghost)
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  case "$stripped" in
    '│'*'│') stripped=${stripped#│}; stripped=${stripped%│} ;;
    '┃'*'┃') stripped=${stripped#┃}; stripped=${stripped%┃} ;;
    '|'*'|') stripped=${stripped#|}; stripped=${stripped%|} ;;
  esac
  stripped="${stripped#"${stripped%%[![:space:]]*}"}"
  stripped="${stripped%"${stripped##*[![:space:]]}"}"
  fm_composer_classify_content "$bordered" "$stripped" \
    "${FM_BACKEND_HERDR_IDLE_RE:-^Type a message\.\.\.$}" insensitive "$plain"
}

fm_backend_herdr_agent_status() {  # <target> -> idle|working|blocked|done|unknown
  fm_backend_herdr_target_ready "$1" || { printf 'unknown'; return 0; }
  local out status
  out=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" agent get "$FM_BACKEND_HERDR_PANE" 2>/dev/null) || { printf 'unknown'; return 0; }
  status=$(printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null)
  case "$status" in
    idle|working|blocked|done) printf '%s' "$status" ;;
    *) printf 'unknown' ;;
  esac
}

fm_backend_herdr_agent_status_raw() {  # <session> <pane> -> raw status
  local out
  out=$(fm_backend_herdr_cli "$1" agent get "$2" 2>/dev/null) || { printf ''; return 0; }
  printf '%s' "$out" | jq -r '.result.agent.agent_status // empty' 2>/dev/null
}

fm_backend_herdr_classify_agent_status() {  # <raw-agent_status> -> busy|idle|unknown
  case "$1" in
    working) printf busy ;;
    idle|done|blocked) printf idle ;;
    *) printf unknown ;;
  esac
}

fm_backend_herdr_classify_submit_agent_status() {  # <raw-agent_status> -> busy|idle|unknown
  case "$1" in
    working|blocked) printf busy ;;
    idle|done) printf idle ;;
    *) printf unknown ;;
  esac
}

fm_backend_herdr_kill() {
  local panes
  fm_backend_herdr_target_ready "$1" || return 1
  if ! fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane get "$FM_BACKEND_HERDR_PANE" >/dev/null 2>&1; then
    fm_backend_herdr_pane_absent || return 1
    return 0
  fi
  fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane close "$FM_BACKEND_HERDR_PANE" >/dev/null 2>&1 || return 1
  fm_backend_herdr_pane_absent
}

fm_backend_herdr_pane_absent() {
  local panes
  panes=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane list 2>/dev/null) || return 1
  printf '%s' "$panes" | jq -e --arg pane "$FM_BACKEND_HERDR_PANE" '
    (.result | type) == "object"
    and (.result.panes | type) == "array"
    and all(.result.panes[]; type == "object" and (.pane_id | type) == "string")
    and all(.result.panes[]; .pane_id != $pane)
  ' >/dev/null 2>&1
}

fm_backend_herdr_busy_state() {
  fm_backend_herdr_target_ready "$1" || { printf 'unknown'; return 0; }
  fm_backend_herdr_classify_agent_status \
    "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")"
}

FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=${FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP:-0.6}

fm_backend_herdr_submit_confirm_budget() {  # <caller-budget-seconds>
  awk -v budget="${1:-0}" -v minimum="$FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP" 'BEGIN {
    budget += 0
    minimum += 0
    if (budget < 0) budget = 0
    if (minimum < 0) minimum = 0
    if (minimum > budget) budget = minimum
    printf "%.4f", budget
  }' 2>/dev/null || printf '%s' "${1:-0}"
}

fm_backend_herdr_wait_for_working() {  # <session> <pane> <budget-seconds> <polls>
  local session=$1 pane_id=$2 budget=$3 polls=${4:-1} i interval raw state saw_idle=0
  case "$polls" in ''|*[!0-9]*|0) polls=1 ;; esac
  interval=$(awk -v budget="$budget" -v polls="$polls" \
    'BEGIN { divisor = polls - 1; if (divisor < 1) divisor = 1; value = budget / divisor; if (value < 0) value = 0; printf "%.4f", value }' \
    2>/dev/null)
  case "$interval" in ''|*[!0-9.]*) interval=0 ;; esac
  for ((i = 0; i < polls; i++)); do
    if [ "$polls" -eq 1 ] || [ "$i" -gt 0 ]; then
      sleep "$interval"
    fi
    raw=$(fm_backend_herdr_agent_status_raw "$session" "$pane_id")
    state=$(fm_backend_herdr_classify_submit_agent_status "$raw")
    case "$state" in
      busy) printf busy; return 0 ;;
      idle) saw_idle=1 ;;
    esac
  done
  if [ "$saw_idle" -eq 1 ]; then
    printf idle
  else
    printf unknown
  fi
}

fm_backend_herdr_list_task_ids() {  # <session:workspace>
  local container=$1 session=${1%%:*} wsid=${1#*:} tabs
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -r '.result.tabs[]?.tab_id // empty' 2>/dev/null
}

fm_backend_herdr_task_id_for_display_label() {  # <label>
  local want=$1 state record data label owner found='' count=0
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-$FM_BACKEND_HERDR_ROOT}/state}
  for record in "$state"/*.meta "$state"/*.herdr-label; do
    [ -f "$record" ] || continue
    owner=$(basename "$record")
    owner=${owner%.meta}
    owner=${owner%.herdr-label}
    data=$(fm_task_label_read_record "$record" "$owner" 2>/dev/null) || continue
    label=${data%%$'\t'*}
    [ "$label" = "$want" ] || continue
    if [ -z "$found" ]; then
      found=$owner
      count=1
    elif [ "$found" != "$owner" ]; then
      count=2
    fi
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$found"
}

fm_backend_herdr_task_id_for_exact_ids() {  # <session> <workspace> <tab> <pane>
  local session=$1 wsid=$2 tab_id=$3 pane_id=$4 state record owner found='' count=0
  local backend record_session record_workspace record_tab record_pane
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-$FM_BACKEND_HERDR_ROOT}/state}
  for record in "$state"/*.meta; do
    [ -f "$record" ] || continue
    backend=$(grep '^backend=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ "$backend" = herdr ] || continue
    record_session=$(grep '^herdr_session=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    record_workspace=$(grep '^herdr_workspace_id=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    record_tab=$(grep '^herdr_tab_id=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    record_pane=$(grep '^herdr_pane_id=' "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ "$record_session" = "$session" ] || continue
    [ "$record_workspace" = "$wsid" ] || continue
    [ "$record_tab" = "$tab_id" ] || continue
    [ "$record_pane" = "$pane_id" ] || continue
    owner=$(basename "$record" .meta)
    if [ -z "$found" ]; then
      found=$owner
      count=1
    elif [ "$found" != "$owner" ]; then
      count=2
    fi
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$found"
}

# Recovery fallback. Exact persisted session/pane ids remain the normal route.
# New labels are claimed only by an exact metadata or pre-create-journal match;
# legacy fm-<id> discovery remains supported.
fm_backend_herdr_list_live() {  # <session> [workspace]
  local session=$1 wsid=${2:-} tabs rows row tab_id label pane_id task_id reported
  [ -n "$wsid" ] || wsid=$(fm_backend_herdr_workspace_find "$session") || return 1
  [ -n "$wsid" ] || return 0
  tabs=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  printf '%s' "$tabs" | jq -e '
    (.result | type) == "object"
    and (.result.tabs | type) == "array"
    and all(.result.tabs[]; type == "object" and (.tab_id | type) == "string" and (.label | type) == "string")
  ' >/dev/null 2>&1 || return 1
  rows=$(printf '%s' "$tabs" | jq -c '
    def has_unsafe_controls:
      any(explode[];
        (. >= 0 and . <= 31)
        or . == 127
        or (. >= 8234 and . <= 8238)
        or (. >= 8294 and . <= 8297));
    .result.tabs[]
    | select(.tab_id | has_unsafe_controls | not)
    | select(.label | has_unsafe_controls | not)
    | [.tab_id, .label]
  ') || return 1
  [ -n "$rows" ] || return 0
  while IFS= read -r row; do
    tab_id=$(printf '%s' "$row" | jq -r '.[0]') || return 1
    label=$(printf '%s' "$row" | jq -r '.[1]') || return 1
    [ -n "$tab_id" ] || continue
    pane_id=$(fm_backend_herdr_pane_for_tab "$session" "$wsid" "$tab_id") || return 1
    [ -n "$pane_id" ] || return 1
    reported=$label
    if task_id=$(fm_backend_herdr_task_id_for_exact_ids "$session" "$wsid" "$tab_id" "$pane_id"); then
      reported="fm-$task_id"
    else
      case "$label" in
        fm-*) fm_task_label_task_id_is_valid "${label#fm-}" || continue ;;
        *)
          fm_task_label_validate_display_label "$label" >/dev/null 2>&1 || continue
          if task_id=$(fm_backend_herdr_task_id_for_display_label "$label"); then
            reported="fm-$task_id"
          fi
          ;;
      esac
    fi
    printf '%s:%s\t%s\t%s\n' "$session" "$pane_id" "$reported" "$label"
  done <<<"$rows"
}

# These lifecycle operations are tmux-only in the generic spawn setup. They
# remain explicit no-ops for callers that probe the shared interface.
fm_backend_herdr_set_task_option() { return 0; }
fm_backend_herdr_rename_task() { return 0; }
fm_backend_herdr_task_name() { fm_backend_herdr_parse_target "$1" && printf '%s' "$FM_BACKEND_HERDR_PANE"; }
# fm_backend_herdr_socket_path: the control-socket path for <session>, read from
# `herdr session list --json` (the default session's socket differs from a named
# session's - verified: default -> ~/.config/herdr/herdr.sock, named ->
# ~/.config/herdr/sessions/<name>/herdr.sock). Empty on any failure.
fm_backend_herdr_socket_path() {  # <session>
  local session=$1
  fm_backend_herdr_cli "$session" session list --json 2>/dev/null \
    | jq -r --arg name "$session" '.sessions[]? | select(.name == $name) | .socket_path // empty' 2>/dev/null \
    | head -1
}

# fm_backend_herdr_events_capable: the version/capability gate for the event
# fast-path (report section 5c trigger 1). Fails closed to the poll loop unless
# ALL hold: herdr+jq present; the raw-socket reader available (python3, unless a
# reader override is configured); client protocol >= FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL;
# and both `events.subscribe` and `pane.agent_status_changed` present in `herdr
# api schema`. FM_BACKEND_HERDR_EVENTS_FORCE overrides the whole verdict for
# tests (1 = capable, 0 = incapable) without touching the real binary. The
# `api schema` read is ~220KB, so callers (the watcher) memoize this per session
# for a process lifetime rather than probing every poll.
fm_backend_herdr_events_capable() {  # <session>
  local session=$1 protocol schema
  case "${FM_BACKEND_HERDR_EVENTS_FORCE:-}" in
    1) return 0 ;;
    0) return 1 ;;
  esac
  fm_backend_herdr_tool_check || return 1
  if [ -z "${FM_BACKEND_HERDR_EVENT_READER:-}" ]; then
    command -v python3 >/dev/null 2>&1 || return 1
  fi
  protocol=$(fm_backend_herdr_cli "$session" status --json 2>/dev/null | jq -r '.client.protocol // empty' 2>/dev/null)
  case "$protocol" in ''|*[!0-9]*) return 1 ;; esac
  [ "$protocol" -ge "$FM_BACKEND_HERDR_MIN_EVENTS_PROTOCOL" ] || return 1
  schema=$(fm_backend_herdr_cli "$session" api schema --json 2>/dev/null) || return 1
  printf '%s' "$schema" | grep -Fq 'events.subscribe' || return 1
  printf '%s' "$schema" | grep -Fq 'pane.agent_status_changed' || return 1
  return 0
}

# fm_backend_herdr_normalize_event: THE single normalize point (report section 5
# refinement: one backend transition shape, one parse point). Both the stream
# reader's projected lines AND the level-reconcile's `agent get` reads flow
# through here into the shared normalized-transition record. herdr's event
# carries no previous status and its stream is edge-triggered, so from_status is
# left empty; to_status drives the policy.
fm_backend_herdr_normalize_event() {  # <pane_id> <workspace_id> <agent_status> <agent>
  fm_transition_record "${1:-}" "${2:-}" "" "${3:-}" "${4:-}"
}

# fm_backend_herdr_event_reader_cmd: emit the reader argv (one word per line) for
# the raw-socket subscriber. Default: `python3 <this dir>/herdr-eventwait.py`.
# FM_BACKEND_HERDR_EVENT_READER overrides it with a whitespace-split command so
# tests can substitute a fake reader that replays canned stream lines.
fm_backend_herdr_event_reader_cmd() {
  local word
  if [ -n "${FM_BACKEND_HERDR_EVENT_READER:-}" ]; then
    for word in $FM_BACKEND_HERDR_EVENT_READER; do
      printf '%s\n' "$word"
    done
    return 0
  fi
  printf 'python3\n'
  printf '%s\n' "$FM_BACKEND_HERDR_ROOT/bin/backends/herdr-eventwait.py"
}

# fm_backend_herdr_escalation_marker: the per-pane dedupe marker path for a
# <window> ("<session>:<pane_id>"), keyed identically to the watcher's
# .stale-<key> (tr ':/.' '___'), under <state_dir>.
fm_backend_herdr_escalation_marker() {  # <state_dir> <window>
  local state=$1 window=$2 key
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s/%s%s' "$state" "$FM_BACKEND_HERDR_ESCALATED_PREFIX" "$key"
}

# fm_backend_herdr_apply_transition: route one normalized record through the
# shared policy table, maintaining the per-pane dedupe marker under <state_dir>.
# On a fresh `actionable` (blocked) edge - policy actionable AND no marker yet -
# it prints the record on stdout and returns 0 (the caller stops and hands the
# record up). The caller commits the marker only after handling the record.
# `absorb` (working) clears the marker and
# returns 1. `defer`/`fallback`, and an already-marked `actionable`, return 1
# with no output. <session> reconstructs the window ("<session>:<pane_id>") for
# the marker key, matching the watcher's own key scheme.
fm_backend_herdr_apply_transition() {  # <state_dir> <session> <record>
  local state=$1 session=$2 record=$3 pane_id to action window marker
  pane_id=$(fm_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  to=$(fm_transition_to_status "$record")
  action=$(fm_transition_policy "$to")
  window="$session:$pane_id"
  marker=$(fm_backend_herdr_escalation_marker "$state" "$window")
  case "$action" in
    actionable)
      if [ ! -e "$marker" ]; then
        printf '%s' "$record"
        return 0
      fi
      ;;
    absorb)
      rm -f "$marker" 2>/dev/null || true
      ;;
  esac
  return 1
}

fm_backend_herdr_commit_transition() {  # <state_dir> <session> <record>
  local state=$1 session=$2 record=$3 pane_id window marker
  pane_id=$(fm_transition_pane_id "$record")
  [ -n "$pane_id" ] || return 1
  window="$session:$pane_id"
  marker=$(fm_backend_herdr_escalation_marker "$state" "$window")
  : > "$marker"
}

fm_backend_herdr_clear_transition() {  # <state_dir> <window>
  local state=$1 window=$2 marker
  [ -n "$window" ] || return 0
  marker=$(fm_backend_herdr_escalation_marker "$state" "$window")
  rm -f "$marker" 2>/dev/null || true
}

# fm_backend_herdr_wait_transition: the bounded event wait. Blocks up to
# <timeout_secs> for one of <pane_window...> ("<session>:<pane_id>") to reach a
# fresh `blocked` edge, then prints the normalized record and returns 0.
# Returns 1 on a clean timeout (the reader ran the full budget, no fresh
# actionable edge - the caller has effectively already slept and just continues)
# and 2 when the event path is unusable (not capable, socket unresolved, reader
# failed to run/subscribe - the caller sleeps the budget itself, the fail-closed
# backstop). See the header block above for the full contract.
fm_backend_herdr_wait_transition() {  # <session> <timeout_secs> <state_dir> <pane_window...>
  local session=$1 timeout=$2 state=$3
  shift 3
  local windows=("$@")
  [ "${#windows[@]}" -gt 0 ] || return 2
  if [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" != 1 ]; then
    fm_backend_herdr_events_capable "$session" || return 2
  fi
  local sock
  sock=$(fm_backend_herdr_socket_path "$session")
  [ -n "$sock" ] || return 2

  # Map each window to its herdr pane id (strip the leading "<session>:").
  local w pane_id
  local pane_ids=()
  for w in "${windows[@]}"; do
    pane_id=${w#*:}
    if [ -z "$pane_id" ] || [ "$pane_id" = "$w" ]; then
      continue
    fi
    pane_ids+=("$pane_id")
  done
  [ "${#pane_ids[@]}" -gt 0 ] || return 2

  # Start the raw-socket reader and wait for its subscription acknowledgement
  # before level reconciliation, so edges occurring during reconciliation are
  # already buffered in the live stream.
  local reader=()
  while IFS= read -r w; do
    reader+=("$w")
  done < <(fm_backend_herdr_event_reader_cmd)
  [ "${#reader[@]}" -gt 0 ] || return 2

  local fifo_dir fifo reader_pid line ws status agent raw record hit rc=1 reader_rc=0
  fifo_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-eventwait.XXXXXX") || return 2
  fifo="$fifo_dir/events"
  if ! mkfifo "$fifo" 2>/dev/null; then
    rm -rf "$fifo_dir" 2>/dev/null || true
    return 2
  fi
  "${reader[@]}" "$sock" "$timeout" "${pane_ids[@]}" > "$fifo" 2>/dev/null &
  reader_pid=$!
  if ! exec 9< "$fifo"; then
    kill "$reader_pid" 2>/dev/null || true
    wait "$reader_pid" 2>/dev/null || true
    rm -rf "$fifo_dir" 2>/dev/null || true
    return 2
  fi
  if ! IFS= read -r -u 9 line || [ "$line" != "@subscribed" ]; then
    rc=2
  fi

  # Level reconcile on (re)connect (report section 3d): a pane already `blocked`
  # during the gap since the last subscription is returned now, once, while
  # newer edges accumulate in the active stream. `working` panes clear their
  # marker here too.
  if [ "$rc" -ne 2 ]; then
    for w in "${windows[@]}"; do
      pane_id=${w#*:}
      if [ -z "$pane_id" ] || [ "$pane_id" = "$w" ]; then
        continue
      fi
      raw=$(fm_backend_herdr_agent_status_raw "$session" "$pane_id")
      [ -n "$raw" ] || continue
      record=$(fm_backend_herdr_normalize_event "$pane_id" "" "$raw" "")
      if hit=$(fm_backend_herdr_apply_transition "$state" "$session" "$record"); then
        printf '%s' "$hit"
        rc=0
        break
      fi
    done
  fi

  # Drain stream edges until a fresh blocked edge or the timeout. The reader is
  # a subprocess of this call (NOT a second watcher), and is killed the instant
  # a blocked edge is found.
  # Split each raw projected line (pane_id\tworkspace_id\tagent_status\tagent)
  # with `cut`, NOT `IFS=$'\t' read`: a tab is IFS-whitespace, so `read` would
  # collapse an empty middle field (e.g. an absent workspace_id) and shift the
  # status into the wrong column. `cut` preserves empty fields.
  while [ "$rc" -eq 1 ] && IFS= read -r line <&9; do
    [ -n "$line" ] || continue
    pane_id=$(printf '%s' "$line" | cut -f1)
    ws=$(printf '%s' "$line" | cut -f2)
    status=$(printf '%s' "$line" | cut -f3)
    agent=$(printf '%s' "$line" | cut -f4)
    [ -n "$pane_id" ] || continue
    record=$(fm_backend_herdr_normalize_event "$pane_id" "$ws" "$status" "$agent")
    if hit=$(fm_backend_herdr_apply_transition "$state" "$session" "$record"); then
      printf '%s' "$hit"
      rc=0
      break
    fi
  done
  if [ "$rc" -eq 0 ]; then
    kill "$reader_pid" 2>/dev/null || true
  fi
  if [ "$rc" -eq 2 ]; then
    kill "$reader_pid" 2>/dev/null || true
  fi
  # No actionable edge: distinguish a clean full-budget wait (reader exit 0 ->
  # return 1, caller already waited) from a reader error (connect/subscribe
  # failure, exit non-zero -> return 2, caller sleeps and counts toward the
  # runtime-disable threshold).
  wait "$reader_pid" 2>/dev/null || reader_rc=$?
  exec 9<&-
  rm -rf "$fifo_dir" 2>/dev/null || true
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 2 ] && return 2
  [ "$reader_rc" -eq 0 ] && return 1
  return 2
}
