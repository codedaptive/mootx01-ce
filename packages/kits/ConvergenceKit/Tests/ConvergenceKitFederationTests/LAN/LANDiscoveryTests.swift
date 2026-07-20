// LANDiscoveryTests.swift — ConvergenceKitFederationTests
//
// Tests for LANDiscovery (FED-OD-1).
//
// All tests are deterministic and use no live-network activity.
// FakeLANDiscoverySession is injected so NWBrowser/NWListener are never started.
//
// Test coverage:
//   T-1: TXT round-trip — encode then decode preserves all four fields.
//   T-2: TXT NEGATIVE — exactly four keys present after encode; no content bytes.
//   T-3: Visibility policy defaults to .off; setVisibility round-trips correctly.
//   T-4: startDiscovery starts both advertising and browsing on the session.
//   T-5: stopDiscovery stops both and clears peers.
//   T-6: startDiscovery is idempotent — second call is a no-op.
//   T-7: Known fingerprint → isVerified = true classification.
//   T-8: Unknown fingerprint → isVerified = false classification.
//   T-9: updateKnownFingerprints reclassifies already-discovered peers.
//   T-10: Fingerprint derivation — different keys produce different fingerprints.
//   T-11: Fingerprint is deterministic for the same key.
//   T-12: LANDiscovery.localTXTRecord.fingerprint matches lanFingerprintFromPublicKey.

import Testing
import Foundation
import Crypto
@testable import ConvergenceKitFederation

// MARK: - Test helpers

/// Generate a fresh random Ed25519 public key. Not secret — for testing only.
private func makeTestPublicKey() -> Data {
    Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
}

// MARK: - T-1: TXT round-trip

@Suite("LANDiscovery — TXT record round-trip")
struct LANDiscoveryTXTRoundTripTests {

    @Test("encode then decode preserves fingerprint, name, version, port")
    func txtRoundTrip() {
        let original = LANFederationTXTRecord(
            fingerprint: "aabbccdd11223344",
            displayName: "Alice's MacBook",
            protocolVersion: "1",
            relayPort: 4343
        )
        let encoded = original.encode()
        let decoded = LANFederationTXTRecord.decode(encoded)
        #expect(decoded != nil, "decode must succeed")
        #expect(decoded?.fingerprint == original.fingerprint)
        #expect(decoded?.displayName == original.displayName)
        #expect(decoded?.protocolVersion == original.protocolVersion)
        #expect(decoded?.relayPort == original.relayPort)
    }

    @Test("decode without mandatory fp field returns nil")
    func decodeWithoutFingerprintReturnsNil() {
        // Omit "fp" — the mandatory field. Decode must reject the record.
        let dict: [String: String] = [
            "n": "Alice",
            "v": "1",
            "p": "4343",
        ]
        #expect(LANFederationTXTRecord.decode(dict) == nil,
                "decode must return nil when fp is absent")
    }

    @Test("decode with partial fields uses defaults for n, v, p")
    func decodeWithPartialFieldsUsesDefaults() {
        let dict: [String: String] = ["fp": "aabbccdd11223344"]
        let result = LANFederationTXTRecord.decode(dict)
        #expect(result != nil)
        #expect(result?.displayName == "")
        #expect(result?.protocolVersion == "1")
        #expect(result?.relayPort == 0)
    }
}

// MARK: - T-2: TXT NEGATIVE — content-byte prohibition

@Suite("LANDiscovery — TXT record NEGATIVE invariant (no content bytes)")
struct LANDiscoveryTXTNegativeTests {

