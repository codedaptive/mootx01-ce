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
        let engineA = FederationSyncEngine()
        let engineB = FederationSyncEngine()

        try await engineA.enable(manifest: makeManifest(), storage: storageA)
        try await engineB.enable(manifest: makeManifest(), storage: storageB)

        let relay = FederationRelay()
        let family = HyperplaneFamilySpec(seed: 0xDEADBEEF)
        try await engineA.pair(with: engineB, via: relay, family: family)

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
    /// authorization; the sender must be in the paired peer list.
    @Test("pull rejects signed envelope from sender that is not a paired peer")
    func pullRejectsSignedEnvelopeFromUnpairedSender() async throws {
        let storageVictim = try await makeStorage()
        let storageTrusted = try await makeStorage()
        let engineVictim = FederationSyncEngine()
        let engineTrusted = FederationSyncEngine()
        // Attacker identity — NOT paired with victim.
        let attackerIdentity = LocalIdentity()

        let manifest = makeManifest()
        try await engineVictim.enable(manifest: manifest, storage: storageVictim)
        try await engineTrusted.enable(manifest: manifest, storage: storageTrusted)

        let relay = FederationRelay()
        let family = HyperplaneFamilySpec(seed: 0xDEADC0DE)
        try await engineVictim.pair(with: engineTrusted, via: relay, family: family)
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
}
