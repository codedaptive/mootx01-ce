import Foundation

// CaptureSpreadRunner.swift — harness lane `capturespread` (Part B, P2a).
//
// LANE SHAPE
//
//   ONE estate for the whole run (same design as the supersession lane):
//   all corpus records are ingested into a single persistent estate, the
//   matrix is dreamed, and all probes are queried against that estate.
//   Per-question provisioning would make capture-timing effects
//   unmeasurable — the matrix priors are zero without an audit trail.
//
//   Three build variants (selected by --variant):
//     spread:   each record's captureDate is populated → distinct HLC filedAt
//               values → the matrix decay projection sees real age differences.
//     burst:    captureDate omitted → all records receive the batch wall-clock
//               → the control cell (T-side spread alone: eventTime has spread).
//     splitcap: captureDate = designed (O-side alive) + eventTime = T0 constant
//               (T-side killed) → isolates the O projection alone. Comparing
//               splitcap decayed-vs-balanced against v1 burst decayed-vs-balanced
//               (T-side alone) completes the two-dimensional decomposition.
//
//   Queries: moot_recall_shaped (preset selectable via --recall-shape).
//
//   Two probe classes (reported separately in the output):
//     current_value:    gold = fresh cluster record IDs. Decay should help.
//     what_was_before:  gold = stale cluster record IDs. Over-decay guard.
//
// ESTATE CACHE
//
//   The whole run is one "unit" — the same seed+variant always produces the
//   same estate. The estate cache key uses `benchmark = "capturespread"` and
//   `variant = "spread"/"burst"/"splitcap"`, with `unitID = "run"`.
//
// ACCURACY METRICS
//
//   any@k, all@k, MRR per probe class. Per-probe result + aggregate.
//   Accuracy files carry figures + identity only; NO timing (register rule).

// MARK: - Config

/// Run configuration for the capture-spread lane.
struct CaptureSpreadRunConfig: Sendable {
    /// Path to the mootx01 binary (the serve process).
    let mootBinaryPath: String
    /// Pre-loaded corpus (from capturespread-corpus or generated on the fly).
    let corpus: CaptureSpreadCorpus
    /// Spread = distinct capture dates; burst = batch wall-clock.
    let variant: CaptureSpreadVariant
    /// Named RecallShape preset for moot_recall_shaped. Default "matrix_decayed"
    /// (the S4-C arm preset using exp-decayed O/T projections). The spec used
    /// the term "matrixAware" to describe the capability; the product preset name
    /// is "matrix_decayed". Override via --recall-shape.
    let recallShape: String
    /// Top-k cut-off for recall scoring.
    let topK: Int
    /// Encode barrier mode.
    let encodeBarrier: EncodeBarrier
    /// Estate cache mode.
    let cacheMode: EstateCacheMode
    /// Cache directory root. Used only when cacheMode != .off.
    let cacheDir: URL
    /// Scratch posture (plaintextTransient for benchmarks — no keychain contact).
    let posture: ScratchEstatePosture
    /// Output directory for report JSON.
    let outDir: URL
    /// Caller-supplied run ID (--run-id) or an auto-generated stable ID.
    let runID: String
    /// mootx01 version string for provenance (from mootx01 --version).
    let mootx01Version: String
}

/// Which build variant is this run.
///
/// - spread:   captureDate = designed per-record date; eventTime = captureDate.
///             Both O-side and T-side temporal signals are alive.
/// - burst:    captureDate = nil (batch wall-clock); eventTime = captureDate.
///             O-side collapsed; T-side signal alive. Null-control cell.
/// - splitcap: captureDate = designed per-record date (O-side alive);
///             eventTime = T0 constant for all records (T-side killed).
///             Isolates the O projection alone — the v2 escape hatch.
enum CaptureSpreadVariant: String, Sendable, Codable {
    case spread
    case burst
    case splitcap
}

// MARK: - Output types

/// Accuracy scores for one probe.
struct CaptureSpreadProbeResult: Sendable, Codable {
    let probeID: String
    let topicIndex: Int
    let probeClass: CaptureSpreadProbe.ProbeClass
    /// True when the estate cache was used (ingest skipped).
    let cacheHit: Bool
    /// Ranked record IDs returned by moot_recall_shaped (top-20 max).
    let rankedRecordIDs: [String]
    /// Gold record IDs for this probe.
    let goldIDs: [String]
    /// Number of ranked results before any mapping was applied.
    let rawRankedCount: Int
    let recallAnyAtK: Double
    let recallAllAtK: Double
    let mrr: Double
}

