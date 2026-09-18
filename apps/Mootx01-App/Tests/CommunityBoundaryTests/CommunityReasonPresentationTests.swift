import Foundation
import MootCommunityUI
import Testing

// MARK: - Capture + LAN human-language presentation (MD-MOOT-CAPTURE-LANGUAGE)
//
// Regression locks for census items R-C2, R-C3, R-C4, R-C5, and R-C22
// (apps/Mootx01-App/docs/UI_ACCEPTANCE_CENSUS.md): the Community capture and
// LAN surfaces must present sensitivity levels, refused fields, and daemon
// reason codes as human language. The raw wire vocabulary — enum rawValues
// ("export-eligibility") and contract reason slugs ("privacy-escalation",
// "lan-authority-missing") — must never be the default-visible explanation.
//
// SwiftUI views are not introspectable without a forbidden dependency, so the
// view-layer half is a SOURCE contract (the same convention as the MA
// human-language guards and CAPTURE-PLACEMENT-R1): the shipped sources must
// route every reason code through the presentation layer and must not render
// the raw tokens the census flagged.

@Suite("Capture + LAN human-language source contract (R-C2…R-C5, R-C22)")
struct CaptureLANSourceContract {

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

    @Test("the capture view renders no raw sensitivity or field values (R-C2, R-C3, R-C4)")
    func captureViewShowsNoRawValues() throws {
        let source = try Self.source("Capture/CommunityCaptureView.swift")
        #expect(!source.contains("rawValue.capitalized"),
                "sensitivity picker rows and the receipt must render the humanized displayName, not the capitalized wire value (R-C2, R-C3)")
        #expect(!source.contains("Text(field.rawValue)"),
                "the refused field must render its human displayName, not the wire slug (R-C4)")
    }

    @Test("the capture refusal reason is presented, never the bare daemon slug (R-C5)")
    func captureRefusalReasonIsPresented() throws {
        let source = try Self.source("Capture/CommunityCaptureView.swift")
        #expect(!source.contains("Text(reason)"),
                "the daemon reason code must pass through the reason presentation layer before display (R-C5)")
        #expect(source.contains("CommunityDaemonReason"),
                "the capture view must present refusal reasons through CommunityDaemonReason (R-C5)")
    }

    @Test("the LAN view never shows a raw daemon reason in a label, caption, or accessibility value (R-C22)")
    func lanReasonsArePresented() throws {
        let source = try Self.source("LAN/LANControlView.swift")
        // "(reason)" catches every raw use the census flagged: the
        // "\(reason)" interpolations, "Text(reason)" captions, and
        // ".accessibilityValue(reason)" — while matching neither the
        // switch-case bindings ("(let reasonCode)") nor presented output.
        #expect(!source.contains("(reason)"),
                "raw daemon reason codes must not reach labels, captions, or accessibility values (R-C22)")
        #expect(source.contains("CommunityDaemonReason"),
                "the LAN view must present daemon reasons through CommunityDaemonReason (R-C22)")
    }
}

// MARK: - Reason presentation semantics

@Suite("Community daemon reason presentation (R-C5, R-C22)")
struct CommunityDaemonReasonPresentation {

    /// Every distinct-meaning reason code the capture and LAN surfaces can
    /// receive today: the contract reasonCodes the two daemon coordinators
    /// emit plus the daemon-side fallbacks.
    static let distinctCodes = [
        "capture-content-invalid",
        "destination-stale",
        "destination-forbidden",
        "privacy-escalation",
        "request-conflict",
        "lan-authority-missing",
        "lan-network-unavailable",
        "lan-policy-forbidden",
        "lan-credential-expired",
        "unexpected-failure",
        "daemon-blocked",
        "daemon-refused",
        "daemon-result-ambiguous",
    ]

    /// App-side wire-adapter codes: one shared truthful sentence (the app
    /// cannot distinguish an unreachable daemon from an unreadable response
    /// beyond what these codes already say).
    static let wireCodes = [
        "daemon-unavailable",
        "daemon-unavailable-or-malformed",
        "daemon-call-failed",
        "malformed-daemon-response",
    ]