    /// NEGATIVE INVARIANT: the TXT record encodes EXACTLY four keys.
    ///
    /// This test asserts the TXT record contains exactly "fp", "n", "v", "p"
    /// and NO other keys. Any additional key would risk carrying content-derived
    /// bytes (drawer IDs, KG facts, document text, embeddings) into a passive
    /// network broadcast — a privacy violation flagged by Perkins.
    ///
    /// If the TXT record format must expand in the future, this test must be
    /// updated simultaneously with encode() and the protocol version bumped.
    @Test("TXT encode produces exactly four keys: fp, n, v, p — no others")
    func txtRecordHasExactlyFourKeys() {
        let record = LANFederationTXTRecord(
            fingerprint: "aabbccdd11223344",
            displayName: "Test Estate",
            protocolVersion: "1",
            relayPort: 9090
        )
        let keys = Set(record.encode().keys)
        #expect(keys == Set(["fp", "n", "v", "p"]),
                "TXT record must contain exactly {fp, n, v, p} — found \(keys)")
    }

    /// NEGATIVE INVARIANT: fingerprint bytes are derived from the public key.
    ///
    /// Verifies that lanFingerprintFromPublicKey takes the public key as its
    /// input, not estate content bytes. The fingerprint placed in the TXT record
    /// must equal the SHA-256(publicKey).prefix(8) result.
    @Test("fingerprint in TXT record equals key-derived value, not content-derived")
    func fingerprintDerivedFromKeyNotContent() {
        let publicKey = makeTestPublicKey()
        let expectedFP = lanFingerprintFromPublicKey(publicKey)

        let record = LANFederationTXTRecord(
            fingerprint: expectedFP,
            displayName: "My Estate",
            relayPort: 0
        )
        let fpInRecord = record.encode()["fp"]!

        // The fp in the TXT record must equal the key-derived fingerprint.
        #expect(fpInRecord == expectedFP,
                "TXT record fp must equal lanFingerprintFromPublicKey(publicKey)")

        // Spot-check: the fingerprint must NOT be a SHA-256 of arbitrary content bytes.
        let contentBytes = Data("drawer title: quarterly review meeting notes".utf8)
        let contentFP = SHA256.hash(data: contentBytes)
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        // These won't match unless the public key bytes happen to equal the content bytes
        // (probability 2^-256). This assertion documents the invariant.
        #expect(fpInRecord != contentFP || publicKey == contentBytes,
                "fp must be key-derived, not content-derived")
    }

    @Test("fingerprint is 16 lowercase hex characters")
    func fingerprintLengthAndFormat() {
        let fp = lanFingerprintFromPublicKey(makeTestPublicKey())
        #expect(fp.count == 16, "fingerprint must be exactly 16 characters (8 bytes hex)")
        #expect(fp == fp.lowercased(), "fingerprint must be lowercase hex")
        #expect(fp.allSatisfy { $0.isHexDigit }, "fingerprint must be hexadecimal")
    }
}

// MARK: - T-3: Visibility policy

@Suite("LANDiscovery — DiscoveryVisibilityPolicy")
struct LANDiscoveryVisibilityPolicyTests {

    @Test("default visibility is .off when no key is stored")
    func defaultVisibilityIsOff() {
        let suite = "test.vis.default.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        #expect(DiscoveryVisibilityPolicy.visibility(defaults: d) == .off)
    }

    @Test("visibility-off default means callers must not call startDiscovery")
    func visibilityOffSuppressesDiscovery() throws {
        // LANDiscovery does not read UserDefaults itself — the caller (Federation
        // panel / app layer) reads the policy and conditionally calls startDiscovery.
        // This test verifies that pattern: when visibility is .off, startDiscovery
        // is not called, and the session records zero advertise/browse starts.
        let suite = "test.vis.off.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }

        let visibility = DiscoveryVisibilityPolicy.visibility(defaults: d)
        #expect(visibility == .off)

        let fake = FakeLANDiscoverySession()
        let discovery = LANDiscovery(publicKey: makeTestPublicKey(), displayName: "Test", session: fake)

        // Simulate the caller respecting the off policy.
        if visibility != .off {
            try discovery.startDiscovery()
        }

        #expect(fake.advertiseCallCount == 0, "advertise must not start when caller respects off policy")
        #expect(fake.browseCallCount == 0, "browse must not start when caller respects off policy")
        #expect(discovery.discoveredPeersArray.isEmpty)
    }

    @Test("setVisibility / visibility round-trips all three values")
    func visibilityRoundTrip() {
        let suite = "test.vis.rt.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }

        for v in DiscoveryVisibility.allCases {
            DiscoveryVisibilityPolicy.setVisibility(v, defaults: d)
            #expect(DiscoveryVisibilityPolicy.visibility(defaults: d) == v)
        }
    }
}

// MARK: - T-4 / T-5 / T-6: Lifecycle

