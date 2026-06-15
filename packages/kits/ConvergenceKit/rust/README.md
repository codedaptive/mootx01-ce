# sync-kit (Rust)

Rust port of the Swift `ConvergenceKit` package. Sync abstraction layer over PersistenceKit; ships at v1.0 with two backends.

**Status:** v1.0 with None backend (passthrough) and Federation backend (Ed25519 peer-to-peer). CloudKit is Apple-only and omitted from the Rust port; the Swift side handles iCloud transport.

## What ships at v1.0

- Core types: `SyncDirection`, `ConflictPolicy`, `SyncedTable`, `SyncManifest`, `SyncReceipt`, `SyncEventKind`, `SyncEvent`, `SyncState`, `SyncError`
- Wire format (serde-derived): `SyncRecord`, `SyncValueBox` (discriminated union over all 13 `TypedValue` variants), `SyncValueMap`, `PackedHLC`, `FingerprintWire`
- `SyncEngine` trait (synchronous; same rationale as storage-kit)
- `NoSyncEngine`: passthrough backend; enable/disable succeed trivially, push/pull return empty receipts, subscribe returns an immediately-disconnected receiver
- `FederationSyncEngine`: Ed25519-authenticated peer-to-peer backend. In-process `FederationRelay` for unit tests; cross-machine wire transport is out of scope for v1.0.
- Observer-driven outbox: `enable` subscribes to the storage observer (`observe(table, [Insert, Update, Delete])`) for every push-eligible table and auto-populates the outbox — each observed `TableChange` is mapped to a `SyncRecord` (minting an HLC through the engine's `HLCGenerator` when the change carries none) on a per-table worker thread. This is parity with the Swift port's `storage.observer.observe(...)` subscription. The explicit `enqueue(record)` entry point remains available for callers that mint records directly. Observer workers are cancelled and joined on `disable` (no leaked threads).
- `LocalIdentity`, `PeerIdentity`, `verify_signature` (Ed25519 via `ed25519-dalek` v2)
- Pairing types: `HyperplaneFamilySpec`, `PairingProposal`, `PairingAcceptance`, `proposal_signing_bytes` for canonical byte encoding
- Conflict enforcement at the receive boundary: all four `ConflictPolicy` arms (`LastWriterWinsByHLC`, `RemoteWins`, `LocalWins`, `AppendOnly`) are applied in `apply_record` on every inbound pull. `LastWriterWinsByHLC` compares the incoming `PackedHLC` against the stored `_syncHLC` column and silently drops stale writes and stale deletes; `RemoteWins` overwrites unconditionally; `LocalWins` inserts only when the row is absent; `AppendOnly` rejects remote deletes. This mirrors `CloudKitStateActor.applyInbound` in the Swift port exactly (commit 5cf76ce8).

## Tests

50 integration tests:
- `none_engine_tests.rs` (8): enable / re-enable error / push-pull-before-enable / push-pull-after-enable / state transitions / subscribe returns finished / manifest lookup / SyncedTable defaults
- `federation_tests.rs` (14): identity sign+verify / secret roundtrip / pairing proposal signing bytes / acceptance verifies proposer signature / engine enable+disable / two-peer push-pull roundtrip / pull rejects kit mismatch / pull rejects schema mismatch / subscriber receives PushCompleted / pull rejects tampered signature / (additional inbound routing and edge cases)
- `federation_lww_tests.rs` (4): stale inbound does not overwrite newer local row / newer inbound wins over older local row / stale delete does not remove newer local row / newer delete removes local row
- `federation_observer_outbox_tests.rs` (5): a storage write auto-populates the outbox for insert/update/delete (no explicit enqueue) / explicit enqueue still works (regression) / disable stops auto-population (observer workers cancelled, no leak); mirrors `FederationObserverOutboxTests.swift`
- `federation_inbound_event_tests.rs` (5): insert/update/delete routing through each conflict policy; mirrors `FederationInboundEventTests.swift`
- `wire_format_tests.rs` (14): all 13 `TypedValue` variants roundtrip through `SyncValueBox` / `SyncValueMap` roundtrips / `PackedHLC` and `FingerprintWire` roundtrips / `SyncRecord` JSON roundtrip / `StorageEvent` <-> `SyncEventKind` bidirectional

## What does NOT ship at v1.0

- CloudKit backend (Apple-only; the Swift side handles iCloud)
- Cross-machine wire transport for Federation beyond the in-process relay (out of scope for v1.0; cross-machine transport is ConvergenceKit v1.1 scope per `docs/decisions/DECISION_CONVERGENCEKIT_OPERATIONAL_SYNC_2026-06-09.md`). The outbox auto-population (observer → outbox) ships in both ports at v1.0; only the cross-machine drain/transmit to a remote peer remains v1.1.

## Building

```
cd ConvergenceKit/rust
cargo build
cargo test
```

Requires Rust 1.75+ and sibling `substrate-kit`, `storage-kit` crates.

## See also

- Swift counterpart: `ConvergenceKit/Sources/`
- Design record: `docs/decisions/DECISION_SYNCKIT_DESIGN_2026-05-19.md`
- Kit graph ADR: `docs/decisions/DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md`
