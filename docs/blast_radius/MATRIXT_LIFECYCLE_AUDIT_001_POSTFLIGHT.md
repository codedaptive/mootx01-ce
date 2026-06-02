# Adams Post-Flight: MATRIXT_LIFECYCLE_AUDIT_001

**Date:** 2026-06-01
**Reviewer:** Adams
**Mission:** Trace MatrixT's Real Data Flow and Write a Lifecycle Memo
**Branch:** stream/mt-matrixt-lifecycle-audit
**Baseline:** 4ef8a05 · **Head:** 37fefd2 (single commit)

---

## Final Status: PASS

---

## Blast Radius Verification

**§9.1 — Diff scope (BLOCKING CHECK)**

```
git diff 4ef8a05..37fefd2 --stat
```

Result: 3 files, all docs. No source, no tests, no Package.swift touched.

| File | Disposition |
|---|---|
| `docs/_internal/workhistory/analysis/MATRIXT_LIFECYCLE_AUDIT.md` | MISSION DELIVERABLE — expected |
| `docs/blast_radius/MATRIXT_LIFECYCLE_AUDIT_001_PREFLIGHT.md` | Standard lifecycle artifact — expected |
| `docs/missions/inflight/MISSION_MATRIXT_LIFECYCLE_AUDIT_001.md` | Standard lifecycle artifact — expected |

**PASS. Zero source/test/Package.swift in the diff.**

**§9.2 — Memo path resolution**

Smythe flagged the mission's `docs/_internal/workhistory/analysis/` path as having no repo precedent. The implementer wrote to the mission's stated path verbatim and recorded the warning in the pre-flight. The path is now established. No blocking issue.

**§9.3 — Prohibited patterns**

Grep for bridges, shims, legacy, compat, `@available.*deprecated` in diff: N/A — no executable code changed. Not applicable to a docs-only commit.

---

## §10 Test Execution Verification

**Method: N/A — no code changed.**

The diff is three documentation files. No Swift source, test, or Package.swift file was modified. There is no "tests pass" claim to verify and no re-run warranted. Verified by inspection of `git diff 4ef8a05..37fefd2 --stat`.

---

## Memo Verification — Six Spot-Checks Plus Structural

### Structural checks

**Verdict present at top:** Yes. Opens with "(c) Partially-wired — held but unfed, and additionally unread." Definitive, not hedged. Mission required this; it delivers.

**Write-path question answered definitively:** Yes. "No verb feeds MatrixT" with specific file:line evidence and explicit "test-only" classification.

**Activation list present at end:** Yes. Five-item minimal list (pick one store, wire feed, call decay, persist, lock it).

**All six mission questions answered:** Definition ✓, write path ✓, read path ✓, decay ✓, persistence ✓, test coverage ✓. Each with file:line evidence.

### File:line spot-checks (6 of the memo's ~25 citations verified against source)

| # | Memo claim | Verified? | Note |
|---|---|---|---|
| 1 | `Verbs.swift:83` — `public var matrixT: MatrixT` | **CONFIRMED** | Exact line |
| 2 | `Verbs.swift:93` — `self.matrixT = MatrixT()` | **CONFIRMED** | Exact line |
| 3 | `MatrixTier.swift:255` — `applyTemporalEvent` | **CONFIRMED** | Exact line |
| 4 | `MatrixTier.swift:287` — `applyDecay` | **CONFIRMED** | Exact line |
| 5 | `MatrixT.swift:43` — `CausalityKey` struct | **CONFIRMED** | Exact line |
| 6 | `MatrixTier.swift:173` — `temporalWindowMinutes` | **CONFIRMED** | Exact line |
| 7 | `MatrixPersistence.swift:58` — `MatrixSnapshot` struct | **CONFIRMED** | Exact line |
| 8 | `EnrichmentPipeline.swift:171` — `beforeTCount` | **CONFIRMED** | Exact line |
| 9 | `EnrichmentPipeline.swift:292` — `tDelta` post-pass | **CONFIRMED** | Exact line |
| 10 | `MatrixTierTests.swift:132,136` — only `applyTemporalEvent` callers | **CONFIRMED** | Both lines are the only production+test callers; memo's "only callers" claim holds |
| 11 | `MatrixTierTests.swift:195` — `snapshottedModeRoundTripsExactly` | **CONFIRMED** | Exact line |
| 12 | `MatrixTTests.swift` "5 tests, lines 14–66" | **CONFIRMED** | Five `@Test` funcs; range accurate |

