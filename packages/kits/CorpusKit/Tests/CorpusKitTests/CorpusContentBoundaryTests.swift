// CorpusContentBoundaryTests.swift
//
// Content-boundary, schema-profile, and checkpoint coverage
// (GLK shared-content 1.1, P1).
//
// The conformance harness below is THE source/store contract: it runs
// against the standalone `CorpusDocumentStore` (the real SQLite backend)
// AND against an in-memory test adapter shaped like GLK's Drawer-backed
// adapter — both must satisfy identical semantics, which is what lets the
// engine consume either without knowing which mode it is in.

import Testing
import Foundation
import PersistenceKit
import PersistenceKitSQLite

@testable import CorpusKit

// MARK: - In-memory adapter (the GLK-adapter stand-in)

/// A minimal in-memory `CorpusContentStore` shaped like the attached-mode
/// adapter: content lives OUTSIDE CorpusKit (here, a dictionary standing
/// in for LocusKit Drawers) and the store serves records/changes from it.
private actor InMemoryContentAdapter: CorpusContentStore {
    private var records: [CorpusContentID: CorpusContentRecord] = [:]
    private var journal: [(seq: Int64, change: CorpusContentChange)] = []
    private var nextSeq: Int64 = 1

    func put(_ text: String, id: CorpusContentID, now: Date) async throws -> CorpusContentRecord {
        let digest = CorpusContentDigest.digest(text)
        if let existing = records[id] {
            if existing.digest == digest { return existing }
            let bumped = CorpusContentRecord(
                id: id, revision: existing.revision + 1, digest: digest, text: text)
            records[id] = bumped
            journal.append((nextSeq, .upsert(id: id, revision: bumped.revision, digest: digest)))
            nextSeq += 1
            return bumped
        }
        let fresh = CorpusContentRecord(id: id, revision: 1, digest: digest, text: text)
        records[id] = fresh
        journal.append((nextSeq, .upsert(id: id, revision: 1, digest: digest)))
        nextSeq += 1
        return fresh
    }

    func remove(id: CorpusContentID, now: Date) async throws {
        guard let existing = records.removeValue(forKey: id) else { return }
        journal.append((nextSeq, .remove(id: id, revision: existing.revision)))
        nextSeq += 1
    }

    func record(for id: CorpusContentID) async throws -> CorpusContentRecord? {
        records[id]
    }

    func changes(since cursor: String?, limit: Int) async throws -> CorpusContentChangeBatch {
        guard limit > 0 else { return .empty }
        let after = cursor.flatMap(Int64.init) ?? 0
        let page = journal.filter { $0.seq > after }.prefix(limit)
        guard !page.isEmpty else { return .empty }
        return CorpusContentChangeBatch(
            changes: page.map(\.change),
            nextCursor: String(page.last!.seq))
    }

    func activeContentIDs() async throws -> [CorpusContentID] {
        records.keys.sorted()
    }
}

// MARK: - The conformance harness

private let harnessNow = Date(timeIntervalSince1970: 1_700_000_000)

/// Exercise the full source/store contract against any conformer.
private func exerciseContentStoreConformance(
    _ store: any CorpusContentStore
) async throws {
    // 1. Fresh put → revision 1, correct digest, verbatim text back.
    let textA1 = "The first canonical document."
    let recA1 = try await store.put(textA1, id: "doc-a", now: harnessNow)
    #expect(recA1.revision == 1)
    #expect(recA1.digest == CorpusContentDigest.digest(textA1))
    #expect(try await store.record(for: "doc-a") == recA1)

    // 2. Idempotent re-put: identical text → same record, NO new change.
    let recA1Again = try await store.put(textA1, id: "doc-a", now: harnessNow)
    #expect(recA1Again == recA1)
    let afterIdempotent = try await store.changes(since: nil, limit: 100)
    #expect(afterIdempotent.changes.count == 1)

    // 3. Changed text → revision bump + new digest + journaled upsert.
    let textA2 = "The first canonical document, revised."
    let recA2 = try await store.put(textA2, id: "doc-a", now: harnessNow)
    #expect(recA2.revision == 2)
    #expect(recA2.digest != recA1.digest)

    // A second document for enumeration/pagination coverage.
    _ = try await store.put("A second document.", id: "doc-b", now: harnessNow)
    #expect(try await store.activeContentIDs() == ["doc-a", "doc-b"])

    // 4. Remove → record gone, remove change carries the removed revision.
    try await store.remove(id: "doc-b", now: harnessNow)
    #expect(try await store.record(for: "doc-b") == nil)
    #expect(try await store.activeContentIDs() == ["doc-a"])
    // Removing an absent ID is a no-op.
    try await store.remove(id: "doc-b", now: harnessNow)

    // 5. Feed contents in order: upsert(a,1), upsert(a,2), upsert(b,1), remove(b,1).
    let all = try await store.changes(since: nil, limit: 100)
    #expect(all.changes == [
        .upsert(id: "doc-a", revision: 1, digest: recA1.digest),
        .upsert(id: "doc-a", revision: 2, digest: recA2.digest),
        .upsert(id: "doc-b", revision: 1, digest: CorpusContentDigest.digest("A second document.")),
        .remove(id: "doc-b", revision: 1)
    ])

    // 6. Cursor pagination: limit-1 pages walk the same feed; re-reading a
    //    cursor is stable; the final cursor yields an empty batch.
    var cursor: String? = nil
    var paged: [CorpusContentChange] = []
    for _ in 0..<4 {
        let page = try await store.changes(since: cursor, limit: 1)
        #expect(page.changes.count == 1)
        // Stability: the same cursor re-read returns the same page.
        let reread = try await store.changes(since: cursor, limit: 1)
        #expect(reread == page)
        paged.append(contentsOf: page.changes)
        cursor = page.nextCursor
    }
    #expect(paged == all.changes)
    let drained = try await store.changes(since: cursor, limit: 1)
    #expect(drained == .empty)

    // 7. No verbatim text in the change feed (identity/revision/digest only)
    //    — structural: CorpusContentChange has no text field; assert the
    //    digests are digests, not content.
    for change in all.changes {
        if case let .upsert(_, _, digest) = change {
            #expect(digest.count == 64)
            #expect(digest.allSatisfy { $0.isHexDigit })
        }
    }
}

