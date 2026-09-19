import Foundation
import Testing
@testable import mcp_benchmarker

// SeedPathTests.swift — batch-seeding coverage (MXE-JI-2, subject MXE-JI-4).
//
// Two surfaces under test, all pure (no live estate):
//   1. The shared schema-v1.1 seed-file emitter (SeedExport.swift): byte-exact,
//      key-sorted, deterministic output — the dump contract. Schema v1.1 always
//      emits "subject" (computed from content via deterministicSubject). The
//      emitter is the single seam every converted runner and `--dump-seed` goes
//      through, and its bytes are pinned cross-port by
//      conformance/seed_export_vectors.json (the Rust twin drives the same
//      vector file from seed_export.rs).
//   2. Per-runner seed builders (supersessionSeedRecords): the pure corpus →
//      seed-record projection each converted lane feeds the emitter.

/// Resolves `benchmarks/conformance/<filename>` from this file.
private func seedConformancePath(_ filename: String,
                                 file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()   // mcp-benchmarkerTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // package root
        .appendingPathComponent("conformance")
        .appendingPathComponent(filename)
}

@Suite("Seed emitter (schema v1.1)")
struct SeedEmitterTests {

    private func sampleRecords() -> [SeedFileRecord] {
        [
            SeedFileRecord(
                id: "r0001",
                content: "Line one.\nLine \"two\" with a tab\there.",
                eventTime: "2026-01-03T09:00:00Z",
                room: "supersession/color"),
            SeedFileRecord(
                id: "r0002",
                content: "Ünïcode → stays UTF-8 verbatim.",
                eventTime: "2026-01-04T10:30:00Z",
                room: "supersession/color",
                wing: "Benchmark",
                kind: "prose",
                sensitivity: "normal",
                exportability: "private"),
        ]
    }

    @Test("emission is byte-deterministic")
    func deterministic() throws {
        let a = emitSeedJSON(name: "det-check", records: sampleRecords())
        let b = emitSeedJSON(name: "det-check", records: sampleRecords())
        #expect(a == b)
    }

    @Test("object keys are ASCII-sorted and optional keys are omitted")
    func keyOrderAndOmission() throws {
        let data = emitSeedJSON(name: "keys", records: sampleRecords())
        let text = try #require(String(data: data, encoding: .utf8))
        // Top level: format_version < name < records. The emitter writes
        // records only — the importer's facts/tunnels sections are authored
        // by the Python seeders, never by this emitter.
        let fv = try #require(text.range(of: "\"format_version\""))
        let nm = try #require(text.range(of: "\"name\""))
        let rc = try #require(text.range(of: "\"records\""))
        #expect(fv.lowerBound < nm.lowerBound)
        #expect(nm.lowerBound < rc.lowerBound)
        #expect(!text.contains("\"facts\""))
        #expect(!text.contains("\"tunnels\""))
        // Record keys: content < event_time < id < room (r0001 has no optionals).
        let ct = try #require(text.range(of: "\"content\""))
        let et = try #require(text.range(of: "\"event_time\""))
        let id = try #require(text.range(of: "\"id\""))
        let rm = try #require(text.range(of: "\"room\""))
        #expect(ct.lowerBound < et.lowerBound)
        #expect(et.lowerBound < id.lowerBound)
        #expect(id.lowerBound < rm.lowerBound)
        // Schema v1.1: subject always emitted on both records. ASCII order:
        // room < sensitivity? < subject < wing?
        // Use the FIRST occurrence of each key (r0001's range) for ordering.
        let subj = try #require(text.range(of: "\"subject\""))
        #expect(rm.lowerBound < subj.lowerBound, "room must precede subject")
        // subject appears in BOTH records (always emitted); wing appears only
        // in r0002 (wing < r0002's subject), so find the LAST subject range.
        let components = text.components(separatedBy: "\"subject\"")
        #expect(components.count == 3, "subject must appear exactly twice (one per record)")
        // r0001 carries no kind/sensitivity/exportability/wing keys; r0002
        // carries all four — so each optional key appears exactly once.
        for key in ["\"kind\"", "\"sensitivity\"", "\"exportability\"", "\"wing\""] {
            #expect(text.components(separatedBy: key).count == 2,
                    "optional key \(key) must appear exactly once (r0002 only)")
        }
        // Wing follows subject in r0002 (subject < wing in ASCII).
        let wing = try #require(text.range(of: "\"wing\""))
        #expect(subj.lowerBound < wing.lowerBound, "subject must precede wing")
    }

    @Test("string escaping matches the cross-port contract")
    func escaping() throws {
        let record = SeedFileRecord(
            id: "esc",
            content: "quote:\" backslash:\\ newline:\n tab:\t cr:\r unit:\u{1F}",
            eventTime: "2026-01-01T00:00:00Z",
            room: "esc")
        let data = emitSeedJSON(name: "esc", records: [record])
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains(#"quote:\" backslash:\\ newline:\n tab:\t cr:\r unit:\u001f"#))
        // Round-trips through a strict JSON parser back to the exact content.
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try #require(parsed["records"] as? [[String: Any]])
        #expect(records[0]["content"] as? String == record.content)
    }

    @Test("committed conformance vectors match emission byte-for-byte")
    func conformanceVectors() throws {
        let url = seedConformancePath("seed_export_vectors.json")
        let raw = try Data(contentsOf: url)
        let parsed = try #require(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let cases = try #require(parsed["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)
        for c in cases {
            let id = try #require(c["id"] as? String)
            let name = try #require(c["name"] as? String)
            let recs = try #require(c["records"] as? [[String: Any]]).map {
                SeedFileRecord(
                    id: $0["id"] as! String,
                    content: $0["content"] as! String,
                    eventTime: $0["event_time"] as! String,
                    room: $0["room"] as! String,
                    wing: $0["wing"] as? String,
                    kind: $0["kind"] as? String,
                    sensitivity: $0["sensitivity"] as? String,
                    exportability: $0["exportability"] as? String)
            }
            let expected = try #require(c["expected_json"] as? String)
            let got = String(data: emitSeedJSON(name: name, records: recs),
                             encoding: .utf8)
            #expect(got == expected, "vector case '\(id)' emission drifted")
        }
    }
}

