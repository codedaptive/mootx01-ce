// ZoneSnapshot.swift
//
// Wave 6A2 upstream slice U2 — Part 1.
//
// Paginated read-only zone snapshot API for ConvergenceKitCloudKit.
//
// PURPOSE:
// Enables a downstream consumer (e.g. Fulcrum's dark-cutover driver) to take
// a typed, truthful inventory of a CloudKit zone without touching Storage or
// triggering any apply side-effects. The snapshot is driven entirely through
// CloudKitDatabaseProtocol so test fakes provide the database without any
// network or iCloud container.
//
// KEY TRUTHFULNESS DECISIONS (must not be papered over):
//
// 1. HLC FLOOR UNDER LEGACYPACKED:
//    Under the .legacyPacked representation, physicalTime is truncated to 48
//    bits, logicalCount to 12 bits, and nodeID to 4 bits at the wire encoding
//    layer (CKRecordMapping). The decoded HLC values reflect post-unpack
//    magnitudes — if physicalTime or logicalCount exceeded the domain, the
//    decoded value differs from the original. The floor is computed over the
//    decoded (post-unpack) HLCs, which may reflect truncated magnitudes.
//    Under .fullWidthV2, all three components are lossless; the floor is exact.
//    ZoneSnapshotResult.hlcFloor documents this clearly; callers must not treat
//    a legacyPacked floor as an exact bound above the 48/12/4 ceilings.
//
// 2. TOMBSTONE HLC TRUTHFULNESS:
//    Typed tombstone CKRecords (moot_sync_deleted == 1) carry a decoded HLC
//    (the delete HLC from the engine's tombstone path). However, the snapshot
//    API purposefully EXCLUDES tombstone HLCs from the floor: the floor is a
//    lower bound on live record write time, not on delete time. Including delete
//    HLCs in a "live record floor" would mislead callers about what data is
//    currently live in the zone. Tombstones remove entries from the inventory.
//
// 3. RAW RECORD-ID DELETIONS (deletedRecordIDs):
//    CloudKit sends raw CKRecord.ID deletions for records deleted outside our
//    engine's typed-tombstone path. These carry NO HLC — CloudKit does not
//    provide per-deletion timestamps on the recordZoneChanges path. The snapshot
//    removes the corresponding entries from the live inventory by recordName
//    match; they cannot contribute to the HLC floor.
//
// 4. NO SIDE EFFECTS:
//    The snapshot API accepts only (zoneID, manifest, database). It has no
//    Storage parameter — there is no way to call it and accidentally trigger
//    an apply path. Every access goes through the injected database only.
//
// PART 3 JUDGMENT — ENGINE DATABASE HANDLE:
//    CKContainer(identifier:) is a deterministic constructor: given the same
//    containerIdentifier string, every call returns a container that resolves
//    to the same server-side zone. CloudKitStateActor.database is set to
//    container.privateCloudDatabase during enable(). A consumer who needs to
//    issue snapshot reads against the same zone the engine uses can construct
//    CKContainer(identifier: containerIdentifier).privateCloudDatabase
//    independently — no split-brain risk because CKDatabase is stateless; all
//    state lives server-side in CloudKit. Therefore NO engine API is added.
//    The consumer's handle and the engine's handle address the same zone.
//    This is tested in the test suite (see ZoneSnapshotTests.swift, test (f)).

import Foundation
import CloudKit
import ConvergenceKit
import SubstrateTypes

// MARK: - ZoneRecordIdentity

/// Typed identity of a single CloudKit record: the record type plus the
/// record name (a UUID string). Unique within a zone (CloudKit guarantees
/// recordName uniqueness per zone). Hashable so the full inventory is a Set.
public struct ZoneRecordIdentity: Hashable, Sendable {
    /// CKRecord.recordType — the table identity (kitID + "_" + tableName).
    public let recordType: String
    /// CKRecord.ID.recordName — the row UUID string.
    public let recordName: String

    public init(recordType: String, recordName: String) {
        self.recordType = recordType
        self.recordName = recordName
    }
}

