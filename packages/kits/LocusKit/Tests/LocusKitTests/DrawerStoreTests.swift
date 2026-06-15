import Foundation
import PersistenceKit
import SubstrateTypes
import Testing
@testable import LocusKit

@Suite("DrawerStoreTests")
struct DrawerStoreTests {

    // MARK: - Test fixture helpers

    private func t(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    private func makeTempURL() -> URL {
        let name = "locuskit-store-test-\(UUID().uuidString).sqlite"
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
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

    private func sampleDrawer(
        id: String = "d1",
        wing: String = "wing-a",
        room: String = "room-a",
        sourceFile: String? = nil,
        chunkIndex: Int? = nil,
        filedAt: Date? = nil
    ) -> Drawer {
        Drawer(
            id: TestStorage.tid(id),
            content: "content-\(id)",
            wing: wing,
            room: room,
            sourceFile: sourceFile,
            chunkIndex: chunkIndex,
            addedBy: "bilby",
            filedAt: filedAt ?? t(1_700_000_000),
            embeddingModelID: "minilm-v6"
        )
    }

    // MARK: - Drawer CRUD

    @Test("addDrawer + getDrawer round-trip")
    func addGetDrawer() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)
        let loaded = try await store.getDrawer(id: d.id)
        #expect(loaded == d)
    }

