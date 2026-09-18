---
version: 1.0.1
status: accepted
date: 2026-08-16
description: Adoption semantics for pre-anchor sourceless miner facts under the anchor-scoped MinerEngine.
---

# DECISION — Miner sourceless-fact adoption (2026-08-16)

## Context

Codex Security 07e2d3a5 (mission
MOOTX01-EE-CURRENT-CODE-SECURITY-HARDENING-R1) scoped `MinerEngine`
reconciliation to a durable per-miner source-anchor drawer: facts are filed
with `source_id` = the anchor UUID and enumerated via `source_id_exact`. The
base engine filed miner facts SOURCELESS (`sourceDrawerID == ""`), so on an
estate that ran a miner before this change, those rows sit outside the anchor
scope: the first anchored run would re-file every live sample (duplicate
active facts — `captureKGFact` has no subject+predicate+object dedup) and the
old sourceless rows would never retire (Adams post-flight round 1, finding 2).

## Decision (Bob, in-session, 2026-08-16)

**Engine-level adoption sweep.** On every run, for each identity
(subject + predicate) in the run's incoming sample set, the engine fetches
sourceless facts with that exact subject (`subject_exact` +
`source_id_exact:""`, both SQL-indexed) and, once the anchored replacement is
safely in place (filed, or already present unchanged), retires the sourceless
twin. Sourceless facts outside the mined subjects are never even fetched; among
fetched rows, only facts whose full subject+predicate identity is being mined
this run are ever retired — everything else is never touched.

## Accepted consequence

A hand-filed sourceless fact whose subject AND predicate exactly match a
sample the miner is actively mining is indistinguishable from the miner's own
pre-anchor output and is adopted (retired in favor of the anchored fact).
This is judged acceptable: the collision requires manually reproducing a
miner's exact machine-generated identity (e.g. `health.weight.2026-07-07` +
`measured`), and the adopted content is replaced by the live platform truth
for that same identity. Sourceless facts with any other subject or predicate
are structurally outside the sweep and always survive.

## Changelog

- 1.0.1 (2026-08-16): Precision fix (Adams round 2): same-subject
  different-predicate sourceless facts ARE fetched by the subject-scoped
  query and never retired; only facts outside the mined subjects are never
  fetched at all.
- 1.0.0 (2026-08-16): Initial decision, recorded during
  MOOTX01-EE-CURRENT-CODE-SECURITY-HARDENING-R1.
