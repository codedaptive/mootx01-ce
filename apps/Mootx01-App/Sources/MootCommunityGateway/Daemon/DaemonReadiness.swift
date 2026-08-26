import AriaMCPWire
import Foundation

// MARK: - Daemon readiness
//
// "Ready" means a client may hand real estate work to a resident daemon.
//
// The tempting definition — something is listening on the port — is the one
// this file exists to refuse. A listening socket proves that a process bound an
// address. It does not prove the process is the daemon this client contracted
// with, that it owns the estate the client means, that it speaks a protocol
// version the client understands, or that it knows who is asking.
//
// Readiness is the conjunction of these gates, in order:
//
//   1. A published descriptor exists and is COMPATIBLE (provider, service,
//      revision, protocol, loopback endpoint, capabilities).
//   2. The transport is AUTHENTICATED: an `AuthenticatedDaemonTransport` with a
//      non-empty session identifier — a positive assertion by the
//      authenticator, not the absence of a rejection.
//   3. The MCP `initialize` HANDSHAKE agrees, and the responding daemon reports
//      BOTH its instance identifier and its estate identifier matching the
//      descriptor. A compatible
//      descriptor says which daemon and which estate a client expects; without
//      this step nothing forces the process that actually answered to be that
//      daemon holding that estate.
//   4. `notifications/initialized` completes the MCP lifecycle.
//   5. `ping` SUCCEEDS — the dispatcher is serving, not merely accepting.
//
// Every gate fails closed. No fallback to an unauthenticated transport, no
// protocol downgrade, no partial-readiness state.
//
// CONCURRENCY. `connect()` suspends at every gate, so two callers can interleave
// inside this actor. Each attempt therefore takes a generation token, and only
// an attempt still holding the current token may publish state or a caller.
// A stale attempt — one that started earlier and finished later — computes its
// outcome and discards it. Without this an old attempt's `.authenticationFailed`
// could erase a newer attempt's live caller, or an old success could install a
// caller for a daemon the client has already moved on from.
//
// CRYPTOGRAPHIC BINDING. Gates 2 and 3 are bound by PROOF when the
// authenticator is `FirstPartyDaemonAuthenticator`. That authenticator verifies
// the descriptor's MAC under the shared installation root before it sends any
// traffic, completes an HKDF mutual challenge/establish handshake, and returns a
// transport that MACs every request and verifies every response MAC before the
// body is parsed. The identifiers the daemon reports at `initialize` are
// therefore checked against a descriptor already proved authentic, rather than
// against a claim any process holding the port could have made.
//
// Readiness itself stays authenticator-agnostic: it requires a positive
// `AuthenticatedDaemonTransport` and does not inspect how the proof was
// obtained. That is what lets a test inject a stub while production supplies the
// real handshake, and it is why the type of the transport — not a flag — is the
// evidence.
//
// DEFERRED TO MACD-2c. Nothing here mints a production root, publishes a
// descriptor, or elects a provider. Until that lands there is no live descriptor
// to read, which is why this whole path remains dark.
//
// DARK INFRASTRUCTURE: nothing in production routing reaches this type yet.

/// Where a readiness attempt ended.
public enum DaemonReadinessState: Sendable, Equatable {

    /// No descriptor could be read.
    case unavailable

    /// A descriptor was read but this client does not contract with it. Failed
    /// at gate 1; no authentication was attempted.
    case incompatible

    /// The descriptor was compatible but no authenticated session was
    /// established. Failed at gate 2.
    case authenticationFailed

    /// The session authenticated but the daemon's MCP handshake disagreed with
    /// its own descriptor — including a mismatched instance or estate
    /// identifier — or the dispatcher did not answer a ping.
    case handshakeFailed

    /// The daemon is older than this client supports. The user must update the
    /// DAEMON. Distinct from `.incompatible` because it is actionable: the
    /// client knows exactly what is wrong and what would fix it.
    case updateDaemonRequired(found: SemanticVersion, minimum: SemanticVersion)

    /// The daemon is newer than this client understands. The user must update
    /// the APP. The client never stops or downgrades the daemon.
    case updateAppRequired(found: SemanticVersion, maximumExclusive: SemanticVersion)

