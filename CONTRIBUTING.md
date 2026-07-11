# Contributing

Thanks for wanting to contribute.
One rule up front:

**Human-authored pull requests targeting `main` must be raised through [`no-mistakes`](https://github.com/kunchenguid/no-mistakes).**
We require this to reduce the maintainer's burden of reviewing and merging contributions.

`no-mistakes` puts a local git proxy in front of your real remote.
Pushing through it runs an AI-driven review/test/lint pipeline in an isolated worktree, forwards the push upstream only after every check passes, and opens a clean PR automatically.

A GitHub Actions check (`Require no-mistakes`) runs on PRs targeting `main` and fails if the body is missing the deterministic signature that no-mistakes writes.
Dependency bots are exempt so their automation keeps working, but regular contributor PRs without the signature will not be reviewed or merged.

## Workflow

1. For this captain-owned delivery lane, clone `JTInventory/firstmate` or set your local delivery target to `git@github.com:JTInventory/firstmate.git`.
   A checkout whose `origin` fetches from upstream `kunchenguid/firstmate` is accepted only when `fork/main`, no-mistakes status, the no-mistakes gate, and the resolved `origin` push target all prove delivery to `JTInventory/firstmate`.
2. Create a branch and make your changes.
3. Initialize the gate so its target is `JTInventory/firstmate` (firstmate expects **no-mistakes v1.31.2+** and a GitHub CLI whose `gh pr checks` supports `--json`).
4. Commit your changes.
5. Push through the gate instead of pushing to `origin`:

   ```sh
   git push no-mistakes
   ```

6. Run `no-mistakes` to attach to the pipeline, watch findings, authorize auto-fixes, and review ask-user findings as needed.
   Follow the installed no-mistakes version's SKILL.md and live `axi` help for gate mechanics.
7. Once the pipeline passes, it pushes the branch and opens the PR against `JTInventory/firstmate` for you.

See the [no-mistakes quick start](https://kunchenguid.github.io/no-mistakes/start-here/quick-start/) for the full first-run walkthrough.

## Repo conventions

- This repo is a template for running a firstmate orchestrator agent.
  `AGENTS.md` is the agent's main job description and names when to load bundled skills; `CLAUDE.md` is a symlink to it, and `.claude/skills` is a symlink to `.agents/skills`.
- Only shared material is tracked: `AGENTS.md`, `CLAUDE.md`, `README.md`, `CONTRIBUTING.md`, `LICENSE`, `.gitignore`, `assets/`, `docs/`, `.tasks.toml`, `.no-mistakes.yaml`, `.github/workflows/`, `.agents/skills/`, `.claude/`, `bin/`, and `tests/`.
  Everything personal to one captain's fleet (`.env`, `data/`, `state/`, `config/`, `projects/`, `.no-mistakes/`) is gitignored; never commit it.
  Local report or preservation folders such as `reports/` and `backups/` are not canonical tracked surfaces; leave them out of PRs unless a specific artifact is intentionally promoted into shared documentation.
  The root `.tasks.toml` is tracked `tasks-axi` config for `data/backlog.md`; compatible `tasks-axi` is the default backend for routine backlog mutations.
  A local `config/backlog-backend=manual` opt-out forces hand-editing and stays gitignored.
  It does not make `data/` tracked.
- Helper scripts in `bin/` are plain bash.
  Each starts with a usage header comment; keep it accurate when you change behavior.
  Test scripts and helpers in `tests/` are plain bash too.
  `shellcheck -x -P SCRIPTDIR bin/*.sh tests/*.sh` must pass, and CI enforces it.
- Changes to harness adapters (detection in `bin/fm-harness.sh`, launch and hook mechanics in `bin/fm-spawn.sh`, busy signatures in `bin/fm-watch.sh` and `bin/fm-tmux-lib.sh`, cleanup in `bin/fm-teardown.sh`, and facts in `.agents/skills/harness-adapters/SKILL.md`) must be verified empirically against the real harness, never written from documentation alone.
- In Markdown, put each full sentence on its own line.

## Development

Tracked changes to firstmate itself - `AGENTS.md`, `CLAUDE.md`, `README.md`, `CONTRIBUTING.md`, `LICENSE`, `.gitignore`, `assets/`, `docs/`, `.tasks.toml`, `.no-mistakes.yaml`, `.github/workflows/`, `.agents/skills/`, `.claude/`, `bin/`, and `tests/` - ship through the `no-mistakes` pipeline on a feature branch and require an explicit merge approval.
When supervising live crewmates, keep firstmate's own long validation or build commands in the background so watcher wakes can still be handled.
Crewmate validation follows the installed no-mistakes version's SKILL.md and live `axi` help instead of duplicating gate mechanics in firstmate docs.
Firstmate's wrapper still matters: `ask-user` findings route to the captain through firstmate, and crewmates avoid `--yes` because it silently resolves captain-owned decisions without escalation.
Local `.no-mistakes/` state and test evidence stay out of this repo; `.no-mistakes.yaml` keeps evidence in a temp directory and pins the gate's test command to the same bash behavior suite as CI.
In this captain-owned delivery lane, no-mistakes PRs must target `JTInventory/firstmate`.
`bin/fm-no-mistakes-pr-target-guard.sh` checks direct push targets, all no-mistakes fetch and push targets, and `no-mistakes status` before the test suite runs, so stale gate state cannot open or update a PR on `kunchenguid/firstmate`.
It allows `origin` to fetch from upstream `kunchenguid/firstmate` only in a controlled-fork checkout where `fork`, branch tracking, no-mistakes status, the no-mistakes gate, and resolved `origin` push targets all prove delivery to `JTInventory/firstmate`.

Check and test the toolbelt before pushing:

```sh
bash -n bin/*.sh                          # syntax-check the toolbelt
shellcheck -x -P SCRIPTDIR bin/*.sh tests/*.sh # lint the toolbelt and behavior tests; CI enforces this
for test_script in tests/*.test.sh; do bash "$test_script"; done   # behavior tests, matching CI and no-mistakes commands.test
tests/fm-wake-queue.test.sh               # durable wake queue losslessness, catch-up, double-drain, duplicate-collapse, and drain liveness guard tests
tests/fm-watcher-lock.test.sh             # watcher singleton, lock-race, watch-arm liveness, and guard-warning tests
tests/fm-wake-lib-locale.test.sh          # locale-stable watcher PID identity regression test
tests/fm-watch-triage.test.sh             # always-on watcher triage: benign absorb, actionable surface, stale wedge threshold, heartbeat backstop, and afk one-shot coherence
tests/fm-daemon.test.sh                   # sub-supervisor classifier, /afk presence-gating, max-defer, composer, and fm-send submit tests
tests/fm-send-settle.test.sh              # fm-send post-submit settle pause, tuning, disable, and --key bypass tests
tests/fm-send-popup-settle.test.sh        # fm-send pre-Enter popup-settle selection for slash commands, codex $skill invocations, and marked codex secondmate text
tests/fm-send-codex-secondmate-submit-retry.test.sh # fm-send delayed final Enter for marked Codex secondmate text after generic retries report pending
tests/fm-send-secondmate-marker.test.sh   # fm-send from-firstmate marker for kind=secondmate targets: marked vs crewmate/explicit/--key, and the exact marker byte sequence
tests/fm-wake-daemon-lifecycle-e2e.test.sh # watcher + daemon lifecycle e2e: restart catch-up, batching, dedupe, stale-pane routing, and digest injection
tests/fm-composer-ghost.test.sh           # dim-ghost stripping, ghost-only composer detection, and escape-free peek tests
tests/fm-afk-inject-e2e.test.sh           # event-driven private-socket e2e for afk injection: partial-input deferral, swallowed-Enter retry, and single clean digest
tests/fm-bootstrap.test.sh                # bootstrap dependency, feature-probe, crew-dispatch, and secondmate-profile reporting tests
tests/fm-no-mistakes-pr-target-guard.test.sh # no-mistakes PR target guard for captain-fork delivery, controlled-fork origin fetches, push URLs, gate remotes, and status output
tests/fm-gotmp.test.sh                    # GOTMPDIR-safe temp handling for tests and scripts that must avoid a read-only repo filesystem
tests/fm-grok-harness.test.sh             # grok adapter spawn hook, token guard, teardown cleanup, and session-lock detection tests
tests/fm-fleet-sync.test.sh               # project clone refresh: safe detached recovery, STUCK drift reports, benign skips, deterministic single-clone resolution, and bootstrap relay
tests/fm-backlog-audit.test.sh            # read-only backlog/state drift audit findings, persistent secondmate inventory, and no-change contract
tests/fm-route.test.sh                    # deterministic route profiles, overrides, risk flags, and downgrade handling
tests/fm-x-mode.test.sh                   # X-mode poll, inbox context round-trip, reply threading, dismiss, dry-run preview, and .env-presence activation tests
tests/fm-memory-lookup.test.sh            # manual Cognee memory lookup fallback, source-path verification, and optional brief append
tests/fm-cbm.test.sh                      # optional CBM config, allowlist, brief/env injection, index targeting, and soft-failure behavior
tests/fm-cognee-lookup-gate.test.sh       # fail-closed Cognee automatic/manual gate markers and unsafe-evidence rejection
tests/fm-cognee-lookup.test.sh            # Cognee dry-run/live lookup wrapper, redacted telemetry, retry, and source verification behavior
tests/fm-cognee-session-cost-probe.test.sh # disabled Cognee session/cost probe planner, endpoint allowlist, and redacted JSONL output
tests/fm-cognee-source-verify.test.sh     # Cognee answer reference parsing, manifest matching, local source reopen, and telemetry
tests/fm-cognee-telemetry.test.sh         # secret-safe Cognee telemetry schema, redaction flags, IDs, and env-file loading
tests/fm-cognee-brief-rules.test.sh       # generated briefs include the trial-only, hint-only Cognee memory rules
tests/fm-tangle-guard.test.sh             # primary-checkout tangle detection and spawn/brief isolation tests
tests/fm-spawn-batch.test.sh              # batch dispatch, local-config isolation, and FM_HOME project-path scoping tests
tests/fm-spawn-route.test.sh              # spawn records route profile/model/effort metadata and appends the JT PR Intake Governor for matching PR-mode ship briefs without changing launch behavior
tests/fm-spawn-dispatch-profile.test.sh   # concrete dispatch profile flags: active-profile backstop, harness/model/effort meta, launch templates, batch forwarding, secondmate exemption, and secondmate launch profile threading
tests/fm-update.test.sh                   # fast-forward-only self-update, reread, nudge, dedup, and skip-safety tests
tests/fm-secondmate-sync.test.sh          # local-HEAD secondmate sync, no-fetch, bootstrap nudge gating, and spawn hook tests
tests/fm-secondmate-harness.test.sh       # secondmate-vs-crewmate harness resolution, secondmate launch profiles, primary-to-secondmate config inheritance, and config-push tests
tests/fm-secondmate-lifecycle-e2e.test.sh # persistent secondmate routing, seeding, backlog handoff, spawn, recovery, teardown, and FM_HOME flow tests
tests/fm-secondmate-safety.test.sh        # secondmate home safety, idle charter, handoff validation, and teardown boundary tests
tests/fm-teardown.test.sh                 # fm-teardown.sh landed-work safety, transient Git index-lock return retries, and reminder checks: fork-remote allow, squash/content landings, dirty and unlanded refusals, PR-head metadata, tasks-axi/manual backlog reminder, --force override
tests/fm-pr-merge.test.sh                 # captain-gated PR merge wrapper: approval marker, qualified GitHub URL parsing, PR-evidence recording, squash default, and repository-override refusal
tests/fm-crew-state.test.sh               # fm-crew-state.sh current-state reconciliation: run-step authority including closed panes, stale needs-decision/blocked superseded by a resumed run, genuine-parked, cross-branch attribution, pane/status-log fallback, scout skip, torn-down/missing-meta graceful
tests/fm-crew-state-ci-ready.test.sh      # active no-mistakes CI monitor with green checks reports PR readiness while merge/close monitoring continues
tests/fm-task-identity.test.sh            # task branch/meta identity guard for PR check, diff review, and teardown helpers
tests/fm-watch-session.test.sh            # durable home-scoped watcher tmux runner start/status/stop and re-arm delay behavior
tests/fm-supervision-model.test.sh        # read-only supervision checklist, secondmate/scout classification boundaries, and `firstmate.supervision.v1.1` JSON/schema output
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ]
[ "$(readlink .claude/skills)" = "../.agents/skills" ]
tmp=$(mktemp -d) && printf 'done: smoke\n' > "$tmp/smoke.status" && FM_STATE_OVERRIDE="$tmp" FM_SIGNAL_GRACE=1 FM_POLL=1 FM_HEARTBEAT=999999 bin/fm-watch-arm.sh  # watcher re-arm smoke test (prints arm status, then an actionable signal)
```

## Questions

Open an issue, or talk to me on [Discord](https://discord.gg/Wsy2NpnZDu).
