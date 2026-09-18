import Foundation

// GauntletRunner.swift — the gauntlet runner (batch and live paths).
//
// SEEDING. The mootx01 backend is seeded via one of two paths, selected by
// `--seed-path batch|live` (default batch, ruling 8D5B8053):
//   batch: `gauntletSeedRecords` projects corpus records → SeedFileRecord[];
//          `emitSeedJSON` serialises → one `moot_json_import` → one
//          `waitForEncodeDrain` barrier → `moot_dream` → queries.
//   live:  the original pipelined `moot_file_memory` loop (retained for
//          periodic equivalence re-proving against the batch path).
// The baseline column's write path is ALWAYS live — external backends have no
// `moot_json_import`, so the pipelined baseline write loop is unchanged.
//
// SCORING. Both paths score by CONTENT (via GauntletScorer's normalization).
// The per-record location drives filing in every backend: mootx01 takes the
// whole `location` string; a baseline maps it through its injected
// write-argument closure. Content-based scoring means no attribution pass is
// needed after batch import — the same content lands, the same scores result.
//
// BASELINE INJECTION. Core is moot-only: with `baseline == nil` the runner
// starts, loads, guards, and reports ONLY the moot backend. A two-endpoint
// lane can be built by an extension subpackage that injects a
// `GauntletBaseline` (a second live backend plus the per-record write-argument
// mapping for that product). The runner itself is product-agnostic — every
// baseline-specific name and argument shape arrives through the injection.
//
// SAFETY: the runner writes during load, then dreams, runs degeneracy guard
// probes, queries, scores, and reads backend responses. It must be pointed at
// SCRATCH backends only. The runner does not choose the backends; the CLI
// asserts the scratch requirement forms before the runner is constructed.

/// A mootx01 `moot_memory_search` scoring strategy column. The raw value is the
/// `scoring` MCP arg. These are the fusion-only baselines (no precise reduce).
/// The precise-recall ablation is a separate axis: one column per named
/// reduction composition through `moot_recall_precise` (see
/// `GauntletRunner.compositionNames`).
public enum MootScoring: String, Sendable, CaseIterable {
    case raw, rrf, matrixAware
}

/// One backend column the runner evaluates. A column is one of:
///   - the injected baseline backend's search (`isMootx01 == false`),
///   - a mootx01 `moot_memory_search` under a named `scoring` strategy, or
///   - a mootx01 `moot_recall_precise` under a named reduction `composition`
///     (the ablation grid — one column per composition).
/// The three share a structure so the runner loops uniformly. A precise column
/// carries `composition` (and no `scoring`); a search column carries `scoring`
/// (and no `composition`).
public struct GauntletColumn: Sendable {
    public let name: String
    public let isMootx01: Bool
    /// The `moot_memory_search` scoring strategy, when this is a search column.
    public let scoring: MootScoring?
    /// The named reduction composition, when this is a precise-recall ablation
    /// column. Mutually exclusive with `scoring`.
    public let composition: String?

    /// True when this column calls `moot_recall_precise` with a composition
    /// rather than `moot_memory_search` under a scoring arg.
    public var usesPreciseTool: Bool { composition != nil }
}

/// A second live backend injected into the gauntlet by an extension
/// subpackage for a two-endpoint run. Carries everything baseline-specific:
/// the column name, the connected client + verbs, the per-record
/// write-argument mapping (how THIS product files one corpus record), and the
/// reuse marker state. Core never names a concrete baseline product.
public struct GauntletBaseline: Sendable {
    /// The report column name for this backend (also used in diagnostics).
    public let name: String
    public let client: MCPClient
    public let verbs: EndpointConfig.VerbMap
    /// Builds the write-tool arguments that file one corpus record into this
    /// backend (the product's own location semantics live in this closure).
    public let writeArgs: @Sendable (GauntletRecord) -> [String: JSONValue]
    /// When true, the baseline's load is skipped (its persisted scratch data
    /// is kept — verified by the CLI against the load marker).
    public let reuse: Bool
    /// `.gauntlet-loaded` marker beside this backend's scratch data; written
    /// after a fresh load so the next run can reuse it. nil = not derivable.
    public let marker: URL?

