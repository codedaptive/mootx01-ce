#if GLK_MIGRATION_V1_1_TO_V1_2

// IndexCompositionColumnMigrationTests.swift
//
// Verifies that GLKMigrationCatalog.prepare runs the 1.1→1.2 capsule, which
// adds the composition_policy column to corpus_index_state on populated
// estates created before corpus_index_state reached schema version 3. The
// catalog chain continues through the 1.2→1.3 and 1.3→1.4 capsules, so every
// prepared estate ends at the current format, v1_4.
//
// Tests:
//   1. v1_1-stamped estate with pre-v3 (version 2) schema: after prepare the
//      column exists, the estate is stamped current (v1_4), and a row can be
//      written and read back with a non-empty compositionPolicyID.
//   2. Idempotence: a second prepare on the already-migrated estate is a no-op
//      that leaves the stamp at v1_4.
//   3. Fresh estate (nil stamp): prepare stamps v1_4 without running any capsule.
//   4. v1_0-stamped estate: the full chain (v1_0→v1_1→v1_2→v1_3→v1_4) ends at v1_4.
//      Uses a simple v1_0 estate (no legacy chunks) to avoid duplicating the
//      SharedContentMigration fixture.

import Testing
import Foundation
import CorpusKit
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import GeniusLocusKitMigrations

@testable import GeniusLocusKit
@testable import GLKMigrationV1_1ToV1_2

// MARK: - Helpers

private let testOwner = OwnerCredentials(ownerIdentifier: "test-owner-mig12")
private let testNow = Date(timeIntervalSince1970: 1_756_000_000)

/// Build an in-memory corpus_index_state schema at version 2 (pre-v3: no
/// composition_policy column). Applying this before the v3 schema simulates
/// an estate that was created or last migrated before corpus_index_state reached schema version 3.
private func version2IndexStateSchema() -> SchemaDeclaration {
    SchemaDeclaration(
        kitID: "CorpusKitIndexState",
        version: 2,
        tables: [
            TableDeclaration(
                name: "corpus_index_state",
                columns: [
                    .text("content_id", nullable: false),
                    .int("revision", nullable: false),
                    .text("digest", nullable: false),
                    .int("index_version", nullable: false),
                    .text("applied_cursor", nullable: true),
                    .timestamp("updated_at", nullable: false),
                    .bitmap("operational_bitmap", default: 0)
                    // No composition_policy column: this is the pre-v3 layout.
                ],
                primaryKey: ["content_id"]
            ),
            TableDeclaration(
                name: "corpus_bitmap_generation",
                columns: [
                    .int("singleton_id", nullable: false),
                    ColumnDeclaration(
                        name: "basis_generation", type: .int, nullable: false,
                        defaultValue: .int(0))
                ],
                primaryKey: ["singleton_id"]
            )
        ],
        migrations: []
    )
}

/// Create an in-memory estate with the LocusKit schema and the pre-v3
/// corpus_index_state schema (v2). Stamps the estate format at the given
/// `stamp` version, then opens it in a fresh GeniusLocusKit instance.
private func makeVersion2Estate(
    stampedAt stamp: EstateFormatVersion
) async throws -> (kit: GeniusLocusKit, handle: EstateHandle) {
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))

    // Install LocusKit tables so kit.open() succeeds.
    _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)

    // Apply the pre-v3 corpus_index_state schema (v2 — no composition_policy).
    // This simulates an estate that was written before corpus_index_state reached schema version 3 ran its addColumn.
    try await storage.migrate(to: version2IndexStateSchema())

    // Stamp the given estate format version (v1_1 or v1_0 for chain tests).
    try await EstateFormatStore(storage: storage).stamp(stamp, now: testNow)

    let kit = GeniusLocusKit()
    let handle = try await kit.open(
        storage: storage,
        owner: testOwner,
        identityKeyStore: InMemoryEstateIdentityKeyStore()
    )
    return (kit, handle)
}

// MARK: - Test suite

@Suite("IndexCompositionColumnMigration", .serialized)
struct IndexCompositionColumnMigrationTests {

    // MARK: §1 Core fix: v1_1 estate gains composition_policy column

