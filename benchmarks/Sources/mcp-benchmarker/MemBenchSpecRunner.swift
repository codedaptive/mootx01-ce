import Foundation

// MemBenchSpecRunner.swift — Official-protocol runner for the membench-spec lane.
//
// This file implements the MemBench evaluation protocol verbatim, per
// MEMBENCH_OFFICIAL_PROTOCOL.md §2–§6, realigning the existing membench lane's
// four known deviations (§7 rows 1–6):
//
//   §7 row 1: answer letter produced by an external answering model via the
//             BYOAI seam (--answer-cmd or offline batch), not heuristic choice-scan.
//   §7 row 2: storage lines use the §2 step-prefix format
//             (`{step}[|]{message}` or `{step}[|]'user': {u}; 'agent': {a}`).
//   §7 row 3: recall metric is §4 `get_recall` verbatim, not LME ranked-list math.
//   §7 row 4: recall/answer query uses `recallQuery(question:time:)` — `question (time)`.
//   §7 row 5: §5 wall-clock timers recorded per moot_file_memory and moot_memory_search call.
//   §7 row 6: §6 step_cap capacity walk; TokenCounter seam defers cl100k_base artifact.
//
// Step ↔ sid correspondence (MEMBENCH_OFFICIAL_PROTOCOL.md §2):
//   The env stores each message as `{step}[|]{message}` where step is the env's
//   step_id. We use `turn.sid` (the corpus global turn id) as the step value.
//   Rationale: §4 parses `int(stored_text.split('[|]')[0])` and compares against
//   `target_step_id[*].globalSid`. Using `turn.sid` makes those values identical —
//   stored step id == corpus sid == target global sid. This is the only mapping
//   that makes the §4 recall comparison work without a secondary table.
//
//   Documentation: step = turn.sid (no offset). FirstAgent session 0 has sids
//   0–N, session 1 has sids (N+1)–M, etc. (verified from MemBenchCorpus loader).
//
// Estate strategy: pre-built artifact estates opened read-only via the id-map.json
// seam (M4 migration). Each unit estate is keyed by the unit stem derived from the
// item ID: "<family>__<category>__<section>__<tid>". The id-map encodes
// "<family>/<category>/<section>/<tid>/<entity>" → drawerUUID where entity is the
// turn sid (as a decimal string) used during artifact construction.
//
// §6 step_cap EXCEPTION: the step_cap capacity walk KEEPS fresh-estate-per-item
// (encodeBarrier=.impatient, per-turn ingest). Artifact estates are opened only on
// the standard accuracy path (runMode == .standard).
//
// Live-path ingest only (step_cap only): the §2 step-prefix content is written per
// turn via moot_file_memory. The standard path opens a pre-built estate and queries
// directly with no ingest or settle phase.
//
// Answer path — two modes (§3, §7 row 1):
//   live:  --answer-cmd <cmd>     subprocess per item while the estate is alive.
//   batch: --dump-answer-inputs   writes JSONL prompts after each estate run,
//          --consume-answers      reads pre-scored letters from an earlier dump.
//   When neither is configured, answered_count is 0 and accuracy is not reported.
//   NO fallback heuristic: absent an answering model, there is no prediction.
//
// §6 step_cap is a SEPARATE RUN MODE (runMode: .stepCap). The standard mode
// (runMode: .standard) implements §3–§5. step_cap is invoked only when explicitly
// requested and uses inline encoding (impatient) so each stored turn is
// immediately queryable.

// MARK: - VerbMap

/// Standard mootx01 VerbMap for membench-spec step_cap ingest + recall queries.
/// Location "benchmarks/membench-spec" distinguishes spec-lane estates from
/// the existing membench lane ("benchmarks/membench").
///
/// Used only in step_cap mode (fresh-estate-per-item). Standard mode uses
/// `memBenchSpecArtifactVerbMap` (no location arg) to open pre-built artifact estates.
let memBenchSpecMootVerbMap = EndpointConfig.VerbMap(
    write: AriaV2Surface.fileMemory,
    query: AriaV2Surface.memorySearch,
    list: nil,
    constantArgs: ["location": "benchmarks/membench-spec"],
    resultFormat: .mootV2
)

/// Artifact VerbMap for membench-spec standard mode.
///
/// Omits the location constant arg: artifact estates are provenance-blind — the
/// location tag was applied during construction and must not be re-applied at
/// query time. Mirrors `loCoMoSpecVerbMap`.
private let memBenchSpecArtifactVerbMap = EndpointConfig.VerbMap(
    write: AriaV2Surface.fileMemory,
    query: AriaV2Surface.memorySearch,
    list: nil,
    constantArgs: [:],
    resultFormat: .mootV2
)

// MARK: - Run mode

/// Controls whether the runner executes the standard §3–§5 protocol or
/// the §6 step_cap capacity walk.
///
/// `.standard`: ingest all turns → settle → recall → answer → §3–§5 metrics.
/// `.stepCap`:  ingest one turn at a time; ask QA at every step after the
///              last evidence step; accumulate (tokenCount, correct) pairs (§6).
enum MemBenchSpecRunMode: Sendable, Equatable {
    /// Standard §3–§5 run: ingest + settle + recall + optional answer.
    case standard
    /// §6 step_cap run: per-step ingest and QA ask from the last evidence step.
    case stepCap
}

// MARK: - Run config

