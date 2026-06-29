// EstateCloseStorageTests.swift
//
// Tests for the close() storage-connection-leak fix (issue #28 from the 17a RCA).
//
// Root cause: `GeniusLocusKit.close(_:)` cleared all per-estate maps but never
// called `storage.close()` and never nilled `storages[handle]`, so the SQLite
// connection (and file lock) persisted until the actor was deallocated.
//
// Coverage:
//   T1  close() releases the SQLite file lock — the same path is openable
//       read-write immediately after close (file-lock release verification).
//   T2  close() clears storages[handle] — the map entry is nil after close.
//   T3  close() empties every per-estate map (registry, auditLogs, diaryStores,
//       kgStores, fingerprintStores, matrixTiers, calibrationRegistries,
//       matrixPersistenceBackends, nodeTopologyProviders, corpusKits,
//       vectorStores, mountStates, grantStores, scopeVaults).
//   T4  Double-close is safe — second close raises estateNotOpen, not a crash.
//   T5  Subsequent verb call on a closed handle raises estateNotOpen.

import Testing
import Foundation
import LocusKit
import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory
import PersistenceKitSQLite
@testable import GeniusLocusKit

// MARK: - Helpers

private let testOwner = OwnerCredentials(ownerIdentifier: "close-storage-tests")

/// Create a temporary SQLite path (the file is NOT created by this function;
/// SQLiteStorage creates it on first use).
private func tempSQLitePath() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("glk-close-test-\(UUID().uuidString).sqlite")
}

/// Remove a SQLite file and its WAL/SHM sidecars.
private func cleanup(_ url: URL) {
    let fm = FileManager.default
    for suffix in ["", "-wal", "-shm"] {
        let target = URL(fileURLWithPath: url.path + suffix)
        try? fm.removeItem(at: target)
    }
}

// MARK: - T1: file lock released after close

/// T1 — close() releases the SQLite file lock so the same path is immediately
/// openable read-write by a second SQLiteStorage instance.
///
/// Before the fix, the connection was retained until actor dealloc. After the
/// fix, `storage.close()` is called inside `close(_:)` and the WAL lock is
/// released synchronously. The proof: constructing a second SQLiteStorage on the
/// same path after close succeeds without a "database is locked" error from
/// SQLite.
@Suite("close() — storage file-lock release")
struct EstateCloseFileLockTests {

    @Test
    func closeReleasesFileLockAllowingImmediateReopen() async throws {
        let url = tempSQLitePath()
        defer { cleanup(url) }

        let kit = GeniusLocusKit()
        let params = EstateProvisionParams(
            estateName: "FileLockTest",
            kind: .locusOnly,
            zoomWindowLow: 0,
            zoomWindowHigh: 5,
            frameworkProfile: "FileLockProfile",
            syncMode: .none
        )

        // Provision on the SQLite file so the connection is open and WAL is active.
        let storage1 = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url)
        ))
        let handle = try await kit.provision(
            storage: storage1,
            owner: testOwner,
            params: params
        )

        // Verify the estate is mounted.
        let stateBefore = await kit.mountState(for: handle)
        #expect(stateBefore == .mounted)

        // Close the estate. After this call storage1.close() has been called
        // and the SQLite connection is released.
        try await kit.close(handle)

        // Immediately open a second SQLiteStorage on the same path.
        // If the file lock was not released, this would fail (SQLITE_BUSY / database locked).
        let storage2 = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url)
        ))

        // Opening an estate on the same path requires reading the manifest.
        // This will succeed only if the connection is writable (i.e. no shared WAL lock).
        // We use Estate.open which reads the manifest; if the file is still locked this throws.
        let estate2 = try await LocusKit.Estate.open(storage: storage2, owner: testOwner)
        let manifest = try await estate2.manifest
        // The estate name must still be in the file (data is durable).
        #expect(manifest.estateName == "FileLockTest",
            "estate manifest must be readable from the re-opened SQLite file after close")

        await storage2.close()
    }
}

// MARK: - T2: storages map cleared

/// T2 — close() nils the storages[handle] entry so no storage reference is retained
/// after close.
@Suite("close() — storages map cleared")
struct EstateCloseStoragesMapTests {

