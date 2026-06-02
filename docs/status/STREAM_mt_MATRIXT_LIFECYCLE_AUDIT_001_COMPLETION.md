# COMPLETION: MATRIXT_LIFECYCLE_AUDIT_001 — Trace MatrixT's Real Data Flow and Write a Lifecycle Memo

**Status: COMPLETE**
Stream: mt · Branch: `stream/mt-matrixt-lifecycle-audit`
Baseline: `4ef8a05` · Head: `37fefd2` (memo commit; lifecycle docs follow in the report commit)
Mission: `docs/missions/inflight/MISSION_MATRIXT_LIFECYCLE_AUDIT_001.md`
Date: 2026-06-01

---

## Summary

Read-only scout, completed. The memo at
`docs/_internal/workhistory/analysis/MATRIXT_LIFECYCLE_AUDIT.md` answers all
six mission questions (definition, write path, read path, decay, persistence,
test coverage) with `file:line` evidence and opens with the verdict:

**(c) Partially-wired — held but unfed, and additionally unread.**
`SubstrateTypes.MatrixT` is fully implemented, unit-tested (5 Swift tests +
5 Rust `#[test]` mirror), and declared in the estate (`Verbs.swift:83,:93`),
but **no production path writes, reads, decays, or persists it** — the
instance has exactly two references in the entire repo (decl + init).
Classification: **test-only** (not live-verb-fed, not GLK-training-fed).

The load-bearing correction to the mission's preliminary findings: the six
listed "GLK consumers" were **substring matches** (`MatrixTier`,
`MatrixTemporalKey`, `MatrixDecay`, `MatrixPersistence`) — GLK never touches
`MatrixT` or `CausalityKey`. GLK carries its own *parallel*
temporal-causality store (`MatrixTier.temporalCausality`), which is itself
production-unfed: its only feed primitive `applyTemporalEvent`
(`MatrixTier.swift:255`) is called solely from `MatrixTierTests.swift:132,136`,
and its decay `applyDecay` (`MatrixTier.swift:287`) has **zero callers
repo-wide, including tests**. Bonus findings: a three-way half-life doc
conflict (T τ=30d in `MatrixDecay.swift:21` vs 90d in `MatrixT.swift:31` and
`MatrixTier.swift:285-291`) and incompatible lag-bucket conventions between
the two stores (round-down index vs round-up boundary).

## What Was Done

- **Parts 1–3 (audit + memo)** — `37fefd2`
  (`docs(matrixt): lifecycle audit memo — MatrixT held-but-unfed; GLK T-tier
  parallel and test-only`)
  - Part 1 — write path traced: capture/mutate/expunge update F and O only
    (`Verbs.swift:141-147,154,250-267,335-343`); no `applyPair`/`increment`
    on the estate's `matrixT` anywhere. Answered definitively, not hedged.
  - Part 2 — read path mapped for all six named GLK files (none read
    MatrixT; per-file roles recorded in the memo §3); decay located as
    defined-but-uncalled (`applyDecay`, zero callers); persistence:
    `MatrixT.writeWire/readWire` have no callers outside
    `SubstrateTypesTests` — no estate snapshot includes any matrix; GLK's
    `MatrixSnapshot` persists the parallel tier only, and its cold-start
    `rebuild` cannot reconstruct T from the log.
  - Part 3 — shape confirmed, test coverage mapped (what
    `MatrixTTests`/`MatrixTierTests` lock vs. what nothing locks: verb→T
    path, decay-over-time, T-populated round-trip), memo written with
    verdict + 5-item minimal-activation list for sequential mining.
- **Lifecycle docs** — Smythe pre-flight + inflight mission committed with
  the memo; Adams post-flight + this report in the report commit.

## Test Verification Log

**N/A — zero executable code changed.** This was a docs-only scout;
`git diff 4ef8a05..37fefd2 --stat` shows exactly 3 files (memo, Smythe
pre-flight, inflight mission), all under `docs/`. No source, no tests, no
`Package.swift`, `docs/validation/**` untouched. No "tests pass" claim is
made or needed; Adams §10 independently confirmed N/A status from the diff.

## Smythe Pre-flight

Verdict: **YELLOW — proceed**, one warning, no blockers.
(`docs/blast_radius/MATRIXT_LIFECYCLE_AUDIT_001_PREFLIGHT.md`)
- Resolved real paths: mission paths omit the `packages/` prefix; all 11
  files confirmed present under `packages/libs/...` and `packages/kits/...`.
