# Worker isolation verification

Audience: maintainer verification.

This record contains reusable evidence for the guarantees in [`docs/worker-isolation.md`](../worker-isolation.md).
The command/output blocks are maintained contract examples, not fresh captures
of the current branch. The original host captures used Linux 6.18 (WSL2) and
tmux 3.6 on 2026-07-26.
Exact task chronology, branch names, temporary homes, and delivery transcripts remain in private reports or PR evidence.

## Launched-agent home declaration

```sh
. bin/fm-worker-isolation-lib.sh
fm_worker_launch_env_prefix crewmate demo-task /home/cap/firstmate; echo
fm_worker_launch_env_prefix secondmate dom-x /home/cap/homes/dom; echo
```

Expected output, with the final literal trailing space rendered as `<SPACE>`:

```text
exec <AUTHORITY_FD>&-; exec <DURABLE_AUTHORITY_FD>&-; FM_HOME= FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_LIFECYCLE_HOME= FM_LIFECYCLE_STATE= FM_LIFECYCLE_SCRIPT= FM_LOCK_PROCESS_TOKEN= FM_SESSION_AUTHORITY_FD= FM_SESSION_AUTHORITY_DURABLE_FD= FM_SESSION_AUTHORITY_BROKER_PID= FM_SESSION_AUTHORITY_BROKER_START= FM_SESSION_AUTHORITY_BROKER_IDENTITY= FM_SESSION_AUTHORITY_BROKER_SCRIPT= FM_AGENT_ROLE=crewmate FM_AGENT_TASK='demo-task' FM_AGENT_OWNER_HOME='/home/cap/firstmate'<SPACE>
FM_HOME='/home/cap/homes/dom' FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_LIFECYCLE_HOME= FM_LIFECYCLE_STATE= FM_LIFECYCLE_SCRIPT= FM_LOCK_PROCESS_TOKEN= FM_AGENT_ROLE=secondmate FM_AGENT_TASK='dom-x' FM_AGENT_OWNER_HOME='/home/cap/homes/dom'<SPACE>
```