@Suite("Supersession seed builder")
struct SupersessionSeedBuilderTests {

    @Test("corpus records project to seed records in given order")
    func projection() throws {
        let corpus = generateSupersessionCorpus(
            seed: 20260725, entityCount: 3, versionsPerChain: 2,
            contradictionCount: 1, divergenceCount: 0, decoyCount: 0)
        let ordered = corpus.records.sorted {
            ($0.eventTime, $0.id) < ($1.eventTime, $1.id)
        }
        let seeds = supersessionSeedRecords(from: ordered)
        #expect(seeds.count == ordered.count)
        for (seed, record) in zip(seeds, ordered) {
            #expect(seed.id == record.id)
            #expect(seed.content == record.content)
            #expect(seed.eventTime == record.eventTime)
            #expect(seed.room == "supersession/" + record.attribute)
            // Wing omitted: batch import must land in the same default wing
            // ("Agentic Memory") the live moot_file_memory path uses.
            #expect(seed.wing == nil)
        }
    }

    @Test("seed record ids are unique (strict-append precondition)")
    func uniqueIDs() throws {
        let corpus = generateSupersessionCorpus(
            seed: 20260725, entityCount: 5, versionsPerChain: 3,
            contradictionCount: 2, divergenceCount: 2, decoyCount: 2)
        let seeds = supersessionSeedRecords(from: corpus.records)
        #expect(Set(seeds.map(\.id)).count == seeds.count)
    }
}

// MARK: - LMEB seed builder

@Suite("LMEB seed builder")
struct LMEBSeedBuilderTests {

    /// Minimal in-memory LMEB corpus with 3 docs.
    private func makeCorpus() -> (LMEBCorpus, [String]) {
        let docs: [LMEBDoc] = [
            LMEBDoc(id: "doc-A", text: "Content of doc A.", title: "Doc A"),
            LMEBDoc(id: "doc-B", text: "Content of doc B.", title: "Doc B"),
            LMEBDoc(id: "doc-C", text: "Content of doc C.", title: "Doc C"),
        ]
        let byID = Dictionary(uniqueKeysWithValues: docs.map { ($0.id, $0) })
        let corpus = LMEBCorpus(
            docsByID: byID,
            queriesByID: [:],
            candidatesBySceneID: [:],
            relevantDocsByQueryID: [:]
        )
        return (corpus, docs.map(\.id))
    }

