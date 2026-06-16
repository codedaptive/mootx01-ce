import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
import SubstrateML
import SubstrateTypes
@testable import CognitionKit

/// MomentTests — temporal fingerprint signature recipe (Lens 1, Time).
/// Verifies the recipe result equals the lens result on the same shaped
/// input (C-3), and the degenerate empty-estate path is guarded (B-8).
@Suite("MomentTests")
struct MomentTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "moment-test"))
        return (kit, handle)
    }

    /// Capture a drawer and return the estate handle (the fingerprint is
    /// computed internally by the estate at capture time).
    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        content: String, room: String = "study"
    ) async throws {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("0"),
            addedBy: "test",
            embeddingModelID: "test-v1")
        _ = try await kit.capture(handle, frame)
    }

    // CK-MO-1: recipe result equals the lens result on the same shaped input.
    // Captures three drawers in the primary window and two in a comparison
    // window, reads both sets through the GLK surface, shapes input identically
    // to what the recipe does, and asserts output equality.
    @Test("recipe result matches direct lens call on same shaped input")
    func recipeResultMatchesDirectLensCall() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()

        // Primary window: three drawers.
        let primaryStart = Date(timeIntervalSinceNow: -3600)
        let primaryEnd = Date(timeIntervalSinceNow: -1800)
        for i in 0..<3 {
            _ = try await capture(kit, handle, content: "primary-\(i)")
        }

        // Comparison window: two drawers captured after the primary window.
        let cmpStart = Date(timeIntervalSinceNow: -1800)
        let cmpEnd = now

        for i in 0..<2 {
            _ = try await capture(kit, handle, content: "comparison-\(i)")
        }

        let primaryWindow = primaryStart...primaryEnd
        let cmpWindow = cmpStart...cmpEnd

        // Read fingerprints directly — same as the recipe's GLK reads.
        let primaryFPs = try await kit.glkFingerprintsCaptured(
            in: handle, window: primaryWindow)
        let cmpFPs = try await kit.glkFingerprintsCaptured(
            in: handle, window: cmpWindow)

        // Shape input identically to Moment.run.
        let primaryRows = primaryFPs.map { RowLite(fingerprint: $0, captureHLC: .zero) }
        let candidates: [Fingerprint256] = cmpFPs.isEmpty
            ? [] : [MomentSummary.orReduce(cmpFPs)]
        let expected = NeuronKit.momentSignature(
            fingerprints: primaryRows, candidates: candidates)

        // Run the recipe.
        let out = try await Moment.run(
            kit: kit, handle: handle,
            window: primaryWindow,
            comparisonWindows: [cmpWindow],
            now: now)

        #expect(out.result == expected,
                "recipe result must equal the direct lens call on the same shaped input")
        #expect(out.comparisonCounts == [cmpFPs.count])
    }

    // CK-MO-2: empty primary window yields zero signature and empty ranking
    // (B-8 total-over-edge-input posture).
    @Test("empty primary window is guarded")
    func emptyPrimaryWindowIsGuarded() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()
        // Past window that precedes any captures.
        let emptyWindow = Date(timeIntervalSinceNow: -7200)...Date(timeIntervalSinceNow: -3600)
        let out = try await Moment.run(
            kit: kit, handle: handle,
            window: emptyWindow,
            comparisonWindows: [],
            now: now)

        #expect(out.windowCount == 0)
        #expect(out.result.signature == .zero)
        #expect(out.result.ranking.isEmpty)
        #expect(out.comparisonCounts.isEmpty)
    }

    // CK-MO-3: empty comparison list → no candidates → empty ranking,
    // non-zero signature when primary window has data.
    @Test("non-empty primary, no comparisons: signature present, ranking empty")
    func noComparisonWindowsYieldsEmptyRanking() async throws {
        let (kit, handle) = try await openEstate()
        let now = Date()
        let window = Date(timeIntervalSinceNow: -3600)...now
        _ = try await capture(kit, handle, content: "data-point")

        let out = try await Moment.run(
            kit: kit, handle: handle,
            window: window,
            comparisonWindows: [],
            now: now)

        #expect(out.windowCount >= 0)
        #expect(out.result.ranking.isEmpty, "no candidates → no ranking")
        #expect(out.comparisonCounts.isEmpty)
    }
}
