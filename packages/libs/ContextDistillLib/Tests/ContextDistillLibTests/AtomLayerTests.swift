// AtomLayerTests.swift
// CDL-01 Part 3 — intent atom layer conformance.
//
// Two test suites:
//   OracleConformance — 509-row test: every oracle row's selected_source_spans
//     must appear as atoms in intentAtoms(source).
//   AtomFixtureUnit   — 5-row unit test: speakerTurns and structuredAtoms
//     output matches the frozen atoms-fixture-v22.json.

import Testing
import Foundation
@testable import ContextDistillLib

// MARK: - Oracle conformance (509 rows across 4 beds)

@Suite("OracleConformance")
struct OracleConformanceTests {

    /// Tuple used as the atom identity key for subset checking.
    struct AtomKey: Hashable, CustomStringConvertible {
        let start: Int
        let end: Int
        let kind: String
        let speaker: String?  // nil when Python returns null

        var description: String {
            "[\(start)..\(end)] kind=\(kind) speaker=\(speaker ?? "nil")"
        }
    }

    // MARK: debug7 (7 rows)

    @Test func debug7Conformance() throws {
        try checkBed("debug7")
    }

    // MARK: sample30 (30 rows)

    @Test func sample30Conformance() throws {
        try checkBed("sample30")
    }

    // MARK: locomo (272 rows)

    @Test func locomoConformance() throws {
        try checkBed("locomo")
    }

    // MARK: blind200 (200 rows)

    @Test func blind200Conformance() throws {
        try checkBed("blind200")
    }

    // MARK: - Shared helper

    private func checkBed(_ bed: String) throws {
        let rows = loadOracleRows(bed: bed)

        var failures: [(drawerID: String, missing: [AtomKey])] = []

        for row in rows {
            let source = row.original
            let result = intentAtoms(source)
            let atomSet = Set(result.atoms.map {
                AtomKey(start: $0.start, end: $0.end, kind: $0.kind, speaker: $0.speaker)
            })

            // Parse selected_source_spans from rawJSON
            guard let spanDicts = row.rawJSON["selected_source_spans"] as? [[String: Any]] else {
                // Row has no selected_source_spans — skip (possible in incomplete oracle rows)
                continue
            }

            var missing: [AtomKey] = []
            for spanDict in spanDicts {
                guard let start = spanDict["start"] as? Int,
                      let end = spanDict["end"] as? Int,
                      let kind = spanDict["kind"] as? String else {
                    continue
                }
                // speaker can be nil (JSON null) or a String
                let speaker = spanDict["speaker"] as? String  // nil when null

                let key = AtomKey(start: start, end: end, kind: kind, speaker: speaker)
                if !atomSet.contains(key) {
                    missing.append(key)
                }
            }
            if !missing.isEmpty {
                failures.append((drawerID: row.drawerID, missing: missing))
            }
        }

        guard failures.isEmpty else {
            var msg = "\(bed): \(failures.count) row(s) with missing atoms:\n"
            for (drawerID, missing) in failures.prefix(5) {
                msg += "  \(drawerID): missing \(missing.count) span(s)\n"
                for key in missing.prefix(3) {
                    msg += "    \(key)\n"
                }
            }
            Issue.record(Comment(rawValue: msg))
            return
        }
    }
}

// MARK: - Fixture unit tests (5 rows from atoms-fixture-v22.json)

@Suite("AtomFixtureUnit")
struct AtomFixtureUnitTests {

    // MARK: Fixture loader

    struct FixtureEntry {
        let drawerID: String
        let shapePrimary: String
        let mode: String
        let atoms: [[String: Any]]
        let hardIDs: [Int]
        let coverageIDs: [Int]
        let unsupported: [String]
        let speakerTurnsData: [[String: Any]]
    }

