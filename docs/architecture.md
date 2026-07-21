# Architecture

How firstmate works, in depth.

The [README](../README.md) carries the high-level diagram and a short synopsis.
This document expands every part of it.
firstmate's full operating manual for the orchestrator agent itself is [`AGENTS.md`](../AGENTS.md); this is the human-facing companion.

## Event-driven supervision

A zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet, classifies detected wakes in bash, and wakes the first mate only when something is actionable.
Actionable wakes include captain-relevant status signals, no-verb signals whose crew is not provably working, check-script output such as PR merge polling or an X mention, terminal stale panes, non-terminal stale panes whose crew is not provably working, provably-working non-terminal stale panes that persist past `FM_STALE_ESCALATE_SECS`, valid declared external waits that reach `FM_PAUSE_RESURFACE_SECS`, and heartbeat backstop hits.
Those actionable wakes are written to a durable local queue (`state/.wake-queue`) before detector state advances, so a missed process exit can be recovered by draining the queue.
No-verb wakes, such as `working:` notes, bare turn-ended signals, and fresh non-terminal stale panes, are benign only when `bin/fm-crew-state.sh` reports positive evidence that the crew is still working: an actively running no-mistakes step for that crew's branch or a pane busy signature.
No-change heartbeats are also benign.
Absorbed wakes advance their suppression markers, log to `state/.watch-triage.log`, and keep the watcher blocking without a queue record or LLM turn.
After each drain, `fm-wake-drain.sh` runs the same liveness guard as the supervision scripts, so a lapsed watcher chain surfaces even on a turn that only drains and handles queued wakes.
Routine watcher polling, re-arm no-ops, elapsed waiting time, and absorbed benign wakes stay silent; an idle crew costs you nothing.
Crew status files are append-only wake-event logs, not current-state fields.
`bin/fm-crew-state.sh <id>` is the cheap current-state read for an actionable heartbeat review: it attributes the matching no-mistakes run, active or terminal, to the crew's own branch and keeps that run-step authoritative even if the pane has closed. During no-mistakes CI monitoring, it reads the current CI-log marker so green checks awaiting captain merge report as ready rather than as still validating.
Only when no matching run exists does it fall back to the pane busy-signature and then the status log; a dead pane without a run reports unknown instead of trusting a stale log. A valid `paused: <reason>` log is an explicit external wait, distinct from `blocked:` and `working:`; an active run always wins over a stale pause, and an empty pause reason remains unknown.
Optional X mode rides the same check path: bootstrap drops a local `state/x-watch.check.sh` shim only after the user opts in with `FMX_PAIRING_TOKEN`, and non-X homes keep the default watcher behavior.

Routine re-arms go through `bin/fm-watch-arm.sh`, which launches the watcher in its own session/process group, follows it as a tracked follower, verifies it is genuinely alive with a fresh liveness beacon, and prints exactly one honest status line (`started` / `attached` / `follower already waiting` / restart-only `healthy` / `FAILED`, the last exiting non-zero). A per-home arm lock prevents duplicate healthy-cycle followers from stacking.
On `attached` it stays live until the existing verified cycle ends, so a background-notify harness does not receive an empty false wake from a healthy no-op exit.
The shared lock helper writes versioned PID identities using the `C` locale, so watcher identity does not change with the caller locale. It preserves live-held behavior for locks with no process identity; matching legacy locale-dependent identities are migrated in place, while an unmigratable legacy identity becomes reclaimable after `FM_LOCK_LEGACY_IDENTITY_MAX_AGE` (default 300 seconds). Watcher locks with a stale current identity can be reclaimed once the current live PID no longer matches it.
Its `--restart` mode signals only the watcher recorded in the current home's `state/.watch.lock`, so restarting one home cannot kill sibling secondmate watchers.
For harnesses where a tracked background call is not durable enough, `bin/fm-watch-session.sh` provides a home-scoped tmux runner that repeatedly arms the normal watcher from a persistent process, re-arms immediately after wake output, reports status from the derived `firstmate-watch:fm-watch-<home/state hash>` window, and stops that current-home runner plus its detached watcher.
A pull-based guard (`bin/fm-guard.sh`) warns through supervision tool output if the primary checkout is tangled, queued wakes are waiting to be drained, or tasks are in flight and watcher liveness is not proved by both a fresh beacon and a live `state/.watch.lock` for this same home/path.
A shared tool-path helper appends existing `$HOME/.nvm/versions/node/*/bin` and `$HOME/.local/bin` directories without moving them ahead of an explicit caller path.
Bootstrap, spawn, teardown, and the read-only supervision model use it before tool lookup, so SSH and other clean non-interactive sessions can find HOME-installed Axi tools consistently.
It combines GitHub commit status and check-runs when classifying PR CI, so Actions failures such as stale or failed check-runs are not treated as green just because legacy commit status is empty.
It also classifies a scout report as teardown work before PR or missing-worktree checks only when the latest status is `done:`, and a live `kind=secondmate` record as a persistent direct report unless the latest status is `done:`, `blocked:`, `needs-decision:`, `failed:`, or valid `paused: <reason>`. Before classifying a pause as `worker_external_wait`, it shares the bounded `FM_SUPERVISION_PAUSE_RECONCILE_SECS` budget across paused records to read current state; authoritative active or terminal state supersedes the pause.
The drain script calls that guard after emptying the queue, which avoids repeating the queued-wakes warning for records it just consumed while still warning on stale watcher liveness.
It leads with prominent bordered banners for the tangle and no-watcher cases so they cannot be skimmed past.

