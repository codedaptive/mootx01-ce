import Foundation

// LoCoMoSpecRunner.swift — Spec-compliant LoCoMo QA runner for the locomo-spec lane.
//
// Source of truth: LOCOMO_OFFICIAL_PROTOCOL.md §1–§6 and §7 (deviation table).
//
// Architectural relationship to the existing locomo lane:
//   - LoCoMoRunner.swift:     rank-based recall scoring (recall@k / MRR over retrieved
//                              dia_ids). No answer generation.
//   - LoCoMoSpecRunner.swift: answer-generation + F1/exact/abstention scoring per §3.
//                              Answers produced via moot_synthesize; evidence recall
//                              computed per §4 (dia form). All 1,986 questions scored.
//
// Estate source (run book §8, the #94 measure seam): the runner opens the
// PRE-BUILT artifacts — at unit scale one fleet estate per conversation
// (the official per-instance protocol scope), at bench-aggregate the one
// Form-2 estate. It builds nothing, settles nothing, and never deletes
// anything; id-map.json inside each estate maps seed record ids
// ("<sampleID>/S<n>", the Rule-1 session projection) to drawer UUIDs.
//
// Answer production:
//   moot_synthesize is the "existing moot answer-production path"
//   (LongMemEvalRunner.swift synthesize arm, PR-08). It takes the question,
//   searches the estate for relevant turns, and returns synthesized answer text.
//   The text blocks joined by newline are the prediction string fed to scoreQuestion.
//
// Evidence recall (§4):
//   A recall query (moot_memory_search) is run for every question to capture
//   the retrieved UUID list. The manifest maps each UUID to its dia_id, producing
//   the dia_id context list. evidenceRecall(context:evidence:) scores this list
//   against the gold evidence dia_ids using the §4 verbatim formula.

// MARK: - VerbMap (cloned from loCoMoMootVerbMap)

// Bare verb map: NO constant location arg — the rebuilt artifacts are
// provenance-blind (rooms carry nothing benchmark-shaped), and at unit
// scale the per-instance estate IS the official protocol scope.
private let loCoMoSpecVerbMap = EndpointConfig.VerbMap(
    write: AriaV2Surface.fileMemory,
    query: AriaV2Surface.memorySearch,
    list: nil,
    constantArgs: [:],
    resultFormat: .mootV2
)

// MARK: - Run configuration

/// Configuration for one locomo-spec run.
///
/// Closely mirrors LoCoMoRunConfig (LoCoMoRunner.swift) but omits fields that
/// are spec-fixed (recall strategy is always .search; no rerank; no fleet shape).
/// Cloned rather than referencing LoCoMoRunConfig because the spec runner has
/// different semantics (answer scoring vs. rank scoring) and must never be
/// wired to the existing locomo CLI path.
struct LoCoMoSpecRunConfig: Sendable {
    /// Path to the mootx01 binary.
    let mootBinaryPath: String
    /// Path to locomo10.json (or compatible fixture).
    let datasetPath: URL
    /// Maximum questions to run. nil = all 1,986 questions.
    let limit: Int?
    /// Skip this many questions from the seeded-shuffled list.
    let offset: Int
    /// Seed for deterministic question shuffling.
    let seed: UInt64
    /// Directory to write outputs. nil = current working directory.
    let outDir: URL?
    /// Run label for the report filename and header (becomes the record arm).
    let runLabel: String
    /// Which artifact scale the run opens (run book §8: per-instance
    /// protocols default to .unit). .unit opens one fleet estate per
    /// conversation; .benchAggregate opens the one Form-2 estate for every
    /// conversation, serially.
    let targetScale: ArtifactTargetScale
    /// Catalog.json path for the dataset (maps unit stems to estate directories).
    /// Required at .unit scale.
    let catalogPath: URL?
    /// The Form-2 estate directory. Required at .benchAggregate scale.
    let estateDir: URL?
    /// When non-nil, only questions whose questionID is in this set run.
    /// The full corpus is still loaded (corpus_digest unchanged); the filter
    /// selects which questions run before the seeded shuffle.
    var unitIDs: Set<String>? = nil
    /// File path the unit-ID set was loaded from. Recorded in the report for
    /// subset identity per the testname-arm-serial discipline.
    var unitIDsPath: String? = nil
    /// Max conversations to process concurrently. Default ≈ 80% of cores.
    var parallelConversations: Int =
        max(1, ProcessInfo.processInfo.activeProcessorCount * 4 / 5)
    /// Guard sampling policy. Default .oncePerLeg.
    var guardSamplingPolicy: GuardSamplingPolicy = .oncePerLeg
    /// SHA-256 of the corpus fixture (B2 provenance). Default "unknown".
    var corpusDigest: String = "unknown"
    /// Optional offline reader-input JSONL path. When present, the runner
    /// hydrates the ranked memories but still records the ordinary spec report.
    var dumpAnswerInputsPath: String? = nil
    /// Number of ranked drawers hydrated into each offline reader prompt.
    var answerHydrationDepth: Int = 10
    /// Stored representation exposed to the reader. Distilled is the product
    /// shape; full is an explicit control.
    var answerHydrationTier: HydrationDepth = .distilled
    /// When non-nil, passed as `"scoring"` in the moot_memory_search argument dict.
    /// Accepted values: "raw", "rrf", "matrixAware", "discriminative".
    /// When nil, the key is absent — call is byte-identical to the pre-flag baseline.
    var scoringStrategy: String? = nil
    /// When non-nil, the per-question recall call switches to moot_recall_shaped with
    /// this preset. Mutually exclusive with scoringStrategy (CLI enforces).
    var recallShape: String? = nil
    /// Per-question verb result cap (default 20 = current behaviour).
    /// Always sent explicitly so the value is recorded and auditable.
    var requestLimit: Int = 20
    /// Content-term threshold for the short-query gate (default 4).
    /// A question with content_term_count < shortQueryTerms counts as short.
    var shortQueryTerms: Int = 4