/// Configuration for one membench-spec run.
///
/// Mirrors `MemBenchRunConfig` but scoped to the spec lane's narrower requirements:
/// no estate cache, no parallel concurrency control (the spec runner is serial to
/// avoid cross-estate timing contamination in the §5 measurements), no batch seed path.
struct MemBenchSpecRunConfig: Sendable {
    /// Binary SHA-256 + mootx01 version + protocol version (STEP7_FINDINGS.md F1).
    /// Collected at the CLI layer; nil for library/test callers. Full machine
    /// profile is accuracy-lane-excluded per the 2026-08-18 doctrine.
    var runEnvironment: IdentityEnvironment? = nil
    /// Path to the mootx01 binary.
    let mootBinaryPath: String
    /// Root MemData directory (contains FirstAgent/ and ThirdAgent/).
    let dataDir: URL
    /// Agent perspective to load ("FirstAgent" or "ThirdAgent").
    let agent: String
    /// Category names to include. nil = all 7 LowLevel categories.
    let categories: [String]?
    /// Maximum number of items to run. nil = all loaded items.
    let limit: Int?
    /// Skip this many items from the seeded-shuffled item list.
    let offset: Int
    /// Seed for deterministic item shuffling.
    let seed: UInt64
    /// Directory to write the results report. nil = current working directory.
    let outDir: URL?
    /// Run label for the report filename and header.
    let runLabel: String
    /// Run serial (from --run-id or UTC timestamp). Ties the report to its params sidecar.
    let runSerial: String
    /// Encode-queue synchronisation strategy. Used ONLY in step_cap mode (fresh estate).
    /// Standard mode ignores this field (artifact estates need no encode barrier).
    /// Step_cap mode: forced to `.impatient` so each stored turn is immediately queryable.
    let encodeBarrier: EncodeBarrier
    /// At-rest posture for scratch estates. Used ONLY in step_cap mode.
    let scratchPosture: ScratchEstatePosture
    /// Storage backend shape for scratch estates. Used ONLY in step_cap mode.
    let shape: BenchShape
    // MARK: Artifact estate seam (standard mode only)
    /// Granularity of artifact estate allocation.
    /// `.unit`: one pre-built estate per item (catalog.json required).
    /// `.benchAggregate`: one shared estate for the whole run; parallelism forced to 1.
    var targetScale: ArtifactTargetScale = .unit
    /// Catalog.json path for the dataset (maps unit stems to estate directories).
    /// Required when targetScale == .unit.
    var catalogPath: URL? = nil
    /// Single estate directory. Required when targetScale == .benchAggregate.
    var estateDir: URL? = nil
    /// BYOAI answering command (§3, §7 row 1). nil = no predictions; answered_count: 0.
    ///
    /// The command reads the rendered §3 answer prompt on stdin and writes its
    /// response on stdout. Any shell command works (e.g. "claude -p" or "./my-model.sh").
    /// The runner parses the response via `MemBenchAnswerConstraint.parseAnswerChoice`.
    /// NO fallback heuristic applies when no answer command is provided.
    let answerCmd: String?
    /// Path to write answer-prompt JSONL dump for offline scoring.
    ///
    /// When set, the runner writes one JSONL line per QA item after completing
    /// each estate. Format:
    ///   header: {"type":"header","run_label":"…","agent":"…"}
    ///   qa rows: {"type":"qa","item_id":"…","category":"…","agent":"…",
    ///             "prompt":"…","ground_truth":"…","item_recall":0.0}
    ///
    /// Offline scoring: run the dump through an LLM, write answers as:
    ///   {"item_id":"…","answer":"A"} (one line per item)
    /// then pass to `consumeAnswersPath` in a subsequent run.
    let dumpAnswerInputsPath: URL?
    /// Path to read pre-scored answers for each item.
    ///
    /// Each line: {"item_id":"…","answer":"A"} where answer is A/B/C/D.
    /// Missing or unrecognised item_ids are silently skipped (scored as unanswered).
    let consumeAnswersPath: URL?
    /// Run mode: standard §3–§5, or §6 step_cap capacity walk.
    let runMode: MemBenchSpecRunMode
    /// Bucket boundaries (token counts) for the §6 capacity report.
    /// Default: [1000, 5000, 20000] — matches the three tier sizes in the paper.
    let capacityBucketBoundaries: [Int]
    /// When non-nil, only items whose itemID is in this set run.
    /// The full corpus is still loaded (corpus_digest unchanged); the filter is
    /// applied after the category filter and before the seeded shuffle.
    var unitIDs: Set<String>? = nil
    /// File path the unit-ID set was loaded from. Recorded in the report for
    /// subset identity per the testname-arm-serial discipline.
    var unitIDsPath: String? = nil
    /// When non-nil, passed as `"scoring"` in every moot_memory_search argument dict.
    /// When nil, the call is byte-identical to the pre-flag baseline (no "scoring" key).
    var scoringStrategy: String? = nil
    /// Directory containing per-unit seed JSON files (format: `{"records":[{"id":...},...]}`)
    /// used as the third fallback in `loadOrReconstructIDMap` when id-map.json is absent
    /// and sourceFile/chunkIndex reconstruction yields no rows.
    /// The file for a unit is `<seedUnitsDir>/<estateName>.json`.
    /// When nil, lineage derivation is skipped and the function throws if the first two
    /// sources both fail. CLI flag: --seed-units-dir.
    var seedUnitsDir: URL? = nil
    /// Guard probe sampling policy.
    /// `.oncePerLeg` (default): probe once per estate run — appropriate for fleet and aggregate
    /// paths where the binary is validated by the first query.
    /// `.perUnit`: probe on every item — useful for debugging aggregate-estate configurations
    /// where the daemon may return different results across queries.
    var guardSamplingPolicy: GuardSamplingPolicy = .oncePerLeg
}

// MARK: - Per-item outcome

/// The result of running the spec protocol against one MemBench item.
///
/// Carries §3 correctness, §4 recall, §5 timings, and optionally §6 capacity samples.
struct MemBenchSpecItemOutcome: Sendable {
    /// Category label (e.g. "simple", "noisy").
    let category: String
    /// Agent perspective label ("FirstAgent" or "ThirdAgent").
    let agent: String
    /// True when the answering model's letter equals the ground truth (§3).
    /// nil when no answer model is configured or consumption file had no entry.
    let answeredCorrect: Bool?
    /// §4 recall score ∈ [0, 1].
    let recallScore: Double
    /// Per-store wall-clock durations in seconds (§5). One per moot_file_memory call.
    let writeDurations: [Double]
    /// Wall-clock duration of the single moot_memory_search call, in seconds (§5).
    let readDuration: Double
    /// §6 step_cap samples: (tokenCount, correct) pairs. Empty in standard mode.
    let capacitySamples: [(tokenCount: Int, correct: Bool)]
}

/// Builds the artifact runner's UUID → turn-id manifest. MemBench lineage IDs
/// use `<family>/<category>/<section>/<tid>/<relationship-slug>`; older
/// id-maps may use the decimal turn id directly. Rows in neither form are
/// counted so callers can report incomplete mapping instead of hiding it.
func memBenchSpecManifest(from idMap: [String: String]) -> (manifest: [String: Int], unmappedCount: Int) {
    var manifest: [String: Int] = [:]
    var unmappedCount = 0
    for (seedID, uuid) in idMap {
        let components = seedID.split(separator: "/", omittingEmptySubsequences: false)
        let sid = Int(seedID) ?? (components.count == 5 ? Int(components[3]) : nil)
        if let sid {
            manifest[uuid.lowercased()] = sid
        } else {
            unmappedCount += 1
        }
    }
    return (manifest, unmappedCount)
}

// MARK: - Report

/// Codable report for the membench-spec lane.
///
/// Written to `membench-spec-<agent>-<serial>.json` via RecordWriter conventions.
/// The params sidecar shares the same serial: `membench-spec-<agent>-<serial>-params.json`.
struct MemBenchSpecReport: Sendable, Codable {
    // MARK: Run metadata (mirrors the existing membench report fields)
    /// Run label from config.
    let runLabel: String
    /// Port identifier: "swift".
    let port: String
    /// Agent perspective ("FirstAgent" or "ThirdAgent").
    let agent: String
    /// Seed used for item shuffling.
    let seed: UInt64
    /// Estate mode label: "artifact-unit", "artifact-bench-aggregate", or "step-cap-fresh".
    let estateMode: String
    /// Artifact target scale label: "unit", "bench-aggregate", or "step-cap".
    /// Mirrors `LoCoMoSpecReport.targetScale`.
    let targetScale: String
    /// Protocol mode: "standard" (§3–§5) or "step_cap" (§6). Emitted as
    /// "protocol_mode" — a test parameter, distinct from the retired
    /// machine-state run_mode field.
    let protocolMode: String

    // MARK: Aggregated results (§3 + §4)
    /// Overall accuracy and recall across all answered items.
    let overall: MemBenchSpecAggregateSlice
    /// Per-category breakdown (LowLevel categories in paper order, then HighLevel).
    let byCategory: [MemBenchSpecAggregateSlice]
    /// Per-perspective breakdown ("FirstAgent" and/or "ThirdAgent").
    let byPerspective: [MemBenchSpecAggregateSlice]

    // MARK: Answer coverage
    /// Number of items where an answer letter was produced (§3).
    /// 0 when no answer command was configured and no consume file was provided.
    let answeredCount: Int

    // MARK: §5 Efficiency
    /// Aggregated per-store wall-clock stats (§5).
    let writeEfficiency: MemBenchSpecEfficiencyStats
    /// Aggregated per-recall wall-clock stats (§5).
    let readEfficiency: MemBenchSpecEfficiencyStats

    // MARK: §6 Capacity (nil unless step_cap mode ran)
    /// Raw (tokenCount, correct) pairs from step_cap. nil in standard mode.
    let capacitySamples: [(tokenCount: Int, correct: Bool)]?
    /// Bucketed capacity accuracy. nil in standard mode.
    let capacityBuckets: [MemBenchSpecCapacityBucket]?

    // MARK: Item counts
    /// Number of items that ran to completion.
    let itemCount: Int