### Watcher truth table

Three watcher-adjacent commands prove different things:

The runtime backend is the session-provider layer below firstmate's scripts.
It owns task endpoint creation, bounded capture, text/key sends, current-path reads for spawn-time worktree discovery when the backend does not create the worktree itself, live-window fallback lookup, agent-process liveness probes where verified, and endpoint teardown.
`bin/fm-backend.sh` centralizes backend selection, `state/<id>.meta` helpers, selector resolution, and operation dispatch; `bin/backends/tmux.sh` is the verified reference adapter ([`docs/tmux-backend.md`](tmux-backend.md)), and `bin/backends/herdr.sh` (P2), `bin/backends/zellij.sh` (P3), `bin/backends/orca.sh` (P4), and `bin/backends/cmux.sh` (P5) are experimental task-spawn adapters.
New spawns select a backend from `--backend`, then `FM_BACKEND`, then local `config/backend`, then runtime auto-detection from `$TMUX`, `HERDR_ENV=1`, or cmux runtime signals, then default `tmux`.
Runtime auto-detection is innermost-first: `$TMUX` wins over `HERDR_ENV=1`, which wins over cmux's primary `CMUX_WORKSPACE_ID` marker and documented fallback signals; auto-detected herdr or cmux prints a one-time opt-out notice, auto-detected tmux stays silent, and zellij and orca are never auto-detected (only explicit selection).
Unknown backend names fail loudly.
For compatibility, default tmux tasks do not write `backend=tmux`; every reader treats a missing `backend=` field as `tmux`.
`fm-watch.sh` polls each window's backend for a busy state: tmux, zellij, orca, and cmux have no native primitive and always report unknown, preserving the original pane-tail-regex detection unchanged; herdr's `agent.get` semantic state (working/idle/done/blocked) is consulted first for stale detection, with unknown native states falling back to the same regex.
That poll loop is the default event source for backends with no native push events, so this stays an extraction of the abstraction rather than a watcher rewrite.
For capable herdr sessions, the same watcher replaces its terminal sleep with a bounded native event wait that immediately surfaces `blocked`; [herdr-backend.md](herdr-backend.md#native-paneagent_status_changed-push-escalation-immediate-blocked-wake) owns the mechanism, capability gates, and verification evidence.
The deeper session-start agent-process liveness probe is separate from that busy-state poll: tmux and herdr have verified classifiers for secondmate recovery, while zellij, Orca, and cmux currently report `unknown` rather than guess.
Herdr is experimental and can be selected explicitly or by runtime auto-detection: treehouse remains the worktree provider for it exactly as it is for tmux (herdr is a session provider only), and its full verification - the container shape decision, created-vs-adopted default-tab prune safety, restored-layout husk respawn idempotency, verified CLI facts, ANSI-preserved ghost/placeholder classification through the shared extractor, a verified small-`--lines` capture bug and its workaround, and known gaps - is recorded in `docs/herdr-backend.md`.
Herdr's durable default container shape is workspace-per-home plus tab-per-task: the primary home uses workspace label `firstmate`, secondmate homes use `2ndmate-<secondmate-id>`, and recovery/list-live scopes to the current `FM_HOME`'s workspace.
Its optional default-off presentation projection may place one clean new task in a disposable workspace without changing endpoint authority or lifecycle ownership; [`docs/herdr-backend.md`](herdr-backend.md#optional-disposable-single-task-presentation-spaces) owns that conditional design.
Zellij is experimental and selected only explicitly: treehouse remains its worktree provider too, and its full verification - the resolved "gaps to verify" list from the original design report, the unconditional-exit-0 CLI quirk and its mitigation, the focus-steal-on-new-tab finding, the home-scoped tab-title collision fix, and known gaps - is recorded in `docs/zellij-backend.md`.
Zellij's container shape is simpler than herdr's: one shared `firstmate` session, one tab per task, with no per-home workspace split; visible tab titles are scoped by the active home label plus a short hash of the resolved `FM_ROOT` path.
Orca is experimental and selected only explicitly: Orca owns both worktree and terminal lifecycle, records `orca_worktree_id=` and `terminal=`, and removes worktrees through `orca worktree rm` only after the usual firstmate teardown checks pass. Its current behavior and limitations are recorded in `docs/orca-backend.md`.
cmux is experimental, GUI-first, macOS-only, and can be selected explicitly or by runtime auto-detection from its primary `CMUX_WORKSPACE_ID` marker plus documented fallback signals: treehouse remains its worktree provider (cmux is a session provider only, like herdr/zellij), and its full verification - the socket access setup requirement with Automation mode recommended, the read-screen-fails-on-a-fresh-surface finding, the close-surface-refuses-on-the-last-surface finding, the source-verified runtime marker and fallback behavior, and known gaps - is recorded in `docs/cmux-backend.md`.
cmux's container shape is one workspace per task with one surface, no per-home container split; workspace titles are scoped by the active home label plus a short hash of the resolved `FM_ROOT` path, and `--secondmate` spawns are refused, mirroring Orca.
Codex App support is recorded in `docs/codex-app-backend.md`; it is not selectable as a runtime backend.

## Worktrees, not branches in your checkout

Crewmates never intentionally touch your project clone; [treehouse](https://github.com/kunchenguid/treehouse) pools clean worktrees so parallel tasks on one repo cannot collide.
For ship and scout work, `fm-spawn.sh` waits for `treehouse get` and then refuses to launch unless the pane resolves to a real git worktree root of the target project: its physical git common dir must match the target project and its HEAD must exist in that repo. A different git root is not an acceptable isolation result; the fresh window is killed and no task meta is recorded on refusal.
For tmux it creates each window as `fm-<id>`, disables automatic and application-driven renaming, restores and verifies that title, then targets every post-create operation by the immutable window ID rather than the mutable title. For Herdr it creates a readable `<kind> - <phrase> · <task-key>` tab in the home workspace, journals the full-id mapping before create, and targets the exact recorded `session:pane` endpoint.
If tmux does not return a valid ID or cannot retain the canonical title, spawn cleans up a uniquely identified newly created window and aborts before it sends a pane command; Herdr likewise aborts if it cannot return a task tab/pane target.

The firstmate repo has one extra exposure because it can dispatch crewmates to work on itself.
Its operating checkout (`FM_ROOT`) and the disposable crewmate worktrees are all linked git worktrees of the same repository, so the valid discriminator is branch state, not whether the checkout is linked.
The primary checkout is healthy on its default branch, and linked worktrees or secondmate homes are healthy at detached HEAD.
Only a named non-default branch checked out in `FM_ROOT` is a worktree tangle.

`fm-tangle-lib.sh` resolves the default branch from `origin/HEAD`, then local `main` or `master`, and classifies that named non-default primary branch as the tangle.
`fm-guard.sh` prints the repair command on the next fleet action, while `fm-bootstrap.sh` reports the same condition as a `TANGLE:` line at session start.
Ship briefs also tell the crewmate to verify `pwd -P` and `git rev-parse --show-toplevel` before creating `fm/<id>`, then stop with a blocked status if it landed in the primary checkout.

The callable `bin/fm-turnend-guard.sh` is the script-only "no turn ends blind" backstop for a primary firstmate checkout and a genuinely marked secondmate home. It blocks with exit 2 only when child metadata is in flight and this home's watcher cannot be proved live by matching PID identity, home/path lock fields, and a fresh beacon. Linked child crew/scout worktrees are exempt because their git-dir differs from git-common-dir and they do not carry the secondmate marker. JT deliberately does not install live PreToolUse or harness hooks for this guard in Phase B; callers must invoke it explicitly.

## No-mistakes gate authority boundary

Firstmate's own no-mistakes gate runs agents inside a checkout that also contains the fleet-captain identity in `AGENTS.md`, so gate execution needs an authority boundary separate from ordinary crewmate worktree isolation.
The tracked `.no-mistakes.yaml` sets `disable_project_settings: true`; no-mistakes honors that setting only from the trusted default-branch copy.
Independently, `fm-spawn.sh`, `fm-send.sh`, and `fm-teardown.sh` source `bin/fm-gate-refuse-lib.sh` and exit with status 3 before fleet mutation when the gate marker is set or the checkout matches the `.no-mistakes/repos/*.git` topology.
A normal primary checkout or crewmate worktree has neither signal and remains unaffected; the behavior runner preserves the gate marker, runs the real refusal suite in the gate checkout, and uses a temporary test-only lifecycle shim for the remaining normal-session fixtures.

## Two task shapes

Ship tasks change projects and ship by project mode (`no-mistakes`, `direct-PR`, or `local-only`); scout tasks investigate, plan, reproduce bugs, or audit, then leave a report at `data/<id>/report.md` and never push.
Matching JT Control Room ship tasks in `.openclaw` or `jt-control-room` get an extra `JT PR Intake Governor` block when their mode can open a PR (`no-mistakes` or `direct-PR`).
That brief gate makes the crewmate classify the problem, priority, authority, expected proof, verification gate, duplicate/superseded context, and runtime-data policy before implementation or PR creation.

## Dispatch profiles

Crewmate and scout dispatch can stay on the static crewmate harness resolved by `config/crew-harness`, or it can use local dispatch profiles in `config/crew-dispatch.json`.
The dispatch file is intentionally judgment-based: firstmate reads the natural-language rules at intake, chooses the best matching profile, and passes only concrete `--harness`, `--model`, and `--effort` axes to `fm-spawn.sh`.
The shell scripts validate the JSON shape and verified harness/effort combinations, but they do not parse task intent or match the natural-language rules.
Bootstrap surfaces either the active rule block or a concise invalid-config line at startup.
When the file exists, `fm-spawn.sh` refuses crewmate and scout launches without an explicit harness, so `config/crew-harness` is only automatic when no dispatch profile file is active.
Secondmate launches are exempt because they resolve the secondmate harness instead.
Unsupported effort values are still recorded in task meta when passed to `fm-spawn.sh`, but the launch template omits any effort flag that the selected harness does not accept.
That keeps spawn launch compatible across claude, codex, grok, pi, and opencode while preserving the requested profile for later audit.

## Optional CBM orientation

For allowlisted ship and scout projects, `fm-spawn.sh` can add optional codebase-memory-mcp (CBM) orientation to the generated brief and pass its cache, resource caps, binary directory, task id, and logged CLI path into the launch environment. It is for architecture maps, call chains, and multi-file navigation—not proof, runtime truth, or authority for an external action.

CBM is a soft dependency: a missing binary or empty index never prevents a spawn, and workers continue with normal search and read tools. Secondmate charters remain unchanged. A local `config/cbm-projects` file is a restrictive allowlist; without it, `.openclaw`, JT Control Room, and firstmate are eligible. `config/cbm.env` contains only simple `FM_CBM_*=value` settings.

Firstmate does not install CBM or change host MCP configuration. The captain may use `bin/fm-cbm-index.sh` to check status, list projects, or index an allowlisted target. The helper routes its CLI calls through `bin/fm-cbm-cli.sh` when available, recording durable usage in `$FM_HOME/data/cbm/usage.jsonl`; `bin/fm-cbm-usage.sh` summarizes, locates, or tails that log. The brief recommends the same wrapper and spawned ship/scout panes tag its entries with `FM_CBM_TASK_ID`. A captain may point a host MCP command at `bin/fm-cbm-mcp.sh` to count MCP process starts, but that optional wrapper does not count individual MCP tool calls. The helper indexes the JT Control Room application path rather than the `.openclaw` monorepo root.

## Optional secondmates

`data/secondmates.md` records persistent domain supervisors with natural-language scopes, project clone lists, and home paths.
`fm-home-seed.sh` provisions the isolated home, clones the listed PR-based projects into it, initializes newly cloned `no-mistakes` projects, copies the charter to `data/charter.md`, and `fm-spawn.sh --secondmate` launches it through the selected session-provider and shared status-file path as any direct report.
When seeded with `-`, the home is a durable treehouse lease under the secondmate id, so it survives with no live process and is not recycled by later `treehouse get` or pruning.
Retirement or seed rollback returns the leased home; normal restart/recovery keeps it leased.
Teardown retries only a transient Git `index.lock`/`File exists` failure from `treehouse return` before leaving the route and home intact for any remaining return failure, rather than hiding a still-held lease.
Seeding is transactional: if validation, cloning, initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.
`local-only` projects stay with the main first mate because they merge into the main local checkout instead of a remote-backed PR path.
The same project may appear in multiple secondmate homes when their scopes differ, such as issue triage versus feature development.
Secondmates are idle by default: after startup recovery reconciles only work already in their own home, an empty queue waits silently for routed tasks, and they never self-initiate surveys or audits.
`fm-send.sh` accepts a bare target only as a recorded `fm-<id>` from this home; it refuses other bare window names, which avoids ambiguous cross-home sends.
Bare `fm-send.sh fm-<id>` requests to a live `kind=secondmate` are prefixed with the terminal-safe U+2063 from-firstmate marker from `bin/fm-marker-lib.sh`; the transform is idempotent and preserves trailing newlines, so the secondmate returns terse answers through status lines and detailed answers through docs plus status pointers instead of replying only in its own chat.
Explicit `session:window` sends and direct human typing stay unmarked, so captain intervention in a secondmate pane remains conversational.
After seeding a secondmate, `fm-backlog-handoff.sh` moves each already-judged in-scope queued item block, including its indented context, from the main backlog into that secondmate home so the domain queue starts in the right place.
Idle secondmate panes are healthy; teardown is explicit, emits no main-backlog completion reminder, and refuses while the secondmate home has in-flight work unless the captain has approved discard with `--force`.
Historical PR metadata on the secondmate's parent record, such as a merged or closed seed PR, does not turn a live secondmate into ordinary PR-worker cleanup.
The backlog audit follows the same model: a `kind=secondmate` meta record registered in `data/secondmates.md` or the main backlog's `## Secondmate Backlogs` section is expected persistent inventory outside main `## In flight`, while unregistered secondmate meta is still reported as drift.

Secondmate homes stay on the same firstmate version as the primary checkout.
On main firstmate bootstrap, `fm-bootstrap.sh` fast-forwards each live secondmate home recorded in `state/*.meta` to the primary default-branch commit with no origin fetch.
The live signal is a `state/<id>.meta` record with `kind=secondmate`; `data/secondmates.md` only backfills `home=` for older or incomplete meta records.
A tracked-files fast-forward leaves the home's gitignored `data/`, `state/`, `config/`, `projects/`, `reports/`, `backups/`, and `.no-mistakes/` directories untouched.
Bootstrap separately propagates the primary's declared inheritable local config, currently `config/crew-dispatch.json`, `config/crew-harness`, and `config/backlog-backend`, into each validated live secondmate home so that secondmate's own crewmates, dispatch profiles, and backlog backend use the primary settings.
That propagation is primary-authoritative, re-runs even when tracked files were already current, mirrors absence when the primary clears the value, and deliberately never copies `config/secondmate-harness` or `config/secondmate-profile.json`.
Dirty, diverged, unsafe, or in-flight homes are reported and left unchanged by the tracked-file sync.
Only a running secondmate home that actually advanced and changed `AGENTS.md`, `bin/`, or `.agents/skills/` is listed for a re-read nudge.
`fm-config-push.sh` is the focused mid-session version of that same inheritance path: it discovers the same live secondmate homes, calls the same propagation helper, and reports per-home/per-item results without running the tracked-file fast-forward or sending reread nudges.
`fm-spawn.sh --secondmate` performs the same guarded local fast-forward before launch or recovery respawn; skipped syncs warn and the secondmate launches unchanged.
Secondmate spawn also propagates the same inheritable config before launch.

Secondmate agents can run on a different verified harness than crewmates.
`config/secondmate-harness` controls the primary's secondmate launch harness and falls back to `config/crew-harness`, then to the primary's own harness, when unset or `default`.
`config/secondmate-profile.json` controls only the primary's secondmate launch model and effort axes, so a primary can durably pair `config/secondmate-harness=codex` with `{"model":"gpt-5.6-sol","effort":"high"}` without relying on operator memory.
`fm-spawn.sh --secondmate` re-reads that profile on each launch or recovery respawn, while explicit `--model` and `--effort` still win for one spawn.
`config/crew-harness` remains the crewmate harness and is inherited into secondmate homes.
`config/crew-dispatch.json` is inherited too; secondmates use the same natural-language dispatch profiles when spawning their own crewmates.
`config/backlog-backend` is inherited too; absent or `tasks-axi` selects the default tasks-axi backlog backend, while `manual` forces hand-editing across the fleet.
`config/secondmate-harness` and `config/secondmate-profile.json` are primary-local and are not inherited into secondmate homes.

The `data/secondmates.md` line schema and the secondmate environment variables are documented in [configuration.md](configuration.md).

## Project modes are explicit

`data/projects.md` records each project's delivery mode and optional `+yolo` autonomy flag.
`no-mistakes` projects run the full validation pipeline, `direct-PR` projects open PRs without that pipeline, and `local-only` projects stay local until firstmate performs an approved fast-forward merge.
Every PR merge remains captain-gated, including for `+yolo` projects: after explicit approval, firstmate uses `FM_CAPTAIN_APPROVED_MERGE=1 bin/fm-pr-merge.sh <id> <full GitHub PR URL>` rather than invoking `gh-axi pr merge` directly.
The wrapper records PR metadata before merging, accepts only a qualified GitHub PR URL, derives its repository from that URL, defaults to squash, and refuses repository override arguments.
Teardown is fail-closed for ship worktrees: dirty worktrees refuse, and committed work must be landed before the worktree is returned.
Before failing a `treehouse return`, teardown retries only the transient Git `index.lock`/`File exists` case; all other return failures remain fail-closed.
Landed work is accepted when `HEAD` is reachable from any remote-tracking branch, when a merged PR's GitHub head contains the current local work, or when the worktree content is already present in the freshly fetched default branch.
PR-head containment covers an exact PR head match, a local `HEAD` that is an ancestor of the PR head, or unpushed local patches whose patch IDs appear in the PR head after no-mistakes replayed the branch.
GitHub lookup errors fall back to the content check and still refuse if that check is inconclusive.
Those PR-head and content checks let a squash-merged PR whose head branch was deleted tear down cleanly without using `--force`; `local-only` work instead tears down after the approved local default-branch merge or after the branch is pushed to any remote.

## Optional X mode

X mode is opt-in presence for the shared `@myfirstmate` bot.
A user enables it by putting `FMX_PAIRING_TOKEN` in the firstmate home's gitignored `.env`; `FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`.
That token is standing authorization for firstmate to answer public mentions and act autonomously on normal reversible mention requests.
Destructive, irreversible, or security-sensitive asks are escalated for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner, while parent-thread context may still include other public accounts.
On bootstrap, that token creates two local artifacts: `state/x-watch.check.sh`, which performs one bounded relay poll through `bin/fm-x-poll.sh`, and `config/x-mode.env`, which sets `FM_CHECK_INTERVAL=30` for watcher arms in that home.
Without the token, bootstrap removes those artifacts on opt-out and otherwise stays silent, so non-X users see no behavior change.
Pending mentions are stored as `state/x-inbox/<request_id>.json`; the `fmx-respond` agent-only skill drains that inbox, uses `in_reply_to` parent-tweet context for conversational continuity, classifies each mention as an actionable request, question, or pure acknowledgment, and submits public-safe replies through `bin/fm-x-reply.sh`.
When a reply has a real visual artifact, `--image <path>` attaches one local PNG, JPEG, GIF, WebP, BMP, or TIFF to the relay's optional `{media_type,data_base64}` image object.
The client checks `FMX_IMAGE_MAX_BYTES` before base64 encoding, defaulting to 5242880 bytes, so oversized local artifacts are rejected before the payload expands.
Actionable reversible requests run through firstmate's normal intake, backlog, dispatch, investigation, or ship lifecycle.
Work that completes in the answering turn gets one outcome reply.
Work that spawns a longer-running task gets an acknowledgement reply first; `bin/fm-x-link.sh` records `x_request=` and `x_request_ts=` in that task's `state/<id>.meta`, and the terminal completion wake later uses `bin/fm-x-followup.sh` to post one public-safe follow-up through the relay's `connector/followup` endpoint.
The follow-up helper forwards `--image <path>` to the same reply client when the completion outcome needs an image.
The follow-up is bounded by a local 24h window, clears the link after success or expiry, and is skipped for tasks that did not originate from an X mention.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh`, which calls the relay's `connector/dismiss` endpoint and posts no text, then the local inbox file is cleared.
Concise replies stay single unnumbered tweets; genuinely long replies are split by the client into bounded, numbered threads on word boundaries, with `texts` carrying the ordered chunks for the relay.
If an image is attached to a split reply, the relay puts it on the first/opener tweet only and leaves later chunks text-only.
For preview testing, `FMX_DRY_RUN` makes `fm-x-reply.sh` and `fm-x-dismiss.sh` skip the public post or dismiss call and record the would-be payload under `state/x-outbox/`, including `texts` when the reply would be a thread and an `endpoint` marker when the preview is a completion follow-up or dismiss, while the rest of the poll -> compose -> would-post loop still succeeds.
Attached images are recorded as compact `{media_type, bytes, source_path}` metadata in dry-run instead of base64 bytes.
The watcher, wake queue, and arm wrapper remain the shared foundations; X mode is layered on top through the existing check mechanism.

## Project memory belongs to projects

Durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a symlink.
Ship briefs prompt crewmates to create or update those files through the normal delivery path; `data/projects.md` stays a thin private registry.
The full ownership rule - what is project-intrinsic versus fleet-private, and how firstmate keeps the two apart without writing into project clones - is owned by firstmate's operating manual in [`AGENTS.md`](../AGENTS.md) (project memory ownership).

## Operational memory routing

`/stow` sweeps the current session for durable knowledge that only exists in conversation and routes each finding to the most specific disk home.
Captain preferences go to `data/captain.md`, fleet-local operational facts and gotchas go to `data/learnings.md`, project-intrinsic knowledge goes through normal crewmate delivery into that project's committed `AGENTS.md`, and task-scoped notes or undone next steps go to the backlog.
Generalizable firstmate knowledge goes to shared tracked docs through the normal PR pipeline; `/stow` deliberately never stores findings in skills.

## Local clones stay fresh

Bootstrap and PR-based teardown refresh remote-backed project clones when the clone is safe to move; `fm-fleet-sync.sh <name>` and `fm-fleet-sync.sh projects/<name>` resolve that one clone against the active home's projects directory without depending on the caller's working directory.
Clean default-branch clones fast-forward to `origin/<default>`, and a clean detached HEAD that holds no unique commits is re-attached to the default branch before the same fast-forward path runs.
Dirty clones, non-default branches, detached HEADs with unique commits, diverged defaults, and default branches checked out in another worktree are reported as `STUCK:` with their behind count and left untouched.
Fetches blocked by an orphaned `.git/packed-refs.lock` use bounded retries and remove the lock only when the shared staleness proof can prove it abandoned; the recovery emits a `recovered:` summary for bootstrap to relay.
Local-only projects, clones without an origin remote, and fetch failures remain benign skips.
The refresh also prunes local branches whose remote is gone and that no worktree still needs.

## Self-updates stay safe

`/updatefirstmate` fast-forwards the running firstmate repo and registered secondmate homes from `origin`, then re-reads updated instructions and nudges updated secondmates without touching project clones.
The update is fast-forward only: dirty, diverged, offline, and off-default targets are reported and left untouched.
The origin-based updater and the local secondmate sync share the same guarded fast-forward helper; only the origin mode fetches.
The mechanics are owned by the `/updatefirstmate` skill and firstmate's operating manual in [`AGENTS.md`](../AGENTS.md) (self-update).

## Restart-proof

Fleet state lives in the selected session provider (tmux by default or Herdr for marked tasks), no-mistakes run records, status event logs, local markdown under `data/` including `data/captain.md` and `data/learnings.md`, and persistent secondmate homes.
Use `/stow` before an intentional reset when the conversation may hold durable knowledge that has not yet been written to disk; after that, the next firstmate session can reconcile and carry on.

## Development notes

The current watcher reliability work combines always-on bash triage with a durable queue for actionable wakes, a race-proof singleton lock with reused-PID identity recovery, duplicate self-eviction, drain-time liveness assertion that requires both a live matching lock and fresh beacon, a self-verifying detached-watcher follower arm with one follower per home, and a home-scoped tmux session runner that immediately re-arms after wake output for harnesses without durable background tasks.
The presence-gated sub-supervisor (`bin/fm-supervise-daemon.sh`) provides walk-away supervision via the `/afk` skill while reusing the same shared wake classifier as the always-on watcher.