- Confirmed the central preliminary finding: `matrixT` declared+initialized
  in `Verbs.swift` with zero `applyPair`/`.matrixT` hits elsewhere in
  SubstrateLib.
- **Warning (the YELLOW):** memo path `docs/_internal/workhistory/analysis/`
  has no precedent in this CE repo (`docs/analysis/` is the convention).
  Resolution: the mission explicitly reserves that exact path as the only
  permitted write, so it was followed verbatim; flagged here for Bob/Nagatha
  to relocate post-merge if CE convention should win.
- No conflicting branches, no prior MatrixT memo, no prerequisites.

## Adams Post-flight

Verdict: **PASS.** Both blocking checks PASS, findings INFO-only.
(`docs/blast_radius/MATRIXT_LIFECYCLE_AUDIT_001_POSTFLIGHT.md`)
- **§9 Blast Radius Verification: PASS** — diff is exactly the 3 doc files;
  zero source/test/Package.swift/validation changes.
- **§10 Test Execution Verification: N/A-PASS** — no executable code
  changed, confirmed from the diff; no test claim made.
- **Memo verification:** 12 of ~25 `file:line` citations independently
  spot-checked against live source — all 12 exact. Key claims re-verified by
  Adams's own greps: `matrixT` two-reference claim, `applyTemporalEvent`
  test-only callers, `applyDecay` zero callers, no production
  `writeWire`/`readWire`, GLK zero `MatrixT\b`/`CausalityKey`, the 30d/90d
  half-life conflict, and the bucket-convention divergence.

### Adams findings resolution
| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | INFO | Memo path is a new directory tree with no repo precedent | Expected — mission-specified path honored; Smythe warning recorded above for post-merge placement decision. |
| 2 | INFO | Activation-list item #1 could explicitly note the two lag-bucket APIs are semantically incompatible | Cosmetic; the divergence is recorded in memo §6 with both citations and test locks. Left as-is to keep the memo to one page. |

No CRITICAL or WARNING findings. Hard gate satisfied before signal.

## Self-review

- Diff matches the mission's reservation exactly: the memo is the only
  deliverable write; pre-flight/post-flight/mission/this report are standard
  lifecycle artifacts (same pattern as `STREAM_smltest_SML_TEST_01_COMPLETION.md`).
- All four success criteria met: (1) six questions answered with `file:line`;
  (2) write-path answered definitively — no verb feeds MatrixT, ever;
  (3) clear verdict (c) + 5-item activation list; (4) zero code/test changes.
- The audit corrected, not just confirmed, the mission's priors: the
  "consumer" list was substring noise, and the real finding is *two* parallel
  unfed T implementations with conflicting half-life docs and incompatible
  bucket conventions — recorded as the first activation blocker.
- No fixes attempted (non-goal honored); the memo recommends follow-on work
  only.

## Conditional lifecycle agents — evaluated

- **Kong — NOT spawned.** No design decision made; read-only audit. (The
  memo's activation item #1 — pick one T store — is flagged as a future Kong
  candidate when the sequential-mining mission is authored.)
- **Simms / Friedlander / Nert — N/A.** No user-facing behavior, no views.
- **Perkins — N/A.** No sensitive surface touched; docs-only.
- **Nagatha docs-repo sync — deferred to post-merge** per standard flow;
  note the `docs/_internal/` placement question for her.

## Discoveries

- **Substring-match hazard in mission pre-scans:** all six "GLK consumers"
  of MatrixT were `MatrixT*`-prefix substring hits. Word-boundary greps
  (`MatrixT\b`) flipped the read-path answer entirely. Worth baking into
  future scout missions.
- **Two parallel temporal-causality implementations exist** (SubstrateTypes
  `MatrixT` keyed by `CausalityKey`; GLK `MatrixTier.temporalCausality`
  keyed by `MatrixTemporalKey`), both production-unfed, with **incompatible
  lag-bucket conventions** (round-down index 0..7 vs round-up boundary
  1..128) and a **three-way half-life doc conflict** (30d vs 90d vs 90d).
  Any sequential-mining mission must start by reconciling these.
- **GLK's `rebuild(from:)` cannot reconstruct T from the audit log** — only
  F/O fold paths exist — so even snapshotted T data is unrecoverable after
  a snapshot loss. Affects the persistence design of any activation mission.

## Outstanding (out of scope — not addressed)

- Wiring the dreaming-daemon pair-mining pass, decay tick, and T
  persistence — the memo's activation list; each is a follow-on mission.
- Relocating the memo if `docs/analysis/` is ruled the canonical CE home
  (Smythe warning; Nagatha placement call).
