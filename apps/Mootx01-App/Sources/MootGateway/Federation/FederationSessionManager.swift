// FederationSessionManager.swift — MootGateway
//
// FED-OD-4: Federation Session Lifecycle — the on-demand window.
//
// A FederationSessionManager owns exactly ONE federation session at a time.
// It constructs and tears down the FederationSyncEngine + LANRelay pair that
// constitutes a session. The UI layer calls startSession/endSession; the session
// manager enforces the session-end ordering invariant.
//
// CUSTODY MODE MAPPING (FED-OD charter §V4 / custody-mode-mapping note):
//   F1's session-as-grant is equivalent to custody mode 1 (mediated per-access)
//   per the sharing model Appendix B.1. The session IS the mediation: the
//   originating estate controls access by controlling the LANRelay TLS channel
//   lifetime. When the session ends, access ends. No signed grant row exists in F1
//   (no _grants table until FED-OD-8 / F2). This mapping is the interim the
//   charter blessed — document it here so the F2 migration path is legible.
//
// SESSION-END INVARIANT (THE LOAD-BEARING REQUIREMENT — Kong adjudication):
//   endSession() closes the LANRelay TLS channel FIRST, then disables the engine.
//   See endSession() documentation for the full rationale. This ordering is NOT
//   subject to modification without a new Kong review.
//
// F1 INVARIANT LINE (what is NOT built here — must not ship until F2):
//   - No per-scope key minting or distribution
//   - No tell-record log entries (no grant ID to log against)
//   - No always-on mode or durable key handoff
//   - No re-share controls (even UI-only)
//   - No cryptographic clawback
//   - No private-share prompt
//   - No posture other than Balanced (the only functional F1 posture)
//   - Ceiling-only enforcement: secret-never-crosses + private-default-closed
//
// Perkins Amendment 1 enforcement:
//   startSession() wraps the estate storage in SensitivityFilteredStorage
//   BEFORE passing it to engine.enable(). The wrapper IS the exact handle the
//   engine receives — integrity-hook writes flow through the filtered observer
//   and are suppressed from the outbox if above-ceiling, so the ceiling holds
//   even for hook-originated writes. See SensitivityFilteredStorage.swift.

import Foundation
import ConvergenceKit
import ConvergenceKitFederation
import PersistenceKit
import LocusKit
import OSLog

private let logger = Logger(subsystem: "com.codedaptive.mootx01", category: "fed-session")

// MARK: - FederationPosture

/// The synchronization posture for a federation session.
///
/// F1 ships exactly ONE functional posture: `.balanced`.
/// All others are named for the F2/F3 chooser surface but are NOT functional
/// in F1 — invoking them in startSession throws `.postureUnavailable`.
///
/// Balanced F1 semantics: ceiling = `.elevated` (normal + elevated sync;
/// restricted + secret gated), single-session lifetime, no tell record,
/// no cryptographic clawback, no per-scope key, no re-share.
public enum FederationPosture: Sendable, Equatable {
    /// Ceiling-protected, session-bounded sharing. The only F1 functional posture.
    ///
    /// Scope: manifest granularity (all declared tables). Ceiling: .elevated.
    /// No tell record. No per-scope key. No clawback (session end only).
    case balanced

    // NOTE: The postures below are named for the F2/F3 chooser but are NOT
    // functional in F1. `startSession` throws .postureUnavailable if requested.
    // They are listed here so the API surface is stable across the F1→F2 upgrade.

    /// Durable grants + free re-share (F2+). NOT functional in F1.
    case open
    /// Relay link + long-decay key (F2+). NOT functional in F1.
    case convenient
    /// Cryptographic clawback + NFC touch (F2/F3+). NOT functional in F1.
    case locked
    /// UWB + physical-decay custody (F3+). NOT functional in F1.
    case inPerson
    /// Secret class; no key ever minted. NOT functional in any posture.
    case sealed
}

// MARK: - FederationSessionError

