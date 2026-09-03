#if GLK_MIGRATION_V1_2_TO_V1_3

// DistilledSourceDigestColumnMigrationTests.swift
//
// Verifies that GLKMigrationCatalog.prepare runs the 1.2→1.3 capsule, which
// carries the `distilled_source_digest` column on the drawers table to
// populated estates written under LocusKit schema v17 and stamps the estate
// format v1_3; the chain then continues through the 1.3→1.4 capsule, so
// every prepared estate ends at the current format, v1_4.
//
// Tests:
//   1. v1_2-stamped estate whose drawers table lacks the digest column: after
//      prepare the LocusKit kit version is 18, the estate is stamped v1_4, and
//      a representation write carrying a digest round-trips through the
//      store API.
//   2. Idempotence: a second prepare on the already-migrated estate is a no-op
//      that leaves the stamp at v1_4.
//   3. Fresh estate (nil stamp): prepare stamps v1_4 without running any capsule.
//   4. v1_1-stamped estate: the 1.1→1.2, 1.2→1.3 and 1.3→1.4 capsules run and end at v1_4.
//   5. v1_0-stamped estate: the full chain (v1_0→v1_1→v1_2→v1_3→v1_4) ends at v1_4.
//      Uses a simple v1_0 estate (no legacy chunks) to avoid duplicating the
//      SharedContentMigration fixture.

import Testing
import Foundation
import ContextDistillLib
import LocusKit
import PersistenceKit
import PersistenceKitInMemory
import GeniusLocusKitMigrations

@testable import GeniusLocusKit
@testable import GLKMigrationV1_2ToV1_3

// MARK: - Helpers

private let testOwner = OwnerCredentials(ownerIdentifier: "test-owner-mig13")
private let testNow = Date(timeIntervalSince1970: 1_756_000_000)
private let digestColumn = "distilled_source_digest"

/// The live LocusKit declaration with the drawers table rolled back to its
/// v17 layout: the `distilled_source_digest` column removed, version 17, and
/// no migrations list. Applying this before the live v18 schema simulates a
/// populated estate written before the column existed.
private func version17LocusKitSchema() -> SchemaDeclaration {
    let live = LocusKitSchema.schema
    let tables = live.tables.map { table -> TableDeclaration in
        guard table.name == "drawers" else { return table }
        return TableDeclaration(
            name: table.name,
            columns: table.columns.filter { $0.name != digestColumn },
            primaryKey: table.primaryKey,
            uniqueConstraints: table.uniqueConstraints,
            generatedColumns: table.generatedColumns,
            appendOnly: table.appendOnly,
            hashable: table.hashable
        )
    }
    return SchemaDeclaration(
        kitID: live.kitID,
        version: 17,
        tables: tables,
        indices: live.indices,
        migrations: []
    )
}

/// Create an in-memory estate at the v17 LocusKit layout (no digest column),
/// stamped at `stamp`, then open it in a fresh GeniusLocusKit instance.
/// Returns the storage too so a test can read the recorded kit version.
private func makeVersion17Estate(
    stampedAt stamp: EstateFormatVersion
) async throws -> (kit: GeniusLocusKit, handle: EstateHandle, storage: InMemoryStorage) {
    let storage = InMemoryStorage(
        configuration: EstateConfiguration(estateID: UUID(), backend: .inMemory))

    // Lay down the v17 LocusKit tables first so the kit version record reads
    // 17 and the drawers table has no digest column.
    try await storage.migrate(to: version17LocusKitSchema())
    #expect(try await storage.currentSchemaVersion(for: LocusKitSchema.kitID) == 17)
    let drawersColumns = version17LocusKitSchema().tables
        .first { $0.name == "drawers" }?.columns.map(\.name) ?? []
    #expect(!drawersColumns.contains(digestColumn))

    // Estate.create installs the manifest rows the open path reads. Opening a
    // DrawerStore applies the live LocusKit declaration, which replays the
    // v17 → v18 ladder entry on this storage — the same replay every host
    // open performs; the capsule replays it again (idempotent) and turns the
    // column's presence into the v1_3 stamp the catalog keys on.
    _ = try await LocusKit.Estate.create(storage: storage, owner: testOwner)

    // Stamp the given estate format version.
    try await EstateFormatStore(storage: storage).stamp(stamp, now: testNow)

    let kit = GeniusLocusKit()
    let handle = try await kit.open(
        storage: storage,
        owner: testOwner,
        identityKeyStore: InMemoryEstateIdentityKeyStore()
    )
    return (kit, handle, storage)
}

