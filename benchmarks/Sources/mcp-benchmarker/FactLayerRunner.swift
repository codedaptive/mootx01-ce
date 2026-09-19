import Foundation

// FactLayerRunner.swift — drives the fact-layer supersession capability cell.
//
// INTERNAL CAPABILITY CELL — OUTSIDE THE FAIRNESS-RULE COMPARATIVE LANE.
//
// This runner exercises the structured-fact lifecycle:
//   1. File all fact versions in chronological order via `moot_file_fact`.
//   2. Retire all non-current versions via `moot_retire_fact`.
//   3. Query via `moot_fact_search` and score whether the current version
//      appears in results and whether retired versions are surfaced.
//
// Ground truth is keyed on the fact UUIDs returned by `moot_file_fact`,
// NOT drawer UUIDs. A retired fact that surfaces above the current one
// is a contamination event; a retired fact that does not surface is
// the correct outcome.
//
// This cell is not in competition with any external memory system. No other
// product is scored here. The label INTERNAL CAPABILITY CELL is required
// on every report that carries this data so readers know it is a
// product-mechanism check, not a comparative measurement.

// MARK: - Config

struct FactLayerRunConfig: Sendable {
    let mootBinaryPath: String
    let seed: UInt64
    let factCount: Int
    let versionsPerFact: Int
    let scratchDir: URL
    /// Scratch posture — always ephemeral to avoid orphaned key material.
    let posture: ScratchEstatePosture
    /// C1: backend shape — .disk (SQLite) or .ram (InMemory). Default is .disk.
    /// .ram injects --in-memory into the served process environment
    /// so the estate bypasses disk I/O entirely. Same injection as the LME lane.
    let shape: LMEShape
}

// MARK: - Per-query result

struct FactLayerQueryResult: Sendable {
    let queryID: String
    /// True when the current-version fact UUID appears anywhere in search results.
    let currentFactFound: Bool
    /// Ranks (1-based) of retired fact UUIDs that appeared in results.
    /// Non-empty means the retire call did not suppress a stale version.
    let retiredFactRanks: [Int]
    /// Rank (1-based) of the current fact UUID in results, nil if absent.
    let currentFactRank: Int?
    /// True when the current version outranks every surfaced retired version.
    /// False when the current version is absent OR any retired version ranks higher.
    let currentWins: Bool
    let latencySeconds: Double
}

// MARK: - Runner output

struct FactLayerCellOutcome: Sendable {
    let queryResults: [FactLayerQueryResult]
    /// UUID map keyed on harness-assigned fact ID: harness id → product UUID.
    /// Product UUIDs are assigned by `moot_file_fact` at filing time.
    let productUUIDByFactID: [String: String]
    /// Facts whose `moot_file_fact` call returned no parseable UUID.
    /// These are excluded from scoring — the harness could not track them.
    let unfiledFactIDs: [String]
    /// C4: wall-clock seconds covering the ingest phase (Steps 1 and 2 combined:
    /// moot_file_fact filing + moot_retire_fact retirements). Captured at the only
    /// available settle point for this cell — there is no dream/drain step because
    /// moot_file_fact and moot_retire_fact are synchronous structured operations.
    let ingestElapsedSeconds: Double
}

// MARK: - JSON Report

/// Minimal JSON report emitted to stdout after the text summary (C7).
///
/// cell_type is always "internal_capability" — records are not in the fairness
/// lane and must not be compared against external systems. Every report key
/// follows snake_case for parity with Rust serde output.
struct FactLayerReport: Codable, Sendable {
    /// Always "internal_capability". Label required on every report that
    /// carries fact-layer data (spec invariant).
    let cellType: String
    /// C1: backend shape that was active ("disk" or "ram").
    let backendShape: String
    /// Internal only — never encoded (accuracy files carry no timing columns).
    var ingestElapsedSeconds: Double = 0
    let queryCount: Int
    let currentFoundRate: Double
    let currentWinRate: Double
    let meanRetiredPerQuery: Double
    /// Internal only — never encoded (accuracy files carry no timing columns).
    var p50LatencySeconds: Double = 0
    let unfiledFactCount: Int
    /// Binary + protocol identity.
    let runEnvironment: IdentityEnvironment