// MARK: - ZoneSnapshotResult

/// The result of a complete paginated zone snapshot.
///
/// All fields are derived from what `CloudKitDatabaseProtocol.fetchZoneChanges`
/// actually returned — no fabricated or assumed values. See ZoneSnapshot.swift
/// header for the truthfulness decisions that govern the floor and tombstone
/// handling.
public struct ZoneSnapshotResult: Sendable {

    /// Live record identities present in the zone at snapshot time.
    ///
    /// Tombstone records (moot_sync_deleted == 1) are removed from this set;
    /// raw CKRecord.ID deletions (deletedRecordIDs) are also removed by
    /// recordName match. This is the inventory of currently-live data.
    public let inventory: Set<ZoneRecordIdentity>

    /// Per-live-record HLC, keyed by recordName (UUID string).
    ///
    /// Derived from representation-aware `CKRecordMapping.decode` on each
    /// modified record. Tombstones and raw-ID deletions do not appear here.
    ///
    /// LEGACYPACKED NOTE: under .legacyPacked, the decoded HLC may reflect
    /// truncated magnitudes (48/12/4 ceilings). Under .fullWidthV2, the HLC
    /// is exact and lossless.
    public let recordHLCs: [String: HLC]

    /// Maximum HLC across all live records in this snapshot.
    ///
    /// LEGACYPACKED FLOOR TRUTHFULNESS: under .legacyPacked representation, the
    /// floor is derived from post-unpack HLCs where physicalTime > 47-bit ceiling
    /// or logicalCount > 4095 may have been truncated at the wire encoding layer.
    /// The floor is a lower bound on live record write time within the 48/12/4
    /// domain; it should not be treated as exact above those ceilings.
    ///
    /// FULLWIDTHV2: the floor is exact across the full Int64 physicalTime,
    /// full Int32 logicalCount, and full Int32 nodeID ranges.
    ///
    /// TOMBSTONE / DELETION EXCLUSION: tombstone HLCs and raw-ID deletions are
    /// excluded from this floor. The floor covers only currently-live records.
    ///
    /// HLC.zero if the snapshot contains no live records.
    public let hlcFloor: HLC

    /// Zone ID echoed from the call arguments — confirms which zone was snapped.
    public let zoneID: CKRecordZone.ID

    /// Schema version echoed from `manifest.schemaVersion`.
    public let schemaVersion: Int

    public init(
        inventory: Set<ZoneRecordIdentity>,
        recordHLCs: [String: HLC],
        hlcFloor: HLC,
        zoneID: CKRecordZone.ID,
        schemaVersion: Int
    ) {
        self.inventory = inventory
        self.recordHLCs = recordHLCs
        self.hlcFloor = hlcFloor
        self.zoneID = zoneID
        self.schemaVersion = schemaVersion
    }
}

// MARK: - ZoneSnapshotError

/// Errors from the zone snapshot path.
public enum ZoneSnapshotError: Error, Sendable {
    /// A modified record from `fetchZoneChanges` could not be decoded via
    /// `CKRecordMapping.decode`. The snapshot does not proceed; the caller
    /// should treat this as a protocol violation (wrong representation, corrupt
    /// record, or mismatched manifest).
    case decodeFailure(recordName: String, underlying: any Error)
}

// MARK: - takeZoneSnapshot