    /// An estate stamped v1_1 with pre-v3 corpus_index_state schema:
    /// after GLKMigrationCatalog.prepare the column exists, the stamp is
    /// current (v1_4), and a store-API write round-trips a compositionPolicyID.
    @Test
    func v1_1EstateGainsCompositionPolicyColumn() async throws {
        let (kit, handle) = try await makeVersion2Estate(stampedAt: .v1_1)

        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(prep.format == .v1_4)
        #expect(prep.migrated == false)

        // Verify the column exists by writing a row using the store API (no raw SQL).
        let storage = try await kit.migrationStorage(for: handle)
        let store = CorpusIndexStateStore(storage: storage)
        let contentID = "drawer:test-content-id"
        let state = CorpusIndexState(
            contentID: contentID,
            revision: 1,
            digest: "abc123",
            indexVersion: 1,
            appliedCursor: nil,
            updatedAt: testNow,
            compositionPolicyID: IndexCompositionPolicy.current.id
        )
        // advance() writes composition_policy — would throw "no such column" if
        // the migration capsule failed to add it.
        try await store.advance(state)

        // Read back and confirm the policy round-tripped.
        let read = try await store.state(for: contentID)
        #expect(read?.compositionPolicyID == IndexCompositionPolicy.current.id)
        #expect(!read!.compositionPolicyID.isEmpty)
    }

    // MARK: §2 Idempotence: second prepare is a no-op

    @Test
    func prepareTwiceIsNoOp() async throws {
        let (kit, handle) = try await makeVersion2Estate(stampedAt: .v1_1)

        let first = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(first.format == .v1_4)

        // Second prepare must return early with "already current", stamp unchanged.
        let second = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(second.format == .v1_4)
        #expect(second.migrated == false)
    }

    // MARK: §3 Fresh estate (nil stamp): stamped v1_4 without running capsule

    @Test
    func freshEstateStampsCurrentWithoutCapsule() async throws {
        let storage = InMemoryStorage(
            configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)
        // No format stamp — simulates a brand-new estate.

        let kit = GeniusLocusKit()
        let handle = try await kit.open(
            storage: storage,
            owner: testOwner,
            identityKeyStore: InMemoryEstateIdentityKeyStore()
        )

        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(prep.format == .current)
        #expect(prep.format == .v1_4)
        #expect(prep.migrated == false)
        #expect(prep.migrationState == nil)
    }

    // MARK: §4 Full chain from v1_0 ends at v1_4

    #if GLK_MIGRATION_V1_0_TO_V1_1
    /// A v1_0-stamped estate (no legacy chunks) runs the full catalog chain
    /// (v1_0→v1_1→v1_2→v1_3→v1_4) and ends at v1_4. Uses the simplest possible
    /// fixture to avoid duplicating the SharedContentMigration legacy-estate
    /// builder.
    @Test
    func v1_0EstateRunsFullChainToCurrent() async throws {
        let (kit, handle) = try await makeVersion2Estate(stampedAt: .v1_0)

        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        // The v1_0→v1_1 capsule (SharedContentMigration) runs for a fresh-at-v1_0
        // estate (no legacy chunks) and stamps v1_1; the v1_1→v1_2 capsule
        // stamps v1_2; the v1_2→v1_3 capsule stamps v1_3; the v1_3→v1_4
        // capsule stamps v1_4. migrated=false because no legacy chunk data
        // was moved.
        #expect(prep.format == .v1_4)
        #expect(prep.migrated == false)

        // Verify corpus_index_state is writable (composition_policy column present).
        let storage = try await kit.migrationStorage(for: handle)
        let store = CorpusIndexStateStore(storage: storage)
        let state = CorpusIndexState(
            contentID: "drawer:chain-test",
            revision: 1,
            digest: "def456",
            indexVersion: 1,
            appliedCursor: nil,
            updatedAt: testNow
        )
        try await store.advance(state)
        let read = try await store.state(for: "drawer:chain-test")
        #expect(read != nil)
    }
    #endif
}

#endif // GLK_MIGRATION_V1_1_TO_V1_2