    enum CodingKeys: String, CodingKey {
        case cellType              = "cell_type"
        case backendShape          = "backend_shape"
        case queryCount            = "query_count"
        case currentFoundRate      = "current_found_rate"
        case currentWinRate        = "current_win_rate"
        case meanRetiredPerQuery   = "mean_retired_per_query"
        case unfiledFactCount      = "unfiled_fact_count"
        case runEnvironment        = "run_environment"
    }
}

// MARK: - Scoring

struct FactLayerScores: Sendable {
    let queryCount: Int
    /// Fraction of queries where the current fact UUID appeared in results.
    let currentFoundRate: Double
    /// Fraction of queries where the current fact UUID outranked every
    /// surfaced retired version (or no retired versions surfaced).
    let currentWinRate: Double
    /// Mean retired-fact contamination per query (retired fact UUIDs
    /// appearing in search results). 0.0 means no stale facts surfaced.
    let meanRetiredPerQuery: Double
    let p50LatencySeconds: Double
}

func scoreFactLayer(_ results: [FactLayerQueryResult]) -> FactLayerScores {
    let n = max(results.count, 1)
    let found = results.filter(\.currentFactFound).count
    let wins  = results.filter(\.currentWins).count
    let totalRetired = results.map { $0.retiredFactRanks.count }.reduce(0, +)
    let sorted = results.map(\.latencySeconds).sorted()
    return FactLayerScores(
        queryCount: results.count,
        currentFoundRate: Double(found) / Double(n),
        currentWinRate:   Double(wins)  / Double(n),
        meanRetiredPerQuery: Double(totalRetired) / Double(n),
        p50LatencySeconds: sorted.isEmpty ? 0 : sorted[sorted.count / 2])
}

// MARK: - Runner

