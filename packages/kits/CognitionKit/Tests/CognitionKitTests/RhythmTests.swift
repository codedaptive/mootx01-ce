import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// RhythmTests — fingerprint bit-activity periodicity recipe (Lens 2,
/// Prediction+Time).
/// Verifies the recipe result equals the lens result on the same shaped
/// input (C-3), and the degenerate paths are guarded (B-8).
@Suite("RhythmTests")
struct RhythmTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "rhythm-test"))
        return (kit, handle)
    }

    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle, content: String
    ) async throws {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: "study",
            latticeAnchor: .udc("0"),
            addedBy: "test",
            embeddingModelID: "test-v1")
        _ = try await kit.capture(handle, frame)
    }

    // CK-RH-1: recipe result equals the lens result on the same shaped input.
    // Reads the bit series through the GLK surface, calls the lens directly,
    // and asserts the recipe produces the same output.
    @Test("recipe result matches direct lens call on same shaped input")
    func recipeResultMatchesDirectLensCall() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()
        for i in 0..<4 {
            _ = try await capture(kit, handle, content: "rhythm-fixture-\(i)")
        }

        // Parameters — bit 0, 64-second buckets, 16 buckets.
        let bit = 0
        let bucketSeconds = 64
        let bucketCount = 16
        let topK = 3

        // Read the bit series directly — same as the recipe's GLK read.
        let buckets = try await kit.glkFingerprintBitSeries(
            in: handle,
            bit: bit,
            bucketSeconds: bucketSeconds,
            bucketCount: bucketCount,
            endingAt: now)

        let expected = NeuronKit.rhythm(
            buckets: buckets,
            bucketDurationSeconds: Double(bucketSeconds),
            topK: topK)

        // Run the recipe.
        let out = try await Rhythm.run(
            kit: kit, handle: handle,
            bit: bit,
            bucketSeconds: bucketSeconds,
            bucketCount: bucketCount,
            endingAt: now,
            topK: topK,
            now: now)

        #expect(out.periods == expected,
                "recipe result must equal the direct lens call on the same shaped input")
        #expect(out.bucketCount == buckets.count)
    }

    // CK-RH-2: empty estate, all-false bit series → empty period list (B-8).
    @Test("all-false bit series is guarded")
    func allFalseBitSeriesIsGuarded() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()
        // No captures → all buckets are false.
        let out = try await Rhythm.run(
            kit: kit, handle: handle,
            bit: 0,
            bucketSeconds: 3600,
            bucketCount: 8,
            endingAt: now,
            topK: 3,
            now: now)

        // All-constant (all false) series yields empty periods.
        #expect(out.periods.isEmpty,
                "all-constant series carries no frequency information → empty result")
    }

    // CK-RH-3: topK = 0 → empty period list (B-8).
    @Test("topK zero is guarded")
    func topKZeroIsGuarded() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()
        _ = try await capture(kit, handle, content: "data")
        let out = try await Rhythm.run(
            kit: kit, handle: handle,
            bit: 0,
            bucketSeconds: 60,
            bucketCount: 8,
            endingAt: now,
            topK: 0,
            now: now)

        #expect(out.periods.isEmpty)
    }
}
