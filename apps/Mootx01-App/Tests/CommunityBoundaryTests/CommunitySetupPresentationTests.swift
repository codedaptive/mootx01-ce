import Foundation
import MootCommunityUI
import Testing

// MARK: - Setup + shell lifecycle human-language presentation (MH-MOOT-SETUP-LANGUAGE)
//
// Regression locks for census items R-C1, R-C9, R-C10, R-C11, R-C12, and
// R-C13 (apps/Mootx01-App/docs/UI_ACCEPTANCE_CENSUS.md): the Community shell
// status line and the estate setup surface must present lifecycle conditions
// as human language. Raw daemon reason slugs ("estate-missing"), bare
// persistence vocabulary (`estate.schemaVersion`), and unlabeled wire strings
// (`diagnosis`, `reason`) must never be the default-visible explanation.
//
// SwiftUI views are not introspectable without a forbidden dependency, so the
// view-layer half is a SOURCE contract (the same convention as
// CaptureLANSourceContract and the MA human-language guards): the shipped
// sources must route every lifecycle reason through the presentation layer
// and must label every technical value they keep on screen.

@Suite("Setup + shell human-language source contract (R-C9…R-C13)")
struct SetupLifecycleSourceContract {

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

    @Test("the estate chooser labels the schema version instead of printing it bare (R-C9)")
    func schemaVersionIsLabeled() throws {
        let source = try Self.source("Setup/CommunitySetupView.swift")
        #expect(!source.contains("Text(estate.schemaVersion)"),
                "the estate chooser must not print bare persistence vocabulary (R-C9)")
        #expect(source.contains(#"Schema version \(estate.schemaVersion)"#),
                "the schema version must appear behind a human label (R-C9)")
    }

    @Test("the corrupt-estate screen presents a human sentence with the daemon diagnosis as labeled detail (R-C10)")
    func corruptDiagnosisIsLabeled() throws {
        let source = try Self.source("Setup/CommunitySetupView.swift")
        #expect(!source.contains(#"— \(diagnosis)"#),
                "the raw daemon diagnosis must not be spliced into the detail line (R-C10)")
        #expect(source.contains("Reported diagnosis:"),
                "the daemon's diagnosis must stay available behind a label (R-C10)")
    }

    @Test("the incompatible-estate screen presents a human sentence with the wire reason as labeled detail (R-C11)")
    func incompatibleReasonIsLabeled() throws {
        let source = try Self.source("Setup/CommunitySetupView.swift")
        #expect(!source.contains(#"— \(reason)"#),
                "the raw wire reason must not be spliced into the detail line (R-C11)")
        #expect(source.contains("Reported reason:"),
                "the wire reason must stay available behind a label (R-C11)")
    }

    @Test("migration progress counts are labeled, not a bare X / Y (R-C12)")
    func migrationProgressIsLabeled() throws {
        let source = try Self.source("Setup/CommunitySetupView.swift")
        #expect(!source.contains(#"\(progress.completedUnits) / \(progress.totalUnits)"#),
                "migration progress must not render an unlabeled count pair (R-C12)")
        #expect(source.contains(#"Migration progress: \(progress.completedUnits) of \(progress.totalUnits)"#),
                "migration progress must carry a human label (R-C12)")
    }

    @Test("the setup-blocked screen routes the daemon reason through the presentation layer (R-C13)")
    func setupBlockedReasonIsPresented() throws {
        let source = try Self.source("Setup/CommunitySetupView.swift")
        #expect(!source.contains("detail: reason"),
                "the raw daemon reason slug must not be the visible detail (R-C13)")
        #expect(source.contains("CommunityDaemonReason"),
                "the setup view must present blocked reasons through CommunityDaemonReason (R-C13)")
    }

    @Test("the shell status line routes the blocked reason through the presentation layer (R-C1)")
    func shellBlockedStatusIsPresented() throws {
        let source = try Self.source("CommunityAppModel.swift")
        #expect(!source.contains(#": \(reason)"#),
                "the shell status must not append the raw reason slug (R-C1)")
        #expect(source.contains("CommunityDaemonReason"),
                "the shell status must present blocked reasons through CommunityDaemonReason (R-C1)")
    }
}

// MARK: - Lifecycle reason presentation semantics

@Suite("Lifecycle + review reason presentation (R-C1, R-C13…R-C15)")
struct LifecycleReasonSemantics {

    /// Every distinct-meaning lifecycle and review reason code these surfaces
    /// can receive today: the daemon's estate-lifecycle blocked vocabulary
    /// (per LifecycleStateBuilder.blocked and the lifecycle endpoint guards),
    /// the app-synthesized identity-mismatch condition, and the review wire
    /// adapter's own codes.
    static let lifecycleCodes = [
        // Daemon estate-lifecycle blocked vocabulary (contract reasonCodes).
        "estate-missing",
        "estate-corrupt",
        "estate-incompatible",
        "estate-key-missing",
        "migration-required",
        "migration-interrupted",
        "operation-cancelled",
        "authority-insufficient",
        "action-refused",
        // App-synthesized: setup receipt names a different estate than the
        // authenticated daemon connection (CommunityAppModel.start).
        "estate-identity-mismatch",
        // Review wire-adapter codes (DaemonReviewCenterPort).
        "incomplete-daemon-response",
        "session-kind-mismatch",
    ]

    @Test("every lifecycle reason code maps to a human sentence, never the slug")
    func lifecycleCodesAreHuman() {
        for code in Self.lifecycleCodes {
            let presented = CommunityDaemonReason(code: code)
            #expect(presented.isRecognized, "\(code) has no mapped explanation")
            let explanation = presented.explanation
            #expect(explanation.contains(" "), "\(code) explanation reads as an identifier")
            #expect(!explanation.contains(code), "\(code) explanation echoes the machine code")
            #expect(!CommunityPresentationSemanticsTests.containsSlugToken(explanation),
                    "\(code) explanation carries a machine slug: \(explanation)")
        }
    }

    @Test("distinct lifecycle conditions get distinct explanations")
    func lifecycleCodesStayDistinct() {
        let explanations = Self.lifecycleCodes.map {
            CommunityDaemonReason(code: $0).explanation
        }
        #expect(Set(explanations).count == Self.lifecycleCodes.count,
                "two different lifecycle conditions collapse to one sentence")
    }

    @Test("the technical detail always names the exact lifecycle code")
    func technicalDetailCarriesCode() {
        for code in Self.lifecycleCodes {
            #expect(CommunityDaemonReason(code: code).technicalDetail.contains(code))
        }
    }
}
