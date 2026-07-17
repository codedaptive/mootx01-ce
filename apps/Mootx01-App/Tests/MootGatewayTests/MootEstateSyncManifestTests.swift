import Testing
import ConvergenceKit
import LocusKit
@testable import MootGateway

// MARK: - MootEstateSyncManifest tests
//
// The manifest is a cross-device contract, so these pin the load-bearing
// values against the real schema — a wrong table name or a drifted schema
// version would make CloudKitSyncEngine throw at enable/pull on a device.

@Suite("MootEstateSyncManifest — verified against the estate schema")
struct MootEstateSyncManifestTests {

    @Test("schema version tracks LocusKitSchema, never a hardcoded guess")
    func schemaVersionTracksSchema() {
        let manifest = MootEstateSyncManifest.standard()
        #expect(manifest.schemaVersion == LocusKitSchema.version)
        #expect(manifest.kitID == "LocusKit")
    }

    @Test("syncs the durable single-PK content tables, with the right policies")
    func tableSet() {
        let manifest = MootEstateSyncManifest.standard(zoneIdentifier: "z")
        let byName = Dictionary(uniqueKeysWithValues: manifest.tables.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["drawers", "tunnels", "kg_facts", "diary"])
        // All keyed by "id" — the single-PK requirement of SyncedTable.
        #expect(manifest.tables.allSatisfy { $0.primaryKeyColumn == "id" })
        #expect(byName["drawers"]?.conflictPolicy == .lastWriterWinsByHLC)
        #expect(byName["kg_facts"]?.conflictPolicy == .appendOnly)
        #expect(byName["diary"]?.conflictPolicy == .appendOnly)
    }

    @Test("derived/projection tables are deliberately excluded")
    func excludesDerived() {
        let names = Set(MootEstateSyncManifest.standard().tables.map(\.name))
        // These rebuild locally (composite keys / projections) — never synced.
        #expect(names.isDisjoint(with: ["node_bundles", "matrix_snapshot", "container_fingerprints"]))
    }
}
