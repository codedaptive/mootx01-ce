// EstateAdminTests.swift
//
// P6 verify line (engine unit tests): the admin-plane engine provisions estates
// of each kind/backend through GLK, reflects mount state, drives the lifecycle
// verbs (quiesce/drain/destroy), and refuses a destroy whose confirm-name does
// not match. All against SCRATCH estates (InMemory, or SQLite under a temp dir)
// — no real data is touched.

import Testing
import Foundation
@testable import MootManager

// MARK: - Helpers

private func makeScratchEstatesDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("moot-mgr-admin-\(UUID().uuidString)", isDirectory: true)
}

private func makeAdmin() -> EstateAdmin {
    EstateAdmin(estatesDirectory: makeScratchEstatesDir())
}

/// A valid provisioning request for the given kind/backend.
private func req(
    name: String = "Scratch",
    kind: String = "GLK",
    backend: String = "InMemory",
    owner: String = "admin-tests"
) -> EstateAdminRequest {
    EstateAdminRequest(
        estateName: name,
        kind: kind,
        backend: backend,
        zoomWindowLow: 1,
        zoomWindowHigh: 10,
        frameworkProfile: "KnowledgeWork",
        syncMode: "None",
        owner: owner
    )
}

// MARK: - Provisioning

@Suite("EstateAdmin — provisioning")
struct EstateAdminProvisionTests {

    // Every provisioning test runs under the process-wide intellectusTestMutex
    // (IntellectusTestLock.swift): provisioning emits GLK telemetry through the
    // global `Intellectus` sink, so it must not interleave with the end-to-end
    // integration test, which installs a real sink and enables the global gate.

    @Test("provision(.glk, InMemory) returns ok + a mounted estate")
    func provisionGLKInMemory() async throws {
        try await withIntellectusLock {
            let admin = makeAdmin()
            let result = try await admin.provision(req(kind: "GLK", backend: "InMemory"))
            #expect(result.ok)
            #expect(result.estateUUID != nil)
            #expect(result.mountState == "mounted")
        }
    }

    @Test("provision(.corpusOnly) and (.locusOnly) both succeed")
    func provisionOtherKinds() async throws {
        try await withIntellectusLock {
            let admin = makeAdmin()
            let corpus = try await admin.provision(req(name: "C", kind: "CorpusOnly"))
            let locus = try await admin.provision(req(name: "L", kind: "LocusOnly"))
            #expect(corpus.ok)
            #expect(locus.ok)
        }
    }

    @Test("provision(.locusOnly, SQLite) writes the estate file under the scratch dir")
    func provisionSQLite() async throws {
        try await withIntellectusLock {
            let dir = makeScratchEstatesDir()
            let admin = EstateAdmin(estatesDirectory: dir)
            // LocusOnly wires no Corpus/VectorStore sub-stores, so it exercises the
            // SQLite-backed provisioning path cleanly. (GLK's full .glk kind currently
            // covers only the InMemory backend in its own provision tests — its Corpus
            // sub-store rebuild on a fresh SQLite file is a GLK/CorpusKit concern,
            // outside this app's directory.)
            let result = try await admin.provision(req(name: "Durable", kind: "LocusOnly", backend: "SQLite"))
            #expect(result.ok)
            // The admin engine creates the estates dir and one .sqlite file in it.
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            #expect(files.contains { $0.hasSuffix(".sqlite") })
        }
    }

    @Test("provision rejects an unknown kind without creating storage")
    func provisionRejectsUnknownKind() async throws {
        let admin = makeAdmin()
        await #expect(throws: AdminError.self) {
            _ = try await admin.provision(req(kind: "NotAKind"))
        }
    }

    @Test("provision rejects an empty estate name")
    func provisionRejectsEmptyName() async throws {
        let admin = makeAdmin()
        await #expect(throws: AdminError.self) {
            _ = try await admin.provision(req(name: ""))
        }
    }

    @Test("provision rejects an inverted zoom window")
    func provisionRejectsInvertedZoom() async throws {
        let admin = makeAdmin()
        let bad = EstateAdminRequest(
            estateName: "Bad", kind: "GLK", backend: "InMemory",
            zoomWindowLow: 10, zoomWindowHigh: 1,
            frameworkProfile: "X", syncMode: "None", owner: "o")
        await #expect(throws: AdminError.self) {
            _ = try await admin.provision(bad)
        }
    }
}

