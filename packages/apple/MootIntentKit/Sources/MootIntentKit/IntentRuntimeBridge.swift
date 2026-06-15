import Foundation

// MARK: - IntentRuntimeBridge
//
// The shared runtime that system-instantiated intents (Siri, Shortcuts, the
// Action Button) use when the host app has not injected a caller directly.
// When the system launches an intent without a prior app launch, the intent
// must still reach the MOOT. IntentRuntimeBridge is the hook the host app
// wires at launch so that system-instantiated calls land on the same estate
// the app uses.
//
// Usage:
//   1. At app launch: call IntentRuntimeBridge.shared.register(bridge) with
//      the MootBridge (or any MootToolCalling conformance) you opened.
//   2. Intents that have no injected caller call
//      IntentRuntimeBridge.shared.bridge() and get back whatever the host
//      registered, or an error if nothing was registered yet.
//
// Design: this is a simple actor holding a weak-ish reference (stored as
// existential). It does not own the bridge — the host (GatewayRuntime) owns
// the real MootBridge. The registration is one-write: once a bridge is
// registered, a second call to register() is a no-op so a late call cannot
// swap the estate out from under an in-flight intent.

/// The process-wide fallback bridge for system-instantiated intents.
public actor IntentRuntimeBridge {

    /// The shared instance. All intents that resolve via the fallback path
    /// use this.
    public static let shared = IntentRuntimeBridge()

    private var registeredCaller: (any MootToolCalling)?

    private init() {}

    /// Register the bridge the host opened. Call once at app launch. Calling
    /// again after the first registration is a no-op (first wins).
    public func register(_ caller: any MootToolCalling) {
        guard registeredCaller == nil else { return }
        registeredCaller = caller
    }

    /// Return the registered caller, or throw if nothing is registered.
    /// Intents call this from their `resolvedCaller()` fallback.
    public func bridge() throws -> any MootToolCalling {
        guard let caller = registeredCaller else {
            throw IntentRuntimeError.noBridgeRegistered
        }
        return caller
    }
}

// MARK: - IntentRuntimeError

public enum IntentRuntimeError: Error, CustomStringConvertible {
    /// The host app has not yet registered a bridge. This happens when the
    /// system instantiates an intent before the app has launched and called
    /// IntentRuntimeBridge.shared.register(_:).
    ///
    /// By design, no in-memory fallback bridge is registered automatically.
    /// Cold-launch intents (system-instantiated without a prior app launch)
    /// return [] or throw this error; a live estate requires the host to have
    /// run start() and called register(_:). This is the correct fail-closed
    /// behavior — no fabricated results, no phantom estate.
    case noBridgeRegistered

    public var description: String {
        "IntentRuntimeBridge: no MootToolCalling bridge registered. "
            + "Call IntentRuntimeBridge.shared.register(_:) at app launch."
    }
}
