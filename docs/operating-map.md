# Operating Map

This is a navigation map for firstmate's operating lifecycle.
It points to the command or operating-manual section that owns each step instead of repeating all policy text.

## 1. Captain Request Enters Firstmate

The first mate receives the captain's request in chat and stays the only captain-facing contact.
It classifies the request as an immediate answer, a backlog change, a scout, a ship task, a secondmate routing case, or a lifecycle operation such as teardown.

Owner: `AGENTS.md` sections 1, 6, 7, and 9.

## 2. Startup, Recovery, And Fleet Truth

At session start, firstmate runs bootstrap, reads local fleet records, and recovers already in-flight work before dispatching anything new.
The durable inputs are local `data/` records, `state/*.meta`, `state/*.status`, tmux windows, secondmate homes, and project clones.
Bootstrap uses the shared tool-path helper before dependency checks; spawn, teardown, and the read-only model reuse it so clean non-interactive shells discover HOME-installed Axi tools the same way.

Owner: `AGENTS.md` sections 2, 3, and 5; `bin/fm-bootstrap.sh`; `bin/fm-tool-path-lib.sh`; `bin/fm-fleet-sync.sh`; `bin/fm-crew-state.sh`.

## 3. Intake And Routing

Firstmate resolves the project from `data/projects.md`, applies project mode, checks secondmate scopes, and selects the route profile, harness, model, and effort.
Local-only projects stay with the main firstmate; routed secondmate work goes through the registered secondmate home.

Owner: `AGENTS.md` sections 4, 6, and 7; `bin/fm-project-mode.sh`; `bin/fm-route.sh`; `data/projects.md`; `data/secondmates.md`.

## 4. Backlog Placement

Accepted work is recorded under `data/backlog.md` through the active backend.
Default homes use `tasks-axi`; `config/backlog-backend=manual` opts into hand edits.
Secondmate handoffs use the validated helper instead of a raw task move; it
moves the selected queued item's complete block, including indented context,
into the secondmate's own backlog.

Owner: `AGENTS.md` section 10; `.tasks.toml`; `bin/fm-tasks-axi-lib.sh`; `bin/fm-backlog-handoff.sh`.

## 5. Brief Creation

A brief becomes the direct-report contract.
Ship briefs assert checkout identity and isolation, scout briefs are report-only, and secondmate briefs are charters.
Matching JT Control Room PR-mode ship briefs also receive the JT PR Intake Governor after route selection.

Owner: `AGENTS.md` sections 6 and 7; `bin/fm-brief.sh`; `bin/fm-spawn.sh`.

## 6. Spawn

`fm-spawn.sh` allocates the canonical `fm-<id>` tmux window, validates its immutable window ID and title before issuing pane commands, gets or validates the isolated worktree, writes the task meta record, launches the selected harness with the resolved model and effort when supported, and installs any harness-specific turn-end hooks.
It uses the window ID for all post-create tmux operations, so a mutable title cannot redirect a task command; an unverified ID or title cleans up a uniquely identified new window and aborts the spawn.
Secondmate spawn uses the same direct-report machinery but points at an isolated firstmate home.

Owner: `AGENTS.md` sections 4 and 7; `bin/fm-spawn.sh`; `bin/fm-harness.sh`; `bin/fm-task-identity-lib.sh`; `bin/fm-home-seed.sh`.

## 7. Tmux, Worktree, And Meta Identity

Each direct report has a `state/<id>.meta` record with fields such as `window=`, `worktree=`, `project=`, `kind=`, `mode=`, `yolo=`, and route metadata.
The stored `window=` value is the human-facing canonical `session:fm-<id>` label; spawn uses the tmux-assigned immutable window ID internally after creation.
The tmux window is the live work surface, while the worktree or secondmate home is the filesystem boundary.

Owner: `AGENTS.md` sections 2, 6, and 7; `bin/fm-spawn.sh`; `bin/fm-tmux-lib.sh`; `bin/fm-tangle-lib.sh`.

## 8. Status And Current State

`state/<id>.status` is an append-only event log, not the current state by itself.
Firstmate reads current state through `fm-crew-state.sh`, which reconciles no-mistakes run state, pane state, and the latest status line; an active CI monitor with a current green-check marker reports PR-ready while it continues watching for merge or close. A valid `paused: <reason>` status names an external wait only if no authoritative run supersedes it; a blank pause reason is not a current state.

Owner: `AGENTS.md` sections 2 and 8; `bin/fm-crew-state.sh`; `bin/fm-classify-lib.sh`.

## 9. Watcher And Supervision

The watcher sleeps in bash, queues actionable wakes, and wakes firstmate only when there is something to handle.
`fm-watch-arm.sh` is the watcher-health source of truth, `fm-guard.sh` is a conservative warning surface, and `fm-watch-session.sh status` proves only the durable runner window.
A valid `paused: <reason>` is an external wait rather than a wedge, but the watcher and away-mode daemon re-surface it for review at the shared `FM_PAUSE_RESURFACE_SECS` cadence (default 3600 seconds); confirm current state and recheck the named dependency before treating that wake as stuck work.

