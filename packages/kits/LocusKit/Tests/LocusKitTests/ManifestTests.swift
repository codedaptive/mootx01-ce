import Foundation
import SQLite3
import Testing
@testable import LocusKit

@Suite("ManifestTests")
struct ManifestTests {

    // MARK: - Test fixture helpers

    private func makeTempURL() -> URL {
        let name = "locuskit-manifest-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    /// SQLITE_TRANSIENT analogue used by the migration test to bind
    /// raw bytes into a hand-rolled SQLite handle. DrawerStore has
    /// its own private constant; tests reach SQLite directly to seed
    /// the legacy schema before opening a `DrawerStore`.
    private static let SQLITE_TRANSIENT_TEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func tableExists(at url: URL, name: String) throws -> Bool {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened = handle else {
            if let h = handle { sqlite3_close_v2(h) }
            return false
        }
        defer { sqlite3_close_v2(opened) }
        var stmt: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
        guard sqlite3_prepare_v2(opened, sql, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, Self.SQLITE_TRANSIENT_TEST)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - 3a. Schema test

    @Test("manifest table exists, meta table absent on fresh open")
    func schemaShape() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        do {
            _ = try await DrawerStore(storage: TestStorage.sqlite(url))
        }
        #expect(try tableExists(at: url, name: "manifest") == true)
        #expect(try tableExists(at: url, name: "meta") == false)
    }

    // MARK: - 3b. v1 defaults test

    @Test("18 v1 required keys populated with expected defaults")
    func v1Defaults() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        #expect(try await store.getMeta(key: "manifest_version") == "1.0")
        #expect(try await store.getMeta(key: "schema_version") == "1.0")
        #expect(try await store.getMeta(key: "estate_name") == "")
        #expect(try await store.getMeta(key: "owner_identifier") == "")
        #expect(try await store.getMeta(key: "lattice_citation") == "UDC:2024+Wikidata:2024-Q3")
        #expect(try await store.getMeta(key: "framework_profile") == "unspecified_v0")
        #expect(try await store.getMeta(key: "framework_profile_definition") == "{}")
        #expect(try await store.getMeta(key: "zoom_window_low") == "0")
        #expect(try await store.getMeta(key: "zoom_window_high") == "99")
        #expect(try await store.getMeta(key: "access_posture") == "0")
        #expect(try await store.getMeta(key: "provenance_defaults") == "0")
        #expect(try await store.getMeta(key: "active_storage_mode") == "8")
        #expect(try await store.getMeta(key: "tables_present") == "")
        #expect(try await store.getMeta(key: "bitmap_layout_version") == "v1.0")
        #expect(try await store.getMeta(key: "provenance_bitmap_version") == "v1.0")

        // estate_uuid must be a parseable UUID string.
        let uuidValue = try await store.getMeta(key: "estate_uuid")
        #expect(uuidValue != nil)
        if let uuidValue {
            #expect(UUID(uuidString: uuidValue) != nil)
        }

        // created_at and last_modified must be equal at first open
        // and parse as ISO-8601 (with fractional seconds, matching
        // DrawerStore.iso formatter options).
        let createdAt = try await store.getMeta(key: "created_at")
        let lastModified = try await store.getMeta(key: "last_modified")
        #expect(createdAt != nil)
        #expect(lastModified != nil)
        #expect(createdAt == lastModified)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let createdAt {
            #expect(iso.date(from: createdAt) != nil)
        }

        // federation_group_id is intentionally absent — it is an
        // optional key set by the application later when an estate
        // joins a federation group.
        #expect(try await store.getMeta(key: "federation_group_id") == nil)
    }

    // MARK: - 3c. Idempotency test

    @Test("estate_uuid is stable across re-opens of the same database")
    func idempotency() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let firstUUID: String?
        do {
            let first = try await DrawerStore(storage: TestStorage.sqlite(url))
            firstUUID = try await first.getMeta(key: "estate_uuid")
        }
        #expect(firstUUID != nil)

        let second = try await DrawerStore(storage: TestStorage.sqlite(url))
        let secondUUID = try await second.getMeta(key: "estate_uuid")
        #expect(secondUUID == firstUUID)
    }

    // MARK: - 3e. ManifestKey enum structure

    @Test("ManifestKey required and optional sets are well-formed")
    func manifestKeyShape() throws {
        let requiredRaws = Set(ManifestKey.required.map(\.rawValue))
        let optionalRaws = Set(ManifestKey.optional.map(\.rawValue))

        #expect(ManifestKey.required.count == 18)
        #expect(ManifestKey.optional.count == 7)
        #expect(requiredRaws.count == 18)
        #expect(optionalRaws.count == 7)
        #expect(requiredRaws.isDisjoint(with: optionalRaws))
        #expect(ManifestKey.allCases.count == 25)
    }

    // MARK: - 3f. ManifestValues round-trip

    @Test("readManifest returns typed snapshot with v1 defaults on fresh open")
    func manifestValuesRoundTrip() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        let values = try await store.readManifest()

        #expect(values.manifestVersion == "1.0")
        #expect(values.schemaVersion == "1.0")
        #expect(UUID(uuidString: values.estateUUID) != nil)
        #expect(values.estateName == "")
        #expect(values.ownerIdentifier == "")
        #expect(values.latticeCitation == "UDC:2024+Wikidata:2024-Q3")
        #expect(values.frameworkProfile == "unspecified_v0")
        #expect(values.frameworkProfileDefinition == "{}")
        #expect(values.zoomWindowLow == 0)
        #expect(values.zoomWindowHigh == 99)
        #expect(values.accessPosture == 0)
        #expect(values.provenanceDefaults == 0)
        #expect(values.activeStorageMode == 8)
        #expect(values.tablesPresent == "")
        #expect(values.bitmapLayoutVersion == "v1.0")
        #expect(values.provenanceBitmapVersion == "v1.0")

        // Optional keys are absent by default — nil on a fresh open.
        #expect(values.federationGroupID == nil)
        #expect(values.miningPatternsHash == nil)
        #expect(values.tinyModelID == nil)
        #expect(values.tinyModelTrainingCorpusSize == nil)
        #expect(values.operationalBitmapLayouts == nil)
    }

    @Test("readManifest estateUUID is stable across re-opens")
    func manifestValuesUUIDStability() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        let firstUUID: String
        do {
            let first = try await DrawerStore(storage: TestStorage.sqlite(url))
            firstUUID = try await first.readManifest().estateUUID
        }
        let second = try await DrawerStore(storage: TestStorage.sqlite(url))
        #expect(try await second.readManifest().estateUUID == firstUUID)
    }
}
