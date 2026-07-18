// FederationPanelView.swift
//
// FED-OD-6: Federation UI panel — the user-facing surface for LAN discovery,
// proximity pairing, posture selection, and session management.
//
// Panel regions (per decision doc §5):
//   1. VISIBILITY  — Off / While Open / Always discoverability toggle.
//   2. NEARBY      — Discovered estates; verified badge when paired; Pair button.
//   3. PEERS       — _fed_peers list: name, last session, Unpair.
//   4. START SESSION — Peer picker, posture cards, live session banner.
//
// F1 functional subset (FED-OD-6):
//   • Balanced posture actually starts a session.
//   • Other postures render VISIBLY LOCKED: disabled, lock icon, "coming soon" hint.
//     They never silently do nothing — the locked affordance is structural.
//   • No private-share prompt (F2 scope).
//   • No tell-record viewer (F2 scope).
//   • Secret has no UI — FederationPosture.allCases excludes Sealed.
//
// Localization: every user-visible string via String(localized:).
// Layout: .leading / .trailing only — no .left / .right.
// A11y: .accessibilityLabel + .accessibilityHint on every interactive element.
//       Countdown announces via .accessibilityValue updates.
//       44pt minimum touch targets enforced via .frame(minHeight: 44).

import SwiftUI
import MootGateway
import ConvergenceKitFederation

// MARK: - FederationPanelView

/// The top-level Federation panel. Shared by the Engine tab on all platforms.
public struct FederationPanelView: View {