    // MARK: Identity block (accuracy lane — binary + protocol version only)
    /// Binary SHA-256 + mootx01 version + protocol version (STEP7_FINDINGS.md F1).
    /// Collected at the CLI layer; nil for library/test callers. Full machine
    /// profile is accuracy-lane-excluded per the 2026-08-18 doctrine.
    var runEnvironment: IdentityEnvironment? = nil
    // MARK: Unit-ID filter identity
    /// Path of the unit-ID filter file, or nil when no filter was applied.
    /// Distinguishes a subset measurement from a full-corpus run in the register.
    var unitIDsPath: String? = nil
    /// Number of items selected after the unit-ID filter (and seed-shuffle +
    /// offset + limit). Matches item_count in the report.
    var selectedCount: Int = 0
    /// Pending dreaming jobs in the estate at measurement start.
    /// 0 for unit-scale runs (no shared estate).
    var dreamPending: Int = 0
    /// Dreaming drain lane state at measurement start: 0 = idle or absent, 1 = draining.
    /// 0 for unit-scale runs (no shared estate).
    var dreamDraining: Int = 0
}

// MARK: - Report Codable support

// Codable conformance for tuples (capacitySamples field).
// Swift does not synthesize Codable for [(Int, Bool)], so we use a bridging type.

private struct CapacitySample: Codable {
    let tokenCount: Int
    let correct: Bool
}

extension MemBenchSpecReport {
    // Custom encode/decode for the capacitySamples tuple list.
    enum CodingKeys: String, CodingKey {
        case runLabel, port, agent, seed, estateMode, targetScale, protocolMode
        case overall, byCategory, byPerspective, answeredCount
        case writeEfficiency, readEfficiency
        case capacitySamples, capacityBuckets
        case itemCount
        case runEnvironment
        case unitIDsPath  = "unit_ids_path"
        case selectedCount = "selected_count"
        case dreamPending  = "dream_pending"
        case dreamDraining = "dream_draining"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(runLabel, forKey: .runLabel)
        try c.encode(port, forKey: .port)
        try c.encode(agent, forKey: .agent)
        try c.encode(seed, forKey: .seed)
        try c.encode(estateMode, forKey: .estateMode)
        try c.encode(targetScale, forKey: .targetScale)
        try c.encode(protocolMode, forKey: .protocolMode)
        try c.encode(overall, forKey: .overall)
        try c.encode(byCategory, forKey: .byCategory)
        try c.encode(byPerspective, forKey: .byPerspective)
        try c.encode(answeredCount, forKey: .answeredCount)
        try c.encode(writeEfficiency, forKey: .writeEfficiency)
        try c.encode(readEfficiency, forKey: .readEfficiency)
        if let samples = capacitySamples {
            let bridged = samples.map { CapacitySample(tokenCount: $0.tokenCount, correct: $0.correct) }
            try c.encode(bridged, forKey: .capacitySamples)
        } else {
            try c.encodeNil(forKey: .capacitySamples)
        }
        try c.encode(capacityBuckets, forKey: .capacityBuckets)
        try c.encode(itemCount, forKey: .itemCount)
        // Identity block (F1). encodeIfPresent: absent for library/test callers,
        // present on every CLI-driven run.
        try c.encodeIfPresent(runEnvironment, forKey: .runEnvironment)
        // Unit-ID filter identity: absent when no filter was applied.
        try c.encodeIfPresent(unitIDsPath, forKey: .unitIDsPath)
        try c.encode(selectedCount, forKey: .selectedCount)
        try c.encode(dreamPending, forKey: .dreamPending)
        try c.encode(dreamDraining, forKey: .dreamDraining)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        runLabel        = try c.decode(String.self, forKey: .runLabel)
        port            = try c.decode(String.self, forKey: .port)
        agent           = try c.decode(String.self, forKey: .agent)
        seed            = try c.decode(UInt64.self, forKey: .seed)
        estateMode      = try c.decode(String.self, forKey: .estateMode)
        targetScale     = try c.decode(String.self, forKey: .targetScale)
        protocolMode    = try c.decode(String.self, forKey: .protocolMode)
        overall         = try c.decode(MemBenchSpecAggregateSlice.self, forKey: .overall)
        byCategory      = try c.decode([MemBenchSpecAggregateSlice].self, forKey: .byCategory)
        byPerspective   = try c.decode([MemBenchSpecAggregateSlice].self, forKey: .byPerspective)
        answeredCount   = try c.decode(Int.self, forKey: .answeredCount)
        writeEfficiency = try c.decode(MemBenchSpecEfficiencyStats.self, forKey: .writeEfficiency)
        readEfficiency  = try c.decode(MemBenchSpecEfficiencyStats.self, forKey: .readEfficiency)
        if let bridged = try c.decodeIfPresent([CapacitySample].self, forKey: .capacitySamples) {
            capacitySamples = bridged.map { (tokenCount: $0.tokenCount, correct: $0.correct) }
        } else {
            capacitySamples = nil
        }
        capacityBuckets = try c.decodeIfPresent([MemBenchSpecCapacityBucket].self, forKey: .capacityBuckets)
        itemCount       = try c.decode(Int.self, forKey: .itemCount)
        runEnvironment  = try c.decodeIfPresent(IdentityEnvironment.self, forKey: .runEnvironment)
        unitIDsPath     = try c.decodeIfPresent(String.self, forKey: .unitIDsPath)
        selectedCount   = (try? c.decode(Int.self, forKey: .selectedCount)) ?? 0
        dreamPending    = (try? c.decode(Int.self, forKey: .dreamPending))  ?? 0
        dreamDraining   = (try? c.decode(Int.self, forKey: .dreamDraining)) ?? 0
    }
}

// MARK: - Codable for MemBenchSpecAggregateSlice and related types

extension MemBenchSpecAggregateSlice: Codable {
    enum CodingKeys: String, CodingKey {
        case label, count, accuracy, meanRecall
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encode(count, forKey: .count)
        try c.encode(accuracy, forKey: .accuracy)
        try c.encode(meanRecall, forKey: .meanRecall)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label     = try c.decode(String.self, forKey: .label)
        count     = try c.decode(Int.self, forKey: .count)
        accuracy  = try c.decode(Double.self, forKey: .accuracy)
        meanRecall = try c.decode(Double.self, forKey: .meanRecall)
    }
}

extension MemBenchSpecEfficiencyStats: Codable {
    enum CodingKeys: String, CodingKey {
        case count, mean, p50, p95
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(count, forKey: .count)
        try c.encode(mean, forKey: .mean)
        try c.encode(p50, forKey: .p50)
        try c.encode(p95, forKey: .p95)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        count = try c.decode(Int.self, forKey: .count)
        mean  = try c.decode(Double.self, forKey: .mean)
        p50   = try c.decode(Double.self, forKey: .p50)
        p95   = try c.decode(Double.self, forKey: .p95)
    }
}

extension MemBenchSpecCapacityBucket: Codable {
    enum CodingKeys: String, CodingKey {
        case tokenLow, tokenHigh, count, accuracy
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tokenLow, forKey: .tokenLow)
        try c.encodeIfPresent(tokenHigh, forKey: .tokenHigh)
        try c.encode(count, forKey: .count)
        try c.encode(accuracy, forKey: .accuracy)
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokenLow  = try c.decode(Int.self, forKey: .tokenLow)
        tokenHigh = try c.decodeIfPresent(Int.self, forKey: .tokenHigh)
        count     = try c.decode(Int.self, forKey: .count)
        accuracy  = try c.decode(Double.self, forKey: .accuracy)
    }
}

// MARK: - Offline answer consume

