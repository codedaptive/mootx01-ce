import Foundation

// LongMemEvalRunner.swift — LongMemEval session-recall harness (Part 4).
//
// This runner OWNS the test-estate lifecycle: for each question it provisions
// a fresh scratch estate under /tmp/lme-bench-XXXXXX, launches mootx01 with
// MOOTX01_DATA_DIR pointing at it, ingests haystack sessions via live MCP write,
// queries via live MCP query, records the manifest, and tears down the estate.
//
// Safety guarantees:
//   - lmeScratchDir() names the dir with /tmp/lme-bench- so the teardown guard
//     can distinguish LME scratch dirs from arbitrary /tmp directories.
//   - lmeGuardedTeardown() refuses any path that does not carry the
//     /tmp/lme-bench- prefix; a non-scratch path cannot be passed by mistake.
//   - The built EndpointConfig always carries MOOTX01_DATA_DIR=/tmp/lme-bench-...
//     so assertScratchBackend (GauntletCLI.swift) independently verifies the
//     scratch constraint before any write begins.
//
// Estate strategies:
//   - --fresh-per-question (default): each question gets its own scratch estate.
//     Correct isolation, but slower: O(N) estate provisions.
//   - --shared-estate: all questions share one estate provisioned before the run.
//     Faster, but haystack contamination across questions is methodology-affecting
//     (prior sessions' content can influence recall for later questions).

// MARK: - Verbmap for mootx01 in LME mode

/// Standard mootx01 VerbMap used for LME ingestion + recall queries.
/// Matches the live E2E test's mootEndpoint verbMap convention.
///
/// write:         moot_file_memory
/// query:         moot_memory_search (moot_memory_search default, no override needed)
/// constantArgs:  { "location": "benchmark/longmemeval" }
/// resultFormat:  .mootText
let lmeMootVerbMap = EndpointConfig.VerbMap(
    write: "moot_file_memory",
    query: "moot_memory_search",
    list: nil,
    constantArgs: ["location": "benchmark/longmemeval"],
    resultFormat: .mootText
)

// MARK: - Manifest entry

/// Maps a filed-memory UUID back to its origin in the haystack, enabling the
/// scorer to correlate retrieved UUIDs → session IDs for recall scoring.
struct LMEManifestEntry: Sendable, Codable {
    /// The UUID returned by moot_file_memory ("filed memory <UUID>").
    let uuid: String
    /// The haystack session this turn belongs to.
    let sessionID: String
    /// Zero-based index of this turn within its session.
    let turnIndex: Int
    /// Zero-based index of the session within the question's haystack.
    let sessionIndex: Int
    /// The turn's role: "user" or "assistant".
    let role: String
}

// MARK: - Per-question result

/// The result of running the LME harness against one question.
struct LMEQuestionResult: Sendable {
    /// The question's unique identifier.
    let questionID: String
    /// The question type (non-abstention: not *_abs).
    let questionType: String
    /// Time taken for the moot_memory_search call, in seconds.
    let queryLatencySeconds: Double
    /// UUIDs returned by moot_memory_search, in ranked order.
    let retrievedUUIDs: [String]
    /// Manifest: filed UUID → haystack position for every ingested turn.
    let manifest: [LMEManifestEntry]
    /// Ground truth session IDs that contain evidence for this question.
    let answerSessionIDs: [String]
    /// True when the DegeneracyGuard ran and found the backend healthy.
    /// False means guard refusal — this question's result is excluded from
    /// aggregate scoring.
    let guardHealthy: Bool
    /// If the guard was unhealthy, the diagnostic message.
    let guardDiagnostic: String?
    /// Total number of turns ingested for this question's haystack.
    let turnsIngested: Int
    /// Mean write latency (seconds) across all ingested turns.
    let writeMeanLatencySeconds: Double
}

// MARK: - Run config

/// Configuration for one LME run. Built from CLI arguments in `runLongMemEval`.
struct LMERunConfig: Sendable {
    /// Path to the mootx01 binary. The runner launches it as a stdio MCP server
    /// with MOOTX01_DATA_DIR set to the provisioned scratch estate.
    let mootBinaryPath: String
    /// Path to the LongMemEval variant JSON file (e.g. longmemeval_s_cleaned.json).
    let datasetPath: URL
    /// Variant name for report labelling ("s", "m", or "oracle").
    let variant: String
    /// Maximum number of questions to run. nil = all non-abstention questions.
    let limit: Int?
    /// Skip this many questions from the (seeded-shuffled) question list.
    let offset: Int
    /// Seed for deterministic question shuffling and run reproducibility.
    let seed: UInt64
    /// When true (default), each question gets its own fresh scratch estate.
    /// When false, a single shared estate is used for all questions in the run.
    let freshPerQuestion: Bool
    /// Directory to write the results report. nil = current directory.
    let outDir: URL?
    /// Run label for the report filename and header.
    let runLabel: String
}

