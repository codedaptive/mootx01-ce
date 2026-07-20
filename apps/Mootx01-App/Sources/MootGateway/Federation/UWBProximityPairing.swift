// UWBProximityPairing.swift
//
// FED-OD-5: UWB proximity "touch the tips" enhancement layer.
//
// This file provides the capability seam and transport protocol for UWB-based
// automatic pairing. UWB is an ADDITIVE enhancement over the QR ceremony
// (FED-OD-3) — it replaces only the QR-scan transport step for exchanging
// QRPairingPayload and QRAcceptorPayload. The ephemeral X25519 exchange,
// SAS confirmation gate, and _fed_peers write are IDENTICAL to the QR path.
//
// Architecture:
//   UWBCapabilityChecking      — protocol seam; real impl queries NI; fakes return fixed value
//   LiveUWBCapabilityChecker   — real impl: iOS-only check via NISession.deviceCapabilities
//   UWBPairingRole             — proposer/acceptor, mirrors QRPairingView.Role
//   UWBPairingEvent            — events delivered to the ceremony coordinator layer
//   UWBPairingTransporting     — protocol seam for the MPC + NI transport layer
//   LiveUWBPairingTransport    — iOS-only real impl using MPC advertiser/browser + NISession
//
// Foreground-only requirement (NearbyInteraction):
//   NISession is automatically suspended when the app enters background. The live
//   transport observes UIApplication.didEnterBackgroundNotification and calls stop(),
//   firing .proximityLost so the pairing screen surfaces the QR fallback.
//
// Security boundary (no crypto in this file):
//   UWB only provides the payload transport channel. All cryptographic work —
//   X25519 key agreement, SAS derivation, and the _fed_peers confirmation gate —
//   lives in QRPairingCoordinator unchanged. This file contains zero key material.
//
// Hardware gate (Kong mandate from FED-OD charter §V3):
//   Check NISession.deviceCapabilities.supportsDeviceInitiation BEFORE creating
//   any NISession. Non-UWB devices present the framework but crash at NISession()
//   creation. LiveUWBCapabilityChecker is the mandatory guard; the live transport
//   also re-asserts the gate in startNISession() as defense-in-depth.
//
// Test surface:
//   FakeUWBCapabilityChecker and FakeUWBPairingTransport in UWBProximityPairingTests
//   implement these protocols without any NI/MPC dependency. All tests compile and
//   run on macOS without UWB hardware.

import Foundation

#if os(iOS)
import NearbyInteraction
import MultipeerConnectivity
import UIKit
#endif

// MARK: - Capability Checking

/// Protocol seam for the UWB hardware capability check.
///
/// The real implementation queries NearbyInteraction on iOS (no hardware
/// activation — it is a property read on NISession.deviceCapabilities).
/// Fakes return a fixed Boolean for deterministic tests without hardware.
///
/// This seam exists so the QR pairing view can be tested for the
/// non-UWB path (no NISession created, no transport started, QR-only UI)
/// without requiring a U1/U3-equipped iOS device.
public protocol UWBCapabilityChecking: Sendable {
    /// True iff this device supports UWB proximity pairing via NearbyInteraction.
    ///
    /// On iOS (U1/U3 chip, iPhone 11+): returns NISession.deviceCapabilities.supportsDeviceInitiation.
    /// On all other platforms (macOS, non-UWB iOS devices): returns false.
    ///
    /// Do NOT call NISession() before checking this. Non-UWB devices crash at
    /// NISession() creation if the capability is not gated here first.
    var supportsProximityPairing: Bool { get }
}

/// Live capability checker: queries NearbyInteraction on iOS.
///
/// On iOS 16+: reads NISession.deviceCapabilities.supportsDeviceInitiation.
/// This is a static capability check — no session is created, no UWB radio
/// is activated. It is safe to call at any time.
///
/// On macOS and other non-iOS platforms: always returns false. UWB peer-to-peer
/// proximity pairing (the "touch the tips" ceremony) is a U1/U3 iPhone feature.
public struct LiveUWBCapabilityChecker: UWBCapabilityChecking, Sendable {
    public init() {}

    public var supportsProximityPairing: Bool {
        #if os(iOS)
        // HARDWARE GATE — required by Kong / charter §V3:
        // supportsDeviceInitiation is true only on U1/U3-equipped devices (iPhone 11+
        // family, some iPad Pro models). The check is a static property read; it does
        // not create a session or activate the UWB radio. This is the authoritative
        // guard. The live transport also re-asserts it in startNISession() for depth.
        return NISession.deviceCapabilities.supportsDeviceInitiation
        #else
        return false
        #endif
    }
}

