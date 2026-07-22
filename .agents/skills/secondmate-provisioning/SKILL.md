---
name: secondmate-provisioning
description: Agent-only reference for persistent secondmate setup and retirement. Use when creating, seeding, validating, recovering, handing backlog to, pushing inherited config into, or retiring a secondmate home, or when editing data/secondmates.md. Covers home leases, transactional seeding, project clone restrictions, inherited config push, idle charter, handoff helper, and teardown safety.
user-invocable: false
---

# secondmate-provisioning

Use this reference before creating, seeding, validating, handing backlog to, recovering, pushing inherited config into, or retiring a persistent secondmate, and before editing `data/secondmates.md`.

Keep the always-inline routing rules in `AGENTS.md` authoritative: route by natural-language `scope:`, local-only projects stay with the main firstmate, and secondmates are idle by default.

## Routing table

`data/secondmates.md` has one line per persistent domain supervisor:

```markdown
- <id> - <charter summary> (home: <absolute-home-path>; scope: <natural-language responsibility>; projects: <project-a>, <project-b>; added <date>)
```

The `scope:` field is used during intake.
The `projects:` field is a non-exclusive clone list, not ownership.

## Charter and seed

Scaffold a secondmate charter with:

```sh
bin/fm-brief.sh <id> --secondmate <project>...
```

The scaffold writes a charter brief instead of a task brief.
Set `FM_SECONDMATE_CHARTER='<charter>'` to fill the charter text and `FM_SECONDMATE_SCOPE='<scope>'` when the routing scope differs.
If you scaffold without `FM_SECONDMATE_CHARTER`, replace the `{TASK}` placeholder before seeding.
Keep the charter focused on the persistent responsibility, available project clones, escalation back to the main firstmate status file, and the requests-from-main-firstmate contract.
The scaffold's definition of done encodes the idle-by-default contract: on startup the secondmate reconciles only its own in-flight work and then waits for routed tasks, never self-initiating a survey or audit.
Preserve that wording when filling the charter, including the marker rule that marked supervisor requests return through status or a doc pointer while unmarked captain messages stay conversational.

Provision the persistent home and registry entry after the charter is filled:

```sh
bin/fm-home-seed.sh <id> <home|-> <project>...
```

`-` durably leases a fresh firstmate worktree via `treehouse get --lease` under the secondmate id.
The lease survives with no live process and is never recycled by later `treehouse get` or `prune`.
The slot stays reserved across restarts until the lease is released.
Release happens only on explicit retirement or seed rollback, never on routine restart or recovery.