    public init(name: String, client: MCPClient, verbs: EndpointConfig.VerbMap,
                writeArgs: @escaping @Sendable (GauntletRecord) -> [String: JSONValue],
                reuse: Bool = false, marker: URL? = nil) {
        self.name = name
        self.client = client
        self.verbs = verbs
        self.writeArgs = writeArgs
        self.reuse = reuse
        self.marker = marker
    }
}

/// Drives a full gauntlet run against live (scratch) backends: the moot
/// backend always, plus the injected baseline when one is supplied.
public struct GauntletRunner: Sendable {
    /// The PreciseRecall recipe tool exposed by ARIA_MCP. The `precise`
    /// strategy column calls this instead of `moot_memory_search`; it
    /// returns the same mootText shape.
    public static let preciseRecallToolName = AriaV2Surface.recallPrecise

    /// The injected reference baseline, or nil for a moot-only run.
    let baseline: GauntletBaseline?
    let moot: MCPClient
    let mootVerbs: EndpointConfig.VerbMap
    let corpus: GauntletCorpus
    let scorer: GauntletScorer
    let runLabel: String
    /// Max results to request per query (the search `limit`/depth). Must be ≥ the
    /// deepest k so found@10 is observable. Default 20 (mootx01's own default).
    let searchLimit: Int

    /// When true the mootx01 load + dream are skipped and queries run straight
    /// against the persisted estate. Guarded by the load-marker in the CLI; a
    /// stale/mismatched marker falls back to a fresh load. The DegeneracyGuard
    /// still warm-probes the backend, so a stale/empty reuse aborts rather than
    /// scores. (The baseline's own reuse flag travels inside `GauntletBaseline`;
    /// a baseline is typically a fixed external product whose load dominates
    /// the per-run cost, so it loads once and is reused thereafter, while
    /// mootx01 reloads fresh each run because its ingestion changes with the
    /// code under test.) Default false — normal runs load fresh.
    let reuseMoot: Bool

    /// When true, skip ALL `moot_recall_precise` composition columns and run only
    /// the search-strategy columns (raw, rrf, matrixAware) plus the baseline
    /// column when one is injected. Cuts a ~25-min full run down to ~2-3 min —
    /// useful for rapid iteration on recall quality without waiting for the full
    /// ablation grid. The report prints a clear "QUICK MODE" banner so the
    /// reduced column set is never mistaken for a full run. Default false.
    let quickMode: Bool
    /// `.gauntlet-loaded` marker beside the moot backend's data, written after a
    /// FRESH load so the next run can reuse it. nil when the path can't be
    /// derived. A fresh load writes its own marker; a reused backend keeps its.
    let mootMarker: URL?

    /// Coarse-pool width requested for every precise-recall (composition) column.
    /// Wide enough to admit the whole searchable frontier of a gauntlet corpus
    /// so the precise pool MEMBERSHIP is stable run-to-run (the determinism
    /// prerequisite — see the `pool` arg in `query`). The backend clamps to the
    /// available candidates, so an over-wide value is harmless.
    let precisePoolWidth = 500

    /// How the mootx01 backend is seeded. `batch` (default, ruling 8D5B8053):
    /// one `moot_json_import` from a seed file written to `scratchDir`.
    /// `live`: the retained slow lane (pipelined `moot_file_memory` loop) for
    /// periodic equivalence re-proving. The baseline column is always live.
    let seedPath: SeedPathMode
    /// The scratch directory the batch path writes its seed file into. Required
    /// when `seedPath == .batch` and `reuseMoot == false`; nil is safe when
    /// the live path is selected or when the moot backend is being reused.
    let scratchDir: URL?

    public init(moot: MCPClient, mootVerbs: EndpointConfig.VerbMap,
                corpus: GauntletCorpus, scorer: GauntletScorer,
                runLabel: String, searchLimit: Int = 20,
                baseline: GauntletBaseline? = nil,
                reuseMoot: Bool = false, mootMarker: URL? = nil,
                quickMode: Bool = false,
                seedPath: SeedPathMode = .batch, scratchDir: URL? = nil) {
        self.baseline = baseline
        self.moot = moot
        self.mootVerbs = mootVerbs
        self.corpus = corpus
        self.scorer = scorer
        self.runLabel = runLabel
        self.searchLimit = max(searchLimit, (scorer.kValues.max() ?? 10))
        self.reuseMoot = reuseMoot
        self.mootMarker = mootMarker
        self.quickMode = quickMode
        self.seedPath = seedPath
        self.scratchDir = scratchDir
    }

