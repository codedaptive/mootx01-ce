import Foundation

// PayloadEconomicsRunner.swift — the payload-economics and synthesis-payload
// internal lanes (run book §9; benchmarks/payload-economics.md,
// benchmarks/synthesis-payload.md).
//
// A MOOTx01-authored instrument over the frozen lme-s corpus and the selected
// port's Form-2 lme-s artifact. Scoring is mechanical and deterministic —
// no judge anywhere in the loop (operator ruling, 2026-08-28):
//
//   tokens read              (utf8_byte_count + 3) / 4   [lmeEstimateTokens]
//   evidence hit rate        has_answer turn text, normalized substring
//                            [lmeEvidenceHit] — the cleaned fixture variants
//                            (longmemeval_s_cleaned.json) carry has_answer;
//                            a corpus without the field yields nil
//   answer presence rate     gold answer text, normalized substring
//                            [lmeGoldAnswerInPayload] — always available
//   per-1000-token figures   rate ÷ mean tokens × 1000 — the comparison
//                            figures the definitions name
//
// Result surfaces per question, all over ONE read-only serve on the
// artifact estate (the artifact-recall open pattern — the lane never
// provisions, settles, or tears down). The definition's payload shapes
// map onto the ARIA surface as follows (the report's `shape_mapping`
// field records this mapping in every artifact):
//
//   Preview       exact arm       moot_memory_search — the ruled candidate
//                                 rows: a short extract per returned row
//   Full content  full_content    moot_memory_get {ids, depth: full} over
//                                 the exact arm's returned ids — the
//                                 complete body of each returned row,
//                                 rendered from the SAME frozen retrieval
//   Compressed    dense arm       moot_recall_distilled — the store-reduced
//                                 form of the returned content
//   Synthesis     synthesize      moot_synthesize — store-generated digest
//                                 (--synthesize-arm; the synthesis-payload
//                                 lane is this runner with the arm on)
//
// naked|<id>[,<id>...] prepares one arm per run: the artifact is cloned
// the artifact-cache restore path uses), the clone is served frozen, and
// the clone is removed after the serve exits, also on error. The artifact
// is never written. Without the flag the artifact is served in place with
// and `artifact_digest` beside `shape_mapping`.
//
// Retrieval hit@k / MRR are computed for the exact and dense arms through
// the artifact id-map fold (id-map.json keys are raw lme-s session ids),
// so the report also shows the retrieval effectiveness the payload rides on.
// The synth arm returns prose, not ranked ids — it carries token and
// evidence figures only.
//
// --payload-arm v0..v5 (PayloadArm) post-processes payload text harness-side
// before token/evidence measurement, exactly as in the longmemeval lane.
// Dense-row grammar lines are stripped per arm; non-row payloads pass
// through unchanged, so the arm is safe to apply uniformly to all three
// payload kinds.

// MARK: - Config

/// The payload-lane invocation, parsed by `runPayloadEconomics`.
struct PayloadLaneConfig: Sendable {
    /// The selected port's Form-2 lme-s artifact estate (fixed dependency;
    /// the lane takes no SCALE — run book §9).
    let estateDir: URL
    /// The seeding pipeline's 3rd-person unscoped questions.jsonl
    /// (lme-s adapter shape; sample_id == official question_id).
    let questionsPath: URL
    /// Official LongMemEval data dir — source of gold answers and, where
    /// present, has_answer evidence annotations.
    let dataDir: URL
    /// Corpus variant ("s" for the frozen lme-s corpus).
    let variant: String
    /// True = the synthesis-payload lane: adds the moot_synthesize digest arm.
    let synthesizeArm: Bool
    /// Optional `limit` forwarded to moot_synthesize (recorded in the report).
    let synthesizeLimit: Int?
    /// Optional harness-side payload shape variant (v0..v5).
    let payloadArm: PayloadArm?
    /// Question cap (0 = all).
    let limit: Int
    /// Retrieval result limit AND the k of hit@k.
    let topK: Int
    /// Report output path.
    let outPath: URL
    /// mootx01 binary path.
    let mootBinaryPath: String
}

// MARK: - Pure aggregation