// MARK: - Read reflection

@Suite("EstateAdmin — read reflection")
struct EstateAdminReflectionTests {

    @Test("payload reflects provisioned estates with kind/backend/mount-state")
    func payloadReflectsHosted() async throws {
        try await withIntellectusLock {
            let admin = makeAdmin()
            let r = try await admin.provision(req(name: "Reflected", kind: "GLK", backend: "InMemory"))
            let payload = await admin.payload()
            #expect(payload.hosted.count == 1)
            let entry = try #require(payload.hosted.first)
            #expect(entry.estateUUID == r.estateUUID)
            #expect(entry.estateName == "Reflected")
            #expect(entry.kind == "GLK")
            #expect(entry.backend == "InMemory")
            #expect(entry.mountState == "mounted")
        }
    }

    @Test("empty admin reflects an empty hosted list")
    func payloadEmptyWhenNothingProvisioned() async {
        let admin = makeAdmin()
        let payload = await admin.payload()
        #expect(payload.hosted.isEmpty)
    }
}

// MARK: - Lifecycle

@Suite("EstateAdmin — lifecycle")
struct EstateAdminLifecycleTests {

    @Test("quiesce transitions a mounted estate to quiesced")
    func quiesceTransitions() async throws {
        try await withIntellectusLock {
            let admin = makeAdmin()
            let r = try await admin.provision(req())
            let uuid = try #require(r.estateUUID)
            let q = try await admin.quiesce(EstateLifecycleRequest(estateUUID: uuid))
            #expect(q.ok)
            #expect(q.mountState == "quiesced")
            // Reflected in the read payload too.
            let payload = await admin.payload()
            #expect(payload.hosted.first?.mountState == "quiesced")
        }
    }

    @Test("drain transitions a mounted estate to quiesced")
    func drainTransitions() async throws {
        try await withIntellectusLock {
            let admin = makeAdmin()
            let r = try await admin.provision(req())
            let uuid = try #require(r.estateUUID)
            let d = try await admin.drain(EstateLifecycleRequest(estateUUID: uuid))
            #expect(d.ok)
            #expect(d.mountState == "quiesced")
        }
    }

    @Test("destroy with the matching confirm name tears the estate down")
    func destroyWithConfirm() async throws {
        try await withIntellectusLock {
            let admin = makeAdmin()
            let r = try await admin.provision(req(name: "Doomed"))
            let uuid = try #require(r.estateUUID)
            let result = try await admin.destroy(
                EstateLifecycleRequest(estateUUID: uuid, confirmName: "Doomed"))
            #expect(result.ok)
            // No longer hosted.
            let payload = await admin.payload()
            #expect(payload.hosted.isEmpty)
        }
    }

    @Test("destroy refuses when the confirm name does not match")
    func destroyRefusesMismatch() async throws {
        try await withIntellectusLock {
            let admin = makeAdmin()
            let r = try await admin.provision(req(name: "Safe"))
            let uuid = try #require(r.estateUUID)
            await #expect(throws: AdminError.destroyConfirmMismatch) {
                _ = try await admin.destroy(
                    EstateLifecycleRequest(estateUUID: uuid, confirmName: "WrongName"))
            }
            // Still hosted — destroy did not run.
            let payload = await admin.payload()
            #expect(payload.hosted.count == 1)
        }
    }

    @Test("lifecycle verb on an unknown estate throws unknownEstate")
    func lifecycleUnknownEstate() async throws {
        // No provision here — nothing is hosted, so no GLK telemetry is emitted;
        // the lock is unnecessary for this pure-rejection path.
        let admin = makeAdmin()
        await #expect(throws: AdminError.self) {
            _ = try await admin.quiesce(EstateLifecycleRequest(estateUUID: UUID().uuidString))
        }
    }
}
