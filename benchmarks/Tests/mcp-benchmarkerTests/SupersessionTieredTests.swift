import Foundation
import Testing
@testable import mcp_benchmarker

// SupersessionTieredTests — MXE-CT3 P4: the tiered-section parser, the
// per-tier planted scorers, the synthesis exactly-once check, and the decoy
// classifier.
//
// FIXTURE PROVENANCE. The tiered blocks below are hand-derived from the ONE
// shared renderer both report surfaces route through, and pinned line by
// line against its emitters:
//   Swift: packages/kits/AriaMcpKit/Sources/AriaMCP/RecipeTools.swift
//     tieredSectionLines (:1368-1424): headers :1384-1386, lane counts
//     :1390-1391, tier-1 PROVEN :1403-1405 + dense rows :1406-1408,
//     restricted arm :1398-1401, tier-2/3 findings :1410-1411, timing
//     :1418-1421.
//   Rust twin: packages/kits/AriaMcpKit/rust/src/recipe_tools.rs
//     tiered_section_lines (:291-388) — byte-identical formats.
// If the renderer changes, these fixtures are stale and MUST be re-derived.

// A synthesis-mode report: legacy sweep lines + typed conflict-projection
// section (both of which the tiered parser must ignore) followed by the
// tiered digest. The legacy prefix deliberately includes PROPOSED/CANDIDATE
// lines and a typed PROVEN block with dense rows to prove the parser starts
// at the first tier header, not before.
private let sampleSynthesisReport = """
moot_hunt_contradictions: sweep complete
probesScanned: 26
pairsScreened: 40
alreadySettled: 0
proposed: 1
  PROPOSED UUID-LEGACY-A contradicts UUID-LEGACY-B (word_exclusion, score 0.62, tunnel T-1)
Review with moot_lens_contradiction; accept/reject via moot_review_tunnel.
borderlineCandidates: 1
  CANDIDATE UUID-LEGACY-C vs UUID-LEGACY-D (negation_asymmetry, score 0.55)
    a: legacy snippet a
    b: legacy snippet b
proven: 1
historical: 2
coverage: 26/30
  PROVEN typed1111
    rule: dim.person.employer@1
    99999999-0000-4000-8000-000000000001 · typed row one · fdc:343 · qid:Q1 · 2026-01-01T00:00:00Z
    99999999-0000-4000-8000-000000000002 · typed row two · fdc:343 · qid:Q2 · 2026-01-01T00:00:00Z
  HISTORICAL hist2222 person:x|role (same_coordinate, validity_disjoint)
TIER 1 — CONTRADICTION (proven)
  lane: fetched 1, returned 1, promotedAway 0, backfilled 0
  PROVEN aaaa1111 at coord-d1 (rule dim.person.employer@1)
    11111111-0000-4000-8000-000000000001 · subject one · fdc:343 · qid:Q1 · 2026-01-01T00:00:00Z
    11111111-0000-4000-8000-000000000002 · subject two · fdc:343 · qid:Q2 · 2026-01-01T00:00:00Z
  a conflicting claim exists at coord-d9 [restricted]
TIER 2 — CONFLICT CANDIDATE
  lane: fetched 3, returned 2, promotedAway 1, backfilled 1
  UUID-B1 vs UUID-B2 (word_exclusion, score 0.62)
  UUID-C1 vs UUID-C2 (negation_asymmetry, score 0.58)
TIER 3 — DIVERGENCE
  lane: fetched 2, returned 2, promotedAway 0, backfilled 0
  UUID-D1 vs UUID-D2 (value_divergence, score 0.875)
  UUID-E1 vs UUID-E2 (value_divergence, score 0.8)
lane_seconds: hunt=1.234 synthesis=0.567
synthesis_wall_seconds: 1.801
"""

// A single-tier purpose report: one header, no lane counts, no timing lines
// (both are synthesis-only renderer arms — RecipeTools.swift:1388, :1415).
private let sampleTier3PurposeReport = """
moot_hunt_contradictions: tier 3 search complete
TIER 3 — DIVERGENCE
  UUID-D1 vs UUID-D2 (value_divergence, score 0.875)
"""

@Suite("Supersession tiered parsing and scoring (MXE-CT3 P4)")
struct SupersessionTieredTests {

    // MARK: Parser