    @Test("records emit in candidateDocIDs order")
    func order() throws {
        let (corpus, ids) = makeCorpus()
        let records = lmebSeedRecords(candidateDocIDs: ids, corpus: corpus)
        #expect(records.count == 3)
        #expect(records[0].id == "doc-A")
        #expect(records[1].id == "doc-B")
        #expect(records[2].id == "doc-C")
    }

    @Test("content mirrors doc.text verbatim")
    func content() throws {
        let (corpus, ids) = makeCorpus()
        let records = lmebSeedRecords(candidateDocIDs: ids, corpus: corpus)
        #expect(records[0].content == "Content of doc A.")
        #expect(records[1].content == "Content of doc B.")
        #expect(records[2].content == "Content of doc C.")
    }

    @Test("room is the LMEB location constant on every record")
    func room() throws {
        let (corpus, ids) = makeCorpus()
        let records = lmebSeedRecords(candidateDocIDs: ids, corpus: corpus)
        for rec in records { #expect(rec.room == "benchmarks/lmeb") }
    }

    @Test("record IDs are unique (doc IDs are the record IDs)")
    func uniqueIDs() throws {
        let (corpus, ids) = makeCorpus()
        let records = lmebSeedRecords(candidateDocIDs: ids, corpus: corpus)
        #expect(Set(records.map(\.id)).count == records.count)
    }

    @Test("event times are unique and start at the base")
    func eventTimesUnique() throws {
        let (corpus, ids) = makeCorpus()
        let records = lmebSeedRecords(candidateDocIDs: ids, corpus: corpus)
        let times = records.map(\.eventTime)
        #expect(Set(times).count == times.count)
        #expect(times[0] == "2026-01-01T00:00:00Z")
    }

    @Test("wing is nil (records land in default Agentic Memory wing)")
    func wingNil() throws {
        let (corpus, ids) = makeCorpus()
        let records = lmebSeedRecords(candidateDocIDs: ids, corpus: corpus)
        for rec in records { #expect(rec.wing == nil) }
    }

    @Test("docs absent from corpus are silently skipped")
    func missingDocSkipped() throws {
        let (corpus, ids) = makeCorpus()
        let withMissing = ids + ["doc-MISSING"]
        let records = lmebSeedRecords(candidateDocIDs: withMissing, corpus: corpus)
        // Only 3 real docs; missing is skipped.
        #expect(records.count == 3)
        #expect(!records.map(\.id).contains("doc-MISSING"))
    }
}


// MARK: - Gauntlet seed builder

/// Minimal fixture: three records with distinct ids, contents, and per-record
/// locations (the T5-scatter pattern — each record files into its own room).
private func makeGauntletRecords() -> [GauntletRecord] {
    [
        GauntletRecord(id: "n0001", content: "The fox jumps",
                       location: "gauntlet/T1/n0001", tier: .lexical, role: .needle, needleID: "n0001"),
        GauntletRecord(id: "n0001-d1", content: "A distractor sentence",
                       location: "gauntlet/T1/n0001-d1", tier: .lexical, role: .distractor, needleID: "n0001"),
        GauntletRecord(id: "n0002", content: "Second needle text",
                       location: "gauntlet/T5/n0002", tier: .scatter, role: .needle, needleID: "n0002"),
    ]
}

@Suite("Gauntlet seed builder")
struct GauntletSeedBuilderTests {

    @Test("count equals corpus record count")
    func recordCount() throws {
        let runner = makeGauntletRunner()
        let records = runner.gauntletSeedRecords(from: makeGauntletRecords())
        #expect(records.count == 3)
    }

    @Test("IDs match corpus record ids in corpus order")
    func recordIDs() throws {
        let runner = makeGauntletRunner()
        let records = runner.gauntletSeedRecords(from: makeGauntletRecords())
        #expect(records.map(\.id) == ["n0001", "n0001-d1", "n0002"])
    }

    @Test("content matches corpus record content verbatim")
    func recordContent() throws {
        let runner = makeGauntletRunner()
        let records = runner.gauntletSeedRecords(from: makeGauntletRecords())
        #expect(records[0].content == "The fox jumps")
        #expect(records[1].content == "A distractor sentence")
        #expect(records[2].content == "Second needle text")
    }

    @Test("room is the record's location string verbatim (per-record T5 scatter)")
    func recordRoom() throws {
        let runner = makeGauntletRunner()
        let records = runner.gauntletSeedRecords(from: makeGauntletRecords())
        #expect(records[0].room == "gauntlet/T1/n0001")
        #expect(records[1].room == "gauntlet/T1/n0001-d1")
        #expect(records[2].room == "gauntlet/T5/n0002")
    }

    @Test("wing is omitted (nil) so import defaults to Agentic Memory")
    func recordWing() throws {
        let runner = makeGauntletRunner()
        let records = runner.gauntletSeedRecords(from: makeGauntletRecords())
        for rec in records { #expect(rec.wing == nil) }
    }

    @Test("event_times are unique, start at base epoch, all precede dreamInstant")
    func recordEventTimes() throws {
        let runner = makeGauntletRunner()
        let records = runner.gauntletSeedRecords(from: makeGauntletRecords())
        let times = records.map(\.eventTime)
        // All unique (required for attribution).
        #expect(Set(times).count == times.count)
        // First record anchors at 2026-01-01T00:00:00Z (syntheticEventTime offset 0).
        #expect(times[0] == "2026-01-01T00:00:00Z")
        // Monotone increasing (+1s per record).
        #expect(times[1] == "2026-01-01T00:00:01Z")
        #expect(times[2] == "2026-01-01T00:00:02Z")
        // All times precede the fixed dream instant (2026-06-11T00:00:00Z).
        for t in times { #expect(t < GauntletRunner.dreamInstant) }
    }

    @Test("empty corpus yields empty records")
    func emptyCorpus() throws {
        let runner = makeGauntletRunner()
        let records = runner.gauntletSeedRecords(from: [])
        #expect(records.isEmpty)
    }
}

/// Builds a minimal GauntletRunner for unit-testing the seed builder.
/// Uses a stub MCPClient with a placeholder endpoint; the runner is never
/// called to `run()` in these tests — only `gauntletSeedRecords` is exercised.
private func makeGauntletRunner() -> GauntletRunner {
    // A no-op corpus and scorer so the runner struct can be initialised.
    let corpus = GauntletCorpus(
        seed: 0, records: [], needles: [], tierCounts: [:], distractorsPerNeedle: 0)
    let scorer = GauntletScorer(kValues: [1])
    // The endpoint is never connected in these tests; any stdio string works.
    let endpoint = EndpointConfig(
        name: "stub",
        transport: .stdio(command: "echo stub"),
        auth: nil,
        verbMap: EndpointConfig.VerbMap(
            write: "moot_file_memory", query: "moot_memory_search",
            list: nil,
            contentArg: "content", queryArg: "query",
            constantArgs: [:], resultFormat: .mootText),
        role: .both)
    let client = MCPClient(endpoint: endpoint)
    return GauntletRunner(
        moot: client, mootVerbs: endpoint.verbMap,
        corpus: corpus, scorer: scorer, runLabel: "test",
        seedPath: .batch, scratchDir: nil)
}

// MARK: - Lane capture tests

/// Tests for the --lane-capture flag's parsing and diff logic.
///
/// All tests are pure-logic and require no binary, no estate, and no network.
/// The fixture tests pin the RecallExplainer output format so a product format
/// change fails loudly here instead of silently capturing zeros.
@Suite("Lane capture")
struct LaneCaptureTests {

    // ── Test 1: parseLaneCaptureLines — fixture for RecallExplainer format ─

    /// Asserts that `parseLaneCaptureLines` correctly parses the verbatim
    /// RecallExplainer output format (RecallExplainer.swift:8-11).
    ///
    /// This is a format-pinning fixture: if the product changes the `score:`
    /// line format, this test fails loudly instead of silently capturing zeros.
    @Test("parseLaneCaptureLines parses verbatim RecallExplainer score lines")
    func parseLaneCaptureLinesParsesScoreLines() throws {
        // Verbatim RecallExplainer output for two hits in one recall response.
        // Format: UUID line, then sources, score, mode, why (4 lines per hit).
        let explainText = """
            A1B2C3D4-E5F6-7890-ABCD-EF1234567890  [test/room]  content A
            sources: locusBitmap, corpusBM25
            score: locus=0.82 bm25=0.71 fieldFit=0.44
            mode: unionBest | scoring: matrixAware
            why: content query; BM25 and vector weighted high
            B2C3D4E5-F6A7-8901-BCDE-F12345678901  [test/room]  content B
            sources: corpusBM25
            score: bm25=0.55 vector=0.33
            mode: unionBest | scoring: matrixAware
            why: content query; BM25 and vector weighted high
            """

        let snapshot = parseLaneCaptureLines(
            [explainText], queryID: "q-fixture", timestamp: "2026-08-09T00:00:00Z")

        #expect(snapshot.queryID == "q-fixture")
        #expect(snapshot.hitScores.count == 2,
                "two UUID lines must produce two HitLaneScores; got \(snapshot.hitScores.count)")

        let h0 = snapshot.hitScores[0]
        #expect(h0.locus    == 0.82, "hit 0 locus must be 0.82; got \(h0.locus)")
        #expect(h0.bm25     == 0.71, "hit 0 bm25 must be 0.71; got \(h0.bm25)")
        #expect(h0.fieldFit == 0.44, "hit 0 fieldFit must be 0.44; got \(h0.fieldFit)")
        #expect(h0.vector   == 0.0,  "hit 0 vector must be 0.0 (absent); got \(h0.vector)")

        let h1 = snapshot.hitScores[1]
        #expect(h1.bm25   == 0.55, "hit 1 bm25 must be 0.55; got \(h1.bm25)")
        #expect(h1.vector == 0.33, "hit 1 vector must be 0.33; got \(h1.vector)")
        #expect(h1.locus  == 0.0,  "hit 1 locus must be 0.0 (absent); got \(h1.locus)")
    }

    // ── Test 2: parseScoreTokens — all nine lanes ──────────────────────────

    @Test("parseScoreTokens parses all nine RecallExplainer lane names")
    func parseScoreTokensParsesAllNineLanes() throws {
        let tokens = "locus=0.10 bm25=0.20 vector=0.30 dense=0.40 "
                   + "fieldFit=0.50 coOccurrence=0.60 temporal=0.70 "
                   + "graph=0.80 preference=0.90"
        let s = parseScoreTokens(tokens)
        #expect(s.locus        == 0.10)
        #expect(s.bm25         == 0.20)
        #expect(s.vector       == 0.30)
        #expect(s.dense        == 0.40)
        #expect(s.fieldFit     == 0.50)
        #expect(s.coOccurrence == 0.60)
        #expect(s.temporal     == 0.70)
        #expect(s.graph        == 0.80)
        #expect(s.preference   == 0.90)
    }

    // ── Test 3: parseScoreTokens — final= fallback ─────────────────────────

    @Test("parseScoreTokens handles the final= fallback and ignores unknown tokens")
    func parseScoreTokensIgnoresUnknownTokens() throws {
        // `final=` appears when all component scores are zero; unknown future
        // tokens are silently ignored for forward compatibility.
        let s = parseScoreTokens("final=0.55 futureToken=0.99")
        #expect(s.locus == 0.0, "locus absent from tokens must be 0.0")
        #expect(s.bm25  == 0.0, "bm25 absent from tokens must be 0.0")
    }

    // ── Test 4: parseLaneCaptureLines — empty text produces empty snapshot ─

    @Test("parseLaneCaptureLines with no UUID lines produces an empty snapshot")
    func parseLaneCaptureEmptyTextProducesEmptySnapshot() throws {
        let snapshot = parseLaneCaptureLines(
            ["no uuid lines here\nsources: whatever\nscore: bm25=0.5"],
            queryID: "q-empty", timestamp: "2026-08-09T00:00:00Z")
        #expect(snapshot.hitScores.isEmpty,
                "text without UUID-prefixed lines must produce empty hitScores")
    }

    // ── Test 5: diffLaneCaptures — identical captures produce zero delta ───

    @Test("diffLaneCaptures on identical captures produces zero delta for every lane")
    func diffLaneCapturesIdenticalProducesZero() throws {
        let snapshot = QueryLaneSnapshot(
            queryID: "q1",
            queryTimestamp: "2026-08-09T00:00:00Z",
            hitScores: [
                HitLaneScores(locus: 0.8, bm25: 0.6, vector: 0.0, dense: 0.0,
                              fieldFit: 0.4, coOccurrence: 0.0,
                              temporal: 0.0, graph: 0.0, preference: 0.0),
            ])
        let cap = LaneCapture(importTimestamp: "2026-08-09T00:00:00Z", snapshots: [snapshot])

        let diffs = diffLaneCaptures(baseline: cap, candidate: cap)
        for d in diffs {
            #expect(d.deltaAbs == 0.0,
                    "all lanes must have zero delta when comparing a capture to itself")
        }
    }

    // ── Test 6: diffLaneCaptures — single perturbed lane is reported ────────

    @Test("diffLaneCaptures reports exactly the lane whose mean differs")
    func diffLaneCapturesSinglePerturbedLaneReported() throws {
        func makeCapture(bm25: Double) -> LaneCapture {
            let snap = QueryLaneSnapshot(
                queryID: "q1",
                queryTimestamp: "2026-08-09T00:00:00Z",
                hitScores: [
                    HitLaneScores(locus: 0.5, bm25: bm25, vector: 0.0, dense: 0.0,
                                  fieldFit: 0.0, coOccurrence: 0.0,
                                  temporal: 0.0, graph: 0.0, preference: 0.0),
                ])
            return LaneCapture(importTimestamp: "2026-08-09T00:00:00Z", snapshots: [snap])
        }

        let cap1 = makeCapture(bm25: 0.70)
        let cap2 = makeCapture(bm25: 0.55)
        let diffs = diffLaneCaptures(baseline: cap1, candidate: cap2)

        // The bm25 lane must appear at the top (highest deltaAbs).
        #expect(!diffs.isEmpty, "at least one diff must be reported")
        #expect(diffs[0].laneName == "bm25",
                "bm25 must be the top-ranked diff lane; got '\(diffs[0].laneName)'")
        let bm25Diff = diffs.first { $0.laneName == "bm25" }
        #expect(bm25Diff?.deltaAbs != nil &&
                abs((bm25Diff?.deltaAbs ?? 0) - 0.15) < 1e-9,
                "bm25 delta must be 0.15; got \(String(describing: bm25Diff?.deltaAbs))")
        // locus must be zero-delta (same in both captures).
        let locusDiff = diffs.first { $0.laneName == "locus" }
        #expect(locusDiff?.deltaAbs == 0.0,
                "locus must have zero delta; got \(String(describing: locusDiff?.deltaAbs))")
    }

    // ── Test 7: renderLaneDiffTable — snapshot shape determinism ───────────

    @Test("renderLaneDiffTable produces a deterministic table for known inputs")
    func renderLaneDiffTableProducesDeterministicTable() throws {
        let snap = QueryLaneSnapshot(
            queryID: "q1",
            queryTimestamp: "2026-08-09T00:00:01Z",
            hitScores: [
                HitLaneScores(locus: 0.8, bm25: 0.6, vector: 0.0, dense: 0.0,
                              fieldFit: 0.4, coOccurrence: 0.0,
                              temporal: 0.0, graph: 0.0, preference: 0.0),
            ])
        let cap1 = LaneCapture(importTimestamp: "2026-08-09T00:00:00Z", snapshots: [snap])
        let snapB = QueryLaneSnapshot(
            queryID: "q1",
            queryTimestamp: "2026-08-09T00:01:00Z",
            hitScores: [
                HitLaneScores(locus: 0.8, bm25: 0.4, vector: 0.0, dense: 0.0,
                              fieldFit: 0.4, coOccurrence: 0.0,
                              temporal: 0.0, graph: 0.0, preference: 0.0),
            ])
        let cap2 = LaneCapture(importTimestamp: "2026-08-09T00:01:00Z", snapshots: [snapB])

        let diffs = diffLaneCaptures(baseline: cap1, candidate: cap2)
        let table = renderLaneDiffTable(
            baseline: cap1, candidate: cap2, diffs: diffs,
            label1: "run 1", label2: "run 2")

        #expect(table.contains("import timestamps"), "table must include timestamp header")
        #expect(table.contains("bm25"), "table must include bm25 lane row")
        #expect(table.contains("DRIFT"), "bm25 lane with delta 0.2 must show DRIFT")
        #expect(table.contains("locus"), "table must include locus lane row")
        // Rendering the same inputs twice must produce bit-identical output —
        // the table itself must be deterministic, not dependent on hash-map order.
        let table2 = renderLaneDiffTable(
            baseline: cap1, candidate: cap2, diffs: diffs,
            label1: "run 1", label2: "run 2")
        #expect(table == table2, "two renders of the same inputs must produce identical output")
    }
}