/// Per-class aggregate summary.
struct CaptureSpreadClassAggregate: Sendable, Codable {
    let probeClass: String
    let probeCount: Int
    let meanRecallAnyAtK: Double
    let meanRecallAllAtK: Double
    let meanMRR: Double
}

/// The full run report. Written to --out as `<runID>-capturespread-<arm>-<serial>.json`.
struct CaptureSpreadReport: Sendable, Codable {
    // Run identity
    let runID: String
    let seed: UInt64
    let variant: String
    let recallShape: String
    let topK: Int
    let probeTopicCount: Int
    let distractorCount: Int
    let totalRecords: Int
    let totalProbes: Int
    let mootx01Version: String
    /// True when every probe's estate was restored from cache (full cache hit).
    let allCacheHits: Bool
    // Per-probe results
    let probeResults: [CaptureSpreadProbeResult]
    // Aggregate per class
    let currentValueAggregate: CaptureSpreadClassAggregate
    let whatWasBeforeAggregate: CaptureSpreadClassAggregate
    // Overall aggregate across both classes
    let overallAggregate: CaptureSpreadClassAggregate
}

// MARK: - Manifest entry (estate cache)

/// One record in the estate cache manifest: maps a seed record ID to its
/// drawer UUID as assigned by moot_json_import. The UUID is used to
/// attribute ranked recall results back to seed records for scoring.
struct CaptureSpreadManifestEntry: Sendable, Codable {
    let recordID: String
    let drawerUUID: String
}

// MARK: - Scratch estate lifecycle

/// Creates a fresh scratch directory under /tmp/capturespread-bench-<UUID>.
/// The guarded teardown function checks this prefix before deleting. Path
/// uses /tmp/ (not /private/tmp/) so the --db token satisfies
/// the `assertScratchBackend` /tmp prefix requirement — same pattern as
/// `loCoMoScratchDir`. `resolvingSymlinksInPath` leaves /tmp intact on macOS.
func captureSpreadScratchDir(posture: ScratchEstatePosture) throws -> URL {
    // Trim UUID dashes to keep the prefix short (mirrors loCoMoScratchDir).
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    let path = "/tmp/capturespread-bench-\(suffix)"
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
    } catch {
        throw MCPError(description:
            "captureSpreadScratchDir: could not create \(path): \(error)")
    }
    // Reject symlinks at the target path — an attacker could place a symlink
    // here to redirect estate writes to a non-scratch location.
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
        throw MCPError(description:
            "captureSpreadScratchDir: SAFETY: '\(path)' is a symlink — "
            + "refusing to use as scratch estate")
    }
    // Resolve symlinks and verify the canonical path stays under /tmp/capturespread-bench-.
    let canonical = url.resolvingSymlinksInPath()
    guard canonical.path.hasPrefix("/tmp/capturespread-bench-") else {
        throw MCPError(description:
            "captureSpreadScratchDir: SAFETY: canonicalized path '\(canonical.path)' "
            + "escapes /tmp/capturespread-bench-")
    }
    // Posture: plaintextTransient is a transient catalog record, plaintext by rule;
    // encryptedEphemeral leaves the directory clean (product's default).
    return canonical
}

/// Deletes a scratch directory created by `captureSpreadScratchDir`. Refuses
/// any path that does not begin with `/tmp/capturespread-bench-` to prevent
/// accidental deletion of non-scratch paths (belt-and-suspenders, mirrors
/// `loCoMoGuardedTeardown`). Also refuses symlinks.
func captureSpreadGuardedTeardown(_ url: URL) throws {
    let path = url.path
    guard path.hasPrefix("/tmp/capturespread-bench-") else {
        throw MCPError(description:
            "SAFETY: captureSpreadGuardedTeardown refused to delete '\(path)' — "
            + "path must have the /tmp/capturespread-bench- prefix. "
            + "Only directories created by captureSpreadScratchDir may be torn down "
            + "by this guard.")
    }
    // Refuse symlinks — a symlink at the path would delete a non-scratch target.
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
        throw MCPError(description:
            "SAFETY: captureSpreadGuardedTeardown refused symlink '\(path)' — "
            + "refusing to delete non-canonical path")
    }
    try FileManager.default.removeItem(at: url)
}

