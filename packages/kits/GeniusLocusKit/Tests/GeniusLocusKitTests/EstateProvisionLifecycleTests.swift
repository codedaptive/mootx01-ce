// EstateProvisionLifecycleTests.swift
//
// TDD coverage for GLK_PROVISION_001: composition-aware estate provisioning
// and lifecycle verbs added to GeniusLocusKit.
//
// Tests cover:
//   T1  provision(.glk)       — kind-prefixed profile stored in manifest
//   T2  provision(.corpusOnly) — manifest correct, corpus wired, no vector store
//   T3  provision(.locusOnly)  — manifest correct, no sub-stores wired
//   T4  Idempotent create       — re-provisioning the same storage raises duplicateEstate
//   T5  mountState             — freshly provisioned estate is .mounted
//   T6  quiesce                — transitions mounted → quiesced; idempotent on re-call
//   T7  drain                  — transitions directly to quiesced
//   T8  destroy(.glk)          — closes estate, leaves no orphan registry entry
//   T9  destroy(.locusOnly)    — works when no sub-stores were wired
//   T10 quiesce stale handle   — raises estateNotOpen
//   T11 drain stale handle     — raises estateNotOpen
//   T12 destroy after close    — succeeds (close already ran, just clears recall index)
//   T13 provision(.glk) on SQLite — durable file path: provision + capture + recall +
//       quiesce + destroy all succeed without "no such table: chunks" (regression guard
//       for cp-glk-sqlite-fix: the Corpus sub-store schema was never created when
//       migrate(to:) was called on a fresh SQLite file without a prior open call)

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

/// Build an isolated in-memory storage instance (each call produces a distinct store).
private func makeStorage() -> InMemoryStorage {
    InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .inMemory
    ))
}

/// Standard test owner credentials.
private let testOwner = OwnerCredentials(ownerIdentifier: "glk-provision-tests")

/// Standard base params for full GLK kind.
private func glkParams(name: String = "TestGLK") -> EstateProvisionParams {
    EstateProvisionParams(
        estateName: name,
        kind: .glk,
        zoomWindowLow: 1,
        zoomWindowHigh: 10,
        frameworkProfile: "KnowledgeWork",
        syncMode: .none
    )
}

/// Params for corpus-only kind.
private func corpusOnlyParams(name: String = "TestCorpusOnly") -> EstateProvisionParams {
    EstateProvisionParams(
        estateName: name,
        kind: .corpusOnly,
        zoomWindowLow: 2,
        zoomWindowHigh: 8,
        frameworkProfile: "CorpusTest",
        syncMode: .none
    )
}

/// Params for locus-only kind.
private func locusOnlyParams(name: String = "TestLocusOnly") -> EstateProvisionParams {
    EstateProvisionParams(
        estateName: name,
        kind: .locusOnly,
        zoomWindowLow: 0,
        zoomWindowHigh: 5,
        frameworkProfile: "MinimalProfile",
        syncMode: .none
    )
}

// MARK: - T1: provision(.glk) — kind-prefixed profile stored in manifest

@Suite("EstateProvision — GLK kind")
struct EstateProvisionGLKTests {

    /// provision(.glk) returns a valid handle and stores the kind-prefixed
    /// framework profile in the manifest ("GLK:KnowledgeWork").
    @Test
    func provisionGLKStoresKindPrefixedProfile() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let params = glkParams()

        let handle = try await kit.provision(
            storage: storage,
            owner: testOwner,
            params: params
        )

        // The handle UUID must be valid (non-zero).
        #expect(handle.estateUUID != UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)

        // The estate must be open in the registry.
        let count = await kit.openEstateCount
        #expect(count == 1)

        // Mount state must be .mounted immediately after provision.
        let state = await kit.mountState(for: handle)
        #expect(state == .mounted)

