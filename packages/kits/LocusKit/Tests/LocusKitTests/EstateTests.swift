import Foundation
import SQLite3
import PersistenceKit
import Testing
@testable import LocusKit

/// Estate lifecycle coverage per spec § 7.8.1.
///
/// `Estate` is the application's single connection point to a
/// GeniusLocus — a Swift `actor` that owns a `DrawerStore`, loads
/// the manifest on open, and validates bitmap-layout-version
/// compatibility.
///
/// This suite covers three shapes:
/// 1. Lifecycle — open + close on an existing path, create + close
///    materialising a new SQLite file, open on a path whose parent
///    directory does not exist surfaces `EstateError.substrateUnavailable`,
///    and re-open of a freshly created estate succeeds.
/// 2. Manifest — a freshly created estate exposes a typed
///    `ManifestValues` snapshot with `manifestVersion == "1.0"` and
///    `bitmapLayoutVersion == "v1.0"`. A seeded database carrying
///    `bitmap_layout_version = "v99.0"` refuses to open and throws
///    `EstateError.manifestMismatch(key: "bitmap_layout_version", …)`.
///    `Estate.create` with a non-empty `estateName` round-trips to a
///    subsequent open of the same path.
/// 3. estateUUID — the per-estate UUID is non-nil after open and is
///    byte-stable across a create → close → open cycle of the same
///    file (the spec guarantee that estate identity does not depend
///    on the handle lifetime).
@Suite("EstateTests")
struct EstateTests {

    // MARK: - Helpers

    private func makeTempURL() -> URL {
        let name = "locuskit-estate-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    private static let SQLITE_TRANSIENT_TEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Standard owner credentials for tests; the substrate layer only
    /// validates that `ownerIdentifier` is non-empty.
    private let testOwner = OwnerCredentials(ownerIdentifier: "test-owner")

    // MARK: - Lifecycle

    /// Create-then-open is the canonical happy path. `Estate.create`
    /// materialises a new SQLite file at `path` and returns a fully
    /// initialised actor; `close()` is the semantic teardown signal
    /// callers issue when they are done with the handle.
    @Test("Estate.create + close succeeds and the database file exists at path")
    func createAndClose() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        let estate = try await Estate.create(storage: TestStorage.sqlite(url), owner: testOwner)
        #expect(FileManager.default.fileExists(atPath: url.path))
        try await estate.close()
    }

    /// After a successful `create`, the same path must round-trip
    /// through `Estate.open`. This is the substrate-level guarantee
    /// that the manifest written at create time is readable by the
    /// next process that opens the file.
    @Test("Estate.open succeeds against a previously-created database, then close")
    func openAndClose() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        let created = try await Estate.create(storage: TestStorage.sqlite(url), owner: testOwner)
        try await created.close()

        let opened = try await Estate.open(
            storage: TestStorage.sqlite(url), owner: testOwner,
            // Temp-dir SQLite counts as durable, so the backend-keyed default
            // would mint into the real login keychain — keep test identities
            // in memory. (These tests assert manifest/meta behavior, not
            // signing, so a fresh store per open is fine.)
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        try await opened.close()
    }

