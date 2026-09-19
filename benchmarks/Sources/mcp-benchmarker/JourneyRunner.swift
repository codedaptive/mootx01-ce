import Foundation

// JourneyRunner.swift — the journey lane's live runner.
//
// The corpus generators, the recorder, the metrics module and the argument
// builders all shipped and were unit-tested against canned fixture replies.
// What never shipped was this file: the loop that provisions an estate, seeds
// it, and walks a real server. `benchmarks/journey.md` documented the lane,
// the run script called it as measured, and the subcommand threw — a lane with
// a definition and nothing behind it. Found on 2026-08-17 by running it, not by
// reviewing it, which is the whole argument for a smoke pass that executes
// every arm rather than checking that every arm is wired.
//
// SHAPE OF THE LANE. Two sub-corpora, two different measurements:
//
//   PRECISE-MISS is a SINGLE query. The target and a lexically denser decoy
//     both sit in the estate; the score is whether the target outranks the
//     decoy. There is no journey to walk — one search answers it.
//
//   VAGUE-NARROW is the JOURNEY. A vague question cannot be answered by one
//     query, so the agent walks four steps: survey the space, pivot from an
//     anchor into its neighbourhood, winnow to a candidate, hydrate the
//     candidate's full body. That walk is what JourneyRecorder records and
//     what JourneyMetrics scores — hops, token-turn integral, and how much
//     full content was pulled BEFORE the terminal step (cheap steps first is
//     the behaviour under measurement).
//
// SEAM. This reuses the supersession lane's plumbing rather than growing a
// second one: the same scratch-estate provisioning, the same batch seed import,
// the same encode barrier, the same UUID attribution pass, the same guarded
// teardown. One seam, never two paths to the same leaf.
//
// FAIRNESS RULE (inherited from JourneyCorpus). Every scored behaviour must be
// achievable by any competent retrieval system. The four steps use ordinary
// recall verbs and an anchor pivot; nothing here needs a moot-specific feature.

// MARK: - Configuration

/// Configuration for one journey lane run.
struct JourneyRunConfig: Sendable {
    /// Deterministic corpus seed; appears in the record name and the report.
    let seed: UInt64
    /// Path to the mootx01 binary the lane serves.
    let mootBinaryPath: String
    /// Scratch estate directory, created and retired by the caller.
    let scratchDir: URL
    /// At-rest posture. Ephemeral-encrypted by default, so a run leaves no key.
    let posture: ScratchEstatePosture
    /// Backend shape — disk-backed SQLite or in-memory.
    let shape: JourneyEstateShape
    /// Rank cutoff for "found". Ranks are 1-based, so this must be ≥ 1.
    let topK: Int
}

// MARK: - Outcomes

/// One PRECISE-MISS scenario's result.
struct PreciseMissOutcome: Sendable, Codable, Equatable {
    let scenarioID: String
    /// 1-based rank of the target, nil when absent from the top-k reply.
    let targetRank: Int?
    /// 1-based rank of the decoy, nil when absent.
    let decoyRank: Int?
    /// True when the target was returned AND outranked the decoy. A target
    /// that is absent does not outrank anything, and a decoy that is absent
    /// while the target is present counts as outranked — the decoy losing
    /// entirely is the strongest form of the behaviour being measured.
    let targetOutranksDecoy: Bool
    /// True when the target appeared anywhere in the top-k reply.
    let targetFound: Bool
    /// Seconds for the single scored query.
    let querySeconds: Double
    /// The recorded walk. A precise-miss journey is ONE step, and one step
    /// still has four counts — hops 1, integral equal to that step's payload,
    /// pre-terminal full content 0. benchmarks/journey.md defines the lane as
    /// those counts; omitting them because the walk is short measured
    /// correctness where the specification asked for cost.
    let metrics: JourneyMetrics
    /// The step sequence itself, per §What is recorded.
    let steps: [JourneyStep]
}