/// Loads a pre-scored answer file written by an offline batch run.
///
/// Each line must be `{"item_id":"…","answer":"A"}` where answer is A/B/C/D.
/// Lines that fail to parse or carry an invalid letter are silently skipped.
///
/// - Parameter url: Path to the answers JSONL file.
/// - Returns: Dictionary from item_id to answer letter.
/// - Throws: `MCPError` when the file cannot be read.
func loadConsumedAnswers(_ url: URL) throws -> [String: String] {
    guard let data = FileManager.default.contents(atPath: url.path),
          let content = String(data: data, encoding: .utf8) else {
        throw MCPError(description:
            "membench-spec: cannot read consume-answers file at '\(url.path)'")
    }
    var result: [String: String] = [:]
    for line in content.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let lineData = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let itemID = obj["item_id"] as? String,
              let answer = obj["answer"] as? String,
              answer == "A" || answer == "B" || answer == "C" || answer == "D" else {
            continue
        }
        result[itemID] = answer
    }
    return result
}

// MARK: - Answer dump writer

/// Wraps a JSONL dump file for offline answer scoring.
///
/// Write the header first, then one row per QA item using `writeRow`.
/// The dump format matches the `judge-batch` subcommand's input format closely,
/// with item_id substituting for question_id (membench items are keyed by item_id).
final class MemBenchSpecAnswerDump: @unchecked Sendable {
    private let fd: Int32
    private let path: String

    init(url: URL, runLabel: String, agent: String) throws {
        let p = url.path
        let f = open(p, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if f < 0 {
            throw MCPError(description:
                "membench-spec dump: cannot create '\(p)': \(String(cString: strerror(errno)))")
        }
        self.fd = f
        self.path = p
        // Write header line. The "benchmark" field lets answer-batch dispatch
        // on the protocol without inspecting any other record shape.
        // memory_texts in membench-spec come directly from moot_memory_search —
        // no moot_memory_get call — so hydration_tier is a fixed annotation
        // recording the source path rather than a configurable depth tier.
        let header: [String: Any] = [
            "type": "header",
            "benchmark": "membench-spec",
            "run_label": runLabel,
            "agent": agent,
            "hydration_tier": "search-result",
        ]
        try writeJSONLine(header)
    }

    deinit { close(fd) }

    /// Writes one QA item's rendered answer prompt to the dump file.
    ///
    /// - Parameters:
    ///   - itemID: The item's synthetic identifier.
    ///   - category: The item's category label.
    ///   - agent: "FirstAgent" or "ThirdAgent".
    ///   - prompt: The fully-rendered §3 answer prompt (byte-exact per spec).
    ///   - groundTruth: Correct answer letter (A/B/C/D) for offline grading.
    ///   - recallScore: §4 score at the time of the dump (for audit).
    ///   - memoryTexts: Individual recalled text blocks in retrieval order, before
    ///     joining with "\n". Stored alongside the rendered prompt for scoring.
    ///   - retrievedDrawerIDs: Estate drawer UUIDs in retrieval order, one per
    ///     hit. moot_memory_search renders every hit into ONE text block, so
    ///     memoryTexts usually holds a single block covering all of these ids.
    ///     Recorded for artifact-recall scoring.
    func writeRow(
        itemID: String,
        category: String,
        agent: String,
        prompt: String,
        groundTruth: String,
        recallScore: Double,
        memoryTexts: [String],
        retrievedDrawerIDs: [String]
    ) throws {
        let row: [String: Any] = [
            "type": "qa",
            "item_id": itemID,
            "category": category,
            "agent": agent,
            "prompt": prompt,
            "ground_truth": groundTruth,
            "item_recall": recallScore,
            // The search's text blocks as returned: one block for every hit in
            // practice, or one block per drawer when a server renders hits separately.
            "memory_texts": memoryTexts,
            // Estate drawer UUIDs in retrieval order; recorded for artifact-recall scoring.
            "retrieved_drawer_ids": retrievedDrawerIDs,
        ]
        try writeJSONLine(row)
    }

    private func writeJSONLine(_ obj: [String: Any]) throws {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            throw MCPError(description: "membench-spec dump: JSON serialisation failed")
        }
        let line = str + "\n"
        let bytes = Array(line.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw MCPError(description:
                    "membench-spec dump: write failed: \(String(cString: strerror(errno)))")
            }
            offset += written
        }
    }
}

// MARK: - Scratch estate for the spec lane

/// Creates a fresh, hardened scratch directory for the membench-spec lane.
///
/// Uses the `/tmp/membench-spec-` prefix (distinct from the existing membench
/// lane's `/tmp/membench-bench-` prefix) so teardown guards can distinguish
/// the two lanes' estates.
///
/// Mirrors `memBenchScratchDir(posture:)` with a different prefix.
///
/// - Parameter posture: At-rest posture for the estate.
/// - Returns: Canonical URL of the created directory.
/// - Throws: `MCPError` on creation failure, symlink check failure, or prefix escape.
func memBenchSpecScratchDir(posture: ScratchEstatePosture) throws -> URL {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    let path = "/tmp/membench-spec-\(suffix)"
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    } catch {
        throw MCPError(description:
            "memBenchSpecScratchDir: could not create \(path): \(error)")
    }
    // Reject symlinks — mirrors memBenchScratchDir(posture:) symlink guard.
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
        throw MCPError(description:
            "memBenchSpecScratchDir: SAFETY: '\(path)' is a symlink — "
            + "refusing to use as scratch estate")
    }
    let canonical = url.resolvingSymlinksInPath()
    let canonicalPath = canonical.path
    guard canonicalPath.hasPrefix("/tmp/membench-spec-") ||
          canonicalPath.hasPrefix("/private/tmp/membench-spec-") else {
        throw MCPError(description:
            "memBenchSpecScratchDir: SAFETY: canonicalized path '\(canonicalPath)' "
            + "escapes /tmp/membench-spec-")
    }
    return canonical
}

/// Tears down a scratch estate created by `memBenchSpecScratchDir`.
/// Refuses any path without the `/tmp/membench-spec-` prefix.
///
/// Mirrors `memBenchGuardedTeardown(_:)` with the spec prefix.
func memBenchSpecGuardedTeardown(_ url: URL) throws {
    let path = url.path
    guard path.hasPrefix("/tmp/membench-spec-") ||
          path.hasPrefix("/private/tmp/membench-spec-") else {
        throw MCPError(description:
            "SAFETY: memBenchSpecGuardedTeardown refused '\(path)' — "
            + "path must have /tmp/membench-spec- prefix")
    }
    if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil {
        throw MCPError(description:
            "SAFETY: memBenchSpecGuardedTeardown refused symlink '\(path)'")
    }
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        FileHandle.standardError.write(Data(
            "[membench-spec] teardown warning: could not remove \(path): \(error)\n".utf8))
    }
}

// MARK: - EndpointConfig builders

/// Builds an EndpointConfig for mootx01 pointing at a membench-spec scratch estate.
///
/// Used ONLY in step_cap mode. Standard mode uses `memBenchSpecArtifactEndpointConfig`.
/// Mirrors `memBenchEndpointConfig(scratchDir:mootBinaryPath:posture:shape:)` but
/// uses `memBenchSpecMootVerbMap` (location: "benchmarks/membench-spec").
func memBenchSpecEndpointConfig(
    scratchDir: URL,
    mootBinaryPath: String,
    posture: ScratchEstatePosture,
    shape: BenchShape
) throws -> EndpointConfig {
    let command = try mootServeCommand(
        binary: mootBinaryPath, scratchDir: scratchDir, inMemory: shape == .ram,
        environment: ["MOOTX01_VAULT=1", "MOOTX01_SUBJECT_RIDER=0"])

    let endpoint = EndpointConfig(
        name: "mootx01-membench-spec",
        transport: .stdio(command: command),
        auth: nil,
        verbMap: memBenchSpecMootVerbMap,
        role: .target
    )
    try assertScratchBackend(endpoint, requirement: mootScratchRequirement)
    return endpoint
}