A crewmate carries no home at all; a secondmate carries only its own.
For a secondmate spawn, this declaration precedes
`bin/fm-session-authority-exec.sh`; the authorized parent has already placed a
one-use signed enrollment ticket in that home without exposing the issuer key.
The signer binds its public-key digest to its live protected process. Spawn
launches a randomly tagged wrapper through a backend-owned operation and
resolves that exact PID through tmux's exact-pane serialized respawn response
or Herdr's direct agent-start response and pane process-info. The normalized
launcher `PATH` is carried into that direct process launch. Both backends compare
their complete live endpoint identity with the recorded endpoint before ticket
issue and again after authenticated acceptance. New tmux metadata persists the
exact pane. A legacy record without endpoint fields is accepted for migration
only when its live process has the complete secondmate declaration and a
primary-issued authority-authenticated launch receipt matching its PID, start
value, executable identity, task, and home. Declaration, marker, cwd, or pane
evidence alone is insufficient. Pre-port processes without that receipt fail
closed and require a coordinated primary and secondmate restart. Ambiguity refuses.
Older window-scoped records that already have a generation are accepted only
with one stable pane.
The ticket
binds the wrapper's start value and executable identity, and the signer accepts
only that exact process. The
private signing key stays in shell memory and fresh anonymous pipes, with no
filesystem pathname, environment export, or terminal command text. On Linux,
the broker, signer, and wrapper each use a real same-credential child open
attempt to prove that procfs cannot expose any authority-bearing descriptor
before creating its secret; readable or unrecognized isolation refuses
startup. Darwin has no corresponding procfs descriptor path. The wrapper then
keeps live-broker HMAC and durable-receipt HMAC on distinct protected
descriptors. Only the production authority wrapper may authorize a detached
custodian, after proving its own broker PID, start, executable identity, and
script path. It gives the custodian a launch certificate bound to its exact PID
and session and authenticated by both roots, plus a one-use signing channel on
reserved FD 17 whose public half is pinned in the custodian's immutable
arguments. FD 17 must be unused and sibling-isolated. At startup the custodian
independently proves that its actual parent is that exact production wrapper and
that its inherited FDs 9, 18, and 17 are the same protected channels still held
by the parent. The parent closes FD 17 before launching the harness command, so
a later broker child cannot invoke the public custodian script with self-created
keys.
After validating it, the custodian closes FDs 9, 18, and 17, clears the
live-broker environment, and retains only the durable receipt root and signing
private key in shell memory. A replacement wrapper
that no longer inherited that descriptor re-execs with a one-use RSA public key
in immutable arguments; the custodian checks the exact wrapper, original kernel
session and session-start identity, live process identity, and permitted primary
or exact-home secondmate ancestry before returning the root encrypted to that
key. The ciphertext and both endpoint identities carry a durable-root HMAC.
Before installing the candidate root on FD 18, the wrapper sends a second fresh
challenge to the same live custodian and requires both a candidate-root HMAC
and a signature matching the public key pinned in that exact process's
arguments. It then installs
the root, validates the complete record again, and rotates the separate
live-broker key. A replacement that retained only FD 9 must also recover an
existing custodian root before the compatibility adoption path can run. A
restarted secondmate must recover that root before creating any new scoped key.
A broker that still holds the root can authenticate and replace a stale
custodian without changing durable provenance. The wrapper then
creates an anonymous consumer key and publishes its public key and exact live
process identity in `${enrollment}.consume`. The signer validates that request
and publishes a signed `${enrollment}.accepted` record. The wrapper validates
it, signs `${enrollment}.accepted.ack`, captures the ticket and acceptance,
removes its private consumer ticket, and re-execs into the confirmed stage
while preserving the private consumer key only on protected FD 8.
That stage validates both captured records and publishes the final
consumer-signed `${enrollment}.accepted.final` receipt with a distinct
`stage=final` signature domain. A copied `stage=ack` receipt is not final
acceptance. The confirmed stage closes FD 8 after the final write succeeds.
Spawn waits for the signer to validate
the final receipt and rechecks the backend endpoint before reporting success. Tmux
lifecycle operations and ordinary `fm-<id>` selectors share one strict parser
that rejects duplicate or malformed pane data and proves the persisted exact
pane still belongs to the recorded window and generation before transport.

The declaration refuses rather than emitting a partial prefix:

```sh
fm_worker_launch_env_prefix auditor t /home/cap/firstmate; echo "rc=$?"
fm_worker_launch_env_prefix crewmate '' /home/cap/firstmate; echo "rc=$?"
fm_worker_launch_env_prefix crewmate t relative/home; echo "rc=$?"
```

```text
error: unknown agent role 'auditor'; expected crewmate or secondmate
rc=1
error: agent role crewmate requires a task id
rc=1
error: agent role crewmate requires an absolute owning home, got 'relative/home'
rc=1
```

## Harness axis: every verified harness launches with the declaration

Captured by driving `bin/fm-spawn.sh` against the fake-provider fixture used by `tests/fm-worker-isolation.test.sh`, which records the literal launch command the provider is asked to run.
The operating home and repository root are elided as `<HOME>` and `<ROOT>`.