/// Errors produced by FederationSessionManager.
public enum FederationSessionError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A session is already active; endSession() must be called first.
    case sessionAlreadyActive
    /// No active session; startSession() must be called first.
    case noActiveSession
    /// The requested posture is not functional in F1 (requires F2 key spine).
    case postureUnavailable(FederationPosture)
    /// The storage bridge is unavailable.
    case storageBridgeUnavailable

    public var description: String {
        switch self {
        case .sessionAlreadyActive:
            return "FederationSessionManager: a session is already active — call endSession() before startSession()"
        case .noActiveSession:
            return "FederationSessionManager: no active session — call startSession() first"
        case .postureUnavailable(let posture):
            return "FederationSessionManager: posture '\(posture)' is not functional in F1; only .balanced is supported"
        case .storageBridgeUnavailable:
            return "FederationSessionManager: estate storage bridge is unavailable"
        }
    }
}

// MARK: - FederationSessionState

/// State machine for the federation session lifecycle.
///
/// Transitions: idle → active → ended.
/// After `ended`, the manager can be reset to `idle` by calling `reset()`.
/// No automatic re-use of ended sessions — each session is a distinct grant
/// window, even in F1 where grants are implicit.
public enum FederationSessionState: Sendable, Equatable {
    /// No session is active. `startSession()` transitions to `.active`.
    case idle
    /// A session is active. The `peerPublicKey` identifies the remote estate.
    case active(peerPublicKey: Data)
    /// The session has ended. Call `reset()` to return to `.idle`.
    case ended
}

// MARK: - FederationSessionManager