        // Read the manifest to confirm the kind-prefixed framework profile was persisted.
        let estate = try await kit.estate(for: handle)
        let manifest = try await estate.manifest
        // Kind-prefixed format: "GLK:KnowledgeWork"
        #expect(manifest.frameworkProfile == "GLK:KnowledgeWork",
            "provision must store kind-prefixed framework profile in the LocusKit manifest")
        // Estate name must round-trip.
        #expect(manifest.estateName == "TestGLK")
    }

    /// provision(.glk) wires a VectorStore for the handle. The vector store
    /// is accessible via the internal registry.
    @Test
    func provisionGLKWiresVectorStore() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let params = glkParams()

        let handle = try await kit.provision(
            storage: storage,
            owner: testOwner,
            params: params
        )

        // A VectorStore must be wired — access via internal registry.
        let vs = await kit.vectorStores[handle]
        #expect(vs != nil, "provision(.glk) must wire a VectorStore")
    }

    /// provision(.glk) wires a Corpus for the handle.
    @Test
    func provisionGLKWiresCorpus() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let params = glkParams()

        let handle = try await kit.provision(
            storage: storage,
            owner: testOwner,
            params: params
        )

        let corpus = await kit.corpusKits[handle]
        #expect(corpus != nil, "provision(.glk) must wire a Corpus")
    }

    /// provision stores zoomWindowLow and zoomWindowHigh in the manifest.
    @Test
    func provisionGLKStoresZoomWindow() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let params = EstateProvisionParams(
            estateName: "ZoomTest",
            kind: .glk,
            zoomWindowLow: 3,
            zoomWindowHigh: 12,
            frameworkProfile: "ZoomProfile",
            syncMode: .none
        )

        let handle = try await kit.provision(
            storage: storage,
            owner: testOwner,
            params: params
        )
        let estate = try await kit.estate(for: handle)
        let manifest = try await estate.manifest
        #expect(manifest.zoomWindowLow == 3,
            "provision must store zoomWindowLow in the manifest")
        #expect(manifest.zoomWindowHigh == 12,
            "provision must store zoomWindowHigh in the manifest")
    }
}

// MARK: - T2: provision(.corpusOnly) — manifest correct, corpus wired, no vector store

@Suite("EstateProvision — CorpusOnly kind")
struct EstateProvisionCorpusOnlyTests {

    @Test
    func provisionCorpusOnlyStoresKindPrefixedProfile() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let params = corpusOnlyParams()

        let handle = try await kit.provision(
            storage: storage,
            owner: testOwner,
            params: params
        )

        let estate = try await kit.estate(for: handle)
        let manifest = try await estate.manifest
        // Kind-prefixed format: "CorpusOnly:CorpusTest"
        #expect(manifest.frameworkProfile == "CorpusOnly:CorpusTest",
            "CorpusOnly provision must store CorpusOnly-prefixed profile")
    }

    @Test
    func provisionCorpusOnlyWiresCorpusButNotVectorStore() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let params = corpusOnlyParams()

        let handle = try await kit.provision(
            storage: storage,
            owner: testOwner,
            params: params
        )

        let corpus = await kit.corpusKits[handle]
        let vs = await kit.vectorStores[handle]
        #expect(corpus != nil, "CorpusOnly provision must wire a Corpus")
        #expect(vs == nil, "CorpusOnly provision must NOT wire a standalone VectorStore")
    }
}

// MARK: - T3: provision(.locusOnly) — manifest correct, no sub-stores wired

@Suite("EstateProvision — LocusOnly kind")
struct EstateProvisionLocusOnlyTests {

    @Test
    func provisionLocusOnlyStoresKindPrefixedProfile() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let params = locusOnlyParams()

        let handle = try await kit.provision(
            storage: storage,
            owner: testOwner,
            params: params
        )

        let estate = try await kit.estate(for: handle)
        let manifest = try await estate.manifest
        #expect(manifest.frameworkProfile == "LocusOnly:MinimalProfile",
            "LocusOnly provision must store LocusOnly-prefixed profile")
    }

    @Test
    func provisionLocusOnlyWiresNoSubStores() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let params = locusOnlyParams()

        let handle = try await kit.provision(
            storage: storage,
            owner: testOwner,
            params: params
        )

        let corpus = await kit.corpusKits[handle]
        let vs = await kit.vectorStores[handle]
        #expect(corpus == nil, "LocusOnly provision must NOT wire a Corpus")
        #expect(vs == nil, "LocusOnly provision must NOT wire a VectorStore")
    }
}

// MARK: - T4: Idempotent create — re-provisioning same storage raises duplicateEstate

@Suite("EstateProvision — idempotent create")
struct EstateProvisionIdempotentTests {

    @Test
    func reprovisioningSameStorageRaisesDuplicateEstate() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let params = glkParams()

        // First provision succeeds.
        _ = try await kit.provision(
            storage: storage,
            owner: testOwner,
            params: params
        )