    init(
        mootBinaryPath: String,
        datasetPath: URL,
        limit: Int? = nil,
        offset: Int = 0,
        seed: UInt64 = 20260818,
        outDir: URL? = nil,
        runLabel: String = "locomo-spec",
        targetScale: ArtifactTargetScale = .unit,
        catalogPath: URL? = nil,
        estateDir: URL? = nil
    ) {
        self.mootBinaryPath = mootBinaryPath
        self.datasetPath = datasetPath
        self.limit = limit
        self.offset = offset
        self.seed = seed
        self.outDir = outDir
        self.runLabel = runLabel
        self.targetScale = targetScale
        self.catalogPath = catalogPath
        self.estateDir = estateDir
    }
}

// MARK: - Per-question record

/// The per-question output produced by the spec runner.
/// Carries everything needed for aggregation and the report JSON.
struct LoCoMoSpecQuestionRecord: Sendable {
    /// Synthetic id: "<sampleID>_q<qaIndex>".
    let questionID: String
    /// Integer category (1–5).
    let category: Int
    /// Human-readable category label.
    let categoryLabel: String
    /// Gold answer string. Nil for category 5 (adversarial — no gold answer).
    /// For category 3 (multi_hop), stored verbatim; scorer truncates at ';' per §3.
    let goldAnswer: String?
    /// Prediction produced by moot_synthesize.
    /// Empty string when synthesize failed (scores 0 for that question).
    let prediction: String
    /// Retrieved dia_ids in rank order (mapped from recall query UUIDs via manifest).
    /// Used in evidence recall §4 and reported in the per-question record.
    let retrievedDiaIDs: [String]
    /// Per-§3 score: F1 (cat 1–4) or binary abstention (cat 5). In [0.0, 1.0].
    let score: Double
    /// Per-§4 evidence recall value. 1.0 when evidence is empty or context nil.
    let evidenceRecallValue: Double
    /// Latency of the moot_memory_search (recall) call, seconds.
    let recallLatencySeconds: Double
    /// Latency of the moot_synthesize call, seconds.
    let synthesizeLatencySeconds: Double
    /// True when the DegeneracyGuard classified the estate as healthy.
    let guardHealthy: Bool
    /// Guard diagnostic message when guardHealthy is false.
    let guardDiagnostic: String?
    /// Total turns/sessions ingested into this conversation's estate.
    let turnsIngested: Int
    /// Always nil: artifact estates are pre-built; the estate-cache axis
    /// does not exist in this lane. Retained so the report schema keeps
    /// its column across the changeover.
    let cacheHit: Bool?
    /// Content-term count of the question text (lowercase alnum tokens minus
    /// the shared EN stopword fixture). Used for the short-query gate (§7.1).
    let contentTermCount: Int
    /// 1-based ranks of gold evidence dia_ids within the recalled list.
    /// Empty when the question has no gold evidence (category 5) or none ranked.
    let goldRanks: [Int]
}

/// One fully materialized, estate-free input for an external LoCoMo reader.
struct LoCoMoSpecAnswerInput: Sendable {
    let questionID: String
    let category: Int
    let categoryLabel: String
    let question: String
    let goldAnswer: String?
    let memoryTexts: [String]
    let retrievedDrawerIDs: [String]
    let retrievedRanks: [Int]
    let retrievedDiaIDs: [String]
}

// MARK: - Run result

/// Full output of runLoCoMoSpecQuestions.
struct LoCoMoSpecRunResult: Sendable {
    /// Per-question records in the order they were processed.
    let questionRecords: [LoCoMoSpecQuestionRecord]
    /// §5 aggregate: overall and per-category accuracy + evidence recall.
    let aggregate: LoCoMoSpecAggregate
    /// Run-level metadata for the report JSON.
    let metadata: LoCoMoSpecRunMetadata
    /// Deterministically ordered offline reader inputs; empty unless requested.
    var answerInputs: [LoCoMoSpecAnswerInput] = []
}