/// One VAGUE-NARROW cluster's journey result.
struct VagueNarrowOutcome: Sendable, Codable, Equatable {
    let clusterID: String
    /// True when the cluster's answer-carrying member was reached by the
    /// winnow step — the step the journey exists to land on.
    let trueFound: Bool
    /// 1-based rank of the true member within the winnow reply, nil when absent.
    let trueRank: Int?
    /// True when the terminal hydrate returned the true member's body.
    let hydratedTrueMember: Bool
    /// The recorded four-step walk, scored by JourneyMetrics.
    let metrics: JourneyMetrics
    /// The step sequence itself. benchmarks/journey.md §What is recorded asks
    /// for it per journey; only the derived counts were kept before.
    let steps: [JourneyStep]
    /// Seconds across all four steps.
    let journeySeconds: Double
}

/// Everything one journey run produced.
struct JourneyLaneOutcome: Sendable {
    let preciseMiss: [PreciseMissOutcome]
    let vagueNarrow: [VagueNarrowOutcome]
    /// Records actually seeded, from the import receipt rather than the plan.
    let seededRecords: Int
}

// MARK: - Seed records

/// Converts both sub-corpora into seed-file records.
///
/// Rooms separate the sub-corpora so a survey over one cannot be answered by a
/// stray hit in the other: `precise-miss` and `vague-narrow`. Within a room the
/// records are indistinguishable by metadata — the target, the decoy and the
/// fillers differ only in content, which is the point. Putting the answer in
/// the metadata would measure the harness's labelling, not the product's recall.
func journeySeedRecords(from corpus: JourneyCorpus) -> [SeedFileRecord] {
    var out: [SeedFileRecord] = []
    out.reserveCapacity(corpus.preciseMiss.records.count + corpus.vagueNarrow.records.count)
    for r in corpus.preciseMiss.records {
        out.append(SeedFileRecord(
            id: r.id, content: r.content, eventTime: r.eventTime, room: "precise-miss"))
    }
    for r in corpus.vagueNarrow.records {
        out.append(SeedFileRecord(
            id: r.id, content: r.content, eventTime: r.eventTime, room: "vague-narrow"))
    }
    // Chronological, id as tiebreak — same rule as the supersession lane. All
    // records in a scenario share an instant by design, so an unstable sort
    // would file them in an order that differs between runs and between legs.
    return out.sorted { ($0.eventTime, $0.id) < ($1.eventTime, $1.id) }
}

// MARK: - Lane

