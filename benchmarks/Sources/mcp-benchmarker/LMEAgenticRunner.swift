import Foundation

// LMEAgenticRunner.swift — the OFFICIAL-protocol agentic answering arm for
// LongMemEval (lme-agentic lane).
//
// Role: for each question, spawn `mootx01` serve (stdio) on that question's
// PREBUILT estate (restored from the lme-spec artifact store under
// `--estate-cache require` semantics — this lane NEVER builds), hand an
// external answering AI the question plus the estate's MCP tool surface,
// let the AI issue MULTIPLE tool calls against the estate, and collect its
// final answer as the official hypothesis. The prior synthesize-direct arm
// was wrong because it skipped the answering AI entirely; this lane puts a
// frontier model in the loop, querying the estate itself.
//
// Output mirrors LMESpecRunner's official shapes so judging reuses the
// existing judge-batch path unchanged:
//   - hypothesis JSONL: {"question_id":…,"hypothesis":…} (lmeSpecHypothesisLine)
//   - optional judge-input dump: §2 anscheck prompts + §3 call parameters
//     (lmeSpecJudgeInputLine), consumable by lmeSpecRunJudgeBatch and
//     the workshop's judge shard runner
//   - report JSON + params sidecar via RecordWriter; the answering model
//     NAME is recorded in the params sidecar and the report so no score is
//     ever unattributed.
//
// Instrumentation per question, recorded beside the official fields:
//   - tool_calls: number of MCP tool calls the AI issued (executed calls)
//   - answer_cmd_invocations: number of times the answering AI was invoked
//   - prompt_tokens / completion_tokens: summed from the usage blocks the
//     answer command reports (0 when the command reports no usage)
//
// THE AI SEAM IS AN EXTERNAL COMMAND (--answer-cmd, or MOOT_BENCH_ANSWER_CMD
// for secrecy — the env var never appears in `ps` argv), so the harness stays
// model-agnostic. The command is invoked once per AI turn: it reads ONE JSON
// request on stdin and writes ONE JSON response on stdout, then exits 0.
// The command is stateless across turns — every request carries the full
// transcript so far.
//
// ── Request JSON (harness → answer command, on stdin) ────────────────────────
// {
//   "type": "lme_agentic_request",
//   "version": 1,
//   "model": "<the --model name, verbatim — the command should drive this model>",
//   "question_id": "<dataset question_id>",
//   "question": "<question text>",
//   "question_date": "<dataset question_date>",
//   "tools": [ <MCP tools/list entries, VERBATIM, filtered to the read-only
//              allowlist below: {"name":…,"description":…,"inputSchema":…}> ],
//   "transcript": [
//     {"role": "assistant", "tool_call": {"name": "…", "arguments": {…}}},
//     {"role": "tool", "name": "…", "content": "<tool result text>"},
//     …
//   ],
//   "max_tool_calls_remaining": N
// }
//
// ── Response JSON (answer command → harness, on stdout) ──────────────────────
// Exactly ONE of "tool_call" or "answer" must be present:
//   {"tool_call": {"name": "…", "arguments": {…}},
//    "usage": {"prompt_tokens": 123, "completion_tokens": 45}}
//   {"answer": "<final answer text>",
//    "usage": {"prompt_tokens": 123, "completion_tokens": 45}}
// "usage" is optional; when absent the turn contributes 0 to both counters.
// "arguments" is optional on a tool_call (defaults to {}).
//
// Determinism note: the bench-clock env is deliberately NOT set for this
// lane — the agentic arm is judged accuracy, not determinism-gated, and the
// answering AI is an external nondeterministic system anyway.
//
// PORT note: Swift only. There is NO Rust twin for this harness lane (mission
// ruling LME-AGENTIC); the Rust benchmarker carries no lme-agentic subcommand
// and the asymmetry is declared in the CLI option-surface comment.

// MARK: - Read-only tool allowlist

