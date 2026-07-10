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
