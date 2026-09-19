// ThroughputRunner.swift — throughput subcommand: sustained query-load measurement.
//
// Throughput mode drives ONE lane in sustained-load mode for a fixed wall-clock window.
// N parallel workers cycle through the pinned unit subset repeatedly, each restoring
// an estate from cache (--estate-cache require) and issuing one moot_memory_search
// call per cycle. The report counts completed queries and measures latency.
//
// Output: throughput-<lane>-<serial>.json
//   artifact_type = "throughput" (NOT an accuracy file — no recall figures)
//
// Register rule (FINAL_REPORT_2026-08-20 §7):
//   Timing goes to sidecar/throughput files. No recall figures in timing artifacts.

import Foundation

// MARK: - Report type

/// Throughput measurement report. A timing artifact — contains NO recall figures.
///
/// Written to throughput-<lane>-<serial>.json beside --out directory.
/// artifact_type = "throughput" distinguishes this from accuracy reports
/// (lme/locomo/lmeb/membench) and timing sidecars.
struct ThroughputReport: Codable, Sendable {
    /// Always "throughput". Identifies the artifact kind without requiring field-name inspection.
    let artifactType: String
    /// Lane name: "locomo", "longmemeval", "lmeb", or "membench".
    let lane: String
    /// Run serial from --run-id or UTC timestamp.
    let runID: String
    /// Measurement window length in seconds (--window-seconds).
    let windowSeconds: Int
    /// Number of parallel workers (--parallel).
    let parallelWidth: Int
    /// Total queries completed across all workers during the window.
    let queriesCompleted: Int
    /// Queries completed divided by actual elapsed window duration.
    let queriesPerSecond: Double
    /// Nearest-rank p50 of per-query wall-clock latency in seconds.
    let queryLatencyP50Seconds: Double
    /// Nearest-rank p95 of per-query wall-clock latency in seconds.
    let queryLatencyP95Seconds: Double
    /// Binary and protocol identity of the measured mootx01 binary.
    let runIdentity: IdentityEnvironment

    enum CodingKeys: String, CodingKey {
        case artifactType = "artifact_type"
        case lane
        case runID = "run_id"
        case windowSeconds = "window_seconds"
        case parallelWidth = "parallel_width"
        case queriesCompleted = "queries_completed"
        case queriesPerSecond = "queries_per_second"
        case queryLatencyP50Seconds = "query_latency_p50_seconds"
        case queryLatencyP95Seconds = "query_latency_p95_seconds"
        case runIdentity = "run_identity"
    }
}

// MARK: - One-cycle result

/// Result of a single estate-restore + query cycle.
private struct ThroughputCycleResult: Sendable {
    let unitID: String
    let queryLatencySeconds: Double
}

// MARK: - Runner

/// Runs the throughput subcommand.
///
/// Drives one lane in sustained-load mode: N workers cycle through the pinned unit
/// subset repeatedly for `--window-seconds`, each restoring an estate from the cache
/// and issuing one moot_memory_search query. Reports completed-query count,
/// queries-per-second, and p50/p95 latency.
///
/// Currently supports --lane locomo. Other lanes (longmemeval, lmeb, membench)
/// are structurally parallel and use the same estate-cache + seam machinery.
func runThroughput(_ args: [String]) async throws {
    let lane = try requireOption("--lane", in: args)
    guard ["locomo"].contains(lane) else {
        throw MCPError(description:
            "--lane must be 'locomo'; got '\(lane)' (other lanes not yet wired for throughput)")
    }

    switch lane {
    case "locomo":
        try await runThroughputLocomo(args)
    default:
        fatalError("unreachable — lane validated above")
    }
}

// MARK: - LoCoMo throughput lane

