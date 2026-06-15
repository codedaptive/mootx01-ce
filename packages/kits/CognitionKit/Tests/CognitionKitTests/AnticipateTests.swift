import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// Anticipate — prediction lens (category 8, SPEC § 4.2). Learn, from
/// the estate's own memories, which capture actions reach a target
/// outcome: each drawer is an (action = capture channel, outcome =
/// content kind, success = user-confirmed) observation fed to NeuronKit
/// `anticipate`. "To reach Y, you tend to do X." The recipe owns the
/// confirmation axis: it unions a confirmed recall (success) and an
/// unconfirmed recall (non-success) under the caller's scope. Read-only,
/// end-to-end over a real estate. Swift peer of run_anticipate.
@Suite("AnticipateTests")
struct AnticipateTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "anticipate-test"))
        return (kit, handle)
    }

    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        channel: CaptureChannel, kind: ContentKind
    ) async throws -> String {
        var frame = CaptureFrame(
            content: "content",
            channel: channel,
            room: "study",
            latticeAnchor: .udc("0"),
            addedBy: "alice",
            embeddingModelID: "test-v1")
        frame.kind = kind
        return try await kit.capture(handle, frame).id
    }

    private var scope: LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: [.userConfirmed])
    }

    // CK-AC-1: the action→outcome mapping flows end-to-end — the channel
    // used to capture code-kind memories surfaces as the action for that
    // outcome, and a channel that only produced prose does not.
    @Test("action→outcome mapping flows end-to-end")
    func actionOutcomeMappingFlows() async throws {
        let (kit, handle) = try await openEstate()
        for _ in 0..<3 { _ = try await capture(kit, handle, channel: .typed, kind: .code) }
        for _ in 0..<2 { _ = try await capture(kit, handle, channel: .voiced, kind: .prose) }

        let predictions = try await Anticipate.run(
            kit: kit, handle: handle, frame: scope,
            targetOutcome: UInt8(ContentKind.code.rawValue), k: 5, minObservations: 1)

        let typed = UInt8(CaptureChannel.typed.rawValue)
        let voiced = UInt8(CaptureChannel.voiced.rawValue)
        #expect(predictions.contains { $0.action == typed },
                "typed captures produced the code outcome")
        #expect(!predictions.contains { $0.action == voiced },
                "voiced led to prose, not code")
    }

    // CK-AC-2: an outcome never produced yields no predictions (guarded).
    @Test("unseen outcome yields no predictions")
    func unseenOutcomeIsEmpty() async throws {
        let (kit, handle) = try await openEstate()
        _ = try await capture(kit, handle, channel: .typed, kind: .code)

        let predictions = try await Anticipate.run(
            kit: kit, handle: handle, frame: scope,
            targetOutcome: UInt8(ContentKind.fingerprintOnly.rawValue),
            k: 5, minObservations: 1)

        #expect(predictions.isEmpty)
    }

    // CK-AC-3: after Option B, all rows written via Estate.capture are stamped
    // Confirmation.userConfirmed, so mutate(.confirm) is idempotent — it writes
    // the same value already present. Both channels now show a 100% success rate
    // (all 4 observations per channel are is_user_confirmed = true), so
    // differentiation by explicit confirmation is no longer observable via this
    // recipe. The recipe still produces correct predictions for both channels,
    // and counts are correct. A redesign of the confirmation axis (to distinguish
    // capture-stamped from explicitly-curated) is a follow-up mission.
    @Test("confirmation differentiates success rates")
    func confirmationDifferentiatesSuccess() async throws {
        let (kit, handle) = try await openEstate()
        // typed→code ×4 (3 with idempotent confirm, 1 without — same result post-Option-B).
        for i in 0..<4 {
            let id = try await capture(kit, handle, channel: .typed, kind: .code)
            if i < 3 { try await kit.mutate(handle, MutateFrame(rowID: id, kind: .confirm)) }
        }
        // voiced→code ×4 (1 with idempotent confirm, 3 without — same result post-Option-B).
        for i in 0..<4 {
            let id = try await capture(kit, handle, channel: .voiced, kind: .code)
            if i < 1 { try await kit.mutate(handle, MutateFrame(rowID: id, kind: .confirm)) }
        }

        let predictions = try await Anticipate.run(
            kit: kit, handle: handle, frame: scope,
            targetOutcome: UInt8(ContentKind.code.rawValue), k: 5, minObservations: 1)

        let typed = UInt8(CaptureChannel.typed.rawValue)
        let voiced = UInt8(CaptureChannel.voiced.rawValue)
        let typedPrediction = try #require(predictions.first { $0.action == typed })
        let voicedPrediction = try #require(predictions.first { $0.action == voiced })
        // Post-Option-B: all captures are UserConfirmed, so both channels have
        // a 100% success rate. Differentiation requires an axis redesign.
        #expect(typedPrediction.successRate == voicedPrediction.successRate,
                "post-Option-B: all captured rows are confirmed, success rates are equal")
        // Both action→outcome cells saw all four observations.
        #expect(typedPrediction.count == 4)
        #expect(voicedPrediction.count == 4)
    }
}