// MARK: - Endpoint config

/// Builds an EndpointConfig for a capturespread scratch estate.
///
/// Reuses the EndpointConfig factory that other lanes use; the VerbMap is
/// minimal (write = moot_file_memory for probe compliance, but we use batch
/// import so the write verb is never called in normal operation).
func captureSpreadEndpointConfig(
    scratchDir: URL,
    mootBinaryPath: String,
    posture: ScratchEstatePosture
) throws -> EndpointConfig {
    // command string follows the same pattern as lmeEndpointConfig /
    // loCoMoEndpointConfig: env vars inline before the binary path, stdio
    // transport. No --in-memory override — capturespread always uses
    // the disk backend so estate files persist between provision and query.
    // MOOTX01_VAULT=1 gates batch import (moot_json_import requires vault).
    // MOOTX01_SUBJECT_RIDER=0 suppresses the subject-expansion rider so
    // recall results reflect the stored content only.
    let command = try mootServeCommand(binary: mootBinaryPath, scratchDir: scratchDir, environment: ["MOOTX01_VAULT=1", "MOOTX01_SUBJECT_RIDER=0"])
    let verbMap = EndpointConfig.VerbMap(
        write: AriaV2Surface.fileMemory,
        query: AriaV2Surface.recallShaped,
        list: nil,
        // capturespread writes via batch import (moot_json_import), not the
        // write verb directly, so constantArgs can be empty. The location
        // constant is only needed for per-item moot_file_memory calls.
        constantArgs: [:],
        resultFormat: .mootV2)
    let endpoint = EndpointConfig(
        name: "mootx01-capturespread",
        transport: .stdio(command: command),
        auth: nil,
        verbMap: verbMap,
        role: .target)
    try assertScratchBackend(endpoint, requirement: mootScratchRequirement)
    return endpoint
}

// MARK: - Main runner

