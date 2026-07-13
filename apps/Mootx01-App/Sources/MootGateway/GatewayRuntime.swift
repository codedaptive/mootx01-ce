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
}
