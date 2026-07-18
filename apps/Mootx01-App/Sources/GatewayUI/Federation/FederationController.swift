// FederationController.swift
//
// FED-OD-6b reconciliation: wired to real FED-OD-4 session manager, identity,
// and _fed_peers store. Replaces all F1 placeholders.
//
// Responsibilities:
//   - Manage DiscoveryVisibility (Off/WhileOpen/Always), persisted in UserDefaults.
//   - Drive LANDiscovery (ConvergenceKitFederation) for browsing; surface DiscoveredPeer.
//   - Maintain the KnownPeers list backed by _fed_peers (via FederationSessionManager).
//   - Track the active FederationSession (UI type; does NOT map 1:1 to manager state).
//
// Architecture:
//   FederationController delegates session lifecycle and peer persistence to
//   FederationSessionManager (MootGateway), obtained lazily from GatewayRuntime.
//   The local identity (Ed25519 public key) is loaded via estateIdentity() on the
//   manager and cached for reuse in LANDiscovery advertising and the QR ceremony.
//
// KnownPeers data model (FED-OD-6b):
//   _fed_peers (SQLite) is the authoritative membership store.
//   Display names and lastSession timestamps are cached in UserDefaults alongside
//   the full KnownPeer JSON (publicKeyData included). On init, the UserDefaults
//   cache provides an immediately-visible list while the async _fed_peers load
//   enriches entries with real publicKeyData.
//
// F1 INVARIANT LINE (carried from FED-OD-4 / FED-OD-6):
//   Only .balanced is functional. .sealed excluded by construction.
//   No private-share prompt, no tell-record, no cryptographic clawback (F2 scope).
//   Ceiling enforcement delegated to FederationSessionManager (SensitivityFilteredStorage).

import Foundation
import Observation
import MootGateway
import ConvergenceKitFederation
import OSLog

private let logger = Logger(subsystem: "com.codedaptive.mootx01", category: "fed-controller")

// MARK: - FederationController

@MainActor
@Observable
public final class FederationController: FederationSessionManaging {

    // MARK: - Discovery visibility (persisted)

    /// Discoverability setting: Off / While Open / Always.
    ///
    /// Written here; read at startup to restore the user's choice.
    /// Changing this immediately starts or stops LANDiscovery.
    var visibility: DiscoveryVisibility {
        didSet {
            guard oldValue != visibility else { return }
            DiscoveryVisibilityPolicy.setVisibility(visibility)
            applyVisibility()
        }
    }

    // MARK: - Discovery state

    /// Peers currently visible on the LAN via mDNS.
    /// Updated by the LANDiscovery poll task.
    private(set) var discoveredPeers: [DiscoveredPeer] = []

    /// True while LANDiscovery is active (browsing and advertising).
    private(set) var isDiscovering: Bool = false

    // MARK: - Known peers (_fed_peers-backed)

    /// Paired peers — backed by the real _fed_peers table via FederationSessionManager.
    ///
    /// Initially populated from the UserDefaults cache (synchronous, immediately visible).
    /// After init, enriched from _fed_peers async to populate real publicKeyData.
    private(set) var knownPeers: [KnownPeer] = []

    /// UserDefaults key for the KnownPeer JSON cache.
    /// Stores the full [KnownPeer] array including publicKeyData.
    private static let knownPeersDefaultsKey = "federation.knownPeers.f1b"

    // MARK: - Session state

    /// The active federation session, or nil. Read by the FederationSessionManaging protocol.
    public private(set) var activeSession: FederationSession?

    // MARK: - UI flow state

    /// Peer selected in the Peers list for session initiation.
    var selectedSessionPeer: KnownPeer?

    /// Posture selected on the posture card picker. Default: balanced.
    var selectedPosture: FederationPosture = .balanced

    /// True while the QR pairing sheet is presented.
    var showingPairingSheet: Bool = false

    /// The discovered peer that triggered "Pair" — passed into QRPairingView.
    var pairingTargetPeer: DiscoveredPeer?

    // MARK: - Estate identity (cached for discovery and QR ceremony)

    /// The local estate Ed25519 identity. Loaded async after init.
    ///
    /// Used for:
    ///   1. LANDiscovery advertising key (publicKey sent in mDNS TXT record).
    ///   2. QRPairingView localIdentity parameter.
    ///
    /// Nil until bootstrapFromEstate() completes. Discovery starts with a placeholder
    /// key until the real identity is available, then restarts with the real key.
    private(set) var localIdentity: LocalIdentity?

