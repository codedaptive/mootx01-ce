import Foundation
import ConvergenceKit
import LocusKit   // LocusKitSchema.version — the cross-device schema contract

// MARK: - MootEstateSyncManifest  (which estate tables sync, verified vs schema)
//
// The SyncManifest is a cross-device CONTRACT: the engine hard-guards kitID
// and schemaVersion (pull throws .kitMismatch / .schemaMismatch on a
// mismatch), and every SyncedTable.name must be a real table in the estate
// schema. These values are therefore taken from LocusKitSchema (verified,
// not guessed): schemaVersion tracks `LocusKitSchema.version` so it can never
// silently drift from the shipped schema.
//
// What syncs (the durable, single-primary-key canonical content):
//   - drawers   (id)  — the memories themselves            · LWW-by-HLC
//   - tunnels   (id)  — reference edges between drawers     · LWW-by-HLC
//   - kg_facts  (id)  — knowledge-graph facts              · append-only
//   - diary     (id)  — diary entries                       · append-only
//
// What does NOT sync, by design: derived/projection tables (node_bundles,
// matrix_snapshot, container_fingerprints) — they have composite keys and
// rebuild locally from the canonical rows, so replicating them would be
// redundant and, worse, could import a stale projection. Brain-emitted
// proposals/associations/learned_references are deferred until their
// cross-device semantics are decided.
//
// Encrypted content columns (FAB5-EV seam, FAB5-ST activation):
//   - drawers.content is routed through CKRecord.encryptedValues.
//     Only the device that created the record (and devices in the same iCloud
//     account trusted zone) can decrypt it. CloudKit infrastructure never sees
//     plaintext. The "content" column name matches DrawerStore.drawerValues(_:)
//     and LocusKit's structuredDrawerColumns list.

public enum MootEstateSyncManifest {

    /// The kit whose tables these are — must match on every device.
    public static let kitID = "LocusKit"

    /// Build the default estate manifest for a CloudKit zone.
    public static func standard(zoneIdentifier: String = "moot.estate") -> SyncManifest {
        SyncManifest(
            kitID: kitID,
            schemaVersion: LocusKitSchema.version,
            zoneIdentifier: zoneIdentifier,
            tables: [
                SyncedTable(name: "drawers", direction: .bidirectional,
                            primaryKeyColumn: "id", conflictPolicy: .lastWriterWinsByHLC),
                SyncedTable(name: "tunnels", direction: .bidirectional,
                            primaryKeyColumn: "id", conflictPolicy: .lastWriterWinsByHLC),
                SyncedTable(name: "kg_facts", direction: .bidirectional,
                            primaryKeyColumn: "id", conflictPolicy: .appendOnly),
                SyncedTable(name: "diary", direction: .bidirectional,
                            primaryKeyColumn: "id", conflictPolicy: .appendOnly),
            ],
            // Drawer content rides CKRecord.encryptedValues — end-to-end encrypted
            // in iCloud. Other drawer columns (adjectiveBitmap, operationalBitmap,
            // metadata) remain plaintext so SensitivityFilteredStorage can inspect
            // adjectiveBitmap in inbound records without decryption.
            encryptedContentColumns: ["drawers": ["content"]])
    }
}