// MARK: - Transport Role

/// The device's role in the UWB pairing exchange, matching QRPairingView.Role.
///
/// The role is set by QRPairingView when the pairing screen is presented —
/// exactly the same proposer/acceptor choice the user makes for the QR path.
/// UWB does NOT negotiate roles independently; it uses the role already established.
///
/// Proposer: generates QRPairingPayload → sends to nearby acceptor via MPC data.
/// Acceptor: receives proposer payload via MPC → responds with QRAcceptorPayload via MPC.
public enum UWBPairingRole: Sendable {
    /// This device initiated pairing (generates QRPairingPayload, sends first).
    case proposer
    /// This device responds to the proposer (receives payload, sends QRAcceptorPayload).
    case acceptor
}

// MARK: - Transport Events

/// Events delivered by the UWBPairingTransporting implementation to the ceremony coordinator.
///
/// The QRPairingView event handler acts on these to drive QRPairingCoordinator
/// through the same methods the QR path uses. The cryptographic ceremony
/// (startAsProposer, startAsAcceptor, processAcceptorPayload, confirmSAS) is
/// identical on both paths — no fork.
public enum UWBPairingEvent: Sendable {

    /// NI ranging confirms the devices are within ~10 cm of each other.
    ///
    /// Both devices are in the pairing screen (MPC discovery was already established).
    /// Response:
    ///   Proposer: call transport.sendProposerPayload(_:) with the coordinator's
    ///             encoded QRPairingPayload from startAsProposer().
    ///   Acceptor: no action — wait for proposerPayloadArrived.
    case proximityReady

    /// The encoded QRPairingPayload arrived from the proposer (acceptor role only).
    ///
    /// Response: decode with QRPairingCodec.decode(_:), call
    /// QRPairingCoordinator.startAsAcceptor(payload:identity:), encode the
    /// QRAcceptorPayload, call transport.sendAcceptorPayload(_:).
    case proposerPayloadArrived(Data)

    /// The encoded QRAcceptorPayload arrived from the acceptor (proposer role only).
    ///
    /// Response: decode with QRPairingCodec.decodeAcceptor(_:) and call
    /// QRPairingCoordinator.processAcceptorPayload(_:).
    /// This mirrors the onAcceptorPayloadReceived path in the QR relay.
    case acceptorPayloadArrived(Data)

    /// Proximity session ended without a complete ceremony.
    ///
    /// Causes: devices moved apart, MPC session lost, app backgrounded.
    /// The pairing screen should surface the QR fallback affordance.
    case proximityLost

    /// Unrecoverable transport error. Message is displayable to the user.
    ///
    /// The transport is stopped after this event. Restart to retry.
    case failed(String)
}

// MARK: - Transport Protocol (the seam)

/// Protocol seam for the UWB + MPC proximity pairing transport.
///
/// Live implementation (LiveUWBPairingTransport, iOS-only):
///   MultipeerConnectivity: peer discovery + bidirectional payload data channel
///   NearbyInteraction: ranging — confirms proximity ≤ 10 cm before exchange
///
/// Test fakes (FakeUWBPairingTransport in test target):
///   Implement this protocol directly. Tests inject UWBPairingEvent values
///   without MPC or NI hardware. All ceremony tests compile and run on macOS.
///
/// Threading note: eventHandler is dispatched to the main thread by
/// LiveUWBPairingTransport (via Task { @MainActor }). Test fakes may call
/// it directly on the test thread. Callers should not assume a specific thread.
///
/// Foreground requirement: start() must only be called while the app is in the
/// foreground. NearbyInteraction sessions are suspended by the OS on background.
/// The live transport fires .proximityLost automatically on background transition.
public protocol UWBPairingTransporting: AnyObject, Sendable {

    /// Event callback from the transport to the ceremony coordinator.
    ///
    /// Set before calling start(). May fire on any thread (live: dispatched to main).
    var eventHandler: (@Sendable (UWBPairingEvent) -> Void)? { get set }

    /// Start proximity detection for a given pairing role.
    ///
    /// - Parameters:
    ///   - role: `.proposer` or `.acceptor` — mirrors the QRPairingView role.
    ///   - localFingerprint: This device's estate fingerprint (16 hex chars).
    ///     Used as the MPC peer display name and in service discovery info.
    func start(role: UWBPairingRole, localFingerprint: String)

