// QRPairingView.swift
//
// FED-OD-3: QR pairing ceremony views.
// FED-OD-5: UWB proximity "touch the tips" enhancement (additive).
//
// Scope note: this file provides the structural scaffolding for the QR
// ceremony UI. The full interactive panel (Nearby peers, discovery toggle,
// session banner) is FED-OD-6 scope. This file wires QRPairingCoordinator
// to the display + scan surfaces and hands off to SASConfirmationView.
//
// FED-OD-5 additions (UWB — strictly additive, no QR regressions):
//   - If the device supports UWB (U1/U3 chip, iPhone 11+), a "hold devices
//     together" affordance overlays the QR/scan phases.
//   - When both devices are within ~10 cm, the UWB transport exchanges the
//     QRPairingPayload and QRAcceptorPayload — the SAME types the QR path uses.
//   - All crypto (X25519, SAS derivation, _fed_peers gate) is unchanged;
//     it runs identically whether the payload transport was QR or UWB.
//   - On non-UWB devices, the UWB UI is absent; QR is the sole path.
//   - SAS confirmation is ALWAYS required — proximity does NOT skip code-compare.
//
// UWB injection seam (for tests):
//   Pass a UWBCapabilityChecking and optional UWBPairingTransporting in the
//   init. Tests pass a fake checker returning false (non-UWB path, no transport
//   started) or a fake transport (UWB path, direct event injection).
//
// Localization: all user-visible strings use String(localized:) per the
// project localization rule.

import SwiftUI
import MootGateway
import ConvergenceKit
import ConvergenceKitFederation

// MARK: - QRPairingView

/// Entry point for the QR pairing ceremony, with optional UWB proximity enhancement.
///
/// Shows one of two faces depending on the user's role:
///   - Proposer: displays a QR code (device A, initiating side)
///   - Acceptor: shows a camera scanner to scan A's QR (device B)
///
/// After the QR exchange completes, transitions to SASConfirmationView.
/// If UWB is available, an additional "hold devices together" affordance is shown
/// and auto-fires the payload exchange when both devices are within ~10 cm.
///
/// Usage (QR-only, the default):
/// ```swift
/// QRPairingView(
///     localIdentity: identity,
///     family: HyperplaneFamilySpec(seed: 42),
///     role: .proposer,
///     onComplete: { confirmation, peerKey in
///         try await engine.acceptPairingProposal(confirmation.proposal!, ...)
///     },
///     onCancel: { /* dismiss */ }
/// )
/// ```
///
/// Usage (custom UWB seam for tests):
/// ```swift
/// QRPairingView(
///     localIdentity: identity,
///     family: family,
///     role: .acceptor,
///     uwbCapabilityChecker: FakeUWBCapabilityChecker(supports: false),
///     onComplete: { _, _ in },
///     onCancel: { }
/// )
/// ```
public struct QRPairingView: View {

    public enum Role {
        /// This device initiates the pairing and displays a QR code.
        case proposer
        /// This device scans the proposer's QR code.
        case acceptor
    }

    let localIdentity: LocalIdentity
    let family: HyperplaneFamilySpec
    let role: Role
    /// Called when SAS is confirmed. Carries the `SASConfirmation` token and the
    /// 32-byte Ed25519 public key of the remote peer — the peer key is captured during
    /// the ceremony:
    ///   - Proposer side: from `QRAcceptorPayload.identityPublicKey` (acceptor's key).
    ///   - Acceptor side: from `QRPairingPayload.identityPublicKey` (proposer's key).
    let onComplete: (SASConfirmation, Data) async throws -> Void
    let onCancel: () -> Void

    // FED-OD-5: UWB capability and transport seam.
    //
    // uwbEnabled is derived from the capability checker at init time. The transport
    // is nil on non-UWB devices and in non-UWB tests.
    //
    // Design: stored as `let` on the view struct. @State is used for mutable derived
    // state (uwbProximityReady). The transport is a class reference; Swift value
    // capture semantics mean re-creation of the view struct shares the same transport.
    let uwbEnabled: Bool
    let uwbTransport: (any UWBPairingTransporting)?

