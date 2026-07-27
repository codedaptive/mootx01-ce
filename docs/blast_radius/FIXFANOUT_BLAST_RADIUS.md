---
version: v0.1
mission: fix-fanout
stream: stream/fix-fanout
branch: stream/fix-fanout
date: 2026-07-27
---

# Blast Radius Report — fix-fanout: Restore ingest fan-out to CorpusContentEngine queue drain

## Baseline

- Swift test pass count at mission start: **393**
- Command: `cd /Users/bob/devlop/mootx01-ce-fix-fanout && nice -n 19 swift test --package-path packages/kits/CorpusKit`
- Rust test run: pending (cargo test after implementation)

---

## Scope Summary

The 1.1.x `CorpusContentEngine` queue drain (`drainContentQueueOnce`) processes
embedding jobs serially. The 1.0.x `Corpus.ingestBatch` used a
`boundedConcurrentMap` fan-out capped at `activeProcessorCount` — producing ~4x
throughput on multi-core hardware. This mission restores the fan-out to the 1.1.x
queue drain path, plus hoists `registerClaims` (Cause 2) and batches
`vectorStore.addPayloads` + `coverageStore.markCovered` (Cause 5) out of the per-job
loop.

---

## Symbols Being Changed

### Symbol 1: `drainContentQueueOnce()` — `CorpusContentEngineQueue.swift`

**Change class:** semantic (implementation rewritten; signature and return type unchanged)
**Scope:** internal (extension on public actor, callable within module and tests)

#### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `CorpusContentEngineQueue.swift` | 198 | codegraph | MUST_UPDATE | Only caller — the drain loop; implementation rewrite is the mission |
| `CorpusContentEngineTests.swift` — *via queue mount/drain* | various | grep | INTENTIONALLY_LEFT | Tests call `mountIngestQueue` + `enqueueChange` + `awaitIngestDrain`; the contract (same indexed outputs) is preserved |

**Summary:** 1 MUST_UPDATE (the function itself), all test callers are INTENTIONALLY_LEFT
(contract preserved, output byte-identical).

---

### Symbol 2: `StructuralProvider` — `CorpusContentEngine.swift`

**Change class:** access level private → internal (additive — no callers break)
**Scope:** private (file-scope), becoming internal

#### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `CorpusContentEngine.swift` ~line 682 | inline | grep | INTENTIONALLY_LEFT | Only use is inside `indexWholeContentBatch` in the same file — access level change is additive |

**Summary:** 0 MUST_UPDATE; access widening is safe.

---

### Symbol 3: `PreparedStructuralRecord` — `CorpusContentEngine.swift`

**Change class:** access level private → internal (additive)
**Scope:** private (file-scope), becoming internal

#### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `CorpusContentEngine.swift` ~line 723–746 | inline | grep | INTENTIONALLY_LEFT | Only use is inside `indexWholeContentBatch` in the same file — access level change is additive |

**Summary:** 0 MUST_UPDATE; access widening is safe.

---

### Symbol 4: `embedQueueRecords(records:slotScope:cap:now:)` — `CorpusContentEngine.swift`

**Change class:** new symbol (additive — no existing callers)
**Scope:** internal

**Summary:** New function, no blast radius.

---

### Symbol 5: `drain_content_with_queue` — Rust `content_engine_queue.rs`

**Change class:** semantic (implementation rewritten; signature unchanged)
**Scope:** `pub(crate)`

#### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `content_engine_queue.rs` ~line 260 | codegraph | MUST_UPDATE | Only caller — `drain_content_queue_once`; implementation rewrite is the mission |
| `content_engine_queue.rs` ~line 428 | codegraph | MUST_UPDATE | Also called from `run_content_drain_loop`; implementation rewrite is the mission |

**Summary:** 2 MUST_UPDATE (function itself + its two callers, which are both in the same file and share the new implementation).

---

## Non-code references

| File | Reference | Classification | Justification |
|---|---|---|---|
| `docs/engineering/substrate_reference/` | No spec references to `drainContentQueueOnce` | INTENTIONALLY_LEFT | Internal implementation — no spec governs the internal drain schedule |

---

## RESCOPE_REQUIRED

None.

---

## Causes 3 and 4 (deferred follow-ups)

- **Cause 3** (`commitQueueBatch` O(N×slots) query amplification): not addressed in this mission — would require a transactional batch-upsert path in the counts store. Defer.
- **Cause 4** (`source.record(for:)` re-fetching): partially mitigated — Phase 1 fetches each record once per drain pass, same as before. The queue payload does not carry inline text (by design). Defer inline-carry as a future optimization.

---

## Test Verification (preliminary)

```
Baseline: 393 tests pass
Expected post-implementation: ≥ 393 tests pass + new structural equivalence test
```

---

## Supplemental: JacobiSVD parallel-chunking crash (Kinsta diagnosis, 2026-07-27)

**Baseline (SubstrateML):** 486 tests pass.  
**Machine:** 18 CPU (Darwin 27.0.0) — `ProcessInfo.processInfo.activeProcessorCount = 18`.

### Symbol 6: `JacobiSVD.decompose` parallel loop body — `JacobiSVD.swift` line ~214

**Change class:** bug fix — add `guard lo < hi else { return }` guard before range construction  
**Scope:** private (inside `decompose` static method body, not a named symbol)

**Root cause:** `DispatchQueue.concurrentPerform(iterations: chunkCount) { ci in }` spawns
`chunkCount = min(workers, round.count)` iterations. With ceiling-division chunk size
`per = (round.count + chunkCount - 1) / chunkCount`, trailing iterations get
`lo = ci * per > round.count`, so `hi = min(lo + per, round.count) < lo`. Swift's
`lo..<hi` Range precondition requires lowerBound ≤ upperBound and traps when violated.
Latent since 5edc7bb6 (parallel tournament SVD); exposed by batchTrainIfNeeded growth
retrains (n ≥ 38 on an 18-core box triggers round.count > workers).

#### Call sites (code)

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `JacobiSVD.swift` | ~214 | code | MUST_UPDATE | The guarded line itself — the fix |
| `JacobiSVDTests.swift` | new | additive | MUST_UPDATE | New regression test exercising the n=64 path |

**Summary:** 1 MUST_UPDATE (guard added), 1 additive test.

---

### Symbol 7: `wait_for_encode_drain` — Rust `encode_barrier.rs`

**Change class:** bug fix — detect fatal transport errors (broken pipe / stream closed) and abort early rather than retrying until timeout  
**Scope:** `pub`

#### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `encode_barrier.rs` | ~88 | code | MUST_UPDATE | Error arm — add fatal-transport detection |

**Summary:** 1 MUST_UPDATE.

---

### Symbol 8: `waitForEncodeDrain` — Swift `EncodeBarrier.swift`

**Change class:** bug fix — same fatal-transport early-abort as Symbol 7  
**Scope:** `internal`

#### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `EncodeBarrier.swift` | ~107 | code | MUST_UPDATE | catch block — add fatal-transport detection |

**Summary:** 1 MUST_UPDATE.
