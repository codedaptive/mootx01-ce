import Foundation
import MootCommunityUI
import Testing

// MARK: - Obsidian + Transfer human-language presentation (MI-MOOT-INTEGRATION-LANGUAGE)
//
// Regression locks for census items R-C19, R-C20, R-C21, and R-C23
// (apps/Mootx01-App/docs/UI_ACCEPTANCE_CENSUS.md): the Obsidian sync and
// Transfer surfaces must present daemon reason codes as human language.
// The raw wire vocabulary — contract reason slugs ("vault-access-revoked",
// "plan-stale") and app-side adapter codes ("source-authorization-unavailable")
// — must never be the default-visible explanation or the VoiceOver value.
//
// SwiftUI views are not introspectable without a forbidden dependency, so the
// view-layer half is a SOURCE contract (the same convention as
// CaptureLANSourceContract for R-C5/R-C22): the shipped sources must route
// every reason code through CommunityDaemonReason and must not render the raw
// tokens the census flagged.

@Suite("Obsidian + Transfer human-language source contract (R-C19, R-C20, R-C21)")
struct ObsidianTransferSourceContract {

    static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/CommunityBoundaryTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // apps/Mootx01-App
            .appendingPathComponent("Sources/MootCommunityUI")
    }

    static func source(_ relative: String) throws -> String {
        try String(
            contentsOf: sourcesRoot.appendingPathComponent(relative),
            encoding: .utf8
        )
    }

    @Test("the Obsidian view never shows a raw daemon reason in a label, caption, or accessibility value (R-C19)")
    func obsidianReasonsArePresented() throws {
        let source = try Self.source("Obsidian/ObsidianSyncView.swift")
        // "(reason)" catches every raw use the census flagged: the
        // "\(reason)" interpolations, "Text(reason)" captions, and
        // ".accessibilityValue(reason)" — while matching neither the
        // switch-case bindings ("(let reason, …)") nor presented output.
        #expect(!source.contains("(reason)"),
                "raw daemon reason codes must not reach labels, captions, or accessibility values (R-C19)")
        #expect(source.contains("CommunityDaemonReason"),
                "the Obsidian view must present daemon reasons through CommunityDaemonReason (R-C19)")
    }

    @Test("the Transfer view never shows a raw daemon reason in a label, caption, or accessibility value (R-C20)")
    func transferReasonsArePresented() throws {
        let source = try Self.source("Transfer/TransferView.swift")
        #expect(!source.contains("(reason)"),
                "raw daemon reason codes must not reach labels, captions, or accessibility values (R-C20)")
        #expect(source.contains("CommunityDaemonReason"),
                "the Transfer view must present daemon reasons through CommunityDaemonReason (R-C20)")
    }

    @Test("the transfer receipt is selectable so it can be copied (R-C21)")
    func transferReceiptIsCopyable() throws {
        let source = try Self.source("Transfer/TransferView.swift")
        guard let receiptText = source.range(of: "Text(receipt)") else {
            Issue.record("TransferView no longer renders Text(receipt) — update this lock with the census")
            return
        }
        // The modifier chain directly on the receipt Text must enable
        // selection; 300 characters comfortably covers that chain without
        // reaching into the next view.
        let chain = source[receiptText.upperBound...].prefix(300)
        #expect(chain.contains(".textSelection(.enabled)"),
                "the daemon-issued receipt must be selectable/copyable (R-C21)")
    }
}

// MARK: - Reason semantics for the integration surfaces

@Suite("Obsidian + Transfer daemon reason semantics (R-C19, R-C20)")
struct IntegrationDaemonReasonSemantics {

    /// Every distinct-meaning reason code the Obsidian surface can receive
    /// today: the codes CommunityObsidianCoordinator emits plus the app-side
    /// vault adapter codes from DaemonCommunityFeaturePorts.
    static let obsidianCodes = [
        "vault-authorization-missing",
        "vault-access-revoked",
        "sync-not-retryable",
        "vault-authorization-unavailable",
        "vault-selection-unavailable",
    ]

    /// Every distinct-meaning reason code the Transfer surface can receive
    /// today: the codes CommunityTransferCoordinator emits plus the app-side
    /// source/destination adapter codes from DaemonCommunityFeaturePorts.
    static let transferCodes = [
        "permission-revoked",
        "plan-stale",
        "policy-refused",
        "source-authorization-unavailable",
        "source-selection-unavailable",
        "destination-authorization-unavailable",
        "destination-selection-unavailable",
        "job-identity-or-payload-mismatch",
    ]

    @Test("every integration-surface reason code maps to a human sentence, never the slug")
    func recognizedCodesAreHuman() {
        for code in Self.obsidianCodes + Self.transferCodes {
            let presented = CommunityDaemonReason(code: code)
            #expect(presented.isRecognized, "\(code) has no mapped explanation")
            let explanation = presented.explanation
            #expect(explanation.contains(" "), "\(code) explanation reads as an identifier")
            #expect(!explanation.contains(code), "\(code) explanation echoes the machine code")
            #expect(!CommunityPresentationSemanticsTests.containsSlugToken(explanation),
                    "\(code) explanation carries a machine slug: \(explanation)")
        }
    }

    @Test("distinct-meaning codes stay distinct across the capture, LAN, and integration surfaces")
    func distinctCodesStayDistinct() {
        let allDistinctCodes = Self.obsidianCodes + Self.transferCodes
            + CommunityDaemonReasonPresentation.distinctCodes
        let explanations = allDistinctCodes.map {
            CommunityDaemonReason(code: $0).explanation
        }
        #expect(Set(explanations).count == allDistinctCodes.count,
                "two different daemon conditions collapse to one sentence")
    }

    @Test("the technical detail always names the exact daemon code")
    func technicalDetailCarriesCode() {
        for code in Self.obsidianCodes + Self.transferCodes {
            #expect(CommunityDaemonReason(code: code).technicalDetail.contains(code))
        }
    }
}

// MARK: - Checkpoint accessibility key (R-C23)

@Suite("Obsidian checkpoint accessibility key (R-C23)")
struct ObsidianCheckpointAccessibilityKey {

    @Test("the checkpoint a11y key resolves in the shipped table, so VoiceOver never hears the raw dotted key")
    func checkpointAccessibilityKeyResolves() throws {
        let table = CommunityLocalizationKeyGuard.tableKeys(
            in: try String(
                contentsOf: CommunityLocalizationKeyGuard.stringsTable,
                encoding: .utf8
            )
        )
        // ObsidianSyncView looks up "obsidian.status.checkpoint.a11y \(count)",
        // which resolves by prefix against the "%lld" table entry.
        let use = CommunityLocalizationKeyGuard.KeyUse(
            file: "ObsidianSyncView.swift",
            prefix: "obsidian.status.checkpoint.a11y",
            interpolated: true
        )
        #expect(CommunityLocalizationKeyGuard.resolves(use, in: table),
                "obsidian.status.checkpoint.a11y has no Localizable.strings entry — VoiceOver is read the raw dotted key (R-C23)")
    }
}
