# Primary `cd` guard

`bin/fm-cd-pretool-check.sh` is a small PreToolUse seatbelt for the primary
Firstmate checkout.
It denies a persistent top-level `cd projects/<clone>` or `pushd projects/<clone>`
before the command runs.

The guard is scoped to a normal checkout whose git directory is also its common
directory.
Linked crewmate and scout worktrees are therefore inert, so a worker can change
directory inside its own worktree.
Commands in a subshell, such as `(cd projects/<clone> && command)`, do not move
the parent shell and are allowed.
Unrelated commands and changes to directories outside `projects/` are allowed.

`bin/fm-cd-command-policy.mjs` owns the lexical decision.
It never evaluates, expands, sources, or executes submitted command text.
`bin/fm-cd-pretool-check.sh` owns stdin extraction, primary scoping, and the
exit/output transport used by harness hooks.

## Hook snippets

The tracked snippets in `.grok/hooks/fm-primary-cd-check.json` and
`.codex/hooks.json` show the verified JT Grok and Codex hook shapes.
They are project-local snippets for explicit harness configuration; this PR does
not write to a user's managed global hook directory or enable a hook outside the
checkout.
No Herdr, cmux, or zellij hook is included.

## Manual checks

From the primary checkout:

```sh
bin/fm-cd-pretool-check.sh --command 'cd projects/example'
bin/fm-cd-pretool-check.sh --command 'cd /tmp'
```

The first command exits `2` and the second exits `0`.
