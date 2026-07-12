// Storage.swift
//
// Top-level Storage protocol. Every backend conforms.
//
// Storage is RowStore + BlobStore + AuditLog + StorageObserver. It does
// NOT own a vector-search engine: dense-embedding k-NN lives solely in
// VectorKit (ADR-008 persistencekit-vector-contract-correction). What
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

    /// Close the backend cleanly. Idempotent.
    func close() async

    /// Run `block` inside a transaction at the requested isolation
    /// level. If `block` throws, the transaction rolls back.
    func transaction<T: Sendable>(
        isolation: IsolationLevel,
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T

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

    /// Apply migrations forward to the schema's declared version.
    /// Forward-only, fail-fast per Q4.
    func migrate(to schema: SchemaDeclaration) async throws
}

public extension Storage {
    /// Default isolation is read-committed.
    func transaction<T: Sendable>(
        _ block: @Sendable (any StorageTransaction) async throws -> T
    ) async throws -> T {
        try await transaction(isolation: .readCommitted, block)
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
