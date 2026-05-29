# sync-kit (Rust)

Rust port of the Swift `ConvergenceKit` package. Sync abstraction layer over PersistenceKit; ships at v1.0 with two backends.

**Status:** v1.0 with None backend (passthrough) and Federation backend (Ed25519 peer-to-peer). CloudKit is Apple-only and omitted from the Rust port; the Swift side handles iCloud transport.

## What ships at v1.0

- Core types: `SyncDirection`, `ConflictPolicy`, `SyncedTable`, `SyncManifest`, `SyncReceipt`, `SyncEventKind`, `SyncEvent`, `SyncState`, `SyncError`
- Wire format (serde-derived): `SyncRecord`, `SyncValueBox` (discriminated union over all 13 `TypedValue` variants), `SyncValueMap`, `PackedHLC`, `FingerprintWire`
- `SyncEngine` trait (synchronous; same rationale as storage-kit)
- `NoSyncEngine`: passthrough backend; enable/disable succeed trivially, push/pull return empty receipts, subscribe returns an immediately-disconnected receiver
- `FederationSyncEngine`: Ed25519-authenticated peer-to-peer backend. In-process `FederationRelay` for unit tests; wire transport is out of scope for v1.0.
- `LocalIdentity`, `PeerIdentity`, `verify_signature` (Ed25519 via `ed25519-dalek` v2)
- Pairing types: `HyperplaneFamilySpec`, `PairingProposal`, `PairingAcceptance`, `proposal_signing_bytes` for canonical byte encoding

## Tests

32 integration tests:
- `none_engine_tests.rs` (8): enable / re-enable error / push-pull-before-enable / push-pull-after-enable / state transitions / subscribe returns finished / manifest lookup / SyncedTable defaults
- `federation_tests.rs` (10): identity sign+verify / secret roundtrip / pairing proposal signing bytes / acceptance verifies proposer signature / engine enable+disable / two-peer push-pull roundtrip / pull rejects kit mismatch / pull rejects schema mismatch / subscriber receives PushCompleted / pull rejects tampered signature
- `wire_format_tests.rs` (14): all 13 `TypedValue` variants roundtrip through `SyncValueBox` / `SyncValueMap` roundtrips / `PackedHLC` and `FingerprintWire` roundtrips / `SyncRecord` JSON roundtrip / `StorageEvent` <-> `SyncEventKind` bidirectional

## What does NOT ship at v1.0

- CloudKit backend (Apple-only; the Swift side handles iCloud)
- Wire transport for Federation beyond the in-process relay (deferred)
- Conflict resolution enforcement at the receive boundary (records currently accepted unconditionally past kit + schema validation; conflict policies are part of the manifest but not yet applied)
- Observer-driven outbox (callers `enqueue` explicitly for now)
- StorageObserver integration (the Swift side wakes the outbox via StorageObserver; the Rust v1.0 backend uses explicit `enqueue`)

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
