<!-- HLC packed-form ordering — root-cause finding from the 2026-07-12 fast-lane
     stabilization session. One LocusKit test (ProvenanceTests.mutateHappyPath)
     is intentionally left red as the tripwire for this finding. -->

FINDING: HLC_PACKED_ORDER_UNSOUND — `HLC.packed` does not preserve HLC order, and it is the audit log's ordering key

---

**Symptom (reproducible, deterministic):** `LocusKitTests.ProvenanceTests`
"mutateProvenance flips bits and writes audit row atomically (cookbook §2.5)"
fails: `auditEventsForRow` returns the genesis capture AFTER the 3 ms-later
mutation. Probe output from a live run:

```
verb=mutate  actor=bob   hlc=HLC(physicalTime: 1783833507374, logicalCount: 0, ...) packed=576461436625303086
verb=capture actor=bilby hlc=HLC(physicalTime: 1783833507371, logicalCount: 1, ...) packed=576462536136930859
```

The capture is 3 ms EARLIER yet its packed value is LARGER, so
`ORDER BY "hlc" ASC` returns it last.

---

**Root cause:** the packed layout in BOTH legs
(`SubstrateTypes/HLC.swift` `var packed`, `SubstrateTypes/rust/src/hlc.rs`
`fn packed`) is

```
(node << 56) | (logical << 40) | (physicalTime & 0xFF_FFFF_FFFF)
```

`logicalCount` occupies HIGHER bits than `physicalTime`. HLC order is
(physicalTime, logicalCount, nodeID); integer order of the packed form is
(nodeID, logicalCount, physicalTime). Whenever an event with logicalCount > 0
(same-millisecond burst — batch captures, the #84 generator wall-clock seeding)
is followed by a later-millisecond event with logicalCount 0, the packed
integers sort in the WRONG chronological order. The node byte in the top
bits additionally makes cross-node packed comparison meaningless and flips
the Int64 sign for node low-bytes ≥ 0x80.

Also latent in the same layout: `physicalTime` is masked to 40 bits, which
already overflowed (2^40 ms ≈ Nov 2004), so packed physical values are
epoch-ms mod 2^40 — fine until the next wraparound (~2039), but it means the
packed column has been relying on both wrapped values sharing the same epoch
window.

---

**Where the packed value is the ordering key (all of these inherit the bug):**

- Swift SQLite: `_storagekit_audit` `ORDER BY "hlc" ASC` (iterate + per-row
  reads in `PersistenceKitSQLite/SQLiteStorage.swift`), plus the
  `after:`-cursor pagination in `GeniusLocusKit.auditLog(for:)`.
- Rust SQLite: same table/ORDER BY (`PersistenceKit/rust/src/sqlite.rs`).
- Rust Postgres: same (`postgres.rs`).
- Every consumer that treats audit iteration order as chronology:
  `UnifiedAuditLog.orderedEntries`, GLK topology tombstone resolution
  (`events.last(where:)`), event-lag-pair folds, enrichment pipeline.

Per-row LWW guards compare full HLC structs, not packed integers — those are
NOT affected.

**Why it went unnoticed:** logicalCount is almost always 0 (one write per
millisecond). The LocusKit generator's wall-clock seeding (#84) plus
same-millisecond test writes made logicalCount=1 events routine in tests,
exposing the mis-order deterministically.

---

**Why this was NOT fixed in the lane-stabilization pass:** the schema is
locked for 1.0 (SCHEMA_STATUS.md) and `hlc` is a PK component in every
persisted audit row across both legs and both backends. Either fix path is a
Tier-1 primitive change needing its own mission and migration:

- **Option A — re-key ordering on the full-precision columns.** Since
  `physical_time`/`logical_count`/`node_id` are now stored full-width in both
  legs (Swift: 20325b94; Rust was already correct), change every audit
  `ORDER BY`/cursor to `(physical_time, logical_count, node_id)`. Needs a
  backfill migration for Swift rows written before 20325b94 (their full
  columns default to 0) — unpack from the packed value at migration time —
  plus matching index changes, both legs, both backends.
- **Option B — fix the packed layout** to `(physicalTime << 24) |
  (logical << 8) | node` (order-preserving, and widens usable physical
  range). Migration must rewrite every stored `hlc` PK value; conformance
  vectors and any golden fixtures embedding packed values regenerate.

Option A is smaller and keeps the wire/PK format untouched; Option B fixes
the primitive for every future consumer. Decision is Bob's; both need a
mission with a Blast Radius Report over `HLC.packed`, `_storagekit_audit`,
and the cursor pagination in `auditLog(for:)`.

**Tripwire:** `ProvenanceTests.mutateHappyPath` is left failing on purpose —
it asserts the correct chronological contract (`events.last` is the
mutation). Do not "fix" the test; fix the ordering.
