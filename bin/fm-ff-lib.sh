# shellcheck shell=bash
# Shared fast-forward machinery for firstmate self-sync.
# Usage: . bin/fm-ff-lib.sh   (after FM_ROOT and FM_HOME are set)
#
# This is the one implementation of "advance a firstmate checkout to a base by a
# clean fast-forward, never forcing, merging, or stashing" used by every sync
# path:
#   - /updatefirstmate (bin/fm-update.sh) pulls from origin: base_mode "origin".
#   - the local-HEAD secondmate sync (bin/fm-spawn.sh on launch, bin/fm-bootstrap.sh
#     on startup) follows the PRIMARY checkout's current default-branch commit:
#     base_mode is that local commit, with NO fetch and no origin dependency.
#
# Every secondmate home is a worktree of this same repo, so it already holds the
# primary's commit in the shared object store; the local-HEAD sync is therefore a
# purely local fast-forward that never touches the network. A tracked-files
# fast-forward never touches the gitignored operational dirs (data/, state/,
# config/, projects/, .no-mistakes/), so a secondmate's backlog, projects, and
# in-flight work are never disturbed. Homes are leased at a detached HEAD on the
# default branch, so the fast-forward advances HEAD only and never moves the
# shared default branch or any other worktree's checkout.

SUB_HOME_MARKER="${SUB_HOME_MARKER:-.fm-secondmate-home}"

# --- helpers ---------------------------------------------------------------

first_line() {
  printf '%s\n' "$1" | sed -n '1s/[[:space:]]\{1,\}/ /g;1p'
}

fm_update_obligation_records_dir() {
  printf '%s.generations' "$1"
}

fm_update_obligation_valid_generation() {
  [ "${#1}" -eq 40 ] || return 1
  case "$1" in
    *[!0-9a-f]*) return 1 ;;
  esac
}

fm_update_obligation_write() {
  local marker=$1 generation=$2 records tmp record
  fm_update_obligation_valid_generation "$generation" || return 1
  records=$(fm_update_obligation_records_dir "$marker")
  record="$records/$generation"
  mkdir -p "$records" || return 1
  [ -f "$record" ] && return 0
  tmp=$(mktemp "$records/.update-obligation.XXXXXX") || return 1
  printf 'generation=%s\n' "$generation" > "$tmp" \
    && chmod 600 "$tmp" 2>/dev/null \
    && { ln "$tmp" "$record" 2>/dev/null || [ -f "$record" ]; } || {
      rm -f "$tmp" 2>/dev/null || true
      return 1
    }
  rm -f "$tmp"
}

fm_update_obligation_generation() {
  local marker=$1 dir=$2 records head record generation selected=""
  records=$(fm_update_obligation_records_dir "$marker")
  head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)
  [ -n "$head" ] || return 1
  [ -d "$records" ] || return 1
  for record in "$records"/*; do
    [ -f "$record" ] || continue
    generation=${record##*/}
    fm_update_obligation_valid_generation "$generation" || continue
    git -C "$dir" merge-base --is-ancestor "$generation" "$head" 2>/dev/null || continue
    if [ -z "$selected" ] \
      || git -C "$dir" merge-base --is-ancestor "$selected" "$generation" 2>/dev/null; then
      selected=$generation
    fi
  done
  [ -n "$selected" ] || return 1
  printf '%s\n' "$selected"
}

fm_update_obligation_load() {
  local marker=$1 dir=$2 head generation value records record candidate
  FF_OBLIGATION_GENERATION=""
  if [ -f "$marker" ]; then
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)
    [ -n "$head" ] || return 1
    value=$(sed -n 's/^generation=//p' "$marker" 2>/dev/null || true)
    if fm_update_obligation_valid_generation "$value" \
      && git -C "$dir" cat-file -e "$value^{commit}" 2>/dev/null; then
      generation=$value
    else
      generation=$head
    fi
    fm_update_obligation_write "$marker" "$generation" || return 1
    rm -f "$marker" || return 1
  fi
  if generation=$(fm_update_obligation_generation "$marker" "$dir"); then
    FF_OBLIGATION_GENERATION=$generation
    return 0
  fi
  records=$(fm_update_obligation_records_dir "$marker")
  for record in "$records"/*; do
    [ -f "$record" ] || continue
    candidate=${record##*/}
    fm_update_obligation_valid_generation "$candidate" || continue
    git -C "$dir" cat-file -e "$candidate^{commit}" 2>/dev/null && return 0
  done
  return 1
}

