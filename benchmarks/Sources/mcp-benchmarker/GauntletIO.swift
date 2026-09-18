import Foundation

// GauntletIO.swift — serialization for the gauntlet artifacts (Phase 2).
//
// Three things are written/read:
//   - corpus.jsonl  : one JSON record per line, in deterministic emission order.
//   - needles.json  : the ground-truth manifest (seed + needles + tier).
//   - the run report: a rendered .txt + a .json sidecar holding the full
//     per-needle scores and the worst-10 retained request/response pairs.
//
// Paths embed the seed (and, for the report, the run label) so artifacts from
// different seeds/runs never collide. The report path is
// results/<seed>-gauntlet-v1/ exactly as the plan specifies (line 143), with the
// run label distinguishing repeated runs of one seed.

public enum GauntletIO {

    /// The on-disk shape of needles.json: the seed + difficulty profile + the
    /// ground-truth needles. Self-describing so a reader needs nothing else to
    /// score a backend against this corpus.
    struct NeedlesFile: Codable {
        let seed: UInt64
        let distractorsPerNeedle: Int
        let tierCounts: [String: Int]   // tier raw value → needle count
        let needles: [Needle]
    }

    /// Writes corpus.jsonl + needles.json into `directory` (created if absent),
    /// returning the two written file URLs. The corpus filename embeds the seed.
    public static func writeCorpus(_ corpus: GauntletCorpus, toDirectory directory: String)
        throws -> (corpus: URL, needles: URL) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // corpus.jsonl — one record per line. Sorted keys so the bytes are stable
        // for a given corpus (the determinism gate compares these bytes).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var jsonl = Data()
        for record in corpus.records {
            jsonl.append(try encoder.encode(record))
            jsonl.append(0x0A)  // newline
        }
        let corpusURL = dir.appendingPathComponent("corpus-\(corpus.seed).jsonl")
        try jsonl.write(to: corpusURL)

        // needles.json — the ground truth.
        var tierCounts: [String: Int] = [:]
        for (tier, count) in corpus.tierCounts { tierCounts[tier.rawValue] = count }
        let needlesFile = NeedlesFile(seed: corpus.seed,
                                      distractorsPerNeedle: corpus.distractorsPerNeedle,
                                      tierCounts: tierCounts,
                                      needles: corpus.needles)
        let prettyEncoder = JSONEncoder()
        prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let needlesURL = dir.appendingPathComponent("needles-\(corpus.seed).json")
        try prettyEncoder.encode(needlesFile).write(to: needlesURL)

