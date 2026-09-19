import Testing
import Foundation
@testable import mcp_benchmarker

// GauntletReportTests — aggregation math against synthetic per-needle scores.
// Pure: no live backend. Two-endpoint evaluation and its tests live in
// extension packages.

@Suite("Gauntlet report")
struct GauntletReportTests {

    private let kValues = [1, 5, 10]

    private func score(needle: String, tier: NoiseTier, rank: Int?, complete: Double,
                       contam: Int, latency: Double) -> NeedleScore {
        var found: [Int: Bool] = [:]
        for k in kValues { found[k] = (rank.map { $0 <= k }) ?? false }
        return NeedleScore(needleID: needle, tier: tier, foundAtK: found, rank: rank,
                           completeness: complete, contamination: contam,
                           latencySeconds: latency, bytesReturned: 100)
    }

    @Test("aggregate computes mean found@k, MRR, completeness, contamination")
    func aggregateMath() {
        let scores = [
            score(needle: "a", tier: .lexical, rank: 1, complete: 1.0, contam: 0, latency: 0.01),
            score(needle: "b", tier: .lexical, rank: 5, complete: 0.0, contam: 2, latency: 0.03),
        ]
        let agg = StrategyTierAggregate.from(tier: .lexical, scores: scores, kValues: kValues)
        #expect(agg.needleCount == 2)
        #expect(agg.foundAtK[1] == 0.5)        // one of two at rank 1
        #expect(agg.foundAtK[5] == 1.0)        // both within 5
        #expect(abs(agg.mrr - (1.0 + 0.2) / 2) < 1e-9)
        #expect(agg.completeness == 0.5)
        #expect(agg.meanContamination == 1.0)
    }

    // MARK: - Record naming
    //
    // The lane wrote <seed>-gauntlet-v1/report-<label>.json until 2026-08-17: a
    // path fixed by seed and label, so a re-run at one seed replaced the earlier
    // run's record in place. These pin the arm-and-serial name and the refusal.

    private func emptyReport(label: String) -> GauntletRunReport {
        GauntletRunReport(seed: 20260725, runLabel: label, kValues: kValues,
                          distractorsPerNeedle: 4, tierCounts: [.lexical: 2],
                          strategies: [], worstFailures: [], guardHealthy: true)
    }

    private func scratchDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gauntlet-io-\(UUID().uuidString)")
    }

    @Test("Record carries lane, arm and serial, beside its rendered text")
    func recordNameCarriesArmAndSerial() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try GauntletIO.writeReport(emptyReport(label: "official"),
                                             outRoot: dir.path,
                                             runSerial: "20260817T055302Z")
        #expect(url.lastPathComponent == "gauntlet-official-20260817T055302Z.json")
        let names = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(names.contains("gauntlet-official-20260817T055302Z.json"))
        #expect(names.contains("gauntlet-official-20260817T055302Z.txt"))
        // Flat in the pass directory: no per-seed subdirectory to hide in.
        #expect(names.count == 2)
    }

    @Test("Two runs of one seed under one label cannot produce one name")
    func twoRunsOneSeedStayDistinct() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try GauntletIO.writeReport(emptyReport(label: "official"),
                                               outRoot: dir.path,
                                               runSerial: "20260817T055302Z")
        let second = try GauntletIO.writeReport(emptyReport(label: "official"),
                                                outRoot: dir.path,
                                                runSerial: "20260817T210000Z")
        #expect(first != second)
    }

    @Test("Writing a record twice at one serial refuses rather than replaces")
    func repeatedSerialRefuses() throws {
        let dir = scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try GauntletIO.writeReport(emptyReport(label: "official"),
                                       outRoot: dir.path, runSerial: "20260817T055302Z")
        #expect(throws: (any Error).self) {
            _ = try GauntletIO.writeReport(self.emptyReport(label: "official"),
                                           outRoot: dir.path, runSerial: "20260817T055302Z")
        }
    }
}
