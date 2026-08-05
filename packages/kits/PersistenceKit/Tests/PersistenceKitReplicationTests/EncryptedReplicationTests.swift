// EncryptedReplicationTests.swift
//
// Mission MXE-PW — a non-empty keyID is not proof of encryption.
//
// The end-to-end half of the mission's Part 3, and the reason the defect
// mattered: replicating an encrypting estate into an encrypting destination
// used to store memory content in cleartext at rest.
//
// The mechanism, with no attacker involved:
//   1. The source is a RowEncryption estate, so `content` is sealed on disk.
//   2. Snapshot replication reads the source rows through `queryRows`, which
//      runs `decryptedForRead` — handing back PLAINTEXT while RETAINING the
//      source row's keyID.
//   3. It upserts that (plaintext, keyID) pair into the destination.
//   4. The destination's invariant guard saw a non-empty keyID, concluded the
//      text must already be ciphertext, and let the write through.
//
// Nothing above is exotic. It is the ordinary replication path.
//
// The fix runs the encryption seam inside `upsertRow` and narrows the guard to
// test the VALUE'S TYPE. `StorageReplicator` is deliberately untouched — the
// behaviour corrects from beneath it, because the destination store seals with
// its own configured key. Sealing in the replication layer instead would mean
// handing the destination's key to a component that never touches key
// material.
//
// THE ASSERTION IS ON THE RAW FILE BYTES. The read path cannot answer this
// question: `decryptedForRead` passes non-blob values through unchanged, so a
// plaintext-at-rest row reads back as the correct string and hides the failure
// completely.

import Testing
import Foundation
import SubstrateTypes
import PersistenceKit
import PersistenceKitSQLite
@testable import PersistenceKitReplication

// MARK: - Schema

/// A drawers-shaped schema reduced to the columns this test exercises.
/// `keyID` is nullable: NULL for plaintext rows, the estate key identifier
/// for sealed ones.
private let encryptedReplicationSchema = SchemaDeclaration(
    kitID: "EncryptedReplicationTestKit",
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

// MARK: - Factories

/// A SQLite storage at a KNOWN url, so the test can read the file's raw bytes
/// after closing it.
private func makeEncryptingSQLite(tag: String) async throws -> (SQLiteStorage, URL, EstateEncryptionConfig) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mxe-pw-\(tag)-\(UUID().uuidString).sqlite")
    let encryption = EstateEncryptionConfig(.rowEncryption)
    let storage = try SQLiteStorage(configuration: EstateConfiguration(
        estateID: UUID(),
        backend: .sqlite(url: url),
        encryptionConfig: encryption
    ))
    try await storage.open(schema: encryptedReplicationSchema)
    return (storage, url, encryption)
}

/// Search a file's bytes for `marker`. SQLite stores short TEXT values
/// verbatim in the page payload, so an unencrypted string is findable as a
/// literal byte run.
private func rawFileContains(_ marker: String, at url: URL) throws -> Bool {
    let bytes = try Data(contentsOf: url)
    return bytes.range(of: Data(marker.utf8)) != nil
}

// MARK: - Tests

@Suite("Encrypted snapshot replication (MXE-PW)")
struct EncryptedReplicationTests {

    /// Encrypting source → encrypting destination. The row must arrive, must
    /// still read back as plaintext through the seam, and must be CIPHERTEXT
    /// in the destination file.
    ///
    /// Fails against pre-fix code: the destination file contained the marker.
    @Test func replicationIntoEncryptingDestinationStoresCiphertext() async throws {
        let marker = "MXE-PW-SWIFT-REPLICATED-SECRET-MARKER"
        let (source, sourceURL, _) = try await makeEncryptingSQLite(tag: "src")
        let (destination, destURL, destEncryption) = try await makeEncryptingSQLite(tag: "dst")

        _ = try await source.rowStore.insert(
            table: "drawers",
            values: ["id": .text("d1"), "content": .text(marker)]
        )

        _ = try await StorageReplicator.replicate(
            from: source,
            to: destination,
            schema: encryptedReplicationSchema
        )

        // The row replicated and still reads correctly at the destination.
        let rows = try await destination.rowStore.query(
            table: "drawers",
            where: .eq(Column(table: "drawers", name: "id"), .text("d1"))
        )
        #expect(rows.count == 1, "the row must replicate")
        #expect(rows[0]["content"] == .text(marker),
                "destination must still read the content back as plaintext")
        // The destination re-sealed under ITS OWN key, not the source's — that
        // is what sealing inside upsert (rather than in the replication layer)
        // buys: no key crosses a layer boundary.
        #expect(rows[0]["keyID"] == .text(destEncryption.keyIdentifier!),
                "the destination must seal under its own key identifier")

        await source.close()
        await destination.close()

        // The deliverable. Do not trust the read path above.
        #expect(try rawFileContains(marker, at: destURL) == false,
                "replicating into an encrypting destination must store ciphertext at rest")
        #expect(try rawFileContains(marker, at: sourceURL) == false,
                "the encrypting source must also hold ciphertext")
    }
}