/// File one drawer and write a representation carrying a digest through the
/// estate API, then read it back. Throws "no such column" if the migration
/// failed to add the digest column.
private func writeAndReadDigest(
    kit: GeniusLocusKit, handle: EstateHandle
) async throws -> String? {
    let content = "Digest column round-trip after the 1.2 to 1.3 capsule."
    let drawer = try await kit.capture(handle, CaptureFrame(
        content: content,
        channel: .typed,
        room: "mig13-room",
        latticeAnchor: LatticeAnchor(udcCode: "000"),
        addedBy: "mig13-test",
        embeddingModelID: "test-model-v1",
        eventTime: testNow
    ))
    let estate = try await kit.estate(for: handle)
    let digest = sourceDigest(content)
    let written = try await estate.setDistilledRepresentation(
        drawerId: drawer.id,
        distilled: "Digest column round-trip.",
        pipelineVersion: GeniusLocusKit.distillationConverterID,
        sourceDigest: digest,
        tokenCount: 4,
        at: testNow)
    #expect(written == 1)
    return try await estate.getDrawers(ids: [drawer.id]).first?.distilledSourceDigest
}

// MARK: - Test suite

@Suite("DistilledSourceDigestColumnMigration", .serialized)
struct DistilledSourceDigestColumnMigrationTests {

    // MARK: §1 Core fix: v1_2 estate gains distilled_source_digest column

    /// An estate stamped v1_2 with the v17 drawers layout: after
    /// GLKMigrationCatalog.prepare the LocusKit kit version is 18, the stamp
    /// is v1_4, and a representation write round-trips its digest.
    @Test
    func v1_2EstateGainsDigestColumn() async throws {
        let (kit, handle, storage) = try await makeVersion17Estate(stampedAt: .v1_2)

        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(prep.format == .v1_4)
        #expect(prep.migrated == false)
        #expect(try await storage.currentSchemaVersion(for: LocusKitSchema.kitID) == LocusKitSchema.version)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_4)

        let content = "Digest column round-trip after the 1.2 to 1.3 capsule."
        #expect(try await writeAndReadDigest(kit: kit, handle: handle) == sourceDigest(content))
    }

    // MARK: §2 Idempotence: second prepare is a no-op

    @Test
    func prepareTwiceIsNoOp() async throws {
        let (kit, handle, _) = try await makeVersion17Estate(stampedAt: .v1_2)

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

    // MARK: §4 v1_1 estate runs 1.1→1.2, 1.2→1.3, then 1.3→1.4

    #if GLK_MIGRATION_V1_1_TO_V1_2
    @Test
    func v1_1EstateRunsThreeCapsulesToCurrent() async throws {
        let (kit, handle, storage) = try await makeVersion17Estate(stampedAt: .v1_1)

        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        #expect(prep.format == .v1_4)
        #expect(prep.migrated == false)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_4)
        let content = "Digest column round-trip after the 1.2 to 1.3 capsule."
        #expect(try await writeAndReadDigest(kit: kit, handle: handle) == sourceDigest(content))
    }
    #endif

    // MARK: §5 Full chain from v1_0 ends at v1_4

    #if GLK_MIGRATION_V1_0_TO_V1_1
    /// A v1_0-stamped estate (no legacy chunks) runs the full catalog chain
    /// (v1_0→v1_1→v1_2→v1_3→v1_4) and ends at v1_4.
    @Test
    func v1_0EstateRunsFullChainToCurrent() async throws {
        let (kit, handle, storage) = try await makeVersion17Estate(stampedAt: .v1_0)

        let prep = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle, now: testNow)
        // SharedContentMigration stamps v1_1, the 1.1→1.2 capsule stamps v1_2,
        // the 1.2→1.3 capsule stamps v1_3, the 1.3→1.4 capsule stamps v1_4.
        // migrated=false because no legacy chunk data was moved.
        #expect(prep.format == .v1_4)
        #expect(prep.migrated == false)
        #expect(try await EstateFormatStore(storage: storage).readIfPresent() == .v1_4)
        let content = "Digest column round-trip after the 1.2 to 1.3 capsule."
        #expect(try await writeAndReadDigest(kit: kit, handle: handle) == sourceDigest(content))
    }
    #endif
}

#endif // GLK_MIGRATION_V1_2_TO_V1_3