    static func loadFixture() -> [FixtureEntry] {
        guard let url = Bundle.module.url(
            forResource: "atoms-fixture-v22",
            withExtension: "json",
            subdirectory: "Vectors"
        ) else {
            preconditionFailure("AtomFixtureUnit: missing atoms-fixture-v22.json in Vectors/")
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { preconditionFailure("AtomFixtureUnit: cannot read fixture: \(error)") }

        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            preconditionFailure("AtomFixtureUnit: malformed atoms-fixture-v22.json")
        }

        return arr.map { d in
            FixtureEntry(
                drawerID: d["drawer_id"] as? String ?? "",
                shapePrimary: d["shape_primary"] as? String ?? "",
                mode: d["mode"] as? String ?? "",
                atoms: d["atoms"] as? [[String: Any]] ?? [],
                hardIDs: d["hard_ids"] as? [Int] ?? [],
                coverageIDs: d["coverage_ids"] as? [Int] ?? [],
                unsupported: d["unsupported"] as? [String] ?? [],
                speakerTurnsData: d["speaker_turns"] as? [[String: Any]] ?? []
            )
        }
    }

    // MARK: speakerTurns unit tests

    /// Dialogue row (A1ADADBD): 55 speaker turns.
    @Test func dialogueSpeakerTurns() throws {
        let fixture = AtomFixtureUnitTests.loadFixture()
        guard let entry = fixture.first(where: { $0.shapePrimary == "dialogue" }) else {
            Issue.record("dialogue fixture entry not found"); return
        }
        let row = findOracleRow(drawerID: entry.drawerID)
        guard let row else { Issue.record("oracle row \(entry.drawerID) not found"); return }

        let turns = speakerTurns(row.original)

        #expect(turns.count == entry.speakerTurnsData.count,
            "dialogue: speakerTurns count \(turns.count) ≠ expected \(entry.speakerTurnsData.count)")