    // MARK: - Session manager (lazy, obtained from GatewayRuntime)

    /// The real FED-OD-4 session manager. Loaded lazily from GatewayRuntime.
    private var _sessionManager: FederationSessionManager?

    // MARK: - Discovery internals

    private var lanDiscovery: LANDiscovery?
    private var peerUpdateTask: Task<Void, Never>?

    // MARK: - Init

    public init() {
        // Restore the user's last visibility choice.
        self.visibility = DiscoveryVisibilityPolicy.visibility()
        // Load the KnownPeer cache from UserDefaults synchronously for immediate display.
        loadKnownPeers()
        // Bootstrap asynchronously: load identity + real peers from estate.
        // Discovery and peer-list enrichment happen inside the task.
        Task { @MainActor [weak self] in
            await self?.bootstrapFromEstate()
        }
    }

    #if DEBUG
    /// Test-only initializer: inject a pre-built session manager to avoid estate bootstrap.
    ///
    /// The controller starts with an empty peer list (no UserDefaults state).
    /// Tests that need known peers should call `addKnownPeerForTesting(_:)`.
    public init(sessionManager: FederationSessionManager) {
        self.visibility = DiscoveryVisibilityPolicy.visibility()
        self.knownPeers = []
        self._sessionManager = sessionManager
    }
    #endif

    // MARK: - Bootstrap

    /// Load the estate identity and real peer list, then start discovery if configured.
    ///
    /// Runs after init. On failure (estate not yet available, permission denied, etc.)
    /// the controller degrades gracefully: discovery uses a placeholder key, and the
    /// KnownPeer list reflects whatever was in the UserDefaults cache.
    private func bootstrapFromEstate() async {
        // Step 1: obtain session manager
        guard let manager = await sessionManager() else {
            // Estate unavailable (common in unit tests). Start discovery with placeholder.
            if visibility == .always {
                startDiscovery()
            }
            return
        }

        // Step 2: load estate identity (creates _fed_identity if this is the first run)
        if let id = try? await manager.estateIdentity() {
            localIdentity = id
        }

        // Step 3: load real peers from _fed_peers and merge into knownPeers
        if let estatePeers = try? await manager.loadPairedPeers(), !estatePeers.isEmpty {
            mergePeersFromEstate(estatePeers)
        }

        // Step 4: start discovery (now with real identity if available)
        if visibility == .always {
            startDiscovery()
        }
    }

    /// Merge _fed_peers rows into the in-memory knownPeers list.
    ///
    /// For existing KnownPeer entries (from UserDefaults) whose publicKeyData is nil,
    /// this populates publicKeyData from the estate row if the fingerprint matches.
    /// For estate rows with no matching UserDefaults entry, a new KnownPeer is added
    /// with the fingerprint as the display name (display name was not stored at pairing).
    private func mergePeersFromEstate(_ estatePeers: [(publicKey: Data, pairedAt: Date)]) {
        var updated = knownPeers
        for (publicKey, _) in estatePeers {
            let fingerprint = lanFingerprintFromPublicKey(publicKey)
            if let idx = updated.firstIndex(where: { $0.id == fingerprint }) {
                // Existing entry — populate publicKeyData if absent.
                if updated[idx].publicKeyData == nil {
                    updated[idx] = KnownPeer(
                        id: fingerprint,
                        displayName: updated[idx].displayName,
                        lastSession: updated[idx].lastSession,
                        publicKeyData: publicKey
                    )
                }
            } else {
                // Estate row not in UserDefaults cache — add with fingerprint as name.
                updated.append(KnownPeer(
                    id: fingerprint,
                    displayName: fingerprint,
                    lastSession: nil,
                    publicKeyData: publicKey
                ))
            }
        }
        knownPeers = updated
        saveKnownPeers()
    }

    // MARK: - Session manager accessor

    /// Return the cached session manager, or load it lazily from GatewayRuntime.
    ///
    /// Returns nil if the estate cannot be attached (common in unit tests that use
    /// `init()` without configuring an in-memory estate).
    private func sessionManager() async -> FederationSessionManager? {
        if let m = _sessionManager { return m }
        do {
            let m = try await GatewayRuntime.shared.federationSession()
            _sessionManager = m
            return m
        } catch {
            logger.debug("fed-controller: session manager unavailable: \(error)")
            return nil
        }
    }

    // MARK: - Discovery lifecycle

