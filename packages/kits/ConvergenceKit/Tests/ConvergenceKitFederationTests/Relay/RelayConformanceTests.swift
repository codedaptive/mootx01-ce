// RelayConformanceTests.swift — ConvergenceKitFederationTests
//
// Shared relay conformance fixture (spec §6, CVK-WC7).
//
// Runs the spec §6 checklist against two relay implementations:
//   1. FederationRelay — the in-process reference implementation (§6.1)
//   2. HostedRelay     — the HTTPS conformer against FakeRelayHTTPTransport (§6.2)
//
// Spec reference: docs/reference/FEDERATION_SYNCSERVER_WIRE_PROTOCOL.md v0.1
// INTERFACE reference: CONVERGENCEKIT_INTERFACE.md §4 Relay abstraction
//
// DESIGN: The core conformance rows run against BOTH relays via a shared
// `runCoreConformance` function. HostedRelay-specific rows (HTTP status
// mapping, protocol version header, 409 dedup at the HTTP layer, unregistered
// 404→peerUnreachable) are in a separate HostedRelay-only suite.

import Testing
import Foundation
import SubstrateTypes
import ConvergenceKit
@testable import ConvergenceKitFederation

// MARK: - Test identity helpers

/// Build a minimal self-signed test SignedEnvelope from a given LocalIdentity.
/// The payload is a single empty `[SyncRecord]` JSON array (valid syncRecordBatch).
private func makeTestEnvelope(
    sender: LocalIdentity,
    hlcSeed: Int64 = 1_000_000_000
) throws -> SignedEnvelope {
    let records: [SyncRecord] = []
    let payload = try JSONEncoder().encode(records)
    // PackedHLC requires wrapping through HLC (no memberwise init; only init(_ hlc: HLC)).
    let batchHLC = PackedHLC(HLC(physicalTime: hlcSeed, logicalCount: 0, nodeID: 7))
    let sigBytes = envelopeSigningBytes(
        senderPublicKey: sender.publicKey,
        payloadKind: .syncRecordBatch,
        payload: payload,
        hlc: batchHLC
    )
    let signature = try sender.sign(sigBytes)
    return SignedEnvelope(
        senderPublicKey: sender.publicKey,
        payloadKind: .syncRecordBatch,
        payload: payload,
        signature: signature,
        hlc: batchHLC
    )
}

// MARK: - Shared conformance function (spec §6 rows common to both relays)