/// Metadata captured at run time for the report JSON.
/// Mirrors the metadata fields in the existing LoCoMo report.
struct LoCoMoSpecRunMetadata: Sendable {
    /// "swift" (this port).
    let port: String
    /// SplitMix64 seed used for question shuffling.
    let seed: UInt64
    /// Estate fleet mode. Always "per-conversation" (no Shape 3 in spec lane).
    let estateMode: String
    /// Artifact target scale ("unit" | "bench-aggregate").
    let targetScale: String
    /// Parallel conversations setting.
    let parallelUnits: Int
    /// SHA-256 of the corpus fixture.
    let corpusDigest: String
    /// Total questions processed (across all 5 categories).
    let totalQuestions: Int
    /// Number of distinct conversations whose estate was provisioned.
    let conversationsUsed: Int
    /// Run label (= record arm in RecordWriter convention).
    let runLabel: String
    /// Corpus category counts: {1: 282, 2: 321, 3: 96, 4: 841, 5: 446}.
    /// From LoCoMoSpecCorpus.categoryCounts.
    let categoryCounts: [Int: Int]
    /// Path of the unit-ID filter file, or nil when no filter was applied.
    let unitIDsPath: String?
    /// Number of questions selected after the unit-ID filter (and seed-shuffle +
    /// offset + limit). Matches total_questions in the report.
    let selectedCount: Int
    /// When non-nil, the scoring strategy passed to moot_memory_search ("raw", "rrf",
    /// "matrixAware", "discriminative"). When nil, the default estate scoring was used.
    var scoringStrategy: String? = nil
    /// When non-nil, the preset passed to moot_recall_shaped. Mutually exclusive with
    /// scoringStrategy. When nil, moot_memory_search was used (the baseline path).
    var recallShape: String? = nil
    /// Per-question verb result cap (default 20). Always recorded for auditing.
    var requestLimit: Int = 20
    /// Content-term threshold for the short-query gate (default 4).
    var shortQueryTerms: Int = 4
    /// Pending dreaming jobs in the estate at run start.
    /// 0 for unit-scale runs (no shared estate; dreaming is not active during
    /// per-conversation measurement).
    var dreamPending: Int = 0
    /// Dreaming drain lane state at run start: 0 = idle or absent, 1 = draining.
    /// 0 for unit-scale runs.
    var dreamDraining: Int = 0
}

// MARK: - EndpointConfig builder

/// Builds an EndpointConfig for mootx01 pointing at a pre-built artifact
/// estate. READ-ONLY use: the lane only calls moot_memory_search and
/// moot_synthesize. The estate carries its transient record (plaintext by rule); the
/// ephemeral-lifetime env token keeps serve identity keys in memory (zero
/// Keychain contact). Deliberately NOT routed through assertScratchBackend:
/// that guard pins WRITE lanes to /tmp scratch, and this lane reads a
/// durable artifact in place (same posture as ArtifactRecallRunner).
func loCoMoSpecEndpointConfig(
    estateDir: URL,
    mootBinaryPath: String
) throws -> EndpointConfig {
    let command = try mootServeCommand(binary: mootBinaryPath, scratchDir: estateDir, environment: ["MOOTX01_FROZEN=1", "MOOTX01_SUBJECT_RIDER=0"])
    return EndpointConfig(
        name: "mootx01-locomo-spec",
        transport: .stdio(command: command),
        auth: nil,
        verbMap: loCoMoSpecVerbMap,
        role: .target
    )
}

// MARK: - UUID → dia_id mapping

/// Maps retrieved UUIDs to dia_ids using the conversation's manifest.
///
/// Adapted from loCoMoManifestAsLME + lmeRankedSessions: converts the LoCoMo
/// manifest to the LME form and then derives the ranked dia_id list.
///
/// The spec runner uses dia_ids as the "context" for §4 evidence recall.
/// Each UUID that maps to a manifest entry contributes its dia_id to the
/// ranked list in the order the UUIDs appear in the recall result.
///
/// - Parameters:
///   - uuids: Ordered UUIDs from moot_memory_search.
///   - manifest: The conversation's manifest (UUID → dia_id).
/// - Returns: Ranked dia_ids (first appearance order, no duplicates).
private func loCoMoSpecRankedDiaIDs(
    uuids: [String],
    manifest: [LoCoMoManifestEntry]
) -> [String] {
    // Build UUID → dia_id lookup from manifest.
    var uuidToDiaID: [String: String] = [:]
    for entry in manifest { uuidToDiaID[entry.uuid] = entry.diaID }

    // Walk retrieved UUIDs in rank order; deduplicate by dia_id (first occurrence).
    var seen = Set<String>()
    var ranked: [String] = []
    for uuid in uuids {
        if let diaID = uuidToDiaID[uuid], seen.insert(diaID).inserted {
            ranked.append(diaID)
        }
    }
    return ranked
}

// MARK: - Per-conversation task

