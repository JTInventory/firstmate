# Firstmate upstream adoption ledger

## Baseline

| Field | Evidence |
| --- | --- |
| Delivery repository | `JTInventory/firstmate` |
| Integration branch | `codex/firstmate-upstream-adoption` |
| JT baseline | `1c3b1d4` (PR #46) |
| Required ancestors | `4319fb6` (PR #44), `aef6973` (PR #45), `1c3b1d4` (PR #46) |
| Upstream comparison ref | `kunchenguid/firstmate` `31afb8c` fetched on 2026-07-10 |
| Divergence at comparison | JT fork 42 commits ahead, 92 commits behind |

The active `/root/firstmate` checkout is not an integration target.  All changes
are first characterized in the clean clone and are delivered only to the JT fork.

## Decisions

| Capability family | Upstream PRs | Decision | JT adaptation and boundary |
| --- | --- | --- | --- |
| Task backend and handoff | #145, #398, #401, #411 | Adapt | Preserve explicit/manual backend selection, persistent secondmate inventory, and complete multiline handoff bodies. |
| Teardown and landed-work detection | #149, #167, #168, #296 | Adapt | Accept qualified JT fork and squash-merge proof; protect dirty or unlanded work; no autonomous merge. |
| Clone sync and PR/CI visibility | #293, #294, #297 | Adapt | Make clone freshness and green PR evidence visible without bypassing no-mistakes. |
| Axi bootstrap and path discovery | #145, #332 | Adapt | Use deterministic NVM global-bin discovery in interactive and clean non-interactive shells; manual mode remains supported. |
| Dynamic dispatch mechanics | #144, #154, #159, #161, #180, #327, #331, #342 | Adapt | Retain JT Luna/Terra/Sol GPT-5.6 policy, captain overrides, and secondmate profile precedence. |
| tmux watcher hardening | #126, #233, #249, #285, #375, #403 | Adapt | Read-only tmux/Codex supervision only; no hook activation. |
| Generic backend abstraction | #183 and related multi-runtime work | Defer | Compatibility code must not make unsupported runtimes selectable. |
| Codex or Claude hook changes | #339, #367, #387, #397 | Defer | Requires explicit captain approval, backup, pre/post diff, rollback rehearsal, and observation window. |
| Fleet/session/Stow expansions | #197, #201, #300, #333, #343, #372 | Defer | Reconsider only after the core adoption train is stable. |
| Project-less secondmate homes | #409 | Defer | Requires a JT ownership and cleanup contract before enablement. |
| X/social integration | upstream X-mode work | Reject | Outside Firstmate's JT identity and approval boundary. |
| Herdr lifecycle and lab work | #402, #404 | Reject | Herdr is not an enabled JT runtime. |

## Adoption rules

1. Every candidate must be marked Adopt, Adapt, Defer, or Reject here before code is enabled.
2. A controlled upstream fetch is allowed for comparison only; no upstream delivery or push is allowed.
3. A merge parser may inspect a qualified JT PR URL, but only a captain-approved path may request a merge.
4. Runtime proof comes from backlog, state files, tmux, Treehouse, watcher, GitHub, and read-only supervisor output.
5. Deferred and rejected capabilities must remain unavailable in the supported tmux/Codex runtime.

## Phase II closeout (2026-07-13)

The selective transition is complete for the accepted reliability and operator-truth families. The JT fork delivered and merged the following focused adaptations:

| JT PR | Adopted family | JT boundary preserved |
| --- | --- | --- |
| #55 | Bounded retry for the transient Treehouse `index.lock` return race | Retry is signature-specific; stale-lock and landed-work proof remain required. |
| #57 | Immutable tmux window identity during spawn/worktree discovery | Window IDs are used for transient lookup; names remain human-facing metadata. |
| #58 | Fail-closed `fm-send` target resolution | Recorded `fm-*` selectors are validated against this home; caller-supplied `session:window` targets remain an explicit escape hatch without identity validation; pane guessing does not. |
| #59 | `paused: <reason>` external-wait classification | `paused` remains distinct from `blocked`, active runs, and canonical terminal truth. |
| #60 | Shared pause re-surface cadence | Watcher and away-mode daemon share one bounded marker/cadence contract. |
| #61 | Read-only supervisor wedge visibility | `.subsuper-inject-wedged` becomes a local high-severity checklist item; no external notifier is added. |

This is a historical closeout record captured on 2026-07-13, not a live runtime-status assertion. Each PR was merged after the repository's required behavior, shell-lint, invariant, no-mistakes, and CI checks passed; the PR and Checks links below are the audit trail.

| PR | Merge commit | Historical receipt |
| --- | --- | --- |
| [#55](https://github.com/JTInventory/firstmate/pull/55) | `fab23e711b524d565f4a3574baa2162f79aec4f5` | [Checks](https://github.com/JTInventory/firstmate/pull/55/checks) |
| [#57](https://github.com/JTInventory/firstmate/pull/57) | `e2559ae1471cdc0057a0955346bde92f54b8ae1d` | [Checks](https://github.com/JTInventory/firstmate/pull/57/checks) |
| [#58](https://github.com/JTInventory/firstmate/pull/58) | `8392063c0e9ab398dc7d68e4530662a4b38c6a5a` | [Checks](https://github.com/JTInventory/firstmate/pull/58/checks) |
| [#59](https://github.com/JTInventory/firstmate/pull/59) | `4d7d1c683f4eb34f5ae344af881f514e8282ae6e` | [Checks](https://github.com/JTInventory/firstmate/pull/59/checks) |
| [#60](https://github.com/JTInventory/firstmate/pull/60) | `d9a7129aa8b3642ec8e0084dcdb99ad66e6130e1` | [Checks](https://github.com/JTInventory/firstmate/pull/60/checks) |
| [#61](https://github.com/JTInventory/firstmate/pull/61) | `5da9351f3ce17c4fdd318da0021625645e046ef3` | [Checks](https://github.com/JTInventory/firstmate/pull/61/checks) |

The no-mistakes receipt is anchored by `.no-mistakes.yaml` and `CONTRIBUTING.md`; CI enforcement is `.github/workflows/no-mistakes-required.yml`.

The clean detached checkout at runtime head `5da9351f3ce17c4fdd318da0021625645e046ef3` passed these focused Phase II suites: `fm-teardown`, `fm-spawn-route`, `fm-tangle-guard`, `fm-send-strict`, `fm-crew-state`, `fm-watch-triage`, `fm-daemon`, and `fm-supervision-model`.

```sh
set -e
for test_script in tests/fm-teardown.test.sh tests/fm-spawn-route.test.sh tests/fm-tangle-guard.test.sh tests/fm-send-strict.test.sh tests/fm-crew-state.test.sh tests/fm-watch-triage.test.sh tests/fm-daemon.test.sh tests/fm-supervision-model.test.sh; do bash "$test_script"; done
```

The canonical `/root/firstmate` home was then fast-forwarded to the fork head while preserving operator-owned untracked configuration, plans, reports, and skill copies; Treehouse dirty/leased slots were not cleaned or restarted. The historical runtime proof used `bin/fm-supervise.sh --json` against `state/.subsuper-inject-wedged`, `bin/fm-backlog-audit.sh` against `data/backlog.md`, `data/secondmates.md`, and `state/*.meta`, `bin/fm-watch-arm.sh` against `state/.watch.lock` and `state/.last-watcher-beat`, and `bin/fm-no-mistakes-pr-target-guard.sh` for the `JTInventory/firstmate` target. It recorded a clean tracked tree, `fm-supervise --json` at `ok` with no high/medium actions, a running watcher, no backlog drift, and a silent guard after the queued wake was drained.

The durable Compound Engineering explanation is maintained in the JT workspace at `docs/solutions/architecture-patterns/firstmate-selective-upstream-adoption.md` (outside this repository tree). This ledger remains the Firstmate-side decision record; the Compound document explains the reusable pattern and links back here rather than duplicating this table.

### Explicitly not enabled by this train

- U5b JT Control Room ingestion of the local wedge marker: deferred because there is no approved JT writer, endpoint, generated-data contract, or demonstrated operator gap.
- Generic multi-runtime backends, project-less secondmate homes, quota-balanced dispatch, and global hook changes: deferred pending separate JT contracts and approval.
- New upstream Herdr, Orca, cmux, Zellij, and external Slack/SMS/paging variants: rejected by this train as outside the supported JT identity and approval boundary. Existing optional Pi harness and opt-in X mode remain available under their existing verified/local contracts; this train neither enables nor broadens them.
- Grok remains the already-landed optional adapter from JT PR #28 / upstream #143; the open/conflicting Grok-primary proposal (upstream #461) is not adopted.
