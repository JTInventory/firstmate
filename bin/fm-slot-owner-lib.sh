#!/usr/bin/env bash
# bin/fm-slot-owner-lib.sh - the ONE owner of "may this pooled worktree slot be
# released?".
#
# A task's recorded `worktree=` is a HISTORICAL record of a slot the task once
# used, never proof that the task still owns it. Pooled slots are reused: a
# census on 2026-07-24 found ten treehouse slots recorded by more than one task,
# up to six each, and on 2026-07-25 the hazard fired - tearing down one task
# released a lease that a still-live quarantined-paused task also recorded, and
# the pool reissued that exact slot to a new spawn.
#
# So disposal is gated on POSITIVE evidence of a conflict, in three independent
# forms, any one of which retains the lease:
#
#   1. another task recorded in the same home names the same physical slot -
#      the observed incident, and it needs no cooperation from the occupant;
#   2. the slot's ownership stamp names a different task or home - the metadata
#      being trusted is positively stale because the slot was reissued;
#   3. a live agent declared for a DIFFERENT task is running inside the slot
#      (bin/fm-agent-cwd-lib.sh's authoritative process cwd).
#
# Retain means the lease is not returned to the pool: firstmate finishes the
# rest of the teardown (records and endpoint) and leaves the directory on disk,
# so the slot can never be reissued out from under its other holder. That is
# the records-and-panes-only policy that kept the 2026-07-25 collision harmless,
# made deterministic. It is NOT a work-preservation check and therefore is NOT
# waived by --force: --force is the captain's authority to discard THIS task's
# work, never authority to release another task's slot.
#
# Absence of evidence is not evidence: a slot with no stamp (every task spawned
# before stamping existed) and no conflicting reference still disposes normally.
#
# Retention must not be a one-way door either. A task that retains on rule 1 AND
# still completes its own teardown gives up its own stamp as it goes
# (fm_slot_stamp_relinquish), so the holder left behind can still release the
# slot once nothing references it. A caller that refuses outright keeps every
# record and therefore keeps the stamp too, because a refused operation changes
# nothing. A stamp naming someone ELSE is never cleared either, because that
# stamp is what stops a stale task from disposing of a slot whose real occupant
# is merely paused.
# docs/worker-isolation.md owns the operator reclaim path for a slot that was
# already leaked before this rule existed.
#
# The stamp lives in the worktree's PRIVATE git directory, never in the working
# tree, so it can never dirty a status check or leak into a commit. Writing is
# refused for anything that is not a linked worktree, so a primary checkout can
# never be stamped as a disposable slot.
#
# docs/worker-isolation.md owns how this mechanism fits with the other three.
#
# This file is sourced by scripts and has no side effects on source.

_FM_SLOT_OWNER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-agent-cwd-lib.sh
. "$_FM_SLOT_OWNER_LIB_DIR/fm-agent-cwd-lib.sh"

FM_SLOT_OWNER_STAMP_NAME=fm-slot-owner

# The exact prefix of the rule-1 (metadata reference) retain verdict. One owner,
# because fm_slot_stamp_relinquish keys the only stamp clear that is safe off
# this specific reason.
FM_SLOT_RETAIN_META_PREFIX='retain: slot is also recorded by task(s) '

