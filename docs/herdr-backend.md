# Herdr runtime backend (experimental)

JT firstmate can use Herdr as an experimental session provider. Tmux remains
the default and remains the fleet's production path. This PR does not claim a
multi-backend production fleet: Herdr is an opt-in compatibility path while it
is verified against the local Herdr CLI.

## Compatibility and licensing

The adapter is written for Herdr 0.7.x and requires protocol 14 or newer. It
uses the standalone `herdr` CLI and `jq`; no Herdr library is linked into
firstmate. Herdr is dual-licensed AGPL-3.0-or-later / commercial. Firstmate
invokes Herdr as a separate process and does not change the license of this
repository. Confirm the current Herdr license and install instructions at
[herdr.dev](https://herdr.dev) before enabling it.

## Enable it for new tasks

Herdr is selected in this order:

1. `fm-spawn.sh --backend herdr`
2. `FM_BACKEND=herdr`
3. the first non-empty line of local, gitignored `config/backend`
4. runtime detection, only when there is no explicit setting
5. the hard default, `tmux`

Runtime detection selects Herdr when `HERDR_ENV=1`. If `$TMUX` is also set,
tmux wins because the shell is running inside a nested tmux session. Herdr
auto-detection prints a notice so it is never mistaken for the default.

Selecting Herdr makes `fm-bootstrap.sh` check `herdr`, `jq`, and `treehouse`.
With no Herdr selection, bootstrap does not require the Herdr CLI. A selected
Herdr backend fails closed if the CLI is missing or its client protocol is
older than 14.

## Session and worktree shape

Herdr is a session provider only. Treehouse still leases the isolated git
worktree, and firstmate still owns the worktree lifecycle.

Each firstmate home gets one persistent Herdr workspace and each task gets one
tab with one root pane:

- primary home: workspace label `firstmate`
- secondmate home: workspace label `2ndmate-<secondmate-id>`
- task target: `<session>:<pane-id>`, for example `default:w1:p2`

Herdr task metadata records `backend=herdr`, `herdr_session=`,
`herdr_workspace_id=`, `herdr_tab_id=`, and `herdr_pane_id=`. Tmux metadata
continues to omit `backend=tmux`; a missing backend field still means tmux.

The adapter avoids focusing new workspaces or tabs where Herdr supports that
flag. It refuses duplicate task-tab labels and removes only the seeded default
tab created by a workspace that this spawn itself created. Existing workspaces
are adopted without pruning their tabs.

## Lab and safety

Use `bin/fm-herdr-lab.sh` for real Herdr experiments:

```sh
session=$(bin/fm-herdr-lab.sh name smoke)
bin/fm-herdr-lab.sh provision "$session"
bin/fm-herdr-lab.sh run "$session" workspace list
bin/fm-herdr-lab.sh teardown "$session"
```

Lab names must begin with `fm-lab-`. The helper rejects `default`, refuses
caller-supplied `--session` flags, blocks direct server/session lifecycle
commands, and records a default-session fleet-state tripwire before provision.
Stop/delete operations require that tripwire and re-check the default session
immediately before each destructive call. Never use the helper to stop or
delete the captain's live `default` session.

The unit suite uses a fake Herdr client and needs no server:

```sh
bash tests/fm-backend-herdr.test.sh
bash tests/fm-herdr-lab.test.sh
```

Real Herdr smoke is opt-in and skips unless Herdr, a live socket, and the
explicit smoke environment are present. CI therefore remains green without a
Herdr server. The AFK daemon can inject into a Herdr supervisor when
`FM_SUPERVISOR_BACKEND=herdr` and a `<session>:<pane-id>` target are selected;
unsupported supervisor backends fail closed. The gated coverage lives in
`tests/fm-afk-inject-herdr-e2e.test.sh` and uses only `fm-lab-*` sessions.

Changes for this JT fork ship through the `JTInventory/firstmate` PR target;
the owner repository is comparison-only during the port.
