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
        LocusKit.RecallFrame(filterChain: [.unconfirmed])
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

    // CK-AC-3: success DIFFERENTIATION end-to-end via the live confirm
    // verb. Two channels both reach the code outcome, but typed captures
    // get confirmed (succeed) far more often than voiced ones — so for
    // "reach code," typed ranks above voiced with a higher learned
    // success rate.
    @Test("confirmation differentiates success rates")
    func confirmationDifferentiatesSuccess() async throws {
        let (kit, handle) = try await openEstate()
        // typed→code ×4, confirm 3 (3/4 succeed).
        for i in 0..<4 {
            let id = try await capture(kit, handle, channel: .typed, kind: .code)
            if i < 3 { try await kit.mutate(handle, MutateFrame(rowID: id, kind: .confirm)) }
        }
        // voiced→code ×4, confirm 1 (1/4 succeed).
        for i in 0..<4 {
            let id = try await capture(kit, handle, channel: .voiced, kind: .code)
            if i < 1 { try await kit.mutate(handle, MutateFrame(rowID: id, kind: .confirm)) }
        }

        let predictions = try await Anticipate.run(
            kit: kit, handle: handle, frame: scope,
            targetOutcome: UInt8(ContentKind.code.rawValue), k: 5, minObservations: 1)

        let typed = UInt8(CaptureChannel.typed.rawValue)
        let voiced = UInt8(CaptureChannel.voiced.rawValue)
        #expect(predictions.first?.action == typed,
                "the more-confirmed action leads for the code outcome")
        let typedPrediction = try #require(predictions.first { $0.action == typed })
        let voicedPrediction = try #require(predictions.first { $0.action == voiced })
        #expect(typedPrediction.successRate > voicedPrediction.successRate,
                "typed's learned success rate exceeds voiced's")
        // Both action→outcome cells saw all four observations (confirmed
        // + unconfirmed unioned), so the rate is differentiation, not
        // coverage.
        #expect(typedPrediction.count == 4)
        #expect(voicedPrediction.count == 4)
    }

    // Security invariant (Codex 3269c59 verification): the recipe deliberately
    // owns the confirmation axis (dual confirmed/unconfirmed recall computes a
    // differentiated success rate — unconfirmed rows are the non-success
    // signal, not a leak). But `withoutConfirmationLevel` must strip ONLY the
    // confirmation-level filters — the caller's real access gate,
    // `.sensitivityAtMost`, and every other scoping filter must survive so the
    // two recalls stay bounded by the caller's clearance. This test locks it.
    @Test("withoutConfirmationLevel preserves sensitivity and other filters")
    func withoutConfirmationLevelPreservesSensitivity() {
        let chain: [Filter] = [
            .userConfirmed,
            .sensitivityAtMost(.elevated),
            .unconfirmed,
            .inWing("study"),
            .automatedConfirmedOnly,
        ]
        let base = Anticipate.withoutConfirmationLevel(chain)
        // Confirmation-level filters removed.
        #expect(!base.contains {
            switch $0 {
            case .userConfirmed, .automatedConfirmedOnly, .unconfirmed: return true
            default: return false
            }
        })
        // The access gate and other scoping filters survive.
        #expect(base.contains {
            if case .sensitivityAtMost(.elevated) = $0 { return true }
            return false
        }, "the caller's sensitivity ceiling must NOT be stripped alongside confirmation")
        #expect(base.contains {
            if case .inWing(let w) = $0 { return w == "study" }
            return false
        }, "wing scoping must survive the confirmation strip")
    }
}
