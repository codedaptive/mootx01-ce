import Testing
import Foundation
import LocusKit
import GeniusLocusKit
import PersistenceKit
import PersistenceKitInMemory
@testable import VaultKit

// JsonImportBridge tests — the fourth import lane (seed-file JSON schema v1).
//
// Part 1 covers the parser + total pre-write validator: every schema rule has
// a failing input whose parse MUST throw a single error naming the FIRST
// offending element, and (structurally) performs zero estate writes — the
// validator is pure and takes no estate handle. Later parts add the import
// pipeline tests (collision, frame build, windowed write, relationships,
// receipt).
@Suite("JsonImportBridge seed-file schema v1")
struct JsonImportBridgeTests {

    static var fixtureSeedURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/seedfile/valid_seed.json")
    }

    /// Parse helper: run the validator over raw JSON text at default limits.
    private func parse(
        _ json: String,
        limits: JsonImportLimits = .default
    ) throws -> JsonSeedFile {
        try JsonSeedFile.parse(data: Data(json.utf8), limits: limits)
    }

    /// Expect `parse` to throw `VaultKitError.adapterError` whose message
    /// contains every given fragment (the "one error naming the first
    /// offending element" contract).
    private func expectParseError(
        _ json: String,
        limits: JsonImportLimits = .default,
        contains fragments: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        do {
            _ = try parse(json, limits: limits)
            Issue.record(
                "expected adapterError containing \(fragments); parse succeeded",
                sourceLocation: sourceLocation)
        } catch let VaultKitError.adapterError(message) {
            for fragment in fragments {
                #expect(
                    message.contains(fragment),
                    "error message must contain \"\(fragment)\"; got: \(message)",
                    sourceLocation: sourceLocation)
            }
        } catch {
            Issue.record(
                "expected VaultKitError.adapterError; got \(error)",
                sourceLocation: sourceLocation)
        }
    }

    /// A minimal valid seed body the failure tests mutate one element at a time.
    private func seed(
        records: String = """
        [{"id": "r1", "content": "c1", "event_time": "2026-01-01T00:00:00Z", "room": "rm"}]
        """,
        facts: String = "[]",
        tunnels: String = "[]"
    ) -> String {
        """
        {"format_version": 1, "name": "t", "records": \(records),
         "facts": \(facts), "tunnels": \(tunnels)}
        """
    }

    // MARK: - Valid seed

    @Test("valid fixture seed parses with defaults applied and file order kept")
    func validFixtureParses() throws {
        let data = try Data(contentsOf: Self.fixtureSeedURL)
        let file = try JsonSeedFile.parse(data: data, limits: .default)

        #expect(file.formatVersion == 1)
        #expect(file.name == "fixture-valid-seed")
        #expect(file.records.count == 3)
        #expect(file.facts.count == 2)
        #expect(file.tunnels.count == 2)

        // records array order IS ingestion order — never sorted.
        #expect(file.records.map(\.id) == ["r0001", "r0002", "r0003"])

        // Optional fields get schema-v1 defaults.
        let r2 = file.records[1]
        #expect(r2.wing == nil)
        #expect(r2.kind == .prose)
        #expect(r2.sensitivity == .normal)
        #expect(r2.exportability == .private_)

        // Explicit fields survive verbatim.
        let r3 = file.records[2]
        #expect(r3.wing == "Benchmark")
        #expect(r3.kind == .transcript)
        #expect(r3.sensitivity == .elevated)
        #expect(r3.exportability == .public_)

        // Tunnel kinds decode from the closed vocabulary.
        #expect(file.tunnels[0].kind == .supersedes)
        #expect(file.tunnels[1].kind == .references)
        #expect(file.tunnels[1].label == nil)
    }

    @Test("fractional-second UTC event_time parses to the exact instant")
    func fractionalSecondsParse() throws {
        let file = try parse(seed(records: """
            [{"id": "r1", "content": "c", "event_time": "2026-01-05T08:15:00.250Z", "room": "rm"}]
            """))
        let expected = ISO8601DateFormatter().date(from: "2026-01-05T08:15:00Z")!
            .addingTimeInterval(0.25)
        #expect(abs(file.records[0].eventTime.timeIntervalSince(expected)) < 0.001)
    }

    // MARK: - Malformed document

    @Test("malformed JSON is one hard error")
    func malformedJSON() {
        expectParseError("{not json", contains: ["malformed JSON"])
    }

    @Test("a JSON array at top level is rejected — the seed is an object")
    func topLevelArrayRejected() {
        expectParseError("[1, 2]", contains: ["top level", "object"])
    }

    @Test("wrong format_version is a hard error naming the version found")
    func wrongFormatVersion() {
        expectParseError(
            #"{"format_version": 2, "name": "t", "records": []}"#,
            contains: ["format_version", "2", "expected 1"])
    }

    @Test("missing format_version is a hard error")
    func missingFormatVersion() {
        expectParseError(
            #"{"name": "t", "records": []}"#,
            contains: ["format_version", "missing"])
    }

    @Test("missing or empty name is a hard error")
    func missingName() {
        expectParseError(
            #"{"format_version": 1, "records": []}"#,
            contains: ["name", "missing or empty"])
        expectParseError(
            #"{"format_version": 1, "name": "", "records": []}"#,
            contains: ["name", "missing or empty"])
    }

    @Test("missing records array is a hard error")
    func missingRecords() {
        expectParseError(
            #"{"format_version": 1, "name": "t"}"#,
            contains: ["records", "missing"])
    }

    @Test("unknown top-level key is rejected (rigid schema)")
    func unknownTopLevelKey() {
        expectParseError(
            #"{"format_version": 1, "name": "t", "records": [], "extra": 1}"#,
            contains: ["unknown top-level key", "extra"])
    }

    // MARK: - Record rules

    @Test("record missing id is a hard error naming the index")
    func recordMissingID() {
        expectParseError(
            seed(records: #"[{"content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm"}]"#),
            contains: ["record[0]", "id", "missing or empty"])
    }

    @Test("duplicate record id is a hard error naming the id")
    func duplicateRecordID() {
        expectParseError(
            seed(records: """
                [{"id": "r1", "content": "a", "event_time": "2026-01-01T00:00:00Z", "room": "rm"},
                 {"id": "r2", "content": "b", "event_time": "2026-01-01T00:00:00Z", "room": "rm"},
                 {"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm"}]
                """),
            contains: ["record[2]", "\"r1\"", "duplicate id"])
    }

    @Test("empty content is a hard error naming the record (I-5)")
    func emptyContent() {
        expectParseError(
            seed(records: #"[{"id": "r1", "content": "", "event_time": "2026-01-01T00:00:00Z", "room": "rm"}]"#),
            contains: ["record[0]", "\"r1\"", "content", "empty"])
    }

    @Test("missing event_time is a hard error naming the record")
    func missingEventTime() {
        expectParseError(
            seed(records: #"[{"id": "r1", "content": "c", "room": "rm"}]"#),
            contains: ["record[0]", "\"r1\"", "event_time", "missing"])
    }

    @Test("non-UTC or garbage event_time is a hard error naming the value")
    func badEventTime() {
        // Garbage.
        expectParseError(
            seed(records: #"[{"id": "r1", "content": "c", "event_time": "yesterday", "room": "rm"}]"#),
            contains: ["record[0]", "event_time", "yesterday"])
        // Offset form is rejected — schema v1 pins UTC "Z" (cross-port parity).
        expectParseError(
            seed(records: #"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00+02:00", "room": "rm"}]"#),
            contains: ["record[0]", "event_time", "+02:00"])
        // Fraction width other than 3 digits is rejected (pinned shape).
        expectParseError(
            seed(records: #"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00.25Z", "room": "rm"}]"#),
            contains: ["record[0]", "event_time", "0.25Z"])
        // Calendar-invalid date is rejected.
        expectParseError(
            seed(records: #"[{"id": "r1", "content": "c", "event_time": "2026-02-30T00:00:00Z", "room": "rm"}]"#),
            contains: ["record[0]", "event_time", "2026-02-30"])
    }

    @Test("missing or empty room is a hard error naming the record")
    func missingRoom() {
        expectParseError(
            seed(records: #"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z"}]"#),
            contains: ["record[0]", "\"r1\"", "room", "missing or empty"])
    }

    @Test("empty wing is a hard error (omit the key to use the default wing)")
    func emptyWing() {
        expectParseError(
            seed(records: #"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm", "wing": ""}]"#),
            contains: ["record[0]", "wing", "empty"])
    }

    @Test("unknown record kind / sensitivity / exportability are hard errors")
    func badEnumLabels() {
        expectParseError(
            seed(records: #"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm", "kind": "poem"}]"#),
            contains: ["record[0]", "kind", "poem"])
        expectParseError(
            seed(records: #"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm", "sensitivity": "hush"}]"#),
            contains: ["record[0]", "sensitivity", "hush"])
        expectParseError(
            seed(records: #"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm", "exportability": "shared"}]"#),
            contains: ["record[0]", "exportability", "shared"])
    }

    @Test("unknown record key is rejected (rigid schema)")
    func unknownRecordKey() {
        expectParseError(
            seed(records: #"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm", "mood": "hopeful"}]"#),
            contains: ["record[0]", "unknown key", "mood"])
    }

    // MARK: - Fact rules

    @Test("fact with empty subject/predicate/object is a hard error")
    func emptyFactField() {
        expectParseError(
            seed(facts: #"[{"subject": "", "predicate": "p", "object": "o", "record_id": "r1"}]"#),
            contains: ["fact[0]", "subject", "empty"])
    }

    @Test("dangling fact record_id is a hard error naming the id")
    func danglingFactRecordID() {
        expectParseError(
            seed(facts: #"[{"subject": "s", "predicate": "p", "object": "o", "record_id": "r9999"}]"#),
            contains: ["fact[0]", "record_id", "\"r9999\"", "does not resolve"])
    }

    // MARK: - Tunnel rules

    @Test("dangling tunnel endpoints are hard errors naming the id")
    func danglingTunnelEndpoints() {
        expectParseError(
            seed(tunnels: #"[{"from": "r9", "to": "r1", "kind": "references"}]"#),
            contains: ["tunnel[0]", "from", "\"r9\"", "does not resolve"])
        expectParseError(
            seed(tunnels: #"[{"from": "r1", "to": "r8", "kind": "references"}]"#),
            contains: ["tunnel[0]", "to", "\"r8\"", "does not resolve"])
    }

    @Test("unknown tunnel kind is a hard error listing the closed vocabulary")
    func badTunnelKind() {
        expectParseError(
            seed(tunnels: #"[{"from": "r1", "to": "r1", "kind": "links"}]"#),
            contains: ["tunnel[0]", "kind", "links", "references"])
    }

    // MARK: - Budget ceilings

    @Test("row ceiling: records+facts+tunnels beyond the limit is a hard error")
    func rowCeiling() {
        var limits = JsonImportLimits.default
        limits.maxRows = 2
        expectParseError(
            seed(records: """
                [{"id": "r1", "content": "a", "event_time": "2026-01-01T00:00:00Z", "room": "rm"},
                 {"id": "r2", "content": "b", "event_time": "2026-01-01T00:00:00Z", "room": "rm"},
                 {"id": "r3", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm"}]
                """),
            limits: limits,
            contains: ["row ceiling", "3", "2"])
    }

    @Test("byte ceiling: an oversized document is a hard error before decode")
    func byteCeiling() {
        var limits = JsonImportLimits.default
        limits.maxSeedFileBytes = 16
        expectParseError(seed(), limits: limits, contains: ["byte ceiling", "16"])
    }
}

// Part 2 — phase 3 (strict-append collision assertion) and phase 4 (pure
// frame build in file order).
@Suite("JsonImportBridge strict append + frame build")
struct JsonImportPipelineTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "jsonimportbridge-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    private func fixtureFile() throws -> JsonSeedFile {
        let data = try Data(contentsOf: JsonImportBridgeTests.fixtureSeedURL)
        return try JsonSeedFile.parse(data: data, limits: .default)
    }

    // MARK: - Phase 3: strict append

    @Test("strict append passes when no file lineage exists in the estate")
    func strictAppendFreshEstate() throws {
        let file = try fixtureFile()
        try JsonImportBridge.assertStrictAppend(file: file, occupied: [])
    }

    @Test("lineage collision is a hard error naming the first colliding record")
    func strictAppendNamesFirstCollision() throws {
        let file = try fixtureFile()
        // Occupy r0002 and r0003 — the FIRST in file order (r0002) must be named.
        let occupied: Set<UUID> = [
            DrawerMapping.lineageID(forStableSourceKey: "r0002"),
            DrawerMapping.lineageID(forStableSourceKey: "r0003"),
        ]
        do {
            try JsonImportBridge.assertStrictAppend(file: file, occupied: occupied)
            Issue.record("expected lineage-collision error; assertion passed")
        } catch let VaultKitError.adapterError(message) {
            #expect(message.contains("record[1]"), "first colliding record in file order; got: \(message)")
            #expect(message.contains("\"r0002\""), "colliding id must be named; got: \(message)")
            #expect(message.contains("lineage collision"), "got: \(message)")
        }
    }

    @Test("occupied snapshot covers active AND withdrawn lineages")
    func occupiedCoversActiveAndWithdrawn() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = JsonImportBridge(kit: kit)

        // Active drawer at r0001's lineage.
        let activeDrawer = try await kit.capture(handle, CaptureFrame(
            content: "occupies r0001",
            channel: .importedFile,
            room: "rm",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "test",
            embeddingModelID: "no-embedding",
            lineageID: DrawerMapping.lineageID(forStableSourceKey: "r0001")))

        // Withdrawn drawer at r0002's lineage.
        let withdrawnDrawer = try await kit.capture(handle, CaptureFrame(
            content: "occupies r0002",
            channel: .importedFile,
            room: "rm",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "test",
            embeddingModelID: "no-embedding",
            lineageID: DrawerMapping.lineageID(forStableSourceKey: "r0002")))
        try await kit.withdraw(handle, WithdrawFrame(
            rowID: withdrawnDrawer.id, reason: "test-withdrawal"))

        let occupied = try await bridge.occupiedLineageIDs(handle: handle)
        #expect(occupied.contains(activeDrawer.lineageID))
        #expect(occupied.contains(withdrawnDrawer.lineageID))

        // And the fixture file collides on record[0] (id r0001).
        let file = try fixtureFile()
        do {
            try JsonImportBridge.assertStrictAppend(file: file, occupied: occupied)
            Issue.record("expected lineage-collision error against the estate snapshot")
        } catch let VaultKitError.adapterError(message) {
            #expect(message.contains("record[0]"), "got: \(message)")
            #expect(message.contains("\"r0001\""), "got: \(message)")
        }
    }

    // MARK: - Phase 4: pure frame build

    @Test("frame build is deterministic, file-ordered, and explicit-lineage")
    func frameBuildDeterministic() throws {
        let file = try fixtureFile()
        let first = JsonImportBridge.buildFrames(file: file, defaultWing: nil)
        let second = JsonImportBridge.buildFrames(file: file, defaultWing: nil)

        #expect(first.count == 3)
        // Field-by-field determinism (CaptureFrame is not Equatable).
        for (a, b) in zip(first, second) {
            #expect(a.content == b.content)
            #expect(a.lineageID == b.lineageID)
            #expect(a.eventTime == b.eventTime)
            #expect(a.wing == b.wing)
            #expect(a.room == b.room)
            #expect(a.kind == b.kind)
            #expect(a.sensitivity == b.sensitivity)
            #expect(a.exportability == b.exportability)
        }
        // File order, not sorted: r0001, r0002, r0003.
        let expectedLineages = ["r0001", "r0002", "r0003"]
            .map { DrawerMapping.lineageID(forStableSourceKey: $0) }
        #expect(first.map(\.lineageID) == expectedLineages)
        // Explicit event times ride through (no `now` in frames).
        #expect(first[0].eventTime == ISO8601DateFormatter().date(from: "2026-01-03T09:00:00Z"))
        // Sentinel UDC anchor exactly as buildChromaFrame: "000".
        #expect(first.allSatisfy { $0.latticeAnchor.udcCode == "000" })
        // Import provenance stamped.
        #expect(first.allSatisfy { $0.channel == .importedFile })
        #expect(first.allSatisfy { $0.provenanceChannel == .fileImport })
        #expect(first.allSatisfy { $0.sourceType == .imported })
    }

    @Test("default wing fills only records that omit wing")
    func frameBuildDefaultWing() throws {
        let file = try fixtureFile()
        let frames = JsonImportBridge.buildFrames(file: file, defaultWing: "SeedWing")
        // r0001 and r0003 carry explicit "Benchmark"; r0002 omits wing.
        #expect(frames[0].wing == "Benchmark")
        #expect(frames[1].wing == "SeedWing")
        #expect(frames[2].wing == "Benchmark")

        // With no default wing, the omitted record's frame carries nil
        // (the estate default wing applies at capture).
        let bare = JsonImportBridge.buildFrames(file: file, defaultWing: nil)
        #expect(bare[1].wing == nil)
    }
}
