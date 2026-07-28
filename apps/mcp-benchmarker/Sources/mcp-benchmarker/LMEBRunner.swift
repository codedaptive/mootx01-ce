import Foundation

// LMEBRunner.swift — LMEB/ConvoMem retrieval harness.
//
// This runner OWNS the test-estate lifecycle: for each query it provisions a
// fresh scratch estate under /tmp/lmeb-bench-XXXXXX, launches mootx01 with
// MOOTX01_DATA_DIR pointing at it, ingests candidate documents via live MCP
// write, queries via live MCP query, records the UUID→docID manifest, scores,
// and tears down the estate.
//
// Key differences from LongMemEvalRunner.swift:
//   - Ground truth is a SET OF DOCUMENT IDs (not session IDs). The retrieval
//     scope per query is the scene's candidate pool (10–168 docs), not all 500k.
//   - Scratch dir prefix is /tmp/lmeb-bench- (distinct from /tmp/lme-bench-).
//   - VerbMap location is "benchmark/lmeb" (distinct from "benchmark/longmemeval").
//   - Each corpus doc is ingested as a single moot_file_memory call; there is
//     no session/turn structure.
//
// Safety guarantees:
//   - lmebScratchDir(posture:) names the dir with /tmp/lmeb-bench- so the teardown
//     guard can distinguish LMEB scratch dirs from arbitrary /tmp directories.
//   - lmebGuardedTeardown() refuses any path without the /tmp/lmeb-bench- prefix.
//   - The built EndpointConfig always carries MOOTX01_DATA_DIR=/tmp/lmeb-bench-...
//     so assertScratchBackend (GauntletCLI.swift) independently verifies the
//     scratch constraint before any write begins.

// MARK: - VerbMap

/// Standard mootx01 VerbMap used for LMEB ingestion + recall queries.
///
/// location: "benchmark/lmeb" scopes all writes to the LMEB namespace —
/// distinct from the longmemeval namespace so the two benchmarks never share
/// content when run on the same estate.
let lmebMootVerbMap = EndpointConfig.VerbMap(
    write: "moot_file_memory",
    query: "moot_memory_search",
    list: nil,
    constantArgs: ["location": "benchmark/lmeb"],
    resultFormat: .mootText
)

// MARK: - Manifest entry

/// Maps a filed-memory UUID back to its origin doc in the candidate pool.
/// Codable so it can round-trip through estate cache manifest.json.
struct LMEBManifestEntry: Sendable, Codable {
    /// The UUID returned by moot_file_memory ("filed memory <UUID>").
    let uuid: String
    /// The corpus document ID this ingestion represents.
    let docID: String
}

// MARK: - Per-query result

/// The raw result of running the LMEB harness against one query.
struct LMEBQueryResult: Sendable {
    /// Query identifier, e.g. "scene_42_q_0".
    let queryID: String
    /// Time taken for the moot_memory_search call, in seconds.
    let queryLatencySeconds: Double
    /// Doc IDs retrieved by moot_memory_search, in ranked order (UUID→docID mapped).
    /// UUIDs not in the manifest are dropped (conservative: unmappable hits never
    /// earn credit).
    let retrievedDocIDs: [String]
    /// Ground-truth relevant document IDs for this query.
    let relevantDocIDs: Set<String>
    /// True when the DegeneracyGuard classified the backend as healthy.
    let guardHealthy: Bool
    /// Diagnostic message when the guard was not healthy.
    let guardDiagnostic: String?
    /// Total number of candidate docs ingested for this query.
    let docsIngested: Int
    /// Mean write latency (seconds) across all ingested docs.
    let writeMeanLatencySeconds: Double
    /// Raw payload text (joined textBlocks) from the moot_memory_search response.
    /// Used by the report builder to compute tokens_per_result and provenance_summary.
    /// Nil when the MCP response carried no textBlocks.
    let payloadText: String?
    /// Whether this query's estate was served from the snapshot cache.
    /// true = cache hit (ingest skipped), false = cache miss (ingest ran + snapshot saved).
    /// nil = --estate-cache off (cache not in use for this run).
    let cacheHit: Bool?
    /// Whether the drain barrier observed the corpus_encode lane registered
    /// (Shape B response) before accepting idle. false = converged via the
    /// no-lanes grace window (ambiguous evidence). nil = barrier did not run
    /// (barrier != drain, or estate restored from cache).
    let drainLaneObserved: Bool?
}