/// Runs the journey lane against a live server and returns both sub-corpora's
/// outcomes.
///
/// - Parameters:
///   - corpus: The generated corpus. A pure function of the seed.
///   - config: Binary, scratch estate, posture, shape and rank cutoff.
/// - Returns: Per-scenario and per-cluster outcomes.
/// - Throws: `MCPError` when the estate cannot be seeded, when the encode
///   queue does not settle, or when the UUID attribution pass is incomplete.
///   Each of those would otherwise produce a plausible-looking wrong number.
func runJourneyLane(
    corpus: JourneyCorpus,
    config: JourneyRunConfig
) async throws -> JourneyLaneOutcome {
    let endpoint = try lmeEndpointConfig(
        scratchDir: config.scratchDir,
        mootBinaryPath: config.mootBinaryPath,
        posture: config.posture,
        shape: config.shape == .ram ? .ram : .disk)
    let client = MCPClient(endpoint: endpoint)
    try await client.connect()

    // ── Seed ──────────────────────────────────────────────────────────────
    let seedRecords = journeySeedRecords(from: corpus)
    let seedData = emitSeedJSON(name: "journey-\(config.seed)", records: seedRecords)
    let seedURL = try writeSeedFile(
        seedData, in: config.scratchDir, name: "journey-\(config.seed)")
    let imported = try await client.callTool(
        AriaV2Surface.jsonImport,
        arguments: [
            "path": .string(seedURL.path),
            // return_id_map: the reply carries a second text block holding the
            // record-id → drawer-UUID map. The importer mints the ids, so it is
            // the only source that is both exact and total (see seedIDMap).
            "return_id_map": .bool(true),
        ],
        format: .mootV2,
        // Bulk tier: one call seeds the entire corpus.
        deadline: MCPDeadline.bulk)
    // v2 surface: drawer count is in structuredContent.data.drawers_written.
    guard let written = imported.drawersWritten, written == seedRecords.count else {
        throw MCPError(description:
            "journey: moot_json_import did not confirm \(seedRecords.count) drawers "
            + "— refusing to score an unseeded estate. Got: "
            + (imported.drawersWritten.map(String.init) ?? "(no structured data)"))
    }

    // ── Barrier ───────────────────────────────────────────────────────────
    // Querying a partially-indexed estate returns understated rankings with no
    // visible signal — a wrong number that reads like a right one.
    let barrier = await waitForEncodeDrain(
        client: client, label: "journey seed=\(config.seed)")
    guard barrier.converged else {
        throw MCPError(description:
            "journey: encode drain did not converge within 300s — refusing to query "
            + "a partially-indexed estate. Re-run on an unloaded machine.")
    }

    // ── Attribution ───────────────────────────────────────────────────────
    // The corpus-id → drawer-UUID map comes from the import receipt's id_map
    // block. Scoring needs it in both directions: forward to know which UUID
    // is the target, reverse to name what a reply returned. `seedIDMap` throws
    // on a short map, so a partial map can never be scored.
    let uuidByRecordID = try seedIDMap(
        fromImportBlocks: imported.textBlocks,
        expecting: seedRecords.count,
        label: "journey seed=\(config.seed)")
    var recordIDByUUID: [String: String] = [:]
    for (recordID, uuid) in uuidByRecordID { recordIDByUUID[uuid] = recordID }

    /// 1-based rank of `recordID` within a reply's ordered UUIDs.
    func rank(of recordID: String, in orderedIDs: [String]) -> Int? {
        guard let uuid = uuidByRecordID[recordID] else { return nil }
        return orderedIDs.firstIndex(of: uuid).map { $0 + 1 }
    }

    // ── PRECISE-MISS: one query per scenario ──────────────────────────────
    var preciseMiss: [PreciseMissOutcome] = []
    preciseMiss.reserveCapacity(corpus.preciseMiss.scenarios.count)
    for scenario in corpus.preciseMiss.scenarios {
        let started = Date()
        let reply = try await client.callTool(
            AriaV2Surface.memorySearch,
            arguments: [
                "query": .string(scenario.question),
                "limit": .number(Double(config.topK)),
            ],
            format: .mootV2)
        let seconds = Date().timeIntervalSince(started)
        let ids = reply.orderedIDs
        let targetRank = rank(of: scenario.targetRecordID, in: ids)
        let decoyRank = rank(of: scenario.decoyRecordID, in: ids)
        // Target absent → it outranks nothing. Decoy absent with target
        // present → the strongest form of the measured behaviour.
        let outranks: Bool
        switch (targetRank, decoyRank) {
        case let (t?, d?): outranks = t < d
        case (_?, nil):    outranks = true
        default:           outranks = false
        }
        // One step, and it IS the terminal step: the single search answers the
        // question. hydratedFullContent is false — a dense recall reply is not
        // a full-body fetch.
        var pmRecorder = JourneyRecorder()
        pmRecorder.append(verb: "recall",
                          replyText: reply.textBlocks.joined(separator: "\n"),
                          hydratedFullContent: false,
                          terminal: true)
        preciseMiss.append(PreciseMissOutcome(
            scenarioID: scenario.id,
            targetRank: targetRank,
            decoyRank: decoyRank,
            targetOutranksDecoy: outranks,
            targetFound: targetRank != nil,
            querySeconds: seconds,
            metrics: pmRecorder.metrics(),
            steps: pmRecorder.currentSteps()))
    }

    // ── VAGUE-NARROW: the four-step journey per cluster ───────────────────
    var vagueNarrow: [VagueNarrowOutcome] = []
    vagueNarrow.reserveCapacity(corpus.vagueNarrow.clusters.count)
    // Winnow narrows to a third of the survey width, floored at one. The
    // journey's value is landing on the answer with a SMALLER reply, so the
    // winnow step must actually narrow; querying at survey width again would
    // score the same reply twice and call the second one progress.
    let winnowLimit = max(1, config.topK / 3)

    for cluster in corpus.vagueNarrow.clusters {
        let started = Date()
        var recorder = JourneyRecorder()

        // 1. SURVEY — broad recall on the vague question.
        let survey = try await client.callTool(
            AriaV2Surface.memorySearch,
            arguments: [
                "query": .string(cluster.question),
                "limit": .number(Double(config.topK)),
            ],
            format: .mootV2)
        recorder.append(verb: "survey",
                        replyText: survey.textBlocks.joined(separator: "\n"),
                        hydratedFullContent: false, terminal: false)

        // 2. PIVOT — anchor on the survey's top hit and explore its
        //    neighbourhood. `near` is a different code path from text recall,
        //    which is why the pivot is worth measuring separately. With no
        //    survey hit there is nothing to anchor on, and the journey is
        //    recorded as the short walk it actually was rather than being
        //    padded with a synthetic step.
        var pivotIDs: [String] = []
        if let anchor = survey.orderedIDs.first {
            let pivot = try await client.callTool(
                AriaV2Surface.memorySearch,
                arguments: nearPivotSearchArgs(
                    uuid: anchor,
                    extraArgs: ["limit": .number(Double(config.topK))]),
                format: .mootV2)
            pivotIDs = pivot.orderedIDs
            recorder.append(verb: "pivot",
                            replyText: pivot.textBlocks.joined(separator: "\n"),
                            hydratedFullContent: false, terminal: false)
        }

        // 3. WINNOW — narrow to the candidate that answers the question.
        let winnow = try await client.callTool(
            AriaV2Surface.memorySearch,
            arguments: [
                "query": .string(cluster.question),
                "limit": .number(Double(winnowLimit)),
            ],
            format: .mootV2)
        let winnowIDs = winnow.orderedIDs
        recorder.append(verb: "winnow",
                        replyText: winnow.textBlocks.joined(separator: "\n"),
                        hydratedFullContent: false, terminal: false)

        // 4. HYDRATE — pull the full body of the winnowed candidate. This is
        //    the terminal step and the only one that pays for full content.
        var hydratedTrue = false
        if let candidate = winnowIDs.first {
            let hydrate = try await client.callTool(
                AriaV2Surface.memoryGet,
                arguments: batchHydrateArgs(ids: [candidate], depth: .full),
                format: .mootV2)
            recorder.append(verb: "hydrate",
                            replyText: hydrate.textBlocks.joined(separator: "\n"),
                            hydratedFullContent: true, terminal: true)
            hydratedTrue = recordIDByUUID[candidate] == cluster.trueID
        }

        let trueRank = rank(of: cluster.trueID, in: winnowIDs)
        _ = pivotIDs  // Recorded in the walk; not scored on its own.
        vagueNarrow.append(VagueNarrowOutcome(
            clusterID: cluster.id,
            trueFound: trueRank != nil,
            trueRank: trueRank,
            hydratedTrueMember: hydratedTrue,
            metrics: recorder.metrics(),
            steps: recorder.currentSteps(),
            journeySeconds: Date().timeIntervalSince(started)))
    }

    return JourneyLaneOutcome(
        preciseMiss: preciseMiss,
        vagueNarrow: vagueNarrow,
        seededRecords: seedRecords.count)
}