/// Executes one conversation's estate lifecycle for the locomo-spec lane.
///
/// Provisioning, ingest, settle, and teardown are cloned from
/// loCoMoConversationTask (LoCoMoRunner.swift). The scoring step differs:
/// instead of rank-based recall@k / MRR, this task calls moot_synthesize per
/// question to produce a prediction string and then scores with LoCoMoSpecScorer.
///
/// - Parameters:
///   - convIndex:      Conversation index in the corpus (for result assembly).
///   - specQuestions:  Spec questions selected for this conversation.
///   - conversation:   The full LoCoMoSpecConversation.
///   - config:         Run configuration (shared, read-only across all tasks).
///   - guardSampler:   Shared leg-level guard sampler (actor).
/// - Returns: (convIndex, per-question records for this conversation).
private func loCoMoSpecConversationTask(
    convIndex: Int,
    specQuestions: [LoCoMoSpecQuestion],
    conversation: LoCoMoSpecConversation,
    config: LoCoMoSpecRunConfig,
    guardSampler: LegGuardSampler
) async throws -> (Int, [LoCoMoSpecQuestionRecord], [LoCoMoSpecAnswerInput]) {
    var convRecords: [LoCoMoSpecQuestionRecord] = []
    var convAnswerInputs: [LoCoMoSpecAnswerInput] = []

    // ── Artifact estate resolution (run book §8: the spec runner opens the
    // pre-built artifacts through the same estate seam as the measure lane;
    // it builds nothing, settles nothing, and never deletes anything) ─────────
    let estateDir: URL
    switch config.targetScale {
    case .unit:
        guard let catalogPath = config.catalogPath else {
            throw MCPError(description: "locomo-spec: unit scale requires --catalog")
        }
        // Unit stem is the conversation sampleID. The catalog resolver checks
        // existence and applies the containment guard.
        estateDir = try artifactUnitEstateDir(catalogPath: catalogPath, id: conversation.sampleID)
    case .benchAggregate, .completeAggregate:
        guard let dir = config.estateDir else {
            throw MCPError(description:
                "locomo-spec: \(config.targetScale.rawValue) requires --estate-dir")
        }
        estateDir = dir
    }
    // id-map.json (written by the seeding pipeline at build) maps seed
    // record ids to drawer UUIDs. Keys are "<sampleID>/S<n>" — the Rule-1
    // session projection. The manifest for §4 evidence mapping is built
    // from the conversation's own keys.
    let idMap = try loadArtifactIDMap(estateDir: estateDir)
    var manifest: [LoCoMoManifestEntry] = []
    let keyPrefix = "\(conversation.sampleID)/S"
    for (seedID, uuid) in idMap where seedID.hasPrefix(keyPrefix) {
        let sessionNum = Int(seedID.dropFirst(keyPrefix.count)) ?? 0
        manifest.append(LoCoMoManifestEntry(
            uuid: uuid,
            diaID: "S\(sessionNum)",
            sessionNumber: sessionNum,
            turnIndex: 0,
            speaker: "session"
        ))
    }
    guard !manifest.isEmpty else {
        throw MCPError(description:
            "locomo-spec \(conversation.sampleID): id-map at \(estateDir.path) "
            + "has no \(keyPrefix)* entries — wrong estate for this conversation?")
    }
    let ingestCount = manifest.count

    let endpoint = try loCoMoSpecEndpointConfig(
        estateDir: estateDir,
        mootBinaryPath: config.mootBinaryPath)
    let client = MCPClient(endpoint: endpoint)
    try await client.connect()
    defer { Task { await client.disconnect() } }

    FileHandle.standardError.write(Data(
        ("[locomo-spec] conv=\(conversation.sampleID) "
         + "(\(specQuestions.count) questions, \(ingestCount) sessions, "
         + "scale=\(config.targetScale.rawValue))\n").utf8))

    // ── DegeneracyGuard probe ─────────────────────────────────────────────────
    // Shared leg sampler: probes on the first conversation; caches verdict for
    // all subsequent conversations (frozen-ranking binary is frozen on every estate).
    let (verdict, _) = await guardSampler.probe {
        await probeMCPClient(client, verbMap: loCoMoSpecVerbMap, name: "mootx01-locomo-spec")
    }
    let guardHealthy: Bool
    if case .healthy = verdict { guardHealthy = true } else { guardHealthy = false }
    let guardDiagnostic: String? = guardHealthy ? nil : verdict.diagnostic

    // ── Evidence mapping ──────────────────────────────────────────────────────
    // Ground-truth evidence is per-turn (dia_ids like "D1:3"), but the
    // artifact projection stores whole sessions (Rule-1), so documents rank
    // as sessions. Map each evidence dia_id to its session's pseudo-id
    // ("S<n>") via the conversation structure.
    // Twin of Rust `scored_evidence_ids`.
    var diaIDToSessionPseudo: [String: String] = [:]
    for session in conversation.sessions {
        for turn in session.turns {
            diaIDToSessionPseudo[turn.diaID] = "S\(session.sessionNumber)"
        }
    }
    func scoredEvidenceIDs(_ evidence: [String]) -> [String] {
        var seen = Set<String>()
        var mapped: [String] = []
        for e in evidence {
            let sid = diaIDToSessionPseudo[e] ?? e
            if seen.insert(sid).inserted { mapped.append(sid) }
        }
        return mapped
    }

    // ── Per-question loop ─────────────────────────────────────────────────────
    for question in specQuestions {
        // ── Step 1: Recall query → retrieved dia_ids for §4 evidence recall ──
        // moot_memory_search with the locomo location filter — same as the
        // existing locomo lane's .search strategy path. Retrieved UUIDs are
        // mapped to dia_ids via the manifest.
        let recallStart = Date()
        // Two verb paths: moot_recall_shaped when --recall-shape is given (matrixAware
        // preset internally), moot_memory_search otherwise. Mutually exclusive with
        // --scoring (CLI enforces before this point).
        let recallVerb: String
        var queryArgs = AriaV2Surface.memorySearchArgs(verbMap: loCoMoSpecVerbMap, query: question.question)
        // Always send the limit explicitly so the value is recorded and auditable.
        queryArgs["limit"] = .number(Double(config.requestLimit))
        if let shape = config.recallShape {
            recallVerb = AriaV2Surface.recallShaped
            queryArgs["preset"] = .string(shape)
        } else {
            recallVerb = loCoMoSpecVerbMap.query
            // When --scoring is given, pass it to the estate; when omitted, the call is
            // byte-identical to the pre-flag baseline (no "scoring" key in the dict).
            if let s = config.scoringStrategy { queryArgs["scoring"] = .string(s) }
        }
        let recallResult = try await client.callTool(
            recallVerb,
            arguments: queryArgs,
            format: loCoMoSpecVerbMap.resultFormat
        )
        let recallLatency = Date().timeIntervalSince(recallStart)
        let retrievedUUIDs = recallResult.orderedIDs
        // Map UUIDs → ranked dia_ids for §4 evidence recall.
        let retrievedDiaIDs = loCoMoSpecRankedDiaIDs(uuids: retrievedUUIDs, manifest: manifest)

        if config.dumpAnswerInputsPath != nil {
            var memoryTexts: [String] = []
            var hydratedIDs: [String] = []
            var hydratedRanks: [Int] = []
            for (index, drawerID) in retrievedUUIDs.prefix(config.answerHydrationDepth).enumerated() {
                do {
                    let hydrated = try await client.callTool(
                        AriaV2Surface.memoryGet,
                        arguments: AriaV2Surface.memoryGetArgs(memoryId: drawerID, depth: config.answerHydrationTier.rawValue),
                        format: loCoMoSpecVerbMap.resultFormat)
                    let text = hydrated.textBlocks.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        memoryTexts.append(text)
                        hydratedIDs.append(drawerID)
                        hydratedRanks.append(index + 1)
                    }
                } catch {
                    FileHandle.standardError.write(Data(
                        "[locomo-spec] moot_memory_get failed for \(drawerID): \(error)\n".utf8))
                }
            }
            convAnswerInputs.append(LoCoMoSpecAnswerInput(
                questionID: question.questionID,
                category: question.category,
                categoryLabel: question.categoryLabel,
                question: question.question,
                goldAnswer: question.answer,
                memoryTexts: memoryTexts,
                retrievedDrawerIDs: hydratedIDs,
                retrievedRanks: hydratedRanks,
                retrievedDiaIDs: retrievedDiaIDs))
        }

        // ── Step 2: Answer production via moot_synthesize ──────────────────
        // moot_synthesize is the "existing moot answer-production path" referenced
        // by the LongMemEval synthesize arm (LongMemEvalRunner.swift, PR-08).
        // It retrieves relevant content from the estate and synthesizes a
        // short-phrase answer — exactly what the LoCoMo spec requires.
        // If the call fails, prediction = "" (scores 0 for this question) and the
        // error is logged to stderr; the run continues.
        //
        // §6 prompt structure is embedded in moot_synthesize's internal
        // implementation. We pass only the question.
        let synthesizeStart = Date()
        var prediction = ""
        do {
            let synthResult = try await client.callTool(
                AriaV2Surface.synthesize,
                arguments: [loCoMoSpecVerbMap.queryArg: .string(question.question)],
                format: loCoMoSpecVerbMap.resultFormat
            )
            prediction = synthResult.textBlocks.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            FileHandle.standardError.write(Data(
                "[locomo-spec] moot_synthesize failed for \(question.questionID): \(error)\n".utf8))
        }
        let synthesizeLatency = Date().timeIntervalSince(synthesizeStart)

        // ── Step 3: Score per §3 ───────────────────────────────────────────
        // scoreQuestion requires a gold answer. Category 5 questions have no gold
        // answer; they are scored purely by abstention (binary check on prediction).
        let goldAnswer: String
        if let ga = question.answer {
            goldAnswer = ga
        } else if question.category == 5 {
            // Category 5 (adversarial): gold answer is absent; scoring is purely
            // by abstention check (§3: 1 iff output contains "no information
            // available" or "not mentioned"). Pass empty string — scoreQuestion
            // for cat-5 ignores the gold answer entirely (only checks prediction).
            goldAnswer = ""
        } else {
            // Non-cat5 question with nil gold answer: log and score 0.
            FileHandle.standardError.write(Data(
                "[locomo-spec] WARNING: non-cat5 question \(question.questionID) has nil gold answer — scoring as 0\n".utf8))
            goldAnswer = ""
        }

        let score: Double
        do {
            score = try scoreQuestion(
                category: question.category,
                prediction: prediction,
                goldAnswer: goldAnswer
            )
        } catch {
            FileHandle.standardError.write(Data(
                "[locomo-spec] scoreQuestion error for \(question.questionID): \(error)\n".utf8))
            // Unexpected category: log and skip with score 0.
            score = 0.0
        }

        // ── Step 4: Evidence recall per §4 (dia form) ─────────────────────
        // The retrieved context for §4 is the ranked dia_id list from the recall
        // query. §4 uses the "dia form" (context entries do NOT start with 'S' at
        // turn granularity) for direct dia_id membership check.
        //
        // At session granularity, context entries start with 'S', so evidenceRecall
        // uses the session form (strips the numeric suffix and checks session numbers).
        // The scoredEvidenceIDs helper already maps evidence dia_ids to session pseudo-ids
        // for session granularity, so retrieved dia_ids and evidence dia_ids are in the
        // same address space.
        let evidenceForScoring = scoredEvidenceIDs(question.evidence)
        // Context is nil when the recall query was not run (never the case here).
        // When evidence is empty, evidenceRecall returns 1.0 per §4.
        let recallValue = evidenceRecall(
            context: retrievedDiaIDs,
            evidence: evidenceForScoring
        )

        // ── Expand-verify scoreboard per-question fields (§7.5) ──────────────
        // Content-term count: lowercase alnum tokens minus the shared EN stopword fixture.
        // This is the harness's own gate, independent of the product's tokeniser.
        let contentTermCount = lmebContentTermCount(text: question.question)

        // Gold ranks: 1-based positions of gold evidence dia_ids within the retrieved list.
        // Uses the scored (session-mapped) form for consistency with §4 evidence recall.
        let goldEvidenceSet = Set(scoredEvidenceIDs(question.evidence))
        let goldRanks: [Int] = retrievedDiaIDs.enumerated().compactMap { i, diaID in
            goldEvidenceSet.contains(diaID) ? i + 1 : nil
        }

        convRecords.append(LoCoMoSpecQuestionRecord(
            questionID: question.questionID,
            category: question.category,
            categoryLabel: question.categoryLabel,
            goldAnswer: question.answer,       // stored verbatim; scorer truncates cat-3
            prediction: prediction,
            retrievedDiaIDs: retrievedDiaIDs,
            score: score,
            evidenceRecallValue: recallValue,
            recallLatencySeconds: recallLatency,
            synthesizeLatencySeconds: synthesizeLatency,
            guardHealthy: guardHealthy,
            guardDiagnostic: guardDiagnostic,
            turnsIngested: ingestCount,
            cacheHit: nil,
            contentTermCount: contentTermCount,
            goldRanks: goldRanks
        ))
    }

    return (convIndex, convRecords, convAnswerInputs)
}

