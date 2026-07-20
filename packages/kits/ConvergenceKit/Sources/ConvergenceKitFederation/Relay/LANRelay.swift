// LANRelay.swift — ConvergenceKitFederation
//
// LANRelay: the third Relay conformer. Delivers SignedEnvelopes over an
// identity-pinned TLS channel on the local network (FED-OD-2).
//
// CONTRACT (spec §6, FED-OD charter V1):
//   send(to:message:)  — writes the envelope to the peer via the injected transport.
//   drain(for:)        — reads and clears the local receive buffer for the recipient.
//
// DESIGN — buffer semantics extended over a TLS socket:
//   LANRelay is structurally identical to FederationRelay (NSLock-guarded inbox dict)
//   with the send path delegated to LANRelayTransport instead of writing in-process.
//   The transport seam keeps all socket I/O out of the Relay contract:
//
//     ┌─────────────────────────────────────────────────────────────┐
//     │  LANRelay                                                    │
//     │    ┌──────────────────────────────────────────────────┐     │
//     │    │  inboxes: [Data:[SignedEnvelope]] (NSLock)        │     │
//     │    └──────────────────────────────────────────────────┘     │
//     │         ▲                              │                     │
//     │     drain()                         send()                   │
//     │         │                              ▼                     │
//     │    ┌──────────────┐       ┌────────────────────────┐        │
//     │    │ LANRelay     │       │  LANRelayTransport     │        │
//     │    │ local buffer │       │  (injected seam)       │        │
//     │    │              │◀──────│  .deliverReceived()    │        │
//     │    └──────────────┘       └────────────────────────┘        │
//     └─────────────────────────────────────────────────────────────┘
//
//   In production: LANRelayNWTransport wraps NWConnection (send) and NWListener
//   (receive → deliverReceived callback). TLS is configured via LANRelayTLSConfig.
//
//   In tests: FakeLANRelayTransport routes send() directly to its own in-memory
//   inboxes dict, no sockets involved. Tests call relay.drain() normally.
//
// TLS IDENTITY PINNING (FED-OD charter V2):
//   Production transport uses a self-signed P-256 certificate whose Subject
//   Alternative Name extension carries the hex fingerprint of the estate's Ed25519
//   public key (the identity persisted in _fed_identity, WC1). A custom
//   sec_protocol_options_set_verify_block (see LANRelayTLSConfig.swift) accepts ONLY
//   connections whose certificate fingerprint appears in _fed_peers.
//
//   Unknown peer → TLS handshake refused → send() throws SyncError.peerUnreachable.
//   This is the MITM defense for recurring connections (SAS is the first-contact
//   guarantee; the pinned cert is the recurring-connection guarantee — charter V2).
//
// DESIGN CONSTRAINTS:
//   - drain(for:) is NON-THROWING per the Relay protocol. Network errors must not
//     propagate from drain; the at-least-once guarantee comes from the durable outbox
//     retrying on the next push() cycle.
//   - LANRelay.send(to:message:) DOES throw (SyncError) on transport failure,
//     consistent with HostedRelay and the Relay protocol contract.
//   - The local buffer is cleared on drain, identical to FederationRelay semantics.
//   - No cursor management (unlike HostedRelay) — the buffer is local and ephemeral.
//     Restart clears the buffer; the durable outbox (WC2) handles re-delivery.
//
// PLATFORM SCOPE (FED-OD charter V7):
//   Apple-only for F1. Rust LANRelay is F2 scope (FED-OD-16).
//
// Spec references:
//   - docs/analysis/FED_OD_CHARTER.md §V1, §V2 (Kong review, 2026-07-18)
//   - docs/reference/CONVERGENCEKIT_INTERFACE.md §4 Relay abstraction
// Pairing and synchronization remain on-demand and explicitly authorized.

import Foundation
import ConvergenceKit
import os

private let logger = Logger(
    subsystem: "com.mootx01.synckit.federation",
    category: "LANRelay"
)

// MARK: - LANRelayTransport (seam)

/// Injectable transport for LANRelay.
///
/// Production conformer: `LANRelayNWTransport` (NWConnection + NWListener + TLS,
/// see LANRelayTLSConfig.swift for the identity-bound cert/verifier).
///
/// Test conformer: `FakeLANRelayTransport` (in-memory loopback, no sockets —
/// lives in the test target). Tests drive the full relay contract without any
/// real socket I/O.
///
/// - Note: The transport owns the outbound send path. Inbound delivery
///   is pushed into the LANRelay's local buffer via the `deliverReceived`
///   callback registered at init.
public protocol LANRelayTransport: Sendable {

    /// Send a signed envelope to a peer identified by `peerPublicKey`.
    ///
    /// The transport establishes (or reuses) a TLS connection to the peer's
    /// listening port and writes the framed envelope.
    ///
    /// - Throws: `SyncError.peerUnreachable` when the peer's TLS certificate
    ///   fingerprint is not in `_fed_peers` (unknown key).
    ///   `SyncError.transportFailure` on network errors.
    func send(to peerPublicKey: Data, message: SignedEnvelope) throws

    /// Drain all received envelopes for `recipientPublicKey` from the
    /// transport's inbound buffer.
    ///
    /// NON-THROWING: network errors return `[]` so the engine's pull cycle
    /// degrades gracefully. At-least-once is preserved by the durable outbox
    /// (WC2) retrying on the next push() cycle.
    ///
    /// In the production NW transport the buffer is populated by the
    /// background NWListener task. In `FakeLANRelayTransport` the buffer is
    /// populated by `send(to:message:)` routing to the same dict.
    func drain(for recipientPublicKey: Data) -> [SignedEnvelope]

