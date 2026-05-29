import Foundation
import Testing
@testable import LocusKit

@Suite("DiaryEntryTests")
struct DiaryEntryTests {

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    @Test("designated init sets every field")
    func designatedInit() {
        let now = t(1_700_000_000)
        let e = DiaryEntry(
            id: "e1",
            agentName: "skippy",
            entry: "today I learned",
            topic: "loci-1",
            wing: "wing_skippy",
            room: "diary",
            filedAt: now,
            embeddingModelID: "minilm-v6"
        )
        #expect(e.id == "e1")
        #expect(e.agentName == "skippy")
        #expect(e.entry == "today I learned")
        #expect(e.topic == "loci-1")
        #expect(e.wing == "wing_skippy")
        #expect(e.room == "diary")
        #expect(e.filedAt == now)
        #expect(e.embeddingModelID == "minilm-v6")
        #expect(e.tombstonedAt == nil)
        #expect(e.removedByBatch == nil)
    }

    @Test("Codable round-trip preserves all fields")
    func codableRoundTrip() throws {
        let now = t(1_700_000_000)
        let original = DiaryEntry(
            id: "e1",
            agentName: "skippy",
            entry: "x",
            topic: "y",
            wing: "wing_skippy",
            room: "diary",
            filedAt: now,
            embeddingModelID: "minilm-v6",
            tombstonedAt: t(1_700_000_500),
            removedByBatch: "batch-2"
        )
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(DiaryEntry.self, from: data)
        #expect(back == original)
    }

    @Test("Codable round-trip preserves nil optionals")
    func codableNilOptionals() throws {
        let now = t(1_700_000_000)
        let original = DiaryEntry(
            id: "e2",
            agentName: "bilby",
            entry: "x",
            topic: "y",
            wing: "wing_bilby",
            room: "diary",
            filedAt: now,
            embeddingModelID: "minilm-v6"
        )
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(DiaryEntry.self, from: data)
        #expect(back == original)
        #expect(back.tombstonedAt == nil)
        #expect(back.removedByBatch == nil)
    }

    @Test("Equatable + Hashable contract")
    func equatable() {
        let now = t(1_700_000_000)
        let a = DiaryEntry(id: "x", agentName: "s", entry: "e", topic: "t",
                           wing: "w", room: "r", filedAt: now, embeddingModelID: "m")
        let b = DiaryEntry(id: "x", agentName: "s", entry: "e", topic: "t",
                           wing: "w", room: "r", filedAt: now, embeddingModelID: "m")
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("differing entry text makes entries unequal")
    func notEqualOnEntry() {
        let now = t(1_700_000_000)
        let a = DiaryEntry(id: "x", agentName: "s", entry: "e1", topic: "t",
                           wing: "w", room: "r", filedAt: now, embeddingModelID: "m")
        let b = DiaryEntry(id: "x", agentName: "s", entry: "e2", topic: "t",
                           wing: "w", room: "r", filedAt: now, embeddingModelID: "m")
        #expect(a != b)
    }

    @Test("default id is a fresh UUID")
    func defaultIdIsFreshUUID() {
        let now = t(1_700_000_000)
        let a = DiaryEntry(agentName: "s", entry: "e", topic: "t",
                           wing: "w", room: "r", filedAt: now, embeddingModelID: "m")
        let b = DiaryEntry(agentName: "s", entry: "e", topic: "t",
                           wing: "w", room: "r", filedAt: now, embeddingModelID: "m")
        #expect(a.id != b.id)
        #expect(UUID(uuidString: a.id) != nil)
    }
}