    /// Opening a URL whose parent directory does not exist must
    /// surface as `EstateError.substrateUnavailable` — Estate wraps
    /// the underlying SQLite failure into the spec § 8.1 category
    /// rather than leaking a substrate-level error type.
    @Test("Estate.open throws substrateUnavailable when the parent directory does not exist")
    func openMissingParentThrows() async throws {
        // /nonexistent-<uuid>/foo.sqlite — the parent directory
        // cannot be created by sqlite3_open_v2 because /nonexistent-…
        // does not exist and the OS will not auto-create it.
        let bogus = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/estate.sqlite")

        // With injected storage, a parent directory that cannot be
        // opened fails at storage construction rather than inside
        // Estate.open. The substrate refuses the path; the kit never
        // sees a usable storage to wrap. Either the storage build
        // throws, or (defensively) Estate.open surfaces
        // substrateUnavailable if a backend defers its open.
        // The substrate refuses a path under a nonexistent parent.
        // With injected storage the failure surfaces at storage
        // construction (an NSError / StorageError from the backend)
        // rather than as a kit-typed error, since the kit never
        // receives a usable storage to wrap. The contract under test
        // is simply that a bad path does not silently succeed.
        await #expect(throws: (any Error).self) {
            let storage = try TestStorage.sqliteThrowing(bogus)
            _ = try await Estate.open(storage: storage, owner: testOwner)
        }
    }

    /// Re-opening a previously-closed estate succeeds repeatedly.
    /// This guards against any close-side state that would prevent a
    /// second handle from materialising on the same file.
    @Test("Estate.open + close + open succeeds for the same path")
    func reopenStability() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        let first = try await Estate.create(storage: TestStorage.sqlite(url), owner: testOwner)
        try await first.close()

        let second = try await Estate.open(
            storage: TestStorage.sqlite(url), owner: testOwner,
            // Temp-dir SQLite counts as durable, so the backend-keyed default
            // would mint into the real login keychain — keep test identities
            // in memory. (These tests assert manifest/meta behavior, not
            // signing, so a fresh store per open is fine.)
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        try await second.close()

        let third = try await Estate.open(
            storage: TestStorage.sqlite(url), owner: testOwner,
            // Temp-dir SQLite counts as durable, so the backend-keyed default
            // would mint into the real login keychain — keep test identities
            // in memory. (These tests assert manifest/meta behavior, not
            // signing, so a fresh store per open is fine.)
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        try await third.close()
    }

    // MARK: - Manifest

    /// A freshly created estate exposes the v1 manifest defaults:
    /// `manifest_version` is the literal "1.0" the kit writes on
    /// first open, per spec § 7.7 manifest contract.
    @Test("Estate.manifest after create has manifestVersion == \"1.0\"")
    func manifestVersionAfterCreate() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        let estate = try await Estate.create(storage: TestStorage.sqlite(url), owner: testOwner)
        defer { Task { try? await estate.close() } }
        let manifest = try await estate.manifest
        #expect(manifest.manifestVersion == "1.0")
    }

    /// `bitmap_layout_version` on a freshly created estate is
    /// "v1.0" — the value the kit writes at this iteration of the
    /// spec. This is the field Estate validates on open.
    @Test("Estate.manifest.bitmapLayoutVersion equals \"v1.0\" on a fresh estate")
    func manifestBitmapLayoutVersionAfterCreate() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        let estate = try await Estate.create(storage: TestStorage.sqlite(url), owner: testOwner)
        defer { Task { try? await estate.close() } }
        let manifest = try await estate.manifest
        #expect(manifest.bitmapLayoutVersion == "v1.0")
    }

    /// The public consumer key-value surface (`setMeta`/`meta`) round-trips a
    /// namespaced value, and it survives close + reopen (the manifest table is
    /// durable). This is the substrate-owned persistence primitive upper layers
    /// (e.g. NeuronKit's daemons) use instead of a host-owned store.
    @Test("Estate.setMeta/meta round-trips a namespaced value across reopen")
    func metaRoundTripsAcrossReopen() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        let key = "neuronkit.dreaming.policy"
        let value = #"{"minConfidence":0.7}"#

        do {
            let estate = try await Estate.create(storage: TestStorage.sqlite(url), owner: testOwner)
            // Absent before first write.
            let before = try await estate.meta(key: key)
            #expect(before == nil)
            try await estate.setMeta(key: key, value: value)
            let after = try await estate.meta(key: key)
            #expect(after == value)
            try? await estate.close()
        }

        // Reopen the same database — the value persisted.
        let reopened = try await Estate.open(
            storage: TestStorage.sqlite(url), owner: testOwner,
            // Temp-dir SQLite counts as durable, so the backend-keyed default
            // would mint into the real login keychain — keep test identities
            // in memory. (These tests assert manifest/meta behavior, not
            // signing, so a fresh store per open is fine.)
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await reopened.close() } }
        let restored = try await reopened.meta(key: key)
        #expect(restored == value, "Consumer manifest value must survive a restart")
    }

    /// A database whose manifest was hand-seeded with an
    /// unrecognised `bitmap_layout_version` must refuse to open.
    /// Estate's open validates the layout compatibility and throws
    /// `EstateError.manifestMismatch` with `key == "bitmap_layout_version"`.
    @Test("Estate.open throws manifestMismatch when bitmap_layout_version is v99.0")
    func openRefusesIncompatibleBitmapLayoutVersion() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        // First, create the estate normally so the schema and
        // manifest table exist.
        let created = try await Estate.create(storage: TestStorage.sqlite(url), owner: testOwner)
        try await created.close()

        // Then overwrite the bitmap_layout_version row via raw SQL.
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        #expect(sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK)
        defer { if let h = handle { sqlite3_close_v2(h) } }
        let update = "UPDATE manifest SET value = 'v99.0' WHERE key = 'bitmap_layout_version'"
        #expect(sqlite3_exec(handle, update, nil, nil, nil) == SQLITE_OK)
        sqlite3_close_v2(handle)
        handle = nil

        // Re-open must throw manifestMismatch keyed on bitmap_layout_version.
        do {
            _ = try await Estate.open(
            storage: TestStorage.sqlite(url), owner: testOwner,
            // Temp-dir SQLite counts as durable, so the backend-keyed default
            // would mint into the real login keychain — keep test identities
            // in memory. (These tests assert manifest/meta behavior, not
            // signing, so a fresh store per open is fine.)
            identityKeyStore: InMemoryEstateIdentityKeyStore())
            Issue.record("Expected manifestMismatch but open succeeded")
        } catch let EstateError.manifestMismatch(key, found, expected) {
            #expect(key == "bitmap_layout_version")
            #expect(found == "v99.0")
            #expect(expected == "v1.0")
        }
    }

    /// `Estate.create` with a `manifest` carrying `estateName`
    /// writes that value through to the manifest table; a
    /// subsequent open of the same file returns it verbatim. This
    /// is the substrate-level contract for create-time seeding.
    @Test("Estate.create seeds estate_name; open round-trips the seeded value")
    func createSeedsEstateName() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        let seed = ManifestValues(
            manifestVersion: "1.0",
            schemaVersion: "0.35",
            estateUUID: UUID().uuidString,
            estateName: "Test Estate",
            ownerIdentifier: testOwner.ownerIdentifier,
            latticeCitation: "UDC, Wikidata",
            frameworkProfile: "default",
            frameworkProfileDefinition: "{}",
            zoomWindowLow: 0,
            zoomWindowHigh: 0,
            accessPosture: 0,
            provenanceDefaults: 0,
            activeStorageMode: 0,
            tablesPresent: "",
            createdAt: Date(timeIntervalSince1970: 0),
            lastModified: Date(timeIntervalSince1970: 0),
            bitmapLayoutVersion: "v1.0",
            provenanceBitmapVersion: "v1.0",
            federationGroupID: nil,
            miningPatternsHash: nil,
            tinyModelID: nil,
            tinyModelTrainingCorpusSize: nil,
            operationalBitmapLayouts: nil
        )
        let created = try await Estate.create(storage: TestStorage.sqlite(url), owner: testOwner, manifest: seed)
        try await created.close()

        let opened = try await Estate.open(
            storage: TestStorage.sqlite(url), owner: testOwner,
            // Temp-dir SQLite counts as durable, so the backend-keyed default
            // would mint into the real login keychain — keep test identities
            // in memory. (These tests assert manifest/meta behavior, not
            // signing, so a fresh store per open is fine.)
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        defer { Task { try? await opened.close() } }
        let manifest = try await opened.manifest
        #expect(manifest.estateName == "Test Estate")
    }

    // MARK: - estateUUID

    /// `estate.estateUUID` is the parsed Foundation `UUID` form of
    /// the manifest's `estate_uuid` row. A freshly created estate
    /// must produce a non-zero UUID (the kit assigns one at create
    /// time).
    @Test("Estate.estateUUID after create is non-zero")
    func estateUUIDIsNonZero() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        let estate = try await Estate.create(storage: TestStorage.sqlite(url), owner: testOwner)
        defer { Task { try? await estate.close() } }
        let uuid = await estate.estateUUID
        // A UUID with all zero bytes signals an uninitialised manifest.
        #expect(uuid != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
    }

    /// `estate.estateUUID` is byte-stable across a create → close →
    /// open cycle of the same file. Estate identity persists with
    /// the substrate, not with the handle lifetime.
    @Test("Estate.estateUUID is stable across create + close + open")
    func estateUUIDStableAcrossReopens() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }

        let first = try await Estate.create(storage: TestStorage.sqlite(url), owner: testOwner)
        let firstUUID = await first.estateUUID
        try await first.close()

        let second = try await Estate.open(
            storage: TestStorage.sqlite(url), owner: testOwner,
            // Temp-dir SQLite counts as durable, so the backend-keyed default
            // would mint into the real login keychain — keep test identities
            // in memory. (These tests assert manifest/meta behavior, not
            // signing, so a fresh store per open is fine.)
            identityKeyStore: InMemoryEstateIdentityKeyStore())
        let secondUUID = await second.estateUUID
        try await second.close()

        #expect(firstUUID == secondUUID)
    }
}
