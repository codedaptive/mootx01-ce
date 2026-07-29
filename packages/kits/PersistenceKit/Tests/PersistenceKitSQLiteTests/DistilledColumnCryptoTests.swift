// DistilledColumnCryptoTests.swift
//
// SPEC_DISTILLATION_STORAGE §2 — "At-rest protection is inherited":
// the `distilled` column is content-derived text and carries the same
// row-level protection class as `content` under the Mode-2 row-crypto
// seam. These tests pin:
//
//   1. `encryptedForWrite` seals `distilled` exactly as it seals
//      `content` — including on a representation-only value map (a
//      distillation write is an UPDATE that carries no `content`).
//   2. `decryptedForRead` opens a sealed `distilled` back to text.
//   3. `assertContentKeyIDInvariant` refuses plaintext `distilled`
//      with no keyID on an encrypting estate (the same structural
//      guard content has — FUP-D extended).
//   4. The updateRows write path on an encrypting SQLite estate runs
//      the seam, so a representation UPDATE round-trips through
//      storage as ciphertext at rest and text on read.
//   5. Plaintext estates (Mode 1) are byte-identical to before.
//
// The Rust suite `encryption_tests.rs` mirrors the seam cases
// (twin-parity gate).

import Testing
import Foundation
import CryptoKit
import SubstrateTypes
import PersistenceKit
import PersistenceKitSQLite

struct DistilledColumnCryptoTests {

    // MARK: - Fixtures

    /// A drawers-shaped schema reduced to the columns these tests exercise:
    /// the two protected text columns plus keyID (mirrors
    /// EncryptionInvariantTests).
    private func makeSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "DistilledCryptoKit",
            version: 1,
            tables: [
                TableDeclaration(
                    name: "drawers",
                    columns: [
                        .text("id"),
                        .text("content"),
                        .text("distilled", nullable: true),
                        .text("keyID", nullable: true)
                    ],
                    primaryKey: ["id"]
                )
            ]
        )
    }

    private func freshDBURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("distilled-crypto-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.sqlite")
    }

    private func makeStorage(_ encryption: EstateEncryptionConfig, at url: URL) throws -> SQLiteStorage {
        try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(),
            backend: .sqlite(url: url, busyTimeout: 5.0),
            encryptionConfig: encryption
        ))
    }

    // MARK: - Seam function unit tests

    @Test("encryptedForWrite seals distilled alongside content and stamps keyID")
    func sealsDistilledWithContent() throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        let values: [String: TypedValue] = [
            "id": .text("d1"),
            "content": .text("original body"),
            "distilled": .text("dense body"),
        ]
        let sealed = try encryptedForWrite(values, config: config)
        guard case .blob = sealed["content"] else {
            Issue.record("content was not sealed"); return
        }
        guard case .blob = sealed["distilled"] else {
            Issue.record("distilled was not sealed"); return
        }
        #expect(sealed["keyID"] == .text(config.keyIdentifier!))
    }

    @Test("encryptedForWrite seals a representation-only value map (no content key)")
    func sealsRepresentationOnlyWrite() throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        // A distillation write is an UPDATE carrying only representation
        // columns — the seam must still run for it.
        let values: [String: TypedValue] = ["distilled": .text("dense body")]
        let sealed = try encryptedForWrite(values, config: config)
        guard case .blob = sealed["distilled"] else {
            Issue.record("representation-only distilled was not sealed"); return
        }
        #expect(sealed["keyID"] == .text(config.keyIdentifier!))
    }

    @Test("decryptedForRead opens a sealed distilled back to text")
    func opensDistilled() throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        let sealed = try encryptedForWrite(
            ["content": .text("body"), "distilled": .text("dense body")],
            config: config)
        let opened = try decryptedForRead(sealed, config: config)
        #expect(opened["content"] == .text("body"))
        #expect(opened["distilled"] == .text("dense body"))
    }

    @Test("plaintext estates pass distilled through unchanged (Mode 1 no-op)")
    func plaintextNoOp() throws {
        let values: [String: TypedValue] = [
            "content": .text("body"), "distilled": .text("dense body"),
        ]
        let out = try encryptedForWrite(values, config: .plaintext)
        #expect(out["content"] == .text("body"))
        #expect(out["distilled"] == .text("dense body"))
        #expect(out["keyID"] == nil)
    }

    @Test("invariant guard refuses plaintext distilled with no keyID on an encrypting estate")
    func invariantRefusesPlaintextDistilled() throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        #expect(throws: (any Error).self) {
            try assertContentKeyIDInvariant(
                ["id": .text("d1"), "distilled": .text("leaked dense body")],
                table: "drawers",
                config: config)
        }
        // NULL distilled (the cleared-representation write) is exempt —
        // clearing carries nothing to encrypt.
        try assertContentKeyIDInvariant(
            ["id": .text("d1"), "distilled": .null],
            table: "drawers",
            config: config)
    }

    // MARK: - Storage round-trip through updateRows

    @Test("representation UPDATE on an encrypting estate round-trips (sealed at rest, text on read)")
    func updateRowsSealsDistilled() async throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        let url = freshDBURL()
        let storage = try makeStorage(config, at: url)
        try await storage.open(schema: makeSchema())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: ["id": .text("d1"), "content": .text("original body")])

        // The distillation write: representation-only UPDATE.
        let updated = try await storage.rowStore.update(
            table: "drawers",
            values: ["distilled": .text("dense body")],
            where: .eq(Column(table: "drawers", name: "id"), .text("d1")))
        #expect(updated == 1)

        // Read back through the decrypt seam: text again.
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1")))
        #expect(rows.first?["distilled"] == .text("dense body"))
        #expect(rows.first?["content"] == .text("original body"))

        // At-rest check: a keyless open of the same file (plaintext config —
        // the decrypt seam no-ops) must see ciphertext blobs, not text. This
        // is what proves the UPDATE path ran the encrypt seam.
        let rawStorage = try makeStorage(.plaintext, at: url)
        try await rawStorage.open(schema: makeSchema())
        let rawRows = try await rawStorage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1")))
        guard case .blob = rawRows.first?["distilled"] else {
            Issue.record("distilled stored as plaintext at rest after updateRows"); return
        }
        guard case .blob = rawRows.first?["content"] else {
            Issue.record("content stored as plaintext at rest"); return
        }
    }

    @Test("erasure UPDATE (content = empty) still passes on an encrypting estate")
    func updateRowsErasureStillPasses() async throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        let url = freshDBURL()
        let storage = try makeStorage(config, at: url)
        try await storage.open(schema: makeSchema())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: ["id": .text("d1"), "content": .text("body"), "distilled": .text("dense")])

        // The expunge scrub shape: zero content, NULL the representation.
        let updated = try await storage.rowStore.update(
            table: "drawers",
            values: ["content": .text(""), "distilled": .null],
            where: .eq(Column(table: "drawers", name: "id"), .text("d1")))
        #expect(updated == 1)

        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1")))
        // Empty content stays plaintext-empty (the invariant's erasure
        // exemption); distilled is gone.
        #expect(rows.first?["content"] == .text(""))
        #expect(rows.first?["distilled"] == nil || rows.first?["distilled"] == .null)
    }
}
