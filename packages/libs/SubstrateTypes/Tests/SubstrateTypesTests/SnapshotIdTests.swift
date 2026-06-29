import Testing
import Foundation
@testable import SubstrateTypes

@Suite("SnapshotId typed UUID wrapper")
struct SnapshotIdTests {

    @Test func initFromUUID() {
        let uuid = UUID()
        let id = SnapshotId(uuid)
        #expect(id.uuid == uuid)
    }

    @Test func initFromString() {
        let str = "550E8400-E29B-41D4-A716-446655440000"
        let id = SnapshotId(uuidString: str)
        #expect(id != nil)
        #expect(id?.uuidString == str)
    }

    @Test func invalidStringReturnsNil() {
        let id = SnapshotId(uuidString: "not-a-uuid")
        #expect(id == nil)
    }

    @Test func codableRoundTrip() throws {
        let original = SnapshotId(UUID())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SnapshotId.self, from: data)
        #expect(original == decoded)
    }

    @Test func equality() {
        let uuid = UUID()
        let a = SnapshotId(uuid)
        let b = SnapshotId(uuid)
        let c = SnapshotId(UUID())
        #expect(a == b)
        #expect(a != c)
    }

    @Test func hashableConformance() {
        let uuid = UUID()
        let a = SnapshotId(uuid)
        let b = SnapshotId(uuid)
        let set: Set<SnapshotId> = [a, b]
        #expect(set.count == 1)
    }

    @Test func descriptionIsUUIDString() {
        let uuid = UUID()
        let id = SnapshotId(uuid)
        #expect(id.description == uuid.uuidString)
    }
}