    @Test("synthesis report parses sections, counts, pairs, and timing")
    func synthesisParses() {
        let parsed = parseTieredSections(sampleSynthesisReport)
        #expect(parsed.tier1.present && parsed.tier2.present && parsed.tier3.present)
        #expect(parsed.tier1.counts == ParsedTierLaneCounts(
            fetched: 1, returned: 1, promotedAway: 0, backfilled: 0))
        #expect(parsed.tier2.counts == ParsedTierLaneCounts(
            fetched: 3, returned: 2, promotedAway: 1, backfilled: 1))
        // Tier-1 pair comes from the two dense rows under the PROVEN line;
        // the restricted line carries no ids and yields no pair.
        #expect(parsed.tier1.pairs == [ReportedProvenPair(
            a: "11111111-0000-4000-8000-000000000001",
            b: "11111111-0000-4000-8000-000000000002")])
        #expect(parsed.tier2.pairs == [
            ReportedProvenPair(a: "UUID-B1", b: "UUID-B2"),
            ReportedProvenPair(a: "UUID-C1", b: "UUID-C2"),
        ])
        #expect(parsed.tier3.pairs == [
            ReportedProvenPair(a: "UUID-D1", b: "UUID-D2"),
            ReportedProvenPair(a: "UUID-E1", b: "UUID-E2"),
        ])
        #expect(parsed.laneSeconds == [
            ParsedLaneSeconds(label: "hunt", seconds: 1.234),
            ParsedLaneSeconds(label: "synthesis", seconds: 0.567),
        ])
        #expect(parsed.synthesisWallSeconds == 1.801)
    }

    @Test("the legacy prefix is ignored: no legacy or typed-section pair leaks in")
    func legacyPrefixIgnored() {
        let parsed = parseTieredSections(sampleSynthesisReport)
        let all = (parsed.tier1.pairs + parsed.tier2.pairs + parsed.tier3.pairs)
            .flatMap { [$0.a, $0.b] }
        // The legacy PROPOSED/CANDIDATE ids and the typed section's dense-row
        // UUIDs all sit BEFORE the first tier header and must not appear.
        #expect(!all.contains("UUID-LEGACY-A"))
        #expect(!all.contains("UUID-LEGACY-C"))
        #expect(!all.contains("99999999-0000-4000-8000-000000000001"))
    }

    @Test("single-tier purpose report parses its one section, without counts or timing")
    func purposeReportParses() {
        let parsed = parseTieredSections(sampleTier3PurposeReport)
        #expect(!parsed.tier1.present && !parsed.tier2.present && parsed.tier3.present)
        #expect(parsed.tier3.counts == nil)
        #expect(parsed.tier3.pairs == [ReportedProvenPair(a: "UUID-D1", b: "UUID-D2")])
        #expect(parsed.laneSeconds.isEmpty)
        #expect(parsed.synthesisWallSeconds == nil)
    }

    @Test("a report with no tiered sections parses to an empty result")
    func noSectionsParsesEmpty() {
        let parsed = parseTieredSections(
            "moot_hunt_contradictions: sweep complete\nproposed: 0\nborderlineCandidates: 0")
        #expect(parsed == ParsedTieredReport())
    }

    // MARK: Case-insensitive matching

    @Test("planted matching is case-insensitive across the UUID casing seam")
    func caseInsensitiveMatching() {
        // Swift UUID.uuidString is UPPERCASE; Rust Uuid::to_string() is
        // lowercase (precedent c95910dff). The ingest map may carry either
        // casing; the report may carry the other. Both directions must match.
        let planted = [ContradictionPair(
            id: "con-0", leftRecordID: "con-0-a", rightRecordID: "con-0-b",
            entity: "E0", attribute: "employer")]
        let upperMap = ["con-0-a": "AAAA1111-0000-4000-8000-000000000001",
                        "con-0-b": "AAAA1111-0000-4000-8000-000000000002"]
        let lowerReported = [ReportedProvenPair(
            a: "aaaa1111-0000-4000-8000-000000000002",
            b: "aaaa1111-0000-4000-8000-000000000001")] // and reversed order
        #expect(countDetectedPlanted(
            planted: planted, uuidByRecordID: upperMap,
            reportedPairs: lowerReported) == 1)

        let lowerMap = upperMap.mapValues { $0.lowercased() }
        let upperReported = [ReportedProvenPair(
            a: "AAAA1111-0000-4000-8000-000000000001",
            b: "AAAA1111-0000-4000-8000-000000000002")]
        #expect(countDetectedPlanted(
            planted: planted, uuidByRecordID: lowerMap,
            reportedPairs: upperReported) == 1)
    }

    @Test("an unmappable planted pair counts as undetected")
    func unmappablePlantedIsUndetected() {
        let planted = [ContradictionPair(
            id: "con-0", leftRecordID: "con-0-a", rightRecordID: "con-0-b",
            entity: "E0", attribute: "employer")]
        #expect(countDetectedPlanted(
            planted: planted, uuidByRecordID: [:],
            reportedPairs: [ReportedProvenPair(a: "X", b: "Y")]) == 0)
    }

    // MARK: Synthesis exactly-once / tier inflation

    private func plantedWithMap() -> ([ContradictionPair], [String: String]) {
        let planted = [
            ContradictionPair(id: "con-0", leftRecordID: "con-0-a",
                              rightRecordID: "con-0-b", entity: "E0", attribute: "employer"),
            ContradictionPair(id: "div-0", leftRecordID: "div-0-a",
                              rightRecordID: "div-0-b", entity: "E1", attribute: "response time"),
        ]
        let map = ["con-0-a": "UUID-B1", "con-0-b": "UUID-B2",
                   "div-0-a": "UUID-D1", "div-0-b": "UUID-D2"]
        return (planted, map)
    }

    @Test("a pair appearing once at its tier is not inflation")
    func exactlyOnceIsClean() {
        let (planted, map) = plantedWithMap()
        // In the sample synthesis report con-0 sits only in tier 2 and div-0
        // only in tier 3 — the exactly-once contract holds.
        let parsed = parseTieredSections(sampleSynthesisReport)
        #expect(countTierInflation(
            planted: planted, uuidByRecordID: map, synthesis: parsed) == 0)
    }

    @Test("a pair reported in two tier sections counts as tier inflation")
    func doubleReportIsInflation() {
        let (planted, map) = plantedWithMap()
        var parsed = parseTieredSections(sampleSynthesisReport)
        // Simulate a dedup failure: the tier-2 planted pair ALSO shows up in
        // the tier-3 section (reversed order and different casing — the
        // inflation check must see through both).
        parsed.tier3.pairs.append(ReportedProvenPair(a: "uuid-b2", b: "uuid-b1"))
        #expect(countTierInflation(
            planted: planted, uuidByRecordID: map, synthesis: parsed) == 1)
    }

    @Test("absence from every section is undetected, not inflation")
    func absenceIsNotInflation() {
        let (planted, map) = plantedWithMap()
        #expect(countTierInflation(
            planted: planted, uuidByRecordID: map,
            synthesis: ParsedTieredReport()) == 0)
    }

    // MARK: Decoy classification

    private func decoyFixture() -> ([DecoyPair], [String: String]) {
        let decoys = [
            DecoyPair(id: "dec-0", leftRecordID: "dec-0-a", rightRecordID: "dec-0-b",
                      kind: DecoyPair.kindMarkerSupersession),
            DecoyPair(id: "dec-1", leftRecordID: "dec-1-a", rightRecordID: "dec-1-b",
                      kind: DecoyPair.kindDistinctEntity),
            DecoyPair(id: "dec-2", leftRecordID: "dec-2-a", rightRecordID: "dec-2-b",
                      kind: DecoyPair.kindUnitEquivalent),
        ]
        let map = ["dec-0-a": "UUID-M1", "dec-0-b": "UUID-M2",
                   "dec-1-a": "UUID-N1", "dec-1-b": "UUID-N2",
                   "dec-2-a": "UUID-U1", "dec-2-b": "UUID-U2"]
        return (decoys, map)
    }

    @Test("a unit-equivalent decoy firing tier 3 is a known-limitation hit, not hard")
    func unitEquivalentIsKnownLimitation() {
        let (decoys, map) = decoyFixture()
        var report = ParsedTieredReport()
        report.tier3.pairs = [ReportedProvenPair(a: "UUID-U1", b: "UUID-U2")]
        let hits = countDecoyHits(
            decoys: decoys, uuidByRecordID: map,
            tieredReports: [report], legacyReported: [])
        #expect(hits == DecoyHitCounts(hard: 0, knownLimitation: 1))
    }

    @Test("a marker or distinct-entity decoy in any tier section or PROPOSED is a hard hit")
    func markerAndDistinctEntityAreHardHits() {
        let (decoys, map) = decoyFixture()
        // Marker decoy in a tier-2 section; distinct-entity decoy on a legacy
        // PROPOSED line (an auto-filed tunnel counts even outside tiers).
        var report = ParsedTieredReport()
        report.tier2.pairs = [ReportedProvenPair(a: "UUID-M2", b: "UUID-M1")]
        let legacy = [ReportedContradictionPair(a: "UUID-N1", b: "UUID-N2", tier: "proposed")]
        let hits = countDecoyHits(
            decoys: decoys, uuidByRecordID: map,
            tieredReports: [report], legacyReported: legacy)
        #expect(hits == DecoyHitCounts(hard: 2, knownLimitation: 0))
    }

    @Test("a decoy on a legacy CANDIDATE line is NOT a hit — borderline is adjudication, not a finding")
    func candidateLineIsNotAHit() {
        let (decoys, map) = decoyFixture()
        let legacy = [ReportedContradictionPair(a: "UUID-M1", b: "UUID-M2", tier: "candidate")]
        let hits = countDecoyHits(
            decoys: decoys, uuidByRecordID: map,
            tieredReports: [], legacyReported: legacy)
        #expect(hits == DecoyHitCounts(hard: 0, knownLimitation: 0))
    }

    @Test("unflagged decoys score zero in both rows")
    func unflaggedDecoysScoreZero() {
        let (decoys, map) = decoyFixture()
        let hits = countDecoyHits(
            decoys: decoys, uuidByRecordID: map,
            tieredReports: [ParsedTieredReport()], legacyReported: [])
        #expect(hits == DecoyHitCounts(hard: 0, knownLimitation: 0))
    }
}

