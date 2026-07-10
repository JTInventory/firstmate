# Configuration

The files and environment variables you set to operate firstmate.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
When the default backend is selected and compatible `tasks-axi` is on `PATH`, firstmate uses its verbs for routine backlog mutations and keeps secondmate transfers behind `fm-backlog-handoff.sh` validation.
Compatible means the shared bootstrap probe accepts `tasks-axi --version` as 0.1.1 or newer.
If the default backend is selected but `tasks-axi` is missing or incompatible, bootstrap suggests `npm install -g tasks-axi` through the normal consent flow and falls back to manual editing until it is installed.
Set the local, gitignored `config/backlog-backend` file to `manual` to force manual backlog editing and suppress the install suggestion.
Absent or `tasks-axi` selects the default tasks-axi backend.
The file format is unchanged in both modes; tasks-axi and manual edits produce the same `## In flight`, `## Queued`, and `## Done` task sections.
Homes may also carry a `## Secondmate Backlogs` inventory section with `- <secondmate-id> ...` lines for persistent secondmates; `fm-backlog-audit.sh` treats those ids, plus ids in `data/secondmates.md`, as registered secondmate inventory rather than ordinary In flight work.

## Gate defaults (.no-mistakes.yaml)

The tracked `.no-mistakes.yaml` keeps test evidence outside the repo and defines `commands.test` so no-mistakes first runs `bin/fm-no-mistakes-pr-target-guard.sh`, then runs firstmate's bash behavior suite directly.
The guard fails closed if direct push resolution, the no-mistakes gate, or no-mistakes status would target `kunchenguid/firstmate`; this captain-owned lane must target `JTInventory/firstmate`.
It does not treat an upstream-owner `origin` fetch URL as a PR target by itself when controlled-fork proof shows delivery through `fork/main`, no-mistakes status, the no-mistakes gate, and a safe resolved `origin` push target.
After the guard passes, that command requires `tmux` on `PATH`, prints `tmux -V`, runs every `tests/*.test.sh` with `bash`, and fails if any script exits non-zero.
It intentionally mirrors the behavior-test baseline in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) instead of delegating the test step to an agent.

## Captain preferences (data/captain.md)

Personal preferences for one captain's fleet live locally in `data/captain.md`; it is gitignored and read after `data/projects.md` and optional `data/secondmates.md` during bootstrap.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live locally in `data/learnings.md`; it is gitignored and read right after `data/captain.md` during bootstrap.
The file is created lazily on first learning and follows the same dated, evidence-backed, curated style as `data/captain.md`: rewrite or prune stale entries instead of appending forever.

## Secondmate routes (data/secondmates.md)

