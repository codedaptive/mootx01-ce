import Foundation
import Testing
@testable import MootCommunityUI

// MARK: - Review Center presentation regression locks (MC-MOOT-REVIEW-LANGUAGE)
//
// Human-language acceptance law applied to the Review Center's duplicate-group
// and outcome/completion-failure presentation (census items R-C16, R-C17,
// R-C18). Each test asserts the property that must hold on the strings the
// user actually receives:
//
//   * a record identifier is never the primary human description, never
//     truncated, and always labeled (R-C16);
//   * a daemon reason slug is never interpolated into the primary banner
//     sentence, and survives verbatim on a labeled detail line (R-C17, R-C18).
//
// CD-5 note: the test host's Bundle.main does not carry the Community strings
// table, so dotted keys resolve to themselves here. The assertions therefore
// pin structure (what the string contains and does not contain), not English
// copy; CommunityLocalizationKeyGuardTests proves every dotted key resolves
// in the shipped app bundle.

@Suite("Review duplicate-group presentation (R-C16)")
struct ReviewDuplicatePresentationTests {

    static let recordIDs = [
        UUID(uuidString: "AAAAAAA1-0000-4000-8000-000000000001")!,
        UUID(uuidString: "BBBBBBB2-0000-4000-8000-000000000002")!,
        UUID(uuidString: "CCCCCCC3-0000-4000-8000-000000000003")!,
    ]

    @Test("the primary description is a human count — no identifier, full or truncated")
    func primaryDescriptionCarriesNoIdentifier() {
        let summary = ReviewDuplicatePresentation.involvedSummary(Self.recordIDs)
        #expect(summary.contains("3"), "the count must be stated")
        for id in Self.recordIDs {
            let full = id.uuidString
            let truncated = String(full.prefix(8))
            #expect(!summary.contains(full),
                    "primary description leaks a full record UUID: \(summary)")
            #expect(!summary.contains(truncated),
                    "primary description leaks a truncated record UUID: \(summary)")
        }
    }

    @Test("the identifier line carries every FULL record identifier and a label")
    func identifierLineIsFullAndLabeled() {
        let line = ReviewDuplicatePresentation.recordIDLine(Self.recordIDs)
        for id in Self.recordIDs {
            #expect(line.contains(id.uuidString),
                    "identifier line must carry the full UUID, not a truncation: \(line)")
        }
        let bareList = Self.recordIDs.map(\.uuidString).joined(separator: ", ")
        #expect(line != bareList,
                "identifier line must be labeled, not a bare identifier list")
    }

    @Test("the identifier line's VoiceOver label states the count and reads no UUID")
    func accessibilityLabelReadsNoIdentifier() {
        let label = ReviewDuplicatePresentation.recordIDsAccessibilityLabel(
            count: Self.recordIDs.count)
        #expect(label.contains("3"))
        for id in Self.recordIDs {
            #expect(!label.contains(id.uuidString))
            #expect(!label.contains(String(id.uuidString.prefix(8))))
        }
    }
}

@Suite("Review outcome and completion-failure presentation (R-C17, R-C18)")
struct ReviewOutcomePresentationTests {

    /// A recognizably machine-shaped reason, as the daemon supplies in
    /// practice (CD-1).
    static let reason = "synthetic-conflict-reason-slug"

    static let reasonCarryingOutcomes: [ReviewActionOutcome] = [
        .conflict(reason), .refused(reason), .failed(reason),
    ]

    static let reasonFreeOutcomes: [ReviewActionOutcome] = [
        .applied, .alreadyApplied, .staleSession,
    ]

    @Test("no primary banner sentence interpolates the daemon's raw reason")
    func primarySentencesCarryNoRawReason() {
        for outcome in Self.reasonCarryingOutcomes {
            let message = ReviewOutcomePresentation.message(for: outcome)
            #expect(!message.isEmpty)
            #expect(!message.contains(Self.reason),
                    "banner sentence leaks the raw daemon reason: \(message)")
        }
    }

    @Test("every outcome renders a distinct primary sentence")
    func primarySentencesAreDistinct() {
        let all = Self.reasonCarryingOutcomes + Self.reasonFreeOutcomes
        let messages = all.map { ReviewOutcomePresentation.message(for: $0) }
        #expect(Set(messages).count == messages.count,
                "two outcomes collapse to one sentence: \(messages)")
    }

    @Test("the daemon's reason survives verbatim on a labeled detail line")
    func detailCarriesReasonLabeled() throws {
        for outcome in Self.reasonCarryingOutcomes {
            let detail = ReviewOutcomePresentation.detail(for: outcome)
            let unwrapped = try #require(detail)
            #expect(unwrapped.contains(Self.reason),
                    "the daemon's reason must be preserved for inspection")
            #expect(unwrapped != Self.reason,
                    "the reason must be labeled, not shown bare")
        }
    }

    @Test("outcomes that carry no reason render no detail line")
    func reasonFreeOutcomesHaveNoDetail() {
        for outcome in Self.reasonFreeOutcomes {
            #expect(ReviewOutcomePresentation.detail(for: outcome) == nil)
        }
    }

    @Test("the completion-failure body is human and the reason is labeled detail")
    func completionFailurePresentation() {
        let body = ReviewOutcomePresentation.completionFailureBody
        #expect(!body.isEmpty)
        #expect(!body.contains(Self.reason))
        let detail = ReviewOutcomePresentation.completionFailureDetail(
            reason: Self.reason)
        #expect(detail.contains(Self.reason),
                "the daemon's completion-failure reason must be preserved")
        #expect(detail != Self.reason,
                "the completion-failure reason must be labeled, not shown bare")
    }
}