@Suite("Supersession corpus P4 classes")
struct SupersessionCorpusTieredTests {

    @Test("generation with divergences and decoys is a pure function of seed")
    func deterministicWithNewClasses() {
        let a = generateSupersessionCorpus(
            seed: 42, entityCount: 8, versionsPerChain: 3, contradictionCount: 4,
            divergenceCount: 5, decoyCount: 6)
        let b = generateSupersessionCorpus(
            seed: 42, entityCount: 8, versionsPerChain: 3, contradictionCount: 4,
            divergenceCount: 5, decoyCount: 6)
        #expect(a == b)
    }

    @Test("new classes draw AFTER the pre-P4 classes: chains and word-valued plants are unchanged")
    func preP4ClassesUnperturbed() {
        let before = generateSupersessionCorpus(
            seed: 20260725, entityCount: 6, versionsPerChain: 3, contradictionCount: 4)
        let after = generateSupersessionCorpus(
            seed: 20260725, entityCount: 6, versionsPerChain: 3, contradictionCount: 4,
            divergenceCount: 5, decoyCount: 6)
        // The headline set is EXACTLY as today: every pre-P4 record, query,
        // and contradiction pair is byte-identical; the new records append.
        #expect(after.queries == before.queries)
        #expect(after.contradictions == before.contradictions)
        #expect(Array(after.records.prefix(before.records.count)) == before.records)
    }