fm_update_obligation_pending() {
  local marker=$1 dir=$2
  [ -f "$marker" ] && return 0
  fm_update_obligation_generation "$marker" "$dir" >/dev/null
}

fm_update_obligation_ack() {
  local marker=$1 generation=$2 dir=$3 records record candidate selected
  fm_update_obligation_valid_generation "$generation" || return 1
  if [ -f "$marker" ]; then
    fm_update_obligation_load "$marker" "$dir" || return 1
  fi
  selected=$(fm_update_obligation_generation "$marker" "$dir") || return 1
  [ "$selected" = "$generation" ] || return 1
  records=$(fm_update_obligation_records_dir "$marker")
  record="$records/$generation"
  [ -f "$record" ] || return 1
  for record in "$records"/*; do
    [ -f "$record" ] || continue
    candidate=${record##*/}
    fm_update_obligation_valid_generation "$candidate" || continue
    [ "$candidate" = "$generation" ] && continue
    if git -C "$dir" merge-base --is-ancestor "$candidate" "$generation" 2>/dev/null; then
      rm -f "$record" || return 1
    fi
  done
  rm -f "$records/$generation"
}

default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the PRIMARY checkout's current default-branch commit - the local-HEAD
# sync target every secondmate follows. Reads the default branch *ref* rather than
# HEAD, so even a primary stranded on a feature branch (the worktree tangle of
# section 8) still yields the true default-branch tip instead of propagating a
# stray feature branch to the fleet. Echoes the commit SHA, or returns 1.
primary_head_commit() {
  local root=$1 default
  default=$(default_branch "$root") || return 1
  git -C "$root" rev-parse --verify --quiet "refs/heads/$default^{commit}" 2>/dev/null || return 1
}

resolve_path() {
  # Resolve to a canonical absolute path, falling back to the literal input
  # when the directory does not exist (so callers can still dedup/skip on it).
  ( cd "$1" 2>/dev/null && pwd -P ) || printf '%s\n' "$1"
}

resolved_existing_dir() {
  local path=$1
  [ -d "$path" ] || return 1
  cd "$path" && pwd -P
}