/// The estate tools the answering AI may see and call. Mirrors the READ tier
/// of `PermissionsWriter.readTools` (apps/mootx01, tier snapshot 2026-08-26):
/// no estate content is created, changed, or removed by any tool here. The
/// estate copy the AI queries is a restored artifact clone, but the allowlist
/// still matters — a write would desettle the estate mid-question and make
/// the arm unreproducible, and `moot_synthesize` is excluded on purpose: the
/// answering AI producing the hypothesis itself is the entire point of this
/// arm (the synthesize-direct arm was the defect this lane replaces).
let lmeAgenticReadOnlyTools: Set<String> = [
    AriaV2Surface.estateStatus, AriaV2Surface.estatePing, AriaV2Surface.drainStatus,
    AriaV2Surface.timingReport,
    AriaV2Surface.listLenses, AriaV2Surface.listRecipes,
    AriaV2Surface.vaultStatus, AriaV2Surface.vaultJob,
    AriaV2Surface.memorySearch, AriaV2Surface.memoryGet, AriaV2Surface.memoryList,
    AriaV2Surface.recallPrecise, AriaV2Surface.recallShaped, AriaV2Surface.recallDistilled,
    AriaV2Surface.recallVague,
    AriaV2Surface.factSearch, AriaV2Surface.factTimeline,
    AriaV2Surface.connectionSearch, AriaV2Surface.connectionMap,
    AriaV2Surface.estateMap, AriaV2Surface.readJournal, AriaV2Surface.federatedRecall,
    AriaV2Surface.datasetQuery, AriaV2Surface.datasetStats,
    AriaV2Surface.lensAnticipate, AriaV2Surface.lensApriori, AriaV2Surface.lensAssociations, AriaV2Surface.lensBias,
    AriaV2Surface.lensCohesion, AriaV2Surface.lensComplexity, AriaV2Surface.lensConcepts, AriaV2Surface.lensConstellation,
    AriaV2Surface.lensContradiction, AriaV2Surface.lensDivergence, AriaV2Surface.lensDrift, AriaV2Surface.lensFreeAssociation,
    AriaV2Surface.lensKeystones, AriaV2Surface.lensLatentThemes, AriaV2Surface.lensMoment, AriaV2Surface.lensNodeMotion,
    AriaV2Surface.lensOverlap, AriaV2Surface.lensPartialCue, AriaV2Surface.lensPrecedence, AriaV2Surface.lensRhythm,
    AriaV2Surface.lensSuccessors, AriaV2Surface.lensThemeWeather, AriaV2Surface.lensTrustSynthesis,
]

/// Wall-clock bound for one answer-command invocation, in seconds.
///
/// Deliberately LONGER than `subprocessTimeoutSeconds` (120 s by default, the
/// judge / reranker / answer bound): an agentic turn carries the full transcript — potentially
/// many large tool payloads — into a frontier model, and a long generation on
/// a loaded API is normal, not pathological. A hung command past this bound
/// is still killed, never awaited (runBoundedCmdSubprocess TERM→KILL path).
let lmeAgenticAnswerTimeoutSeconds: Double = 600.0

// MARK: - Answer seam types

/// Token usage one answer-command turn reports for itself.
struct LMEAgenticUsage: Sendable, Equatable {
    /// Tokens the model consumed as input for this turn.
    let promptTokens: Int
    /// Tokens the model generated for this turn.
    let completionTokens: Int
}

/// One parsed answer-command response: either a tool call to execute or the
/// final answer.
enum LMEAgenticStep: Sendable, Equatable {
    /// The AI wants a tool executed against the estate.
    case toolCall(name: String, arguments: [String: JSONValue])
    /// The AI's final answer text (the hypothesis).
    case answer(String)
}

// MARK: - Request / response JSON (the answer-cmd wire shape)