        // Second provision on the same storage: the estate UUID is already in the
        // registry, so duplicateEstate must be thrown.
        do {
            _ = try await kit.provision(
                storage: storage,
                owner: testOwner,
                params: params
            )
            Issue.record("Expected duplicateEstate error for re-provisioning same storage")
        } catch let error as GeniusLocusKitError {
            switch error {
            case .duplicateEstate:
                // Expected — estate already registered.
                break
            default:
                Issue.record("Expected duplicateEstate but got: \(error)")
            }
        }
    }

    @Test
    func provisioningDistinctStoragesSucceeds() async throws {
        let kit = GeniusLocusKit()
        let s1 = makeStorage()
        let s2 = makeStorage()

        let h1 = try await kit.provision(storage: s1, owner: testOwner, params: glkParams(name: "Estate1"))
        let h2 = try await kit.provision(storage: s2, owner: testOwner, params: glkParams(name: "Estate2"))

        // Two distinct estates — handles must be different.
        #expect(h1.estateUUID != h2.estateUUID)
        let count = await kit.openEstateCount
        #expect(count == 2)
    }
}

// MARK: - T5–T7: Mount state transitions

@Suite("EstateProvision — mount state transitions")
struct EstateMountStateTests {

    @Test
    func freshlyProvisionedEstateIsMounted() async throws {
        let kit = GeniusLocusKit()
        let handle = try await kit.provision(
            storage: makeStorage(), owner: testOwner, params: glkParams()
        )
        let state = await kit.mountState(for: handle)
        #expect(state == .mounted)
    }

    @Test
    func quiesceTransitionsMountedToQuiesced() async throws {
        let kit = GeniusLocusKit()
        let handle = try await kit.provision(
            storage: makeStorage(), owner: testOwner, params: glkParams()
        )
        try await kit.quiesce(handle)
        let state = await kit.mountState(for: handle)
        #expect(state == .quiesced)
    }

    @Test
    func quiesceIsIdempotentOnAlreadyQuiescedEstate() async throws {
        let kit = GeniusLocusKit()
        let handle = try await kit.provision(
            storage: makeStorage(), owner: testOwner, params: glkParams()
        )
        // Quiesce twice — must not throw on the second call.
        try await kit.quiesce(handle)
        try await kit.quiesce(handle) // idempotent
        let state = await kit.mountState(for: handle)
        #expect(state == .quiesced)
    }

    @Test
    func drainTransitionsToQuiesced() async throws {
        let kit = GeniusLocusKit()
        let handle = try await kit.provision(
            storage: makeStorage(), owner: testOwner, params: glkParams()
        )
        try await kit.drain(handle)
        let state = await kit.mountState(for: handle)
        #expect(state == .quiesced,
            "drain must complete by transitioning to .quiesced")
    }

    @Test
    func mountStateForClosedHandleIsNil() async throws {
        // Open, close, then check mount state — must be nil after close.
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let handle = try await kit.provision(
            storage: storage, owner: testOwner, params: glkParams()
        )
        try await kit.close(handle)
        let state = await kit.mountState(for: handle)
        #expect(state == nil, "closed handle must return nil mount state")
    }
}

// MARK: - T8–T9: destroy

@Suite("EstateProvision — destroy")
struct EstateDestroyTests {

    @Test
    func destroyGLKClosesEstateAndClearsRegistry() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let params = glkParams()

        let handle = try await kit.provision(
            storage: storage, owner: testOwner, params: params
        )
        // Verify it's open.
        let beforeCount = await kit.openEstateCount
        #expect(beforeCount == 1)

        try await kit.destroy(storage: storage, handle: handle)

        // Registry entry must be gone.
        let afterCount = await kit.openEstateCount
        #expect(afterCount == 0, "destroy must remove the estate from the registry")
        // Mount state for the handle must be nil (cleaned up).
        let state = await kit.mountState(for: handle)
        #expect(state == nil, "destroy must clear mount state")
    }

    @Test
    func destroyLocusOnlySucceedsWithoutSubStores() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()

        let handle = try await kit.provision(
            storage: storage, owner: testOwner, params: locusOnlyParams()
        )
        // Must not throw — no sub-store teardown code paths needed.
        try await kit.destroy(storage: storage, handle: handle)

        let count = await kit.openEstateCount
        #expect(count == 0)
    }

    @Test
    func destroyAfterManualCloseStillSucceeds() async throws {
        // If the caller already closed the estate, destroy must not crash.
        // It falls through to sub-store teardown (registry entry already gone).
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let params = corpusOnlyParams()

        let handle = try await kit.provision(
            storage: storage, owner: testOwner, params: params
        )
        // Manual close first.
        try await kit.close(handle)
        // destroy on a closed handle — must succeed.
        try await kit.destroy(storage: storage, handle: handle)
        // Nothing left in the registry.
        let count = await kit.openEstateCount
        #expect(count == 0)
    }
}

// MARK: - T10–T11: error paths for stale handles

@Suite("EstateProvision — error paths")
struct EstateProvisionErrorTests {

