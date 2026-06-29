// ReductionComposition.swift
//
// A REDUCTION COMPOSITION is a declarative recipe: an ordered, weighted list of
// signal components folded into one precision score per candidate, then a
// BOUNDED top-k re-rank. It is the data-driven unit the optimizer enumerates —
// adding a composition is a registry entry, not a new type.
//
// The bounded-reduce discipline (the matrixAware over-prune lesson): a
// composition only RE-ORDERS the coarse pool and truncates to the caller's
// `limit`; it never prunes the pool below the coarse grab. The true target,
// once surfaced by the coarse grab, can never be dropped out of the returned
// set — found@10 holds while found@1/MRR lift.
//
// Determinism: the fold is a pure function of (query, candidates). The final
// sort is stable by construction — precision score descending, then candidate
// content ascending (tie-break on content string for determinism across runs),
// then coarse-pool rank ascending (last resort for identical-content pairs) —
// so the reduce is bit-reproducible across the Swift and Rust ports.

import Foundation

extension NeuronKit {

    /// One weighted term in a composition: a signal and its non-negative weight.
    /// A weight of 0 disables the term; the catalogue uses 1.0 for single-signal
    /// compositions and tuned weights for the weighted-all composition.
    public struct WeightedSignal: Sendable, Equatable, Codable {
        /// The signal component to evaluate.
        public let signal: ReductionSignal
        /// The non-negative weight applied to this signal's [0, 1] score.
        public let weight: Double

        /// Build a weighted term. `weight` defaults to 1.0 (the single-signal case).
        public init(_ signal: ReductionSignal, weight: Double = 1.0) {
            self.signal = signal
            self.weight = weight
        }
    }

    /// A named, declarative reduction composition: a weighted sum of signal
    /// components plus the bounded-reduce policy. Pure and deterministic.
    public struct ReductionComposition: Sendable, Equatable, Codable {
        /// The composition's stable name — the gauntlet column id and the
        /// `composition` arg value on `moot_recall_precise`.
        public let name: String
        /// The weighted signal terms summed into the per-candidate precision
        /// score. Set-level signals (`mmr`, `assembly`) are applied after the
        /// weighted-sum sort: `mmr` as a diversity re-rank, `assembly` as a
        /// split-fact partner expansion, both in declaration order.
        public let terms: [WeightedSignal]
        /// The MMR trade-off λ for the `mmr` re-rank term, in [0, 1]. 1.0 is
        /// pure relevance (no diversity); lower values trade relevance for
        /// diversity. Ignored when no `mmr` term is present.
        public let mmrLambda: Double

        /// Build a composition. `mmrLambda` defaults to 0.7 (the HybridRecall
        /// default) and is used only when a term names `mmr`.
        public init(name: String, terms: [WeightedSignal], mmrLambda: Double = 0.7) {
            self.name = name
            self.terms = terms
            self.mmrLambda = mmrLambda
        }

        /// The per-candidate terms (everything except the set-level `mmr`).
        var perCandidateTerms: [WeightedSignal] { terms.filter { !$0.signal.isSetLevel } }

        /// True when this composition includes an `mmr` diversity re-rank pass.
        var hasMMR: Bool { terms.contains { $0.signal == .mmr } }

        /// True when this composition includes the `assembly` split-fact
        /// expansion pass.
        var hasAssembly: Bool { terms.contains { $0.signal == .assembly } }

        /// The per-candidate terms that read NO content (the dense signals):
        /// the narrow-then-hydrate reduce scores these over the wide pool
        /// body-free, before any hydration.
        var densePerCandidateTerms: [WeightedSignal] {
            perCandidateTerms.filter { !$0.signal.needsContent }
        }

        /// The per-candidate terms that read content (`text`, `tokenExact`):
        /// evaluated only after the survivors are hydrated.
        var contentPerCandidateTerms: [WeightedSignal] {
            perCandidateTerms.filter { $0.signal.needsContent }
        }

        /// True when this composition needs a hydrated body for ANY term — a
        /// content per-candidate term or the content-shingle `mmr` re-rank.
        /// When false, the narrow-then-hydrate reduce never hydrates at all.
        var needsContent: Bool { terms.contains { $0.signal.needsContent } }
    }