/// Runs the LoCoMo lane in throughput mode.
///
/// Each worker cycle:
///   1. Pick the next conversation from the pinned set (round-robin).
///   2. Restore its estate from cache (--estate-cache require).
///   3. Launch mootx01 serve, connect MCP client.
///   4. Issue one moot_memory_search for one question from that conversation.
///   5. Record query-only latency, tear down.
///
/// Workers run concurrently for the window duration and are collected into a single
/// ThroughputReport after the deadline expires.
private func runThroughputLocomo(_ args: [String]) async throws {
    // Required inputs.
    guard let dataFileStr = optionValue("--data-file", in: args) ?? optionValue("--corpus", in: args) else {
        throw MCPError(description: "missing required option --data-file (or --corpus)")
    }
    let datasetPath = URL(fileURLWithPath: dataFileStr)
    guard FileManager.default.fileExists(atPath: datasetPath.path) else {
        throw MCPError(description: "LoCoMo dataset file not found at \(datasetPath.path)")
    }

    let mootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args) ?? optionValue("--binary", in: args) {
        mootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        mootBinary = discovered
        FileHandle.standardError.write(Data(
            "[throughput/locomo] auto-discovered mootx01 at: \(mootBinary)\n".utf8))
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Pass --mootx01-binary <path>.")
    }
    guard FileManager.default.isExecutableFile(atPath: mootBinary) else {
        throw MCPError(description:
            "mootx01 binary not executable at '\(mootBinary)'")
    }

    // Window and concurrency.
    let windowSeconds: Int
    if let w = optionValue("--window-seconds", in: args).flatMap(Int.init) {
        guard w > 0 else {
            throw MCPError(description: "--window-seconds must be a positive integer")
        }
        windowSeconds = w
    } else {
        windowSeconds = 300
    }
    let defaultParallel = max(1, ProcessInfo.processInfo.activeProcessorCount * 4 / 5)
    let parallelWidth: Int
    if let p = optionValue("--parallel", in: args).flatMap(Int.init) {
        guard p >= 1 else {
            throw MCPError(description: "--parallel must be a positive integer")
        }
        parallelWidth = p
    } else {
        parallelWidth = defaultParallel
    }

    // Estate-cache: throughput mode requires the cache — fresh ingest per cycle
    // would measure ingest overhead, not query throughput.
    let estateCacheStr = optionValue("--estate-cache", in: args) ?? "require"
    let estateCache: EstateCacheMode
    switch estateCacheStr {
    case "off":
        throw MCPError(description:
            "--estate-cache off is not supported in throughput mode: "
            + "throughput measures query latency with pre-built estates. "
            + "Use --estate-cache require (the default for throughput).")
    case "reuse":   estateCache = .reuse
    case "require": estateCache = .require
    default:
        throw MCPError(description:
            "--estate-cache must be 'reuse' or 'require' for throughput; got '\(estateCacheStr)'")
    }
    let cacheDir = optionValue("--cache-dir", in: args).map { URL(fileURLWithPath: $0) }

    // Corpus parameters (mirror the locomo lane's defaults for cache-key compatibility).
    let seed = optionValue("--seed", in: args).flatMap(UInt64.init) ?? 20_260_725
    let limit = try parseLimitOption(in: args)
    let offset = optionValue("--offset", in: args).flatMap(Int.init) ?? 0
    let outDir = try resolvedOutputDirectory(in: args)
    let serial = resolveRunSerial(args)

    // Corpus parameters that must match the cache entry's provenance.
    // These match the locomo lane's defaults for the published pre-built cache.
    let encodeBarrier: EncodeBarrier = .drain
    let scratchPosture: ScratchEstatePosture = .plaintextTransient
    let seedPath: SeedPathMode = .batch

    FileHandle.standardOutput.write(Data("[throughput/locomo] loading corpus\n".utf8))
    let corpus = try loadLoCoMoCorpus(from: datasetPath)
    let corpusDigest = fileSha256Hex(path: datasetPath.path) ?? "unknown"
    FileHandle.standardOutput.write(Data(
        ("[throughput/locomo] loaded \(corpus.conversations.count) conversations, "
        + "\(corpus.questions.count) questions\n").utf8))

    // Select the pinned unit subset: shuffle with SplitMix64, apply offset+limit.
    var rng = SplitMix64(seed: seed)
    var shuffled = corpus.questions
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }
    let afterOffset = Array(shuffled.dropFirst(offset))
    let selected: [LoCoMoQuestion]
    if let limit {
        selected = Array(afterOffset.prefix(limit))
    } else {
        selected = afterOffset
    }
    guard !selected.isEmpty else {
        throw MCPError(description: "no units in the pinned subset (check --offset/--limit)")
    }

    // Group questions by conversation so each cycle picks a full conversation.
    // conversationIndex is the 0-based array position in corpus.conversations
    // (not a parsed number from sampleID — see LoCoMoCorpus.swift line 332).
    // Declared let so the dictionary can be safely captured by the task-group closures.
    let questionsByConv: [Int: [LoCoMoQuestion]] = {
        var d: [Int: [LoCoMoQuestion]] = [:]
        for q in selected { d[q.conversationIndex, default: []].append(q) }
        return d
    }()
    let convIndices = questionsByConv.keys.sorted()
    // Build lookup from array position → conversation.
    let convByIndex: [Int: LoCoMoConversation] = Dictionary(
        uniqueKeysWithValues: corpus.conversations.enumerated().map { ($0.offset, $0.element) })

    FileHandle.standardOutput.write(Data(
        ("[throughput/locomo] pinned subset: \(selected.count) questions "
        + "across \(convIndices.count) conversations\n").utf8))
    FileHandle.standardOutput.write(Data(
        "[throughput/locomo] window: \(windowSeconds)s, parallel: \(parallelWidth)\n".utf8))

    // Build provenance for cache key validation.
    let mootVersion = mootBinaryVersion(binaryPath: mootBinary)
    let runProvenance = makeArtifactProvenance(
        benchmark: "locomo",
        variant: "",
        seed: seed,
        encodeBarrier: encodeBarrier,
        posture: scratchPosture,
        seedPath: seedPath,
        corpusDigest: corpusDigest,
        mootx01Version: mootVersion
    )
    let resolvedCacheDir: URL = try resolvedCacheDirEnforcingDriftGate(
        cacheDir: cacheDir,
        outDir: outDir,
        mootBinaryPath: mootBinary,
        estateCache: estateCache
    )

    // Deadline for the window.
    let windowStart = Date()
    let deadline = windowStart.addingTimeInterval(Double(windowSeconds))

    // Shared mutable state accessed via an actor.
    actor ResultsCollector {
        var results: [ThroughputCycleResult] = []
        func append(_ r: ThroughputCycleResult) { results.append(r) }
    }
    let collector = ResultsCollector()

    // Atomic cycle index for round-robin assignment across workers.
    // Each worker picks the next conversation in the cycle by atomically
    // incrementing a shared counter.
    final class AtomicCounter: @unchecked Sendable {
        private var value: Int = 0
        private let lock = NSLock()
        func next(modulo m: Int) -> Int {
            lock.lock()
            defer { lock.unlock() }
            let v = value % m
            value += 1
            return v
        }
    }
    let counter = AtomicCounter()
    let nConvs = convIndices.count

    FileHandle.standardOutput.write(Data("[throughput/locomo] starting workers\n".utf8))

    // Launch N concurrent workers, each cycling until the deadline.
    try await withThrowingTaskGroup(of: Void.self) { group in
        for workerID in 0..<parallelWidth {
            group.addTask {
                while Date() < deadline {
                    // Pick the next conversation round-robin.
                    let slot = counter.next(modulo: nConvs)
                    let convIndex = convIndices[slot]
                    guard let convQuestions = questionsByConv[convIndex],
                          let conversation = convByIndex[convIndex],
                          let question = convQuestions.first else {
                        continue
                    }

                    // Build the cache key for this conversation's estate.
                    let cacheEntry = estateCacheEntryURL(
                        cacheDir: resolvedCacheDir,
                        benchmark: "locomo",
                        variant: "",
                        seed: seed,
                        encodeBarrier: encodeBarrier,
                        posture: scratchPosture,
                        seedPath: seedPath,
                        unitID: conversation.sampleID
                    )

                    // Restore estate from cache (require mode: miss = error).
                    guard let (scratchDir, _): (URL, [LoCoMoManifestEntry]) =
                        try restoreEstateCacheEntry(
                            from: cacheEntry,
                            expectedProvenance: runProvenance,
                            scratchDirFactory: {
                                try loCoMoScratchDir(posture: scratchPosture)
                            })
                    else {
                        // Cache miss: only reaches here when estateCache == .reuse.
                        // With .require, restoreEstateCacheEntry never returns nil;
                        // it throws ArtifactRequiredError instead.
                        FileHandle.standardError.write(Data(
                            ("[throughput/locomo] cache miss for \(conversation.sampleID) "
                            + "(worker \(workerID)) — skipping cycle\n").utf8))
                        continue
                    }

                    // Launch mootx01 serve and connect MCP client.
                    let endpoint = try loCoMoEndpointConfig(
                        scratchDir: scratchDir,
                        mootBinaryPath: mootBinary,
                        posture: scratchPosture
                    )
                    let client = MCPClient(endpoint: endpoint)
                    try await client.connect()

                    var cycleCompleted = false
                    defer {
                        Task { await client.disconnect() }
                        if cycleCompleted {
                            try? retireScratchEstate(
                                scratchDir,
                                expectPlaintext: scratchPosture == .plaintextTransient,
                                teardown: loCoMoGuardedTeardown
                            )
                        } else {
                            keepScratchEstateOnFailure(scratchDir, lane: "throughput/locomo")
                        }
                    }

                    // Issue the query and measure latency (query-only, not estate provisioning).
                    // Build args from the verb map: query text + all constant args
                    // (e.g. location:benchmarks/locomo). Same construction as the
                    // locomo lane's .search strategy path.
                    let queryStart = Date()
                    let queryArgs = AriaV2Surface.memorySearchArgs(verbMap: loCoMoMootVerbMap, query: question.question)
                    _ = try await client.callTool(
                        loCoMoMootVerbMap.query,
                        arguments: queryArgs,
                        format: loCoMoMootVerbMap.resultFormat
                    )
                    let queryLatency = Date().timeIntervalSince(queryStart)
                    cycleCompleted = true

                    await collector.append(ThroughputCycleResult(
                        unitID: question.questionID,
                        queryLatencySeconds: queryLatency
                    ))
                }
            }
        }
        try await group.waitForAll()
    }

    let actualElapsed = Date().timeIntervalSince(windowStart)
    let results = await collector.results
    let latencies = results.map(\.queryLatencySeconds)
    let qps = actualElapsed > 0 ? Double(results.count) / actualElapsed : 0.0

    // Stamp the testname-arm-serial triple before building the report (D1 fix).
    // arm is the constant "locomo"; serial was resolved when the filename was named.
    var throughputIdentity = IdentityEnvironment.collect(mootx01BinaryPath: mootBinary)
    stampTestIdentity(&throughputIdentity, test: "throughput", arm: "locomo", serial: serial)

    let report = ThroughputReport(
        artifactType: "throughput",
        lane: "locomo",
        runID: serial,
        windowSeconds: windowSeconds,
        parallelWidth: parallelWidth,
        queriesCompleted: results.count,
        queriesPerSecond: qps,
        queryLatencyP50Seconds: latencyPercentile(values: latencies, p: 0.50),
        queryLatencyP95Seconds: latencyPercentile(values: latencies, p: 0.95),
        runIdentity: throughputIdentity
    )

    let reportFilename = recordFilename(test: "throughput", arm: "locomo", serial: serial)
    let reportURL = (outDir ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .appendingPathComponent(reportFilename)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let reportData = try encoder.encode(report)
    try writeRecordNeverOverwrite(reportData, to: reportURL)

    let summary = """
        [throughput/locomo] run complete
          window:              \(windowSeconds)s (actual \(String(format: "%.1f", actualElapsed))s)
          parallel:            \(parallelWidth)
          queries completed:   \(results.count)
          queries/second:      \(String(format: "%.2f", qps))
          query p50:           \(String(format: "%.1f", report.queryLatencyP50Seconds * 1000)) ms
          query p95:           \(String(format: "%.1f", report.queryLatencyP95Seconds * 1000)) ms
          report written to:   \(reportURL.path)

        """
    FileHandle.standardOutput.write(Data(summary.utf8))
}