    /// The reduction-ablation grid: one column per named composition through
    /// `moot_recall_precise`. These names MUST match
    /// `NeuronKit.CompositionGrid.all` (the executor side) exactly — the
    /// benchmarker is a pure MCP client and imports no kit, so the grid is
    /// mirrored here by name and passed as the `composition` arg. The
    /// `CompositionGridSyncTests` documents the expected set; if the kit grid
    /// changes, update this list and that test together.
    public static let compositionNames: [String] = [
        "text", "hamming", "matrix", "lattice", "tokenExact", "bm25",
        // "vector" removed: probe-verified byte-identical to "hamming".
        // GLK's RecallScoreVector.vector IS normalized Hamming similarity —
        // one lane, two names. "dense-fused" (below) is the TRUE float lane
        // that replaces the removed "vector" alias: cosine over the pooled
        // float embedding (Lane D), not the lossy 256-bit SimHash projection.
        "hamming+tokenExact", "hamming+text", "text+matrix", "lattice+hamming",
        "text+tokenExact", "text+mmr",
        // T3 temporal (current-over-superseded), T4 assembly (split-fact
        // expansion), T5 association (matrix-weighted) — the structural signals.
        "temporalState", "temporalText", "temporal", "text+temporal",
        "text+assembly", "tokenExact+assembly",
        "matrix-weighted", "matrix+hamming",
        // T2/T5 semantic: the TRUE float-embedding dense lane (cosine over the
        // pooled vector), the dense column W6 removed when it deleted the
        // "vector" alias. Ranks an answer above a near-duplicate of the question.
        "dense-fused",
        "weighted-all",
    ]

    /// Every column evaluated, in a fixed order so the report is stable:
    ///   1. the baseline column, when `baselineName` is non-nil,
    ///   2. mootx01 `moot_memory_search` under each scoring strategy (raw, rrf,
    ///      matrixAware) — the fusion baselines,
    ///   3. mootx01 `moot_recall_precise` under each reduction composition — the
    ///      ablation grid (one column per composition).
    public static func columns(baselineName: String? = nil) -> [GauntletColumn] {
        var cols: [GauntletColumn] = []
        if let baselineName {
            cols.append(GauntletColumn(name: baselineName, isMootx01: false,
                                       scoring: nil, composition: nil))
        }
        for s in MootScoring.allCases {
            cols.append(GauntletColumn(
                name: "mootx01:\(s.rawValue)", isMootx01: true, scoring: s, composition: nil))
        }
        for comp in compositionNames {
            cols.append(GauntletColumn(
                name: "precise:\(comp)", isMootx01: true, scoring: nil, composition: comp))
        }
        return cols
    }