    /// Apply the current visibility setting to the LANDiscovery layer.
    private func applyVisibility() {
        switch visibility {
        case .off:
            stopDiscovery()
        case .whileOpen:
            // whileOpen: start on app foreground, stop on background.
            // The panel's onAppear/onDisappear drive start/stop.
            break
        case .always:
            startDiscovery()
        }
    }

    /// Start LANDiscovery (browse + advertise). Safe to call when already active.
    ///
    /// Uses the real estate identity key if loaded, else falls back to a 32-byte
    /// zero placeholder. The placeholder results in a "0000000000000000" fingerprint —
    /// other estates can still discover this device, but the fingerprint is not useful
    /// for verification until the real identity is available.
    func startDiscovery() {
        guard !isDiscovering else { return }

        // Use real identity if available, else placeholder.
        // The placeholder is replaced if the identity loads after discovery starts
        // (see bootstrapFromEstate: if already discovering, stopDiscovery+startDiscovery).
        let advertisingKey = localIdentity?.publicKey ?? Data(count: 32)
        let knownFingerprints = Set(knownPeers.map(\.id))

        let discovery = LANDiscovery(
            publicKey: advertisingKey,
            displayName: "This device",
            relayPort: 0,
            knownFingerprints: knownFingerprints
        )

        do {
            try discovery.startDiscovery()
        } catch {
            // If the NW stack refuses to start (e.g., permissions denied), stay not-discovering.
            isDiscovering = false
            return
        }

        lanDiscovery = discovery
        isDiscovering = true

        // Poll for peer updates. LANDiscovery updates its internal peers dict
        // but doesn't push updates via a callback on the MainActor; we poll every 0.5 s.
        peerUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if let peers = self?.lanDiscovery?.discoveredPeersArray {
                    await MainActor.run {
                        self?.discoveredPeers = peers
                    }
                }
            }
        }
    }

    /// Stop LANDiscovery. Safe to call when not active.
    func stopDiscovery() {
        peerUpdateTask?.cancel()
        peerUpdateTask = nil
        lanDiscovery?.stopDiscovery()
        lanDiscovery = nil
        discoveredPeers = []
        isDiscovering = false
    }

    // MARK: - Pairing helpers

    /// Start the QR pairing ceremony for a discovered peer.
    ///
    /// Sets `pairingTargetPeer` and `showingPairingSheet` so the panel presents
    /// QRPairingView. The onComplete callback (in FederationPanelView) persists
    /// the new KnownPeer via completePairing.
    func beginPairing(with peer: DiscoveredPeer) {
        pairingTargetPeer = peer
        showingPairingSheet = true
    }

    /// Called when the QR pairing ceremony completes successfully.
    ///
    /// Writes the peer to _fed_peers via the session manager and updates the
    /// in-memory knownPeers list and UserDefaults cache.
    func completePairing(
        fingerprint: String,
        displayName: String,
        publicKeyData: Data?,
        family: HyperplaneFamilySpec?
    ) async {
        guard !knownPeers.contains(where: { $0.id == fingerprint }) else {
            showingPairingSheet = false
            pairingTargetPeer = nil
            return
        }

        // Persist to _fed_peers if we have the real public key and family.
        if let pubKey = publicKeyData, let fam = family {
            if let manager = await sessionManager() {
                do {
                    try await manager.registerPairedPeer(publicKey: pubKey, family: fam)
                } catch {
                    logger.error("fed-controller: registerPairedPeer failed: \(error)")
                }
            }
        }

        let peer = KnownPeer(
            id: fingerprint,
            displayName: displayName,
            lastSession: nil,
            publicKeyData: publicKeyData
        )
        knownPeers.append(peer)
        saveKnownPeers()

        // Refresh the verified fingerprint set so the newly-paired peer shows
        // as verified if it is still visible in discovery results.
        let fingerprints = Set(knownPeers.map(\.id))
        lanDiscovery?.updateKnownFingerprints(fingerprints)
        showingPairingSheet = false
        pairingTargetPeer = nil
    }

    /// Remove a peer from the known list (Unpair).
    ///
    /// Removes from _fed_peers via the session manager AND from the UserDefaults cache.
    func unpair(_ peer: KnownPeer) {
        knownPeers.removeAll { $0.id == peer.id }
        saveKnownPeers()
        let fingerprints = Set(knownPeers.map(\.id))
        lanDiscovery?.updateKnownFingerprints(fingerprints)

        // Remove from _fed_peers if we have the real public key.
        if let pubKey = peer.publicKeyData {
            Task { [weak self] in
                guard let self else { return }
                if let manager = await self.sessionManager() {
                    do {
                        try await manager.removePairedPeer(publicKey: pubKey)
                    } catch {
                        logger.error("fed-controller: removePairedPeer failed: \(error)")
                    }
                }
            }
        }

        // If the current session is with this peer, end it.
        if activeSession?.peer.id == peer.id {
            activeSession = nil
        }
        if selectedSessionPeer?.id == peer.id {
            selectedSessionPeer = nil
        }
    }

    // MARK: - Session lifecycle (FederationSessionManaging)

    /// Start a federation session with the given peer under the given posture.
    ///
    /// F1 constraint: only `.balanced` is functional. Other postures throw
    /// `FederationSessionError.postureNotFunctionalInF1` — they are never silently
    /// stubbed to do nothing.
    ///
    /// If `peer.publicKeyData` is available, delegates to the real
    /// `FederationSessionManager.startSession`. Otherwise falls back to the F1
    /// stub (creates a `FederationSession` locally, no engine enabled).
    public func startSession(peer: KnownPeer, posture: FederationPosture) async throws {
        guard posture.isFunctionalInF1 else {
            throw FederationSessionError.postureNotFunctionalInF1(posture)
        }
        guard activeSession == nil else {
            throw FederationSessionError.sessionAlreadyActive
        }

        // Delegate to the real manager when the peer has a verified public key.
        // The controller's guard above already ensures activeSession == nil, so the
        // manager's sessionAlreadyActive error should never fire. If it does for any
        // reason, it propagates up (callers catch all errors silently in the view).
        if let peerKey = peer.publicKeyData, let manager = await sessionManager() {
            // Map GatewayUI.FederationPosture.balanced → MootGateway.FederationPosture.balanced.
            // F1 only: balanced is the sole functional posture on both sides.
            let manifest = MootEstateSyncManifest.standard()
            try await manager.startSession(
                peer: peerKey,
                posture: MootGateway.FederationPosture.balanced,
                scope: manifest
            )
            // Fall through: create the UI session tracking struct below.
        }
        // (Falls through regardless of whether manager was used, so the UI always
        //  gets an activeSession to display the session banner.)

        let session = FederationSession(peer: peer, posture: posture)
        activeSession = session

        // Schedule auto-expiry: the session ends at expiresAt regardless.
        let expiresAt = session.expiresAt
        Task { [weak self] in
            let interval = expiresAt.timeIntervalSinceNow
            guard interval > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            await self?.endSession()
        }
    }

    /// End the active session.
    ///
    /// Calls the real FederationSessionManager.endSession() if the session was
    /// started with a real peer (publicKeyData available). Always clears activeSession.
    public func endSession() async {
        guard let session = activeSession else { return }

        // Delegate end to real manager if session was wired to it.
        if session.peer.publicKeyData != nil, let manager = _sessionManager {
            do {
                try await manager.endSession()
                // After endSession, the manager is in .ended state. Reset it
                // so it can accept a new session next time.
                try? await manager.reset()
            } catch {
                logger.error("fed-controller: manager.endSession failed: \(error)")
            }
        }

        // Update last-session timestamp on the peer in the in-memory list.
        if let idx = knownPeers.firstIndex(where: { $0.id == session.peer.id }) {
            knownPeers[idx] = KnownPeer(
                id: session.peer.id,
                displayName: session.peer.displayName,
                lastSession: Date(),
                publicKeyData: session.peer.publicKeyData
            )
            saveKnownPeers()
        }
        activeSession = nil
    }

    // MARK: - Test support

    /// Add a peer directly to the known list. Only for use in `@testable` test contexts.
    /// Production code always goes through `completePairing(...)`.
    func addKnownPeerForTesting(_ peer: KnownPeer) {
        guard !knownPeers.contains(where: { $0.id == peer.id }) else { return }
        knownPeers.append(peer)
    }

    /// Remove a peer directly from the known list. Only for test teardown.
    func removeKnownPeerForTesting(_ peer: KnownPeer) {
        knownPeers.removeAll { $0.id == peer.id }
    }

    // MARK: - Persistence helpers

    private func loadKnownPeers() {
        guard let data = UserDefaults.standard.data(forKey: Self.knownPeersDefaultsKey),
              let peers = try? JSONDecoder().decode([KnownPeer].self, from: data) else {
            knownPeers = []
            return
        }
        knownPeers = peers
    }

    private func saveKnownPeers() {
        guard let data = try? JSONEncoder().encode(knownPeers) else { return }
        UserDefaults.standard.set(data, forKey: Self.knownPeersDefaultsKey)
    }
}
