import Testing
import Foundation
@testable import mcp_benchmarker

// GauntletScorerTests — the pure scorer against synthetic fixture result-sets
// (Phase 2.2). No live backend: each test hands the scorer a hand-built returned
// list and asserts found@k, rank, completeness (byte-compare), and contamination.
//
// Completeness is derived from the RETURNED items themselves: the returned item
// matched to the needle is byte-compared against the needle's verbatim content.
// There is no separate full-record fetch parameter — what the query returned IS
// the completeness source, identically for both backends.

@Suite("Gauntlet scorer")
struct GauntletScorerTests {

    private let scorer = GauntletScorer(kValues: [1, 5, 10])

    /// A plain (non-split) needle with two planted distractors.
    private func plainNeedle() -> (needle: Needle, distractors: [String: String]) {
        let needle = Needle(
            id: "n0001",
            query: "What is the charter year of the Velrath Combine?",
            content: "the Velrath Combine was chartered in the year 1820.",
            tier: .lexical, location: "Charter/velrath-combine",
            distractorIDs: ["n0001-t1-0", "n0001-t1-1"],
            splitPartnerID: nil, expectedRank: 1)
        let distractors = [
            "n0001-t1-0": "the Velrath Combine holds a reserve valued at 40 million marks.",
            "n0001-t1-1": "the Velrath Combine operates a fleet numbering exactly 88 vessels.",
        ]
        return (needle, distractors)
    }

    private func item(_ content: String, id: String? = nil) -> ScoredItem {
        ScoredItem(id: id, content: content)
    }

    @Test("needle at rank 1: found@1/@5/@10 all true, rank 1, MRR 1.0")
    func needleAtRankOne() {
        let (needle, distractors) = plainNeedle()
        let returned = [item(needle.content), item(distractors["n0001-t1-0"]!)]
        let s = scorer.score(needle: needle, returned: returned,
                             distractorContents: distractors,
                             splitPartnerContent: nil,
                             latencySeconds: 0.01, bytesReturned: 100)
        #expect(s.foundAtK[1] == true)
        #expect(s.foundAtK[5] == true)
        #expect(s.foundAtK[10] == true)
        #expect(s.rank == 1)
        #expect(s.reciprocalRank == 1.0)
    }

    @Test("needle at rank 6: found@1 false, found@10 true, rank 6")
    func needleAtRankSix() {
        let (needle, distractors) = plainNeedle()
        // Five filler items, then the needle at position 6.
        var returned = (0..<5).map { item("filler record number \($0) unrelated content") }
        returned.append(item(needle.content))
        let s = scorer.score(needle: needle, returned: returned,
                             distractorContents: distractors,
                             splitPartnerContent: nil,
                             latencySeconds: 0.01, bytesReturned: 100)
        #expect(s.foundAtK[1] == false)
        #expect(s.foundAtK[5] == false)
        #expect(s.foundAtK[10] == true)
        #expect(s.rank == 6)
    }

    @Test("needle absent: not found at any k, rank nil, MRR 0")
    func needleAbsent() {
        let (needle, distractors) = plainNeedle()
        let returned = [item("something else entirely"), item("yet another record")]
        let s = scorer.score(needle: needle, returned: returned,
                             distractorContents: distractors,
                             splitPartnerContent: nil,
                             latencySeconds: 0.01, bytesReturned: 100)
        #expect(s.foundAtK[1] == false)
        #expect(s.foundAtK[10] == false)
        #expect(s.rank == nil)
        #expect(s.reciprocalRank == 0.0)
        // Not found → the answer was never returned → completeness 0.
        #expect(s.completeness == 0.0)
    }

    @Test("completeness byte-compare: exact fetched content → 1.0")
    func completenessExact() {
        let (needle, distractors) = plainNeedle()
        let returned = [item(needle.content)]
        let s = scorer.score(needle: needle, returned: returned,
                             distractorContents: distractors,
                             splitPartnerContent: nil,
                             latencySeconds: 0.01, bytesReturned: 100)
        #expect(s.completeness == 1.0)
    }

