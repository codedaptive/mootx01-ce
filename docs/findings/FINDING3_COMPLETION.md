---
version: v0.1
---

# FINDING-3 Completion Report — Duplicate Association Edge Accumulation

```
COMPLETION: FINDING-3

Status: COMPLETE

What Was Done:

Part 1 — Blast Radius Report — commit d8b16720
  BRR filed at docs/analysis/blast_radius/FINDING3_BLAST_RADIUS.md.
  MUST_UPDATE list: LocusKitSchema.swift, DrawerStore.swift,
  VectorSimilaritySignal.swift, GeniusLocusKitSchema.swift,
  HydrateRoundTripTests.swift, schema.rs (LocusKit), hydration.rs (GLK),
  vector_similarity.rs (GLK), default_set.rs, drawer_store_inmemory.rs.
  RESCOPE_REQUIRED: 0.

Part 2 — Full fix, both Swift and Rust legs — commit 27db2183
  Swift:
    LocusKitSchema.swift — version 9→10, associations uniqueConstraints added,
    v9→v10 migration (dedup SQL then AddIndex).
    DrawerStore.swift — addAssociation catches StorageError.duplicateKey, returns
    silently (INSERT-OR-IGNORE semantics). New hasAssociationBetweenDrawers method.
    VectorSimilaritySignal.swift — AssociationEdgeChecker typealias, edgeChecker
    parameter on spec()/proximityPass(). Filter loop suppresses already-persisted
    pairs before emission. Diagnostic updated to show found vs. emitting count.
    GeniusLocusKitSchema.swift — comment updated (LocusKit v10, composite = 19).
    HydrateRoundTripTests.swift — hardcoded 18→19, titles updated.
    AssociationTests.swift — 3 new tests:
      duplicateEdgeIsNoOp, migrationDedupsAssociationRows,
      hasAssociationBetweenDrawers (FINDING-3 coverage).

  Rust:
    LocusKit/rust/src/schema.rs — SCHEMA_VERSION 9→10, unique_constraints on
    associations_table(), v9→v10 migration (Custom dedup SQL + AddIndex), schema
    test renamed schema_version_is_ten, asserts migration length = 1.
    LocusKit/rust/src/drawer_store_inmemory.rs — add_association catches
    StorageError::DuplicateKey, returns Ok(()) silently.
    GeniusLocusKit/rust/src/brain/signals/vector_similarity.rs — AssociationEdgeChecker
    type alias, edge_checker parameter on spec()/proximity_pass(). Filter block
    before emission loop.
    GeniusLocusKit/rust/src/brain/signals/mod.rs — exports AssociationEdgeChecker.
    GeniusLocusKit/rust/src/lib.rs — re-exports AssociationEdgeChecker.
    GeniusLocusKit/rust/src/brain/signals/default_set.rs — passes None for edge_checker.
    GeniusLocusKit/rust/src/hydration.rs — version assertion 18→19 with updated comment.
    GeniusLocusKit/rust/tests/standing_signals_parity.rs — None arg for edge_checker.
    GeniusLocusKit/rust/tests/rag_wiring_parity.rs — None arg for edge_checker (3 sites).

Test Verification Log:
  swift build (LocusKit): exit 0 (2026-07-13)
  swift test (LocusKit): exit 0, 806 tests, all passing (baseline 803; +3 new)
  swift build (GeniusLocusKit): exit 0 (2026-07-13)
  swift test (GeniusLocusKit): exit 0, 597 tests, all passing (unchanged)
  cargo build (LocusKit/rust): exit 0 (2026-07-13)
  cargo test (LocusKit/rust): exit 0, 875 tests, all passing
  cargo build (GeniusLocusKit/rust): exit 0 (2026-07-13)
  cargo test (GeniusLocusKit/rust): exit 0, all suites passing

Discoveries:
  - Rust LocusKit/rust/src/schema.rs previously declared migrations: Vec::new()
    with a "no migration ladder" comment. v10 is the first migration to ship.
    The comment has been updated. The test was renamed schema_version_is_ten.
  - NULL != NULL in SQLite unique indexes: wing/room-level associations with
    NULL sourceDrawerId / targetDrawerId do not conflict with each other under
    the new UNIQUE constraint. This is acceptable — VectorSimilaritySignal
    always emits drawer-level pairs with non-null IDs. Wing/room-level
    associations (no drawer) are a different caller concern.
  - The AssociationEdgeChecker closure is wired as an optimization only —
    default is nil/None in both legs. The DB-level uniqueness constraint is
    the durable correctness guarantee. The checker avoids churning AssociateFrames
    on every 300-second pass when the neighbourhood is stable.
  - Migration correctness order is enforced structurally: Custom dedup SQL
    MUST precede AddIndex in the operations slice. If reversed, CREATE UNIQUE
    INDEX fails on duplicate rows. Both legs maintain this order.

Outstanding:
  - Production callers that wire a real DrawerStore may wish to supply an
    AssociationEdgeChecker to VectorSimilaritySignal::spec() to reduce frame
    churn. This is an optimization wire-up, not a correctness gap.
  - Perkins was designated to audit post-completion per the original finding
    brief. Security surface: the de-duplication SQL is a simple DELETE …
    WHERE rowid NOT IN (SELECT MIN(rowid) …) with no user-controlled inputs —
    no injection surface. The unique constraint reduces the association table
    growth rate from O(300s passes) to O(new pairs), which also reduces the
    prompt-injection amplification angle noted in the finding.
```
