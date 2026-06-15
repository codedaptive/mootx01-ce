// ReductionSignals.swift
//
// The composable precise-reduction signal components — the building blocks of
// the reduction ablation harness. Each signal is a PURE, DETERMINISTIC
// per-candidate scorer in [0, 1] over (query, candidate). A candidate carries
// the dense recall signal (the Step-2 `RecallScoreVector`: integer Hamming
// distance, per-lane bm25/vector/coOccurrence, the lattice anchor) plus the
// hydrated content — everything a reducer needs to rank the EXACT answer above
// its near-duplicate distractors.
//
// This is the catalogue the optimizer ablates over. No signal is pre-judged:
// the gauntlet ranks them. Adding a signal is a new `case` + one scorer arm;
// composing them is data-driven (`ReductionComposition`), not a new type per
// recipe.
//
// Layering (B-1, verified Kong review): NeuronKit imports GeniusLocusKit and
// reads its output value types (`RecallHit`, `RecallScoreVector`, `Drawer`) —
// legal, NK depends on GLK. GLK never imports NeuronKit; the reduction climbs
// no recipe knowledge into GLK. Every field a signal reads is a GLK-or-below
// value type, so no inversion.
//
// Determinism: no clock, no RNG, no locale-sensitive transform beyond
// `lowercased()` (ASCII-folded, matching the Rust port's `to_lowercase()` on
// the conformance vectors). Every signal is a total function of its inputs.

import Foundation
import GeniusLocusKit
import LocusKit

extension NeuronKit {

    /// One candidate handed to the reduction signals: the dense recall signal
    /// (`score`) plus the hydrated content and the lattice anchor. Built from a
    /// GLK `RecallHit` by `from(hit:coarseRank:)`. The `coarseRank` is the
    /// candidate's 0-based position in the coarse-grab pool — the deterministic
    /// tie-break basis so equal-precision near-duplicates keep the coarse lane's
    /// order (and the reduce is bit-reproducible).
    /// Not `Equatable`: the embedded `RecallScoreVector` is `Sendable` but not
    /// `Equatable`, and candidates are compared by `id` where identity is needed.
    public struct ReductionCandidate: Sendable {
        /// The drawer's stable row id.
        public let id: String
        /// The drawer's content (empty when the hit was not hydrated).
        public let content: String
        /// The drawer's room (echoed for serialization parity).
        public let room: String
        /// The dense per-lane recall signal carried from GLK (Step 2): integer
        /// Hamming distance, per-lane bm25/vector/coOccurrence, final fused score.
        public let score: RecallScoreVector
        /// The candidate's UDC lattice code (`""` when unanchored).
        public let udcCode: String
        /// The candidate's optional UDC facet expression.
        public let udcFacets: String?
        /// The candidate's 0-based rank in the coarse-grab pool. The
        /// deterministic tie-break key for the bounded reduce.
        public let coarseRank: Int
        /// The candidate's event time (when the recorded thing happened/was
        /// authored), or `nil` when the hit carried no structured drawer. Read
        /// BODY-FREE: `eventTime` is a structured column preserved at the
        /// `.bitmapOnly` hydration the precise pool loads at, so the temporal
        /// signal can prefer the more-recent record without reading any body.
        public let eventTime: Date?
        /// Whether the candidate is in a currently-believed state (drawer state
        /// Cluster A: active/pending/contested/accepted) versus a superseded or
        /// terminal one. Read BODY-FREE from the drawer's adjective state
        /// bitmap. The temporal signal prefers a currently-believed record over
        /// a superseded one — the structural, dream-independent half of T3.
        public let isCurrentlyBelieved: Bool

        /// Memberwise initializer.
        public init(
            id: String, content: String, room: String,
            score: RecallScoreVector, udcCode: String, udcFacets: String?,
            coarseRank: Int, eventTime: Date? = nil, isCurrentlyBelieved: Bool = true
        ) {
            self.id = id
            self.content = content
            self.room = room
            self.score = score
            self.udcCode = udcCode
            self.udcFacets = udcFacets
            self.coarseRank = coarseRank
            self.eventTime = eventTime
            self.isCurrentlyBelieved = isCurrentlyBelieved
        }

