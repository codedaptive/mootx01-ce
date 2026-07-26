import Foundation

// GauntletCLI.swift — the `gauntlet-corpus` and `gauntlet` subcommands (Phase 2).
//
// These live in the benchmarker target (rather than a sibling package) so they
// REUSE the benchmarker's rails directly — MCPClient, Config/VerbMap,
// DegeneracyGuard, the result parsing, Timing — with zero duplication and zero
// changes to the existing benchmarker files. The plan calls for "a new gauntlet
// capability beside the benchmarker that reuses its transports, verbMap, result
// decoding, and DegeneracyGuard"; a subcommand in the same target is the tightest
// fit for that (a sibling package would force the benchmarker's internal types to
// become a public library surface — a large, unjustified blast radius).
//
//   mcp-benchmarker gauntlet-corpus --seed N --out DIR [--per-tier N]
//        [--distractors N] [--tiers T1=a,T2=b,...]
//   mcp-benchmarker gauntlet --config c.json --corpus DIR --run-label LABEL
//        [--out DIR] [--k 1,5,10] [--limit N] [--reuse-backends] [--reuse-mempalace]
//        [--quick] [--moot-only]
//
// --reuse-backends skips the load + dream when both scratch backends already
// hold the corpus (a load-marker beside each backend's data records the seed +
// record count). It turns an ablation sweep from "re-pay MemPalace's Chroma load
// every run" into "load once, then query-only" — the per-iteration cost drops to
// the query phase. A missing/mismatched marker loads fresh; the DegeneracyGuard
// still aborts if a reused backend is actually empty.
//
// --quick skips ALL moot_recall_precise composition columns and runs only the
// MemPalace baseline + three moot_memory_search strategy columns (~2-3 min vs
// ~25 min for the full ablation grid). The report carries a clear "QUICK MODE"
// banner so a quick-mode artifact is never mistaken for a full ablation run.
//
// --moot-only suppresses MemPalace process startup, corpus loading, guard probes,
// and report columns. Corpus generation, MOOT writes, dreaming, query arguments,
// scoring, and the MOOT DegeneracyGuard remain unchanged. This supports current
// product retests without silently presenting historical MemPalace data as a
// live comparison.
//
// SAFETY: `gauntlet` WRITES to both backends. The CLI asserts the scratch flag
// forms before constructing the runner: mootx01 must carry MOOTX01_DATA_DIR=/tmp
// or ARIA_MCP_SQLITE_PATH=/tmp in its stdio command, and MemPalace must carry
// the `--palace /tmp` FLAG (never the bare env var).
// A config that fails these checks aborts before a single write.

// MARK: - corpus generation subcommand

/// Parses a `--tiers T1=a,T2=b,...` spec into per-tier counts. Absent tiers get
/// the `--per-tier` default. An unparseable token is a usage error.
func parseTierSpec(_ spec: String?, perTierDefault: Int) throws -> [NoiseTier: Int] {
    var counts: [NoiseTier: Int] = [:]
    for tier in NoiseTier.allCases { counts[tier] = perTierDefault }
    guard let spec, !spec.isEmpty else { return counts }
    for token in spec.split(separator: ",") {
        let pair = token.split(separator: "=", maxSplits: 1)
        guard pair.count == 2, let tier = NoiseTier(rawValue: String(pair[0])),
              let n = Int(pair[1]), n >= 0 else {
            throw MCPError(description: "bad --tiers token '\(token)' (expected T1=N,…)")
        }
        counts[tier] = n
    }
    return counts
}