Persistent secondmate routes live locally in `data/secondmates.md`.
Each line records the secondmate id, charter summary, absolute home path, natural-language scope, project clone list, and added date; `fm-home-seed.sh validate` refuses duplicate ids, duplicate homes, and nested or overlapping homes.
The main first mate routes by reading those scopes with judgment; the project list is provisioning data, not exclusive ownership.
`fm-backlog-audit.sh` also uses these ids as registered persistent inventory, so a live `kind=secondmate` meta record does not have to appear under the main `## In flight` section.
Use `fm-home-seed.sh <id> - <project>...` to lease a fresh firstmate worktree for the secondmate home.
The lease is held under the secondmate id until explicit retirement or seed rollback returns it, so normal restarts do not free or recycle the home.
Teardown of a leased home fails closed if `treehouse return` cannot release the lease; plain-clone homes with no treehouse pool slot are removed directly.
Secondmate routes cover `no-mistakes` and `direct-PR` projects; `local-only` projects remain main-firstmate work.
For `no-mistakes` projects, seeding initializes only projects newly cloned into a secondmate home and refuses to mutate a preexisting clone that is not already initialized.
After creating a secondmate, move existing main-backlog items that you have judged in-scope with `fm-backlog-handoff.sh <secondmate-id> <item-key>...`; it is idempotent, moves each selected item's indented continuation context with it, and refuses in-flight items or non-secondmate homes.
Set `FM_SECONDMATE_CHARTER` to seed from inline charter text when no filled charter brief exists; set `FM_SECONDMATE_SCOPE` when the routing scope should differ from the charter text.

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance.
When it is unset, the repo root is the home; when it is set, scripts still run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`.
`FM_ROOT_OVERRIDE` overrides the firstmate repo root used by scripts, including the primary checkout watched by the worktree-tangle guard.
When `FM_HOME` is unset, it also behaves as the old whole-root override.
`FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` override individual operational directories for tests and specialized harness setup.

## Harness support

claude, codex, opencode, pi, and grok are all empirically verified; new harnesses get verified through a supervised trial task before joining the set.
The verified adapter knowledge - busy signatures, interrupt and exit commands, skill-invocation syntax, and per-harness quirks - lives in [`.agents/skills/harness-adapters/SKILL.md`](../.agents/skills/harness-adapters/SKILL.md).
Launch mechanics, including the verified command templates, live in [`bin/fm-spawn.sh`](../bin/fm-spawn.sh).
`config/crew-harness` is a local, gitignored file containing one adapter name for crewmate and scout launches.
When it is absent or contains `default`, crewmates mirror the firstmate's own harness.
`config/secondmate-harness` is a separate local, gitignored file containing the adapter the primary uses to launch secondmate agents.
When it is absent or contains `default`, secondmate launch falls back through `config/crew-harness` and then the primary's own harness, preserving the previous behavior.
`config/secondmate-profile.json` is the separate local, gitignored model/effort profile for those primary-to-secondmate launches, for example `{"model":"gpt-5.6-sol","effort":"high"}`.
It never chooses the harness; `config/secondmate-harness` keeps that job.
Missing file, omitted keys, and explicit `"default"` values preserve `model=default` and `effort=default`.
Explicit `--model` or `--effort` on `fm-spawn.sh --secondmate` overrides the file for that one launch.
An explicit harness argument to `fm-spawn.sh` still overrides either harness config file for that spawn only.
When `config/crew-dispatch.json` exists, crewmate and scout spawns require an explicit resolved harness instead of automatically falling back to `config/crew-harness`.
When that file is absent, `fm-spawn.sh` uses the deterministic route's model and effort for crewmate and scout launches if the active crew harness still matches the routed harness.
The primary propagates `config/crew-dispatch.json`, `config/crew-harness`, and `config/backlog-backend` into secondmate homes at secondmate spawn, during the bootstrap secondmate sweep, and during explicit `bin/fm-config-push.sh` runs, so a secondmate's own crewmates, dispatch profiles, and backlog backend use the primary values.
`config/secondmate-harness` is not inherited because secondmates do not launch secondmates.
`config/secondmate-profile.json` is not inherited either; use inherited `config/crew-dispatch.json` for a secondmate home's own future crewmate and scout defaults.
For grok, `fm-spawn.sh` installs one firstmate-owned global turn-end hook under `$GROK_HOME/hooks/`, or `~/.grok/hooks/` when `GROK_HOME` is unset, and drops a per-task `.fm-grok-turnend` pointer in the worktree, with teardown removing the task token and pointer.

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional local, gitignored file containing natural-language rules that firstmate reads before dispatching a crewmate or scout.
The shell scripts do not match those rules; firstmate chooses the best profile with judgment and passes only concrete `--harness`, `--model`, and `--effort` flags to `fm-spawn.sh`.
When the file exists, `fm-spawn.sh` enforces that contract by refusing crewmate and scout spawns that lack an explicit harness (`--harness`, a positional adapter, or a raw launch command).
Batch spawns satisfy the same requirement with a shared `--harness`.
Secondmate spawns are exempt and still resolve through `config/secondmate-harness`, then apply any primary-local `config/secondmate-profile.json` model or effort defaults.
Each rule has `when`, `use.harness`, optional `use.model`, optional `use.effort`, and optional `why`; an optional `default` profile uses the same `use` shape without `when`.
See [`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) for a starting point to copy into local `config/crew-dispatch.json`.
The recommended Codex family policy is: keep MiniMax for very simple token-saving work, use `gpt-5.6-luna` for small Codex-shaped tasks, use `gpt-5.6-terra` as the everyday default, and use `gpt-5.6-sol` for high-risk or critical work.
When the file exists, bootstrap validates it with `jq`.
Valid files produce a `CREW_DISPATCH: active config/crew-dispatch.json` block that lists each rule as `rule: <when> -> <harness[/model[/effort]]>` and prints `default:` when present.
Malformed JSON, an unverified harness, or an effort value unsupported by that harness is reported as `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`; missing `jq` is reported through the normal `MISSING: jq` install-consent flow.
If no dispatch rule fits, firstmate uses the dispatch profile `default` when present, then falls back to `config/crew-harness`.
Because the spawn backstop is gated by file presence, any fallback path after a missing match, validation error, or missing `jq` still passes a resolved harness explicitly until the file is fixed or removed.
Secondmate homes inherit this file from the primary, so a secondmate's own crewmates apply the same dispatch profile behavior.

