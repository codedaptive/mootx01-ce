// EncryptionInvariantTests.swift
//
// Mission FUP-D (E-1) — the structural content/keyID write-boundary guard.
//
// AUDIT-01 Zone E flagged that the content/keyID invariant ("protected text on
// an encrypting estate must be stored as ciphertext") was convention-only,
// living in a comment on upsertRow. A raw write path that bypassed the
// encryption seam could silently persist plaintext on an encrypting estate —
// a leaky row.
//
// The seam now runs on every write verb (insertRow, upsertRow, updateRows), so
// the guard is the structural safety net beneath it rather than the only
// safeguard. The guard tests the value's TYPE: ciphertext is a blob, so
// non-empty text in a protected column means the seam did not run — whether or
// not the row also carries a keyID.
//
// These tests pin that contract:
//   - A .text content upsert on an encrypting estate is sealed and stamped,
//     not written as plaintext.
//   - Mode 1 (plaintext) is unaffected — byte-identical to today.
//   - The insert and update paths on an encrypting estate are undisturbed.
//
// NOTE ON PLACEMENT: the mission text lists this file under PersistenceKitTests,
// but that target depends only on [PersistenceKit, SubstrateLib] and cannot import
// PersistenceKitSQLite, where the guard lives. Editing Package.swift is forbidden,
// so the test lives here in PersistenceKitSQLiteTests alongside EncryptionWiringTests.

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

struct EncryptionInvariantTests {

    /// A drawers-shaped schema with the nullable keyID column, reduced to the
    /// columns these tests exercise (mirrors EncryptionWiringTests).
    private func makeSchema() -> SchemaDeclaration {
        SchemaDeclaration(
            kitID: "EncInvariantKit",
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
            .appendingPathComponent("enc-invariant-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("test.sqlite")
    }

    /// E-1 (upsert path): a content upsert on an encrypting estate is SEALED,
    /// not refused. upsertRow runs the encryption seam like insertRow and
    /// updateRows, so the plaintext becomes ciphertext and the row is stamped
    /// with the estate keyID before the guard runs.
    ///
    /// This assertion inverted when the seam was wired into upsert. It
    /// previously expected a throw, which was correct only while upsert was
    /// the one write verb the seam did not cover. Sealing is the better of the
    /// two outcomes the invariant permits — the write succeeds AND no
    /// plaintext reaches disk.
    @Test func contentUpsertOnEncryptingEstateIsSealed() async throws {
        let encryption = EstateEncryptionConfig(.rowEncryption)
        let storage = try makeStorage(encryption, at: freshDBURL())
        try await storage.open(schema: makeSchema())

        _ = try await storage.rowStore.upsert(
            table: "drawers",
            values: ["id": .text("d1"), "content": .text("plaintext secret")],
            conflictColumns: ["id"]
        )
        // Read through the decrypt seam: text again, keyID stamped.
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1"))
        )
        #expect(rows.count == 1)
        #expect(rows[0]["content"] == .text("plaintext secret"))
        #expect(rows[0]["keyID"] == .text(encryption.keyIdentifier!))
        await storage.close()
    }

    /// Mode 1 (plaintext): the same content upsert is unaffected — it succeeds,
    /// reads back verbatim, and writes no keyID. Byte-identical to today.
    @Test func plaintextContentUpsertUnaffected() async throws {
        let storage = try makeStorage(EstateEncryptionConfig(.plaintext), at: freshDBURL())
        try await storage.open(schema: makeSchema())

        _ = try await storage.rowStore.upsert(
            table: "drawers",
            values: ["id": .text("d1"), "content": .text("plain note")],
            conflictColumns: ["id"]
        )
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1"))
        )
        #expect(rows.count == 1)
        #expect(rows[0]["content"] == .text("plain note"))
        #expect((rows[0]["keyID"] ?? .null) == .null)
        await storage.close()
    }