/// Manages the on-demand federation session lifecycle for one peer at a time.
///
/// A session is a bounded sync window: the user explicitly starts it (via
/// `startSession`) and explicitly ends it (via `endSession`). Between start
/// and end, the estate's storage is sync-enabled to the peer via a LANRelay
/// with a sensitivity ceiling of `.elevated` (Balanced posture, F1).
///
/// ## Session-End Ordering (the load-bearing invariant)
///
/// `endSession()` ALWAYS closes the LANRelay channel BEFORE disabling the engine.
/// See `endSession()` for the full rationale. This ordering is the session-end
/// invariant and must not be changed without a new Kong review.
///
/// ## F2 Migration Path
///
/// When F2 lands (FED-OD-8), `startSession` will:
///   1. Create a signed grant row in `_grants` (grantee, scope, terms, custody mode).
///   2. Derive a per-scope key and hand it to the peer (sign-then-encrypt-to-scope).
///   3. Begin logging tell-record events keyed to the grant ID.
///
/// The session lifecycle (enable/disable) is the durable abstraction; grants are
/// metadata layered on top. Nothing in F2 requires tearing out F1 code.
///
/// ## Usage
///
/// ```swift
/// let manager = FederationSessionManager(bridge: bridge)
/// try await manager.startSession(peer: peerKey, posture: .balanced, scope: manifest)
/// // ... sync window is open ...
/// try await manager.endSession()
/// ```
///
/// For production use, obtain the manager from `GatewayRuntime.shared.federationSession(bridge:)`.
/// For tests, inject a closable transport:
/// ```swift
/// let transport = ClosableInMemoryTransport()
/// let manager = FederationSessionManager(bridge: bridge, transport: transport)
/// ```
public actor FederationSessionManager {

    // MARK: - State

    /// Current session state.
    public private(set) var sessionState: FederationSessionState = .idle

    // MARK: - Internals

    /// The estate bridge used to obtain the live storage handle.
    private let bridge: MootBridge

    /// Active engine and relay (non-nil only in `.active` state).
    private var engine: FederationSyncEngine?
    private var lanRelay: LANRelay?

    /// Optional transport factory for dependency injection in tests.
    /// Production: builds a FakeLANRelayTransport (placeholder until LANRelayNWTransport ships).
    /// Tests: caller provides a ClosableInMemoryTransport or similar.
    private let transportFactory: @Sendable () -> any LANRelayTransport

    // MARK: - Init

    /// Create a session manager backed by the given estate bridge.
    ///
    /// - Parameters:
    ///   - bridge: The estate bridge. `startSession()` calls `bridge.estateStorage()`.
    ///   - transport: Optional pre-built transport for testing. When nil, the manager
    ///     constructs a `FakeLANRelayTransport` (F1 placeholder; production NW transport
    ///     ships in a later mission as `LANRelayNWTransport`).
    public init(bridge: MootBridge, transport: (any LANRelayTransport)? = nil) {
        self.bridge = bridge
        if let t = transport {
            self.transportFactory = { t }
        } else {
            // F1 placeholder: in-process loopback until LANRelayNWTransport ships.
            // For F1 production, pairing establishes trust; the session uses the
            // paired FederationSyncEngine path. This default is for single-device
            // integration flows until the NW transport is ready.
            self.transportFactory = { FakeLANRelayLoopbackTransport() }
        }
    }

    // MARK: - Session lifecycle

    /// Start a federation session with a peer.
    ///
    /// Constructs a `LANRelay` wired to the injected transport, creates a
    /// `FederationSyncEngine` backed by that relay, wraps the estate storage
    /// in `SensitivityFilteredStorage` at the session's sync ceiling, then
    /// enables the engine.
    ///
    /// **Perkins Amendment 1**: the `SensitivityFilteredStorage` wrapper is the
    /// EXACT handle passed to `engine.enable()`. Do not bypass this wrapper.
    ///
    /// **F1 only**: posture must be `.balanced`. All other postures throw
    /// `.postureUnavailable` — they require the F2 cryptographic spine.
    ///
    /// - Parameters:
    ///   - peerPublicKey: The 32-byte Ed25519 public key of the peer estate.
    ///   - posture: Must be `.balanced` in F1. Other values throw `.postureUnavailable`.
    ///   - scope: The `SyncManifest` describing which tables to sync. F1 scope
    ///     is manifest granularity (the whole declared table set).
    /// - Throws: `FederationSessionError.sessionAlreadyActive` if a session is
    ///   active. `FederationSessionError.postureUnavailable` for non-Balanced postures.
    public func startSession(
        peer peerPublicKey: Data,
        posture: FederationPosture = .balanced,
        scope manifest: SyncManifest
    ) async throws {
        // Guard: no concurrent sessions.
        guard sessionState == .idle else {
            throw FederationSessionError.sessionAlreadyActive
        }

        // F1 INVARIANT LINE: only Balanced is functional.
        // All other postures require the F2 grant spine (signed grants, per-scope keys,
        // tell record). They are named in FederationPosture for API stability but must
        // not be wired up in F1. See FED-OD charter §V5 for the invariant line table.
        guard posture == .balanced else {
            throw FederationSessionError.postureUnavailable(posture)
        }

        // Build transport and relay.
        let transport = transportFactory()
        let relay = LANRelay(transport: transport)

        // Build federation engine wired to this relay.
        let fedEngine = FederationSyncEngine(relay: relay)

        // Wrap estate storage with sensitivity ceiling (Perkins Amendment 1).
        // Ceiling = .elevated for Balanced posture:
        //   - normal + elevated rows sync freely (below or at ceiling)
        //   - restricted + secret rows are gated (above ceiling)
        // The wrapper IS the exact handle engine.enable() receives. This ensures
        // integrity-hook writes on above-ceiling rows flow through the filtered
        // observer and never enter the outbox (see SensitivityFilteredStorage.swift §header).
        let rawStorage = await bridge.estateStorage()
        let filteredStorage = SensitivityFilteredStorage(
            wrapping: rawStorage,
            ceiling: .elevated   // Balanced posture ceiling; the only F1 ceiling
        )

        // Enable the engine. This creates the federation side tables, loads or mints
        // the estate Ed25519 identity, reloads peers from _fed_peers, and starts the
        // outbound storage observer tasks.
        try await fedEngine.enable(manifest: manifest, storage: filteredStorage)

        // Store the active engine and relay.
        self.engine = fedEngine
        self.lanRelay = relay
        self.sessionState = .active(peerPublicKey: peerPublicKey)

        logger.info("federation: session started — peer \(peerPublicKey.prefix(4).hex, privacy: .public)… posture=balanced ceiling=elevated")
    }

    /// End the active federation session.
    ///
    /// ## SESSION-END INVARIANT (Kong's load-bearing requirement)
    ///
    /// This method closes the LANRelay TLS channel FIRST, then disables the engine.
    /// The ordering is not negotiable. Here is why:
    ///
    /// The durable `_fed_outbox` may hold queued envelopes at session-end that
    /// the push() cycle has not yet delivered. If we disabled the engine first,
    /// a racing push() could drain those entries into the still-open LANRelay
    /// channel — delivering envelopes to the peer inbox AFTER the user ended the
    /// session. The user believed the window was closed; it was not.
    ///
    /// Channel-close-first makes the race safe: once the transport channel is
    /// closed, any `relay.send()` call throws (`peerUnreachable` or
    /// `transportFailure`). The engine's push() cycle catches the throw and retains
    /// the outbox entry — the entry is NOT delivered. `engine.disable()` then
    /// cancels observer tasks, awaiting each to completion (see
    /// `FederationStateActor.disable()`), so no new outbox entries are added.
    ///
    /// Outbox entries retained at session-end are NOT discarded. They are durable
    /// (WC2) and will be delivered in the next session to the same peer, once a
    /// new session starts and push() cycles resume.
    ///
    /// - Throws: `FederationSessionError.noActiveSession` if no session is active.
    public func endSession() async throws {
        guard case .active = sessionState else {
            throw FederationSessionError.noActiveSession
        }

        // SESSION-END INVARIANT: close channel FIRST, THEN disable engine.
        // See full rationale in this method's documentation block above.
        lanRelay?.closeChannel()   // Step 1: close channel — subsequent sends throw
        try await engine?.disable() // Step 2: disable engine — cancel observers, stop writes

        logger.info("federation: session ended — channel closed, engine disabled")

        self.engine = nil
        self.lanRelay = nil
        self.sessionState = .ended
    }

    /// Reset the manager to `.idle` so a new session can be started.
    ///
    /// No-op if the manager is already `.idle`. Throws if a session is `.active`
    /// (call `endSession()` first).
    ///
    /// - Throws: `FederationSessionError.sessionAlreadyActive` if a session is active.
    public func reset() throws {
        switch sessionState {
        case .idle:
            return  // already idle
        case .active:
            throw FederationSessionError.sessionAlreadyActive
        case .ended:
            sessionState = .idle
        }
    }

    // MARK: - Push / Pull (pass-through)

    /// Push local outbox entries to the peer.
    ///
    /// Convenience pass-through for callers that want to drive push/pull
    /// without holding a reference to the underlying engine.
    @discardableResult
    public func push() async throws -> SyncReceipt {
        guard let engine else { throw FederationSessionError.noActiveSession }
        return try await engine.push()
    }

    /// Pull inbound envelopes from the peer's relay inbox.
    @discardableResult
    public func pull() async throws -> SyncReceipt {
        guard let engine else { throw FederationSessionError.noActiveSession }
        return try await engine.pull()
    }
}

