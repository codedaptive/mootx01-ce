import LocusKit

/// The complete output of a `GLKRecallRequest` routed through the Recall Director.
public struct GLKRecallResult: Sendable {
    /// The original request that produced this result.
    public let request: GLKRecallRequest
    /// The plan the director computed before lane recall ran.
    public let plan: RecallPlan
    /// Cross-lane union profile. Populated by the `.unionBest` lane only.
    /// Nil for `.locusOnly`, `.corpusOnly`, and `.hybrid` results.
    public let unionProfile: RecallUnionProfile?
    /// Hits in the order the active lane and scoring returned them.
    public let hits: [RecallHit]

    /// Dense float lane (Lane D) status for this query. Non-nil when the lane
    /// was dark (did not contribute hits), carrying the observable reason as a
    /// short string. Nil ONLY when the lane ran and returned hits — every other
    /// case now carries an explicit dark tag so callers can distinguish "active"
    /// from "never attempted".
    ///
    /// Values follow the `dark:<reason>` convention:
    /// - `"dark:providerOptOut"` — the corpus's embedding provider has no float lane.
    /// - `"dark:noFloatRows"` — no float vectors are stored (corpus ingested with a
    ///   non-float provider, or no documents ingested yet).
    /// - `"dark:storeError"` — the vector store threw; error already logged by CorpusKit.
    /// - `"dark:emptyQuery"` — query text is nil or empty; the float index cannot
    ///   be queried without a query string. Set by the outer guard (no corpus entry
    ///   attempted) or by the per-signal `emptyQuery` outcome (corpus present, text
    ///   guard fired inside the dense block).
    /// - `"dark:noCorpus"` — no CorpusKit is registered for this estate handle;
    ///   the dense lane was never attempted. Previously serialized as nil (indistinguishable
    ///   from "active"), now always carries this explicit tag so the consumer can
    ///   distinguish "corpus not configured" from "lane ran and returned hits".
    ///
    /// Callers that consume this result (e.g. the quality optimizer, NeuronKit
    /// reductions) use this field to detect misconfigured estates where the dense
    /// lane is expected but consistently dark.
    public let denseLaneStatus: String?

    /// Per-stage degradation indicators for this query.
    ///
    /// Each element names a pipeline stage that encountered a recoverable error
    /// and was skipped. The query survived by operating on whatever signals
    /// remained. An empty array means every attempted stage succeeded.
    ///
    /// Stage identifiers follow the `<lane>.<operation>` convention:
    /// - `"vectorHamming.findNearest"` — `VectorStore.findNearest` threw; the
    ///   Hamming vector lane contributed no candidates. Matrix/graph/preference
    ///   scoring is unaffected but the vector column is absent from hit scores.
    /// - `"corpus.embed"` — the embedding call inside `compileSketch` threw;
    ///   the vector lane is dark for this query (same downstream effect as above,
    ///   but the failure happened one step earlier).
    /// - `"pool.getDrawers"` — `estate.getDrawers` threw while loading the
    ///   structured pool that feeds matrix, graph, and preference scoring.
    ///   All three scoring stages produced zero-scores for this query; results
    ///   are ranked on locus/BM25/vector signals only.
    /// - `"pool.hydrateBodies.mmr"` — `estate.hydrateBodies` threw during the
    ///   MMR content-hydration step (step 9.5). MMR ran on the sourceMask
    ///   Jaccard proxy instead of content shingles; selection order may differ
    ///   from the fully-hydrated path.
    /// - `"pool.hydrateBodies.return"` — `estate.hydrateBodies` threw during
    ///   the late-hydration step for the returned top-k (step 10.5). Returned
    ///   hits carry empty `content` fields for a `.structured` recall.
    /// - `"hybrid.getDrawers"` — `estate.getDrawers` threw while loading the
    ///   frontier candidates for the `hybrid` lane. BM25/vector hits that were
    ///   not already in the locus index are absent from the result set.
    /// - `"corpusOnly.getDrawers"` — same as above for the `corpusOnly` lane.
    /// - `"locus.liveRows.readFailed"` — the LocusKit recall bounded corpus
    ///   scan failed inside `estate.recall`; the locus lane contributed no
    ///   rows for a reason OTHER than an empty estate. Surfaced via the
    ///   `RecallStream.degradedStages` channel (P0-5 sites 1-5).
    /// - `"locus.roomFingerprints.readFailed"` — the recall fingerprint-pruning
    ///   path could not enumerate room fingerprints; same channel.
    /// - `"locus.roomDrawerRead.readFailed"` — a surviving room's drawer read
    ///   failed during fingerprint-pruned recall; same channel.
    /// - `"locus.bitmapEval.failed"` — the recall bitmap evaluator threw; same
    ///   channel. These four `locus.*` stages are how a FAILED locus recall is
    ///   distinguished from a GENUINE-EMPTY estate (which records nothing).
    ///
    /// A second class of identifiers names a SCORING FALLBACK — the caller
    /// requested a scoring strategy that is not a distinct implementation in
    /// that lane, so the director applied a simpler combiner. The query
    /// succeeded; this entry names the fallback so the caller knows the
    /// requested scoring was not the one applied. Genuinely-implemented combos
    /// (`unionBest` + `matrixAware`, the full weighted pipeline; `hybrid` /
    /// `corpusOnly` + `rrf`, real RRF fusion) record nothing.
    /// - `"locusOnly.matrixAware"` — `matrixAware` requested on `locusOnly`,
    ///   which has no matrix pass; returned raw bitmap-evaluator ordering.
    /// - `"corpusOnly.matrixAware"` — `matrixAware` requested on `corpusOnly`,
    ///   which has no matrix pass; fell back to RRF fusion of BM25 + vector.
    /// - `"hybrid.matrixAware"` — `matrixAware` requested on `hybrid`, which has
    ///   no matrix pass; fell back to three-way RRF fusion.
    /// - `"unionBest.rrf"` — `rrf` requested on `unionBest`, which has no
    ///   distinct equal-weight RRF fusion across lane scores; fell back to the
    ///   raw (`buffer.final`) lane-normalised score.
    ///
    /// Scoring-stage failures always DEGRADE (query survives on remaining
    /// signals). Estate-unavailable failures throw instead of degrading — they
    /// surface as `GeniusLocusKitError.estateNotOpen` before any stage runs.
    ///
    /// Counterpart telemetry: each degraded stage emits a
    /// `glk.recall.<stage>_degraded` counter tagged with `estate_id` and
    /// `lane`. Consumers can correlate this field with the Intellectus counter
    /// stream for per-estate health dashboards.
    public let degradedStages: [String]

    /// Convenience accessor — the hydrated `Drawer` for each hit that has one.
    public var drawers: [LocusKit.Drawer] { hits.compactMap(\.drawer) }
}
