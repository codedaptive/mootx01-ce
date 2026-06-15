// CompositionGridSyncTests.swift
//
// GRID SYNC ENFORCEMENT — asserts that NeuronKit.CompositionGrid.all produces
// exactly the composition name set recorded in the package-local fixture file:
//
//   packages/kits/NeuronKit/conformance/composition-grid.json
//
// That fixture is ALSO what the benchmarker's AblationColumnsTests derive
// their expected list from, so any divergence between NeuronKit's real grid
// and the benchmarker's column list surfaces as a test failure here AND there —
// not as a silent drift that only shows up when a stale gauntlet report is
// mistaken for post-change truth.
//
// The fixture lives inside NeuronKit's own package tree so CE builds (which
// do not ship tools/) can resolve it without reaching outside the package.
//
// NOTE ON "vector": NeuronKit.CompositionGrid.all contains "vector" because the
// signal still exists (used inside weighted-all). The benchmarker omits the
// standalone "vector" column (it is byte-identical to "hamming" as a gauntlet
// column). The fixture contains the BENCHMARKER'S list (omitting "vector"). This
// test therefore checks the fixture subset — all fixture names must appear in
// CompositionGrid.all, in order — rather than strict equality. If a name in the
// fixture is absent from the kit grid, the test fails and the grid must be updated.

import Testing
import Foundation
@testable import NeuronKit

// MARK: - fixture path

/// Resolves packages/kits/NeuronKit/conformance/composition-grid.json from
/// this test file's location — package-local so CE builds (which do not
/// ship tools/) can resolve it without referencing the repo root:
///   packages/kits/NeuronKit/Tests/NeuronKitTests/CompositionGridSyncTests.swift
///     → NeuronKitTests/  (deletingLastPathComponent ×1)
///     → Tests/           (×2)
///     → NeuronKit/       (×3 — package root)
///     → NeuronKit/conformance/composition-grid.json
private func compositionGridFixturePath(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()   // NeuronKitTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // NeuronKit/ (package root)
        .appendingPathComponent("conformance")
        .appendingPathComponent("composition-grid.json")
}

/// Loads the authoritative composition name list from the package-local
/// fixture. Throws when the file is missing or malformed.
private func loadFixtureCompositions() throws -> [String] {
    let url = compositionGridFixturePath()
    let data = try Data(contentsOf: url)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let names = json["compositionNames"] as? [String] else {
        throw NSError(
            domain: "CompositionGridSyncTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "composition-grid.json missing or malformed (expected top-level compositionNames array). "
                + "Path: \(compositionGridFixturePath().path)"])
    }
    return names
}

// MARK: - tests

@Suite("CompositionGridSyncTests")
struct CompositionGridSyncTests {

    /// Every name in the benchmarker fixture must exist in NeuronKit.CompositionGrid.all.
    /// If a name is present in the fixture but missing from the kit, the benchmarker
    /// sends a composition arg the kit cannot resolve — silent wrong results at run time.
    /// Fail here instead, loudly, at build time.
    @Test("every fixture composition name exists in CompositionGrid.all")
    func fixtureNamesExistInGrid() throws {
        let fixtureNames = try loadFixtureCompositions()
        let gridNames = Set(NeuronKit.CompositionGrid.all.map(\.name))
        for name in fixtureNames {
            #expect(gridNames.contains(name),
                    "composition '\(name)' is in the benchmarker fixture but missing from NeuronKit.CompositionGrid.all — add it or update the fixture")
        }
    }

    /// No name in the fixture is duplicated in the kit grid. Duplicates in the
    /// grid mean the benchmarker sends a name that resolves ambiguously.
    @Test("CompositionGrid.all has no duplicate names")
    func noDuplicateNamesInGrid() {
        let names = NeuronKit.CompositionGrid.all.map(\.name)
        let dupes = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys
        #expect(dupes.isEmpty,
                "duplicate composition names in CompositionGrid.all: \(dupes.sorted())")
    }

    /// The fixture's composition list is in the same relative order as the kit's
    /// grid (excluding names the benchmarker intentionally omits, e.g. "vector").
    /// Order stability is required: the benchmarker column list is emitted in
    /// declaration order and the leaderboard is stable across runs only when the
    /// column order is stable.
    @Test("fixture composition order matches CompositionGrid.all order (excluding benchmarker omissions)")
    func fixtureOrderMatchesGrid() throws {
        let fixtureNames = try loadFixtureCompositions()
        let gridNames = NeuronKit.CompositionGrid.all.map(\.name)
        // Filter the grid to only names the fixture includes (the benchmarker's subset).
        let gridSubset = gridNames.filter { fixtureNames.contains($0) }
        #expect(gridSubset == fixtureNames,
                "fixture order diverged from CompositionGrid.all order — update the fixture to match the kit's declaration order")
    }
}
