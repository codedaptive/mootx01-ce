// QRPairingCoordinatorTests.swift
//
// FED-OD-3: QR pairing ceremony coordinator tests.
//
// Test matrix:
//   QR-1: happy ceremony — matching SAS on both sides → peer persisted after confirmSAS
//   QR-2: SAS mismatch (MITM simulation) → no _fed_peers write
//   QR-3: tampered QR proposal signature → authenticationFailed + no _fed_peers write
//   QR-4: ephemeral keys not retained after ceremony completion
//   QR-5: QR codec round-trip + malformed rejection
//
// All tests use in-process FederationSyncEngine instances so no network is needed.
// The _fed_peers gate is verified by querying the _fed_peers table in storage
// before and after the confirmSAS()+pair() sequence.

import Testing
import Foundation
import CryptoKit
import ConvergenceKit
import ConvergenceKitFederation
@testable import MootGateway
import PersistenceKit
import PersistenceKitInMemory

// MARK: - Test helpers

private func makeStorage() async throws -> any Storage {
    let storage = InMemoryStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .inMemory
    ))
    // FederationSyncEngine.enable() creates the _fed_peers table via its schema setup.
    // We call enable() on the engine (not the storage directly) so the correct schema
    // version and migrations run.
    return storage
}

private func makeManifest() -> SyncManifest {
    SyncManifest(
        kitID: "FED-OD-3-TestKit",
        schemaVersion: 1,
        zoneIdentifier: "fed-od-3-test",
        tables: []
    )
}

private func makeEngine(relay: FederationRelay, storage: any Storage) async throws
    -> FederationSyncEngine
{
    let engine = FederationSyncEngine(relay: relay)
    try await engine.enable(manifest: makeManifest(), storage: storage)
    return engine
}

/// Count rows in _fed_peers for a given storage. Returns 0 if the table is
/// absent (pre-enable) or empty; never throws — a missing table is treated as 0.
private func fedPeersCount(storage: any Storage) async -> Int {
    do {
        let rows = try await storage.rowStore.query(table: "_fed_peers")
        return rows.count
    } catch {
        // Table may not exist if enable() was not called — count is 0.
        return 0
    }
}

// MARK: - Test suite

@Suite("QR Pairing Ceremony (FED-OD-3)")
struct QRPairingCoordinatorTests {

    // MARK: - QR-1: Happy ceremony

    /// Full in-process ceremony: A generates QR, B processes it, both compute
    /// SAS, both call confirmSAS(), the caller writes _fed_peers.
    ///
    /// Gate assertion: _fed_peers is empty BEFORE confirmSAS+pair, non-empty AFTER.
    /// This verifies the coordinator does not write _fed_peers prematurely.
    @Test("QR-1: happy ceremony — matching SAS on both sides — peer persisted after confirmSAS")
    func happyCeremony() async throws {
        let relay = FederationRelay()
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let engineA = try await makeEngine(relay: relay, storage: storageA)
        let engineB = try await makeEngine(relay: relay, storage: storageB)

        let identityA = await engineA.identity
        let identityB = await engineB.identity
        let family = HyperplaneFamilySpec(seed: 0xFED_0D03)

        let coordA = QRPairingCoordinator()
        let coordB = QRPairingCoordinator()

        // Step 1: A generates the QR payload.
        let qrPayload = try await coordA.startAsProposer(identity: identityA, family: family)

        // Step 2: B scans A's QR, computes SAS.
        let (acceptorResponse, sasB) = try await coordB.startAsAcceptor(
            payload: qrPayload, identity: identityB)

        // Step 3: A processes B's response, computes SAS.
        let sasA = try await coordA.processAcceptorPayload(acceptorResponse)

        // Both sides must have derived the same SAS (no MITM → identical transcript).
        #expect(sasA == sasB, "SAS must be identical on both sides when no MITM is present")

        // Gate check: _fed_peers must be empty before confirmSAS + pair.
        let beforeA = await fedPeersCount(storage: storageA)
        let beforeB = await fedPeersCount(storage: storageB)
        #expect(beforeA == 0, "_fed_peers must be empty before confirmSAS — gate check")
        #expect(beforeB == 0, "_fed_peers must be empty before confirmSAS — gate check")

        // Step 4: Both sides confirm SAS (simulating user pressing "Confirm").
        let confirmA = try await coordA.confirmSAS()
        let confirmB = try await coordB.confirmSAS()

        // Acceptor writes its _fed_peers entry first (per real-world relay sequencing).
        // acceptPairingProposal verifies A's signature and writes B's _fed_peers row.
        _ = try await engineB.acceptPairingProposal(
            confirmB.proposal!,
            proposerSignature: confirmB.proposerSignature!
        )

        // Proposer side: use the in-process pair() which writes A's _fed_peers.
        // In real relay-based flow (WC7) this would be a relay-transported proposal;
        // in-process pair() is the correct gate-proxy for FED-OD-3 testing.
        try await engineA.pair(with: engineB, family: confirmA.family)

        // Gate check: _fed_peers must have exactly one row on each side after write.
        let afterA = await fedPeersCount(storage: storageA)
        let afterB = await fedPeersCount(storage: storageB)
        #expect(afterA == 1, "_fed_peers on A must have 1 row after confirmSAS+pair")
        #expect(afterB == 1, "_fed_peers on B must have 1 row after confirmSAS+pair")

        await coordA.markComplete()
        await coordB.markComplete()
        try await engineA.disable()
        try await engineB.disable()
    }