/// Builds the JSON request for one answer-command invocation.
///
/// The shape is documented in the file header; this function is pure so the
/// wire contract is unit-testable without a subprocess. Keys are sorted for
/// byte-stable output (stable across runs and in tests).
///
/// - Parameters:
///   - model: The answering model name (--model), forwarded verbatim.
///   - questionID: The dataset's question_id.
///   - question: The question text.
///   - questionDate: The dataset's question_date string.
///   - tools: The filtered tools/list entries, forwarded verbatim.
///   - transcript: Prior turns (assistant tool_calls and tool results).
///   - maxToolCallsRemaining: Tool-call budget left; 0 tells the AI it must
///     answer now.
/// - Returns: One JSON object as a UTF-8 string (no trailing newline).
/// - Throws: `MCPError` on encoding failure (should be unreachable — every
///   input is already a JSONValue or a String).
func lmeAgenticRequestJSON(
    model: String,
    questionID: String,
    question: String,
    questionDate: String,
    tools: [JSONValue],
    transcript: [JSONValue],
    maxToolCallsRemaining: Int
) throws -> String {
    let request = JSONValue.object([
        "type": .string("lme_agentic_request"),
        "version": .number(1),
        "model": .string(model),
        "question_id": .string(questionID),
        "question": .string(question),
        "question_date": .string(questionDate),
        "tools": .array(tools),
        "transcript": .array(transcript),
        "max_tool_calls_remaining": .number(Double(maxToolCallsRemaining)),
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(request),
          let str = String(data: data, encoding: .utf8) else {
        throw MCPError(description: "lme-agentic: could not encode answer request JSON")
    }
    return str
}

/// Parses one answer-command response.
///
/// Exactly one of `tool_call` / `answer` must be present (both or neither is
/// a contract violation and throws — a silent default would misattribute a
/// malformed turn as an abstention). `usage` is optional; missing or partial
/// usage decodes as nil and the caller records 0 for that turn.
///
/// - Parameter raw: The command's stdout (trimmed by the caller or not —
///   leading/trailing whitespace is tolerated).
/// - Returns: The parsed step and the turn's usage (nil when unreported).
/// - Throws: `MCPError` when the response is not a JSON object or violates
///   the one-of contract.
func lmeAgenticParseResponse(_ raw: String) throws -> (step: LMEAgenticStep, usage: LMEAgenticUsage?) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8),
          let value = try? JSONDecoder().decode(JSONValue.self, from: data),
          case .object = value else {
        throw MCPError(description:
            "lme-agentic: answer command did not return a JSON object — got: "
            + String(trimmed.prefix(200)))
    }

    // Usage block (optional). Partial blocks decode as nil rather than
    // guessing a missing half as zero — the caller's 0-fallback is then
    // visibly "unreported" per turn, not a fabricated split.
    var usage: LMEAgenticUsage? = nil
    if let u = value["usage"],
       let p = u["prompt_tokens"]?.numericValue,
       let c = u["completion_tokens"]?.numericValue {
        usage = LMEAgenticUsage(promptTokens: Int(p), completionTokens: Int(c))
    }

    let toolCallValue = value["tool_call"]
    let answerValue = value["answer"]?.stringValue

    switch (toolCallValue, answerValue) {
    case (nil, nil):
        throw MCPError(description:
            "lme-agentic: answer response carries neither 'tool_call' nor 'answer'")
    case (.some, .some):
        throw MCPError(description:
            "lme-agentic: answer response carries BOTH 'tool_call' and 'answer' — "
            + "the contract is exactly one")
    case (nil, .some(let answer)):
        return (.answer(answer), usage)
    case (.some(let tc), nil):
        guard let name = tc["name"]?.stringValue else {
            throw MCPError(description: "lme-agentic: tool_call is missing 'name'")
        }
        var arguments: [String: JSONValue] = [:]
        if let argsValue = tc["arguments"], case .object(let o) = argsValue {
            arguments = o
        }
        return (.toolCall(name: name, arguments: arguments), usage)
    }
}

/// Invokes the answer command once: request JSON on stdin, response JSON on
/// stdout. Same bounded-lifecycle seam as the judge/reranker
/// (`runBoundedCmdSubprocess`) with the lane's longer timeout.
///
/// - Throws: `MCPError` on timeout, non-zero exit, or undecodable stdout.
func lmeAgenticInvokeAnswerCmd(cmd: String, requestJSON: String) throws -> String {
    guard let result = try runBoundedCmdSubprocess(
        cmd: cmd, prompt: requestJSON,
        timeout: lmeAgenticAnswerTimeoutSeconds) else {
        throw MCPError(description:
            "lme-agentic: answer command timed out after \(Int(lmeAgenticAnswerTimeoutSeconds))s")
    }
    guard result.terminationStatus == 0 else {
        let errText = String(data: result.stderr, encoding: .utf8) ?? ""
        let errSuffix = errText.isEmpty ? "" : ": \(errText.prefix(200))"
        throw MCPError(description:
            "lme-agentic: answer command exited \(result.terminationStatus)\(errSuffix)")
    }
    return String(data: result.stdout, encoding: .utf8) ?? ""
}

// MARK: - Run configuration

