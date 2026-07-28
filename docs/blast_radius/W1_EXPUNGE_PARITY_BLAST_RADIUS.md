# Blast Radius Report — W1_EXPUNGE_PARITY

**Baseline:**
- GLK Swift test pass count at mission start: 637
- GLK Rust (cargo test --all) pass count at mission start: 450
- LocusKit Rust (cargo test --all) pass count at mission start: 896
- Commands:
  - `cd packages/kits/GeniusLocusKit && swift test 2>&1 | tail -5`
  - `cd packages/kits/GeniusLocusKit/rust && cargo test --all 2>&1 | grep "test result:"`
  - `cd packages/kits/LocusKit/rust && cargo test --all 2>&1 | grep "test result:"`

**Mission:** Bring Rust expunge to parity with Swift — fix the gate-rejected sibling
scrub in LocusKit storage layer, add GLK coordinator lineage fan-out for cross-kit
vector deletes, and add conformance tests for the gate-reject scenario on both legs.

## Symbol 1: `DrawerStoreCore::expunge_gated` — gate-rejected sibling branch

**Change class:** semantic (behavior change in an existing branch)
**Scope:** pub(crate) — accessed only through `DrawerStore` trait implementations
(InMemoryDrawerStore, SqliteDrawerStore)

**Divergence confirmed:**
`packages/kits/LocusKit/rust/src/drawer_store_inmemory.rs` lines 2180–2182.
When a lineage sibling's state-machine gate rejects the tombstone transition
(e.g., a sibling whose state cannot legally advance to tombstoned via S-3), the
Swift `DrawerStore.expungeGated` unconditionally zeroes the `content` blob AND
NULLs the four representation columns (`distilled`, `distilled_pipeline_version`,
`distilled_token_count`, `distilled_at`). The Rust `DrawerStoreCore::expunge_gated`
currently silently skips the scrub in that branch ("skip silently. Accepted rows
survive." comment), violating the destruction contract.

Swift reference (DrawerStore.swift lines 1411–1424):
```swift
// Gate rejected the state transition (e.g., accepted →
// tombstoned is S-3 forbidden). Content scrub is unconditional
// and independent of the state machine: even when the state
// cannot transition, the verbatim content MUST be zeroed.
_ = try await txn.rowStore.update(
    table: "drawers",
    values: Self.withClearedRepresentation(["content": .text("")]),
    where: .eq(Column(table: "drawers", name: "id"), .text(siblingId))
)
try await refreshContentFingerprint(drawerId: siblingId, txn: txn)
```

Rust bug location:
- `packages/kits/LocusKit/rust/src/drawer_store_inmemory.rs` lines 2180–2182
- Comment reads: "If the gate rejects (e.g. accepted → tombstoned is / S-3 forbidden),
  skip silently. Accepted rows survive."

The SQLite-backed stores delegate `expunge_gated` to `DrawerStoreCore`, so both
in-memory and SQLite paths are fixed by a single change.

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| packages/kits/LocusKit/rust/src/drawer_store_inmemory.rs | 2180–2182 | read | MUST_UPDATE | The gate-rejected sibling branch — change from skip to content-zero + representation-clear |
| packages/kits/LocusKit/rust/tests/drawer_store_inmemory.rs (new test) | — | new | MUST_UPDATE | Conformance test asserting content+representation zeroed on gate-reject |

### Summary
- MUST_UPDATE: 2 sites (source fix + test)
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## Symbol 2: `EstateCoordinator::expunge` — lineage fan-out in cross-kit vector delete

**Change class:** semantic (missing behavior in existing code path)
**Scope:** pub — GLK coordinator public API

**Divergence confirmed:**
`packages/kits/GeniusLocusKit/rust/src/coordinator.rs` step 2 (cross-kit vector delete).
Swift calls `estate.lineageChain(for: frame.rowID)` and fans out the cross-kit delete
over ALL lineage members, not just the head row. The Rust coordinator only deletes for
`row_id`. As a result, sibling vectors (for predecessor lineage versions) survive a Rust
expunge, leaking content-derived embeddings.

Swift reference (VerbSurface.swift lines 739–780):
```swift
let lineageIds = try await estate.lineageChain(for: frame.rowID)
let idsToDelete = lineageIds.isEmpty ? [frame.rowID] : lineageIds
for deleteId in idsToDelete {
    if let corpus { try await corpus.removeContent(id: deleteId) }
    if let vectorStore {
        try await vectorStore.deleteAllVectors(itemID: deleteId, modelID: Self.distillationLaneModelID)
    }
    if let vectorStore, let corpus { ... modelID delete ... }
}
```

Rust bug location: `packages/kits/GeniusLocusKit/rust/src/coordinator.rs` lines 3062–3131.
The `step2_result` closure executes `c.remove_content(row_id)` and
`vs.delete_all_vectors(row_id, ...)` only for `row_id` — no `lineage_chain` call,
no loop over lineage members.

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| packages/kits/GeniusLocusKit/rust/src/coordinator.rs | 3062–3131 | read | MUST_UPDATE | Add lineage_chain fan-out before the step-2 closure |
| packages/kits/GeniusLocusKit/rust/tests/expunge_vector_orphan.rs (new tests E10+) | — | new | MUST_UPDATE | E9+E10 parity of Swift's E9+E10: undistilled no-op and lineage cascade scrubs all lane entries |

### Summary
- MUST_UPDATE: 2 sites (source fix + new tests)
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## Finding: integrity sweep missing distillation lane scrub (both Swift and Rust)

**NOT a twin divergence.** Both `runExpungeIntegritySweep` (Swift) and
`run_expunge_integrity_sweep` (Rust) are missing the distillation lane scrub in the
re-delete step. They are in parity — both skip the distillation lane in the sweep. The
fix (add `vs.delete_all_vectors(row_id, distillation_lane_model_id)` to BOTH) is a
correctness improvement but outside the scope of bringing Rust to Swift parity.

This is reported as a finding, not implemented. A follow-up mission should add the
distillation lane scrub to both sweeps together.
