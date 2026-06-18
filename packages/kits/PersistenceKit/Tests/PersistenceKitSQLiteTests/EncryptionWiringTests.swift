// EncryptionWiringTests.swift
//
// Mission ENC-01 — integration tests for the SQLiteBackend crypto seam.
// Verifies the two end-to-end behaviors the mission requires of the
// insertRow/queryRows wiring:
//   - Mode 1 (plaintext) is a pure no-op: content is stored and read
//     unchanged and no keyID is written (the "null-key" case).
//   - Mode 2 (row encryption) round-trips: a row inserted under an
//     encrypting estate reads back as the original plaintext, the keyID
//     column carries the estate key identifier, and a reader opened in
//     plaintext mode against the same file sees ciphertext, not plaintext
//     — proof the content is encrypted at rest.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitSQLite
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

struct EncryptionWiringTests {

    /// A drawers-shaped schema with the nullable keyID column the mission
    /// adds, reduced to the columns these tests exercise.
    private func makeSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "EncTestKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "drawers",
                    columns: [
                        .text("id"),
                        .text("content"),
                        .text("keyID", nullable: true)
                    ],
                    primaryKey: ["id"]
                )
            ]
        )
    }

    private func makeStorage(_ encryption: EstateEncryptionConfig, at url: URL) throws -> SQLiteStorage {
        try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0),
            encryptionConfig: encryption
        ))
    }

    private func freshDBURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enc-wiring-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.sqlite")
    }

    /// Mode 1: content unchanged on read, no keyID written. This is the
    /// "null-key, no crypto applied" case from the mission.
    @Test func plaintextModeIsNoOp() async throws {
        let storage = try makeStorage(EstateEncryptionConfig(.plaintext), at: freshDBURL())
        try await storage.open(schema: makeSchema())

        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: ["id": .text("d1"), "content": .text("plain note")]
        )
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1"))
        )
        #expect(rows.count == 1)
        #expect(rows[0]["content"] == .text("plain note"))
        // keyID is NULL: no crypto path ran.
        #expect((rows[0]["keyID"] ?? .null) == .null)
        await storage.close()
    }

    /// Mode 2: insert under an encrypting estate, read back the original
    /// plaintext, confirm keyID is the estate identifier, and confirm a
    /// plaintext-mode reader on the same file sees ciphertext at rest.
    @Test func rowEncryptionRoundTripThroughStorage() async throws {
        let url = freshDBURL()
        let encryption = EstateEncryptionConfig(.rowEncryption)
        let storage = try makeStorage(encryption, at: url)
        try await storage.open(schema: makeSchema())

        let secret = "the encrypted note"
        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: ["id": .text("d1"), "content": .text(secret)]
        )

        // The encrypting estate reads back the original plaintext.
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1"))
        )
        #expect(rows.count == 1)
        #expect(rows[0]["content"] == .text(secret))
        // keyID carries the estate key identifier.
        #expect(rows[0]["keyID"] == .text(encryption.keyIdentifier!))
        await storage.close()

        // A reader with no key (plaintext mode) sees ciphertext at rest:
        // the stored content is not the plaintext string.
        let reader = try makeStorage(EstateEncryptionConfig(.plaintext), at: url)
        try await reader.open(schema: makeSchema())
        let raw = try await reader.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1"))
        )
        #expect(raw.count == 1)
        #expect(raw[0]["content"] != .text(secret),
                "content must be ciphertext at rest, not plaintext")
        await reader.close()
    }

    /// Mode 3 (FullDatabase): the whole estate file — schema included — is
    /// encrypted by SQLCipher. A reader with no key cannot open it (page 1, the
    /// schema, is ciphertext); the correct key reopens and round-trips. This is
    /// the Apple lockdown guarantee, mirroring the Rust port.
    @Test func fullDatabaseWholeFileLockdown() async throws {
        let url = freshDBURL()
        // Deterministic 32-byte whole-file key (the per-install Keychain key in
        // production; an explicit key here so the reopen uses the same one).
        let key = Data((0..<32).map { UInt8($0) })

        // Write under the whole-file key.
        let writer = try makeStorage(.fullDatabase(key: key), at: url)
        try await writer.open(schema: makeSchema())
        _ = try await writer.rowStore.insert(
            table: "drawers",
            values: ["id": .text("d1"), "content": .text("locked note")]
        )
        await writer.close()

        // No key → page 1 is ciphertext → the file cannot be opened/read as a
        // database. Whichever access touches the DB first (the WAL pragma at
        // open, or the schema DDL) fails — an external process cannot read or
        // alter the structure.
        await #expect(throws: (any Error).self) {
            let noKey = try makeStorage(EstateEncryptionConfig(.plaintext), at: url)
            try await noKey.open(schema: makeSchema())
        }

        // The correct whole-file key reopens and round-trips the content
        // (FullDatabase no-ops the per-row seam, so content is verbatim).
        let reader = try makeStorage(.fullDatabase(key: key), at: url)
        try await reader.open(schema: makeSchema())
        let rows = try await reader.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1"))
        )
        #expect(rows.count == 1)
        #expect(rows[0]["content"] == .text("locked note"))
        await reader.close()
    }
}