    @Test("completeness byte-compare: returned preview truncated past the match prefix → found but 0.0")
    func completenessMismatch() {
        // A long needle whose normalized 64-char match prefix is shared by a
        // truncated preview. The backend RETURNS the truncated preview: it
        // normalize-matches (so found@k is true) but is byte-different from the
        // verbatim record, so completeness is 0. This is exactly the
        // "found but only got a preview, not the whole answer" case.
        let needle = Needle(
            id: "n0002",
            query: "What does the Velrath charter clause specify in full?",
            content: "the Velrath Combine was chartered in the year 1820 under the seal of the regional admiralty board, clause seven.",
            tier: .lexical, location: "Charter/velrath-combine",
            distractorIDs: [], splitPartnerID: nil, expectedRank: 1)
        // Truncated preview: identical normalized 64-char prefix, byte-different tail.
        let preview = "the Velrath Combine was chartered in the year 1820 under the seal…"
        #expect(GauntletScorer.normalize(preview) == GauntletScorer.normalize(needle.content),
                "preview must normalize-match so the needle is FOUND")
        let returned = [item(preview)]
        let s = scorer.score(needle: needle, returned: returned,
                             distractorContents: [:],
                             splitPartnerContent: nil,
                             latencySeconds: 0.01, bytesReturned: 100)
        #expect(s.foundAtK[1] == true)      // found (normalized prefix matches)
        #expect(s.completeness == 0.0)      // but the returned content ≠ verbatim
    }

    @Test("completeness: needle not returned → 0.0")
    func completenessNeedleAbsent() {
        let (needle, distractors) = plainNeedle()
        // The needle is not among the returned items → completeness 0 (the query
        // did not return the answer at all).
        let returned = [item("an unrelated record"), item("another unrelated record")]
        let s = scorer.score(needle: needle, returned: returned,
                             distractorContents: distractors,
                             splitPartnerContent: nil,
                             latencySeconds: 0.01, bytesReturned: 100)
        #expect(s.foundAtK[1] == false)
        #expect(s.completeness == 0.0)
    }

    @Test("contamination counts distractors present in top-k")
    func contaminationCount() {
        let (needle, distractors) = plainNeedle()
        // Both distractors present, plus the needle.
        let returned = [
            item(needle.content),
            item(distractors["n0001-t1-0"]!),
            item(distractors["n0001-t1-1"]!),
        ]
        let s = scorer.score(needle: needle, returned: returned,
                             distractorContents: distractors,
                             splitPartnerContent: nil,
                             latencySeconds: 0.01, bytesReturned: 100)
        #expect(s.contamination == 2)
    }

    @Test("contamination: zero when no distractors returned")
    func contaminationZero() {
        let (needle, distractors) = plainNeedle()
        let returned = [item(needle.content), item("an unrelated clean record")]
        let s = scorer.score(needle: needle, returned: returned,
                             distractorContents: distractors,
                             splitPartnerContent: nil,
                             latencySeconds: 0.01, bytesReturned: 100)
        #expect(s.contamination == 0)
    }

    @Test("contamination only counts within top-k, not beyond")
    func contaminationRespectsK() {
        let (needle, distractors) = plainNeedle()
        // Needle at 1, then 9 filler, then a distractor at position 11 (beyond k=10).
        var returned = [item(needle.content)]
        for i in 0..<9 { returned.append(item("filler \(i) text")) }
        returned.append(item(distractors["n0001-t1-0"]!))   // position 11
        let s = scorer.score(needle: needle, returned: returned,
                             distractorContents: distractors,
                             splitPartnerContent: nil,
                             latencySeconds: 0.01, bytesReturned: 100)
        #expect(s.contamination == 0, "distractor beyond k=10 must not count")
    }

    // MARK: - split (T4) scoring

    private func splitNeedle() -> (needle: Needle, partner: String, distractors: [String: String]) {
        let needle = Needle(
            id: "n0009",
            query: "What is the fleet size of Drossel Yards?",
            content: "Drossel Yards records its fleet size under reference REF-0042; see the matching reference entry for the value.",
            tier: .split, location: "Fleet/drossel-yards",
            distractorIDs: ["n0009-t4-0"],
            splitPartnerID: "n0009-partner", expectedRank: 1)
        let partner = "Reference REF-0042: the fleet size is 130 vessels."
        let distractors = ["n0009-t4-0": "Reference REF-9999: the fleet size is 12 vessels."]
        return (needle, partner, distractors)
    }

    @Test("split needle: found only when BOTH halves present")
    func splitNeedsBothHalves() {
        let (needle, partner, distractors) = splitNeedle()
        // Only the needle half present → not found (the value half is missing).
        let onlyNeedle = [item(needle.content)]
        let s1 = scorer.score(needle: needle, returned: onlyNeedle,
                              distractorContents: distractors,
                              splitPartnerContent: partner,
                              latencySeconds: 0.01, bytesReturned: 100)
        #expect(s1.foundAtK[10] == false, "split needle with only one half is not found")
        #expect(s1.rank == nil)
        #expect(s1.completeness == 0.0, "a missing partner half is not complete")

        // Both halves present → found; rank is the LATER position.
        let both = [item(needle.content), item("filler"), item(partner)]
        let s2 = scorer.score(needle: needle, returned: both,
                              distractorContents: distractors,
                              splitPartnerContent: partner,
                              latencySeconds: 0.01, bytesReturned: 100)
        #expect(s2.foundAtK[10] == true)
        #expect(s2.rank == 3, "rank is the later of the two halves (partner at position 3)")
        #expect(s2.completeness == 1.0, "both halves returned verbatim → complete")
    }

    @Test("split needle completeness requires both returned halves to byte-match")
    func splitCompleteness() {
        let (needle, partner, distractors) = splitNeedle()
        // The partner returned is a byte-mismatched preview that still normalize-
        // matches the partner key (so both halves are FOUND), yet the partner's
        // returned content differs from verbatim → incomplete.
        let partnerPreview = partner.uppercased()   // normalizes equal, bytes differ
        #expect(GauntletScorer.normalize(partnerPreview) == GauntletScorer.normalize(partner),
                "the preview must normalize-match so the partner half is FOUND")
        let both = [item(needle.content), item(partnerPreview)]
        let s = scorer.score(needle: needle, returned: both,
                             distractorContents: distractors,
                             splitPartnerContent: partner,
                             latencySeconds: 0.01, bytesReturned: 100)
        #expect(s.foundAtK[10] == true)
        #expect(s.completeness == 0.0, "a byte-mismatched partner fails completeness")
    }

    // MARK: - normalization

    @Test("normalize collapses whitespace and case for cross-backend matching")
    func normalizeMatchesAcrossFormatting() {
        let a = GauntletScorer.normalize("The  Velrath   Combine WAS chartered")
        let b = GauntletScorer.normalize("the velrath combine was chartered")
        #expect(a == b)
    }
}