## Toolchain

On first launch the first mate detects what its required toolchain is missing or too old (tmux, node, gh with `gh pr checks --json` support, treehouse with durable lease support, no-mistakes v1.31.2 or newer, gh-axi, chrome-devtools-axi, lavish-axi), lists it with the exact install commands, and installs only after you say go.
Bootstrap, spawn, teardown, and read-only supervision normalize existing `$HOME/.nvm/versions/node/*/bin` and `$HOME/.local/bin` directories before looking up Axi tools. This covers clean non-interactive SSH shells without overriding an explicit caller PATH.
Set `FM_TOOL_PATH_HOME` only when those shared lookups must use a home directory other than `HOME`, such as in a specialized shell or test fixture.
When `config/crew-dispatch.json` or `config/secondmate-profile.json` exists, bootstrap also requires `jq` for JSON validation.
Malformed `config/secondmate-profile.json`, a non-object top level, non-string axes, an empty model, or an effort outside `default|low|medium|high|xhigh|max` is reported as `SECONDMATE_PROFILE: invalid config/secondmate-profile.json - ...`.
When X mode is opted in, bootstrap also requires `curl` and `jq` before arming the relay poll shim.
Unless `config/backlog-backend=manual`, bootstrap treats `tasks-axi` as the default backlog backend.
If compatible `tasks-axi` is already on `PATH`, bootstrap records it as `TASKS_AXI: available` and firstmate uses its verbs for routine backlog mutations.
When it is absent or incompatible, bootstrap reports `MISSING: tasks-axi (install: npm install -g tasks-axi)` and firstmate keeps hand-editing `data/backlog.md` until installation is approved and completed.
When `config/backlog-backend=manual`, bootstrap hand-edits and does not suggest installing `tasks-axi`.
Bootstrap also reports a `TANGLE:` line when `FM_ROOT` is on a named non-default branch; follow the printed checkout remediation rather than treating it as an installable tool problem.
Bootstrap also runs a best-effort project clone refresh through `fm-fleet-sync.sh`.
It emits `FLEET_SYNC:` for skipped refreshes that may matter, recovered self-heals, and `STUCK:` alarms; local-only and no-origin skips stay silent.
Bootstrap also runs the guarded local secondmate sync for recorded live secondmate homes, then propagates declared inheritable local config into each validated live home.
It emits `SECONDMATE_SYNC:` only when a home was skipped for an actionable sync reason or config inheritance failed, and `NUDGE_SECONDMATES:` only when a running home advanced and its instruction surface changed.
For a mid-session inherited config edit where tracked-file sync and reread nudges are not needed, run `bin/fm-config-push.sh`.
It uses the same live secondmate discovery and propagation helper as bootstrap, prints each live home's `crew-dispatch.json`, `crew-harness`, and `backlog-backend` result as `pushed`, `unchanged`, `skipped`, or `error`, and exits non-zero only for real propagation errors.
That live discovery starts from `state/*.meta` records with `kind=secondmate`; `data/secondmates.md` only backfills `home=` for older or incomplete meta records.
Skipped items, such as a destination checkout that does not yet gitignore the item, are visible warnings but not hard failures.

