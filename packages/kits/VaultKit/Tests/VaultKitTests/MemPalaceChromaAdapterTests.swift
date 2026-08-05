import Testing
import Foundation
import LocusKit
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import VaultKit

// MemPalaceChromaAdapter conformance tests.
//
// Exercises the shared fixture palace
// `Fixtures/mempalace/` (palace/chroma.sqlite3 + tunnels.json +
// knowledge_graph.sqlite3 — regenerate with `generate_fixture.sh`).
// The Rust suite (`rust/tests/mem_palace_adapter.rs`) loads the SAME
// fixture files and asserts the SAME values — the cross-language
// field-mapping conformance contract. Any change to the fixture or the
// mapping must keep both suites green in the same commit.
@Suite("MemPalaceChromaAdapter")
struct MemPalaceChromaAdapterTests {

    /// The shared fixture palace root, resolved relative to this source
    /// file (the Rust suite reaches the same directory via
    /// CARGO_MANIFEST_DIR).
    static var fixturePalaceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mempalace")
    }

    private func fixtureNotes() throws -> [NoteIR] {
        try MemPalaceChromaAdapter().toIR(vaultURL: Self.fixturePalaceURL)
    }

    private func note(_ key: String, in notes: [NoteIR]) throws -> NoteIR {
        try #require(notes.first { $0.stableSourceKey == key })
    }

    // MARK: - Deterministic shape

    @Test("fixture palace maps all three stores, sorted by stable key bytes")
    func fixtureShape() throws {
        let notes = try fixtureNotes()
        // 5 chroma rows + 2 tunnels + 2 KG entities + 2 KG triples.
        #expect(notes.count == 11)
        #expect(notes.map(\.stableSourceKey) == [
            "aaaa000011112222",
            "bbbb000011112222",
            "closet_clarity_0004",
            "closet_entities_0005",
            "diary_fulcrum_0002",
            "drawer_alpha_0001",
            "drawer_min_0003",
            "fleet",
            "skippy",
            "t_fleet_works_with_skippy_0001",
            "t_minimal_0002",
        ])
        #expect(notes.map(\.kind) == [
            "tunnel", "tunnel",
            "closet_summary", "closet_summary",
            "diary_entry", "drawer", "drawer",
            "kg_entity", "kg_entity",
            "kg_triple", "kg_triple",
        ])
    }

    // MARK: - Store 1: chroma rows

    @Test("full drawer row: verbatim frontmatter, placement, entities facts, source")
    func fullDrawerRow() throws {
        let note = try note("drawer_alpha_0001", in: try fixtureNotes())
        #expect(note.kind == "drawer")
        #expect(note.body == [Block(kind: "markdown", text: "Alpha decision content with detail.")])
        // Frontmatter keys VERBATIM — no prefixes; numerics in SQLite's
        // own text form (the cross-port float determinism anchor).
        #expect(note.frontmatter == [
            "wing": "mootx01",
            "hall": "hall_general",
            "room": "decisions",
            "filed_at": "2026-05-04T19:58:47.837740",
            "source_file": "notes/alpha.md",
            "source_mtime": "1746678432.25",
            "chunk_index": "0",
            "added_by": "skippy",
            "normalize_version": "3",
            "entities": "Fleet;Skippy",
        ])
        #expect(note.pathComponents == ["mootx01", "hall_general", "decisions"])
        #expect(note.originalPath == "mootx01/hall_general/decisions")
        // filed_at normalized: microseconds truncated to milliseconds, UTC.
        #expect(note.originDate?.iso8601 == "2026-05-04T19:58:47.837Z")
        #expect(note.source == SourceRef(path: "notes/alpha.md", contentHash: ""))
        // entities → one mention fact per name, anchored to this note.
        #expect(note.facts == [
            FactIR(subject: "Fleet", predicate: "mentioned_in", object: "drawer_alpha_0001"),
            FactIR(subject: "Skippy", predicate: "mentioned_in", object: "drawer_alpha_0001"),
        ])
        #expect(note.links.isEmpty)
        #expect(note.tags.isEmpty)
        #expect(note.scope.isEmpty)
        #expect(note.mootID == nil)
    }

    @Test("diary row: kind diary_entry, diary keys verbatim")
    func diaryRow() throws {
        let note = try note("diary_fulcrum_0002", in: try fixtureNotes())
        #expect(note.kind == "diary_entry")
        #expect(note.frontmatter["type"] == "diary_entry")
        #expect(note.frontmatter["date"] == "2026-05-08")
        #expect(note.frontmatter["agent"] == "skippy")
        #expect(note.frontmatter["topic"] == "handoff")
        #expect(note.originDate?.iso8601 == "2026-05-08T04:27:12.542Z")
        #expect(note.pathComponents == ["fulcrum", "hall_diary", "diary"])
        #expect(note.source == nil)
    }

    @Test("minimal drawer row: no hall, CURRENT_TIMESTAMP filed_at shape")
    func minimalDrawerRow() throws {
        let note = try note("drawer_min_0003", in: try fixtureNotes())
        #expect(note.kind == "drawer")
        #expect(note.pathComponents == ["mootx01", "storage"])
        #expect(note.originalPath == "mootx01/storage")
        // " " separator normalized to "T", fraction synthesized.
        #expect(note.originDate?.iso8601 == "2026-04-28T02:48:07.000Z")
        #expect(note.facts.isEmpty)
    }

    @Test("closet rows: kind closet_summary, drawer_count rides verbatim")
    func closetRows() throws {
        let notes = try fixtureNotes()
        let clarity = try note("closet_clarity_0004", in: notes)
        #expect(clarity.kind == "closet_summary")
        #expect(clarity.frontmatter["drawer_count"] == "12")
        #expect(clarity.body.first?.text == "clarity|Fleet|summary of twelve drawers")

        let entities = try note("closet_entities_0005", in: notes)
        #expect(entities.kind == "closet_summary")
        #expect(entities.facts == [
            FactIR(subject: "Not", predicate: "mentioned_in", object: "closet_entities_0005"),
            FactIR(subject: "Skippy", predicate: "mentioned_in", object: "closet_entities_0005"),
        ])
        // Microsecond fraction truncates, not rounds: .000001 → .000.
        #expect(entities.originDate?.iso8601 == "2026-05-01T00:00:00.000Z")
    }

    // MARK: - Store 2: tunnels

    @Test("labeled tunnel: wikilink to target, endpoints in frontmatter")
    func labeledTunnel() throws {
        let note = try note("aaaa000011112222", in: try fixtureNotes())
        #expect(note.kind == "tunnel")
        #expect(note.body == [Block(kind: "markdown", text: "Decision informs diary handoff")])
        #expect(note.links == [WikiLink(
            target: "fulcrum/diary", alias: nil, raw: "Decision informs diary handoff")])
        #expect(note.frontmatter == [
            "source_wing": "mootx01",
            "source_room": "decisions",
            "target_wing": "fulcrum",
            "target_room": "diary",
            "created_at": "2026-05-29T08:38:47.205501+00:00",
        ])
        #expect(note.pathComponents == ["mootx01", "decisions"])
        #expect(note.originalPath == "mootx01/decisions")
        // "+00:00" offset stripped, microseconds truncated.
        #expect(note.originDate?.iso8601 == "2026-05-29T08:38:47.205Z")
    }

    @Test("unlabeled tunnel: endpoint fallback keeps body and link non-empty (I-5)")
    func unlabeledTunnel() throws {
        let note = try note("bbbb000011112222", in: try fixtureNotes())
        #expect(note.body == [Block(kind: "markdown", text: "fulcrum/diary -> mootx01/storage")])
        #expect(note.links == [WikiLink(
            target: "mootx01/storage", alias: nil, raw: "fulcrum/diary -> mootx01/storage")])
        #expect(note.frontmatter["created_at"] == nil)
        #expect(note.originDate == nil)
    }

    // MARK: - Store 3: knowledge graph

    @Test("KG entity rows: name/type/properties verbatim, placed under knowledge_graph/entities")
    func kgEntityRows() throws {
        let notes = try fixtureNotes()
        let skippy = try note("skippy", in: notes)
        #expect(skippy.kind == "kg_entity")
        #expect(skippy.body == [Block(kind: "markdown", text: "Skippy")])
        #expect(skippy.frontmatter == [
            "name": "Skippy",
            "type": "agent",
            "properties": "{\"role\": \"ai\"}",
            "created_at": "2026-04-28 02:50:08",
        ])
        #expect(skippy.pathComponents == ["knowledge_graph", "entities"])
        #expect(skippy.originDate?.iso8601 == "2026-04-28T02:50:08.000Z")
        #expect(skippy.facts.isEmpty)
    }

    @Test("KG triple rows: FactIR with validity window + confidence, provenance in frontmatter")
    func kgTripleRows() throws {
        let notes = try fixtureNotes()
        let full = try note("t_fleet_works_with_skippy_0001", in: notes)
        #expect(full.kind == "kg_triple")
        #expect(full.body == [Block(kind: "markdown", text: "fleet works_with skippy")])
        #expect(full.facts == [FactIR(
            subject: "fleet", predicate: "works_with", object: "skippy",
            validFrom: "2026-04-27", validTo: nil, confidence: 1.0)])
        #expect(full.frontmatter == [
            "source_closet": "closet_clarity_0004",
            "source_file": "notes/alpha.md",
            "source_drawer_id": "drawer_alpha_0001",
            "adapter_name": "general",
            "extracted_at": "2026-04-28 02:48:07",
        ])
        #expect(full.source == SourceRef(path: "notes/alpha.md", contentHash: ""))
        #expect(full.pathComponents == ["knowledge_graph", "triples"])
        #expect(full.originDate?.iso8601 == "2026-04-28T02:48:07.000Z")

        let minimal = try note("t_minimal_0002", in: notes)
        #expect(minimal.body == [Block(kind: "markdown", text: "skippy knows fleet")])
        #expect(minimal.facts == [FactIR(
            subject: "skippy", predicate: "knows", object: "fleet",
            validFrom: nil, validTo: nil, confidence: 0.75)])
        #expect(minimal.frontmatter.isEmpty)
        #expect(minimal.source == nil)
        #expect(minimal.originDate == nil)
    }

    // MARK: - Timestamp normalization

    @Test("canonicalISO8601: the four MemPalace shapes + rejections")
    func timestampNormalization() {
        let f = MemPalaceChromaAdapter.canonicalISO8601(fromMemPalace:)
        // Naive microseconds (filed_at) — truncate to milliseconds, UTC.
        #expect(f("2026-05-08T04:27:12.542283") == "2026-05-08T04:27:12.542Z")
        // Explicit UTC offset (tunnel created_at).
        #expect(f("2026-05-29T08:38:47.205501+00:00") == "2026-05-29T08:38:47.205Z")
        // SQLite CURRENT_TIMESTAMP (KG rows).
        #expect(f("2026-04-28 02:48:07") == "2026-04-28T02:48:07.000Z")
        // Date-only (diary `date`).
        #expect(f("2026-05-08") == "2026-05-08T00:00:00.000Z")
        // Short fraction pads; trailing Z accepted.
        #expect(f("2026-05-08T04:27:12.5") == "2026-05-08T04:27:12.500Z")
        #expect(f("2026-05-08T04:27:12.542Z") == "2026-05-08T04:27:12.542Z")
        // Non-UTC offsets are rejected (no tz arithmetic), as is garbage.
        #expect(f("2026-05-08T04:27:12+02:00") == nil)
        #expect(f("2026-05-08T04:27:12-05:00") == nil)
        #expect(f("not a date") == nil)
        #expect(f("2026-05-08T04:27") == nil)
        #expect(f("") == nil)
    }

    // MARK: - Read-only direction

    @Test("fromIR is rejected: MemPalace is a source, never a destination")
    func writeDirectionRejected() {
        #expect(throws: VaultKitError.self) {
            try MemPalaceChromaAdapter().fromIR([], to: Self.fixturePalaceURL)
        }
    }

    @Test("missing chroma store throws adapterError, not silence")
    func missingChromaThrows() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-palace-\(UUID().uuidString)")
        #expect(throws: VaultKitError.self) {
            _ = try MemPalaceChromaAdapter().toIR(vaultURL: bogus)
        }
    }

    // MARK: - Bridge entry point

    @Test("importMemPalace: fixture palace lands in an estate, idempotent on re-import")
    func bridgeImport() async throws {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "mempalace-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)

        let bridge = VaultBridge(kit: kit)
        let now = Date(timeIntervalSince1970: 1_765_000_000)

        let first = try await bridge.importMemPalace(
            at: Self.fixturePalaceURL, into: handle, now: now)
        // All 11 notes have non-empty content (I-5 fallbacks hold), so
        // every one captures; the 2 tunnel notes each carry one wikilink.
        #expect(first.drawersWritten == 11)
        #expect(first.drawersUpdated == 0)
        #expect(first.itemsSkipped == 0)
        #expect(first.tunnelsCreated == 2)
        #expect(first.fdcClassified + first.fdcUnclassified == 11)

        // Idempotency: re-importing the same fixture with identical content
        // must not rotate UUIDs or supersede. The content-idempotent guard
        // fires for every lineage → all 11 skipped-unchanged, none updated.
        let second = try await bridge.importMemPalace(
            at: Self.fixturePalaceURL, into: handle, now: now)
        #expect(second.drawersWritten == 0)
        #expect(second.drawersUpdated == 0)
        #expect(second.drawersSkippedUnchanged == 11)
        #expect(second.tunnelsCreated == 0)
    }

    // MARK: - Real-palace integration (guarded)

    @Test("real ~/.mempalace imports with the expected store counts")
    func realPalaceIntegration() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mempalace")
        // Guarded: runs only on a machine that has a live palace.
        guard FileManager.default.fileExists(
            atPath: root.appendingPathComponent("palace/chroma.sqlite3").path)
        else { return }

        let notes = try MemPalaceChromaAdapter().toIR(vaultURL: root)
        var byKind: [String: Int] = [:]
        for note in notes { byKind[note.kind, default: 0] += 1 }

        // Verified against the live palace 2026-06-10: 39,777 drawer rows
        // (2,281 of them diary), 7,525 closets, 959 KG entities, 810 KG
        // triples. The palace is live and append-mostly, so the floor is
        // asserted (>=) rather than equality.
        let drawerRows = (byKind["drawer"] ?? 0) + (byKind["diary_entry"] ?? 0)
        #expect(drawerRows >= 39_777)
        #expect(byKind["diary_entry"] ?? 0 >= 2_281)
        #expect(byKind["closet_summary"] ?? 0 >= 7_525)
        #expect(byKind["kg_entity"] ?? 0 >= 959)
        #expect(byKind["kg_triple"] ?? 0 >= 810)
        #expect(byKind["tunnel"] ?? 0 >= 1)

        // Spot-check fidelity invariants over the whole palace: stable
        // keys are unique and every chroma row carries its placement.
        #expect(Set(notes.map(\.stableSourceKey)).count == notes.count)
        for note in notes where ["drawer", "diary_entry", "closet_summary"].contains(note.kind) {
            #expect(note.frontmatter["wing"] != nil)
            #expect(note.frontmatter["room"] != nil)
            #expect(note.frontmatter["filed_at"] != nil)
        }
    }

    // MARK: - Import bounds (the palace root is untrusted input)

    /// Copy the fixture palace into a fresh temp directory so a test can
    /// oversize or corrupt one store without touching the shared fixture
    /// that every other test in both ports asserts against.
    private func temporaryPalaceCopy() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mempalace-bounds-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: Self.fixturePalaceURL, to: root)
        return root
    }

    /// The message of the `VaultKitError` a bounded import threw, or a
    /// recorded failure when it did not throw at all.
    private func limitErrorMessage(
        _ operation: () throws -> some Any
    ) -> String {
        do {
            _ = try operation()
            Issue.record("expected the import limit to reject this palace")
            return ""
        } catch {
            return "\(error)"
        }
    }

    @Test("an oversized tunnels.json is rejected BEFORE the file is read, naming the limit")
    func oversizedTunnelsRejectedBeforeRead() throws {
        let root = try temporaryPalaceCopy()
        defer { try? FileManager.default.removeItem(at: root) }

        // Deliberately MALFORMED as well as oversized. If the size check did
        // not precede the read, this would fail with the JSON decode error
        // instead of the limit — which is exactly what pre-fix code does.
        // That is what makes this a regression test for the unbounded read
        // rather than a test that some rejection happens.
        let oversized = String(repeating: "x", count: 4096)
        try oversized.write(
            to: root.appendingPathComponent("tunnels.json"),
            atomically: true, encoding: .utf8)

        let adapter = MemPalaceChromaAdapter(
            limits: MemPalaceImportLimits(maxTunnelsJSONBytes: 1024))
        let message = limitErrorMessage { try adapter.toIR(vaultURL: root) }

        #expect(message.contains("maxTunnelsJSONBytes"))
        #expect(message.contains("4096"), "the error must name the OBSERVED value")
        #expect(message.contains("1024"), "the error must name the LIMIT")
        // The proof the file was never parsed: no decode diagnostic.
        #expect(!message.contains("malformed"))
    }

    @Test("a row count over the cap is rejected, naming the limit and the count")
    func rowCapRejectedWithNamedLimit() throws {
        // The fixture's drawers scan alone returns more than three rows.
        let adapter = MemPalaceChromaAdapter(
            limits: MemPalaceImportLimits(maxImportRows: 3))
        let message = limitErrorMessage {
            try adapter.toIR(vaultURL: Self.fixturePalaceURL)
        }
        #expect(message.contains("maxImportRows"))
        #expect(message.contains("3"), "the error must name the limit")
        #expect(message.contains("SQLite rows"))
    }

    @Test("a materialized-byte total over the cap is rejected, naming the limit")
    func byteCapRejectedWithNamedLimit() throws {
        let adapter = MemPalaceChromaAdapter(
            limits: MemPalaceImportLimits(maxMaterializedBytes: 16))
        let message = limitErrorMessage {
            try adapter.toIR(vaultURL: Self.fixturePalaceURL)
        }
        #expect(message.contains("maxMaterializedBytes"))
        #expect(message.contains("16"))
    }

    @Test("the SQLite progress guard abandons a query past the step budget")
    func stepBudgetAbandonsQuery() throws {
        // Grain 1 fires the handler every virtual-machine instruction, so a
        // one-step budget trips on the first statement rather than depending
        // on how much work the fixture happens to need.
        let adapter = MemPalaceChromaAdapter(
            limits: MemPalaceImportLimits(
                maxSQLiteVMSteps: 1, sqliteProgressGrain: 1))
        let message = limitErrorMessage {
            try adapter.toIR(vaultURL: Self.fixturePalaceURL)
        }
        #expect(message.contains("maxSQLiteVMSteps"))
        // The named limit, not SQLite's bare "interrupted" diagnostic.
        #expect(message.contains("virtual-machine steps"))
    }

    @Test("the fixture palace imports identically under the shipping defaults")
    func defaultsDoNotAlterNormalImport() throws {
        // The caps must be invisible to real input. Same 11 notes, same
        // order, same kinds as `fixtureShape` asserts — read through the
        // default (bounded) path.
        let bounded = try MemPalaceChromaAdapter(limits: .default)
            .toIR(vaultURL: Self.fixturePalaceURL)
        #expect(bounded.count == 11)
        #expect(bounded.map(\.stableSourceKey) == [
            "aaaa000011112222",
            "bbbb000011112222",
            "closet_clarity_0004",
            "closet_entities_0005",
            "diary_fulcrum_0002",
            "drawer_alpha_0001",
            "drawer_min_0003",
            "fleet",
            "skippy",
            "t_fleet_works_with_skippy_0001",
            "t_minimal_0002",
        ])
    }

    @Test("the shipping limit defaults are the documented values, identical to Rust")
    func defaultLimitValuesAreTheDocumentedConstants() {
        // Asserted literally in BOTH ports: divergent caps would mean an
        // import that succeeds in one port and fails in the other. Changing
        // a default here must change it in
        // `rust/tests/mem_palace_adapter.rs` in the same commit.
        let limits = MemPalaceImportLimits.default
        #expect(limits.maxTunnelsJSONBytes == 67_108_864)
        #expect(limits.maxImportRows == 20_000_000)
        #expect(limits.maxMaterializedBytes == 1_073_741_824)
        #expect(limits.maxSQLiteVMSteps == 1_000_000_000)
        #expect(limits.sqliteProgressGrain == 1_000_000)
    }

    @Test("raising the limit above the file restores the pre-fix code path")
    func raisingTheLimitRestoresThePreFixCodePath() throws {
        // The runnable proof that the size check is what changes the outcome,
        // and therefore that `oversizedTunnelsRejectedBeforeRead` is a real
        // regression test. With the cap raised ABOVE the same
        // oversized-and-malformed file, the read proceeds and the JSON decode
        // fails — exactly what pre-fix code did for every file size, because
        // no size check existed. That test asserts this message is ABSENT;
        // this one asserts it is present once the bound is lifted. Same
        // fixture, same file, opposite outcomes.
        let root = try temporaryPalaceCopy()
        defer { try? FileManager.default.removeItem(at: root) }
        try String(repeating: "x", count: 4096).write(
            to: root.appendingPathComponent("tunnels.json"),
            atomically: true, encoding: .utf8)

        let adapter = MemPalaceChromaAdapter(
            limits: MemPalaceImportLimits(maxTunnelsJSONBytes: 1_000_000))
        let message = limitErrorMessage { try adapter.toIR(vaultURL: root) }
        #expect(message.contains("malformed"))
        #expect(!message.contains("maxTunnelsJSONBytes"))
    }
}
