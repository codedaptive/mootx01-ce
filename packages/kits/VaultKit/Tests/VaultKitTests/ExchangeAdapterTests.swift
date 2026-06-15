import Testing
import Foundation
import LocusKit
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import VaultKit

// VK-ADAPT-01 (read side) + VK-EXPORT-01 (write side) — ExchangeAdapter
// decode/encode, CorpusProjection, and adapter→bridge end-to-end tests.
//
// Two shared cross-language conformance vectors: the golden fixture
// `Fixtures/exchange_export_golden.json` (decode mapping) and the
// canonical fixture `Fixtures/exchange_export_canonical.json` (the
// byte-exact canonical encode of the golden fixture). The Rust suite
// (`rust/tests/exchange_adapter.rs`) loads the SAME files and asserts
// the same decoded values and identical encoded bytes. Any change to a
// fixture must keep both suites green in the same commit.
//
// The end-to-end tests are the relocated coverage for the retired GLK
// flat import verb: one-drawer-per-entry, provenance, and idempotent
// re-import are now properties of the adapter → `VaultBridge.importVault`
// path, asserted here instead of in GLK_MIG_02_MigrationTests.

@Suite("ExchangeAdapter decode + projection + import pipeline")
struct ExchangeAdapterTests {

    // MARK: - Fixtures

