import Testing
import Foundation
@testable import mcp_benchmarker

// AblationColumnsTests — the reduction-ablation column wiring and the
// leaderboard render. Pure: no live backend. Proves the gauntlet exposes every
// composition as its own column, that the column set is stable, and that the
// leaderboard ranks deterministically.
//
// SYNC-TEST ENFORCEMENT: the expected composition list is NOT hardcoded here.
// It is loaded from packages/kits/NeuronKit/conformance/composition-grid.json —
// the NeuronKit-owned fixture that BOTH this test and NeuronKit's
// CompositionGridSyncTests assert against. NeuronKit owns the fixture so that
// CE builds (which do not ship tools/) can resolve it. The benchmarker is EE-only
// and reaches the same package-local path from the repo root.
// If GauntletRunner.compositionNames or NeuronKit.CompositionGrid.all drifts
// from the fixture, the relevant test fails. That is the intended behavior: a
// divergence between the benchmarker column list and NeuronKit's registry is
// a test failure, not a silent drift.

// MARK: - fixture loading

/// Resolves packages/kits/NeuronKit/conformance/composition-grid.json from
/// this test file's location. NeuronKit owns the fixture (CE-portability
/// requirement: tools/ is EE-only and is not shipped to CE). The benchmarker
/// lives at apps/mcp-benchmarker/ (CE flat layout, no swift-bench/ subdir)
/// and walks up to the repo root to reach the same file:
///   .../apps/mcp-benchmarker/Tests/mcp-benchmarkerTests/AblationColumnsTests.swift
///     → mcp-benchmarkerTests/ (×1)
///     → Tests/                (×2)
///     → mcp-benchmarker/      (×3)
///     → apps/                 (×4)
///     → repo root             (×5)
///     → packages/kits/NeuronKit/conformance/composition-grid.json
///
/// CE path note: EE had an extra swift-bench/ level (×6 deletions); CE uses
/// the package-root-flat layout, so one fewer deletion is needed (×5).
private func compositionGridFixturePath(file: String = #filePath) -> URL {
    URL(fileURLWithPath: file)
        .deletingLastPathComponent()   // mcp-benchmarkerTests/
        .deletingLastPathComponent()   // Tests/
        .deletingLastPathComponent()   // mcp-benchmarker/ (CE: no swift-bench level)
        .deletingLastPathComponent()   // apps/
        .deletingLastPathComponent()   // repo root
        .appendingPathComponent("packages")
        .appendingPathComponent("kits")
        .appendingPathComponent("NeuronKit")
        .appendingPathComponent("conformance")
        .appendingPathComponent("composition-grid.json")
}

/// Loads the authoritative composition name list from the NeuronKit-owned
/// fixture file. Throws when the file is missing or malformed — a missing
/// fixture is a test infrastructure failure, not a test skip.
private func loadFixtureCompositions() throws -> [String] {
    let url = compositionGridFixturePath()
    let data = try Data(contentsOf: url)
    // The fixture is {"_comment": "...", "compositionNames": [...]}
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let names = json["compositionNames"] as? [String] else {
        throw NSError(domain: "AblationColumnsTests",
                      code: 1,
                      userInfo: [NSLocalizedDescriptionKey:
                        "composition-grid.json missing or malformed (expected top-level compositionNames array)"])
    }
    return names
}

@Suite("Ablation columns + leaderboard")
struct AblationColumnsTests {

    /// The authoritative composition list loaded from the shared fixture file.
    /// Both GauntletRunner.compositionNames and this list must match the fixture;
    /// a mismatch is a test failure, not a warning.
    private var fixtureCompositions: [String] {
        get throws { try loadFixtureCompositions() }
    }

