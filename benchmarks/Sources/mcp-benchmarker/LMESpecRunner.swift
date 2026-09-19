import Foundation

// LMESpecRunner.swift — Spec-compliant LongMemEval runner for the lme-spec lane.
//
// Estate source contract: the runner opens PRE-BUILT artifact estates via the
// id-map.json seam. It builds nothing, settles nothing, and never deletes
// anything. At unit scale one fleet estate per question is opened (unit stem =
// question_id). At bench-aggregate scale one estate is opened serially for every
// question. id-map.json keys are raw session ids (e.g. "3722ea11_2"); the map
// size gives the turnsIngested count for the report.
//
// Role: artifact estate open → hypothesis production via moot_synthesize
// → official hypothesis JSONL → anscheck judge-input dump → optional inline
// judging → §4 aggregation → report + params sidecar.
//
// Judging seam (BYOAI posture, no vendor SDK):
//   1. Inline:  judgeCmd is set → lmeRunJudge (LongMemEvalJudge.swift subprocess seam)
//               is called per question; §3 verdict rule applied; verdicts aggregated §4.
//   2. Dump:    dumpJudgeInputsPath is set → anscheck prompts written to JSONL;
//               operator runs their judge externally; lmeSpecRunJudgeBatch consumes output.
//   3. Neither: run records judged_count=0; aggregate field is absent from the report.
//
// Do NOT wire CLI entry points. Expose runLMESpec and lmeSpecRunJudgeBatch; the
// orchestrator (CLI.swift) wires the lane when ready.

// MARK: - VerbMap

// Bare verb map: NO constant location arg — artifact estates are provenance-blind
// (rooms carry nothing benchmark-shaped). Mirrors loCoMoSpecVerbMap pattern.
private let lmeSpecVerbMap = EndpointConfig.VerbMap(
    write: AriaV2Surface.fileMemory,
    query: AriaV2Surface.memorySearch,
    list: nil,
    constantArgs: [:],
    resultFormat: .mootV2
)

// MARK: - Run configuration

/// Configuration for one lme-spec run. Built from CLI arguments in the caller.
///
/// Mirrors `LMERunConfig` conventions with the lme-spec-specific additions:
/// `judgeModel` (§3 model identity), `dumpJudgeInputsPath` (offline judge seam),
/// and `hypothesisOutputPath` (§1 official hypothesis JSONL location).
struct LMESpecRunConfig: Sendable {
    /// Binary SHA-256 + mootx01 version + protocol version. Collected at the
    /// CLI layer; nil for library/test callers. Full machine profile is
    /// accuracy-lane-excluded per the 2026-08-18 doctrine.
    var runEnvironment: IdentityEnvironment? = nil
    // ── Dataset ───────────────────────────────────────────────────────────────
    /// Path to the mootx01 binary (stdio MCP server launched per question).
    let mootBinaryPath: String
    /// Path to the LongMemEval variant JSON (e.g. longmemeval_m_cleaned.json).
    let datasetPath: URL
    /// Variant name: "s", "m", or "oracle". Recorded in the report arm label.
    let variant: String

    // ── Question selection ────────────────────────────────────────────────────
    /// Maximum questions to run. nil = all questions in the spec corpus (500 for _m).
    let limit: Int?
    /// Skip this many questions from the seeded-shuffled list.
    let offset: Int
    /// Seed for deterministic question shuffling (SplitMix64 Fisher-Yates).
    let seed: UInt64

    // ── Output ────────────────────────────────────────────────────────────────
    /// Directory for the report and params sidecar. nil = current directory.
    let outDir: URL?
    /// Human-readable label, e.g. "lme-spec-m-seed42".
    let runLabel: String
    /// RecordWriter serial tying report to params sidecar. Use resolveRunSerial.
    let runSerial: String

    // ── Judge seam ────────────────────────────────────────────────────────────
    /// Where to write the JSONL dump of anscheck prompts for offline judging.
    /// nil = do not write a dump file; inline judging still runs if judgeCmd is set.
    let dumpJudgeInputsPath: String?
    /// Shell command for inline judging (e.g. "claude -p" or "./judge.sh").
    /// Prompt (the filled §2 anscheck prompt) goes to stdin; answer on stdout.
    /// nil = no inline judging; if also dumpJudgeInputsPath is nil, judged_count=0.
    let judgeCmd: String?
    /// §3 model identifier recorded in judge-input lines and verdict records.
    /// Officially "gpt-4o-2024-08-06" but any external model name is accepted.
    let judgeModel: String

    // ── Unit-ID filter (MOOT_BENCH_UNIT_IDS seam) ───────────────────────────
    /// When non-nil, only these question IDs run (full corpus still loaded; digest unchanged).
    var unitIDs: Set<String>? = nil
    /// File path the unit-ID set was loaded from. Recorded in the params sidecar for
    /// subset identity per the testname-arm-serial discipline.
    var unitIDsPath: String? = nil

    // ── Artifact estate seam ─────────────────────────────────────────────────
    /// Which artifact scale the run opens. Default .unit (one fleet estate per question).
    /// At .benchAggregate, one estate is opened serially for every question.
    let targetScale: ArtifactTargetScale
    /// Catalog.json path for the dataset (maps unit stems to estate directories).
    /// Required at .unit scale.
    let catalogPath: URL?
    /// The bench-aggregate estate directory. Required at .benchAggregate scale.
    let estateDir: URL?

    // ── Answer-input dump seam (reader-model flow) ────────────────────────────
    /// Where to write the JSONL dump of answer inputs for the offline reader flow.
    /// When set, the runner calls moot_memory_search, hydrates the top-K drawer
    /// texts via moot_memory_get, and writes one answer_input line per question.
    /// The hypothesis_digest (moot_synthesize output) is included for reference
    /// but is NOT the hypothesis; a reader model reads the memory_texts instead.
    /// nil = do not write an answer-input dump.
    var dumpAnswerInputsPath: String? = nil
    /// Number of drawer texts to hydrate per question via moot_memory_get.
    /// Matches the convomem-spec answerHydrationDepth default of 10.
    var answerHydrationDepth: Int = 10
    /// Depth tier passed as the `depth` argument to `moot_memory_get` during answer-input
    /// hydration. Distilled is the production shape — the reader sees what a real caller
    /// would receive. Full is the comparison arm for ablation.
    /// Default: .distilled.
    var answerHydrationTier: HydrationDepth = .distilled
}