    /// Every gate passed. Carries the matched descriptor.
    case ready(DaemonDescriptor)

    /// The attempt was superseded by a newer `connect()` before it could
    /// publish. Reported to the caller that ran it, never stored.
    case superseded
}

/// A transport that has been authenticated to a resident daemon.
///
/// A distinct type rather than a flag, because the readiness argument rests on
/// being unable to reach gate 3 without having passed gate 2. An authenticator
/// cannot express "authenticated" by returning a bare transport.
///
/// It forwards `send` unchanged. The credential rides on the wrapped transport
/// (typically an `HTTPTransport` with a `GatewayRequestAuthorization`); this
/// wrapper carries the authenticator's assertion that authentication happened,
/// not the secret or a cryptographic proof of peer identity.
public struct AuthenticatedDaemonTransport: GatewayTransport, Sendable {

    /// The authenticated wire to the daemon.
    private let transport: any GatewayTransport

    /// The daemon-issued session this transport speaks on. Non-empty by
    /// contract; readiness refuses an empty identifier.
    public let sessionIdentifier: String

    /// Wrap an authenticated transport.
    public init(transport: any GatewayTransport, sessionIdentifier: String) {
        self.transport = transport
        self.sessionIdentifier = sessionIdentifier
    }

    /// Forward one JSON-RPC frame to the authenticated transport.
    public func send(_ request: JSONRPCRequest) async throws -> JSONRPCResponse? {
        try await transport.send(request)
    }
}