    @Test
    func quiesceOnClosedHandleThrowsEstateNotOpen() async throws {
        // Provision then close; the handle is now stale. quiesce must raise estateNotOpen.
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let handle = try await kit.provision(
            storage: storage, owner: testOwner, params: locusOnlyParams()
        )
        try await kit.close(handle)
        do {
            try await kit.quiesce(handle)
            Issue.record("Expected estateNotOpen but quiesce succeeded on closed handle")
        } catch let error as GeniusLocusKitError {
            switch error {
            case .estateNotOpen:
                break // expected
            default:
                Issue.record("Expected estateNotOpen but got: \(error)")
            }
        }
    }

    @Test
    func drainOnClosedHandleThrowsEstateNotOpen() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let handle = try await kit.provision(
            storage: storage, owner: testOwner, params: locusOnlyParams()
        )
        try await kit.close(handle)
        do {
            try await kit.drain(handle)
            Issue.record("Expected estateNotOpen but drain succeeded on closed handle")
        } catch let error as GeniusLocusKitError {
            switch error {
            case .estateNotOpen:
                break // expected
            default:
                Issue.record("Expected estateNotOpen but got: \(error)")
            }
        }
    }

    @Test
    func provisionWithEmptyNameThrowsInvalidManifest() async throws {
        let kit = GeniusLocusKit()
        let badParams = EstateProvisionParams(
            estateName: "",
            kind: .glk,
            zoomWindowLow: 0,
            zoomWindowHigh: 5,
            frameworkProfile: "SomeProfile",
            syncMode: .none
        )
        do {
            _ = try await kit.provision(storage: makeStorage(), owner: testOwner, params: badParams)
            Issue.record("Expected invalidManifest for empty estate name")
        } catch let error as GeniusLocusKitError {
            switch error {
            case .invalidManifest(let key, _):
                #expect(key == "estate_name")
            default:
                Issue.record("Expected invalidManifest but got: \(error)")
            }
        }
    }

    @Test
    func provisionWithInvertedZoomWindowThrowsInvalidManifest() async throws {
        let kit = GeniusLocusKit()
        let badParams = EstateProvisionParams(
            estateName: "InvertedWindow",
            kind: .glk,
            zoomWindowLow: 10,
            zoomWindowHigh: 3, // inverted
            frameworkProfile: "P",
            syncMode: .none
        )
        do {
            _ = try await kit.provision(storage: makeStorage(), owner: testOwner, params: badParams)
            Issue.record("Expected invalidManifest for inverted zoom window")
        } catch let error as GeniusLocusKitError {
            switch error {
            case .invalidManifest(let key, _):
                #expect(key == "zoom_window")
            default:
                Issue.record("Expected invalidManifest but got: \(error)")
            }
        }
    }
}

// MARK: - T12: separate corpusStorage path

@Suite("EstateProvision — separate corpus storage")
struct EstateProvisionSeparateStorageTests {

    @Test
    func provisionGLKWithSeparateCorpusStorageMountsBothStores() async throws {
        let kit = GeniusLocusKit()
        let primaryStorage = makeStorage()
        let corpusStorage = makeStorage()

        let handle = try await kit.provision(
            storage: primaryStorage,
            corpusStorage: corpusStorage,
            owner: testOwner,
            params: glkParams()
        )

        // Both corpus and vector store must be wired.
        let corpus = await kit.corpusKits[handle]
        let vs = await kit.vectorStores[handle]
        #expect(corpus != nil, "separate corpusStorage path must wire a Corpus")
        #expect(vs != nil, "separate corpusStorage path must wire a VectorStore")

        let state = await kit.mountState(for: handle)
        #expect(state == .mounted)
    }

    @Test
    func destroyGLKWithSeparateStorageSucceeds() async throws {
        let kit = GeniusLocusKit()
        let primaryStorage = makeStorage()
        let corpusStorage = makeStorage()

        let handle = try await kit.provision(
            storage: primaryStorage,
            corpusStorage: corpusStorage,
            owner: testOwner,
            params: glkParams()
        )

        // destroy must succeed and remove the estate from the registry.
        try await kit.destroy(
            storage: primaryStorage,
            corpusStorage: corpusStorage,
            handle: handle
        )
        let separateCount = await kit.openEstateCount
        #expect(separateCount == 0)
    }
}

// MARK: - T13: provision(.glk) on SQLite file backend (regression guard cp-glk-sqlite-fix)