        for (i, (turn, expected)) in zip(turns, entry.speakerTurnsData).enumerated() {
            let eStart = expected["start"] as? Int ?? -1
            let eEnd = expected["end"] as? Int ?? -1
            let eFirstLineEnd = expected["first_line_end"] as? Int ?? -1
            let eBodyStart = expected["body_start"] as? Int ?? -1
            let eSpeaker = expected["speaker"] as? String ?? ""

            #expect(turn.start == eStart,
                "dialogue turn[\(i)].start \(turn.start) ≠ \(eStart)")
            #expect(turn.end == eEnd,
                "dialogue turn[\(i)].end \(turn.end) ≠ \(eEnd)")
            #expect(turn.firstLineEnd == eFirstLineEnd,
                "dialogue turn[\(i)].firstLineEnd \(turn.firstLineEnd) ≠ \(eFirstLineEnd)")
            #expect(turn.bodyStart == eBodyStart,
                "dialogue turn[\(i)].bodyStart \(turn.bodyStart) ≠ \(eBodyStart)")
            #expect(turn.speaker == eSpeaker,
                "dialogue turn[\(i)].speaker \(turn.speaker) ≠ \(eSpeaker)")
        }
    }

    /// Hybrid row (1A976AE7): 7 speaker turns.
    @Test func hybridSpeakerTurns() throws {
        let fixture = AtomFixtureUnitTests.loadFixture()
        guard let entry = fixture.first(where: { $0.shapePrimary == "hybrid" }) else {
            Issue.record("hybrid fixture entry not found"); return
        }
        let row = findOracleRow(drawerID: entry.drawerID)
        guard let row else { Issue.record("oracle row \(entry.drawerID) not found"); return }

        let turns = speakerTurns(row.original)

        #expect(turns.count == entry.speakerTurnsData.count,
            "hybrid: speakerTurns count \(turns.count) ≠ expected \(entry.speakerTurnsData.count)")

        for (i, (turn, expected)) in zip(turns, entry.speakerTurnsData).enumerated() {
            let eStart = expected["start"] as? Int ?? -1
            let eEnd = expected["end"] as? Int ?? -1
            #expect(turn.start == eStart, "hybrid turn[\(i)].start \(turn.start) ≠ \(eStart)")
            #expect(turn.end == eEnd, "hybrid turn[\(i)].end \(turn.end) ≠ \(eEnd)")
            let eSpeaker = expected["speaker"] as? String ?? ""
            #expect(turn.speaker == eSpeaker, "hybrid turn[\(i)].speaker \(turn.speaker) ≠ \(eSpeaker)")
        }
    }

    // MARK: structuredAtoms unit tests

    /// Timeline row (0277CF4B): 7 atoms, document mode.
    @Test func timelineStructuredAtoms() throws {
        let fixture = AtomFixtureUnitTests.loadFixture()
        guard let entry = fixture.first(where: { $0.shapePrimary == "timeline" }) else {
            Issue.record("timeline fixture entry not found"); return
        }
        let row = findOracleRow(drawerID: entry.drawerID)
        guard let row else { Issue.record("oracle row \(entry.drawerID) not found"); return }

        // structuredAtoms for the document-mode rows equals the atom list from _intent_atoms
        let result = intentAtoms(row.original)
        #expect(result.mode == entry.mode, "timeline mode \(result.mode) ≠ \(entry.mode)")
        #expect(result.atoms.count == entry.atoms.count,
            "timeline atoms \(result.atoms.count) ≠ \(entry.atoms.count)")

        for (i, (atom, expected)) in zip(result.atoms, entry.atoms).enumerated() {
            let eStart = expected["start"] as? Int ?? -1
            let eEnd = expected["end"] as? Int ?? -1
            let eKind = expected["kind"] as? String ?? ""
            #expect(atom.start == eStart, "timeline atom[\(i)].start \(atom.start) ≠ \(eStart)")
            #expect(atom.end == eEnd, "timeline atom[\(i)].end \(atom.end) ≠ \(eEnd)")
            #expect(atom.kind == eKind, "timeline atom[\(i)].kind \(atom.kind) ≠ \(eKind)")
        }
    }

    /// Entity-dense row (051A249C): 8 atoms, document mode.
    @Test func entityDenseStructuredAtoms() throws {
        let fixture = AtomFixtureUnitTests.loadFixture()
        guard let entry = fixture.first(where: { $0.shapePrimary == "entity_dense" }) else {
            Issue.record("entity_dense fixture entry not found"); return
        }
        let row = findOracleRow(drawerID: entry.drawerID)
        guard let row else { Issue.record("oracle row \(entry.drawerID) not found"); return }

        let result = intentAtoms(row.original)
        #expect(result.mode == entry.mode, "entity_dense mode \(result.mode) ≠ \(entry.mode)")
        #expect(result.atoms.count == entry.atoms.count,
            "entity_dense atoms \(result.atoms.count) ≠ \(entry.atoms.count)")

        for (i, (atom, expected)) in zip(result.atoms, entry.atoms).enumerated() {
            let eStart = expected["start"] as? Int ?? -1
            let eEnd = expected["end"] as? Int ?? -1
            let eKind = expected["kind"] as? String ?? ""
            #expect(atom.start == eStart, "entity_dense atom[\(i)].start \(atom.start) ≠ \(eStart)")
            #expect(atom.end == eEnd, "entity_dense atom[\(i)].end \(atom.end) ≠ \(eEnd)")
            #expect(atom.kind == eKind, "entity_dense atom[\(i)].kind \(atom.kind) ≠ \(eKind)")
        }
    }

    /// Prose row (6808659B): 2 atoms, document mode.
    @Test func proseStructuredAtoms() throws {
        let fixture = AtomFixtureUnitTests.loadFixture()
        guard let entry = fixture.first(where: { $0.shapePrimary == "prose" }) else {
            Issue.record("prose fixture entry not found"); return
        }
        let row = findOracleRow(drawerID: entry.drawerID)
        guard let row else { Issue.record("oracle row \(entry.drawerID) not found"); return }

        let result = intentAtoms(row.original)
        #expect(result.mode == entry.mode, "prose mode \(result.mode) ≠ \(entry.mode)")
        #expect(result.atoms.count == entry.atoms.count,
            "prose atoms \(result.atoms.count) ≠ \(entry.atoms.count)")
    }

    // MARK: - Oracle row finder

    /// Finds an oracle row by its drawerID prefix across all four beds.
    private func findOracleRow(drawerID: String) -> OracleRow? {
        let prefix = drawerID.prefix(8).uppercased()
        for bed in ["debug7", "sample30", "locomo", "blind200"] {
            let rows = loadOracleRows(bed: bed)
            if let row = rows.first(where: { $0.drawerID.uppercased().hasPrefix(prefix) }) {
                return row
            }
        }
        return nil
    }
}
