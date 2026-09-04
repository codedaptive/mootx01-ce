// GLK estate-format 1.4 → 1.5 migration capsule.
//
// Root cause of this capsule's existence: the vector tier was renamed
// VectorKit → SynapseKit (the old name collided with Apple's MapKit VectorKit
// framework), and the tier's two kit ids are stored values: one row each in
// PersistenceKit's schema-version ledger in every populated estate. A store
// that finds no ledger row under its declared id treats the estate as
// version 0 and replays its ladder from the start; the vector store's v5→v6
// step drops and recreates `vectors`. This capsule moves both rows to their
// new ids through `Storage.renameSchemaKit(from:to:)` (PERSISTENCEKIT_SPEC
// I-7a), keeping version and applied-at, then stamps the estate format v1_5
// (GENIUSLOCUSKIT_SPEC I-24).
//
// Placement in the chain: the rewrite runs BEFORE every older capsule (the
// 1.0→1.1 capsule opens the vector store) and the v1_5 stamp is written LAST,
// after the 1.3→1.4 capsule has stamped v1_4, so a crash mid-chain never
// leaves an estate stamped v1_5 with an older capsule's work undone.
// `GLKMigrationCatalog.prepare` calls `rewriteStorageLedgerKitIDs` at the top
// of the chain and `runStorageLedgerKitIDMigration` at the end. Both run
// before `wireSubstores`, which is where the renamed store opens.
//
// The (old, new) pairs are frozen history: the capsule rewrites exactly these
// ids whatever the store declares later. A later rename needs its own capsule.
//
// Enabled by the MigrationV1_4ToV1_5 / MigrationFloor1_0 / MigrationFloor1_1 /
// MigrationFloor1_2 / MigrationFloor1_3 / MigrationFloor1_4 Swift package
// traits and the GLK_MIGRATION_V1_4_TO_V1_5 compile-time define.
//
// Migration steps (all idempotent):
//   1. Rewrite each ledger pair in `GeniusLocusKit.storageLedgerKitIDRenames`;
//      a pair with no old row is a no-op, a pair with rows under both ids is
//      reported and left as it is.
//   2. Stamp the estate format v1_5.
//
// Logging: Apple OSLog, subsystem "com.mootx01.kit", category "GeniusLocusKit".

import Foundation
import GeniusLocusKit
import PersistenceKit
import os.log

private let log = Logger(
    subsystem: "com.mootx01.kit",
    category: "GeniusLocusKit"
)

/// One (old, new) kit-id pair the 1.4 → 1.5 capsule rewrites in the
/// schema-version ledger.
public struct StorageLedgerKitIDRename: Sendable, Equatable {
    /// The ledger id the row carries before the capsule runs.
    public let from: String
    /// The ledger id the row carries afterwards.
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// What the capsule found and did for each pair.
public struct StorageLedgerKitIDMigrationReport: Sendable, Equatable {
    /// The vector store's row: `VectorKit` → `SynapseKit`.
    public let vectorStore: SchemaKitRenameOutcome
    /// The representation-claims ledger's row: `VectorKitClaims` → `SynapseKitClaims`.
    public let representationClaims: SchemaKitRenameOutcome

    public init(vectorStore: SchemaKitRenameOutcome, representationClaims: SchemaKitRenameOutcome) {
        self.vectorStore = vectorStore
        self.representationClaims = representationClaims
    }
}

public extension GeniusLocusKit {

    /// The two ledger pairs the 1.4 → 1.5 capsule rewrites. Frozen history:
    /// these literals never follow a later rename of the vector tier.
    static let storageLedgerKitIDRenames: (
        vectorStore: StorageLedgerKitIDRename,
        representationClaims: StorageLedgerKitIDRename
    ) = (
        vectorStore: StorageLedgerKitIDRename(from: "VectorKit", to: "SynapseKit"),
        representationClaims: StorageLedgerKitIDRename(from: "VectorKitClaims", to: "SynapseKitClaims")
    )