/// Builds an EndpointConfig pointing at a pre-built artifact estate for standard mode.
///
/// Opens the estate read-only (MOOTX01_SUBJECT_RIDER=0); no ingest phase.
/// Uses `memBenchSpecArtifactVerbMap` (no location arg). Mirrors `loCoMoSpecEndpointConfig`.
///
/// - Parameters:
///   - estateDir: Pre-built estate root directory.
///   - mootBinaryPath: Path to the mootx01 binary.
/// - Returns: Configured EndpointConfig (no assertScratchBackend — not a scratch estate).
private func memBenchSpecArtifactEndpointConfig(
    estateDir: URL,
    mootBinaryPath: String
) throws -> EndpointConfig {
    let command =
        try mootServeCommand(binary: mootBinaryPath, scratchDir: estateDir, environment: ["MOOTX01_FROZEN=1", "MOOTX01_SUBJECT_RIDER=0"])
    return EndpointConfig(
        name: "mootx01-membench-spec",
        transport: .stdio(command: command),
        auth: nil,
        verbMap: memBenchSpecArtifactVerbMap,
        role: .target
    )
}

/// Derives the fleet unit stem for a membench-spec item.
///
/// Maps `"<family>/<category>/<section>/<tid>"` → `"<family>__<category>__<section>__<tid>"`.
/// The item.itemID format is `"<family>/<category>/<section>/<tid>"` (four components).
///
/// Example: `"FirstAgent/simple/roles/0"` → `"FirstAgent__simple__roles__0"`.
private func memBenchSpecUnitStem(itemID: String) -> String {
    itemID.replacingOccurrences(of: "/", with: "__")
}

// MARK: - Main entry point