/// Per-question, per-arm measurement retained for aggregation and the
/// inspectability tail.
struct PayloadArmSample: Sendable, Equatable {
    /// Estimated payload tokens.
    let tokens: Int
    /// has_answer evidence present in the payload. nil = the question carries
    /// no annotation (unknown, never a miss).
    let evidenceHit: Bool?
    /// Gold answer text present in the payload.
    let answerPresent: Bool
    /// Retrieval hit@k through the id-map fold. nil for the synth arm
    /// (prose, no ranked ids).
    let hitAtK: Bool?
    /// Retrieval reciprocal rank. nil for the synth arm.
    let reciprocalRank: Double?
}

/// One arm's aggregated cell, as published in the report.
struct PayloadArmCell: Sendable, Equatable {
    let n: Int
    let meanTokens: Double
    /// nil when no question carried a has_answer annotation.
    let evidenceHitRate: Double?
    /// Evidence hits per 1000 tokens. nil when evidenceHitRate is nil or
    /// meanTokens is 0.
    let evidenceHitsPer1kTokens: Double?
    let answerPresenceRate: Double
    /// Answer presence per 1000 tokens. nil when meanTokens is 0.
    let answerPresencePer1kTokens: Double?
    /// nil for the synth arm.
    let hitAtK: Double?
    let mrr: Double?
}

/// Aggregates one arm's samples into its report cell. Pure — the literal
/// vector is pinned identically in the Rust twin
/// (payload_arm_cell_parity in payload_economics.rs).
func aggregatePayloadArm(_ samples: [PayloadArmSample]) -> PayloadArmCell {
    let n = samples.count
    guard n > 0 else {
        return PayloadArmCell(
            n: 0, meanTokens: 0, evidenceHitRate: nil,
            evidenceHitsPer1kTokens: nil, answerPresenceRate: 0,
            answerPresencePer1kTokens: nil, hitAtK: nil, mrr: nil)
    }
    let meanTokens = Double(samples.map(\.tokens).reduce(0, +)) / Double(n)
    let annotated = samples.compactMap(\.evidenceHit)
    let evidenceRate: Double? = annotated.isEmpty ? nil
        : Double(annotated.filter { $0 }.count) / Double(annotated.count)
    let answerRate = Double(samples.filter(\.answerPresent).count) / Double(n)
    let scored = samples.compactMap(\.hitAtK)
    let hitAtK: Double? = scored.isEmpty ? nil
        : Double(scored.filter { $0 }.count) / Double(scored.count)
    let rrs = samples.compactMap(\.reciprocalRank)
    let mrr: Double? = rrs.isEmpty ? nil : rrs.reduce(0, +) / Double(rrs.count)
    func per1k(_ rate: Double?) -> Double? {
        guard let rate, meanTokens > 0 else { return nil }
        return rate / meanTokens * 1000
    }
    return PayloadArmCell(
        n: n, meanTokens: meanTokens, evidenceHitRate: evidenceRate,
        evidenceHitsPer1kTokens: per1k(evidenceRate),
        answerPresenceRate: answerRate,
        answerPresencePer1kTokens: per1k(answerRate),
        hitAtK: hitAtK, mrr: mrr)
}

/// Joins the artifact questions to the official corpus by question id,
/// carrying gold answer + optional evidence text. Pure. Questions missing
/// from the official corpus are a hard error: a silent drop would score a
/// truncated set as if it were complete.
struct PayloadLaneQuestion: Sendable {
    let questionID: String
    /// The 3rd-person unscoped question text asked against the estate.
    let question: String
    /// Gold answer text (always present in the official corpus).
    let goldAnswer: String
    /// Joined has_answer turn text; nil when unannotated.
    let evidenceText: String?
    /// Ground-truth session ids for the retrieval fold.
    let answerSessionIDs: [String]
}

func joinPayloadLaneQuestions(
    artifact: [ArtifactRecallQuestion],
    official: [LMEQuestion]
) throws -> [PayloadLaneQuestion] {
    var byID: [String: LMEQuestion] = [:]
    for q in official { byID[q.questionID] = q }
    return try artifact.map { aq in
        guard let oq = byID[aq.sampleID] else {
            throw MCPError(description:
                "question '\(aq.sampleID)' is in the artifact questions but "
                + "not in the official corpus — the frozen corpus and the "
                + "seeding projection are out of step")
        }
        return PayloadLaneQuestion(
            questionID: aq.sampleID,
            question: aq.question,
            goldAnswer: oq.answer,
            evidenceText: lmeEvidenceTextForQuestion(oq),
            answerSessionIDs: aq.answerSessionIDs)
    }
}

// MARK: - Arm provenance

