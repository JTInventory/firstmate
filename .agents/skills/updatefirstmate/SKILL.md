---
name: updatefirstmate
description: Self-update a running firstmate and its secondmates to the latest from origin. Use when the captain invokes /updatefirstmate (e.g. "/updatefirstmate", "update firstmate", "pull the latest firstmate"). Fast-forwards this firstmate repo's default branch and every secondmate home from origin (fast-forward only, never forced, never disruptive), then re-reads AGENTS.md and nudges each updated secondmate to do the same, so the whole tree runs the latest bin/ and instructions.
user-invocable: true
---

# updatefirstmate

Self-update firstmate in place.
Firstmate is its own repo, behind the same no-mistakes gate as any project, so new tracked material (AGENTS.md, bin/, skills) reaches `main` and then sits there until each running firstmate pulls it.
This skill performs that pull for the running main firstmate and every secondmate, without disturbing any in-flight work.

The update is **fast-forward only** - the same sanctioned self-write as the fleet sync firstmate already runs.
It never forces, never creates a merge commit, never stashes, and advances a target only on a clean fast-forward; anything dirty, diverged, offline, or on the wrong branch is skipped and reported.
A tracked-files fast-forward leaves the gitignored operational dirs (data/, state/, config/, projects/, .no-mistakes/) untouched, so a secondmate's in-flight work is never disrupted.
This touches only the firstmate repo and its own worktrees, never anything under `projects/`.

## What it does

1. **Run the updater:**
   ```sh
   bin/fm-update.sh
   ```
   It fast-forwards this firstmate repo's default branch from origin, then fast-forwards every registered secondmate home (each a treehouse worktree of this same repo, leased at a detached HEAD on the default branch) the same way.
   It prints one status line per target (`updated <old>..<new>` / `already current` / `skipped: <reason>`), followed by action lines that tell you exactly what to do next:
   - `reread-firstmate: yes|no`
   - `reread-firstmate-generation: <commit>|none`
   - `restart-firstmate-watcher: yes|no`
   - `restart-secondmate-watchers: <window-targets...>|none`
   - `nudge-secondmates: <window-targets...>|none`
   - one `nudge-secondmate-generation: <window-target>|<commit>` line per nudge

2. **Re-read AGENTS.md if your own instructions changed.**
   When the updater printed `reread-firstmate: yes`, the tracked instruction surface (AGENTS.md, bin/, or skills) just advanced under you.
   **Read `AGENTS.md` now** (CLAUDE.md is a symlink to it) to refresh your operating instructions before doing anything else, so you are acting on the new instructions rather than the stale ones you were started with.
   After the read succeeds, acknowledge it:
   ```sh
   bin/fm-update.sh --ack-reread-firstmate <commit-from-reread-firstmate-generation>
   ```
   When the first run updated firstmate, run `bin/fm-update.sh` once more from the installed checkout before acknowledging. This second invocation is required so an updater that began on the previous protocol cannot validate a watcher with its old in-memory rules.
   When it printed `reread-firstmate: no`, nothing changed for you - skip the re-read.

3. **Restart this home's watcher when required.**
   The updater verifies the home-scoped watcher and its harness-tracked follower before it prints its summary. If it finds a legacy watcher, it stops that home-scoped cycle and exits non-zero with durable protocol and reread obligations. Let the existing follower wake the harness, re-arm the watcher through the harness's tracked background mechanism, then run `bin/fm-update.sh` again. The retry replays the required AGENTS.md reread and any secondmate nudges even when every checkout is already current. `restart-firstmate-watcher: yes` is printed only after that tracked replacement is verified.

4. **Nudge each updated live secondmate.**
   For every target listed on the `nudge-secondmates:` line (do nothing when it says `none`), send a one-line re-read nudge so that secondmate picks up its new instructions too:
   ```sh
   bin/fm-send.sh <window-target> 'firstmate was updated to the latest - please re-read your AGENTS.md to pick up the new instructions.'
   bin/fm-update.sh --ack-secondmate-nudge <window-target> <commit-from-the-matching-generation-line>
   ```
   Run the acknowledgement only after `fm-send.sh` confirms delivery. A failed or interrupted send leaves the durable nudge obligation for the next updater retry.
   The updater has already verified each watcher and follower listed on `restart-secondmate-watchers:`. If it stopped a legacy secondmate watcher, that secondmate must complete its normal harness-tracked re-arm before the updater retry can succeed. Updated homes without a running watcher need no restart because no legacy process remains; their next watcher starts from the updated code. The restart does not stop a secondmate's agent pane or project work.
   A secondmate that was skipped, already current, or has no live metadata is not on the list and needs no nudge.

5. **Report to the captain in plain outcomes.**
   Summarize what landed without firstmate's internal vocabulary: which parts of the fleet are now on the latest, and which were left as-is and why.
   For example: "Captain, firstmate and both domain supervisors are now on the latest."
   Surface any skipped target whose reason needs the captain's attention - for instance a home with its own un-landed changes (diverged) or local edits (dirty), which were left untouched on purpose.

## Safety

- **Fast-forward only.**
  A target that has diverged, is dirty, is offline, or is on a non-default branch is skipped and reported, never forced or stashed.
  Nothing with unlanded work is ever discarded - this is prime directive #3.
- **Only the firstmate repo and its worktrees** are touched, never `projects/`.
  It is the same sanctioned self-write as the fleet sync.
- **Secondmate work is never disrupted.**
  A secondmate gets a tracked-files fast-forward plus a home-scoped watcher restart and re-read nudge. Its agent pane, operational state, and project work remain intact.