    /// Reduce `candidates` under `composition` against `query`, returning the
    /// top `limit` in precision order.
    ///
    /// Steps:
    ///   1. WEIGHTED SUM — each candidate's precision is the weighted sum of its
    ///      per-candidate signal scores. With no per-candidate term (a pure
    ///      `mmr` composition) every candidate ties at 0 and the coarse order is
    ///      preserved into the MMR pass.
    ///   2. STABLE SORT — descending by precision, tie-broken by ascending
    ///      coarse-pool rank, so the reduce is deterministic.
    ///   3. MMR RE-RANK (optional) — if the composition names `mmr`, apply a
    ///      content-shingle diversity re-rank over the sorted pool (vector-free,
    ///      the same proxy `HybridRecallEngine` uses under invariant B-1).
    ///   4. BOUNDED TRUNCATE — return the top `limit`. The pool is never pruned
    ///      below `limit`; the reduce only re-orders and truncates.
    ///
    /// - Parameters:
    ///   - composition: the named weighted composition to apply.
    ///   - query: the query context (text + optional lattice anchor).
    ///   - candidates: the coarse-grab pool, in coarse order (index = coarse rank).
    ///   - limit: how many ranked candidates to return.
    /// - Returns: up to `limit` candidates, descending by composition precision.
    public static func reduce(
        composition: ReductionComposition,
        query: ReductionQuery,
        candidates: [ReductionCandidate],
        limit: Int
    ) -> [ReductionCandidate] {
        guard !candidates.isEmpty, limit > 0 else { return [] }

        // 1. WEIGHTED SUM per candidate over the per-candidate terms.
        let perTerms = composition.perCandidateTerms
        let scored: [(candidate: ReductionCandidate, precision: Double)] =
            candidates.map { candidate in
                var sum = 0.0
                for term in perTerms where term.weight != 0 {
                    sum += term.weight * reductionScore(term.signal, query: query, candidate: candidate)
                }
                return (candidate, sum)
            }
        // Stamp each candidate with its composition precision score so callers
        // (e.g. PreciseRecall) can surface the re-rank score rather than the
        // coarse fusion score (`score.final`). Discrimination classification and
        // PreciseMatch.score should reflect the composition's correctness, not
        // the coarse lane's spread.
        let stamped: [ReductionCandidate] = scored.map { item in
            ReductionCandidate(
                id: item.candidate.id, content: item.candidate.content,
                room: item.candidate.room, score: item.candidate.score,
                udcCode: item.candidate.udcCode, udcFacets: item.candidate.udcFacets,
                coarseRank: item.candidate.coarseRank, eventTime: item.candidate.eventTime,
                isCurrentlyBelieved: item.candidate.isCurrentlyBelieved,
                precisionScore: item.precision)
        }

        // 2. STABLE SORT: precision desc, then a CONTENT-stable tie-break.
        //    Equal-precision near-duplicates are ordered by their content
        //    lexicographically, then by coarse rank as a final fallback. The
        //    content tie-break (not the coarse rank alone) is what makes the
        //    reduce DETERMINISTIC ACROSS RUNS: the coarse-grab pool order is
        //    itself unstable run-to-run because the backend mints a random UUID
        //    per drawer and the GLK RRF fusion tie-breaks equal lane scores on
        //    that UUID, so two runs over identical content produce different
        //    coarse orders. Tie-breaking the reduce on the stable content string
        //    removes that dependence: identical content → identical reduce order,
        //    regardless of which run minted which id. Coarse rank remains the
        //    last resort for the (degenerate) identical-content case.
        // Sort on the stamped candidates (each carries its precisionScore).
        var ranked = stamped.sorted { lhs, rhs in
            if lhs.precisionScore != rhs.precisionScore { return lhs.precisionScore > rhs.precisionScore }
            if lhs.content != rhs.content { return lhs.content < rhs.content }
            return lhs.coarseRank < rhs.coarseRank
        }

        // 3. MMR RE-RANK (optional, set-level): re-order the sorted pool to
        //    penalize content redundancy, λ-weighted against the position-derived
        //    relevance. Vector-free shingle proxy (B-1), deterministic.
        if composition.hasMMR {
            ranked = mmrDiversityRerank(ranked, lambda: composition.mmrLambda)
        }

        // 3b. ASSEMBLY EXPANSION (optional, set-level): for each ranked
        //     candidate carrying a reference code, pull its split-fact partner
        //     (the pool record sharing that code) up to immediately follow it,
        //     so both halves of a split fact are co-surfaced inside the bounded
        //     window. Runs over the WHOLE ranked pool before the truncate, so a
        //     partner sitting past `limit` is promoted into the returned set.
        if composition.hasAssembly {
            ranked = assemblyExpand(ranked)
        }

        // 4. BOUNDED TRUNCATE — never below the coarse pool; just the top `limit`.
        return Array(ranked.prefix(limit))
    }