// MARK: - Run config

/// Configuration for one LMEB run.
struct LMEBRunConfig: Sendable {
    /// Path to the mootx01 binary.
    let mootBinaryPath: String
    /// Root data directory (contains one subdirectory per evidence type).
    let dataDir: URL
    /// Evidence types to include, e.g. ["user_evidence", "preference_evidence"].
    let evidenceTypes: [String]
    /// Maximum number of queries to run. nil = all queries.
    let limit: Int?
    /// Skip this many queries from the (seeded-shuffled) list.
    let offset: Int
    /// Seed for deterministic query shuffling.
    let seed: UInt64
    /// Directory to write the results report. nil = current directory.
    let outDir: URL?
    /// Run label for the report filename and header.
    let runLabel: String
    /// Encode-queue synchronization strategy. Controls whether ingest uses inline
    /// encoding (impatient), a post-ingest drain barrier (drain, default), or no
    /// barrier (none). Recorded in the report JSON as "encode_barrier".
    let encodeBarrier: EncodeBarrier
    /// Estate snapshot reuse mode (--estate-cache). Defaults to .off (fresh ingest
    /// every run). .reuse snapshots after ingest+encode and copies on cache hits.
    let estateCache: EstateCacheMode
    /// Root directory for estate snapshots (--cache-dir). nil = <outDir>/estate-cache
    /// (or <cwd>/estate-cache when outDir is also nil).
    let cacheDir: URL?
    /// At-rest posture for scratch estates. Default plaintextOptOut: writes
    /// mootx01's `no-encrypt` marker into each scratch data dir before serve
    /// launch (no keychain contact). --no-plaintext-scratch selects
    /// encryptedDefault. Recorded in the report JSON as "estate_encryption".
    let scratchPosture: ScratchEstatePosture
}

// MARK: - Scratch estate management

/// Creates a fresh scratch directory under /tmp/lmeb-bench-<12hex> for LMEB use.
///
/// The /tmp/lmeb-bench- prefix is the contract with `lmebGuardedTeardown`.
/// The UUID suffix guarantees uniqueness across concurrent runs.
///
/// - Parameter posture: At-rest posture for the estate this dir will hold
///   (see ScratchPosture.swift). No default value on purpose: every call
///   site decides posture explicitly.
func lmebScratchDir(posture: ScratchEstatePosture) throws -> URL {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    let path = "/tmp/lmeb-bench-\(suffix)"
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        throw MCPError(description: "lmebScratchDir: could not create \(path): \(error)")
    }
    try applyScratchPosture(posture, to: url)
    return url
}

/// Deletes a scratch directory created by `lmebScratchDir`. Refuses any path
/// that does not carry the `/tmp/lmeb-bench-` prefix — mirrors the safety
/// guard in `lmeGuardedTeardown` (commit f5e51a50).
func lmebGuardedTeardown(_ url: URL) throws {
    let path = url.path
    guard path.hasPrefix("/tmp/lmeb-bench-") else {
        throw MCPError(description:
            "SAFETY: lmebGuardedTeardown refused to delete '\(path)' — "
            + "path must have the /tmp/lmeb-bench- prefix. "
            + "Only directories created by lmebScratchDir(posture:) may be torn down by this guard.")
    }
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        FileHandle.standardError.write(Data(
            "[lmeb] teardown warning: could not remove \(path): \(error)\n".utf8))
    }
}

// MARK: - EndpointConfig builder

/// Builds an EndpointConfig for mootx01 pointing at a scratch estate.
func lmebEndpointConfig(scratchDir: URL, mootBinaryPath: String) throws -> EndpointConfig {
    let command = "MOOTX01_DATA_DIR=\(scratchDir.path) \(mootBinaryPath)"
    let endpoint = EndpointConfig(
        name: "mootx01-lmeb",
        transport: .stdio(command: command),
        auth: nil,
        verbMap: lmebMootVerbMap,
        role: .target
    )
    // Belt-and-suspenders: assertScratchBackend verifies the scratch constraint
    // independently before any write begins.
    try assertScratchBackend(endpoint)
    return endpoint
}

