// InMemoryAuditLog.swift

import Foundation
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
import SubstrateTypes

final class InMemoryAuditLog: AuditLog, Sendable {
    private let stateActor: InMemoryStateActor

    init(stateActor: InMemoryStateActor) {
        self.stateActor = stateActor
    }

    func append(_ event: AuditEvent) async throws {
        await stateActor.appendAudit(event)
    }

    func appendBatch(_ events: [AuditEvent]) async throws {
        await stateActor.appendAuditBatch(events)
    }

    func iterate(after: HLC?, rowID: UUID?, limit: Int) async throws -> [AuditEvent] {
        await stateActor.iterateAudit(after: after, rowID: rowID, limit: limit)
    }

    func eventsForRow(_ rowID: UUID) async throws -> [AuditEvent] {
        await stateActor.auditEventsForRow(rowID)
    }

    func count() async throws -> Int {
        await stateActor.auditCount()
    }
}
