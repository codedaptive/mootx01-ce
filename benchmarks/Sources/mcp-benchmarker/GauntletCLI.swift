import Foundation

// GauntletCLI.swift — the `gauntlet-corpus` and `gauntlet` subcommands.
//
// These live in the core library so they REUSE the benchmarker's rails
// directly — MCPClient, Config/VerbMap, DegeneracyGuard, the result parsing,
// Timing — with zero duplication. Core's `gauntlet` is the MOOT-ONLY lane: it
// starts, loads, guards, and scores only the moot backend. A two-endpoint
// lane can be built by an extension subpackage's CLI, which builds a
// `GauntletBaseline` and injects it into the same `GauntletRunner` engine so
// both lanes traverse one call tree.
//
//   mcp-benchmarker gauntlet-corpus --seed N --out DIR [--per-tier N]
//        [--distractors N] [--tiers T1=a,T2=b,...]
//   mcp-benchmarker gauntlet --config c.json --corpus DIR --run-label LABEL
//        [--out DIR] [--k 1,5,10] [--limit N] [--reuse-backends]
//        [--quick] [--moot-only] [--shape disk|ram] [--guard-sample once|per-unit]
//
// --reuse-backends skips the load + dream when the scratch backend already
// holds the corpus (a load-marker beside the backend's data records the seed +
// record count). A missing/mismatched marker loads fresh; the DegeneracyGuard
// still aborts if a reused backend is actually empty.
//
// --quick skips ALL moot_recall_precise composition columns and runs only the
// three moot_memory_search strategy columns (~2-3 min vs ~25 min for the full
// ablation grid). The report carries a clear "QUICK MODE" banner so a
// quick-mode artifact is never mistaken for a full ablation run.
//
// --moot-only is accepted for compatibility with pre-split invocations; the
// core gauntlet is always moot-only, so the flag changes nothing here.
//
// --shape disk|ram (C1, benchmark reset 2026-08-13): when "ram", appends
// --in-memory to the endpoint's stdio command so the served
// mootx01 process selects PersistenceKit's InMemory backend — no keychain
// contact, no SQLite I/O. Default "disk".
//
// --guard-sample once|per-unit (C5): sampling policy for the DegeneracyGuard.
// The gauntlet's guard is structurally once-per-run (one estate, one probe
// batch before all needle scoring), so this flag only affects the JSON label
// in the report sidecar; it does not change run behaviour. Default "once".
//
// SAFETY: `gauntlet` WRITES to its backend. The CLI asserts the scratch
// requirement before constructing the runner: the moot endpoint must carry
// `--db /tmp/...` in its stdio command (a transient catalog record).
// The requirement is expressed as data (`ScratchRequirement`), so a caller
// (e.g. an extension CLI) can assert a different product's scratch form
// through the same mechanism. A config that fails the check aborts before a
// single write.

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

// MARK: - scratch-backend safety gate (config-driven, product-agnostic)

/// The scratch form a backend's stdio command must present before the gauntlet
/// will write to it. Expressed as data so the requirement travels with the
/// caller (core supplies the moot env-key forms; an extension CLI supplies
/// its baseline product's form) instead of being name-matched in code.
/// Single-case by design: `flag` covers the only requirement variant in use
/// (`--db /tmp/...`), and the enum is the extension point if new constraint
/// kinds are added. Preserving the enum (rather than inlining the string)
/// keeps the Swift and Rust call signatures in twin parity —
/// `assertScratchBackend(_:requirement:)` reads identically in both ports
/// regardless of how many cases the enum eventually carries.
public enum ScratchRequirement: Sendable {
    /// The command must pass this flag with a following `/tmp/...` path token
    /// (`--db` for the product's transient record, `--palace` for MemPalace;
    /// a bare env var would leave data on a real store — the historical
    /// contamination bug).
    case flag(String)
}

/// Asserts that an endpoint's stdio command satisfies the scratch requirement.
/// Throws (aborting before any write) when the required form is absent or its
/// path is not under `/tmp`. The `/tmp` prefix is non-negotiable — it is the
/// contamination guard that keeps the gauntlet off any real (non-scratch)
/// data store.
public func assertScratchBackend(_ endpoint: EndpointConfig,
                                 requirement: ScratchRequirement) throws {
    guard case let .stdio(command) = endpoint.transport else {
        throw MCPError(description: "gauntlet requires stdio backends; '\(endpoint.name)' is not stdio")
    }
    switch requirement {
    case .flag(let flag):
        guard command.contains(flag) else {
            throw MCPError(description:
                "SAFETY: backend '\(endpoint.name)' must use the \(flag) FLAG "
                + "(never a bare env var); refusing to write. command=\(command)")
        }
        guard scratchPathIsTmp(afterFlag: flag, in: command) else {
            throw MCPError(description:
                "SAFETY: backend '\(endpoint.name)' \(flag) must point at a /tmp scratch path; "
                + "refusing to write. command=\(command)")
        }
    }
}

