import Testing
import EngramLib
@testable import VectorKit

/// Tests for `VectorMatch` — the value returned by
/// `VectorStore.findNearest`. The store-level suites exercise it only
/// indirectly (reading `.drawerID` / `.distance` / `.modelID` off
/// results). This suite covers the type's own contract directly:
/// member-wise initialization, `Equatable`, and the `Comparable`
/// ordering, which is defined on `distance` ascending (smaller =
/// closer) with no tiebreak guaranteed at this layer.
@Suite("VectorMatch")
struct VectorMatchTests {

    /// The memberwise initializer retains every field verbatim.
    @Test func testInitRetainsAllFields() {
        let match = VectorMatch(drawerID: "drawer-A", distance: 7, modelID: "minilm-v6")
        #expect(match.drawerID == "drawer-A")
        #expect(match.distance == 7)
        #expect(match.modelID == "minilm-v6")
    }

    /// Two matches are equal exactly when all three fields agree.
    @Test func testEqualityRequiresAllFields() {
        let base = VectorMatch(drawerID: "d", distance: 3, modelID: "m")
        #expect(base == VectorMatch(drawerID: "d", distance: 3, modelID: "m"))
        #expect(base != VectorMatch(drawerID: "other", distance: 3, modelID: "m"))
        #expect(base != VectorMatch(drawerID: "d", distance: 4, modelID: "m"))
        #expect(base != VectorMatch(drawerID: "d", distance: 3, modelID: "other"))
    }

    /// `Comparable` orders by `distance` ascending — smaller distance
    /// is "less than" (closer to the front of a near→far list).
    @Test func testComparableOrdersByDistanceAscending() {
        let near = VectorMatch(drawerID: "near", distance: 1, modelID: "m")
        let far  = VectorMatch(drawerID: "far",  distance: 9, modelID: "m")
        #expect(near < far)
        #expect(!(far < near))
    }

    /// Sorting a shuffled set of matches yields distance-ascending
    /// order — the property `VectorStore.findNearest` relies on when
    /// it returns a sorted result list.
    @Test func testSortingProducesDistanceAscendingOrder() {
        let matches = [
            VectorMatch(drawerID: "c", distance: 4, modelID: "m"),
            VectorMatch(drawerID: "a", distance: 1, modelID: "m"),
            VectorMatch(drawerID: "d", distance: 9, modelID: "m"),
            VectorMatch(drawerID: "b", distance: 2, modelID: "m"),
        ]
        let sorted = matches.sorted()
        #expect(sorted.map(\.distance) == [1, 2, 4, 9])
        #expect(sorted.map(\.drawerID) == ["a", "b", "c", "d"])
    }

    /// Equal distances do not order either way — `<` is false in both
    /// directions, matching the documented "no tiebreak at this layer"
    /// contract.
    @Test func testEqualDistancesAreNotOrderedEitherWay() {
        let lhs = VectorMatch(drawerID: "x", distance: 5, modelID: "m")
        let rhs = VectorMatch(drawerID: "y", distance: 5, modelID: "m")
        #expect(!(lhs < rhs))
        #expect(!(rhs < lhs))
    }
}