path_is_ancestor_of() {
  local ancestor=$1 path=$2
  [ -n "$ancestor" ] || return 1
  [ -n "$path" ] || return 1
  [ "$ancestor" != "$path" ] || return 1
  case "$path" in
    "$ancestor"/*) return 0 ;;
  esac
  return 1
}

VALIDATED_HOME=""
VALIDATION_ERROR=""

validate_operational_dirs() {
  local abs_home=$1 abs_active_home=$2 abs_root=$3 name dir abs_dir
  for name in data state config projects; do
    dir="$abs_home/$name"
    if [ -L "$dir" ] && [ ! -e "$dir" ]; then
      VALIDATION_ERROR="secondmate $name directory must resolve inside the secondmate home"
      return 1
    fi
    if [ -d "$dir" ]; then
      abs_dir=$(cd "$dir" && pwd -P) || {
        VALIDATION_ERROR="secondmate $name directory cannot be resolved"
        return 1
      }
    elif [ -e "$dir" ]; then
      VALIDATION_ERROR="secondmate $name path is not a directory"
      return 1
    else
      abs_dir="$abs_home/$name"
    fi
    if ! path_is_ancestor_of "$abs_home" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory must resolve inside the secondmate home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_active_home" ] || path_is_ancestor_of "$abs_active_home" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory cannot be inside the active firstmate home"
      return 1
    fi
    if [ "$abs_dir" = "$abs_root" ] || path_is_ancestor_of "$abs_root" "$abs_dir"; then
      VALIDATION_ERROR="secondmate $name directory cannot be inside the firstmate repo"
      return 1
    fi
  done
}

validate_secondmate_home() {
  local id=$1 home=$2 abs_home abs_active_home abs_root marker_id
  VALIDATED_HOME=""
  VALIDATION_ERROR=""
  abs_home=$(resolved_existing_dir "$home") || {
    VALIDATION_ERROR="not a directory"
    return 1
  }
  abs_active_home=$(resolved_existing_dir "$FM_HOME") || {
    VALIDATION_ERROR="active firstmate home is not a directory"
    return 1
  }
  abs_root=$(resolved_existing_dir "$FM_ROOT") || {
    VALIDATION_ERROR="firstmate repo is not a directory"
    return 1
  }
  if [ "$abs_home" = "/" ]; then
    VALIDATION_ERROR="secondmate home cannot be the filesystem root"
    return 1
  fi
  if [ "$abs_home" = "$abs_active_home" ]; then
    VALIDATION_ERROR="secondmate home cannot be the active firstmate home"
    return 1
  fi
  if [ "$abs_home" = "$abs_root" ]; then
    VALIDATION_ERROR="secondmate home cannot be the firstmate repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_active_home" "$abs_home"; then
    VALIDATION_ERROR="secondmate home cannot be inside the active firstmate home"
    return 1
  fi
  if path_is_ancestor_of "$abs_root" "$abs_home"; then
    VALIDATION_ERROR="secondmate home cannot be inside the firstmate repo"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_active_home"; then
    VALIDATION_ERROR="secondmate home cannot be an ancestor of the active firstmate home"
    return 1
  fi
  if path_is_ancestor_of "$abs_home" "$abs_root"; then
    VALIDATION_ERROR="secondmate home cannot be an ancestor of the firstmate repo"
    return 1
  fi
  validate_operational_dirs "$abs_home" "$abs_active_home" "$abs_root" || return 1
  if [ -L "$abs_home/$SUB_HOME_MARKER" ]; then
    VALIDATION_ERROR="secondmate marker must not be a symlink"
    return 1
  fi
  if [ ! -f "$abs_home/$SUB_HOME_MARKER" ]; then
    VALIDATION_ERROR="not a seeded secondmate home"
    return 1
  fi
  marker_id=$(cat "$abs_home/$SUB_HOME_MARKER" 2>/dev/null || true)
  if [ "$marker_id" != "$id" ]; then
    VALIDATION_ERROR="marked for secondmate ${marker_id:-unknown}, expected $id"
    return 1
  fi
  if [ ! -f "$abs_home/AGENTS.md" ]; then
    VALIDATION_ERROR="not a firstmate home (missing AGENTS.md)"
    return 1
  fi
  if [ ! -d "$abs_home/bin" ]; then
    VALIDATION_ERROR="not a firstmate home (missing bin/)"
    return 1
  fi
  VALIDATED_HOME="$abs_home"
}

# A single fetch refreshes every worktree that shares an object store, so fetch
# each distinct git-common-dir at most once. Used ONLY by the origin base mode;
# the local-HEAD sync never fetches.
FETCHED=""
fetch_once() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -n "$common" ]; then
    case " $FETCHED " in
      *" $common "*) return 0 ;;
    esac
  fi
  if git -C "$dir" fetch origin --prune --quiet 2>/dev/null; then
    [ -n "$common" ] && FETCHED="$FETCHED $common"
    return 0
  fi
  return 1
}

# Which watched instruction paths changed between HEAD and BASE (comma list).
# These are the files a running agent actually reads or runs: its instructions
# (AGENTS.md, which CLAUDE.md symlinks), its skills, and its tooling (bin/).
changed_instr() {
  local dir=$1 base=$2 p out=""
  for p in AGENTS.md bin .agents/skills; do
    if ! git -C "$dir" diff --quiet HEAD "$base" -- "$p" 2>/dev/null; then
      out="$out${out:+, }$p"
    fi
  done
  printf '%s' "$out"
}

dirty_status() {
  local dir=$1 ignore_seed_marker=${2:-no}
  if [ "$ignore_seed_marker" = yes ]; then
    git -C "$dir" status --porcelain 2>/dev/null | awk -v marker="?? $SUB_HOME_MARKER" '$0 != marker { print; exit }'
  else
    git -C "$dir" status --porcelain 2>/dev/null | head -1
  fi
}

secondmate_registry_field() {
  local reg=$1 id=$2 key=$3 line value
  [ -f "$reg" ] || return 1
  line=$(grep -E "^- $id( |$)" "$reg" | tail -1 || true)
  [ -n "$line" ] || return 1
  case "$key" in
    home) value=$(printf '%s\n' "$line" | sed -n 's/.*(home:[[:space:]]*\([^;)]*\);.*/\1/p' | sed 's/[[:space:]]*$//') ;;
    projects) value=$(printf '%s\n' "$line" | sed -n 's/.*; projects:[[:space:]]*\([^;)]*\); added .*/\1/p' | sed 's/[[:space:]]*$//') ;;
    *) return 1 ;;
  esac
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# List this home's LIVE secondmate direct reports from state/<id>.meta records.
# The meta file is the liveness signal and must carry one complete lifecycle
# identity before a live home can be mutated.
FM_SECONDMATE_META_HOME=
FM_SECONDMATE_META_WINDOW=
FM_SECONDMATE_META_ENDPOINT_GENERATION=
FM_SECONDMATE_META_HARNESS=
FM_SECONDMATE_META_BACKEND=
FM_SECONDMATE_META_TARGET=
FM_SECONDMATE_META_PROVIDER_IDENTITY=
FM_SECONDMATE_META_ERROR=

