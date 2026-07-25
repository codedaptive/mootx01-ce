// LANFederationConformanceTests.swift — ConvergenceKitFederationTests
//
// FED-OD-7: F1 On-Demand Federation Conformance Suite — aggregator.
//
// The LAN federation contract names
// six negative conformance rows. This file:
//
//   1. Documents all six rows with the EXACT test function that satisfies each.
//   2. Contains a lightweight aggregator test that compiles the conformance surface
//      and spot-checks the key types are present (catches API drift at CI time).
//   3. Row 3 (ceiling holds on LANRelay) requires SensitivityFilteredStorage from
//      the MootGateway layer — its proof lives in:
//        MootGatewayTests/Federation/FederationSessionManagerTests.swift
//        FSM-7: "CEIL-1 restricted row suppressed: above-ceiling row never reaches
//               LANRelay transport inbox" and FSM-8 positive control.
//
// ───────────────────────────────────────────────────────────────────────────────
// F1 Conformance Row → Test Mapping
// ───────────────────────────────────────────────────────────────────────────────
//
// Row 1 — TXT no-content-bytes
//   Decision doc: "Discovery TXT record contains no content-derived bytes
//                  (negative test: fingerprint only)."
//   Tests (CITED — existing, green):
//     LANDiscoveryTXTNegativeTests.txtRecordHasExactlyFourKeys
//       file: LAN/LANDiscoveryTests.swift
//       asserts: encode() returns exactly {"fp","n","v","p"} — no other keys
//     LANDiscoveryTXTNegativeTests.fingerprintDerivedFromKeyNotContent
//       file: LAN/LANDiscoveryTests.swift
//       asserts: fp equals lanFingerprintFromPublicKey(publicKey), not content bytes
//     LANDiscoveryLifecycleTests.startDiscoveryAdvertisesCorrectTXTRecord
//       file: LAN/LANDiscoveryTests.swift
//       asserts: advertised TXT has exactly four keys
//   Status: COVERED by existing FED-OD-1 tests.
//
// Row 2 — Session-end determinism
//   Decision doc: "Session end is deterministic: no outbound entry created after
//                  End Session lands in any relay (extends I-2/I-10 style tests)."
//   Test (CITED — existing, green):
//     FederationSessionManagerTests.sessionEndDeterminism (FSM-1)
//       file: MootGatewayTests/Federation/FederationSessionManagerTests.swift
//       asserts: transport.isClosed after endSession() AND
//                transport inbox depth unchanged (no envelopes delivered post-close)
//   Note: FSM-1 checks BOTH transport.isClosed AND inbox depth delta == 0.
//   This satisfies the relay-inbox-level assertion required by the row.
//   Status: COVERED by existing FED-OD-4 FSM-1 test.
//
// Row 3 — Ceiling holds on LANRelay
//   Decision doc: "Ceiling holds across sessions: above-ceiling rows never reach
//                  a LANRelay inbox (extends the P5-M1 gate tests to the new transport)."
//   Tests (NEW — added by FED-OD-7, in MootGatewayTests):
//     FederationSessionManagerTests.restrictedRowNeverReachesLANRelayInbox (FSM-7)
//       file: MootGatewayTests/Federation/FederationSessionManagerTests.swift
//       asserts: restricted row (adjective_bitmap=2048, raw sensitivity 32 > ceiling 16)
//                not suppressed from observer → outbox empty → receipt.pushed==0 →
//                transport.inboxCount(for: bKey)==0
//     FederationSessionManagerTests.normalRowReachesLANRelayInbox (FSM-8)
//       file: MootGatewayTests/Federation/FederationSessionManagerTests.swift
//       asserts: positive control — normal row (bitmap=0) reaches the relay inbox
//   Status: NEW tests added by FED-OD-7.
//
// Row 4 — SAS mismatch refusal
//   Decision doc: "Pairing over LANRelay refuses on SAS mismatch..."
//   Test (CITED — existing, green):
//     QRPairingCoordinatorTests.sasMismatchNoPersistedPeer (QR-2)
//       file: MootGatewayTests/Federation/QRPairingCoordinatorTests.swift
//       asserts: when ephemeral key is tampered by MITM, sasA ≠ sasB AND
//                _fed_peers remains empty on both sides (no write occurs)
//   Note: The row requires that a mismatched SAS does not write _fed_peers.
//   QR-2 proves this: confirmSAS() is never called when SAS mismatches, and
//   the test explicitly checks fedPeersCount == 0 on both sides post-ceremony.
//   Status: COVERED by existing FED-OD-3 QR-2 test.
//
// Row 5 — Tampered proposal refusal
//   Decision doc: "...and on tampered proposal (extends the WC6 negative tests
//                  to the new channel)."
//   Tests (CITED — existing, green):
//     QRPairingCoordinatorTests.tamperedProposalSignatureRejected (QR-3)
//       file: MootGatewayTests/Federation/QRPairingCoordinatorTests.swift
//       asserts: tampered proposalSignature throws PairingError.authenticationFailed AND
//                _fed_peers empty on both sides (no peer persisted)
//     FederationPairingTests.tamperedProposalRejected
//       file: ConvergenceKitFederationTests/FederationPairingTests.swift
//       asserts: acceptPairingProposal with wrong-key signature throws
//                SyncError.authenticationFailed (engine-level gate)
//   Status: COVERED by existing FED-OD-3 QR-3 + WC6 test.
//
// Row 6 — TLS refused on unknown key
//   Decision doc: "LANRelay passes RelayConformanceTests unmodified."
//                 (Row 6 is the LANRelay-specific TLS identity-pinning negative test.)
//   Test (CITED — existing, green):
//     LANRelayConformanceTests.tlsRefusedOnUnknownKey
//       file: Relay/RelayConformanceTests.swift (Suite 3)
//       asserts: FakeLANRelayTransport(knownPeers:[knownKey]) throws
//                SyncError.peerUnreachable when send() targets an unknown peer key
//   Note: FakeLANRelayTransport's knownPeers gate simulates the production
//   NWParameters custom TLS verifier that rejects certs whose Ed25519 fingerprint
//   is not in _fed_peers (charter V2). The negative test asserts that a send to
//   an unrecognized peer key throws peerUnreachable, proving that LANRelay does
//   not deliver to unknown keys.
//   Status: COVERED by existing FED-OD-2 Suite 3 test.
//
// ───────────────────────────────────────────────────────────────────────────────

