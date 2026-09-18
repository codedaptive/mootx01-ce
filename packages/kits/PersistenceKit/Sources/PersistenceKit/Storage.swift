// Storage.swift
//
// Top-level Storage protocol. Every backend conforms.
//
// Storage is RowStore + BlobStore + AuditLog + StorageObserver. It does
// NOT own a vector-search engine: dense-embedding k-NN lives solely in
// SynapseKit (SynapseKit-owned vector search persistencekit-vector-contract-correction). What
// PersistenceKit guarantees instead is the ACCOMMODATION contract — every
// backend must support vector workloads' STORAGE needs (vector-payload row
// round-trip, bulk hydration at scale, count, delete) through the general
// RowStore / BlobStore surfaces. The accommodation guarantee is machine-
// enforced by the conformance harness's vector fixtures.

import Foundation

public protocol Storage: Sendable {
    var configuration: EstateConfiguration { get }

    /// The three sub-stores, accessible outside a transaction for
    /// auto-committed single operations. For multi-op atomicity,
    /// use `transaction(_:)`.
    var rowStore: any RowStore { get }
    var blobStore: any BlobStore { get }
    var auditLog: any AuditLog { get }
    var observer: any StorageObserver { get }

    /// Dataset store for user-defined tabular data (MX-TAB-1).
    ///
    /// Throws `StorageError.featureGated(feature: "datasetStore")` by default
    /// so existing `Storage` conformers (including deferred Postgres, MX-TAB-2)
    /// keep compiling without modification.
    ///
    /// Why throwing: a plain non-throwing `var` would require every conformer
    /// to unconditionally supply a value; the throwing-accessor shape lets the
    /// default protocol-extension implementation propagate `featureGated` so
    /// unimplemented backends fail at the call site instead of at compile time.
    /// Mirrors Rust's `fn dataset_store(&self) -> StorageResult<Arc<dyn DatasetStore>>`.
    var datasetStore: any DatasetStore { get throws }

    /// Open the backend (creates files, establishes connections,
    /// runs migrations up to the declared schema version).
    func open(schema: SchemaDeclaration) async throws

    /// Validate and register an existing schema without persistent writes.
    func openExisting(schema: SchemaDeclaration) async throws

    /// Close the backend cleanly. Idempotent.
    func close() async

    /// Run `block` inside a transaction at the requested isolation
    /// level. If `block` throws, the transaction rolls back.
    func transaction<T: Sendable>(
        isolation: IsolationLevel,
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T

    /// Capture immutable, bounded drawer and node rows from one backend snapshot.
    /// This is a strict storage primitive: callers perform domain decoding,
    /// authorization, filtering, and ordering after capture.
    func captureInventorySnapshot(limits: InventorySnapshotLimits) async throws -> InventorySnapshot

    /// Current schema version applied to the backend.
    /// Returns the global maximum version across all kits when multiple
    /// kits share one storage. Use `currentSchemaVersion(for:)` for
    /// per-kit precision in multi-kit deployments.
    func currentSchemaVersion() async throws -> Int

    /// Current schema version for a specific kit on this backend.
    /// Each kit migrates independently when multiple kits share one storage;
    /// this method returns the version recorded for `kitID` alone, not the
    /// global maximum across all kits.
    func currentSchemaVersion(for kitID: String) async throws -> Int

    /// Move the schema-version ledger row recorded for `oldKitID` to
    /// `newKitID`, keeping its version and its applied-at instant (SPEC I-7a).
    ///
    /// A kit's ledger row is keyed by its `kitID`. When a kit changes its id
    /// the row must move with it, or `open(schema:)` under the new id reads
    /// version 0 and replays the kit's ladder from the start on a populated
    /// estate. The operation never creates a version and never runs a
    /// migration step:
    /// - `.renamed(version:)` when a row under `oldKitID` moved;
    /// - `.noRow` when no row exists under `oldKitID` (nothing changed);
    /// - `.conflict(oldVersion:newVersion:)` when rows exist under both ids
    ///   (nothing changed; the caller decides).
    func renameSchemaKit(from oldKitID: String, to newKitID: String) async throws -> SchemaKitRenameOutcome

    /// Apply migrations forward to the schema's declared version.
    /// Forward-only, fail-fast per Q4.
    func migrate(to schema: SchemaDeclaration) async throws
}

/// The result of `Storage.renameSchemaKit(from:to:)` (SPEC I-7a).
public enum SchemaKitRenameOutcome: Sendable, Equatable {
    /// A row under the old id moved to the new id; `version` is the version it carried.
    case renamed(version: Int)
    /// No row exists under the old id; nothing changed.
    case noRow
    /// Rows exist under both ids; nothing changed.
    case conflict(oldVersion: Int, newVersion: Int)
}

public extension Storage {
    func openExisting(schema: SchemaDeclaration) async throws {
        throw StorageError.featureGated(feature: "readOnlySchemaRegistration")
    }

    /// Default isolation is read-committed.
    func transaction<T: Sendable>(
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T {
        try await transaction(isolation: .readCommitted, block)
    }

    func captureInventorySnapshot() async throws -> InventorySnapshot {
        try await captureInventorySnapshot(limits: .production)
    }

    /// Third-party storage conformers must opt in to the strict snapshot
    /// contract explicitly. Retaining this default keeps the additive protocol
    /// requirement source-compatible while failing closed at the call site.
    func captureInventorySnapshot(limits: InventorySnapshotLimits) async throws -> InventorySnapshot {
        throw StorageError.featureGated(feature: "inventorySnapshot")
    }

    /// Default `datasetStore` implementation throws `featureGated("datasetStore")`.
    ///
    /// Backends that implement the DatasetStore surface (SQLiteStorage,
    /// InMemoryStorage) override this with a concrete implementation. All
    /// other conformers — including Postgres (deferred per MX-TAB-2) and
    /// any third-party conformers — inherit this default, which fails loudly
    /// at call time instead of silently at compile time.
    var datasetStore: any DatasetStore {
        get throws {
            throw StorageError.featureGated(feature: "datasetStore")
        }
    }
}
