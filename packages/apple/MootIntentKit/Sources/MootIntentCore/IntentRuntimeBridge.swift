import Foundation

// MARK: - IntentRuntimeBridge
//
// The shared runtime that system-instantiated intents (Siri, Shortcuts, the
// Action Button) use when the host app has not injected a caller directly.
// IntentRuntimeBridge is the hook the host app wires during synchronous app
// initialization. When no caller or provider has been registered, `bridge()` throws
// `IntentRuntimeError.noBridgeRegistered` — the code intentionally fails
// closed rather than providing a default in-memory fallback.
//
// Usage:
//   1. During app initialization, register a lazy provider that opens the
//      process's durable bridge, or register an already-open caller.
//   2. Intents that have no injected caller call
//      IntentRuntimeBridge.shared.bridge() and get back whatever the host
//      registered, or an error if nothing was registered yet.
//
// Registration is synchronous and lock-protected so a cold App Intent cannot
// race an unstructured bootstrap Task. Provider execution remains async.

/// The process-wide fallback bridge for system-instantiated intents.
public final class IntentRuntimeBridge: @unchecked Sendable {

    /// The shared instance. All intents that resolve via the fallback path
    /// use this.
    public static let shared = IntentRuntimeBridge()

    public typealias Provider = @Sendable () async throws -> any MootToolCalling

    private let lock = NSLock()
    private var registeredCaller: (any MootToolCalling)?
    private var registeredProvider: Provider?
    private var providerTask: (id: UUID, task: Task<any MootToolCalling, any Error>)?

    public init() {}

    /// Register the bridge the host opened. Call once at app launch. Calling
    /// again after the first registration is a no-op (first wins).
    public func register(_ caller: any MootToolCalling) {
        lock.withLock {
            guard registeredCaller == nil else { return }
            registeredCaller = caller
        }
    }

    /// Register the cold-start provider. The first provider wins.
    public func registerProvider(_ provider: @escaping Provider) {
        lock.withLock {
            guard registeredProvider == nil else { return }
            registeredProvider = provider
        }
    }

    /// Return the registered caller, or throw if nothing is registered.
    /// Intents call this from their `resolvedCaller()` fallback.
    public func bridge() async throws -> any MootToolCalling {
        if let caller = lock.withLock({ registeredCaller }) {
            return caller
        }
        guard let provider = lock.withLock({ registeredProvider }) else {
            throw IntentRuntimeError.noBridgeRegistered
        }
        let inFlight = lock.withLock { () -> (UUID, Task<any MootToolCalling, any Error>) in
            if let providerTask { return (providerTask.id, providerTask.task) }
            let id = UUID()
            let task = Task { try await provider() }
            providerTask = (id, task)
            return (id, task)
        }
        do {
            let created = try await inFlight.1.value
            return lock.withLock {
                if providerTask?.id == inFlight.0 { providerTask = nil }
                if let caller = registeredCaller { return caller }
                registeredCaller = created
                return created
            }
        } catch {
            lock.withLock {
                if providerTask?.id == inFlight.0 { providerTask = nil }
            }
            throw error
        }
    }
}

// MARK: - IntentRuntimeError

public enum IntentRuntimeError: Error, CustomStringConvertible {
    /// The host app did not install its durable provider during initialization.
    /// No in-memory fallback is registered automatically.
    case noBridgeRegistered

    public var description: String {
        "IntentRuntimeBridge: no MootToolCalling bridge registered. "
            + "Register a caller or durable provider during app initialization."
    }
}
