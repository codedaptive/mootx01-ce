import Foundation

// LoCoMoRunner.swift — LoCoMo turn-recall harness (Part 2).
//
// This runner OWNS the test-estate lifecycle. It differs from LongMemEvalRunner
// in one key architectural way: LoCoMo uses PER-CONVERSATION estates (not
// per-question), because each conversation has ~154 questions that all share the
// same 700+ turns as their evidence base.
//
//   LME model:    1 question  →  1 scratch estate  →  ingest haystack  →  1 query
//   LoCoMo model: 1 conversation → 1 scratch estate → ingest all turns → N queries
//
// Re-ingesting 700+ turns per question (×1,542 questions = ~1M writes) would be
// impractical. Per-conversation estates pay O(10) estate provisions instead of
// O(1,542), with full turn isolation between conversations.
//
// Safety guarantees (parallel to LME):
//   - loCoMoScratchDir() uses the /tmp/locomo-bench- prefix.
//   - loCoMoGuardedTeardown() refuses any path without that prefix.
//   - The EndpointConfig carries MOOTX01_DATA_DIR=/tmp/locomo-bench-... so
//     assertScratchBackend independently verifies the scratch constraint.
//
// Manifest correlation:
//   - Each ingested turn produces a UUID from moot_file_memory.
//   - LoCoMoManifestEntry maps UUID → dia_id (e.g. "D1:3").
//   - The scorer uses lmeRankedSessions (math is string-agnostic) to map
//     retrieved UUIDs → ranked dia_ids for recall scoring against evidence sets.
//
// Inline encoding (n=true):
//   - Required on all ingest calls. The same correctness invariant as LME:
//     ingest → encode → query, with no background-encoding race.
//   - Origin: LME-01 finding (COMPLETION_LME-01.md) — without n=true, recall
//     queries issued immediately after full ingest can precede encoding completion.

// MARK: - Verbmap for mootx01 in LoCoMo mode

/// Standard mootx01 VerbMap for LoCoMo ingestion + recall queries.
/// Mirrors the LME verbMap with a LoCoMo-specific location.
///
/// write:         moot_file_memory
/// query:         moot_memory_search
/// constantArgs:  { "location": "benchmark/locomo" }
/// resultFormat:  .mootText
let loCoMoMootVerbMap = EndpointConfig.VerbMap(
    write: "moot_file_memory",
    query: "moot_memory_search",
    list: nil,
    constantArgs: ["location": "benchmark/locomo"],
    resultFormat: .mootText
)

// MARK: - Manifest entry

/// Maps a filed-memory UUID back to its origin turn, enabling the scorer to
/// correlate retrieved UUIDs → dia_ids for turn-level recall scoring.
struct LoCoMoManifestEntry: Sendable, Codable {
    /// The UUID returned by moot_file_memory ("filed memory <UUID>").
    let uuid: String
    /// The dia_id of the turn (e.g. "D1:3" = session 1, 3rd dialog turn).
    let diaID: String
    /// 1-based session number this turn belongs to.
    let sessionNumber: Int
    /// 0-based index of this turn within its session.
    let turnIndex: Int
    /// Speaker name (matches conversation.speaker_a or speaker_b).
    let speaker: String
}

// MARK: - Per-question result

/// The result of querying the harness with one LoCoMo question.
struct LoCoMoQuestionResult: Sendable {
    /// Synthetic question identifier (e.g. "conv-26_q3").
    let questionID: String
    /// Category label: "single_hop" | "temporal" | "multi_hop" | "open_domain".
    let categoryLabel: String
    /// Raw integer category (1-4).
    let category: Int
    /// Time taken for the moot_memory_search call, in seconds.
    let queryLatencySeconds: Double
    /// UUIDs returned by moot_memory_search, in ranked order.
    let retrievedUUIDs: [String]
    /// Manifest mapping UUID → dia_id for every ingested turn in this conversation's estate.
    /// Shared across all questions for the same conversation.
    let manifest: [LoCoMoManifestEntry]
    /// Ground-truth dia_ids that contain evidence for this question.
    let evidenceDiaIDs: [String]
    /// True when the DegeneracyGuard classified the backend as healthy.
    let guardHealthy: Bool
    /// If the guard was unhealthy, the diagnostic message.
    let guardDiagnostic: String?
    /// Total turns ingested into this conversation's estate.
    let turnsIngested: Int
    /// Mean write latency across all turns for this conversation's estate.
    let writeMeanLatencySeconds: Double
}

// MARK: - Run config