/// gauntlet-corpus subcommand — emits corpus.jsonl + needles.json for a seed.
func runGauntletCorpus(_ args: [String]) throws {
    guard let seedStr = optionValue("--seed", in: args), let seed = UInt64(seedStr) else {
        throw MCPError(description: "missing or invalid required option --seed (a 64-bit unsigned integer)")
    }
    let outDir = try requireOption("--out", in: args)
    let perTier = optionValue("--per-tier", in: args).flatMap(Int.init) ?? 4
    let distractors = optionValue("--distractors", in: args).flatMap(Int.init) ?? 4
    let tierCounts = try parseTierSpec(optionValue("--tiers", in: args), perTierDefault: perTier)

    let profile = GauntletProfile(tierCounts: tierCounts, distractorsPerNeedle: distractors)
    let corpus = GauntletGenerator(profile: profile).generate(seed: seed)

    let (corpusURL, needlesURL) = try GauntletIO.writeCorpus(corpus, toDirectory: outDir)
    let summary = """
    gauntlet-corpus: seed \(seed)
      needles:   \(corpus.needles.count)
      records:   \(corpus.records.count)
      distractors/needle: \(corpus.distractorsPerNeedle)
      tier profile: \(NoiseTier.allCases.compactMap { t in corpus.tierCounts[t].map { "\(t.rawValue)=\($0)" } }.joined(separator: " "))
      corpus.jsonl → \(corpusURL.path)
      needles.json → \(needlesURL.path)

    """
    FileHandle.standardOutput.write(Data(summary.utf8))
}

// MARK: - gauntlet run subcommand

/// Asserts that an endpoint's transport points at a SCRATCH backend per the plan
/// safety rules. Throws (aborting before any write) when the scratch form is
/// absent. mootx01 must carry `MOOTX01_DATA_DIR=/tmp` in its stdio command;
/// MemPalace must carry the `--palace /tmp` FLAG.
func assertScratchBackend(_ endpoint: EndpointConfig) throws {
    guard case let .stdio(command) = endpoint.transport else {
        throw MCPError(description: "gauntlet requires stdio backends; '\(endpoint.name)' is not stdio")
    }
    let lower = command.lowercased()
    let isMoot = lower.contains("mootx01") || endpoint.verbMap.write.hasPrefix("moot_")
    let isMem = lower.contains("mempalace") || endpoint.verbMap.write.hasPrefix("mempalace_")
    if isMem {
        // The FLAG form is mandatory — the bare env var leaves the KG on the real
        // palace (the contamination bug). Require `--palace` AND a /tmp target.
        guard command.contains("--palace") else {
            throw MCPError(description:
                "SAFETY: MemPalace backend '\(endpoint.name)' must use the --palace FLAG "
                + "(never the bare env var); refusing to write. command=\(command)")
        }
        guard scratchPathIsTmp(afterFlag: "--palace", in: command) else {
            throw MCPError(description:
                "SAFETY: MemPalace --palace must point at a /tmp scratch path; refusing to write. "
                + "command=\(command)")
        }
    } else if isMoot {
        // Two valid scratch forms, both pinned to /tmp:
        //   • MOOTX01_DATA_DIR=/tmp/...     — the legacy data-dir scratch estate.
        //   • ARIA_MCP_SQLITE_PATH=/tmp/... — the aria-mcp durable-estate scratch
        //     form (the env var that selects an explicit on-disk SQLite estate and
        //     lights up semantic recall). The old warm config wrongly used
        //     MOOTX01_DATA_DIR for aria-mcp; ARIA_MCP_SQLITE_PATH is the correct
        //     selector for that binary.
        // The /tmp prefix is non-negotiable — it is the contamination guard that
        // keeps the gauntlet off any real (non-scratch) estate.
        //
        // NOTE: a raw `command.contains("KEY=/tmp")` substring check would pass
        // a path like `MOOTX01_DATA_DIR=/tmp.evil/estates` because "/tmp" is a
        // prefix of "/tmp.evil". Use `scratchEnvVarIsTmp` which parses the
        // token by splitting on the FIRST `=` and checks the VALUE independently.
        let hasDataDir = scratchEnvVarIsTmp(key: "MOOTX01_DATA_DIR", in: command)
        let hasSqlitePath = scratchEnvVarIsTmp(key: "ARIA_MCP_SQLITE_PATH", in: command)
        guard hasDataDir || hasSqlitePath else {
            throw MCPError(description:
                "SAFETY: mootx01 backend '\(endpoint.name)' must set MOOTX01_DATA_DIR=/tmp/... "
                + "OR ARIA_MCP_SQLITE_PATH=/tmp/... (scratch estate); refusing to write. "
                + "command=\(command)")
        }
    } else {
        throw MCPError(description:
            "SAFETY: backend '\(endpoint.name)' is neither recognizably mootx01 nor MemPalace; "
            + "refusing to write to an unverified backend.")
    }
}