// MARK: - Seed file output hygiene (BM-01)

/// Regressions for BM-01: slash ID sanitization (Finding 1) and owner-only
/// seed-file permissions (Finding 2). Both tests are pure filesystem operations
/// that require no live estate or network.
@Suite("Seed file output hygiene")
struct SeedFileHygieneTests {

    // ── Finding 1 ─────────────────────────────────────────────────────────────

    /// MemBench item IDs contain slash characters (e.g. "FirstAgent/simple/roles/0").
    /// The runner must sanitize them to underscores before calling `writeSeedFile`
    /// so the resulting path stays flat inside the scratch directory.
    @Test("MemBench slash ID sanitizes to an underscore-separated flat filename")
    func memBenchSlashIDSanitizesToFlatFilename() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bm01-slash-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let slashID = "FirstAgent/simple/roles/0"
        let safeID  = slashID.replacingOccurrences(of: "/", with: "_")
        let data    = Data("{}".utf8)
        let url     = try writeSeedFile(data, in: dir, name: "membench-\(safeID)")

        // File must exist at the returned URL.
        #expect(FileManager.default.fileExists(atPath: url.path),
                "seed file must exist at the returned URL")
        // File must land directly in `dir` — compare resolved paths to handle
        // symlinked temp directories (e.g. /var → /private/var on macOS).
        let parentResolved = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let dirResolved    = dir.resolvingSymlinksInPath().path
        #expect(parentResolved == dirResolved,
                "writeSeedFile must produce a file directly in scratchDir")
        // The filename component must not contain a slash.
        #expect(!url.lastPathComponent.contains("/"),
                "sanitized filename must not contain path separators")
        // Slash characters must have been replaced by underscores.
        #expect(url.lastPathComponent.contains("FirstAgent_simple_roles_0"),
                "underscores must replace slashes in the filename")
    }

    // ── Finding 2 ─────────────────────────────────────────────────────────────

    /// Seed files hold benchmark corpus data that should not be world-readable
    /// while a run is in progress. `writeSeedFile` must create the file with
    /// 0o600 (owner-read/write only) permissions.
    @Test("writeSeedFile creates the seed file with owner-only (0o600) permissions")
    func writeSeedFileCreatesOwnerOnlyPermissions() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bm01-perm-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let data = Data("{\"test\":true}".utf8)
        let url  = try writeSeedFile(data, in: dir, name: "perm-test")

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let mode  = (attrs[.posixPermissions] as? Int) ?? 0
        #expect(mode == 0o600,
                "seed file must have 0o600 permissions; got 0o\(String(mode, radix: 8))")
    }
}

// MARK: - Estate cache seed-path keying (jh-closure)

@Suite("Estate cache seed-path keying")
struct EstateCacheSeedPathTests {

    // A live-built and a batch-built estate are different estate shapes
    // (subject debt, collapsed capture times — ledger L-3/L-4); the cache
    // key must never let one restore into a run expecting the other.
    @Test("live and batch estates get distinct cache entries")
    func distinctEntries() throws {
        func entry(_ mode: SeedPathMode) -> URL {
            estateCacheEntryURL(
                cacheDir: URL(fileURLWithPath: "/tmp/ec-test"),
                benchmark: "lme", variant: "", seed: 1,
                encodeBarrier: .drain,
                posture: .plaintextTransient,
                seedPath: mode, unitID: "q1")
        }
        #expect(entry(.live) != entry(.batch))
        #expect(entry(.batch).path.contains("seedpath_batch"))
    }
}
