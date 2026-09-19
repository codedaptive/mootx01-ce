// SupersessionStructuredTierTests.swift
//
// Typed proving tier — parser + scorer for the typed conflict-projection section.
// The fixture text below is the EXACT shape the ARIA renderer emits
// (RecipeTools.conflictProjectionSection ↔ conflict_projection_section);
// the Rust leg pins the same fixture in supersession_runner.rs tests so
// the two harness legs cannot drift in how they read a report.

import Foundation
import Testing
@testable import mcp_benchmarker

@Suite struct SupersessionStructuredTierTests {

    static let sampleSection = """
    moot_lens_contradiction: legacy lines above
    conflicting_facts: 2 subject+predicate pair(s)
    proven: 3
    historical: 4
    compatible: 1
    unknown_or_invalid: 2
    coverage: 26/30
      PROVEN aaaa1111
        rule: dim.person.employer@1
        coordinate: person:sarah chen c0|employer
        values: d1hash vs d2hash
        time: t:pt:100 | t:pt:100
        reasons: same_coordinate, validity_overlap, values_exclusive
        11111111-0000-4000-8000-000000000001 · subject one · fdc:343 · qid:Q1 · 2026-01-01T00:00:00Z
        11111111-0000-4000-8000-000000000002 · subject two · fdc:343 · qid:Q2 · 2026-01-01T00:00:00Z
      PROVEN bbbb2222
        rule: dim.person.city@1
        coordinate: person:noor haddad c1|city
        values: d3hash vs d4hash
        time: t:unknown | t:unknown
        reasons: same_coordinate, validity_unknown, values_exclusive
        22222222-0000-4000-8000-000000000003 · subject three · fdc:343 · qid:Q3 · 2026-01-02T00:00:00Z
        22222222-0000-4000-8000-000000000004 · subject four · fdc:343 · qid:Q4 · 2026-01-02T00:00:00Z
      a conflicting claim exists at coorddigest [restricted]
      HISTORICAL cccc3333 person:x|role (same_coordinate, validity_disjoint)
    """

    @Test func parserReadsCountsAndProvenPairs() {
        let parsed = parseTypedConflictSection(Self.sampleSection)
        #expect(parsed.proven == 3)
        #expect(parsed.historical == 4)
        #expect(parsed.projected == 26)
        #expect(parsed.scanned == 30)
        // Two full blocks yield pairs; the redacted block carries no ids.
        #expect(parsed.pairs == [
            ReportedProvenPair(
                a: "11111111-0000-4000-8000-000000000001",
                b: "11111111-0000-4000-8000-000000000002"),
            ReportedProvenPair(
                a: "22222222-0000-4000-8000-000000000003",
                b: "22222222-0000-4000-8000-000000000004"),
        ])
    }

    @Test func scorerSeparatesProvenPlantedFromFalseProofs() {
        let planted = [
            ContradictionPair(id: "con-0", leftRecordID: "con-0-a",
                              rightRecordID: "con-0-b",
                              entity: "Sarah Chen C0", attribute: "employer"),
            // Unmappable pair (never ingested): counts as undetected.
            ContradictionPair(id: "con-1", leftRecordID: "con-1-a",
                              rightRecordID: "con-1-b",
                              entity: "Ghost", attribute: "city"),
        ]
        let uuids = [
            "con-0-a": "11111111-0000-4000-8000-000000000001",
            "con-0-b": "11111111-0000-4000-8000-000000000002",
        ]
        let parsed = parseTypedConflictSection(Self.sampleSection)
        let outcome = scoreStructuredTier(
            planted: planted, uuidByRecordID: uuids,
            parsed: parsed, tierSeconds: 1.5)
        #expect(outcome.plantedCount == 2)
        // Proven-planted: con-0 proven (order-independent set match); con-1
        // unmappable.
        #expect(outcome.provenPlanted == 1)
        // False proof: the second PROVEN block is not a planted pair.
        #expect(outcome.provenOutsidePlanted == 1)
        #expect(outcome.provenReported == 3)
        #expect(outcome.historicalReported == 4)
        #expect(outcome.coverageProjected == 26)
        #expect(outcome.coverageScanned == 30)
    }

    /// A report with no typed section parses to zeros and no pairs —
    /// the lane treats that as a hard failure upstream (it throws before
    /// scoring), so the parser itself stays total.
    @Test func parserIsTotalOnLegacyOnlyReports() {
        let parsed = parseTypedConflictSection(
            "contradicts_tunnels: none\nconflicting_facts: none")
        #expect(parsed.proven == 0)
        #expect(parsed.pairs.isEmpty)
    }
}