    @Test("columns include mempalace, the three search strategies, and every composition")
    func columnSet() throws {
        let expected = try fixtureCompositions
        let cols = GauntletRunner.columns()
        let names = cols.map(\.name)
        #expect(names.first == "mempalace")
        #expect(names.contains("mootx01:raw"))
        #expect(names.contains("mootx01:rrf"))
        #expect(names.contains("mootx01:matrixAware"))
        for comp in expected {
            #expect(names.contains("precise:\(comp)"),
                    "missing ablation column for composition '\(comp)'")
        }
        // Exactly one column per composition; no duplicates.
        #expect(cols.count == 1 + MootScoring.allCases.count + expected.count)
    }

    @Test("precise columns carry a composition and use the precise tool; search columns do not")
    func columnKinds() {
        for col in GauntletRunner.columns() {
            if col.name.hasPrefix("precise:") {
                #expect(col.composition != nil)
                #expect(col.scoring == nil)
                #expect(col.usesPreciseTool)
            } else if col.name.hasPrefix("mootx01:") {
                #expect(col.scoring != nil)
                #expect(col.composition == nil)
                #expect(!col.usesPreciseTool)
            }
        }
    }

    /// Proves that GauntletRunner.compositionNames exactly matches the
    /// NeuronKit-owned fixture file. If the benchmarker's list is updated
    /// without updating the fixture (or vice versa), this test fails. That is
    /// the contract: both sides must stay in sync with the fixture, not just
    /// with each other.
    @Test("GauntletRunner.compositionNames matches the NeuronKit composition-grid.json fixture")
    func gridMirrorMatchesFixture() throws {
        let fixture = try fixtureCompositions
        #expect(GauntletRunner.compositionNames == fixture,
                "GauntletRunner.compositionNames diverged from packages/kits/NeuronKit/conformance/composition-grid.json — update the fixture or the benchmarker list to match")
    }

    // DETERMINISM CONTRACT. The gauntlet is deterministic on QUALITY (found@k,
    // MRR, completeness, contamination) — latency is wall-clock and excluded.
    // The live two-run proof (E vs F) confirmed all precise ablation columns
    // (currently 22 composition names in GauntletRunner) bit-identical on quality. This pure test locks the contract that the
    // report's quality projection is a function of the scores ALONE, independent
    // of latency: two reports with identical NeedleScore quality but different
    // latency render identical quality rows.
    @Test("quality table is deterministic: identical scores → identical quality rows, latency aside")
    func qualityDeterministicAcrossLatency() {
        let kValues = [1, 5, 10]
        func score(_ tier: NoiseTier, rank: Int?, latency: Double) -> NeedleScore {
            var found: [Int: Bool] = [:]
            for k in kValues { found[k] = (rank.map { $0 <= k }) ?? false }
            return NeedleScore(needleID: "n", tier: tier, foundAtK: found, rank: rank,
                               completeness: 1.0, contamination: 1,
                               latencySeconds: latency, bytesReturned: 100)
        }
        func report(latency: Double) -> GauntletRunReport {
            let s = StrategyResult.build(
                name: "precise:weighted-all", isMootx01: true,
                scores: [score(.lexical, rank: 1, latency: latency),
                         score(.semantic, rank: 2, latency: latency)],
                kValues: kValues)
            return GauntletRunReport(
                seed: 1, runLabel: "det", kValues: kValues, distractorsPerNeedle: 4,
                tierCounts: [.lexical: 1, .semantic: 1], strategies: [s],
                worstFailures: [], guardHealthy: true)
        }
        // Strip the two trailing latency numbers from each rendered table row.
        func qualityRows(_ r: GauntletRunReport) -> [String] {
            r.rendered().split(separator: "\n").map(String.init)
                .filter { $0.contains("precise:") || $0.contains("f@1") }
                .map { line in
                    // Drop the trailing lat_ms + p95_ms tokens (last two numbers).
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    return parts.dropLast(line.contains("f@1") ? 0 : 2).joined(separator: " ")
                }
        }
        #expect(qualityRows(report(latency: 0.01)) == qualityRows(report(latency: 0.99)))
    }

    @Test("leaderboard ranks by found@1 then MRR and names the winner deterministically")
    func leaderboardRanks() {
        let kValues = [1, 5, 10]
        func score(_ needle: String, _ tier: NoiseTier, rank: Int?) -> NeedleScore {
            var found: [Int: Bool] = [:]
            for k in kValues { found[k] = (rank.map { $0 <= k }) ?? false }
            return NeedleScore(needleID: needle, tier: tier, foundAtK: found, rank: rank,
                               completeness: 1.0, contamination: 0,
                               latencySeconds: 0.01, bytesReturned: 100)
        }
        // Column A finds at rank 1; column B at rank 3. A must win.
        let a = StrategyResult.build(
            name: "precise:tokenExact", isMootx01: true,
            scores: [score("n", .lexical, rank: 1)], kValues: kValues)
        let b = StrategyResult.build(
            name: "precise:matrix", isMootx01: true,
            scores: [score("n", .lexical, rank: 3)], kValues: kValues)
        let report = GauntletRunReport(
            seed: 1, runLabel: "test", kValues: kValues, distractorsPerNeedle: 4,
            tierCounts: [.lexical: 1], strategies: [b, a], worstFailures: [],
            guardHealthy: true)
        let rendered = report.rendered()
        #expect(rendered.contains("ABLATION LEADERBOARD"))
        // The winner line for the lexical tier names the rank-1 column.
        #expect(rendered.contains("winner: precise:tokenExact"))
        // Rendering is deterministic.
        #expect(report.rendered() == rendered)
    }

    // MARK: — Provenance tests

    /// Proves the rendered report header carries all required provenance fields.
    /// A report with no provenance set renders placeholder values, not silence —
    /// so an artifact is always self-describing about its provenance state.
    @Test("rendered report header carries provenance fields")
    func provenanceInHeader() {
        var report = GauntletRunReport(
            seed: 42, runLabel: "prov-test", kValues: [1, 5], distractorsPerNeedle: 4,
            tierCounts: [:], strategies: [], worstFailures: [], guardHealthy: true)
        report.gitSHA = "abc1234"
        report.runTimestamp = "2026-06-12T00:00:00Z"
        report.columnsRun = ["mempalace", "mootx01:raw"]
        report.compositionListVersion = ["text", "hamming"]

        let rendered = report.rendered()
        #expect(rendered.contains("git SHA:"))
        #expect(rendered.contains("abc1234"))
        #expect(rendered.contains("run timestamp:"))
        #expect(rendered.contains("2026-06-12T00:00:00Z"))
        #expect(rendered.contains("columns run:"))
        #expect(rendered.contains("mempalace"))
        #expect(rendered.contains("composition grid:"))
        #expect(rendered.contains("text"))
    }

    /// Proves an unset provenance renders placeholder strings, never blank lines.
    @Test("unset provenance renders placeholders not blank lines")
    func provenancePlaceholdersWhenUnset() {
        let report = GauntletRunReport(
            seed: 1, runLabel: "unset", kValues: [1], distractorsPerNeedle: 0,
            tierCounts: [:], strategies: [], worstFailures: [], guardHealthy: true)
        let rendered = report.rendered()
        // Default gitSHA is "unknown"; timestamp placeholder is "(not set)".
        #expect(rendered.contains("unknown"))
        #expect(rendered.contains("(not set)"))
        // Unset column lists render as "(not recorded)".
        #expect(rendered.contains("(not recorded)"))
    }
}