`bin/fm-home-seed.sh` copies the charter into the secondmate home as `data/charter.md`.
`bin/fm-spawn.sh --secondmate` launches it through the secondmate harness path, resolving `config/secondmate-harness` -> `config/crew-harness` -> the primary's own harness unless an explicit per-spawn harness override is passed.
Before launch, `fm-spawn.sh --secondmate` locally fast-forwards the home to the primary firstmate checkout's current default-branch commit when it is safe; dirty, diverged, or in-flight homes launch unchanged with a warning.
The locked session-start bootstrap sweep runs the same guarded fast-forward for every live secondmate home, discovered from `state/<id>.meta` records with `kind=secondmate` (`data/secondmates.md` only backfills `home=` for older records).
That no-fetch path is a purely local fast-forward of tracked files, never an origin fetch, and it never touches the gitignored operational dirs, so a secondmate's backlog, projects, and in-flight work are never disturbed; a linked worktree advances immediately, while a standalone clone that lacks the target receives firstmate updates through `/updatefirstmate`'s origin refresh.
The same launch and the same locked bootstrap sweep also propagate the primary's declared inherited local material: `config/crew-dispatch.json`, `config/crew-harness`, `config/backlog-backend`, `config/herdr-presentation-spaces`, and the one shared captain-preference file `data/captain-shared.md`.
Because these paths are gitignored, that propagation is a separate, primary-authoritative copy independent of the tracked-files fast-forward: it re-converges every live home whether or not its tracked files advanced, and it touches only the declared items.
Propagation failures warn without blocking secondmate launch or session-start continuation, and the destination keeps whatever safely validated state the helper left behind.
Inheritance copies the literal `config/crew-harness` file, so a secondmate's own crewmates use the primary's crewmate harness only when it names a concrete adapter such as `codex`; an unset or `default` value has nothing concrete to inherit, and the secondmate's own crewmates fall back to the secondmate's own or detected harness instead.
`config/secondmate-harness` is not inherited because it is only the primary's knob for launching secondmate agents.
`data/captain-shared.md` is main-authoritative in the primary home and read-only in secondmate homes.
Its primary file header must state that the file is main-authoritative, read-only in secondmate homes, must not be edited there, and that new captain-preference discoveries are routed to the main firstmate through marked status or a document pointer.
Every propagation point converges the secondmate copy to the primary bytes; when the primary file is absent, any existing secondmate copy is quarantined and removed so absence converges too.
The helper rejects unsafe directories, symlinked or nonordinary source or destination artifacts, and hardlinked destination files.
Between propagation runs, the secondmate copy is filesystem read-only; the helper may make its owned destination writable only around a guarded update and restores read-only mode on success, unchanged bytes, and recoverable failure paths.
Before replacing divergent secondmate bytes, the helper hash-compares source and destination, quarantines the secondmate-local version to a collision-safe private dated sibling file, and emits a `SECONDMATE_SYNC:` diagnostic naming the home and quarantine artifact.
Never copy any secondmate `data/captain-shared.md` back into the primary.
Keep each home's `data/captain.md` domain-local.
After first propagation to an existing home, trim that home's local `data/captain.md` by hand to domain-specific content plus pointers to `data/captain-shared.md`; do not automate or silently delete private content.
Keep every `data/learnings.md` fully local by captain decision; route fleet-general machinery facts into tracked documentation through the normal firstmate repo path rather than inventing shared learnings propagation.
No AGENTS.md reread nudge is needed at spawn or respawn because the agent reads instructions fresh on launch; only the bootstrap sweep's running-home instruction-surface advance needs that AGENTS.md re-read.
Bootstrap reports successful AGENTS.md re-read sends as `BOOTSTRAP_INFO:` and only emits `NUDGE_SECONDMATES:` when that send fails and needs retry.
A separate, literal-content config reread is required whenever inherited `config/*` material changes under an already-running secondmate.
After each successful allowlisted config write, both the locked bootstrap convergence path and mid-session `bin/fm-config-push.sh` use the shared propagation report to build one per-home generation-specific private instruction file from the validated destination post-write bytes for only the allowlisted config items that actually changed for that home (`config/crew-dispatch.json`, `config/crew-harness`, `config/backlog-backend`, `config/herdr-presentation-spaces`), in deterministic allowlist order.
Each changed path is printed with clear begin/end delimiters and the destination file's full exact new bytes unparsed, or the explicit token `ABSENT` when propagation removed the destination copy.
The instruction uses only minimal framing that these are defaults/rules and do not remove judgment; it never includes SHA values, selected profiles, parsed summaries, or any other generated interpretation.
`data/captain-shared.md` is not a config file and is never inlined into this instruction file or message.
Homes whose allowlisted config files were all unchanged receive no config-reread message when no retry is pending.
Different homes may receive different changed-file sets based on their pre-push destination bytes.
Delivery uses the existing routed secondmate path (`fm-send`) with only a single-line `CONFIG_REREAD: <absolute generation-specific instruction path>` pointer; a failed instruction publication retains the generated exact bytes in a bounded private retry queue when possible, legacy retry reports remain recoverable, a failed publication or retry-marker write retains the exact generation until it can be delivered, a failed send records a per-generation durable retry marker when possible, and all failures surface a concrete `CONFIG_REREAD:` diagnostic without claiming the live agent already re-read the values.
The propagation, generation publication, and pointer-delivery sequence holds one per-home inheritance lock, so concurrent mid-session pushes cannot deliver an older generation after a newer one.
A newly launched or relaunched secondmate already reads its files at launch, so its pending config-reread generations are discarded or quarantined after cleanup failure and it needs no redundant live-agent config nudge unless propagation changes files after launch.
Quarantined pre-relaunch generations are retained in bounded private history, and cleanup skips creating an empty quarantine generation.
Successfully delivered generations are retained only within a bounded per-home state history, while pending generations remain until delivery succeeds or a launch supersedes them.
These config values remain defaults and rules only; they must not harden `fm-spawn` to reject a deliberate runtime choice that differs from the configured defaults.
For already-live secondmates, use `bin/fm-config-push.sh` to push a mid-session inherited local-material change without running the tracked-file fast-forward.
It uses the same live-home discovery and propagation helper as bootstrap, reports each item as `pushed`, `unchanged`, `skipped`, or `error`, and follows the config-reread contract above for changed or pending generations.
`bin/fm-home-seed.sh` refuses to copy a missing or placeholder charter.