// MARK: - Scratch estate management

/// Creates a fresh scratch directory under /tmp/lme-bench-<UUID> for LME use.
/// The /tmp/lme-bench- prefix is the contract with `lmeGuardedTeardown`.
///
/// The UUID suffix guarantees uniqueness across concurrent runs without needing
/// mkdtemp(3) or a subprocess call.
///
/// - Returns: The URL of the created directory.
/// - Throws: `MCPError` when directory creation fails.
func lmeScratchDir() throws -> URL {
    // Build a unique path with the /tmp/lme-bench- prefix.
    // The 8-character UUID prefix gives 32-bit entropy (4B combinations) —
    // more than sufficient for sequential benchmark runs on one machine.
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    let path = "/tmp/lme-bench-\(suffix)"
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    } catch {
        throw MCPError(description: "lmeScratchDir: could not create \(path): \(error)")
    }
}

/// Deletes a scratch directory created by `lmeScratchDir`. Refuses any path
/// that does not carry the `/tmp/lme-bench-` prefix — a contamination guard
/// that mirrors commit 253cebf1's fixture-cleanup guard.
///
/// - Parameter url: The scratch directory to remove.
/// - Throws: `MCPError` when the prefix guard fires. Does NOT throw on
///   FileManager errors (missing dir is a no-op; actual I/O failures are
///   swallowed and logged to stderr).
func lmeGuardedTeardown(_ url: URL) throws {
    let path = url.path
    guard path.hasPrefix("/tmp/lme-bench-") else {
        throw MCPError(description:
            "SAFETY: lmeGuardedTeardown refused to delete '\(path)' — "
            + "path must have the /tmp/lme-bench- prefix. "
            + "Only directories created by lmeScratchDir() may be torn down by this guard.")
    }
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        // Log but do not propagate: a missing or already-deleted scratch dir is
        // not a correctness failure, and a teardown error should not mask the
        // benchmark result.
        FileHandle.standardError.write(Data(
            "[lme] teardown warning: could not remove \(path): \(error)\n".utf8))
    }
}

// MARK: - EndpointConfig builder

/// Builds an EndpointConfig for mootx01 pointing at a scratch estate.
/// The command form is `MOOTX01_DATA_DIR=<scratchDir> <mootBinaryPath>` which:
///   1. Passes assertScratchBackend (scratchDir is always /tmp/lme-bench-*).
///   2. Tells the MCPClient how to launch the server (stdio transport).
///
/// - Parameters:
///   - scratchDir: A directory created by `lmeScratchDir()`.
///   - mootBinaryPath: Path to the mootx01 binary.
/// - Returns: A validated EndpointConfig for this estate.
/// - Throws: `MCPError` via assertScratchBackend when the config does not meet
///   the scratch safety constraint (should not happen for lmeScratchDir output).
func lmeEndpointConfig(scratchDir: URL, mootBinaryPath: String) throws -> EndpointConfig {
    let command = "MOOTX01_DATA_DIR=\(scratchDir.path) \(mootBinaryPath)"
    let endpoint = EndpointConfig(
        name: "mootx01-lme",
        transport: .stdio(command: command),
        auth: nil,
        verbMap: lmeMootVerbMap,
        role: .target
    )
    // Validate scratch constraint before returning — belt-and-suspenders.
    try assertScratchBackend(endpoint)
    return endpoint
}

// MARK: - Runner

