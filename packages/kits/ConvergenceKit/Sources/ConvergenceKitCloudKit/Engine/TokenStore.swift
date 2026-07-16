// TokenStore.swift
//
// Persists CKServerChangeToken per CloudKit zone in the _ck_change_token
// side table. Implements R5 from
// DECISION_CONVERGENCEKIT_OPERATIONAL_SYNC_2026-06-09.md.
//
// Problem being fixed: `serverChangeToken` was an actor variable; every
// process launch re-pulled the full zone even if nothing had changed.
// TokenStore solves this by writing the post-pull token to storage so
// the next launch resumes from where the previous one left off.
//
// --- Archiver choice ---
// CKServerChangeToken conforms to NSSecureCoding, not Codable. Round-trip
// uses NSKeyedArchiver(requiringSecureCoding: true) rather than the legacy
// NSCoder path. requiringSecureCoding enforces class whitelisting on
// unarchival: if a database row were corrupted or tampered, the unarchiver
// would reject the payload rather than instantiate an arbitrary NSCoding
// class. For a sync engine that trusts the local SQLite estate,
// requiringSecureCoding is sufficient; it guards against accidental
// corruption, not a hostile attacker with direct DB access.
//
// --- Schema note ---
// P1-M4 (parallel mission on a sibling stream) is creating a consolidated
// SideSchema.swift in ConvergenceKitCloudKit for all _ck_* tables. This
// file declares _ck_change_token locally using the same
// SchemaDeclaration + migrate(to:) pattern as CloudKitStateActor's
// ensureSyncMetaTable. When SideSchema.swift lands and the root merge
// reconciles, this local declaration should be folded in there.
//
// --- Per-zone keying ---
// zone_name is the sole primary key. Tokens for different zones are
// fully independent: saving zone A's token never touches zone B's row.
// clear(zoneName:) deletes the row; subsequent load returns nil, which
// triggers a full-zone pull from scratch on the next pull() call.

import Foundation
import CloudKit
import PersistenceKit

// MARK: - TokenStore

/// Persists and retrieves CKServerChangeToken per CloudKit zone.
/// All methods are static; no instances are created.
enum TokenStore {

    static let tableName = "_ck_change_token"

    // MARK: - Schema setup