    @State private var controller = FederationController()
    @State private var showingEndSessionConfirm = false

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "federation.panel.title",
                            defaultValue: "Federation"))
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                visibilityRegion
                nearbyRegion
                peersRegion

                if controller.activeSession != nil {
                    sessionBanner
                } else {
                    startSessionRegion
                }
            }
            .padding(20)
        }
        .onAppear {
            // whileOpen: start discovery when the panel becomes visible.
            if controller.visibility == .whileOpen {
                controller.startDiscovery()
            }
        }
        .onDisappear {
            // whileOpen: stop when panel leaves (app backgrounded or tab switch).
            if controller.visibility == .whileOpen {
                controller.stopDiscovery()
            }
        }
        .sheet(isPresented: $controller.showingPairingSheet) {
            pairingSheet
        }
    }

    // MARK: - 1. Visibility Region

    private var visibilityRegion: some View {
        GroupBox(String(localized: "federation.visibility.title",
                        defaultValue: "Discoverability")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "federation.visibility.description",
                            defaultValue: "Controls when other Mootx01 estates can find this one on your local network. Discovery never implies trust — pairing is always a separate step."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Three-position segmented control mirroring AirDrop's Off/Contacts/Everyone.
                Picker(
                    String(localized: "federation.visibility.picker.label",
                           defaultValue: "Discoverability"),
                    selection: $controller.visibility
                ) {
                    Text(String(localized: "federation.visibility.off",
                                defaultValue: "Off"))
                        .tag(DiscoveryVisibility.off)
                    Text(String(localized: "federation.visibility.whileopen",
                                defaultValue: "While Open"))
                        .tag(DiscoveryVisibility.whileOpen)
                    Text(String(localized: "federation.visibility.always",
                                defaultValue: "Always"))
                        .tag(DiscoveryVisibility.always)
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(String(localized: "federation.visibility.picker.a11y.label",
                                           defaultValue: "Discoverability mode"))
                .accessibilityHint(String(localized: "federation.visibility.picker.a11y.hint",
                                          defaultValue: "Off hides this device. While Open discovers when the app is active. Always discovers continuously."))

                HStack(spacing: 6) {
                    Circle()
                        .fill(controller.isDiscovering ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(controller.isDiscovering
                         ? String(localized: "federation.visibility.status.discovering",
                                   defaultValue: "Discovering")
                         : String(localized: "federation.visibility.status.idle",
                                   defaultValue: "Not discovering"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(controller.isDiscovering
                            ? String(localized: "federation.visibility.status.a11y.on",
                                     defaultValue: "Discovery is active")
                            : String(localized: "federation.visibility.status.a11y.off",
                                     defaultValue: "Discovery is not active"))
                }
            }
            .padding(6)
        }
    }

    // MARK: - 2. Nearby Region

    private var nearbyRegion: some View {
        GroupBox(String(localized: "federation.nearby.title",
                        defaultValue: "Nearby")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "federation.nearby.description",
                            defaultValue: "Mootx01 estates visible on this network. A badge means you have previously paired with that estate. Enable discoverability above to start browsing."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if controller.discoveredPeers.isEmpty {
                    Text(controller.isDiscovering
                         ? String(localized: "federation.nearby.scanning",
                                   defaultValue: "Scanning for nearby estates…")
                         : String(localized: "federation.nearby.empty",
                                   defaultValue: "No nearby estates. Enable discoverability to browse."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(controller.discoveredPeers, id: \.fingerprint) { peer in
                        NearbyPeerRow(peer: peer, controller: controller)
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - 3. Peers Region

    private var peersRegion: some View {
        GroupBox(String(localized: "federation.peers.title",
                        defaultValue: "Paired Peers")) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "federation.peers.description",
                            defaultValue: "Estates you have paired with. Only paired peers can start a session."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if controller.knownPeers.isEmpty {
                    Text(String(localized: "federation.peers.empty",
                                defaultValue: "No paired peers yet. Use the Pair button in Nearby to pair a device."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(controller.knownPeers) { peer in
                        KnownPeerRow(peer: peer, controller: controller)
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - 4. Start Session Region

    private var startSessionRegion: some View {
        GroupBox(String(localized: "federation.startsession.title",
                        defaultValue: "Start Session")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "federation.startsession.description",
                            defaultValue: "Choose a paired peer and a sharing posture, then start a time-boxed session. Your key expires when the session ends."))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Peer picker (only known peers can be in a session)
                if controller.knownPeers.isEmpty {
                    Text(String(localized: "federation.startsession.nopeer",
                                defaultValue: "Pair with a peer first."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    peerPicker
                }

                // Posture cards
                Text(String(localized: "federation.posture.chooser.label",
                            defaultValue: "Sharing posture"))
                    .font(.caption.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)

                postureCardGrid

                // Start button — disabled until a peer and posture are selected.
                // Only Balanced is enabled in F1; other postures are locked.
                let canStart = controller.selectedSessionPeer != nil
                               && controller.selectedPosture.isFunctionalInF1
                Button {
                    Task { await startSession() }
                } label: {
                    Text(String(localized: "federation.startsession.button",
                                defaultValue: "Start Session"))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)   // 44pt minimum touch target
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
                .accessibilityLabel(String(localized: "federation.startsession.button.a11y.label",
                                           defaultValue: "Start session"))
                .accessibilityHint(canStart
                    ? String(localized: "federation.startsession.button.a11y.hint.ready",
                             defaultValue: "Starts a Balanced session with the selected peer.")
                    : String(localized: "federation.startsession.button.a11y.hint.disabled",
                             defaultValue: "Select a paired peer to enable."))
            }
            .padding(6)
        }
    }

    private var peerPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "federation.startsession.peer.label",
                        defaultValue: "Peer"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker(
                String(localized: "federation.startsession.peer.picker.label",
                       defaultValue: "Select peer"),
                selection: $controller.selectedSessionPeer
            ) {
                Text(String(localized: "federation.startsession.peer.placeholder",
                            defaultValue: "Choose a peer"))
                    .tag(Optional<KnownPeer>.none)
                ForEach(controller.knownPeers) { peer in
                    Text(peer.displayName).tag(Optional<KnownPeer>.some(peer))
                }
            }
            .accessibilityLabel(String(localized: "federation.startsession.peer.picker.a11y.label",
                                       defaultValue: "Select a paired peer to session with"))
        }
    }

    private var postureCardGrid: some View {
        // Vertical stack of posture cards — one per case (Sealed excluded by construction).
        VStack(spacing: 8) {
            ForEach(FederationPosture.allCases) { posture in
                PostureCard(
                    posture: posture,
                    isSelected: controller.selectedPosture == posture,
                    onTap: {
                        // Locked postures: tapping them tells the user WHY they're locked.
                        // They do NOT silently change the selection.
                        if posture.isFunctionalInF1 {
                            controller.selectedPosture = posture
                        }
                        // Locked: the card itself shows the affordance; nothing changes.
                    }
                )
            }
        }
    }

    // MARK: - Live Session Banner

    private var sessionBanner: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text(String(localized: "federation.session.banner.title",
                                defaultValue: "Session Active"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    // Countdown timer
                    if let session = controller.activeSession {
                        SessionCountdown(expiresAt: session.expiresAt)
                    }
                }

                if let session = controller.activeSession {
                    // Who
                    HStack(spacing: 4) {
                        Text(String(localized: "federation.session.peer.label",
                                    defaultValue: "With:"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(session.peer.displayName)
                            .font(.caption.weight(.semibold))
                    }

                    // What's crossing (plain language, posture-derived)
                    Text(session.whatsCrossing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            String(localized: "federation.session.whatscrossing.a11y",
                                   defaultValue: "What is crossing: \(session.whatsCrossing)"))
                }

                // Prominent End Session button
                Button(role: .destructive) {
                    showingEndSessionConfirm = true
                } label: {
                    Text(String(localized: "federation.session.end.button",
                                defaultValue: "End Session"))
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .accessibilityLabel(String(localized: "federation.session.end.button.a11y.label",
                                           defaultValue: "End session"))
                .accessibilityHint(String(localized: "federation.session.end.button.a11y.hint",
                                          defaultValue: "Ends the active federation session. The peer's key expires immediately."))
                .confirmationDialog(
                    String(localized: "federation.session.end.confirm.title",
                           defaultValue: "End Session?"),
                    isPresented: $showingEndSessionConfirm,
                    titleVisibility: .visible
                ) {
                    Button(
                        String(localized: "federation.session.end.confirm.button",
                               defaultValue: "End Session"),
                        role: .destructive
                    ) {
                        Task { await controller.endSession() }
                    }
                    Button(
                        String(localized: "federation.session.end.confirm.cancel",
                               defaultValue: "Cancel"),
                        role: .cancel
                    ) {}
                } message: {
                    Text(String(localized: "federation.session.end.confirm.message",
                                defaultValue: "Ending the session expires the peer's key. They will no longer be able to read your shared memories."))
                }
            }
            .padding(6)
        }
    }

    // MARK: - QR Pairing Sheet

    /// The pairing sheet content. Presents the real QRPairingView using the estate
    /// identity loaded by FederationController.bootstrapFromEstate().
    ///
    /// Role: .proposer (this device shows its QR code for the peer to scan).
    /// The back-channel from acceptor → proposer (relay or second QR scan) is the
    /// genuinely-hardware-gated seam: ProposerQRDisplayView.onAcceptorPayloadReceived
    /// fires when the acceptor's response arrives, but the relay transport
    /// (LANRelayNWTransport) ships in a later mission. Until then, the proposer side
    /// displays the QR and awaits relay delivery.
    ///
    /// Camera seam (P6): AcceptorQRScanView.onPayloadScanned requires AVCaptureSession
    /// integration in the app target (platform-specific). The coordinator logic and
    /// handleScannedPayload path are fully implemented; the hardware wiring is the
    /// remaining gap.
    @ViewBuilder
    private var pairingSheet: some View {
        if let targetPeer = controller.pairingTargetPeer {
            // Use the real estate identity if already loaded; fall back to a fresh
            // ephemeral identity if bootstrap hasn't completed. The fallback identity
            // is valid for the ceremony but is NOT the persistent estate key — callers
            // should await bootstrapFromEstate() before presenting the pairing sheet
            // in production flows.
            let identity = controller.localIdentity ?? LocalIdentity()
            // Fresh random family seed per ceremony. Both sides end up with the same
            // family via the QR proposal (proposer encodes it; acceptor echoes it back).
            let familySeed = UInt64.random(in: .min ... .max)
            let family = HyperplaneFamilySpec(seed: familySeed)

            QRPairingView(
                localIdentity: identity,
                family: family,
                role: .proposer,
                onComplete: { confirmation, peerPublicKey in
                    let fingerprint = lanFingerprintFromPublicKey(peerPublicKey)
                    await controller.completePairing(
                        fingerprint: fingerprint,
                        displayName: targetPeer.displayName,
                        publicKeyData: peerPublicKey,
                        family: confirmation.family
                    )
                },
                onCancel: {
                    controller.showingPairingSheet = false
                    controller.pairingTargetPeer = nil
                }
            )
        } else {
            // Should not reach — sheet is only shown when pairingTargetPeer is set.
            EmptyView()
        }
    }

    // MARK: - Session helpers

    private func startSession() async {
        guard let peer = controller.selectedSessionPeer else { return }
        do {
            try await controller.startSession(peer: peer, posture: controller.selectedPosture)
        } catch {
            // F1: only .balanced is enabled; the button is disabled for locked postures.
            // If we still hit an error, it's a logic guard — surface nothing to the user.
        }
    }
}

// MARK: - NearbyPeerRow

private struct NearbyPeerRow: View {
    let peer: DiscoveredPeer
    let controller: FederationController

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(peer.displayName)
                        .font(.caption.weight(.semibold))
                    if peer.isVerified {
                        // Verified badge: fingerprint matches a known _fed_peers entry.
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .accessibilityLabel(
                                String(localized: "federation.nearby.verified.badge.a11y",
                                       defaultValue: "Paired"))
                    }
                }
                Text(peer.fingerprint)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if peer.isVerified {
                Text(String(localized: "federation.nearby.paired.label",
                            defaultValue: "Paired"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(String(localized: "federation.nearby.pair.button",
                              defaultValue: "Pair")) {
                    controller.beginPairing(with: peer)
                }
                .font(.caption)
                .frame(minHeight: 44)
                .accessibilityLabel(
                    String(localized: "federation.nearby.pair.button.a11y.label",
                           defaultValue: "Pair with \(peer.displayName)"))
                .accessibilityHint(
                    String(localized: "federation.nearby.pair.button.a11y.hint",
                           defaultValue: "Opens the pairing ceremony to establish a trusted link with this estate."))
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            peer.isVerified
            ? String(localized: "federation.nearby.row.a11y.paired",
                     defaultValue: "\(peer.displayName), paired estate")
            : String(localized: "federation.nearby.row.a11y.unpaired",
                     defaultValue: "\(peer.displayName), not paired"))
    }
}

// MARK: - KnownPeerRow

private struct KnownPeerRow: View {
    let peer: KnownPeer
    let controller: FederationController

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(.caption.weight(.semibold))
                if let lastSession = peer.lastSession {
                    Text(String(localized: "federation.peers.lastsession",
                                defaultValue: "Last session: \(lastSession.formatted(.relative(presentation: .named)))"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text(String(localized: "federation.peers.nosession",
                                defaultValue: "No session yet"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(String(localized: "federation.peers.unpair.button",
                          defaultValue: "Unpair")) {
                controller.unpair(peer)
            }
            .font(.caption)
            .foregroundStyle(.red)
            .frame(minHeight: 44)
            .accessibilityLabel(
                String(localized: "federation.peers.unpair.button.a11y.label",
                       defaultValue: "Unpair \(peer.displayName)"))
            .accessibilityHint(
                String(localized: "federation.peers.unpair.button.a11y.hint",
                       defaultValue: "Removes this estate from your paired peers. You will need to pair again to start a session."))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(localized: "federation.peers.row.a11y",
                   defaultValue: "\(peer.displayName). \(peer.lastSession.map { "Last session \($0.formatted(.relative(presentation: .named)))." } ?? "No session yet.")"))
    }
}

// MARK: - PostureCard

/// A single posture card from the risk-level chooser (sharing model §11).
///
/// Balanced: selectable, active, visually prominent.
/// Other postures: visually locked — disabled, lock icon, "coming soon" hint.
/// A locked card NEVER silently pretends to be functional.
private struct PostureCard: View {
    let posture: FederationPosture
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(posture.cardTitle)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if posture.isFunctionalInF1 {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    } else {
                        // Lock affordance: honest visual for unavailable posture.
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }

                Text(posture.cardWhatCrosses)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 12) {
                    Label {
                        Text(posture.cardLifetime)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .accessibilityHidden(true)
                    }
                }

                if !posture.isFunctionalInF1 {
                    Text(String(localized: "federation.posture.card.locked.hint",
                                defaultValue: "Requires the grant system — coming in a future release."))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .overlay(cardBorder)
            .opacity(posture.isFunctionalInF1 ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!posture.isFunctionalInF1)
        .accessibilityLabel(posture.cardAccessibilityLabel)
        .accessibilityAddTraits(isSelected && posture.isFunctionalInF1 ? .isSelected : [])
        .accessibilityHint(
            posture.isFunctionalInF1
            ? String(localized: "federation.posture.card.enabled.a11y.hint",
                     defaultValue: "Tap to select this sharing posture.")
            : String(localized: "federation.posture.card.locked.a11y.hint",
                     defaultValue: "Not available in this release."))
    }

    @ViewBuilder
    private var cardBackground: some View {
        if isSelected && posture.isFunctionalInF1 {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.1))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        }
    }

    @ViewBuilder
    private var cardBorder: some View {
        if isSelected && posture.isFunctionalInF1 {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 1.5)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
    }
}

// MARK: - SessionCountdown

/// A live countdown timer displaying time remaining in the active session.
///
/// Announces time remaining to VoiceOver via .accessibilityValue so screen
/// reader users hear "15 minutes remaining" without watching the clock.
private struct SessionCountdown: View {
    let expiresAt: Date

    @State private var remaining: TimeInterval = 0
    @State private var displayText: String = ""

    var body: some View {
        Text(displayText)
            .font(.caption.monospaced())
            .foregroundStyle(remaining < 300 ? .red : .secondary)
            // VoiceOver: announces remaining time when the value changes.
            // The 60-second update cadence avoids flooding assistive tech.
            .accessibilityLabel(String(localized: "federation.session.countdown.a11y.label",
                                       defaultValue: "Time remaining"))
            .accessibilityValue(accessibilityRemainingText)
            .onAppear { updateDisplay() }
            .task {
                // Update every second while the banner is visible.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    updateDisplay()
                }
            }
    }

    private func updateDisplay() {
        remaining = max(0, expiresAt.timeIntervalSinceNow)
        let mins = Int(remaining) / 60
        let secs = Int(remaining) % 60
        displayText = String(format: "%02d:%02d", mins, secs)
    }

    private var accessibilityRemainingText: String {
        let mins = Int(max(0, remaining)) / 60
        if mins > 0 {
            return String(localized: "federation.session.countdown.a11y.minutes",
                          defaultValue: "\(mins) minutes remaining")
        } else {
            return String(localized: "federation.session.countdown.a11y.ending",
                          defaultValue: "Session ending")
        }
    }
}