/// Runs the membench-spec lane against a loaded corpus.
///
/// Implements MEMBENCH_OFFICIAL_PROTOCOL.md §2–§5 (standard mode) or §6 (step_cap mode).
///
/// Standard mode per-item strategy (artifact estate):
///   1. Resolve estate dir from catalog/<unit_stem> or estateDir.
///   2. Load id-map (seedID → drawerUUID); build UUID → sid reverse map.
///   3. Open estate read-only (no ingest or settle).
///   4. Issue the recall query `recallQuery(question:time:)` (§3–4).
///   5. Map retrieved UUIDs to sids via reverse id-map.
///   6. Compute §4 get_recall against target_step_id global sids.
///   7. Optionally obtain an answer letter via the BYOAI seam (§3).
///   8. Write the report via RecordWriter conventions.
///
/// Step_cap mode: keeps fresh-estate-per-item (see `runOneMemBenchSpecItemStepCap`).
///
/// Returns per-item outcomes and the aggregated report. The report is also
/// written to disk when `config.outDir` is set.
///
/// §7 row 6 resolved: `memBenchCountTokens` counts with the vendored
/// cl100k_base tokenizer (byte-exact tiktoken). See `MemBenchSpecProtocol.swift`.
///
/// - Parameters:
///   - items: Loaded corpus items (from `loadMemBenchCorpus`).
///   - config: Run configuration.
/// - Returns: Per-item outcomes and the aggregated report.
/// - Throws: `MCPError` on estate provisioning, MCP communication, or I/O errors.
func runMemBenchSpec(
    items: [MemBenchItem],
    config: MemBenchSpecRunConfig
) async throws -> (outcomes: [MemBenchSpecItemOutcome], report: MemBenchSpecReport) {

    // Load consumed answers (offline batch path) before running any estates.
    // An empty dictionary is safe: missing keys produce nil answers.
    let consumedAnswers: [String: String]
    if let consumePath = config.consumeAnswersPath {
        consumedAnswers = try loadConsumedAnswers(consumePath)
    } else {
        consumedAnswers = [:]
    }

    // Open the dump file if configured. The dump writer is shared across all items.
    // Created once here; nil when no dump path is configured.
    let dumpWriter: MemBenchSpecAnswerDump?
    if let dumpPath = config.dumpAnswerInputsPath {
        dumpWriter = try MemBenchSpecAnswerDump(
            url: dumpPath,
            runLabel: config.runLabel,
            agent: config.agent
        )
    } else {
        dumpWriter = nil
    }

    // Category filter → unit-ID filter → seeded shuffle → offset + limit.
    let filtered: [MemBenchItem]
    if let cats = config.categories {
        filtered = items.filter { cats.contains($0.category) }
    } else {
        filtered = items
    }
    // Unit-ID filter (before shuffle: same ids file → same units regardless of seed).
    // Applied after the category filter so the category constraint remains authoritative.
    let unitFiltered = try filterUnits(
        filtered, ids: config.unitIDs, id: { $0.itemID }, lane: "membench-spec")
    var rng = SplitMix64(seed: config.seed)
    var shuffled = unitFiltered
    for i in stride(from: shuffled.count - 1, through: 1, by: -1) {
        let j = rng.upTo(i + 1)
        shuffled.swapAt(i, j)
    }
    let afterOffset = Array(shuffled.dropFirst(config.offset))
    let selected: [MemBenchItem] = config.limit.map { Array(afterOffset.prefix($0)) } ?? afterOffset

    // One guard sampler for the leg (actor — probes on the first item, caches thereafter).
    let guardSampler = LegGuardSampler(policy: config.guardSamplingPolicy)

    // Dream drain status at run start (bench-aggregate: one lightweight probe on the
    // estate before the per-item loop; unit-scale: no shared estate, defaults to idle).
    // Opens a temporary client for the probe and disconnects immediately — the per-item
    // loop opens its own connections for each item's measurement.
    let dreamStatus: DreamStatus
    if config.targetScale != .unit, let dir = config.estateDir {
        let probeEndpoint = try memBenchSpecArtifactEndpointConfig(
            estateDir: dir, mootBinaryPath: config.mootBinaryPath)
        let probeClient = MCPClient(endpoint: probeEndpoint, responseDeadline: 30)
        do {
            try await probeClient.connect()
            dreamStatus = await readDrainStatusOnce(client: probeClient)
            Task { await probeClient.disconnect() }
        } catch {
            // If the probe fails, continue with defaults — dream status is informational.
            FileHandle.standardError.write(Data(
                "[membench-spec] dream-status probe failed: \(error)\n".utf8))
            dreamStatus = DreamStatus(pending: 0, settled: true)
        }
    } else {
        dreamStatus = DreamStatus(pending: 0, settled: true)
    }

    // Per-item execution: serial to avoid cross-estate §5 timing contamination.
    var outcomes: [MemBenchSpecItemOutcome] = []
    outcomes.reserveCapacity(selected.count)

    for (itemIdx, item) in selected.enumerated() {
        FileHandle.standardError.write(Data(
            "[membench-spec] item=\(item.itemID) (#\(itemIdx + 1)/\(selected.count))\n".utf8))

        let outcome: MemBenchSpecItemOutcome
        switch config.runMode {
        case .standard:
            outcome = try await runOneMemBenchSpecItem(
                item: item,
                config: config,
                consumedAnswers: consumedAnswers,
                dumpWriter: dumpWriter,
                guardSampler: guardSampler
            )
        case .stepCap:
            outcome = try await runOneMemBenchSpecItemStepCap(
                item: item,
                config: config,
                consumedAnswers: consumedAnswers,
                guardSampler: guardSampler
            )
        }
        outcomes.append(outcome)
    }

    // §4: build MemBenchSpecItemScore list for aggregation.
    // Items with nil `answeredCorrect` contribute to recall but not accuracy.
    let scores: [MemBenchSpecItemScore] = outcomes.map { o in
        MemBenchSpecItemScore(
            category: o.category,
            agent: o.agent,
            // When unanswered, treat correct: false so the aggregate is not inflated.
            // This is conservative: only `answeredCount` reflects the true answer coverage.
            correct: o.answeredCorrect ?? false,
            recall: o.recallScore
        )
    }
    let aggregation = membenchSpecAggregate(scores)

    // §5: aggregate wall-clock stats across all items.
    let allWriteDurations = outcomes.flatMap(\.writeDurations)
    let allReadDurations = outcomes.map(\.readDuration)
    let writeEff = membenchSpecEfficiencyStats(durations: allWriteDurations)
    let readEff  = membenchSpecEfficiencyStats(durations: allReadDurations)

    // §6: collect capacity samples (non-empty only in step_cap mode).
    let allCapSamples = outcomes.flatMap(\.capacitySamples)
    let capSamples: [(tokenCount: Int, correct: Bool)]? =
        config.runMode == .stepCap ? allCapSamples : nil
    let capBuckets: [MemBenchSpecCapacityBucket]? = capSamples.map {
        membenchSpecCapacityBuckets(
            samples: $0,
            bucketBoundaries: config.capacityBucketBoundaries
        )
    }

    let answeredCount = outcomes.filter { $0.answeredCorrect != nil }.count

    let isStepCap = config.runMode == .stepCap
    let reportEstateMode: String
    let reportTargetScale: String
    if isStepCap {
        // step_cap keeps fresh-estate-per-item; no artifact seam.
        reportEstateMode  = "step-cap-fresh"
        reportTargetScale = "step-cap"
    } else {
        switch config.targetScale {
        case .unit:
            reportEstateMode  = "artifact-unit"
            reportTargetScale = "unit"
        case .benchAggregate:
            reportEstateMode  = "artifact-bench-aggregate"
            reportTargetScale = "bench-aggregate"
        case .completeAggregate:
            reportEstateMode  = "artifact-complete-aggregate"
            reportTargetScale = "complete-aggregate"
        }
    }

    var report = MemBenchSpecReport(
        runLabel: config.runLabel,
        port: "swift",
        agent: config.agent,
        seed: config.seed,
        estateMode: reportEstateMode,
        targetScale: reportTargetScale,
        protocolMode: config.runMode == .standard ? "standard" : "step_cap",
        overall: aggregation.overall,
        byCategory: aggregation.byCategory,
        byPerspective: aggregation.byPerspective,
        answeredCount: answeredCount,
        writeEfficiency: writeEff,
        readEfficiency: readEff,
        capacitySamples: capSamples,
        capacityBuckets: capBuckets,
        itemCount: outcomes.count,
        // §6 required report fields ride in from the CLI layer (F1).
        runEnvironment: config.runEnvironment
    )
    // Unit-ID filter identity (subset measurement vs. full-corpus run).
    report.unitIDsPath   = config.unitIDsPath
    report.selectedCount = outcomes.count
    report.dreamPending  = dreamStatus.pending
    report.dreamDraining = dreamStatus.settled ? 0 : 1

    // Write report + params sidecar via RecordWriter conventions.
    // Record name stem: 'membench-spec-<agent>-<serial>'
    // (§7 note: agent is the arm discriminator — FirstAgent and ThirdAgent runs
    // must not share a record name; the agent label satisfies RecordWriter's
    // arm requirement directly).
    if let outDir = config.outDir {
        let reportName = recordFilename(
            test: "membench-spec",
            arm: config.agent,
            serial: config.runSerial
        )
        let reportURL = outDir.appendingPathComponent(reportName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Snake_case on disk: the report's CodingKeys are camelCase Swift names;
        // without this strategy the Swift report diverged from the Rust twin's
        // serde snake_case keys (cross-port parity defect, STEP7_FINDINGS.md F4).
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let reportData = try encoder.encode(report)
        try writeRecordNeverOverwrite(reportData, to: reportURL)

        // Params sidecar.
        let paramsName = recordFilename(
            test: "membench-spec",
            arm: config.agent,
            serial: config.runSerial,
            suffix: "params"
        )
        let paramsURL = outDir.appendingPathComponent(paramsName)
        var params: [String: Any] = [
            "run_label": config.runLabel,
            "port": "swift",
            "agent": config.agent,
            "seed": config.seed,
            "categories": config.categories ?? membenchSpecCategoryLabels,
            "limit": config.limit as Any,
            "offset": config.offset,
            "target_scale": reportTargetScale,
            "estate_mode": reportEstateMode,
            "protocol_mode": config.runMode == .standard ? "standard" : "step_cap",
            "answer_cmd_present": config.answerCmd != nil,
            "dump_answer_inputs_present": config.dumpAnswerInputsPath != nil,
            "consume_answers_present": config.consumeAnswersPath != nil,
        ]
        // step_cap mode still tracks encode barrier and shape (fresh estate).
        if isStepCap {
            params["encode_barrier"] = config.encodeBarrier.reportLabel
            params["shape"]          = config.shape.rawValue
        }
        // Scoring strategy: record "default" when omitted so every sidecar is self-describing.
        params["scoring"] = config.scoringStrategy ?? "default"
        let paramsData = try JSONSerialization.data(
            withJSONObject: params,
            options: [.prettyPrinted, .sortedKeys]
        )
        try writeRecordNeverOverwrite(paramsData, to: paramsURL)
    }

    return (outcomes, report)
}

// MARK: - Per-item runner (standard mode — artifact estate)

/// Runs one membench-spec item against a pre-built artifact estate.
///
/// Standard mode (§3–§5 protocol) using an artifact estate:
///   1. Resolve the estate directory from catalog/<unit_stem> or estateDir.
///   2. Load the id-map (seedID → drawerUUID). The seedID encodes the turn sid
///      in its last path component (e.g. "FirstAgent/simple/roles/0/42").
///   3. Open a read-only endpoint (MOOTX01_SUBJECT_RIDER=0) — no ingest or settle.
///   4. DegeneracyGuard probe.
///   5. Issue the recall query `recallQuery(question:time:)`.
///   6. Map retrieved UUIDs → sids via the reverse id-map.
///   7. Compute §4 get_recall, optionally obtain an answer letter (BYOAI seam).
///
/// - Parameters:
///   - item: The corpus item to run.
///   - config: Run configuration (shared across all items in the leg).
///   - consumedAnswers: Pre-loaded offline answers keyed by item_id.
///   - dumpWriter: Optional shared dump file for offline answer-scoring.
///   - guardSampler: Shared leg-level DegeneracyGuard sampler (actor).
/// - Returns: The per-item outcome with §3–§5 metrics.
/// - Throws: `MCPError` on estate open or MCP errors.
func runOneMemBenchSpecItem(
    item: MemBenchItem,
    config: MemBenchSpecRunConfig,
    consumedAnswers: [String: String],
    dumpWriter: MemBenchSpecAnswerDump?,
    guardSampler: LegGuardSampler
) async throws -> MemBenchSpecItemOutcome {

    // Resolve the estate directory for this unit.
    let estateDir: URL
    switch config.targetScale {
    case .unit:
        guard let catalogPath = config.catalogPath else {
            throw MCPError(description:
                "membench-spec: targetScale=.unit requires --catalog to be set")
        }
        let stem = memBenchSpecUnitStem(itemID: item.itemID)
        // The catalog resolver checks existence and applies the containment guard.
        estateDir = try artifactUnitEstateDir(catalogPath: catalogPath, id: stem)
    case .benchAggregate, .completeAggregate:
        guard let dir = config.estateDir else {
            throw MCPError(description:
                "membench-spec: targetScale=.\(config.targetScale) requires estateDir to be set")
        }
        estateDir = dir
    }

    // Load the id-map (seedID → drawerUUID).
    // seedID format: "<family>/<category>/<section>/<tid>/<sidStr>"
    // where <sidStr> is the decimal turn.sid used during artifact construction.
    // Three-source fallback (priority order):
    //   1. id-map.json when present.
    //   2. drawers.sourceFile + chunkIndex (standard membench seeding).
    //   3. drawers.lineageID matched against FNV-1a-128(seedRecordID) from the
    //      seed unit file in config.seedUnitsDir (JSON-import-lane estates).
    let idMap = try loadOrReconstructIDMap(estateDir: estateDir, seedUnitsDir: config.seedUnitsDir)
    // Build reverse map: UUID.lowercased() → turn sid. Lineage-derived keys
    // carry the tid as component 4; older id-maps may use a bare numeric id.
    let mapping = memBenchSpecManifest(from: idMap)
    let uuidToSid = mapping.manifest
    if mapping.unmappedCount > 0 {
        fputs("[membench-spec] \(mapping.unmappedCount) id-map row(s) could not be mapped to a turn id\n", stderr)
    }

    let endpoint = try memBenchSpecArtifactEndpointConfig(
        estateDir: estateDir,
        mootBinaryPath: config.mootBinaryPath
    )
    let client = MCPClient(endpoint: endpoint, responseDeadline: 600)
    try await client.connect()
    defer { Task { await client.disconnect() } }

    // No ingest or settle phase: the artifact estate is already indexed.
    // writeDurations is empty — §5 write timing is not applicable to artifact mode.
    let writeDurations: [Double] = []

    // DegeneracyGuard: once per leg (sampler caches the first verdict).
    _ = await guardSampler.probe {
        await probeMCPClient(client, verbMap: memBenchSpecArtifactVerbMap, name: "mootx01-membench-spec")
    }

    // §3–4: Recall query uses `question (time)` format.
    let query = recallQuery(question: item.qa.question, time: item.qa.time)
    var queryArgs = AriaV2Surface.memorySearchArgs(verbMap: memBenchSpecArtifactVerbMap, query: query)
    // When --scoring is given, pass it to the estate; when omitted, the call is
    // byte-identical to the pre-flag baseline (no "scoring" key in the dict).
    if let s = config.scoringStrategy { queryArgs["scoring"] = .string(s) }

    // §5: wall-clock timer around the moot_memory_search call.
    let readStart = Date()
    let queryResult = try await client.callTool(
        memBenchSpecArtifactVerbMap.query,
        arguments: queryArgs,
        format: memBenchSpecArtifactVerbMap.resultFormat
    )
    let readDuration = Date().timeIntervalSince(readStart)

    // The recalled memory context string (raw payload) is the §3 answer prompt's
    // `{memory}` field. Join all text blocks exactly as the Python `memory.recall()`
    // returns the memory context string.
    let rawPayload = queryResult.textBlocks.joined(separator: "\n")

    // §4: Map retrieved UUIDs → sids via the reverse id-map.
    // UUIDs not found in the reverse map (drawers from other items) are dropped.
    let retrievedStepIDs: [Int]? = queryResult.orderedIDs.isEmpty
        ? nil
        : queryResult.orderedIDs.compactMap { uuidToSid[$0.lowercased()] }

    // §4: Target step ids = QA's target_step_id global sids.
    // §4 shape note: "the target flattens to its global sid (element 0)".
    let targetStepIDs: [Int] = item.qa.targetStepID.map { $0.globalSid }

    // §4: get_recall verbatim.
    let recallScore = membenchSpecGetRecall(
        retrievedStepIDs: retrievedStepIDs,
        targetStepIDs: targetStepIDs
    )

    // §3: Answer production — three exclusive paths:
    //   1. consume path: read pre-scored letter for this item_id.
    //   2. live path: send the rendered prompt to the external --answer-cmd.
    //   3. no prediction: neither consume nor live configured.
    //
    // NO fallback heuristic (§7 row 1): if no model is available, there is
    // no prediction. `answered_count: 0` is the correct report value.
    var answeredCorrect: Bool? = nil

    let perspective: MemBenchPerspective =
        item.agent == "FirstAgent" ? .firstAgent : .thirdAgent

    if let consumedLetter = consumedAnswers[item.itemID] {
        // Consume path: pre-scored offline answer.
        // §3 correctness: exact string equality.
        answeredCorrect = membenchSpecAnswerCorrect(
            response: consumedLetter,
            groundTruth: item.qa.groundTruth
        )
    } else if let cmd = config.answerCmd {
        // Live path: send the §3 answer prompt to the BYOAI subprocess.
        let prompt = answerPrompt(
            perspective: perspective,
            memory: rawPayload,
            question: item.qa.question,
            time: item.qa.time,
            choices: item.qa.choices
        )
        // Use `lmeRunJudge` as the subprocess seam: it runs any shell command,
        // sends the prompt on stdin, returns trimmed stdout. The same function
        // drives the LME judge, providing a common bounded subprocess lifecycle
        // (TERM→KILL escalation, post-exit pipe drain).
        if let rawResponse = try? lmeRunJudge(cmd: cmd, prompt: prompt),
           let letter = MemBenchAnswerConstraint.parseAnswerChoice(from: rawResponse) {
            // §3 correctness: exact string equality on the parsed letter.
            answeredCorrect = membenchSpecAnswerCorrect(
                response: letter,
                groundTruth: item.qa.groundTruth
            )
        }
        // If the subprocess failed or returned an unparseable response, answeredCorrect
        // remains nil — that item does not contribute to answered_count.
    }

    // Dump path (orthogonal to live path — can dump AND answer live).
    // Write the rendered prompt to the dump file for offline scoring.
    if let dump = dumpWriter {
        let prompt = answerPrompt(
            perspective: perspective,
            memory: rawPayload,
            question: item.qa.question,
            time: item.qa.time,
            choices: item.qa.choices
        )
        try dump.writeRow(
            itemID: item.itemID,
            category: item.category,
            agent: item.agent,
            prompt: prompt,
            groundTruth: item.qa.groundTruth,
            recallScore: recallScore,
            // One text per ordered UUID: items is already one entry per search
            // result (parsed by parseMootText / parseJSONObjects), so this aligns
            // memory_texts with retrieved_drawer_ids even when moot_memory_search
            // returns all N results in a single raw text block.
            memoryTexts: queryResult.items.map { $0.content ?? "" },
            retrievedDrawerIDs: queryResult.orderedIDs
        )
    }

    return MemBenchSpecItemOutcome(
        category: item.category,
        agent: item.agent,
        answeredCorrect: answeredCorrect,
        recallScore: recallScore,
        writeDurations: writeDurations,
        readDuration: readDuration,
        capacitySamples: []
    )
}

// MARK: - Per-item runner (§6 step_cap mode)

/// Runs one membench-spec item in §6 step_cap capacity mode.
///
/// §6 protocol (verbatim):
///   Messages ingest as §2 while a running token count accumulates (official
///   tokenizer: tiktoken cl100k_base, counting user + agent strings per message;
///   our seam delegates to `memBenchCountTokens` — see §7 row 6).
///   From the step AFTER the last evidence step (`target_step_id[-1]`), the QA
///   is asked at EVERY subsequent step; each answer yields `(token_count_at_ask,
///   correct)`. The item terminates at the end of `message_list`.
///
/// Implementation notes:
/// - Uses `impatient: true` per-turn so each stored item is immediately queryable
///   at the next recall call, regardless of `config.encodeBarrier`.
/// - No settle (dream/reindex) between steps: we measure capacity under live
///   memory state, matching the Python env's per-step recall semantics.
/// - A full settle IS applied BEFORE the first ask so that encoding accumulated
///   during the evidence-ingest phase is complete.
///
/// §7 row 6: cl100k_base ARTIFACT DECISION (operator).
///   `memBenchCountTokens` delegates to `lmeEstimateTokens` (UTF-8 / 4) until
///   the cl100k vocabulary artifact is approved. Token counts from this function
///   are estimates and will differ from cl100k_base counts for non-ASCII text.
func runOneMemBenchSpecItemStepCap(
    item: MemBenchItem,
    config: MemBenchSpecRunConfig,
    consumedAnswers: [String: String],
    guardSampler: LegGuardSampler
) async throws -> MemBenchSpecItemOutcome {

    // §6: last evidence step = target_step_id[-1]'s global sid.
    // Per §4 shape note: "step_cap uses target_step_id[-1]'s sid as the last-evidence step."
    let lastEvidenceSid: Int? = item.qa.targetStepID.last?.globalSid

    let scratchDir = try memBenchSpecScratchDir(posture: config.scratchPosture)
    let endpoint = try memBenchSpecEndpointConfig(
        scratchDir: scratchDir,
        mootBinaryPath: config.mootBinaryPath,
        posture: config.scratchPosture,
        shape: config.shape
    )
    let client = MCPClient(endpoint: endpoint, responseDeadline: 600)
    try await client.connect()

    var unitCompleted = false
    defer {
        Task { await client.disconnect() }
        if unitCompleted {
            try? retireScratchEstate(
                scratchDir,
                expectPlaintext: config.scratchPosture == .plaintextTransient,
                teardown: memBenchSpecGuardedTeardown
            )
        } else {
            keepScratchEstateOnFailure(scratchDir, lane: "membench-spec-stepcap")
        }
    }

    // §6: flatten all turns across all sessions in message_list order.
    let allTurns = item.sessions.flatMap(\.turns)

    var manifest: [String: Int] = [:]
    var writeDurations: [Double] = []
    var readDuration: Double = 0.0
    var capacitySamples: [(tokenCount: Int, correct: Bool)] = []
    var retrievedStepIDs: [Int] = []
    let targetStepIDs: [Int] = item.qa.targetStepID.map { $0.globalSid }

    // §6: running token count — accumulates tokens for user + agent strings per turn.
    var accumulatedTokens: Int = 0
    // Track whether a settle has been issued for turns before the ask range.
    var settledUpToEvidence = false

    let perspective: MemBenchPerspective =
        item.agent == "FirstAgent" ? .firstAgent : .thirdAgent

    for turn in allTurns {
        // §6: count tokens for user + agent strings per message before storing.
        // §7 row 6: cl100k_base seam — `memBenchCountTokens` delegates to
        // `lmeEstimateTokens` (UTF-8 / 4) until the cl100k vocabulary is approved.
        let turnTokens = memBenchCountTokens(turn.userMessage)
                       + memBenchCountTokens(turn.assistantMessage)
        accumulatedTokens += turnTokens

        // §2: build storage line (same shape selection as standard mode).
        let storageContent: String
        if turn.assistantMessage.isEmpty {
            storageContent = storageLine(step: turn.sid, message: turn.userMessage)
        } else {
            storageContent = storageLine(
                step: turn.sid,
                user: turn.userMessage,
                agent: turn.assistantMessage
            )
        }

        var writeArgs: [String: JSONValue] = [
            memBenchSpecMootVerbMap.contentArg: .string(storageContent),
            "subject": .string(deterministicSubject(storageContent)),
            // step_cap uses impatient encoding per-turn so each turn is immediately
            // queryable at the next recall call without a separate drain step.
            "impatient": .bool(true),
        ]
        for (k, v) in memBenchSpecMootVerbMap.constantArgs {
            writeArgs[k] = .string(v)
        }

        // §5: wall-clock timer around the moot_file_memory call.
        let writeStart = Date()
        let writeResult = try await client.callTool(
            memBenchSpecMootVerbMap.write,
            arguments: writeArgs,
            format: memBenchSpecMootVerbMap.resultFormat
        )
        writeDurations.append(Date().timeIntervalSince(writeStart))
        if let uuid = writeResult.writeAssignedID {
            manifest[uuid] = turn.sid
        }

        // §6: "From the step AFTER the last evidence step, the QA is asked at EVERY
        //      subsequent step". We ask if we've passed the last evidence sid.
        // When lastEvidenceSid is nil (no target steps), we never ask.
        guard let lastSid = lastEvidenceSid else { continue }
        guard turn.sid > lastSid else { continue }

        // First ask: apply a one-time settle to ensure evidence turns are encoded.
        // This differs from the pure Python env (which has no settle concept) but
        // is necessary for the moot backend to surface encoded results in recall.
        if !settledUpToEvidence {
            settledUpToEvidence = true
            _ = try await client.callTool(
                AriaV2Surface.dream,
                arguments: ["associates": JSONValue.string("all")],
                format: .mootV2,
                deadline: MCPDeadline.bulk
            )
            _ = try await client.callTool(
                AriaV2Surface.reindex,
                arguments: [:],
                format: .mootV2,
                deadline: MCPDeadline.bulk
            )
            _ = await waitForEncodeDrain(
                client: client,
                label: "membench-spec-stepcap settle item=\(item.itemID)"
            )
        }

        // §3–4: recall query using `question (time)`.
        let query = recallQuery(question: item.qa.question, time: item.qa.time)
        var queryArgs = AriaV2Surface.memorySearchArgs(verbMap: memBenchSpecMootVerbMap, query: query)
        // When --scoring is given, pass it to the estate; when omitted, the call is
        // byte-identical to the pre-flag baseline (no "scoring" key in the dict).
        if let s = config.scoringStrategy { queryArgs["scoring"] = .string(s) }

        // §5: wall-clock timer around the recall call (last per-step value recorded
        // as the final readDuration; §5 describes per-question timing).
        let readStart = Date()
        let queryResult = try await client.callTool(
            memBenchSpecMootVerbMap.query,
            arguments: queryArgs,
            format: memBenchSpecMootVerbMap.resultFormat
        )
        readDuration = Date().timeIntervalSince(readStart)

        let rawPayload = queryResult.textBlocks.joined(separator: "\n")
        // Capture the last retrieved step ids for the outcome record.
        retrievedStepIDs = queryResult.orderedIDs.compactMap { manifest[$0] }

        // §3: obtain answer letter for this step's token count (capacity ask).
        var correct = false
        if let consumedLetter = consumedAnswers[item.itemID] {
            correct = membenchSpecAnswerCorrect(
                response: consumedLetter,
                groundTruth: item.qa.groundTruth
            )
        } else if let cmd = config.answerCmd {
            let prompt = answerPrompt(
                perspective: perspective,
                memory: rawPayload,
                question: item.qa.question,
                time: item.qa.time,
                choices: item.qa.choices
            )
            if let rawResponse = try? lmeRunJudge(cmd: cmd, prompt: prompt),
               let letter = MemBenchAnswerConstraint.parseAnswerChoice(from: rawResponse) {
                correct = membenchSpecAnswerCorrect(
                    response: letter,
                    groundTruth: item.qa.groundTruth
                )
            }
        }

        // §6: record (token_count_at_ask, correct) pair.
        capacitySamples.append((tokenCount: accumulatedTokens, correct: correct))
    }

    // Guard probe (once per leg — delegated to the shared sampler).
    _ = await guardSampler.probe {
        await probeMCPClient(client, verbMap: memBenchSpecMootVerbMap, name: "mootx01-membench-spec")
    }

    // §4: recall score for the step_cap outcome uses the final recall state
    // (after the last ask). When no asks happened (item had no turns past the
    // evidence step), recall is 0.
    let finalRetrievedSids: [Int]? = retrievedStepIDs.isEmpty ? nil : retrievedStepIDs
    let recallScore = membenchSpecGetRecall(
        retrievedStepIDs: finalRetrievedSids,
        targetStepIDs: targetStepIDs
    )

    // §6 answeredCorrect: derive from capacitySamples if any were collected.
    // Use the LAST sample's correct flag as the item-level correctness indicator.
    let answeredCorrect: Bool? = capacitySamples.last.map { $0.correct }

    unitCompleted = true
    return MemBenchSpecItemOutcome(
        category: item.category,
        agent: item.agent,
        answeredCorrect: answeredCorrect,
        recallScore: recallScore,
        writeDurations: writeDurations,
        readDuration: readDuration,
        capacitySamples: capacitySamples
    )
}

// MARK: - EncodeBarrier report label

private extension EncodeBarrier {
    /// The label written to the report JSON's `encode_barrier` field.
    var reportLabel: String {
        switch self {
        case .drain:     return "drain"
        case .impatient: return "impatient"
        case .none:      return "none"
        }
    }
}
