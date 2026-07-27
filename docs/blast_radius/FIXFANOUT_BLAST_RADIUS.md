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