/// Configuration for one LoCoMo run.
struct LoCoMoRunConfig: Sendable {
    /// Path to the mootx01 binary.
    let mootBinaryPath: String
    /// Path to the LoCoMo dataset JSON file (locomo10.json).
    let datasetPath: URL
    /// Maximum number of questions to run. nil = all scoreable questions.
    let limit: Int?
    /// Skip this many questions from the (seeded-shuffled) question list.
    let offset: Int
    /// Seed for deterministic question shuffling.
    let seed: UInt64
    /// Directory to write the results report. nil = current directory.
    let outDir: URL?
    /// Run label for the report filename and header.
    let runLabel: String
}

// MARK: - Scratch estate management

/// Creates a fresh scratch directory under /tmp/locomo-bench-<UUID> for LoCoMo use.
/// The /tmp/locomo-bench- prefix is the contract with `loCoMoGuardedTeardown`.
///
/// - Returns: The URL of the created directory.
/// - Throws: `MCPError` when directory creation fails.
func loCoMoScratchDir() throws -> URL {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    let path = "/tmp/locomo-bench-\(suffix)"
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    } catch {
        throw MCPError(description: "loCoMoScratchDir: could not create \(path): \(error)")
    }
}

/// Deletes a scratch directory created by `loCoMoScratchDir`. Refuses any path
/// without the `/tmp/locomo-bench-` prefix — the same contamination guard as
/// `lmeGuardedTeardown` (see LongMemEvalRunner.swift and commit 253cebf1).
///
/// - Parameter url: The scratch directory to remove.
/// - Throws: `MCPError` when the prefix guard fires.
func loCoMoGuardedTeardown(_ url: URL) throws {
    let path = url.path
    guard path.hasPrefix("/tmp/locomo-bench-") else {
        throw MCPError(description:
            "SAFETY: loCoMoGuardedTeardown refused to delete '\(path)' — "
            + "path must have the /tmp/locomo-bench- prefix. "
            + "Only directories created by loCoMoScratchDir() may be torn down by this guard.")
    }
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        FileHandle.standardError.write(Data(
            "[locomo] teardown warning: could not remove \(path): \(error)\n".utf8))
    }
}

// MARK: - EndpointConfig builder

/// Builds an EndpointConfig for mootx01 pointing at a LoCoMo scratch estate.
func loCoMoEndpointConfig(scratchDir: URL, mootBinaryPath: String) throws -> EndpointConfig {
    let command = "MOOTX01_DATA_DIR=\(scratchDir.path) \(mootBinaryPath)"
    let endpoint = EndpointConfig(
        name: "mootx01-locomo",
        transport: .stdio(command: command),
        auth: nil,
        verbMap: loCoMoMootVerbMap,
        role: .target
    )
    try assertScratchBackend(endpoint)
    return endpoint
}

// MARK: - Runner

