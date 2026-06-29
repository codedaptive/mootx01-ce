# VectorKit Changelog

## 2026-06-28 — SECFIX-PUNT-VECTOR: Planned security hardening

**Branch:** `secfix/punt-vector`

Two planned security hardening items implemented across Swift and Rust ports.
Framed as planned data-integrity hardening; both findings were internal to
VectorKit and required no callers to change.

### F1 — MIH itemID-collision: distinct co-item vectors now retained independently

**Surfaces:**
- Swift: `MIHIndex` (`MIHIndex.swift`), `BruteForceIndex` (`BruteForceIndex.swift`)
- Rust: `MIHIndex` (`engine/mih.rs`), `BruteForceIndex` (`engine/brute_force.rs`)

The `vectors` table UNIQUE constraint is `(item_id, vector_index, model_id)`.
Two rows sharing `item_id` but differing in `vector_index` or `model_id` are
distinct records (e.g. multi-vector ColBERT encodings or dual-model indexing).
Prior to this change, MIHIndex keyed its internal structures — the band-hash
posting lists (`SubstringTable`), the code dictionary (`codes`), the
candidate heap (`BoundedMaxHeap`), and the deduplication set — on `itemID`
(a `String`) alone. The second `add()` for a co-item sibling silently
overwrote the first, dropping one vector.

**Fix:** all MIH internals now key on the full `VectorRecordKey`
(`itemID + vectorIndex + modelID + modelVersion`), which is already `Hashable`
and `Comparable` in both Swift and Rust. The `keysByItemID` reverse-lookup
map (used only as a bridge for the old `String`-keyed API) is removed.
`BruteForceIndex` sort tie-break is extended from `itemID ASC` to full
`VectorRecordKey ASC` for conformance parity.

**Tests added:**
- Swift (`MIHIndexTests.swift`): `MIHIndex-same-itemID collision fix` suite —
  four tests covering `add` path, `build` path, co-model-id case, and upsert
  contract (same full key replaces; co-item sibling is not evicted).
- Rust (`engine/mih.rs`): three inline tests —
  `same_item_id_distinct_vector_index_both_survive`,
  `same_item_id_via_build_both_survive`, `upsert_same_full_key_replaces_not_sibling`.
- Both ports: deferred-window integration test (see F2 test section) also
  verifies F1 through the merged-snapshot code path.

### F2 — Deferred buffer back-pressure: memory-only pending buffer now bounded

**Surfaces:**
- Swift: `VectorStore` (`VectorStore.swift`)
- Rust: `VectorStore` (`vector_store.rs`)

In memory-only deferred-index mode (no sidecar), `addPayloads` accumulates
records in `deferredPendingRecords` / `deferred_pending_records` and defers
all index rebuilds to `publishResidentIndex`. A caller that never calls
`publishResidentIndex` (or does so only at process exit after a very large
burst) could grow the buffer without bound.

**Fix:** a cap `deferredPendingLimit` (default `50_000`, configurable at
`init` for testing) is checked after each `addPayloads` call in deferred
memory-only mode. When the buffer exceeds the cap, `_flushDeferredPending()`
(`flush_deferred_pending` in Rust) performs an intermediate merge and index
rebuild, clears the buffer, and reseeds `deferredLiveKeys` from the new
snapshot. The deferred window stays open — callers observe no mode change.
The sidecar path is excluded (sidecar writes are already bounded per append).

**Tests added:**
- Swift (`BulkIngestTests.swift`): `deferredBufferBackPressureFlushesAndStaysCorrect`
  — uses `deferredPendingLimit: 100` to trigger three flush events during 300
  records in 50-record batches; verifies all items retrievable at distance 0
  after publish.
- Swift (`BulkIngestTests.swift`): `deferredWindowSameItemIDBothSurvive` —
  verifies F1 fix also holds through the deferred merged-snapshot code path.
- Rust (`tests/bulk_ingest_tests.rs`): `deferred_buffer_back_pressure_bounds_memory`
  — same design, `deferred_pending_limit: 100`, 300 records.
- Rust (`tests/bulk_ingest_tests.rs`): `deferred_window_same_item_id_both_survive`.

### Out of scope: vector sidecar at-rest encryption

Finding noted in the security audit — at-rest encryption of the `.vec` sidecar
belongs to the planned encryption feature track (coordinated with CorpusKit
and GeniusLocusKit key management). Not attempted in this fix. The audit note
is preserved in `the maintainer security audit (VectorKit)`.