    /// Runs the full gauntlet and returns the assembled report. Throws on a
    /// transport failure during load; a DegeneracyGuard refusal returns a thrown
    /// `GauntletGuardRefusal` so the CLI aborts the table (a refusal is a non-
    /// result, never a zero — plan rule 5).
    public func run() async throws -> GauntletRunReport {
        // 1. LOAD the corpus into the backend(s) via their live write tools,
        //    then 1b. DREAM the mootx01 estate — UNLESS a backend already holds
        //    this corpus (reuse, verified by the CLI against the load-markers).
        //    The dream's co-occurrence/temporal matrix is built by the dreaming
        //    pass, NOT by the (impatient) capture path — so a freshly loaded
        //    estate has an EMPTY matrix and the matrix-driven precise
        //    compositions (matrix, text+matrix, the matrix term in weighted-all)
        //    score 0 until it runs. One moot_dream call rebuilds + registers the
        //    matrix tier and runs one dreaming cycle; deterministic `now` keeps it
        //    reproducible. Only the mootx01 backend has a matrix tier; a baseline
        //    needs no equivalent. On reuse, both the load and the dream are
        //    skipped: the matrix persists in the estate SQLite across the process
        //    restart, and the DegeneracyGuard below still warm-probes every
        //    backend so an empty/stale reuse is caught rather than scored.
        if let baseline, baseline.reuse {
            FileHandle.standardError.write(Data((
                "gauntlet: reusing persisted \(baseline.name) data (seed \(corpus.seed), "
                + "\(corpus.records.count) records) — \(baseline.name) load skipped.\n").utf8))
        }
        if reuseMoot {
            FileHandle.standardError.write(Data((
                "gauntlet: reusing persisted mootx01 estate — mootx01 load + dream skipped.\n").utf8))
        }
        // Load only the non-reused backend(s); loadCorpus skips a reused one.
        try await loadCorpus()
        // Dream only when mootx01 was freshly loaded (a reused estate keeps its
        // dreamed matrix; the daemon rebuilds it on open regardless).
        if !reuseMoot { try await dreamMootEstate() }
        // C4 (benchmark reset 2026-08-13): capture the timing report immediately
        // after the estate is settled (load + dream complete, before needle scoring
        // begins). The gauntlet has one estate per run — no per-unit estates — so
        // a single capture covers the leg. fetchTimingReport swallows errors into
        // nil so a missing tool never aborts the run; the field stays nil in the
        // report JSON and the rendered header omits it.
        let capturedTimingReport: String? = await fetchTimingReport(client: moot)

        // Write each freshly-loaded backend's marker so the next run can reuse it.
        if let baseline, !baseline.reuse { writeMarker(baseline.marker) }
        if !reuseMoot { writeMarker(mootMarker) }

        // 2. GUARD before scoring: probe each backend with ≥3 distinct queries
        //    and classify. A non-healthy verdict aborts the whole table.
        // C5: the guard runs once per run (structurally once-per-run — the gauntlet
        // has a single shared estate, not per-unit estates, so there is no sampling
        // decision to make; enforceGuard probes once and the verdict holds for all
        // subsequent needle queries). GuardSamplingPolicy is exposed at the CLI
        // level for report JSON consistency but does not change run behaviour here.
        // C6: needle scoring is serial. The gauntlet reuses one mootx01 process and
        // one MCP connection for the entire run. Concurrent MCP calls to a single
        // stdio connection are not safe, and spawning per-column or per-needle
        // processes would defeat the gauntlet's single-estate comparative design.
        // parallelUnits stays 1 and is recorded in the report JSON.
        let guard_ = DegeneracyGuard()
        try await enforceGuard(guard_)

        // 3. SCORE every needle under every column.
        var strategyResults: [StrategyResult] = []
        var retained: [RetainedFailure] = []
        // Quick mode: skip all precise-recall composition columns and run only
        // the (optional) baseline column + three moot_memory_search strategy
        // columns. The report prints a banner so the reduced set is never
        // mistaken for a full run. ~2-3 min vs ~25 min for the full ablation grid.
        let allColumns = Self.columns(baselineName: baseline?.name)
        let columns = quickMode
            ? allColumns.filter { !$0.usesPreciseTool }
            : allColumns
        if quickMode {
            FileHandle.standardError.write(Data(
                "QUICK MODE — precise ablation grid skipped (composition columns omitted)\n".utf8))
        }

        for column in columns {
            var scores: [NeedleScore] = []
            for needle in corpus.needles {
                let (items, latency, bytes, request, response) =
                    try await query(needle: needle, column: column)
                let distractorContents = distractorContentMap(for: needle)
                let partnerContent = splitPartnerContent(for: needle)

                // Completeness is derived in-scorer from `items` — the content
                // this query actually returned — so there is no separate
                // full-record fetch. Every backend is measured identically: the
                // returned item matched to the needle is byte-compared verbatim.
                let score = scorer.score(
                    needle: needle,
                    returned: items,
                    distractorContents: distractorContents,
                    splitPartnerContent: partnerContent,
                    latencySeconds: latency,
                    bytesReturned: bytes)
                scores.append(score)

                // Retain a failure (not found at deepest k, or incomplete) with
                // its full request/response for the worst-10 appendix.
                let deepestK = scorer.kValues.max() ?? 10
                let notFound = !(score.foundAtK[deepestK] ?? false)
                let incomplete = score.completeness < 1.0
                if notFound || incomplete {
                    let reason = notFound ? "not found@\(deepestK)" : "incomplete (fetched record ≠ verbatim)"
                    // Severity: missing (rank nil) is worst; otherwise deeper rank
                    // is worse; an incomplete-but-found is the least bad.
                    let severity = score.rank.map { Double($0) } ?? Double(searchLimit + 1)
                    retained.append(RetainedFailure(
                        strategyName: column.name, needleID: needle.id, tier: needle.tier,
                        query: needle.query, request: request, response: response,
                        reason: reason, severity: severity))
                }
            }
            strategyResults.append(StrategyResult.build(
                name: column.name, isMootx01: column.isMootx01,
                scores: scores, kValues: scorer.kValues))
        }

        // Worst 10 by descending severity (highest severity = worst).
        let worst = Array(retained.sorted { $0.severity > $1.severity }.prefix(10))

        var report = GauntletRunReport(
            seed: corpus.seed,
            runLabel: runLabel,
            kValues: scorer.kValues,
            distractorsPerNeedle: corpus.distractorsPerNeedle,
            tierCounts: corpus.tierCounts,
            strategies: strategyResults,
            worstFailures: worst,
            guardHealthy: true,
            quickMode: quickMode)
        // C4: wire the captured timing report into the report struct. The
        // timingSampling label "once-per-run" distinguishes the gauntlet's
        // single-estate pattern from the per-unit-estate lanes (which label
        // theirs "once-per-leg" via LegTimingSampler).
        report.timingReport = capturedTimingReport
        return report
    }

