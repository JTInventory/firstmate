# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each file also starts with a short header comment.

| Script                   | Description                                                                                                         |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| `fm-bootstrap.sh`        | Detect required toolchain and version problems, dispatch profile JSON errors or active-rule blocks, secondmate profile JSON errors, default backlog-backend status, primary-checkout `TANGLE:` problems, and actionable clone refresh outcomes; refresh project clones best-effort; locally sync live secondmate homes and propagate declared inheritable config; set up opt-in X mode; install tools only after consent |
| `fm-fleet-sync.sh`       | Fetch clones, fast-forward safe default-branch states, self-heal clean detached ancestor drift, report unsafe drift as `STUCK:`, and safely prune branches whose remote is gone |
| `fm-update.sh`           | Self-update the running firstmate repo and registered secondmate homes with fast-forward-only pulls from origin     |
| `fm-backlog-handoff.sh`  | Move already-judged in-scope queued backlog items from the main home into a seeded secondmate home                 |
| `fm-backlog-audit.sh`    | Read-only audit for backlog/state drift between `data/backlog.md`, `state/*.meta`, and local adoption signals      |
| `fm-brief.sh`            | Scaffold a ship brief with a worktree-isolation assertion, a report-only scout brief with `--scout`, or a secondmate charter with `--secondmate` |
| `fm-cognee-lookup-gate.sh` | Fail-closed local evidence gate for Cognee lookup modes; automatic lookup is disabled by default and manual verified lookup remains hint-only |
| `fm-ensure-agents-md.sh` | Ensure project `AGENTS.md` is the real memory file and `CLAUDE.md` symlinks to it                                   |
| `fm-guard.sh`            | Warn when the primary checkout is tangled, when queued wakes are pending, or when watcher liveness is not proved by a fresh beacon plus a live matching lock |
| `fm-home-seed.sh`        | Lease/provision a secondmate home transactionally, clone projects, initialize gates, and maintain `data/secondmates.md` |
| `fm-memory-lookup.sh`    | Manual read-only Cognee memory lookup for optional pre-dispatch hints; opens local source paths before brief attachment and stays non-blocking when unavailable |
| `fm-no-mistakes-pr-target-guard.sh` | Fail closed before no-mistakes test/push/PR work if local git or the no-mistakes gate would target `kunchenguid/firstmate` instead of `JTInventory/firstmate` |
| `fm-spawn.sh`            | Spawn one task, several `id=repo` pairs, or a persistent secondmate with `--secondmate`; accepts concrete `--harness`, `--model`, and `--effort` profile axes; ship/scout spawns require an explicit resolved harness when dispatch profiles are active and an isolated treehouse worktree, install per-harness turn-end signaling, and secondmate spawns resolve the secondmate harness, apply primary-local secondmate model/effort defaults, locally sync the home, and propagate declared inheritable config before launch |
| `fm-config-push.sh`      | Config-only mid-session push of declared inheritable local config into live secondmate homes; reports each item as pushed, unchanged, skipped, or error without fast-forwarding tracked files or nudging agents |
| `fm-project-mode.sh`     | Resolve a project's delivery mode and `+yolo` flag from `data/projects.md`                                          |
| `fm-route.sh`            | Classify a task into a deterministic route profile, harness, model, effort, reason, override, and risk flags without changing spawn behavior |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval                                           |
| `fm-review-diff.sh`      | Review a crewmate branch against the authoritative base, with optional `--stat` output                              |
| `fm-cognee-lookup.sh`    | Read-only Cognee lookup wrapper with dry-run fixtures and guarded live `POST /api/v1/search`; treats answers as hints and delegates source proof to local manifest/source verification |
| `fm-cognee-manifest-check.sh` | Validate TSV Cognee manifest rows and verify `SOURCE_ID`, `SOURCE_PATH`, or `SEED_FILE` answer references against reopened local files |
| `fm-cognee-session-cost-probe.sh` | Disabled metadata-only planner for approved future Cognee session/cost probes; validates GET-only endpoint templates and writes redacted local JSONL probe-plan events without network calls |
| `fm-cognee-telemetry-lib.sh` | Secret-safe JSONL telemetry helper for Cognee wrappers; records labels, timings, counts, cost classifications, and hashed identifiers without raw prompts, answers, headers, URLs, or secrets |
| `fm-cognee-verify-source.sh` | Local-only verifier for Cognee hint text against JSONL manifests; reopens referenced source files and emits source-verification JSON plus secret-safe telemetry |
| `fm-marker-lib.sh`       | Shared from-firstmate request marker and detector sourced by `fm-send.sh`, `fm-brief.sh`, and tests                 |
| `fm-watch-arm.sh`        | Verified per-home watcher re-arm; reports `started`, `healthy`, or `FAILED`; `--restart` relaunches only this home's watcher |
| `fm-watch-session.sh`    | Durable home-scoped tmux runner that loops through `fm-watch-arm.sh` for harness lanes without reliable tracked background tasks |
| `fm-watch.sh`            | Singleton-safe always-on watcher; absorbs no-verb signal and stale wakes only when the crew is provably working, queues and exits for actionable wakes, and reverts to daemon-owned one-shot behavior while `state/.afk` exists |
| `fm-supervise.sh`        | Read-only current-work checklist, plus `--json` / `--schema` for the shared `firstmate.supervision.v1` model |
| `fm-supervision-model.sh` | Sourceable read-only model library used by `fm-supervise.sh` and future display consumers |
| `fm-supervise-daemon.sh` | Presence-gated sub-supervisor for walk-away (`/afk`) supervision: wraps `fm-watch.sh`, uses the shared wake classifier, self-handles routine wakes in bash, and escalates only captain-relevant events as one verified, batched, single-line digest prefixed with a sentinel marker |
| `fm-crew-state.sh`       | Print one stable current-state line for a crew by reconciling its matching no-mistakes run-step, even when the pane has closed, with pane and status-log fallback |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification sourced by bootstrap and guard         |
| `fm-ff-lib.sh`           | Shared guarded fast-forward helper for `/updatefirstmate` origin pulls and no-fetch local secondmate syncs         |
| `fm-task-identity-lib.sh` | Shared branch/meta identity guard for helpers that must refuse when a ship task's worktree is not on `fm/<task-id>` |
| `fm-config-inherit-lib.sh` | Shared primary->secondmate inheritable-config propagation (a declared, extensible item list - currently `config/crew-dispatch.json`, `config/crew-harness`, and `config/backlog-backend`; excludes primary-local secondmate launch config) sourced by spawn, bootstrap, and config push |
| `fm-tasks-axi-lib.sh`    | Shared backlog-backend selector and `tasks-axi` compatibility probe sourced by bootstrap and teardown              |
| `fm-wake-drain.sh`       | Atomically drain queued watcher wakes before handling supervision work, then run the watcher-liveness guard         |
| `fm-wake-lib.sh`         | Shared durable wake queue and portable lock helpers sourced by the watcher, drain, arm, guard, and daemon          |
| `fm-classify-lib.sh`     | Shared captain-relevant wake classifier sourced by the watcher and daemon, plus the watcher's provably-working predicate |
| `fm-send.sh`             | Send one verified literal line (or `--key Escape`) to a direct-report window; exits non-zero on confirmed swallowed Enter; bare `kind=secondmate` targets are marked as from-firstmate; slash commands, codex `$...` skill invocations, and marked codex secondmate text get popup-settle before Enter; marked Codex secondmate text gets one delayed final Enter if generic retries leave it pending; text sends pause `FM_SEND_SETTLE` seconds after success |
| `fm-tmux-lib.sh`         | Shared tmux pane primitives for busy detection, dim-ghost-aware and border-aware composer detection, and verified submit retry |
| `fm-peek.sh`             | Print a bounded tail of a crewmate pane                                                                             |
| `fm-pr-check.sh`         | Record `pr=` and GitHub's `pr_head=` when available for a PR-ready task, then arm the watcher's merge poll          |
| `fm-promote.sh`          | Promote a scout task in place so it becomes a protected ship task                                                   |
| `fm-teardown.sh`         | Return a clean, landed ship worktree or retire/release a secondmate home; requires scout reports, checks child work, removes firstmate-owned hook artifacts, and prints the backend-aware backlog reminder |
| `fm-harness.sh`          | Detect the running harness; resolve the effective crewmate (`crew`) or secondmate-launch (`secondmate`) harness     |
| `fm-lock.sh`             | Per-home firstmate session lock                                                                                     |
| `fm-x-lib.sh`            | Shared X-mode `.env`, alternate env-file, relay, dry-run config, reply-thread splitting, outbound image payloads, and task-to-X-request meta-link helpers |
| `fm-x-poll.sh`           | Do one bounded X relay poll; without `FMX_PAIRING_TOKEN` it is silent, with a pending mention it stashes the full inbox JSON, including `in_reply_to`, and prints `x-mention <request_id>` |
| `fm-x-reply.sh`          | Post or dry-run preview a composed public-safe X answer or `--followup`, auto-splitting long text into `{request_id,text,texts}` threads and optionally attaching `--image <path>` to the opener; reads text from an argument, stdin, or `--text-file` |
| `fm-x-dismiss.sh`        | Dismiss or dry-run preview a skipped X mention without replying by sending `{request_id}` to the relay's `connector/dismiss` endpoint |
| `fm-x-link.sh`           | Link a spawned task to its originating X mention by recording `x_request=` and `x_request_ts=` in `state/<id>.meta` |
| `fm-x-followup.sh`       | Detect, post, and clear the single completion follow-up for an X-linked task, forwarding optional `--image <path>`, enforcing the local 24h window, and retrying only when the relay post fails |

Cognee policy lives in [cognee-policy.md](cognee-policy.md). Automatic lookup needs per-wrapper-call cost evidence: `FM_COGNEE_GATE_COST_USAGE_EVIDENCE=per_wrapper_call`. Current `session_window_only` evidence is accepted only as trial monitoring evidence and still blocks automatic promotion because there is no safe per-wrapper-call cost/request/session/QA id bridge. Manual verified lookup remains read-only, hint-only, fail-closed, and local-source-verified.

The official docs now show raw data readback and session/model cost surfaces. That does not satisfy Firstmate's production gates by itself: raw retention/source-authority guarantees and safe per-wrapper-call cost correlation remain unproven.
