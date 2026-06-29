import Testing
import Foundation
@testable import SubstrateTypes

@Suite("AsOfCoordinate temporal query parameter")
struct AsOfCoordinateTests {

    @Test func presentEquality() {
        #expect(AsOfCoordinate.present == AsOfCoordinate.present)
    }

    @Test func asOfEquality() {
        let hlc = HLC(physicalTime: 1000, logicalCount: 0, nodeID: 1)
        #expect(AsOfCoordinate.asOf(hlc) == AsOfCoordinate.asOf(hlc))
    }

    @Test func presentNotEqualToAsOf() {
        let hlc = HLC(physicalTime: 0, logicalCount: 0, nodeID: 0)
        #expect(AsOfCoordinate.present != AsOfCoordinate.asOf(hlc))
    }

    @Test func zeroHLCIsNotPresent() {
        // Core invariant: a zero HLC wrapped in .asOf is
        // distinct from .present, preventing the ambiguity bug.
        let zeroHLC = HLC(physicalTime: 0, logicalCount: 0, nodeID: 0)
        #expect(AsOfCoordinate.present != AsOfCoordinate.asOf(zeroHLC))
    }

    @Test func codableRoundTripPresent() throws {
        let original = AsOfCoordinate.present
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AsOfCoordinate.self, from: data)
        #expect(original == decoded)
    }

    @Test func codableRoundTripAsOf() throws {
        let hlc = HLC(physicalTime: 1718000000000, logicalCount: 5, nodeID: 42)
        let original = AsOfCoordinate.asOf(hlc)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AsOfCoordinate.self, from: data)
        #expect(original == decoded)
    }

    @Test func hashableConformance() {
        let hlc = HLC(physicalTime: 500, logicalCount: 1, nodeID: 7)
        let set: Set<AsOfCoordinate> = [.present, .asOf(hlc)]
        #expect(set.count == 2)
    }
}