// MARK: - Public runner

/// Runs the locomo-spec harness against all (or a subset of) questions.
///
/// Returns per-question records with predictions, scores, and evidence recall,
/// plus the §5 aggregate and run metadata. The caller is responsible for
/// serialising the result to JSON using RecordWriter conventions:
///   record name stem: 'locomo-spec-<arm>-<serial>'
///   params sidecar:   'locomo-spec-<arm>-<serial>-params'
///
/// Parallel conversation processing (bounded by config.parallelConversations):
///   - Results collected per-conversation and re-assembled in ascending
///     convIndex order for byte-deterministic output (same as LoCoMoRunner).
///   - Error semantics: per-conversation errors propagate through the task group
///     and ABORT the run (Swift is the measurement instrument).
///
/// - Parameters:
///   - questions:     All questions from LoCoMoSpecCorpus.questions (1,986 total).
///   - conversations: LoCoMoSpecCorpus.conversations (10 in the standard dataset).
///   - config:        Run configuration.
/// - Returns: LoCoMoSpecRunResult with records, aggregate, and metadata.
func runLoCoMoSpecQuestions(
    questions: [LoCoMoSpecQuestion],
    conversations: [LoCoMoSpecConversation],
    config: LoCoMoSpecRunConfig
) async throws -> LoCoMoSpecRunResult {

    // ── Unit-ID filter (before shuffle: same ids file → same units regardless of seed) ──
    let filteredQuestions = try filterUnits(
        questions, ids: config.unitIDs, id: { $0.questionID }, lane: "locomo-spec")

    // ── Shuffle + offset + limit (same as LoCoMoRunner) ──────────────────────
    var rng = SplitMix64(seed: config.seed)
    var shuffled = filteredQuestions
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }
    let afterOffset = Array(shuffled.dropFirst(config.offset))
    let selected: [LoCoMoSpecQuestion]
    if let limit = config.limit {
        selected = Array(afterOffset.prefix(limit))
    } else {
        selected = afterOffset
    }

    // Group by conversation index (preserving the shuffled order within each group).
    var questionsByConversation: [Int: [LoCoMoSpecQuestion]] = [:]
    for q in selected {
        questionsByConversation[q.conversationIndex, default: []].append(q)
    }
    let convIndices = questionsByConversation.keys.sorted()

    // Shared guard sampler across all concurrent conversations.
    let guardSampler = LegGuardSampler(policy: config.guardSamplingPolicy)

    // Aggregate scale shares ONE estate across every conversation: run
    // conversations serially so exactly one serve holds the estate at a
    // time (the WAL has one writer; dreaming rides the open serve).
    let effectiveParallel = config.targetScale == .unit
        ? config.parallelConversations : 1

    // ── Dream drain status probe ──────────────────────────────────────────────
    // Captured once per run via a temporary probe client. At bench-aggregate
    // scale the run holds one shared estate for all conversations; the probe
    // opens that estate before the conversation loop starts. At unit scale each
    // conversation has its own estate, so there is no shared estate to probe and
    // the field defaults to zero.
    let dreamStatus: DreamStatus
    if config.targetScale != .unit, let dir = config.estateDir {
        let probeEndpoint = try loCoMoSpecEndpointConfig(
            estateDir: dir, mootBinaryPath: config.mootBinaryPath)
        let probeClient = MCPClient(endpoint: probeEndpoint, responseDeadline: 30)
        do {
            try await probeClient.connect()
            dreamStatus = await readDrainStatusOnce(client: probeClient)
            Task { await probeClient.disconnect() }
        } catch {
            FileHandle.standardError.write(Data(
                "[locomo-spec] dream-status probe failed: \(error)\n".utf8))
            dreamStatus = DreamStatus(pending: 0, settled: true)
        }
    } else {
        dreamStatus = DreamStatus(pending: 0, settled: true)
    }

    // ── Bounded parallel conversation processing ──────────────────────────────
    var resultsByConvIndex: [Int: [LoCoMoSpecQuestionRecord]] = [:]
    resultsByConvIndex.reserveCapacity(convIndices.count)
    var inputsByConvIndex: [Int: [LoCoMoSpecAnswerInput]] = [:]
    inputsByConvIndex.reserveCapacity(convIndices.count)

    try await withThrowingTaskGroup(
        of: (Int, [LoCoMoSpecQuestionRecord], [LoCoMoSpecAnswerInput]).self
    ) { group in
        var remaining = convIndices[...]
        let initialBatch = min(effectiveParallel, remaining.count)
        for _ in 0..<initialBatch {
            let ci = remaining.removeFirst()
            let convQuestions = questionsByConversation[ci]!
            let conversation = conversations[ci]
            group.addTask {
                try await loCoMoSpecConversationTask(
                    convIndex: ci,
                    specQuestions: convQuestions,
                    conversation: conversation,
                    config: config,
                    guardSampler: guardSampler)
            }
        }
        for try await (ci, records, inputs) in group {
            resultsByConvIndex[ci] = records
            inputsByConvIndex[ci] = inputs
            if !remaining.isEmpty {
                let ci2 = remaining.removeFirst()
                let convQuestions2 = questionsByConversation[ci2]!
                let conversation2 = conversations[ci2]
                group.addTask {
                    try await loCoMoSpecConversationTask(
                        convIndex: ci2,
                        specQuestions: convQuestions2,
                        conversation: conversation2,
                        config: config,
                        guardSampler: guardSampler)
                }
            }
        }
    }

    // Re-assemble in ascending convIndex order (byte-deterministic output).
    let allRecords = convIndices.flatMap { resultsByConvIndex[$0] ?? [] }
    let allAnswerInputs = convIndices.flatMap { inputsByConvIndex[$0] ?? [] }

    // ── §5 Aggregation ────────────────────────────────────────────────────────
    // Feed (category, score, evidenceRecall) tuples to the scorer.
    let scoreTuples = allRecords.map { r in
        (category: r.category, score: r.score, evidenceRecall: r.evidenceRecallValue)
    }
    let aggregate = loCoMoSpecAggregate(scores: scoreTuples)

    // ── Run metadata ──────────────────────────────────────────────────────────
    // Collect category counts from the full question list (not just the selected
    // subset) so the report faithfully reflects the dataset composition.
    var categoryCounts: [Int: Int] = [:]
    for q in questions { categoryCounts[q.category, default: 0] += 1 }

    var metadata = LoCoMoSpecRunMetadata(
        port: "swift",
        seed: config.seed,
        estateMode: config.targetScale == .unit
            ? "artifact-unit" : "artifact-aggregate",
        targetScale: config.targetScale.rawValue,
        parallelUnits: config.parallelConversations,
        corpusDigest: config.corpusDigest,
        totalQuestions: allRecords.count,
        conversationsUsed: convIndices.count,
        runLabel: config.runLabel,
        categoryCounts: categoryCounts,
        unitIDsPath: config.unitIDsPath,
        selectedCount: allRecords.count,
        scoringStrategy: config.scoringStrategy
    )
    metadata.recallShape    = config.recallShape
    metadata.requestLimit   = config.requestLimit
    metadata.shortQueryTerms = config.shortQueryTerms
    metadata.dreamPending  = dreamStatus.pending
    metadata.dreamDraining = dreamStatus.settled ? 0 : 1

    return LoCoMoSpecRunResult(
        questionRecords: allRecords,
        aggregate: aggregate,
        metadata: metadata,
        answerInputs: allAnswerInputs
    )
}

