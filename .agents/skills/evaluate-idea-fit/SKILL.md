---
name: evaluate-idea-fit
description: Research and evaluate an external idea, repository, product, workflow, integration, or downstream ripple against Cedrick's real current structure, then recommend Adopt, Trial, Borrow, or Reject. Use when Cedrick supplies a link or names a candidate and asks whether it fits, is worth integrating, duplicates the current stack, creates useful ripple effects, or merits a grounded repo/post/video comparison; also use for recurring prompts such as "analyse cette idee", "evalue cette integration", "regarde ce repo", "compare-le a ce qu'on a", or "quel ripple est-ce que ca cree".
---

# Evaluate Idea Fit

Turn a link or named candidate into an evidence-backed decision relative to the
actual target system. Research first, compare candidate and incumbent at the
same level, and keep implementation outside scope unless the user authorizes it.

## Establish the decision frame

1. Restate the candidate, decision to make, requested artifacts, constraints,
   and done-when condition.
2. Name one **target surface** before researching: for example Codex Desktop,
   OpenClaw, Firstmate, JT Control Room, a specific repository, or an operating
   workflow. Do not silently broaden the comparison to adjacent systems.
3. If the surface is ambiguous but one interpretation is strongly supported by
   the prompt and workspace, state the assumption and proceed. Ask only when
   different surfaces would materially change the result.
4. Track every requested deliverable as `DONE`, `BLOCKED`, or `NOT STARTED`.

## Route rather than duplicate

Load and follow only the specialized skills needed for the active evidence:

- Use `last30days:last30days` for recent community reception, commentary,
  adoption signals, or claims that depend on current discourse.
- Use `github:github` for repository, issue, pull request, release, contributor,
  or activity evidence. Follow the workspace's approved external-repository
  ingress rules when a local clone is genuinely needed.
- Use `openclaw-axi-routing` whenever the target or ripple touches OpenClaw,
  Firstmate, JT Control Room, Axi, tmux, no-mistakes, or their GitHub lanes.
- Use `jt-cbm-orientation` as a read-only orientation aid for JT codebase
  relationships, then verify important hints in source, generated data, served
  output, or runtime as appropriate.
- Use `compound-engineering:ce-explain` only after the evidence and verdict are
  stable, when the user requests a durable visual teaching artifact.

Do not restate those skills' procedures here. If a routed skill is unavailable,
continue with the best read-only method and disclose the degraded evidence.

## Research the candidate before judging it

1. Retrieve the primary post/page and identify every linked repository,
   document, demo, video, release, or benchmark that bears on the claim.
2. For video, obtain a transcript or captions when accessible. Distinguish an
   official transcript from auto-captions, local transcription, and a summary.
   Never reconstruct missing speech as a transcript.
3. Inspect the full candidate scope before narrowing: repository tree, README,
   implementation paths, configuration, dependencies, tests, CI, releases,
   security posture, open issues/PRs, license, and maintenance signals where
   relevant. For catalogues, enumerate all categories before ranking entries.
4. Prefer primary sources for technical facts. Use current official docs for
   auth, limits, pricing, commercial terms, API behavior, and compatibility.
5. Keep a claims ledger with `claim`, `source`, `status`, and `confidence`.
   Mark project-authored performance or adoption claims `UNVERIFIED` unless an
   independent benchmark or reproducible local test corroborates them.
6. Record access gaps explicitly. A blocked post, missing transcript, private
   repo, or unavailable runtime is a limitation, not evidence against the
   candidate.

Do not pivot to architecture or implementation until the requested evidence
pass is complete or formally marked `BLOCKED`.

## Establish the incumbent baseline

Inspect the current target surface rather than comparing against memory or a
generic stack. Use the cheapest authoritative evidence that can drift:

- contracts and conventions: active `AGENTS.md` and narrower repo instructions;
- durable configuration: relevant config, installed skills/plugins, hooks, and
  supported native capabilities;
- repository reality: source, dependency manifests, tests, CI, release state;
- runtime reality: live state and served outputs when the decision depends on
  them.

Separate `already covered`, `partially covered`, `missing`, and `intentionally
excluded`. Distinguish local proof from remote, CI, deployed, and live proof.

## Compare incumbent and candidate

Build one comparison matrix. Adapt dimensions to the target, but cover these
unless genuinely inapplicable:

| Dimension | Incumbent evidence | Candidate evidence | Delta | Score | Confidence |
|---|---|---|---|---:|---|
| User or operator value | | | | 0-5 | low/med/high |
| Unique capability vs duplication | | | | 0-5 | |
| Architectural and workflow fit | | | | 0-5 | |
| Integration and maintenance cost | | | | 0-5 | |
| Security, privacy, and authority risk | | | | 0-5 | |
| Maturity and evidence quality | | | | 0-5 | |
| Reversibility and trialability | | | | 0-5 | |

Define `0` as strongly unfavorable or unsupported and `5` as strongly
favorable with solid evidence. Explain any weighting; do not hide a critical
security, authority, or runtime blocker inside an average. If a percentage is
useful, report `weighted points / maximum points` and label it a decision aid,
not an empirical probability.

Map downstream ripples separately when the candidate affects three or more
surfaces:

| Ripple | Trigger | Affected surfaces | Benefit | Cost/risk | Reversible? | Proof needed |
|---|---|---|---|---|---|---|

Call out the smallest differentiated capability worth preserving even when the
whole candidate is a poor fit.

## Issue one verdict

Choose exactly one primary verdict:

- **Adopt**: proven net-new value, acceptable risk, clear owner and integration
  path, and no cheaper incumbent capability supplies the same outcome.
- **Trial**: promising but uncertain; define a bounded, reversible experiment,
  success metric, time/effort box, stop conditions, and no-production boundary.
- **Borrow**: reject wholesale adoption but adapt one or more specific patterns,
  interfaces, prompts, tests, or architectural ideas into the incumbent.
- **Reject**: duplication, weak evidence, poor fit, excessive cost/risk, or no
  meaningful advantage. State what future evidence could change the verdict.

Do not install, integrate, push, enable hooks, mutate runtime, or open external
PRs as part of evaluation unless the user explicitly authorizes execution.

## Deliver the decision packet

Match the user's language and lead with the verdict. Include:

1. a one-paragraph executive conclusion;
2. deliverable status, including post, transcript, repo, incumbent baseline,
   matrix, ripple map, and explanation artifact when requested;
3. candidate process or architecture in plain language;
4. incumbent-vs-candidate comparison matrix and important ripples;
5. verified facts, unverified claims, and evidence gaps;
6. the verdict with rationale, major risks, and opportunity cost;
7. one recommended next move, including a bounded trial spec for `Trial`;
8. source links or local file references close to the claims they support.

When requested, invoke `compound-engineering:ce-explain` after completing this
packet and base the explanation on the verified comparison and verdict. Do not
let the explanation artifact replace the underlying evidence report.