    /// Send the encoded QRPairingPayload to the nearby acceptor via MPC.
    ///
    /// Call this after receiving `.proximityReady` (proposer role) and after
    /// generating the payload via QRPairingCoordinator.startAsProposer().
    func sendProposerPayload(_ data: Data)

    /// Send the encoded QRAcceptorPayload back to the proposer via MPC.
    ///
    /// Call this after receiving `.proposerPayloadArrived` (acceptor role) and
    /// processing it via QRPairingCoordinator.startAsAcceptor().
    func sendAcceptorPayload(_ data: Data)

    /// Stop all proximity detection and clean up NI session and MPC connections.
    ///
    /// Safe to call multiple times or before start(). After stop(), no further
    /// events will fire. Call start() again to begin a new proximity attempt.
    func stop()
}

// MARK: - Live Transport (iOS only)

#if os(iOS)

/// MPC service type for the UWB pairing discovery channel.
///
/// Must be identical on both devices. MCNearbyServiceAdvertiser enforces a
/// 15-char limit and only allows lowercase ASCII letters, digits, and hyphens.
private let kUWBPairingServiceType = "mootx01-uwbpair"

/// Proximity threshold: auto-fire distance in metres.
///
/// 0.10 m = 10 cm — the "touch the tips" target. Below this the payload exchange
/// fires automatically. Above it the transport waits for closer proximity.
private let kUWBProximityThresholdMetres: Float = 0.10

/// MPC message tag bytes. First byte of every message identifies payload type.
private let kTagNIToken: UInt8 = 0x01   // NI discovery token (both sides exchange)
private let kTagProposerPayload: UInt8 = 0x02   // encoded QRPairingPayload
private let kTagAcceptorPayload: UInt8 = 0x03   // encoded QRAcceptorPayload