/// SQLite-file provision tests.
///
/// Prior to cp-glk-sqlite-fix, `provision(kind: .glk)` on a SQLite backend failed
/// with "no such table: chunks". The root cause: `Corpus.init` calls
/// `storage.migrate(to: BundleStore.schemaDeclaration)`, but `SQLiteStorage.migrate(to:)`
/// called `applyMigrations` which only ran pending SQL migration steps — it never
/// created the tables declared in the schema. `InMemoryStorage.migrate(to:)` does create
/// tables, which is why all prior provision tests (using InMemory) passed.
///
/// These tests exercise the durable path and act as a regression guard.
@Suite("EstateProvision — SQLite file backend (cp-glk-sqlite-fix regression guard)")
struct EstateProvisionSQLiteTests {

    /// Create a SQLite-backed storage at a unique temp path.
    /// The file is created fresh; the caller is responsible for cleanup.
    private func makeSQLiteStorage() throws -> (SQLiteStorage, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-sqlite-provision-\(UUID().uuidString).sqlite")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url)
        ))
        return (storage, url)
    }

    /// Remove a SQLite file and its WAL / SHM sidecars.
    private func cleanup(_ url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let target = URL(fileURLWithPath: url.path + suffix)
            try? fm.removeItem(at: target)
        }
    }

    /// provision(.glk) on a fresh SQLite file must succeed and the estate must be usable.
    ///
    /// Regression: before cp-glk-sqlite-fix this test threw
    ///   "no such table: chunks"
    /// during Corpus.init's allChunks() call because migrate(to:) did not create tables.
    @Test
    func provisionGLKOnSQLiteSucceedsAndEstateIsUsable() async throws {
        let (storage, url) = try makeSQLiteStorage()
        defer { cleanup(url) }

        let kit = GeniusLocusKit()
        let params = EstateProvisionParams(
            estateName: "SQLiteGLKEstate",
            kind: .glk,
            zoomWindowLow: 0,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none,
            // Ephemeral: the Ed25519 identity key stays in process memory, so this
            // file-backed estate leaves zero Keychain residue when its file is
            // deleted (test-loop key-residue fix). Only the identity key store
            // changes; the SQLite file backend still exercises the regression path.
            lifetime: .ephemeral
        )
        let owner = OwnerCredentials(ownerIdentifier: "sqlite-provision-test")

        // Must not throw. Before the fix this raised "no such table: chunks".
        let handle = try await kit.provision(
            storage: storage,
            owner: owner,
            params: params
        )

        // Estate is mounted and both sub-stores are wired.
        let mountState = await kit.mountState(for: handle)
        #expect(mountState == .mounted)

        let corpus = await kit.corpusKits[handle]
        let vs = await kit.vectorStores[handle]
        #expect(corpus != nil, "provision(.glk) on SQLite must wire a Corpus")
        #expect(vs != nil, "provision(.glk) on SQLite must wire a VectorStore")

        // Capture a drawer so the estate has real content, using the GLK verb surface.
        let frame = CaptureFrame(
            content: "SQLite durable provision round-trip test content.",
            channel: .typed,
            room: "sqlite-provision-tests",
            latticeAnchor: .udc("000"),
            addedBy: "sqlite-provision-test",
            embeddingModelID: "test-model-v1"
        )
        let drawer = try await kit.capture(handle, frame)
        #expect(!drawer.id.isEmpty, "captured drawer must have a non-empty id")

        // allDrawers on the underlying estate must include the captured row.
        let estate = try await kit.estate(for: handle)
        let drawers = try await estate.allDrawers()
        #expect(!drawers.isEmpty, "captured drawer must be retrievable after SQLite provision")

        // Lifecycle: quiesce then destroy must succeed cleanly.
        try await kit.quiesce(handle)
        let quiescedState = await kit.mountState(for: handle)
        #expect(quiescedState == .quiesced)

        try await kit.destroy(storage: storage, handle: handle)
        let afterDestroyCount = await kit.openEstateCount
        #expect(afterDestroyCount == 0, "destroy must remove SQLite-backed estate from registry")
    }

    /// provision(.corpusOnly) on a fresh SQLite file must also succeed.
    ///
    /// corpusOnly uses the same Corpus.init → migrate(to:) path as .glk; verifying
    /// this kind ensures the fix covers all corpus-bearing kinds.
    @Test
    func provisionCorpusOnlyOnSQLiteSucceeds() async throws {
        let (storage, url) = try makeSQLiteStorage()
        defer { cleanup(url) }

        let kit = GeniusLocusKit()
        let params = EstateProvisionParams(
            estateName: "SQLiteCorpusOnlyEstate",
            kind: .corpusOnly,
            zoomWindowLow: 0,
            zoomWindowHigh: 5,
            frameworkProfile: "CorpusTest",
            syncMode: .none,
            // Ephemeral identity key: no Keychain write for this file-backed
            // estate (test-loop key-residue fix). SQLite backend path unchanged.
            lifetime: .ephemeral
        )
        let owner = OwnerCredentials(ownerIdentifier: "sqlite-provision-test")

        // Must not throw.
        let handle = try await kit.provision(
            storage: storage,
            owner: owner,
            params: params
        )

        let corpus = await kit.corpusKits[handle]
        let vs = await kit.vectorStores[handle]
        #expect(corpus != nil, "corpusOnly provision on SQLite must wire a Corpus")
        #expect(vs == nil, "corpusOnly provision on SQLite must NOT wire a standalone VectorStore")

        try await kit.destroy(storage: storage, handle: handle)
        let sqliteCount = await kit.openEstateCount
        #expect(sqliteCount == 0)
    }
}

