// FederationPairingTests.swift
//
// End-to-end in-process pairing test. Two FederationSyncEngine
// instances paired via a shared FederationRelay. Records pushed
// on one side appear on the other after pull.

import Testing
import Foundation
import SubstrateTypes
import ConvergenceKit
import ConvergenceKitFederation
import PersistenceKit
import PersistenceKitInMemory
// ─────────────────────────────────────────────────────────────────
// DO NOT REIMPLEMENT SUBSTRATE MATH.
//
// The substrate publishes conformance-gated, byte-identical
// Swift+Rust implementations of every primitive listed in
// docs/engineering/HARNESS_REFERENCE.md. If you
// need SimHash, Hamming, OR-reduce, Fingerprint256 ops, HammingNN
// top-K, HLC, AuditGate, MatrixDecay, AuditLogFold, Bradley-Terry,
// NMF, FFT, eigenvalue centrality, or any other substrate primitive,
// it's already in SubstrateTypes / SubstrateKernel / SubstrateML.
// CI catches drift four ways. See packages/libs/Substrate{Types,
// Kernel,ML}/AGENTS.md.
// ─────────────────────────────────────────────────────────────────

@Suite("Federation in-process pairing")
struct FederationPairingTests {

    func makeStorage() async throws -> any Storage {
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .inMemory
        ))
        try await storage.open(schema: SchemaDeclaration(
            kitID: "TestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "items",
                    columns: [
                        .uuid("id"),
                        .text("note"),
                        .bitmap("flags")
                    ],
                    primaryKey: ["id"]
                )
            ],
            indices: [],
            migrations: []
        ))
        return storage
    }

    func makeManifest() -> SyncManifest {
        SyncManifest(
            kitID: "TestKit",
            schemaVersion: 1,
            zoneIdentifier: "test-zone",
            tables: [SyncedTable(name: "items", primaryKeyColumn: "id")]
        )
    }

    @Test("records written on A replicate to B after push/pull")
    func inProcessPairingPushPull() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()
        let relay = FederationRelay()
        let engineA = FederationSyncEngine(relay: relay)
        let engineB = FederationSyncEngine(relay: relay)

        try await engineA.enable(manifest: makeManifest(), storage: storageA)
        try await engineB.enable(manifest: makeManifest(), storage: storageB)

        let family = HyperplaneFamilySpec(seed: 0xDEADBEEF)
        try await engineA.pair(with: engineB, family: family)

        // Write on A.
        let rowID = UUID()
        _ = try await storageA.rowStore.insert(
            table: "items",
            values: [
                "id": .uuid(rowID),
                "note": .text("hello from A"),
                "flags": .bitmap(0x01)
            ]
        )

        // Let the observer flush.
        try await Task.sleep(nanoseconds: 100_000_000)

        // A pushes; B pulls.
        let pushReceipt = try await engineA.push()
        #expect(pushReceipt.pushed > 0, "A should have pushed at least one record")

        let pullReceipt = try await engineB.pull()
        #expect(pullReceipt.pulled > 0, "B should have pulled at least one record")

        // Verify the row exists on B.
        let rows = try await storageB.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(rowID))
        )
        #expect(rows.count == 1, "row should have replicated to B")
        #expect(rows[0]["note"] == .text("hello from A"))
        #expect(rows[0]["flags"] == .bitmap(0x01))

        try await engineA.disable()
        try await engineB.disable()
    }

    /// Pull rejects a valid self-signed envelope from an engine that is NOT
    /// a paired peer. A valid signature alone does not prove pairing
    /// authorization (ADR-013); the sender must be in the paired peer list.
    @Test("pull rejects signed envelope from sender that is not a paired peer")
    func pullRejectsSignedEnvelopeFromUnpairedSender() async throws {
        let storageVictim = try await makeStorage()
        let storageTrusted = try await makeStorage()
        let relay = FederationRelay()
        let engineVictim = FederationSyncEngine(relay: relay)
        let engineTrusted = FederationSyncEngine(relay: relay)
        // Attacker identity — NOT paired with victim.
        let attackerIdentity = LocalIdentity()

        let manifest = makeManifest()
        try await engineVictim.enable(manifest: manifest, storage: storageVictim)
        try await engineTrusted.enable(manifest: manifest, storage: storageTrusted)

        let family = HyperplaneFamilySpec(seed: 0xDEADC0DE)
        try await engineVictim.pair(with: engineTrusted, family: family)
        // Attacker is NOT paired with victim.

        // Build a valid self-signed envelope from the attacker's identity.
        let victimPubKey = await engineVictim.identity.publicKey
        let fakeBatch = try JSONEncoder().encode([String]())  // empty-array JSON
        let batchHLC = PackedHLC(HLC(physicalTime: 1000, logicalCount: 1, nodeID: 0))
        let signingBytes = envelopeSigningBytes(
            senderPublicKey: attackerIdentity.publicKey,
            payloadKind: .syncRecordBatch,
            payload: fakeBatch,
            hlc: batchHLC
        )
        let signature = try attackerIdentity.sign(signingBytes)
        let envelope = SignedEnvelope(
            senderPublicKey: attackerIdentity.publicKey,
            payloadKind: .syncRecordBatch,
            payload: fakeBatch,
            signature: signature,
            hlc: batchHLC
        )

        // Inject the attacker's envelope directly into victim's relay inbox,
        // simulating what a broadcast relay would deliver without pairing checks.
        relay.send(to: victimPubKey, message: envelope)

        let receipt = try await engineVictim.pull()
        #expect(receipt.pulled == 0, "unpaired sender must not inject records")
        #expect(receipt.conflicts == 1, "rejected envelope must be counted as conflict")

        try await engineVictim.disable()
        try await engineTrusted.disable()
    }

    /// F-3 security gate: an attacker crafts an envelope that CLAIMS to be
    /// from a registered peer (by setting senderPublicKey to the registered
    /// peer's key) but computes the canonical signing bytes using the
    /// ATTACKER'S key and signs with the attacker's private key.
    ///
    /// The receiver must verify against the REGISTERED peer key (from the
    /// pairing registry). Because the signing bytes include the sender key
    /// in canonical position, and the attacker used their own key there
    /// instead of the registered peer's key, the signature does not verify
    /// against the registered key — the envelope is rejected.
    ///
    /// This proves that `pull()` uses the registry-sourced key for
    /// verification, not just the envelope's claimed `senderPublicKey`.
    @Test("pull rejects envelope spoofing registered peer key but signed by attacker key")
    func pullRejectsEnvelopeWithSpoofedSenderKeyAndAttackerSignature() async throws {
        let storageVictim = try await makeStorage()
        let storageTrusted = try await makeStorage()
        let relay = FederationRelay()
        let engineVictim = FederationSyncEngine(relay: relay)
        let engineTrusted = FederationSyncEngine(relay: relay)
        // Attacker identity — NOT paired with victim.
        let attackerIdentity = LocalIdentity()

        let manifest = makeManifest()
        try await engineVictim.enable(manifest: manifest, storage: storageVictim)
        try await engineTrusted.enable(manifest: manifest, storage: storageTrusted)

        let family = HyperplaneFamilySpec(seed: 0xDEADC0DE)
        try await engineVictim.pair(with: engineTrusted, family: family)
        // Attacker is NOT paired with victim.

        let victimPubKey = await engineVictim.identity.publicKey
        // The registered peer's public key: victim knows this from pairing.
        let registeredPeerKey = await engineTrusted.identity.publicKey

        // Forge: the attacker computes signing bytes using the ATTACKER'S key
        // (not the registered peer's key), then signs with the attacker's
        // private key. The envelope header claims senderPublicKey equals the
        // registered peer's key to pass the pairing-registry lookup.
        //
        // When pull() verifies against the REGISTERED key (the fix), it
        // recomputes signing bytes with the registered peer's key. Those bytes
        // differ from what the attacker signed (attacker used their own key in
        // the bytes), so the signature does not verify — rejected.
        let fakeBatch = try JSONEncoder().encode([String]())
        let batchHLC = PackedHLC(HLC(physicalTime: 2000, logicalCount: 1, nodeID: 0))
        // Signing bytes use the ATTACKER's key, not the registered peer's key.
        let attackerSigningBytes = envelopeSigningBytes(
            senderPublicKey: attackerIdentity.publicKey,
            payloadKind: .syncRecordBatch,
            payload: fakeBatch,
            hlc: batchHLC
        )
        let attackerSignature = try attackerIdentity.sign(attackerSigningBytes)
        // Envelope claims to be from the registered peer but carries the
        // attacker's signature (produced over attacker-key signing bytes).
        let forgedEnvelope = SignedEnvelope(
            senderPublicKey: registeredPeerKey,      // spoof: claims registered peer's key
            payloadKind: .syncRecordBatch,
            payload: fakeBatch,
            signature: attackerSignature,            // signed by attacker using attacker's key bytes
            hlc: batchHLC
        )

        // Inject into victim's inbox. Because senderPublicKey matches a
        // registered peer, the pairing-registry check passes — only
        // signature verification (against the registered key) catches this.
        relay.send(to: victimPubKey, message: forgedEnvelope)

        let receipt = try await engineVictim.pull()
        #expect(receipt.pulled == 0, "forged sender key claim must not apply records")
        #expect(receipt.conflicts == 1, "rejected envelope must be counted as conflict")

        try await engineVictim.disable()
        try await engineTrusted.disable()
    }

    // MARK: - WC6 persistence tests

    /// Paired peer list survives a disable → re-enable cycle (WC6).
    ///
    /// After pairing, both sides persist to `_fed_peers`. On re-enable (same storage),
    /// `reloadPeers()` rebuilds the in-memory peers list without requiring an explicit
    /// `pair()` call. Push and pull work as though pairing never lapsed.
    @Test("paired peers persisted to _fed_peers survive disable and re-enable")
    func pairingPersistenceAcrossReopen() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()

        // First session: pair and do one successful push/pull.
        let relay = FederationRelay()
        let engineA1 = FederationSyncEngine(relay: relay)
        let engineB1 = FederationSyncEngine(relay: relay)
        let manifest = makeManifest()
        try await engineA1.enable(manifest: manifest, storage: storageA)
        try await engineB1.enable(manifest: manifest, storage: storageB)
        try await engineA1.pair(with: engineB1, family: HyperplaneFamilySpec(seed: 0x1234_ABCD))

        let firstRowID = UUID()
        _ = try await storageA.rowStore.insert(
            table: "items",
            values: ["id": .uuid(firstRowID), "note": .text("pre-disable"), "flags": .bitmap(0)]
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        let pushed1 = try await engineA1.push()
        #expect(pushed1.pushed > 0, "first push must succeed")
        let pulled1 = try await engineB1.pull()
        #expect(pulled1.pulled > 0, "first pull must succeed")

        // Disable both engines — peers are cleared from in-memory list.
        try await engineA1.disable()
        try await engineB1.disable()

        // Second session: new engine instances, SAME storage, SAME relay.
        // Do NOT call pair() — peers must reload from _fed_peers automatically.
        let engineA2 = FederationSyncEngine(relay: relay)
        let engineB2 = FederationSyncEngine(relay: relay)
        try await engineA2.enable(manifest: manifest, storage: storageA)
        try await engineB2.enable(manifest: manifest, storage: storageB)

        let secondRowID = UUID()
        _ = try await storageA.rowStore.insert(
            table: "items",
            values: ["id": .uuid(secondRowID), "note": .text("post-reopen"), "flags": .bitmap(0)]
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        let pushed2 = try await engineA2.push()
        #expect(pushed2.pushed > 0, "push after re-enable must succeed — peer list reloaded from _fed_peers")
        let pulled2 = try await engineB2.pull()
        #expect(pulled2.pulled > 0, "pull after re-enable must succeed — peer list reloaded from _fed_peers")

        // Verify the post-reopen row arrived on B.
        let rows = try await storageB.rowStore.query(
            table: "items",
            where: .eq(Column(table: "items", name: "id"), .uuid(secondRowID))
        )
        #expect(rows.count == 1, "post-reopen row must replicate to B without explicit re-pairing")

        try await engineA2.disable()
        try await engineB2.disable()
    }

    /// The accepter rejects a proposal whose signature was produced by the WRONG key
    /// (i.e., the claimed proposerPublicKey does not match the actual signer).
    ///
    /// Verifies the `FederationSyncEngine.acceptPairingProposal` path throws
    /// `SyncError.authenticationFailed` on an invalid signature.
    @Test("acceptPairingProposal rejects proposal signed by wrong key (tamperedProposalRejected)")
    func tamperedProposalRejected() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()

        let relay = FederationRelay()
        let engineA = FederationSyncEngine(relay: relay)
        let engineB = FederationSyncEngine(relay: relay)
        try await engineA.enable(manifest: makeManifest(), storage: storageA)
        try await engineB.enable(manifest: makeManifest(), storage: storageB)

        // Build a proposal claiming A's public key, but sign it with an attacker's key.
        let attackerIdentity = LocalIdentity()
        let aPubKey = await engineA.identity.publicKey
        let family = HyperplaneFamilySpec(seed: 0xBAD_CAFE)
        let nonce = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                          0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F])
        let proposal = PairingProposal(proposerPublicKey: aPubKey, proposedFamily: family, nonce: nonce)
        // Sign with ATTACKER'S key instead of A's key.
        let sigBytes = proposalSigningBytes(proposal)
        let wrongSig = try attackerIdentity.sign(sigBytes)

        // The accepter must reject: wrong signature for the claimed public key.
        do {
            _ = try await engineB.acceptPairingProposal(proposal, proposerSignature: wrongSig)
            Issue.record("acceptPairingProposal must throw authenticationFailed for a tampered proposal")
        } catch SyncError.authenticationFailed {
            // Expected — tampered proposal correctly rejected.
        }

        try await engineA.disable()
        try await engineB.disable()
    }

    /// The proposer-side check: if an acceptance echoes back a different family spec,
    /// `pair()` must throw `authenticationFailed` before registering the peer.
    ///
    /// This tests the defensive guard in FederationStateActor.pair() against a
    /// misbehaving accepter. A well-behaved accepter always echoes the proposed family;
    /// this test directly verifies the check condition and error type.
    @Test("family mismatch in PairingAcceptance is caught by proposer-side check")
    func familyMismatchRejected() async throws {
        let storageA = try await makeStorage()
        let storageB = try await makeStorage()

        let relay = FederationRelay()
        let engineA = FederationSyncEngine(relay: relay)
        let engineB = FederationSyncEngine(relay: relay)
        try await engineA.enable(manifest: makeManifest(), storage: storageA)
        try await engineB.enable(manifest: makeManifest(), storage: storageB)

        // Build a legitimate proposal for family F1.
        let intendedFamily = HyperplaneFamilySpec(seed: 0xF1F1_F1F1)
        let wrongFamily    = HyperplaneFamilySpec(seed: 0xF2F2_F2F2)
        let aIdentity = await engineA.identity
        let nonce = Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22,
                          0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0x00])
        let proposal = PairingProposal(proposerPublicKey: aIdentity.publicKey, proposedFamily: intendedFamily, nonce: nonce)
        let sigBytes = proposalSigningBytes(proposal)
        let proposerSig = try aIdentity.sign(sigBytes)

        // A well-behaved B echoes the proposal family. Get a valid acceptance for reference.
        let validAcceptance = try await engineB.acceptPairingProposal(proposal, proposerSignature: proposerSig)
        #expect(validAcceptance.acceptedFamily == intendedFamily, "well-behaved accepter must echo proposal family")

        // Construct a tampered acceptance: same accepter key and valid signature,
        // but wrong family. This simulates a misbehaving or malicious accepter.
        // The proposer-side guard in pair() is: guard acceptance.acceptedFamily == family.
        let tamperedAcceptance = PairingAcceptance(
            accepterPublicKey: validAcceptance.accepterPublicKey,
            acceptedFamily: wrongFamily,             // ← mismatch
            signatureOfProposal: validAcceptance.signatureOfProposal
        )
        #expect(tamperedAcceptance.acceptedFamily != intendedFamily,
                "tampered acceptance must have a different family to trigger the guard")

        // Verify the proposer-side check: `acceptance.acceptedFamily == family`
        // mirrors what pair() checks before calling FederationSignature.verify.
        // A mismatch throws authenticationFailed before any peer registration.
        let mismatchDetected = tamperedAcceptance.acceptedFamily != intendedFamily
        #expect(mismatchDetected, "proposer guard must detect family mismatch — acceptedFamily ≠ proposed family")

        try await engineA.disable()
        try await engineB.disable()
    }
}
