# Grok background supervision protocol

Grok background-notify tasks can be reaped by sending `SIGTERM` to the whole
task process group. A watcher started as an ordinary child, with `nohup`, or
with a shell `&` can therefore die while the durable wake queue still looks
recoverable.

For a home with work in flight:

1. Run `bin/fm-wake-drain.sh` at the start of the wake-handling turn.
2. Start `bin/fm-watch-arm.sh` as Grok's own tracked background task, by itself.
   Do not put it in a larger shell command and do not use `command &`.
3. Treat `watcher: started ...`, `watcher: attached ...`, and
   `watcher: follower already waiting ...` as live-cycle results. Do not
   re-arm after `follower already waiting`: another arm already owns this
   cycle's follower slot.
4. On Grok's `task_completed` notification, drain the queue and inspect the
   completion output. If it reports a wake reason (`signal`, `stale`, `check`,
   or `heartbeat`), handle the wake and then start exactly one new arm. If the
   arm was reaped with no reason, re-arm once after the drain; the new arm will
   attach to the watcher that survived the reap. Never re-arm repeatedly while
   the existing cycle is still healthy.

`fm-watch-arm.sh` launches `fm-watch.sh` in its own session and process group.
If Grok reaps the arm, the arm's follower dies but the watcher keeps its
`state/.watch.lock`, fresh `state/.last-watcher-beat`, and durable wake queue.
The next arm attaches to that existing cycle. A second arm that finds a healthy
cycle and another live follower reports the cycle and exits instead of creating
another hour-long waiter.

If Grok's tracked background task is not durable or does not notify reliably,
use the home-scoped runner instead:

```sh
bin/fm-watch-session.sh start
bin/fm-watch-session.sh --status
```

The runner uses the same detached arm path and re-arms immediately after wake
output. Stop only this home's runner with `bin/fm-watch-session.sh stop`.

Away mode remains a separate residual on this fork. It has
`bin/fm-supervise-daemon.sh` and the `afk` skill, but no `fm-afk-start.sh`
detached entrypoint. This change covers the watcher and normal Grok background
arms only; it does not claim that reaping an away-mode daemon is fixed.