// MARK: - Report

/// Aggregate figures for the PRECISE-MISS sub-corpus.
struct PreciseMissAggregate: Codable, Sendable, Equatable {
    let scenarios: Int
    // THE LANE'S METRICS, per benchmarks/journey.md §Metrics: four integer
    // counts over the step sequence. A precise-miss journey is one step, which
    // makes hops 1 and the pre-terminal count 0 by construction — that is the
    // measurement, not a reason to omit it.
    let meanHops: Double
    let meanTokenTurnIntegral: Double
    let meanPreTerminalFullContentTokens: Double
    let meanTotalPayloadTokens: Double
    // Supporting correctness figures. Useful, and NOT what the definition says
    // the lane measures: reporting these as the headline is what defect 10
    // was.
    let targetOverDecoyRate: Double
    let targetFoundRate: Double
    /// Mean 1-based rank of the target across scenarios where it was found.
    let meanTargetRank: Double?
    let queryP50Seconds: Double

    enum CodingKeys: String, CodingKey {
        case scenarios
        case meanHops = "mean_hops"
        case meanTokenTurnIntegral = "mean_token_turn_integral"
        case meanPreTerminalFullContentTokens = "mean_pre_terminal_full_content_tokens"
        case meanTotalPayloadTokens = "mean_total_payload_tokens"
        case targetOverDecoyRate = "target_over_decoy_rate"
        case targetFoundRate = "target_found_rate"
        case meanTargetRank = "mean_target_rank"
        case queryP50Seconds = "query_p50_seconds"
    }
}