## X mode (.env)

X mode lets a firstmate instance answer public `@myfirstmate` mentions and act on normal reversible mention requests through firstmate's normal lifecycle.
It is off unless the firstmate home's gitignored `.env` contains a non-empty `FMX_PAIRING_TOKEN`.
The pairing token both identifies the relay tenant and records opt-in consent for autonomous public replies and eligible lifecycle actions.
Destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner/captain, while parent-thread context may still include other public accounts.
`FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`, mainly for developers pointing at a local relay.
For direct client invocations, environment values override `.env`; bootstrap activation still keys off `.env` presence so watcher artifacts are explicit local opt-in state.
`FMX_ENV_FILE` can point direct poll/reply client invocations at another `.env`-style file, but it does not change bootstrap activation.

Bootstrap turns the token into local generated state.
It writes `state/x-watch.check.sh`, a check shim that runs `bin/fm-x-poll.sh`, and `config/x-mode.env`, which exports `FM_CHECK_INTERVAL=30` for watcher arms in that home.
When the token is removed or empty, the next bootstrap removes those artifacts.
Steady-state off is silent and writes nothing.

`bin/fm-x-poll.sh` calls `GET /connector/poll` with `Authorization: Bearer <FMX_PAIRING_TOKEN>`.
HTTP 204 is silent.
A pending mention with non-empty `text` is stored at `state/x-inbox/<request_id>.json` and wakes firstmate with `x-mention <request_id>`.
The full relay object is preserved, including `in_reply_to: {author_handle, text}` when the mention is a reply in a conversation or `null` for fresh mentions.
The `fmx-respond` skill decides whether the stashed mention is an actionable request, a question, or a pure acknowledgment.
Actionable reversible requests are run through intake, backlog, dispatch, investigation, or ship flow as appropriate.
If the work completes in that turn, the public reply reports the outcome.
If the request spawns a longer-running task, firstmate posts an acknowledgement through the normal answer endpoint, links the task to the mention with `bin/fm-x-link.sh`, and posts one completion follow-up when the task reaches a terminal state.
Pure acknowledgments or mentions with nothing to answer are dismissed through `bin/fm-x-dismiss.sh` before the local inbox file is cleared.
Dismiss sends `POST /connector/dismiss` with `{request_id}`, posts no text, and tells the relay to drop the request instead of re-offering it or falling back to an offline auto-reply.
Relay auth or config problems are reported once as `x-mode-error ...` until recovery.
Live replies are posted by `bin/fm-x-reply.sh`, which sends `POST /connector/answer` with `{request_id,text}` for one-tweet replies.
Add `--image <path>` to attach one local PNG, JPEG, GIF, WebP, BMP, or TIFF as `{media_type,data_base64}` in the relay's optional `image` object.
The client rejects image files larger than `FMX_IMAGE_MAX_BYTES` before base64 encoding; the default is 5242880 bytes.
Completion follow-ups use `bin/fm-x-followup.sh`, which checks the local `state/<id>.meta` link and sends the same payload shape through `POST /connector/followup` by calling `bin/fm-x-reply.sh --followup`.
Add `--image <path>` there too when the completion follow-up should carry an image.
The follow-up helper clears the link after a successful post or after the 24h window has elapsed; a failed post leaves the link in place so it can be retried.
If the reply exceeds `FMX_X_REPLY_MAX_CHARS`, the client splits it into a numbered thread on word boundaries and sends `{request_id,text,texts}`, where `texts` is the ordered chunk list and `text` remains the first chunk for older relays.
When `--image <path>` is present on a split reply, the image rides the first/opener tweet and later chunks stay text-only.
`FMX_X_REPLY_MAX_CHARS` defaults to 280 and clamps to a minimum of 50; `FMX_X_THREAD_MAX` defaults to 25 and caps oversized replies, marking the last retained tweet with an ellipsis when truncation is needed.
`FMX_FOLLOWUP_MAX_AGE_SECS` defaults to 86400 and controls the local completion follow-up window.

