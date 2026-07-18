// QRPairingView.swift
//
// FED-OD-3: QR pairing ceremony views.
//
// Scope note: this file provides the structural scaffolding for the QR
// ceremony UI. The full interactive panel (Nearby peers, discovery toggle,
// session banner) is FED-OD-6 scope. This file wires QRPairingCoordinator
// to the display + scan surfaces and hands off to SASConfirmationView.
//
// Localization: all user-visible strings use String(localized:) per the
// project localization rule.

import SwiftUI
import MootGateway
import ConvergenceKit
import ConvergenceKitFederation

// MARK: - QRPairingView

/// Entry point for the QR pairing ceremony.
///
/// Shows one of two faces depending on the user's role:
///   - Proposer: displays a QR code (device A, initiating side)
///   - Acceptor: shows a camera scanner to scan A's QR (device B)
///
/// After the QR exchange completes, transitions to SASConfirmationView.
///
/// Usage:
/// ```swift
/// QRPairingView(
///     localIdentity: identity,
///     family: HyperplaneFamilySpec(seed: 42),
///     role: .proposer,
///     onComplete: { confirmation in
///         // Caller performs the _fed_peers write using confirmation
///         try await engine.acceptPairingProposal(confirmation.proposal!, ...)
///     },
///     onCancel: { /* dismiss */ }
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
    let onComplete: (SASConfirmation) async throws -> Void
    let onCancel: () -> Void

    @State private var coordinator = QRPairingCoordinator()
    @State private var phase: Phase = .initializing
    @State private var qrPayload: QRPairingPayload? = nil
    @State private var qrImageData: Data? = nil
    @State private var sasPattern: [SASEntry] = []
    @State private var pendingConfirmation: SASConfirmation? = nil
    @State private var errorMessage: String? = nil

    enum Phase {
        case initializing
        case showingQR             // proposer: QR displayed
        case scanningQR            // acceptor: camera active
        case showingSAS            // both: SAS displayed, awaiting user confirmation
        case complete
        case failed(String)
    }

    public init(
        localIdentity: LocalIdentity,
        family: HyperplaneFamilySpec,
        role: Role,
        onComplete: @escaping (SASConfirmation) async throws -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.localIdentity = localIdentity
        self.family = family
        self.role = role
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

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
                        onAcceptorPayloadReceived: { acceptorPayload in
                            await handleAcceptorResponse(acceptorPayload)
                        }
                    )

                case .scanningQR:
                    AcceptorQRScanView(
                        onPayloadScanned: { payloadData in
                            await handleScannedPayload(payloadData)
                        }
                    )

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
                        onCancel()
                    }
                }
            }
        }
    }

    // MARK: - Ceremony logic

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
            try await onComplete(confirmation)
            phase = .complete
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func handleSASRejected() async {
        try? await coordinator.rejectSAS()
        onCancel()
    }
}

// MARK: - ProposerQRDisplayView

/// Displays A's QR code while waiting for B to scan and send back a response.
///
/// In the v1 QR-first ceremony, the back-channel from B to A is:
///   - Another QR code displayed on B's screen (A scans it), OR
///   - A relay envelope (FED-OD-7 / pairingAcceptance PayloadKind)
///
/// This view shows the proposer QR and listens on the relay for B's response.
/// The `onAcceptorPayloadReceived` callback fires when the response arrives.
struct ProposerQRDisplayView: View {
    let qrImageData: Data?
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
struct AcceptorQRScanView: View {
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
        }
        .padding()
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