    @State private var coordinator = QRPairingCoordinator()
    @State private var phase: Phase = .initializing
    @State private var qrPayload: QRPairingPayload? = nil
    @State private var qrImageData: Data? = nil
    @State private var sasPattern: [SASEntry] = []
    @State private var pendingConfirmation: SASConfirmation? = nil
    @State private var errorMessage: String? = nil
    /// The 32-byte Ed25519 public key of the remote peer, captured during ceremony.
    /// Set in handleAcceptorResponse (proposer) or handleScannedPayload (acceptor).
    /// Non-nil when the SAS confirmation fires; used as the second argument to onComplete.
    @State private var remotePeerPublicKey: Data? = nil
    /// FED-OD-5: true when UWB transport confirmed proximity ≤ 10 cm.
    /// Used to show a "Devices are close — exchanging…" affordance in the UI.
    @State private var uwbProximityReady: Bool = false

    enum Phase {
        case initializing
        case showingQR             // proposer: QR displayed
        case scanningQR            // acceptor: camera active
        case showingSAS            // both: SAS displayed, awaiting user confirmation
        case complete
        case failed(String)
    }

    // MARK: - Init

    /// Standard init with optional UWB seam for tests.
    ///
    /// - Parameters:
    ///   - uwbCapabilityChecker: Checks whether the device supports UWB proximity
    ///     pairing. Default: `LiveUWBCapabilityChecker()` (queries NI on iOS).
    ///   - uwbTransport: Optional transport override. Default: nil — the live
    ///     transport is created automatically when `uwbCapabilityChecker` returns
    ///     true. Pass a fake for testing.
    public init(
        localIdentity: LocalIdentity,
        family: HyperplaneFamilySpec,
        role: Role,
        uwbCapabilityChecker: any UWBCapabilityChecking = LiveUWBCapabilityChecker(),
        uwbTransport: (any UWBPairingTransporting)? = nil,
        onComplete: @escaping (SASConfirmation, Data) async throws -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.localIdentity = localIdentity
        self.family = family
        self.role = role
        self.onComplete = onComplete
        self.onCancel = onCancel

        // Determine UWB availability and create or store the transport.
        // On non-UWB devices or macOS, uwbEnabled is false and transport is nil.
        let capable = uwbCapabilityChecker.supportsProximityPairing
        if capable {
            if let provided = uwbTransport {
                // Test or caller-supplied transport (e.g. FakeUWBPairingTransport).
                self.uwbTransport = provided
                self.uwbEnabled = true
            } else {
                // Live transport: created only when the capability check passed.
                // This is the only call site for LiveUWBPairingTransport() — all
                // other code paths store a nil transport.
                #if os(iOS)
                self.uwbTransport = LiveUWBPairingTransport()
                self.uwbEnabled = true
                #else
                // macOS: capability checker returns false so we never reach here,
                // but the else guard is explicit for clarity.
                self.uwbTransport = nil
                self.uwbEnabled = false
                #endif
            }
        } else {
            // Non-UWB device or test with FakeUWBCapabilityChecker(supports: false).
            // No NISession is EVER created. No transport is started.
            // Zero UWB code paths execute. QR is the sole ceremony path.
            self.uwbTransport = uwbTransport  // nil in normal non-UWB case
            self.uwbEnabled = false
        }
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .initializing:
                    ProgressView(String(localized: "federation.pairing.initializing",
                                       defaultValue: "Preparing ceremony…"))
                        .task { await initialize() }

                case .showingQR:
                    ProposerQRDisplayView(
                        qrImageData: qrImageData,
                        uwbEnabled: uwbEnabled,
                        uwbProximityReady: uwbProximityReady,
                        onAcceptorPayloadReceived: { acceptorPayload in
                            await handleAcceptorResponse(acceptorPayload)
                        }
                    )
                    // FED-OD-5: start UWB transport when the proposer QR is showing.
                    // Runs concurrently with the existing relay-wait path.
                    .task(id: "uwb-proposer") { await runUWBTransport() }

                case .scanningQR:
                    AcceptorQRScanView(
                        uwbEnabled: uwbEnabled,
                        uwbProximityReady: uwbProximityReady,
                        onPayloadScanned: { payloadData in
                            await handleScannedPayload(payloadData)
                        }
                    )
                    // FED-OD-5: start UWB transport when the acceptor scan is active.
                    .task(id: "uwb-acceptor") { await runUWBTransport() }

                case .showingSAS:
                    if let confirmation = pendingConfirmation {
                        SASConfirmationView(
                            sasPattern: sasPattern,
                            onConfirm: {
                                await handleSASConfirmed(confirmation)
                            },
                            onReject: {
                                await handleSASRejected()
                            }
                        )
                    }

                case .complete:
                    Text(String(localized: "federation.pairing.complete",
                                defaultValue: "Pairing complete."))

                case .failed(let message):
                    VStack(spacing: 16) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 48))
                            .foregroundStyle(.red)
                            .accessibilityLabel(String(localized: "federation.pairing.failed.icon",
                                                       defaultValue: "Pairing failed"))
                        Text(message)
                            .multilineTextAlignment(.center)
                        Button(String(localized: "federation.pairing.retry",
                                      defaultValue: "Try Again")) {
                            onCancel()
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle(String(localized: "federation.pairing.title",
                                    defaultValue: "Pair Devices"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "federation.pairing.cancel",
                                  defaultValue: "Cancel")) {
                        uwbTransport?.stop()
                        onCancel()
                    }
                }
            }
        }
    }

    // MARK: - Ceremony logic (unchanged from FED-OD-3)

    private func initialize() async {
        switch role {
        case .proposer:
            await startProposerCeremony()
        case .acceptor:
            phase = .scanningQR
        }
    }

    private func startProposerCeremony() async {
        do {
            let payload = try await coordinator.startAsProposer(
                identity: localIdentity, family: family)
            qrPayload = payload
            let payloadData = try QRPairingCodec.encode(payload)
            qrImageData = payloadData   // QRCodeGeneratorView converts this to an image
            phase = .showingQR
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func handleAcceptorResponse(_ acceptorPayload: QRAcceptorPayload) async {
        do {
            let sas = try await coordinator.processAcceptorPayload(acceptorPayload)
            let confirmation = try await coordinator.confirmSAS()
            // Capture the acceptor's identity key — this is the peer public key
            // the caller needs to register in _fed_peers after SAS confirmation.
            remotePeerPublicKey = acceptorPayload.identityPublicKey
            sasPattern = sas
            pendingConfirmation = confirmation
            phase = .showingSAS
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func handleScannedPayload(_ payloadData: Data) async {
        do {
            let payload = try QRPairingCodec.decode(payloadData)
            let (_, sas) = try await coordinator.startAsAcceptor(
                payload: payload, identity: localIdentity)
            let confirmation = try await coordinator.confirmSAS()
            // Capture the proposer's identity key — this is the peer public key
            // the caller needs to register in _fed_peers after SAS confirmation.
            remotePeerPublicKey = payload.identityPublicKey
            sasPattern = sas
            pendingConfirmation = confirmation
            phase = .showingSAS
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func handleSASConfirmed(_ confirmation: SASConfirmation) async {
        do {
            await coordinator.markComplete()
            // Pass the captured peer public key alongside the SAS token.
            // remotePeerPublicKey is always set before showingSAS phase; the
            // fallback Data(count:32) is a defensive guard that should never fire.
            let peerKey = remotePeerPublicKey ?? Data(count: 32)
            try await onComplete(confirmation, peerKey)
            phase = .complete
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func handleSASRejected() async {
        try? await coordinator.rejectSAS()
        onCancel()
    }

    // MARK: - FED-OD-5: UWB transport driver

    /// Runs the UWB transport event loop for the duration of the QR/scan phase.
    ///
    /// Uses AsyncStream as a bridge between the transport's sync callback API and
    /// the async ceremony handler functions. This function is called from a `.task`
    /// modifier on the QR/scan phase views and cancels automatically when the view
    /// transitions to another phase (SwiftUI cancels tasks when the view disappears).
    ///
    /// Event routing:
    ///   .proximityReady     (proposer) → send already-generated proposer payload via transport
    ///   .proposerPayloadArrived        → decode + startAsAcceptor + send acceptor payload back
    ///   .acceptorPayloadArrived        → decode + processAcceptorPayload (same as QR relay path)
    ///   .proximityLost / .failed       → update uwbProximityReady flag; QR path continues
    ///
    /// This function does NOT call any crypto methods itself — it delegates to the
    /// existing ceremony handlers which use QRPairingCoordinator unchanged.
    private func runUWBTransport() async {
        guard uwbEnabled, let transport = uwbTransport else { return }

        // Build event stream: sync eventHandler closure → AsyncStream.
        // The transport dispatches to @MainActor internally (LiveUWBPairingTransport
        // uses Task { @MainActor in }), so the stream receives events on main thread.
        let (stream, continuation) = AsyncStream<UWBPairingEvent>.makeStream()
        transport.eventHandler = { event in
            continuation.yield(event)
        }

        defer {
            transport.stop()
            continuation.finish()
        }

        // Estate fingerprint: first 16 hex chars of the identity public key.
        // Used by the transport as the local MPC peer identifier.
        let fingerprint = localIdentity.publicKey.prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        let uwbRole: UWBPairingRole = (role == .proposer) ? .proposer : .acceptor
        transport.start(role: uwbRole, localFingerprint: fingerprint)

        // Process transport events asynchronously.
        for await event in stream {
            switch event {

            case .proximityReady:
                // Both devices are within ~10 cm. Update UI affordance.
                uwbProximityReady = true

                if role == .proposer, let proposerPayloadData = qrImageData {
                    // Proposer: send the already-generated QRPairingPayload data
                    // (produced by startProposerCeremony()) to the acceptor via MPC.
                    // This is the UWB substitute for the acceptor scanning the QR code.
                    transport.sendProposerPayload(proposerPayloadData)
                }
                // Acceptor: no action here — wait for proposerPayloadArrived.

            case .proposerPayloadArrived(let payloadData):
                // Acceptor received the proposer's QRPairingPayload via UWB/MPC.
                // Process it through QRPairingCoordinator.startAsAcceptor — SAME
                // method the QR scan path uses. No crypto fork.
                guard role == .acceptor else { break }
                do {
                    let qrPayloadDecoded = try QRPairingCodec.decode(payloadData)
                    let (acceptorResponse, sas) = try await coordinator.startAsAcceptor(
                        payload: qrPayloadDecoded, identity: localIdentity)
                    let confirmation = try await coordinator.confirmSAS()
                    remotePeerPublicKey = qrPayloadDecoded.identityPublicKey
                    sasPattern = sas
                    pendingConfirmation = confirmation
                    phase = .showingSAS

                    // Send the QRAcceptorPayload back to the proposer via UWB/MPC.
                    // This is the UWB substitute for B displaying a second QR code.
                    let acceptorResponseData = try QRPairingCodec.encodeAcceptor(acceptorResponse)
                    transport.sendAcceptorPayload(acceptorResponseData)
                } catch {
                    phase = .failed(error.localizedDescription)
                }

            case .acceptorPayloadArrived(let payloadData):
                // Proposer received the acceptor's QRAcceptorPayload via UWB/MPC.
                // Decode and pass to handleAcceptorResponse — SAME method the QR
                // relay path uses. No crypto fork.
                guard role == .proposer else { break }
                do {
                    let acceptorPayload = try QRPairingCodec.decodeAcceptor(payloadData)
                    await handleAcceptorResponse(acceptorPayload)
                } catch {
                    phase = .failed(error.localizedDescription)
                }

            case .proximityLost:
                // Devices moved apart or peer disconnected. QR path continues as fallback.
                uwbProximityReady = false

            case .failed:
                // Transport error. QR path continues as fallback.
                uwbProximityReady = false
            }
        }
    }
}

// MARK: - ProposerQRDisplayView

/// Displays A's QR code while waiting for B to scan and send back a response.
///
/// In the v1 QR-first ceremony, the back-channel from B to A is:
///   - Another QR code displayed on B's screen (A scans it), OR
///   - A relay envelope (FED-OD-7 / pairingAcceptance PayloadKind)
///
/// FED-OD-5: if uwbEnabled, overlays a "hold devices together" affordance
/// below the QR. When uwbProximityReady, the affordance updates to confirm
/// proximity is detected and the exchange is happening automatically.
struct ProposerQRDisplayView: View {
    let qrImageData: Data?
    let uwbEnabled: Bool
    let uwbProximityReady: Bool
    let onAcceptorPayloadReceived: (QRAcceptorPayload) async -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text(String(localized: "federation.pairing.proposer.instruction",
                        defaultValue: "Ask the other device to scan this code."))
                .multilineTextAlignment(.center)

            // QR code display — the raw JSON bytes are rendered as a QR image.
            // CoreImage CIFilter "CIQRCodeGenerator" is used by the app target;
            // this SwiftUI layer passes the data and renders whatever the host
            // platform provides via QRCodeImageView (see Mootx01App target).
            if let data = qrImageData {
                QRCodePlaceholderView(data: data)
                    .frame(width: 220, height: 220)
                    .accessibilityLabel(
                        String(localized: "federation.pairing.qr.label",
                               defaultValue: "Pairing QR code"))
            } else {
                ProgressView()
                    .frame(width: 220, height: 220)
            }

            // FED-OD-5: UWB proximity affordance (UWB-capable devices only).
            // On non-UWB devices, this block compiles to nothing at runtime (uwbEnabled == false).
            if uwbEnabled {
                UWBProximityAffordanceView(proximityReady: uwbProximityReady)
            }

            Text(String(localized: "federation.pairing.proposer.waiting",
                        defaultValue: "Waiting for the other device to respond…"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

// MARK: - AcceptorQRScanView

/// Camera scanner for device B to scan A's QR code.
///
/// The actual AVCaptureSession integration lives in the app target
/// (platform-specific). This view provides the structural container and
/// callback wiring. FED-OD-3 tests exercise the coordinator logic directly
/// without going through this view.
///
/// FED-OD-5: if uwbEnabled, overlays a "hold devices together" affordance
/// below the camera finder.
struct AcceptorQRScanView: View {
    let uwbEnabled: Bool
    let uwbProximityReady: Bool
    let onPayloadScanned: (Data) async -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(String(localized: "federation.pairing.acceptor.instruction",
                        defaultValue: "Point the camera at the other device's pairing code."))
                .multilineTextAlignment(.center)

            // Camera viewfinder placeholder.
            // The app target replaces this with a real AVCaptureSession view.
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.08))
                .overlay(
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 64))
                        .foregroundStyle(.secondary)
                )
                .frame(width: 280, height: 280)
                .accessibilityLabel(
                    String(localized: "federation.pairing.camera.label",
                           defaultValue: "Camera viewfinder for scanning pairing QR code"))

            // FED-OD-5: UWB proximity affordance (UWB-capable devices only).
            if uwbEnabled {
                UWBProximityAffordanceView(proximityReady: uwbProximityReady)
            }
        }
        .padding()
    }
}

// MARK: - UWBProximityAffordanceView

/// "Touch the tips" proximity affordance shown on UWB-capable devices.
///
/// Shown below the QR code (proposer) or camera viewfinder (acceptor).
/// Transitions from an invitation state ("hold devices together") to a
/// confirmation state ("Devices are close — exchanging…") when UWB
/// proximity is detected.
///
/// Accessibility:
///   - Label describes the current affordance state (invitation or exchange in progress).
///   - The affordance is decorative when the exchange is already completing;
///     the descriptive text conveys the same information.
///   - Never the ONLY way to complete pairing — QR fallback is always visible.
struct UWBProximityAffordanceView: View {
    let proximityReady: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: proximityReady ? "wave.3.right.circle.fill"
                                             : "wave.3.right.circle")
                .font(.system(size: 24))
                .foregroundStyle(proximityReady ? Color.accentColor : .secondary)
                .accessibilityHidden(true)   // label below conveys the state

            VStack(alignment: .leading, spacing: 2) {
                Text(proximityReady
                     ? String(localized: "federation.pairing.uwb.exchanging",
                               defaultValue: "Devices are close — exchanging…")
                     : String(localized: "federation.pairing.uwb.invite",
                               defaultValue: "Or hold the devices together"))
                    .font(.subheadline.weight(proximityReady ? .semibold : .regular))
                    .foregroundStyle(proximityReady ? .primary : .secondary)

                if !proximityReady {
                    Text(String(localized: "federation.pairing.uwb.invite.detail",
                                defaultValue: "Bring them within a few centimetres"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.05))
        )
        // Accessibility: the entire affordance row has a single label describing state.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            proximityReady
            ? String(localized: "federation.pairing.uwb.a11y.exchanging",
                     defaultValue: "Devices are close. Exchanging pairing data automatically.")
            : String(localized: "federation.pairing.uwb.a11y.invite",
                     defaultValue: "UWB shortcut: hold this device and the other device within a few centimetres to pair automatically. You will still need to confirm the pairing code.")
        )
    }
}

// MARK: - QRCodePlaceholderView

/// Minimal QR code display placeholder.
///
/// In the app target, this is replaced with a CoreImage CIQRCodeGenerator render.
/// Shown here as a bordered rectangle labelled with byte count so the proposer
/// can confirm the payload was generated, without requiring CoreImage in the
/// SwiftPM library build.
struct QRCodePlaceholderView: View {
    let data: Data

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary, lineWidth: 2)
            // In the real app target, replace with:
            //   Image(uiImage: generateQRImage(from: data))
            //       .interpolation(.none)
            //       .resizable()
            //       .scaledToFit()
            Image(systemName: "qrcode")
                .font(.system(size: 80))
                .foregroundStyle(.primary)
        }
    }
}
