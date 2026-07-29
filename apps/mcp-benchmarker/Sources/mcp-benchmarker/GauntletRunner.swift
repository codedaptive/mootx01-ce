import Foundation

// GauntletRunner.swift — the live runner (Phase 2.2). Loads a generated corpus
// into BOTH scratch backends via their OWN live write tools, runs every needle
// query against the contender search and against mootx01 moot_memory_search under
// each scoring strategy, scores each needle (completeness is derived from the
// returned items themselves — no separate full-record fetch), runs the
// DegeneracyGuard, and assembles the run report.
//
// SAFETY (plan lines 51-62): the runner writes during load, then dreams, runs
// degeneracy guard probes, queries, scores, and reads backend responses. It must
// be pointed at SCRATCH backends — mootx01 via MOOTX01_DATA_DIR=/tmp/... or
// ARIA_MCP_SQLITE_PATH=/tmp/... in its stdio command, the contender via the
// `--contender-dir /tmp/...` FLAG (never the bare env var). The runner does not choose
// the backends; the CLI asserts the scratch flag forms before the runner is
// constructed.
//
// IDENTITY. Backends do not share an id space and the contender's search returns no id,
// so the runner scores by CONTENT (via GauntletScorer's normalization). The
// per-record location drives filing in BOTH backends: mootx01 takes the whole
// `location` string; the contender takes wing+room from its first two path segments.

/// A mootx01 `moot_memory_search` scoring strategy column. The raw value is the
/// `scoring` MCP arg. These are the fusion-only baselines (no precise reduce).
/// The precise-recall ablation is a separate axis: one column per named
/// reduction composition through `moot_recall_precise` (see
/// `GauntletRunner.compositionNames`).
enum MootScoring: String, Sendable, CaseIterable {
    case raw, rrf, matrixAware
}

/// One backend column the runner evaluates. A column is one of:
///   - the contender search baseline (`isMootx01 == false`),
///   - a mootx01 `moot_memory_search` under a named `scoring` strategy, or
///   - a mootx01 `moot_recall_precise` under a named reduction `composition`
///     (the ablation grid — one column per composition).
/// The three share a structure so the runner loops uniformly. A precise column
/// carries `composition` (and no `scoring`); a search column carries `scoring`
/// (and no `composition`).
struct GauntletColumn: Sendable {
    let name: String
    let isMootx01: Bool
    /// The `moot_memory_search` scoring strategy, when this is a search column.
    let scoring: MootScoring?
    /// The named reduction composition, when this is a precise-recall ablation
    /// column. Mutually exclusive with `scoring`.
    let composition: String?

    /// True when this column calls `moot_recall_precise` with a composition
    /// rather than `moot_memory_search` under a scoring arg.
    var usesPreciseTool: Bool { composition != nil }
}

/// Drives a full gauntlet run against two live (scratch) backends.
struct GauntletRunner {
    /// The PreciseRecall recipe tool exposed by ARIA_MCP. The `precise`
    /// strategy column calls this instead of `moot_memory_search`; it
    /// returns the same mootText shape.
    static let preciseRecallToolName = "moot_recall_precise"

    let contender: MCPClient
    let contenderVerbs: EndpointConfig.VerbMap
    let moot: MCPClient
    let mootVerbs: EndpointConfig.VerbMap
    let corpus: GauntletCorpus
    let scorer: GauntletScorer
    let runLabel: String
    /// Max results to request per query (the search `limit`/depth). Must be ≥ the
    /// deepest k so found@10 is observable. Default 20 (mootx01's own default).
    let searchLimit: Int