Owner: `AGENTS.md` section 8; `bin/fm-watch.sh`; `bin/fm-watch-arm.sh`; `bin/fm-watch-session.sh`; `bin/fm-guard.sh`; `bin/fm-wake-drain.sh`; `bin/fm-supervise-daemon.sh`; `bin/fm-classify-lib.sh`; `docs/architecture.md`.

## 10. Radar And Read-Only Model

When a display or operator needs the shared state model, `fm-supervise.sh` emits either a checklist or the `firstmate.supervision.v1.1` JSON contract.
The JSON includes task classifications, worktree checks, external reminders, watcher source status, and `backlog_consistency` drift findings based on the same audit vocabulary as `fm-backlog-audit.sh`.
The model invokes the shared HOME-local tool-path normalization before optional GitHub reads, so non-interactive shells can still report GitHub runtime health when `gh-axi` is installed under NVM or `.local/bin`.
For valid paused statuses, it shares `FM_SUPERVISION_PAUSE_RECONCILE_SECS` across current-state reads in one collection; a matching active or terminal run wins, otherwise the task is `worker_external_wait` with `external` ownership.
When away-mode cannot confirm an escalation submit after the configured defer window, a non-empty `state/.subsuper-inject-wedged` marker adds the high-severity `supervision:inject-wedged` checklist finding; collection is read-only and leaves the marker for recovery or catch-up.

Owner: `AGENTS.md` sections 8 and 10; `bin/fm-supervise.sh`; `bin/fm-supervision-model.sh`; `bin/fm-backlog-audit.sh`; `bin/fm-backlog-audit-lib.sh`.

## 11. Steering And Secondmate Return Channel

Firstmate steers direct reports through `fm-send.sh`.
It accepts only a recorded bare `fm-<id>` target or an explicit `session:window` target; other bare window names fail closed.
Bare sends to a `kind=secondmate` target are marked as from-firstmate so the secondmate answers through status lines or document pointers instead of only through chat.

Owner: `AGENTS.md` sections 4, 7, and 8; `bin/fm-send.sh`; `bin/fm-marker-lib.sh`; `bin/fm-peek.sh`.

## 12. PR Checks And Review Readiness

A PR-ready task records its PR URL and PR head metadata, then the watcher can poll for merge state.
After the captain explicitly approves a PR merge, firstmate runs `FM_CAPTAIN_APPROVED_MERGE=1 bin/fm-pr-merge.sh <id> <full GitHub PR URL>` instead of calling `gh-axi pr merge` directly.
The wrapper records the PR evidence through `fm-pr-check.sh`, derives the repository and PR number from the qualified GitHub URL, defaults to squash, and refuses repository overrides.
The supervision model treats GitHub commit status and check-runs together before calling CI green.

Owner: `AGENTS.md` sections 1, 7, and 8; `bin/fm-pr-check.sh`; `bin/fm-pr-merge.sh`; `bin/fm-supervision-model.sh`; `bin/fm-no-mistakes-pr-target-guard.sh`.

## 13. Reports

Scout tasks finish by writing `data/<id>/report.md`.
The report is the scout deliverable, and teardown is allowed after that report exists.
Ship tasks report PRs, local merge outcomes, failures, or blockers through firstmate.

Owner: `AGENTS.md` sections 7 and 9; `bin/fm-teardown.sh`; `data/<id>/report.md`.

## 14. Teardown

Teardown returns a scout worktree after its report exists, or returns a ship worktree only when work is landed and clean.
It refuses dirty or unlanded work unless the captain explicitly approves discard.
It retries only transient Git `index.lock` failures while returning a worktree or leased secondmate home; any other return failure remains fail-closed.
Secondmate teardown means explicit retirement, not ordinary task closeout, and
leaves the main backlog unchanged.

Owner: `AGENTS.md` section 7; `bin/fm-teardown.sh`; `bin/fm-merge-local.sh`; `bin/fm-ff-lib.sh`.

## 15. Backlog Closeout

After landed work, report delivery, or local-only merge, firstmate updates the backlog through the active backend and re-evaluates queued work.
The done entry should carry the full PR URL, report path, or local merge note.

Owner: `AGENTS.md` sections 7 and 10; `.tasks.toml`; `bin/fm-tasks-axi-lib.sh`; `tasks-axi`.

## 16. Persistent Knowledge

Captain preferences, fleet-local learnings, project-intrinsic knowledge, and task-scoped notes each have different homes.
General firstmate knowledge belongs in tracked docs through a normal PR.

Owner: `AGENTS.md` section 6; `data/captain.md`; `data/learnings.md`; project `AGENTS.md`; `docs/`.
