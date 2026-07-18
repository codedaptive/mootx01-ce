// FakeLANRelayTransport.swift — ConvergenceKitFederationTests
//
// In-memory loopback transport for LANRelay conformance and unit tests (FED-OD-2).
//
// DESIGN:
//   FakeLANRelayTransport implements the LANRelayTransport seam without any sockets,
//   TLS, or network I/O. It routes `send(to:message:)` directly into an in-memory
//   inbox dict keyed by recipient public key, and `drain(for:)` reads and clears
//   that dict. This creates a loopback: the relay sends to itself, so the conformance
//   fixture (which uses the same key for send-destination and drain-source) exercises
//   the full LANRelay contract in a single-process, deterministic test context.
//
//   Production semantic mapping:
//     send(to: peerKey)    → establish NWConnection to peerKey's endpoint, write
//     drain(for: ownKey)   → read from NWListener's local receive buffer for ownKey
//   Test semantic (loopback):
//     send(to: key)        → inboxes[key].append(envelope)
//     drain(for: key)      → reads and clears inboxes[key]
//
//   This is structurally identical to FederationRelay (in-process buffer), which
//   is intentional: the conformance rows don't test HOW the envelope reaches the
//   buffer — they test THAT it arrives intact.
//
// TLS-REFUSED TESTING:
//   `FakeLANRelayTransport` has an optional `knownPeers` set. When provided,
//   `send(to:message:)` throws `SyncError.peerUnreachable` if the recipient key
//   is NOT in the set — mimicking the production TLS verifier's rejection behavior.
//   Tests that verify "TLS refused on unknown key" inject a restricted fake.
//
// THREAD SAFETY:
//   NSLock-guarded. Tests drive the relay synchronously; the lock is defensive.

import Foundation
@testable import ConvergenceKitFederation
import ConvergenceKit

// MARK: - FakeLANRelayTransport

/// In-memory loopback LANRelayTransport for unit tests.
///
/// Instantiate with no arguments for an open loopback (all keys accepted):
/// ```swift
/// let transport = FakeLANRelayTransport()
/// let relay = LANRelay(transport: transport)
/// ```
///
/// Instantiate with `knownPeers` to simulate TLS peer verification:
/// ```swift
/// let transport = FakeLANRelayTransport(knownPeers: [knownKey])
/// let relay = LANRelay(transport: transport)
/// // send to unknownKey → throws SyncError.peerUnreachable
/// ```
final class FakeLANRelayTransport: LANRelayTransport, @unchecked Sendable {

    // MARK: State

    private let lock = NSLock()

    /// Inbound buffer per recipient public key.
    /// Populated by `send(to:message:)` (loopback); drained by `drain(for:)`.
    private var inboxes: [Data: [SignedEnvelope]] = [:]

    /// Optional set of accepted peer public keys (simulates _fed_peers for TLS verify).
    /// nil = accept all (default for conformance tests).
    /// non-nil = reject sends to keys not in the set with peerUnreachable.
    private let knownPeers: Set<Data>?

    // MARK: Init

    /// Create an open loopback transport (accepts all recipient keys).
    /// Use for conformance tests (Suite 3) and general LANRelay unit tests.
    init() {
        self.knownPeers = nil
    }

    /// Create a peer-restricted transport (simulates TLS identity verification).
    ///
    /// - Parameter knownPeers: Set of accepted recipient public keys. Sends to
    ///   any key not in this set throw `SyncError.peerUnreachable`, mirroring
    ///   the production TLS verifier's behavior for unknown-key rejection.
    init(knownPeers: Set<Data>) {
        self.knownPeers = knownPeers
    }

    // MARK: - LANRelayTransport

    /// Deliver an envelope to a recipient's loopback inbox.
    ///
    /// If `knownPeers` is set and `peerPublicKey` is not in it, throws
    /// `SyncError.peerUnreachable` (simulates TLS handshake refusal for unknown key).
    func send(to peerPublicKey: Data, message: SignedEnvelope) throws {
        // Simulate TLS identity verification gate.
        if let peers = knownPeers, !peers.contains(peerPublicKey) {
            throw SyncError.peerUnreachable(identity: peerPublicKey.hexPrefix)
        }

        lock.lock()
        defer { lock.unlock() }
        inboxes[peerPublicKey, default: []].append(message)
    }

    /// Drain (and clear) the loopback inbox for a recipient key.
    /// Non-throwing: always returns the current buffer contents (may be empty).
    func drain(for recipientPublicKey: Data) -> [SignedEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        let msgs = inboxes[recipientPublicKey] ?? []
        inboxes[recipientPublicKey] = []
        return msgs
    }

    // MARK: - Test inspection helpers

    /// Current inbox depth for a key (for assertions without draining).
    func inboxCount(for key: Data) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return inboxes[key]?.count ?? 0
    }

    /// Reset all inbox state (useful between test cases sharing a transport instance).
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        inboxes.removeAll()
    }
}

// MARK: - Data hex prefix helper (test-only display use)

private extension Data {
    /// Short hex prefix for use in error messages and test diagnostics.
    var hexPrefix: String {
        prefix(4).map { String(format: "%02x", $0) }.joined() + "…"
    }
}