// MARK: - Default wing seeding at provision

/// Seven default wings are seeded at provision.
///
/// Every provisioned estate (any kind) has seven wings, each carrying a
/// hint drawer (AI_Charter_Hint room) that describes the wing's role. The
/// default wing for `capture` is "Agentic Memory". Hint drawers are normal
/// drawers — embedded and recalled like any other drawer.
@Suite("Default Wing Seeding at Provision")
struct DefaultWingSeedingTests {

    // MARK: - T14: seven wings present after provision

    /// A freshly provisioned estate exposes exactly 7 distinct wing names —
    /// the wing organization default wing set, drawn from `LocusKit.defaultWings`.
    @Test
    func provisionSeedsSevenDistinctWings() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let handle = try await kit.provision(storage: storage, owner: testOwner, params: glkParams())
        defer { Task { try? await kit.close(handle) } }

        let estate = try await kit.estate(for: handle)
        let allDrawers = try await estate.allDrawers()
        let nodeNames = try await estate.resolveNodeNames(
            parentNodeIds: allDrawers.map(\.parentNodeId))
        let wingNames = Set(nodeNames.values.map(\.wing))

        let expectedWings = Set(LocusKit.defaultWings.map(\.name))
        #expect(wingNames == expectedWings,
            "provision must seed exactly the 7 default wing names; got \(wingNames)")
    }

    // MARK: - T15: each wing has a hint drawer in AI_Charter_Hint room

    /// Each of the 7 default wings has exactly one hint drawer in the
    /// `AI_Charter_Hint` room, confirming wings are created by hint filing.
    @Test
    func eachDefaultWingHasOneHintDrawer() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let handle = try await kit.provision(storage: storage, owner: testOwner, params: glkParams())
        defer { Task { try? await kit.close(handle) } }

        let estate = try await kit.estate(for: handle)
        let allDrawers = try await estate.allDrawers()
        let hints = allDrawers.filter { $0.addedBy == LocusKit.hintAddedBy }

        #expect(hints.count == LocusKit.defaultWings.count,
            "must have one hint drawer per default wing; got \(hints.count)")

        // Resolve display names so we can verify each wing has exactly one hint drawer.
        let nodeNames = try await estate.resolveNodeNames(parentNodeIds: hints.map(\.parentNodeId))

        // Every default wing name must appear exactly once.
        for wing in LocusKit.defaultWings {
            let wingHints = hints.filter { nodeNames[$0.parentNodeId]?.wing == wing.name }
            #expect(wingHints.count == 1,
                "wing '\(wing.name)' must have exactly 1 hint drawer; got \(wingHints.count)")
        }
    }

    // MARK: - T16: default wing name is "Agentic Memory"

    /// `LocusKit.defaultWingName` is "Agentic Memory" and capture lands there.
    @Test
    func defaultWingNameIsAgenticMemory() async throws {
        #expect(LocusKit.defaultWingName == "Agentic Memory",
            "defaultWingName must be 'Agentic Memory'")

        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let handle = try await kit.provision(storage: storage, owner: testOwner, params: glkParams())
        defer { Task { try? await kit.close(handle) } }

        let frame = CaptureFrame(
            content: "arbitrary content",
            channel: .typed,
            room: "inbox",
            latticeAnchor: .udc("001"),
            addedBy: "test",
            embeddingModelID: "test-v1"
        )
        let drawer = try await kit.capture(handle, frame)
        let estate = try await kit.estate(for: handle)
        let names = try await estate.resolveNodeNames(parentNodeIds: [drawer.parentNodeId])
        let wingName = names[drawer.parentNodeId]?.wing ?? ""
        #expect(wingName == LocusKit.defaultWingName,
            "capture without explicit wing must land in defaultWingName")
    }

    // MARK: - T17: hint drawers do NOT carry the "none" embedding sentinel

    /// Hint drawers are normal content — they must NOT carry embeddingModelID == "none".
    /// They carry a real model ID (or "estate-provision" as a non-"none" fallback if no
    /// corpus is wired at provision time). The encode pipeline embeds them normally.
    @Test
    func hintDrawersDoNotCarryNoneEmbeddingSentinel() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let handle = try await kit.provision(storage: storage, owner: testOwner, params: glkParams())
        defer { Task { try? await kit.close(handle) } }

        let estate = try await kit.estate(for: handle)
        let allDrawers = try await estate.allDrawers()
        let hints = allDrawers.filter { $0.addedBy == LocusKit.hintAddedBy }

        for hint in hints {
            #expect(hint.embeddingModelID != "none",
                "hint drawer '\(hint.id)' must NOT have embeddingModelID == 'none'; got '\(hint.embeddingModelID)'")
        }
    }

    // MARK: - T18: seeding works for all estate kinds

    /// Wing seeding is not restricted to GLK estates — locusOnly and
    /// corpusOnly estates also receive the 7 default wings.
    @Test
    func allEstateKindsSeedDefaultWings() async throws {
        for (name, params) in [
            ("locus-only", locusOnlyParams()),
            ("corpus-only", corpusOnlyParams()),
        ] {
            let kit = GeniusLocusKit()
            let storage = makeStorage()
            let handle = try await kit.provision(storage: storage, owner: testOwner, params: params)
            defer { Task { try? await kit.close(handle) } }

            let estate = try await kit.estate(for: handle)
            let allDrawers = try await estate.allDrawers()
            let nodeNames = try await estate.resolveNodeNames(
                parentNodeIds: allDrawers.map(\.parentNodeId))
            let wingNames = Set(nodeNames.values.map(\.wing))
            let expectedWings = Set(LocusKit.defaultWings.map(\.name))
            #expect(wingNames == expectedWings,
                "\(name) provision must seed all 7 default wings; got \(wingNames)")
        }
    }
}