    @Test("every surface reason code maps to a human sentence, never the slug")
    func recognizedCodesAreHuman() {
        for code in Self.distinctCodes + Self.wireCodes {
            let presented = CommunityDaemonReason(code: code)
            #expect(presented.isRecognized, "\(code) has no mapped explanation")
            let explanation = presented.explanation
            #expect(explanation.contains(" "), "\(code) explanation reads as an identifier")
            #expect(!explanation.contains(code), "\(code) explanation echoes the machine code")
            #expect(!CommunityPresentationSemanticsTests.containsSlugToken(explanation),
                    "\(code) explanation carries a machine slug: \(explanation)")
        }
    }

    @Test("distinct-meaning codes get distinct explanations")
    func distinctCodesStayDistinct() {
        let explanations = Self.distinctCodes.map {
            CommunityDaemonReason(code: $0).explanation
        }
        #expect(Set(explanations).count == Self.distinctCodes.count,
                "two different daemon conditions collapse to one sentence")
    }

    @Test("an unknown code is presented honestly, with the code as labeled detail only")
    func unknownCodeIsHonest() {
        let presented = CommunityDaemonReason(code: "brand-new-condition")
        #expect(!presented.isRecognized)
        #expect(presented.explanation.contains(" "))
        #expect(!presented.explanation.contains("brand-new-condition"),
                "the fallback sentence must not smuggle the slug into prose")
        #expect(!CommunityPresentationSemanticsTests.containsSlugToken(presented.explanation))
        #expect(presented.technicalDetail.contains("brand-new-condition"),
                "the labeled technical detail must preserve the exact code")
        #expect(presented.technicalDetail != "brand-new-condition",
                "the technical detail must be labeled, not the bare code")
    }

    @Test("the technical detail always names the exact daemon code")
    func technicalDetailCarriesCode() {
        for code in Self.distinctCodes {
            #expect(CommunityDaemonReason(code: code).technicalDetail.contains(code))
        }
    }
}

// MARK: - Capture display-name semantics

@Suite("Capture sensitivity and refused-field display names (R-C2…R-C4)")
struct CaptureDisplayNameSemantics {

    @Test("every sensitivity display name is a human phrase, distinct, and not the wire value")
    func sensitivityDisplayNames() {
        var seen: Set<String> = []
        for sensitivity in CommunityCaptureSensitivity.allCases {
            let name = sensitivity.displayName
            #expect(name.contains(" "), "\(sensitivity) display name \(name) reads as an identifier")
            #expect(name.lowercased() != sensitivity.rawValue.lowercased())
            seen.insert(name)
        }
        #expect(seen.count == CommunityCaptureSensitivity.allCases.count,
                "two sensitivities share one display name")
    }

    @Test("the eye and VoiceOver receive the same sensitivity name")
    func sensitivityNamesAgreeWithAccessibility() {
        for sensitivity in CommunityCaptureSensitivity.allCases {
            #expect(sensitivity.displayName == sensitivity.accessibilityLabel)
        }
    }

    static let everyField: [CommunityCaptureRefusedField] = [
        .destination, .sensitivity, .exportEligibility, .lanEligibility, .content, .daemon,
    ]

    @Test("every refused-field display name is human, distinct, and slug-free")
    func refusedFieldDisplayNames() {
        var seen: Set<String> = []
        for field in Self.everyField {
            let name = field.displayName
            #expect(!name.isEmpty)
            #expect(!name.contains("-"), "\(field) display name \(name) still carries the wire slug shape")
            #expect(name != field.rawValue, "\(field) display name is the bare wire value")
            #expect(!CommunityPresentationSemanticsTests.containsSlugToken(name))
            seen.insert(name)
        }
        #expect(seen.count == Self.everyField.count, "two refused fields share one display name")
    }
}
