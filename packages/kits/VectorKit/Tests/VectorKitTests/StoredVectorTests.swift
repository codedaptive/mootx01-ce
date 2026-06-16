import Testing
import EngramLib
import Foundation
@testable import VectorKit

/// Tests for `StoredVector` — one row of the `vectors` table. The
/// `VectorStore` suite exercises it indirectly through
/// `vectors(forItemID:)` round-trips; this suite covers the value
/// type's own contract directly: memberwise initialization retains
/// every field, and `Equatable` is field-wise across all members
/// (`id`, `itemID`, `vectorIndex`, `modelID`, `modelVersion`, `engram`, `filedAt`).
@Suite("StoredVector")
struct StoredVectorTests {

    private func sample(id: String = "row-1",
                        itemID: String = "drawer-A",
                        vectorIndex: UInt32 = 0,
                        modelID: String = "minilm-v6",
                        modelVersion: String = "1.0.0",
                        engram: Engram = Engram(blocks: 0xAA, 0xBB, 0xCC, 0xDD),
                        filedAt: Date = Date(timeIntervalSince1970: 1_700_000_000))
    -> StoredVector {
        StoredVector(id: id, itemID: itemID, vectorIndex: vectorIndex,
                     modelID: modelID, modelVersion: modelVersion,
                     engram: engram, filedAt: filedAt)
    }

    /// The memberwise initializer retains every field verbatim.
    @Test func testInitRetainsAllFields() {
        let engram = Engram(blocks: 0x1234, 0x5678, 0x9ABC, 0xDEF0)
        let when = Date(timeIntervalSince1970: 1_700_000_123)
        let row = StoredVector(id: "uuid-xyz",
                               itemID: "drawer-V",
                               vectorIndex: 0,
                               modelID: "minilm-v6",
                               modelVersion: "1.0.0-alpha.3",
                               engram: engram,
                               filedAt: when)
        #expect(row.id == "uuid-xyz")
        #expect(row.itemID == "drawer-V")
        #expect(row.vectorIndex == 0)
        #expect(row.modelID == "minilm-v6")
        #expect(row.modelVersion == "1.0.0-alpha.3")
        #expect(row.engram == engram)
        #expect(row.filedAt == when)
    }

    /// Two rows with identical fields compare equal.
    @Test func testEqualWhenAllFieldsMatch() {
        #expect(sample() == sample())
    }

    /// Equality is field-wise: changing any single field breaks it.
    @Test func testInequalityWhenAnyFieldDiffers() {
        let base = sample()
        #expect(base != sample(id: "row-2"))
        #expect(base != sample(itemID: "drawer-B"))
        #expect(base != sample(vectorIndex: 1))
        #expect(base != sample(modelID: "gemma"))
        #expect(base != sample(modelVersion: "2.0.0"))
        #expect(base != sample(engram: Engram(blocks: 1, 2, 3, 4)))
        #expect(base != sample(filedAt: Date(timeIntervalSince1970: 1_700_000_999)))
    }
}
