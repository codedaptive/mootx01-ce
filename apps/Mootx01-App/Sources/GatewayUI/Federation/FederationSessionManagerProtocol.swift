// FederationSessionManagerProtocol.swift
//
// FED-OD-6 (protocol seam) + FED-OD-6b (reconciliation complete).
//
// FED-OD-6b wired the real FED-OD-4 FederationSessionManager into this surface.
// Shipped reality:
//   - FederationController is the FederationSessionManaging conformer. It holds
//     a real FederationSessionManager (MootGateway) via composition in its
//     `_sessionManager` stored property, loaded lazily from GatewayRuntime.
//   - LocalIdentity is loaded from the engine layer via manager.estateIdentity()
//     inside FederationController.bootstrapFromEstate(), and cached as
//     `localIdentity` for LANDiscovery advertising and the QR ceremony. Discovery
//     uses the real Ed25519 public key once bootstrapFromEstate() completes; it
//     falls back to a 32-byte zero placeholder only while the estate is unavailable.
//   - KnownPeers are backed by `_fed_peers` (via FederationSessionManager) with a
//     UserDefaults cache for synchronous initial display. mergePeersFromEstate()
//     enriches entries with real publicKeyData on startup.

import Foundation

// MARK: - FederationPosture

/// The six sharing-model §11 postures, excluding Sealed.
///
/// Sealed is absent by construction: its data class is "secret" and the
/// sharing model mandates that no key is ever minted for secret rows. No
/// UI control ever references or offers a secret row — this enum embeds
/// that invariant structurally. (Sharing model §11, decision §5.)
///
/// F1 functional subset: only `.balanced` actually starts a session (FED-OD-6).
/// All other cases render visibly locked — disabled with a lock affordance and
/// an honest "coming soon" message. A locked card never silently pretends to
/// do something.
public enum FederationPosture: String, CaseIterable, Identifiable, Sendable {
    case open       = "Open"
    case convenient = "Convenient"
    case balanced   = "Balanced"
    case locked     = "Locked"
    case inPerson   = "In-person"
    // Sealed is intentionally absent — see file header.

    public var id: String { rawValue }

    /// True only for `.balanced` in F1. Other postures require the grant system
    /// (F2) before they can safely start a session.
    public var isFunctionalInF1: Bool { self == .balanced }

    /// Plain-language card title (matches the sharing model §11 preset name).
    public var cardTitle: String {
        switch self {
        case .open:       return String(localized: "federation.posture.open.title",
                                        defaultValue: "Open")
        case .convenient: return String(localized: "federation.posture.convenient.title",
                                        defaultValue: "Convenient")
        case .balanced:   return String(localized: "federation.posture.balanced.title",
                                        defaultValue: "Balanced")
        case .locked:     return String(localized: "federation.posture.locked.title",
                                        defaultValue: "Locked")
        case .inPerson:   return String(localized: "federation.posture.inperson.title",
                                        defaultValue: "In-person")
        }
    }

    /// One-sentence plain-language description: what crosses the boundary.
    /// Written for the chooser card, not the sharing model table.
    public var cardWhatCrosses: String {
        switch self {
        case .open:
            return String(localized: "federation.posture.open.what",
                          defaultValue: "Shareable memories are shared verbatim, durably.")
        case .convenient:
            return String(localized: "federation.posture.convenient.what",
                          defaultValue: "Private memories as full text, with long-lived keys.")
        case .balanced:
            return String(localized: "federation.posture.balanced.what",
                          defaultValue: "Private memories as facts and fields, key expires when you end the session.")
        case .locked:
            return String(localized: "federation.posture.locked.what",
                          defaultValue: "Restricted memories as statistics only, single session.")
        case .inPerson:
            return String(localized: "federation.posture.inperson.what",
                          defaultValue: "Only posture signals cross — nothing persists past this moment.")
        }
    }

    /// Plain-language description of when the session key expires.
    public var cardLifetime: String {
        switch self {
        case .open:       return String(localized: "federation.posture.open.lifetime",
                                        defaultValue: "Durable — stays until revoked.")
        case .convenient: return String(localized: "federation.posture.convenient.lifetime",
                                        defaultValue: "Long — fades over days.")
        case .balanced:   return String(localized: "federation.posture.balanced.lifetime",
                                        defaultValue: "Short — ends with this session.")
        case .locked:     return String(localized: "federation.posture.locked.lifetime",
                                        defaultValue: "Single session only.")
        case .inPerson:   return String(localized: "federation.posture.inperson.lifetime",
                                        defaultValue: "This moment only.")
        }
    }