/// Run the core relay conformance checklist against any Relay implementation.
///
/// - Parameters:
///   - relay: The relay under test.
///   - inboxKey: The recipient public key whose inbox is being tested.
///     For HostedRelay, `register(publicKey: inboxKey)` must be called before this.
///   - senderIdentity: The sender's local identity (used to sign test envelopes).
private func runCoreConformance(
    relay: some Relay,
    inboxKey: Data,
    senderIdentity: LocalIdentity
) throws {
    // ── Row 1: Empty inbox before any send ──────────────────────────────────
    // spec §6.1 "drain of unknown recipient returns empty array"
    let beforeSend = relay.drain(for: inboxKey)
    #expect(beforeSend.isEmpty, "inbox must be empty before any send")

    // ── Row 2: Send routes to recipient inbox ────────────────────────────────
    // spec §6.1 "send delivers envelope to recipient inbox"
    let envelope = try makeTestEnvelope(sender: senderIdentity)
    try relay.send(to: inboxKey, message: envelope)

    // ── Row 3: Drain delivers the envelope ───────────────────────────────────
    // spec §6.1 "drain clears and returns all pending envelopes for recipient"
    let received = relay.drain(for: inboxKey)
    #expect(received.count == 1, "drain must return the sent envelope")

    // ── Row 4: Envelope fidelity (byte-round-trip) ───────────────────────────
    // spec §6.2 "Signature canonical bytes match: envelopeSigningBytes byte-identical"
    // We verify the payload survived intact through send → drain.
    guard let first = received.first else {
        Issue.record("no envelope received after send")
        return
    }
    #expect(first.senderPublicKey == envelope.senderPublicKey,
            "senderPublicKey must survive the relay round-trip")
    #expect(first.payloadKind == envelope.payloadKind,
            "payloadKind must survive the relay round-trip")
    #expect(first.payload == envelope.payload,
            "payload bytes must be byte-identical after relay round-trip")
    #expect(first.signature == envelope.signature,
            "signature must survive the relay round-trip")
    #expect(first.hlc.physicalTime == envelope.hlc.physicalTime,
            "HLC physicalTime must survive the relay round-trip")
    #expect(first.hlc.logicalCount == envelope.hlc.logicalCount,
            "HLC logicalCount must survive the relay round-trip")
    #expect(first.hlc.nodeID == envelope.hlc.nodeID,
            "HLC nodeID must survive the relay round-trip")

    // Verify signature verifies against the original signing bytes.
    let signingBytes = envelopeSigningBytes(
        senderPublicKey: first.senderPublicKey,
        payloadKind: first.payloadKind,
        payload: first.payload,
        hlc: first.hlc
    )
    #expect(FederationSignature.verify(first.signature, of: signingBytes, by: senderIdentity.publicKey),
            "relayed envelope signature must verify against sender's public key")

    // ── Row 5: Second drain is empty (idempotency from caller perspective) ────
    // FederationRelay: inboxes[key] was cleared.
    // HostedRelay: cursor advanced past all seqnos; server returns empty next poll.
    let secondDrain = relay.drain(for: inboxKey)
    #expect(secondDrain.isEmpty, "second drain must return empty (cursor/cleared)")

    // ── Row 6: Unregistered sender key — no special error (relay is dumb) ────
    // The RELAY protocol does NOT authenticate senders at the transport layer.
    // An envelope from an unknown key is accepted by the relay and rejected by
    // the ENGINE's pull() guard. The relay.send call must not throw here.
    // (The engine-level security is tested in FederationStubTests / pull guards.)
    let unknownSender = LocalIdentity()
    let unknownEnvelope = try makeTestEnvelope(sender: unknownSender, hlcSeed: 2_000_000_000)
    try relay.send(to: inboxKey, message: unknownEnvelope)
    let unknownReceived = relay.drain(for: inboxKey)
    #expect(unknownReceived.count == 1,
            "relay must accept and deliver envelope from unregistered sender (dumb relay)")
}

// MARK: - Suite 1: Core conformance — FederationRelay (reference)

@Suite("Relay conformance — FederationRelay (reference implementation)")
struct FederationRelayConformanceTests {

    @Test("core conformance checklist (spec §6.1)")
    func coreConformance() throws {
        let relay = FederationRelay()
        let recipient = LocalIdentity()
        let sender = LocalIdentity()
        // FederationRelay has no registration concept; drain for any key starts empty.
        try runCoreConformance(relay: relay, inboxKey: recipient.publicKey, senderIdentity: sender)
    }

    @Test("multiple recipients: envelopes route to correct inbox")
    func multipleRecipients() throws {
        let relay = FederationRelay()
        let aliceSender = LocalIdentity()
        let aliceInbox: Data = aliceSender.publicKey
        let bob = LocalIdentity()

        let envForAlice = try makeTestEnvelope(sender: aliceSender, hlcSeed: 100)
        let envForBob = try makeTestEnvelope(sender: aliceSender, hlcSeed: 200)

        try relay.send(to: aliceInbox, message: envForAlice)
        try relay.send(to: bob.publicKey, message: envForBob)

        let aliceReceived = relay.drain(for: aliceInbox)
        let bobReceived = relay.drain(for: bob.publicKey)

        #expect(aliceReceived.count == 1, "Alice should receive exactly one envelope")
        #expect(bobReceived.count == 1, "Bob should receive exactly one envelope")
        #expect(aliceReceived[0].hlc.physicalTime == 100, "Alice received wrong envelope")
        #expect(bobReceived[0].hlc.physicalTime == 200, "Bob received wrong envelope")
    }