/// Aggregate figures for the VAGUE-NARROW sub-corpus.
struct VagueNarrowAggregate: Codable, Sendable, Equatable {
    let clusters: Int
    /// The lane's headline: how often the journey landed on the answer.
    let trueFoundRate: Double
    let hydratedTrueRate: Double
    let meanTrueRank: Double?
    let meanHops: Double
    /// Mean token-turn integral — the cost of the walk, not just its success.
    let meanTokenTurnIntegral: Double
    /// Mean full-content tokens pulled BEFORE the terminal step. Cheap steps
    /// first is the behaviour under measurement, so a nonzero mean here is a
    /// finding rather than noise.
    let meanPreTerminalFullContentTokens: Double
    /// The fourth count from §Metrics, absent until 2026-08-18.
    let meanTotalPayloadTokens: Double
    let journeyP50Seconds: Double

    enum CodingKeys: String, CodingKey {
        case clusters
        case trueFoundRate = "true_found_rate"
        case hydratedTrueRate = "hydrated_true_rate"
        case meanTrueRank = "mean_true_rank"
        case meanHops = "mean_hops"
        case meanTokenTurnIntegral = "mean_token_turn_integral"
        case meanPreTerminalFullContentTokens = "mean_pre_terminal_full_content_tokens"
        case meanTotalPayloadTokens = "mean_total_payload_tokens"
        case journeyP50Seconds = "journey_p50_seconds"
    }
}

/// What this run covered, per the §6 required-field rule. A report that cannot
/// answer "how much of the benchmark is this?" is the defect that cost eight
/// days on LMEB and MemBench.
struct JourneyCoverage: Codable, Sendable, Equatable {
    let preciseMissScenarios: Int
    let vagueNarrowClusters: Int
    let membersPerCluster: Int
    let recordsSeeded: Int
    let shape: String
    let estatePosture: String

    enum CodingKeys: String, CodingKey {
        case preciseMissScenarios = "precise_miss_scenarios"
        case vagueNarrowClusters = "vague_narrow_clusters"
        case membersPerCluster = "members_per_cluster"
        case recordsSeeded = "records_seeded"
        case shape
        case estatePosture = "estate_posture"
    }
}

/// The journey lane's report.
struct JourneyReport: Codable, Sendable {
    /// The estate schema the harness was built against, stamped into every
    /// report so the results record can carry the column without anyone typing
    /// it (BENCHMARK_PROTOCOL §9). Constant rather than a parameter: a report
    /// describes the run that produced it, and that run's artifacts were
    /// validated against this exact value on open, so a mismatch fails the run
    /// rather than reaching a report.
    ///
    /// Declared with its value, so it is always encoded and never decoded: an
    /// older report that predates the field still reads.
    let estateSchemaVersion: String = currentEstateSchemaVersion