    /// NARROW-THEN-HYDRATE reduce — the dense-first body-saving path.
    ///
    /// Runs the composition's BODY-FREE (dense) signals over the entire wide
    /// pool first, narrows to a bounded survivor set on that dense score, and
    /// ONLY THEN hydrates the survivors' bodies (via `hydrate`) to evaluate the
    /// content signals (`text`/`tokenExact`) and the content-shingle `mmr`
    /// re-rank. The wide pool's bodies are never read — bodies are read for the
    /// survivors alone.
    ///
    /// Equivalence with `reduce`:
    ///   - PURE-DENSE composition (no content term): identical ranking; the wide
    ///     SELECTION pool is scored body-free (the latency win), then the FINAL
    ///     top-k alone are hydrated for OUTPUT — the returned records always
    ///     carry their bodies. Hydration is bounded to ≈ `limit` records, not the
    ///     pool, so the body-free selection win holds.
    ///   - CONTENT-ONLY composition (no dense term, e.g. the default `text`):
    ///     there is no dense signal to narrow on, so EVERY candidate is a
    ///     survivor and the result is bit-identical to `reduce` — no body saving,
    ///     no regression. The default recipe is unchanged.
    ///   - MIXED composition: the dense signals pre-rank the pool; the top
    ///     `max(limit · survivorMultiple, limit)` survivors (clamped to the pool)
    ///     are hydrated and the FULL composition re-scores them. `survivorMultiple`
    ///     is generous by default so a content-promotable candidate is not pruned
    ///     before hydration — the over-prune lesson; the gauntlet confirms
    ///     found@k holds. The bounded reduce never returns fewer than the coarse
    ///     grab would.
    ///
    /// - Parameters:
    ///   - composition: the named weighted composition to apply.
    ///   - query: the query context (text + optional lattice anchor).
    ///   - candidates: the wide coarse pool, in coarse order (index = coarse rank).
    ///     Candidates carry the dense signal already (Step 2); their `content`
    ///     is expected to be EMPTY (body-free) and is filled by `hydrate`.
    ///   - limit: how many ranked candidates to return.
    ///   - survivorMultiple: survivor-set size as a multiple of `limit` for a
    ///     mixed composition. Defaults to 8 — a few× the limit, bounded.
    ///   - hydrate: an async closure that, given a survivor id set, returns each
    ///     id's body text. This is the GLK-owned late-hydration capability
    ///     passed down from the recipe; NeuronKit never reaches the store itself.
    /// - Returns: up to `limit` candidates, descending by composition precision,
    ///   each survivor carrying its hydrated body.
    public static func reduceLate(
        composition: ReductionComposition,
        query: ReductionQuery,
        candidates: [ReductionCandidate],
        limit: Int,
        survivorMultiple: Int = 8,
        hydrate: ([String]) async throws -> [String: String]
    ) async throws -> [ReductionCandidate] {
        guard !candidates.isEmpty, limit > 0 else { return [] }

        // PURE-DENSE shortcut (SELECTION lane, body-free). When the composition
        // needs no content at all, `reduce` SELECTS the final top-k touching no
        // body — but the SELECTION lane carries empty content. The two-lane
        // principle: the unhydrated lane SELECTS; the OUTPUT must always be
        // MATERIALIZED. So we hydrate the SELECTED top-k (≈ `limit` records, not
        // the wide pool) before returning, preserving the body-free latency win
        // on the wide SELECTION while still returning non-empty content.
        if !composition.needsContent {
            let selected = reduce(composition: composition, query: query,
                                  candidates: candidates, limit: limit)
            return try await hydrateCandidates(selected, using: hydrate)
        }
        if composition.densePerCandidateTerms.isEmpty {
            // No dense signal to narrow on: hydrate the whole pool, then reduce.
            // The returned top-k are already materialized by this full-pool
            // hydration — no separate final-output pass needed.
            let hydrated = try await hydrateCandidates(candidates, using: hydrate)
            return reduce(composition: composition, query: query,
                          candidates: hydrated, limit: limit)
        }

        // MIXED: rank the pool body-free on the dense terms, keep the top
        // survivors, hydrate only those, then run the FULL composition on them.
        let denseTerms = composition.densePerCandidateTerms
        let denseScored: [(candidate: ReductionCandidate, dense: Double)] =
            candidates.map { candidate in
                var sum = 0.0
                for term in denseTerms where term.weight != 0 {
                    sum += term.weight * reductionScore(term.signal, query: query, candidate: candidate)
                }
                return (candidate, sum)
            }
        // Stable dense sort: dense score desc, then coarse rank asc (the pool's
        // bodies are empty here, so the content tie-break of `reduce` is not
        // available pre-hydration — coarse rank is the deterministic fallback).
        let denseRanked = denseScored.sorted { lhs, rhs in
            if lhs.dense != rhs.dense { return lhs.dense > rhs.dense }
            return lhs.candidate.coarseRank < rhs.candidate.coarseRank
        }.map(\.candidate)

        // Bounded survivor set: a few× the limit, never below `limit`, never
        // above the pool. The true target cannot be pruned out of a generous
        // survivor window before content has a chance to promote it.
        // Safe multiplication: limit * survivorMultiple can overflow when both
        // values are large; report the overflow and clamp to pool size instead
        // of returning a silently-wrong negative count. (NK-8 planned hardening)
        let (product, overflowed) = limit.multipliedReportingOverflow(by: max(survivorMultiple, 1))
        let survivorCount = min(candidates.count, max(limit, overflowed ? candidates.count : product))
        let survivors = Array(denseRanked.prefix(survivorCount))

        // Hydrate ONLY the survivors, then run the FULL composition (dense +
        // content + optional mmr) over them via the shared `reduce`.
        let hydrated = try await hydrateCandidates(survivors, using: hydrate)
        return reduce(composition: composition, query: query,
                      candidates: hydrated, limit: limit)
    }