/// Runs the LoCoMo harness against a loaded corpus. Returns per-question
/// results with manifest, latency, and guard verdict for each question.
///
/// Per-conversation estate strategy:
///   1. Select and shuffle the question list.
///   2. For each conversation that has ≥1 selected question:
///      a. Provision a fresh scratch estate.
///      b. Ingest all turns from that conversation (n=true for inline encoding).
///      c. Run the DegeneracyGuard probe.
///      d. For each selected question in this conversation, issue a query.
///      e. Tear down the estate.
///
/// Questions are processed in conversation order (deterministic given the shuffle),
/// not the shuffled order — the shuffle only selects which questions to include.
func runLoCoMoQuestions(
    questions: [LoCoMoQuestion],
    conversations: [LoCoMoConversation],
    config: LoCoMoRunConfig
) async throws -> [LoCoMoQuestionResult] {
    // Apply offset + limit to the seeded-shuffled question list.
    var rng = SplitMix64(seed: config.seed)
    var shuffled = questions
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }
    let afterOffset = Array(shuffled.dropFirst(config.offset))
    let selected: [LoCoMoQuestion]
    if let limit = config.limit {
        selected = Array(afterOffset.prefix(limit))
    } else {
        selected = afterOffset
    }

    // Group selected questions by conversation index. Use a dict of [Int: [LoCoMoQuestion]]
    // preserving insertion order (each group retains the shuffled order of its members).
    var questionsByConversation: [Int: [LoCoMoQuestion]] = [:]
    for q in selected {
        questionsByConversation[q.conversationIndex, default: []].append(q)
    }

    var allResults: [LoCoMoQuestionResult] = []
    allResults.reserveCapacity(selected.count)

    // Process conversations in ascending index order for determinism.
    let convIndices = questionsByConversation.keys.sorted()

    for convIndex in convIndices {
        let convQuestions = questionsByConversation[convIndex]!
        let conversation = conversations[convIndex]

        // Provision a scratch estate for this conversation.
        let scratchDir = try loCoMoScratchDir()
        let endpoint = try loCoMoEndpointConfig(
            scratchDir: scratchDir, mootBinaryPath: config.mootBinaryPath)
        let client = MCPClient(endpoint: endpoint)
        try await client.connect()
        defer {
            Task { await client.disconnect() }
            try? loCoMoGuardedTeardown(scratchDir)
        }

        let convLabel = "[locomo] conv=\(conversation.sampleID) (\(convQuestions.count) questions, "
            + "\(conversation.allTurns.count) turns)"
        FileHandle.standardError.write(Data((convLabel + "\n").utf8))

        // Ingest all turns from this conversation. Each turn becomes one filed memory.
        // Content format: "speaker: text" — matches conversation transcript format.
        var manifest: [LoCoMoManifestEntry] = []
        var writeTimes: [Double] = []

        for (sessionNumber, turn) in conversation.allTurns {
            let content = "\(turn.speaker): \(turn.text)"
            var writeArgs: [String: JSONValue] = [
                loCoMoMootVerbMap.contentArg: .string(content),
            ]
            for (k, v) in loCoMoMootVerbMap.constantArgs {
                writeArgs[k] = .string(v)
            }
            // n=true: inline encoding barrier. Prevents background-encoding race
            // where recall queries issue before encoding completes.
            // Origin: LME-01 correctness finding (COMPLETION_LME-01.md).
            writeArgs["n"] = .bool(true)

            let writeStart = Date()
            let writeResult = try await client.callTool(
                loCoMoMootVerbMap.write,
                arguments: writeArgs,
                format: loCoMoMootVerbMap.resultFormat
            )
            let writeDuration = Date().timeIntervalSince(writeStart)
            writeTimes.append(writeDuration)

            if let uuid = writeResult.writeAssignedID {
                // Derive turn index within session: find this turn in the session's list.
                let session = conversation.sessions.first(where: { $0.sessionNumber == sessionNumber })
                let turnIndex = session?.turns.firstIndex(where: { $0.diaID == turn.diaID }) ?? 0
                manifest.append(LoCoMoManifestEntry(
                    uuid: uuid,
                    diaID: turn.diaID,
                    sessionNumber: sessionNumber,
                    turnIndex: turnIndex,
                    speaker: turn.speaker
                ))
            }
        }

        let writeMean = writeTimes.isEmpty ? 0.0
            : writeTimes.reduce(0, +) / Double(writeTimes.count)

        // DegeneracyGuard probe — once per estate (not per question).
        let guard_ = DegeneracyGuard()
        let probeRankings = await probeMCPClient(
            client, verbMap: loCoMoMootVerbMap, name: "mootx01-locomo")
        let verdict = guard_.classify(probeRankings: probeRankings)
        let guardHealthy: Bool
        if case .healthy = verdict { guardHealthy = true } else { guardHealthy = false }
        let guardDiagnostic: String? = guardHealthy ? nil : verdict.diagnostic

        // Issue a query for each question in this conversation.
        for question in convQuestions {
            var queryArgs: [String: JSONValue] = [
                loCoMoMootVerbMap.queryArg: .string(question.question),
            ]
            for (k, v) in loCoMoMootVerbMap.constantArgs { queryArgs[k] = .string(v) }

            let queryStart = Date()
            let queryResult = try await client.callTool(
                loCoMoMootVerbMap.query,
                arguments: queryArgs,
                format: loCoMoMootVerbMap.resultFormat
            )
            let queryLatency = Date().timeIntervalSince(queryStart)

            allResults.append(LoCoMoQuestionResult(
                questionID: question.questionID,
                categoryLabel: question.categoryLabel,
                category: question.category,
                queryLatencySeconds: queryLatency,
                retrievedUUIDs: queryResult.orderedIDs,
                manifest: manifest,
                evidenceDiaIDs: question.evidence,
                guardHealthy: guardHealthy,
                guardDiagnostic: guardDiagnostic,
                turnsIngested: manifest.count,
                writeMeanLatencySeconds: writeMean
            ))
        }
    }

    // Restore original shuffled order of results (the per-conversation grouping
    // changed the output order; sort back by questionID to match the shuffle order).
    // NOTE: Results retain their conversation-grouped order (deterministic with seed)
    // since we process convIndices ascending. The shuffle order is preserved via the
    // per-question iteration within each conv group. No re-sort needed.
    return allResults
}