/// Take a complete, paginated, read-only snapshot of a CloudKit zone.
///
/// Iterates `database.fetchZoneChanges` from `nil` token (zone history start)
/// until `moreComing == false`, accumulating the full live inventory, per-record
/// HLCs, and the max HLC floor. No Storage is touched; no records are applied.
///
/// - Parameters:
///   - zoneID: The CloudKit zone to snapshot.
///   - manifest: Manifest binding — `hlcWireRepresentation` drives the decode
///     path; `schemaVersion` is echoed in the result. No tables are accessed.
///   - database: Injectable database seam. Provide a fake in tests; production
///     callers can use `CKContainer(identifier: containerIdentifier).privateCloudDatabase`
///     (deterministic, same zone as the engine's own database — no engine API
///     is needed; see ZoneSnapshot.swift header for the full judgment).
///
/// - Returns: A `ZoneSnapshotResult` with the full live inventory, per-record
///   HLCs, HLC floor, and echoed zone/schema binding.
///
/// - Throws: `ZoneSnapshotError.decodeFailure` if any modified record fails
///   representation-aware decode. Transport errors from `fetchZoneChanges`
///   propagate as-is.
public func takeZoneSnapshot(
    zoneID: CKRecordZone.ID,
    manifest: SyncManifest,
    database: any CloudKitDatabaseProtocol
) async throws -> ZoneSnapshotResult {
    let representation = manifest.hlcWireRepresentation

    // Accumulate live inventory and per-record HLCs across all pages.
    var inventory: Set<ZoneRecordIdentity> = []
    var recordHLCs: [String: HLC] = [:]
    var token: CKServerChangeToken? = nil

    // Pagination loop: issue fetchZoneChanges until moreComing == false.
    // On each iteration, pass the previous page's changeToken to request the next
    // page. The loop terminates when the protocol reports moreComing = false,
    // which is the default for single-shot fakes and the real CKDatabase signal
    // for the final page of a multi-page zone.
    repeat {
        let changes = try await database.fetchZoneChanges(inZoneWith: zoneID, since: token)

        // Process modified records. Decode representation-awarely via CKRecordMapping.
        // Decode failures are not silently swallowed — they indicate a manifest/zone
        // mismatch (wrong representation, corrupt HLC field) and must surface loudly.
        for record in changes.modifiedRecords {
            let decoded: DecodedRecord
            do {
                decoded = try CKRecordMapping.decode(record, representation: representation)
            } catch {
                throw ZoneSnapshotError.decodeFailure(
                    recordName: record.recordID.recordName,
                    underlying: error
                )
            }

            let identity = ZoneRecordIdentity(
                recordType: record.recordType,
                recordName: record.recordID.recordName
            )

            if decoded.isTombstone {
                // Typed tombstone (moot_sync_deleted == 1): remove from live inventory.
                // The tombstone HLC (decoded.hlc) is available but is intentionally
                // EXCLUDED from the floor — the floor covers live record write times
                // only, not delete times. Including delete HLCs would mislead callers
                // about the current live state of the zone.
                inventory.remove(identity)
                recordHLCs.removeValue(forKey: record.recordID.recordName)
            } else {
                inventory.insert(identity)
                recordHLCs[record.recordID.recordName] = decoded.hlc
            }
        }

        // Process raw CKRecord.ID deletions (deletedRecordIDs).
        // These are D1 fallback deletions — records removed outside our engine's
        // typed-tombstone path. They carry NO HLC (CloudKit does not provide
        // per-deletion timestamps on the recordZoneChanges path). We remove the
        // matching inventory entries by recordName; no HLC contribution is possible.
        for deletedID in changes.deletedRecordIDs {
            // Remove any inventory entry whose recordName matches, regardless of
            // record type (we have no type information from a raw ID deletion).
            inventory = inventory.filter { $0.recordName != deletedID.recordName }
            recordHLCs.removeValue(forKey: deletedID.recordName)
        }

        // Advance the page cursor. The next fetch will start from this token.
        token = changes.changeToken

        // Stop when the protocol signals there are no more pages.
        if !changes.moreComing { break }
    } while true

    // Compute the max HLC floor over all live records using HLC's Comparable impl
    // (lexicographic on physicalTime, logicalCount, nodeID per SubstrateTypes/HLC.swift).
    // HLC.zero is the identity for max — an empty inventory returns HLC.zero.
    let hlcFloor = recordHLCs.values.max() ?? .zero

    return ZoneSnapshotResult(
        inventory: inventory,
        recordHLCs: recordHLCs,
        hlcFloor: hlcFloor,
        zoneID: zoneID,
        schemaVersion: manifest.schemaVersion
    )
}