/// Live UWB + MPC pairing transport.
///
/// ## Session lifecycle
///
/// 1. start(role:localFingerprint:)
///    → creates MCPeerID, MCSession, starts MPC advertiser + browser
/// 2. Nearby peer found (browser) or receives invitation (advertiser)
///    → MPC session connected; both sides exchange NI discovery tokens (kTagNIToken)
/// 3. Each side receives the peer's token
///    → creates NISession, runs NINearbyPeerConfiguration with peer token
///    → UWB ranging starts
/// 4. NI ranging reports distance ≤ 10 cm
///    → NISession.invalidate() (no repeated firing); fireEvent(.proximityReady)
/// 5. Payload exchange (driven by QRPairingView acting on events)
///    → sendProposerPayload / sendAcceptorPayload via MCSession.send
///    → onReceive fires proposerPayloadArrived / acceptorPayloadArrived
/// 6. stop() — advertiser/browser stop, MCSession.disconnect(), NISession.invalidate()
///
/// ## Foreground enforcement
///
/// On UIApplication.didEnterBackgroundNotification: calls stop() and fires
/// .proximityLost so QRPairingView surfaces the QR fallback affordance.
///
/// ## Thread safety
///
/// Internal state is protected by NSLock. eventHandler calls are dispatched
/// to MainActor via Task { @MainActor in } for safe SwiftUI integration.
public final class LiveUWBPairingTransport: NSObject, UWBPairingTransporting,
                                             @unchecked Sendable {

    // MARK: - UWBPairingTransporting

    public var eventHandler: (@Sendable (UWBPairingEvent) -> Void)?

    // MARK: - Internal state

    private let stateLock = NSLock()
    private var role: UWBPairingRole = .acceptor
    private var isStopped = true

    // MPC handles
    private var localPeerID: MCPeerID?
    private var mcSession: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var connectedPeer: MCPeerID?

    // NI handles
    private var niSession: NISession?
    private var niPeerToken: NIDiscoveryToken?

    // Background notification observer (removed on deinit)
    private var backgroundObserver: Any?

    // MARK: - Init / deinit

    public override init() {
        super.init()
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Foreground-only requirement: stop transport and surface QR fallback.
            self?.stop()
            self?.fireEvent(.proximityLost)
        }
    }

    deinit {
        if let obs = backgroundObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - UWBPairingTransporting — start / stop / send

    public func start(role: UWBPairingRole, localFingerprint: String) {
        stateLock.lock()
        self.role = role
        self.isStopped = false
        stateLock.unlock()

        // MCPeerID displayName: "m01-" prefix + first 12 chars of fingerprint.
        // 63-char limit; fingerprint prefix is deterministic per estate.
        let pid = MCPeerID(displayName: "m01-\(localFingerprint.prefix(12))")

        let session = MCSession(
            peer: pid,
            securityIdentity: nil,
            encryptionPreference: .required   // MPC channel encrypted end-to-end
        )
        session.delegate = self

        // Advertise: nearby devices will find us.
        let adv = MCNearbyServiceAdvertiser(
            peer: pid,
            discoveryInfo: [
                "role": role == .proposer ? "p" : "a",
                "fp":   String(localFingerprint.prefix(8))
            ],
            serviceType: kUWBPairingServiceType
        )
        adv.delegate = self
        adv.startAdvertisingPeer()

        // Browse: we also find nearby devices actively in pairing mode.
        let brw = MCNearbyServiceBrowser(peer: pid, serviceType: kUWBPairingServiceType)
        brw.delegate = self
        brw.startBrowsingForPeers()

        stateLock.lock()
        localPeerID = pid
        mcSession = session
        advertiser = adv
        browser = brw
        stateLock.unlock()
    }

    public func stop() {
        stateLock.lock()
        guard !isStopped else { stateLock.unlock(); return }
        isStopped = true
        let adv = advertiser; advertiser = nil
        let brw = browser;   browser   = nil
        let ses = mcSession; mcSession  = nil
        let ni  = niSession; niSession  = nil
        connectedPeer = nil
        niPeerToken = nil
        localPeerID = nil
        stateLock.unlock()

        adv?.stopAdvertisingPeer()
        brw?.stopBrowsingForPeers()
        ses?.disconnect()
        ni?.invalidate()
    }

    public func sendProposerPayload(_ data: Data) {
        sendTagged(kTagProposerPayload, payload: data)
    }

    public func sendAcceptorPayload(_ data: Data) {
        sendTagged(kTagAcceptorPayload, payload: data)
    }

    // MARK: - Internals

    private func sendTagged(_ tag: UInt8, payload: Data) {
        stateLock.lock()
        let ses  = mcSession
        let peer = connectedPeer
        stateLock.unlock()
        guard let ses, let peer else { return }
        var msg = Data([tag])
        msg.append(payload)
        try? ses.send(msg, toPeers: [peer], with: .reliable)
    }

    /// Exchange NI discovery tokens once an MPC session is connected.
    ///
    /// Each side sends its NIDiscoveryToken to the other via MPC (kTagNIToken).
    /// When each side receives the peer's token, it starts an NISession for ranging.
    private func exchangeNIToken() {
        // HARDWARE GATE (defense-in-depth): re-assert capability before NISession().
        // This guard is reached only when MPC connects; the primary gate in
        // LiveUWBCapabilityChecker should have already prevented reaching this point
        // on non-UWB devices.
        guard NISession.deviceCapabilities.supportsDeviceInitiation else {
            fireEvent(.failed("UWB not supported on this device (reached token exchange)"))
            return
        }

        let ni = NISession()
        ni.delegate = self
        stateLock.lock()
        niSession = ni
        stateLock.unlock()

        // Archive the local discovery token for MPC transmission.
        // NIDiscoveryToken is NSSecureCoding-conformant.
        guard let tokenData = try? NSKeyedArchiver.archivedData(
            withRootObject: ni.discoveryToken as Any,
            requiringSecureCoding: true
        ) else {
            fireEvent(.failed("Failed to archive NI discovery token"))
            return
        }
        sendTagged(kTagNIToken, payload: tokenData)
    }

    private func startRanging(with peerToken: NIDiscoveryToken) {
        stateLock.lock()
        let ni = niSession
        stateLock.unlock()
        guard let ni else { return }

        let config = NINearbyPeerConfiguration(peerToken: peerToken)
        ni.run(config)
    }

    private func fireEvent(_ event: UWBPairingEvent) {
        guard let handler = eventHandler else { return }
        Task { @MainActor in handler(event) }
    }
}

// MARK: - MCSessionDelegate

extension LiveUWBPairingTransport: MCSessionDelegate {

    public func session(_ session: MCSession, peer peerID: MCPeerID,
                        didChange state: MCSessionState) {
        switch state {
        case .connected:
            stateLock.lock()
            connectedPeer = peerID
            stateLock.unlock()
            // MPC session up — exchange NI discovery tokens to begin ranging.
            exchangeNIToken()

        case .notConnected:
            stateLock.lock()
            if connectedPeer == peerID { connectedPeer = nil }
            stateLock.unlock()
            fireEvent(.proximityLost)

        default:
            break
        }
    }

