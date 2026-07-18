// LANDiscovery.swift — ConvergenceKitFederation
//
// LAN mDNS discovery for Federation (FED-OD-1).
//
// OVERVIEW
// --------
// Advertises and browses for Mootx01 estates on the local network using
// Bonjour/mDNS (service type "_mootx01-fed._tcp"). Two roles run in
// parallel when discovery is active:
//
//   Advertiser — NWListener publishes this estate's presence via a TXT
//                record carrying ONLY identity metadata (fingerprint,
//                display name, protocol version, relay port). No estate
//                content is ever included. See TXT Record Invariant below.
//
//   Browser    — NWBrowser finds other estates advertising the same service
//                type. Each discovered result is turned into a DiscoveredPeer.
//
// TRUST BOUNDARY
// --------------
// Discovery NEVER implies trust. Finding a peer's mDNS advertisement does
// not grant access to that peer's estate. The WC6 signed pairing handshake
// (QRPairingCoordinator, FED-OD-3) gates all trust decisions. The discovery
// layer only surfaces reachability and identity fingerprint.
//
// Peers are classified as `verified` when their fingerprint matches an entry
// already in the caller-supplied known-fingerprints set (i.e., a peer that
// has previously completed the signed pairing ceremony). This classification
// is informational only — it does NOT open a session or transmit any data.
//
// TXT RECORD INVARIANT (NEGATIVE — tested in LANDiscoveryTests)
// -------------------------------------------
// The TXT record carries EXACTLY four keys: "fp", "n", "v", "p".
// No other keys are ever added. The values are:
//   fp — SHA256(ed25519_public_key).prefix(8) as lowercase hex (16 chars).
//        Identifies the estate without exposing the raw public key.
//   n  — User-chosen display name (truncated to 63 bytes UTF-8).
//   v  — Protocol version string ("1" for FED-OD-1).
//   p  — Relay port number as decimal string.
// Content-derived bytes (drawer IDs, KG facts, document content, embeddings,
// or any other estate data) MUST NOT appear in the TXT record. This invariant
// is enforced by construction: the encode function is the only TXT write path,
// and it accepts only the four typed parameters above.
//
// VISIBILITY (OFF BY DEFAULT)
// ---------------------------
// Three-position AirDrop-style toggle persisted in UserDefaults:
//   Off        — neither browse nor advertise; no mDNS traffic
//   WhileOpen  — active only while the app is foregrounded
//   Always     — active in background (meaningful on Mac resident)
//
// Both browsing and advertising gate on the current visibility. The default
// is Off — discovery does not begin until the user explicitly enables it.
//
// TESTABILITY SEAM
// ----------------
// All NWBrowser/NWListener I/O is abstracted behind the LANDiscoverySession
// protocol. Tests supply a class-based FakeLANDiscoverySession (in-memory,
// deterministic). Production uses NWLANDiscoverySession (Network.framework).
// This mirrors the RelayHTTPTransport / FakeRelayHTTPTransport precedent.
//
// The peer-found callback is passed directly into startBrowsing(_:), avoiding
// the awkward property-based wiring that value-type existentials make difficult.

import Foundation
import Network
import Crypto
import os

private let logger = Logger(
    subsystem: "com.mootx01.convergencekit.federation",
    category: "LANDiscovery"
)

// MARK: - Service Type Constant

/// Bonjour/mDNS service type for Mootx01 federation discovery.
/// Both NWBrowser and NWListener use this string. The "_tcp" suffix is
/// required by the Bonjour specification; the OS appends ".local." internally.
/// `NSBonjourServices` in Info.plist must declare this service type for
/// iOS/macOS App Store compliance — see project.yml.
public let LANFederationServiceType = "_mootx01-fed._tcp"

// MARK: - Fingerprint

