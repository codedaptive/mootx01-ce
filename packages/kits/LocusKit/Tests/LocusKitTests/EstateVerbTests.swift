import Testing
import Foundation
@testable import LocusKit

@Suite("Estate verb tests — capture, withdraw, recall, stubs")
struct EstateVerbTests {

    /// Build a fresh estate on a unique temp path.
    private func makeEstate() async throws -> (Estate, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-verb-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        let estate = try await Estate.create(storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner")
        )
        return (estate, path)
    }

    @Test("capture round-trips a drawer with correct fields")
    func capture_roundTrip() async throws {
        let (estate, _) = try await makeEstate()
        // CaptureChannel has no `.manual` case in shipped code (see BRR);
        // `.typed` is the canonical typed-input channel.
        let frame = CaptureFrame(
            content: "Hello LocusKit",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
        )
        let drawer = try await estate.capture(frame)
        #expect(drawer.content == "Hello LocusKit")
        #expect(!drawer.wing.isEmpty)
        #expect(drawer.room == "test-room")
        #expect(drawer.udcCode == "004")
        #expect(drawer.adjectiveBitmap & 0x3F == 0)
        #expect(drawer.operationalBitmap & 0x3F == Int64(CaptureChannel.typed.rawValue))
    }

    @Test("capture with the same lineageID triggers the supersession cascade")
    func capture_supersessionByLineage() async throws {
        let (estate, _) = try await makeEstate()
        let lineage = UUID()
        let f1 = CaptureFrame(
            content: "v1",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6",
            lineageID: lineage
        )
        let d1 = try await estate.capture(f1)
        let f2 = CaptureFrame(
            content: "v2",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6",
            lineageID: lineage
        )
        _ = try await estate.capture(f2)

        let refetched = try await estate._peekDrawer(id: d1.id)
        guard let refetched else {
            Issue.record("d1 not found after supersession")
            return
        }
        #expect(refetched.adjectiveBitmap & 0x3F == Int64(State.superseded.rawValue))
    }

    @Test("withdraw moves a drawer's state to .withdrawn")
    func withdraw_changesState() async throws {
        let (estate, _) = try await makeEstate()
        let frame = CaptureFrame(
            content: "to be withdrawn",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
        )
        let drawer = try await estate.capture(frame)
        try await estate.withdraw(rowID: drawer.id, reason: "test")

        let refetched = try await estate._peekDrawer(id: drawer.id)
        guard let refetched else {
            Issue.record("drawer not found after withdraw")
            return
        }
        #expect((refetched.adjectiveBitmap & 0x3F) == Int64(State.withdrawn.rawValue))
    }

    @Test("recall yields a single page from an empty estate without throwing")
    func recall_emptyEstateSinglePage() async throws {
        let (estate, _) = try await makeEstate()
        // `.unconfirmed` suppresses the evaluator's default `.userConfirmed`
        // insertion (§ 7.9.5); this test predates the provenance-aware
        // evaluator and operates on the empty corpus that the default
        // would still admit zero rows from, so the override keeps the
        // page-shape contract observable rather than masking it.
        let stream = await estate.recall(
            RecallFrame(filterChain: [.currentlyBelieve, .unconfirmed])
        )
        var pageCount = 0
        for await page in stream {
            pageCount += 1
            #expect(page.rows.isEmpty)
            #expect(page.isLast)
        }
        #expect(pageCount == 1)
    }

    @Test("mutate stub throws invalidContent")
    func mutate_throwsInvalidContent() async throws {
        let (estate, _) = try await makeEstate()
        await #expect(throws: LocusKitError.self) {
            try await estate.mutate(rowID: "x", kind: .confirm, payload: String?.none)
        }
    }
}