        return (corpusURL, needlesURL)
    }

    /// Loads a corpus back from a directory holding corpus-<seed>.jsonl +
    /// needles-<seed>.json. The seed and difficulty profile come from the needles
    /// file; the records come from the jsonl. Throws when either file is missing
    /// or malformed.
    public static func loadCorpus(fromDirectory directory: String) throws -> GauntletCorpus {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(atPath: dir.path)
        guard let needlesName = entries.first(where: { $0.hasPrefix("needles-") && $0.hasSuffix(".json") }) else {
            throw MCPError(description: "no needles-<seed>.json found in \(directory)")
        }
        guard let corpusName = entries.first(where: { $0.hasPrefix("corpus-") && $0.hasSuffix(".jsonl") }) else {
            throw MCPError(description: "no corpus-<seed>.jsonl found in \(directory)")
        }
        let needlesData = try Data(contentsOf: dir.appendingPathComponent(needlesName))
        let needlesFile = try JSONDecoder().decode(NeedlesFile.self, from: needlesData)

        let corpusData = try Data(contentsOf: dir.appendingPathComponent(corpusName))
        let decoder = JSONDecoder()
        var records: [GauntletRecord] = []
        for line in corpusData.split(separator: 0x0A, omittingEmptySubsequences: true) {
            records.append(try decoder.decode(GauntletRecord.self, from: Data(line)))
        }

        var tierCounts: [NoiseTier: Int] = [:]
        for (raw, count) in needlesFile.tierCounts {
            if let tier = NoiseTier(rawValue: raw) { tierCounts[tier] = count }
        }
        return GauntletCorpus(seed: needlesFile.seed,
                              records: records,
                              needles: needlesFile.needles,
                              tierCounts: tierCounts,
                              distractorsPerNeedle: needlesFile.distractorsPerNeedle)
    }

    /// The JSON sidecar shape for a run report: the header fields, the full
    /// per-needle scores per strategy, and the worst-10 retained failures.
    struct ReportSidecar: Codable {
        struct ScoreRow: Codable {
            let needleID: String
            let tier: String
            let foundAtK: [String: Bool]
            let rank: Int?
            let completeness: Double
            let contamination: Int
            let latencySeconds: Double
            let bytesReturned: Int
        }
        struct StrategyRows: Codable {
            let name: String
            let isMootx01: Bool
            let scores: [ScoreRow]
        }
        struct FailureRow: Codable {
            let strategyName: String
            let needleID: String
            let tier: String
            let query: String
            let request: String
            let response: String
            let reason: String
        }
        let seed: UInt64
        let runLabel: String
        let kValues: [Int]
        // Provenance fields — enables stale-report detection and self-description.
        let gitSHA: String
        let runTimestamp: String
        let columnsRun: [String]
        let compositionListVersion: [String]
        /// The caller-supplied header epilogue (a caller supplying a baseline
        /// column wires its evaluation text here; empty for a moot-only run).
        let headerEpilogue: String
        let guardHealthy: Bool
        // Lane standard fields (C1/C4/C5/C6 — benchmark reset 2026-08-13)
        let shape: String
        let guardSampling: String
        let parallelUnits: Int
        let timingReport: String?
        let timingSampling: String
        let strategies: [StrategyRows]
        let worstFailures: [FailureRow]
    }

    /// Writes the run report into `outRoot` as `gauntlet-<arm>-<serial>.json`
    /// plus the rendered `.txt` beside it, and returns the JSON record's URL.
    /// The arm is the run label; the serial identifies the run.
    ///
    /// Both files are written no-clobber. Until 2026-08-17 this lane wrote
    /// `<seed>-gauntlet-v1/report-<label>.json`, a path determined entirely by
    /// seed and label: two runs of one seed under one label resolved to one
    /// file and the second silently replaced the first, which is what happened
    /// on 2026-08-17 when a re-run overwrote a voided run. Carrying the arm and
    /// the serial in the name is the same contract every other lane follows
    /// (see `recordFilename`), and it puts the record in the pass directory
    /// beside its params sidecar rather than in a subdirectory of its own.
    public static func writeReport(_ report: GauntletRunReport,
                                   outRoot: String?,
                                   runSerial: String) throws -> URL {
        let root: URL
        if let outRoot {
            root = URL(fileURLWithPath: outRoot, isDirectory: true)
        } else {
            root = defaultResultsRoot()
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Rendered text report — the human-readable view of the same run.
        let txtName = recordFilename(test: "gauntlet", arm: report.runLabel,
                                     serial: runSerial, ext: "txt")
        try writeRecordNeverOverwrite(Data(report.rendered().utf8),
                                      to: root.appendingPathComponent(txtName))

        // The record: full per-needle data.
        let sidecar = buildSidecar(report)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let jsonName = recordFilename(test: "gauntlet", arm: report.runLabel, serial: runSerial)
        let jsonURL = root.appendingPathComponent(jsonName)
        try writeRecordNeverOverwrite(try encoder.encode(sidecar), to: jsonURL)

        return jsonURL
    }

    /// Builds the JSON sidecar from a report.
    private static func buildSidecar(_ report: GauntletRunReport) -> ReportSidecar {
        let strategies = report.strategies.map { s in
            ReportSidecar.StrategyRows(
                name: s.name, isMootx01: s.isMootx01,
                scores: s.scores.map { sc in
                    var found: [String: Bool] = [:]
                    for (k, v) in sc.foundAtK { found[String(k)] = v }
                    return ReportSidecar.ScoreRow(
                        needleID: sc.needleID, tier: sc.tier.rawValue, foundAtK: found,
                        rank: sc.rank, completeness: sc.completeness,
                        contamination: sc.contamination, latencySeconds: sc.latencySeconds,
                        bytesReturned: sc.bytesReturned)
                })
        }
        let failures = report.worstFailures.map { f in
            ReportSidecar.FailureRow(
                strategyName: f.strategyName, needleID: f.needleID, tier: f.tier.rawValue,
                query: f.query, request: f.request, response: f.response, reason: f.reason)
        }
        return ReportSidecar(
            seed: report.seed, runLabel: report.runLabel, kValues: report.kValues,
            gitSHA: report.gitSHA,
            runTimestamp: report.runTimestamp,
            columnsRun: report.columnsRun,
            compositionListVersion: report.compositionListVersion,
            headerEpilogue: report.headerEpilogue,
            guardHealthy: report.guardHealthy,
            shape: report.shape,
            guardSampling: report.guardSampling,
            parallelUnits: report.parallelUnits,
            timingReport: report.timingReport,
            timingSampling: report.timingSampling,
            strategies: strategies, worstFailures: failures)
    }

    /// The tool's default results root: benchmarks/results. Derived
    /// from this source file's path (benchmarks/Sources/mcp-benchmarker/GauntletIO.swift).
    /// Three levels up from this file reaches benchmarks/.
    public static func defaultResultsRoot() -> URL {
        // benchmarks/results/ is untracked run output (gitignored) — raw run
        // artifacts are never committed; curated write-ups are authored
        // separately. Operators direct runs elsewhere with --out.
        URL(fileURLWithPath: #filePath)        // benchmarks/Sources/mcp-benchmarker/GauntletIO.swift
            .deletingLastPathComponent()        // benchmarks/Sources/mcp-benchmarker
            .deletingLastPathComponent()        // benchmarks/Sources
            .deletingLastPathComponent()        // benchmark
            .appendingPathComponent("results")
    }
}