        /// Build a reduction candidate from a GLK recall hit at coarse-pool
        /// position `coarseRank`. An unhydrated hit (no drawer) yields empty
        /// content and an unanchored lattice — those candidates score the
        /// content/lattice signals at the neutral floor and sort by the dense
        /// lanes alone. The structured temporal fields (`eventTime`, the state
        /// cluster) come from the drawer's BODY-FREE columns, preserved at the
        /// `.bitmapOnly` hydration the precise pool loads at, so they are
        /// available even on an unhydrated (body-free) candidate.
        public static func from(hit: RecallHit, coarseRank: Int) -> ReductionCandidate {
            ReductionCandidate(
                id: hit.id,
                content: hit.drawer?.content ?? "",
                room: hit.drawer?.room ?? "",
                score: hit.score,
                udcCode: hit.drawer?.udcCode ?? "",
                udcFacets: hit.drawer?.udcFacets,
                coarseRank: coarseRank,
                eventTime: hit.drawer?.eventTime,
                isCurrentlyBelieved: hit.drawer?.state.isClusterA ?? true)
        }
    }

    /// The query side a signal scores against: the raw query text plus its
    /// optional lattice anchor (the region the query is "about"). When the query
    /// carries no anchor the `lattice` signal returns its neutral value.
    public struct ReductionQuery: Sendable, Equatable {
        /// The raw query text.
        public let text: String
        /// The query's UDC lattice code, or `""` when the query is unanchored.
        public let udcCode: String

        /// Build a query context. `udcCode` defaults to unanchored.
        public init(text: String, udcCode: String = "") {
            self.text = text
            self.udcCode = udcCode
        }
    }

    /// A named precise-reduction signal component. Each case is a pure
    /// per-candidate scorer in [0, 1]; `mmr` is the one re-rank-over-the-set
    /// signal and is handled by the composition fold, not by `score`.
    ///
    /// The catalogue is OPEN — adding a signal is a new case plus one arm in
    /// `score(query:candidate:)`. None is pre-judged; the gauntlet ranks them.
    public enum ReductionSignal: String, Sendable, CaseIterable, Codable {
        /// Content-word match (reuses `NeuronKit.queryPrecision`): the fraction
        /// of the query's content words present in the candidate, plus the
        /// distinctive-token bonus. The "46 vs 11" separator's coarse half.
        case text
        /// Vector closeness from the integer Hamming distance:
        /// `(256 - distance) / 256`. The sentinel (no vector-lane hit) → 0.
        case hamming
        /// Matrix co-occurrence signal carried from GLK (`score.coOccurrence`).
        case matrix
        /// Lattice proximity: how close the candidate's UDC code is to the
        /// query's UDC region. Neutral (0.5) when the query is unanchored.
        case lattice
        /// The raw BM25 lane score, squashed into [0, 1].
        case bm25
        /// The raw vector lane similarity (already normalized in [0, 1]).
        case vector
        /// DENSE FLOAT cosine similarity carried from GLK (`score.dense`): the
        /// TRUE float-embedding lane (Lane D), already normalized to [0, 1] as
        /// `(cosine + 1) / 2`. Body-free (dense): it reads the cosine the GLK
        /// dense lane computed, not the candidate's content, so it ranks an
        /// answer statement above a near-duplicate of the question — the case
        /// the 256-bit SimHash `hamming`/`vector` columns cannot separate. The
        /// sentinel (no dense-lane hit) is 0, sorting such candidates below any
        /// real dense match on this signal alone.
        case dense
        /// Exact distinctive-token / numeric match: does the candidate contain
        /// the query's distinctive tokens (numbers, proper nouns)? The fine
        /// discriminator — the literal "46 vs 11" separator.
        case tokenExact
        /// TEMPORAL CURRENCY from STRUCTURE (T3, dense/body-free). Prefers a
        /// currently-believed record (drawer state Cluster A) over a superseded
        /// one, and the more-recent `eventTime`. Reads only structured columns
        /// preserved at `.bitmapOnly`, so it needs no body and is independent of
        /// the dreaming pass. On a corpus that varies state/eventTime per
        /// version it is the load-bearing temporal discriminator; on the
        /// gauntlet (which encodes currency in CONTENT, not in these fields) it
        /// is uniform — see `temporalText` for the content-marker half.
        case temporalState
        /// TEMPORAL CURRENCY from CONTENT (T3, needs body). Rewards an explicit
        /// "current as of <year>" currency marker and penalizes a "superseded"
        /// marker in the candidate's text, breaking the tie between an
        /// up-to-date fact and a stale earlier version that shares every content
        /// word. This is the content-side half of T3 — the discriminator the
        /// gauntlet's T3 tier actually plants (the structural `temporalState`
        /// half is uniform there because every version is filed active at one
        /// instant).
        case temporalText
        /// SPLIT-FACT ASSEMBLY (T4, set-level expansion). A reference code
        /// (`REF-NNNN`) in one record points at a partner record keyed by the
        /// same code; neither alone answers the query. This signal is a
        /// set-level EXPANSION (like `mmr`): after ranking, for each surfaced
        /// candidate carrying a reference code it pulls the partner record that
        /// shares that code up to immediately follow it, so both halves of the
        /// split fact are co-surfaced in the bounded set. Handled by the
        /// composition fold, not by the per-candidate `score`.
        case assembly
        /// Diversity re-rank (MMR). A set-level signal: it re-orders the pool to
        /// penalize redundancy. Handled by the composition fold via `mmrRank`,
        /// not by the per-candidate `score`.
        case mmr

