import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// ComplexityTests — Shannon entropy recipe (Lens 4, Topics).
/// Verifies the recipe result equals the lens result on the same shaped
/// input (C-3), and the degenerate paths are guarded (B-8).
@Suite("ComplexityTests")
struct ComplexityTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "complexity-test"))
        return (kit, handle)
    }

    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        content: String, room: String = "study", modelID: String = "test-v1"
    ) async throws {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("0"),
            addedBy: "test",
            embeddingModelID: modelID)
        _ = try await kit.capture(handle, frame)
    }

    private var unconfirmed: LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: [.unconfirmed])
    }

    // CK-CM-1: recipe result equals the lens result on the same shaped input.
    // Recalls via frame, derives the distribution manually, calls the lens
    // directly, and asserts output equality.
    @Test("recipe result matches direct lens call on same shaped input")
    func recipeResultMatchesDirectLensCall() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()

        // Three drawers: two in "research", one in "reading".
        for _ in 0..<2 {
            _ = try await capture(kit, handle, content: "r\(UUID())", room: "research")
        }
        _ = try await capture(kit, handle, content: "reading-note", room: "reading")

        // Manually replicate what Complexity.run does for fieldA = "room".
        let drawers = try await kit.recall(handle, unconfirmed)
        var freq: [String: Int] = [:]
        for d in drawers { freq[d.room, default: 0] += 1 }
        let keys = freq.keys.sorted()
        let countsA = keys.map { Float32(freq[$0]!) }
        let expected = NeuronKit.complexity(countsA: countsA, countsB: nil, joint: nil)

        // Run the recipe.
        let out = try await Complexity.run(
            kit: kit, handle: handle,
            frame: unconfirmed,
            fieldA: "room",
            now: now)

        #expect(out.result == expected,
                "recipe result must equal the direct lens call on the same shaped input")
        #expect(out.totalCount == drawers.count)
    }

    // CK-CM-2: mutual information is computed when both fieldA and fieldB are
    // supplied. Uses "room" × "embeddingModelID" so both fields are controllable
    // at capture time.
    @Test("mutual information is present when both fields supplied")
    func mutualInformationIsPresentWithTwoFields() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()

        // Four drawers spanning two rooms × two embedding model IDs.
        _ = try await capture(kit, handle, content: "a", room: "lab",    modelID: "model-a")
        _ = try await capture(kit, handle, content: "b", room: "lab",    modelID: "model-b")
        _ = try await capture(kit, handle, content: "c", room: "office", modelID: "model-a")
        _ = try await capture(kit, handle, content: "d", room: "office", modelID: "model-b")

        let out = try await Complexity.run(
            kit: kit, handle: handle,
            frame: unconfirmed,
            fieldA: "room",
            fieldB: "embeddingModelID",
            now: now)

        #expect(out.result.entropyB != nil,
                "entropy of fieldB must be present")
        #expect(out.result.mutualInformation != nil,
                "mutual information must be present when joint distribution is supplied")
    }

    // CK-CM-3: empty estate yields zero entropy (B-8).
    @Test("empty estate is guarded")
    func emptyEstateIsGuarded() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()

        let out = try await Complexity.run(
            kit: kit, handle: handle,
            frame: unconfirmed,
            fieldA: "room",
            now: now)

        #expect(out.result.entropyA == 0.0)
        #expect(out.totalCount == 0)
    }
}