/// Configuration for one lme-agentic run. Built from CLI arguments.
///
/// Fixed (not configurable) lane properties, chosen to ADDRESS THE LME-SPEC
/// ARTIFACT STORE — the prebuilt estates this lane restores were built by
/// `lme-spec` artifact runs, so every cache-key component must match that
/// lane's build configuration:
///   fresh-per-question, posture plaintext-optout, seed-path batch, shape
///   disk, estate-cache REQUIRE (measure-only; this lane never builds an
///   estate).
struct LMEAgenticRunConfig: Sendable {
    /// Binary SHA-256 + mootx01 version + protocol version, collected at the
    /// CLI layer; nil for library/test callers.
    var runEnvironment: IdentityEnvironment? = nil

    // ── Dataset / estate ─────────────────────────────────────────────────────
    /// Path to the mootx01 binary (stdio MCP server launched per question).
    let mootBinaryPath: String
    /// Path to the LongMemEval variant JSON.
    let datasetPath: URL
    /// Variant name: "s", "m", or "oracle". Part of the artifact cache key.
    let variant: String
    /// Root directory of the lme-spec artifact store. nil = <out>/estate-cache.
    let cacheDir: URL?
    /// Encode-barrier mode the ARTIFACTS were built under (cache-key
    /// component; default drain matches the artifact build default).
    let encodeBarrier: EncodeBarrier

    // ── Question selection (same SplitMix64 shuffle as lme-spec, so equal
    //    seed/limit/offset values address the same artifact entries) ─────────
    let limit: Int?
    let offset: Int
    let seed: UInt64

    // ── Answering AI ─────────────────────────────────────────────────────────
    /// External answer command (stdin JSON request → stdout JSON response).
    let answerCmd: String
    /// The answering model's NAME, recorded in the report + params sidecar so
    /// no score is ever unattributed. Forwarded verbatim in every request.
    let answerModel: String
    /// Tool-call budget per question. When exhausted the request advertises
    /// max_tool_calls_remaining = 0; an AI that still asks for a tool ends
    /// the question with no hypothesis.
    let maxToolCalls: Int

    // ── Judge seam (mirror of lme-spec; optional) ────────────────────────────
    /// Where to write the §2 anscheck judge-input JSONL dump. nil = no dump.
    let dumpJudgeInputsPath: String?
    /// §3 model identifier recorded in judge-input lines.
    let judgeModel: String

    // ── Output ──────────────────────────────────────────────────────────────
    let outDir: URL?
    let runLabel: String
    let runSerial: String

    // ── Misc ────────────────────────────────────────────────────────────────
    var guardSamplingPolicy: GuardSamplingPolicy
    /// SHA-256 of the corpus fixture (provenance). "unknown" never validates.
    var corpusDigest: String
}

// MARK: - Report structs

/// Per-question instrumentation record, written into the report beside the
/// official hypothesis fields.
public struct LMEAgenticQuestionRecord: Codable, Sendable {
    public let questionID: String
    public let baseQuestionType: String
    public let isAbstention: Bool
    /// True when the AI produced a non-empty final answer.
    public let answered: Bool
    /// MCP tool calls actually executed against the estate.
    public let toolCalls: Int
    /// Times the answer command was invoked (tool turns + the answer turn +
    /// any refused-tool turns).
    public let answerCmdInvocations: Int
    /// Summed prompt tokens the answer command reported (0 when unreported).
    public let promptTokens: Int
    /// Summed completion tokens the answer command reported (0 when unreported).
    public let completionTokens: Int

    enum CodingKeys: String, CodingKey {
        case questionID           = "question_id"
        case baseQuestionType     = "base_question_type"
        case isAbstention         = "is_abstention"
        case answered
        case toolCalls            = "tool_calls"
        case answerCmdInvocations = "answer_cmd_invocations"
        case promptTokens         = "prompt_tokens"
        case completionTokens     = "completion_tokens"
    }
}

/// The lme-agentic run report. Accuracy fields are ABSENT by design: this
/// lane produces hypotheses; accuracy comes from the offline judge-batch
/// pass over the dump file (same path as lme-spec).
public struct LMEAgenticReport: Codable, Sendable {
    // ── Run identity ─────────────────────────────────────────────────────────
    public let runID: String
    public let runLabel: String
    public let variant: String
    public let generatedAt: String
    /// "swift" — this lane has no Rust twin (mission ruling LME-AGENTIC).
    public let port: String

    // ── Attribution ──────────────────────────────────────────────────────────
    /// The answering model's name (--model). THE score-attribution field.
    public let answerModel: String
    /// Tool-call budget per question.
    public let maxToolCalls: Int

