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

Herdr task metadata records `backend=herdr`, `display_label=`, `task_key=`,
`herdr_session=`, `herdr_workspace_id=`, `herdr_tab_id=`, and
`herdr_pane_id=`. Tmux metadata continues to omit `backend=tmux`; a missing
backend field still means tmux.

The adapter avoids focusing new workspaces or tabs where Herdr supports that
flag.

### Task display labels: presentation split from identity

`bin/fm-task-label-lib.sh` creates one Herdr-only label at spawn:

```text
<kind> - <phrase> · <task-key>
```

Ship maps to `Crew`, scout maps to `Scout`, and the persistent secondmate agent
maps to `2nd`. The phrase is 1-28 characters from explicit `--display-title`,
then `data/<id>/display-title`, then the structured backlog title, then a
semantic task-id fallback. It permits only ASCII letters, digits, spaces, `.`,
`+`, `_`, and `-`; control, ANSI, newline, tab, and bidi input is refused. The
whole label is at most 50 characters and is set once, never renamed for a
phase or status change.

The key reuses a stable 4-6 character alphanumeric id tail when it contains
both letters and digits. Otherwise it uses the first six lowercase SHA-256
characters of the full task id. A collision found in metadata, pre-create
journals, or live workspace labels extends it deterministically to ten
characters. The key helps people scan tabs but never authorizes routing,
recovery, or cleanup.

Before tab create, spawn atomically publishes the private
`state/<id>.herdr-label` journal with the full `task_id=`, exact
`display_label=`, `task_key=`, `herdr_home=`, `herdr_session=`, and
`herdr_workspace_id=`. After the create response's exact tab and pane ids plus
the label are atomically published in `state/<id>.meta`, the journal is removed.
A crash or lost response therefore leaves the backend and workspace identity
needed to inventory the right home, and a retry reuses the same label.

Normal routing prefers `herdr_session=` plus `herdr_pane_id=` and keeps
`herdr_tab_id=` for exact correlation. Recovery still recognizes legacy
`fm-<id>` labels. For readable labels it maps only an exact `display_label=`
match from metadata or the pre-create journal back to the full task id.
Unmatched readable labels remain unknown orphans; there is no
pretty-label-only or short-key-only recovery. Workspace identity remains
`firstmate` or `2ndmate-<id>`, and tmux naming is unchanged.
Journal-only selector recovery remains routed through Herdr even before final
metadata exists.

### ID stability across a server restart

Herdr restores workspace, tab, and pane ids and labels after a session or server
restart.
Restored task panes can therefore return as husks with no registered agent.
A duplicate label is safe to replace only when its pane is proven to be a husk:
the pane is gone (`dead`) or the pane exists without a registered agent
(`no-agent`).
A live or ambiguous pane still refuses the duplicate.
Replacement is create-first, close-second, so a husk is never removed before
its replacement exists.
`agent_alive` reports `alive`, `dead`, or `unknown` with the same fail-closed
rule.

### Default-tab prune

Herdr seeds a new workspace with a default tab. JT threads the exact tab id
returned by that same workspace-create call through the spawn path and prunes
it only after the first real task tab exists. Adopted workspaces carry no seed
id, so their tabs are never pruned by a later spawn. This is a spawn-safety
guard, not permission to touch the captain's `default` session.

Composer classification is shared with tmux in `bin/fm-composer-lib.sh`. ANSI
dim/faint and dark truecolor ghost text is ignored, real typed text stays
`pending`, and a bare shell prompt (`>`, `$`, `%`, `#`) is `unknown` rather than
an injection-safe empty agent composer. A bordered agent composer remains
`empty` when it contains only its own prompt.

On Herdr protocol 16 or newer, the adapter can also wait on the native
`pane.agent_status_changed` stream. `bin/backends/herdr-eventwait.py` is a
bounded raw-socket reader; `fm_backend_herdr_wait_transition` normalizes events
through `bin/fm-transition-lib.sh` and treats only a fresh `blocked` edge as
immediately actionable. Capability, socket, subscription, and reader failures
return to the normal polling path. The transition marker is committed only by
the caller after it handles the wake, so a failed handoff is not lost.

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
python3 tests/fm-backend-herdr-eventwait.test.py
bash tests/fm-composer-lib.test.sh
```

The normal behavior suite and CI test loop discover the real-lab scripts below,
but they skip unless a real-lab opt-in variable is set.
This keeps the hermetic suite green without a live Herdr server or live e2e.

### Ambient Herdr isolation for hermetic tests

Running tests from a live Herdr pane exports `HERDR_ENV=1` (and pane ids).
Without scrubbing those, hermetic spawn and secondmate fixtures auto-select the
experimental herdr backend and can create real `2ndmate-*` workspaces on the
captain's `default` session under temp cwd paths such as
`/tmp/fm-behavior-tests...`.
`bin/fm-run-behavior-tests.sh` and `tests/lib.sh` therefore unset the six
ambient runtime `HERDR_*` markers for hermetic runs and pin `FM_BACKEND=tmux`
when the outer environment did not already set `FM_BACKEND`. The
`FM_HERDR_E2E` and `FM_HERDR_SMOKE` real-lab selectors do not disable this
scrub. Real-lab e2e tests instead prepare a private `fm-lab-*` session, export
`HERDR_SESSION` for that session, and use explicit Herdr selection where a
spawn needs it; they never rely on the captain pane's ambient markers.
Set `FM_HERDR_ALLOW_AMBIENT=1` only when deliberately testing ambient
detection. That opt-in preserves ambient `HERDR_*` markers and the caller's
`FM_BACKEND` for the full suite.

Set `FM_HERDR_E2E=1` to run the four real lab tests:

```sh
FM_HERDR_E2E=1 bash tests/fm-backend-herdr-workspace-per-home-e2e.test.sh
FM_HERDR_E2E=1 bash tests/fm-backend-herdr-respawn-idem-e2e.test.sh
FM_HERDR_E2E=1 bash tests/fm-backend-herdr-prune-safety-e2e.test.sh
FM_HERDR_E2E=1 bash tests/fm-send-secondmate-marker-herdr-e2e.test.sh
```

They cover per-home workspace isolation, restart-idempotent husk replacement,
adopted-workspace prune safety, and secondmate marker delivery plus unmarked
direct input.
Each test creates a private `fm-lab-*` session and never touches the live
`default` session.
The marker test also accepts `FM_SEND_MARKER_HERDR_E2E=1` when it is run alone.

Real Herdr smoke remains separately opt-in through `FM_HERDR_SMOKE=1`.
The AFK daemon can inject into a Herdr supervisor when
`FM_SUPERVISOR_BACKEND=herdr` and a `<session>:<pane-id>` target are selected;
unsupported supervisor backends fail closed.
The gated AFK coverage lives in `tests/fm-afk-inject-herdr-e2e.test.sh` and
uses only `fm-lab-*` sessions.

Changes for this JT fork ship through the `JTInventory/firstmate` PR target;
the owner repository is comparison-only during the port.
