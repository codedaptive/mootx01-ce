import Foundation
import MootCommunityUI
import MootCommunityGateway
import Testing

// MARK: - Community presentation semantics (MA-MOOT-UI-CENSUS)
//
// Additive unit tests for the presentation/formatting behavior the Community
// surfaces already ship: the human-language acceptance law applied to the
// strings a user (or VoiceOver) actually receives. These tests assert the
// GREEN half of the census (apps/Mootx01-App/docs/UI_ACCEPTANCE_CENSUS.md);
// the RED half is held by the enumerated guard baselines, not painted green
// here.

@Suite("Community presentation semantics")
struct CommunityPresentationSemanticsTests {

    // MARK: Capture sensitivity accessibility vocabulary

    @Test("every sensitivity has a human, multi-word accessibility label distinct from its raw value")
    func sensitivityAccessibilityLabels() {
        var seen: Set<String> = []
        for sensitivity in CommunityCaptureSensitivity.allCases {
            let label = sensitivity.accessibilityLabel
            #expect(!label.isEmpty)
            // A human phrase, not an identifier: contains a space and is not
            // the raw enum value in any casing.
            #expect(label.contains(" "), "\(sensitivity) label \(label) reads as an identifier")
            #expect(label.lowercased() != sensitivity.rawValue.lowercased())
            seen.insert(label)
        }
        #expect(seen.count == CommunityCaptureSensitivity.allCases.count,
                "two sensitivities share one accessibility label")
    }

    @Test("every sensitivity states its consequence for assistive technology")
    func sensitivityConsequences() {
        for sensitivity in CommunityCaptureSensitivity.allCases {
            #expect(!sensitivity.accessibilityConsequence.isEmpty)
        }
    }

    // MARK: Capture model accessibility fallbacks

    @MainActor
    @Test("with no destination chosen the accessibility value and hint are honest sentences, not empty or placeholder")
    func destinationAccessibilityFallbacks() {
        let model = CommunityCaptureModel(service: UnavailableCommunityCaptureService())
        #expect(model.selectedDestination == nil)
        let value = model.selectedDestinationAccessibilityValue
        let hint = model.selectedDestinationAccessibilityHint
        #expect(!value.isEmpty)
        #expect(!hint.isEmpty)
        #expect(value.contains(" "), "fallback value \(value) reads as an identifier")
        #expect(hint.contains(" "), "fallback hint \(hint) reads as an identifier")
    }

    // MARK: Connection status vocabulary

    /// Every unready connection state the model can display, including
    /// blocked with the one reason code the app itself synthesizes (R-C1
    /// closed: the reason passes through CommunityDaemonReason, so the
    /// status must survive the slug check like every other state).
    static let unreadyStates: [CommunityDaemonConnectionState] = {
        let version = SemanticVersion(major: 1, minor: 1, patch: 0)
        return [
            .unavailable,
            .starting,
            .shuttingDown,
            .migrating,
            .recovering,
            .blocked(reason: "estate-identity-mismatch"),
            .incompatible,
            .authenticationFailed,
            .handshakeFailed,
            .updateDaemonRequired(found: version, minimum: version),
            .updateAppRequired(found: version, maximumExclusive: version),
        ]
    }()

    @MainActor
    @Test("every unready connection state renders a distinct human status with no slug-shaped state code")
    func connectionStatusesAreHuman() async {
        var statuses: [String] = []
        for state in Self.unreadyStates {
            let model = CommunityAppModel(
                connector: PresentationConnectionFixture(state: state))
            await model.start()
            let status = model.status
            #expect(!status.isEmpty)
            #expect(status.contains(" "), "status \(status) reads as an identifier")
            // The law: no unexplained state codes. A slug like
            // "estate-identity-mismatch" contains an intra-word hyphen; a
            // human sentence does not (today's copy uses none).
            #expect(!Self.containsSlugToken(status),
                    "status \(status) carries a machine slug")
            statuses.append(status)
        }
        #expect(Set(statuses).count == statuses.count,
                "two distinct daemon states collapse to one status text: \(statuses)")
    }

    /// True when any whitespace-delimited token looks like a machine slug:
    /// lowercase words joined by hyphens ("daemon-unavailable-or-malformed").
    static func containsSlugToken(_ text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace }).contains { token in
            let parts = token.split(separator: "-")
            return parts.count >= 2 && parts.allSatisfy { part in
                !part.isEmpty && part.allSatisfy { $0.isLowercase && $0.isLetter }
            }
        }
    }

    @Test("the slug detector recognizes slugs and passes human sentences")
    func slugDetectorSelfTest() {
        #expect(Self.containsSlugToken("Blocked: estate-identity-mismatch"))
        #expect(Self.containsSlugToken("daemon-unavailable-or-malformed"))
        #expect(!Self.containsSlugToken("Resident daemon is shutting down"))
        #expect(!Self.containsSlugToken("Estate migration in progress"))
    }
}

/// Minimal connector fixture for driving CommunityAppModel presentation.
/// A private twin of the fixture in CommunityBoundaryTests.swift (that one
/// is file-private by design).
private actor PresentationConnectionFixture: CommunityDaemonConnecting {
    let state: CommunityDaemonConnectionState

    init(state: CommunityDaemonConnectionState) {
        self.state = state
    }

    func connect() async -> CommunityDaemonConnection {
        CommunityDaemonConnection(state: state)
    }
}
