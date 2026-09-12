import AriaMCP
import Foundation

/// Resolves the Community daemon's one authoritative GLK session for a stable
/// first-party provider.  It owns no dispatcher and performs no tool routing:
/// the provider's future executor keeps its own session and ledger state and
/// asks this context for a refreshed handle only when it needs one.
struct CommunityFirstPartyProviderExecutorContext: FirstPartyProviderExecutorContext {
    let host: CommunityEstateHost

    func currentEstateSession() async throws -> FirstPartyProviderEstateSession {
        FirstPartyProviderEstateSession(kit: host.kit, handle: try await host.handle())
    }
}
