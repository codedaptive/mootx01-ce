// FederationController.swift
//
// FED-OD-6: Observable state machine for the Federation panel.
//
// Responsibilities:
//   - Manage DiscoveryVisibility (Off/WhileOpen/Always), persisted in UserDefaults.
//   - Drive LANDiscovery (ConvergenceKitFederation) for browsing; surface DiscoveredPeer.
//   - Maintain the KnownPeers list (F1 stub: UserDefaults; FED-OD-4: _fed_peers).
//   - Track the active FederationSession.
//
// Architecture:
//   LANDiscovery instances require a local Ed25519 public key for advertising.
//   At F1, this key is unavailable from the GatewayUI layer (the engine identity
//   surface is scoped to MootGateway, not GatewayUI). FederationController stubs
//   advertising with a placeholder key and marks the RECONCILIATION site below.
//   Browsing (finding other estates) works without the local key.
//
// RECONCILIATION NOTE:
//   Replace `Data(count: 32)` advertising key with the real estate Ed25519
//   public key once FED-OD-4 wires it through GatewayRuntime / AppModel.

import Foundation
import Observation
import ConvergenceKitFederation

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
    /// Updated by LANDiscovery's peer-found callback.
    private(set) var discoveredPeers: [DiscoveredPeer] = []

    /// True while LANDiscovery is active (browsing and advertising).
    private(set) var isDiscovering: Bool = false

    // MARK: - Known peers (F1: UserDefaults-backed stub)

    /// Paired peers — _fed_peers in FED-OD-4's real implementation.
    ///
    /// F1 stub: stored as JSON in UserDefaults under the key below.
    /// FED-OD-4 replaces this with ConvergenceKitFederation's PairingRecord store.
    private(set) var knownPeers: [KnownPeer] = []

    // UserDefaults key for the F1 known-peers list.
    private static let knownPeersDefaultsKey = "federation.knownPeers.f1"

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

    // MARK: - Discovery internals

    private var lanDiscovery: LANDiscovery?
    private var peerUpdateTask: Task<Void, Never>?

    // MARK: - Init

    public init() {
        // Restore the user's last visibility choice.
        // DiscoveryVisibilityPolicy reads UserDefaults.standard.
        self.visibility = DiscoveryVisibilityPolicy.visibility()
        loadKnownPeers()
        // Discovery starts if the persisted setting is non-off. The whileOpen
        // case is managed by the panel's onAppear/onDisappear hooks.
        if visibility == .always {
            startDiscovery()
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
            // If discovery is currently running, continue; lifecycle calls will manage it.
            break
        case .always:
            startDiscovery()
        }
    }

    /// Start LANDiscovery (browse + advertise). Safe to call when already active.
    func startDiscovery() {
        guard !isDiscovering else { return }

        // F1 RECONCILIATION: Use a zero-byte placeholder for the local public key.
        // The advertising fingerprint will be "0000000000000000" — not useful for
        // other estates to verify us. Browsing (finding others) works correctly.
        // FED-OD-4 will inject the real Ed25519 public key from GatewayRuntime.
        let placeholderPublicKey = Data(count: 32)
        let knownFingerprints = Set(knownPeers.map(\.id))

        let discovery = LANDiscovery(
            publicKey: placeholderPublicKey,
            displayName: "This device",
            relayPort: 0,
            knownFingerprints: knownFingerprints
        )

        do {
            try discovery.startDiscovery()
        } catch {
            // If the NW stack refuses to start (e.g., permissions denied), surface
            // the error in a log and stay in the not-discovering state.
            // The user sees no peers and the circle indicator stays grey.
            isDiscovering = false
            return
        }

        lanDiscovery = discovery
        isDiscovering = true

        // Poll for peer updates. LANDiscovery updates its internal peers dict
        // but doesn't push updates via a callback on the MainActor; we poll.
        // FED-OD-4 can replace this with an async stream from the real stack.
        peerUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 s poll
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
    /// the new KnownPeer.
    func beginPairing(with peer: DiscoveredPeer) {
        pairingTargetPeer = peer
        showingPairingSheet = true
    }

    /// Called when the QR pairing ceremony completes successfully.
    ///
    /// Adds the peer to the known list and refreshes LANDiscovery's fingerprint set
    /// so the newly-paired peer shows as verified on next scan.
    func completePairing(fingerprint: String, displayName: String) {
        let peer = KnownPeer(id: fingerprint, displayName: displayName)
        guard !knownPeers.contains(where: { $0.id == fingerprint }) else { return }
        knownPeers.append(peer)
        saveKnownPeers()
        // Refresh the verified fingerprint set so the newly-paired peer shows
        // as verified if it is still visible in the discovery results.
        let fingerprints = Set(knownPeers.map(\.id))
        lanDiscovery?.updateKnownFingerprints(fingerprints)
        showingPairingSheet = false
        pairingTargetPeer = nil
    }

    /// Remove a peer from the known list (Unpair).
    func unpair(_ peer: KnownPeer) {
        knownPeers.removeAll { $0.id == peer.id }
        saveKnownPeers()
        let fingerprints = Set(knownPeers.map(\.id))
        lanDiscovery?.updateKnownFingerprints(fingerprints)
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
    public func startSession(peer: KnownPeer, posture: FederationPosture) async throws {
        guard posture.isFunctionalInF1 else {
            throw FederationSessionError.postureNotFunctionalInF1(posture)
        }
        guard activeSession == nil else {
            throw FederationSessionError.sessionAlreadyActive
        }
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
    public func endSession() async {
        guard let session = activeSession else { return }
        // Update last-session timestamp on the peer.
        if let idx = knownPeers.firstIndex(where: { $0.id == session.peer.id }) {
            knownPeers[idx] = KnownPeer(
                id: session.peer.id,
                displayName: session.peer.displayName,
                lastSession: Date()
            )
            saveKnownPeers()
        }
        activeSession = nil
    }

    // MARK: - Test support

    /// Add a peer directly to the known list. Only for use in `@testable` test contexts.
    /// Production code always goes through `completePairing(fingerprint:displayName:)`.
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
