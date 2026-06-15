// InMemoryRowStore.swift

import Foundation
import SubstrateTypes
import PersistenceKit
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

final class InMemoryRowStore: RowStore, Sendable {
    private let stateActor: InMemoryStateActor

    init(stateActor: InMemoryStateActor) {
        self.stateActor = stateActor
    }

    func insert(table: String, values: [String: TypedValue]) async throws -> RowHandle {
        try await stateActor.insertRow(table: table, values: values)
    }

    func upsert(table: String, values: [String: TypedValue], conflictColumns: [String]) async throws -> RowHandle {
        try await stateActor.upsertRow(table: table, values: values, conflictColumns: conflictColumns)
    }

    func update(table: String, values: [String: TypedValue], where predicate: StoragePredicate) async throws -> Int {
        try await stateActor.updateRows(table: table, values: values, where: predicate)
    }

    func delete(table: String, where predicate: StoragePredicate) async throws -> Int {
        try await stateActor.deleteRows(table: table, where: predicate)
    }

    func query(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?
    ) async throws -> [StorageRow] {
        try await stateActor.queryRows(table: table, where: predicate, orderBy: orderBy, limit: limit, offset: offset, columns: nil)
    }

    // No-blob projection: drop every column not named in `columns` from each
    // returned row. The InMemory backend holds full rows in memory, so this
    // does not save a transfer the way SQLite does, but it makes the returned
    // StorageRow byte-identical to the SQLite projection — a consumer decoding
    // an absent column reads the same empty/default value on both backends, so
    // dense-first tests behave identically across InMemory and SQLite.
    func query(
        table: String,
        where predicate: StoragePredicate?,
        orderBy: [OrderClause],
        limit: Int?,
        offset: Int?,
        columns: [String]?
    ) async throws -> [StorageRow] {
        try await stateActor.queryRows(table: table, where: predicate, orderBy: orderBy, limit: limit, offset: offset, columns: columns)
    }

    func count(table: String, where predicate: StoragePredicate?) async throws -> Int {
        try await stateActor.countRows(table: table, where: predicate)
    }
}
