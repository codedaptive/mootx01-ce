# Mission MATRIXT_LIFECYCLE_AUDIT_001 — Trace MatrixT's Real Data Flow and Write a Lifecycle Memo

## Priority: P3
## Stream: mt
## Branch from: main
## Depends on: None
## Parallel safe with: everything — read-only; reserves only the memo path.

---

## Context

**Tree.** This mission targets **mootx01-ce**, base branch **main**.

**Read-only scout.** MatrixT — the lagged *causality* matrix — is referenced across SubstrateTypes, SubstrateLib, and GeniusLocusKit, but its **production write-path is not yet confirmed**. This mission traces the real data flow and writes a one-page memo. **No code changes.** It is investigation, not implementation: there is no Part-0-then-code; the audit *is* the work.

**Why now.** `ar` and `fa` deferred sequential/causal mining because MatrixT's status was not pinned down. Before any future sequential-mining mission, MatrixT's actual lifecycle needs to be on record: is it fed by the live verbs, only by GLK training, or only by tests; how is its decay applied; does it round-trip in the estate snapshot. A prior assumption that MatrixT is "unpopulated" is **too strong** — it is tested, persisted, and consumed by GeniusLocusKit. The real question is narrower and is the point of this scout.

## Known Ambiguities
The scout exists to resolve these; they are recorded, not hidden, and each is answered in the memo with `file:line` evidence rather than assumed:
- Whether the estate's `matrixT` is fed by the live verbs. The pre-flight found `var matrixT` declared and initialized in `Verbs.swift` but **no** `applyPair`/`increment` call on it in capture/mutate/expunge. Status: to be traced through the verb call chain.
- Whether and where the 90-day decay half-life is actually applied (a decay tick that reaches MatrixT), versus defined-but-uncalled.
- Whether MatrixT round-trips in the estate snapshot, or only via GLK's `MatrixPersistence`.

## Preliminary findings (from a pre-flight scan — confirm, correct, and extend; do NOT take as ground truth)
- **Defined:** `libs/SubstrateTypes/Sources/SubstrateTypes/MatrixT.swift`. `MatrixT: Sendable, Equatable`; keyed by `CausalityKey(sourceField, sourceValue, targetField, targetValue, lagBucket: 0..7)`; lag buckets in minutes `[1,2,4,8,16,32,64,128]`, `maxLagMinutes 256`. API: `count(_:)`, `increment(_:by:)`, `applyPair(...)`, `entries`, `reset()`, `writeWire(into:)`.
- **Decay:** the file states *"T HAS decay (cookbook §6.8), half-life 90 days"* — unlike `MatrixF` (no decay). Find where/when the half-life is actually applied.
- **Verb surface:** `SubstrateLib/Verbs.swift` declares `public var matrixT: MatrixT` and initializes `self.matrixT = MatrixT()`, but the scan found no `applyPair`/`increment` call on that instance in capture/mutate/expunge. Confirming whether the verbs populate MatrixT at all is the central question.
- **Consumers (read path):** GeniusLocusKit — `Matrix/MatrixTier.swift`, `Training/EnrichmentPipeline.swift`, `Training/TrainingDaemon.swift`, `Training/ThresholdGate.swift`, `Audit/AuditBridge.swift`, `Matrix/MatrixPersistence.swift`. Map what each does with MatrixT.
- **Tests:** `SubstrateTypesTests/MatrixTTests.swift` (~21 references) and `GeniusLocusKitTests/MatrixTierTests.swift` (~13) lock the most invariants — read them for the intended contract.

## Implementation Parts

### Part 1 — Trace the write path (the central finding)
Grep `Verbs.swift` and the capture/mutate/expunge call chain for any `applyPair`/`increment` on the estate's `matrixT`. Determine definitively whether the verbs feed it. Classify the result: **live-verb-fed / GLK-training-fed / test-only.** This is the load-bearing finding; everything else hangs off it. Capture `file:line` evidence for whatever populates MatrixT in production (or proof that nothing does).

### Part 2 — Map read path, decay, and persistence
For each GLK consumer (`MatrixTier`, `EnrichmentPipeline`, `TrainingDaemon`, `ThresholdGate`, `AuditBridge`, `MatrixPersistence`), record what MatrixT is read *for* and which would silently degrade if it were empty. Locate where and when the 90-day decay half-life is applied, or confirm it is defined-but-uncalled. Determine whether MatrixT round-trips in the *estate* snapshot (`writeWire`/`readWire` on the main path) or only via GLK's `MatrixPersistence`, and what survives a restart. Cite `file:line` for each.

### Part 3 — Record shape and coverage, reach a verdict, write the memo
Confirm the definition and shape (key, lag-bucketing, decay half-life). Record what `MatrixTTests`/`MatrixTierTests` lock and what they do not (e.g., the verb-write-path, decay-over-time). Then write the one-page memo at the path: a one-paragraph verdict up top — **(a) live production infrastructure, (b) GLK-training-only, or (c) partially-wired (held but unfed in the main estate)** — followed by the findings with `file:line` evidence, and a short minimal "to activate for sequential mining" list (e.g. wire `applyPair` into the verbs, add a decay tick, include it in the snapshot — whichever the evidence shows is missing).

## Files You Will Modify
- `docs/_internal/workhistory/analysis/MATRIXT_LIFECYCLE_AUDIT.md` — the one-page memo (create; the only write).

## Files You MUST NOT Modify
- Everything else. This is a read-only audit: no source, no tests, no `Package.swift`, no other docs. If the audit reveals a bug or a missing wire, the memo **recommends** a follow-on mission; it does not fix anything here.

## Deliverable shape (one page)
One-paragraph verdict up top (live / GLK-only / partially-wired), then the findings with `file:line` evidence, then a short "to activate for sequential mining" list. Keep it to a page; link, don't quote.

## Verification
The memo exists at the path, opens with the verdict, answers the write-path / read-path / decay / persistence / coverage questions with concrete `file:line` citations, and ends with the activation list. No code or test file changed (`git status` shows only the memo). No implementer is spawned — this is a scout; the only artifact is the memo.

## Success Criteria
1. The memo answers definition, write path, read path, decay, persistence, and test coverage, each with `file:line` evidence.
2. The write-path question (does a verb actually feed MatrixT?) is answered **definitively**, not hedged.
3. A clear verdict plus a minimal-activation list for sequential mining.
4. Zero code/test changes.

## Non-goal / deferred
Fixing any wire gap the audit finds (→ a follow-on mission); implementing sequential/causal mining; touching GLK. The memo recommends; it does not repair.

## Signal File
Write to: `/Users/bob/devlop/ddfactory/control/signals/.done-mt`