    /// Hydrate a candidate set: fetch each id's body via `hydrate` and return
    /// copies carrying that content. Candidates with no body returned keep their
    /// existing (empty) content. Order is preserved. Note: the reconstructed
    /// copy does NOT carry `eventTime` or `isCurrentlyBelieved` — those are
    /// populated by the reduce fold, not the hydrate step. A `hydrate` failure
    /// propagates — the caller decides whether an unhydratable survivor set is a
    /// failed result (it is, for fail-closed recall) rather than this helper
    /// silently returning body-free candidates.
    static func hydrateCandidates(
        _ candidates: [ReductionCandidate],
        using hydrate: ([String]) async throws -> [String: String]
    ) async throws -> [ReductionCandidate] {
        let bodies = try await hydrate(candidates.map(\.id))
        return candidates.map { c in
            guard let body = bodies[c.id], body != c.content else { return c }
            // Preserve precisionScore: it is set by the reduce fold AFTER
            // hydration (for mixed compositions) or carried through unchanged
            // (for pure-dense compositions). The hydrate step only fills bodies;
            // it must not reset the precision score.
            // Preserve eventTime and isCurrentlyBelieved: these are structural
            // columns read at body-free hydration time (pool load) and must
            // survive the content-fill hydration step. Losing them silently
            // drops temporal state from the candidate before the precision fold
            // and the T3 temporal scorer reads them. (NK-7 planned hardening)
            return ReductionCandidate(
                id: c.id, content: body, room: c.room, score: c.score,
                udcCode: c.udcCode, udcFacets: c.udcFacets, coarseRank: c.coarseRank,
                eventTime: c.eventTime, isCurrentlyBelieved: c.isCurrentlyBelieved,
                precisionScore: c.precisionScore)
        }
    }

    /// Content-shingle MMR diversity re-rank over an already-relevance-ordered
    /// pool. Relevance is the pool POSITION (1.0 at the front, decaying to 0 at
    /// the back) — the composition has already ranked by precision, so MMR here
    /// trades that precision order against content diversity rather than
    /// recomputing relevance. Similarity is the 3-gram shingle Jaccard the rest
    /// of NeuronKit uses (vector-free, B-1). Deterministic: ties resolve to the
    /// earlier pool position.
    ///
    /// `MMR(i) = λ · relevance(i) − (1−λ) · maxSim(i, selected)`.
    static func mmrDiversityRerank(
        _ pool: [ReductionCandidate],
        lambda: Double
    ) -> [ReductionCandidate] {
        let n = pool.count
        guard n > 1 else { return pool }
        // Guard NaN: IEEE 754 comparisons with NaN always return false, so a NaN
        // lambda passes through min/max unchanged and then propagates to every MMR
        // score, making all scores NaN. NaN > -inf is false, so bestIdx stays -1
        // and the pool loop writes out-of-bounds. Default NaN to 0.5 (equal weight
        // between relevance and diversity — the neutral MMR operating point).
        // Mirrors Rust mmr_diversity_rerank NaN guard. (NK-9 planned hardening)
        let lam = lambda.isNaN ? 0.5 : min(max(lambda, 0), 1)

        // Position-derived relevance: front of the pool is most relevant.
        // relevance(i) = (n - i) / n, in (0, 1], strictly decreasing.
        let relevance = (0..<n).map { Double(n - $0) / Double(n) }

        var selected: [Int] = []
        selected.reserveCapacity(n)
        var isSelected = [Bool](repeating: false, count: n)
        var maxSim = [Double](repeating: 0, count: n)

        while selected.count < n {
            var bestIdx = -1
            var bestScore = -Double.infinity
            for i in 0..<n where !isSelected[i] {
                let score = lam * relevance[i] - (1 - lam) * maxSim[i]
                // Strict `>` plus ascending scan = earliest-position tie-break.
                if score > bestScore {
                    bestScore = score
                    bestIdx = i
                }
            }
            isSelected[bestIdx] = true
            selected.append(bestIdx)
            // Fold the pick into every remaining candidate's running max sim.
            let pickContent = pool[bestIdx].content
            for i in 0..<n where !isSelected[i] {
                let sim = Double(HybridRecallEngine.shingleSimilarity(pool[i].content, pickContent))
                if sim > maxSim[i] { maxSim[i] = sim }
            }
        }
        return selected.map { pool[$0] }
    }