    @Test("unknown recipient returns empty array")
    func unknownRecipientEmpty() throws {
        let relay = FederationRelay()
        let ghostKey = LocalIdentity().publicKey
        #expect(relay.drain(for: ghostKey).isEmpty, "drain for unknown key must be empty")
    }

    @Test("at-least-once: re-send same envelope does not lose delivery")
    func atLeastOnceResend() throws {
        let relay = FederationRelay()
        let recipient = LocalIdentity()
        let sender = LocalIdentity()
        let envelope = try makeTestEnvelope(sender: sender, hlcSeed: 12345)

        // Send twice — simulates durable-outbox retry.
        // FederationRelay stores both (no dedup at relay level; engine LWW handles it).
        try relay.send(to: recipient.publicKey, message: envelope)
        try relay.send(to: recipient.publicKey, message: envelope)

        let received = relay.drain(for: recipient.publicKey)
        // Engine-level idempotency (LWW gate) handles duplicates; both arrived.
        #expect(received.count >= 1, "at least one delivery must succeed")
    }
}

// MARK: - Suite 2: Core conformance — HostedRelay via fake server (§6.2)

@Suite("Relay conformance — HostedRelay (via FakeRelayHTTPTransport, spec §6.2)")
struct HostedRelayConformanceTests {

    private static let testBaseURL = URL(string: "https://relay.test")!
    private static let testBearerToken = "test-bearer-token"

    // Convenience: make a fresh (relay, transport) pair with recipient registered.
    private func makeRelay(recipientKey: Data) throws -> (HostedRelay, FakeRelayHTTPTransport) {
        let transport = FakeRelayHTTPTransport()
        let relay = HostedRelay(
            baseURL: Self.testBaseURL,
            bearerToken: Self.testBearerToken,
            transport: transport
        )
        try relay.register(publicKey: recipientKey)
        return (relay, transport)
    }

    // ── Core conformance ──────────────────────────────────────────────────────

    @Test("core conformance checklist (spec §6.2)")
    func coreConformance() throws {
        let recipient = LocalIdentity()
        let sender = LocalIdentity()
        let (relay, _) = try makeRelay(recipientKey: recipient.publicKey)
        try runCoreConformance(relay: relay, inboxKey: recipient.publicKey, senderIdentity: sender)
    }

    // ── HostedRelay-specific rows (spec §6.2 second table) ────────────────────

    @Test("register — POST /v1/register succeeds")
    func registerSucceeds() throws {
        let transport = FakeRelayHTTPTransport()
        let relay = HostedRelay(
            baseURL: Self.testBaseURL,
            bearerToken: Self.testBearerToken,
            transport: transport
        )
        let identity = LocalIdentity()
        // Must not throw.
        try relay.register(publicKey: identity.publicKey)
    }