// MARK: - –serve-path wing seeding via seedDefaultWings (wing organization + serve-wires-corpus fix)

/// Tests proving that the SERVE-STYLE open path (bare Estate.create → kit.open →
/// kit.seedDefaultWings) produces the same seven wings as the provision path.
///
/// Background: `mootx01 serve` opens estates via `Estate.create` + `kit.open` +
/// `kit.wireGLKSubstores` — it does NOT call `provision`. Before this fix, served
/// estates had NO wings (verified: `estate_map` on a fresh served estate returned
/// "estate map:" empty). The fix adds `seedDefaultWings` — a public, idempotent
/// method on GeniusLocusKit — and calls it from ServeCommand after `wireGLKSubstores`.
///
/// T19: Serve-style open + seedDefaultWings yields exactly 7 wings each with a hint drawer.
/// T20: Calling seedDefaultWings twice (idempotency) still yields exactly 7 wings.
/// T21: seedDefaultWings on a provision-created estate is a no-op (still 7 wings, no duplicates).
@Suite("wing organization — Serve-Path Wing Seeding (seedDefaultWings)")
struct ServePathWingSeedingTests {

    // MARK: - T19: bare open + seedDefaultWings produces 7 wings

    /// A serve-style open (Estate.create → kit.open) followed by seedDefaultWings
    /// must produce exactly 7 wings, each with one hint drawer (AI_Charter_Hint room).
    ///
    /// This is the exact flow that `mootx01 serve` executes after this fix:
    ///   1. LocusKit.Estate.create (raw create — no provision, no wing seeding)
    ///   2. kit.open (admits estate to registry, issues handle)
    ///   3. kit.seedDefaultWings (seeds missing wings idempotently)
    @Test
    func serveStyleOpenThenSeedDefaultWingsYieldsSevenWings() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // Serve-style open: create + open (not provision — this is the gap).
        _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)
        let handle = try await kit.open(storage: storage, owner: testOwner)
        defer { Task { try? await kit.close(handle) } }

        // Before seeding: the bare opened estate must have NO wing drawers.
        let estateBefore = try await kit.estate(for: handle)
        let drawersBefore = try await estateBefore.allDrawers()
        #expect(drawersBefore.isEmpty,
            "bare open (no provision) must produce zero drawers — wings are absent")

        // The fix: seedDefaultWings seeds the 7 default wings idempotently.
        try await kit.seedDefaultWings(for: handle, now: now)

        // After seeding: exactly 7 wings each with one hint drawer (AI_Charter_Hint room).
        let estateAfter = try await kit.estate(for: handle)
        let allDrawers = try await estateAfter.allDrawers()
        let hints = allDrawers.filter { $0.addedBy == LocusKit.hintAddedBy }

        // Resolve display names to verify wing assignment.
        let nodeNames = try await estateAfter.resolveNodeNames(parentNodeIds: hints.map(\.parentNodeId))
        let wingNames = Set(hints.compactMap { nodeNames[$0.parentNodeId]?.wing })
        let expectedWings = Set(LocusKit.defaultWings.map(\.name))
        #expect(wingNames == expectedWings,
            "seedDefaultWings must produce exactly the 7 default wing names; got \(wingNames)")
        #expect(hints.count == LocusKit.defaultWings.count,
            "must have exactly one hint drawer per wing; got \(hints.count)")

        // Verify each wing has exactly one hint drawer.
        for wing in LocusKit.defaultWings {
            let wingHints = hints.filter { nodeNames[$0.parentNodeId]?.wing == wing.name }
            #expect(wingHints.count == 1,
                "wing '\(wing.name)' must have exactly 1 hint drawer after seedDefaultWings; got \(wingHints.count)")
        }
    }

    // MARK: - T20: idempotency — calling seedDefaultWings twice does not duplicate charters

    /// Calling seedDefaultWings twice on the same estate must NOT produce duplicate
    /// hint drawers. After two calls: still exactly 7 wings, one hint drawer each.
    ///
    /// This is the serve restart scenario: process exits, restarts, opens the same
    /// estate, calls seedDefaultWings again — must be a no-op on the second call.
    @Test
    func seedDefaultWingsTwiceIsIdempotentNoDuplicateCharters() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)
        let handle = try await kit.open(storage: storage, owner: testOwner)
        defer { Task { try? await kit.close(handle) } }

        // First call seeds 7 wings.
        try await kit.seedDefaultWings(for: handle, now: now)

        // Second call must be a no-op (no additional drawers inserted).
        try await kit.seedDefaultWings(for: handle, now: now)

        let estate = try await kit.estate(for: handle)
        let allDrawers = try await estate.allDrawers()
        let hints = allDrawers.filter { $0.addedBy == LocusKit.hintAddedBy }

        // Still exactly 7 wings — no duplicates from the second call.
        #expect(hints.count == LocusKit.defaultWings.count,
            "seedDefaultWings called twice must not produce duplicate hint drawers; got \(hints.count)")

        // Resolve display names to verify per-wing hint drawer uniqueness.
        let nodeNames = try await estate.resolveNodeNames(parentNodeIds: hints.map(\.parentNodeId))
        for wing in LocusKit.defaultWings {
            let wingHints = hints.filter { nodeNames[$0.parentNodeId]?.wing == wing.name }
            #expect(wingHints.count == 1,
                "wing '\(wing.name)' must still have exactly 1 hint drawer after second seedDefaultWings; got \(wingHints.count)")
        }
    }

    // MARK: - T21: seedDefaultWings on a provisioned estate is a no-op

    /// `provision` already seeds 7 wings. Calling `seedDefaultWings` on a
    /// provisioned estate must add zero new drawers — all wings are already present.
    ///
    /// This proves that calling seedDefaultWings from the serve path on an estate
    /// that was provisioned via `provision` (and then re-opened via serve) is safe.
    @Test
    func seedDefaultWingsOnProvisionedEstateIsNoOp() async throws {
        let kit = GeniusLocusKit()
        let storage = makeStorage()
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // Provision seeds 7 wings as part of its flow.
        let handle = try await kit.provision(storage: storage, owner: testOwner, params: glkParams())
        defer { Task { try? await kit.close(handle) } }

        let estateBefore = try await kit.estate(for: handle)
        let drawersBefore = try await estateBefore.allDrawers()
        let hintsBefore = drawersBefore.filter { $0.addedBy == LocusKit.hintAddedBy }
        #expect(hintsBefore.count == LocusKit.defaultWings.count,
            "provision must have seeded exactly 7 hint drawers")

        // Calling seedDefaultWings on a fully-seeded estate must be a complete no-op.
        try await kit.seedDefaultWings(for: handle, now: now)

        let estateAfter = try await kit.estate(for: handle)
        let drawersAfter = try await estateAfter.allDrawers()
        let hintsAfter = drawersAfter.filter { $0.addedBy == LocusKit.hintAddedBy }

        // Hint drawer count must be unchanged — no duplicates added.
        #expect(hintsAfter.count == hintsBefore.count,
            "seedDefaultWings on a provisioned estate must add 0 hint drawers; before=\(hintsBefore.count), after=\(hintsAfter.count)")
    }
}