// MARK: - Runner

/// Runs the LMEB harness against a loaded corpus. Returns per-query results
/// with manifest, latency, and guard verdict for each query.
///
/// Strategy: fresh-per-query estate. Each query gets its own /tmp/lmeb-bench-*
/// directory → clean ingest → guard probe → retrieval query → teardown.
/// This matches the `longmemeval` default (--fresh-per-question) and gives
/// correct isolation across queries from different scenes.
func runLMEBQueries(
    queries: [LMEBQuery],
    corpus: LMEBCorpus,
    config: LMEBRunConfig
) async throws -> [LMEBQueryResult] {
    // Deterministic shuffle using SplitMix64 (fleet-standard PRNG).
    var rng = SplitMix64(seed: config.seed)
    var shuffled = queries
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }
    let afterOffset = Array(shuffled.dropFirst(config.offset))
    let sliced: [LMEBQuery]
    if let limit = config.limit {
        sliced = Array(afterOffset.prefix(limit))
    } else {
        sliced = afterOffset
    }

    var results: [LMEBQueryResult] = []
    results.reserveCapacity(sliced.count)

    // Cache-mode setup (reuse only; zero cost when estateCache == .off).
    let binaryFingerprint: String = config.estateCache == .reuse
        ? mootBinaryFingerprint(config.mootBinaryPath) : ""
    let resolvedCacheDir: URL = config.cacheDir ?? defaultCacheDir(outDir: config.outDir)

    for query in sliced {
        // Candidate pool for this query's scene.
        let candidateDocIDs = corpus.candidateDocs(forQuery: query.id)
        let relevantDocIDs = corpus.relevantDocs(forQuery: query.id)

        // --- Cache-aware estate provisioning ---
        var manifest: [LMEBManifestEntry] = []
        var writeTimes: [Double] = []
        var queryCacheHit: Bool? = nil
        var cacheEntryForSnapshot: URL? = nil

        var scratchURL: URL
        if config.estateCache == .reuse {
            let cacheEntry = estateCacheEntryURL(
                cacheDir: resolvedCacheDir,
                benchmark: "lmeb",
                variant: "",
                seed: config.seed,
                encodeBarrier: config.encodeBarrier,
                binaryFingerprint: binaryFingerprint,
                posture: config.scratchPosture,
                unitID: query.id
            )
            if let (restored, hit): (URL, [LMEBManifestEntry]) =
                restoreEstateCacheEntry(
                    from: cacheEntry,
                    expectedPosture: config.scratchPosture,
                    scratchDirFactory: { try lmebScratchDir(posture: config.scratchPosture) }) {
                scratchURL = restored
                manifest = hit
                queryCacheHit = true
            } else {
                scratchURL = try lmebScratchDir(posture: config.scratchPosture)
                queryCacheHit = false
                cacheEntryForSnapshot = cacheEntry
            }
        } else {
            scratchURL = try lmebScratchDir(posture: config.scratchPosture)
        }

        let endpoint = try lmebEndpointConfig(scratchDir: scratchURL,
                                               mootBinaryPath: config.mootBinaryPath)
        let client = MCPClient(endpoint: endpoint)
        try await client.connect()
        defer {
            Task { await client.disconnect() }
            try? lmebGuardedTeardown(scratchURL)
        }

        // Ingest each candidate doc via live moot_file_memory. Skipped on cache hit.
        // The encode barrier strategy is set by config.encodeBarrier: impatient sends
        // impatient:true per write, drain polls moot_drain_status after full ingest,
        // none has no barrier.
        let skipIngest = (queryCacheHit == true)
        // Drain-barrier lane evidence for this query's estate. nil when the
        // barrier did not run (barrier != drain, or cache hit).
        var drainLaneObserved: Bool? = nil
        if !skipIngest {
        for docID in candidateDocIDs {
            guard let doc = corpus.docsByID[docID] else {
                // Candidate doc not in corpus (cross-evidence-type ID or filtered load).
                // Skip gracefully — the scorer treats it as unretrieved.
                continue
            }
            var writeArgs: [String: JSONValue] = [
                lmebMootVerbMap.contentArg: .string(doc.text),
            ]
            for (k, v) in lmebMootVerbMap.constantArgs {
                writeArgs[k] = .string(v)
            }
            if config.encodeBarrier == .impatient {
                writeArgs["impatient"] = .bool(true)
            }

            let writeStart = Date()
            let writeResult = try await client.callTool(
                lmebMootVerbMap.write,
                arguments: writeArgs,
                format: lmebMootVerbMap.resultFormat
            )
            let writeDuration = Date().timeIntervalSince(writeStart)
            writeTimes.append(writeDuration)

            if let uuid = writeResult.writeAssignedID {
                manifest.append(LMEBManifestEntry(uuid: uuid, docID: docID))
            }
        }

        // Encode barrier (drain mode): poll moot_drain_status after all candidate
        // docs are ingested, waiting for idle before the retrieval query.
        // Skipped on cache hit.
        if config.encodeBarrier == .drain {
            let outcome = await waitForEncodeDrain(
                client: client,
                label: "lmeb q=\(query.id)"
            )
            drainLaneObserved = outcome.laneObserved
        }
        } // end if !skipIngest

        // Snapshot to cache on miss: estate is fully committed after ingest + encode.
        if let ce = cacheEntryForSnapshot {
            saveEstateCacheEntry(estateScratchDir: scratchURL, manifest: manifest, to: ce)
        }

        // DegeneracyGuard probe: issue ≥3 distinct probes before scoring.
        let guard_ = DegeneracyGuard()
        let probeRankings = await probeMCPClient(client, verbMap: lmebMootVerbMap,
                                                  name: "mootx01-lmeb")
        let verdict = guard_.classify(probeRankings: probeRankings)
        let guardHealthy: Bool
        if case .healthy = verdict { guardHealthy = true } else { guardHealthy = false }
        let guardDiagnostic: String? = guardHealthy ? nil : verdict.diagnostic

        // Query via moot_memory_search.
        var queryArgs: [String: JSONValue] = [
            lmebMootVerbMap.queryArg: .string(query.text),
        ]
        for (k, v) in lmebMootVerbMap.constantArgs { queryArgs[k] = .string(v) }
        let queryStart = Date()
        let queryResult = try await client.callTool(
            lmebMootVerbMap.query,
            arguments: queryArgs,
            format: lmebMootVerbMap.resultFormat
        )
        let queryLatency = Date().timeIntervalSince(queryStart)

        // Map returned UUIDs → docIDs using the manifest.
        // UUIDs not in the manifest are dropped (conservative: unmappable hits never
        // earn credit, matching the LME UUID→session mapping policy).
        let uuidToDocID: [String: String] = Dictionary(
            manifest.map { ($0.uuid, $0.docID) },
            uniquingKeysWith: { first, _ in first }
        )
        var seen: Set<String> = []
        var rankedDocIDs: [String] = []
        for uuid in queryResult.orderedIDs {
            guard let docID = uuidToDocID[uuid] else { continue }
            if seen.insert(docID).inserted {
                rankedDocIDs.append(docID)
            }
        }

        let writeMean = writeTimes.isEmpty ? 0.0
            : writeTimes.reduce(0, +) / Double(writeTimes.count)

        // Capture raw payload text for token-efficiency and provenance_summary.
        let rawPayload = queryResult.textBlocks.isEmpty ? nil
            : queryResult.textBlocks.joined(separator: "\n")

        results.append(LMEBQueryResult(
            queryID: query.id,
            queryLatencySeconds: queryLatency,
            retrievedDocIDs: rankedDocIDs,
            relevantDocIDs: relevantDocIDs,
            guardHealthy: guardHealthy,
            guardDiagnostic: guardDiagnostic,
            docsIngested: manifest.count,
            writeMeanLatencySeconds: writeMean,
            payloadText: rawPayload,
            cacheHit: queryCacheHit,
            drainLaneObserved: drainLaneObserved
        ))

        let progressMsg = "[lmeb] query \(results.count)/\(sliced.count) "
            + "\(query.id): ingested \(manifest.count) docs, "
            + "guard=\(guardHealthy ? "healthy" : "EXCLUDED"), "
            + "retrieved \(rankedDocIDs.count) docs\n"
        FileHandle.standardError.write(Data(progressMsg.utf8))
    }

    return results
}