Set `FMX_DRY_RUN` to preview replies and dismissals without posting.
Truthy means anything except unset, empty, `0`, `false`, `no`, or `off`; an explicit environment value wins over `.env`.
In dry-run, `fm-x-reply.sh` records the would-be payload to `state/x-outbox/<request_id>.json`, including `texts` for a thread and an `endpoint` marker for follow-up previews, prints a `DRY RUN` summary to stderr, echoes the `request_id`, and exits 0.
When an image is attached, the dry-run record uses compact `{media_type, bytes, source_path}` metadata instead of writing the base64 bytes.
In dry-run, `fm-x-dismiss.sh` records `{request_id, endpoint:"dismiss"}` to the same outbox path, prints a `DRY RUN` summary, echoes the `request_id`, and exits 0.
The live answer and follow-up bodies intentionally stay the same shape, including optional `image`; the relay distinguishes them by endpoint, and dismiss stays `{request_id}`.
These paths need `jq` to build the JSON payload, but they run before token and network checks, so they need neither `FMX_PAIRING_TOKEN` nor `curl`.

## Cognee trial memory

Cognee is trial-only memory context for Firstmate.
It is not a source of truth, durable archive, proof system, or action authority; [cognee-policy.md](cognee-policy.md) owns the operating policy.

Manual lookup is configured with `FM_COGNEE_LOOKUP_CMD`, `FM_COGNEE_MANIFEST`, and the already-exported Cognee read-only credentials.
`fm-memory-lookup.sh` runs the backend only when invoked by hand, treats output as a hint, and attaches only local source paths it can reopen.
Without `FM_COGNEE_LOOKUP_CMD`, it exits 0 with a memory-unavailable note so dispatch continues without Cognee.

Live lookup through `fm-cognee-lookup.sh` requires `COGNEE_BASE_URL`, `COGNEE_API_KEY`, a dataset selector (`COGNEE_DATASET_ID` or `FM_COGNEE_DATASET_ALIAS`), and a manifest path (`FM_COGNEE_MANIFEST` or `--manifest`).
`FM_COGNEE_ENV_FILE` may load only the allowlisted Cognee names from an env-style file; malformed or unreadable files fail closed without shell-sourcing the file.
The live wrapper calls only `POST /api/v1/search`, records secret-safe telemetry, and still delegates proof to local manifest/source verification.

Automatic lookup remains disabled unless `FM_COGNEE_AUTO_LOOKUP=1` and the local evidence under `FM_COGNEE_EVIDENCE_ROOT` proves every gate marker, including `FM_COGNEE_GATE_COST_USAGE_EVIDENCE=per_wrapper_call` and `FM_COGNEE_GATE_RAW_DURABILITY_SOURCE_AUTHORITY=pass`.
`session_window_only` cost evidence is accepted only as trial monitoring evidence and still blocks automatic promotion.

## Environment variables

Runtime tuning via environment variables (defaults shown):