/// True when the token following `flag` in the whitespace-split command begins
/// with `/tmp` (a scratch path). Used to verify `--palace /tmp/...`.
func scratchPathIsTmp(afterFlag flag: String, in command: String) -> Bool {
    let parts = command.split(separator: " ").map(String.init)
    guard let i = parts.firstIndex(of: flag), i + 1 < parts.count else { return false }
    return parts[i + 1].hasPrefix("/tmp")
}

/// True when a `KEY=VALUE` token in the whitespace-split command sets `key` to a
/// path under `/tmp`. The value is extracted by splitting on the FIRST `=` so
/// that a value containing `=` characters (e.g. a base64 path component) is
/// handled correctly. This avoids a substring-match false positive: a raw
/// `command.contains("KEY=/tmp")` check would pass `KEY=/tmp.evil/path` because
/// "/tmp" is a prefix of "/tmp.evil". This helper checks that the parsed value
/// is either exactly `/tmp` or begins with `/tmp/`.
func scratchEnvVarIsTmp(key: String, in command: String) -> Bool {
    let prefix = "\(key)="
    let parts = command.split(separator: " ").map(String.init)
    guard let token = parts.first(where: { $0.hasPrefix(prefix) }) else { return false }
    // Split on the first `=` only so values containing `=` are preserved intact.
    let value = String(token.dropFirst(prefix.count))
    return value == "/tmp" || value.hasPrefix("/tmp/")
}

