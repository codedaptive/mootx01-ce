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

enum GauntletIO {

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
    static func writeCorpus(_ corpus: GauntletCorpus, toDirectory directory: String)
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
    static func loadCorpus(fromDirectory directory: String) throws -> GauntletCorpus {
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
        let definitionOfSuperior: String
        let superiorityVerdict: String
        let guardHealthy: Bool
        let strategies: [StrategyRows]
        let worstFailures: [FailureRow]
    }

    /// Writes the run report as a rendered .txt and a .json sidecar into
    /// `outRoot`/<seed>-gauntlet-v1/ (default outRoot = the tool's results/ dir).
    /// Returns the directory written. The run label is part of each file name so
    /// repeated runs of one seed do not clobber.
    static func writeReport(_ report: GauntletRunReport, outRoot: String?) throws -> URL {
        let root: URL
        if let outRoot {
            root = URL(fileURLWithPath: outRoot, isDirectory: true)
        } else {
            root = defaultResultsRoot()
        }
        let dir = root.appendingPathComponent("\(report.seed)-gauntlet-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Rendered text report.
        let txtURL = dir.appendingPathComponent("report-\(report.runLabel).txt")
        try Data(report.rendered().utf8).write(to: txtURL)

        // JSON sidecar with the full data.
        let sidecar = buildSidecar(report)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let jsonURL = dir.appendingPathComponent("report-\(report.runLabel).json")
        try encoder.encode(sidecar).write(to: jsonURL)

        return dir
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
            definitionOfSuperior: GauntletRunReport.definitionOfSuperior,
            superiorityVerdict: report.superiorityVerdict(),
            guardHealthy: report.guardHealthy,
            strategies: strategies, worstFailures: failures)
    }

    /// The tool's default results root: apps/mcp-benchmarker/results. Derived
    /// from this source file's path (apps/mcp-benchmarker/Sources/mcp-benchmarker/GauntletIO.swift).
    /// CE has no swift-bench/ wrapper; 3 levels up reaches apps/mcp-benchmarker/.
    static func defaultResultsRoot() -> URL {
        URL(fileURLWithPath: #filePath)        // apps/mcp-benchmarker/Sources/mcp-benchmarker/GauntletIO.swift
            .deletingLastPathComponent()        // apps/mcp-benchmarker/Sources/mcp-benchmarker
            .deletingLastPathComponent()        // apps/mcp-benchmarker/Sources
            .deletingLastPathComponent()        // apps/mcp-benchmarker
            .appendingPathComponent("results")
    }
}