// MARK: - Suites

@Suite("CorpusContentBoundary", .serialized)
struct CorpusContentBoundaryTests {

    // MARK: Conformance — both implementations, same harness

    @Test func documentStoreSatisfiesTheContentStoreContract() async throws {
        let storage = try makeScratchStorage()
        try await storage.migrate(to: CorpusDocumentStore.schemaDeclaration)
        try await exerciseContentStoreConformance(CorpusDocumentStore(storage: storage))
    }

    @Test func inMemoryAdapterSatisfiesTheContentStoreContract() async throws {
        try await exerciseContentStoreConformance(InMemoryContentAdapter())
    }

    @Test func documentStoreSurvivesReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpuskit-docstore-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let config = EstateConfiguration(estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0))

        let first = try SQLiteStorage(configuration: config)
        try await first.migrate(to: CorpusDocumentStore.schemaDeclaration)
        let store1 = CorpusDocumentStore(storage: first)
        _ = try await store1.put("Persisted across reopen.", id: "doc-r", now: harnessNow)

        // A NEW store over a NEW storage on the same file continues the
        // journal without gaps or seq reuse.
        let second = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
        try await second.migrate(to: CorpusDocumentStore.schemaDeclaration)
        let store2 = CorpusDocumentStore(storage: second)
        let record = try await store2.record(for: "doc-r")
        #expect(record?.revision == 1)
        _ = try await store2.put("Persisted across reopen, revised.", id: "doc-r", now: harnessNow)
        let feed = try await store2.changes(since: nil, limit: 10)
        #expect(feed.changes.map(\.revision) == [1, 2])
    }

    @Test func digestIsCrossPortStable() {
        // Frozen SHA-256 vectors — the Rust twin asserts the same strings.
        #expect(CorpusContentDigest.digest("")
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(CorpusContentDigest.digest("hello")
            == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    // MARK: Operating-mode / index-unit validation

#if CORPUSKIT_STANDALONE_PASSAGES
    @Test func attachedModeRejectsPassageConfigurationBeforeWriting() {
        #expect(throws: CorpusKitError.self) {
            _ = try CorpusContentConfiguration(
                mode: .attached,
                indexUnit: .tokenWindows(windowTokens: 512, overlapTokens: 64))
        }
    }

    @Test func invalidPassageWindowsAreRejected() {
        #expect(throws: CorpusKitError.self) {
            _ = try CorpusContentConfiguration(
                mode: .standalone,
                indexUnit: .tokenWindows(windowTokens: 0, overlapTokens: 0))
        }
        #expect(throws: CorpusKitError.self) {
            _ = try CorpusContentConfiguration(
                mode: .standalone,
                indexUnit: .tokenWindows(windowTokens: 512, overlapTokens: 512))
        }
    }