    @Test("bearer token present on every request (spec §2.1 + §5.1)")
    func bearerTokenPresent() throws {
        // We verify via the fake: if the bearer token were missing the fake
        // server would need to check it, but for this test we verify the
        // transport receives it. Use a recording transport.
        let recordingTransport = RecordingRelayHTTPTransport()
        let relay = HostedRelay(
            baseURL: Self.testBaseURL,
            bearerToken: "expected-token",
            transport: recordingTransport
        )

        let recipient = LocalIdentity()
        let sender = LocalIdentity()
        let envelope = try makeTestEnvelope(sender: sender)

        // We can't call send without a real register; use recording to verify headers.
        // Inject a stubbed response for send.
        let sendURL = Self.testBaseURL.appendingPathComponent("v1/send/\(recipient.publicKey.hex)")
        recordingTransport.stub(url: sendURL, statusCode: 202,
                                body: #"{"accepted":true,"seqno":1}"#.data(using: .utf8)!)

        _ = try? relay.send(to: recipient.publicKey, message: envelope)

        // Verify bearer token and protocol version header were present.
        let sentRequests = recordingTransport.recordedRequests
        for req in sentRequests {
            #expect(req.headers["Authorization"] == "Bearer expected-token",
                    "Authorization header must be present on every request")
            #expect(req.headers["X-Sync-Protocol"] == "1",
                    "X-Sync-Protocol: 1 must be present on every request (spec §5.1)")
        }
    }

    @Test("401 response → authenticationFailed (spec §4)")
    func authFailureMaps401() throws {
        let transport = FakeRelayHTTPTransport()
        let relay = HostedRelay(
            baseURL: Self.testBaseURL,
            bearerToken: "bad-token",
            transport: transport
        )

        // Re-register doesn't auth-check (the fake always accepts register).
        // Manually verify: if send returned 401 we get authenticationFailed.
        // We use a stub transport to force 401.
        let stubTransport = StubbedRelayHTTPTransport(
            statusCode: 401,
            body: #"{"error":"token_invalid","detail":"invalid bearer token"}"#.data(using: .utf8)!
        )
        let relay401 = HostedRelay(
            baseURL: Self.testBaseURL,
            bearerToken: "bad",
            transport: stubTransport
        )
        let recipient = LocalIdentity()
        let sender = LocalIdentity()
        let envelope = try makeTestEnvelope(sender: sender)

        do {
            try relay401.send(to: recipient.publicKey, message: envelope)
            Issue.record("expected authenticationFailed, got no error")
        } catch SyncError.authenticationFailed {
            // correct
        } catch {
            Issue.record("expected authenticationFailed, got \(error)")
        }
    }

    @Test("404 response → peerUnreachable (spec §4)")
    func notFoundMapsPeerUnreachable() throws {
        let stubTransport = StubbedRelayHTTPTransport(
            statusCode: 404,
            body: #"{"error":"recipient_not_found","detail":"recipient public key not registered"}"#.data(using: .utf8)!
        )
        let relay = HostedRelay(
            baseURL: Self.testBaseURL,
            bearerToken: "tok",
            transport: stubTransport
        )
        let recipient = LocalIdentity()
        let sender = LocalIdentity()
        let envelope = try makeTestEnvelope(sender: sender)

        do {
            try relay.send(to: recipient.publicKey, message: envelope)
            Issue.record("expected peerUnreachable, got no error")
        } catch SyncError.peerUnreachable {
            // correct — 404 maps to peerUnreachable per spec §4
        } catch {
            Issue.record("expected peerUnreachable, got \(error)")
        }
    }

    @Test("409 response treated as success (spec §3.2 — server dedup)")
    func duplicateSend409TreatedAsSuccess() throws {
        let recipient = LocalIdentity()
        let sender = LocalIdentity()
        let (relay, _) = try makeRelay(recipientKey: recipient.publicKey)
        let envelope = try makeTestEnvelope(sender: sender, hlcSeed: 9_999)

        // First send: succeeds (202)
        try relay.send(to: recipient.publicKey, message: envelope)
        // Second send of SAME envelope: server returns 409 (dedup). Must NOT throw.
        try relay.send(to: recipient.publicKey, message: envelope)

        // After both sends (one real, one duped), inbox has exactly one item.
        // The HostedRelay cursor advanced on first drain, so a fresh drain sees 1.
        let received = relay.drain(for: recipient.publicKey)
        #expect(received.count == 1, "server-side dedup must prevent duplicate inbox entry")
    }

    @Test("cursor advances: poll with after={seqno} returns only newer envelopes (spec §1.2)")
    func cursorAdvances() throws {
        let recipient = LocalIdentity()
        let sender = LocalIdentity()
        let (relay, _) = try makeRelay(recipientKey: recipient.publicKey)

        // Send two distinct envelopes.
        let env1 = try makeTestEnvelope(sender: sender, hlcSeed: 1_000)
        let env2 = try makeTestEnvelope(sender: sender, hlcSeed: 2_000)

        try relay.send(to: recipient.publicKey, message: env1)

        // First drain: sees env1, cursor advances to seqno=1.
        let firstBatch = relay.drain(for: recipient.publicKey)
        #expect(firstBatch.count == 1)
        #expect(firstBatch[0].hlc.physicalTime == 1_000)

        try relay.send(to: recipient.publicKey, message: env2)

        // Second drain: sees only env2 (cursor skips past seqno=1).
        let secondBatch = relay.drain(for: recipient.publicKey)
        #expect(secondBatch.count == 1)
        #expect(secondBatch[0].hlc.physicalTime == 2_000)
    }

    @Test("network error on send → transportFailure thrown (spec §4)")
    func networkErrorMapsTranportFailure() throws {
        let brokenTransport = BrokenRelayHTTPTransport()
        let relay = HostedRelay(
            baseURL: Self.testBaseURL,
            bearerToken: "tok",
            transport: brokenTransport
        )
        let recipient = LocalIdentity()
        let sender = LocalIdentity()
        let envelope = try makeTestEnvelope(sender: sender)

        do {
            try relay.send(to: recipient.publicKey, message: envelope)
            Issue.record("expected transportFailure, got no error")
        } catch SyncError.transportFailure {
            // correct — network error maps to transportFailure per spec §4
        } catch {
            Issue.record("expected transportFailure, got \(error)")
        }
    }

    @Test("drain on network error returns [] (non-throwing, degraded gracefully)")
    func drainNetworkErrorReturnsEmpty() {
        let brokenTransport = BrokenRelayHTTPTransport()
        let relay = HostedRelay(
            baseURL: Self.testBaseURL,
            bearerToken: "tok",
            transport: brokenTransport
        )
        let recipient = LocalIdentity()
        // drain is non-throwing; network error must return [] not crash.
        let result = relay.drain(for: recipient.publicKey)
        #expect(result.isEmpty, "drain on network error must return [] (at-least-once retry on next cycle)")
    }
}

