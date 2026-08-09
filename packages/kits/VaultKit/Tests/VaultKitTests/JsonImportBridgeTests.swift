import Testing
import Foundation
import CryptoKit
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

    @Test("secret + public is rejected in total validation (I-22)")
    func secretPublicRejected() {
        // The storage gate refuses secret+public on every write; the
        // validator must reject it BEFORE any window commits, or a
        // multi-window seed could land partially.
        expectParseError(
            seed(records: #"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm", "sensitivity": "secret", "exportability": "public"}]"#),
            contains: ["record[0]", "\"r1\"", "public", "secret", "I-22"])
        // secret + private (default) remains valid.
        #expect(throws: Never.self) {
            _ = try parse(seed(records: #"[{"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm", "sensitivity": "secret"}]"#))
        }
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

// Part 3 — phase 5 (windowed bulk write) and phase 6 (relationship pass).
@Suite("JsonImportBridge import pipeline (write + relationships)")
struct JsonImportWriteTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "jsonimportbridge-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// Write a seed JSON string to a temp file and return its URL.
    private func tempSeedFile(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonimport-test-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    @Test("fixture seed lands with exact drawer/fact/tunnel counts")
    func fixtureRoundTrip() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = JsonImportBridge(kit: kit)
        let now = Date()

        let report = try await bridge.importSeed(
            at: JsonImportBridgeTests.fixtureSeedURL, into: handle, now: now)

        #expect(report.seedName == "fixture-valid-seed")
        #expect(report.drawersWritten == 3)
        #expect(report.factsWritten == 2)
        #expect(report.tunnelsCreated == 2)

        // Drawers landed with explicit event times (not `now`).
        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .full, limit: 100))
        #expect(drawers.count == 3)
        let r1 = try #require(drawers.first {
            $0.lineageID == DrawerMapping.lineageID(forStableSourceKey: "r0001")
        })
        #expect(r1.eventTime == ISO8601DateFormatter().date(from: "2026-01-03T09:00:00Z"))

        // Facts landed anchored to their records' drawers.
        let facts = try await kit.recallKGFacts(handle)
        #expect(facts.count == 2)
        let thursday = try #require(facts.first { $0.object == "Thursday" })
        #expect(thursday.sourceDrawerID == r1.id)
        #expect(thursday.subject == "planning meeting")

        // Tunnels landed with drawer endpoints and the generated default
        // label for the unlabeled one. The unlabeled tunnel's source is
        // r0002, which omits `wing` and therefore lands in the estate
        // DEFAULT wing — resolve it rather than assuming a name.
        let estate = try await kit.estate(for: handle)
        let r2 = try #require(drawers.first {
            $0.lineageID == DrawerMapping.lineageID(forStableSourceKey: "r0002")
        })
        let r2Names = try await estate.resolveNodeNames(parentNodeIds: [r2.parentNodeId])
        let defaultWingName = try #require(r2Names[r2.parentNodeId]?.wing)

        let benchmarkTunnels = try await kit.recallTunnels(handle, wing: "Benchmark")
        #expect(benchmarkTunnels.contains { $0.kind == .supersedes && $0.label == "reschedule chain" })
        let defaultWingTunnels = try await kit.recallTunnels(handle, wing: defaultWingName)
        #expect(defaultWingTunnels.contains {
            $0.kind == .references
                && $0.label == "\(defaultWingName)/supersession/chains -> Benchmark/supersession/chains"
        })
    }

    @Test("a seed spanning two write windows commits both windows")
    func twoWindowWrite() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = JsonImportBridge(kit: kit)

        // 5 records at an internal window size of 2 → 3 windows (2+2+1).
        let records = (1...5).map {
            #"{"id": "w\#($0)", "content": "window record \#($0)", "event_time": "2026-01-01T00:00:0\#($0)Z", "room": "rm"}"#
        }.joined(separator: ",")
        let url = try tempSeedFile(
            #"{"format_version": 1, "name": "two-window", "records": [\#(records)]}"#)
        defer { try? FileManager.default.removeItem(at: url) }

        let report = try await bridge.importSeed(
            at: url, into: handle, defaultWing: nil, now: Date(),
            progress: nil, mode: .foreground, windowSize: 2)

        #expect(report.drawersWritten == 5)
        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured, limit: 100))
        #expect(drawers.count == 5)
    }

    @Test("default wing routes records that omit wing")
    func defaultWingApplied() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = JsonImportBridge(kit: kit)

        _ = try await bridge.importSeed(
            at: JsonImportBridgeTests.fixtureSeedURL, into: handle,
            defaultWing: "SeedWing", now: Date())

        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured, limit: 100))
        let r2 = try #require(drawers.first {
            $0.lineageID == DrawerMapping.lineageID(forStableSourceKey: "r0002")
        })
        let estate = try await kit.estate(for: handle)
        let names = try await estate.resolveNodeNames(parentNodeIds: [r2.parentNodeId])
        #expect(names[r2.parentNodeId]?.wing == "SeedWing")
    }

    @Test("lineage collision performs ZERO writes — never a partial estate")
    func zeroWritesOnCollision() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = JsonImportBridge(kit: kit)

        // Occupy r0002's lineage before the import.
        _ = try await kit.capture(handle, CaptureFrame(
            content: "occupies r0002",
            channel: .importedFile,
            room: "rm",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "test",
            embeddingModelID: "no-embedding",
            lineageID: DrawerMapping.lineageID(forStableSourceKey: "r0002")))

        do {
            _ = try await bridge.importSeed(
                at: JsonImportBridgeTests.fixtureSeedURL, into: handle, now: Date())
            Issue.record("expected lineage-collision error")
        } catch let VaultKitError.adapterError(message) {
            #expect(message.contains("\"r0002\""), "got: \(message)")
        }

        // ZERO writes: only the pre-existing drawer, no facts, no tunnels.
        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured, limit: 100))
        #expect(drawers.count == 1)
        let facts = try await kit.recallKGFacts(handle)
        #expect(facts.isEmpty)
        let tunnels = try await kit.recallTunnels(handle, wing: "Benchmark")
        #expect(tunnels.isEmpty)
    }

    @Test("an invalid seed file performs ZERO writes")
    func zeroWritesOnInvalidFile() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = JsonImportBridge(kit: kit)

        // Valid JSON, invalid schema (dangling tunnel endpoint) — the
        // validator must reject BEFORE any estate work.
        let url = try tempSeedFile("""
            {"format_version": 1, "name": "bad", "records": [
              {"id": "r1", "content": "c", "event_time": "2026-01-01T00:00:00Z", "room": "rm"}],
             "tunnels": [{"from": "r1", "to": "r999", "kind": "references"}]}
            """)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await bridge.importSeed(at: url, into: handle, now: Date())
            Issue.record("expected validation error")
        } catch let VaultKitError.adapterError(message) {
            #expect(message.contains("\"r999\""), "got: \(message)")
        }

        let drawers = try await kit.recall(
            handle,
            RecallFrame(filterChain: [.unconfirmed], hydrationLevel: .structured, limit: 100))
        #expect(drawers.isEmpty)
    }
}

