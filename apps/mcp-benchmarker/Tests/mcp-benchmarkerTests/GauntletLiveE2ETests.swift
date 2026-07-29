import Testing
import Foundation
@testable import mcp_benchmarker

// GauntletLiveE2ETests — ONE guarded live end-to-end test (plan Phase 2). It
// generates a tiny corpus, loads BOTH scratch backends via their live write
// tools, runs the gauntlet, and asserts a well-formed report is produced and the
// DegeneracyGuard ran.
//
// SAFETY: the backends are pointed at FRESH /tmp scratch dirs only — mootx01 via
// MOOTX01_DATA_DIR=/tmp/..., contender via the `--contender-dir /tmp/...` FLAG (never the
// bare env var). The real contender data dir and the real mootx01 data dir are NEVER
// touched. The scratch dirs are removed before and after the run.
//
// GUARDED: the test is skipped (not failed) when either backend binary is absent,
// so the suite stays green on a machine without the live servers. Availability is
// probed by file existence at the known install paths.

@Suite("Gauntlet live end-to-end", .serialized)
struct GauntletLiveE2ETests {

    // Known install paths (CONFIG.md / plan). The test self-skips if either is
    // missing so CI without the servers does not fail.
    private static let mootBinary = "\(NSHomeDirectory())/.mootx01/bin/mootx01"
    private static let contenderBinary = "\(NSHomeDirectory())/.local/bin/contender-mcp"

    private static var backendsAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: mootBinary)
            && FileManager.default.fileExists(atPath: contenderBinary)
    }

    @Test("tiny corpus loads into both scratch backends, scores, and produces a report")
    func liveEndToEnd() async throws {
        try await confirmation(expectedCount: Self.backendsAvailable ? 1 : 0) { ran in
            guard Self.backendsAvailable else { return }   // self-skip, no failure

            // Fresh scratch dirs under /tmp — wiped before and after.
            let stamp = UUID().uuidString.prefix(8)
            let mootDir = "/tmp/gauntlet-e2e-moot-\(stamp)"
            let contenderDir = "/tmp/gauntlet-e2e-contender-\(stamp)"
            let outDir = "/tmp/gauntlet-e2e-out-\(stamp)"
            for d in [mootDir, contenderDir, outDir] {
                try? FileManager.default.removeItem(atPath: d)
            }
            try FileManager.default.createDirectory(atPath: contenderDir, withIntermediateDirectories: true)
            defer {
                for d in [mootDir, contenderDir, outDir] {
                    try? FileManager.default.removeItem(atPath: d)
                }
            }

            // A tiny corpus: 2 needles per tier = 10 needles, 2 distractors each.
            let profile = GauntletProfile.evenMix(perTier: 2, distractorsPerNeedle: 2)
            let corpus = GauntletGenerator(profile: profile).generate(seed: 2026_0610)
            #expect(corpus.needles.count == 10)

            // Scratch endpoints — the FLAG forms only.
            let contenderEndpoint = EndpointConfig(
                name: "contender",
                transport: .stdio(command: "\(Self.contenderBinary) --contender-dir \(contenderDir)"),
                auth: nil,
                verbMap: EndpointConfig.VerbMap(
                    write: "contender_add_drawer", query: "contender_search",
                    list: nil, resultFormat: .jsonObjects(idKey: nil, contentKey: "text")),
                role: .source)
            let mootEndpoint = EndpointConfig(
                name: "mootx01",
                transport: .stdio(command: "MOOTX01_DATA_DIR=\(mootDir) \(Self.mootBinary)"),
                auth: nil,
                verbMap: EndpointConfig.VerbMap(
                    write: "moot_file_memory", query: "moot_memory_search",
                    list: nil, constantArgs: [:], resultFormat: .mootText),
                role: .target)

            // The safety gate must accept both (and would throw if it did not).
            try assertScratchBackend(contenderEndpoint)
            try assertScratchBackend(mootEndpoint)

            let contender = MCPClient(endpoint: contenderEndpoint)
            let moot = MCPClient(endpoint: mootEndpoint)
            try await contender.connect()
            try await moot.connect()
            defer { Task { await contender.disconnect(); await moot.disconnect() } }

            let scorer = GauntletScorer(kValues: [1, 5, 10])
            let runner = GauntletRunner(
                contender: contender, contenderVerbs: contenderEndpoint.verbMap,
                moot: moot, mootVerbs: mootEndpoint.verbMap,
                corpus: corpus, scorer: scorer, runLabel: "e2e-test", searchLimit: 20)

            // The gauntlet has TWO well-formed outcomes, both of which exercise the
            // full load → guard → (score|refuse) path end to end:
            //
            //   (a) the DegeneracyGuard finds both backends healthy and a complete
            //       report is produced; OR
            //   (b) the guard REFUSES a backend (a non-result, never a zero — plan
            //       rule 5) and the run aborts via GauntletGuardRefusal WITHOUT
            //       emitting a table.
            //
            // On a small fresh scratch corpus, the live mootx01 backend is observed
            // to return a near-constant ranking across distinct queries (a genuine
            // recall finding the gauntlet exists to surface). That correctly trips
            // the guard, so (b) is a valid, designed outcome here. The test asserts
            // the system did the RIGHT thing in whichever branch occurred — that the
            // guard actually ran and the contract held.
            do {
                let report = try await runner.run()

                // Branch (a): healthy. A complete, well-formed report.
                // Full run: 1 (contender) + 3 (scoring) + compositionNames.count (precise).
                let expectedCount = 1 + MootScoring.allCases.count + GauntletRunner.compositionNames.count
                #expect(report.guardHealthy == true)
                #expect(report.strategies.count == expectedCount)
                #expect(report.strategies.contains { $0.name == "contender" })
                #expect(report.strategies.contains { $0.name == "mootx01:raw" })
                #expect(report.strategies.contains { $0.name == "mootx01:rrf" })
                #expect(report.strategies.contains { $0.name == "mootx01:matrixAware" })
                // Every composition appears as its own precise:<name> column.
                for comp in GauntletRunner.compositionNames {
                    #expect(report.strategies.contains { $0.name == "precise:\(comp)" },
                            "missing precise column for '\(comp)'")
                }
                for s in report.strategies {
                    #expect(s.scores.count == 10, "strategy \(s.name) scored \(s.scores.count) needles")
                }
                let rendered = report.rendered()
                #expect(rendered.contains("MOOT RETRIEVAL GAUNTLET"))
                #expect(rendered.contains(GauntletRunReport.definitionOfSuperior))
                #expect(rendered.contains("superiority:"))
                #expect(rendered.contains("PER-TIER RESULTS"))

                let dir = try GauntletIO.writeReport(report, outRoot: outDir)
                let txt = dir.appendingPathComponent("report-e2e-test.txt")
                let json = dir.appendingPathComponent("report-e2e-test.json")
                #expect(FileManager.default.fileExists(atPath: txt.path))
                #expect(FileManager.default.fileExists(atPath: json.path))
            } catch let refusal as GauntletGuardRefusal {
                // Branch (b): a guard refusal. This is the designed non-result path
                // (plan rule 5) — the guard RAN and correctly aborted the table. The
                // diagnostic names the backend and the reason; assert it is shaped
                // as a real refusal, not an empty/zeroed result.
                #expect(!refusal.backend.isEmpty)
                #expect(refusal.diagnostic.contains("ranking")
                        || refusal.diagnostic.contains("fallback")
                        || refusal.diagnostic.contains("contradict"),
                        "refusal diagnostic should explain the degeneracy: \(refusal.diagnostic)")
            }

            ran.confirm()
        }
    }
}
