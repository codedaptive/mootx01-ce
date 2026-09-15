import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import PersistenceKit
import PersistenceKitSQLite

/// Public-handle behavior for metadata and enrichment writes plus the matching
/// read surface. These tests exercise routing and lifecycle gates without
/// reaching through a handle to the backing `Estate`.
@Suite("GLK handle access surface", .serialized)
struct HandleAccessTests {

    private func openEstate(
        _ kit: GeniusLocusKit, ownerIdentifier: String
    ) async throws -> (handle: EstateHandle, url: URL) {
        let owner = OwnerCredentials(ownerIdentifier: ownerIdentifier)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glk-handle-access-\(UUID().uuidString).sqlite")
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url)))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(
            storage: storage,
            owner: owner,
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        return (handle, url)
    }

    private func cleanupSQLite(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + "-shm"))
    }

    private func capture(
        _ kit: GeniusLocusKit,
        _ handle: EstateHandle,
        content: String,
        wing: String,
        room: String
    ) async throws -> Drawer {
        try await kit.capture(handle, CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("000"),
            addedBy: "handle-access-tests",
            embeddingModelID: "test-model-v1",
            wing: wing))
    }

    private func drawer(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, id: String
    ) async throws -> Drawer {
        let drawers = try await kit.getDrawers(
            in: handle, ids: [id], hydrationLevel: .full)
        return try #require(drawers.first, "captured drawer must remain addressable through its handle")
    }

    private func expectEstateNotOpen(
        from handle: EstateHandle, body: () async throws -> Void
    ) async {
        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await body()
        }
        if case .estateNotOpen(let estateUUID)? = thrown {
            #expect(estateUUID == handle.estateUUID)
        } else {
            Issue.record("expected .estateNotOpen, got \(String(describing: thrown))")
        }
    }

    private func expectQuiesced(
        from handle: EstateHandle, body: () async throws -> Void
    ) async {
        let thrown = await #expect(throws: GeniusLocusKitError.self) {
            try await body()
        }
        if case .estateQuiesced(let estateUUID)? = thrown {
            #expect(estateUUID == handle.estateUUID)
        } else {
            Issue.record("expected .estateQuiesced, got \(String(describing: thrown))")
        }
    }

    @Test("metadata, enrichment, audit, and room reads stay in the addressed estate")
    func writesAndReadsAreIsolatedByHandle() async throws {
        let kit = GeniusLocusKit()
        let alphaEstate = try await openEstate(kit, ownerIdentifier: "handle-access-alpha")
        defer { cleanupSQLite(at: alphaEstate.url) }
        let betaEstate = try await openEstate(kit, ownerIdentifier: "handle-access-beta")
        defer { cleanupSQLite(at: betaEstate.url) }
        let alpha = alphaEstate.handle
        let beta = betaEstate.handle

        let alphaDrawer = try await capture(
            kit, alpha, content: "alpha content", wing: "alpha-wing", room: "alpha-room")
        let betaDrawer = try await capture(
            kit, beta, content: "beta content", wing: "beta-wing", room: "beta-room")
        let alphaPlacement = try #require(
            try await kit.resolveNodeNames(alpha, parentNodeIds: [alphaDrawer.parentNodeId])[alphaDrawer.parentNodeId])
        let betaPlacement = try #require(
            try await kit.resolveNodeNames(beta, parentNodeIds: [betaDrawer.parentNodeId])[betaDrawer.parentNodeId])
        #expect(alphaPlacement.wing == "alpha-wing")
        #expect(alphaPlacement.room == "alpha-room")
        #expect(betaPlacement.wing == "beta-wing")
        #expect(betaPlacement.room == "beta-room")
        let betaBeforeWrites = try await drawer(kit, beta, id: betaDrawer.id)
        let generatedAt = Date(timeIntervalSince1970: 1_700_000_123)

        try await kit.setMeta(in: alpha, key: "tests.handle.meta", value: "alpha-value")
        #expect(try await kit.setSSCFacts(in: alpha, "entity: alpha", for: alphaDrawer.id) == 1)
        #expect(try await kit.setSubjectRepresentation(
            in: alpha,
            drawerId: alphaDrawer.id,
            subject: "Alpha subject",
            pipelineVersion: "handle-access-v1",
            at: generatedAt) == 1)

        let storedAlpha = try await drawer(kit, alpha, id: alphaDrawer.id)
        #expect(storedAlpha.sscFacts == "entity: alpha")
        #expect(storedAlpha.subject == "Alpha subject")
        #expect(storedAlpha.subjectPipelineVersion == "handle-access-v1")
        #expect(storedAlpha.subjectAt == generatedAt)
        #expect(try await kit.meta(in: alpha, key: "tests.handle.meta") == "alpha-value")

        let storedBeta = try await drawer(kit, beta, id: betaDrawer.id)
        #expect(storedBeta.content == "beta content")
        #expect(storedBeta.sscFacts == betaBeforeWrites.sscFacts)
        #expect(storedBeta.subject == betaBeforeWrites.subject)
        #expect(try await kit.meta(in: beta, key: "tests.handle.meta") == nil)

        #expect(try await kit.listRooms(in: alpha, wing: "alpha-wing") == [
            RoomSummary(wing: "alpha-wing", name: "alpha-room", drawerCount: 1)
        ])
        #expect(try await kit.listRooms(in: beta, wing: "alpha-wing").isEmpty)

        let alphaAudit = try await kit.auditTrail(in: alpha, rowID: alphaDrawer.id)
        #expect(alphaAudit.contains { $0.verb == "setSubject" })
        #expect(try await kit.auditTrail(in: beta, rowID: alphaDrawer.id).isEmpty)

        try await kit.close(alpha)
        try await kit.close(beta)
    }

    @Test("stale handles refuse both access lanes")
    func staleHandleRefusesReadsAndWrites() async throws {
        let kit = GeniusLocusKit()
        let estate = try await openEstate(kit, ownerIdentifier: "handle-access-stale")
        defer { cleanupSQLite(at: estate.url) }
        let handle = estate.handle
        try await kit.close(handle)

        await expectEstateNotOpen(from: handle) {
            _ = try await kit.listRooms(in: handle)
        }
        await expectEstateNotOpen(from: handle) {
            try await kit.setMeta(in: handle, key: "tests.handle.meta", value: "must-not-write")
        }
    }

    @Test("quiesced handles preserve reads and refuse writes without mutation")
    func quiescedHandleKeepsReadsAndRefusesWrites() async throws {
        let kit = GeniusLocusKit()
        let estate = try await openEstate(kit, ownerIdentifier: "handle-access-quiesced")
        defer { cleanupSQLite(at: estate.url) }
        let handle = estate.handle
        let captured = try await capture(
            kit, handle, content: "quiesced content", wing: "quiesced-wing", room: "quiesced-room")
        let placement = try #require(
            try await kit.resolveNodeNames(handle, parentNodeIds: [captured.parentNodeId])[captured.parentNodeId])
        #expect(placement.wing == "quiesced-wing")
        #expect(placement.room == "quiesced-room")
        let generatedAt = Date(timeIntervalSince1970: 1_700_000_456)

        try await kit.setMeta(in: handle, key: "tests.handle.meta", value: "before")
        #expect(try await kit.setSSCFacts(in: handle, "entity: before", for: captured.id) == 1)
        #expect(try await kit.setSubjectRepresentation(
            in: handle,
            drawerId: captured.id,
            subject: "Before subject",
            pipelineVersion: "before-v1",
            at: generatedAt) == 1)
        let auditBefore = try await kit.auditTrail(in: handle, rowID: captured.id)

        try await kit.quiesce(handle)

        await expectQuiesced(from: handle) {
            try await kit.setMeta(in: handle, key: "tests.handle.meta", value: "after")
        }
        await expectQuiesced(from: handle) {
            _ = try await kit.setSSCFacts(in: handle, "entity: after", for: captured.id)
        }
        await expectQuiesced(from: handle) {
            _ = try await kit.setSubjectRepresentation(
                in: handle,
                drawerId: captured.id,
                subject: "After subject",
                pipelineVersion: "after-v1",
                at: generatedAt.addingTimeInterval(1))
        }

        #expect(try await kit.meta(in: handle, key: "tests.handle.meta") == "before")
        let stored = try await drawer(kit, handle, id: captured.id)
        #expect(stored.sscFacts == "entity: before")
        #expect(stored.subject == "Before subject")
        #expect(stored.subjectPipelineVersion == "before-v1")
        #expect(stored.subjectAt == generatedAt)
        #expect(try await kit.listRooms(in: handle, wing: "quiesced-wing") == [
            RoomSummary(wing: "quiesced-wing", name: "quiesced-room", drawerCount: 1)
        ])
        let auditAfter = try await kit.auditTrail(in: handle, rowID: captured.id)
        #expect(auditAfter.map(\.eventID) == auditBefore.map(\.eventID),
                "refused writes must not append an audit event")

        try await kit.close(handle)
    }
}