    /// Ensure the _ck_change_token side table exists in storage.
    ///
    /// Uses SchemaDeclaration + migrate(to:) (ADDITIVE) so the
    /// application schema declaration is never overwritten. This mirrors
    /// the pattern from CloudKitStateActor.ensureSyncMetaTable exactly.
    ///
    /// The kitID "ConvergenceKitCloudKit" and version 1 are shared with
    /// ensureSyncMetaTable. Both calls are safe to interleave because:
    ///   - SQLite: CREATE TABLE IF NOT EXISTS runs for every table in the
    ///     schema.tables array, regardless of the kit version gate.
    ///   - InMemory: tables are created if absent before version gates fire.
    /// Either call order creates both _ck_sync_meta and _ck_change_token.
    static func ensure(storage: any Storage) async throws {
        let schema = SchemaDeclaration(
            kitID: "ConvergenceKitCloudKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: tableName,
                    columns: [
                        // zone_name is the sole primary key — one row per zone.
                        ColumnDeclaration(name: "zone_name", type: .text, nullable: false),
                        // token: NSKeyedArchiver blob of a CKServerChangeToken.
                        ColumnDeclaration(name: "token", type: .blob, nullable: false),
                        // updated_at: ISO 8601 wall-clock timestamp for debugging.
                        // Date storage is TEXT (ISO8601) per schema-invariants.md.
                        ColumnDeclaration(name: "updated_at", type: .text, nullable: false),
                    ],
                    primaryKey: ["zone_name"]
                ),
            ],
            indices: []
        )
        // migrate(to:) is ADDITIVE — creates _ck_change_token without
        // touching the application schema or any existing tables.
        try await storage.migrate(to: schema)
    }

    // MARK: - Load / Save / Clear

    /// Load the persisted change token for the given zone.
    /// Returns nil if no token is stored (first pull, or after a
    /// changeTokenExpired reset), in which case the engine should pull
    /// from scratch (no `since:` token).
    static func load(zoneName: String, storage: any Storage) async throws -> CKServerChangeToken? {
        guard let blob = try await loadBlob(zoneName: zoneName, storage: storage) else {
            return nil
        }
        return try unarchive(CKServerChangeToken.self, from: blob)
    }

    /// Persist the change token for the given zone. Replaces any existing
    /// row (upsert on zone_name). Called after every successful pull so
    /// the next process launch can resume from this point.
    static func save(token: CKServerChangeToken, zoneName: String, storage: any Storage) async throws {
        let blob = try archive(token)
        try await saveBlob(blob, zoneName: zoneName, storage: storage)
    }

    /// Remove the persisted token for the given zone. A subsequent load
    /// returns nil, driving a full-zone re-pull. Called when the engine
    /// receives CKError.changeTokenExpired.
    static func clear(zoneName: String, storage: any Storage) async throws {
        _ = try await storage.rowStore.delete(
            table: tableName,
            where: .eq(Column(table: tableName, name: "zone_name"), .text(zoneName))
        )
    }

    // MARK: - Internal archiver helpers
    //
    // These are `internal` (not `private`) so @testable import lets unit
    // tests exercise the archiver contract with a stand-in NSSecureCoding
    // type. CKServerChangeToken has no public initializer; instances are
    // only returned by CloudKit operations, making direct construction in
    // tests impossible without a live CloudKit container. The helper-level
    // tests verify the NSKeyedArchiver round-trip contract with NSString
    // (which also conforms to NSSecureCoding) and note the substitution.
    //
    // saveBlob / loadBlob are also exposed at this level so the per-zone
    // keying test can write and read raw bytes without needing a real token.

    /// Archive any NSObject that conforms to NSSecureCoding.
    /// Uses requiringSecureCoding: true for class-whitelisting on
    /// unarchival — see file header for rationale.
    /// NSObject is required because archivedData's ObjC-origin interface
    /// expects an Objective-C root class.
    static func archive<T: NSObject & NSSecureCoding>(_ object: T) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: true)
    }

    /// Unarchive a specific NSObject subclass that conforms to NSSecureCoding
    /// from Data. unarchivedObject(ofClass:from:) requires both NSObject
    /// and NSCoding; NSSecureCoding is a stricter requirement that implies NSCoding,
    /// so T: NSObject & NSSecureCoding satisfies the API's constraints.
    static func unarchive<T: NSObject & NSSecureCoding>(_ type: T.Type, from data: Data) throws -> T {
        guard let obj = try NSKeyedUnarchiver.unarchivedObject(ofClass: type, from: data) else {
            throw TokenStoreError.unarchiveFailed
        }
        return obj
    }

    /// Write raw archived bytes for a zone (used by save; exposed for testing).
    static func saveBlob(_ data: Data, zoneName: String, storage: any Storage) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        _ = try await storage.rowStore.upsert(
            table: tableName,
            values: [
                "zone_name":  .text(zoneName),
                "token":      .blob(data),
                "updated_at": .text(now),
            ],
            conflictColumns: ["zone_name"]
        )
    }

    /// Read raw archived bytes for a zone (used by load; exposed for testing).
    static func loadBlob(zoneName: String, storage: any Storage) async throws -> Data? {
        let rows = try await storage.rowStore.query(
            table: tableName,
            where: .eq(Column(table: tableName, name: "zone_name"), .text(zoneName))
        )
        guard let row = rows.first,
              case .blob(let data) = row["token"] else { return nil }
        return data
    }
}

// MARK: - TokenStoreError

/// Errors specific to TokenStore operations.
enum TokenStoreError: Error, Equatable {
    /// NSKeyedUnarchiver returned nil for the expected type.
    /// Indicates the stored blob is corrupt or was produced by a
    /// different archiver/class combination.
    case unarchiveFailed
}
