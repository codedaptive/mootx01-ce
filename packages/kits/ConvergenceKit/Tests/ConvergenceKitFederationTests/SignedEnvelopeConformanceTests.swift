// SignedEnvelopeConformanceTests.swift
//
// Conformance tests for SignedEnvelope canonical signing bytes and
// cross-port sign/verify. These tests are the anchor that prevents
// the envelope from drifting between the Swift and Rust ports.
//
// The canonical signing-byte and sign/verify cases are mirrored in
// `convergence-kit/tests/federation_tests.rs` under the
// "Canonical signing bytes conformance" section. The Swift file also
// contains `payloadKindRawValue` and `signedEnvelopeCodableRoundtrip`,
// which are not mirrored in that Rust section.

import Testing
import Foundation
import Crypto
import SubstrateTypes
import ConvergenceKit
import ConvergenceKitFederation

@Suite("SignedEnvelope canonical signing bytes")
struct SignedEnvelopeConformanceTests {

    // MARK: - Determinism

    @Test("envelopeSigningBytes is deterministic: same inputs, same output")
    func signingBytesAreDeterministic() {
        let pk = Data(repeating: 0xAB, count: 32)
        let payload = Data("test-payload-data".utf8)
        let hlc = PackedHLC(HLC(physicalTime: 1_000_000, logicalCount: 7, nodeID: 3))
        let a = envelopeSigningBytes(senderPublicKey: pk, payloadKind: .syncRecordBatch, payload: payload, hlc: hlc)
        let b = envelopeSigningBytes(senderPublicKey: pk, payloadKind: .syncRecordBatch, payload: payload, hlc: hlc)
        #expect(a == b)
    }

    @Test("different inputs produce different canonical bytes")
    func signingBytesDifferOnDifferentInputs() {
        let pk = Data(repeating: 0xAB, count: 32)
        let hlc = PackedHLC(HLC(physicalTime: 100, logicalCount: 1, nodeID: 1))
        let payloadA = Data("payload-A".utf8)
        let payloadB = Data("payload-B".utf8)
        let bytesA = envelopeSigningBytes(senderPublicKey: pk, payloadKind: .syncRecordBatch, payload: payloadA, hlc: hlc)
        let bytesB = envelopeSigningBytes(senderPublicKey: pk, payloadKind: .syncRecordBatch, payload: payloadB, hlc: hlc)
        #expect(bytesA != bytesB)
    }

    // MARK: - Golden vector

