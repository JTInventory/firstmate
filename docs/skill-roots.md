# Skill Roots

Firstmate keeps its own skill roots small and explicit.
This note covers the roots that belong to this repository.
It does not audit OpenClaw, global Codex, global agent, plugin-cache, or personal runtime skill folders.

## Canonical

`.agents/skills/` is the canonical Firstmate skill root.
Skills here are tracked with the repo and are part of the shared Firstmate operating surface.

Current Firstmate skills:

- `afk`
- `harness-adapters`
- `secondmate-provisioning`
- `stuck-crewmate-recovery`
- `updatefirstmate`

## Compatibility

`.claude/skills` is a symlink to `../.agents/skills`.
It exists for Claude compatibility and must not diverge from the canonical root.

## Plugin and Global Roots

Plugin and global skill roots are outside this repository.
Firstmate can use them when the running harness exposes them, but they are not Firstmate's source of truth.
Do not copy plugin or global skills into `.agents/skills/` unless the skill is becoming a maintained Firstmate skill.

## Legacy or External Roots

Any OpenClaw, workspace-local, or personal runtime skill folder should be treated as external until a separate read-only scout proves its role.
Do not mark an external root unused, delete it, or sync it with Firstmate based only on matching skill names.

## Invocation Convention

Skill names are shared, but invocation syntax is harness-specific:

- Claude uses `/<skill-name>`.
- Codex uses `$<skill-name>`.
- Other verified harnesses use their native skill invocation surface, or the agent reads `SKILL.md` directly when no slash/dollar surface exists.

Generated Firstmate briefs repeat this convention so workers do not guess.