    /// Close the transport's outbound channel.
    ///
    /// After `close()` returns, any call to `send(to:message:)` MUST throw
    /// (`SyncError.peerUnreachable` or `SyncError.transportFailure`) so the
    /// engine's push cycle retains outbox entries rather than delivering.
    ///
    /// Default implementation is a no-op. Production conformers (NWTransport)
    /// override to cancel the NWConnection; test conformers that need to verify
    /// session-end determinism override to set a closed flag. `LANRelay.closeChannel()`
    /// is the session-end call site — see FED-OD-4 session-end ordering.
    func close()
}

/// Default no-op `close()` so existing `LANRelayTransport` conformers (including
/// `FakeLANRelayTransport` used in conformance tests) do not need to implement it
/// unless they want to verify session-end channel-close semantics.
public extension LANRelayTransport {
    func close() { }
}

// MARK: - LANRelay

/// LAN Relay conformer — the third Relay implementation.
///
/// Delivers `SignedEnvelope` values over an identity-pinned TLS channel on the
/// local network. Designed as "FederationRelay's buffer semantics extended over
/// a TLS socket": the contract is identical; the transport is real TCP/TLS rather
/// than in-process dictionary writes.
///
/// Usage (production — inject a real NW transport):
/// ```swift
/// let tlsConfig = LANRelayTLSConfig(localIdentity: identity, knownPeers: fedPeersSet)
/// let transport = LANRelayNWTransport(tlsConfig: tlsConfig, port: 5090)
/// let relay = LANRelay(transport: transport)
/// try engine.enable(manifest: manifest, storage: storage, relay: relay)
/// ```
///
/// Usage (tests — inject the fake):
/// ```swift
/// let transport = FakeLANRelayTransport()
/// let relay = LANRelay(transport: transport)
/// // conformance fixture runs unchanged
/// ```
///
/// Relay contract:
///   - `send(to:message:)` — forwards to the injected transport. Throws on
///     transport failure or TLS rejection (unknown key).
///   - `drain(for:)` — reads and clears the local buffer. Non-throwing.
///   - `closeChannel()` — closes the transport channel; subsequent `send()` calls
///     throw so the engine retains outbox entries. Called by `FederationSessionManager`
///     as the session-end invariant: channel close FIRST, then engine.disable() (FED-OD-4).
public final class LANRelay: Relay, @unchecked Sendable {

    // MARK: Injected transport

    /// The transport seam (production: NWTransport; tests: FakeLANRelayTransport).
    private let transport: any LANRelayTransport

    // MARK: Init

    /// Create a LANRelay with an injected transport.
    ///
    /// - Parameter transport: The transport implementation to use. Production
    ///   callers supply `LANRelayNWTransport`; tests supply `FakeLANRelayTransport`.
    public init(transport: any LANRelayTransport) {
        self.transport = transport
    }

    // MARK: Relay.send

    /// Deliver a signed envelope to a peer's inbox over the LAN transport.
    ///
    /// Throws on transport failure or TLS rejection (unknown peer key).
    /// When `send` throws, the durable outbox retains the record for the next
    /// push() cycle's retry.
    public func send(to recipient: Data, message: SignedEnvelope) throws {
        do {
            try transport.send(to: recipient, message: message)
            logger.debug("lan-relay: sent envelope to \(recipient.prefix(4).hex, privacy: .public)…")
        } catch let err as SyncError {
            throw err
        } catch {
            // Wrap unexpected transport errors as transportFailure.
            throw SyncError.transportFailure(detail: "LAN send failed: \(error.localizedDescription)")
        }
    }

    // MARK: Relay.drain

    /// Drain (and clear) the local receive buffer for a recipient.
    ///
    /// Non-throwing: transport errors return `[]` and are logged. At-least-once
    /// delivery is preserved by the engine's pull() cycle and the durable outbox.
    public func drain(for recipient: Data) -> [SignedEnvelope] {
        let received = transport.drain(for: recipient)
        if !received.isEmpty {
            logger.debug("lan-relay: drained \(received.count) envelope(s) for \(recipient.prefix(4).hex, privacy: .public)…")
        }
        return received
    }

    // MARK: Session-end channel close

    /// Close the underlying transport channel.
    ///
    /// SESSION-END INVARIANT (FED-OD-4): `FederationSessionManager.endSession()`
    /// calls this BEFORE calling `engine.disable()`. The ordering is load-bearing:
    ///
    ///   After `closeChannel()` returns, any subsequent `transport.send()` throws
    ///   (peerUnreachable or transportFailure). The engine's push() cycle sees the
    ///   throw and retains the outbox entry — it is NOT delivered post-session.
    ///   `engine.disable()` then cancels observer tasks and stops new outbox writes.
    ///
    ///   If the order were reversed (disable first, close second), a push() racing
    ///   on the actor queue could drain the outbox into the still-open channel
    ///   between disable and close, delivering envelopes after the session closed.
    ///   Channel-close-first eliminates the race: any such push() gets a transport
    ///   error and retains entries.
    ///
    /// The durable _fed_outbox entries are NOT discarded on session end; they
    /// persist for delivery in the next session to the same peer (WC2 contract).
    public func closeChannel() {
        transport.close()
        logger.debug("lan-relay: channel closed — subsequent sends will fail")
    }
}