    // ── Run metadata ─────────────────────────────────────────────────────────
    public let seed: UInt64
    public let totalQuestions: Int
    /// Questions with a non-empty hypothesis.
    public let answeredCount: Int
    /// Aggregate instrumentation over all questions.
    public let totalToolCalls: Int
    public let totalPromptTokens: Int
    public let totalCompletionTokens: Int
    /// Always equals totalQuestions under require semantics (a miss is a
    /// hard error, never a silent fresh build).
    public let cacheHits: Int
    /// Per-question instrumentation, in run order.
    public let perQuestion: [LMEAgenticQuestionRecord]
    /// Binary SHA-256 + mootx01 version + protocol version.
    public var runEnvironment: IdentityEnvironment? = nil

    enum CodingKeys: String, CodingKey {
        case runID                 = "run_id"
        case runLabel              = "run_label"
        case variant
        case generatedAt           = "generated_at"
        case port
        case answerModel           = "answer_model"
        case maxToolCalls          = "max_tool_calls"
        case seed
        case totalQuestions        = "total_questions"
        case answeredCount         = "answered_count"
        case totalToolCalls        = "total_tool_calls"
        case totalPromptTokens     = "total_prompt_tokens"
        case totalCompletionTokens = "total_completion_tokens"
        case cacheHits             = "cache_hits"
        case perQuestion           = "per_question"
        case runEnvironment        = "run_environment"
    }
}

/// Params sidecar: every option that moves the number, led by the answering
/// model name so two cells at different models are distinguishable without
/// opening the report.
public struct LMEAgenticReportParams: Codable, Sendable {
    public let variant: String
    public let seed: UInt64
    public let limit: Int?
    public let offset: Int
    /// The answering model's NAME (--model), verbatim.
    public let answerModel: String
    public let maxToolCalls: Int
    /// True when --answer-cmd / MOOT_BENCH_ANSWER_CMD was set (always true
    /// for a completed run; recorded for shape parity with lme-spec's
    /// judge_cmd_set — the command itself may carry API keys and is NEVER
    /// recorded).
    public let answerCmdSet: Bool
    public let judgeModel: String
    public let dumpJudgeInputsSet: Bool
    public let encodeBarrier: String
    /// Always "require" — the lane's only estate-cache mode.
    public let estateCache: String

    enum CodingKeys: String, CodingKey {
        case variant
        case seed
        case limit
        case offset
        case answerModel        = "answer_model"
        case maxToolCalls       = "max_tool_calls"
        case answerCmdSet       = "answer_cmd_set"
        case judgeModel         = "judge_model"
        case dumpJudgeInputsSet = "dump_judge_inputs_set"
        case encodeBarrier      = "encode_barrier"
        case estateCache        = "estate_cache"
    }
}

// MARK: - Tool-surface filtering

/// Extracts the read-only tool surface from a raw `tools/list` result.
///
/// Entries are forwarded VERBATIM (name, description, inputSchema — whatever
/// the server sent) so the answering AI sees the server's own contract, not a
/// paraphrase. Only tools in `lmeAgenticReadOnlyTools` survive the filter.
///
/// - Throws: `MCPError` when the result carries no tools array or the filter
///   leaves an empty surface (an estate with no advertised read tool cannot
///   be queried — fail loud, never run a zero-tool arm silently).
func lmeAgenticFilterToolSurface(_ toolsListResult: JSONValue) throws -> [JSONValue] {
    guard case .array(let entries)? = toolsListResult["tools"] else {
        throw MCPError(description:
            "lme-agentic: tools/list result carries no 'tools' array")
    }
    let filtered = entries.filter { entry in
        guard let name = entry["name"]?.stringValue else { return false }
        return lmeAgenticReadOnlyTools.contains(name)
    }
    guard !filtered.isEmpty else {
        throw MCPError(description:
            "lme-agentic: server advertised \(entries.count) tools but NONE are in "
            + "the read-only allowlist — cannot run an agentic arm with no tools")
    }
    return filtered
}

// MARK: - Main run function

