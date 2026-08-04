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
// The same rules cover `subject`, which is content-derived text on the
// same terms. Those cases additionally pin what the table filter buys:
// `kg_facts` declares its own `subject` column — the subject term of an
// S-P-O triple, on a table with no keyID column — and must come through
// every seam entry point byte-identical. A seam that intercepted by column
// name alone would fail those tests.
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
    /// the three protected text columns plus keyID (mirrors
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
                        .text("subject", nullable: true),
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
        let sealed = try encryptedForWrite(values, table: "drawers", config: config)
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
        let sealed = try encryptedForWrite(values, table: "drawers", config: config)
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
            table: "drawers", config: config)
        let opened = try decryptedForRead(sealed, table: "drawers", config: config)
        #expect(opened["content"] == .text("body"))
        #expect(opened["distilled"] == .text("dense body"))
    }

    @Test("plaintext estates pass distilled through unchanged (Mode 1 no-op)")
    func plaintextNoOp() throws {
        let values: [String: TypedValue] = [
            "content": .text("body"), "distilled": .text("dense body"),
        ]
        let out = try encryptedForWrite(values, table: "drawers", config: .plaintext)
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

    // MARK: - Table-aware protection (MXE-RD)

    /// The regression this rescope exists for. `kg_facts` declares its own
    /// `subject` column — the subject term of an S-P-O triple, not a
    /// content summary — and has no `keyID` column at all. A by-name seam
    /// would seal it and stamp a keyID, producing an INSERT that names a
    /// column the table does not have. This fails against any
    /// implementation that filters by column name alone.
    @Test("kg_facts.subject is never sealed and never gains a keyID")
    func kgFactsSubjectUntouched() throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        let fact: [String: TypedValue] = [
            "id": .text("f1"),
            "subject": .text("Ada Lovelace"),
            "predicate": .text("worked_on"),
            "object": .text("Analytical Engine"),
        ]
        let out = try encryptedForWrite(fact, table: "kg_facts", config: config)
        // Byte-identical to the input: no sealing, no keyID stamp.
        #expect(out == fact)
        #expect(out["keyID"] == nil)
        // A read of the same row is equally untouched.
        #expect(try decryptedForRead(fact, table: "kg_facts", config: config) == fact)
    }

    /// The invariant guard must not fire for a table it does not protect.
    /// Before the table filter it would have rejected every KG fact write
    /// on an encrypting estate, because `subject` carried plaintext and the
    /// row has no keyID to satisfy the guard.
    @Test("the invariant guard does not fire for kg_facts")
    func invariantSparesKGFacts() throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        try assertContentKeyIDInvariant(
            ["id": .text("f1"), "subject": .text("Ada Lovelace")],
            table: "kg_facts",
            config: config)
    }

    @Test("encryptedForWrite seals subject alongside content and distilled")
    func sealsSubjectWithContent() throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        let values: [String: TypedValue] = [
            "id": .text("d1"),
            "content": .text("original body"),
            "distilled": .text("dense body"),
            "subject": .text("a summary of the body"),
        ]
        let sealed = try encryptedForWrite(values, table: "drawers", config: config)
        for column in ["content", "distilled", "subject"] {
            guard case .blob = sealed[column] else {
                Issue.record("\(column) was not sealed"); return
            }
        }
        #expect(sealed["keyID"] == .text(config.keyIdentifier!))
    }

    /// The subject's provenance columns are metadata about how a subject was
    /// produced, not the subject text — they stay readable so the recall path
    /// can decide whether a subject needs regenerating without holding a key.
    @Test("subject provenance columns stay plaintext")
    func subjectProvenanceStaysPlaintext() throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        let sealed = try encryptedForWrite(
            [
                "content": .text("body"),
                "subject": .text("a summary"),
                "subject_pipeline_version": .text("2.1.0"),
                "subject_at": .text("2026-08-03T10:00:00Z"),
            ],
            table: "drawers", config: config)
        #expect(sealed["subject_pipeline_version"] == .text("2.1.0"))
        #expect(sealed["subject_at"] == .text("2026-08-03T10:00:00Z"))
        guard case .blob = sealed["subject"] else {
            Issue.record("subject was not sealed"); return
        }
    }

    @Test("invariant guard refuses plaintext subject with no keyID on drawers")
    func invariantRefusesPlaintextSubject() throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        #expect(throws: (any Error).self) {
            try assertContentKeyIDInvariant(
                ["id": .text("d1"), "subject": .text("leaked summary")],
                table: "drawers",
                config: config)
        }
        // Empty-string subject is the erasure exemption, same as content.
        try assertContentKeyIDInvariant(
            ["id": .text("d1"), "subject": .text("")],
            table: "drawers",
            config: config)
    }

    @Test("plaintext and FullDatabase estates pass subject through untouched")
    func subjectUntouchedOutsideRowCrypto() throws {
        let values: [String: TypedValue] = ["subject": .text("a summary")]
        for mode in [EstateEncryptionConfig.plaintext, EstateEncryptionConfig(.fullDatabase)] {
            let out = try encryptedForWrite(values, table: "drawers", config: mode)
            #expect(out["subject"] == .text("a summary"))
            #expect(out["keyID"] == nil)
            #expect(try decryptedForRead(values, table: "drawers", config: mode) == values)
        }
    }

    /// A subject-only UPDATE is the subjecting write path's shape. It must
    /// seal, stamp keyID, and round-trip back to the original text.
    @Test("subject-only UPDATE seals as a blob, stamps keyID, and round-trips")
    func updateRowsSealsSubject() async throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        let url = freshDBURL()
        let storage = try makeStorage(config, at: url)
        try await storage.open(schema: makeSchema())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: ["id": .text("d1"), "content": .text("original body")])

        let updated = try await storage.rowStore.update(
            table: "drawers",
            values: ["subject": .text("a summary of the body")],
            where: .eq(Column(table: "drawers", name: "id"), .text("d1")))
        #expect(updated == 1)

        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1")))
        #expect(rows.first?["subject"] == .text("a summary of the body"))

        // At-rest check through a keyless open: the decrypt seam no-ops, so
        // what the file actually holds is visible.
        let rawStorage = try makeStorage(.plaintext, at: url)
        try await rawStorage.open(schema: makeSchema())
        let rawRows = try await rawStorage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1")))
        guard case .blob = rawRows.first?["subject"] else {
            Issue.record("subject stored as plaintext at rest after updateRows"); return
        }
        #expect(rawRows.first?["keyID"] == .text(config.keyIdentifier!))
    }

    /// A capture-time INSERT seals all three protected columns at once.
    @Test("capture-time write seals content, distilled, and subject")
    func insertSealsAllThree() async throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        let url = freshDBURL()
        let storage = try makeStorage(config, at: url)
        try await storage.open(schema: makeSchema())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: [
                "id": .text("d1"),
                "content": .text("original body"),
                "distilled": .text("dense body"),
                "subject": .text("a summary"),
            ])

        let rawStorage = try makeStorage(.plaintext, at: url)
        try await rawStorage.open(schema: makeSchema())
        let raw = try await rawStorage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1")))
        for column in ["content", "distilled", "subject"] {
            guard case .blob = raw.first?[column] else {
                Issue.record("\(column) stored as plaintext at rest"); return
            }
        }
    }

    /// The structured projection reads `subject` but does not ask for
    /// `keyID` — the seam needs the key identifier to open the value, so the
    /// backend selects it and strips it back out. Without that, `subject`
    /// would come back as raw ciphertext bytes and decode as absent.
    @Test("a projection that reads subject but omits keyID still decrypts")
    func projectedReadDecryptsSubject() async throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        let url = freshDBURL()
        let storage = try makeStorage(config, at: url)
        try await storage.open(schema: makeSchema())
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: [
                "id": .text("d1"),
                "content": .text("original body"),
                "subject": .text("a summary of the body"),
            ])

        // The no-blob projection shape: subject rides it, keyID does not.
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1")),
            orderBy: [], limit: nil, offset: nil,
            columns: ["id", "subject"])
        #expect(rows.first?["subject"] == .text("a summary of the body"))
        // The projection contract is unchanged: the borrowed keyID is gone
        // and the omitted content column never appears.
        #expect(rows.first?["keyID"] == nil)
        #expect(rows.first?["content"] == nil)
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