/// Serializes the reader-input seam in stable question order.
func loCoMoSpecAnswerInputsJSONL(
    _ result: LoCoMoSpecRunResult,
    hydrationDepth: Int,
    hydrationTier: HydrationDepth
) throws -> Data {
    var objects: [[String: Any]] = [[
        "type": "header",
        "benchmark": "locomo-spec",
        "seed": result.metadata.seed,
        "run_label": result.metadata.runLabel,
        "answer_hydration_depth": hydrationDepth,
        "hydration_tier": hydrationTier.rawValue,
        "corpus_digest": result.metadata.corpusDigest,
    ]]
    objects.append(contentsOf: result.answerInputs.map { input in
        [
            "type": "answer_input",
            "benchmark": "locomo-spec",
            "question_id": input.questionID,
            "category": input.category,
            "category_label": input.categoryLabel,
            "question": input.question,
            "gold_answer": input.goldAnswer ?? NSNull(),
            "memory_texts": input.memoryTexts,
            "retrieved_drawer_ids": input.retrievedDrawerIDs,
            "retrieved_dia_ids": input.retrievedDiaIDs,
            "retrieved_ranks": input.retrievedRanks,
        ]
    })
    let lines = try objects.map { object -> String in
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    return Data((lines.joined(separator: "\n") + "\n").utf8)
}

// MARK: - JSON report builder

/// Produces the report JSON for a LoCoMoSpecRunResult following RecordWriter conventions.
///
/// Record name stem: 'locomo-spec-<arm>-<serial>'  (BENCHMARKER_OPTIMIZER_CONTRACT.md).
/// Params sidecar:   'locomo-spec-<arm>-<serial>-params'.
///
/// Report JSON structure:
///   - overall_accuracy          (§5 round3)
///   - total_questions
///   - category_order: [4,1,2,3,5]
///   - by_category: array in [4,1,2,3,5] order, each with:
///       category, category_label, accuracy, mean_evidence_recall, question_count
///   - run_parameters: port, seed, estate_mode, shape, encode_barrier,
///       granularity, corpus_digest, conversations_used
///   - per_question_records: array (in processing order), each with:
///       question_id, category, category_label, gold_answer, prediction,
///       retrieved_dia_ids, score, evidence_recall, recall_latency_s,
///       synthesize_latency_s, guard_healthy, guard_diagnostic, turns_ingested, cache_hit
///
/// - Parameters:
///   - result: The run result to serialise.
///   - arm:    The record arm (run label), e.g. "all1986-drain".
///   - serial: The run serial from resolveRunSerial(_:).
/// - Returns: JSON-encoded Data.
/// - Throws: Encoding error when JSONSerialization fails.
func loCoMoSpecReportJSON(
    _ result: LoCoMoSpecRunResult,
    arm: String,
    serial: String
) throws -> Data {
    let meta = result.metadata
    let agg  = result.aggregate

    // §5 category order: [4, 1, 2, 3, 5].
    let categoryLabels: [Int: String] = [
        1: "single_hop", 2: "temporal", 3: "multi_hop", 4: "open_domain", 5: "adversarial",
    ]

    let byCategory: [[String: Any]] = agg.byCategory.map { cm in
        [
            "category":            cm.category,
            "category_label":      categoryLabels[cm.category] ?? "unknown",
            "accuracy":            cm.accuracy,
            "mean_evidence_recall": cm.meanRecall,
            "question_count":      cm.questionCount,
        ]
    }

    let perQuestion: [[String: Any?]] = result.questionRecords.map { r in
        [
            "question_id":        r.questionID,
            "category":           r.category,
            "category_label":     r.categoryLabel,
            "gold_answer":        r.goldAnswer as Any?,
            "prediction":         r.prediction,
            "retrieved_dia_ids":  r.retrievedDiaIDs,
            "score":              r.score,
            "evidence_recall":    r.evidenceRecallValue,
            "guard_healthy":      r.guardHealthy,
            "guard_diagnostic":   r.guardDiagnostic as Any?,
            "turns_ingested":     r.turnsIngested,
            "cache_hit":          r.cacheHit as Any?,
            // Expand-verify scoreboard fields (§7.5).
            "content_term_count": r.contentTermCount,
            "gold_ranks":         r.goldRanks,
        ]
    }
    // Convert Any? → Any (replacing nil with NSNull) for JSONSerialization.
    let perQuestionCoerced = perQuestion.map { row -> [String: Any] in
        row.mapValues { v in (v as Optional<Any>).map { $0 } ?? NSNull() as Any }
    }

    // Short-query subset metrics (§7.5): questions with content_term_count < shortQueryTerms.
    let includedRecords = result.questionRecords.filter { $0.guardHealthy }
    let shortRecords = includedRecords.filter { $0.contentTermCount < meta.shortQueryTerms }
    let shortQueryCount = shortRecords.count
    let shortQueryMeanScore = shortQueryCount > 0
        ? shortRecords.map { $0.score }.reduce(0, +) / Double(shortQueryCount) : 0.0
    let shortQueryMeanEvidenceRecall = shortQueryCount > 0
        ? shortRecords.map { $0.evidenceRecallValue }.reduce(0, +) / Double(shortQueryCount) : 0.0
    let shortQueryPoolGuarantee = shortQueryCount > 0
        ? Double(shortRecords.filter { !$0.goldRanks.isEmpty }.count) / Double(shortQueryCount) : 0.0

    let report: [String: Any] = [
        "record_name_stem":       recordFilename(test: "locomo-spec", arm: arm, serial: serial),
        "lane":                   "locomo-spec",
        "overall_accuracy":       agg.overall,
        "overall_mean_evidence_recall": agg.overallMeanRecall,
        "total_questions":        meta.totalQuestions,
        "category_order":         [4, 1, 2, 3, 5],
        "by_category":            byCategory,
        "corpus_category_counts": meta.categoryCounts.sorted(by: { $0.key < $1.key })
            .reduce(into: [String: Int]()) { $0["\($1.key)"] = $1.value },
        // Short-query subset metrics for the scoreboard (§7.5).
        "short_query_count":                shortQueryCount,
        "short_query_mean_score":           shortQueryMeanScore,
        "short_query_mean_evidence_recall": shortQueryMeanEvidenceRecall,
        "short_query_pool_guarantee":       shortQueryPoolGuarantee,
        "run_parameters": [
            "port":             meta.port,
            "seed":             meta.seed,
            "estate_mode":      meta.estateMode,
            "target_scale":     meta.targetScale,
            "corpus_digest":    meta.corpusDigest,
            "conversations_used": meta.conversationsUsed,
            "run_label":        meta.runLabel,
            "arm":              arm,
            "serial":           serial,
            "unit_ids_path":    meta.unitIDsPath as Any,
            "selected_count":   meta.selectedCount,
            "scoring":          meta.scoringStrategy ?? "default",
            // Recall shape: "none" when moot_memory_search was used (the baseline).
            "recall_shape":     meta.recallShape ?? "none",
            // Per-question verb limit — always recorded for arm-comparison auditing.
            "request_limit":    meta.requestLimit,
            // Threshold used to classify short queries; mirrors the Rust run_parameters key.
            "short_query_terms": meta.shortQueryTerms,
            // Dream drain lane state at run start; 0 for unit-scale runs.
            "dream_pending":     meta.dreamPending,
            "dream_draining":    meta.dreamDraining,
        ] as [String: Any],
        "per_question_records": perQuestionCoerced,
    ]

    return try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
}