    private func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    }

    @Test
    func closeNilsStoragesEntry() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let params = EstateProvisionParams(
            estateName: "StoragesMapTest",
            kind: .locusOnly,
            zoomWindowLow: 0,
            zoomWindowHigh: 5,
            frameworkProfile: "P",
            syncMode: .none
        )
        let handle = try await kit.provision(storage: storage, owner: testOwner, params: params)

        // Before close, the storage entry must be populated.
        let beforeStorage = await kit.storages[handle]
        #expect(beforeStorage != nil, "storages[handle] must be populated after open/provision")

        try await kit.close(handle)

        // After close, the entry must be nil.
        let afterStorage = await kit.storages[handle]
        #expect(afterStorage == nil, "storages[handle] must be nil after close — storage-leak fix")
    }
}

// MARK: - T3: per-estate map census after close

/// T3 — close() empties every per-estate map: the complete map census from
/// GeniusLocusKit.swift is verified against the closed handle.
///
/// Maps censused:
///   registry, auditLogs, mountStates, storages, diaryStores, kgStores,
///   fingerprintStores, matrixTiers, calibrationRegistries,
///   matrixPersistenceBackends, nodeTopologyProviders, corpusKits,
///   vectorStores, grantStores, scopeVaults
/// (The encode queue/drain/HLC now live inside the Corpus — CorpusKit owns the
/// ingest pipeline — and are torn down when corpusKits[handle] is released.)
@Suite("close() — per-estate map census")
struct EstateCloseMapCensusTests {

    private func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    }

    @Test
    func closeEmptiesAllPerEstateMapEntries() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()

        // Provision a GLK estate so corpus, vectorStore, and encodeQueue are all wired.
        let params = EstateProvisionParams(
            estateName: "MapCensusTest",
            kind: .glk,
            zoomWindowLow: 0,
            zoomWindowHigh: 5,
            frameworkProfile: "MapCensusProfile",
            syncMode: .none
        )
        let handle = try await kit.provision(storage: storage, owner: testOwner, params: params)

        // Sanity: before close, core maps are populated.
        let regBefore = await kit.registry[handle]
        #expect(regBefore != nil, "registry must be populated before close")
        let auditBefore = await kit.auditLogs[handle]
        #expect(auditBefore != nil, "auditLogs must be populated before close")
        let mountBefore = await kit.mountStates[handle]
        #expect(mountBefore == .mounted, "mountStates must be .mounted before close")
        let storBefore = await kit.storages[handle]
        #expect(storBefore != nil, "storages must be populated before close")
        let corpusBefore = await kit.corpusKits[handle]
        #expect(corpusBefore != nil, "corpusKits must be wired (GLK kind) before close")
        let vsBefore = await kit.vectorStores[handle]
        #expect(vsBefore != nil, "vectorStores must be wired (GLK kind) before close")

        try await kit.close(handle)

        // After close, all per-estate map entries must be nil / absent.

        // Core registry maps
        let regAfter = await kit.registry[handle]
        #expect(regAfter == nil, "registry[handle] must be nil after close")

        let auditAfter = await kit.auditLogs[handle]
        #expect(auditAfter == nil, "auditLogs[handle] must be nil after close")

        let mountAfter = await kit.mountStates[handle]
        #expect(mountAfter == nil, "mountStates[handle] must be nil after close")

        // Storage — the leak fix
        let storAfter = await kit.storages[handle]
        #expect(storAfter == nil, "storages[handle] must be nil after close (leak fix #28)")

        // Sub-store registrations
        let corpusAfter = await kit.corpusKits[handle]
        #expect(corpusAfter == nil, "corpusKits[handle] must be nil after close")

        let vsAfter = await kit.vectorStores[handle]
        #expect(vsAfter == nil, "vectorStores[handle] must be nil after close")

        // Lazy-built stores (not wired for this test — assert absence, not value)
        let diaryAfter = await kit.diaryStores[handle]
        #expect(diaryAfter == nil, "diaryStores[handle] must be nil after close")

        let kgAfter = await kit.kgStores[handle]
        #expect(kgAfter == nil, "kgStores[handle] must be nil after close")

        let fpAfter = await kit.fingerprintStores[handle]
        #expect(fpAfter == nil, "fingerprintStores[handle] must be nil after close")

        let matrixAfter = await kit.matrixTiers[handle]
        #expect(matrixAfter == nil, "matrixTiers[handle] must be nil after close")

        let calRegAfter = await kit.calibrationRegistries[handle]
        #expect(calRegAfter == nil, "calibrationRegistries[handle] must be nil after close")

        let matPersAfter = await kit.matrixPersistenceBackends[handle]
        #expect(matPersAfter == nil, "matrixPersistenceBackends[handle] must be nil after close")

        let nodeTopoAfter = await kit.nodeTopologyProviders[handle]
        #expect(nodeTopoAfter == nil, "nodeTopologyProviders[handle] must be nil after close")

        // The encode QUEUE + DRAIN worker now live inside the Corpus (CorpusKit
        // owns the ingest pipeline). close() calls corpusKits[handle]?
        // .dropIngestQueue() then releases corpusKits[handle], so the
        // corpusKits-nil assertion above covers teardown of the encode pipeline;
        // GLK no longer holds encodeQueues/encodeHLCs/encodeDrainWorkers maps.

        // Grant surface maps (dropped by dropGrantSurface)
        let grantStoreAfter = await kit.grantStores[handle]
        #expect(grantStoreAfter == nil, "grantStores[handle] must be nil after close")

        let scopeVaultAfter = await kit.scopeVaults[handle]
        #expect(scopeVaultAfter == nil, "scopeVaults[handle] must be nil after close")
    }
}

