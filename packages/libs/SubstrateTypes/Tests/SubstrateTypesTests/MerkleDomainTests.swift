import Testing
@testable import SubstrateTypes

@Suite("MerkleDomain domain-separation tags")
struct MerkleDomainTests {

    @Test func frozenValues() {
        #expect(MerkleDomain.leaf == 0x00)
        #expect(MerkleDomain.interior == 0x01)
        #expect(MerkleDomain.tombstone == 0x02)
        #expect(MerkleDomain.commitment == 0x03)
    }

    @Test func allTagsAreDistinct() {
        let tags: [UInt8] = [
            MerkleDomain.leaf,
            MerkleDomain.interior,
            MerkleDomain.tombstone,
            MerkleDomain.commitment,
        ]
        let unique = Set(tags)
        #expect(unique.count == tags.count)
    }
}