    let benchmarkProtocolVersion: String
    let runEnvironment: RunEnvironment
    let seed: UInt64
    let topK: Int
    let coverage: JourneyCoverage
    let preciseMissAggregate: PreciseMissAggregate
    let vagueNarrowAggregate: VagueNarrowAggregate
    let preciseMiss: [PreciseMissOutcome]
    let vagueNarrow: [VagueNarrowOutcome]

    enum CodingKeys: String, CodingKey {
        case estateSchemaVersion     = "estate_schema_version"
        case benchmarkProtocolVersion = "benchmark_protocol_version"
        case runEnvironment = "run_environment"
        case seed
        case topK = "k"
        case coverage
        case preciseMissAggregate = "precise_miss_aggregate"
        case vagueNarrowAggregate = "vague_narrow_aggregate"
        case preciseMiss = "precise_miss"
        case vagueNarrow = "vague_narrow"
    }
}

/// Returns the p50 of `values`, or 0 when empty.
///
/// Nearest-rank on the sorted values: with an even count this takes the upper
/// of the two middles rather than averaging them, matching how the other lanes
/// report p50 so figures stay comparable across the suite.
func journeyP50(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, sorted.count / 2)]
}

/// Builds the report from a lane outcome.
func buildJourneyReport(
    corpus: JourneyCorpus,
    outcome: JourneyLaneOutcome,
    config: JourneyRunConfig,
    runEnvironment: RunEnvironment
) -> JourneyReport {
    let pm = outcome.preciseMiss
    let vn = outcome.vagueNarrow
    let pmCount = Double(max(1, pm.count))
    let vnCount = Double(max(1, vn.count))

    let foundTargetRanks = pm.compactMap(\.targetRank).map(Double.init)
    let foundTrueRanks = vn.compactMap(\.trueRank).map(Double.init)

    // Means of the four counts, computed the same way for both sub-corpora.
    // Broken out of the initialiser: the compiler could not type-check the
    // combined expression in reasonable time once the counts were added.
    let pmHops = pm.isEmpty ? 0 : Double(pm.map(\.metrics.hops).reduce(0, +)) / pmCount
    let pmIntegral = pm.isEmpty ? 0
        : Double(pm.map(\.metrics.tokenTurnIntegral).reduce(0, +)) / pmCount
    let pmPreTerminal = pm.isEmpty ? 0
        : Double(pm.map(\.metrics.preTerminalFullContentTokens).reduce(0, +)) / pmCount
    let pmTotalPayload = pm.isEmpty ? 0
        : Double(pm.map(\.metrics.totalPayloadTokens).reduce(0, +)) / pmCount
    let pmOverDecoy = pm.isEmpty ? 0
        : Double(pm.filter(\.targetOutranksDecoy).count) / pmCount
    let pmFound = pm.isEmpty ? 0 : Double(pm.filter(\.targetFound).count) / pmCount
    let pmMeanRank: Double? = foundTargetRanks.isEmpty ? nil
        : foundTargetRanks.reduce(0, +) / Double(foundTargetRanks.count)

    let pmAgg = PreciseMissAggregate(
        scenarios: pm.count,
        meanHops: pmHops,
        meanTokenTurnIntegral: pmIntegral,
        meanPreTerminalFullContentTokens: pmPreTerminal,
        meanTotalPayloadTokens: pmTotalPayload,
        targetOverDecoyRate: pmOverDecoy,
        targetFoundRate: pmFound,
        meanTargetRank: pmMeanRank,
        queryP50Seconds: journeyP50(pm.map(\.querySeconds)))

    let vnPreTerminal = vn.isEmpty ? 0
        : Double(vn.map(\.metrics.preTerminalFullContentTokens).reduce(0, +)) / vnCount
    let vnTotalPayload = vn.isEmpty ? 0
        : Double(vn.map(\.metrics.totalPayloadTokens).reduce(0, +)) / vnCount

    let vnAgg = VagueNarrowAggregate(
        clusters: vn.count,
        trueFoundRate: vn.isEmpty ? 0 : Double(vn.filter(\.trueFound).count) / vnCount,
        hydratedTrueRate: vn.isEmpty ? 0
            : Double(vn.filter(\.hydratedTrueMember).count) / vnCount,
        meanTrueRank: foundTrueRanks.isEmpty ? nil
            : foundTrueRanks.reduce(0, +) / Double(foundTrueRanks.count),
        meanHops: vn.isEmpty ? 0
            : Double(vn.map(\.metrics.hops).reduce(0, +)) / vnCount,
        meanTokenTurnIntegral: vn.isEmpty ? 0
            : Double(vn.map(\.metrics.tokenTurnIntegral).reduce(0, +)) / vnCount,
        meanPreTerminalFullContentTokens: vnPreTerminal,
        meanTotalPayloadTokens: vnTotalPayload,
        journeyP50Seconds: journeyP50(vn.map(\.journeySeconds)))

    return JourneyReport(
        benchmarkProtocolVersion: benchmarkProtocolVersion,
        runEnvironment: runEnvironment,
        seed: config.seed,
        topK: config.topK,
        coverage: JourneyCoverage(
            preciseMissScenarios: corpus.preciseMiss.scenarios.count,
            vagueNarrowClusters: corpus.vagueNarrow.clusters.count,
            membersPerCluster: corpus.vagueNarrow.membersPerCluster,
            recordsSeeded: outcome.seededRecords,
            shape: config.shape.rawValue,
            estatePosture: "\(config.posture)"),
        preciseMissAggregate: pmAgg,
        vagueNarrowAggregate: vnAgg,
        preciseMiss: pm,
        vagueNarrow: vn)
}