// MARK: - JSONL line builders

/// Builds one official §1 hypothesis JSONL line: `{"question_id":…,"hypothesis":…}`.
///
/// The spec (§1) requires hypothesis records as JSONL. Empty hypothesis (nil) is
/// written as an empty string rather than omitting the record — every question
/// must appear so the line count equals the question count and the file can be
/// used as a hypothesis file for the upstream evaluate_qa.py script.
///
/// - Parameters:
///   - questionID: The dataset's question_id string.
///   - hypothesis: The system's answer text (moot_synthesize output), or nil on error.
/// - Returns: A UTF-8 JSON line with a trailing newline, or nil on serialization failure.
func lmeSpecHypothesisLine(questionID: String, hypothesis: String?) -> String? {
    let obj: [String: Any] = [
        "question_id": questionID,
        "hypothesis": hypothesis ?? "",
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
          let str = String(data: data, encoding: .utf8) else { return nil }
    return str + "\n"
}

/// Builds one judge-input dump JSONL line.
///
/// The dump line carries everything an offline judge-batch pass needs:
/// the filled §2 anscheck prompt, the §3 call parameters, and enough metadata
/// to reconstruct the §4 verdict record after the judge responds.
///
/// Judge-input line schema:
/// ```json
/// {
///   "type": "question",
///   "question_id": "…",
///   "base_question_type": "…",
///   "is_abstention": false,
///   "hypothesis": "…",
///   "anscheck_prompt": "…",    // the byte-exact §2 filled prompt
///   "model": "gpt-4o-2024-08-06",
///   "n": 1,
///   "temperature": 0,
///   "max_tokens": 10
/// }
/// ```
///
/// - Parameters:
///   - questionID: The dataset's question_id.
///   - baseQuestionType: question_type with any _abs suffix stripped.
///   - isAbstention: True when '_abs' appears in questionID.
///   - hypothesis: The system's answer text for the Model Response slot.
///   - anscheckPrompt: The filled §2 prompt string.
///   - judgeModel: §3 model identifier.
///   - retrievedDrawerIDs: Ordered drawer UUIDs returned by moot_synthesize for this
///     question. Stored in the dump for artifact-recall scoring. Empty when synthesize
///     returned none (e.g., the moot_synthesize verb does not currently forward
///     orderedIDs from its result).
/// - Returns: A UTF-8 JSON line with a trailing newline, or nil on serialization failure.
func lmeSpecJudgeInputLine(
    questionID: String,
    baseQuestionType: String,
    isAbstention: Bool,
    hypothesis: String,
    anscheckPrompt: String,
    judgeModel: String,
    retrievedDrawerIDs: [String] = []
) -> String? {
    let obj: [String: Any] = [
        "type": "question",
        "question_id": questionID,
        "base_question_type": baseQuestionType,
        "is_abstention": isAbstention,
        "hypothesis": hypothesis,
        "anscheck_prompt": anscheckPrompt,
        // §3 call parameters verbatim.
        "model": judgeModel,
        "n": 1,
        "temperature": 0,
        "max_tokens": 10,
        // Drawer UUIDs from moot_synthesize; recorded for artifact-recall scoring.
        "retrieved_drawer_ids": retrievedDrawerIDs,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
          let str = String(data: data, encoding: .utf8) else { return nil }
    return str + "\n"
}

// MARK: - Answer-input dump line builder (reader-model flow)

/// Builds one answer-input dump JSONL line for the offline reader-model flow.
///
/// The answer-input dump (--dump-answer-inputs) carries everything the
/// answer-batch subcommand needs to run a reader model without a live estate:
///
/// - question_id, question_type, question, question_date, correct_answer:
///   directly from the dataset, for prompt construction and judge-input building.
/// - memory_texts: hydrated full-body texts of the top-K retrieved drawers
///   (via moot_memory_get), for the reader model's context window.
/// - retrieved_drawer_ids: the parallel drawer UUIDs (one per memory_text),
///   recorded for artifact-recall scoring.
/// - hypothesis_digest: the moot_synthesize answer, kept for reference and
///   experiment comparison but NOT used as the hypothesis by answer-batch.
/// - base_question_type, is_abstention: passed through so answer-batch can
///   select the correct anscheck prompt template.
///
/// - Parameters:
///   - question: The dataset question.
///   - memoryTexts: Hydrated text strings for the retrieved drawers.
///   - retrievedDrawerIDs: The parallel drawer UUIDs (same order as memoryTexts).
///   - hypothesisDigest: The moot_synthesize answer (reference only).
/// - Returns: A UTF-8 JSON line with a trailing newline, or nil on serialization failure.
func lmeSpecAnswerInputLine(
    question: LMESpecQuestion,
    memoryTexts: [String],
    retrievedDrawerIDs: [String],
    hypothesisDigest: String?
) -> String? {
    let obj: [String: Any] = [
        "type": "answer_input",
        "benchmark": "lme-spec",
        "question_id": question.questionID,
        "question_type": question.questionType,
        "base_question_type": question.baseQuestionType,
        "is_abstention": question.isAbstention,
        "question": question.question,
        "question_date": question.questionDate,
        "correct_answer": question.answer,
        "memory_texts": memoryTexts,
        "retrieved_drawer_ids": retrievedDrawerIDs,
        "hypothesis_digest": hypothesisDigest ?? NSNull() as Any,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
          let str = String(data: data, encoding: .utf8) else { return nil }
    return str + "\n"
}

// MARK: - Per-question result

/// The result of running the lme-spec harness for one question.
struct LMESpecPerQuestionResult: Sendable {
    /// The dataset's question_id.
    let questionID: String
    /// question_type with any _abs suffix stripped (per §4).
    let baseQuestionType: String
    /// True when '_abs' appears in questionID (§2 selector).
    let isAbstention: Bool
    /// The system's answer text from moot_synthesize. nil when the call failed.
    let hypothesis: String?
    /// The verdict record from the inline judge. nil when no inline judge ran or
    /// the anscheck prompt construction failed (unknownQuestionType error).
    let verdictRecord: LMESpecVerdictRecord?
    /// Whether the DegeneracyGuard backend probe found the estate healthy.
    let guardHealthy: Bool
    /// Guard diagnostic message when guardHealthy is false.
    let guardDiagnostic: String?
    /// Always nil: artifact estates are pre-built; the estate-cache axis does not
    /// exist in this lane. Retained so report schema keeps its column.
    let cacheHit: Bool?
    /// Number of id-map entries in the artifact estate (= haystack sessions seeded).
    let turnsIngested: Int
}

// MARK: - Serializable per-question row types

/// Serializable verdict nested inside a per-question report row.
///
/// Wire keys: judge_model, label.
/// Matches LmeSpecReportVerdict from lme_spec_runner.rs for JSON round-trip.
public struct LMESpecReportVerdict: Codable, Sendable {
    public let judgeModel: String
    public let label: Bool
    enum CodingKeys: String, CodingKey {
        case judgeModel = "judge_model"
        case label
    }
}

/// Serializable verdict record nested inside a per-question report row.
///
/// Wire keys: question_id, base_question_type, verdict.
/// Matches LmeSpecReportVerdictRecord from lme_spec_runner.rs for JSON round-trip.
public struct LMESpecReportVerdictRecord: Codable, Sendable {
    public let questionID: String
    public let baseQuestionType: String
    public let verdict: LMESpecReportVerdict
    enum CodingKeys: String, CodingKey {
        case questionID       = "question_id"
        case baseQuestionType = "base_question_type"
        case verdict
    }
}

/// Per-question result row for the lme-spec run report.
///
/// Carries the raw per-question signal (guard health, hypothesis, verdict) that
/// the main loop accumulates. Wire keys match declaration order under the
/// CodingKeys enum, which aligns with LmeSpecReportPerQuestionRow from
/// lme_spec_runner.rs for JSON round-trip.
public struct LMESpecReportPerQuestionRow: Codable, Sendable {
    public let questionID: String
    public let baseQuestionType: String
    public let isAbstention: Bool
    public let hypothesis: String?
    public let verdictRecord: LMESpecReportVerdictRecord?
    public let guardHealthy: Bool
    public let guardDiagnostic: String?
    public let cacheHit: Bool?
    public let turnsIngested: Int
    enum CodingKeys: String, CodingKey {
        case questionID       = "question_id"
        case baseQuestionType = "base_question_type"
        case isAbstention     = "is_abstention"
        case hypothesis
        case verdictRecord    = "verdict_record"
        case guardHealthy     = "guard_healthy"
        case guardDiagnostic  = "guard_diagnostic"
        case cacheHit         = "cache_hit"
        case turnsIngested    = "turns_ingested"
    }
}

// MARK: - Report structs

/// Per-type accuracy entry for the §4 aggregation (always six entries in fixed order).
///
/// Matches `LMESpecPerTypeResult` from LMESpecGrader.swift for Codable round-trip.
public struct LMESpecReportPerType: Codable, Sendable {
    /// One of the six fixed question types from §4.
    public let questionType: String
    /// Mean label over instances of this type, rounded 4dp. 0.0 when count is 0.
    public let accuracy: Double
    /// Number of instances of this type in the evaluated set.
    public let count: Int

    enum CodingKeys: String, CodingKey {
        case questionType = "question_type"
        case accuracy
        case count
    }
}

/// Run parameters sidecar for lme-spec records.
///
/// Carries every option that moves the QA accuracy number. Written as a params
/// sidecar file alongside the report so two cells at different judge models or
/// estate modes are distinguishable in the record set without opening the report.
public struct LMESpecReportParams: Codable, Sendable {
    public let variant: String
    public let seed: UInt64
    public let limit: Int?
    public let offset: Int
    public let judgeModel: String
    /// True when a judge command was configured. The command itself (which may carry
    /// API keys) is never recorded per the same secrecy law as `judgeCmdSet` in
    /// `LMEReportRunParameters` (LongMemEvalScorer.swift).
    public let judgeCmdSet: Bool
    /// True when a dump file path was configured for offline judging.
    public let dumpJudgeInputsSet: Bool
    /// Path of the unit-ID filter file, or nil when no filter was applied.
    /// Distinguishes a subset measurement from a full-corpus run.
    public var unitIDsPath: String? = nil
    /// Number of questions selected after the unit-ID filter (and seed-shuffle +
    /// offset + limit). Matches question_count in the report.
    public var selectedCount: Int = 0

    enum CodingKeys: String, CodingKey {
        case variant
        case seed
        case limit
        case offset
        case judgeModel           = "judge_model"
        case judgeCmdSet          = "judge_cmd_set"
        case dumpJudgeInputsSet   = "dump_judge_inputs_set"
        case unitIDsPath          = "unit_ids_path"
        case selectedCount        = "selected_count"
    }
}

/// The lme-spec run report.
///
/// Always-present fields: per-type accuracy (six entries, fixed order per §4),
/// run metadata (port, seed, estate mode, variant — mirror LMEReport conventions),
/// and judged_count.
///
/// Conditional fields: `taskAveragedAccuracy`, `overallAccuracy`,
/// `abstentionAccuracy`, and `aggregate` are present only when `judgedCount > 0`.
/// When no judge is attached the run records `judgedCount: 0` and these fields
/// are nil/absent — per the lme-spec task specification.
public struct LMESpecReport: Codable, Sendable {
    // ── Protocol conformance (§4) ─────────────────────────────────────────────
    /// Per-type accuracy in the fixed §4 order. Always six entries.
    /// All accuracies are 0.0 and counts are 0 when judgedCount is 0.
    public let perType: [LMESpecReportPerType]
    /// §4 task-averaged accuracy: unweighted mean of six raw per-type accuracies,
    /// rounded 4dp. nil when judgedCount is 0.
    public let taskAveragedAccuracy: Double?
    /// §4 overall accuracy: mean label over all judged instances, rounded 4dp.
    /// nil when judgedCount is 0.
    public let overallAccuracy: Double?
    /// §4 abstention accuracy: mean label over instances with '_abs' in question_id,
    /// rounded 4dp. nil when judgedCount is 0.
    public let abstentionAccuracy: Double?
    /// Number of abstention instances in the evaluated set (based on the corpus,
    /// not the judging). Populated from the question list regardless of judgedCount.
    public let abstentionCount: Int
    /// Unique judge model identifiers seen across all verdicts (sorted).
    /// Empty when judgedCount is 0.
    public let judgeModels: [String]
    /// Number of questions for which a verdict was produced.
    /// 0 when no judge was attached.
    public let judgedCount: Int

    // ── Run identity ─────────────────────────────────────────────────────────
    /// UUID for this run instance.
    public let runID: String
    /// Human-readable label.
    public let runLabel: String
    /// LongMemEval variant: "s", "m", or "oracle".
    public let variant: String
    /// ISO8601 timestamp of report generation.
    public let generatedAt: String
    /// Port: "swift" (this file) or "rust" (lme_spec_runner.rs).
    public let port: String

    // ── Run metadata ─────────────────────────────────────────────────────────
    /// Seed for the deterministic question shuffle.
    public let seed: UInt64
    /// "artifact-unit" or "artifact-aggregate". Matches ArtifactTargetScale semantics.
    public let estateMode: String
    /// Artifact target scale raw value: "unit" or "bench-aggregate".
    public let targetScale: String
    /// Total questions in this run (after limit/offset; includes abstentions).
    public let totalQuestions: Int
    /// Binary SHA-256 + mootx01 version + protocol version (STEP7_FINDINGS.md F1).
    /// Collected at the CLI layer; nil for library/test callers. Full machine
    /// profile is accuracy-lane-excluded per the 2026-08-18 doctrine.
    public var runEnvironment: IdentityEnvironment? = nil
    /// Pending dreaming jobs in the estate at measurement start.
    /// 0 when the dreaming drain lane is absent or the estate reports "drains: none".
    /// Unit-scale runs always record 0 (no shared estate).
    public var dreamPending: Int = 0
    /// Dreaming drain lane state at measurement start: 0 = idle or absent, 1 = draining.
    /// Unit-scale runs always record 0 (no shared estate).
    public var dreamDraining: Int = 0

    // ── Per-question results ──────────────────────────────────────────────────
    /// Per-question result rows carrying the guard health, hypothesis, and verdict
    /// for each evaluated question. Always present; populated from the main loop.
    /// Positioned last in the key order per the wire-contract for this field.
    public var perQuestionResults: [LMESpecReportPerQuestionRow] = []

    enum CodingKeys: String, CodingKey {
        case perType                = "per_type"
        case taskAveragedAccuracy   = "task_averaged_accuracy"
        case overallAccuracy        = "overall_accuracy"
        case abstentionAccuracy     = "abstention_accuracy"
        case abstentionCount        = "abstention_count"
        case judgeModels            = "judge_models"
        case judgedCount            = "judged_count"
        case runID                  = "run_id"
        case runLabel               = "run_label"
        case variant
        case generatedAt            = "generated_at"
        case port
        case seed
        case estateMode             = "estate_mode"
        case targetScale            = "target_scale"
        case totalQuestions         = "total_questions"
        case runEnvironment         = "run_environment"
        case dreamPending           = "dream_pending"
        case dreamDraining          = "dream_draining"
        case perQuestionResults     = "per_question_results"
    }
}

// MARK: - Offline judge-batch (consume path)

/// Reads a lme-spec judge-input dump file, runs the judge for each question,
/// applies the §3 verdict rule, and returns the §4 aggregate result.
///
/// This is the offline consume path of the lme-spec BYOAI judging seam —
/// parallel to `judgebatchRunBatch` (JudgeBatch.swift) but using the §2 anscheck
/// prompt instead of the evidence-payload prompt, and the §3 yes/no verdict rule
/// instead of substring/verdict grading.
///
/// Dump file format (written by `runLMESpec` when `dumpJudgeInputsPath` is set):
/// - Line 0: header `{"type":"header","benchmark":"lme-spec",…}`
/// - Line 1…N: one per question, `{"type":"question","question_id":…,"anscheck_prompt":…,…}`
///
/// For each question line the judge subprocess is called with `anscheck_prompt`
/// on stdin. The response is parsed per §3: `'yes' in eval_response.lower()`.
///
/// - Parameters:
///   - dumpPath: Path to the JSONL dump file produced by `runLMESpec`.
///   - judgeCmd: Shell command for the judge subprocess (reads prompt on stdin,
///     writes yes/no response on stdout).
///   - judgeModel: Model identifier for verdict records. Should match the model
///     that produces responses (used in §4 aggregation's `judge_models` list).
///   - outDir: Directory for the verdict output JSONL file.
/// - Returns: The §4 aggregate result over all successfully judged questions.
/// - Throws: `MCPError` when the dump file cannot be read or has no header.
func lmeSpecRunJudgeBatch(
    dumpPath: String,
    judgeCmd: String,
    judgeModel: String,
    outDir: URL
) throws -> LMESpecAggregateResult {
    guard let rawContent = FileManager.default.contents(atPath: dumpPath),
          let content = String(data: rawContent, encoding: .utf8) else {
        throw MCPError(description: "lme-spec judge-batch: cannot read dump file '\(dumpPath)'")
    }

    let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
    guard !lines.isEmpty else {
        throw MCPError(description: "lme-spec judge-batch: dump file is empty: '\(dumpPath)'")
    }

    // Validate header (first line, type: "header").
    guard let headerData = lines[0].data(using: .utf8),
          let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
          let headerType = header["type"] as? String, headerType == "header" else {
        throw MCPError(description:
            "lme-spec judge-batch: first line is not a valid header object in '\(dumpPath)'")
    }

    let runLabel = header["run_label"] as? String ?? "unknown"
    var verdictRecords: [LMESpecVerdictRecord] = []
    var verdictJSONLLines: [String] = []

    for line in lines.dropFirst() {
        guard let lineData = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let lineType = obj["type"] as? String, lineType == "question",
              let questionID = obj["question_id"] as? String,
              let baseType = obj["base_question_type"] as? String,
              let prompt = obj["anscheck_prompt"] as? String else {
            continue
        }

        // Run the judge subprocess with the filled §2 anscheck prompt on stdin.
        let response: String
        do {
            response = try lmeRunJudge(cmd: judgeCmd, prompt: prompt)
        } catch {
            FileHandle.standardError.write(Data(
                "[lme-spec judge-batch] judge failed for \(questionID): \(error)\n".utf8))
            continue
        }

        // §3: `label = 'yes' in eval_response.lower()` after strip.
        let verdict = lmeSpecVerdict(evalResponse: response, judgeModel: judgeModel)
        verdictRecords.append(LMESpecVerdictRecord(
            questionID: questionID,
            baseQuestionType: baseType,
            verdict: verdict))

        // Write one verdict line to the output JSONL.
        let verdictObj: [String: Any] = [
            "question_id": questionID,
            "base_question_type": baseType,
            "judge_model": judgeModel,
            "response": response,
            "label": verdict.label,
        ]
        if let vData = try? JSONSerialization.data(withJSONObject: verdictObj, options: [.sortedKeys]),
           let vLine = String(data: vData, encoding: .utf8) {
            verdictJSONLLines.append(vLine)
        }
    }

    // Write verdict file (no-clobber, owner-only permissions, ISO8601 stamped).
    let iso8601: String = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "Z")
    }()
    let safeLabel = runLabel
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "\\", with: "_")
    let verdictFilename = "lme-spec-judge-verdicts-\(safeLabel)-\(iso8601).jsonl"
    let verdictURL = outDir.appendingPathComponent(verdictFilename)
    let verdictContent = verdictJSONLLines.joined(separator: "\n")
        + (verdictJSONLLines.isEmpty ? "" : "\n")
    FileManager.default.createFile(
        atPath: verdictURL.path, contents: nil,
        attributes: [.posixPermissions: 0o600 as NSNumber])
    try Data(verdictContent.utf8).write(to: verdictURL)

    // §4 aggregation over all successfully judged questions.
    return lmeSpecAggregate(verdictRecords)
}

