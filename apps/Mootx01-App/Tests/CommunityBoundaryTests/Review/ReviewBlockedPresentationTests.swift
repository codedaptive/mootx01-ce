import Foundation
import MootCommunityUI
import Testing

// MARK: - Review blocked-state human-language presentation (MH-MOOT-SETUP-LANGUAGE)
//
// Regression locks for census items R-C14 and R-C15
// (apps/Mootx01-App/docs/UI_ACCEPTANCE_CENSUS.md): the review dashboard's
// blocked-mode row and the session-blocked screen must present the daemon's
// reason code as a human sentence, with the exact machine code preserved only
// as a labeled, selectable detail. The raw slug ("daemon-unavailable-or-
// malformed") must never be the default-visible explanation or the VoiceOver
// text.
//
// SwiftUI views are not introspectable without a forbidden dependency, so
// this is a SOURCE contract (the same convention as CaptureLANSourceContract
// and SetupLifecycleSourceContract). The reason-code mapping semantics are
// locked by LifecycleReasonSemantics in CommunitySetupPresentationTests.

@Suite("Review blocked-state human-language source contract (R-C14, R-C15)")
struct ReviewBlockedSourceContract {

    static var reviewSource: String {
        get throws {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // Tests/CommunityBoundaryTests/Review
                .deletingLastPathComponent()   // Tests/CommunityBoundaryTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // apps/Mootx01-App
                .appendingPathComponent("Sources/MootCommunityUI/Review/ReviewCenterView.swift")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    @Test("the dashboard blocked-mode status is never the bare daemon reason (R-C14)")
    func dashboardBlockedStatusIsPresented() throws {
        let source = try Self.reviewSource
        // The census-flagged form: `case .blocked(let reason):   reason` —
        // the raw wire value as the whole status expression.
        let rawStatusLine = source.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("case .blocked") && trimmed.hasSuffix("reason")
        }
        #expect(!rawStatusLine,
                "the blocked-mode status must be a human sentence, not the raw daemon reason (R-C14)")
        #expect(source.contains("CommunityDaemonReason"),
                "the review view must present blocked reasons through CommunityDaemonReason (R-C14, R-C15)")
    }

    @Test("the session-blocked screen presents the reason, never the raw wire value (R-C15)")
    func sessionBlockedReasonIsPresented() throws {
        let source = try Self.reviewSource
        #expect(!source.contains("Text(reason)"),
                "the session-blocked description must be a human sentence, not the raw reason (R-C15)")
        #expect(!source.contains(#"Session blocked: \(reason)"#),
                "VoiceOver must receive the human sentence, not the raw reason (R-C15)")
        #expect(source.contains("technicalDetail"),
                "the exact machine code must stay available as a labeled, selectable detail (R-C14, R-C15)")
    }
}