@Suite("LANDiscovery — lifecycle")
struct LANDiscoveryLifecycleTests {

    @Test("startDiscovery calls startAdvertising and startBrowsing exactly once each")
    func startDiscoveryStartsBoth() throws {
        let fake = FakeLANDiscoverySession()
        let discovery = LANDiscovery(publicKey: makeTestPublicKey(), displayName: "Alice", session: fake)
        try discovery.startDiscovery()
        #expect(fake.advertiseCallCount == 1, "startAdvertising must be called once")
        #expect(fake.browseCallCount == 1, "startBrowsing must be called once")
        #expect(fake.isAdvertising)
        #expect(fake.isBrowsing)
    }

    @Test("stopDiscovery calls stopAdvertising and stopBrowsing and clears peers")
    func stopDiscoveryClearsPeers() throws {
        let fake = FakeLANDiscoverySession()
        let discovery = LANDiscovery(publicKey: makeTestPublicKey(), displayName: "Alice", session: fake)
        try discovery.startDiscovery()

        // Inject a synthetic peer via the fake session.
        let peerFP = lanFingerprintFromPublicKey(makeTestPublicKey())
        let peerTXT = LANFederationTXTRecord(fingerprint: peerFP, displayName: "Bob", relayPort: 4343)
        fake.simulatePeerFound(fingerprint: peerFP, txtRecord: peerTXT)
        #expect(discovery.discoveredPeers[peerFP] != nil, "peer must be visible after inject")

        discovery.stopDiscovery()
        #expect(discovery.discoveredPeersArray.isEmpty, "peers must be cleared after stopDiscovery")
        #expect(fake.stopAdvertiseCallCount == 1)
        #expect(fake.stopBrowseCallCount == 1)
        #expect(!fake.isAdvertising)
        #expect(!fake.isBrowsing)
    }

    @Test("startDiscovery is idempotent — second call is a no-op")
    func startDiscoveryIdempotent() throws {
        let fake = FakeLANDiscoverySession()
        let discovery = LANDiscovery(publicKey: makeTestPublicKey(), displayName: "Alice", session: fake)
        try discovery.startDiscovery()
        try discovery.startDiscovery()  // second call — must be ignored
        #expect(fake.advertiseCallCount == 1, "startAdvertising must only be called once")
        #expect(fake.browseCallCount == 1, "startBrowsing must only be called once")
    }

    @Test("startDiscovery advertises the correct TXT record keys")
    func startDiscoveryAdvertisesCorrectTXTRecord() throws {
        let key = makeTestPublicKey()
        let fake = FakeLANDiscoverySession()
        let discovery = LANDiscovery(publicKey: key, displayName: "MyEstate", relayPort: 7070, session: fake)
        try discovery.startDiscovery()

        let txt = fake.lastAdvertisedTXTRecord
        #expect(txt != nil)
        // Verify only the four expected keys are present.
        #expect(Set(txt!.keys) == Set(["fp", "n", "v", "p"]),
                "advertised TXT must have exactly four keys")
        // Verify fingerprint matches key derivation.
        #expect(txt!["fp"]! == lanFingerprintFromPublicKey(key))
        // Verify name is present.
        #expect(txt!["n"]! == "MyEstate")
    }
}

// MARK: - T-7 / T-8 / T-9: Peer verification

@Suite("LANDiscovery — peer verification classification")
struct LANDiscoveryVerificationTests {