fm_secondmate_lifecycle_meta_read() {
  local meta=$1 expected_id=$2 line key value
  local kind_count=0 home_count=0 task_count=0 window_count=0 generation_count=0
  local harness_count=0 backend_count=0 session_count=0 workspace_count=0
  local tab_count=0 pane_count=0
  local kind= home= task= window= generation= harness= backend=
  local session= workspace= tab= pane= target= provider_identity=
  FM_SECONDMATE_META_HOME=
  FM_SECONDMATE_META_WINDOW=
  FM_SECONDMATE_META_ENDPOINT_GENERATION=
  FM_SECONDMATE_META_HARNESS=
  FM_SECONDMATE_META_BACKEND=
  FM_SECONDMATE_META_TARGET=
  FM_SECONDMATE_META_PROVIDER_IDENTITY=
  FM_SECONDMATE_META_ERROR=
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    FM_SECONDMATE_META_ERROR="metadata is missing, unreadable, or not a regular file"
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) continue ;;
    esac
    case "$key" in
      kind) kind_count=$((kind_count + 1)); kind=$value ;;
      home) home_count=$((home_count + 1)); home=$value ;;
      task) task_count=$((task_count + 1)); task=$value ;;
      window) window_count=$((window_count + 1)); window=$value ;;
      harness) harness_count=$((harness_count + 1)); harness=$value ;;
      backend) backend_count=$((backend_count + 1)); backend=$value ;;
      herdr_session) session_count=$((session_count + 1)); session=$value ;;
      herdr_workspace_id) workspace_count=$((workspace_count + 1)); workspace=$value ;;
      herdr_tab_id) tab_count=$((tab_count + 1)); tab=$value ;;
      herdr_pane_id) pane_count=$((pane_count + 1)); pane=$value ;;
      endpoint_generation)
        generation_count=$((generation_count + 1))
        generation=$value
        ;;
      generation)
        FM_SECONDMATE_META_ERROR="ambiguous lifecycle generation field"
        return 1
        ;;
    esac
  done < "$meta" || {
    FM_SECONDMATE_META_ERROR="metadata could not be read completely"
    return 1
  }
  if [ "$kind_count" -ne 1 ] || [ "$home_count" -ne 1 ] \
    || [ "$task_count" -ne 1 ] || [ "$window_count" -ne 1 ] \
    || [ "$generation_count" -ne 1 ] || [ "$harness_count" -ne 1 ] \
    || [ "$backend_count" -gt 1 ]; then
    FM_SECONDMATE_META_ERROR="ambiguous lifecycle metadata"
    return 1
  fi
  [ "$kind" = secondmate ] && [ "$task" = "$expected_id" ] \
    && [ -n "$home" ] && [ -n "$window" ] && [ -n "$generation" ] \
    && [ -n "$harness" ] || {
      FM_SECONDMATE_META_ERROR="incomplete or mismatched lifecycle metadata"
      return 1
    }
  case "$home" in
    *'|'*) FM_SECONDMATE_META_ERROR="unsafe lifecycle metadata"; return 1 ;;
  esac
  case "$window" in
    *'|'*) FM_SECONDMATE_META_ERROR="unsafe lifecycle metadata"; return 1 ;;
  esac
  case "$generation" in
    *[!A-Za-z0-9._-]*|""|*/*)
      FM_SECONDMATE_META_ERROR="unsafe endpoint generation"
      return 1
      ;;
  esac
  case "$harness" in
    claude|codex|opencode|pi|grok) ;;
    *) FM_SECONDMATE_META_ERROR="unverified lifecycle harness"; return 1 ;;
  esac
  backend=${backend:-tmux}
  case "$backend" in
    tmux)
      if [ "$session_count" -ne 0 ] || [ "$workspace_count" -ne 0 ] \
        || [ "$tab_count" -ne 0 ] || [ "$pane_count" -ne 0 ]; then
        FM_SECONDMATE_META_ERROR="provider fields do not match lifecycle backend"
        return 1
      fi
      target=$window
      provider_identity="tmux:$window"
      ;;
    herdr)
      if [ "$session_count" -ne 1 ] || [ "$workspace_count" -ne 1 ] \
        || [ "$tab_count" -ne 1 ] || [ "$pane_count" -ne 1 ] \
        || [ -z "$session" ] || [ -z "$workspace" ] \
        || [ -z "$tab" ] || [ -z "$pane" ]; then
        FM_SECONDMATE_META_ERROR="incomplete or ambiguous Herdr endpoint"
        return 1
      fi
      case "$session$workspace$tab$pane" in
        *'|'*|*:* ) FM_SECONDMATE_META_ERROR="unsafe provider endpoint"; return 1 ;;
      esac
      target="$session:$pane"
      if [ "$window" != "$target" ]; then
        FM_SECONDMATE_META_ERROR="conflicting Herdr endpoint representations"
        return 1
      fi
      provider_identity="herdr:$session:$workspace:$tab:$pane"
      ;;
    *)
      FM_SECONDMATE_META_ERROR="unknown lifecycle backend"
      return 1
      ;;
  esac
  FM_SECONDMATE_META_HOME=$home
  FM_SECONDMATE_META_WINDOW=$window
  FM_SECONDMATE_META_ENDPOINT_GENERATION=$generation
  FM_SECONDMATE_META_HARNESS=$harness
  FM_SECONDMATE_META_BACKEND=$backend
  FM_SECONDMATE_META_TARGET=$target
  FM_SECONDMATE_META_PROVIDER_IDENTITY=$provider_identity
}

fm_secondmate_lifecycle_identity_matches() {
  local state=$1 id=$2 expected_home=$3 expected_window=$4 expected_generation=$5
  local expected_provider=${6:-}
  fm_secondmate_lifecycle_meta_read "$state/$id.meta" "$id" || return 1
  [ "$FM_SECONDMATE_META_WINDOW" = "$expected_window" ] \
    && [ "$FM_SECONDMATE_META_ENDPOINT_GENERATION" = "$expected_generation" ] \
    || return 1
  [ -z "$expected_provider" ] \
    || [ "$FM_SECONDMATE_META_PROVIDER_IDENTITY" = "$expected_provider" ] \
    || return 1
  validate_secondmate_home "$id" "$FM_SECONDMATE_META_HOME" || return 1
  [ "$VALIDATED_HOME" = "$expected_home" ]
}

live_secondmate_meta_records() {
  local state=$1 _registry=${2:-} meta id
  [ -d "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
    id=$(basename "$meta" .meta)
    if ! fm_secondmate_lifecycle_meta_read "$meta" "$id"; then
      echo "secondmate $id: refused: ${FM_SECONDMATE_META_ERROR:-ambiguous lifecycle metadata}" >&2
      continue
    fi
    printf '%s|%s|%s|%s|%s|%s\n' "$id" "$FM_SECONDMATE_META_HOME" \
      "$FM_SECONDMATE_META_WINDOW" "$meta" "$FM_SECONDMATE_META_ENDPOINT_GENERATION" \
      "$FM_SECONDMATE_META_PROVIDER_IDENTITY"
  done
}

# Fast-forward one target to a base. Prints its status line. Sets globals for the
# caller:
#   FF_STATUS = updated|current|skipped
#   FF_INSTR  = comma list of changed instruction paths (only when updated)
#
# base_mode selects where the fast-forward base comes from:
#   origin       - fetch origin and advance to origin/<default> (the /updatefirstmate
#                  path); requires an origin remote and network reachability.
#   <commit-ish> - advance to that LOCAL commit with NO fetch and no origin
#                  dependency (the local-HEAD secondmate sync). The commit must
#                  already exist in the target's object store, which it always does
#                  for a worktree of this same repo; a standalone clone that lacks
#                  it is skipped rather than fetched.
# Guards are identical in both modes: ff-only (never force/merge/stash); skip a
# dirty, diverged, or wrong-branch target and leave its work untouched.
FF_STATUS=""
FF_INSTR=""
ff_target() {
  local dir=$1 label=$2 base_mode=$3 allow_detached=${4:-no} ignore_seed_marker=${5:-no}
  local obligation_marker=${6:-} obligation_mode=${7:-always}
  FF_STATUS="skipped"
  FF_INSTR=""
  FF_OBLIGATION_GENERATION=""

  if [ ! -d "$dir" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$label: skipped: not a git repo"
    return 0
  fi
  if [ -n "$obligation_marker" ] && fm_update_obligation_pending "$obligation_marker" "$dir"; then
    fm_update_obligation_load "$obligation_marker" "$dir" || {
      echo "$label: skipped: update obligation is invalid"
      return 0
    }
  fi

  local default base cur instr local_rev base_rev before after out
  default=$(default_branch "$dir") || {
    echo "$label: skipped: cannot determine default branch"
    return 0
  }

  # Resolve the fast-forward base from base_mode (see header).
  if [ "$base_mode" = origin ]; then
    if ! git -C "$dir" remote get-url origin >/dev/null 2>&1; then
      echo "$label: skipped: no origin remote"
      return 0
    fi
    if ! fetch_once "$dir"; then
      echo "$label: skipped: fetch failed"
      return 0
    fi
    base="origin/$default"
  else
    base="$base_mode"
  fi

  if ! git -C "$dir" rev-parse --verify --quiet "$base^{commit}" >/dev/null; then
    echo "$label: skipped: $base does not exist"
    return 0
  fi

  cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ -z "$cur" ] && [ "$allow_detached" != yes ]; then
    echo "$label: skipped: detached HEAD, expected $default"
    return 0
  fi
  if [ -n "$cur" ] && [ "$cur" != "$default" ]; then
    echo "$label: skipped: on $cur, expected $default"
    return 0
  fi

  if [ -n "$(dirty_status "$dir" "$ignore_seed_marker")" ]; then
    echo "$label: skipped: dirty working tree"
    return 0
  fi

  local_rev=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || {
    echo "$label: skipped: cannot read HEAD"
    return 0
  }
  base_rev=$(git -C "$dir" rev-parse "$base" 2>/dev/null) || {
    echo "$label: skipped: cannot read $base"
    return 0
  }
  if [ "$local_rev" = "$base_rev" ]; then
    FF_STATUS="current"
    echo "$label: already current"
    return 0
  fi
  if ! git -C "$dir" merge-base --is-ancestor HEAD "$base" 2>/dev/null; then
    echo "$label: skipped: diverged from $base"
    return 0
  fi

  instr=$(changed_instr "$dir" "$base")
  if [ -n "$obligation_marker" ] \
    && { [ "$obligation_mode" = always ] || [ -n "$instr" ]; }; then
    if ! fm_update_obligation_write "$obligation_marker" "$base_rev"; then
      echo "$label: skipped: update obligation could not be persisted"
      return 0
    fi
    FF_OBLIGATION_GENERATION=$base_rev
  fi
  before=$(git -C "$dir" rev-parse --short HEAD)
  if ! out=$(git -C "$dir" merge --ff-only "$base" 2>&1); then
    if [ -n "$obligation_marker" ]; then
      fm_update_obligation_load "$obligation_marker" "$dir" 2>/dev/null || \
        FF_OBLIGATION_GENERATION=""
    fi
    echo "$label: skipped: fast-forward failed: $(first_line "$out")"
    return 0
  fi
  after=$(git -C "$dir" rev-parse --short HEAD)
  if [ -n "$obligation_marker" ] \
    && fm_update_obligation_pending "$obligation_marker" "$dir"; then
    fm_update_obligation_load "$obligation_marker" "$dir" || {
      echo "$label: skipped: update obligation is invalid"
      return 0
    }
  fi
  FF_STATUS="updated"
  FF_INSTR="$instr"
  if [ -n "$instr" ]; then
    echo "$label: updated $before..$after (instructions changed: $instr)"
  else
    echo "$label: updated $before..$after"
  fi
  return 0
}

# Sweep accumulators. The caller resets them before a sweep and reads
# FF_NUDGE_WINDOWS after.
FF_NUDGE_WINDOWS=""
FF_NUDGE_GENERATIONS=""
FF_SEEN_HOMES=""

fm_ff_locked_secondmate_action() {
  local id=$1 home=$2 label=$3 callback=$4 expected rc=0
  shift 4
  if [ "$(type -t fm_ff_target_lock_acquire 2>/dev/null || true)" != function ] \
    || [ "$(type -t fm_ff_target_lock_release 2>/dev/null || true)" != function ]; then
    return 1
  fi
  validate_secondmate_home "$id" "$home" || return 1
  expected="$VALIDATED_HOME"
  fm_ff_target_lock_acquire "$expected/state" "$label" "$expected" || return 1
  if ! validate_secondmate_home "$id" "$expected" \
    || [ "$VALIDATED_HOME" != "$expected" ]; then
    fm_ff_target_lock_release
    return 1
  fi
  "$callback" "$id" "$expected" "$@" || rc=$?
  fm_ff_target_lock_release
  return "$rc"
}

# Validate and fast-forward one secondmate home, accumulating its window into
# FF_NUDGE_WINDOWS when it should be live-converged. Args:
#   id home window base_mode nudge_requires_instr
# A home is nudged when it advanced or carries a durable reread obligation and
# has a live window. With nudge_requires_instr=yes a new advance must have
# changed the instruction surface, while an already-current interrupted update
# replays its obligation. The firstmate repo itself (FM_ROOT) is never processed
# as its own secondmate, and each resolved home is processed at most once.
process_secondmate() {
  local id=$1 home=$2 window=${3:-} base_mode=$4 nudge_requires_instr=${5:-no}
  local endpoint_generation=${6:-} lifecycle_state=${7:-${STATE:-}}
  local provider_identity=${8:-} home_real fm_root_real
  local reread_marker pending_reread should_nudge target_locked=0 ff_rc=0
  [ -n "$id" ] || return 0
  [ -n "$home" ] || return 0
  fm_root_real=$(resolve_path "$FM_ROOT")
  home_real=$(resolve_path "$home")
  [ "$home_real" != "$fm_root_real" ] || return 0
  if ! validate_secondmate_home "$id" "$home"; then
    echo "secondmate $id: skipped: unsafe home: $VALIDATION_ERROR"
    return 0
  fi
  home_real="$VALIDATED_HOME"
  if [ -n "$window" ] && { [ -z "$lifecycle_state" ] \
    || ! fm_secondmate_lifecycle_identity_matches \
      "$lifecycle_state" "$id" "$home_real" "$window" "$endpoint_generation" \
      "$provider_identity"; }; then
    echo "secondmate $id: refused: lifecycle metadata is ambiguous or changed" >&2
    return 1
  fi
  case " $FF_SEEN_HOMES " in
    *" $home_real "*) return 0 ;;
  esac
  FF_SEEN_HOMES="$FF_SEEN_HOMES $home_real"

  reread_marker="$home_real/state/.watch-protocol-reread-required"
  if [ "$(type -t fm_ff_target_lock_acquire 2>/dev/null || true)" != function ] \
    || [ "$(type -t fm_ff_target_lock_release 2>/dev/null || true)" != function ]; then
    echo "secondmate $id: refused: lifecycle lock capability is unavailable" >&2
    return 1
  fi
  if ! fm_ff_target_lock_acquire "$home_real/state" "secondmate $id" "$home_real"; then
    FF_STATUS="skipped"
    FF_INSTR=""
    echo "secondmate $id: skipped: spawn or teardown is active"
    return 0
  fi
  target_locked=1
  if ! validate_secondmate_home "$id" "$home_real" \
    || [ "$VALIDATED_HOME" != "$home_real" ]; then
    fm_ff_target_lock_release
    return 1
  fi
  if [ -n "$window" ] && ! fm_secondmate_lifecycle_identity_matches \
      "$lifecycle_state" "$id" "$home_real" "$window" "$endpoint_generation" \
      "$provider_identity"; then
    fm_ff_target_lock_release
    return 1
  fi
  if [ -n "$window" ]; then
    if [ "$nudge_requires_instr" = yes ]; then
      ff_target "$home_real" "secondmate $id" "$base_mode" yes yes "$reread_marker" instructions || ff_rc=$?
    else
      ff_target "$home_real" "secondmate $id" "$base_mode" yes yes "$reread_marker" always || ff_rc=$?
    fi
  else
    ff_target "$home_real" "secondmate $id" "$base_mode" yes yes || ff_rc=$?
  fi
  if [ "$ff_rc" -ne 0 ]; then
    fm_ff_target_lock_release
    return "$ff_rc"
  fi
  pending_reread=0
  fm_update_obligation_pending "$reread_marker" "$home_real" && pending_reread=1
  if [ "$(type -t fm_ff_after_target_update 2>/dev/null || true)" = function ]; then
    if ! validate_secondmate_home "$id" "$home_real" \
      || [ "$VALIDATED_HOME" != "$home_real" ] \
      || { [ -n "$window" ] && ! fm_secondmate_lifecycle_identity_matches \
        "$lifecycle_state" "$id" "$home_real" "$window" "$endpoint_generation" \
          "$provider_identity"; } \
      || ! fm_ff_after_target_update "$id" "$home_real" "$window" \
        "$endpoint_generation" "$provider_identity"; then
      fm_ff_target_lock_release
      return 1
    fi
  fi
  should_nudge=0
  if [ "$FF_STATUS" = "updated" ]; then
    if [ "$nudge_requires_instr" != yes ] || [ -n "$FF_INSTR" ]; then
      should_nudge=1
    fi
  fi
  [ "$pending_reread" -eq 1 ] && should_nudge=1
  if [ "$should_nudge" -eq 1 ] && [ -n "$window" ]; then
    if [ "$(type -t fm_ff_after_instruction_update 2>/dev/null || true)" = function ]; then
      if ! validate_secondmate_home "$id" "$home_real" \
        || [ "$VALIDATED_HOME" != "$home_real" ] \
        || ! fm_secondmate_lifecycle_identity_matches \
          "$lifecycle_state" "$id" "$home_real" "$window" "$endpoint_generation" \
          "$provider_identity" \
        || ! fm_ff_after_instruction_update "$id" "$home_real" "$window" \
          "$FF_INSTR" "$endpoint_generation" "$provider_identity"; then
        fm_ff_target_lock_release
        return 1
      fi
    fi
    FF_NUDGE_WINDOWS="$FF_NUDGE_WINDOWS $window"
    if [ -n "$FF_OBLIGATION_GENERATION" ]; then
      FF_NUDGE_GENERATIONS="${FF_NUDGE_GENERATIONS}${FF_NUDGE_GENERATIONS:+
}$window|$FF_OBLIGATION_GENERATION"
    fi
  fi
  if [ "$target_locked" -eq 1 ]; then
    fm_ff_target_lock_release
  fi
}

# Sweep this home's LIVE secondmate direct reports - state/<id>.meta files with
# kind=secondmate - fast-forwarding each to base_mode. Passes base_mode and
# nudge_requires_instr through to process_secondmate. Accumulates into
# FF_NUDGE_WINDOWS / FF_SEEN_HOMES, which the caller resets before and reads after.
sweep_live_secondmate_metas() {
  local state=$1 base_mode=$2 nudge_requires_instr=${3:-no} registry=${4:-$FM_HOME/data/secondmates.md}
  local id home window meta endpoint_generation provider_identity
  [ -d "$state" ] || return 0
  while IFS='|' read -r id home window meta endpoint_generation provider_identity; do
    process_secondmate "$id" "$home" "$window" "$base_mode" "$nudge_requires_instr" \
      "$endpoint_generation" "$state" "$provider_identity" || return 1
  done < <(live_secondmate_meta_records "$state" "$registry")
}
