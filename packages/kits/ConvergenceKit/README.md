# ConvergenceKit

ConvergenceKit replicates PersistenceKit operations across device or perimeter boundaries. Third foundation kit in the eleven-kit family per `docs/decisions/DECISION_KIT_GRAPH_REFACTOR_2026-05-19.md`. Design settled in `docs/decisions/DECISION_SYNCKIT_DESIGN_2026-05-19.md`.

ConvergenceKit's only consumer is PersistenceKit. Downstream kits (QueueKit, GeniusLocusKit, and app-level entity stores) get sync for free by enabling ConvergenceKit on their PersistenceKit instance. They never call ConvergenceKit directly.

## Status (2026-05-19)

| Target | Status |
|---|---|
| ConvergenceKit (core protocols + types) | Complete |
| ConvergenceKitNone | Complete; production-ready passthrough |
| ConvergenceKitCloudKit | Complete v1.0; generalized CloudSync engine per SyncManifest |
| ConvergenceKitFederation | Complete v1.0; in-process pairing via FederationRelay; Ed25519 signed messages |
| Conformance fixture suite | Pending |

Tests: 12 pass (4 core, 5 None, 1 CloudKit stub, 2 Federation including end-to-end pairing).

## Architecture

Four Swift package targets:

- **ConvergenceKit** — protocols and types. Consumed by every backend.
- **ConvergenceKitNone** — passthrough for single-device deployments, development, tests.
- **ConvergenceKitCloudKit** — Apple ecosystem sync via CloudKit private database, generic CKRecord mapping driven by SyncManifest.
- **ConvergenceKitFederation** — substrate-native CRDT exchange per paper section 9. Per-estate Ed25519 keypair, signed message exchange, in-process pairing via FederationRelay at v1.0.

Dependencies: SubstrateLib (HLC, Fingerprint256), PersistenceKit (the observed surface), swift-crypto 3.0+ for Ed25519.

## The model

```
Application code
    ↓ writes to
PersistenceKit (with ConvergenceKit enabled)
    ↓ observed by
ConvergenceKit (wakes on writes, ships outbound)
    ↓ delivers to peer's
PersistenceKit (write goes through normal RowStore API)
    ↓ wakes peer's downstream watchers via
StorageObserver
```

The application never sees sync directly. Writing to PersistenceKit is sufficient; ConvergenceKit handles the rest. Receiving devices wake up watchers naturally because incoming records are applied through PersistenceKit's RowStore, which fires StorageObserver.

## Eight settled design decisions

Per DECISION_SYNCKIT_DESIGN_2026-05-19.md:

1. **Consumer model**: ConvergenceKit consumes PersistenceKit; downstream kits get sync for free.
2. **Wire format**: SyncRecord with schemaVersion + kitID; mismatch rejects with `SyncError.schemaMismatch`.
3. **Subscribe primitive**: long-running `subscribe()` returns `AsyncStream<SyncEvent>`.
4. **Backends**: CloudKit, Federation, None.
5. **ConflictPolicy** per SyncedTable: lastWriterWinsByHLC (default), appendOnly (audit log), localWins, remoteWins.
6. **Peer identity** (Federation): per-estate Ed25519 keypair.
7. **State** for UI: SyncState enum; detailed telemetry via Logger.
8. **Conformance**: own fixture suite, sibling to PersistenceKit's (pending).

## Backends

### ConvergenceKitNone (v1.0 complete)

Passthrough. `enable()` succeeds, `push()` and `pull()` return empty receipts, `subscribe()` returns a stream that never emits. Use for development, tests, and single-device deployments.

### ConvergenceKitCloudKit (v1.0 complete)

Generic CKRecord mapping driven by SyncManifest. The mapper translates `[String: TypedValue]` to and from `CKRecord`, with sync metadata in reserved `_syncHLC`, `_syncSchemaVersion`, `_syncKitID` fields. Per-estate zone in the private database. Lazy container initialization so the engine can be instantiated in unit tests without iCloud entitlements.

```swift
let engine = CloudKitSyncEngine()  // resolves CKContainer at enable() time
try await engine.enable(manifest: myManifest, storage: myStorage)
let receipt = try await engine.push()
let pulled = try await engine.pull()
```

CloudKit container resolution happens lazily on first push/pull. Tests that don't exercise the real container can instantiate freely.

### ConvergenceKitFederation (v1.0 complete)

Substrate-native CRDT exchange per paper section 9. Each engine generates a per-estate Ed25519 keypair on init. Pairing exchanges public keys plus a HyperplaneFamilySpec (paper section 9.2). Signed messages travel through a `FederationRelay` (in-process shared state for v1.0; wire transport for cross-machine deferred to v1.x).

```swift
let engineA = FederationSyncEngine()
let engineB = FederationSyncEngine()
try await engineA.enable(manifest: m, storage: storageA)
try await engineB.enable(manifest: m, storage: storageB)

let relay = FederationRelay()
let family = HyperplaneFamilySpec(seed: 0xDEADBEEF)
try await engineA.pair(with: engineB, via: relay, family: family)

// Write on A, push, pull on B.
try await engineA.push()
try await engineB.pull()
```

Cross-machine federation (HTTPS-relay, peer-to-peer) is a v1.x decision. In-process pairing is enough to exercise the protocol and the cross-perimeter math in tests.

## Building and testing

```
cd ConvergenceKit
swift build
swift test
```

Requires Swift 6.0+ and sibling packages at `../SubstrateLib` and `../PersistenceKit`. CloudKit tests that exercise the real container require `CLOUDKIT_TEST_CONTAINER` environment variable.

## Public API stability

Once shipped, public API follows semantic versioning. Adding a case to `SyncDirection`, `ConflictPolicy`, `SyncEvent`, `SyncState`, or `SyncError` is a breaking change requiring a major version bump and a decision record. Backend additions are additive.

## Next missions

ConvergenceKit sits in the substrate's storage layer. The remaining substrate kits (LocusKit, VectorKit, CorpusKit), GeniusLocusKit, NeuronKit, CognitionKit, and app integrations consume ConvergenceKit through this kit's public surface.