    /// Per-backend reuse controls (`reuseContender`, `reuseMoot`). When true for a
    /// backend, the load and dream for that backend are skipped and queries run
    /// straight against the persisted estate. Each backend is guarded by its own
    /// load-marker; a stale/mismatched marker falls back to a fresh load. The
    /// DegeneracyGuard still warm-probes both backends. Default false — normal
    /// runs load fresh.
    /// PER-BACKEND reuse. The contender is a fixed external baseline (same corpus +
    /// queries every run) and its load is the dominant per-run cost, so it should
    /// load ONCE and be reused thereafter. mootx01 reloads fresh each run
    /// (its ingestion changes with the code under test). When `reuseContender` is
    /// true the contender load is skipped (estate already populated, verified by
    /// the CLI marker); when `reuseMoot` is true the mootx01 load + dream are
    /// skipped. The DegeneracyGuard still warm-probes both, so a stale/empty reuse
    /// aborts.
    let reuseContender: Bool
    let reuseMoot: Bool

    /// When true, skip ALL `moot_recall_precise` composition columns and run only
    /// the search-strategy columns (raw, rrf, matrixAware) plus the contender
    /// baseline. Cuts a ~25-min full run down to ~2-3 min — useful for rapid
    /// iteration on recall quality without waiting for the full ablation grid.
    /// The report prints a clear "QUICK MODE" banner so the reduced column set is
    /// never mistaken for a full run. Default false.
    let quickMode: Bool
    /// Local retest mode: exercise and score only the MOOT backend while keeping
    /// the historical corpus, scorer, and guard unchanged.
    let mootOnly: Bool
    /// `.gauntlet-loaded` marker beside each backend's data, written after a FRESH
    /// load of that backend so the next run can reuse it. nil when the path can't
    /// be derived. A fresh load writes its own marker; a reused backend keeps its.
    let contenderMarker: URL?
    let mootMarker: URL?

    /// Coarse-pool width requested for every precise-recall (composition) column.
    /// Wide enough to admit the whole searchable frontier of a gauntlet corpus
    /// so the precise pool MEMBERSHIP is stable run-to-run (the determinism
    /// prerequisite — see the `pool` arg in `query`). The backend clamps to the
    /// available candidates, so an over-wide value is harmless.
    let precisePoolWidth = 500

    init(contender: MCPClient, contenderVerbs: EndpointConfig.VerbMap,
         moot: MCPClient, mootVerbs: EndpointConfig.VerbMap,
         corpus: GauntletCorpus, scorer: GauntletScorer,
         runLabel: String, searchLimit: Int = 20,
         reuseContender: Bool = false, reuseMoot: Bool = false,
         contenderMarker: URL? = nil, mootMarker: URL? = nil,
         quickMode: Bool = false, mootOnly: Bool = false) {
        self.contender = contender
        self.contenderVerbs = contenderVerbs
        self.moot = moot
        self.mootVerbs = mootVerbs
        self.corpus = corpus
        self.scorer = scorer
        self.runLabel = runLabel
        self.searchLimit = max(searchLimit, (scorer.kValues.max() ?? 10))
        self.reuseContender = reuseContender
        self.reuseMoot = reuseMoot
        self.contenderMarker = contenderMarker
        self.mootMarker = mootMarker
        self.quickMode = quickMode
        self.mootOnly = mootOnly
    }