/// Compute the short public-key fingerprint from a raw Ed25519 public-key blob.
///
/// The fingerprint is the first 8 bytes of SHA-256(publicKey), hex-encoded as
/// 16 lowercase characters. This is the ONLY identity token carried in the TXT
/// record: it uniquely identifies the estate without exposing the raw key bytes
/// to passive observers on the network.
///
/// - Parameter publicKey: 32-byte Ed25519 verifying key (from LocalIdentity.publicKey).
/// - Returns: 16-character lowercase hex string.
public func lanFingerprintFromPublicKey(_ publicKey: Data) -> String {
    // SHA-256 is available via swift-crypto (already a ConvergenceKitFederation dep).
    // We take only the first 8 bytes — sufficient for a short, human-distinguishable
    // fingerprint in the local-network discovery context. This is NOT a
    // security-critical comparison (that role is played by the full Ed25519 key in
    // the WC6 pairing handshake). It is a display/correlation token.
    let digest = SHA256.hash(data: publicKey)
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

// MARK: - TXT Record

/// The four-field TXT record carried in each mDNS advertisement.
///
/// INVARIANT: these are the ONLY fields that may appear in the TXT record.
/// Adding a fifth field requires a protocol version bump and a corresponding
/// update to the NEGATIVE test in LANDiscoveryTests that asserts exactly
/// {fp, n, v, p} are present and nothing else.
public struct LANFederationTXTRecord: Sendable, Equatable {
    /// Short fingerprint: SHA-256(publicKey).prefix(8).hex — 16 lowercase hex chars.
    public let fingerprint: String

    /// User-chosen display name, truncated to 63 bytes UTF-8 to fit TXT record limits.
    /// Mootx01 display names are already short; the truncation is a defensive cap.
    public let displayName: String

    /// Protocol version. "1" for the FED-OD-1 discovery wire format.
    public let protocolVersion: String

    /// The relay port this estate is listening on for LANRelay connections (FED-OD-2).
    /// Carried in discovery so the connecting side can open a TCP socket without
    /// a second round-trip. Zero means "not yet advertising a relay port."
    public let relayPort: UInt16

    public init(fingerprint: String, displayName: String, protocolVersion: String = "1", relayPort: UInt16) {
        self.fingerprint = fingerprint
        // 63-byte cap: defensive truncation. See TXT RECORD INVARIANT comment above.
        let nameBytes = displayName.utf8.prefix(63)
        self.displayName = String(bytes: nameBytes, encoding: .utf8) ?? displayName
        self.protocolVersion = protocolVersion
        self.relayPort = relayPort
    }

    // MARK: TXT wire encoding / decoding

    /// Encode to `[String: String]` for NWTXTRecord.
    ///
    /// FOUR KEYS ONLY: "fp", "n", "v", "p". This is the single write path for
    /// the TXT wire format. The NEGATIVE invariant test in LANDiscoveryTests
    /// verifies that no additional keys appear after encoding.
    ///
    /// NWTXTRecord uses String-valued entries (subscript: [String: String?]).
    func encode() -> [String: String] {
        [
            "fp": fingerprint,
            "n":  displayName,
            "v":  protocolVersion,
            "p":  String(relayPort),
        ]
    }

    /// Decode from `[String: String]` (NWTXTRecord string values).
    ///
    /// Returns `nil` if the mandatory "fp" field is absent. "n" defaults to
    /// empty string, "v" defaults to "1", "p" defaults to 0 — graceful
    /// degradation for future protocol extensions.
    static func decode(_ dict: [String: String]) -> LANFederationTXTRecord? {
        guard let fp = dict["fp"] else {
            return nil  // fingerprint is mandatory — reject without it
        }
        let name = dict["n"] ?? ""
        let version = dict["v"] ?? "1"
        let port = dict["p"].flatMap(UInt16.init) ?? 0
        return LANFederationTXTRecord(
            fingerprint: fp,
            displayName: name,
            protocolVersion: version,
            relayPort: port
        )
    }
}

// MARK: - Discovered Peer Model

/// A peer estate discovered via mDNS.
///
/// Carries the subset of identity information available from the TXT record
/// plus the resolved network endpoint.
///
/// TRUST NOTE: presence in this model does NOT imply trust. `isVerified` is
/// true only when the peer's fingerprint matches an entry already in the
/// known-fingerprints set (from `_fed_peers` via the engine layer). Even a
/// verified peer must go through the WC6 pairing handshake on the LANRelay
/// (FED-OD-2) before any estate data flows. Discovery is reachability
/// only, never authorization.
public struct DiscoveredPeer: Sendable, Hashable, Equatable {
    /// Short fingerprint from the peer's TXT record (16 hex chars).
    /// Identifies the estate; matches the fingerprint field in `_fed_peers`
    /// after a successful pairing ceremony.
    public let fingerprint: String

    /// Display name from the peer's TXT record.
    public let displayName: String

    /// Relay port the peer advertised in its TXT record.
    public let relayPort: UInt16

    /// Protocol version from the peer's TXT record.
    public let protocolVersion: String

    /// Textual description of the resolved endpoint (host + port or Bonjour name).
    /// Nil when the endpoint has not yet been resolved by NWBrowser.
    public let endpointDescription: String?

    /// True when this peer's fingerprint matches a known `_fed_peers` entry.
    ///
    /// TRUST NOTE: "verified" means "we have previously completed a signed
    /// pairing ceremony with this estate identity." It does NOT automatically
    /// open a session. The session lifecycle (FED-OD-4) still requires user
    /// intent. A peer with `isVerified == false` is unknown to this estate;
    /// the user must initiate pairing (FED-OD-3) before any federation session.
    public let isVerified: Bool

    public init(
        fingerprint: String,
        displayName: String,
        relayPort: UInt16,
        protocolVersion: String,
        endpointDescription: String?,
        isVerified: Bool
    ) {
        self.fingerprint = fingerprint
        self.displayName = displayName
        self.relayPort = relayPort
        self.protocolVersion = protocolVersion
        self.endpointDescription = endpointDescription
        self.isVerified = isVerified
    }
}

// MARK: - Visibility Setting

/// Three-position discoverability setting (AirDrop-style).
///
/// Persisted in UserDefaults under `DiscoveryVisibilityPolicy.defaultsKey`.
/// Both browsing (finding others) and advertising (being findable) gate on
/// this value. The default is `off` — Mootx01 estates are not discoverable
/// on the LAN until the user explicitly enables this in the Federation panel.
public enum DiscoveryVisibility: Int, Sendable, CaseIterable {
    /// No mDNS activity. Neither browsing nor advertising runs. No local
    /// network traffic is generated by the federation discovery layer.
    case off = 0

    /// Browsing and advertising are active only while the app is in the
    /// foreground. Appropriate for iOS, where background networking requires
    /// additional entitlements.
    case whileOpen = 1

    /// Browsing and advertising run continuously, including in the background.
    /// Meaningful on the Mac resident; on iOS this is equivalent to `whileOpen`
    /// unless the app has background networking entitlements.
    case always = 2
}

/// UserDefaults persistence for `DiscoveryVisibility`.
///
/// Pattern mirrors `SyncPolicy` (CVK-WB2): pure-function enum with a
/// `defaultsKey` constant and a typed reader/writer, testable with a custom
/// `UserDefaults` suite.
public enum DiscoveryVisibilityPolicy {
    /// UserDefaults key for the federation discovery visibility setting.
    /// Bind via `@AppStorage(DiscoveryVisibilityPolicy.defaultsKey)` in SwiftUI.
    public static let defaultsKey = "federationDiscoveryVisibility"

    /// Reads the current setting.
    ///
    /// Returns `.off` when the key is absent (first run). Off is the default —
    /// the user must affirmatively enable LAN discovery.
    ///
    /// - Parameter defaults: The `UserDefaults` suite to query.
    public static func visibility(defaults: UserDefaults = .standard) -> DiscoveryVisibility {
        let raw = defaults.integer(forKey: defaultsKey)
        return DiscoveryVisibility(rawValue: raw) ?? .off
    }

    /// Writes `visibility` to `defaults`.
    ///
    /// - Parameters:
    ///   - visibility: The new visibility setting.
    ///   - defaults: The `UserDefaults` suite to write to.
    public static func setVisibility(_ visibility: DiscoveryVisibility, defaults: UserDefaults = .standard) {
        defaults.set(visibility.rawValue, forKey: defaultsKey)
    }
}

// MARK: - Protocol Seam

/// Abstraction over NWBrowser + NWListener for testability.
///
/// Production conformer: NWLANDiscoverySession (Network.framework, class).
/// Test conformer: FakeLANDiscoverySession (in-process, class).
///
/// This mirrors the RelayHTTPTransport / FakeRelayHTTPTransport precedent
/// (HostedRelay injects the transport; LANDiscovery injects the session).
/// Tests never spin up real NW stacks — they inject fake sessions and
/// drive discovery events synchronously.
///
/// Both conformers are AnyObject (class-only). This allows LANDiscovery to
/// hold a strong reference to the session and read back state after calls,
/// which is not possible with value-type (struct) existentials.
public protocol LANDiscoverySession: AnyObject, Sendable {
    /// Start advertising this estate on the LAN.
    ///
    /// - Parameters:
    ///   - txtRecord: The encoded TXT record ([String: String] from LANFederationTXTRecord.encode()).
    ///   - port: The TCP port to advertise (0 = OS-assigned).
    func startAdvertising(txtRecord: [String: String], port: UInt16) throws

    /// Stop advertising. Safe to call when not advertising.
    func stopAdvertising()

    /// Start browsing for peers advertising `_mootx01-fed._tcp`.
    ///
    /// - Parameter onPeerFound: Called for each discovered peer. The callback
    ///   receives: fingerprint string, decoded TXT record, optional endpoint
    ///   description. Called from the session's internal queue — callers must
    ///   synchronize if they update UI state. The closure must be @Sendable
    ///   because it is captured and invoked from background NW dispatch queues.
    func startBrowsing(onPeerFound: @escaping @Sendable (String, LANFederationTXTRecord, String?) -> Void)

    /// Stop browsing. Safe to call when not browsing.
    func stopBrowsing()
}

// MARK: - LANDiscovery

/// Manages LAN mDNS advertising and browsing for Federation.
///
/// Instantiate with a `LocalIdentity` (for fingerprint derivation), a display
/// name, a relay port, and (optionally) a set of known peer fingerprints for
/// the `isVerified` classification.
///
/// Inject a `LANDiscoverySession` conformer at init for testability:
///   - Production: NWLANDiscoverySession (Network.framework)
///   - Tests: FakeLANDiscoverySession
///
/// Both `startDiscovery()` and `stopDiscovery()` are safe to call from any
/// thread. The internal lock guards the peers dictionary.
///
/// TRUST NOTE: `LANDiscovery` is a read-only surface. It discovers reachability
/// and identity fingerprints. It does NOT establish connections, transmit estate
/// data, or make trust decisions. Trust is the responsibility of the WC6
/// pairing ceremony (QRPairingCoordinator, FED-OD-3) and the session lifecycle
/// (FederationSessionManager, FED-OD-4).
public final class LANDiscovery: @unchecked Sendable {
    // MARK: Configuration

    /// The TXT record this estate will advertise.
    public let localTXTRecord: LANFederationTXTRecord

    // MARK: State

    private let lock = NSLock()
    private let session: any LANDiscoverySession
    private var _peers: [String: DiscoveredPeer] = [:]  // keyed by fingerprint
    private var knownFingerprints: Set<String>
    private var isActive: Bool = false

    // MARK: Init

    /// Create a LANDiscovery instance.
    ///
    /// - Parameters:
    ///   - publicKey: This estate's Ed25519 public key (from LocalIdentity.publicKey).
    ///                Used to derive the short fingerprint placed in the TXT record.
    ///   - displayName: User-chosen estate name. Truncated to 63 bytes UTF-8.
    ///   - relayPort: The LANRelay TCP port (FED-OD-2). Use 0 if not yet known.
    ///   - knownFingerprints: Fingerprints of previously-paired peers (from
    ///                        `_fed_peers` via the engine layer). Used to set
    ///                        `DiscoveredPeer.isVerified`. Callers should refresh
    ///                        this set after pairing events complete.
    ///   - session: The NW session conformer. Defaults to `NWLANDiscoverySession`.
    ///              Inject `FakeLANDiscoverySession` in tests.
    public init(
        publicKey: Data,
        displayName: String,
        relayPort: UInt16 = 0,
        knownFingerprints: Set<String> = [],
        session: any LANDiscoverySession = NWLANDiscoverySession()
    ) {
        let fp = lanFingerprintFromPublicKey(publicKey)
        self.localTXTRecord = LANFederationTXTRecord(
            fingerprint: fp,
            displayName: displayName,
            relayPort: relayPort
        )
        self.knownFingerprints = knownFingerprints
        self.session = session
    }

    // MARK: Public API

    /// All currently visible peers, keyed by fingerprint.
    ///
    /// Thread-safe read. Updated as NWBrowser results arrive.
    public var discoveredPeers: [String: DiscoveredPeer] {
        lock.withLock { _peers }
    }

    /// Convenience accessor returning an array of all current peers.
    public var discoveredPeersArray: [DiscoveredPeer] {
        lock.withLock { Array(_peers.values) }
    }

    /// Update the set of known-paired fingerprints.
    ///
    /// Call after a pairing ceremony completes (FED-OD-3) or after loading
    /// `_fed_peers` from storage on engine enable. Re-classifies all currently
    /// visible peers.
    public func updateKnownFingerprints(_ fingerprints: Set<String>) {
        lock.withLock {
            knownFingerprints = fingerprints
            // Re-classify all currently-discovered peers with the updated set.
            _peers = _peers.mapValues { peer in
                let nowVerified = fingerprints.contains(peer.fingerprint)
                guard peer.isVerified != nowVerified else { return peer }
                return DiscoveredPeer(
                    fingerprint: peer.fingerprint,
                    displayName: peer.displayName,
                    relayPort: peer.relayPort,
                    protocolVersion: peer.protocolVersion,
                    endpointDescription: peer.endpointDescription,
                    isVerified: nowVerified
                )
            }
        }
    }

    /// Start advertising and browsing on the LAN.
    ///
    /// No-op if already active. Both advertising and browsing start together.
    /// Visibility semantics (Off/WhileOpen/Always) are enforced by the caller
    /// (e.g., the Federation panel) before calling this method — LANDiscovery
    /// itself does not read UserDefaults.
    ///
    /// - Throws: If the underlying NW session fails to start advertising.
    public func startDiscovery() throws {
        // Atomically check and set isActive. Returns false when already active
        // (idempotent — second call is a no-op).
        var didActivate = false
        lock.withLock {
            if !isActive {
                isActive = true
                didActivate = true
            }
        }
        guard didActivate else { return }
        let txtRecord = localTXTRecord.encode()
        try session.startAdvertising(txtRecord: txtRecord, port: localTXTRecord.relayPort)
        session.startBrowsing { @Sendable [weak self] fingerprint, txtRecord, endpoint in
            self?.handlePeerFound(fingerprint: fingerprint, txtRecord: txtRecord, endpointDescription: endpoint)
        }
        logger.info("lan-discovery: started (fp=\(self.localTXTRecord.fingerprint, privacy: .public))")
    }

    /// Stop advertising and browsing. Clears the discovered peers list.
    ///
    /// Safe to call when not active.
    public func stopDiscovery() {
        var didDeactivate = false
        lock.withLock {
            if isActive {
                isActive = false
                _peers = [:]
                didDeactivate = true
            }
        }
        guard didDeactivate else { return }
        session.stopAdvertising()
        session.stopBrowsing()
        logger.info("lan-discovery: stopped")
    }

    // MARK: Internal peer update

    /// Handle a peer discovered by the session. Called from the session's
    /// startBrowsing callback — or directly by FakeLANDiscoverySession in tests.
    ///
    /// - Parameters:
    ///   - fingerprint: The peer's "fp" TXT value.
    ///   - txtRecord: The full decoded TXT record.
    ///   - endpointDescription: Human-readable endpoint string, or nil.
    func handlePeerFound(
        fingerprint: String,
        txtRecord: LANFederationTXTRecord,
        endpointDescription: String?
    ) {
        let isVerified: Bool
        lock.lock()
        isVerified = knownFingerprints.contains(fingerprint)
        lock.unlock()

        let peer = DiscoveredPeer(
            fingerprint: fingerprint,
            displayName: txtRecord.displayName,
            relayPort: txtRecord.relayPort,
            protocolVersion: txtRecord.protocolVersion,
            endpointDescription: endpointDescription,
            isVerified: isVerified
        )
        lock.withLock { _peers[fingerprint] = peer }
        logger.debug("lan-discovery: found peer fp=\(fingerprint, privacy: .public) name=\(txtRecord.displayName, privacy: .private) verified=\(isVerified, privacy: .public)")
    }

    /// Remove a peer that is no longer advertising.
    func handlePeerLost(fingerprint: String) {
        lock.lock()
        _peers.removeValue(forKey: fingerprint)
        lock.unlock()
        logger.debug("lan-discovery: lost peer fp=\(fingerprint, privacy: .public)")
    }
}

// MARK: - NWLANDiscoverySession (Production)

/// Production LANDiscoverySession backed by Network.framework.
///
/// Uses NWListener to advertise this estate and NWBrowser to discover peers.
/// Both run on a serial dispatch queue to avoid concurrent NW state mutations.
public final class NWLANDiscoverySession: LANDiscoverySession, @unchecked Sendable {
    private var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.mootx01.lan-discovery", qos: .utility)

    public init() {}

    public func startAdvertising(txtRecord: [String: String], port: UInt16) throws {
        // Build NWTXTRecord using the subscript [String: String?] API.
        // encode() returns [String: String] — all four keys have valid string values.
        var nwTXT = NWTXTRecord()
        for (key, value) in txtRecord {
            nwTXT[key] = value
        }

        let params = NWParameters.tcp
        params.includePeerToPeer = true

        // Port 0 = OS-assigned. For a known relay port, use it explicitly.
        let nwPort: NWEndpoint.Port = port > 0 ? NWEndpoint.Port(rawValue: port)! : .any
        let l = try NWListener(using: params, on: nwPort)

        l.service = NWListener.Service(name: nil, type: LANFederationServiceType, txtRecord: nwTXT)
        l.serviceRegistrationUpdateHandler = { change in
            switch change {
            case .add(let endpoint):
                logger.debug("lan-discovery: advertiser registered endpoint \(String(describing: endpoint), privacy: .public)")
            case .remove(let endpoint):
                logger.debug("lan-discovery: advertiser removed endpoint \(String(describing: endpoint), privacy: .public)")
            @unknown default:
                break
            }
        }
        l.stateUpdateHandler = { state in
            logger.debug("lan-discovery: listener state \(String(describing: state), privacy: .public)")
        }
        l.newConnectionHandler = { connection in
            // FED-OD-1 scope: discovery only. Incoming TCP connections arriving at
            // the discovery listener are cancelled — actual relay connections are
            // handled by LANRelay (FED-OD-2) on its own port.
            connection.cancel()
        }
        l.start(queue: queue)
        listener = l
        logger.info("lan-discovery: NWListener started for \(LANFederationServiceType, privacy: .public)")
    }

    public func stopAdvertising() {
        listener?.cancel()
        listener = nil
        logger.info("lan-discovery: NWListener stopped")
    }

    public func startBrowsing(onPeerFound: @escaping @Sendable (String, LANFederationTXTRecord, String?) -> Void) {
        let descriptor = NWBrowser.Descriptor.bonjour(type: LANFederationServiceType, domain: "local.")
        let params = NWParameters()
        params.includePeerToPeer = true

        let b = NWBrowser(for: descriptor, using: params)
        b.browseResultsChangedHandler = { results, changes in
            for change in changes {
                switch change {
                case .added(let result):
                    if let txt = NWLANDiscoverySession.extractTXTRecord(from: result) {
                        let endpoint = NWLANDiscoverySession.endpointDescription(for: result)
                        onPeerFound(txt.fingerprint, txt, endpoint)
                    }
                case .changed(old: _, new: let result, flags: _):
                    // A changed result means the peer updated its TXT record.
                    // Re-deliver as an update so callers see the latest metadata.
                    if let txt = NWLANDiscoverySession.extractTXTRecord(from: result) {
                        let endpoint = NWLANDiscoverySession.endpointDescription(for: result)
                        onPeerFound(txt.fingerprint, txt, endpoint)
                    }
                case .removed:
                    // Peer removal is not surfaced via onPeerFound — future work
                    // can add an onPeerLost callback if needed for FED-OD-6 UI.
                    break
                case .identical:
                    break
                @unknown default:
                    break
                }
            }
        }
        b.stateUpdateHandler = { state in
            logger.debug("lan-discovery: browser state \(String(describing: state), privacy: .public)")
        }
        b.start(queue: queue)
        browser = b
        logger.info("lan-discovery: NWBrowser started for \(LANFederationServiceType, privacy: .public)")
    }

    public func stopBrowsing() {
        browser?.cancel()
        browser = nil
        logger.info("lan-discovery: NWBrowser stopped")
    }

    // MARK: Helpers

    /// Extract and decode the TXT record from an NWBrowser result.
    ///
    /// Returns nil if the result has no metadata, if the metadata is not a TXT
    /// record, or if the decoded record is missing the mandatory "fp" field.
    ///
    /// NWTXTRecord is a Sequence of (String, NWTXTRecord.Entry) tuples.
    /// We iterate keys and use the String subscript r[key] -> String? to extract
    /// values — the Entry type is opaque but the subscript returns String?.
    private static func extractTXTRecord(from result: NWBrowser.Result) -> LANFederationTXTRecord? {
        guard case .bonjour(let txt) = result.metadata else { return nil }
        var dict: [String: String] = [:]
        for (key, _) in txt {
            if let v = txt[key] {
                dict[key] = v
            }
        }
        return LANFederationTXTRecord.decode(dict)
    }

    /// Human-readable description of the endpoint for a browser result.
    private static func endpointDescription(for result: NWBrowser.Result) -> String? {
        switch result.endpoint {
        case .service(let name, let type_, let domain, _):
            return "\(name).\(type_)\(domain)"
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return nil
        }
    }
}

// MARK: - FakeLANDiscoverySession (Tests)

/// In-process fake for LANDiscoverySession. Used in LANDiscoveryTests.
///
/// Records start/stop calls so tests can assert on the advertise/browse lifecycle.
/// `simulatePeerFound` injects synthetic peer events synchronously into the
/// discovery callback provided by LANDiscovery.startBrowsing.
///
/// This mirrors FakeRelayHTTPTransport's role for HostedRelay tests.
public final class FakeLANDiscoverySession: LANDiscoverySession, @unchecked Sendable {
    // MARK: Recorded call state (assertions in tests)

    /// Number of times startAdvertising was called.
    public private(set) var advertiseCallCount: Int = 0

    /// Number of times stopAdvertising was called.
    public private(set) var stopAdvertiseCallCount: Int = 0

    /// Number of times startBrowsing was called.
    public private(set) var browseCallCount: Int = 0

    /// Number of times stopBrowsing was called.
    public private(set) var stopBrowseCallCount: Int = 0

    /// The last TXT record dict passed to startAdvertising.
    public private(set) var lastAdvertisedTXTRecord: [String: String]? = nil

    /// Whether advertising is currently active.
    public private(set) var isAdvertising: Bool = false

    /// Whether browsing is currently active.
    public private(set) var isBrowsing: Bool = false

    /// The peer-found callback supplied by LANDiscovery.startBrowsing.
    /// Tests call simulatePeerFound to drive synthetic discovery events.
    private var peerFoundCallback: (@Sendable (String, LANFederationTXTRecord, String?) -> Void)?

    public init() {}

    public func startAdvertising(txtRecord: [String: String], port: UInt16) throws {
        advertiseCallCount += 1
        isAdvertising = true
        lastAdvertisedTXTRecord = txtRecord
    }

    public func stopAdvertising() {
        stopAdvertiseCallCount += 1
        isAdvertising = false
    }

    public func startBrowsing(onPeerFound: @escaping @Sendable (String, LANFederationTXTRecord, String?) -> Void) {
        browseCallCount += 1
        isBrowsing = true
        peerFoundCallback = onPeerFound
    }

    public func stopBrowsing() {
        stopBrowseCallCount += 1
        isBrowsing = false
        peerFoundCallback = nil
    }

    /// Inject a synthetic peer discovery event into the owning LANDiscovery.
    ///
    /// Call this from tests to simulate a peer appearing on the network.
    /// The callback is invoked synchronously on the calling thread.
    public func simulatePeerFound(
        fingerprint: String,
        txtRecord: LANFederationTXTRecord,
        endpoint: String? = "fake-peer.local"
    ) {
        peerFoundCallback?(fingerprint, txtRecord, endpoint)
    }
}
