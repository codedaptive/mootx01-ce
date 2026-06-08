# ConvergenceKit Interface Doctrine

For coding agents implementing kits that enable sync on their PersistenceKit instance. ConvergenceKit's contract is with PersistenceKit; downstream kits do not call ConvergenceKit directly except to declare and enable it.

## 1. Sync is enabled at the application layer, not the kit

The kit does not own its sync configuration. The application that composes the kit graph decides whether to sync, which backend, and which zone identifier. Kits declare the manifest of what *would* sync if sync were enabled; the application picks a SyncEngine and calls `enable`.

```swift
// In the kit
public extension LocusKit {
    public static func syncManifest(estateID: UUID) -> SyncManifest {
        SyncManifest(
            kitID: "LocusKit",
            schemaVersion: 1,
            zoneIdentifier: "LocusKit-\(estateID.uuidString)",
            tables: [
                SyncedTable(name: "drawers", primaryKeyColumn: "row_id"),
                SyncedTable(name: "tunnels", primaryKeyColumn: "tunnel_id"),
                SyncedTable(name: "audit_events", primaryKeyColumn: "event_id",
                            conflictPolicy: .appendOnly)
            ]
        )
    }
}

// In the application
let locusKit = LocusKit(storage: storage)
let sync = CloudKitSyncEngine()
try await sync.enable(manifest: LocusKit.syncManifest(estateID: estate.id),
                       storage: storage)
```

The kit never wires its own sync. The application does.

## 2. Choose ConflictPolicy per table, not per kit

Different tables have different conflict semantics. The audit log is append-only (`.appendOnly`); substrate noun tables project from the audit log and tolerate `.lastWriterWinsByHLC`. Queue jobs claim by HLC; settings might be `.localWins`. Per-table choice is the kit author's responsibility.

```swift
SyncedTable(name: "audit_events", primaryKeyColumn: "event_id",
            conflictPolicy: .appendOnly)
SyncedTable(name: "settings", primaryKeyColumn: "key",
            conflictPolicy: .localWins)
SyncedTable(name: "jobs", primaryKeyColumn: "job_id",
            conflictPolicy: .lastWriterWinsByHLC)
```

## 3. Sync direction is declarative

Most tables are `.bidirectional`. Push-only (`.pushOnly`) is for tables a device emits but never receives (logs, telemetry). Pull-only (`.pullOnly`) is for tables a device consumes but never writes (read-only state from a central source). The kit declares; the application doesn't override per-call.

## 4. Schema version must match across peers

If two devices run different schema versions of the same kit, sync between them rejects with `SyncError.schemaMismatch`. The receiver queues the record (or drops it, depending on backend) until both sides upgrade. Document this for the application that orchestrates updates.

Schema version is bumped whenever PersistenceKit's `SchemaDeclaration.version` is bumped. The two numbers must agree.

## 5. The audit log uses appendOnly

The audit log table that GeniusLocusKit owns has `(event_id, hlc)` as its compound primary key. ConvergenceKit's `.appendOnly` policy maps to an idempotent upsert on this key. Duplicate appends from sync replay are no-ops at the storage layer; the CRDT property holds.

Other kits with append-only logs (queue audit, federation handshake history) use the same policy.

## 6. The application catches SyncError

ConvergenceKit operations throw `SyncError` for backend-attributable failures. The application decides retry policy. The kit does not see these errors unless the application surfaces them.

```swift
do {
    _ = try await sync.push()
} catch SyncError.transportFailure(let detail) {
    // queue for retry; show offline indicator
} catch SyncError.schemaMismatch {
    // prompt user to update the app
}
```

## 7. Subscribe for live updates, push/pull for one-shots

`subscribe()` returns a long-running stream that fires events as sync activity happens. Use it for UI bindings ("syncing now," "last synced 30 seconds ago") and for waking up watchers that need notification when remote work arrives.

`push()` and `pull()` are one-shots. Use them for explicit refresh ("pull on app foreground," "push before close") or in test paths where determinism matters.

The two patterns coexist; subscribe stays open while push/pull run.

## 8. CloudKit and Federation can run side by side

A single PersistenceKit instance can have both a ConvergenceKit-CloudKit engine and a ConvergenceKit-Federation engine enabled simultaneously. The manifests pick different zones / peer sets; the engines observe the same StorageObserver independently. Multi-backend deployments (an app syncs its entities via CloudKit between a user's devices AND federates a GeniusLocus estate with a partner via ConvergenceKit-Federation) are natively supported.

The cost is two observer subscriptions per table. Document the resource use in the application.

## 9. Federation pairing is out of band

Pairing two estates over Federation requires exchanging public keys plus the HyperplaneFamilySpec. At v1.0 this is in-process (`engineA.pair(with: engineB, via: relay, family:)`). Cross-machine pairing is a v1.x concern; expect QR code, NFC, or AirDrop as the eventual out-of-band channel.

The kit does not initiate pairing. The application orchestrates it (pairing flow in the UI), and the kit's sync manifest just declares what flows once pairing is in place.

## 10. Test against ConvergenceKitNone in CI

CI test suites for kits with sync declarations use ConvergenceKitNone unless the test specifically exercises sync semantics. ConvergenceKitNone validates the manifest, succeeds on enable/disable, and returns empty receipts on push/pull. Fast and deterministic.

For sync-specific tests use ConvergenceKitFederation in-process pairing (two engines, shared relay, real round-trip). For full CloudKit integration tests, gate on `CLOUDKIT_TEST_CONTAINER` and provision a test container per the project's CI setup.

## 11. When in doubt, file a decision record

If you find yourself wanting to:

- Add a case to `SyncDirection`, `ConflictPolicy`, `SyncEvent`, `SyncState`, or `SyncError`
- Add a new method to `SyncEngine`
- Bypass schema checking
- Sync something that isn't a PersistenceKit row (large blob, file, stream)
- Add a backend-specific escape hatch

Stop. Write a decision record in `docs/decisions/` proposing the change. The closed-enum design depends on every change being deliberate.