// MARK: - Endpoint config builder

/// Builds an EndpointConfig for mootx01 pointing at a pre-built artifact estate.
///
/// READ-ONLY use: the lane only calls moot_synthesize (and optionally
/// moot_memory_search for the guard probe). The estate is attached as a transient
/// record. Deliberately NOT routed through assertScratchBackend — that
/// guard pins WRITE lanes to /tmp scratch; this lane reads a durable artifact
/// in place (same posture as ArtifactRecallRunner).
func lmeSpecEndpointConfig(
    estateDir: URL,
    mootBinaryPath: String
) throws -> EndpointConfig {
    let command = try mootServeCommand(binary: mootBinaryPath, scratchDir: estateDir, environment: ["MOOTX01_FROZEN=1", "MOOTX01_SUBJECT_RIDER=0"])
    return EndpointConfig(
        name: "mootx01-lme-spec",
        transport: .stdio(command: command),
        auth: nil,
        verbMap: lmeSpecVerbMap,
        role: .target
    )
}

// MARK: - Main run function

/// Runs the lme-spec harness against a loaded corpus. Returns the run report.
///
/// For each question the runner:
///   1. Resolves the artifact estate directory (unit: catalog → question_id,
///      bench-aggregate: estateDir shared across all questions).
///   2. Loads id-map.json to count turnsIngested.
///   3. Opens the estate via mootx01 (--db <estate>).
///   4. Calls `moot_synthesize` to produce the hypothesis.
///   5. Writes official `{"question_id":…,"hypothesis":…}` JSONL line.
///   6. Builds the §2 anscheck prompt via `anscheckPrompt` (LMESpecGrader.swift).
///   7. If `dumpJudgeInputsPath` is set: appends judge-input dump line.
///   8. If `judgeCmd` is set: calls `lmeRunJudge`, parses §3 verdict, collects
///      `LMESpecVerdictRecord` for §4 aggregation.
///
/// After all questions:
///   - Calls `lmeSpecAggregate` (LMESpecGrader.swift) on collected verdicts.
///   - Writes report + params sidecar via RecordWriter to `config.outDir`.
///
/// When no judge is attached (`judgeCmd` is nil), `judgedCount` is 0 and the
/// per-type accuracy fields carry 0.0/count=0. The aggregate is still computed
/// (trivially empty) but is omitted from the JSON report per the spec.
///
/// - Parameters:
///   - questions: Questions from `LMESpecCorpus.questions` (all 500 for _m).
///   - config: Run configuration.
///   - hypothesisOutputPath: Where to write official hypothesis JSONL (§1).
///     nil = write next to the report as `lme-spec-hypotheses-<arm>-<serial>.jsonl`.
/// - Returns: The completed `LMESpecReport`.
/// - Throws: `MCPError` on estate access failure or question processing failure.
func runLMESpec(
    questions: [LMESpecQuestion],
    config: LMESpecRunConfig,
    hypothesisOutputPath: URL? = nil
) async throws -> LMESpecReport {

    // ── Unit-ID filter (before shuffle: same ids file → same units regardless of seed) ──
    // The full corpus is always loaded (corpus_digest unchanged); the filter selects
    // which question IDs run. Every requested ID must be present — a miss is a hard error.
    let filteredQuestions = try filterUnits(
        questions, ids: config.unitIDs, id: { $0.questionID }, lane: "lme-spec")

    // ── Question selection (seeded shuffle → offset → limit) ──────────────────
    // SplitMix64 Fisher-Yates — same PRNG as the existing LME lane so equivalent
    // seed+limit values produce the same question ordering across both lanes.
    var rng = SplitMix64(seed: config.seed)
    var shuffled = filteredQuestions
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }
    let afterOffset = Array(shuffled.dropFirst(config.offset))
    let sliced: [LMESpecQuestion]
    if let limit = config.limit {
        sliced = Array(afterOffset.prefix(limit))
    } else {
        sliced = afterOffset
    }

    // ── Output directory ──────────────────────────────────────────────────────
    let outDir: URL = config.outDir
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    // ── Hypothesis output file ────────────────────────────────────────────────
    let hypothesisURL: URL = hypothesisOutputPath
        ?? outDir.appendingPathComponent(
            recordFilename(test: "lme-spec",
                           arm: "hypotheses-\(config.variant)",
                           serial: config.runSerial,
                           suffix: "",
                           ext: "jsonl"))
    // Create empty hypothesis file upfront (owner-only; BYOAI posture).
    FileManager.default.createFile(
        atPath: hypothesisURL.path, contents: nil,
        attributes: [.posixPermissions: 0o600 as NSNumber])

    // ── Judge-input dump header ───────────────────────────────────────────────
    if let dumpPath = config.dumpJudgeInputsPath {
        let headerObj: [String: Any] = [
            "type": "header",
            "benchmark": "lme-spec",
            "variant": config.variant,
            "seed": config.seed,
            "run_label": config.runLabel,
            "judge_model": config.judgeModel,
        ]
        if let hData = try? JSONSerialization.data(withJSONObject: headerObj, options: [.sortedKeys]),
           var hLine = String(data: hData, encoding: .utf8) {
            hLine += "\n"
            FileManager.default.createFile(
                atPath: dumpPath, contents: Data(hLine.utf8),
                attributes: [.posixPermissions: 0o600 as NSNumber])
        }
    }

    // ── Answer-input dump header (reader-model flow) ──────────────────────────
    // Written before the question loop so append_to_file has an existing file.
    // The header records benchmark + hydration depth so answer-batch can dispatch
    // to the correct reader-prompt builder without re-opening the estate.
    if let dumpPath = config.dumpAnswerInputsPath {
        let headerObj: [String: Any] = [
            "type": "header",
            "benchmark": "lme-spec",
            "variant": config.variant,
            "seed": config.seed,
            "run_label": config.runLabel,
            "answer_hydration_depth": config.answerHydrationDepth,
            "hydration_tier": config.answerHydrationTier.rawValue,
        ]
        if let hData = try? JSONSerialization.data(withJSONObject: headerObj, options: [.sortedKeys]),
           var hLine = String(data: hData, encoding: .utf8) {
            hLine += "\n"
            FileManager.default.createFile(
                atPath: dumpPath, contents: Data(hLine.utf8),
                attributes: [.posixPermissions: 0o600 as NSNumber])
        }
    }

    // ── Bench-aggregate: open one shared estate before the loop ──────────────
    // One serve holds the estate at a time; parallelism is forced to 1 for the
    // bench-aggregate path (each question reuses the same client).
    var sharedBenchClient: MCPClient? = nil
    var sharedBenchEstateDir: URL? = nil
    if config.targetScale != .unit {
        guard let dir = config.estateDir else {
            throw MCPError(description:
                "lme-spec: \(config.targetScale.rawValue) scale requires --estate-dir")
        }
        sharedBenchEstateDir = dir
        let endpoint = try lmeSpecEndpointConfig(
            estateDir: dir, mootBinaryPath: config.mootBinaryPath)
        let c = MCPClient(endpoint: endpoint)
        try await c.connect()
        sharedBenchClient = c
    }
    defer { if let c = sharedBenchClient { Task { await c.disconnect() } } }

    // ── Dream drain status at run start (bench-aggregate only) ───────────────
    // Captures how many unprocessed dreaming jobs are outstanding so readers
    // can assess whether dream-derived content was available during retrieval.
    // Unit-scale has no shared estate; dream fields default to 0/settled.
    var dreamStatus = DreamStatus(pending: 0, settled: true)
    if let c = sharedBenchClient {
        dreamStatus = await readDrainStatusOnce(client: c)
    }

    // ── Guard sampler (one probe per leg per policy) ──────────────────────────
    let guardSampler = LegGuardSampler(policy: .oncePerLeg)

    // ── Per-question serial loop ───────────────────────────────────────────────
    var perQuestionResults: [LMESpecPerQuestionResult] = []
    perQuestionResults.reserveCapacity(sliced.count)
    var verdictRecords: [LMESpecVerdictRecord] = []
    // Counts moot_synthesize calls that returned an empty response. A non-zero
    // value is always a problem: the spec requires a hypothesis for every question.
    var synthesizeRefusalCount: Int = 0

    for question in sliced {
        // ── Artifact estate resolution ─────────────────────────────────────
        // Unit scale: one fleet estate per question (unit stem = question_id).
        // Bench-aggregate: shared estate opened before the loop.
        let estateDir: URL
        let client: MCPClient
        // A unit-scale client lives for the whole question. The disconnect
        // is deferred at loop-body scope: a defer inside the switch case would
        // fire as soon as the case ends, before the synthesis call, and the
        // detached disconnect would race the call for the transport.
        var unitClient: MCPClient? = nil
        defer { if let u = unitClient { Task { await u.disconnect() } } }

        switch config.targetScale {
        case .unit:
            guard let catalogPath = config.catalogPath else {
                throw MCPError(description: "lme-spec: unit scale requires --catalog")
            }
            // Unit stem is the question_id (e.g. "3722ea11_2"). The catalog
            // resolver checks existence and applies the containment guard.
            // A missing or unresolvable unit degrades this question
            // (guardHealthy: false) rather than aborting the run. This matches
            // the Rust twin's error handling in lme_spec_runner.rs: per-question
            // degradation keeps the rest of the run intact when one unit is absent
            // from the catalog. The resolver's own error text becomes the diagnostic
            // (e.description, not a re-authored message) so the two ports carry
            // identical diagnostic strings for the same failure.
            do {
                estateDir = try artifactUnitEstateDir(catalogPath: catalogPath, id: question.questionID)
            } catch let e as MCPError {
                perQuestionResults.append(LMESpecPerQuestionResult(
                    questionID: question.questionID,
                    baseQuestionType: question.baseQuestionType,
                    isAbstention: question.isAbstention,
                    hypothesis: nil,
                    verdictRecord: nil,
                    guardHealthy: false,
                    guardDiagnostic: e.description,
                    cacheHit: nil,
                    turnsIngested: 0))
                continue
            }
            let endpoint = try lmeSpecEndpointConfig(
                estateDir: estateDir, mootBinaryPath: config.mootBinaryPath)
            let freshClient = MCPClient(endpoint: endpoint)
            try await freshClient.connect()
            unitClient = freshClient
            client = freshClient
        case .benchAggregate, .completeAggregate:
            guard let bc = sharedBenchClient, let bed = sharedBenchEstateDir else {
                throw MCPError(description: "lme-spec: bench-aggregate client not initialized")
            }
            client = bc
            estateDir = bed
        }

        // ── id-map.json → turnsIngested count ─────────────────────────────
        // id-map.json keys are raw session ids (e.g. "3722ea11_2"). The map
        // size gives the number of sessions seeded into this estate.
        let idMap = try loadArtifactIDMap(estateDir: estateDir)
        let turnsIngested = idMap.count

        FileHandle.standardError.write(Data(
            ("[lme-spec] question=\(question.questionID) "
             + "(\(turnsIngested) sessions, scale=\(config.targetScale.rawValue))\n").utf8))

        // ── DegeneracyGuard probe ─────────────────────────────────────────
        let (guardVerdict, _) = await guardSampler.probe {
            await probeMCPClient(client, verbMap: lmeSpecVerbMap, name: "mootx01-lme-spec")
        }
        let guardHealthy: Bool
        if case .healthy = guardVerdict { guardHealthy = true } else { guardHealthy = false }
        let guardDiagnostic: String? = guardHealthy ? nil : guardVerdict.diagnostic

        // ── Hypothesis production via moot_synthesize ──────────────────────
        // §6 row 4: the hypothesis is the system's answer text. moot_synthesize
        // generates a direct prose answer from the estate without returning ranked
        // IDs — it is the estate's native answer-generation mode and the closest
        // analogue to the "system's answer text" the spec protocol scores.
        var hypothesis: String? = nil
        // Drawer UUIDs from moot_synthesize — captured for artifact-recall scoring.
        var synthOrderedIDs: [String] = []
        do {
            let synthArgs: [String: JSONValue] = [
                lmeSpecVerbMap.queryArg: .string(question.question),
            ]
            let synthResult = try await client.callTool(
                AriaV2Surface.synthesize,
                arguments: synthArgs,
                format: lmeSpecVerbMap.resultFormat)
            let text = synthResult.textBlocks.joined(separator: "\n")
            if text.isEmpty {
                // moot_synthesize returned an empty string — the server refused or
                // produced no text. Count as a synthesis failure so the report does
                // not silently inflate its run_count with unanswered questions.
                FileHandle.standardError.write(Data(
                    ("[lme-spec] moot_synthesize empty response (refusal) for "
                    + "\(question.questionID): "
                    + "textBlocks=\(synthResult.textBlocks.count) all empty\n").utf8))
                synthesizeRefusalCount += 1
                hypothesis = nil
            } else {
                hypothesis = text
            }
            synthOrderedIDs = synthResult.orderedIDs
        } catch {
            FileHandle.standardError.write(Data(
                "[lme-spec] moot_synthesize error for \(question.questionID): \(error)\n".utf8))
        }

        // ── Write official hypothesis JSONL record (§1) ────────────────────
        if let hLine = lmeSpecHypothesisLine(
            questionID: question.questionID,
            hypothesis: hypothesis) {
            if let fh = FileHandle(forWritingAtPath: hypothesisURL.path) {
                fh.seekToEndOfFile()
                fh.write(Data(hLine.utf8))
                fh.closeFile()
            }
        }

        // ── Build anscheck prompt (§2) ────────────────────────────────────
        // Only attempt judging when we have a hypothesis to grade.
        var verdictRecord: LMESpecVerdictRecord? = nil
        if let hyp = hypothesis {
            let promptResult = try? anscheckPrompt(
                questionType: question.questionType,
                questionID: question.questionID,
                question: question.question,
                answer: question.answer,
                hypothesis: hyp)

            if let prompt = promptResult {
                // ── Judge-input dump ─────────────────────────────────────
                if let dumpPath = config.dumpJudgeInputsPath {
                    if let dumpLine = lmeSpecJudgeInputLine(
                        questionID: question.questionID,
                        baseQuestionType: question.baseQuestionType,
                        isAbstention: question.isAbstention,
                        hypothesis: hyp,
                        anscheckPrompt: prompt,
                        judgeModel: config.judgeModel,
                        retrievedDrawerIDs: synthOrderedIDs) {
                        if let fh = FileHandle(forWritingAtPath: dumpPath) {
                            fh.seekToEndOfFile()
                            fh.write(Data(dumpLine.utf8))
                            fh.closeFile()
                        }
                    }
                }

                // ── Inline judging ────────────────────────────────────────
                // §3 call: model, messages[{role:user,content:prompt}], n=1, temp=0, max_tokens=10.
                // The judge subprocess is the external model; lmeRunJudge handles the seam.
                if let judgeCmd = config.judgeCmd {
                    do {
                        let response = try lmeRunJudge(cmd: judgeCmd, prompt: prompt)
                        // §3 verdict: `'yes' in eval_response.lower()` after strip.
                        let verdict = lmeSpecVerdict(
                            evalResponse: response,
                            judgeModel: config.judgeModel)
                        verdictRecord = LMESpecVerdictRecord(
                            questionID: question.questionID,
                            baseQuestionType: question.baseQuestionType,
                            verdict: verdict)
                        verdictRecords.append(verdictRecord!)
                    } catch {
                        FileHandle.standardError.write(Data(
                            "[lme-spec] judge error for \(question.questionID): \(error)\n".utf8))
                    }
                }
            } else {
                // anscheckPrompt threw unknownQuestionType — log and continue.
                FileHandle.standardError.write(Data(
                    ("[lme-spec] unknown question type '\(question.questionType)' "
                    + "for \(question.questionID) — skipping anscheck prompt\n").utf8))
            }
        }

        // ── Answer-input dump (reader-model flow) ────────────────────────────
        // When --dump-answer-inputs is set: call moot_memory_search to get the
        // ranked drawer IDs, hydrate the top-N texts via moot_memory_get, then
        // write one answer_input line. The hypothesis from moot_synthesize is
        // included as hypothesis_digest for reference only — the reader model
        // that runs via answer-batch will produce the actual hypothesis from the
        // memory_texts.
        if let dumpPath = config.dumpAnswerInputsPath {
            var retrievedIDs: [String] = []
            do {
                let searchArgs: [String: JSONValue] = [
                    lmeSpecVerbMap.queryArg: .string(question.question),
                ]
                let searchResult = try await client.callTool(
                    lmeSpecVerbMap.query,
                    arguments: searchArgs,
                    format: lmeSpecVerbMap.resultFormat)
                retrievedIDs = searchResult.orderedIDs
            } catch {
                FileHandle.standardError.write(Data(
                    "[lme-spec] moot_memory_search error for \(question.questionID): \(error)\n".utf8))
            }

            // Hydrate the top-K drawer texts via moot_memory_get.
            var memoryTexts: [String] = []
            var hydratedIDs: [String] = []
            for drawerID in retrievedIDs.prefix(config.answerHydrationDepth) {
                do {
                    let full = try await client.callTool(
                        AriaV2Surface.memoryGet,
                        arguments: AriaV2Surface.memoryGetArgs(memoryId: drawerID, depth: config.answerHydrationTier.rawValue),
                        format: lmeSpecVerbMap.resultFormat)
                    let text = full.textBlocks.joined(separator: "\n")
                    if !text.isEmpty {
                        memoryTexts.append(text)
                        hydratedIDs.append(drawerID)
                    }
                } catch {
                    FileHandle.standardError.write(Data(
                        "[lme-spec] moot_memory_get failed for \(drawerID): \(error)\n".utf8))
                }
            }

            if let dumpLine = lmeSpecAnswerInputLine(
                question: question,
                memoryTexts: memoryTexts,
                retrievedDrawerIDs: hydratedIDs,
                hypothesisDigest: hypothesis) {
                if let fh = FileHandle(forWritingAtPath: dumpPath) {
                    fh.seekToEndOfFile()
                    fh.write(Data(dumpLine.utf8))
                    fh.closeFile()
                }
            }
        }

        perQuestionResults.append(LMESpecPerQuestionResult(
            questionID: question.questionID,
            baseQuestionType: question.baseQuestionType,
            isAbstention: question.isAbstention,
            hypothesis: hypothesis,
            verdictRecord: verdictRecord,
            guardHealthy: guardHealthy,
            guardDiagnostic: guardDiagnostic,
            cacheHit: nil,
            turnsIngested: turnsIngested))
    } // end for question in sliced

    // Log synthesis refusal count so the operator can see it before the report.
    if synthesizeRefusalCount > 0 {
        FileHandle.standardError.write(Data(
            ("[lme-spec] WARNING: \(synthesizeRefusalCount) of \(sliced.count) questions "
            + "received an empty hypothesis from moot_synthesize (refusals)\n").utf8))
    }

    // ── §4 aggregation ────────────────────────────────────────────────────────
    let aggregate = lmeSpecAggregate(verdictRecords)
    let judgedCount = verdictRecords.count

    // Count abstentions from the question list (not the verdict records)
    // so the field is populated even when judgedCount == 0.
    let abstentionCount = sliced.reduce(0) { $0 + ($1.isAbstention ? 1 : 0) }

    // ── Build report ──────────────────────────────────────────────────────────
    let now = Date()
    let isoFmt = ISO8601DateFormatter()
    isoFmt.formatOptions = [.withInternetDateTime]
    let generatedAt = isoFmt.string(from: now)

    let perTypeReport: [LMESpecReportPerType] = aggregate.perType.map { pt in
        LMESpecReportPerType(
            questionType: pt.questionType,
            accuracy: judgedCount > 0 ? pt.accuracy : 0.0,
            count: pt.count)
    }

    // estateMode reflects the artifact scale used for this run.
    let estateMode = config.targetScale == .unit ? "artifact-unit" : "artifact-aggregate"

    var report = LMESpecReport(
        perType: perTypeReport,
        taskAveragedAccuracy: judgedCount > 0 ? aggregate.taskAveragedAccuracy : nil,
        overallAccuracy:      judgedCount > 0 ? aggregate.overallAccuracy      : nil,
        abstentionAccuracy:   judgedCount > 0 ? aggregate.abstentionAccuracy   : nil,
        abstentionCount:      abstentionCount,
        judgeModels:          aggregate.judgeModels,
        judgedCount:          judgedCount,
        runID:                UUID().uuidString,
        runLabel:             config.runLabel,
        variant:              config.variant,
        generatedAt:          generatedAt,
        port:                 "swift",
        seed:                 config.seed,
        estateMode:           estateMode,
        targetScale:          config.targetScale.rawValue,
        totalQuestions:       sliced.count)
    report.runEnvironment = config.runEnvironment
    report.dreamPending  = dreamStatus.pending
    report.dreamDraining = dreamStatus.settled ? 0 : 1
    report.perQuestionResults = perQuestionResults.map { result in
        LMESpecReportPerQuestionRow(
            questionID:       result.questionID,
            baseQuestionType: result.baseQuestionType,
            isAbstention:     result.isAbstention,
            hypothesis:       result.hypothesis,
            verdictRecord:    result.verdictRecord.map { vr in
                LMESpecReportVerdictRecord(
                    questionID:       vr.questionID,
                    baseQuestionType: vr.baseQuestionType,
                    verdict:          LMESpecReportVerdict(
                        judgeModel: vr.verdict.judgeModel,
                        label:      vr.verdict.label))
            },
            guardHealthy:     result.guardHealthy,
            guardDiagnostic:  result.guardDiagnostic,
            cacheHit:         result.cacheHit,
            turnsIngested:    result.turnsIngested)
    }

    // ── Write report + params sidecar via RecordWriter ────────────────────────
    // Record name stem: lme-spec-<variant>-<serial>  (test=lme-spec, arm=variant).
    let arm = config.variant
    let reportFilename = recordFilename(
        test: "lme-spec", arm: arm, serial: config.runSerial, suffix: "", ext: "json")
    let paramsFilename = recordFilename(
        test: "lme-spec", arm: arm, serial: config.runSerial, suffix: "params", ext: "json")

    let reportURL = outDir.appendingPathComponent(reportFilename)
    let paramsURL = outDir.appendingPathComponent(paramsFilename)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let reportData = try encoder.encode(report)
    // Owner-only, matching the hypothesis JSONL and the verdict file beside it.
    // The report embeds the same produced text those two are restricted for;
    // writing it 0644 published at the default while its siblings were guarded,
    // which is the BYOAI posture holding in one file and not the other.
    try writeRecordNeverOverwrite(reportData, to: reportURL, permissions: 0o600)

    var params = LMESpecReportParams(
        variant:            config.variant,
        seed:               config.seed,
        limit:              config.limit,
        offset:             config.offset,
        judgeModel:         config.judgeModel,
        judgeCmdSet:        config.judgeCmd != nil,
        dumpJudgeInputsSet: config.dumpJudgeInputsPath != nil)
    params.unitIDsPath  = config.unitIDsPath
    params.selectedCount = sliced.count
    let paramsData = try encoder.encode(params)
    // The parameters name the judge model and the local paths the run read
    // from; same run, same posture.
    try writeRecordNeverOverwrite(paramsData, to: paramsURL, permissions: 0o600)

    return report
}