    /// Path of the shared golden fixture, resolved relative to this
    /// source file so no Package.swift resource processing is needed
    /// (the Rust suite reaches the same file via CARGO_MANIFEST_DIR).
    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/exchange_export_golden.json")
    }

    /// Open one estate through GeniusLocusKit over in-memory storage.
    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "exchange-adapter-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// Currently-believed drawers, hydrated in full so provenance and
    /// channel fields are readable.
    private func currentDrawers(_ kit: GeniusLocusKit, _ handle: EstateHandle) async throws -> [Drawer] {
        try await kit.recall(handle, RecallFrame(filterChain: [.userConfirmed], hydrationLevel: .full))
    }

    // MARK: - Decode: golden fixture

    @Test("golden fixture decodes: name, sorted keys, field mapping")
    func goldenFixtureDecodes() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let export = try ExchangeAdapter().decode(data)

        #expect(export.name == "golden-palace")
        // Deterministic order: sorted by stableSourceKey even though the
        // fixture lists drawer-002 first.
        #expect(export.notes.map(\.stableSourceKey) == ["drawer-001", "drawer-002", "drawer-003"])

        let full = export.notes[0]
        #expect(full.flattenedBody == "Alice works at Acme.")
        #expect(full.body == [Block(kind: "markdown", text: "Alice works at Acme.")])
        #expect(full.tags == ["org", "people"])
        #expect(full.facts == [FactIR(
            subject: "alice", predicate: "works_at", object: "acme",
            validFrom: "2024-03-04T05:06:07.000Z", confidence: 0.9)])
        #expect(full.pathComponents == ["work", "people"])
        #expect(full.originalPath == "work/people")
        #expect(full.scope == ["agentId": "ag-7"])
        #expect(full.kind == "fact")
    }

    @Test("absent extended fields land their documented defaults")
    func absentExtendedFieldsLandDefaults() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let export = try ExchangeAdapter().decode(data)

        // drawer-002 carries only id/content/tags — the legacy flat shape.
        let flat = export.notes[1]
        #expect(flat.tags == [])
        #expect(flat.facts == [])
        #expect(flat.pathComponents == [])
        #expect(flat.originalPath == "")
        #expect(flat.scope == [:])
        #expect(flat.kind == "note")
        #expect(flat.frontmatter == [:])
        #expect(flat.links == [])
        #expect(flat.mootID == nil)
    }

    @Test("tags key may be omitted entirely")
    func tagsKeyMayBeOmitted() throws {
        let json = #"{ "name": "n", "entries": [ { "id": "a", "content": "c" } ] }"#
        let export = try ExchangeAdapter().decode(Data(json.utf8))
        #expect(export.notes.count == 1)
        #expect(export.notes[0].tags == [])
    }

    @Test("malformed JSON and missing required fields throw")
    func malformedExportThrows() {
        let adapter = ExchangeAdapter()
        // Not JSON at all.
        #expect(throws: (any Error).self) {
            _ = try adapter.decode(Data("not json".utf8))
        }
        // Missing required `content`.
        #expect(throws: (any Error).self) {
            _ = try adapter.decode(Data(#"{ "name": "n", "entries": [ { "id": "a" } ] }"#.utf8))
        }
        // Missing required top-level `name`.
        #expect(throws: (any Error).self) {
            _ = try adapter.decode(Data(#"{ "entries": [] }"#.utf8))
        }
    }

    @Test("toIR reads the export file and returns the notes")
    func toIRReadsFile() throws {
        let notes = try ExchangeAdapter().toIR(vaultURL: Self.fixtureURL)
        #expect(notes.map(\.stableSourceKey) == ["drawer-001", "drawer-002", "drawer-003"])
    }

    // MARK: - Write side (VK-EXPORT-01 — the programmatic exit promise)

    /// Path of the canonical write-side fixture: the byte-exact canonical
    /// re-encode of the golden fixture. The Rust suite asserts the SAME
    /// bytes — the cross-language byte-identity contract for `encode`.
    static var canonicalFixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/exchange_export_canonical.json")
    }

    /// A scratch file URL inside a fresh temporary directory.
    private func tempExportURL(_ file: String = "golden-palace.json") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vk-export-01-\(UUID().uuidString)")
        return dir.appendingPathComponent(file)
    }

    @Test("round-trip: toIR(fromIR(x)) == x over the golden fixture notes")
    func roundTripGoldenFixture() throws {
        let adapter = ExchangeAdapter()
        let notes = try adapter.toIR(vaultURL: Self.fixtureURL)
        let out = try tempExportURL()
        try adapter.fromIR(notes, to: out)
        let reread = try adapter.toIR(vaultURL: out)
        #expect(reread == notes)
    }

    @Test("round-trip: generated format-representable notes survive unchanged")
    func roundTripGeneratedNotes() throws {
        let adapter = ExchangeAdapter()
        // Format-representable fields only: id, content (single markdown
        // block), tags, facts, pathComponents (originalPath = joined view),
        // scope, kind. Includes unicode, slashes, and quotes in content.
        let generated = [
            NoteIR(
                stableSourceKey: "gen-001",
                body: [Block(kind: "markdown", text: "Slash /path/ and \"quotes\" and ünïcödé ✓")],
                tags: ["a", "b"],
                originalPath: "x/y",
                facts: [
                    FactIR(subject: "s", predicate: "p", object: "o"),
                    FactIR(subject: "s2", predicate: "p2", object: "o2",
                           validFrom: "2024-01-02T03:04:05.000Z",
                           validTo: "2025-01-02T03:04:05.000Z",
                           confidence: 0.5),
                ],
                pathComponents: ["x", "y"],
                scope: ["userId": "u-1", "agentId": "ag-2"],
                kind: "journal"
            ),
            NoteIR(
                stableSourceKey: "gen-000-flat",
                body: [Block(kind: "markdown", text: "flat legacy shape")]
            ),
        ]
        let out = try tempExportURL("generated.json")
        try adapter.fromIR(generated, to: out)
        let reread = try adapter.toIR(vaultURL: out)
        // toIR returns sorted by stableSourceKey; compare against the
        // same canonical order.
        #expect(reread == generated.sorted { $0.stableSourceKey < $1.stableSourceKey })
    }

    @Test("canonical encode matches the shared byte-identity fixture")
    func canonicalEncodeMatchesFixture() throws {
        let adapter = ExchangeAdapter()
        let export = try adapter.decode(Data(contentsOf: Self.fixtureURL))
        let encoded = try adapter.encode(export)
        let expected = try Data(contentsOf: Self.canonicalFixtureURL)
        #expect(encoded == expected)
    }

    @Test("re-encode is byte-stable: encode∘decode is idempotent on canonical form")
    func reEncodeIsByteStable() throws {
        let adapter = ExchangeAdapter()
        let first = try adapter.encode(adapter.decode(Data(contentsOf: Self.fixtureURL)))
        let second = try adapter.encode(adapter.decode(first))
        #expect(first == second)
    }

    @Test("encode preserves the corpus name and decode reads it back")
    func encodePreservesName() throws {
        let adapter = ExchangeAdapter()
        let export = ExchangeExport(name: "my-palace", notes: [
            NoteIR(stableSourceKey: "n1", body: [Block(text: "hello")]),
        ])
        let decoded = try adapter.decode(adapter.encode(export))
        #expect(decoded.name == "my-palace")
        #expect(decoded.notes == export.notes)
    }

    @Test("fromIR derives the corpus name from the destination filename")
    func fromIRDerivesNameFromFilename() throws {
        let adapter = ExchangeAdapter()
        let out = try tempExportURL("my-estate.json")
        try adapter.fromIR([NoteIR(stableSourceKey: "n1", body: [Block(text: "x")])], to: out)
        let decoded = try adapter.decode(Data(contentsOf: out))
        #expect(decoded.name == "my-estate")
    }

    @Test("fromIR creates intermediate directories and writes deterministically")
    func fromIRCreatesDirectoriesAndIsDeterministic() throws {
        let adapter = ExchangeAdapter()
        let notes = try adapter.toIR(vaultURL: Self.fixtureURL)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vk-export-01-\(UUID().uuidString)/deep/nested")
        let out = dir.appendingPathComponent("palace.json")
        try adapter.fromIR(notes, to: out)
        let firstBytes = try Data(contentsOf: out)
        // Same notes in reversed order: identical bytes (canonical sort).
        try adapter.fromIR(notes.reversed(), to: out)
        let secondBytes = try Data(contentsOf: out)
        #expect(firstBytes == secondBytes)
    }

    // MARK: - CorpusProjection

    @Test("projection maps notes back to ExternalCorpus entries")
    func projectionMapsNotes() throws {
        let data = try Data(contentsOf: Self.fixtureURL)
        let export = try ExchangeAdapter().decode(data)
        let corpus = CorpusProjection.externalCorpus(name: export.name, notes: export.notes)

        #expect(corpus.name == "golden-palace")
        #expect(corpus.entries.count == 3)
        #expect(corpus.entries[0] == ExternalEntry(
            id: "drawer-001", content: "Alice works at Acme.", tags: ["org", "people"]))
        #expect(corpus.entries.map(\.id) == export.notes.map(\.stableSourceKey))
    }

    // MARK: - End-to-end: adapter → bridge (the consolidated import path)

    @Test("import lands one drawer per entry with .importedFile channel and imported provenance")
    func importLandsDrawersWithProvenance() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = VaultBridge(
            kit: kit,
            adapter: ExchangeAdapter(),
            mapping: DrawerMapping(classifyOnImport: false))

        let report = try await bridge.importVault(at: Self.fixtureURL, into: handle, now: Date())

        #expect(report.drawersWritten == 3)
        #expect(report.drawersUpdated == 0)
        #expect(report.itemsSkipped == 0)

        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.count == 3)
        for drawer in drawers {
            // The retired GLK verb stamped `.typed`; the consolidated
            // path stamps the import channel + imported provenance.
            #expect(drawer.captureChannel == .importedFile)
            #expect(drawer.sourceType == .imported)
        }
    }

    @Test("re-import of the same fixture is idempotent — no duplicate drawers")
    func reImportIsIdempotent() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = VaultBridge(
            kit: kit,
            adapter: ExchangeAdapter(),
            mapping: DrawerMapping(classifyOnImport: false))

        let first = try await bridge.importVault(at: Self.fixtureURL, into: handle, now: Date())
        #expect(first.drawersWritten == 3)

        let second = try await bridge.importVault(at: Self.fixtureURL, into: handle, now: Date())
        #expect(second.drawersWritten == 0)
        #expect(second.drawersUpdated == 3)

        let drawers = try await currentDrawers(kit, handle)
        #expect(drawers.count == 3, "supersession, not duplication, on re-import")
    }

    // MARK: - End-to-end: bridge → adapter write side (VK-EXPORT-01)
    // The 0125 tier machinery exercised through the new write side:
    // VaultBridge.export filters tiers and writes the receipt BEFORE the
    // adapter sees notes; the adapter serializes exactly what it is handed.

    /// Fixed operation instant so receipt assertions are deterministic.
    private static let fixedNow = Date(timeIntervalSince1970: 1_765_000_000)

    /// Capture the shared four-drawer tier corpus (same content strings
    /// as `PrivacyTierAndReceiptTests` / the Rust port's `privacy_tiers.rs`).
    private func captureTierCorpus(_ kit: GeniusLocusKit, _ handle: EstateHandle) async throws {
        let tiers: [(String, AdjectiveSensitivity)] = [
            ("normal note", .normal),
            ("elevated note", .elevated),
            ("restricted note", .restricted),
            ("secret note", .secret),
        ]
        for (content, sensitivity) in tiers {
            _ = try await kit.capture(handle, CaptureFrame(
                content: content,
                channel: .typed,
                room: "tiers",
                latticeAnchor: LatticeAnchor(udcCode: "000"),
                addedBy: "exchange-export-tests",
                embeddingModelID: "test-v1",
                sensitivity: sensitivity
            ))
        }
    }

    @Test("bridge export through the write side: secret never present, private absent by default, receipt written")
    func bridgeExportEnforcesTiersAndWritesReceipt() async throws {
        let (kit, handle) = try await openEstate()
        try await captureTierCorpus(kit, handle)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("vk-export-01-\(UUID().uuidString)")
            .appendingPathComponent("estate.json")
        defer { try? FileManager.default.removeItem(at: out.deletingLastPathComponent()) }

        let bridge = VaultBridge(kit: kit, adapter: ExchangeAdapter())
        let report = try await bridge.export(estate: handle, to: out, now: Self.fixedNow)

        // Tier partition (0125) flowed through unchanged.
        #expect(report.notesExported == 2)
        #expect(report.excludedPrivateTier == 1)
        #expect(report.excludedSecretTier == 1)
        #expect(report.scope == .believed)

        // The written document is the external tool's export shape: it
        // decodes through the adapter's own read side, and the document
        // text carries no excluded-tier content anywhere (body, facts,
        // keys — nothing).
        let document = try #require(String(data: Data(contentsOf: out), encoding: .utf8))
        #expect(document.contains("normal note"))
        #expect(document.contains("elevated note"))
        #expect(!document.contains("restricted note"))
        #expect(!document.contains("secret note"))
        let reread = try ExchangeAdapter().toIR(vaultURL: out)
        #expect(reread.count == 2)

        // The audit receipt landed in the estate diary (ADR-007 D2).
        let receipts = try await kit.readDiaryEntries(
            in: handle, agentName: VaultBridge.receiptAgentName)
        #expect(receipts.count == 1)
        let receipt = try #require(receipts.first)
        #expect(receipt.filedAt == Self.fixedNow)
        #expect(receipt.entry.contains(#""operation":"vault-export""#))
        #expect(receipt.entry.contains(#""notesExported":2"#))
        #expect(receipt.entry.contains(#""excludedSecretTier":1"#))
        #expect(receipt.entry.contains(#""excludedPrivateTier":1"#))
    }

    @Test("bridge export with explicit private opt-in scope: restricted present, secret still never")
    func bridgeExportPrivateOptInThroughWriteSide() async throws {
        let (kit, handle) = try await openEstate()
        try await captureTierCorpus(kit, handle)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("vk-export-01-\(UUID().uuidString)")
            .appendingPathComponent("estate.json")
        defer { try? FileManager.default.removeItem(at: out.deletingLastPathComponent()) }

        let bridge = VaultBridge(kit: kit, adapter: ExchangeAdapter())
        let report = try await bridge.export(
            estate: handle, to: out, scope: .believedIncludingPrivate, now: Self.fixedNow)

        #expect(report.notesExported == 3)
        #expect(report.excludedPrivateTier == 0)
        #expect(report.excludedSecretTier == 1)

        let document = try #require(String(data: Data(contentsOf: out), encoding: .utf8))
        #expect(document.contains("restricted note"))
        #expect(!document.contains("secret note"))
    }

    @Test("applied and dropped fields are correctly classified in the report (C-13, hard-close #29)")
    func droppedFieldsAreRecorded() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = VaultBridge(
            kit: kit,
            adapter: ExchangeAdapter(),
            mapping: DrawerMapping(classifyOnImport: false))

        let report = try await bridge.importVault(at: Self.fixtureURL, into: handle, now: Date())

        // drawer-001 carries facts, scope, kind "fact", 2-level pathComponents, tags
        // drawer-003 carries tags + kind "journal"
        //
        // All structured fields now land in substrate (hard-close #29):
        //   - facts → KG facts (subject/predicate/object)
        //   - scope → KG facts (subject "scope:<key>")
        //   - pathComponents → full room path
        //   - tags → KG facts (subject "tag:<t>", predicate "tagged")
        //   - kind → KG fact (subject "record:kind", predicate "is") when != "note"
        //
        // fieldsDropped must be EMPTY for a fully-structured fixture — no quiet drop
        // path may remain (Bob's ruling: "No report-only loss").
        #expect(report.fieldsDropped["facts"] == nil,
                "facts land as KG facts — must not be tracked as dropped")
        #expect(report.fieldsDropped["scope"] == nil,
                "scope lands as KG facts — must not be tracked as dropped")
        #expect(report.fieldsDropped["pathComponents"] == nil,
                "pathComponents land as full room path — must not be tracked as dropped")
        #expect(report.fieldsDropped["tags"] == nil,
                "tags land as KG facts (hard-close #29-A) — must not be tracked as dropped")
        #expect(report.fieldsDropped["kind"] == nil,
                "kind lands as KG fact (hard-close #29-B) — must not be tracked as dropped")
        #expect(report.fieldsDropped.isEmpty,
                "all structured fields land — fieldsDropped must be empty for a fully-structured fixture")
    }
}