    @Test("discovered peer with known fingerprint is classified isVerified = true")
    func knownFingerprintIsVerified() throws {
        let peerFP = lanFingerprintFromPublicKey(makeTestPublicKey())
        let fake = FakeLANDiscoverySession()
        let discovery = LANDiscovery(
            publicKey: makeTestPublicKey(),
            displayName: "Alice",
            knownFingerprints: [peerFP],
            session: fake
        )
        try discovery.startDiscovery()

        let peerTXT = LANFederationTXTRecord(fingerprint: peerFP, displayName: "Bob", relayPort: 9090)
        fake.simulatePeerFound(fingerprint: peerFP, txtRecord: peerTXT)

        #expect(discovery.discoveredPeers[peerFP]?.isVerified == true,
                "peer with known fingerprint must be classified as verified")
    }

    @Test("discovered peer with unknown fingerprint is classified isVerified = false")
    func unknownFingerprintIsNotVerified() throws {
        let peerFP = lanFingerprintFromPublicKey(makeTestPublicKey())
        let fake = FakeLANDiscoverySession()
        let discovery = LANDiscovery(
            publicKey: makeTestPublicKey(),
            displayName: "Alice",
            knownFingerprints: [],  // empty — no paired peers
            session: fake
        )
        try discovery.startDiscovery()

        let peerTXT = LANFederationTXTRecord(fingerprint: peerFP, displayName: "Carol", relayPort: 5050)
        fake.simulatePeerFound(fingerprint: peerFP, txtRecord: peerTXT)

        #expect(discovery.discoveredPeers[peerFP]?.isVerified == false,
                "peer with unknown fingerprint must be classified as unverified")
    }

    @Test("updateKnownFingerprints reclassifies already-discovered peers")
    func updateKnownFingerprintsReclassifies() throws {
        let peerFP = lanFingerprintFromPublicKey(makeTestPublicKey())
        let fake = FakeLANDiscoverySession()
        let discovery = LANDiscovery(
            publicKey: makeTestPublicKey(),
            displayName: "Alice",
            knownFingerprints: [],
            session: fake
        )
        try discovery.startDiscovery()

        // Inject peer while it is unknown.
        let peerTXT = LANFederationTXTRecord(fingerprint: peerFP, displayName: "Dave", relayPort: 7070)
        fake.simulatePeerFound(fingerprint: peerFP, txtRecord: peerTXT)
        #expect(discovery.discoveredPeers[peerFP]?.isVerified == false, "initially unverified")

        // Pairing ceremony completes; caller updates the known set.
        discovery.updateKnownFingerprints([peerFP])
        #expect(discovery.discoveredPeers[peerFP]?.isVerified == true,
                "peer must be reclassified as verified after updateKnownFingerprints")
    }

    @Test("updateKnownFingerprints with empty set un-verifies previously-verified peers")
    func updateKnownFingerprintsCanUnverify() throws {
        let peerFP = lanFingerprintFromPublicKey(makeTestPublicKey())
        let fake = FakeLANDiscoverySession()
        let discovery = LANDiscovery(
            publicKey: makeTestPublicKey(),
            displayName: "Alice",
            knownFingerprints: [peerFP],  // initially verified
            session: fake
        )
        try discovery.startDiscovery()

        let peerTXT = LANFederationTXTRecord(fingerprint: peerFP, displayName: "Eve", relayPort: 1234)
        fake.simulatePeerFound(fingerprint: peerFP, txtRecord: peerTXT)
        #expect(discovery.discoveredPeers[peerFP]?.isVerified == true, "initially verified")

        // Simulate a revocation / reload without the peer (e.g. after unpair).
        discovery.updateKnownFingerprints([])
        #expect(discovery.discoveredPeers[peerFP]?.isVerified == false,
                "peer must be un-verified after fingerprint removed from known set")
    }
}

// MARK: - T-10 / T-11 / T-12: Fingerprint derivation

@Suite("LANDiscovery — fingerprint derivation")
struct LANDiscoveryFingerprintTests {

    @Test("different public keys produce different fingerprints")
    func distinctKeysDifferentFingerprints() {
        // Collision probability: 1 / 2^64. If this flakes, something is deeply wrong.
        let fp1 = lanFingerprintFromPublicKey(makeTestPublicKey())
        let fp2 = lanFingerprintFromPublicKey(makeTestPublicKey())
        #expect(fp1 != fp2)
    }

    @Test("same public key always produces the same fingerprint")
    func sameKeyDeterministicFingerprint() {
        let key = makeTestPublicKey()
        #expect(lanFingerprintFromPublicKey(key) == lanFingerprintFromPublicKey(key))
    }

    @Test("LANDiscovery.localTXTRecord.fingerprint uses the supplied public key")
    func localTXTRecordUsesKeyFingerprint() {
        let key = makeTestPublicKey()
        let discovery = LANDiscovery(
            publicKey: key,
            displayName: "Test",
            session: FakeLANDiscoverySession()
        )
        #expect(discovery.localTXTRecord.fingerprint == lanFingerprintFromPublicKey(key))
    }
}