/// The scratch directory a backend persists into, parsed from its stdio command,
/// so `--reuse-backends` can place a load-marker beside the data and decide
/// whether a reload is needed. Returns nil when no recognizable scratch path is
/// present (reuse is then declined and the corpus loads fresh).
///   • MemPalace:  the directory is the token after the `--palace` flag.
///   • mootx01:    `ARIA_MCP_SQLITE_PATH=<file>` → the file's PARENT directory;
///                 `MOOTX01_DATA_DIR=<dir>`       → that directory directly.
func scratchDirectory(for endpoint: EndpointConfig) -> URL? {
    guard case let .stdio(command) = endpoint.transport else { return nil }
    let parts = command.split(separator: " ").map(String.init)
    if let i = parts.firstIndex(of: "--palace"), i + 1 < parts.count {
        return URL(fileURLWithPath: parts[i + 1], isDirectory: true)
    }
    if let token = parts.first(where: { $0.hasPrefix("ARIA_MCP_SQLITE_PATH=") }) {
        let path = String(token.dropFirst("ARIA_MCP_SQLITE_PATH=".count))
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }
    if let token = parts.first(where: { $0.hasPrefix("MOOTX01_DATA_DIR=") }) {
        let path = String(token.dropFirst("MOOTX01_DATA_DIR=".count))
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    return nil
}

/// The load-marker file beside a backend's scratch data. Its presence AND
/// matching contents (corpus seed + record count) mean the backend already holds
/// this exact corpus, so `--reuse-backends` may skip the (re)load.
func loadMarkerURL(inScratchDir dir: URL) -> URL {
    dir.appendingPathComponent(".gauntlet-loaded")
}

/// True when the marker exists and records exactly this seed and record count.
/// Any mismatch (different corpus, partial write, absent file) reads as false so
/// the caller loads fresh — the safe default.
func loadMarkerMatches(_ url: URL, seed: UInt64, recordCount: Int) -> Bool {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    return lines.count >= 2 && lines[0] == "\(seed)" && lines[1] == "\(recordCount)"
}

/// gauntlet subcommand — load a corpus into both scratch backends, run every
/// needle under MemPalace + mootx01×{raw,rrf,matrixAware} + the
/// moot_recall_precise composition grid, score, and write the report. A
/// DegeneracyGuard refusal aborts the table (non-zero exit, no report).
///
/// --quick skips the precise composition grid (~20 min bulk) so an iteration
/// run completes in ~2-3 min. The report header flags QUICK MODE clearly.
func runGauntlet(_ args: [String]) async throws {
    let configPath = try requireOption("--config", in: args)
    let corpusDir = try requireOption("--corpus", in: args)
    let runLabel = try requireOption("--run-label", in: args)
    // Default output root: tools/mcp-benchmarker/results/<seed>-gauntlet-v1/ — the
    // seed comes from the loaded corpus so the path is determined by the data.
    let outRoot = optionValue("--out", in: args)
    let kValues = (optionValue("--k", in: args)?.split(separator: ",")
        .compactMap { Int($0) }).flatMap { $0.isEmpty ? nil : $0 } ?? [1, 5, 10]
    let searchLimit = optionValue("--limit", in: args).flatMap(Int.init) ?? 20
    // --quick: skip the moot_recall_precise composition grid for a fast iteration run.
    let quickMode = flagPresent("--quick", in: args)
    let mootOnly = flagPresent("--moot-only", in: args)

    let config = try BenchmarkerConfig.load(from: URL(fileURLWithPath: configPath))

    // SAFETY GATE: assert both backends are scratch before any write.
    try assertScratchBackend(config.source)
    try assertScratchBackend(config.target)

    // Identify which configured endpoint is MemPalace and which is mootx01 by
    // their write-verb prefix (the config convention is source=MemPalace,
    // target=mootx01, but identify by verb so a swapped config still works).
    let (memEndpoint, mootEndpoint) = try classifyEndpoints(config)

    let corpus = try GauntletIO.loadCorpus(fromDirectory: corpusDir)

    let moot = try await connectedClient(for: mootEndpoint)
    let mempalace = mootOnly ? moot : try await connectedClient(for: memEndpoint)
    defer {
        Task {
            if !mootOnly { await mempalace.disconnect() }
            await moot.disconnect()
        }
    }

    // Per-backend reuse: MemPalace is a fixed external baseline whose ~20-min
    // Chroma load is the dominant per-run cost, so it should load ONCE and be
    // reused thereafter; mootx01 reloads fresh each run (its ingestion changes
    // with the code under test). `--reuse-mempalace` reuses ONLY MemPalace;
    // `--reuse-backends` reuses both. Each is gated on its own load-marker; a
    // missing/mismatched marker falls back to a fresh load for that backend, and
    // the DegeneracyGuard still aborts if a reused backend is actually empty.
    let reuseAll = flagPresent("--reuse-backends", in: args)
    let reuseMemFlag = flagPresent("--reuse-mempalace", in: args)
    let memMarker = scratchDirectory(for: memEndpoint).map(loadMarkerURL(inScratchDir:))
    let mootMarker = scratchDirectory(for: mootEndpoint).map(loadMarkerURL(inScratchDir:))
    func markerMatches(_ m: URL?) -> Bool {
        guard let m else { return false }
        return loadMarkerMatches(m, seed: corpus.seed, recordCount: corpus.records.count)
    }
    let reuseMem = (reuseAll || reuseMemFlag) && markerMatches(memMarker)
    let reuseMoot = reuseAll && markerMatches(mootMarker)
    if (reuseAll || reuseMemFlag), !reuseMem {
        FileHandle.standardError.write(Data((
            "reuse: requested but no matching MemPalace load-marker (seed \(corpus.seed), "
            + "\(corpus.records.count) records) — loading MemPalace fresh; marker written for next time.\n").utf8))
    }

    let scorer = GauntletScorer(kValues: kValues)
    let runner = GauntletRunner(
        mempalace: mempalace, memVerbs: memEndpoint.verbMap,
        moot: moot, mootVerbs: mootEndpoint.verbMap,
        corpus: corpus, scorer: scorer, runLabel: runLabel, searchLimit: searchLimit,
        reuseMem: reuseMem, reuseMoot: reuseMoot, memMarker: memMarker, mootMarker: mootMarker,
        quickMode: quickMode, mootOnly: mootOnly)

    // Capture provenance before the run so the timestamp records when queries
    // start (not when the report is serialized). The SHA is "unknown" + a warning
    // when git is absent — a distribution build or a CI environment without the
    // git binary still produces a valid report; the absence is explicit.
    let gitSHA = captureGitSHA()
    let gitDirty = captureGitDirtyCount()
    let runTimestamp = ISO8601DateFormatter().string(from: Date())
    let allColumns = GauntletRunner.columns().filter { !mootOnly || $0.isMootx01 }
    let runColumns = quickMode ? allColumns.filter { !$0.usesPreciseTool } : allColumns

    var report: GauntletRunReport
    do {
        report = try await runner.run()
    } catch let refusal as GauntletGuardRefusal {
        // A guard refusal is a non-result, never a zero (plan rule 5). Print the
        // diagnostic and exit non-zero WITHOUT writing a table.
        FileHandle.standardError.write(Data((refusal.description + "\n").utf8))
        exit(1)
    }

    // Wire provenance into the report before writing so both the rendered text
    // and the JSON sidecar carry the SHA, timestamp, and column inventory.
    report.gitSHA = gitSHA
    report.gitDirtyCount = gitDirty
    report.runTimestamp = runTimestamp
    report.columnsRun = runColumns.map(\.name)
    report.compositionListVersion = GauntletRunner.compositionNames

    // Write the report (rendered text + JSON sidecar) under
    // results/<seed>-gauntlet-v1/ (or --out). The run label is part of the file
    // name so multiple runs of one seed do not clobber each other.
    let resultsDir = try GauntletIO.writeReport(report, outRoot: outRoot)
    FileHandle.standardOutput.write(Data(report.rendered().utf8))
    FileHandle.standardOutput.write(Data("\nreport written to \(resultsDir.path)\n".utf8))
}

/// Runs `git rev-parse HEAD` in the current working directory and returns the
/// 40-character SHA. Returns "unknown" when git is absent or the directory is
/// not a git repository, and writes a one-line warning to stderr so the absence
/// is never silent. The working directory is used (not this binary's path) so
/// the SHA reflects the source the benchmarker was built from, not the binary's
/// install location.
/// Counts dirty (modified/staged/untracked) paths in the working tree at run
/// time. In this repo "right commit, dirty half-applied worker" is a REAL state
/// — a report that cannot say so is not provenance. -1 = git unavailable.
func captureGitDirtyCount() -> Int {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["status", "--porcelain"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()
    do { try proc.run(); proc.waitUntilExit() } catch { return -1 }
    guard proc.terminationStatus == 0 else { return -1 }
    let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return raw.split(separator: "\n").count
}

func captureGitSHA() -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    proc.arguments = ["rev-parse", "HEAD"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = Pipe()    // swallow git's own errors; we emit our own
    do {
        try proc.run()
        proc.waitUntilExit()
    } catch {
        FileHandle.standardError.write(Data(
            "gauntlet provenance: git not available — SHA recorded as 'unknown' (\(error))\n".utf8))
        return "unknown"
    }
    let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                     encoding: .utf8) ?? ""
    let sha = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if sha.isEmpty || proc.terminationStatus != 0 {
        FileHandle.standardError.write(Data(
            "gauntlet provenance: git rev-parse HEAD failed (not a git repo?) — SHA recorded as 'unknown'\n".utf8))
        return "unknown"
    }
    return sha
}

/// Returns (memPalaceEndpoint, mootx01Endpoint) from a config, identifying each
/// by its write-verb prefix. Throws when the config does not contain exactly one
/// of each.
func classifyEndpoints(_ config: BenchmarkerConfig) throws -> (mem: EndpointConfig, moot: EndpointConfig) {
    let endpoints = [config.source, config.target]
    let mem = endpoints.first { $0.verbMap.write.hasPrefix("mempalace_") }
    let moot = endpoints.first { $0.verbMap.write.hasPrefix("moot_") }
    guard let mem, let moot else {
        throw MCPError(description:
            "gauntlet config must contain one MemPalace endpoint (write mempalace_*) and one "
            + "mootx01 endpoint (write moot_*); got writes "
            + "[\(config.source.verbMap.write), \(config.target.verbMap.write)]")
    }
    return (mem, moot)
}