import Testing
import Foundation
@testable import ConvergenceKitFederation

// MARK: - F1 Conformance Suite Aggregator

/// Aggregator suite for the F1 Federation conformance manifest (FED-OD-7).
///
/// This suite does not duplicate the substantive tests — they live in the files
/// named above. It exists to:
///   (a) Document the six-row conformance map in a single canonical location.
///   (b) Compile a smoke-check against the current ConvergenceKitFederation API,
///       so that API drift (renaming, removal, or signature change of the types the
///       conformance rows depend on) is caught at CI time, not at merge review.
@Suite("F1 Federation Conformance — aggregator and API smoke-check (FED-OD-7)")
struct LANFederationConformanceSuite {

    /// Conformance API smoke-check.
    ///
    /// Verifies that the types and APIs the six conformance rows depend on are
    /// present and well-typed in the current build. Does NOT duplicate the
    /// substantive assertions in the referenced tests.
    ///
    /// If this test fails to compile, an API the conformance suite depends on
    /// has drifted — update the tests in the referenced files and amend the
    /// §6 decision doc entries to name the updated test functions.
    @Test("conformance surface compiles: six-row API smoke-check (FED-OD-7)")
    func conformanceSurfaceCompiles() throws {
        // ── Row 1: TXT no-content-bytes ──────────────────────────────────────
        // LANFederationTXTRecord.encode() must return [String: String].
        // LANDiscoveryTXTNegativeTests.txtRecordHasExactlyFourKeys asserts the key set.
        let record = LANFederationTXTRecord(
            fingerprint: "aabbccdd11223344",
            displayName: "smoke-check estate",
            protocolVersion: "1",
            relayPort: 4343
        )
        let encoded: [String: String] = record.encode()
        // Exact-key-set assertion is in the canonical test; here just verify the type.
        let _ = encoded

        // lanFingerprintFromPublicKey is the key-derivation function the TXT fp uses.
        // LANDiscoveryTXTNegativeTests.fingerprintDerivedFromKeyNotContent asserts
        // it takes publicKey bytes, NOT content bytes.
        let sampleKey = Data(repeating: 0xAB, count: 32)
        let fp = lanFingerprintFromPublicKey(sampleKey)
        #expect(fp.count == 16, "fingerprint must be 16 hex characters")

        // ── Row 6: TLS refused on unknown key ────────────────────────────────
        // FakeLANRelayTransport(knownPeers:) is the simulation seam for the TLS
        // identity-pinning gate. LANRelayConformanceTests.tlsRefusedOnUnknownKey
        // uses this constructor with a restricted set to assert peerUnreachable.
        let knownKey = Data(repeating: 0x01, count: 32)
        let restrictedTransport = FakeLANRelayTransport(knownPeers: [knownKey])
        let relay = LANRelay(transport: restrictedTransport)
        // Verify the relay is constructed (transport wired). Functional assertion is in Suite 3.
        let _ = relay

        // ── Row 4 + 5: SAS mismatch and tampered proposal ────────────────────
        // QRPairingCoordinator is the subject type. Functional tests are in
        // QRPairingCoordinatorTests (QR-2 and QR-3) in MootGatewayTests.
        // Here we just verify the type is importable via ConvergenceKitFederation.
        // (QRPairingCoordinator lives in MootGateway; its types are ConvergenceKit-level.)
        // No import needed at this level — the type check happens in MootGatewayTests.

        // ── Rows 2 + 3: session-end determinism and ceiling ──────────────────
        // FederationSessionManager is in MootGateway. Functional tests are in
        // MootGatewayTests (FSM-1 for Row 2, FSM-7/FSM-8 for Row 3).
        // No types to check here — both are app-layer types outside this target.

        // If this function compiles and the assertions above pass, the conformance
        // surface for Rows 1 and 6 is confirmed at the kit layer.
    }
}
