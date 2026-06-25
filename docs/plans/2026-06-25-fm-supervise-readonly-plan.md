---
title: fm-supervise read-only supervision command
created: 2026-06-25
origin: ../data/fm-supervise-plan-0625/report.md
execution: code
---

# fm-supervise read-only supervision command

## Problem Frame

Firstmate has several read-only signals for operational supervision: task meta files,
status files, tmux window liveness, git worktree state, treehouse state, and GitHub PR
state. Today, Radar-like displays duplicate some of the decision logic. The first
version of `fm-supervise` should centralize those decisions in a passive command that
prints a concise checklist and a stable JSON model for later Radar migration.

## Scope Boundaries

In scope:

- Add a sourceable supervision model library.
- Add a small CLI wrapper with `--text`, `--json`, `--schema`, `--include-ok`,
  `--no-default-reminders`, and repeatable `--external-pr`.
- Add focused shell tests with fake state, fake `tmux`, fake `treehouse`, and fake
  `gh-axi`.
- Document the command and record that Radar should later consume
  `fm-supervise --json`.

Out of scope:

- Migrating Radar.
- Mutating state, backlog, tmux, git, treehouse, services, or GitHub.
- Teardown, merge, validation dispatch, watcher arming, or service/systemd actions.
- Committing private runtime directories such as `data/`, `state/`, `projects/`, and
  `.no-mistakes/`.

## Decisions

- `bin/fm-supervision-model.sh` owns collection, classification, JSON rendering, and
  text rendering. This keeps Radar and future display tools from copying decision rules.
- `bin/fm-supervise.sh` is only argument parsing plus a call into the model.
- GitHub read failures are model data, not command failures. They produce `unknown`
  PR state and `sources.github.ok=false`, and the command exits `0`.
- The JSON shape uses `schema_version: firstmate.supervision.v1`, `read_only: true`,
  and explicit `sources`, `summary`, `checklist`, `tasks`, `worktrees`, and
  `external_reminders` fields.
- Text output is intentionally short and always ends with `No changes made.`
- PR #68 is still open and overlaps only documentation (`AGENTS.md` and `README.md`)
  for this task.
  This PR should note the compatibility assumption; script and test behavior should
  remain independent of PR #68.

## Implementation Units

### U1: Model Collection And Classification

Files:

- Create `bin/fm-supervision-model.sh`

Approach:

- Resolve `FM_HOME`, `FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, and
  `FM_PROJECTS_OVERRIDE` the same way existing Firstmate scripts do.
- Read `state/*.meta`, `state/*.status`, and `state/*.turn-ended`.
- Tolerate older meta files by defaulting missing `kind`, `mode`, and `yolo`.
- Read git state only through status, branch, and worktree-list style commands.
- Use only tmux display reads and treehouse status reads.
- Query GitHub PR and commit status through `gh-axi api GET` when available.
- Classify the required v1 cases: merged PR with live worker, open PR with green CI,
  open PR with failing CI, worker done with no PR, dirty worktree with no active task,
  missing tmux window, stale treehouse state, GitHub unavailable, and external
  reminders.

Test scenarios:

- Missing state/data directories still produce valid read-only JSON.
- Sourceable functions load without collecting.
- Duplicate `pr=` uses the last value.
- Missing `kind`, `mode`, and `yolo` use backward-compatible defaults.
- GitHub failure becomes unknown state and does not crash collection.
- Every required classification emits the expected owner, severity, and action.

### U2: CLI And Rendering

Files:

- Create `bin/fm-supervise.sh`

Approach:

- Keep the CLI thin: parse flags, export model options, and call
  `fm_supervision_collect_and_emit`.
- Return `2` for usage errors and `0` for successful supervision even when checklist
  actions exist.
- Emit schema JSON without reading runtime state.

Test scenarios:

- `--schema` contains `firstmate.supervision.v1`.
- Invalid flags exit `2`.
- Text output includes the read-only posture and `No changes made.`
- `--include-ok` shows low-priority OK/watch items that default text hides.

### U3: Tests And Documentation

Files:

- Create `tests/fm-supervision-model.test.sh`
- Modify `README.md`
- Modify `AGENTS.md`

Approach:

- Use temporary fake homes and fake command shims in `PATH`.
- Assert the command does not create files under fake `state/` or `data/`.
- Add `fm-supervise.sh` to the README toolbelt.
- Add Firstmate guidance to use `fm-supervise.sh` as a read-only checklist when
  supervision is unclear.
- Document that Radar migration is a later consumer of `fm-supervise --json`.

Test scenarios:

- The focused test covers all required model behaviors.
- `bash -n`, `shellcheck`, and the full `tests/*.test.sh` suite pass.

## Verification

- `bash -n bin/fm-supervise.sh bin/fm-supervision-model.sh tests/fm-supervision-model.test.sh`
- `shellcheck bin/*.sh tests/*.sh`
- `bash tests/fm-supervision-model.test.sh`
- `for test_script in tests/*.test.sh; do "$test_script"; done`
