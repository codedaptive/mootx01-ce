// ComposerConformanceTests.swift
//
// Central conformance suite for ResultComposer — ARIA_MCP_INTERFACE §11 grammar.
// Every shape defined in §§11.2–11.12 is exercised over the shared fixture set
// at Tests/Conformance/composer_fixtures.json. Both the text payload and the
// structuredContent JSON are compared byte-identically to the golden values in
// the fixture.
//
// Cross-port rule: composer_conformance.rs drives the same fixture file and
// the same expected strings on the Rust port. Neither port may produce output
// that disagrees with the fixture. If a fixture value needs updating, update
// the JSON — both ports change together.
//
// Row format (ENC-W6B): uuid · subject · bestSpan · sscFacts · eventTime · score (S1)
//                       uuid · subject · bestSpan · sscFacts · eventTime (S2)
// activeAdornments, firstSentence, and ssc (object) are removed from the row schema.

import Testing
import Foundation
@testable import AriaMCP

@Suite("Composer conformance — §11 grammar over shared fixture")
struct ComposerConformanceTests {

    // MARK: - Fixture path (compile-time via #filePath)

    // #filePath expands at compile time to the path of this source file:
    //   …/Tests/AriaMCPTests/ComposerConformanceTests.swift
    // Two .deletingLastPathComponent() calls give …/Tests/.
    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // → …/Tests/AriaMCPTests
            .deletingLastPathComponent()  // → …/Tests
            .appendingPathComponent("Conformance/composer_fixtures.json")
    }

    private func loadCases() throws -> [[String: Any]] {
        let data = try Data(contentsOf: fixtureURL())
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return root["cases"] as? [[String: Any]] ?? []
    }

    // MARK: - Decoding helpers

    /// Decode one CandidateRowData from a fixture row dictionary.
    /// Row format (ENC-W6B): uuid · subject · bestSpan · sscFacts · eventTime · score (S1).
    private func candidateRow(from json: [String: Any]) -> CandidateRowData {
        let id = json["id"] as? String ?? ""
        let subject = json["subject"] as? String
        let bestSpan = json["bestSpan"] as? String
        let sscFacts = json["sscFacts"] as? String
        let eventTime = json["eventTime"] as? String ?? ""
        let score = json["score"] as? Double
        return CandidateRowData(
            id: id,
            subject: subject,
            bestSpan: bestSpan,
            sscFacts: sscFacts,
            eventTime: eventTime,
            score: score,
            retrievalSource: json["retrievalSource"] as? String,
            distilled: json["distilled"] as? String,
            representation: json["representation"] as? String,
            tier: json["tier"] as? String,
            estateID: json["estateID"] as? String,
            content: json["content"] as? String
        )
    }

    /// Decode a ControlSignals from a fixture control dictionary.
    /// temporalCapability is an optional nested object; absent when nil in the fixture.
    private func controlSignals(from json: [String: Any]) -> ControlSignals {
        let temporalCapability: TemporalCapability? = (json["temporalCapability"] as? [String: Any]).map { tc in
            TemporalCapability(
                mode: tc["mode"] as? String ?? "",
                source: tc["source"] as? String ?? "",
                grab: tc["grab"] as? String ?? "",
                from: tc["from"] as? String ?? "",
                to: tc["to"] as? String ?? "",
                widenedDays: tc["widenedDays"] as? Int
            )
        }
        return ControlSignals(
            discrimination: json["discrimination"] as? String,
            temporalNarration: json["temporalNarration"] as? String,
            temporalCapability: temporalCapability,
            walkStage: json["walkStage"] as? String,
            walkStoppedEarly: json["walkStoppedEarly"] as? Bool,
            degraded: json["degraded"] as? Bool ?? false,
            tieNote: json["tieNote"] as? Bool ?? false,
            hint: json["hint"] as? String
        )
    }

    /// Convert an Any from JSONSerialization into a JSONValue for equality comparison.
    private func toJSONValue(_ any: Any) throws -> JSONValue {
        try JSONValue.from(any)
    }

    // MARK: - Per-shape dispatch

    private func verifyCase(_ tc: [String: Any]) throws {
        let name = tc["name"] as? String ?? "unknown"
        let shape = tc["shape"] as? String ?? ""

        switch shape {

        // ── S1 ranked surface ────────────────────────────────────────────────

        case "s1":
            let rows = (tc["rows"] as? [[String: Any]] ?? []).map(candidateRow)
            let control = controlSignals(from: tc["control"] as? [String: Any] ?? [:])
            let result = ResultComposer.renderS1Surface(rows: rows, control: control)
            let expectedText = tc["expectedText"] as? String ?? ""
            #expect(result.text == expectedText,
                    "[\(name)] S1 text mismatch")
            if let expAny = tc["expectedStructured"] {
                let expVal = try toJSONValue(expAny)
                #expect(result.structured == expVal,
                        "[\(name)] S1 structured mismatch")
            }

        // ── S1 empty ─────────────────────────────────────────────────────────

        case "s1_empty":
            let hint = tc["hint"] as? String
            let result = ResultComposer.renderEmptyS1(hint: hint)
            let expectedText = tc["expectedText"] as? String ?? ""
            #expect(result.text == expectedText,
                    "[\(name)] S1 empty text mismatch")

        // ── S1 cap line ───────────────────────────────────────────────────────

        case "s1_cap":
            // Verifies the cap-line format string (ResultComposer.renderCapLine).
            let limit = tc["capLimit"] as? Int ?? 0
            let narrowingArg = tc["narrowingArg"] as? String ?? ""
            let capLine = ResultComposer.renderCapLine(limit: limit, narrowingArg: narrowingArg)
            let expected = tc["expectedCapLine"] as? String ?? ""
            #expect(capLine == expected,
                    "[\(name)] cap line format mismatch")

        // ── S2 listing ────────────────────────────────────────────────────────

        case "s2_listing":
            let wing = tc["wing"] as? String ?? ""
            let room = tc["room"] as? String ?? ""
            let rows = (tc["rows"] as? [[String: Any]] ?? []).map(candidateRow)
            let result = ResultComposer.renderS2Listing(wing: wing, room: room, rows: rows)
            let expectedText = tc["expectedText"] as? String ?? ""
            #expect(result.text == expectedText,
                    "[\(name)] S2 listing text mismatch")

        // ── S2 batch get ──────────────────────────────────────────────────────

        case "s2_batch":
            let requestedCount = tc["requestedCount"] as? Int ?? 0
            let rawRows = tc["rows"] as? [[String: Any]] ?? []
            var entries: [ResultComposer.BatchGetEntry] = []
            var resolvedCount = 0
            for rowJSON in rawRows {
                let found = rowJSON["found"] as? Bool ?? false
                if found {
                    entries.append(.found(candidateRow(from: rowJSON)))
                    resolvedCount += 1
                } else {
                    entries.append(.notFound(rowJSON["id"] as? String ?? ""))
                }
            }
            let result = ResultComposer.renderS2BatchGet(
                entries: entries, resolved: resolvedCount, requested: requestedCount)
            let expectedText = tc["expectedText"] as? String ?? ""
            #expect(result.text == expectedText,
                    "[\(name)] S2 batch text mismatch")

        // ── S2 empty listing ──────────────────────────────────────────────────

        case "s2_listing_empty":
            let wing = tc["wing"] as? String ?? ""
            let room = tc["room"] as? String ?? ""
            let result = ResultComposer.renderEmptyS2Listing(wing: wing, room: room)
            let expectedText = tc["expectedText"] as? String ?? ""
            #expect(result.text == expectedText,
                    "[\(name)] S2 empty listing text mismatch")

        // ── S3 full record ────────────────────────────────────────────────────

        case "s3":
            let rec = tc["record"] as? [String: Any] ?? [:]
            // Tunnels: direction "outgoing"/"incoming" → isOutgoing bool.
            let tunnels = (rec["tunnels"] as? [[String: Any]] ?? []).map { t -> FullRecordTunnel in
                FullRecordTunnel(
                    isOutgoing: (t["direction"] as? String ?? "") == "outgoing",
                    otherID: t["targetID"] as? String ?? "",
                    label: t["label"] as? String ?? ""
                )
            }
            let record = FullRecordData(
                id: rec["id"] as? String ?? "",
                room: rec["room"] as? String ?? "",
                wing: rec["wing"] as? String ?? "",
                subject: rec["subject"] as? String,
                filedAt: rec["filedAt"] as? String ?? "",
                eventTime: rec["eventTime"] as? String ?? "",
                state: rec["state"] as? String ?? "",
                trust: rec["trust"] as? String ?? "",
                sensitivity: rec["sensitivity"] as? String ?? "",
                exportability: rec["exportability"] as? String ?? "",
                confirmation: rec["confirmation"] as? String ?? "",
                lineageID: rec["lineageID"] as? String ?? "",
                tunnels: tunnels,
                content: rec["content"] as? String ?? ""
            )
            let result = ResultComposer.renderS3Record(record)
            let expectedText = tc["expectedText"] as? String ?? ""
            #expect(result.text == expectedText,
                    "[\(name)] S3 text mismatch")

        // ── S4 fact search ────────────────────────────────────────────────────

        case "s4_search":
            let facts = (tc["facts"] as? [[String: Any]] ?? []).map { f -> FactSearchRow in
                FactSearchRow(
                    factID: f["factID"] as? String ?? "",
                    subject: f["subject"] as? String ?? "",
                    predicate: f["predicate"] as? String ?? "",
                    object: f["object"] as? String ?? "",
                    sourceDrawerID: f["sourceDrawerID"] as? String,
                    filedAt: f["filedAt"] as? String ?? ""
                )
            }
            let result = ResultComposer.renderS4FactSearch(facts: facts)
            let expectedText = tc["expectedText"] as? String ?? ""
            #expect(result.text == expectedText,
                    "[\(name)] S4 search text mismatch")

        // ── S4 fact timeline ──────────────────────────────────────────────────

        case "s4_timeline":
            let facts = (tc["facts"] as? [[String: Any]] ?? []).map { f -> FactTimelineRow in
                FactTimelineRow(
                    filedAt: f["filedAt"] as? String ?? "",
                    lifecycle: f["lifecycle"] as? String ?? "",
                    factID: f["factID"] as? String ?? "",
                    subject: f["subject"] as? String ?? "",
                    predicate: f["predicate"] as? String ?? "",
                    object: f["object"] as? String ?? "",
                    sourceDrawerID: f["sourceDrawerID"] as? String
                )
            }
            let result = ResultComposer.renderS4FactTimeline(facts: facts)
            let expectedText = tc["expectedText"] as? String ?? ""
            #expect(result.text == expectedText,
                    "[\(name)] S4 timeline text mismatch")

        // ── S5 edge rows ──────────────────────────────────────────────────────

        case "s5":
            let direction = tc["direction"] as? String ?? "outgoing"
            let edges = (tc["edges"] as? [[String: Any]] ?? []).map { e -> EdgeRow in
                let far = candidateRow(from: e["farEndpoint"] as? [String: Any] ?? [:])
                return EdgeRow(
                    tunnelID: e["tunnelID"] as? String ?? "",
                    kindLabel: e["kindLabel"] as? String ?? "",
                    lifecycle: e["lifecycle"] as? String,
                    farEndpoint: far
                )
            }
            let result = ResultComposer.renderS5Edges(direction: direction, edges: edges)
            let expectedText = tc["expectedText"] as? String ?? ""
            #expect(result.text == expectedText,
                    "[\(name)] S5 text mismatch")

        // ── S6 tabular query ──────────────────────────────────────────────────

        case "s6_query":
            // Decode S6 rows: JSON value types map to TabularCellValue.
            // NULL maps to nil; integer JSON numbers → .integer; float → .float;
            // bool → .bool; string → .text.
            let rawRows = tc["rows"] as? [[Any?]] ?? []
            let columns = tc["columns"] as? [String] ?? []
            let typedRows: [[TabularCellValue?]] = rawRows.map { rawRow in
                rawRow.map { cell -> TabularCellValue? in
                    guard let cell = cell else { return nil }
                    if cell is NSNull { return nil }
                    if let n = cell as? NSNumber {
                        if CFGetTypeID(n) == CFBooleanGetTypeID() {
                            return .bool(n.boolValue)
                        }
                        // Determine integer vs float from NSNumber's type code.
                        let typeCode = String(cString: n.objCType)
                        if typeCode == "d" || typeCode == "f" {
                            return .float(n.doubleValue)
                        }
                        return .integer(n.int64Value)
                    }
                    if let s = cell as? String { return .text(s) }
                    return nil
                }
            }
            let data = TabularQueryData(
                datasetID: tc["datasetID"] as? String ?? "",
                datasetName: tc["datasetName"] as? String ?? "",
                returned: tc["returned"] as? Int ?? 0,
                total: tc["total"] as? Int,
                limit: tc["limit"] as? Int ?? 0,
                orderColumn: tc["orderCol"] as? String ?? "",
                orderDirection: tc["orderDir"] as? String ?? "",
                columns: columns,
                rows: typedRows
            )
            let result = ResultComposer.renderS6Query(data)
            let expectedText = tc["expectedText"] as? String ?? ""
            #expect(result.text == expectedText,
                    "[\(name)] S6 query text mismatch")

        // ── S6 dataset stats ──────────────────────────────────────────────────

        case "s6_stats":
            let colStats = (tc["columns"] as? [[String: Any]] ?? []).map { c -> TabularColumnStats in
                TabularColumnStats(
                    name: c["name"] as? String ?? "",
                    count: c["count"] as? Int ?? 0,
                    nulls: c["nulls"] as? Int ?? 0,
                    distinct: c["distinct"] as? Int ?? 0,
                    min: c["min"] as? String,
                    max: c["max"] as? String,
                    mean: c["mean"] as? String,
                    stddev: c["stddev"] as? String
                )
            }
            let data = TabularStatsData(
                datasetID: tc["datasetID"] as? String ?? "",
                datasetName: tc["datasetName"] as? String ?? "",
                totalRows: tc["totalRows"] as? Int ?? 0,
                totalColumns: tc["totalCols"] as? Int ?? 0,
                columns: colStats
            )
            let result = ResultComposer.renderS6Stats(data)
            let expectedText = tc["expectedText"] as? String ?? ""
            #expect(result.text == expectedText,
                    "[\(name)] S6 stats text mismatch")

        // ── Grounded synthesis ────────────────────────────────────────────────

        case "synthesis", "synthesis_whole_estate":
            let rows = (tc["rows"] as? [[String: Any]] ?? []).map(candidateRow)
            let control = controlSignals(from: tc["control"] as? [String: Any] ?? [:])
            let cueTerms = tc["cueTerms"] as? [String]
            let summaryText = tc["summary"] as? String ?? ""
            let data = SynthesisData(
                drawerCount: tc["drawerCount"] as? Int ?? 0,
                cueTerms: cueTerms,
                summary: summaryText,
                rows: rows,
                control: control
            )
            let result = ResultComposer.renderSynthesis(data)
            let expectedText = tc["expectedText"] as? String ?? ""
            #expect(result.text == expectedText,
                    "[\(name)] synthesis text mismatch")
            // Verify cues + summary keys in the structured output.
            if let topLevel = tc["expectedStructuredTopLevel"] as? [String: Any] {
                guard case .object(let obj) = result.structured else {
                    Issue.record("[\(name)] synthesis structured must be an object")
                    return
                }
                if let expCues = topLevel["cues"] as? [String] {
                    #expect(obj["cues"] == .array(expCues.map { .string($0) }),
                            "[\(name)] synthesis cues mismatch")
                }
                if let expSummary = topLevel["summary"] as? String {
                    #expect(obj["summary"] == .string(expSummary),
                            "[\(name)] synthesis summary mismatch")
                }
            }

        // ── Vague recall ──────────────────────────────────────────────────────

        case "vague":
            let summaries = (tc["summaries"] as? [[String: Any]] ?? []).map(candidateRow)
            let originals = (tc["originals"] as? [[String: Any]] ?? []).map(candidateRow)
            let control = controlSignals(from: tc["control"] as? [String: Any] ?? [:])
            let result = ResultComposer.renderVagueRecall(
                summaries: summaries, originals: originals, control: control)
            let expectedText = tc["expectedText"] as? String ?? ""
            #expect(result.text == expectedText,
                    "[\(name)] vague recall text mismatch")

        // ── Distilled recall ──────────────────────────────────────────────────

        case "distilled":
            let rows = (tc["rows"] as? [[String: Any]] ?? []).map(candidateRow)
            let control = controlSignals(from: tc["control"] as? [String: Any] ?? [:])
            let result = ResultComposer.renderDistilledRecall(rows: rows, control: control)
            let expectedText = tc["expectedText"] as? String ?? ""
            #expect(result.text == expectedText,
                    "[\(name)] distilled recall text mismatch")

        // ── Federated recall ──────────────────────────────────────────────────

        case "federated":
            let sections = (tc["estates"] as? [[String: Any]] ?? []).map { e -> FederatedSection in
                let rows = (e["rows"] as? [[String: Any]] ?? []).map(candidateRow)
                let control = controlSignals(from: e["control"] as? [String: Any] ?? [:])
                return FederatedSection(
                    estateName: e["estateName"] as? String ?? "",
                    estateID: e["estateID"] as? String ?? "",
                    rows: rows,
                    control: control
                )
            }
            let result = ResultComposer.renderFederatedRecall(estates: sections)
            let expectedText = tc["expectedText"] as? String ?? ""
            #expect(result.text == expectedText,
                    "[\(name)] federated recall text mismatch")

        // ── Structured parity — forbidden keys ────────────────────────────────

        case "s1_structured_parity":
            // Verifies absent optional fields are ABSENT (not null) from structured JSON.
            let rows = (tc["rows"] as? [[String: Any]] ?? []).map(candidateRow)
            let result = ResultComposer.renderS1Surface(rows: rows, control: ControlSignals())
            let forbiddenKeys = tc["forbiddenKeys"] as? [String] ?? []
            guard case .object(let topObj) = result.structured,
                  case .array(let results) = topObj["results"],
                  let firstResult = results.first,
                  case .object(let rowObj) = firstResult else {
                Issue.record("[\(name)] structured output missing expected shape")
                return
            }
            for key in forbiddenKeys {
                #expect(rowObj[key] == nil,
                        "[\(name)] forbidden key '\(key)' must be absent from structured row")
            }

        default:
            // Unknown shape: fail explicitly so the fixture and the test stay in sync.
            Issue.record("[\(name)] unknown fixture shape: \(shape)")
        }
    }

    // MARK: - Test entry point

    /// Drives every fixture case through the composer and verifies both the text
    /// payload and structuredContent against the golden values in
    /// Tests/Conformance/composer_fixtures.json.
    ///
    /// Each shape maps to one dispatch arm above. A missing arm causes an
    /// explicit test failure so the fixture and this file stay in sync.
    @Test func allFixtureCases() throws {
        let cases = try loadCases()
        #expect(cases.count > 0, "fixture must have at least one case")
        for tc in cases {
            try verifyCase(tc)
        }
    }
}
