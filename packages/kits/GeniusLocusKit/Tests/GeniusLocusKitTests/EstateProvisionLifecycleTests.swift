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

import Testing
import Foundation
import LocusKit
import CorpusKit
import VectorKit
import PersistenceKit
import PersistenceKitInMemory
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
        let count = await kit.openEstateCount
        #expect(count == 0)
    }
}