    /// SPLIT-FACT ASSEMBLY EXPANSION (T4). A split fact lives in two records
    /// linked by a shared reference code (`REF-NNNN`): one half states the fact
    /// exists under a code, the other holds the value keyed by the same code.
    /// Answering the query needs BOTH, but only one half ranks for the query —
    /// so a pure re-rank cannot complete the answer; the partner must be PULLED
    /// IN. This pass scans the ranked pool in order and, for each candidate
    /// carrying a reference code, promotes the FIRST not-yet-emitted partner
    /// record sharing that code to immediately follow it. The result is the same
    /// candidates, re-ordered so every split pair is adjacent and inside the
    /// bounded window — a recall EXPANSION over the surfaced set, not a score.
    ///
    /// Mechanism scope (honest flag): this links partners by the REF token
    /// carried in CONTENT, which is the join the gauntlet's T4 tier plants and
    /// the general case for free-text references. The substrate also models
    /// explicit links as Tunnel edges (`sourceDrawerId → targetDrawerId`); a
    /// tunnel-driven expansion that follows those edges (pulling a partner that
    /// shares NO token with the query) is the next increment and is NOT done
    /// here — this pass sees only what the reduction pool carries, and the pool
    /// has no tunnel edges. For the token-linked split it is complete.
    ///
    /// Deterministic: a single stable forward scan; ties (a code with several
    /// candidate partners) resolve to the earliest-ranked partner. Idempotent —
    /// re-running over an already-assembled pool is a no-op.
    static func assemblyExpand(_ pool: [ReductionCandidate]) -> [ReductionCandidate] {
        let n = pool.count
        guard n > 1 else { return pool }

        // Precompute each candidate's reference codes (most carry none).
        let codes: [Set<String>] = pool.map { referenceCodes(in: $0.content) }

        var emitted = [Bool](repeating: false, count: n)
        var out: [ReductionCandidate] = []
        out.reserveCapacity(n)

        for i in 0..<n {
            if emitted[i] { continue }
            emitted[i] = true
            out.append(pool[i])
            guard !codes[i].isEmpty else { continue }
            // Pull the first not-yet-emitted partner sharing any of i's codes,
            // scanning forward from the front so the earliest-ranked partner
            // wins deterministically.
            for j in 0..<n where !emitted[j] && j != i {
                if !codes[i].isDisjoint(with: codes[j]) {
                    emitted[j] = true
                    out.append(pool[j])
                    break
                }
            }
        }
        return out
    }

    /// Extract reference codes of the form `REF-NNNN` (case-insensitive `ref`
    /// prefix, a hyphen, then digits) from `content`. The split-fact join key.
    /// Returns a set so a record naming several codes links to each partner.
    /// Pure and deterministic; uses Unicode `isLetter`/`isNumber` character
    /// properties (not ASCII-restricted).
    static func referenceCodes(in content: String) -> Set<String> {
        guard !content.isEmpty else { return [] }
        var codes: Set<String> = []
        // Token scan: split on non-alphanumeric-and-non-hyphen, keep tokens that
        // look like ref-<digits>. Folded to lowercase so REF-0042 == ref-0042.
        let tokens = content.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" }
        for token in tokens {
            guard token.hasPrefix("ref-") else { continue }
            let suffix = token.dropFirst(4)
            if !suffix.isEmpty && suffix.allSatisfy({ $0.isNumber }) {
                codes.insert(String(token))
            }
        }
        return codes
    }
}