    // MARK: - load

    /// Seeds the corpus into each participating backend. The mootx01 column uses
    /// `seedPath` to choose between batch import and the live write loop; the
    /// baseline column is always live (external backends have no `moot_json_import`).
    ///
    /// Batch path (ruling 8D5B8053): emit one seed JSON file → one
    /// `moot_json_import` → `waitForEncodeDrain` barrier. The barrier replaces
    /// the live path's `impatient=true` inline-encode; the import lane encodes
    /// during the import call and the drain barrier confirms completion before
    /// `dreamMootEstate` runs. Scoring is content-based (GauntletScorer), so no
    /// attribution pass is needed after import.
    ///
    /// Live path (retained for equivalence re-proving): pipelined
    /// `moot_file_memory` calls with `impatient=true`; the baseline column is
    /// the same pipelined loop. Both backends fire concurrently when present.
    private func loadCorpus() async throws {
        // BASELINE: always live — external backends have no moot_json_import.
        // Build the baseline call batch up front so the live baseline and the moot
        // batch-import can run concurrently when both are fresh.
        var baselineCalls: [(name: String, arguments: [String: JSONValue])] = []
        if baseline != nil {
            baselineCalls.reserveCapacity(corpus.records.count)
            for record in corpus.records {
                baselineCalls.append((name: baseline!.verbs.write,
                                      arguments: baseline!.writeArgs(record)))
            }
        }
        let baselineLoad: Task<Void, Error> = Task {
            guard let baseline, !baseline.reuse else { return }
            _ = try await baseline.client.pipelinedCallTools(
                baselineCalls, format: baseline.verbs.resultFormat)
        }

        // MOOTX01: batch or live, gated by reuseMoot.
        if !reuseMoot {
            switch seedPath {
            case .batch:
                // Batch seeding (ruling 8D5B8053): emit schema v1 → one
                // moot_json_import → waitForEncodeDrain barrier. The drain barrier
                // replaces impatient=true: import encodes inline, drain confirms it.
                guard let dir = scratchDir else {
                    throw MCPError(description:
                        "gauntlet batch seed path requires a scratch directory "
                        + "(pass scratchDir to GauntletRunner.init)")
                }
                let sr = gauntletSeedRecords(from: corpus.records)
                let data = emitSeedJSON(name: "gauntlet-\(corpus.seed)", records: sr)
                let seedURL = try writeSeedFile(
                    data, in: dir, name: "gauntlet-\(corpus.seed)")
                let importResult = try await moot.callTool(
                    AriaV2Surface.jsonImport,
                    arguments: ["path": .string(seedURL.path)],
                    format: mootVerbs.resultFormat)
                // v2 surface: drawer count is in structuredContent.data.drawers_written.
                guard let written = importResult.drawersWritten, written == sr.count else {
                    throw MCPError(description:
                        "gauntlet: moot_json_import did not confirm \(sr.count) drawers "
                        + "— got: \(importResult.drawersWritten.map(String.init) ?? "(no structured data)")")
                }
                // Drain barrier: import encodes during the call; the barrier
                // confirms the encode queue is idle before dreamMootEstate runs.
                _ = await waitForEncodeDrain(
                    client: moot, label: "gauntlet seed=\(corpus.seed)")

            case .live:
                // Live path (retained for equivalence re-proving): pipelined
                // moot_file_memory writes with impatient=true so each drawer is
                // encoded inline before the call returns. No drain barrier needed
                // — impatient mode encodes synchronously.
                var mootCalls: [(name: String, arguments: [String: JSONValue])] = []
                mootCalls.reserveCapacity(corpus.records.count)
                for record in corpus.records {
                    var mootArgs: [String: JSONValue] = [
                        mootVerbs.contentArg: .string(record.content),
                        "subject": .string(deterministicSubject(record.content)),
                        "location": .string(record.location),
                        "impatient": .bool(true),
                    ]
                    for (k, v) in mootVerbs.constantArgs where k != "location" {
                        mootArgs[k] = .string(v)
                    }
                    mootCalls.append((name: mootVerbs.write, arguments: mootArgs))
                }
                _ = try await moot.pipelinedCallTools(mootCalls, format: mootVerbs.resultFormat)
            }
        }

        // Await the baseline load (runs concurrently with the moot load above).
        try await baselineLoad.value
    }