        /// True when this signal is a set-level re-rank/expansion (`mmr`,
        /// `assembly`) rather than a pure per-candidate scorer. The composition
        /// fold routes these specially.
        public var isSetLevel: Bool { self == .mmr || self == .assembly }

        /// True when this signal reads the candidate's TEXT CONTENT (the body).
        /// The dense-first divide: `text` and `tokenExact` score over the
        /// content string, and `mmr` diversifies on content shingles, so all
        /// three need a hydrated body. `hamming`/`matrix`/`lattice`/`bm25`/
        /// `vector` score purely on the dense signal (Hamming distance, lane
        /// scores, UDC lattice) carried on the candidate WITHOUT a body. The
        /// narrow-then-hydrate reduce runs the body-free signals over the wide
        /// pool first, then hydrates only the survivors before evaluating the
        /// content signals — so the wide pool's bodies are never read.
        /// Layered over the new structural signals: `temporalText` scores over
        /// the currency markers in the body, and `assembly` reads reference
        /// codes out of the body to link split halves, so both need a hydrated
        /// body. `temporalState` reads only the body-free structured columns
        /// (state cluster, eventTime), so it is dense like the other dense
        /// lanes.
        public var needsContent: Bool {
            switch self {
            case .text, .tokenExact, .mmr, .temporalText, .assembly: return true
            case .hamming, .matrix, .lattice, .bm25, .vector, .dense, .temporalState: return false
            }
        }
    }

    // MARK: - Per-candidate scorers

    /// Score `candidate` under `signal` against `query`, in [0, 1]. For the
    /// set-level `mmr` signal this returns 0 (it is applied by the composition
    /// fold, not per-candidate); call `score` only for per-candidate signals.
    ///
    /// - Parameters:
    ///   - signal: which signal component to evaluate.
    ///   - query: the query context (text + optional lattice anchor).
    ///   - candidate: the candidate carrying its dense signal + content.
    /// - Returns: a deterministic score in [0, 1].
    public static func reductionScore(
        _ signal: ReductionSignal,
        query: ReductionQuery,
        candidate: ReductionCandidate
    ) -> Double {
        switch signal {
        case .text:
            // Coarse content-word match + distinctive bonus, in [0, 1].
            return Double(queryPrecision(query: query.text, candidate: candidate.content))
        case .hamming:
            return hammingSimilarity(candidate.score.hammingDistance)
        case .matrix:
            // Co-occurrence is already a [0, 1] lane contribution; clamp for safety.
            return clamp01(Double(candidate.score.coOccurrence))
        case .lattice:
            return latticeProximity(queryCode: query.udcCode, candidateCode: candidate.udcCode)
        case .bm25:
            // BM25 is an unbounded positive score; squash monotonically into
            // [0, 1) with x/(1+x) so larger raw scores rank higher without a
            // corpus-dependent normalization constant.
            return squash(Double(candidate.score.bm25))
        case .vector:
            // The vector lane is already the normalized [0, 1] similarity.
            return clamp01(Double(candidate.score.vector))
        case .dense:
            // The dense float lane is already the normalized [0, 1] cosine
            // similarity ((cosine + 1) / 2) carried from GLK. Clamp for safety.
            return clamp01(Double(candidate.score.dense))
        case .tokenExact:
            return tokenExactRate(query: query.text, candidate: candidate.content)
        case .temporalState:
            // Body-free structural currency: a currently-believed record (state
            // Cluster A) scores 1.0; a superseded/terminal one scores 0.0. The
            // dense, dream-independent half of T3. eventTime recency is a
            // relative (pool-wide) comparison and so is not a per-candidate
            // term; the state cluster is the per-candidate structural marker.
            return candidate.isCurrentlyBelieved ? 1.0 : 0.0
        case .temporalText:
            // Content currency markers: reward an explicit "current" marker,
            // penalize a "superseded" marker. The content half of T3.
            return temporalTextScore(candidate.content)
        case .mmr, .assembly:
            // Set-level; not a per-candidate score. The composition fold handles
            // the diversity re-rank (`mmr`) and the split-fact expansion
            // (`assembly`). Returning the neutral 0.5 keeps a misuse harmless and
            // leaves the coarse order undisturbed when one of these is the only
            // term in a composition.
            return 0.5
        }
    }