/// The arm every payload report records beside `shape_mapping`. Twin of
/// Rust `PayloadArmProvenance`; the compact form is pinned byte-for-byte in
/// both ports by conformance/payload_arm_provenance_vectors.json.
struct PayloadArmProvenance: Equatable, Sendable {
    /// SHA-256 of the artifact's estate.sqlite (the bytes cloned, or served).
    let artifactDigest: String

    /// JSONSerialization-compatible fields, merged into the report top level.
    var reportFields: [String: Any] {
        [
            "artifact_digest": artifactDigest,
        ]
    }

    /// Compact, sorted-key bytes — the cross-port byte-compare form. Only
    /// strings, a bool, null and a string array appear here, so the two
    /// ports' compact encoders agree byte for byte (their pretty printers
    /// differ in colon spacing, which is why the compare runs on this form).
    func compactJSON() throws -> Data {
        try JSONSerialization.data(withJSONObject: reportFields, options: [.sortedKeys])
    }
}

// MARK: - Arm scratch

// MARK: - Live runner

/// The four sample arrays one serve produces (synth empty unless the
/// synthesis-payload lane is on).
struct PayloadLaneSamples: Sendable {
    let exact: [PayloadArmSample]
    let fullContent: [PayloadArmSample]
    let dense: [PayloadArmSample]
    let synth: [PayloadArmSample]
}

/// Runs the payload lane over the artifact estate and writes the report.
func runPayloadEconomicsLane(config: PayloadLaneConfig) async throws {
    // Load + join question sources before any process is spawned.
    let jsonl = try String(contentsOf: config.questionsPath, encoding: .utf8)
    let artifactQs = try loadArtifactRecallQuestions(jsonl: jsonl, dataset: .lmeS)
    // Questions without retrieval ground truth (empty answer_session_ids)
    // cannot be run at all; they are excluded from the evaluated slice.
    // This is DISTINCT from the report's `no_evidence`, which per the
    // definition counts EVALUATED questions without a has_answer-annotated
    // evidence turn (they still run; they are never an evidence miss).
    let (scoredPool, noGroundTruth) = partitionArtifactQuestions(artifactQs)
    let corpusFile: String
    switch config.variant {
    case "s": corpusFile = "longmemeval_s_cleaned.json"
    case "m": corpusFile = "longmemeval_m_cleaned.json"
    default:
        throw MCPError(description:
            "payload lanes run over the frozen lme-s corpus; got variant "
            + "'\(config.variant)'")
    }
    let corpus = try loadLMECorpus(
        from: config.dataDir.appendingPathComponent(corpusFile))
    let joined = try joinPayloadLaneQuestions(
        artifact: applyArtifactLimit(scoredPool, limit: config.limit),
        official: corpus.questions)
    guard !joined.isEmpty else {
        throw MCPError(description:
            "no scorable questions (loaded \(artifactQs.count), "
            + "no ground truth \(noGroundTruth))")
    }
    // The definition's `no_evidence`: evaluated questions with no annotated
    // evidence turn. Counted over the evaluated slice, never converted into
    // an evidence miss (the evidence-rate denominator excludes them).
    let noEvidence = joined.filter { $0.evidenceText == nil }.count

    guard let artifactDB = estateDatabasePath(in: config.estateDir) else {
        throw MCPError(description:
            "no estate.sqlite in \(config.estateDir.path) — the payload lanes "
            + "require the selected port's ready Form-2 lme-s artifact "
            + "(run book §9 preparation)")
    }
    let idMap = try loadArtifactIDMap(estateDir: config.estateDir)
    let reverse = artifactReverseIDMap(idMap)
    // Digest of the artifact's own database, taken before any clone: the
    // report names the exact bytes the arm was prepared from.
    guard let artifactDigest = fileSha256Hex(path: artifactDB) else {
        throw MCPError(description: "cannot read \(artifactDB) for its digest")
    }

    let lane = config.synthesizeArm ? "synthesis-payload" : "payload-economics"
    FileHandle.standardError.write(Data(
        ("[\(lane)] questions=\(joined.count) top-k=\(config.topK) "
         + "payload-arm=\(config.payloadArm?.rawValue ?? "none") "
         + "estate=\(config.estateDir.lastPathComponent)\n").utf8))

    let serveDir = config.estateDir
    let provenance = PayloadArmProvenance(artifactDigest: artifactDigest)
    let samples: PayloadLaneSamples = try await {

        // READ-ONLY serve — identical posture rationale to the artifact-recall
        // lane (durable plaintext artifact read in place, ephemeral identity,
        // zero Keychain contact). The clone, when used, is served with the
        // same frozen env line.
        let command = try mootServeCommand(binary: config.mootBinaryPath, scratchDir: serveDir, environment: ["MOOTX01_FROZEN=1", "MOOTX01_SUBJECT_RIDER=0"])
        let endpoint = EndpointConfig(
            name: "mootx01-payload-lane",
            transport: .stdio(command: command),
            auth: nil,
            verbMap: EndpointConfig.VerbMap(
                write: AriaV2Surface.fileMemory,
                query: AriaV2Surface.memorySearch,
                list: nil,
                constantArgs: [:],
                resultFormat: .mootV2),
            role: .target)
        let client = MCPClient(endpoint: endpoint)
        try await client.connect()
        let outcome: Result<PayloadLaneSamples, any Error>
        do {
            outcome = .success(try await measurePayloadArms(
                client: client, config: config, questions: joined, reverse: reverse))
        } catch {
            outcome = .failure(error)
        }
        // The serve exits before the clone is removed: disconnect closes the
        // child's stdin and cancels the session, which tears the child down.
        await client.disconnect()
        return try outcome.get()
    }()

    let report = payloadLaneReport(
        config: config, lane: lane,
        nQuestions: joined.count, noEvidence: noEvidence,
        exact: aggregatePayloadArm(samples.exact),
        fullContent: aggregatePayloadArm(samples.fullContent),
        dense: aggregatePayloadArm(samples.dense),
        synth: config.synthesizeArm ? aggregatePayloadArm(samples.synth) : nil,
        provenance: provenance)
    let data = try JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: config.outPath)
    FileHandle.standardError.write(Data(
        ("[\(lane)] exact mean_tokens="
         + String(format: "%.1f", aggregatePayloadArm(samples.exact).meanTokens)
         + " dense mean_tokens="
         + String(format: "%.1f", aggregatePayloadArm(samples.dense).meanTokens)
         + " → \(config.outPath.path)\n").utf8))
}

