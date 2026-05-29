import Foundation
import Testing
@testable import LocusKit

@Suite("DrawerTests")
struct DrawerTests {

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    @Test("designated init sets every field")
    func designatedInit() {
        let now = t(1_700_000_000)
        let d = Drawer(
            id: "d1", content: "hello", wing: "w", room: "r",
            sourceFile: "/tmp/x.md", chunkIndex: 3,
            addedBy: "bilby", filedAt: now,
            embeddingModelID: "minilm-v6"
        )
        #expect(d.id == "d1")
        #expect(d.content == "hello")
        #expect(d.wing == "w")
        #expect(d.room == "r")
        #expect(d.sourceFile == "/tmp/x.md")
        #expect(d.chunkIndex == 3)
        #expect(d.addedBy == "bilby")
        #expect(d.filedAt == now)
        // eventTime defaults to filedAt when omitted (ING-01): the
        // streaming-capture identity where the two clocks coincide.
        #expect(d.eventTime == now)
        #expect(d.embeddingModelID == "minilm-v6")
        #expect(d.tombstonedAt == nil)
        #expect(d.removedByBatch == nil)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let now = t(1_700_000_000)
        let d = Drawer(
            id: "d1", content: "hello", wing: "w", room: "r",
            sourceFile: "/tmp/x.md", chunkIndex: 3,
            addedBy: "bilby", filedAt: now,
            // Explicit eventTime distinct from filedAt (ING-01) so the
            // round-trip proves the event clock survives encode/decode
            // independently of the ingest clock.
            eventTime: t(1_400_000_000),
            embeddingModelID: "minilm-v6",
            tombstonedAt: t(1_700_000_500),
            removedByBatch: "batch-7"
        )
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(Drawer.self, from: data)
        #expect(back == d)
        #expect(back.eventTime == t(1_400_000_000))
    }

    @Test("Codable round-trip preserves nil optionals")
    func codableNilOptionals() throws {
        let now = t(1_700_000_000)
        let d = Drawer(
            id: "d2", content: "hello", wing: "w", room: "r",
            addedBy: "bilby", filedAt: now,
            embeddingModelID: "minilm-v6"
        )
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(Drawer.self, from: data)
        #expect(back == d)
        #expect(back.sourceFile == nil)
        #expect(back.chunkIndex == nil)
        #expect(back.tombstonedAt == nil)
        #expect(back.removedByBatch == nil)
    }

    @Test("Equatable: identical drawers are equal")
    func equatable() {
        let now = t(1_700_000_000)
        // `lineageID` is supplied explicitly because the substrate
        // generates a fresh `UUID()` per drawer when omitted (per
        // spec § 5.10), which would correctly make two
        // independently-constructed drawers unequal.
        let lineage = UUID()
        let a = Drawer(id: "x", content: "c", wing: "w", room: "r",
                       addedBy: "b", filedAt: now, embeddingModelID: "m",
                       lineageID: lineage)
        let b = Drawer(id: "x", content: "c", wing: "w", room: "r",
                       addedBy: "b", filedAt: now, embeddingModelID: "m",
                       lineageID: lineage)
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("Equatable: differing content makes drawers unequal")
    func notEqualOnContent() {
        let now = t(1_700_000_000)
        let a = Drawer(id: "x", content: "c1", wing: "w", room: "r",
                       addedBy: "b", filedAt: now, embeddingModelID: "m")
        let b = Drawer(id: "x", content: "c2", wing: "w", room: "r",
                       addedBy: "b", filedAt: now, embeddingModelID: "m")
        #expect(a != b)
    }

    @Test("default id is a fresh UUID")
    func defaultIdIsFreshUUID() {
        let now = t(1_700_000_000)
        let a = Drawer(content: "c", wing: "w", room: "r",
                       addedBy: "b", filedAt: now, embeddingModelID: "m")
        let b = Drawer(content: "c", wing: "w", room: "r",
                       addedBy: "b", filedAt: now, embeddingModelID: "m")
        #expect(a.id != b.id)
        #expect(UUID(uuidString: a.id) != nil)
    }

    @Test("designated init defaults adjectiveBitmap to 0 when omitted")
    func defaultAdjectiveBitmapZero() {
        let now = t(1_700_000_000)
        let d = Drawer(
            content: "c", wing: "w", room: "r",
            addedBy: "b", filedAt: now, embeddingModelID: "m"
        )
        #expect(d.adjectiveBitmap == 0)
    }

    @Test("designated init defaults operationalBitmap to 0 when omitted")
    func defaultOperationalBitmapZero() {
        let now = t(1_700_000_000)
        let d = Drawer(
            content: "c", wing: "w", room: "r",
            addedBy: "b", filedAt: now, embeddingModelID: "m"
        )
        #expect(d.operationalBitmap == 0)
    }
}