/// Formats the stdout summary an operator reads first.
///
/// A metric with no samples prints "n/a", never a number: an absent mean and a
/// mean of zero are different findings, and printing zero for both hides the
/// difference behind a plausible value.
func journeySummaryText(_ report: JourneyReport) -> String {
    func rankText(_ v: Double?) -> String {
        v.map { String(format: "%.2f", $0) } ?? "n/a"
    }
    let pm = report.preciseMissAggregate
    let vn = report.vagueNarrowAggregate
    return """

        [journey] run complete (seed \(report.seed), k=\(report.topK))
          The lane measures the COST of reaching a correct answer
          (benchmarks/journey.md §Metrics): four counts per journey. The
          correctness rates below are supporting data, not the metric.

          PRECISE-MISS  scenarios: \(pm.scenarios)
            mean hops:              \(String(format: "%.2f", pm.meanHops))
            mean token-turn:        \(String(format: "%.1f", pm.meanTokenTurnIntegral))
            pre-terminal full:      \(String(format: "%.1f", pm.meanPreTerminalFullContentTokens))
            total payload:          \(String(format: "%.1f", pm.meanTotalPayloadTokens))
            -- supporting --
            target over decoy:      \(String(format: "%.4f", pm.targetOverDecoyRate))
            target found:           \(String(format: "%.4f", pm.targetFoundRate))
            mean target rank:       \(rankText(pm.meanTargetRank))
            query p50:              \(String(format: "%.3f", pm.queryP50Seconds)) s

          VAGUE-NARROW  clusters: \(vn.clusters)
            mean hops:              \(String(format: "%.2f", vn.meanHops))
            mean token-turn:        \(String(format: "%.1f", vn.meanTokenTurnIntegral))
            pre-terminal full:      \(String(format: "%.1f", vn.meanPreTerminalFullContentTokens))   <- cheap steps first; lower is better
            total payload:          \(String(format: "%.1f", vn.meanTotalPayloadTokens))
            -- supporting --
            true member found:      \(String(format: "%.4f", vn.trueFoundRate))
            hydrated true member:   \(String(format: "%.4f", vn.hydratedTrueRate))
            mean true rank:         \(rankText(vn.meanTrueRank))
            journey p50:            \(String(format: "%.3f", vn.journeyP50Seconds)) s

        """
}