    // MARK: - QR-2: SAS mismatch

    /// Simulate a MITM who swaps A's ephemeral key in the QR. A and B each compute
    /// a shared secret with DIFFERENT partners (MITM and real peer), so their SAS
    /// values differ. The user sees the mismatch and rejects; no _fed_peers write occurs.
    ///
    /// Test structure:
    ///   - Real coordinator A starts ceremony → real qrPayload
    ///   - MITM coordinator M intercepts, replaces A's ephemeral key → tamperedPayload
    ///   - Real coordinator B scans tamperedPayload → sasB_with_MITM
    ///   - Real coordinator A processes B's REAL response → sasA_with_B
    ///   - sasA ≠ sasB_with_MITM (different shared secrets)
    ///   - Neither side calls confirmSAS; _fed_peers stays empty
    @Test("QR-2: SAS mismatch (MITM simulation) — no _fed_peers write")
    func sasMismatchNoPersistedPeer() async throws {
        let relay = FederationRelay()
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let engineA = try await makeEngine(relay: relay, storage: storageA)
        let engineB = try await makeEngine(relay: relay, storage: storageB)

        let identityA = await engineA.identity
        let identityB = await engineB.identity
        let family = HyperplaneFamilySpec(seed: 0xBAD_CAFE)

        // Coordinator A (real proposer).
        let coordA = QRPairingCoordinator()

        // Real proposer generates QR.
        let realQRPayload = try await coordA.startAsProposer(identity: identityA, family: family)

        // Coordinator B sees a tampered QR: the ephemeral key is replaced by MITM's
        // ephemeral key, but MITM cannot update the proposalSignature (would need A's
        // Ed25519 private key). However, startAsAcceptor verifies the ORIGINAL signature
        // — so a tampered EPHEMERAL KEY alone passes signature verification (the sig
        // covers only proposerPubKey + familySeed + familyDimension + nonce, not the
        // ephemeral key). The mismatch is detected in the SAS, not here.
        //
        // Build a tampered payload with a random ephemeral key:
        let mitmEphemeralKey = CryptoKit.Curve25519.KeyAgreement.PrivateKey()
        let tamperedPayload = QRPairingPayload(
            version: realQRPayload.version,
            identityPublicKey: realQRPayload.identityPublicKey,
            sessionNonce: realQRPayload.sessionNonce,
            ephemeralPublicKey: mitmEphemeralKey.publicKey.rawRepresentation,  // ← MITM's key
            proposedFamilySeed: realQRPayload.proposedFamilySeed,
            proposedFamilyDimension: realQRPayload.proposedFamilyDimension,
            proposalSignature: realQRPayload.proposalSignature  // sig still valid (not over eph)
        )

        // Coordinator B processes the tampered payload.
        // The signature verifies (it's A's real signature over identity/nonce/family —
        // not over the ephemeral key). SAS is computed using MITM's ephemeral key.
        let coordB = QRPairingCoordinator()
        let (acceptorResponse, sasBWithMITM) = try await coordB.startAsAcceptor(
            payload: tamperedPayload, identity: identityB)

        // Coordinator A processes B's real response (B used MITM's eph key on their side).
        // A computes shared secret with B's real ephemeral key using A's REAL eph private key.
        // A's shared secret ≠ B's shared secret (B used MITM's key, not A's real key).
        let sasAWithB = try await coordA.processAcceptorPayload(acceptorResponse)

        // SAS must differ — MITM caused a transcript divergence.
        #expect(sasAWithB != sasBWithMITM,
                "SAS must differ when ephemeral key is tampered by MITM")