    // MARK: - Seed builder

    /// Projects gauntlet corpus records onto seed-file schema v1 records, in
    /// the caller's order (file order == ingest order, which the importer never
    /// re-sorts). Pure — no network calls, deterministic.
    ///
    /// - `id`: the record's stable corpus id (unique across the file; the
    ///   importer validates uniqueness).
    /// - `room`: the record's `location` string verbatim — the per-record T5
    ///   scatter location the live `moot_file_memory` path passed as
    ///   `"location"`. Each record files into its own distinct room.
    /// - `wing`: omitted (nil → the importer's default wing "Agentic Memory",
    ///   matching where the live path files when no wing is given).
    /// - `event_time`: synthesised deterministically — `syntheticEventTime`
    ///   base (2026-01-01T00:00:00Z) plus a per-record +1 s offset in ingest
    ///   order. All synthetic times precede the fixed dream instant
    ///   (`GauntletRunner.dreamInstant` = "2026-06-11T00:00:00Z"), placing
    ///   every record in the estate's past before the dreaming cycle runs.
    ///   The live path does not pass `event_time` (the estate assigns wall-clock
    ///   capture times); the batch path must supply explicit times so the
    ///   attribution pass can match rows. Since the gauntlet scores by content
    ///   (not UUID), the times serve only to ensure record uniqueness within each
    ///   room and run-to-run reproducibility.
    func gauntletSeedRecords(from records: [GauntletRecord]) -> [SeedFileRecord] {
        records.enumerated().map { (idx, record) in
            SeedFileRecord(
                id: record.id,
                content: record.content,
                eventTime: syntheticEventTime(offsetSeconds: idx),
                room: record.location
            )
        }
    }