// MARK: - Suite 3: Core conformance — LANRelay (via FakeLANRelayTransport, loopback)

// Note on loopback semantics (Kong V1, FED-OD charter):
//   `runCoreConformance` uses the SAME key for send-destination and drain-source.
//   In production two separate LANRelay instances communicate; here a single relay
//   with FakeLANRelayTransport (loopback) satisfies the contract because the seam
//   routes sends directly into the drain buffer for the same key. This is identical
//   to how FederationRelay works in-process — the fixture tests WHAT arrives, not HOW.

@Suite("Relay conformance — LANRelay (via FakeLANRelayTransport, loopback, spec §6.3)")
struct LANRelayConformanceTests {

    // Convenience: make a (relay, transport) pair with a plain open-loopback transport.
    private func makeRelay() -> (LANRelay, FakeLANRelayTransport) {
        let transport = FakeLANRelayTransport()
        let relay = LANRelay(transport: transport)
        return (relay, transport)
    }

    // ── Core conformance ──────────────────────────────────────────────────────

    @Test("core conformance checklist (spec §6.3 — LANRelay loopback)")
    func coreConformance() throws {
        let (relay, _) = makeRelay()
        let recipient = LocalIdentity()
        let sender = LocalIdentity()
        // LANRelay has no registration step (unlike HostedRelay) — drain for any
        // key starts empty. FakeLANRelayTransport loopback routes sends to drain.
        try runCoreConformance(relay: relay, inboxKey: recipient.publicKey, senderIdentity: sender)
    }

    @Test("multiple recipients: envelopes route to correct inbox")
    func multipleRecipients() throws {
        let (relay, _) = makeRelay()
        let aliceSender = LocalIdentity()
        let bob = LocalIdentity()

        let envForAlice = try makeTestEnvelope(sender: aliceSender, hlcSeed: 300)
        let envForBob = try makeTestEnvelope(sender: aliceSender, hlcSeed: 400)

        try relay.send(to: aliceSender.publicKey, message: envForAlice)
        try relay.send(to: bob.publicKey, message: envForBob)

        let aliceReceived = relay.drain(for: aliceSender.publicKey)
        let bobReceived = relay.drain(for: bob.publicKey)

        #expect(aliceReceived.count == 1, "Alice should receive exactly one envelope")
        #expect(bobReceived.count == 1, "Bob should receive exactly one envelope")
        #expect(aliceReceived[0].hlc.physicalTime == 300, "Alice received wrong envelope")
        #expect(bobReceived[0].hlc.physicalTime == 400, "Bob received wrong envelope")
    }