/// Runs every question's arms over one connected serve and returns the
/// samples. Separated from `runPayloadEconomicsLane` so the serve's
/// disconnect and the clone's removal are sequenced explicitly around it.
private func measurePayloadArms(
    client: MCPClient,
    config: PayloadLaneConfig,
    questions joined: [PayloadLaneQuestion],
    reverse: [String: String]
) async throws -> PayloadLaneSamples {
    /// Measures one payload string: arm-stripped, tokenized, evidence-matched.
    func measure(
        payloadBlocks: [String], q: PayloadLaneQuestion,
        hitAtK: Bool?, reciprocalRank: Double?
    ) -> PayloadArmSample {
        let blocks = config.payloadArm?.apply(toTextBlocks: payloadBlocks)
            ?? payloadBlocks
        let text = blocks.joined(separator: "\n")
        let evidence: Bool? = q.evidenceText.map {
            lmeEvidenceHit(evidenceText: $0, payloadText: text)
        }
        return PayloadArmSample(
            tokens: lmeEstimateTokens(text),
            evidenceHit: evidence,
            answerPresent: lmeGoldAnswerInPayload(
                goldAnswer: q.goldAnswer, payloadText: text),
            hitAtK: hitAtK, reciprocalRank: reciprocalRank)
    }

    var exactSamples: [PayloadArmSample] = []
    var fullContentSamples: [PayloadArmSample] = []
    var denseSamples: [PayloadArmSample] = []
    var synthSamples: [PayloadArmSample] = []

    for q in joined {
        // The lme-s artifact is the deduplicated estate: no instance wings,
        // every question searches unscoped (run book §1.2).
        let args: [String: JSONValue] = [
            "query": .string(q.question),
            "limit": .number(Double(config.topK)),
        ]
        var exactIDs: [String] = []
        for (tool, sink) in [(AriaV2Surface.memorySearch, 0), (AriaV2Surface.recallDistilled, 1)] {
            let result = try await client.callTool(
                tool, arguments: args, format: .mootV2,
                deadline: MCPDeadline.interactive)
            if result.isError {
                throw MCPError(description:
                    "\(tool) returned a tool-level error for "
                    + "'\(q.question.prefix(80))': "
                    + result.textBlocks.joined(separator: " ").prefix(200))
            }
            let ranked = artifactMapRankedUUIDs(result.orderedIDs, reverse: reverse)
            let score = scoreArtifactQuestion(
                rankedSeedIDs: ranked, expected: q.answerSessionIDs, k: config.topK)
            let sample = measure(
                payloadBlocks: result.textBlocks, q: q,
                hitAtK: score.hitAtK, reciprocalRank: score.reciprocalRank)
            if sink == 0 { exactSamples.append(sample); exactIDs = result.orderedIDs }
            else { denseSamples.append(sample) }
        }
        // Full-content shape: the complete body of each row the exact arm
        // returned, batch-hydrated from the SAME frozen retrieval (the
        // definition's "rendered from the same frozen retrieval results").
        // No retrieval figures — the ranked list is the exact arm's.
        if exactIDs.isEmpty {
            fullContentSamples.append(measure(
                payloadBlocks: [], q: q, hitAtK: nil, reciprocalRank: nil))
        } else {
            let hydrate = try await client.callTool(
                AriaV2Surface.memoryGet,
                arguments: batchHydrateArgs(ids: exactIDs, depth: .full),
                format: .mootV2, deadline: MCPDeadline.interactive)
            if hydrate.isError {
                throw MCPError(description:
                    "moot_memory_get returned a tool-level error for "
                    + "'\(q.question.prefix(80))': "
                    + hydrate.textBlocks.joined(separator: " ").prefix(200))
            }
            fullContentSamples.append(measure(
                payloadBlocks: hydrate.textBlocks, q: q,
                hitAtK: nil, reciprocalRank: nil))
        }
        if config.synthesizeArm {
            var synthArgs: [String: JSONValue] = ["query": .string(q.question)]
            if let cap = config.synthesizeLimit {
                synthArgs["limit"] = .number(Double(cap))
            }
            let result = try await client.callTool(
                AriaV2Surface.synthesize, arguments: synthArgs, format: .mootV2,
                deadline: MCPDeadline.bulk)
            if result.isError {
                throw MCPError(description:
                    "moot_synthesize returned a tool-level error for "
                    + "'\(q.question.prefix(80))': "
                    + result.textBlocks.joined(separator: " ").prefix(200))
            }
            synthSamples.append(measure(
                payloadBlocks: result.textBlocks, q: q,
                hitAtK: nil, reciprocalRank: nil))
        }
    }
    return PayloadLaneSamples(
        exact: exactSamples, fullContent: fullContentSamples,
        dense: denseSamples, synth: synthSamples)
}

