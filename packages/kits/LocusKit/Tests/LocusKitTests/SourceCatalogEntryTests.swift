import Foundation
import Testing
@testable import LocusKit

/// Conformance + persistence tests for the `SourceCatalogEntry` noun per arch
/// spec §7.8.2. The durable, queryable record of an external source from which
/// references are learned — the `source` slot of the grounding-driven `learn`
/// verb. The Rust suite mirrors the value-type cases inline in
/// `source_catalog_entry.rs`; the store round-trip mirrors
/// `drawer_store_inmemory.rs` source-catalog coverage (conformance gate I-19).
@Suite("SourceCatalogEntryTests")
struct SourceCatalogEntryTests {

    // MARK: - Fixture helpers

    private func t(_ epoch: TimeInterval) -> Date { Date(timeIntervalSince1970: epoch) }

    private func makeTempURL() -> URL {
        let name = "locuskit-srccatalog-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    private func makeStore() async throws -> (DrawerStore, URL) {
        let url = makeTempURL()
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))
        return (store, url)
    }

    private func sample(
        id: String = "src-1",
        kind: SourceKind = .user,
        handle: String = "https://example.com",
        udc: String = "004"
    ) -> SourceCatalogEntry {
        SourceCatalogEntry(
            id: id,
            kind: kind,
            handle: handle,
            latticeAnchor: .udc(udc),
            firstSeen: t(1_700_000_000),
            addedBy: "cataloger"
        )
    }

    // MARK: - SourceKind conformance

    @Test("SourceKind round-trips every case and falls back to .user")
    func sourceKind_roundTrip() {
        for kind in SourceKind.allCases {
            #expect(SourceKind.fromRaw(kind.rawValue) == kind)
        }
        // Unrecognised raws fall back to .user (fail-closed baseline).
        #expect(SourceKind.fromRaw(6) == .user)
        #expect(SourceKind.fromRaw(-1) == .user)
        #expect(SourceKind.fromRaw(99) == .user)
    }

    // MARK: - Store round-trip

    @Test("addSourceCatalogEntry + getSourceCatalogEntry round-trip every field")
    func store_roundTrip() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let entry = sample(kind: .federation, udc: "005")
        try await store.addSourceCatalogEntry(entry)
        let loaded = try await store.getSourceCatalogEntry(id: "src-1")
        #expect(loaded == entry)
        #expect(loaded?.kind == .federation)
        #expect(loaded?.latticeAnchor.udcCode == "005")
    }

    @Test("getSourceCatalogEntry returns nil for a missing id")
    func store_missingId() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        #expect(try await store.getSourceCatalogEntry(id: "no-such-source") == nil)
    }

    @Test("sourceCatalogEntry(forHandle:) resolves the source by handle")
    func store_byHandle() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addSourceCatalogEntry(sample(id: "src-a", handle: "https://a.example"))
        try await store.addSourceCatalogEntry(sample(id: "src-b", handle: "https://b.example"))
        let a = try await store.sourceCatalogEntry(forHandle: "https://a.example")
        #expect(a?.id == "src-a")
        let none = try await store.sourceCatalogEntry(forHandle: "https://missing.example")
        #expect(none == nil)
    }

    @Test("addSourceCatalogEntry rejects an empty lattice anchor")
    func store_rejectsEmptyAnchor() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        // An empty anchor would propagate a fabricated identity through learn.
        let bad = SourceCatalogEntry(
            id: "src-bad",
            kind: .user,
            handle: "https://example.com",
            latticeAnchor: .udc(""),
            firstSeen: t(1_700_000_000),
            addedBy: "cataloger"
        )
        await #expect(throws: LocusKitError.self) {
            try await store.addSourceCatalogEntry(bad)
        }
    }
}