#endif

    @Test func validConfigurationsConstructAndGateMutation() throws {
        let attached = try CorpusContentConfiguration(mode: .attached, indexUnit: .wholeContent)
        #expect(!attached.allowsContentMutation)
        let standaloneWhole = try CorpusContentConfiguration(
            mode: .standalone, indexUnit: .wholeContent)
        #expect(standaloneWhole.allowsContentMutation)
#if CORPUSKIT_STANDALONE_PASSAGES
        let standalonePassages = try CorpusContentConfiguration(
            mode: .standalone,
            indexUnit: .tokenWindows(windowTokens: 512, overlapTokens: 64))
        #expect(standalonePassages.allowsContentMutation)
#endif
    }

    // MARK: Schema profiles

    @Test func attachedProfileContainsNoCanonicalContentTable() {
        let names = Set(CorpusSchemaProfile.attachedDeclaration.tables.map(\.name))
        #expect(names.isDisjoint(with: CorpusSchemaProfile.attachedExcludedTables))
        #expect(names == ["corpus_index_state", "corpus_provider_coverage",
                          "corpus_provider_configuration",
                          "iix_termfreqs", "iix_doclens",
                          "corpus_provider_basis", "corpus_provider_counts",
                          "corpus_provider_count_references"])
        // No column named "text" anywhere in the attached profile — there
        // is no place a verbatim copy could land.
        for table in CorpusSchemaProfile.attachedDeclaration.tables {
            #expect(!table.columns.contains { $0.name == "text" },
                    "attached table \(table.name) must not carry a text column")
        }
    }

    @Test func standaloneProfileGatesPassagesOnConfiguration() {
#if CORPUSKIT_STANDALONE_PASSAGES
        let without = Set(CorpusSchemaProfile.standaloneDeclaration(passageIndexing: false)
            .tables.map(\.name))
#else
        let without = Set(CorpusSchemaProfile.standaloneDeclaration().tables.map(\.name))
#endif
        #expect(without.contains("corpus_documents"))
        #expect(without.contains("corpus_index_state"))
        #expect(!without.contains("corpus_passages"))
        // The standalone profile never carries the legacy copy lane.
        #expect(!without.contains("chunks"))
        #expect(!without.contains("corpus_metadata"))

#if CORPUSKIT_STANDALONE_PASSAGES
        #expect(without.contains("corpus_index_configuration"))
        let with = Set(CorpusSchemaProfile.standaloneDeclaration(passageIndexing: true)
            .tables.map(\.name))
        #expect(with.contains("corpus_passages"))

        // The passage table is range-only: no text column.
        #expect(!CorpusSchemaProfile.passagesTable.columns.contains { $0.name == "text" })
        #expect(CorpusSchemaProfile.passagesTable.columns.contains {
            $0.name == "policy_fingerprint"
        })
#else
        // The default dependency profile used by GLK/MOOTx01 has neither the
        // policy authority nor passage ranges compiled into its schema.
        #expect(!without.contains("corpus_index_configuration"))
#endif
    }

    @Test func attachedProfileOpensWithoutCanonicalContentTables() async throws {
        let storage = try makeScratchStorage()
        try await storage.migrate(to: CorpusSchemaProfile.attachedDeclaration)

        // The derived lanes exist…
        #expect(try await storage.rowStore.count(table: "corpus_index_state", where: nil) == 0)
        #expect(try await storage.rowStore.count(table: "iix_termfreqs", where: nil) == 0)
        #expect(try await storage.rowStore.count(table: "corpus_provider_basis", where: nil) == 0)

        // …and no canonical content table was created.
        await #expect(throws: (any Error).self) {
            _ = try await storage.rowStore.count(table: "corpus_documents", where: nil)
        }
        await #expect(throws: (any Error).self) {
            _ = try await storage.rowStore.count(table: "chunks", where: nil)
        }
    }

    // MARK: Index-state checkpoint lane

    @Test func indexStateAdvanceReadClearRoundTrip() async throws {
        let storage = try makeScratchStorage()
        try await storage.migrate(to: CorpusIndexStateStore.schemaDeclaration)
        let store = CorpusIndexStateStore(storage: storage)

        let state = CorpusIndexState(
            contentID: "drawer-1", revision: 3, digest: CorpusContentDigest.digest("x"),
            indexVersion: 1, appliedCursor: "42", updatedAt: harnessNow)
        try await store.advance(state)
        // Idempotent re-advance.
        try await store.advance(state)
        #expect(try await store.state(for: "drawer-1") == state)

        try await store.advance(CorpusIndexState(
            contentID: "drawer-2", revision: 1, digest: CorpusContentDigest.digest("y"),
            indexVersion: 1, appliedCursor: nil, updatedAt: harnessNow))
        #expect(try await store.allStates().map(\.contentID) == ["drawer-1", "drawer-2"])

        try await store.clear(contentID: "drawer-1")
        #expect(try await store.state(for: "drawer-1") == nil)
        try await store.clearAll()
        #expect(try await store.allStates().isEmpty)
    }

    @Test func indexStateSurvivesReopenOnSQLite() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpuskit-ixstate-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
        try await first.migrate(to: CorpusIndexStateStore.schemaDeclaration)
        let state = CorpusIndexState(
            contentID: "drawer-1", revision: 2, digest: CorpusContentDigest.digest("z"),
            indexVersion: 1, appliedCursor: nil, updatedAt: harnessNow)
        try await CorpusIndexStateStore(storage: first).advance(state)

        // Reopen: the SQLite backend hands TIMESTAMP back as .text ISO8601;
        // the decode must tolerate it (primitive-tolerance discipline).
        let second = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: url, busyTimeout: 5.0)))
        try await second.migrate(to: CorpusIndexStateStore.schemaDeclaration)
        let reread = try await CorpusIndexStateStore(storage: second).state(for: "drawer-1")
        #expect(reread == state)
    }
}