    @Test("divergence pairs share event_time and differ only in a digit-bearing value")
    func divergenceInvariants() {
        let corpus = generateSupersessionCorpus(
            seed: 7, entityCount: 4, versionsPerChain: 2, contradictionCount: 2,
            divergenceCount: 6, decoyCount: 0)
        #expect(corpus.divergences.count == 6)
        for pair in corpus.divergences {
            let left = corpus.records.first { $0.id == pair.leftRecordID }!
            let right = corpus.records.first { $0.id == pair.rightRecordID }!
            #expect(left.eventTime == right.eventTime)
            #expect(left.entity == right.entity)
            #expect(left.attribute == right.attribute)
            #expect(left.value != right.value)
            // Numeric values — the tier-3 (valueDivergence) planted class.
            #expect(left.value.contains { $0.isNumber })
            #expect(right.value.contains { $0.isNumber })
            // Same template: contents differ ONLY at the value token.
            #expect(left.content.replacingOccurrences(of: left.value, with: "#")
                == right.content.replacingOccurrences(of: right.value, with: "#"))
        }
    }

    @Test("decoy shapes cycle and each shape holds its non-contradiction invariant")
    func decoyInvariants() {
        let corpus = generateSupersessionCorpus(
            seed: 7, entityCount: 4, versionsPerChain: 2, contradictionCount: 2,
            divergenceCount: 0, decoyCount: 6)
        #expect(corpus.decoys.count == 6)
        #expect(corpus.decoys.map(\.kind) == [
            DecoyPair.kindMarkerSupersession, DecoyPair.kindDistinctEntity,
            DecoyPair.kindUnitEquivalent, DecoyPair.kindMarkerSupersession,
            DecoyPair.kindDistinctEntity, DecoyPair.kindUnitEquivalent,
        ])
        for decoy in corpus.decoys {
            let left = corpus.records.first { $0.id == decoy.leftRecordID }!
            let right = corpus.records.first { $0.id == decoy.rightRecordID }!
            switch decoy.kind {
            case DecoyPair.kindMarkerSupersession:
                // A real chain: later revision with an explicit marker.
                #expect(left.eventTime < right.eventTime)
                #expect(right.content.hasPrefix("Update: "))
                #expect(right.content.contains(" moved to "))
            case DecoyPair.kindDistinctEntity:
                // Different subjects, same value: agreement, not conflict.
                #expect(left.entity != right.entity)
                #expect(left.value == right.value)
                #expect(left.eventTime == right.eventTime)
            default:
                // Unit-equivalent: 90s vs 1.5min, same instant, same entity.
                #expect(left.entity == right.entity)
                #expect(left.value == "90s")
                #expect(right.value == "1.5min")
                #expect(left.eventTime == right.eventTime)
            }
        }
    }

    @Test("cross-port pins: seed 20260725/6/3/4 + 5 divergences + 6 decoys")
    func crossPortPins() {
        // These exact strings are pinned in the Rust leg's
        // supersession_corpus tests (cross_port_pins_for_p4_classes). Both
        // legs must generate them for the same seed — a shared-fixture
        // determinism check without a committed vector file (the conformance
        // directory is outside this mission's write surface).
        let corpus = generateSupersessionCorpus(
            seed: 20260725, entityCount: 6, versionsPerChain: 3, contradictionCount: 4,
            divergenceCount: 5, decoyCount: 6)
        let byID = Dictionary(uniqueKeysWithValues: corpus.records.map { ($0.id, $0) })
        #expect(byID["div-0-a"]?.content == "Response time for Ines Novak D0 is 90ms. Noted one Thursday morning in November.")
        #expect(byID["div-0-b"]?.content == "Response time for Ines Novak D0 is 30ms. Noted one Thursday morning in November.")
        #expect(byID["div-0-a"]?.eventTime == "2021-03-01T00:53:20Z")
        #expect(byID["dec-0-a"]?.content == "Diego Reyes X0 works at Beta Corp. Noted one Tuesday morning in April.")
        #expect(byID["dec-0-b"]?.content == "Update: Diego Reyes X0 moved to Vireo Systems. Noted one Tuesday morning in April.")
        #expect(byID["dec-1-a"]?.content == "Marcus Kowalski Y1 works at Acme Robotics. Noted one Wednesday noon in May.")
        #expect(byID["dec-1-b"]?.content == "Amara Adeyemi Y1 works at Acme Robotics. Noted one Wednesday noon in May.")
        #expect(byID["dec-2-a"]?.content == "The deploy pipeline for Amara Chen Z2 runs in 90s. Noted one Thursday afternoon in June.")
        #expect(byID["dec-2-b"]?.content == "The deploy pipeline for Amara Chen Z2 runs in 1.5min. Noted one Thursday afternoon in June.")
    }

    @Test("pre-P4 dumps without the new keys still decode, with empty P4 classes")
    func backwardDecode() throws {
        let old = generateSupersessionCorpus(
            seed: 3, entityCount: 2, versionsPerChain: 2, contradictionCount: 1)
        // Encode, strip the new keys, decode: the shape a pre-P4 dump (and
        // the committed conformance vector file) has on disk.
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(old)) as! [String: Any]
        object.removeValue(forKey: "divergences")
        object.removeValue(forKey: "decoys")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SupersessionCorpus.self, from: stripped)
        #expect(decoded == old)
        #expect(decoded.divergences.isEmpty && decoded.decoys.isEmpty)
    }

    @Test("dump round-trip carries the new classes")
    func dumpRoundTrip() throws {
        let corpus = generateSupersessionCorpus(
            seed: 11, entityCount: 3, versionsPerChain: 2, contradictionCount: 2,
            divergenceCount: 2, decoyCount: 3)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let decoded = try JSONDecoder().decode(
            SupersessionCorpus.self, from: encoder.encode(corpus))
        #expect(decoded == corpus)
        #expect(decoded.divergences.count == 2)
        #expect(decoded.decoys.count == 3)
    }
}