```text
claude:   exec <AUTHORITY_FD>&-; exec <DURABLE_AUTHORITY_FD>&-; FM_HOME= FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_LIFECYCLE_HOME= FM_LIFECYCLE_STATE= FM_LIFECYCLE_SCRIPT= FM_LOCK_PROCESS_TOKEN= FM_SESSION_AUTHORITY_FD= FM_SESSION_AUTHORITY_DURABLE_FD= FM_SESSION_AUTHORITY_BROKER_PID= FM_SESSION_AUTHORITY_BROKER_START= FM_SESSION_AUTHORITY_BROKER_IDENTITY= FM_SESSION_AUTHORITY_BROKER_SCRIPT= FM_AGENT_ROLE=crewmate FM_AGENT_TASK='ev-claude' FM_AGENT_OWNER_HOME='<HOME>' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --dangerously-skip-permissions "$('<ROOT>/bin/fm-operational-input.sh' encode launch-brief < '<HOME>/data/ev-claude/brief.md')"
codex:    exec <AUTHORITY_FD>&-; exec <DURABLE_AUTHORITY_FD>&-; FM_HOME= FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_LIFECYCLE_HOME= FM_LIFECYCLE_STATE= FM_LIFECYCLE_SCRIPT= FM_LOCK_PROCESS_TOKEN= FM_SESSION_AUTHORITY_FD= FM_SESSION_AUTHORITY_DURABLE_FD= FM_SESSION_AUTHORITY_BROKER_PID= FM_SESSION_AUTHORITY_BROKER_START= FM_SESSION_AUTHORITY_BROKER_IDENTITY= FM_SESSION_AUTHORITY_BROKER_SCRIPT= FM_AGENT_ROLE=crewmate FM_AGENT_TASK='ev-codex' FM_AGENT_OWNER_HOME='<HOME>' codex --dangerously-bypass-approvals-and-sandbox -c "notify=[\"bash\",\"-c\",\"touch '<HOME>/state/ev-codex.turn-ended'\"]" "$('<ROOT>/bin/fm-operational-input.sh' encode launch-brief < '<HOME>/data/ev-codex/brief.md')"
opencode: exec <AUTHORITY_FD>&-; exec <DURABLE_AUTHORITY_FD>&-; FM_HOME= FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_LIFECYCLE_HOME= FM_LIFECYCLE_STATE= FM_LIFECYCLE_SCRIPT= FM_LOCK_PROCESS_TOKEN= FM_SESSION_AUTHORITY_FD= FM_SESSION_AUTHORITY_DURABLE_FD= FM_SESSION_AUTHORITY_BROKER_PID= FM_SESSION_AUTHORITY_BROKER_START= FM_SESSION_AUTHORITY_BROKER_IDENTITY= FM_SESSION_AUTHORITY_BROKER_SCRIPT= FM_AGENT_ROLE=crewmate FM_AGENT_TASK='ev-opencode' FM_AGENT_OWNER_HOME='<HOME>' OPENCODE_CONFIG_CONTENT='{"permission":{"*":"allow"}}' opencode --prompt "$('<ROOT>/bin/fm-operational-input.sh' encode launch-brief < '<HOME>/data/ev-opencode/brief.md')"
pi:       exec <AUTHORITY_FD>&-; exec <DURABLE_AUTHORITY_FD>&-; FM_HOME= FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_LIFECYCLE_HOME= FM_LIFECYCLE_STATE= FM_LIFECYCLE_SCRIPT= FM_LOCK_PROCESS_TOKEN= FM_SESSION_AUTHORITY_FD= FM_SESSION_AUTHORITY_DURABLE_FD= FM_SESSION_AUTHORITY_BROKER_PID= FM_SESSION_AUTHORITY_BROKER_START= FM_SESSION_AUTHORITY_BROKER_IDENTITY= FM_SESSION_AUTHORITY_BROKER_SCRIPT= FM_AGENT_ROLE=crewmate FM_AGENT_TASK='ev-pi' FM_AGENT_OWNER_HOME='<HOME>' pi -e '<HOME>/state/ev-pi.pi-ext.ts' "$('<ROOT>/bin/fm-operational-input.sh' encode launch-brief < '<HOME>/data/ev-pi/brief.md')"
grok:     exec <AUTHORITY_FD>&-; exec <DURABLE_AUTHORITY_FD>&-; FM_HOME= FM_ROOT_OVERRIDE= FM_STATE_OVERRIDE= FM_DATA_OVERRIDE= FM_PROJECTS_OVERRIDE= FM_CONFIG_OVERRIDE= FM_LIFECYCLE_HOME= FM_LIFECYCLE_STATE= FM_LIFECYCLE_SCRIPT= FM_LOCK_PROCESS_TOKEN= FM_SESSION_AUTHORITY_FD= FM_SESSION_AUTHORITY_DURABLE_FD= FM_SESSION_AUTHORITY_BROKER_PID= FM_SESSION_AUTHORITY_BROKER_START= FM_SESSION_AUTHORITY_BROKER_IDENTITY= FM_SESSION_AUTHORITY_BROKER_SCRIPT= FM_AGENT_ROLE=crewmate FM_AGENT_TASK='ev-grok' FM_AGENT_OWNER_HOME='<HOME>' grok --always-approve "$('<ROOT>/bin/fm-operational-input.sh' encode launch-brief < '<HOME>/data/ev-grok/brief.md')"
```