```sh
FM_HOME=                 # optional operational home; unset means this repo root
FM_ROOT_OVERRIDE=        # override firstmate repo root and tangle-guard target; also legacy whole-root override when FM_HOME is unset
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_TOOL_PATH_HOME=       # optional HOME override for shared NVM and user-local tool discovery
FM_POLL=15              # seconds between watcher poll cycles
FM_HEARTBEAT=600        # base seconds between heartbeat scans; no-change heartbeats are absorbed while idle
FM_HEARTBEAT_MAX=7200   # heartbeat backoff cap
FM_CHECK_INTERVAL=300   # seconds between slow checks (merge polls or the X-mode poll shim)
FM_CHECK_TIMEOUT=30     # seconds allowed per slow check script
FM_CAPTAIN_APPROVED_MERGE=1 # one-command marker required by fm-pr-merge.sh after explicit captain approval; do not set as standing configuration
FM_CREW_STATE_NM_TIMEOUT=10   # seconds allowed per no-mistakes query inside fm-crew-state.sh
FM_CREW_STATE_BIN=bin/fm-crew-state.sh   # test override for the current-state reader used by provably-working watcher triage
FMX_PAIRING_TOKEN=      # X mode pairing token; .env opt-in authorizes replies and eligible lifecycle actions
FMX_RELAY_URL=https://myfirstmate.io   # optional X relay override, mainly for local relay development
FMX_ENV_FILE=           # optional alternate .env file for direct X client invocations; bootstrap still checks $FM_HOME/.env
FMX_DRY_RUN=            # truthy previews X replies and dismissals to state/x-outbox/ without posting or requiring a token
FMX_X_REPLY_MAX_CHARS=280   # X reply per-tweet split budget; values below 50 clamp to 50
FMX_X_THREAD_MAX=25     # maximum tweets in one auto-split X reply thread
FMX_IMAGE_MAX_BYTES=5242880 # maximum outbound image attachment size before base64 encoding
FMX_FOLLOWUP_MAX_AGE_SECS=86400   # local window for posting one X completion follow-up
FMX_NOW_OVERRIDE=       # test-only epoch override for X task-link and follow-up window checks
FM_LOCK_STALE_AFTER=2   # seconds before dead-pid or mismatched-identity lock records can be reclaimed; mid-acquire locks keep at least 2s grace
FM_GUARD_GRACE=300      # seconds before guard warnings and arm health checks treat a watcher beacon as stale
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher before reporting FAILED
FM_WATCHER_STALE_GRACE=300   # defaults to FM_GUARD_GRACE; seconds a live watcher lock may have a stale beacon before re-arm errors
FM_WATCH_SESSION_REARM_DELAY=1   # seconds watch-session waits after failed arms or quiet healthy no-op arms; wake output re-arms immediately
FM_WATCH_SESSION_RETRY_DELAY=    # legacy alias for FM_WATCH_SESSION_REARM_DELAY
FM_WATCH_SESSION_AFK_DELAY=15    # seconds watch-session sleeps while the AFK daemon owns supervision
FM_WATCH_SESSION_TMUX_SESSION=firstmate-watch   # tmux session name for durable watch-session runner windows
FM_WATCH_SESSION_TMUX_WINDOW=   # optional tmux window name; default is fm-watch-<home/state hash>
FM_SIGNAL_GRACE=30      # seconds to coalesce nearby status and turn-end signals into one wake
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # status regex that makes watcher and daemon signal/stale/scan output captain-relevant
FM_STALE_ESCALATE_SECS=240         # idle seconds before a provably-working non-terminal stale pane escalates; not-provably-working stale wakes surface immediately
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the watcher's absorbed-wake debug log
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=20   # seconds allowed for bootstrap's best-effort clone refresh
FM_FLEET_PRUNE=1        # set to 0 to skip pruning local branches whose upstream is gone
FM_BUSY_REGEX='esc (to )?interrupt|Working\.\.\.|Ctrl\+c:cancel'   # busy-pane signatures, shared by watcher and tmux helper
FM_COMPOSER_IDLE_RE=    # optional empty-composer regex, applied after dim-ghost and border stripping
GROK_HOME=              # optional Grok config home for firstmate's global grok turn-end hook; defaults to ~/.grok
FM_SEND_RETRIES=3       # fm-send Enter-retry attempts after typing the line once
FM_SEND_SLEEP=0.4       # seconds between fm-send submit checks
FM_SEND_SETTLE=1        # seconds fm-send waits after a successful text submit; 0 disables
# read-only supervision view (bin/fm-supervise.sh)
FM_SUPERVISE_TREEHOUSE_TIMEOUT=5   # seconds allowed per treehouse status read
FM_SUPERVISE_GH_TIMEOUT=5          # seconds allowed per gh-axi GitHub read
# bootstrap, spawn, teardown, and fm-supervise append existing HOME-local NVM and .local/bin entries when absent
# Cognee trial memory and local verification
FM_COGNEE_LOOKUP_CMD=      # executable backend path for manual memory lookup, usually bin/fm-cognee-lookup.sh
FM_MEMORY_LOOKUP_MAX_HINT_LINES=40   # maximum hint lines printed from a manual memory lookup
COGNEE_BASE_URL=           # Cognee Cloud/API base URL for explicit live lookup
COGNEE_API_KEY=            # Cognee API key for explicit live lookup
COGNEE_DATASET_ID=         # UUID dataset selector; logged only as a sha256 hash
FM_COGNEE_DATASET_ALIAS=   # alternate dataset selector when COGNEE_DATASET_ID is absent
FM_COGNEE_MANIFEST=        # local manifest used for Cognee answer/source verification
FM_COGNEE_ENV_FILE=        # optional env-style file; only allowlisted Cognee names are loaded
FM_COGNEE_SEARCH_TYPE=RAG_COMPLETION   # searchType sent to POST /api/v1/search
FM_COGNEE_TOP_K=8          # topK sent to POST /api/v1/search
FM_COGNEE_MAX_ATTEMPTS=3   # live lookup attempts before fail-closed exit
FM_COGNEE_TIMEOUT_MS=30000 # connect and request timeout budget for live lookup
FM_COGNEE_TELEMETRY_FILE=  # default: $FM_HOME/data/cognee/telemetry.jsonl
FM_COGNEE_EVIDENCE_ROOT=/root/firstmate/data   # local evidence root for fm-cognee-lookup-gate.sh
FM_COGNEE_AUTO_LOOKUP=0    # must be 1 plus all evidence markers before automatic lookup is allowed
UA_NODE_BIN=/root/.nvm/versions/node/v22.22.2/bin/node # Node runtime for JT helpers
JT_REPO=/root/.openclaw/workspace/projects/active/JT-Control-Room # graph source repo for JT helpers
# sub-supervisor (bin/fm-supervise-daemon.sh); presence-gated via /afk
FM_SUPERVISOR_TARGET=firstmate:0   # supervisor tmux target (override; auto-discovers from $TMUX_PANE)
FM_INJECT_SKIP=heartbeat           # |-prefixes force-self-handled bypassing classification; empty disables
FM_ESCALATE_BATCH_SECS=90          # buffer window for batched escalation digests; 0 = flush immediately
FM_MAX_DEFER_SECS=300              # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_INJECT_FAIL_SLEEP=30            # seconds to back off when the supervisor pane is unavailable
FM_INJECT_CONFIRM_RETRIES=3        # daemon Enter-retry attempts after typing a digest once
FM_INJECT_CONFIRM_SLEEP=0.5        # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300         # cadence of the catch-all status scan for missed captain verbs
FM_HOUSEKEEPING_TICK=15            # seconds between batch-flush, stale-recheck, and scan passes
FM_CRASH_THRESHOLD=10              # watcher crashes allowed inside FM_CRASH_WINDOW before daemon backoff
FM_CRASH_WINDOW=60                 # seconds in the crash-loop detection window
FM_CRASH_BACKOFF=60                # seconds to wait after crossing the crash threshold
FM_CRASH_NORMAL_SLEEP=5            # seconds to wait after an isolated watcher crash
FM_LOG_MAX_BYTES=1048576           # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000             # daemon log lines kept when trimming
```
