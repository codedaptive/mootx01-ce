import Foundation

// MARK: - GatewayRuntime
//
// The App Intent shells, the URL router, and the share sink are all
// instantiated by the *system*, not by the app — when a Shortcut fires or a
// callback URL arrives, there is no app-provided `init` to inject a bridge
// into. So the gateway needs one well-known place to reach the attached MOOT.
// `GatewayRuntime.shared` is that place: an actor holding the process-wide
// `MootBridge`.
//
// The app's launch path calls `configure(databaseURL:)` once, and the intents
// pick the same estate up here. When an intent is exercised with no prior
// configuration (e.g. a unit test, or the system firing a Shortcut before the
// app ran), `bridge()` lazily attaches an ephemeral in-memory MOOT so the
// shell still resolves — documented shell behavior, not a durable estate.

/// Process-wide holder for the gateway's single `MootBridge`.
public actor GatewayRuntime {

    /// The shared runtime every system-instantiated shell reaches.
    public static let shared = GatewayRuntime()

    private var bridgeValue: MootBridge?

    /// The database URL a caller asked us to use, remembered so a lazy
    /// `bridge()` after `configure` still lands on the durable estate.
    private var configuredURL: URL?

    private init() {}

    /// Point the runtime at a durable SQLite estate. Call once at app launch
    /// before any intent runs. Passing `nil` selects an ephemeral in-memory
    /// estate. Re-configuring after the bridge is attached is a no-op (the
    /// first attachment wins) so a late call cannot swap the live estate out
    /// from under an in-flight intent.
    public func configure(databaseURL: URL?) {
        guard bridgeValue == nil else { return }
        configuredURL = databaseURL
    }

    /// The attached bridge, lazily creating one on first use. Honors a prior
    /// `configure(databaseURL:)`; with none, attaches in-memory.
    public func bridge() async throws -> MootBridge {
        if let bridgeValue { return bridgeValue }
        let created: MootBridge
        if let url = configuredURL {
            created = try await MootBridge.attachSQLite(at: url)
        } else {
            created = try await MootBridge.attachInMemory()
        }
        bridgeValue = created
        return created
    }
}
