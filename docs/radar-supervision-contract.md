# Radar Supervision Contract

Radar-style displays consume Firstmate supervision state through `bin/fm-supervise.sh --json`.
They should not duplicate Firstmate's decision model.

## Command

Run the command from the Firstmate repo whose `bin/` directory you want to use.
Set `FM_HOME` to the operational home being observed:

```sh
FM_HOME=/path/to/firstmate-home bin/fm-supervise.sh --json --no-default-reminders
```

Use `--no-default-reminders` when the display wants only local fleet state.
Use `--external-pr <url>` to add display-specific PR reminders without hard-coding them into Radar.
Use `--schema` to read the `firstmate.supervision.v1` contract without touching runtime state.

## Consumer Rules

- Treat `schema_version` as the compatibility gate.
- Treat `read_only: true` as part of the contract; a missing or false value is not a Radar-ready model.
- Render `summary.level` as the fleet headline: `ok`, `watch`, or `action`.
- Render `checklist` as the primary action list.
- Use each checklist item's `severity`, `owner`, `action`, `why`, `task_id`, `project`, `pr_url`, and `evidence` directly instead of recomputing the next action.
- Use `tasks`, `worktrees`, and `external_reminders` only for drill-down detail.
- Surface `sources.<name>.ok: false` as incomplete evidence, not as a command failure.

## Non-Goals

- Radar does not classify task state.
- Radar does not decide PR readiness.
- Radar does not inspect tmux, treehouse, git, or GitHub directly when the JSON model already includes the evidence.
- Radar does not write `state/`, `data/`, git branches, treehouse leases, tmux panes, services, or GitHub.

## Migration Sketch

1. Shell out to `fm-supervise.sh --json --no-default-reminders` with the right `FM_HOME`.
2. Parse the JSON.
3. Check `schema_version == "firstmate.supervision.v1"` and `read_only == true`.
4. Render `summary` plus `checklist`.
5. Keep any existing Radar-only layout code, but delete duplicated state classification rules.

The exact local Radar patch belongs outside this repository if the active Radar script still lives at a local-only runtime path.