    /// E-1 (update path): a content update on an encrypting estate runs the
    /// encryption seam (wired in the W1_DISTILL wave, when UPDATE became a
    /// protected-text write path for the distilled-representation columns),
    /// so the write is sealed + keyID-stamped rather than refused. The
    /// invariant's INTENT — plaintext protected text never persists on an
    /// encrypting estate — is now satisfied by encryption, and the guard
    /// remains the safety net for any write path that bypasses the seam.
    @Test func contentUpdateOnEncryptingEstateEncrypts() async throws {
        let encryption = EstateEncryptionConfig(.rowEncryption)
        let storage = try makeStorage(encryption, at: freshDBURL())
        try await storage.open(schema: makeSchema())

        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: ["id": .text("d1"), "content": .text("original")]
        )
        let updated = try await storage.rowStore.update(
            table: "drawers",
            values: ["content": .text("updated secret")],
            where: .eq(Column(table: "drawers", name: "id"), .text("d1"))
        )
        #expect(updated == 1)
        // Read through the decrypt seam: text again, keyID stamped.
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1"))
        )
        #expect(rows.first?["content"] == .text("updated secret"))
        #expect(rows.first?["keyID"] == .text(encryption.keyIdentifier!))
        await storage.close()
    }

    /// The correct insert path on an encrypting estate is not disturbed by the
    /// guard: the encryption seam stamps a keyID before the guard runs, so the
    /// content round-trips and the row carries the estate key identifier.
    @Test func encryptingInsertStillSucceeds() async throws {
        let encryption = EstateEncryptionConfig(.rowEncryption)
        let storage = try makeStorage(encryption, at: freshDBURL())
        try await storage.open(schema: makeSchema())

        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: ["id": .text("d1"), "content": .text("the encrypted note")]
        )
        let rows = try await storage.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1"))
        )
        #expect(rows.count == 1)
        #expect(rows[0]["content"] == .text("the encrypted note"))
        #expect(rows[0]["keyID"] == .text(encryption.keyIdentifier!))
        await storage.close()
    }

    // MARK: - MXE-PW: a non-empty keyID is not proof of encryption

    /// Read the database file's raw bytes and report whether `marker` appears.
    /// The read path cannot be trusted for this question: `decryptedForRead`
    /// passes non-blob values through unchanged, so a plaintext-at-rest row
    /// reads back as the correct string and hides the failure. Only the bytes
    /// on disk answer it.
    private func rawFileContains(_ marker: String, at url: URL) throws -> Bool {
        let bytes = try Data(contentsOf: url)
        return bytes.range(of: Data(marker.utf8)) != nil
    }

    /// THE REGRESSION TEST. Upsert plaintext content while ALSO supplying a
    /// non-empty keyID — the exact value pair `decryptedForRead` produces and
    /// snapshot replication forwards.
    ///
    /// Before this fix the guard read the keyID, concluded the text must be
    /// ciphertext, and returned OK; the row landed as plaintext on an
    /// encrypting estate's disk. The seam now runs first, so the content is
    /// sealed and the supplied keyID is replaced by the estate's own. Verified
    /// against the raw file bytes, not the read path.
    @Test func upsertWithPlaintextAndNonEmptyKeyIDNeverWritesPlaintext() async throws {
        let encryption = EstateEncryptionConfig(.rowEncryption)
        let url = freshDBURL()
        let storage = try makeStorage(encryption, at: url)
        try await storage.open(schema: makeSchema())

        let marker = "MXE-PW-UPSERT-PLAINTEXT-MARKER"
        _ = try await storage.rowStore.upsert(
            table: "drawers",
            values: [
                "id": .text("d1"),
                "content": .text(marker),
                // A keyID from some other estate. Presence must prove nothing.
                "keyID": .text(UUID().uuidString)
            ],
            conflictColumns: ["id"]
        )
        await storage.close()

        #expect(try rawFileContains(marker, at: url) == false,
                "plaintext content must never reach disk on an encrypting estate, even when the write carries a keyID")
    }

    /// The same pairing through `update`. `updateRows` already ran the seam, so
    /// this pins that the guard change did not open a hole beneath it.
    @Test func updateWithPlaintextAndNonEmptyKeyIDNeverWritesPlaintext() async throws {
        let encryption = EstateEncryptionConfig(.rowEncryption)
        let url = freshDBURL()
        let storage = try makeStorage(encryption, at: url)
        try await storage.open(schema: makeSchema())

        _ = try await storage.rowStore.insert(
            table: "drawers",
            values: ["id": .text("d1"), "content": .text("original")]
        )
        let marker = "MXE-PW-UPDATE-PLAINTEXT-MARKER"
        let updated = try await storage.rowStore.update(
            table: "drawers",
            values: ["content": .text(marker), "keyID": .text(UUID().uuidString)],
            where: .eq(Column(table: "drawers", name: "id"), .text("d1"))
        )
        #expect(updated == 1)
        await storage.close()

        #expect(try rawFileContains(marker, at: url) == false,
                "plaintext content must never reach disk via update, even when the write carries a keyID")
    }

    /// The guard itself, called directly, now rejects plaintext regardless of
    /// keyID. This is the unit-level statement of the same contract: the store
    /// tests above prove the seam seals, this proves the net beneath it no
    /// longer has the keyID-shaped hole.
    @Test func guardRejectsPlaintextEvenWithANonEmptyKeyID() throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        let withForeignKeyID: [String: TypedValue] = [
            "id": .text("d1"),
            "content": .text("plaintext that a keyID must not excuse"),
            "keyID": .text("a-non-empty-key-identifier")
        ]
        #expect(throws: StorageError.self) {
            try assertContentKeyIDInvariant(withForeignKeyID, table: "drawers", config: config)
        }
        // Empty keyID was always rejected; it still is.
        var withEmptyKeyID = withForeignKeyID
        withEmptyKeyID["keyID"] = .text("")
        #expect(throws: StorageError.self) {
            try assertContentKeyIDInvariant(withEmptyKeyID, table: "drawers", config: config)
        }
        // Absent keyID — the original defect's only covered case.
        var withNoKeyID = withForeignKeyID
        withNoKeyID["keyID"] = nil
        #expect(throws: StorageError.self) {
            try assertContentKeyIDInvariant(withNoKeyID, table: "drawers", config: config)
        }
    }

    /// The two exemptions the narrowed guard must preserve: the erasure scrub
    /// writes empty text to wipe a blob (#76), and already-sealed blob content
    /// passes untouched. Neither is a violation.
    @Test func guardStillExemptsErasureScrubAndPassesBlobs() throws {
        let config = EstateEncryptionConfig(.rowEncryption)
        // Erasure scrub: empty text, no keyID.
        try assertContentKeyIDInvariant(
            ["id": .text("d1"), "content": .text("")], table: "drawers", config: config)
        // Sealed content: a blob is what a correct encrypting write produces.
        try assertContentKeyIDInvariant(
            ["id": .text("d1"), "content": .blob(Data([0x01, 0x02])), "keyID": .text("k1")],
            table: "drawers", config: config)
        // Null content is not a protected-text row.
        try assertContentKeyIDInvariant(
            ["id": .text("d1"), "content": .null], table: "drawers", config: config)
    }
}