    /// Writes a load-marker beside one backend's scratch data after a fresh load,
    /// so the next run can reuse that backend. The marker holds the corpus seed
    /// and record count (the values the CLI checks). A write failure is non-fatal
    /// — the data is loaded regardless; only the next run's reuse fast-path is
    /// forfeited — so it is logged, not thrown. nil url is a no-op.
    private func writeMarker(_ url: URL?) {
        guard let url else { return }
        let contents = "\(corpus.seed)\n\(corpus.records.count)\n"
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data((
                "gauntlet: could not write load-marker \(url.path): \(error) "
                + "(reuse fast-path unavailable next run)\n").utf8))
        }
    }

    // MARK: - dream

    /// The on-demand dream tool exposed by ARIA_MCP. One call rebuilds the
    /// estate's co-occurrence/temporal matrix tier and runs one dreaming cycle.
    public static let dreamToolName = AriaV2Surface.dream

    /// Fixed ISO8601 instant the gauntlet dreams at, so the dreaming cycle (its
    /// diary timestamp and reward window) is reproducible run-to-run alongside
    /// the rest of the deterministic harness. The matrix rebuild itself is a
    /// pure function of the loaded audit log, independent of this value.
    public static let dreamInstant = "2026-06-11T00:00:00Z"

    /// Dream the mootx01 estate once, after load and before any query, so the
    /// matrix recall lanes carry signal. The result text is ignored; a transport
    /// failure propagates (the run cannot be trusted on an undreamt estate).
    private func dreamMootEstate() async throws {
        _ = try await moot.callTool(
            Self.dreamToolName,
            arguments: ["now": .string(Self.dreamInstant)],
            format: mootVerbs.resultFormat)
    }

    // MARK: - query

    /// Issues one needle's query to one column's backend and returns the parsed
    /// result items, the latency, the response byte size, and the full request +
    /// response strings (retained for the worst-10 appendix).
    private func query(needle: Needle, column: GauntletColumn)
        async throws -> (items: [ScoredItem], latency: Double, bytes: Int,
                         request: String, response: String) {
        let start = DispatchTime.now()
        let result: MCPToolResult
        var args: [String: JSONValue]
        let toolName: String
        let format: ResultFormat

        if column.isMootx01 {
            format = mootVerbs.resultFormat
            if column.usesPreciseTool {
                // PreciseRecall recipe tool: same coarse grab, then the named
                // reduction composition (the ablation selector). No `scoring`
                // arg; it returns the mootText shape so parsing is unchanged.
                toolName = Self.preciseRecallToolName
                args = [
                    mootVerbs.queryArg: .string(needle.query),
                    "limit": .number(Double(searchLimit)),
                    "composition": .string(column.composition!),
                    // DETERMINISM: request a wide coarse pool so the precise
                    // reduce sees a STABLE candidate set. The backend mints a
                    // random UUID per drawer and the GLK coarse grab tie-breaks
                    // equal lane scores on that UUID, so a narrow pool (default
                    // 30) admits DIFFERENT equal-score boundary candidates
                    // run-to-run — the leaderboard noise. A pool wide enough to
                    // admit the whole searchable frontier makes membership
                    // stable; the composition reduce then orders that set by a
                    // content-stable tie-break (ReductionComposition step 2), so
                    // identical content → identical precise ranking across runs.
                    "pool": .number(Double(precisePoolWidth)),
                ]
            } else {
                // moot_memory_search under a named scoring strategy.
                toolName = mootVerbs.query
                args = [
                    mootVerbs.queryArg: .string(needle.query),
                    "scoring": .string(column.scoring!.rawValue),
                    "limit": .number(Double(searchLimit)),
                ]
            }
            result = try await moot.callTool(toolName, arguments: args, format: format)
        } else {
            // The injected baseline column. `run()` only enumerates this column
            // when a baseline is present, so the force-unwrap is structural.
            let baseline = self.baseline!
            toolName = baseline.verbs.query
            format = baseline.verbs.resultFormat
            args = [baseline.verbs.queryArg: .string(needle.query)]
            result = try await baseline.client.callTool(toolName, arguments: args, format: format)
        }
        let latency = elapsedSeconds(since: start)

        let items = result.items.map { ScoredItem(id: $0.id, content: $0.content) }
        let responseText = result.textBlocks.joined(separator: "\n")
        let bytes = responseText.utf8.count
        let request = Self.renderRequest(tool: toolName, args: args)
        return (items, latency, bytes, request, responseText)
    }

    // MARK: - DegeneracyGuard

    /// Probes each backend with ≥3 distinct queries and enforces the guard. A
    /// non-healthy verdict throws `GauntletGuardRefusal`, aborting the table.
    private func enforceGuard(_ guard_: DegeneracyGuard) async throws {
        // Probe with three ACTUAL needle queries drawn from across the corpus.
        // These provably target different subjects/attributes, so a healthy
        // backend MUST return different rankings for each — which is exactly what
        // the guard checks. Generic phrase probes are a poor fit on a small
        // adversarial corpus: every record is a near-paraphrase of the same
        // template, so broad phrases can return a stable top-k and trip the
        // query-invariance check even on a working backend. Distinct needle
        // queries are the discriminating probe set.
        let probes = guardProbes(from: corpus.needles)
        if let baseline {
            // Baseline probes.
            var baselineRankings: [[String]] = []
            for q in probes {
                let r = try await baseline.client.callTool(
                    baseline.verbs.query, arguments: [baseline.verbs.queryArg: .string(q)],
                    format: baseline.verbs.resultFormat)
                baselineRankings.append(BenchmarkEngine.normalizedContentOrder(r.items))
            }
            if case let verdict = guard_.classify(probeRankings: baselineRankings),
               !isHealthy(verdict) {
                throw GauntletGuardRefusal(backend: baseline.name, diagnostic: verdict.diagnostic)
            }
        }
        // mootx01 probes (default scoring).
        var mootRankings: [[String]] = []
        for q in probes {
            let r = try await moot.callTool(
                mootVerbs.query,
                arguments: [mootVerbs.queryArg: .string(q), "limit": .number(Double(searchLimit))],
                format: mootVerbs.resultFormat)
            mootRankings.append(BenchmarkEngine.normalizedContentOrder(r.items))
        }
        let mootVerdict = guard_.classify(probeRankings: mootRankings)
        if !isHealthy(mootVerdict) {
            throw GauntletGuardRefusal(backend: "mootx01", diagnostic: mootVerdict.diagnostic)
        }
    }

    private func isHealthy(_ verdict: DegeneracyGuard.Verdict) -> Bool {
        if case .healthy = verdict { return true }
        return false
    }

    /// Picks three distinct needle queries spread across the corpus to drive the
    /// guard's query-invariance probe. Spread (first, middle, last) maximizes the
    /// chance the three target different subjects/attributes so a healthy backend
    /// returns visibly different rankings. Falls back to whatever needles exist
    /// when the corpus has fewer than three.
    private func guardProbes(from needles: [Needle]) -> [String] {
        guard !needles.isEmpty else { return [] }
        if needles.count < 3 { return needles.map(\.query) }
        let first = needles.first!.query
        let middle = needles[needles.count / 2].query
        let last = needles.last!.query
        return [first, middle, last]
    }

    // MARK: - helpers

    /// The distractor id → verbatim content map for one needle (for contamination
    /// counting by content match).
    private func distractorContentMap(for needle: Needle) -> [String: String] {
        var map: [String: String] = [:]
        let ids = Set(needle.distractorIDs)
        for record in corpus.records where ids.contains(record.id) {
            map[record.id] = record.content
        }
        return map
    }

    /// The verbatim content of a needle's split partner, if any.
    private func splitPartnerContent(for needle: Needle) -> String? {
        guard let pid = needle.splitPartnerID else { return nil }
        return corpus.records.first { $0.id == pid }?.content
    }

    /// Renders a compact one-line request string for the failure appendix.
    ///
    /// Keys are sorted so that two runs of the same query produce a byte-identical
    /// string. Swift randomises Dictionary iteration order per process, so an
    /// unordered JSONEncoder produces a different byte sequence each time even when
    /// the content is identical. `.sortedKeys` eliminates that variation.
    ///
    /// Exposed as `static` so unit tests can call it without constructing a full
    /// `GauntletRunner` instance.
    static func renderRequest(tool: String, args: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let encoded = (try? encoder.encode(JSONValue.object([
            "tool": .string(tool),
            "arguments": .object(args),
        ]))).flatMap { String(data: $0, encoding: .utf8) }
        return encoded ?? "\(tool)(\(args.keys.sorted().joined(separator: ",")))"
    }

    private func elapsedSeconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}

/// Thrown when the DegeneracyGuard refuses a backend. The CLI prints the
/// diagnostic and exits non-zero WITHOUT emitting a table — a guard refusal is a
/// non-result, never a zero (plan rule 5).
public struct GauntletGuardRefusal: Error, CustomStringConvertible {
    public let backend: String
    public let diagnostic: String
    public var description: String {
        "[DegeneracyGuard] REFUSED gauntlet for '\(backend)': \(diagnostic)"
    }
}
