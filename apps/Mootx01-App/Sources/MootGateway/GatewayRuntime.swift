import Foundation
import MootIntentKit

// MARK: - GatewayRuntime
//
// The intents, URL router, and share sink are all instantiated by the system
// (Shortcuts, Siri, Action Button) — when one fires there is no app-provided
// `init` to inject a bridge. So the gateway needs one well-known place to
// reach the attached MOOT. `GatewayRuntime.shared` is that place: an actor
// holding the process-wide `MootBridge`.
//
// The app installs a lazy provider synchronously from its initializer. The
// provider and every GUI surface resolve through this actor, so a cold intent
// and a subsequently opened window attach the same durable estate.

/// Process-wide holder for the gateway's single `MootBridge`.
public actor GatewayRuntime {

    /// The shared runtime every system-instantiated intent reaches.
    public static let shared = GatewayRuntime()

    private var bridgeValue: MootBridge?

    private var configuredEstate: GatewayEstateConfiguration?

    private init() {}

    /// Override the default durable estate before first attachment.
    public func configure(databaseURL: URL) {
        guard bridgeValue == nil else { return }
        configuredEstate = .sqlite(databaseURL)
    }

    #if DEBUG
    /// Select an in-memory estate for unit/integration tests only.
    public func configureInMemoryForTesting() {
        guard bridgeValue == nil else { return }
        configuredEstate = .inMemoryTesting
    }
    #endif

    /// Install the process-wide lazy provider before SwiftUI creates a window.
    /// This is synchronous so an App Intent cannot race provider registration.
    public nonisolated static func installIntentProvider() {
        IntentRuntimeBridge.shared.registerProvider {
            try await GatewayRuntime.shared.bridge()
        }
    }

    /// Lazily attach the configured estate. With no explicit configuration,
    /// resolve the durable app-container URL (or a DEBUG-only test override).
    public func bridge() async throws -> MootBridge {
        if let bridgeValue { return bridgeValue }
        let configuration = try configuredEstate ?? EstateConfigurationResolver.resolve()
        let created: MootBridge
        switch configuration {
        case .sqlite(let url):
            created = try await MootBridge.attachSQLite(at: url)
        #if DEBUG
        case .inMemoryTesting:
            created = try await MootBridge.attachInMemory()
        #endif
        }
        bridgeValue = created
        IntentRuntimeBridge.shared.register(created)
        return created
    }

    // MARK: - Federation Session Manager (FED-OD-4)

    /// The process-wide `FederationSessionManager`. Created lazily on first access.
    ///
    /// F1 supports one concurrent federation session. The manager is backed by
    /// this runtime's estate bridge (lazily resolved). The UI layer (FederationPanelView,
    /// FED-OD-6) calls `startSession` / `endSession` on the manager returned here.
    ///
    /// - Throws: Rethrows from `bridge()` if the estate cannot be attached.
    public func federationSession() async throws -> FederationSessionManager {
        if let m = _federationSession { return m }
        let b = try await bridge()
        let manager = FederationSessionManager(bridge: b)
        _federationSession = manager
        return manager
    }

    // Stored separately from bridgeValue to keep the bridge accessor clean.
    private var _federationSession: FederationSessionManager?
}
