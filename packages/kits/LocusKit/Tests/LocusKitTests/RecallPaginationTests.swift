import Testing
import SubstrateTypes
import Foundation
@testable import LocusKit

@Suite("RecallStream pagination — spec § 7.8.4 / § 7.3")
struct RecallPaginationTests {

    /// Build a fresh estate on a unique temp path.
    private func makeEstate() async throws -> Estate {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locuskit-recall-pagination-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("estate.sqlite3")
        return try await Estate.create(storage: TestStorage.sqlite(path),
            owner: OwnerCredentials(ownerIdentifier: "test-owner")
        )
    }

    /// File `count` drawers into the estate, all distinct content.
    private func captureMany(_ count: Int, into estate: Estate) async throws {
        for i in 0..<count {
            let frame = CaptureFrame(
                content: "row-\(i)",
                channel: .typed,
                room: "test-room",
                latticeAnchor: LatticeAnchor(udcCode: "004"),
                addedBy: "test-agent",
                embeddingModelID: "minilm-v6"
            )
            _ = try await estate.capture(frame)
        }
    }

    @Test("Single page when row count fits inside limit")
    func singlePage() async throws {
        let estate = try await makeEstate()
        try await captureMany(3, into: estate)
        let stream = await estate.recall(
            RecallFrame(filterChain: [.currentlyBelieve, .unconfirmed], limit: 10)
        )
        var pages: [RecallStream.RecallPage] = []
        for await page in stream { pages.append(page) }
        #expect(pages.count == 1)
        #expect(pages[0].pageIndex == 0)
        #expect(pages[0].isLast)
        #expect(pages[0].rows.count == 3)
    }

    @Test("Multi-page pagination — five rows at limit 2 → three pages, no duplicates")
    func multiPage() async throws {
        let estate = try await makeEstate()
        try await captureMany(5, into: estate)
        let stream = await estate.recall(
            RecallFrame(filterChain: [.currentlyBelieve, .unconfirmed], limit: 2)
        )
        var pages: [RecallStream.RecallPage] = []
        for await page in stream { pages.append(page) }
        #expect(pages.count == 3)
        #expect(pages.map(\.pageIndex) == [0, 1, 2])
        #expect(pages.last?.isLast == true)
        #expect(pages.dropLast().allSatisfy { !$0.isLast })
        let totalRows = pages.reduce(0) { $0 + $1.rows.count }
        #expect(totalRows == 5)
        let allIds = pages.flatMap { $0.rows.map(\.id) }
        #expect(Set(allIds).count == allIds.count)
    }

    @Test("Empty estate yields one final page with no rows")
    func emptyEstate() async throws {
        let estate = try await makeEstate()
        let stream = await estate.recall(
            RecallFrame(filterChain: [.currentlyBelieve, .unconfirmed], limit: 10)
        )
        var pages: [RecallStream.RecallPage] = []
        for await page in stream { pages.append(page) }
        #expect(pages.count == 1)
        #expect(pages[0].rows.isEmpty)
        #expect(pages[0].isLast)
    }

    @Test("HydrationLevel.bitmapOnly strips content")
    func hydrationBitmapOnly() async throws {
        let estate = try await makeEstate()
        let frame = CaptureFrame(
            content: "hello",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
        )
        _ = try await estate.capture(frame)
        let stream = await estate.recall(
            RecallFrame(filterChain: [.currentlyBelieve, .unconfirmed],
                        hydrationLevel: .bitmapOnly)
        )
        var rows: [Drawer] = []
        for await page in stream { rows.append(contentsOf: page.rows) }
        #expect(rows.count == 1)
        #expect(rows[0].content == "")
    }

    /// Per spec § 7.3, `.structured` is "bitmap columns + structured-row fields
    /// only, no blob reads". The no-blob SQL projection returns `content = ""`
    /// for `.structured` callers — empty content is the correct result, not a
    /// deficiency. Use `.full` when content bodies are required.
    @Test("HydrationLevel.structured returns content-stripped rows (no blob reads per § 7.3)")
    func hydrationStructured() async throws {
        let estate = try await makeEstate()
        let frame = CaptureFrame(
            content: "hello",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
        )
        let captured = try await estate.capture(frame)
        let stream = await estate.recall(
            RecallFrame(filterChain: [.currentlyBelieve, .unconfirmed],
                        hydrationLevel: .structured)
        )
        var rows: [Drawer] = []
        for await page in stream { rows.append(contentsOf: page.rows) }
        #expect(rows.count == 1)
        // .structured = no blob reads: content is empty string (correct per § 7.3).
        #expect(rows[0].content == "", "structured recall must return content-stripped row")
        // Structured fields (id, bitmaps) must be intact.
        #expect(rows[0].id == captured.id)
    }

    @Test("HydrationLevel.full returns content body")
    func hydrationFull() async throws {
        let estate = try await makeEstate()
        let frame = CaptureFrame(
            content: "hello",
            channel: .typed,
            room: "test-room",
            latticeAnchor: LatticeAnchor(udcCode: "004"),
            addedBy: "test-agent",
            embeddingModelID: "minilm-v6"
        )
        _ = try await estate.capture(frame)
        let stream = await estate.recall(
            RecallFrame(filterChain: [.currentlyBelieve, .unconfirmed],
                        hydrationLevel: .full)
        )
        var rows: [Drawer] = []
        for await page in stream { rows.append(contentsOf: page.rows) }
        #expect(rows.count == 1)
        // .full loads the blob: content must be the captured body.
        #expect(rows[0].content == "hello", "full recall must return the content body")
    }

    @Test("limit nil uses RecallStream.defaultPageSize")
    func defaultPageSizeWhenLimitNil() async throws {
        let estate = try await makeEstate()
        try await captureMany(60, into: estate)
        let stream = await estate.recall(
            RecallFrame(filterChain: [.currentlyBelieve, .unconfirmed], limit: nil)
        )
        var firstPageCount: Int?
        for await page in stream {
            if firstPageCount == nil { firstPageCount = page.rows.count }
        }
        #expect(firstPageCount == RecallStream.defaultPageSize)
        #expect(RecallStream.defaultPageSize == 50)
    }
}