    // MARK: - Signal helpers

    /// Vector closeness from an integer Hamming distance in 0…256:
    /// `(256 - distance) / 256`, so distance 0 → 1.0 and distance 256 → 0.0.
    /// The `noHammingDistance` sentinel (a hit that did not come from the vector
    /// lane) → 0, sorting such candidates below any real vector match on this
    /// signal alone.
    static func hammingSimilarity(_ distance: Int) -> Double {
        guard distance >= 0 else { return 0 }   // sentinel → 0
        let d = min(distance, 256)
        return Double(256 - d) / 256.0
    }

    /// Lattice proximity of a candidate UDC code to the query's UDC region, in
    /// [0, 1]. Deterministic, table-free: the score is the length of the shared
    /// leading prefix (in UDC notation, a longer shared prefix = a closer region)
    /// over the longer of the two codes. Exact match → 1.0; no shared prefix →
    /// 0.0. When the QUERY carries no anchor the signal is NEUTRAL (0.5) so an
    /// unanchored query neither rewards nor punishes on lattice; when the query
    /// is anchored but the CANDIDATE is not, the candidate scores 0 (it is
    /// nowhere near the query's region).
    static func latticeProximity(queryCode: String, candidateCode: String) -> Double {
        if queryCode.isEmpty { return 0.5 }            // unanchored query → neutral
        if candidateCode.isEmpty { return 0 }          // anchored query, unanchored candidate → far
        if queryCode == candidateCode { return 1.0 }
        let q = Array(queryCode)
        let c = Array(candidateCode)
        var shared = 0
        let bound = min(q.count, c.count)
        while shared < bound && q[shared] == c[shared] { shared += 1 }
        let longer = max(q.count, c.count)
        guard longer > 0 else { return 0 }
        return Double(shared) / Double(longer)
    }

    /// Monotonic squash of a non-negative raw score into [0, 1): `x / (1 + x)`.
    /// Negative inputs clamp to 0. Used for BM25, whose raw magnitude is
    /// unbounded and corpus-dependent — the squash preserves ranking without a
    /// fitted normalization constant.
    static func squash(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        return x / (1 + x)
    }

    /// Clamp a value into [0, 1].
    static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }

    /// Content-marker temporal currency in [0, 1]. A record whose text declares
    /// it is the live version ("current", "current as of …", "as of <year>")
    /// scores high; one marked stale ("superseded", "deprecated", "obsolete",
    /// "no longer", "formerly") scores low; an unmarked record is neutral (0.5)
    /// so a corpus without currency markers neither rewards nor punishes on this
    /// signal. Case-folded substring checks — deterministic and locale-stable
    /// (ASCII markers; matches the Rust port's `to_lowercase().contains`). The
    /// gauntlet's T3 tier plants exactly these markers ("current as of <year>"
    /// on the needle, "superseded; recorded <year>" on each stale version), so
    /// this is the discriminator that surfaces the current fact over its
    /// superseded near-duplicates.
    static func temporalTextScore(_ content: String) -> Double {
        guard !content.isEmpty else { return 0.5 }
        let c = content.lowercased()
        // Stale markers dominate: a record that announces it is superseded is
        // stale even if it also contains the word "current" in passing.
        let staleMarkers = ["superseded", "deprecated", "obsolete", "no longer", "formerly", "outdated"]
        for m in staleMarkers where c.contains(m) { return 0.0 }
        let currentMarkers = ["current as of", "current ", "as of ", "presently", "now in effect"]
        for m in currentMarkers where c.contains(m) { return 1.0 }
        return 0.5
    }

    /// Exact distinctive-token match rate: of the query's distinctive tokens
    /// (numbers, proper nouns — see `distinctiveTokens`), the fraction present
    /// verbatim in the candidate's token set. This is the FINE discriminator —
    /// the literal "46 vs 11" separator: among look-alikes, only the candidate
    /// that contains the queried "46" / "Versailles" scores above 0. When the
    /// query names NO distinctive token the rate is 0 (the signal abstains
    /// rather than rewarding everything equally).
    static func tokenExactRate(query: String, candidate: String) -> Double {
        let distinctive = distinctiveTokens(query)
        guard !distinctive.isEmpty else { return 0 }
        let candidateTokens = Set(wordTokens(candidate))
        guard !candidateTokens.isEmpty else { return 0 }
        let matched = distinctive.filter { candidateTokens.contains($0) }.count
        return Double(matched) / Double(distinctive.count)
    }
}