/// Runs the LongMemEval harness against a loaded corpus. Returns per-question
/// results with manifest, latency, and guard verdict for each question.
///
/// This function is the implementation of the `longmemeval` subcommand's inner
/// loop. The CLI dispatch in main.swift wraps it with argument parsing and report
/// writing.
func runLMEQuestions(
    questions: [LMEQuestion],
    config: LMERunConfig
) async throws -> [LMEQuestionResult] {
    // Apply offset + limit to the (seeded-shuffled) question list.
    // SplitMix64 is the fleet-standard seeded PRNG (GauntletRNG.swift).
    var rng = SplitMix64(seed: config.seed)
    var shuffled = questions
    // Fisher-Yates shuffle using SplitMix64 for determinism.
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }
    let sliced: [LMEQuestion]
    let afterOffset = Array(shuffled.dropFirst(config.offset))
    if let limit = config.limit {
        sliced = Array(afterOffset.prefix(limit))
    } else {
        sliced = afterOffset
    }

    var results: [LMEQuestionResult] = []
    results.reserveCapacity(sliced.count)

    // Shared-estate path: provision once and reuse for all questions.
    var sharedScratch: URL?
    var sharedClient: MCPClient?
    if !config.freshPerQuestion {
        let scratch = try lmeScratchDir()
        sharedScratch = scratch
        let endpoint = try lmeEndpointConfig(scratchDir: scratch, mootBinaryPath: config.mootBinaryPath)
        let client = MCPClient(endpoint: endpoint)
        try await client.connect()
        sharedClient = client
    }
    defer {
        if !config.freshPerQuestion {
            if let client = sharedClient {
                Task { await client.disconnect() }
            }
            if let scratch = sharedScratch {
                try? lmeGuardedTeardown(scratch)
            }
        }
    }

    for question in sliced {
        // Per-question estate: provision, use, tear down.
        let (client, scratch): (MCPClient, URL?)
        if config.freshPerQuestion {
            let freshScratch = try lmeScratchDir()
            let endpoint = try lmeEndpointConfig(scratchDir: freshScratch,
                                                  mootBinaryPath: config.mootBinaryPath)
            let freshClient = MCPClient(endpoint: endpoint)
            try await freshClient.connect()
            client = freshClient
            scratch = freshScratch
        } else {
            client = sharedClient!
            scratch = nil
        }
        // Defer teardown for this question's estate.
        defer {
            if config.freshPerQuestion {
                Task { await client.disconnect() }
                if let s = scratch { try? lmeGuardedTeardown(s) }
            }
        }

        // Ingest haystack sessions: write each turn via live moot_file_memory.
        var manifest: [LMEManifestEntry] = []
        var writeTimes: [Double] = []
        for (sessionIndex, session) in question.haystackSessions.enumerated() {
            let sessionID = question.haystackSessionIDs[sessionIndex]
            for (turnIndex, turn) in session.enumerated() {
                // Compose the turn content as "role: content" to preserve speaker context.
                let content = "\(turn.role): \(turn.content)"
                var writeArgs: [String: JSONValue] = [
                    lmeMootVerbMap.contentArg: .string(content),
                ]
                for (k, v) in lmeMootVerbMap.constantArgs {
                    writeArgs[k] = .string(v)
                }
                let writeStart = Date()
                let writeResult = try await client.callTool(
                    lmeMootVerbMap.write,
                    arguments: writeArgs,
                    format: lmeMootVerbMap.resultFormat
                )
                let writeDuration = Date().timeIntervalSince(writeStart)
                writeTimes.append(writeDuration)

                if let uuid = writeResult.writeAssignedID {
                    manifest.append(LMEManifestEntry(
                        uuid: uuid,
                        sessionID: sessionID,
                        turnIndex: turnIndex,
                        sessionIndex: sessionIndex,
                        role: turn.role
                    ))
                }
            }
        }

        // DegeneracyGuard probe: issue ≥3 distinct probes before scoring.
        // Uses the same probe queries and classification as the gauntlet path.
        let guard_ = DegeneracyGuard()
        let probeRankings = await probeMCPClient(client, verbMap: lmeMootVerbMap, name: "mootx01-lme")
        let verdict = guard_.classify(probeRankings: probeRankings)
        // Use pattern matching: Verdict has associated values so `==` is unavailable.
        let guardHealthy: Bool
        if case .healthy = verdict { guardHealthy = true } else { guardHealthy = false }
        let guardDiagnostic: String? = guardHealthy ? nil : verdict.diagnostic

        // Query: issue the question text via moot_memory_search.
        var queryArgs: [String: JSONValue] = [
            lmeMootVerbMap.queryArg: .string(question.question),
        ]
        for (k, v) in lmeMootVerbMap.constantArgs { queryArgs[k] = .string(v) }
        let queryStart = Date()
        let queryResult = try await client.callTool(
            lmeMootVerbMap.query,
            arguments: queryArgs,
            format: lmeMootVerbMap.resultFormat
        )
        let queryLatency = Date().timeIntervalSince(queryStart)

        let retrievedUUIDs = queryResult.orderedIDs

        let writeMean = writeTimes.isEmpty ? 0.0 : writeTimes.reduce(0, +) / Double(writeTimes.count)

        results.append(LMEQuestionResult(
            questionID: question.questionID,
            questionType: question.questionType,
            queryLatencySeconds: queryLatency,
            retrievedUUIDs: retrievedUUIDs,
            manifest: manifest,
            answerSessionIDs: question.answerSessionIDs,
            guardHealthy: guardHealthy,
            guardDiagnostic: guardDiagnostic,
            turnsIngested: manifest.count,
            writeMeanLatencySeconds: writeMean
        ))
    }

    return results
}

// MARK: - Default mootx01 binary discovery

/// Probes candidate binary paths in order and returns the first executable one.
/// Falls back to `~/.mootx01/bin/mootx01` (installed binary) then to the CE
/// debug build (relative to the current working directory at invocation time).
///
/// The caller may override with `--mootx01-binary` to short-circuit this search.
func discoverMootBinary() -> String? {
    let candidates = [
        "\(NSHomeDirectory())/.mootx01/bin/mootx01",
        // CE debug build path (swift build --package-path apps/mootx01).
        // The debug path varies by build system; try both Xcode-style and SPM-style.
        ".build/out/Products/Debug/mootx01",
        ".build/debug/mootx01",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}