/// Scores the capture-spread probe set against a settled estate built from
/// the corpus in the configured variant. Returns the per-probe results.
///
/// Estate lifecycle (one estate for the whole run):
///   1. Provision scratch dir (or restore from cache).
///   2. Connect MCP client to serve process.
///   3. If fresh build: import all records → drain → dream → reindex → settle.
///   4. Anomaly sweep seam (MOOT_BENCH_RUN_ANOMALY_SWEEP).
///   5. For each probe: query via moot_recall_shaped, score.
///   6. Retire scratch dir.
///
/// - Parameters:
///   - config: Run configuration.
/// - Returns: Scored per-probe results and aggregate report.
func runCaptureSpreadLane(
    config: CaptureSpreadRunConfig
) async throws -> CaptureSpreadReport {
    let corpus = config.corpus

    // Records sorted chronologically (captureDate order = ingestion order).
    // File order IS ingestion order — the importer never sorts, so the
    // capture sequence must be in the seed file itself.
    // Note: captureDate from the corpus record is the sort key for all three
    // variants (spread, burst, splitcap). For splitcap, eventTime is T0 but
    // captureDate still carries the designed O-side ordering.
    let sortedRecords = corpus.records.sorted {
        ($0.captureDate, $0.id) < ($1.captureDate, $1.id)
    }
    let seedRecords = captureSpreadSeedRecords(
        from: CaptureSpreadCorpus(
            seed: corpus.seed,
            probeTopicCount: corpus.probeTopicCount,
            distractorCount: corpus.distractorCount,
            records: sortedRecords,
            topics: corpus.topics,
            probes: corpus.probes),
        variant: config.variant)

    // Corpus digest for provenance: stable identifier for this seed+variant.
    let corpusDigest = "capturespread-seed\(corpus.seed)-\(config.variant.rawValue)"

    let runProvenance = makeArtifactProvenance(
        benchmark: "capturespread",
        variant: config.variant.rawValue,
        seed: corpus.seed,
        encodeBarrier: config.encodeBarrier,
        posture: config.posture,
        seedPath: .batch,
        corpusDigest: corpusDigest,
        mootx01Version: config.mootx01Version)

    // One estate entry per (seed, variant) run.
    let cacheEntry = estateCacheEntryURL(
        cacheDir: config.cacheDir,
        benchmark: "capturespread",
        variant: config.variant.rawValue,
        seed: corpus.seed,
        encodeBarrier: config.encodeBarrier,
        posture: config.posture,
        seedPath: .batch,
        unitID: "run")

    // ── 1. Provision scratch estate (cache or fresh build) ────────────────
    var activeScratchDir: URL
    var uuidByRecordID: [String: String] = [:]
    var cacheHit = false

    if config.cacheMode.readsCache,
       let restored = try restoreEstateCacheEntry(
            from: cacheEntry,
            expectedProvenance: runProvenance,
            scratchDirFactory: {
                try captureSpreadScratchDir(posture: config.posture)
            }) as (URL, [CaptureSpreadManifestEntry])? {
        activeScratchDir = restored.0
        for entry in restored.1 {
            uuidByRecordID[entry.recordID] = entry.drawerUUID
        }
        cacheHit = true
        FileHandle.standardError.write(Data(
            "[capturespread] cache HIT for seed=\(corpus.seed) variant=\(config.variant.rawValue)\n"
                .utf8))
    } else {
        activeScratchDir = try captureSpreadScratchDir(posture: config.posture)
        FileHandle.standardError.write(Data((
            "[capturespread] fresh build for seed=\(corpus.seed) variant=\(config.variant.rawValue), "
            + "\(sortedRecords.count) records\n").utf8))
    }

    let endpoint = try captureSpreadEndpointConfig(
        scratchDir: activeScratchDir,
        mootBinaryPath: config.mootBinaryPath,
        posture: config.posture)
    let client = MCPClient(endpoint: endpoint)

    var unitCompleted = false
    defer {
        Task { await client.disconnect() }
        if unitCompleted {
            try? retireScratchEstate(
                activeScratchDir,
                expectPlaintext: config.posture == .plaintextTransient,
                teardown: captureSpreadGuardedTeardown)
        } else {
            keepScratchEstateOnFailure(activeScratchDir, lane: "capturespread")
        }
    }

    try await client.connect()

    // ── 2. Build estate (skip on cache hit) ───────────────────────────────
    if !cacheHit {
        // Emit seed file and import all records in one moot_json_import call.
        // return_id_map: true returns the record-id → drawer-UUID map so we
        // can attribute ranked UUIDs back to corpus records for scoring.
        let seedData = emitSeedJSON(
            name: corpusDigest,
            records: seedRecords)
        let seedURL = try writeSeedFile(
            seedData, in: activeScratchDir, name: corpusDigest)
        let importResult = try await client.callTool(
            AriaV2Surface.jsonImport,
            arguments: [
                "path":          .string(seedURL.path),
                // v2: `mode` arg removed from moot_json_import (v2 manages encode scheduling internally).
                "return_id_map": .bool(true),
            ],
            format: .mootV2,
            // Bulk tier: whole-corpus import in one call.
            deadline: MCPDeadline.bulk)
        // v2 surface: drawer count is in structuredContent.data.drawers_written.
        guard let written = importResult.drawersWritten, written == seedRecords.count else {
            throw MCPError(description:
                "capturespread: moot_json_import did not confirm \(seedRecords.count) "
                + "drawers — refusing to score an unseeded estate. Got: "
                + (importResult.drawersWritten.map(String.init) ?? "(no structured data)"))
        }
        // Parse the record-id → drawer-UUID map.
        uuidByRecordID = try seedIDMap(
            fromImportBlocks: importResult.textBlocks,
            expecting: seedRecords.count,
            label: "capturespread seed=\(corpus.seed) \(config.variant.rawValue)")

        // Drain barrier: wait for the encode queue to be idle before dreaming.
        let barrierOutcome = await waitForEncodeDrain(
            client: client,
            label: "capturespread seed=\(corpus.seed) post-import")
        guard barrierOutcome.converged else {
            throw MCPError(description:
                "capturespread: encode drain did not converge within 300s — refusing to "
                + "query a partially-indexed estate. Re-run on an unloaded machine.")
        }

        // Dream: run the full association + matrix rebuild pass. Use a
        // deterministic fiction `now` — one day past the corpus's last
        // capture date — so the temporal math runs on the corpus's timeline
        // (not the wall clock) and the output is a pure function of the estate.
        let lastCapture = sortedRecords.map(\.captureDate).max() ?? "2026-01-01T00:00:00Z"
        let fictionNow: String = {
            let iso = ISO8601DateFormatter()
            iso.timeZone = TimeZone(secondsFromGMT: 0)
            return iso.date(from: lastCapture).map {
                iso.string(from: $0.addingTimeInterval(86_400))
            } ?? lastCapture
        }()
        let dreamResult = try await client.callTool(
            AriaV2Surface.dream,
            arguments: [
                "now": .string(fictionNow),
                "associates": .string("all"),
            ],
            format: .mootV2,
            deadline: MCPDeadline.bulk)
        // v2 surface: the "matrix rebuilt" text signal was removed. The
        // strongest available confirmation is meta.status == "completed", which
        // proves the dreaming cycle returned successfully. It does NOT prove a
        // matrix rebuild occurred — that confirmation is unavailable on the v2
        // surface. The operator should be aware that matrix rebuild cannot be
        // confirmed via the v2 surface.
        guard dreamResult.metaStatus == "completed" else {
            throw MCPError(description:
                "capturespread: moot_dream did not complete "
                + "(meta.status: \(dreamResult.metaStatus ?? "nil")) — "
                + "refusing to score an un-dreamed estate.")
        }

        // Reindex after dream to ensure the vector index reflects the dreamed
        // matrix state before any probe queries.
        _ = try await client.callTool(
            AriaV2Surface.reindex, arguments: [:], format: .mootV2,
            deadline: MCPDeadline.bulk)

        // Settle-post-dream drain: the reindex enqueues encode work.
        _ = await waitForEncodeDrain(
            client: client,
            label: "capturespread seed=\(corpus.seed) settle-post-dream")

        // Snapshot to estate cache. The settle calls above (all `try await`)
        // would have thrown before reaching this point if the estate were
        // unsettled — the error-propagation path IS the gate (see LME
        // settle-gate invariant comment for the same reasoning).
        if config.cacheMode != .off {
            let manifestEntries = uuidByRecordID.map {
                CaptureSpreadManifestEntry(recordID: $0.key, drawerUUID: $0.value)
            }
            saveEstateCacheEntry(
                estateScratchDir: activeScratchDir,
                manifest: manifestEntries,
                provenance: runProvenance,
                to: cacheEntry)
        }

        FileHandle.standardError.write(Data((
            "[capturespread] estate ready: \(sortedRecords.count) records, "
            + "dream confirmed, reindex complete\n").utf8))
    }

    // ── 3. Anomaly sweep seam (MOOT_BENCH_RUN_ANOMALY_SWEEP) ──────────────
    // Called after cache restore + client connect, before any probe queries.
    // Hard-fails if the sweep cannot be confirmed (same fail-loud rule as
    // provisionLaneWeightsSeam). See EstateSeams.swift for the full rationale.
    try await anomalySweepSeam(
        client: client,
        label: "capturespread seed=\(corpus.seed) \(config.variant.rawValue)")

    // Build an inverted UUID → record-ID map for scoring retrieved UUIDs.
    // Lowercase UUIDs because moot_recall_shaped may return mixed-case IDs
    // (Swift `UUID.uuidString` is UPPERCASE; some surfaces emit lowercase).
    let recordIDByUUID: [String: String] = Dictionary(
        uniqueKeysWithValues: uuidByRecordID.map { ($1.lowercased(), $0) })

    // ── 4. Query all probes ────────────────────────────────────────────────
    var probeResults: [CaptureSpreadProbeResult] = []
    probeResults.reserveCapacity(corpus.probes.count)

    for probe in corpus.probes {
        var args: [String: JSONValue] = ["query": .string(probe.queryText)]
        // Always supply a named preset; the lane's purpose IS to measure
        // shaped-door behaviour. "matrix_decayed" is the default (the S4-C arm
        // preset using exp-decayed O/T projections). The caller may override
        // via --recall-shape to compare against e.g. "balanced".
        args["preset"] = .string(config.recallShape)

        let result = try await client.callTool(
            AriaV2Surface.recallShaped,
            arguments: args,
            format: .mootV2)

        // Map retrieved UUIDs → record IDs. UUIDs not in the map are probe
        // records from a different corpus that somehow leaked into the estate
        // (should not happen) — drop them rather than scoring as misses.
        let rawRankedCount = result.orderedIDs.count
        let rankedRecordIDs = result.orderedIDs.compactMap {
            recordIDByUUID[$0.lowercased()]
        }

        let goldSet = Set(probe.goldIDs)
        let recallAny = lmeRecallAny(
            rankedSessions: rankedRecordIDs, answerIDs: goldSet, k: config.topK)
        let recallAll = lmeRecallAll(
            rankedSessions: rankedRecordIDs, answerIDs: goldSet, k: config.topK)
        let mrr = lmeSessionMRR(
            rankedSessions: rankedRecordIDs, answerIDs: goldSet)

        // Capture top-20 ranked record IDs in the report for traceability.
        probeResults.append(CaptureSpreadProbeResult(
            probeID: probe.probeID,
            topicIndex: probe.topicIndex,
            probeClass: probe.probeClass,
            cacheHit: cacheHit,
            rankedRecordIDs: Array(rankedRecordIDs.prefix(20)),
            goldIDs: probe.goldIDs,
            rawRankedCount: rawRankedCount,
            recallAnyAtK: recallAny,
            recallAllAtK: recallAll,
            mrr: mrr))
    }

    unitCompleted = true

    // ── 5. Aggregate ──────────────────────────────────────────────────────
    func aggregate(
        _ results: [CaptureSpreadProbeResult],
        class probeClass: CaptureSpreadProbe.ProbeClass,
        label: String
    ) -> CaptureSpreadClassAggregate {
        let subset = results.filter { $0.probeClass == probeClass }
        let n = subset.count
        guard n > 0 else {
            return CaptureSpreadClassAggregate(
                probeClass: label, probeCount: 0,
                meanRecallAnyAtK: 0, meanRecallAllAtK: 0, meanMRR: 0)
        }
        let meanAny = subset.map(\.recallAnyAtK).reduce(0, +) / Double(n)
        let meanAll = subset.map(\.recallAllAtK).reduce(0, +) / Double(n)
        let meanMRR = subset.map(\.mrr).reduce(0, +) / Double(n)
        return CaptureSpreadClassAggregate(
            probeClass: label, probeCount: n,
            meanRecallAnyAtK: meanAny,
            meanRecallAllAtK: meanAll,
            meanMRR: meanMRR)
    }

    let cvAgg  = aggregate(probeResults, class: .currentValue,   label: "current_value")
    let wbAgg  = aggregate(probeResults, class: .whatWasBefore,  label: "what_was_before")
    let allN   = probeResults.count
    let allAny = probeResults.isEmpty ? 0.0 : probeResults.map(\.recallAnyAtK).reduce(0,+)/Double(allN)
    let allAll = probeResults.isEmpty ? 0.0 : probeResults.map(\.recallAllAtK).reduce(0,+)/Double(allN)
    let allMRR = probeResults.isEmpty ? 0.0 : probeResults.map(\.mrr).reduce(0,+)/Double(allN)
    let overallAgg = CaptureSpreadClassAggregate(
        probeClass: "overall", probeCount: allN,
        meanRecallAnyAtK: allAny,
        meanRecallAllAtK: allAll,
        meanMRR: allMRR)

    return CaptureSpreadReport(
        runID: config.runID,
        seed: corpus.seed,
        variant: config.variant.rawValue,
        recallShape: config.recallShape,
        topK: config.topK,
        probeTopicCount: corpus.probeTopicCount,
        distractorCount: corpus.distractorCount,
        totalRecords: corpus.records.count,
        totalProbes: probeResults.count,
        mootx01Version: config.mootx01Version,
        allCacheHits: cacheHit,
        probeResults: probeResults,
        currentValueAggregate: cvAgg,
        whatWasBeforeAggregate: wbAgg,
        overallAggregate: overallAgg)
}