    public func session(_ session: MCSession, didReceive data: Data, fromPeer: MCPeerID) {
        guard !data.isEmpty else { return }
        let tag     = data[data.startIndex]
        let payload = data.dropFirst()

        switch tag {
        case kTagNIToken:
            // Peer's NI discovery token arrived. Unarchive and start ranging.
            guard let peerToken = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NIDiscoveryToken.self, from: Data(payload)
            ) else {
                fireEvent(.failed("Peer NI token decode failed"))
                return
            }
            stateLock.lock()
            niPeerToken = peerToken
            stateLock.unlock()
            startRanging(with: peerToken)

        case kTagProposerPayload:
            // Proposer's encoded QRPairingPayload arrived (we are acceptor).
            fireEvent(.proposerPayloadArrived(Data(payload)))

        case kTagAcceptorPayload:
            // Acceptor's encoded QRAcceptorPayload arrived (we are proposer).
            fireEvent(.acceptorPayloadArrived(Data(payload)))

        default:
            break  // Unknown tag — ignore gracefully.
        }
    }

    // Required MCSessionDelegate stubs — not used in the UWB pairing context.
    public func session(_ session: MCSession, didReceive stream: InputStream,
                        withName: String, fromPeer: MCPeerID) {}
    public func session(_ session: MCSession,
                        didStartReceivingResourceWithName: String,
                        fromPeer: MCPeerID, with: Progress) {}
    public func session(_ session: MCSession,
                        didFinishReceivingResourceWithName: String,
                        fromPeer: MCPeerID, at: URL?, withError: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension LiveUWBPairingTransport: MCNearbyServiceAdvertiserDelegate {

    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                           didReceiveInvitationFromPeer peerID: MCPeerID,
                           withContext: Data?,
                           invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Accept the MPC invitation. The real trust boundary is the QRPairingCoordinator
        // cryptographic ceremony and the SAS gate — MPC is the local transport only.
        stateLock.lock()
        let session = mcSession
        stateLock.unlock()
        invitationHandler(true, session)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension LiveUWBPairingTransport: MCNearbyServiceBrowserDelegate {

    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                        withDiscoveryInfo: [String: String]?) {
        // Invite the first nearby peer advertising the pairing service.
        // The user opened the pairing screen intentionally; SAS provides MITM defense.
        stateLock.lock()
        let session  = mcSession
        let selfID   = localPeerID
        let isStopped = self.isStopped
        stateLock.unlock()

        guard !isStopped, let session, let selfID, peerID != selfID else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }

    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        stateLock.lock()
        let isConnected = (connectedPeer == peerID)
        stateLock.unlock()
        if isConnected {
            fireEvent(.proximityLost)
        }
    }
}

// MARK: - NISessionDelegate

extension LiveUWBPairingTransport: NISessionDelegate {

    public func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let obj = nearbyObjects.first,
              let distance = obj.distance else { return }

        if distance <= kUWBProximityThresholdMetres {
            // Within "touch the tips" range. Invalidate to stop repeated firing —
            // one proximity event is enough to trigger the payload exchange.
            session.invalidate()
            stateLock.lock()
            if niSession === session { niSession = nil }
            stateLock.unlock()
            fireEvent(.proximityReady)
        }
    }

    public func session(_ session: NISession, didInvalidateWith error: Error) {
        stateLock.lock()
        let isStopped = self.isStopped
        if niSession === session { niSession = nil }
        stateLock.unlock()
        // Do not fire failed if the session was invalidated by our own stop() call.
        if !isStopped {
            fireEvent(.failed("NI session invalidated: \(error.localizedDescription)"))
        }
    }

    public func sessionWasSuspended(_ session: NISession) {
        // App entered background. The background notification observer fires stop()
        // and .proximityLost separately — no action needed here.
    }

    public func sessionSuspensionEnded(_ session: NISession) {
        // App returned to foreground. Re-run ranging with the stored peer token.
        stateLock.lock()
        let peerToken = niPeerToken
        stateLock.unlock()
        if let peerToken {
            let config = NINearbyPeerConfiguration(peerToken: peerToken)
            session.run(config)
        }
    }
}

#endif  // os(iOS)
