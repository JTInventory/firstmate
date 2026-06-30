# Cognee Policy

Cognee is a trial memory layer for Firstmate. It can provide context hints, but
it is not a source of truth, durable archive, proof system, or action authority.

## Current Contract

- Use Cognee only through explicit, read-only, manual lookup flows unless the
  automatic gate passes.
- Treat every Cognee answer as a hint until a local source file is reopened and
  verified through the local manifest/source-verification path.
- Never use Cognee output to authorize merges, deploys, refreshes, imports,
  deletes, purchases, vendor/customer actions, or any other external action.
- Do not log raw answer bodies, question bodies, context bodies, auth headers,
  base URLs, secret values, or raw session JSON.

## Docs Audit Update

The June 2026 official-docs audit clarified two important points:

- Cognee documents raw data listing and raw data download endpoints, and
  `memory_only=True` deletion preserves raw files/records for reprocessing.
- Cognee documents Cloud pricing and session/model cost surfaces.

Those facts improve the trial picture, but they do not promote Cognee to
production memory for Firstmate.

## Still Blocked

Automatic lookup still requires all existing gate evidence plus:

- a vendor- or docs-backed raw retention, durability, health, restore, and
  source-authority guarantee strong enough for Firstmate;
- safe per-wrapper-call cost correlation from one Firstmate lookup to one
  Cognee request/session/QA/cost record without reading or storing sensitive
  answer, question, or context bodies.

Until both are proven, use this wording:

- Raw readback is documented, but Cloud raw retention/source-of-truth
  guarantees remain unproven for Firstmate.
- Pricing and session/model cost surfaces are documented, but safe
  per-wrapper-call cost correlation remains unproven for Firstmate.

## API Posture

Cognee v1.0 presents `remember`, `recall`, `improve`, and `forget` as the main
memory lifecycle. Firstmate currently uses the documented lower-level
`POST /api/v1/search` path intentionally because the pilot needs explicit,
read-only search control and local source verification.

## Operational Helpers

- `fm-cognee-lookup-gate.sh manual-verified` prints the manual contract:
  read-only, hint-only, fail-closed, local-source-required, and no external
  action authority.
- `fm-cognee-lookup-gate.sh automatic` fails closed unless
  `FM_COGNEE_AUTO_LOOKUP=1` and the local evidence set proves every gate marker,
  including `FM_COGNEE_GATE_COST_USAGE_EVIDENCE=per_wrapper_call` and
  `FM_COGNEE_GATE_RAW_DURABILITY_SOURCE_AUTHORITY=pass`.
- `fm-memory-lookup.sh` is the manual pre-dispatch helper.
  It is not wired into automatic dispatch, and missing or failing lookup does
  not block work.
- `fm-cognee-lookup.sh`, `fm-cognee-manifest-check.sh`, and
  `fm-cognee-verify-source.sh` keep Cognee answers advisory by reopening local
  source references before any hint can be attached.
- `fm-cognee-session-cost-probe.sh` is disabled-by-design planning support for
  a separately approved live probe lane; it writes redacted local JSONL probe
  plans and makes no network calls itself.