    @Test("unknown recipient returns empty array")
    func unknownRecipientEmpty() {
        let (relay, _) = makeRelay()
        let ghostKey = LocalIdentity().publicKey
        #expect(relay.drain(for: ghostKey).isEmpty, "drain for unregistered key must be empty")
    }

    @Test("at-least-once: re-send same envelope does not lose delivery")
    func atLeastOnceResend() throws {
        let (relay, _) = makeRelay()
        let recipient = LocalIdentity()
        let sender = LocalIdentity()
        let envelope = try makeTestEnvelope(sender: sender, hlcSeed: 54321)

        // Send twice — simulates durable-outbox retry.
        // LANRelay/FakeLANRelayTransport stores both (no dedup at relay level;
        // engine LWW gate handles duplicates downstream).
        try relay.send(to: recipient.publicKey, message: envelope)
        try relay.send(to: recipient.publicKey, message: envelope)

        let received = relay.drain(for: recipient.publicKey)
        #expect(received.count >= 1, "at least one delivery must succeed on re-send")
    }

    // ── LANRelay-specific rows ─────────────────────────────────────────────────

    /// TLS-refused-on-unknown-key: send to a key not in _fed_peers → peerUnreachable.
    ///
    /// This row verifies the identity-pinning invariant (charter V2, FED-OD charter):
    ///   - The production TLS verifier refuses connections from unrecognized keys.
    ///   - FakeLANRelayTransport with `knownPeers` simulates this at the seam level.
    ///   - An unknown peer attempting to connect MUST result in SyncError.peerUnreachable.
    @Test("TLS refused: send to unknown peer key throws peerUnreachable (charter V2)")
    func tlsRefusedOnUnknownKey() throws {
        let knownKey = LocalIdentity()
        let unknownKey = LocalIdentity()

        // Build a transport that only accepts the known peer.
        let restrictedTransport = FakeLANRelayTransport(knownPeers: [knownKey.publicKey])
        let relay = LANRelay(transport: restrictedTransport)

        // Send to the KNOWN peer should succeed.
        let envelope = try makeTestEnvelope(sender: knownKey)
        try relay.send(to: knownKey.publicKey, message: envelope)
        // (no assertion needed — no throw = pass)

        // Send to the UNKNOWN peer must throw peerUnreachable (charter V2 invariant).
        let unknownEnvelope = try makeTestEnvelope(sender: unknownKey, hlcSeed: 9_000)
        var caughtExpectedError = false
        do {
            try relay.send(to: unknownKey.publicKey, message: unknownEnvelope)
            Issue.record("expected peerUnreachable for unknown peer, got no error")
        } catch SyncError.peerUnreachable {
            caughtExpectedError = true
        } catch {
            Issue.record("expected peerUnreachable for unknown peer, got: \(error)")
        }
        #expect(caughtExpectedError, "send to unrecognized peer key must throw peerUnreachable")
    }