/// The moot endpoint's scratch requirement: the `--db` flag (the estate
/// catalog's selector, the same on `mootx01 serve` and `aria-mcp`) pointing at
/// a /tmp scratch directory, which attaches a transient record there. No
/// environment value selects an estate any more.
public let mootScratchRequirement = ScratchRequirement.flag(mootServeDatabaseFlag)

/// True when the token following `flag` in the whitespace-split command begins
/// with `/tmp` (a scratch path). Used to verify a `<flag> /tmp/...` form.
///
/// Accepts `/tmp/` prefix as written by `mootServeCommand`; the Swift product
/// resolves paths through `MootProductIdentity`, which returns an unresolved
/// `/tmp/…` form on macOS. The Rust twin (`scratch_path_is_tmp`) additionally
/// accepts the canonical `/private/tmp/` form because Rust's
/// `std::fs::canonicalize` resolves the `/tmp` symlink on macOS before the
/// check. Both forms are valid scratch paths; the split between them is a
/// toolchain artefact, not a semantic difference.
public func scratchPathIsTmp(afterFlag flag: String, in command: String) -> Bool {
    let parts = command.split(separator: " ").map(String.init)
    guard let i = parts.firstIndex(of: flag), i + 1 < parts.count else { return false }
    // Strict: `/tmp` itself or a path below it. A bare `hasPrefix("/tmp")`
    // would pass `/tmp.evil/estates`, the contamination guard's own trap.
    let path = parts[i + 1]
    return path == "/tmp" || path.hasPrefix("/tmp/")
}

/// The scratch directory a backend persists into, parsed from its stdio command
/// according to its scratch requirement, so reuse can place a load-marker
/// beside the data and decide whether a reload is needed. Returns nil when no
/// recognizable scratch path is present (reuse is then declined and the corpus
/// loads fresh).
/// The directory is the token after the requirement's flag.
public func scratchDirectory(for endpoint: EndpointConfig,
                             requirement: ScratchRequirement) -> URL? {
    guard case let .stdio(command) = endpoint.transport else { return nil }
    let parts = command.split(separator: " ").map(String.init)
    switch requirement {
    case .flag(let flag):
        guard let i = parts.firstIndex(of: flag), i + 1 < parts.count else { return nil }
        return URL(fileURLWithPath: parts[i + 1], isDirectory: true)
    }
}

/// The load-marker file beside a backend's scratch data. Its presence AND
/// matching contents (corpus seed + record count) mean the backend already holds
/// this exact corpus, so reuse may skip the (re)load.
public func loadMarkerURL(inScratchDir dir: URL) -> URL {
    dir.appendingPathComponent(".gauntlet-loaded")
}

/// True when the marker exists and records exactly this seed and record count.
/// Any mismatch (different corpus, partial write, absent file) reads as false so
/// the caller loads fresh — the safe default.
public func loadMarkerMatches(_ url: URL, seed: UInt64, recordCount: Int) -> Bool {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    return lines.count >= 2 && lines[0] == "\(seed)" && lines[1] == "\(recordCount)"
}

// MARK: - gauntlet run subcommand (moot-only)

/// Selects the moot endpoint from a config by its write-verb prefix (`moot_`),
/// regardless of which role slot it occupies. Throws when neither endpoint is
/// recognizably moot.
func mootEndpoint(in config: BenchmarkerConfig) throws -> EndpointConfig {
    let endpoints = [config.source, config.target]
    guard let moot = endpoints.first(where: { $0.verbMap.write.hasPrefix("moot_") }) else {
        throw MCPError(description:
            "gauntlet config must contain a mootx01 endpoint (write moot_*); got writes "
            + "[\(config.source.verbMap.write), \(config.target.verbMap.write)]")
    }
    return moot
}