    /// Golden-vector test for `envelopeSigningBytes`.
    ///
    /// This vector is the authoritative cross-port conformance anchor.
    /// The same inputs fed to the Rust `envelope_signing_bytes(...)` MUST
    /// produce the same output.
    ///
    /// Layout:
    ///   [0..31]  sender_public_key: 0x01 × 32
    ///   [32]     payload_kind: 0x01 (syncRecordBatch)
    ///   [33..36] payload_len LE uint32: 4 → 04 00 00 00
    ///   [37..40] payload: 0x41 0x42 0x43 0x44 ("ABCD")
    ///   [41..48] physical_time LE int64: 1234567890 → D2 02 96 49 00 00 00 00
    ///   [49..52] logical_count LE int32: 5 → 05 00 00 00
    ///   [53..56] node_id LE int32: 2 → 02 00 00 00
    @Test("golden vector: envelopeSigningBytes matches cross-port reference layout")
    func goldenVector() {
        let pk = Data(repeating: 0x01, count: 32)
        let payload = Data([0x41, 0x42, 0x43, 0x44])  // "ABCD"
        let hlc = PackedHLC(HLC(physicalTime: 1_234_567_890, logicalCount: 5, nodeID: 2))
        let got = envelopeSigningBytes(
            senderPublicKey: pk,
            payloadKind: .syncRecordBatch,
            payload: payload,
            hlc: hlc
        )

        // Build expected bytes manually to make the layout explicit.
        var expected = Data()
        expected.append(contentsOf: repeatElement(UInt8(0x01), count: 32))  // public key
        expected.append(UInt8(0x01))                                         // SyncRecordBatch

        // payload_len: 4 as LE uint32
        var payloadLen = UInt32(4).littleEndian
        withUnsafeBytes(of: &payloadLen) { expected.append(contentsOf: $0) }
        expected.append(contentsOf: [0x41, 0x42, 0x43, 0x44])               // "ABCD"

        // physicalTime: 1_234_567_890 as LE int64
        var pt = Int64(1_234_567_890).littleEndian
        withUnsafeBytes(of: &pt) { expected.append(contentsOf: $0) }

        // logicalCount: 5 as LE int32
        var lc = Int32(5).littleEndian
        withUnsafeBytes(of: &lc) { expected.append(contentsOf: $0) }

        // nodeID: 2 as LE int32
        var ni = Int32(2).littleEndian
        withUnsafeBytes(of: &ni) { expected.append(contentsOf: $0) }

        #expect(
            got == expected,
            "canonical signing bytes do not match golden vector — cross-port parity broken"
        )
    }

    // MARK: - Sign and verify roundtrip

    @Test("envelope sign-and-verify roundtrip with FederationSignature")
    func signAndVerifyRoundtrip() throws {
        let identity = LocalIdentity()
        let payload = Data("sync-batch-payload".utf8)
        let hlc = PackedHLC(HLC(physicalTime: 9_000_000, logicalCount: 1, nodeID: 0))
        let signingBytes = envelopeSigningBytes(
            senderPublicKey: identity.publicKey,
            payloadKind: .syncRecordBatch,
            payload: payload,
            hlc: hlc
        )
        let signature = try identity.sign(signingBytes)

        // Verify with the public key: must succeed.
        #expect(
            FederationSignature.verify(signature, of: signingBytes, by: identity.publicKey),
            "self-sign/verify roundtrip failed"
        )

        // Verify with tampered canonical bytes: must fail.
        var tampered = signingBytes
        tampered[0] ^= 0xFF
        #expect(
            !FederationSignature.verify(signature, of: tampered, by: identity.publicKey),
            "tampered bytes should not verify"
        )

        // Verify with wrong public key: must fail.
        let other = LocalIdentity()
        #expect(
            !FederationSignature.verify(signature, of: signingBytes, by: other.publicKey),
            "wrong key should not verify"
        )
    }

    // MARK: - PayloadKind raw values

    @Test("PayloadKind.syncRecordBatch has raw value 0x01")
    func payloadKindRawValue() {
        #expect(PayloadKind.syncRecordBatch.rawValue == 0x01)
    }

    // MARK: - SignedEnvelope codable roundtrip

    @Test("SignedEnvelope round-trips through Codable")
    func signedEnvelopeCodableRoundtrip() throws {
        let identity = LocalIdentity()
        let payload = Data("hello-envelope".utf8)
        let hlc = PackedHLC(HLC(physicalTime: 5000, logicalCount: 2, nodeID: 1))
        let signingBytes = envelopeSigningBytes(
            senderPublicKey: identity.publicKey,
            payloadKind: .syncRecordBatch,
            payload: payload,
            hlc: hlc
        )
        let signature = try identity.sign(signingBytes)
        let envelope = SignedEnvelope(
            senderPublicKey: identity.publicKey,
            payloadKind: .syncRecordBatch,
            payload: payload,
            signature: signature,
            hlc: hlc
        )
        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(SignedEnvelope.self, from: encoded)

        #expect(decoded.senderPublicKey == envelope.senderPublicKey)
        #expect(decoded.payloadKind == envelope.payloadKind)
        #expect(decoded.payload == envelope.payload)
        #expect(decoded.signature == envelope.signature)
        #expect(decoded.hlc == envelope.hlc)
    }
}