        // User sees the mismatch; neither side calls confirmSAS.
        // _fed_peers must remain empty on both sides.
        let peersA = await fedPeersCount(storage: storageA)
        let peersB = await fedPeersCount(storage: storageB)
        #expect(peersA == 0, "_fed_peers on A must remain empty when SAS is not confirmed")
        #expect(peersB == 0, "_fed_peers on B must remain empty when SAS is not confirmed")

        try await engineA.disable()
        try await engineB.disable()
    }

    // MARK: - QR-3: Tampered proposal signature

    /// If the QR payload's proposalSignature is tampered (e.g. bit flip), device B's
    /// coordinator throws authenticationFailed before any key material is derived.
    /// No _fed_peers row is written.
    @Test("QR-3: tampered QR proposal signature — authenticationFailed + no _fed_peers write")
    func tamperedProposalSignatureRejected() async throws {
        let relay = FederationRelay()
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let engineA = try await makeEngine(relay: relay, storage: storageA)
        let engineB = try await makeEngine(relay: relay, storage: storageB)

        let identityA = await engineA.identity
        let identityB = await engineB.identity
        let family = HyperplaneFamilySpec(seed: 0xC0FFEE)

        let coordA = QRPairingCoordinator()

        // A generates a real QR payload.
        let realPayload = try await coordA.startAsProposer(identity: identityA, family: family)

        // Tamper the proposalSignature: flip the first byte.
        var tamperedSig = realPayload.proposalSignature
        tamperedSig[0] ^= 0xFF  // bit-flip the first byte

        let tamperedPayload = QRPairingPayload(
            version: realPayload.version,
            identityPublicKey: realPayload.identityPublicKey,
            sessionNonce: realPayload.sessionNonce,
            ephemeralPublicKey: realPayload.ephemeralPublicKey,
            proposedFamilySeed: realPayload.proposedFamilySeed,
            proposedFamilyDimension: realPayload.proposedFamilyDimension,
            proposalSignature: tamperedSig  // ← tampered
        )

        // B processes the tampered payload. Must throw authenticationFailed.
        let coordB = QRPairingCoordinator()
        do {
            _ = try await coordB.startAsAcceptor(payload: tamperedPayload, identity: identityB)
            Issue.record("startAsAcceptor must throw authenticationFailed for a tampered signature")
        } catch PairingError.authenticationFailed {
            // Expected — tampered signature correctly caught before key agreement.
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        // No _fed_peers write — the ceremony aborted before key agreement.
        let peersA = await fedPeersCount(storage: storageA)
        let peersB = await fedPeersCount(storage: storageB)
        #expect(peersA == 0, "_fed_peers on A must be empty after tampered-payload rejection")
        #expect(peersB == 0, "_fed_peers on B must be empty after tampered-payload rejection")

        try await engineA.disable()
        try await engineB.disable()
    }

    // MARK: - QR-4: Ephemeral keys not retained after completion

    /// After the ceremony completes, no coordinator holds a live ephemeral private key.
    ///
    /// The proposer's private key is discarded in processAcceptorPayload.
    /// The acceptor's private key is discarded inside startAsAcceptor (never stored).
    ///
    /// This test verifies the no-durable-opener posture: the coordinator cannot be
    /// used to re-derive the session key after the ceremony ends.
    @Test("QR-4: ephemeral keys not retained after ceremony completion")
    func ephemeralKeysNotRetainedAfterCompletion() async throws {
        let relay = FederationRelay()
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let engineA = try await makeEngine(relay: relay, storage: storageA)
        let engineB = try await makeEngine(relay: relay, storage: storageB)

        let identityA = await engineA.identity
        let identityB = await engineB.identity
        let family = HyperplaneFamilySpec(seed: 0x1234_5678)

        let coordA = QRPairingCoordinator()
        let coordB = QRPairingCoordinator()

        // Proposer starts: ephemeral key IS held (waiting for acceptor response).
        let qrPayload = try await coordA.startAsProposer(identity: identityA, family: family)
        let hasKeyBeforeProcess = await coordA.hasEphemeralPrivateKey
        #expect(hasKeyBeforeProcess == true,
                "Proposer should hold the ephemeral key between start and processAcceptorPayload")

        // Acceptor starts: ephemeral key immediately discarded (never stored post-agreement).
        let (acceptorResponse, _) = try await coordB.startAsAcceptor(
            payload: qrPayload, identity: identityB)
        let acceptorHasKey = await coordB.hasEphemeralPrivateKey
        #expect(acceptorHasKey == false,
                "Acceptor must not hold an ephemeral private key after startAsAcceptor")

        // Proposer processes acceptor response: ephemeral key discarded after agreement.
        _ = try await coordA.processAcceptorPayload(acceptorResponse)
        let hasKeyAfterProcess = await coordA.hasEphemeralPrivateKey
        #expect(hasKeyAfterProcess == false,
                "Proposer must not hold an ephemeral private key after processAcceptorPayload")

        // Complete ceremony.
        _ = try await coordA.confirmSAS()
        _ = try await coordB.confirmSAS()

        // Keys must still be absent after confirmSAS.
        let hasKeyAfterConfirm = await coordA.hasEphemeralPrivateKey
        #expect(hasKeyAfterConfirm == false,
                "No ephemeral key retained after complete ceremony")

        try await engineA.disable()
        try await engineB.disable()
    }

    // MARK: - QR-5: Codec round-trip + malformed rejection

    /// QR payload encoding round-trips through QRPairingCodec without data loss.
    /// Malformed inputs (wrong version, oversized, corrupt JSON) are rejected.
    @Test("QR-5: QR codec round-trip and malformed payload rejection")
    func qrCodecRoundTripAndMalformedRejection() async throws {
        let relay = FederationRelay()
        let storage = try await makeStorage()
        let engine = try await makeEngine(relay: relay, storage: storage)
        let identity = await engine.identity
        let family = HyperplaneFamilySpec(seed: 0xDECAFBAD)

        let coord = QRPairingCoordinator()
        let originalPayload = try await coord.startAsProposer(identity: identity, family: family)

        // Round-trip: encode → decode must produce equal values.
        let encoded = try QRPairingCodec.encode(originalPayload)
        let decoded = try QRPairingCodec.decode(encoded)
        #expect(decoded == originalPayload, "Round-trip must produce identical payload")

        // Size gate: 512-byte ceiling is enforced.
        #expect(encoded.count <= QRPairingCodec.maxPayloadBytes,
                "Encoded payload must fit within maxPayloadBytes")

        // Malformed: corrupt JSON.
        do {
            _ = try QRPairingCodec.decode(Data("not json".utf8))
            Issue.record("decode must throw for corrupt JSON")
        } catch PairingError.malformedPayload {
            // Expected.
        }

        // Malformed: wrong version.
        let wrongVersionPayload = QRPairingPayload(
            version: 999,
            identityPublicKey: originalPayload.identityPublicKey,
            sessionNonce: originalPayload.sessionNonce,
            ephemeralPublicKey: originalPayload.ephemeralPublicKey,
            proposedFamilySeed: originalPayload.proposedFamilySeed,
            proposedFamilyDimension: originalPayload.proposedFamilyDimension,
            proposalSignature: originalPayload.proposalSignature
        )
        let wrongVersionEncoded = try JSONEncoder().encode(wrongVersionPayload)
        do {
            _ = try QRPairingCodec.decode(wrongVersionEncoded)
            Issue.record("decode must throw for unknown version")
        } catch PairingError.malformedPayload {
            // Expected.
        }

        // Malformed: oversized payload.
        let oversizedData = Data(repeating: 0x41, count: QRPairingCodec.maxPayloadBytes + 1)
        do {
            _ = try QRPairingCodec.decode(oversizedData)
            Issue.record("decode must throw for oversized input")
        } catch PairingError.malformedPayload {
            // Expected.
        }

        // Acceptor codec round-trip.
        let acceptorPayload = QRAcceptorPayload(
            version: 1,
            identityPublicKey: identity.publicKey,
            ephemeralPublicKey: CryptoKit.Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        )
        let encodedAcceptor = try QRPairingCodec.encodeAcceptor(acceptorPayload)
        let decodedAcceptor = try QRPairingCodec.decodeAcceptor(encodedAcceptor)
        #expect(decodedAcceptor == acceptorPayload, "Acceptor round-trip must produce identical payload")

        try await engine.disable()
    }

    // MARK: - QR-6: SAS derivation is deterministic

    /// SASDeriver.derive is a pure function: same inputs → same outputs.
    /// This verifies the mapping is stable so both devices always agree on the pattern.
    @Test("QR-6: SAS derivation is deterministic (pure function test)")
    func sasDerivationIsDeterministic() {
        let nonce = Data(repeating: 0x11, count: 16)
        let secret = Data(repeating: 0x22, count: 32)
        let proposalBytes = Data(repeating: 0x33, count: 48)
        let acceptorKey = Data(repeating: 0x44, count: 32)

        let result1 = SASDeriver.derive(
            sessionNonce: nonce,
            sharedEphemeralSecret: secret,
            proposalSigningBytes: proposalBytes,
            acceptorIdentityPublicKey: acceptorKey
        )
        let result2 = SASDeriver.derive(
            sessionNonce: nonce,
            sharedEphemeralSecret: secret,
            proposalSigningBytes: proposalBytes,
            acceptorIdentityPublicKey: acceptorKey
        )

        #expect(result1 == result2, "SAS derivation must be deterministic")
        #expect(result1.count == 4, "SAS pattern must have exactly 4 entries")
        for entry in result1 {
            #expect(entry.emojiIndex >= 0 && entry.emojiIndex < SASDeriver.emojiPalette.count,
                    "emojiIndex must be a valid palette index")
            #expect(entry.colorIndex >= 0 && entry.colorIndex < SASDeriver.colorPalette.count,
                    "colorIndex must be a valid palette index")
        }
    }

    // MARK: - QR-7: confirmSAS is the only path to _fed_peers write

    /// Verifies that calling acceptPairingProposal without confirmSAS first is still
    /// possible (the engine API has no coordinator dependency), but the coordinator
    /// state machine enforces: you get the proposal/sig ONLY from confirmSAS().
    ///
    /// This test verifies state machine correctness: confirmSAS throws if SAS was not
    /// computed, and rejectSAS clears the state so subsequent confirmSAS also throws.
    @Test("QR-7: coordinator state machine — confirmSAS requires SAS to be computed")
    func confirmSASRequiresSASComputed() async throws {
        let coord = QRPairingCoordinator()

        // confirmSAS on idle coordinator must throw.
        do {
            _ = try await coord.confirmSAS()
            Issue.record("confirmSAS on idle coordinator must throw")
        } catch PairingError.notStarted {
            // Expected.
        }

        let relay = FederationRelay()
        let storage = try await makeStorage()
        let engine = try await makeEngine(relay: relay, storage: storage)
        let identity = await engine.identity
        let family = HyperplaneFamilySpec(seed: 0xABCD_1234)

        let coordA = QRPairingCoordinator()
        let qrPayload = try await coordA.startAsProposer(identity: identity, family: family)
        _ = qrPayload  // QR displayed; acceptor response not yet received

        // confirmSAS before processAcceptorPayload must throw (proposerWaiting state).
        do {
            _ = try await coordA.confirmSAS()
            Issue.record("confirmSAS must throw while waiting for acceptor response")
        } catch PairingError.notStarted {
            // Expected — proposerWaiting is logically "not yet ready".
        }

        // After rejectSAS, confirmSAS must throw.
        let identity2 = LocalIdentity()
        let family2 = HyperplaneFamilySpec(seed: 0xF00D)
        let coordB = QRPairingCoordinator()
        let coord2 = QRPairingCoordinator()
        let payload2 = try await coord2.startAsProposer(identity: identity2, family: family2)
        let (response2, _) = try await coordB.startAsAcceptor(payload: payload2, identity: identity2)
        _ = response2

        // rejectSAS on the acceptor side.
        try await coordB.rejectSAS()
        do {
            _ = try await coordB.confirmSAS()
            Issue.record("confirmSAS after rejectSAS must throw")
        } catch PairingError.pairingRefused {
            // Expected.
        }

        try await engine.disable()
    }
}