### Substantive claims verified against source

**"GLK has no `MatrixT\b` or `CausalityKey` references":** Confirmed via grep of `packages/kits/GeniusLocusKit/Sources/` — zero hits for either symbol.

**"Only two references to `matrixT` instance in entire repo (Verbs.swift:83, :93)":** Confirmed. Grep for `.matrixT` and `matrixT` in SubstrateLib returns only those two lines. Zero hits in `apps/`.

**"`applyDecay` has zero callers repo-wide":** Confirmed. Grep for `applyDecay` across all Swift sources returns only the definition at `MatrixTier.swift:287`. No callers in tests or production.

**"`writeWire`/`readWire` have no callers outside SubstrateTypesTests":** Confirmed. Grep for these methods in non-test, non-MatrixT.swift contexts returns only `MatrixC.swift`'s own same-named methods — those are distinct methods on a different type, not callers of MatrixT's wire methods.

**"Rebuild feeds F/O only, never calls `applyTemporalEvent`":** Confirmed by reading `MatrixTier.rebuild(from:)` (line 329 onward) — calls only `applyCapture`, no T-feed path.

**"Half-life conflict: MatrixDecay.swift says T τ=30 days; MatrixT.swift:31 and MatrixTier.swift:285-291 say 90 days":** Confirmed. `MatrixDecay.swift:21` reads `T matrix (temporal causality): τ = 30 days`; `MatrixT.swift:31-33` says 90 days; `MatrixTier.swift:283-291` docstring says "T half-life is 90 days" and default parameter is `tHalfLifeDays: 90.0`. Three-way conflict: 30 in MatrixDecay vs 90 in both MatrixT and MatrixTier.

**"Bucket-convention divergence: MatrixT round-down (index 1) vs MatrixTier round-up (value 4) at input=3":** Confirmed. `MatrixTTests.swift:19` asserts `lagBucket(forMinutes: 3) == 1` (Optional UInt8). `MatrixTierTests.swift:126` asserts `MatrixTier.lagBucket(forMinutes: 3) == 4` (Int, returning the boundary value). Different semantics, different return types — both tests pass, both lock in the divergence.

**"MatrixTier.temporalCausality is `[MatrixTemporalKey: Int64]` at line 158":** Confirmed.

**"`addT` at MatrixTier.swift:439":** Confirmed.

---

## Findings

| # | Severity | Finding | File:Line | Resolution |
|---|---|---|---|---|
| 1 | INFO | Memo written to `docs/_internal/workhistory/analysis/` — a new directory tree with no prior repo precedent. Smythe flagged it YELLOW; implementer followed the mission path verbatim and recorded the warning. The path now exists and is in version control. | `docs/_internal/workhistory/analysis/MATRIXT_LIFECYCLE_AUDIT.md` | No action required. Bob confirmed the mission path; the implementer honored it. If `docs/analysis/` is the canonical analysis home, a follow-on doc hygiene note to the mission template is appropriate but does not block this review. |
| 2 | INFO | The memo's Finding §6 documents the bucket-convention divergence (MatrixT returns UInt8 bucket index 0-7; MatrixTier returns Int boundary value 1-128) but does not explicitly flag this as a correctness risk for any future daemon pass that feeds both stores from a shared lag-minutes input. The finding is present and accurate; it could have sharpened the activation-list item #1 ("pick one store") with a note that the bucket APIs are not duck-typed compatible. | `MATRIXT_LIFECYCLE_AUDIT.md:46` | INFO only. The memo covers it; the activation list flags "pick one T store" as the blocker. No follow-on action required from this review. |

---

## Summary

Zero CRITICAL. Zero WARNING. Two INFO findings, neither blocking.

**Scope:** Clean. Three doc files. No source touched.

**Test execution:** N/A, verified by diff.

**Memo quality:** The file:line citation accuracy is high — every spot-checked claim holds against the live source. The substantive findings (no verb feeds MatrixT, no GLK consumer uses the type, applyDecay has zero callers, bucket conventions diverge, half-life conflict) are all confirmed by independent grep and source reads. The verdict ("partially-wired — held but unfed, and additionally unread") is correct, precise, and an improvement on the pre-flight's prior assumption. The activation list is appropriately minimal.

**Clean. Ship it.**
