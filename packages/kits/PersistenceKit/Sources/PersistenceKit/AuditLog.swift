// AuditLog.swift
//
// Append-only audit log protocol per DECISION_STORAGEKIT_DESIGN
// §9 (Q7). PersistenceKit provides append-only persistence and
// HLC-ordered iteration. GeniusLocusKit owns CRDT enforcement.
// Append is idempotent on (eventID, hlc) compound key.

import Foundation
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
import SubstrateTypes

public protocol AuditLog: Sendable {
    /// Append a single event. Idempotent on (eventID, hlc).
    func append(_ event: AuditEvent) async throws

    /// Bulk append for sync inbound. Idempotent.
    func appendBatch(_ events: [AuditEvent]) async throws

    /// Iterate in HLC order. Resume via `after` cursor.
    func iterate(after: HLC?, rowID: UUID?, limit: Int) async throws -> [AuditEvent]

    /// Read events for a row, in HLC order, for projection.
    func eventsForRow(_ rowID: UUID) async throws -> [AuditEvent]

    /// Total event count (typically used in tests and diagnostics).
    func count() async throws -> Int
}