    @Test("getDrawer returns nil for unknown id")
    func getDrawerMiss() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        #expect(try await store.getDrawer(id: "99999999-9999-4999-8999-999999999999") == nil)
    }

    @Test("getDrawers(ids:) returns the requested drawers, equivalent to getDrawer")
    func getDrawersBatchEquivalence() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let a = sampleDrawer(id: "a")
        let b = sampleDrawer(id: "b")
        let c = sampleDrawer(id: "c")
        try await store.addDrawer(a)
        try await store.addDrawer(b)
        try await store.addDrawer(c)
        // Batch-load a subset; each row must be byte-for-byte the single-load row.
        let batch = try await store.getDrawers(ids: [a.id, c.id])
        let byID = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0) })
        #expect(byID.count == 2)
        #expect(byID[a.id] == (try await store.getDrawer(id: a.id)))
        #expect(byID[c.id] == (try await store.getDrawer(id: c.id)))
        #expect(byID[b.id] == nil)
    }

    @Test("getDrawers(ids:) returns [] for empty input without touching storage")
    func getDrawersEmpty() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        #expect(try await store.getDrawers(ids: []) == [])
    }

    @Test("getDrawers(ids:) omits unknown ids and de-duplicates repeats")
    func getDrawersMissesAndDupes() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let a = sampleDrawer(id: "a")
        try await store.addDrawer(a)
        let unknown = TestStorage.tid("zz")
        // Repeat a.id and include an unknown id: result is exactly one row.
        let batch = try await store.getDrawers(ids: [a.id, a.id, unknown])
        #expect(batch.count == 1)
        #expect(batch.first == a)
    }

    @Test("getDrawers(ids:) chunks past the SQLite bind-parameter ceiling")
    func getDrawersChunkingBeyond900() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        // Insert more rows than a single IN-clause can bind (chunkSize = 900),
        // then request all of them. The chunked path must return every row.
        var ids: [String] = []
        for i in 0..<950 {
            // Distinct ids per row; sampleDrawer derives content from the id.
            let d = sampleDrawer(id: "row-\(i)")
            try await store.addDrawer(d)
            ids.append(d.id)
        }
        let batch = try await store.getDrawers(ids: ids)
        #expect(batch.count == 950)
        #expect(Set(batch.map(\.id)) == Set(ids))
    }

    // MARK: - Dense-first: no-blob structured projection (steps 3+4)

    @Test("getDrawers(ids:hydrationLevel:.structured) does NOT read the content blob")
    func getDrawersStructuredOmitsContent() async throws {
        // The .structured projection must leave content absent — a genuine
        // no-blob read — while every structured/bitmap/lattice column survives.
        // Run against the real SQLite backend so this proves the projected
        // SELECT, not a post-load strip.
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let a = sampleDrawer(id: "a", room: "room-x")
        try await store.addDrawer(a)

        let structured = try await store.getDrawers(
            ids: [a.id], hydrationLevel: .structured)
        #expect(structured.count == 1)
        let s = structured.first
        // content is absent (decodes to "") — the blob was never read.
        #expect(s?.content == "")
        // The dense/structured signal is intact at .structured.
        #expect(s?.id == a.id)
        #expect(s?.wing == a.wing)
        #expect(s?.room == a.room)
        #expect(s?.adjectiveBitmap == a.adjectiveBitmap)
        #expect(s?.operationalBitmap == a.operationalBitmap)
        #expect(s?.udcCode == a.udcCode)
    }

    @Test("getDrawers(ids:hydrationLevel:.full) reads the content blob")
    func getDrawersFullReadsContent() async throws {
        // The .full path is byte-for-byte the bare getDrawers(ids:) — content
        // present, every column intact.
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let a = sampleDrawer(id: "a")
        try await store.addDrawer(a)

        let full = try await store.getDrawers(ids: [a.id], hydrationLevel: .full)
        #expect(full.first?.content == a.content)
        #expect(full.first == a)
        // The bare overload still reads content (full hydration).
        let bare = try await store.getDrawers(ids: [a.id])
        #expect(bare.first?.content == a.content)
    }

    @Test("first open: audit event estate uuid matches manifest estate uuid")
    func firstOpenAuditEstateUuidMatchesManifest() async throws {
        // Regression: the estate uuid stamped into audit events on a
        // fresh estate must equal the manifest estate_uuid. The init
        // resolved estateUuid before populating the manifest, so the
        // store held one uuid and the manifest another; first-session
        // audit events were sealed under the wrong estate identity.
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = sampleDrawer()
        try await store.addDrawer(d)
        let manifest = try await store.readManifest()
        let manifestUUID = try #require(UUID(uuidString: manifest.estateUUID))
        let rowID = try #require(UUID(uuidString: d.id))
        let events = try await store.auditEventsForRow(rowID)
        #expect(!events.isEmpty)
        #expect(events.first?.estateUuid == manifestUUID)
    }

    @Test("addDrawer rejects duplicate id with duplicateKey")
    func addDrawerDuplicateRejected() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer())
        // The storage layer surfaces a PRIMARY KEY collision as
        // StorageError.duplicateKey rather than a raw SQLite string.
        await #expect(throws: StorageError.self) {
            try await store.addDrawer(sampleDrawer())
        }
    }

    @Test("drawersIn(wing:) returns only matching wing, ordered by filedAt")
    func drawersInWing() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer(id: TestStorage.tid("a"), wing: "wing-a", filedAt: t(2)))
        try await store.addDrawer(sampleDrawer(id: TestStorage.tid("b"), wing: "wing-a", filedAt: t(1)))
        try await store.addDrawer(sampleDrawer(id: TestStorage.tid("c"), wing: "wing-b", filedAt: t(3)))
        let result = try await store.drawersIn(wing: "wing-a")
        #expect(result.map(\.id) == [TestStorage.tid("b"), TestStorage.tid("a")])
    }

    @Test("drawersIn(wing:room:) returns only matching pair")
    func drawersInWingRoom() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer(id: TestStorage.tid("a"), wing: "w", room: "r1"))
        try await store.addDrawer(sampleDrawer(id: TestStorage.tid("b"), wing: "w", room: "r2"))
        try await store.addDrawer(sampleDrawer(id: TestStorage.tid("c"), wing: "w", room: "r1"))
        let result = try await store.drawersIn(wing: "w", room: "r1")
        #expect(Set(result.map(\.id)) == [TestStorage.tid("a"), TestStorage.tid("c")])
    }

    @Test("drawersBySource(file:) returns only matching source")
    func drawersBySource() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer(id: TestStorage.tid("a"), sourceFile: "/x.md", chunkIndex: 0))
        try await store.addDrawer(sampleDrawer(id: TestStorage.tid("b"), sourceFile: "/x.md", chunkIndex: 1))
        try await store.addDrawer(sampleDrawer(id: TestStorage.tid("c"), sourceFile: "/y.md", chunkIndex: 0))
        let result = try await store.drawersBySource(file: "/x.md")
        #expect(result.map(\.id) == [TestStorage.tid("a"), TestStorage.tid("b")])
    }

    @Test("allDrawers returns full corpus ordered by filedAt")
    func allDrawersReturned() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer(id: TestStorage.tid("a"), filedAt: t(3)))
        try await store.addDrawer(sampleDrawer(id: TestStorage.tid("b"), filedAt: t(1)))
        try await store.addDrawer(sampleDrawer(id: TestStorage.tid("c"), filedAt: t(2)))
        let result = try await store.allDrawers()
        #expect(result.map(\.id) == [TestStorage.tid("b"), TestStorage.tid("c"), TestStorage.tid("a")])
    }

    @Test("addDrawer rejects empty wing with invalidContent")
    func emptyWingRejected() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = Drawer(id: TestStorage.tid("d"), content: "c", wing: "", room: "r",
                       addedBy: "b", filedAt: t(1), embeddingModelID: "m")
        do {
            try await store.addDrawer(d)
            Issue.record("expected invalidContent for empty wing")
        } catch let LocusKitError.invalidContent(message) {
            #expect(message == "wing must not be empty")
        }
    }

    @Test("addDrawer rejects empty room with invalidContent")
    func emptyRoomRejected() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = Drawer(id: TestStorage.tid("d"), content: "c", wing: "w", room: "",
                       addedBy: "b", filedAt: t(1), embeddingModelID: "m")
        do {
            try await store.addDrawer(d)
            Issue.record("expected invalidContent for empty room")
        } catch let LocusKitError.invalidContent(message) {
            #expect(message == "room must not be empty")
        }
    }

    @Test("addDrawer rejects empty content with invalidContent")
    func emptyContentRejected() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = Drawer(id: TestStorage.tid("d"), content: "", wing: "w", room: "r",
                       addedBy: "b", filedAt: t(1), embeddingModelID: "m")
        do {
            try await store.addDrawer(d)
            Issue.record("expected invalidContent for empty content")
        } catch let LocusKitError.invalidContent(message) {
            #expect(message == "content must not be empty")
        }
    }

    // MARK: - Tunnel CRUD

    private func sampleTunnel(
        id: String = "t1",
        sourceWing: String = "wing-a",
        sourceRoom: String = "room-a",
        targetWing: String = "wing-b",
        targetRoom: String = "room-b",
        filedAt: Date? = nil
    ) -> Tunnel {
        Tunnel(
            id: id,
            sourceWing: sourceWing, sourceRoom: sourceRoom,
            targetWing: targetWing, targetRoom: targetRoom,
            label: "links",
            addedBy: "bilby",
            filedAt: filedAt ?? t(1_700_000_000)
        )
    }

    @Test("addTunnel + getTunnel round-trip")
    func addGetTunnel() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let original = sampleTunnel()
        try await store.addTunnel(original)
        let loaded = try await store.getTunnel(id: original.id)
        #expect(loaded == original)
    }

    @Test("getTunnel returns nil for unknown id")
    func getTunnelMiss() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        #expect(try await store.getTunnel(id: "nope") == nil)
    }

    @Test("tunnelsFrom(wing:) returns only tunnels rooted in that wing")
    func tunnelsFromWing() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addTunnel(sampleTunnel(id: "a", sourceWing: "w1"))
        try await store.addTunnel(sampleTunnel(id: "b", sourceWing: "w1"))
        try await store.addTunnel(sampleTunnel(id: "c", sourceWing: "w2"))
        let result = try await store.tunnelsFrom(wing: "w1")
        #expect(Set(result.map(\.id)) == ["a", "b"])
    }

    @Test("tunnelsFrom(wing:room:) restricts to a wing/room pair")
    func tunnelsFromWingRoom() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addTunnel(sampleTunnel(id: "a", sourceWing: "w", sourceRoom: "r1"))
        try await store.addTunnel(sampleTunnel(id: "b", sourceWing: "w", sourceRoom: "r2"))
        let result = try await store.tunnelsFrom(wing: "w", room: "r1")
        #expect(result.map(\.id) == ["a"])
    }

    @Test("tunnelsTo(wing:) returns only tunnels whose target is that wing")
    func tunnelsToWing() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addTunnel(sampleTunnel(id: "a", targetWing: "w1"))
        try await store.addTunnel(sampleTunnel(id: "b", targetWing: "w2"))
        let result = try await store.tunnelsTo(wing: "w1")
        #expect(result.map(\.id) == ["a"])
    }

    @Test("addTunnel rejects empty label with invalidContent")
    func emptyTunnelLabelRejected() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let t1 = Tunnel(id: "t", sourceWing: "w", sourceRoom: "r",
                        targetWing: "w2", targetRoom: "r2",
                        label: "", addedBy: "b", filedAt: t(1))
        do {
            try await store.addTunnel(t1)
            Issue.record("expected invalidContent for empty label")
        } catch let LocusKitError.invalidContent(message) {
            #expect(message == "label must not be empty")
        }
    }

    // MARK: - Diary CRUD

    private func sampleDiaryEntry(
        id: String = "e1",
        agentName: String = "skippy",
        wing: String? = nil,
        filedAt: Date? = nil
    ) -> DiaryEntry {
        DiaryEntry(
            id: id,
            agentName: agentName,
            entry: "entry-\(id)",
            topic: "loci-1",
            wing: wing ?? "wing_\(agentName)",
            room: "diary",
            filedAt: filedAt ?? t(1_700_000_000),
            embeddingModelID: "minilm-v6"
        )
    }

    @Test("addDiaryEntry + getDiaryEntry round-trip")
    func addGetDiaryEntry() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let entry = sampleDiaryEntry()
        try await store.addDiaryEntry(entry)
        let loaded = try await store.getDiaryEntry(id: entry.id)
        #expect(loaded == entry)
    }

    @Test("readDiary(agentName:lastN:) returns most-recent N, sorted DESC")
    func readDiaryRecentDesc() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDiaryEntry(sampleDiaryEntry(id: "a", filedAt: t(1)))
        try await store.addDiaryEntry(sampleDiaryEntry(id: "b", filedAt: t(3)))
        try await store.addDiaryEntry(sampleDiaryEntry(id: "c", filedAt: t(2)))
        let result = try await store.readDiary(agentName: "skippy", lastN: 2)
        #expect(result.map(\.id) == ["b", "c"])
    }

    @Test("readDiary(agentName:in:lastN:) filters by wing")
    func readDiaryFilteredByWing() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDiaryEntry(sampleDiaryEntry(id: "a",
                                                 wing: "wing_skippy",
                                                 filedAt: t(1)))
        try await store.addDiaryEntry(sampleDiaryEntry(id: "b",
                                                 wing: "wing_other",
                                                 filedAt: t(2)))
        let result = try await store.readDiary(agentName: "skippy",
                                         in: "wing_skippy",
                                         lastN: 10)
        #expect(result.map(\.id) == ["a"])
    }

    @Test("addDiaryEntry rejects empty entry text with invalidContent")
    func emptyDiaryEntryRejected() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let e = DiaryEntry(id: "e", agentName: "s", entry: "", topic: "t",
                           wing: "w", room: "r", filedAt: t(1), embeddingModelID: "m")
        do {
            try await store.addDiaryEntry(e)
            Issue.record("expected invalidContent for empty entry")
        } catch let LocusKitError.invalidContent(message) {
            #expect(message == "entry must not be empty")
        }
    }

    @Test("addDiaryEntry rejects empty agentName with invalidContent")
    func emptyAgentNameRejected() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let e = DiaryEntry(id: "e", agentName: "", entry: "x", topic: "t",
                           wing: "w", room: "r", filedAt: t(1), embeddingModelID: "m")
        do {
            try await store.addDiaryEntry(e)
            Issue.record("expected invalidContent for empty agentName")
        } catch let LocusKitError.invalidContent(message) {
            #expect(message == "agentName must not be empty")
        }
    }

    // MARK: - Meta surface

    @Test("setMeta + getMeta round-trip")
    func setGetMeta() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.setMeta(key: "schemaVersion", value: "1")
        #expect(try await store.getMeta(key: "schemaVersion") == "1")
    }

    @Test("setMeta is upsert — overwrites existing key")
    func setMetaUpsert() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.setMeta(key: "k", value: "first")
        try await store.setMeta(key: "k", value: "second")
        #expect(try await store.getMeta(key: "k") == "second")
    }

    @Test("getMeta returns nil for unknown key")
    func getMetaMiss() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        #expect(try await store.getMeta(key: "nope") == nil)
    }

    // MARK: - Adjective bitmap persistence (LOCI_V035_01B)

    /// Round-trip a non-trivial adjective bitmap value through insert
    /// and fetch. `0x1042` is the canonical mission test bitmap from
    /// `AdjectiveBitmapTests` — state=`.contested`, sensitivity=
    /// `.elevated`, exportability=`.private_`, trust=`.observed`.
    @Test("addDrawer persists adjectiveBitmap and fetch returns it byte-for-byte")
    func adjectiveBitmapRoundTrip() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = Drawer(
            id: TestStorage.tid("ab-1"), content: "c", wing: "w", room: "r",
            addedBy: "b", filedAt: t(1), embeddingModelID: "m",
            // v0.6 capture-legal: state=active(0) | sensitivity=elevated(16<<6)
            // | trust=observed(1<<18) = 0x40400. Capture's initial state
            // must be active or pending (DECISION_CLOCK_TRIANGLE: genesis
            // can't start contested — that arises via the contest verb).
            adjectiveBitmap: 0x40400
        )
        try await store.addDrawer(d)
        let loaded = try await store.getDrawer(id: TestStorage.tid("ab-1"))
        #expect(loaded?.adjectiveBitmap == 0x40400)
    }

    /// A drawer constructed without an explicit `adjectiveBitmap`
    /// argument round-trips with the column-default value of 0.
    @Test("addDrawer persists default adjectiveBitmap = 0")
    func adjectiveBitmapDefaultZero() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer(id: "ab-default"))
        let loaded = try await store.getDrawer(id: TestStorage.tid("ab-default"))
        #expect(loaded?.adjectiveBitmap == 0)
    }

    // MARK: - Operational bitmap persistence (LOCI_V035_02B)

    /// Round-trip a non-trivial operational bitmap value through insert
    /// and fetch. `0x1412` is the canonical mission test bitmap from
    /// `DrawerOperationalTests` — captureChannel=`.ocr` (raw 2),
    /// contentKind=`.code` (raw 1), featureFlags=`[.hasImage,
    /// .isPinned]` (bits 10 and 12).
    @Test("addDrawer persists operationalBitmap and fetch returns it byte-for-byte")
    func operationalBitmapRoundTrip() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        let d = Drawer(
            id: TestStorage.tid("ob-1"), content: "c", wing: "w", room: "r",
            addedBy: "b", filedAt: t(1), embeddingModelID: "m",
            // v0.6 gate-legal: captureChannel=ocr(2) | contentKind=code(1<<6) = 0x42.
            // The earlier 0x1412 set capture_channel to 18 (illegal: legal [0..5]).
            operationalBitmap: 0x42
        )
        try await store.addDrawer(d)
        let loaded = try await store.getDrawer(id: TestStorage.tid("ob-1"))
        #expect(loaded?.operationalBitmap == 0x42)
    }

    /// A drawer constructed without an explicit `operationalBitmap`
    /// argument round-trips with the column-default value of 0.
    @Test("addDrawer persists default operationalBitmap = 0")
    func operationalBitmapDefaultZero() async throws {
        let (store, url) = try await makeStore()
        defer { cleanup(url) }
        try await store.addDrawer(sampleDrawer(id: "ob-default"))
        let loaded = try await store.getDrawer(id: TestStorage.tid("ob-default"))
        #expect(loaded?.operationalBitmap == 0)
    }

    // MARK: - Persistence across instance lifecycles

    @Test("re-opening a closed store reads back data")
    func reopenStoreReadsData() async throws {
        let url = makeTempURL()
        defer { cleanup(url) }
        let d = sampleDrawer()
        do {
            let first = try await DrawerStore(storage: TestStorage.sqlite(url))
            try await first.addDrawer(d)
            try await first.setMeta(key: "schemaVersion", value: "1")
            // first goes out of scope here; deinit closes the SQLite handle.
        }
        let second = try await DrawerStore(storage: TestStorage.sqlite(url))
        #expect(try await second.getDrawer(id: d.id) == d)
        #expect(try await second.getMeta(key: "schemaVersion") == "1")
    }
}