// MARK: - CLI handler (capturespread subcommand)

/// Runs the `capturespread` subcommand.
///
/// Options:
///   --corpus <path>         Path to a .probes.json file from capturespread-corpus.
///   --seed <uint64>         Generate corpus on-the-fly with this seed (default 42).
///   --probes <int>          Probe count when generating on-the-fly (default 50).
///   --distractors <int>     Distractor count when generating on-the-fly (default 150).
///   --variant spread|burst  Build variant (default spread).
///   --recall-shape <preset> Named RecallShape preset (default matrixAware).
///   --k <int>               Top-k for recall scoring (default 10).
///   --mootx01-binary <path> Path to the mootx01 binary.
///   --estate-cache off|reuse|require  (default off).
///   --cache-dir <dir>       Cache directory root.
///   --out <dir>             Output directory for report JSON.
///   --run-id <string>       Caller-supplied run ID (for record filename).
func runCaptureSpread(_ args: [String]) async throws {
    // ── Parse options ─────────────────────────────────────────────────────
    var corpusPath: String? = nil
    var seed: UInt64 = 42
    var probeCount = 50
    var distractorCount = 150
    var variantStr = "spread"
    // "matrix_decayed" is the S4-C arm preset: matrixAware scoring with the
    // §8.13 exp-decayed O/T projections instead of raw counts — the door where
    // capture-HLC age differences should change ranking. The spec used the
    // internal term "matrixAware" when describing the capability; the product's
    // RecallShape preset name is "matrix_decayed".
    var recallShape = "matrix_decayed"
    var topK = 10
    var mootBinary: String? = nil
    var estateCacheModeStr = "off"
    var cacheDirPath: String? = nil
    var outDirPath: String? = nil
    var runID: String? = nil

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--corpus":
            i += 1; guard i < args.count else {
                throw MCPError(description: "--corpus requires a path")
            }
            corpusPath = args[i]
        case "--seed":
            i += 1; guard i < args.count, let v = UInt64(args[i]) else {
                throw MCPError(description: "--seed requires a uint64 value")
            }
            seed = v
        case "--probes":
            i += 1; guard i < args.count, let v = Int(args[i]), v > 0 else {
                throw MCPError(description: "--probes requires a positive integer")
            }
            probeCount = v
        case "--distractors":
            i += 1; guard i < args.count, let v = Int(args[i]), v >= 0 else {
                throw MCPError(description: "--distractors requires a non-negative integer")
            }
            distractorCount = v
        case "--variant":
            i += 1; guard i < args.count,
                          args[i] == "spread" || args[i] == "burst" || args[i] == "splitcap" else {
                throw MCPError(description: "--variant must be 'spread', 'burst', or 'splitcap'")
            }
            variantStr = args[i]
        case "--recall-shape":
            i += 1; guard i < args.count else {
                throw MCPError(description: "--recall-shape requires a preset name")
            }
            recallShape = args[i]
        case "--k":
            i += 1; guard i < args.count, let v = Int(args[i]), v >= 1 else {
                throw MCPError(description: "--k requires a positive integer")
            }
            topK = v
        case "--mootx01-binary", "--binary":
            i += 1; guard i < args.count else {
                throw MCPError(description: "--mootx01-binary requires a path")
            }
            mootBinary = args[i]
        case "--estate-cache":
            i += 1; guard i < args.count else {
                throw MCPError(description: "--estate-cache requires off|reuse|require")
            }
            estateCacheModeStr = args[i]
        case "--cache-dir":
            i += 1; guard i < args.count else {
                throw MCPError(description: "--cache-dir requires a directory path")
            }
            cacheDirPath = args[i]
        case "--out":
            i += 1; guard i < args.count else {
                throw MCPError(description: "--out requires a directory path")
            }
            outDirPath = args[i]
        case "--run-id":
            i += 1; guard i < args.count else {
                throw MCPError(description: "--run-id requires a string")
            }
            runID = args[i]
        default:
            throw MCPError(description: "capturespread: unknown option '\(args[i])'")
        }
        i += 1
    }

    // Resolve binary.
    let binary: String
    if let explicit = mootBinary {
        binary = explicit
    } else if let discovered = discoverMootBinary() {
        binary = discovered
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Pass --mootx01-binary <path>.")
    }

    // Parse variant.
    let variant: CaptureSpreadVariant
    switch variantStr {
    case "spread":   variant = .spread
    case "burst":    variant = .burst
    case "splitcap": variant = .splitcap
    default:
        throw MCPError(description: "--variant must be 'spread', 'burst', or 'splitcap'")
    }

    // Parse estate cache mode.
    let cacheMode: EstateCacheMode
    switch estateCacheModeStr {
    case "off":     cacheMode = .off
    case "reuse":   cacheMode = .reuse
    case "require": cacheMode = .require
    default:
        throw MCPError(description:
            "--estate-cache must be 'off', 'reuse', or 'require'; got '\(estateCacheModeStr)'")
    }

    // Resolve directories.
    let outDir = URL(fileURLWithPath:
        outDirPath ?? FileManager.default.currentDirectoryPath)
    let cacheDir = URL(fileURLWithPath:
        cacheDirPath ?? outDir.appendingPathComponent("estate-cache").path)
    try FileManager.default.createDirectory(
        at: outDir, withIntermediateDirectories: true)

    // Load or generate corpus.
    let corpus: CaptureSpreadCorpus
    if let cp = corpusPath {
        let data = try Data(contentsOf: URL(fileURLWithPath: cp))
        corpus = try JSONDecoder().decode(CaptureSpreadCorpus.self, from: data)
        FileHandle.standardError.write(Data((
            "[capturespread] loaded corpus from \(cp): "
            + "\(corpus.records.count) records, \(corpus.probes.count) probes\n").utf8))
    } else {
        corpus = generateCaptureSpreadCorpus(
            seed: seed,
            probeTopicCount: probeCount,
            distractorCount: distractorCount)
        FileHandle.standardError.write(Data((
            "[capturespread] generated corpus seed=\(seed): "
            + "\(corpus.records.count) records, \(corpus.probes.count) probes\n").utf8))
    }

    // Resolve run serial and ID.
    let serial = resolveRunSerial(args)
    let effectiveRunID = runID ?? "capturespread-seed\(corpus.seed)-\(variantStr)"

    // Fetch mootx01 version for provenance — same approach as other lanes
    // (parseMootVersion is private; IdentityEnvironment.collect is the public seam).
    let mootVersion = IdentityEnvironment.collect(mootx01BinaryPath: binary).mootx01Version

    let config = CaptureSpreadRunConfig(
        mootBinaryPath: binary,
        corpus: corpus,
        variant: variant,
        recallShape: recallShape,
        topK: topK,
        encodeBarrier: .drain,
        cacheMode: cacheMode,
        cacheDir: cacheDir,
        posture: .plaintextTransient,  // benchmarks never touch the keychain
        outDir: outDir,
        runID: effectiveRunID,
        mootx01Version: mootVersion)

    let report = try await runCaptureSpreadLane(config: config)

    // ── Write report JSON ─────────────────────────────────────────────────
    // Accuracy files carry figures + identity only (register discipline).
    // Timing goes to sidecars only — not implemented here (no timing in this
    // file per spec: "figures + identity only, NO timing in accuracy files").
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let reportData = try encoder.encode(report)

    let filename = recordFilename(
        test: "capturespread", arm: variantStr, serial: serial,
        suffix: recallShape == "matrixAware" ? "" : "-\(recallShape)",
        ext: "json")
    let reportURL = outDir.appendingPathComponent(filename)
    try writeRecordNeverOverwrite(reportData, to: reportURL)

    // Print summary to stdout (accuracy figures only).
    let cv  = report.currentValueAggregate
    let wb  = report.whatWasBeforeAggregate
    let ov  = report.overallAggregate
    print("capturespread: seed=\(corpus.seed) variant=\(variantStr) "
        + "shape=\(recallShape) k=\(topK) cacheHits=\(report.allCacheHits)")
    print("  current_value  (\(cv.probeCount) probes): "
        + "any@\(topK)=\(String(format: "%.4f", cv.meanRecallAnyAtK))  "
        + "all@\(topK)=\(String(format: "%.4f", cv.meanRecallAllAtK))  "
        + "MRR=\(String(format: "%.4f", cv.meanMRR))")
    print("  what_was_before (\(wb.probeCount) probes): "
        + "any@\(topK)=\(String(format: "%.4f", wb.meanRecallAnyAtK))  "
        + "all@\(topK)=\(String(format: "%.4f", wb.meanRecallAllAtK))  "
        + "MRR=\(String(format: "%.4f", wb.meanMRR))")
    print("  overall (\(ov.probeCount) probes): "
        + "any@\(topK)=\(String(format: "%.4f", ov.meanRecallAnyAtK))  "
        + "all@\(topK)=\(String(format: "%.4f", ov.meanRecallAllAtK))  "
        + "MRR=\(String(format: "%.4f", ov.meanMRR))")
    print("  report: \(reportURL.path)")
}