    /// Envelope byte-fidelity over LAN framing: all fields survive the transport round-trip.
    ///
    /// Mirrors the core conformance Row 4 but tests explicitly that the fake transport
    /// preserves byte identity, confirming that a production LAN transport must do the same.
    @Test("envelope byte-fidelity: all fields byte-identical after LAN transport round-trip")
    func envelopeByteFidelity() throws {
        let (relay, _) = makeRelay()
        let recipient = LocalIdentity()
        let sender = LocalIdentity()
        let envelope = try makeTestEnvelope(sender: sender, hlcSeed: 7_777_777)

        try relay.send(to: recipient.publicKey, message: envelope)
        let received = relay.drain(for: recipient.publicKey)

        guard let got = received.first else {
            Issue.record("no envelope received — byte-fidelity test failed")
            return
        }

        // Verify every field of SignedEnvelope is byte-identical after transport.
        #expect(got.senderPublicKey == envelope.senderPublicKey,
                "senderPublicKey must be byte-identical after LAN transport")
        #expect(got.payloadKind == envelope.payloadKind,
                "payloadKind must be byte-identical after LAN transport")
        #expect(got.payload == envelope.payload,
                "payload must be byte-identical after LAN transport")
        #expect(got.signature == envelope.signature,
                "signature must be byte-identical after LAN transport")
        #expect(got.hlc.physicalTime == envelope.hlc.physicalTime,
                "HLC.physicalTime must be byte-identical after LAN transport")
        #expect(got.hlc.logicalCount == envelope.hlc.logicalCount,
                "HLC.logicalCount must be byte-identical after LAN transport")
        #expect(got.hlc.nodeID == envelope.hlc.nodeID,
                "HLC.nodeID must be byte-identical after LAN transport")
    }

    /// Connection teardown: after a transport is invalidated, subsequent drain calls
    /// return empty (clean teardown — no leaked buffer state from a prior session).
    ///
    /// In production the NWConnection/NWListener is closed at session end (FED-OD-4).
    /// Here we verify that a reset transport yields empty drain results, confirming
    /// the LANRelay does not hold buffer state beyond what the transport provides.
    @Test("connection teardown: drain returns empty after transport reset (clean teardown)")
    func connectionTeardownIsClean() throws {
        let (relay, transport) = makeRelay()
        let recipient = LocalIdentity()
        let sender = LocalIdentity()
        let envelope = try makeTestEnvelope(sender: sender, hlcSeed: 42_000)

        // Pre-teardown: send and verify delivery.
        try relay.send(to: recipient.publicKey, message: envelope)
        #expect(transport.inboxCount(for: recipient.publicKey) == 1,
                "should have one pending envelope before teardown")

        // Simulate connection teardown: reset the transport state.
        transport.reset()

        // Post-teardown: drain must return empty (no leaked state).
        let afterTeardown = relay.drain(for: recipient.publicKey)
        #expect(afterTeardown.isEmpty,
                "drain must return empty after transport reset (clean teardown)")
    }
}

// MARK: - Test-local transport helpers

/// Transport that records all requests it receives.
/// Used to verify headers (bearer token, X-Sync-Protocol).
final class RecordingRelayHTTPTransport: RelayHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var recordedRequests: [RelayHTTPRequest] = []
    private var stubs: [URL: RelayHTTPResponse] = [:]

    func stub(url: URL, statusCode: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        stubs[url] = RelayHTTPResponse(statusCode: statusCode, body: body)
    }

    func execute(_ request: RelayHTTPRequest) throws -> RelayHTTPResponse {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
        if let stub = stubs[request.url] { return stub }
        return RelayHTTPResponse(statusCode: 200, body: Data())
    }
}

/// Transport that always returns a fixed status code and body.
/// Used to test HTTP status → SyncError mapping without a full fake server.
final class StubbedRelayHTTPTransport: RelayHTTPTransport, Sendable {
    private let statusCode: Int
    private let body: Data

    init(statusCode: Int, body: Data) {
        self.statusCode = statusCode
        self.body = body
    }

    func execute(_ request: RelayHTTPRequest) throws -> RelayHTTPResponse {
        RelayHTTPResponse(statusCode: statusCode, body: body)
    }
}

/// Transport that always throws a network error.
/// Used to test error propagation without a server.
final class BrokenRelayHTTPTransport: RelayHTTPTransport, Sendable {
    enum FakeNetworkError: Error { case refused }

    func execute(_ request: RelayHTTPRequest) throws -> RelayHTTPResponse {
        throw FakeNetworkError.refused
    }
}
