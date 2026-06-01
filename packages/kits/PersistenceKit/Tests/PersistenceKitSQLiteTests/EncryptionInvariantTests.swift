// EncryptionInvariantTests.swift
//
// Mission FUP-D (E-1) — the structural content/keyID write-boundary guard.
//
// AUDIT-01 Zone E flagged that the content/keyID invariant ("a content-bearing
// row on an encrypting estate must carry a keyID") was convention-only, living
// in a comment on upsertRow. A raw write path that bypasses the encryption seam
// (upsertRow does not run encryptedForWrite) could silently persist plaintext
// content with a null keyID on an encrypting estate — an unreadable/leaky row.
//
// These tests pin the structural guard:
//   - A .text content upsert on a non-plaintext estate with no keyID throws,
//     rather than silently writing the unreadable row.
//   - Mode 1 (plaintext) is unaffected — byte-identical to today.
//   - The correct insert path on an encrypting estate is not disturbed (the
//     encryption seam stamps a keyID, so the guard passes).
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
// docs/engineering/HARNESS_REFERENCE_v1.0_2026-05-28.md. If you
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

    /// E-1 (upsert path): a content upsert on an encrypting estate with no keyID must throw.
    /// upsertRow does not run the encryption seam, so without the structural
    /// guard this write lands as plaintext content + null keyID — exactly the
    /// unreadable-row hazard the mission closes.
    @Test func contentUpsertWithoutKeyIDOnEncryptingEstateThrows() async throws {
        let storage = try makeStorage(EstateEncryptionConfig(.rowEncryption), at: freshDBURL())
        try await storage.open(schema: makeSchema())

        do {
            _ = try await storage.rowStore.upsert(
                table: "drawers",
                values: ["id": .text("d1"), "content": .text("plaintext secret")],
                conflictColumns: ["id"]
            )
            Issue.record("expected the content/keyID invariant guard to throw on an unencrypted content write to an encrypting estate")
        } catch let error as StorageError {
            guard case .constraintViolation = error else {
                Issue.record("expected StorageError.constraintViolation, got \(error)")
                return
            }
        }
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

    /// E-1 (update path): a content update on an encrypting estate must throw for the same
    /// reason as upsert — updateRows does not run the encryption seam, so a
    /// .text content update would persist plaintext with a null keyID.
    @Test func contentUpdateOnEncryptingEstateThrows() async throws {
        let storage = try makeStorage(EstateEncryptionConfig(.rowEncryption), at: freshDBURL())
        try await storage.open(schema: makeSchema())

        do {
            _ = try await storage.rowStore.update(
                table: "drawers",
                values: ["content": .text("plaintext secret")],
                where: .eq(Column(table: "drawers", name: "id"), .text("d1"))
            )
            Issue.record("expected the content/keyID invariant guard to throw on an unencrypted content update to an encrypting estate")
        } catch let error as StorageError {
            guard case .constraintViolation = error else {
                Issue.record("expected StorageError.constraintViolation, got \(error)")
                return
            }
        }
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
}