    /// Move the vector tier's schema-version ledger rows to their SynapseKit
    /// ids without stamping anything (step 1 of the 1.4 → 1.5 capsule).
    ///
    /// Safe to call on any estate at any format: a pair with no row under the
    /// old id is a no-op, and a pair with rows under both ids is left as it
    /// is and reported. `GLKMigrationCatalog.prepare` calls this at the top
    /// of the chain, before the 1.0 → 1.1 capsule opens the vector store.
    ///
    /// - Parameter handle: The estate handle for the storage to migrate.
    /// - Returns: One `SchemaKitRenameOutcome` per pair.
    func rewriteStorageLedgerKitIDs(
        handle: EstateHandle
    ) async throws -> StorageLedgerKitIDMigrationReport {
        let storage: any Storage
        do { storage = try migrationStorage(for: handle) }
        catch {
            throw StorageLedgerKitIDMigrationError.storageUnavailable(
                reason: "no storage registered for estate: \(error)")
        }
        let pairs = Self.storageLedgerKitIDRenames
        let vectorStore = try await rename(pairs.vectorStore, on: storage)
        let representationClaims = try await rename(pairs.representationClaims, on: storage)
        return StorageLedgerKitIDMigrationReport(
            vectorStore: vectorStore, representationClaims: representationClaims)
    }

    /// Run the GLK 1.4 → 1.5 storage-ledger kit-id migration for an estate.
    ///
    /// Rewrites the ledger pairs (a no-op when `rewriteStorageLedgerKitIDs`
    /// already ran earlier in the chain), then stamps the estate format v1_5.
    /// Safe to call on any estate at v1_4 or later: the stamp is a no-op when
    /// the estate is already at v1_5.
    ///
    /// - Parameters:
    ///   - handle: The estate handle for the storage to migrate.
    ///   - now: Wall-clock instant for the format stamp row.
    /// - Returns: One `SchemaKitRenameOutcome` per pair, as found by this call.
    @discardableResult
    func runStorageLedgerKitIDMigration(
        handle: EstateHandle,
        now: Date
    ) async throws -> StorageLedgerKitIDMigrationReport {
        // Step 1: the rewrite (idempotent).
        let report = try await rewriteStorageLedgerKitIDs(handle: handle)

        // Step 2: advance the estate format to v1_5.
        let storage: any Storage
        do { storage = try migrationStorage(for: handle) }
        catch {
            throw StorageLedgerKitIDMigrationError.storageUnavailable(
                reason: "no storage registered for estate: \(error)")
        }
        do {
            try await EstateFormatStore(storage: storage).stamp(.v1_5, now: now)
            log.info("GLK 1.4→1.5 migration complete (vector store \(String(describing: report.vectorStore), privacy: .public); claims \(String(describing: report.representationClaims), privacy: .public))")
        } catch {
            throw StorageLedgerKitIDMigrationError.stampFailed(reason: "\(error)")
        }
        return report
    }

    /// One pair through `Storage.renameSchemaKit(from:to:)`, with the
    /// conflict outcome logged: rows under both ids mean a post-rename
    /// runtime already opened this estate under the new id, or the old row
    /// was restored by hand; the capsule leaves both rows and the operator
    /// decides.
    private func rename(
        _ pair: StorageLedgerKitIDRename,
        on storage: any Storage
    ) async throws -> SchemaKitRenameOutcome {
        let outcome: SchemaKitRenameOutcome
        do { outcome = try await storage.renameSchemaKit(from: pair.from, to: pair.to) }
        catch {
            throw StorageLedgerKitIDMigrationError.renameFailed(
                kitID: pair.from, reason: "\(error)")
        }
        if case let .conflict(oldVersion, newVersion) = outcome {
            log.warning("GLK 1.4→1.5 migration: ledger rows exist under both \(pair.from, privacy: .public) (v\(oldVersion)) and \(pair.to, privacy: .public) (v\(newVersion)); both left in place")
        }
        return outcome
    }
}

/// Errors thrown by the storage-ledger kit-id migration capsule.
public enum StorageLedgerKitIDMigrationError: Error, Sendable, Equatable,
    CustomStringConvertible
{
    /// The estate's storage backend could not be accessed.
    case storageUnavailable(reason: String)
    /// The ledger row for `kitID` could not be read or moved.
    case renameFailed(kitID: String, reason: String)
    /// The estate-format stamp could not be written.
    case stampFailed(reason: String)

    public var description: String {
        switch self {
        case let .storageUnavailable(reason):
            return "storage-ledger kit-id migration: storage unavailable — \(reason)"
        case let .renameFailed(kitID, reason):
            return "storage-ledger kit-id migration: ledger rename of \(kitID) failed — \(reason)"
        case let .stampFailed(reason):
            return "storage-ledger kit-id migration: estate-format stamp failed — \(reason)"
        }
    }
}
