// NoSyncEngineTests.swift

import XCTest
import ConvergenceKit
import ConvergenceKitNone
import PersistenceKit
import PersistenceKitInMemory
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
import SubstrateLib

final class NoSyncEngineTests: XCTestCase {

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

    func testEnableThenDisable() async throws {
        let engine = NoSyncEngine()
        let storage = makeStorage()
        try await engine.enable(manifest: makeManifest(), storage: storage)
        if case .enabled(let zone, _, _) = await engine.state {
            XCTAssertEqual(zone, "test-zone")
        } else {
            XCTFail("expected enabled state")
        }
        try await engine.disable()
        if case .disabled = await engine.state {
            // ok
        } else {
            XCTFail("expected disabled state")
        }
    }

    func testPushWithoutEnableFails() async throws {
        let engine = NoSyncEngine()
        do {
            _ = try await engine.push()
            XCTFail("expected throw")
        } catch SyncError.notEnabled {
            // ok
        }
    }

    func testPushPullEmpty() async throws {
        let engine = NoSyncEngine()
        try await engine.enable(manifest: makeManifest(), storage: makeStorage())
        let pushed = try await engine.push()
        let pulled = try await engine.pull()
        XCTAssertEqual(pushed.pushed, 0)
        XCTAssertEqual(pulled.pulled, 0)
    }

    func testDoubleEnableFails() async throws {
        let engine = NoSyncEngine()
        try await engine.enable(manifest: makeManifest(), storage: makeStorage())
        do {
            try await engine.enable(manifest: makeManifest(), storage: makeStorage())
            XCTFail("expected throw on double enable")
        } catch SyncError.alreadyEnabled {
            // ok
        }
    }
}
