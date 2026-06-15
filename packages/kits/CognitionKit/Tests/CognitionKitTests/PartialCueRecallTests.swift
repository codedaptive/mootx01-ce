import Testing
import Foundation
import GeniusLocusKit
import LocusKit
import NeuronKit
import PersistenceKit
import PersistenceKitInMemory
@testable import CognitionKit

/// PartialCueRecall (FeelsLike / AboutThis / FromThen) — associative
/// lens (category 7, SPEC § 4.2). One anchor memory, three different
/// recalls depending which fingerprint block you query: memories that
/// FEEL structurally like it, that are ABOUT the same concept, or that
/// are FROM the same period. The cue is one drawer; the lens is which
/// facet you match on. Read-only, end-to-end over a real estate. Swift
/// peer of run_partial_cue_recall.
@Suite("PartialCueRecallTests")
struct PartialCueRecallTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        let handle = try await kit.open(
            storage: storage,
            owner: OwnerCredentials(ownerIdentifier: "partial-cue-test"))
        return (kit, handle)
    }

    private func capture(
        _ kit: GeniusLocusKit, _ handle: EstateHandle,
        content: String, room: String
    ) async throws -> String {
        let frame = CaptureFrame(
            content: content,
            channel: .typed,
            room: room,
            latticeAnchor: .udc("0"),
            addedBy: "alice",
            embeddingModelID: "test-v1")
        return try await kit.capture(handle, frame).id
    }

    private var unconfirmed: LocusKit.RecallFrame {
        LocusKit.RecallFrame(filterChain: [.userConfirmed])
    }

    // CK-FL-1: the lens runs end-to-end — computes per-drawer
    // fingerprints, excludes the anchor, and ranks the rest by
    // partial-cue similarity. The anchor never appears in its own
    // results, and every other memory does.
    @Test("runs end-to-end and never ranks the anchor against itself")
    func runsAndExcludesAnchor() async throws {
        let (kit, handle) = try await openEstate()
        let anchor = try await capture(
            kit, handle, content: "the spec for the lattice anchor system", room: "study")
        let second = try await capture(
            kit, handle, content: "another note about lattice anchors and codes", room: "study")
        let third = try await capture(
            kit, handle, content: "grocery list eggs milk bread", room: "kitchen")

        let out = try await PartialCueRecall.run(
            kit: kit, handle: handle, frame: unconfirmed,
            anchorID: anchor, mode: .feelsLike, k: 5)

        let ids = out.map(\.id)
        #expect(!ids.contains(anchor), "the anchor is never ranked against itself")
        #expect(ids.contains(second) && ids.contains(third), "every other memory is ranked")
        #expect(out.count == 2)
    }

    // CK-FL-2: an anchor id not in the recalled set is an error — the
    // cue points at nothing.
    @Test("an unknown anchor throws")
    func unknownAnchorThrows() async throws {
        let (kit, handle) = try await openEstate()
        _ = try await capture(kit, handle, content: "only memory", room: "study")

        await #expect(throws: AnchorNotInRecalledSetError(anchorID: "no-such-id")) {
            _ = try await PartialCueRecall.run(
                kit: kit, handle: handle, frame: unconfirmed,
                anchorID: "no-such-id", mode: .aboutThis, k: 5)
        }
    }

    // CK-FL-3: the three cue modes are distinct lenses over one cue —
    // each mode queries a different (match, differ) block pair, and the
    // result is a deterministic function of the estate + mode.
    @Test("each cue mode is deterministic")
    func cueModesAreDeterministic() async throws {
        let (kit, handle) = try await openEstate()
        let anchor = try await capture(
            kit, handle, content: "anchor memory about chemistry", room: "study")
        for i in 0..<3 {
            _ = try await capture(
                kit, handle, content: "note number \(i) about various things", room: "study")
        }

        for mode in [CueMode.feelsLike, .aboutThis, .fromThen] {
            let first = try await PartialCueRecall.run(
                kit: kit, handle: handle, frame: unconfirmed,
                anchorID: anchor, mode: mode, k: 3)
            let second = try await PartialCueRecall.run(
                kit: kit, handle: handle, frame: unconfirmed,
                anchorID: anchor, mode: mode, k: 3)
            #expect(first == second, "mode \(mode) is deterministic")
        }
    }
}