# fm_slot_stamp_path <worktree>: the stamp path for a LINKED worktree, or 1 for
# a plain checkout (whose git dir is shared and must never be stamped).
fm_slot_stamp_path() {
  local wt=$1 git_dir common_dir
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  git_dir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  common_dir=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$git_dir" ] && [ -n "$common_dir" ] || return 1
  # --git-common-dir can be relative to the worktree; resolve both physically
  # rather than depending on a git new enough for --path-format=absolute.
  case "$common_dir" in
    /*) ;;
    *) common_dir="$wt/$common_dir" ;;
  esac
  git_dir=$(fm_agent_canonical_dir "$git_dir") || return 1
  common_dir=$(fm_agent_canonical_dir "$common_dir") || return 1
  [ "$git_dir" != "$common_dir" ] || return 1
  printf '%s/%s' "$git_dir" "$FM_SLOT_OWNER_STAMP_NAME"
}

fm_slot_is_plain_checkout() {
  local wt=$1 git_dir common_dir
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  git_dir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  common_dir=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common_dir" in
    /*) ;;
    *) common_dir="$wt/$common_dir" ;;
  esac
  git_dir=$(fm_agent_canonical_dir "$git_dir") || return 1
  common_dir=$(fm_agent_canonical_dir "$common_dir") || return 1
  [ "$git_dir" = "$common_dir" ]
}

# fm_slot_stamp_write <worktree> <task-id> <home>: claim current ownership of
# the slot without replacing another owner's evidence.
fm_slot_stamp_write() {
  local wt=$1 id=$2 home=$3 path claim legacy_target
  FM_SLOT_STAMP_CREATED=0
  [ -n "$id" ] && [ -n "$home" ] || return 1
  path=$(fm_slot_stamp_path "$wt") || return 1
  claim=$(fm_slot_return_claim_path "$wt" 2>/dev/null || true)
  [ -z "$claim" ] || { [ ! -e "$claim" ] && [ ! -L "$claim" ]; } || return 1
  legacy_target=$(fm_slot_return_legacy_path "$wt" 2>/dev/null || true)
  if [ -L "$path" ] && [ -n "$legacy_target" ] \
    && [ "$(readlink "$path" 2>/dev/null || true)" = "$legacy_target" ] \
    && [ ! -e "$claim" ] && [ ! -L "$claim" ]; then
    rm -f "$path" "$legacy_target" || return 1
  fi
  if [ -e "$path" ] || [ -L "$path" ]; then
    fm_slot_stamp_record "$wt" \
      && [ "$FM_SLOT_STAMP_TASK" = "$id" ] \
      && [ "$FM_SLOT_STAMP_HOME" = "$home" ]
    return
  fi
  if ( set -C; printf 'task=%s\nhome=%s\n' "$id" "$home" > "$path" ) 2>/dev/null; then
    FM_SLOT_STAMP_CREATED=1
    return 0
  fi
  fm_slot_stamp_record "$wt" \
    && [ "$FM_SLOT_STAMP_TASK" = "$id" ] \
    && [ "$FM_SLOT_STAMP_HOME" = "$home" ]
}

# fm_slot_stamp_field <worktree> <task|home>: the stamped value, or 1.
fm_slot_stamp_field() {
  local wt=$1 field=$2
  fm_slot_stamp_record "$wt" || return 1
  case "$field" in
    task) printf '%s' "$FM_SLOT_STAMP_TASK" ;;
    home) printf '%s' "$FM_SLOT_STAMP_HOME" ;;
    *) return 1 ;;
  esac
}

fm_slot_owner_record_file() {
  local path=$1 task_count home_count line_count
  FM_SLOT_STAMP_TASK=
  FM_SLOT_STAMP_HOME=
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    return 1
  fi
  [ -f "$path" ] && [ ! -L "$path" ] && [ -r "$path" ] || return 2
  task_count=$(grep -c '^task=' "$path" 2>/dev/null) || task_count=0
  home_count=$(grep -c '^home=' "$path" 2>/dev/null) || home_count=0
  line_count=$(wc -l < "$path" 2>/dev/null) || return 2
  [ "$task_count" -eq 1 ] && [ "$home_count" -eq 1 ] && [ "$line_count" -eq 2 ] || return 2
  FM_SLOT_STAMP_TASK=$(sed -n 's/^task=//p' "$path")
  FM_SLOT_STAMP_HOME=$(sed -n 's/^home=//p' "$path")
  [ -n "$FM_SLOT_STAMP_TASK" ] && [ -n "$FM_SLOT_STAMP_HOME" ] || return 2
}

fm_slot_stamp_record() {
  local wt=$1 path
  path=$(fm_slot_stamp_path "$wt") || return 2
  fm_slot_owner_record_file "$path"
}

# fm_slot_stamp_clear <worktree>: drop the stamp once the slot is released.
fm_slot_stamp_clear() {
  local wt=$1 path
  path=$(fm_slot_stamp_path "$wt") || return 0
  rm -f "$path" 2>/dev/null || true
}

fm_slot_stamp_clear_exact() {  # <worktree> <task-id> <home>
  local wt=$1 id=$2 home=$3 path
  path=$(fm_slot_stamp_path "$wt") || return 0
  fm_slot_stamp_record "$wt" || return 0
  [ "$FM_SLOT_STAMP_TASK" = "$id" ] \
    && fm_slot_same_path "$FM_SLOT_STAMP_HOME" "$home" || return 0
  rm -f "$path"
}

fm_slot_return_claim_path() {
  local wt=$1 git_dir common_dir slot_key dir
  git_dir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  common_dir=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common_dir" in
    /*) ;;
    *) common_dir="$wt/$common_dir" ;;
  esac
  git_dir=$(fm_agent_canonical_dir "$git_dir") || return 1
  common_dir=$(fm_agent_canonical_dir "$common_dir") || return 1
  [ "$git_dir" != "$common_dir" ] || return 1
  slot_key=${git_dir##*/}
  case "$slot_key" in ''|*[!A-Za-z0-9._-]*|*/*) return 1 ;; esac
  dir="$common_dir/fm-slot-return-claims"
  printf '%s/%s.claim' "$dir" "$slot_key"
}

fm_slot_return_legacy_path() {
  local wt=$1 claim
  claim=$(fm_slot_return_claim_path "$wt") || return 1
  printf '%s.owner' "$claim"
}

fm_slot_return_claim_record_file() {
  local claim=$1 task_count home_count holder_count line_count
  FM_SLOT_RETURN_CLAIM_TASK=
  FM_SLOT_RETURN_CLAIM_HOME=
  FM_SLOT_RETURN_CLAIM_HOLDER=
  if [ ! -e "$claim" ] && [ ! -L "$claim" ]; then
    return 1
  fi
  [ -f "$claim" ] && [ ! -L "$claim" ] && [ -r "$claim" ] || return 2
  task_count=$(grep -c '^task=' "$claim" 2>/dev/null) || task_count=0
  home_count=$(grep -c '^home=' "$claim" 2>/dev/null) || home_count=0
  holder_count=$(grep -c '^lease_holder=' "$claim" 2>/dev/null) || holder_count=0
  line_count=$(wc -l < "$claim" 2>/dev/null) || return 2
  [ "$task_count" -eq 1 ] && [ "$home_count" -eq 1 ] \
    && [ "$holder_count" -eq 1 ] && [ "$line_count" -eq 3 ] || return 2
  FM_SLOT_RETURN_CLAIM_TASK=$(sed -n 's/^task=//p' "$claim")
  FM_SLOT_RETURN_CLAIM_HOME=$(sed -n 's/^home=//p' "$claim")
  FM_SLOT_RETURN_CLAIM_HOLDER=$(sed -n 's/^lease_holder=//p' "$claim")
  [ -n "$FM_SLOT_RETURN_CLAIM_TASK" ] \
    && [ -n "$FM_SLOT_RETURN_CLAIM_HOME" ] \
    && [ -n "$FM_SLOT_RETURN_CLAIM_HOLDER" ] || return 2
}

fm_slot_return_claim_record() {
  local wt=$1 claim
  claim=$(fm_slot_return_claim_path "$wt") || return 2
  fm_slot_return_claim_record_file "$claim"
}

fm_slot_stamp_stage_return() {
  local wt=$1 id=$2 home=$3 _state=$4 lease_holder=$5 path claim legacy tmp link_tmp
  FM_SLOT_RETURN_STAGED=0
  FM_SLOT_RETURN_CLAIM=
  FM_SLOT_RETURN_STAMP_PATH=
  FM_SLOT_RETURN_LEGACY=
  [ -n "$lease_holder" ] || return 1
  path=$(fm_slot_stamp_path "$wt") || return 1
  claim=$(fm_slot_return_claim_path "$wt") || return 1
  legacy=$(fm_slot_return_legacy_path "$wt") || return 1
  if [ -e "${claim%/*}" ] || [ -L "${claim%/*}" ]; then
    [ -d "${claim%/*}" ] && [ ! -L "${claim%/*}" ] || return 1
  else
    mkdir "${claim%/*}" || return 1
  fi
  if [ -e "$claim" ] || [ -L "$claim" ]; then
    fm_slot_return_claim_record_file "$claim" || return 1
    [ "$FM_SLOT_RETURN_CLAIM_TASK" = "$id" ] \
      && fm_slot_same_path "$FM_SLOT_RETURN_CLAIM_HOME" "$home" \
      && [ "$FM_SLOT_RETURN_CLAIM_HOLDER" = "$lease_holder" ] || return 1
  fi
  if [ -e "$path" ] || [ -L "$path" ]; then
    if [ -L "$path" ] && [ "$(readlink "$path" 2>/dev/null || true)" = "$legacy" ]; then
      fm_slot_owner_record_file "$legacy" || return 1
      [ "$FM_SLOT_STAMP_TASK" = "$id" ] \
        && fm_slot_same_path "$FM_SLOT_STAMP_HOME" "$home" || return 1
    else
      fm_slot_owner_record_file "$path" || return 1
      [ "$FM_SLOT_STAMP_TASK" = "$id" ] \
        && fm_slot_same_path "$FM_SLOT_STAMP_HOME" "$home" || return 1
    fi
    if [ ! -e "$claim" ] && [ ! -L "$claim" ]; then
      tmp=$(mktemp "${claim}.XXXXXX") || return 1
      chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
      printf 'task=%s\nhome=%s\nlease_holder=%s\n' "$id" "$home" "$lease_holder" > "$tmp" \
        && mv "$tmp" "$claim" || { rm -f "$tmp"; return 1; }
    fi
    if [ -e "$legacy" ] || [ -L "$legacy" ]; then
      fm_slot_owner_record_file "$legacy" || return 1
      [ "$FM_SLOT_STAMP_TASK" = "$id" ] \
        && fm_slot_same_path "$FM_SLOT_STAMP_HOME" "$home" || return 1
    else
      ( set -C; printf 'task=%s\nhome=%s\n' "$id" "$home" > "$legacy" ) \
        2>/dev/null || return 1
      chmod 600 "$legacy" || return 1
    fi
    link_tmp="${path}.return.$$.$RANDOM"
    ln -s "$legacy" "$link_tmp" || return 1
    mv -f "$link_tmp" "$path" || { rm -f "$link_tmp"; return 1; }
  else
    [ ! -e "$claim" ] && [ ! -L "$claim" ] || return 1
    return 0
  fi
  FM_SLOT_RETURN_STAGED=1
  FM_SLOT_RETURN_CLAIM=$claim
  FM_SLOT_RETURN_STAMP_PATH=$path
  FM_SLOT_RETURN_LEGACY=$legacy
}

fm_slot_stamp_restore_return() {
  local wt=$1 id=$2 home=$3 claim=$4 lease_holder=$5
  local path=${6:-} legacy=${7:-}
  [ -n "$claim" ] || return 0
  [ -n "$path" ] && [ -n "$legacy" ] || return 1
  fm_slot_return_claim_record_file "$claim" || return 1
  [ "$FM_SLOT_RETURN_CLAIM_TASK" = "$id" ] \
    && fm_slot_same_path "$FM_SLOT_RETURN_CLAIM_HOME" "$home" \
    && [ "$FM_SLOT_RETURN_CLAIM_HOLDER" = "$lease_holder" ] || return 1
  fm_slot_owner_record_file "$legacy" || return 1
  [ "$FM_SLOT_STAMP_TASK" = "$id" ] \
    && fm_slot_same_path "$FM_SLOT_STAMP_HOME" "$home" || return 1
  [ "$(fm_slot_stamp_path "$wt" 2>/dev/null || true)" = "$path" ] || return 1
  [ -L "$path" ] && [ "$(readlink "$path" 2>/dev/null || true)" = "$legacy" ]
}

fm_slot_stamp_finalize_return() {
  local claim=$1 legacy=${2:-}
  [ -n "$claim" ] || return 0
  [ -n "$legacy" ] || legacy="${claim}.owner"
  rm -f "$legacy" "$claim"
}

# fm_slot_meta_worktree <meta-file>: the recorded worktree path, or empty.
fm_slot_meta_worktree() {
  local meta=$1
  [ -f "$meta" ] || return 0
  grep '^worktree=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# fm_slot_same_path <a> <b>: physical comparison where both paths exist, exact
# string comparison otherwise, so a recorded slot whose directory is already
# gone is still recognized as the same reference.
fm_slot_same_path() {
  local a=${1:-} b=${2:-} ra rb
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  ra=$(fm_agent_canonical_dir "$a") || return 1
  rb=$(fm_agent_canonical_dir "$b") || return 1
  [ "$ra" = "$rb" ]
}

# fm_slot_meta_referencing_tasks <state-dir> <task-id> <worktree>: other task
# ids in this home whose metadata names the same slot, newline separated.
fm_slot_meta_referencing_tasks() {
  local state=$1 self=$2 wt=$3 meta id other found=1
  [ -d "$state" ] || return 1
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ "$id" != "$self" ] || continue
    other=$(fm_slot_meta_worktree "$meta")
    [ -n "$other" ] || continue
    fm_slot_same_path "$other" "$wt" || continue
    printf '%s\n' "$id"
    found=0
  done
  return "$found"
}

# fm_slot_live_occupant_tasks <worktree> <task-id> <home> <role>: other
# complete identities whose declared
# live agent process is running inside the slot right now, newline separated
# and deduplicated. Missing process capability returns an unknown result.
fm_slot_live_occupant_tasks() {
  local wt=$1 self=$2 self_home=$3 self_role=$4 wt_real entry pid task home role cwd raw_cwd env hits state
  wt_real=$(fm_agent_canonical_dir "$wt") || return 1
  [ -d /proc ] || return 2
  hits=
  for entry in /proc/[0-9]*; do
    [ -d "$entry" ] || continue
    pid=${entry#/proc/}
    if ! cwd=$(fm_agent_proc_cwd "$pid"); then
      [ ! -d "$entry" ] && continue
      state=$(sed -n 's/^State:[[:space:]]*\([^[:space:]]\).*/\1/p' "$entry/status" 2>/dev/null || true)
      case "$state" in Z|X|x) continue ;; esac
      grep -Eq '^Kthread:[[:space:]]*1$' "$entry/status" 2>/dev/null && continue
      if ! cwd=$(fm_agent_proc_cwd "$pid"); then
        [ ! -d "$entry" ] && continue
        state=$(sed -n 's/^State:[[:space:]]*\([^[:space:]]\).*/\1/p' "$entry/status" 2>/dev/null || true)
        case "$state" in Z|X|x) continue ;; esac
        return 2
      fi
    fi
    raw_cwd=$cwd
    if ! cwd=$(fm_agent_canonical_dir "$raw_cwd"); then
      [ ! -d "$entry" ] && continue
      case "$raw_cwd" in
        *" (deleted)")
          raw_cwd=${raw_cwd%" (deleted)"}
          fm_agent_path_within "$wt_real" "$raw_cwd" || continue
          ;;
      esac
      return 2
    fi
    fm_agent_path_within "$wt_real" "$cwd" || continue
    if env=$(fm_agent_environ "$pid"); then
      task=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_TASK=//p' | head -1)
      home=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_OWNER_HOME=//p' | head -1)
      role=$(printf '%s\n' "$env" | sed -n 's/^FM_AGENT_ROLE=//p' | head -1)
    else
      task=
      home=
      role=
    fi
    if [ "$task" = "$self" ] && [ "$role" = "$self_role" ] \
       && fm_slot_same_path "$home" "$self_home"; then
      continue
    fi
    hits="$hits${task:-unidentified-process-$pid}"$'\n'
  done
  [ -n "$hits" ] || return 1
  printf '%s' "$hits" | LC_ALL=C sort -u
}

