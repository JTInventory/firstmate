---
title: Radar Consumes the Firstmate Supervision Model
date: 2026-06-25
category: architecture-patterns
module: supervision
problem_type: architecture_pattern
component: assistant
severity: medium
applies_when:
  - "A display or dashboard needs to show Firstmate fleet state"
  - "A follow-up change would otherwise duplicate task classification logic outside Firstmate"
tags: [radar, supervision, json-contract, display]
---

# Radar Consumes the Firstmate Supervision Model

## Context

Radar is useful as a readable display, but it should not become a second source of truth for Firstmate supervision decisions.
The stable boundary is `bin/fm-supervise.sh --json`: Firstmate owns state collection and classification, while displays render the resulting model.

This came up while preparing the workflow-structure follow-up after the read-only supervision command landed as a sidecar.
The active Radar script lived outside this repo, so the safe Firstmate-side move was to publish the JSON contract, test it, and leave the external runtime patch as a handoff.

## Guidance

Keep classification in Firstmate.
When a display needs fleet state, consume `firstmate.supervision.v1` instead of re-reading `state/`, `tmux`, treehouse, git, or GitHub.

The display should:

- Run `FM_HOME=/path/to/home bin/fm-supervise.sh --json --no-default-reminders`.
- Check `schema_version == "firstmate.supervision.v1"` and `read_only == true`.
- Render `summary` and `checklist` as the primary view.
- Use `tasks`, `worktrees`, and `external_reminders` only for detail.
- Treat `sources.<name>.ok: false` as incomplete evidence, not as a reason to invent fallback classification.

When the display itself lives outside this repository, do not patch it from a Firstmate worktree.
Add or tighten the Firstmate-side contract first, then write an exact handoff for the external patch.

## Why This Matters

Duplicated decision rules drift.
A display might classify a task as routine while Firstmate sees a captain decision, or vice versa.
That makes supervision harder because the operator has to reconcile two explanations of the same fleet.

The JSON contract keeps the boundary simple: Firstmate decides, Radar displays.
It also lets Firstmate improve evidence collection later without requiring every display to relearn the decision model.

## When to Apply

- A new dashboard, terminal display, or status report needs Firstmate fleet state.
- A local runtime script wants to inspect task readiness, PR state, dirty worktrees, or stale worker windows.
- A follow-up branch would otherwise copy logic from `bin/fm-supervision-model.sh`.

## Examples

Preferred display flow:

```sh
FM_HOME=/path/to/firstmate-home bin/fm-supervise.sh --json --no-default-reminders
```

Then render the contract:

- headline from `summary.level`
- action rows from `checklist[]`
- detail drawers from `tasks[]`, `worktrees[]`, and `external_reminders[]`

Avoid this pattern:

```text
Radar reads state/*.meta, calls tmux, checks PRs, and reimplements classification names.
```

That makes Radar a second supervision engine instead of a display.

## Related

- `docs/radar-supervision-contract.md`
- `docs/scripts.md`
- `bin/fm-supervision-model.sh`