// MARK: - FakeLANRelayLoopbackTransport (F1 in-process placeholder)

/// In-process loopback transport used when no external transport is injected.
///
/// This is the F1 production placeholder until `LANRelayNWTransport` ships (a later
/// mission). It behaves identically to `FakeL ANRelayTransport` in the kit's test
/// target: `send()` routes the envelope to the recipient's in-memory inbox;
/// `drain()` reads and clears that inbox.
///
/// For multi-estate federation (two running processes), this transport does nothing
/// useful — that requires the real NW transport. For single-device integration flows
/// (two in-process engine instances sharing this transport), it works correctly.
///
/// `close()` sets a flag that makes subsequent `send()` calls throw
/// `SyncError.peerUnreachable`, satisfying the channel-close-first invariant in
/// `FederationSessionManager.endSession()`.
///
/// NOT for use in unit tests that need deterministic inbox control — tests should
/// inject `ClosableInMemoryTransport` directly (defined in test files).
final class FakeLANRelayLoopbackTransport: LANRelayTransport, @unchecked Sendable {

    private let lock = NSLock()
    private var inboxes: [Data: [SignedEnvelope]] = [:]
    private var _closed = false

    func send(to peerPublicKey: Data, message: SignedEnvelope) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !_closed else {
            throw SyncError.peerUnreachable(
                identity: peerPublicKey.prefix(4).map { String(format: "%02x", $0) }.joined() + "…"
            )
        }
        inboxes[peerPublicKey, default: []].append(message)
    }

    func drain(for recipientPublicKey: Data) -> [SignedEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        let msgs = inboxes[recipientPublicKey] ?? []
        inboxes[recipientPublicKey] = []
        return msgs
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        _closed = true
    }
}

// MARK: - Data hex helper

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