    /// Plain-language description of what happens when the session ends.
    public var cardAtEnd: String {
        switch self {
        case .open:       return String(localized: "federation.posture.open.end",
                                        defaultValue: "Peer retains access; clawback is best-effort.")
        case .convenient: return String(localized: "federation.posture.convenient.end",
                                        defaultValue: "Peer retains access; clawback is best-effort.")
        case .balanced:   return String(localized: "federation.posture.balanced.end",
                                        defaultValue: "Peer's key expires — they cannot read further.")
        case .locked:     return String(localized: "federation.posture.locked.end",
                                        defaultValue: "Key is revoked cryptographically.")
        case .inPerson:   return String(localized: "federation.posture.inperson.end",
                                        defaultValue: "Key is revoked cryptographically.")
        }
    }

    /// Accessibility label for the posture card as a whole.
    public var cardAccessibilityLabel: String {
        if isFunctionalInF1 {
            return String(localized: "federation.posture.card.a11y.active",
                          defaultValue: "\(cardTitle) posture. \(cardWhatCrosses) \(cardLifetime)")
        } else {
            return String(localized: "federation.posture.card.a11y.locked",
                          defaultValue: "\(cardTitle) posture, unavailable. Requires the grant system, coming in a future release.")
        }
    }
}

// MARK: - KnownPeer

/// A paired peer estate stored in `_fed_peers`.
///
/// The `id` (fingerprint) and `displayName` are the UI-layer identifiers.
/// `publicKeyData` is the 32-byte Ed25519 key needed for `startSession` to
/// call the real `FederationSessionManager`. Nil until `mergePeersFromEstate()`
/// enriches the entry from `_fed_peers`; always non-nil for ceremony-paired peers
/// once the estate bootstrap completes.
public struct KnownPeer: Identifiable, Hashable, Sendable, Codable {
    /// Short fingerprint derived from the estate identity key (SHA256 prefix, 16 hex chars).
    /// Used as the list identifier and the mDNS fingerprint in LANDiscovery.
    public let id: String
    /// Display name agreed during pairing.
    public let displayName: String
    /// When the last session ended. Nil if never sessioned.
    public let lastSession: Date?
    /// The 32-byte Ed25519 public key of this peer estate.
    ///
    /// Populated from `_fed_peers` by `mergePeersFromEstate()` during estate bootstrap.
    /// Required for `startSession` to delegate to the real `FederationSessionManager`.
    public let publicKeyData: Data?

    public init(id: String, displayName: String, lastSession: Date? = nil, publicKeyData: Data? = nil) {
        self.id = id
        self.displayName = displayName
        self.lastSession = lastSession
        self.publicKeyData = publicKeyData
    }
}

// MARK: - FederationSession

/// An active federation session (F1: Balanced posture, time-boxed).
///
/// UI-layer tracking struct. FederationController creates this when startSession
/// succeeds and clears it in endSession. It does not map 1:1 to MootGateway
/// FederationSessionManager state — it is the view-layer representation only.
public struct FederationSession: Sendable {
    /// The paired peer this session is open with.
    public let peer: KnownPeer
    /// The posture under which the session was started.
    public let posture: FederationPosture
    /// When the session started.
    public let startedAt: Date
    /// When the session will auto-expire (F1: 30 minutes from start).
    public let expiresAt: Date
    /// Plain-language description of what is crossing the boundary.
    public let whatsCrossing: String

    public init(peer: KnownPeer, posture: FederationPosture, startedAt: Date = Date()) {
        self.peer = peer
        self.posture = posture
        self.startedAt = startedAt
        // F1 production session window: 30 minutes (Balanced posture, charter §V4).
        // The UI timer fires at expiresAt and calls FederationController.endSession().
        self.expiresAt = startedAt.addingTimeInterval(30 * 60)
        self.whatsCrossing = posture.cardWhatCrosses
    }
}

// MARK: - FederationSessionManaging Protocol Seam

/// Protocol seam between FederationPanelView and the session manager.
///
/// Defines the minimal interface FederationPanel consumes. FederationController
/// is the conformer: it delegates startSession/endSession to the real
/// FederationSessionManager (MootGateway) via composition when the peer has a
/// verified public key. The protocol exists so GatewayUITests can inject a
/// test double without importing MootGateway.
///
/// @MainActor: UI-layer surface consumed by FederationPanelView. FederationController
/// conforms on @MainActor; MootGateway.FederationSessionManager is an actor that
/// is called via async delegation inside FederationController's conformance methods.
@MainActor
public protocol FederationSessionManaging: AnyObject {
    /// The currently active federation session, or nil.
    var activeSession: FederationSession? { get }

    /// Start a session with the given peer under the given posture.
    /// Throws if the posture is not functional in F1, or if a session is already active.
    func startSession(peer: KnownPeer, posture: FederationPosture) async throws

    /// End the active session. No-op if no session is active.
    func endSession() async
}

// MARK: - F1 Session Errors

/// Errors from the F1 session stub.
public enum FederationSessionError: Error, Sendable {
    /// The requested posture is not yet functional (locked in F1).
    case postureNotFunctionalInF1(FederationPosture)
    /// A session is already active.
    case sessionAlreadyActive
}
