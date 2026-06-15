import Testing
import EngramLib
@testable import VectorKit

/// Tests for `VectorMatch` — the value returned by
/// `VectorStore.findNearest`. The store-level suites exercise it only
/// indirectly (reading `.itemID` / `.distance` / `.modelID` off
/// results). This suite covers the type's own contract directly:
/// member-wise initialization, `Equatable`, and the `Comparable`
/// ordering, which is defined on `distance` ascending (smaller =
/// closer) with `itemID` ascending as the tiebreak.
@Suite("VectorMatch")
struct VectorMatchTests {

    /// The memberwise initializer retains every field verbatim.
    @Test func testInitRetainsAllFields() {
        let match = VectorMatch(itemID: "drawer-A", distance: 7, modelID: "minilm-v6")
        #expect(match.itemID == "drawer-A")
        #expect(match.distance == 7)
        #expect(match.modelID == "minilm-v6")
    }

    /// Two matches are equal exactly when all three fields agree.
    @Test func testEqualityRequiresAllFields() {
        let base = VectorMatch(itemID: "d", distance: 3, modelID: "m")
        #expect(base == VectorMatch(itemID: "d", distance: 3, modelID: "m"))
        #expect(base != VectorMatch(itemID: "other", distance: 3, modelID: "m"))
        #expect(base != VectorMatch(itemID: "d", distance: 4, modelID: "m"))
        #expect(base != VectorMatch(itemID: "d", distance: 3, modelID: "other"))
    }

    /// `Comparable` orders by `distance` ascending — smaller distance
    /// is "less than" (closer to the front of a near→far list).
    @Test func testComparableOrdersByDistanceAscending() {
        let near = VectorMatch(itemID: "near", distance: 1, modelID: "m")
        let far  = VectorMatch(itemID: "far",  distance: 9, modelID: "m")
        #expect(near < far)
        #expect(!(far < near))
    }

    /// Sorting a shuffled set of matches yields distance-ascending
    /// order — the property `VectorStore.findNearest` relies on when
    /// it returns a sorted result list.
    @Test func testSortingProducesDistanceAscendingOrder() {
        let matches = [
            VectorMatch(itemID: "c", distance: 4, modelID: "m"),
            VectorMatch(itemID: "a", distance: 1, modelID: "m"),
            VectorMatch(itemID: "d", distance: 9, modelID: "m"),
            VectorMatch(itemID: "b", distance: 2, modelID: "m"),
        ]
        let sorted = matches.sorted()
        #expect(sorted.map(\.distance) == [1, 2, 4, 9])
        #expect(sorted.map(\.itemID) == ["a", "b", "c", "d"])
    }

    /// Equal distances: tiebreak is by `itemID` ascending (universal
    /// tie-break rule, retrieval algorithms reference §0.3). "x" < "y"
    /// lexicographically, so the match with itemID "x" sorts first.
    @Test func testEqualDistancesAreTiebrokenByItemIDAscending() {
        let lhs = VectorMatch(itemID: "x", distance: 5, modelID: "m")
        let rhs = VectorMatch(itemID: "y", distance: 5, modelID: "m")
        #expect(lhs < rhs)
        #expect(!(rhs < lhs))
    }
}