/// Drives the full fact-layer lifecycle against one ephemeral estate:
///   1. File all fact versions (chronological order).
///   2. Map harness IDs to product-assigned UUIDs.
///   3. Retire all non-current versions for each chain.
///   4. Query with `moot_fact_search` and score.
///
/// No drain barrier: `moot_file_fact` and `moot_retire_fact` are
/// synchronous structured operations — they do not queue embedding
/// jobs, so the encode-drain cycle that guards the memory lane does
/// not apply here. If the product changes this contract, add a barrier.
///
/// The estate is ALWAYS ephemeral so no Keychain material is orphaned.
func runFactLayerCell(
    corpus: FactLayerCorpus,
    config: FactLayerRunConfig
) async throws -> FactLayerCellOutcome {
    // C1: pass shape so .ram injects --in-memory into the served process.
    let endpoint = try lmeEndpointConfig(
        scratchDir: config.scratchDir,
        mootBinaryPath: config.mootBinaryPath,
        posture: config.posture,
        shape: config.shape)
    let client = MCPClient(endpoint: endpoint)
    try await client.connect()

    // ── C4: ingest timing — capture wall time for Steps 1+2 combined ─────
    // No dream/drain step: moot_file_fact and moot_retire_fact are synchronous
    // structured operations that do not queue embedding jobs, so there is no
    // settle point to wait for. The ingest phase (file + retire) is the
    // closest available capture point.
    let ingestStart = Date()

    // ── Step 1: File all facts, chronologically ───────────────────────────
    // Sort by event_time with id as tiebreak, matching the supersession lane.
    let ordered = corpus.facts.sorted {
        ($0.eventTime, $0.id) < ($1.eventTime, $1.id)
    }

    // harness fact id → product-assigned UUID from `moot_file_fact`
    var productUUIDByFactID: [String: String] = [:]
    var unfiledFactIDs: [String] = []

    for fact in ordered {
        let result = try await client.callTool(
            AriaV2Surface.fileFact,
            arguments: [
                "subject":          .string(fact.subject),
                "predicate":        .string(fact.predicate),
                "object":           .string(fact.object),
                // source_id is OMITTED on purpose: MXE-KH made the write
                // reject any source_id naming no real drawer (a synthetic
                // provenance string here failed all 120 files on
                // 2026-08-04). Omitted means "filed sourceless", which is
                // the contract for facts with no anchoring drawer; writer
                // provenance rides addedBy, stamped by the server.
            ],
            format: .mootV2)

        // `moot_file_fact` returns "filed fact <UUID>: [subject] predicate [object]".
        // MCPClient.parseMootText does not special-case this prefix (it handles
        // "filed memory"); extract the UUID by scanning the text blocks directly.
        if let uuid = factFileUUID(from: result.textBlocks) {
            productUUIDByFactID[fact.id] = uuid
        } else {
            unfiledFactIDs.append(fact.id)
        }
    }

    // ── Step 2: Retire non-current versions ──────────────────────────────
    // Group facts by chain: every non-current version is retired so only the
    // current version answers queries. A failed retire is a harness error,
    // not a product error — record it but do not abort the run.
    var retireFailures: [String] = []
    for fact in corpus.facts where !fact.isCurrent {
        guard let uuid = productUUIDByFactID[fact.id] else { continue }
        // v2: moot_retire_fact uses `fact_id` key (v1 used `id`).
        let result = try await client.callTool(
            AriaV2Surface.retireFact,
            arguments: ["fact_id": .string(uuid)],
            format: .mootV2)
        // A non-error response from moot_retire_fact is enough. If the product
        // confirms differently, update this check.
        if result.textBlocks.joined(separator: "\n")
            .lowercased().contains("error") {
            retireFailures.append(fact.id)
        }
    }
    if !retireFailures.isEmpty {
        // Log failures but continue — a partial retirement still produces a
        // measurable number; the retire contamination count will reflect it.
        let msg = "[fact-layer] WARNING: \(retireFailures.count) retire call(s) reported errors: "
            + retireFailures.prefix(5).joined(separator: ", ")
            + (retireFailures.count > 5 ? "..." : "")
        FileHandle.standardError.write(Data(msg.utf8))
    }

    // C4: close the ingest timing window. Steps 1+2 (file + retire) are the
    // ingest phase for this cell; there is no subsequent drain/dream settle point.
    let ingestElapsedSeconds = Date().timeIntervalSince(ingestStart)

    // ── Step 3: Query and score ───────────────────────────────────────────
    var queryResults: [FactLayerQueryResult] = []

    for query in corpus.queries {
        let start = Date()
        let result = try await client.callTool(
            AriaV2Surface.factSearch,
            arguments: ["query": .string(query.question)],
            format: .mootV2)
        let latency = Date().timeIntervalSince(start)

        // `moot_fact_search` result lines: "<UUID>  [subject] predicate [object]..."
        // MCPClient.parseMootText collects these into orderedIDs.
        let ranked = result.orderedIDs

        // Map corpus harness IDs to product UUIDs for comparison.
        let currentUUID = productUUIDByFactID[query.currentFactID]
        let retiredUUIDs = Set(query.retiredFactIDs.compactMap { productUUIDByFactID[$0] })

        let currentRank = currentUUID.flatMap { ranked.firstIndex(of: $0).map { $0 + 1 } }
        let retiredRanks = ranked.enumerated().compactMap { (idx, uuid) -> Int? in
            retiredUUIDs.contains(uuid) ? idx + 1 : nil
        }

        let wins: Bool = {
            guard let cr = currentRank else { return false }
            return retiredRanks.allSatisfy { cr < $0 }
        }()

        queryResults.append(FactLayerQueryResult(
            queryID: query.id,
            currentFactFound: currentRank != nil,
            retiredFactRanks: retiredRanks,
            currentFactRank: currentRank,
            currentWins: wins,
            latencySeconds: latency))
    }

    return FactLayerCellOutcome(
        queryResults: queryResults,
        productUUIDByFactID: productUUIDByFactID,
        unfiledFactIDs: unfiledFactIDs,
        ingestElapsedSeconds: ingestElapsedSeconds)
}

// MARK: - Helpers

/// Extracts the UUID from a `moot_file_fact` response.
///
/// The response format is:
///   `filed fact <UUID>: [<subject>] <predicate> [<object>]`
///
/// MCPClient.parseMootText handles "filed memory " but not "filed fact ";
/// this helper covers the fact-specific prefix.
private func factFileUUID(from textBlocks: [String]) -> String? {
    let prefix = "filed fact "
    for block in textBlocks {
        for rawLine in block.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces).lowercased()
            guard line.hasPrefix(prefix) else { continue }
            // Token after "filed fact " is "<UUID>:"; strip the colon.
            let after = rawLine.trimmingCharacters(in: .whitespaces)
                .dropFirst(prefix.count)
            let token = after.split(separator: ":").first
                .map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if UUID(uuidString: token) != nil { return token }
        }
    }
    return nil
}
