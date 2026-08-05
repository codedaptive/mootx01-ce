import Testing
import Foundation
import LocusKit
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import VaultKit

// MXE-MI: palace re-import against a backfilled estate files zero
// duplicates — the regression the kg_facts identity backfill exists to
// prevent, exercised with the REAL resolver
// (`DrawerMapping.lineageID(forStableSourceKey:)`) that `mootx01
// upgrade` injects.
//
// The estate is put into the PRE-MXE-KH shape by hand: imported facts'
// palace keys moved back into `sourceDrawerID` with the identity
// columns cleared — exactly what a live estate written by the pre-KH
// importer looks like after the v13 schema migration adds the (empty)
// columns.
//
// NOTE on the mission's expected pre-migration failure: re-import does
// NOT duplicate facts even against the unmigrated shape, because
// MXE-KH's dedup anchor deliberately falls back to `sourceDrawerID`
// when `foreignSourceKey` is empty — that fallback is load-bearing and
// this suite asserts it explicitly (`reimportAgainstUnmigratedShape…`).
// What the backfill protects is the day that fallback is retired: after
// migration the anchor reads the same value from the CORRECT column, so
// dedup no longer depends on the legacy fallback. The migrated-invariant
// assertions below (column placement + anchor stability + zero
// duplicates) are therefore the regression proof.
@Suite("MXE-MI: palace re-import after kg_facts identity backfill")
struct PalaceReimportAfterBackfillTests {

    static var fixturePalaceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mempalace")
    }

    /// Like PalaceBridgeTests.openEstate, but keeps the storage handle —
    /// the reshape and the backfill both need row-level access.
    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle, InMemoryStorage) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "backfill-reimport-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle, storage)
    }

    /// Rewrite every imported fact that carries a palace key into the
    /// pre-KH shape: key in `sourceDrawerID`, identity columns empty.
    /// Returns the reshaped facts (their post-import identities).
    private func reshapeToPreKH(
        kit: GeniusLocusKit, handle: EstateHandle, storage: InMemoryStorage
    ) async throws -> [KGFact] {
        let keyed = try await kit.recallKGFacts(handle)
            .filter { !$0.foreignSourceKey.isEmpty }
        for f in keyed {
            _ = try await storage.rowStore.update(
                table: "kg_facts",
                values: [
                    "sourceDrawerID": .text(f.foreignSourceKey),
                    "foreignSourceKey": .text(""),
                    "foreignRecordID": .text(""),
                ],
                where: .eq(Column(table: "kg_facts", name: "id"), .text(f.id)))
        }
        return keyed
    }

    @Test("re-import against the UNMIGRATED pre-KH shape already files zero duplicates (the KH fallback anchor is load-bearing)")
    func reimportAgainstUnmigratedShapeFilesZeroDuplicates() async throws {
        let (kit, handle, storage) = try await openEstate()
        let bridge = PalaceBridge(kit: kit)
        let now = Date()

        _ = try await bridge.importPalace(at: Self.fixturePalaceURL, into: handle, now: now)
        let keyed = try await reshapeToPreKH(kit: kit, handle: handle, storage: storage)
        #expect(keyed.count >= 3,
            "fixture must produce keyed facts (t_fleet main + temporal siblings)")
        let countBefore = try await kit.recallKGFacts(handle).count

        let second = try await bridge.importPalace(at: Self.fixturePalaceURL, into: handle, now: now)
        let countAfter = try await kit.recallKGFacts(handle).count

        #expect(countAfter == countBefore,
            "the sourceDrawerID fallback in the dedup anchor must keep the unmigrated shape duplicate-free")
        #expect(second.itemsSkipped > 0)
    }

    @Test("palace re-import against the MIGRATED estate files zero duplicates")
    func reimportAfterBackfillFilesZeroDuplicates() async throws {
        let (kit, handle, storage) = try await openEstate()
        let bridge = PalaceBridge(kit: kit)
        let now = Date()

        _ = try await bridge.importPalace(at: Self.fixturePalaceURL, into: handle, now: now)
        let keyed = try await reshapeToPreKH(kit: kit, handle: handle, storage: storage)
        let countBefore = try await kit.recallKGFacts(handle).count

        // The backfill, with the REAL resolver `mootx01 upgrade` injects.
        let report = try await KGFactIdentityBackfill.run(
            storage: storage,
            resolveForeignKey: DrawerMapping.lineageID(forStableSourceKey:))
        #expect(report.foreignPalaceKeys == keyed.count,
            "every reshaped palace key must classify as class B via the real resolver")
        #expect(report.unclassified == 0)

        // Migrated invariants: the key is back in its column, the anchor
        // is unchanged, and `sourceDrawerID` no longer carries it.
        let migrated = try await kit.recallKGFacts(handle)
            .filter { keyed.map(\.id).contains($0.id) }
        for f in migrated {
            #expect(f.foreignSourceKey == "drawer_alpha_0001")
            #expect(f.sourceDrawerID.isEmpty)
            #expect(PalaceBridge.dedupAnchor(for: f) == "drawer_alpha_0001",
                "the CAND-049 anchor must read the same value from the correct column")
        }

        // The regression this mission exists for: re-import files nothing.
        let second = try await bridge.importPalace(at: Self.fixturePalaceURL, into: handle, now: now)
        let countAfter = try await kit.recallKGFacts(handle).count
        #expect(countAfter == countBefore,
            "re-import against the migrated estate must file zero duplicate facts")
        #expect(second.itemsSkipped > 0)
    }
}