/// gauntlet subcommand — load a corpus into the moot scratch backend, run every
/// needle under moot_memory_search×{raw,rrf,matrixAware} + the
/// moot_recall_precise composition grid, score, and write the report. A
/// DegeneracyGuard refusal aborts the table (non-zero exit, no report).
///
/// --quick skips the precise composition grid (~20 min bulk) so an iteration
/// run completes in ~2-3 min. The report header flags QUICK MODE clearly.
///
/// --seed-path live|batch (default batch): how the mootx01 estate is seeded.
/// batch (default, ruling 8D5B8053): one moot_json_import per estate, then
/// waitForEncodeDrain, then moot_dream. live: per-record moot_file_memory
/// (retained for periodic equivalence re-proving).
func runGauntlet(_ args: [String]) async throws {
    let configPath = try requireOption("--config", in: args)
    let corpusDir = try requireOption("--corpus", in: args)
    let runLabel = try requireOption("--run-label", in: args)
    // Default output root: benchmarks/results/<seed>-gauntlet-v1/ (untracked) — the
    // seed comes from the loaded corpus so the path is determined by the data.
    let outRoot = optionValue("--out", in: args)
    let kValues = (optionValue("--k", in: args)?.split(separator: ",")
        .compactMap { Int($0) }).flatMap { $0.isEmpty ? nil : $0 } ?? [1, 5, 10]
    let searchLimit = (try parseLimitOption(in: args)) ?? 20
    // --quick: skip the moot_recall_precise composition grid for a fast iteration run.
    let quickMode = flagPresent("--quick", in: args)
    // --moot-only is accepted for compatibility with pre-split invocations;
    // this lane is always moot-only, so the flag changes nothing.
    _ = flagPresent("--moot-only", in: args)
    // --seed-path live|batch (default batch): batch is the mandated path
    // (ruling 8D5B8053); live is retained for equivalence re-proving.
    let seedPath = try SeedPathMode.parse(optionValue("--seed-path", in: args))
    // C1 (benchmark reset 2026-08-13): estate storage shape. "ram" injects
    // --in-memory into the endpoint command so the served mootx01
    // process uses PersistenceKit's InMemory backend — no keychain, no SQLite.
    let shapeRaw = optionValue("--shape", in: args) ?? "disk"
    guard let shape = BenchRunShape(rawValue: shapeRaw) else {
        throw MCPError(description: "--shape must be 'disk' or 'ram'; got '\(shapeRaw)'")
    }
    // C5 (benchmark reset 2026-08-13): guard sampling policy. The gauntlet's
    // DegeneracyGuard is structurally once-per-run (one shared estate), so
    // this flag only affects the JSON sidecar label; it does not alter the guard
    // execution path. Default "once" mirrors the per-unit-estate lanes' default.
    let guardSamplingPolicy = try GuardSamplingPolicy.parse(optionValue("--guard-sample", in: args))

    let config = try BenchmarkerConfig.load(from: URL(fileURLWithPath: configPath))

    let endpoint = try mootEndpoint(in: config)

    // Extract the moot binary path from the endpoint stdio command so RunEnvironment
    // can call `mootx01 --version` for version + build-date provenance.
    let mootBinaryForEnv: String? = {
        guard case let .stdio(command) = endpoint.transport else { return nil }
        // Skip leading VAR=value env assignments (env-prefix semantics, mirrors MCPClient). A token
        // is an assignment when everything before its first "=" is uppercase/digit/underscore.
        return command.split(separator: " ")
            .map(String.init)
            .first(where: { part in
                guard let eq = part.firstIndex(of: "=") else { return true }
                let key = part[part.startIndex ..< eq]
                return !key.allSatisfy({ $0.isUppercase || $0 == "_" || $0.isNumber })
            })
    }()

    // SAFETY GATE: assert the backend is scratch before any write. The
    // assertion runs on the original endpoint (before shape injection) because
    // shape injection only appends a flag; the scratch path token is unchanged.
    try assertScratchBackend(endpoint, requirement: mootScratchRequirement)

    // C1: apply the estate storage shape. When --shape ram, append --in-memory
    // to the stdio command so the served mootx01 process selects
    // PersistenceKit's InMemory backend. No effect for disk.
    let shapeEndpoint = applyBackendShape(shape, to: endpoint)

    let corpus = try GauntletIO.loadCorpus(fromDirectory: corpusDir)

    // Connect using the shape-modified endpoint. The shape-modified command is what
    // actually launches the mootx01 process — disk leaves the command unchanged;
    // ram appends --in-memory so PersistenceKit's InMemory backend is selected.
    // The scratch-dir computation uses the original endpoint: the --db token
    // is the one after the flag (scratchDirectory(for:requirement:) walks tokens).
    let moot = try await connectedClient(for: shapeEndpoint)
    defer { Task { await moot.disconnect() } }

    // Reuse: skip the load + dream when the persisted estate already holds this
    // corpus, gated on the load-marker; a missing/mismatched marker falls back
    // to a fresh load, and the DegeneracyGuard still aborts if a reused backend
    // is actually empty.
    let reuseAll = flagPresent("--reuse-backends", in: args)
    let mootScratchDir = scratchDirectory(for: endpoint, requirement: mootScratchRequirement)
    let mootMarker = mootScratchDir.map(loadMarkerURL(inScratchDir:))
    let reuseMoot = reuseAll && mootMarker.map {
        loadMarkerMatches($0, seed: corpus.seed, recordCount: corpus.records.count)
    } == true

    let scorer = GauntletScorer(kValues: kValues)
    let runner = GauntletRunner(
        moot: moot, mootVerbs: shapeEndpoint.verbMap,
        corpus: corpus, scorer: scorer, runLabel: runLabel, searchLimit: searchLimit,
        reuseMoot: reuseMoot, mootMarker: mootMarker,
        quickMode: quickMode,
        seedPath: seedPath, scratchDir: mootScratchDir)

    // Capture provenance before the run so the timestamp records when queries
    // start (not when the report is serialized). The SHA is "unknown" + a warning
    // when git is absent — a distribution build or a CI environment without the
    // git binary still produces a valid report; the absence is explicit.
    let gitSHA = captureGitSHA()
    let gitDirty = captureGitDirtyCount()
    let runTimestamp = ISO8601DateFormatter().string(from: Date())
    let allColumns = GauntletRunner.columns()
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
    // and the JSON sidecar carry the SHA, timestamp, column inventory, and machine
    // profile. RunEnvironment.collect runs mootx01 --version synchronously; it
    // degrades gracefully to "unknown" when the binary is absent or times out.
    report.gitSHA = gitSHA
    report.gitDirtyCount = gitDirty
    report.runTimestamp = runTimestamp
    // C1/C5/C6 lane-standard fields (benchmark reset 2026-08-13).
    report.shape = shape.rawValue
    report.guardSampling = guardSamplingPolicy.rawValue
    // parallelUnits stays 1: the gauntlet's shared backend precludes independent
    // parallel units (see GauntletRunner.run() comment for the full rationale).
    report.parallelUnits = 1
    report.columnsRun = runColumns.map(\.name)
    report.compositionListVersion = GauntletRunner.compositionNames
    let runEnv = RunEnvironment.collect(
        mootx01BinaryPath: mootBinaryForEnv,
        runMode: optionValue("--run-mode", in: args) ?? "unspecified")
    report.runEnvironment = runEnv

    // Write the record as gauntlet-<run label>-<serial>.json into --out, with
    // the rendered text beside it, and append the run to the pass ledger. The
    // serial is --run-id when the caller supplies one and a UTC stamp
    // otherwise, so two runs of one seed under one label stay distinct.
    let runSerial = resolveRunSerial(args)
    let recordURL = try GauntletIO.writeReport(report, outRoot: outRoot, runSerial: runSerial)
    if let outRoot {
        try appendToLedger(
            "gauntlet\t\(runLabel)\t\(recordURL.lastPathComponent)"
                + "\tneedles=\(report.tierCounts.values.reduce(0, +))"
                + "\tstrategies=\(report.strategies.count)",
            at: URL(fileURLWithPath: outRoot).appendingPathComponent("records.tsv"))
    }
    FileHandle.standardOutput.write(Data(report.rendered().utf8))
    FileHandle.standardOutput.write(Data("\nreport written to \(recordURL.path)\n".utf8))
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
public func captureGitDirtyCount() -> Int {
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

public func captureGitSHA() -> String {
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

// MARK: - C1 shape injection (appends --in-memory for the RAM shape)

/// Returns a copy of `endpoint` with `--in-memory` appended to its stdio
/// command when `shape == .ram`. When `shape == .disk` or the transport is
/// not stdio, the original endpoint is returned unchanged.
///
/// The flag is appended (not prepended) so the token order remains
/// `<binary> serve --db <dir> --in-memory`; a leading `--in-memory` would
/// be consumed by `/usr/bin/env` as the program name. The `--db` scratch
/// token the gauntlet's requirement checks is untouched.
func applyBackendShape(_ shape: BenchRunShape, to endpoint: EndpointConfig) -> EndpointConfig {
    guard shape == .ram, case let .stdio(command) = endpoint.transport,
          !command.split(separator: " ").contains(Substring(mootServeInMemoryFlag)) else {
        return endpoint
    }
    return EndpointConfig(
        name: endpoint.name,
        transport: .stdio(command: "\(command) \(mootServeInMemoryFlag)"),
        auth: endpoint.auth,
        verbMap: endpoint.verbMap,
        role: endpoint.role
    )
}