/// Report JSON (JSONSerialization-compatible). The `shape_mapping` field
/// records how the definition's payload shapes map onto the arm cells:
/// preview → exact (candidate rows), full_content → full_content (batch
/// hydration of the exact arm's ids), compressed → dense (distilled),
/// synthesis → synthesize (digest). Retrieval figures appear ONLY on the
/// exact and dense cells; full_content rides the exact arm's ranked list.
func payloadLaneReport(
    config: PayloadLaneConfig,
    lane: String,
    nQuestions: Int,
    noEvidence: Int,
    exact: PayloadArmCell,
    fullContent: PayloadArmCell,
    dense: PayloadArmCell,
    synth: PayloadArmCell?,
    provenance: PayloadArmProvenance
) -> [String: Any] {
    func cell(_ c: PayloadArmCell, retrieval: Bool) -> [String: Any] {
        var d: [String: Any] = [
            "n": c.n,
            "mean_tokens": c.meanTokens,
            "answer_presence_rate": c.answerPresenceRate,
        ]
        if let v = c.answerPresencePer1kTokens { d["answer_presence_per_1k_tokens"] = v }
        if let v = c.evidenceHitRate { d["evidence_hit_rate"] = v }
        if let v = c.evidenceHitsPer1kTokens { d["evidence_hits_per_1k_tokens"] = v }
        if retrieval {
            if let v = c.hitAtK { d["hit_at_k"] = v }
            if let v = c.mrr { d["mrr"] = v }
        }
        return d
    }
    var arms: [String: Any] = [
        "exact": cell(exact, retrieval: true),
        "full_content": cell(fullContent, retrieval: false),
        "dense": cell(dense, retrieval: true),
    ]
    if let synth { arms["synthesize"] = cell(synth, retrieval: false) }
    var shapeMapping: [String: Any] = [
        "preview": "exact",
        "full_content": "full_content",
        "compressed": "dense",
    ]
    if synth != nil { shapeMapping["synthesis"] = "synthesize" }
    var report: [String: Any] = [
        "lane": lane,
        "n_questions": nQuestions,
        "shape_mapping": shapeMapping,
        "config": [
            "estate_dir": config.estateDir.path,
            "questions": config.questionsPath.path,
            "data_dir": config.dataDir.path,
            "variant": config.variant,
            "limit": config.limit,
            "top_k": config.topK,
            "payload_arm": config.payloadArm?.rawValue ?? "",
            "binary": config.mootBinaryPath,
        ],
        "estate_mode": "artifact-bench-aggregate",
        "no_evidence": noEvidence,
        "arms": arms,
    ]
    for (key, value) in provenance.reportFields { report[key] = value }
    if dense.meanTokens > 0, exact.meanTokens > 0 {
        report["dense_exact_token_ratio"] = dense.meanTokens / exact.meanTokens
    }
    if config.synthesizeArm, let cap = config.synthesizeLimit {
        report["synthesize_limit"] = cap
    }
    return report
}