// Part 4 — phase 7 (deferred encode enqueue) and phase 8 (digest-bearing
// audit receipt).
@Suite("JsonImportBridge enqueue + receipt")
struct JsonImportReceiptTests {

    private func openEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "jsonimportbridge-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        _ = try await LocusKit.Estate.create(storage: storage, owner: owner)
        let handle = try await kit.open(storage: storage, owner: owner)
        return (kit, handle)
    }

    /// Provisioned estate (Corpus mounted, deterministic embedding model)
    /// so `reindexMissing` can enqueue — same helper shape as
    /// `VaultBridgeTests.openProvisionedEstate`.
    private func openProvisionedEstate() async throws -> (GeniusLocusKit, EstateHandle) {
        let kit = GeniusLocusKit()
        let owner = OwnerCredentials(ownerIdentifier: "jsonimport-encode-tests")
        let storage = InMemoryStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .inMemory))
        let params = EstateProvisionParams(
            estateName: "JsonImport Encode Test Estate",
            kind: .glk,
            zoomWindowLow: 1,
            zoomWindowHigh: 10,
            frameworkProfile: "KnowledgeWork",
            syncMode: .none
        )
        let handle = try await kit.provision(
            storage: storage, owner: owner, params: params,
            embeddingModels: [.deterministic]
        )
        return (kit, handle)
    }

    @Test("receipt carries the seed digest and the exact counts")
    func receiptWithDigest() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = JsonImportBridge(kit: kit)
        let now = Date()

        let report = try await bridge.importSeed(
            at: JsonImportBridgeTests.fixtureSeedURL, into: handle, now: now)

        // Digest is the SHA-256 of the exact input bytes.
        let data = try Data(contentsOf: JsonImportBridgeTests.fixtureSeedURL)
        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(report.seedSha256 == expected)

        // One receipt in the diary, in the established receipt shape plus
        // seedSha256.
        let receipts = try await kit.readDiaryEntries(
            in: handle, agentName: VaultBridge.receiptAgentName)
        #expect(receipts.count == 1)
        let receipt = try #require(receipts.first)
        #expect(receipt.topic == "vault-receipt")
        #expect(receipt.filedAt == now)
        #expect(receipt.entry.contains(#""operation":"json-import""#))
        #expect(receipt.entry.contains(#""seedName":"fixture-valid-seed""#))
        #expect(receipt.entry.contains(#""drawersWritten":3"#))
        #expect(receipt.entry.contains(#""factsWritten":2"#))
        #expect(receipt.entry.contains(#""tunnelsCreated":2"#))
        #expect(receipt.entry.contains(#""seedSha256":"\#(expected)""#))
    }

    @Test("a failed import files NO receipt (zero writes includes the diary)")
    func noReceiptOnFailure() async throws {
        let (kit, handle) = try await openEstate()
        let bridge = JsonImportBridge(kit: kit)

        // Occupy r0001's lineage so the strict-append assertion fires.
        _ = try await kit.capture(handle, CaptureFrame(
            content: "occupies r0001",
            channel: .importedFile,
            room: "rm",
            latticeAnchor: LatticeAnchor(udcCode: "000"),
            addedBy: "test",
            embeddingModelID: "no-embedding",
            lineageID: DrawerMapping.lineageID(forStableSourceKey: "r0001")))

        _ = try? await bridge.importSeed(
            at: JsonImportBridgeTests.fixtureSeedURL, into: handle, now: Date())

        let receipts = try await kit.readDiaryEntries(
            in: handle, agentName: VaultBridge.receiptAgentName)
        #expect(receipts.isEmpty)
    }

    @Test("import into a provisioned estate enqueues every record for encode")
    func enqueueReachesRecordCount() async throws {
        let (kit, handle) = try await openProvisionedEstate()
        let bridge = JsonImportBridge(kit: kit)

        let report = try await bridge.importSeed(
            at: JsonImportBridgeTests.fixtureSeedURL, into: handle, now: Date())

        // Every imported record is enqueued; reindexMissing's internal
        // drain polling means the encode work has settled by return, so
        // the enqueued count IS the encoded-drawer count for this seed.
        #expect(report.enqueuedForEncode == 3,
                "all 3 records must be enqueued for encode; got \(report.enqueuedForEncode)")
    }
}