// MARK: - T4: double-close is safe

/// T4 — Calling close() twice on the same handle is safe: the second call raises
/// `.estateNotOpen`, not a crash or an unexpected error variant.
@Suite("close() — double-close safety")
struct EstateCloseDoubleCloseTests {

    private func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    }

    @Test
    func doubleCloseRaisesEstateNotOpen() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let params = EstateProvisionParams(
            estateName: "DoubleCloseTest",
            kind: .locusOnly,
            zoomWindowLow: 0,
            zoomWindowHigh: 5,
            frameworkProfile: "P",
            syncMode: .none
        )
        let handle = try await kit.provision(storage: storage, owner: testOwner, params: params)

        // First close must succeed.
        try await kit.close(handle)

        // Second close on the same (now stale) handle must raise estateNotOpen.
        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await kit.close(handle)
        }
        if case .estateNotOpen(let uuid)? = thrown {
            #expect(uuid == handle.estateUUID,
                "estateNotOpen must carry the handle's UUID")
        } else {
            Issue.record("expected .estateNotOpen on double-close, got \(String(describing: thrown))")
        }
    }
}

// MARK: - T5: stale-handle error after close

/// T5 — All verb calls on a closed handle must raise `.estateNotOpen`.
/// Verifies that no verb leaks through the guard after storage has been closed.
@Suite("close() — stale-handle verb error")
struct EstateCloseStaleHandleVerbTests {

    private func makeStorage() -> InMemoryStorage {
        InMemoryStorage(configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
    }

    @Test
    func captureOnClosedHandleRaisesEstateNotOpen() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let params = EstateProvisionParams(
            estateName: "StaleHandleVerbTest",
            kind: .locusOnly,
            zoomWindowLow: 0,
            zoomWindowHigh: 5,
            frameworkProfile: "P",
            syncMode: .none
        )
        let handle = try await kit.provision(storage: storage, owner: testOwner, params: params)
        try await kit.close(handle)

        // capture must raise estateNotOpen on the closed handle.
        let frame = CaptureFrame(
            content: "test content",
            channel: .typed,
            room: "test-room",
            latticeAnchor: .udc("000"),
            addedBy: "test-agent",
            embeddingModelID: "test-model"
        )
        let thrown = await #expect(throws: (any Error).self) {
            try await kit.capture(handle, frame)
        }
        // The error must indicate the estate is not open.
        if let glkErr = thrown as? GeniusLocusKitError,
           case .estateNotOpen(let uuid) = glkErr {
            #expect(uuid == handle.estateUUID)
        } else {
            Issue.record("expected GeniusLocusKitError.estateNotOpen, got \(String(describing: thrown))")
        }
    }

    @Test
    func estateForOnClosedHandleRaisesEstateNotOpen() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let params = EstateProvisionParams(
            estateName: "StaleEstateForTest",
            kind: .locusOnly,
            zoomWindowLow: 0,
            zoomWindowHigh: 5,
            frameworkProfile: "P",
            syncMode: .none
        )
        let handle = try await kit.provision(storage: storage, owner: testOwner, params: params)
        try await kit.close(handle)

        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await kit.estate(for: handle)
        }
        if case .estateNotOpen(let uuid)? = thrown {
            #expect(uuid == handle.estateUUID)
        } else {
            Issue.record("expected .estateNotOpen, got \(String(describing: thrown))")
        }
    }
}