Direct seed without a preexisting brief requires `FM_SECONDMATE_CHARTER`.
Run `bin/fm-home-seed.sh validate` when checking registry integrity; it refuses duplicate ids, duplicate homes, and nested or overlapping homes.

Seeding is transactional.
If validation, cloning, no-mistakes initialization, or registry update fails, generated briefs, new homes, new project clones, and registry edits are rolled back.

Secondmate project lists may include `no-mistakes` and `direct-PR` projects only.
`local-only` projects stay with the main firstmate.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.

## Backlog handoff

When a secondmate is created for a domain, existing main-backlog items that fall under its scope should become its work instead of staying stranded in the main backlog.
Scope-matching is firstmate's judgment against the secondmate's natural-language scope, not a keyword rule.
Read `data/backlog.md`, pick queued items that fit the new scope, and move them with:

```sh
bin/fm-backlog-handoff.sh <secondmate-id> <item-key>...
```

After seeding, run this handoff for the new secondmate's in-scope queued items.
The helper resolves the secondmate home from `data/secondmates.md` and mechanically moves each named item from the main `data/backlog.md` into the secondmate home's `data/backlog.md`.
It preserves the line and its section, so the item is neither duplicated nor lost.
It refuses `## In flight` entries because active task ownership also lives in tmux and `state/`.
It is idempotent; an item already in the secondmate backlog is skipped.
It refuses any destination that is not a genuine seeded firstmate home with safe operational directories and a matching `.fm-secondmate-home` marker, so a move can never land in a project.
Do not hand off `local-only` items.

## Recovery

For `kind=secondmate` meta with no window, treat the secondmate as a dead persistent direct report and respawn it with:

```sh
bin/fm-spawn.sh <id> --secondmate
```

Use the recorded `home=` in meta.
If meta is missing but `data/secondmates.md` still registers the secondmate, respawn from the registry entry and its persistent on-disk home.
Respawn re-resolves the secondmate harness from current config, uses the same guarded pre-launch sync, and re-propagates inheritable config, so recovered secondmates converge to the primary firstmate version and local dispatch, crew-harness, and backlog-backend settings whenever their home can be cleanly fast-forwarded.
If the secondmate is already running and only inherited config changed, prefer `bin/fm-config-push.sh` over respawning.

Do not reconstruct a secondmate's whole tree from the main home.
The main firstmate reconciles only direct reports.
Each secondmate is a firstmate in its own home, so it runs recovery on startup and reconciles its own crewmates.
A secondmate's recovery reconciles only work that is already its own and then idles.
It never initiates a survey or audit during recovery.

## Retirement and teardown

A secondmate is persistent by default.
An empty queue is healthy and does not trigger teardown.
Run `bin/fm-teardown.sh <id>` for `kind=secondmate` only when the captain or main firstmate explicitly decides to retire that persistent supervisor.

The safety check is the secondmate's own home.
Teardown refuses while its `state/*.meta` contains in-flight work.
When safe, teardown kills the direct tmux window, removes the `data/secondmates.md` route, clears the main home metadata, and removes the retired secondmate home.
Removing a leased home releases its durable treehouse lease via `treehouse return`, so the pool slot is freed for reuse rather than left leased forever.
A plain-clone home with no pool slot is simply removed.
Teardown retries only a transient Git `index.lock`/`File exists` failure from `treehouse return`; if it still fails, teardown stops with state intact rather than raw-removing the directory and hiding a held lease.

With `--force`, teardown is the explicit discard path.
It kills child windows, discards child work and state inside the secondmate home, removes the route, releases the lease, and removes the retired secondmate home.
Never use `--force` unless the captain explicitly said to discard the work.
