import Foundation
import SQLite3
import Testing
@testable import LocusKit

/// Lattice anchor coverage — the four `Drawer` fields introduced
/// by spec § 5.8 and I-5 ("Every drawer carries a lattice anchor"):
/// `udcCode` (required TEXT with default `""`), `udcFacets`,
/// `wikidataQID`, and `wikidataQidsSecondary` (all optional TEXT).
///
/// These tests cover four shapes:
/// 1. Round-trip with all four fields populated through `DrawerStore`.
/// 2. Round-trip with the three optionals nil and `udcCode` empty.
/// 3. Default behavior of `Drawer.init` — `udcCode` defaults to `""`,
///    the three optionals default to nil.
/// 4. `CREATE INDEX IF NOT EXISTS idx_drawers_udcCode` is applied.
@Suite("LatticeAnchorTests")
struct LatticeAnchorTests {

    // MARK: - Helpers (mirror DrawerStoreTests to keep this suite self-contained)

    private func makeTempURL() -> URL {
        let name = "locuskit-lattice-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("sqlite-shm"))
    }

    private func indexNames(at url: URL, table: String) throws -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let opened = handle else {
            if let h = handle { sqlite3_close_v2(h) }
            return []
        }
        defer { sqlite3_close_v2(opened) }
        var stmt: OpaquePointer?
        let pragma = "PRAGMA index_list(\(table))"
        guard sqlite3_prepare_v2(opened, pragma, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            // PRAGMA index_list returns (seq, name, unique, origin, partial)
            if let cString = sqlite3_column_text(stmt, 1) {
                names.append(String(cString: cString))
            }
        }
        return names
    }

    // MARK: - Drawer value-type defaults

    /// `udcCode` defaults to the empty string and the three optional
    /// fields default to nil when callers omit them at construction.
    /// This mirrors the SQLite column defaults so callers that ingest
    /// content without a lattice anchor produce drawers byte-equal to
    /// what the migration backfills.
    @Test("Drawer.init defaults udcCode to \"\" and the three Q-ID/facet fields to nil")
    func latticeAnchorDefaults() {
        let d = Drawer(
            content: "x",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: Date(timeIntervalSince1970: 0),
            embeddingModelID: "minilm-v6"
        )
        #expect(d.udcCode == "")
        #expect(d.udcFacets == nil)
        #expect(d.wikidataQID == nil)
        #expect(d.wikidataQidsSecondary == nil)
    }

    // MARK: - Round-trip — fully populated lattice anchor

    /// All four fields populated. `udcCode: "547"` is the canonical
    /// UDC code for organic chemistry per spec § 5.8 worked example;
    /// the facets and Wikidata anchors carry independent values that
    /// must survive the round-trip without rewrite or truncation.
    @Test("addDrawer persists all four lattice anchor fields and fetch returns them verbatim")
    func latticeAnchorFullRoundTrip() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        let d = Drawer(
            id: TestStorage.tid("la-full"),
            content: "organic chemistry note",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: Date(timeIntervalSince1970: 1_700_000_000),
            embeddingModelID: "minilm-v6",
            udcCode: "547",
            udcFacets: "(03)=20",
            wikidataQID: "Q11351",
            wikidataQidsSecondary: "Q41487,Q170978"
        )
        try await store.addDrawer(d)

        let loaded = try await store.getDrawer(id: TestStorage.tid("la-full"))
        #expect(loaded?.udcCode == "547")
        #expect(loaded?.udcFacets == "(03)=20")
        #expect(loaded?.wikidataQID == "Q11351")
        #expect(loaded?.wikidataQidsSecondary == "Q41487,Q170978")
    }

    // MARK: - Round-trip — optionals nil, udcCode empty

    /// A drawer constructed without a lattice anchor must round-trip
    /// with `udcCode == ""` and the three optional fields nil. The
    /// SQLite column for `udcCode` is `NOT NULL DEFAULT ''`, so the
    /// empty string is the only valid no-anchor sentinel; the three
    /// optional columns persist NULL.
    @Test("addDrawer persists empty udcCode and nil optionals, fetch returns them unchanged")
    func latticeAnchorEmptyRoundTrip() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let store = try await DrawerStore(storage: TestStorage.sqlite(url))

        let d = Drawer(
            id: TestStorage.tid("la-empty"),
            content: "no anchor",
            parentNodeId: "test-parent",
            addedBy: "bilby",
            filedAt: Date(timeIntervalSince1970: 1_700_000_000),
            embeddingModelID: "minilm-v6"
        )
        try await store.addDrawer(d)

        let loaded = try await store.getDrawer(id: TestStorage.tid("la-empty"))
        #expect(loaded?.udcCode == "")
        #expect(loaded?.udcFacets == nil)
        #expect(loaded?.wikidataQID == nil)
        #expect(loaded?.wikidataQidsSecondary == nil)
    }

    // MARK: - Index presence

    /// `CREATE INDEX IF NOT EXISTS idx_drawers_udcCode ON drawers (udcCode)`
    /// runs as part of schema setup. `PRAGMA index_list(drawers)` must
    /// report the index name on a freshly-created store.
    @Test("idx_drawers_udcCode index is created on a fresh DrawerStore")
    func udcCodeIndexExists() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        _ = try await DrawerStore(storage: TestStorage.sqlite(url))
        let indexes = try indexNames(at: url, table: "drawers")
        #expect(indexes.contains("idx_drawers_udcCode"))
    }
}