/// Runs the readiness gates and owns the caller they produce.
public actor DaemonReadiness {

    /// Reads the daemon's published descriptor. Returns nil when none exists;
    /// throws when one exists but cannot be decoded. Both mean `.unavailable`.
    public typealias DescriptorLoader = () async throws -> DaemonDescriptor?

    /// Establishes an authenticated session. Throwing is the only way to say
    /// "no": no return value means unauthenticated.
    public typealias Authenticator = (DaemonDescriptor) async throws -> AuthenticatedDaemonTransport

    private let policy: DaemonCompatibilityPolicy
    private let loadDescriptor: DescriptorLoader
    private let authenticate: Authenticator

    /// The caller from the last attempt that published a `.ready` outcome.
    /// Cleared synchronously at every attempt entry: while a `connect()` is in
    /// flight there is no caller, because the previous one is exactly what the
    /// attempt is re-validating.
    private var caller: MootCaller?

    /// The published outcome. `.unavailable` before the first attempt and at
    /// each attempt entry, until the attempt publishes.
    public private(set) var state: DaemonReadinessState = .unavailable

    /// Incremented once per attempt. An attempt may publish only while its
    /// token still equals this value.
    private var generation: UInt64 = 0

    /// Highest credential and descriptor generation this checker has ACTED ON.
    ///
    /// Monotonicity is a property of a SEQUENCE of descriptors, so it cannot be
    /// judged from any single record — something has to remember. This actor is
    /// that something: a descriptor that moves either generation backwards is a
    /// stale or replayed record and is refused before authentication is even
    /// attempted.
    ///
    /// **Scope, stated precisely.** This high-water lives in memory and lasts as
    /// long as this actor. It defeats replay WITHIN a session of the app: a
    /// rotated-then-rolled-back descriptor, or a stale file restored underneath
    /// a running client. It does NOT survive an app restart, because there is
    /// nowhere trustworthy to persist it yet — a durable high-water has to live
    /// beside the provider lock, and MACD-2c is the mission that introduces one.
    /// Until then a restarted app accepts whatever generation it first sees.
    /// That gap is deliberate and bounded, not an oversight, and it is why this
    /// property is documented rather than quietly relied upon.
    private var lastCredentialGeneration: UInt64?
    private var lastDescriptorGeneration: UInt64?

    /// Build a readiness checker.
    ///
    /// - Parameters:
    ///   - policy: The compatibility gate. Defaults to the shipped contract.
    ///   - loadDescriptor: Reads the daemon's published descriptor. Handed over
    ///     to this actor; the caller keeps no reference to what it captured.
    ///   - authenticate: Establishes an authenticated session, on the same terms.
    public init(
        policy: DaemonCompatibilityPolicy = .current,
        loadDescriptor: sending @escaping DescriptorLoader,
        authenticate: sending @escaping Authenticator
    ) {
        self.policy = policy
        self.loadDescriptor = loadDescriptor
        self.authenticate = authenticate
    }

    /// The caller for the resident daemon, or nil when it is not ready.
    public func callerIfReady() -> MootCaller? { caller }

    /// Run every readiness gate and, if this attempt is still the current one,
    /// publish its outcome.
    ///
    /// Safe to call concurrently. Each call takes a generation token; a call
    /// overtaken by a later one returns `.superseded` and changes nothing.
    ///
    /// - Returns: This attempt's outcome, or `.superseded`.
    public func connect() async -> DaemonReadinessState {
        generation &+= 1
        let token = generation
        // Clear the published caller SYNCHRONOUSLY, before this attempt's
        // first suspension (Codex Security bafca1e0). A reconnect exists
        // because the previous outcome is in doubt — the daemon may have
        // exited or rotated — so handing out the prior caller during any of
        // the awaits below would route real estate work to a daemon this
        // client is actively re-validating. Every attempt therefore starts
        // from "nothing published": an attempt that ends unavailable,
        // incompatible, failed, superseded, or cancelled exposes no prior
        // caller, and only a full pass through every gate republishes one.
        // The generation token still fences publishes, so a stale completion
        // can neither clear nor reinstall state belonging to a newer attempt.
        caller = nil
        state = .unavailable

        // Gate 1: a descriptor exists and this client contracts with it.
        let descriptor: DaemonDescriptor
        do {
            guard let loaded = try await loadDescriptor() else { return publish(.unavailable, token: token) }
            descriptor = loaded
        } catch {
            return publish(.unavailable, token: token)
        }
        guard isCurrent(token) else { return .superseded }
        // The compatibility verdict is mapped rather than collapsed. A version
        // outside the supported range is not the same condition as a malformed
        // or hostile descriptor, and telling the user "incompatible" when the
        // real answer is "update the daemon" is a readiness state that lies by
        // omission.
        //
        // The generation-aware overload is used, not the plain one: it is the
        // only call site that can supply the history monotonicity needs.
        switch policy.evaluate(
            descriptor,
            lastCredentialGeneration: lastCredentialGeneration,
            lastDescriptorGeneration: lastDescriptorGeneration
        ) {
        case .compatible:
            break
        case .updateDaemonRequired(let found, let minimum):
            return publish(.updateDaemonRequired(found: found, minimum: minimum), token: token)
        case .updateAppRequired(let found, let maximumExclusive):
            return publish(
                .updateAppRequired(found: found, maximumExclusive: maximumExclusive), token: token
            )
        case .invalidDescriptor, .missingCapabilities:
            return publish(.incompatible, token: token)
        }

        // Gate 2: an authenticated session. Reached only for a descriptor the
        // policy already accepted, so an untrusted provider never sees a
        // credential attempt.
        let authenticated: AuthenticatedDaemonTransport
        do {
            authenticated = try await authenticate(descriptor)
        } catch {
            return publish(.authenticationFailed, token: token)
        }
        guard isCurrent(token) else { return .superseded }
        guard !authenticated.sessionIdentifier.isEmpty else {
            return publish(.authenticationFailed, token: token)
        }

        // Gates 3-5 need a caller to send over; it stays local to this attempt
        // until every gate has passed AND this attempt is still current.
        // The identity comes from the descriptor, whose MAC was verified under
        // the shared installation root before any traffic was sent. Gate 3
        // below then requires the daemon's own handshake to report the same
        // estate, so a caller only escapes this scope naming an estate that was
        // both signed for and agreed to.
        let candidate = MootCaller(
            transport: authenticated,
            serverName: DaemonContract.serverName,
            estateIdentity: .daemon(
                estate: descriptor.estateIdentifier,
                service: descriptor.serviceIdentifier
            )
        )
        guard await Self.handshakeAgrees(candidate, with: descriptor) else {
            return publish(.handshakeFailed, token: token)
        }
        guard isCurrent(token) else { return .superseded }
        guard await Self.pingSucceeds(candidate) else {
            return publish(.handshakeFailed, token: token)
        }
        // Advance the high-water only for a descriptor that passed EVERY gate,
        // including the authenticated handshake. Advancing earlier would let an
        // unauthenticated peer push the watermark forward with a descriptor it
        // never proved, and so lock out the genuine daemon behind it.
        if isCurrent(token) {
            lastCredentialGeneration = max(lastCredentialGeneration ?? 0, descriptor.credentialGeneration)
            lastDescriptorGeneration = max(lastDescriptorGeneration ?? 0, descriptor.descriptorGeneration)
        }
        return publish(.ready(descriptor), token: token, caller: candidate)
    }

    /// Whether this attempt still owns the right to publish.
    private func isCurrent(_ token: UInt64) -> Bool { token == generation }

    /// Publish an outcome if this attempt is still current, otherwise discard it.
    ///
    /// The caller is replaced in the same step as the state so the two can never
    /// disagree: a published `.ready` always carries its caller, and every other
    /// published outcome clears it.
    private func publish(
        _ outcome: DaemonReadinessState,
        token: UInt64,
        caller newCaller: MootCaller? = nil
    ) -> DaemonReadinessState {
        guard isCurrent(token) else { return .superseded }
        state = outcome
        caller = newCaller
        return outcome
    }

    // MARK: Handshake

    /// Gate 3: run MCP `initialize` and require the daemon's own answer to match
    /// the descriptor it published, then gate 4's lifecycle notification.
    ///
    /// Five fields must agree:
    ///   - `protocolVersion`: the version the daemon actually negotiates.
    ///   - `serverInfo.name`: the contracted dispatcher identity.
    ///   - `serverInfo.version`: the descriptor's `binaryVersion` — catches a
    ///     stale descriptor left behind by an upgrade.
    ///   - `serverInfo.instanceIdentifier`: the process answering is the daemon
    ///     instance the descriptor named.
    ///   - `serverInfo.estateIdentifier`: that instance holds the estate the
    ///     descriptor named. Without these two, a compatible descriptor could be
    ///     satisfied by any conforming daemon holding any estate.
    ///
    /// A `tools` capability is also required: a daemon that does not serve the
    /// tool surface cannot answer anything a client would ask.
    private static func handshakeAgrees(_ caller: MootCaller, with descriptor: DaemonDescriptor) async -> Bool {
        let params: JSONValue = .object([
            "protocolVersion": .string(descriptor.mcpProtocolVersion),
            "capabilities": .object([:]),
            "clientInfo": .object([
                "name": .string(DaemonContract.providerIdentifier),
                "version": .string(descriptor.binaryVersion),
            ]),
        ])
        guard let response = try? await caller.exchange(method: "initialize", params: params),
              case .result(let value) = response.payload,
              let result = value.objectValue else { return false }

        guard result["protocolVersion"]?.stringValue == descriptor.mcpProtocolVersion else { return false }
        guard let serverInfo = result["serverInfo"]?.objectValue,
              serverInfo["name"]?.stringValue == DaemonContract.serverName,
              serverInfo["version"]?.stringValue == descriptor.binaryVersion,
              serverInfo["instanceIdentifier"]?.stringValue == descriptor.instanceIdentifier.uuidString,
              serverInfo["estateIdentifier"]?.stringValue == descriptor.estateIdentifier.uuidString
        else { return false }
        guard result["capabilities"]?.objectValue?["tools"] != nil else { return false }

        // Gate 4: MCP requires the client to confirm initialization before it
        // issues ordinary requests. It is a notification, so there is no reply
        // to check; a transport failure here fails the handshake.
        do {
            try await caller.notify(method: "notifications/initialized", params: nil)
        } catch {
            return false
        }
        return true
    }

    /// Gate 5: the dispatcher answers `ping` with a result rather than an error.
    ///
    /// Separate from `initialize`: that proves the daemon agrees about who it
    /// is, this proves it is currently serving. A daemon can pass the first and
    /// fail the second — mid-shutdown, or wedged behind a live socket.
    private static func pingSucceeds(_ caller: MootCaller) async -> Bool {
        guard let response = try? await caller.exchange(method: "ping", params: nil),
              case .result = response.payload else { return false }
        return true
    }
}