// MARK: - CLI entry

/// The `payload-economics` subcommand: parses flags and runs the lane.
/// `--synthesize-arm` selects the synthesis-payload lane (same runner,
/// digest arm added, lane name switched — run book §9 twin keys).
func runPayloadEconomics(_ args: [String]) async throws {
    guard let estateDirStr = optionValue("--estate-dir", in: args) else {
        throw MCPError(description:
            "payload-economics requires --estate-dir <the selected port's "
            + "Form-2 lme-s artifact> (run book §9; the lane takes no scale)")
    }
    guard let questionsStr = optionValue("--questions", in: args) else {
        throw MCPError(description:
            "payload-economics requires --questions <seeding questions.jsonl>")
    }
    guard let dataDirStr = optionValue("--data-dir", in: args) else {
        throw MCPError(description:
            "payload-economics requires --data-dir <official LongMemEval data dir>")
    }
    let variant = optionValue("--variant", in: args) ?? "s"
    let synthesizeArm = args.contains("--synthesize-arm")
    let synthesizeLimit: Int? = optionValue("--synthesize-limit", in: args) != nil
        ? try validatedCount("--synthesize-limit", in: args, default: 20, minimum: 1)
        : nil
    if synthesizeLimit != nil && !synthesizeArm {
        throw MCPError(description:
            "--synthesize-limit requires --synthesize-arm (the digest arm is "
            + "what the cap bounds)")
    }
    let payloadArm = try parsePayloadArm(
        optionValue("--payload-arm", in: args)
        ?? ProcessInfo.processInfo.environment["MOOT_BENCH_PAYLOAD_ARM"])
    let limit = (try parseLimitOption(in: args)) ?? 0
    let topK = optionValue("--top-k", in: args).flatMap(Int.init) ?? 10
    guard topK > 0 else {
        throw MCPError(description: "--top-k must be positive; got \(topK)")
    }
    let outPath = optionValue("--out", in: args) ?? "payload-economics-report.json"

    let mootBinary: String
    if let explicit = optionValue("--mootx01-binary", in: args)
        ?? optionValue("--binary", in: args) {
        mootBinary = explicit
    } else if let discovered = discoverMootBinary() {
        mootBinary = discovered
        FileHandle.standardError.write(Data(
            "[payload-economics] auto-discovered mootx01 at: \(discovered)\n".utf8))
    } else {
        throw MCPError(description:
            "mootx01 binary not found. Build with `swift build --package-path "
            + "apps/mootx01` or pass --mootx01-binary <path>.")
    }
    guard FileManager.default.isExecutableFile(atPath: mootBinary) else {
        throw MCPError(description: "mootx01 binary not executable at '\(mootBinary)'")
    }

    try await runPayloadEconomicsLane(config: PayloadLaneConfig(
        estateDir: URL(fileURLWithPath: estateDirStr),
        questionsPath: URL(fileURLWithPath: questionsStr),
        dataDir: URL(fileURLWithPath: dataDirStr),
        variant: variant,
        synthesizeArm: synthesizeArm,
        synthesizeLimit: synthesizeLimit,
        payloadArm: payloadArm,
        limit: limit,
        topK: topK,
        outPath: URL(fileURLWithPath: outPath),
        mootBinaryPath: mootBinary))
}
