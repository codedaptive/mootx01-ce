// TokenStore.swift
//
// Persists CKServerChangeToken per CloudKit zone in the _ck_change_token
// side table. Implements R5 from
// Tokens persist across process restarts and reset on server expiry.
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
// The _ck_change_token table declaration has been consolidated into
// CKSideSchema.swift (v3, CVK-ICLOUD P1-M6 adjudication A11). TokenStore's
// read/write helpers (load, save, clear, archive, unarchive, saveBlob,
// loadBlob) remain here; only the SchemaDeclaration has moved. The
// ensure(storage:) function now delegates to CKSideSchema.ensure so existing
// callers continue to work, and CloudKitStateActor.enable() no longer needs
// to call it separately (CKSideSchema.ensure already covers _ck_change_token).
//
// --- Per-zone keying ---
// zone_name is the sole primary key. Tokens for different zones are
// fully independent: saving zone A's token never touches zone B's row.
// clear(zoneName:) deletes the row; subsequent load returns nil, which
// triggers a full-zone pull from scratch on the next pull() call.

import Foundation
import CloudKit
import PersistenceKit
import ConvergenceKit

// MARK: - TokenStore

/// Persists and retrieves CKServerChangeToken per CloudKit zone.
/// All methods are static; no instances are created.
enum TokenStore {

    static let tableName = CKSideSchema.changeTokenTable

    // MARK: - Schema setup

    /// Ensure the _ck_change_token side table exists in storage.
    ///
    /// Delegates to CKSideSchema.ensure(storage:), which owns the
    /// consolidated SchemaDeclaration for all ConvergenceKit side tables.
    /// Kept as a function so existing callers compile without modification;
    /// CloudKitStateActor.enable() no longer calls this separately because
    /// CKSideSchema.ensure is already called earlier in the enable path.
    static func ensure(storage: any Storage) async throws {
        try await CKSideSchema.ensure(storage: storage)
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