# fm_slot_join_ids <newline-separated>: comma-joined single line.
fm_slot_join_ids() {
  printf '%s' "$1" | LC_ALL=C sort -u | tr '\n' ',' | sed 's/,$//'
}

# fm_slot_disposal_verdict <state-dir> <task-id> <worktree> <stamp-home> <worker-home> <role>
# Print exactly `dispose` or `retain: <reason>`.
fm_slot_disposal_verdict() {
  local state=$1 self=$2 wt=$3 stamp_owner_home=$4 worker_home=$5 role=$6
  local stamp_task stamp_home stamp_status claim_status refs occupants stamp_path legacy_path
  if [ -z "$wt" ] || [ ! -d "$wt" ]; then
    printf 'dispose'
    return 0
  fi
  if refs=$(fm_slot_meta_referencing_tasks "$state" "$self" "$wt"); then
    printf '%s%s in this home' "$FM_SLOT_RETAIN_META_PREFIX" "$(fm_slot_join_ids "$refs")"
    return 0
  fi
  if fm_slot_return_claim_record "$wt"; then
    claim_status=0
  else
    claim_status=$?
  fi
  if [ "$claim_status" -eq 2 ]; then
    printf 'retain: slot return transition claim is malformed, partial, unreadable, or cannot be classified'
    return 0
  fi
  if [ "$claim_status" -eq 0 ]; then
    if [ "$FM_SLOT_RETURN_CLAIM_TASK" != "$self" ]; then
      printf 'retain: slot return transition names task %s, not %s' \
        "$FM_SLOT_RETURN_CLAIM_TASK" "$self"
      return 0
    fi
    if [ -n "$stamp_owner_home" ] \
      && ! fm_slot_same_path "$FM_SLOT_RETURN_CLAIM_HOME" "$stamp_owner_home"; then
      printf 'retain: slot return transition names home %s, not %s' \
        "$FM_SLOT_RETURN_CLAIM_HOME" "$stamp_owner_home"
      return 0
    fi
    if [ "$FM_SLOT_RETURN_CLAIM_HOLDER" != "$self" ]; then
      printf 'retain: slot return transition lease holder %s, not %s' \
        "$FM_SLOT_RETURN_CLAIM_HOLDER" "$self"
      return 0
    fi
  fi
  stamp_path=$(fm_slot_stamp_path "$wt" 2>/dev/null || true)
  legacy_path=$(fm_slot_return_legacy_path "$wt" 2>/dev/null || true)
  if [ "$claim_status" -eq 0 ] && [ -n "$stamp_path" ] && [ -L "$stamp_path" ] \
    && [ "$(readlink "$stamp_path" 2>/dev/null || true)" = "$legacy_path" ]; then
    if fm_slot_owner_record_file "$legacy_path"; then
      stamp_status=0
    else
      stamp_status=2
    fi
  elif fm_slot_stamp_record "$wt"; then
    stamp_status=0
  else
    stamp_status=$?
  fi
  if [ "$stamp_status" -eq 2 ]; then
    printf 'retain: slot ownership stamp is present but malformed, partial, unreadable, or cannot be classified'
    return 0
  fi
  if [ "$stamp_status" -eq 0 ]; then
    stamp_task=$FM_SLOT_STAMP_TASK
    stamp_home=$FM_SLOT_STAMP_HOME
    if [ "$stamp_task" != "$self" ]; then
      printf 'retain: slot ownership stamp names task %s, not %s' "$stamp_task" "$self"
      return 0
    fi
    if [ -n "$stamp_owner_home" ] && ! fm_slot_same_path "$stamp_home" "$stamp_owner_home"; then
      printf 'retain: slot ownership stamp names home %s, not %s' "$stamp_home" "$stamp_owner_home"
      return 0
    fi
  fi
  if occupants=$(fm_slot_live_occupant_tasks "$wt" "$self" "$worker_home" "$role"); then
    printf 'retain: a live agent for task(s) %s is running in the slot' "$(fm_slot_join_ids "$occupants")"
    return 0
  elif [ "$?" -eq 2 ]; then
    printf 'retain: authoritative live-occupant evidence is unavailable'
    return 0
  fi
  printf 'dispose'
}