The declaration precedes each adapter's own environment and flags, so an adapter cannot opt out of it.
These five adapters are the harnesses currently listed in `FM_HARNESS_RE`; adding another requires updating both that shared identity expression and this launch matrix.

## Provider axis: per-pane process id

```sh
tmux new-session -d -s fmiso2 -n w -c /tmp
. bin/fm-agent-cwd-lib.sh
for b in tmux herdr zellij cmux orca; do
  if p=$(fm_agent_backend_shell_pid "$b" 'fmiso2:w' 2>/dev/null); then
    printf '%-7s exposes pid=%s\n' "$b" "$p"
  else
    printf '%-7s no per-pane process id\n' "$b"
  fi
done
```

Observed output against a real live pane:

```text
tmux    exposes pid=776113
herdr   no per-pane process id
zellij  no per-pane process id
cmux    no per-pane process id
orca    no per-pane process id
```

A provider with no process id reports `unknown` rather than degrading to its pane path:

```sh
. bin/fm-agent-cwd-lib.sh && fm_agent_cwd_verdict '' '' '' herdr 'ses:pane' | cat -A
```

```text
unknown^I^I
```

## tmux: the process reading tracks the live foreground, the pane field does not have to

```sh
tmux new-session -d -s fmiso -n w -c /tmp
PP=$(tmux display-message -p -t fmiso:w '#{pane_pid}')
tmux send-keys -t fmiso:w 'cd /usr && sleep 60' Enter
. bin/fm-agent-cwd-lib.sh
FG=$(fm_agent_foreground_pid "$PP")
```

Observed:

```text
pane_pid=641003
pane_current_path=/tmp
proc_cwd_of_pane_pid=/tmp
after cd+sleep:
  pane_current_path=/usr
  shell /proc cwd=/usr
  foreground_pid=641185  fg /proc cwd=/usr
```

The descent to the foreground process is what makes a tmux reading follow a `treehouse get` subshell during the spawn worktree-settle poll, rather than reporting the pane shell's own directory.

## Reading another process's environment

`/proc/<pid>/environ` mode bits are not sufficient permission: the kernel additionally requires ptrace read access, so a same-uid but privileged process passes a readability test and still fails `EACCES` at open.
Before this was handled, a whole-host scan printed lines like the following into a read-only sweep's output, where they would have been surfaced as if they were findings:

```text
bin/fm-agent-cwd-lib.sh: line 114: /proc/462/environ: Permission denied
```

Redirections are applied left to right, so a trailing `2>/dev/null` on the same command is established only after the input redirect has already failed and written to stderr.
The group form is what suppresses it, and `fm_agent_environ` is the single reader that applies it.

Regression: `tests/fm-worker-isolation.test.sh` captures the sweep with stderr folded into stdout. An unreadable live candidate whose command matches `FM_HARNESS_RE` is emitted as unproven and fails closed; unrelated unreadable kernel or non-harness processes are ignored.
