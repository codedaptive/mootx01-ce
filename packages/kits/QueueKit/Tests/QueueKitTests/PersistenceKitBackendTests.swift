// PersistenceKitBackendTests.swift
//
// Covers QUEUEKIT_SPEC §10. Uses PersistenceKitInMemory as the backing
// Storage; the contract under test is the QueueKit/PersistenceKit
// integration, not the InMemory implementation itself.

import Testing
import Foundation
import SubstrateTypes
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────
import PersistenceKit
import PersistenceKitInMemory
@testable import QueueKit

@Suite("PersistenceKitBackend (QUEUEKIT_SPEC §10)")
struct PersistenceKitBackendTests {

    func makeBackend() async throws -> PersistenceKitBackend {
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(
                estateID: UUID(),
                backend: .inMemory))
        try await PersistenceKitBackend.openSchema(on: storage)
        return PersistenceKitBackend(storage: storage)
    }

    @Test func writeThenDrain() async throws {
        let backend = try await makeBackend()
        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "s"),
            submittedAt: HLC(physicalTime: 1, logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data("p".utf8),
            extensions: ["k": .string("v")])
        try await backend.write(job)
        let claimed = try await backend.drainAvailable()
        #expect(claimed.count == 1)
        #expect(claimed[0].0.id == job.id)
        #expect(claimed[0].0.extensions == job.extensions)
    }

    @Test func drainOnEmpty() async throws {
        let backend = try await makeBackend()
        let claimed = try await backend.drainAvailable()
        #expect(claimed.isEmpty)
    }

    @Test func completeMovesToDone() async throws {
        let backend = try await makeBackend()
        let job = Job(
            id: JobID.generate(),
            streamID: StreamID(rawValue: "s"),
            submittedAt: HLC(physicalTime: 1, logicalCount: 0, nodeID: 1),
            priority: 50, payload: Data(), extensions: [:])
        try await backend.write(job)
        _ = try await backend.drainAvailable()
        try await backend.complete(
            job.id, status: .done, artifacts: [])
        let completed = try await backend.completed(streamID: nil)
        #expect(completed.count == 1)
        #expect(completed[0].id == job.id)
    }

    @Test func completeJobNotFound() async throws {
        let backend = try await makeBackend()
        do {
            try await backend.complete(
                JobID(rawValue: "deadbeef000000000000000000000000"),
                status: .done, artifacts: [])
            Issue.record("expected throw")
        } catch QueueError.jobNotFound {
            // expected
        }
    }

    @Test func completeRejectsRunning() async throws {
        let backend = try await makeBackend()
        do {
            try await backend.complete(
                JobID(rawValue: "x"),
                status: .running, artifacts: [])
            Issue.record("expected throw")
        } catch QueueError.invalidTerminalStatus {
            // expected
        }
    }

    @Test func tableNotAppendOnly() {
        // Spec §10 v1.1: appendOnly MUST be false.
        let decl = QueueKitSchema.declaration()
        let table = decl.tables.first { $0.name == queueKitTableName }!
        #expect(!table.appendOnly,
            "spec §10 v1.1: jobs table must be mutable, not appendOnly")
    }

    @Test func requiredIndices() {
        let decl = QueueKitSchema.declaration()
        let names = Set(decl.indices.map { $0.name })
        #expect(names.contains("idx_queuekit_status"))
        #expect(names.contains("idx_queuekit_claim_order"))
        #expect(names.contains("idx_queuekit_stream"))
    }
}
