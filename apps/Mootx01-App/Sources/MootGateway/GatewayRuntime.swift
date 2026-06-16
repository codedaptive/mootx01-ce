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
// The app's launch path calls `configure(databaseURL:)` once; the intents
// pick the same estate up through `IntentRuntimeBridge.shared` (from
// MootIntentKit). When an intent is exercised with no prior configuration
// (e.g. a unit test, or the system firing a Shortcut before the app ran),
// `bridge()` lazily attaches an ephemeral in-memory MOOT so the intent still
// resolves — documented behavior, not a durable estate.

/// Process-wide holder for the gateway's single `MootBridge`.
public actor GatewayRuntime {

    /// The shared runtime every system-instantiated intent reaches.
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
    /// Also registers the bridge with `IntentRuntimeBridge` so intents that
    /// are system-instantiated (Siri, Shortcuts) without a direct caller
    /// injection resolve to the same estate.
    public func bridge() async throws -> MootBridge {
        if let bridgeValue { return bridgeValue }
        let created: MootBridge
        if let url = configuredURL {
            created = try await MootBridge.attachSQLite(at: url)
        } else {
            created = try await MootBridge.attachInMemory()
        }
        bridgeValue = created
        // Register with the intent kit's shared runtime so system-instantiated
        // intents (Siri, Shortcuts) find the same estate without needing the
        // app to re-configure them. First registration wins; later calls no-op.
        await IntentRuntimeBridge.shared.register(created)
        return created
    }
}