# fm_slot_stamp_relinquish <worktree> <task-id> <home> <verdict>
# Give up THIS task's claim on a slot it is retaining, so a retained lease can
# still be released later by whoever is left holding it.
#
# Only a caller that PROCEEDS past the gate and goes on to delete this task's
# own records may ask for this. A caller that refuses outright and preserves
# every record must not: nothing was torn down, ownership did not change, and
# erasing the stamp there would strip the rule-2 evidence that stops a stale
# sibling from later disposing of a slot still holding this task's paused work.
#
# Without this the gate is a one-way door. Task B stamps a slot, paused task A's
# stale metadata also names it, B tears down and retains on rule 1, and B's
# metadata is then removed. When A finally tears down, no reference is left to
# justify the retention - but the stamp still names B, so rule 2 retains forever
# and the pool has silently lost a slot that nothing references.
#
# The clear is deliberately NARROW, and the narrowness is the whole safety
# argument:
#   - retained by ANOTHER TASK'S METADATA while the stamp names SELF: this is
#     the true owner handing the slot back to the other holder, so its stamp
#     must not outlive it;
#   - retained because the stamp names a DIFFERENT task: PRESERVE it. The stamp
#     is positive evidence the slot was reissued to someone else, and clearing
#     it would let a later teardown of the stale task dispose of a slot whose
#     real occupant merely has no live process at that moment (paused or exited
#     work), destroying preserved work - strictly worse than the leak above;
#   - retained by a live occupant: PRESERVE it, for the same reason.
# Metadata references stay checked first and stay authoritative in
# fm_slot_disposal_verdict; that ordering is what protects a live-but-paused
# task from having its slot reissued, and nothing here weakens it.
#
# Always succeeds: a slot with no stamp, or one stamped for someone else, simply
# keeps whatever evidence it has.
fm_slot_stamp_relinquish() {  # <worktree> <task-id> <home> <verdict>
  local wt=$1 self=$2 home=$3 verdict=$4 stamp_task stamp_home
  case "$verdict" in
    "$FM_SLOT_RETAIN_META_PREFIX"*) ;;
    *) return 0 ;;
  esac
  stamp_task=$(fm_slot_stamp_field "$wt" task) || return 0
  [ "$stamp_task" = "$self" ] || return 0
  stamp_home=$(fm_slot_stamp_field "$wt" home) || return 0
  fm_slot_same_path "$stamp_home" "$home" || return 0
  fm_slot_stamp_clear "$wt"
  return 0
}