/// Runs the lme-agentic harness against a loaded corpus. Returns the report.
///
/// Per question (serial — one estate, one AI conversation at a time):
///   1. Restores the question's prebuilt estate from the lme-spec artifact
///      store (provenance-validated; a miss is a hard `ArtifactRequiredError`).
///   2. Spawns `mootx01` serve (stdio) on the restored copy; lists tools and
///      filters to the read-only surface.
///   3. Agentic loop: invoke the answer command with question + tools +
///      transcript; execute allowed tool calls via MCPClient; stop on a
///      final answer or budget exhaustion.
///   4. Writes the official hypothesis JSONL line (lmeSpecHypothesisLine) and,
///      when configured, the §2 anscheck judge-input dump line.
///   5. Tears the scratch copy down (the cache original is never touched).
///
/// After all questions: writes report + params sidecar via RecordWriter.
func runLMEAgentic(
    questions: [LMESpecQuestion],
    config: LMEAgenticRunConfig
) async throws -> LMEAgenticReport {

    // ── Question selection (seeded shuffle → offset → limit) ─────────────────
    // SplitMix64 Fisher-Yates — SAME PRNG and order as the lme-spec lane, so
    // equal seed/offset/limit values select the same questions and therefore
    // address the same artifact entries.
    var rng = SplitMix64(seed: config.seed)
    var shuffled = questions
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

    // ── Artifact store addressing (lme-spec key; this lane never builds) ─────
    let runProvenance = makeArtifactProvenance(
        benchmark: "lme-spec",           // consumes the lme-spec artifact store
        variant: config.variant,
        seed: config.seed,
        encodeBarrier: config.encodeBarrier,
        posture: .plaintextTransient,
        seedPath: .batch,
        corpusDigest: config.corpusDigest,
        mootx01Version: mootBinaryVersion(binaryPath: config.mootBinaryPath))
    let resolvedCacheDir: URL = try resolvedCacheDirEnforcingDriftGate(
        cacheDir: config.cacheDir,
        outDir: config.outDir,
        mootBinaryPath: config.mootBinaryPath,
        estateCache: .require)

    // ── Output files ─────────────────────────────────────────────────────────
    let outDir: URL = config.outDir
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let hypothesisURL = outDir.appendingPathComponent(
        recordFilename(test: "lme-agentic",
                       arm: "hypotheses-\(config.variant)",
                       serial: config.runSerial,
                       suffix: "",
                       ext: "jsonl"))
    // Owner-only permissions: hypothesis text is model output (BYOAI posture).
    FileManager.default.createFile(
        atPath: hypothesisURL.path, contents: nil,
        attributes: [.posixPermissions: 0o600 as NSNumber])

    // Judge-input dump header (same consume path as lme-spec's dump).
    if let dumpPath = config.dumpJudgeInputsPath {
        let headerObj: [String: Any] = [
            "type": "header",
            "benchmark": "lme-agentic",
            "variant": config.variant,
            "seed": config.seed,
            "run_label": config.runLabel,
            "judge_model": config.judgeModel,
            "answer_model": config.answerModel,
        ]
        if let hData = try? JSONSerialization.data(withJSONObject: headerObj, options: [.sortedKeys]),
           var hLine = String(data: hData, encoding: .utf8) {
            hLine += "\n"
            FileManager.default.createFile(
                atPath: dumpPath, contents: Data(hLine.utf8),
                attributes: [.posixPermissions: 0o600 as NSNumber])
        }
    }

    // ── Guard sampler (validates the binary, per policy) ─────────────────────
    let guardSampler = LegGuardSampler(policy: config.guardSamplingPolicy)

    // ── Per-question serial loop ─────────────────────────────────────────────
    var perQuestion: [LMEAgenticQuestionRecord] = []
    perQuestion.reserveCapacity(sliced.count)
    var cacheHitCount = 0

    for question in sliced {
        // ── Restore the prebuilt estate (require semantics: never build) ────
        let cacheEntry = estateCacheEntryURL(
            cacheDir: resolvedCacheDir,
            benchmark: "lme-spec",
            variant: config.variant,
            seed: config.seed,
            encodeBarrier: config.encodeBarrier,
            posture: .plaintextTransient,
            seedPath: .batch,
            unitID: question.questionID)
        // The manifest decodes but is unused: this lane scores nothing by
        // UUID — the hypothesis is judged text, and UUID→origin mapping is
        // the recall lanes' concern.
        guard let (scratchURL, _): (URL, [LMEManifestEntry]) =
            try restoreEstateCacheEntry(
                from: cacheEntry,
                expectedProvenance: runProvenance,
                scratchDirFactory: { try lmeScratchDir(posture: .plaintextTransient) }) else {
            throw ArtifactRequiredError(entryPath: cacheEntry.path)
        }
        cacheHitCount += 1

        let endpoint = try lmeEndpointConfig(
            scratchDir: scratchURL,
            mootBinaryPath: config.mootBinaryPath,
            posture: .plaintextTransient,
            shape: .disk)
        let client = MCPClient(endpoint: endpoint)
        try await client.connect()

        var questionCompleted = false
        defer {
            Task { await client.disconnect() }
            if questionCompleted {
                try? retireScratchEstate(
                    scratchURL,
                    expectPlaintext: true,
                    teardown: lmeGuardedTeardown)
            } else {
                keepScratchEstateOnFailure(scratchURL, lane: "lme-agentic")
            }
        }

        // ── Tool surface (live tools/list, filtered read-only) ──────────────
        let toolsResult = try await client.listTools(deadline: MCPDeadline.status)
        let toolSurface = try lmeAgenticFilterToolSurface(toolsResult)

        // ── Guard probe ─────────────────────────────────────────────────────
        let (guardVerdict, _) = await guardSampler.probe {
            await probeMCPClient(client, verbMap: lmeMootVerbMap, name: "mootx01-lme-agentic")
        }
        if case .healthy = guardVerdict {} else {
            FileHandle.standardError.write(Data(
                ("[lme-agentic] guard verdict for \(question.questionID): "
                + "\(guardVerdict.diagnostic)\n").utf8))
        }

        // ── Agentic loop ────────────────────────────────────────────────────
        var transcript: [JSONValue] = []
        var toolCalls = 0
        var invocations = 0
        var promptTokens = 0
        var completionTokens = 0
        var hypothesis: String? = nil
        // Invocation ceiling: budget turns + the final answer turn + a small
        // slack for refused-tool turns. Prevents a refusal loop (AI keeps
        // asking for a disallowed tool) from running unbounded.
        let maxInvocations = config.maxToolCalls + 3

        // Answer-cmd failures are per-question, not per-run: the question
        // records no hypothesis (empty string in the official JSONL, exactly
        // like a failed moot_synthesize in the lme-spec lane) and the run
        // continues. Estate/transport failures still propagate and keep the
        // scratch for diagnosis.
        do {
            answerLoop: while invocations < maxInvocations {
                let request = try lmeAgenticRequestJSON(
                    model: config.answerModel,
                    questionID: question.questionID,
                    question: question.question,
                    questionDate: question.questionDate,
                    tools: toolSurface,
                    transcript: transcript,
                    maxToolCallsRemaining: config.maxToolCalls - toolCalls)
                let raw = try lmeAgenticInvokeAnswerCmd(
                    cmd: config.answerCmd, requestJSON: request)
                invocations += 1
                let (step, usage) = try lmeAgenticParseResponse(raw)
                if let u = usage {
                    promptTokens += u.promptTokens
                    completionTokens += u.completionTokens
                }

                switch step {
                case .answer(let text):
                    hypothesis = text.isEmpty ? nil : text
                    break answerLoop
                case .toolCall(let name, let arguments):
                    guard toolCalls < config.maxToolCalls else {
                        // Budget exhausted and the AI still wants a tool:
                        // no hypothesis for this question. The empty-string
                        // JSONL record keeps the line count official.
                        FileHandle.standardError.write(Data(
                            ("[lme-agentic] \(question.questionID): tool budget "
                            + "exhausted without a final answer\n").utf8))
                        break answerLoop
                    }
                    transcript.append(.object([
                        "role": .string("assistant"),
                        "tool_call": .object([
                            "name": .string(name),
                            "arguments": .object(arguments),
                        ]),
                    ]))
                    guard lmeAgenticReadOnlyTools.contains(name) else {
                        // Refusal is fed back as a tool message so the AI can
                        // recover; no MCP call happened, so toolCalls does not
                        // advance (the invocation ceiling bounds this path).
                        transcript.append(.object([
                            "role": .string("tool"),
                            "name": .string(name),
                            "content": .string(
                                "tool '\(name)' is not available in this "
                                + "read-only session"),
                        ]))
                        continue
                    }
                    let resultText: String
                    do {
                        let result = try await client.callTool(
                            name,
                            arguments: arguments,
                            format: .mootV2,
                            deadline: MCPDeadline.interactive)
                        resultText = result.textBlocks.joined(separator: "\n")
                    } catch {
                        // A tool-level failure is information the AI can act
                        // on (retry, rephrase, answer without it) — feed it
                        // back rather than aborting the question.
                        resultText = "tool error: \(error)"
                    }
                    toolCalls += 1
                    transcript.append(.object([
                        "role": .string("tool"),
                        "name": .string(name),
                        "content": .string(resultText),
                    ]))
                }
            }
        } catch {
            FileHandle.standardError.write(Data(
                "[lme-agentic] answer seam error for \(question.questionID): \(error)\n".utf8))
            hypothesis = nil
        }

        // ── Official hypothesis JSONL line (shape-identical to lme-spec) ────
        if let hLine = lmeSpecHypothesisLine(
            questionID: question.questionID,
            hypothesis: hypothesis) {
            if let fh = FileHandle(forWritingAtPath: hypothesisURL.path) {
                fh.seekToEndOfFile()
                fh.write(Data(hLine.utf8))
                fh.closeFile()
            }
        }

        // ── Judge-input dump line (reuses the lme-spec judge-batch path) ────
        if let dumpPath = config.dumpJudgeInputsPath, let hyp = hypothesis {
            if let prompt = try? anscheckPrompt(
                questionType: question.questionType,
                questionID: question.questionID,
                question: question.question,
                answer: question.answer,
                hypothesis: hyp),
               let dumpLine = lmeSpecJudgeInputLine(
                questionID: question.questionID,
                baseQuestionType: question.baseQuestionType,
                isAbstention: question.isAbstention,
                hypothesis: hyp,
                anscheckPrompt: prompt,
                judgeModel: config.judgeModel) {
                if let fh = FileHandle(forWritingAtPath: dumpPath) {
                    fh.seekToEndOfFile()
                    fh.write(Data(dumpLine.utf8))
                    fh.closeFile()
                }
            }
        }

        perQuestion.append(LMEAgenticQuestionRecord(
            questionID: question.questionID,
            baseQuestionType: question.baseQuestionType,
            isAbstention: question.isAbstention,
            answered: hypothesis != nil,
            toolCalls: toolCalls,
            answerCmdInvocations: invocations,
            promptTokens: promptTokens,
            completionTokens: completionTokens))
        questionCompleted = true
    }

    // ── Build report ─────────────────────────────────────────────────────────
    let isoFmt = ISO8601DateFormatter()
    isoFmt.formatOptions = [.withInternetDateTime]
    var report = LMEAgenticReport(
        runID:                 UUID().uuidString,
        runLabel:              config.runLabel,
        variant:               config.variant,
        generatedAt:           isoFmt.string(from: Date()),
        port:                  "swift",
        answerModel:           config.answerModel,
        maxToolCalls:          config.maxToolCalls,
        seed:                  config.seed,
        totalQuestions:        sliced.count,
        answeredCount:         perQuestion.reduce(0) { $0 + ($1.answered ? 1 : 0) },
        totalToolCalls:        perQuestion.reduce(0) { $0 + $1.toolCalls },
        totalPromptTokens:     perQuestion.reduce(0) { $0 + $1.promptTokens },
        totalCompletionTokens: perQuestion.reduce(0) { $0 + $1.completionTokens },
        cacheHits:             cacheHitCount,
        perQuestion:           perQuestion)
    report.runEnvironment = config.runEnvironment

    // ── Write report + params sidecar via RecordWriter ───────────────────────
    let reportURL = outDir.appendingPathComponent(recordFilename(
        test: "lme-agentic", arm: config.variant,
        serial: config.runSerial, suffix: "", ext: "json"))
    let paramsURL = outDir.appendingPathComponent(recordFilename(
        test: "lme-agentic", arm: config.variant,
        serial: config.runSerial, suffix: "params", ext: "json"))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writeRecordNeverOverwrite(try encoder.encode(report), to: reportURL)

    let params = LMEAgenticReportParams(
        variant:            config.variant,
        seed:               config.seed,
        limit:              config.limit,
        offset:             config.offset,
        answerModel:        config.answerModel,
        maxToolCalls:       config.maxToolCalls,
        answerCmdSet:       true,
        judgeModel:         config.judgeModel,
        dumpJudgeInputsSet: config.dumpJudgeInputsPath != nil,
        encodeBarrier:      config.encodeBarrier.rawValue,
        estateCache:        "require")
    try writeRecordNeverOverwrite(try encoder.encode(params), to: paramsURL)

    return report
}