    /// The reduction-ablation grid: one column per named composition through
    /// `moot_recall_precise`. These names MUST match
    /// `NeuronKit.CompositionGrid.all` (the executor side) exactly — the
    /// benchmarker is a pure MCP client and imports no kit, so the grid is
    /// mirrored here by name and passed as the `composition` arg. The
    /// `CompositionGridSyncTests` documents the expected set; if the kit grid
    /// changes, update this list and that test together.
    static let compositionNames: [String] = [
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
    ///   1. contender baseline,
    ///   2. mootx01 `moot_memory_search` under each scoring strategy (raw, rrf,
    ///      matrixAware) — the fusion baselines,
    ///   3. mootx01 `moot_recall_precise` under each reduction composition — the
    ///      ablation grid (one column per composition).
    static func columns() -> [GauntletColumn] {
        var cols = [GauntletColumn(name: "contender", isMootx01: false, scoring: nil, composition: nil)]
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
    func run() async throws -> GauntletRunReport {
        // 1. LOAD the corpus into both backends via their live write tools, then
        //    1b. DREAM the mootx01 estate — UNLESS the backends already hold this
        //    corpus (--reuse-backends, verified by the CLI against the
        //    load-markers). The dream's co-occurrence/temporal matrix is built by
        //    the dreaming pass, NOT by the (impatient) capture path — so a freshly
        //    loaded estate has an EMPTY matrix and the matrix-driven precise
        //    compositions (matrix, text+matrix, the matrix term in weighted-all)
        //    score 0 until it runs. One moot_dream call rebuilds + registers the
        //    matrix tier and runs one dreaming cycle; deterministic `now` keeps it
        //    reproducible. Only the mootx01 backend has a matrix tier; the contender
        //    needs no equivalent. On reuse, both the load and the dream are
        //    skipped: the matrix persists in the estate SQLite across the process
        //    restart, and the DegeneracyGuard below still warm-probes both
        //    backends so an empty/stale reuse is caught rather than scored.
        if reuseContender {
            FileHandle.standardError.write(Data((
                "gauntlet: reusing persisted contender estate (seed \(corpus.seed), "
                + "\(corpus.records.count) records) — contender load skipped.\n").utf8))
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
        // Write each freshly-loaded backend's marker so the next run can reuse it.
        if !reuseContender && !mootOnly { writeMarker(contenderMarker) }
        if !reuseMoot { writeMarker(mootMarker) }

        // 2. GUARD before scoring: probe each backend with ≥3 distinct queries
        //    and classify. A non-healthy verdict aborts the whole table.
        let guard_ = DegeneracyGuard()
        try await enforceGuard(guard_)

        // 3. SCORE every needle under every column.
        var strategyResults: [StrategyResult] = []
        var retained: [RetainedFailure] = []
        // Quick mode: skip all precise-recall composition columns and run only
        // the contender baseline + three moot_memory_search strategy columns.
        // The report prints a banner so the reduced set is never mistaken for a
        // full run. ~2-3 min vs ~25 min for the full ablation grid.
        let allColumns = Self.columns().filter { !mootOnly || $0.isMootx01 }
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
                // full-record fetch. Both backends are measured identically: the
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

        return GauntletRunReport(
            seed: corpus.seed,
            runLabel: runLabel,
            kValues: scorer.kValues,
            distractorsPerNeedle: corpus.distractorsPerNeedle,
            tierCounts: corpus.tierCounts,
            strategies: strategyResults,
            worstFailures: worst,
            guardHealthy: true,
            quickMode: quickMode)
    }

    // MARK: - load

    /// Writes every corpus record into both backends via their live write tools,
    /// threading the per-record location (so the T5 scatter tier actually files
    /// records where it intends to). mootx01 gets the whole location string;
    /// the contender gets wing+room derived from the first two path segments.
    private func loadCorpus() async throws {
        // Build the full write batch for each backend up front, then fire each as
        // one pipelined stream rather than a per-record round-trip. The serial
        // await-each path spent its wall-clock blocked on scheduling between
        // calls (neither backend's encode is the cost — both chew a batch in
        // seconds); pipelining lets each long-lived server process its whole load
        // at full speed. The two backends are independent processes, so their
        // batches also run concurrently.
        var mootCalls: [(name: String, arguments: [String: JSONValue])] = []
        var memCalls: [(name: String, arguments: [String: JSONValue])] = []
        mootCalls.reserveCapacity(corpus.records.count)
        memCalls.reserveCapacity(corpus.records.count)

        for record in corpus.records {
            // mootx01: moot_file_memory { content, location, impatient }.
            // impatient=true encodes the drawer (chunk + BM25 + embedding)
            // INLINE before the write returns, so the corpus is semantically
            // searchable immediately — required for a warm gauntlet run. Without
            // it the regular path enqueues the encode for background drain and a
            // query issued right after load hits a dark BM25/vector lane.
            var mootArgs: [String: JSONValue] = [
                mootVerbs.contentArg: .string(record.content),
                "location": .string(record.location),
                "impatient": .bool(true),
            ]
            // Any other constant args from the config are merged but never
            // override the per-record location.
            for (k, v) in mootVerbs.constantArgs where k != "location" {
                mootArgs[k] = .string(v)
            }
            mootCalls.append((name: mootVerbs.write, arguments: mootArgs))

            // contender: write tool { content, wing, room }.
            let (wing, room) = wingRoom(from: record.location)
            let memArgs: [String: JSONValue] = [
                contenderVerbs.contentArg: .string(record.content),
                "wing": .string(wing),
                "room": .string(room),
            ]
            memCalls.append((name: contenderVerbs.write, arguments: memArgs))
        }

        // Fire only the backend(s) not being reused. A reused backend's writes are
        // skipped entirely (its persisted data is kept). The two are independent
        // processes, so when both load they run concurrently.
        async let mootLoad: Void = {
            guard !reuseMoot else { return }
            _ = try await moot.pipelinedCallTools(mootCalls, format: mootVerbs.resultFormat)
        }()
        async let memLoad: Void = {
            guard !reuseContender && !mootOnly else { return }
            _ = try await contender.pipelinedCallTools(memCalls, format: contenderVerbs.resultFormat)
        }()
        _ = try await (mootLoad, memLoad)
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
    static let dreamToolName = "moot_dream"

    /// Fixed ISO8601 instant the gauntlet dreams at, so the dreaming cycle (its
    /// diary timestamp and reward window) is reproducible run-to-run alongside
    /// the rest of the deterministic harness. The matrix rebuild itself is a
    /// pure function of the loaded audit log, independent of this value.
    static let dreamInstant = "2026-06-11T00:00:00Z"

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
            toolName = contenderVerbs.query
            format = contenderVerbs.resultFormat
            args = [contenderVerbs.queryArg: .string(needle.query)]
            result = try await contender.callTool(toolName, arguments: args, format: format)
        }
        let latency = elapsedSeconds(since: start)

        let items = result.items.map { ScoredItem(id: $0.id, content: $0.content) }
        let responseText = result.textBlocks.joined(separator: "\n")
        let bytes = responseText.utf8.count
        let request = renderRequest(tool: toolName, args: args)
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
        if !mootOnly {
            // contender probes.
            var contenderRankings: [[String]] = []
            for q in probes {
                let r = try await contender.callTool(
                    contenderVerbs.query, arguments: [contenderVerbs.queryArg: .string(q)],
                    format: contenderVerbs.resultFormat)
                contenderRankings.append(BenchmarkEngine.normalizedContentOrder(r.items))
            }
            if case let verdict = guard_.classify(probeRankings: contenderRankings),
               !isHealthy(verdict) {
                throw GauntletGuardRefusal(backend: "contender", diagnostic: verdict.diagnostic)
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

    /// Derives a contender (wing, room) from a `wing/room[/...]` location string.
    /// The first segment is the wing; the second (or "General" when absent) is the
    /// room. Extra segments are folded into the room with hyphens so a deep
    /// location still maps to a single filing location deterministically.
    private func wingRoom(from location: String) -> (wing: String, room: String) {
        let parts = location.split(separator: "/").map(String.init)
        let wing = parts.first ?? "General"
        let room = parts.count > 1 ? parts.dropFirst().joined(separator: "-") : "General"
        return (wing, room)
    }

    /// Renders a compact one-line request string for the failure appendix.
    private func renderRequest(tool: String, args: [String: JSONValue]) -> String {
        let encoded = (try? JSONEncoder().encode(JSONValue.object([
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
struct GauntletGuardRefusal: Error, CustomStringConvertible {
    let backend: String
    let diagnostic: String
    var description: String {
        "[DegeneracyGuard] REFUSED gauntlet for '\(backend)': \(diagnostic)"
    }
}
