import Foundation
import MootCommunityUI
import MootCommunityGateway
import Testing

@Suite("Community module boundary")
struct CommunityBoundaryTests {
    @Test("daemon estate identity cannot name or open local storage")
    func daemonIdentityIsStorageOpaque() {
        let identity = EstateIdentity.daemon(
            estate: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            service: "community-daemon"
        )
        #expect(!identity.opensLocalStorage)
        #expect(!identity.displayToken.contains("/"))
    }

    @MainActor
    @Test("Community model fails closed when the resident daemon is unavailable")
    func unavailableDaemonDoesNotExposeAnEstate() async {
        let model = CommunityAppModel(
            connector: CommunityConnectionFixture(state: .unavailable)
        )
        await model.start()
        #expect(model.connectionState == .unavailable)
        #expect(!model.isEstateReady)
        #expect(model.estateIdentity == nil)
    }

    @MainActor
    @Test("every unresolved daemon state fails closed without exposing estate content")
    func unresolvedReadinessMatrix() async {
        let version = SemanticVersion(major: 1, minor: 1, patch: 0)
        let states: [CommunityDaemonConnectionState] = [
            .unavailable,
            .starting,
            .shuttingDown,
            .migrating,
            .recovering,
            .blocked(reason: "authority-required"),
            .incompatible,
            .authenticationFailed,
            .handshakeFailed,
            .updateDaemonRequired(found: version, minimum: version),
            .updateAppRequired(found: version, maximumExclusive: version),
        ]

        for state in states {
            let model = CommunityAppModel(connector: CommunityConnectionFixture(state: state))
            await model.start()
            #expect(!model.isEstateReady)
            #expect(model.estateIdentity == nil)
            #expect(!model.status.isEmpty)
        }
    }

    @MainActor
    @Test("a bounded daemon refusal reason remains visible")
    func blockedReasonIsVisible() async {
        let reason = "recovery-authority-unavailable"
        let model = CommunityAppModel(
            connector: CommunityConnectionFixture(state: .blocked(reason: reason))
        )

        await model.start()

        #expect(model.status.contains(reason))
        #expect(!model.isEstateReady)
    }
}

private actor CommunityConnectionFixture: CommunityDaemonConnecting {
    let state: CommunityDaemonConnectionState

    init(state: CommunityDaemonConnectionState) {
        self.state = state
    }

    func connect() async -> CommunityDaemonConnection {
        CommunityDaemonConnection(state: state)
    }
}
