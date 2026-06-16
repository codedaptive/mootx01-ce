// NoSyncEngineTests.swift

import Testing
import SubstrateTypes
import ConvergenceKit
import ConvergenceKitNone
import PersistenceKit
import PersistenceKitInMemory
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

@Suite("NoSyncEngine")
struct NoSyncEngineTests {

    func makeStorage() -> any Storage {
        InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
    }

    func makeManifest() -> SyncManifest {
        SyncManifest(
            kitID: "TestKit",
            schemaVersion: 1,
            zoneIdentifier: "test-zone",
            tables: [SyncedTable(name: "items", primaryKeyColumn: "id")]
        )
    }

    @Test("enable then disable transitions state")
    func enableThenDisable() async throws {
        let engine = NoSyncEngine()
        let storage = makeStorage()
        try await engine.enable(manifest: makeManifest(), storage: storage)
        guard case .enabled(let zone, _, _) = await engine.state else {
            Issue.record("expected enabled state")
            return
        }
        #expect(zone == "test-zone")
        try await engine.disable()
        guard case .disabled = await engine.state else {
            Issue.record("expected disabled state")
            return
        }
    }

    @Test("push without enable throws notEnabled")
    func pushWithoutEnableFails() async throws {
        let engine = NoSyncEngine()
        await #expect(throws: SyncError.notEnabled) {
            _ = try await engine.push()
        }
    }

    @Test("push and pull on empty return zero")
    func pushPullEmpty() async throws {
        let engine = NoSyncEngine()
        try await engine.enable(manifest: makeManifest(), storage: makeStorage())
        let pushed = try await engine.push()
        let pulled = try await engine.pull()
        #expect(pushed.pushed == 0)
        #expect(pulled.pulled == 0)
    }

    @Test("double enable throws alreadyEnabled")
    func doubleEnableFails() async throws {
        let engine = NoSyncEngine()
        try await engine.enable(manifest: makeManifest(), storage: makeStorage())
        await #expect(throws: SyncError.alreadyEnabled) {
            try await engine.enable(manifest: makeManifest(), storage: makeStorage())
        }
    }
}
