import Foundation
import Testing
import SubstrateTypes
@testable import NeuronKit

// Partial-cue recall lens (SPEC § 7.6). Tests assert the behavioral
// claims the spec makes — not the implementation. The 256-bit drawer
// fingerprint is four independent 64-bit similarity blocks; querying a
// block subset gives "memories that FEEL structurally like this" vs
// "memories ABOUT this concept" — different recalls from one cue. The
// match/differ split scores "similar in X, different in Y." Pure,
// deterministic (B-5, I-18).

@Suite("Partial-cue recall lens (SPEC § 7.6)")
struct PartialRecallTests {

    /// A fingerprint where each 64-bit block is all-ones or all-zeros.
    private func fingerprint(_ blocks: [Bool]) -> Fingerprint256 {
        var bits = [Bool](repeating: false, count: 256)
        for (block, on) in blocks.enumerated() where on {
            for i in (block * 64)..<((block + 1) * 64) { bits[i] = true }
        }
        return .fromBits(bits)
    }

    private let firstID = UUID()
    private let secondID = UUID()

    // PR-1: "feels structurally like the anchor but is conceptually
    // different" — match structure, differ concept. A candidate sharing
    // the anchor's structure block but with a different concept block
    // outscores one identical everywhere (no conceptual difference to
    // reward).
    @Test("structural match with conceptual difference ranks first")
    func structuralMatchConceptualDifferRanksFirst() {
        let anchor = fingerprint([true, false, false, false])
        let rows: [(rowID: UUID, fingerprint: Fingerprint256)] = [
            (firstID, fingerprint([true, true, false, false])),   // match + differ → high
            (secondID, fingerprint([true, false, false, false])), // identical → low
        ]

        let out = NeuronKit.partialRecall(
            anchor: anchor, rows: rows,
            matchBlocks: [.structure], differBlocks: [.concept], k: 2)

        #expect(out[0].rowID == firstID,
                "structurally-alike-but-conceptually-different ranks first")
        #expect(out[0].score > out[1].score)
    }

    // PR-2: switching the lens to "ABOUT this concept" surfaces a
    // different memory — the same cue, a different recall.
    @Test("block choice changes the recall")
    func blockChoiceChangesTheRecall() {
        let anchor = fingerprint([true, true, false, false])
        let rows: [(rowID: UUID, fingerprint: Fingerprint256)] = [
            (firstID, fingerprint([false, true, false, false])),  // concept match
            (secondID, fingerprint([true, false, false, false])), // structure match
        ]

        let about = NeuronKit.partialRecall(
            anchor: anchor, rows: rows,
            matchBlocks: [.concept], differBlocks: [.structure], k: 1)
        #expect(about[0].rowID == firstID, "ABOUT-this-concept surfaces the concept match")

        let feels = NeuronKit.partialRecall(
            anchor: anchor, rows: rows,
            matchBlocks: [.structure], differBlocks: [.concept], k: 1)
        #expect(feels[0].rowID == secondID, "FEELS-like-this surfaces the structure match")
    }
}
