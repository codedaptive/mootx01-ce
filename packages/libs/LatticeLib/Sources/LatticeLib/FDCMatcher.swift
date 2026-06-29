// FDCMatcher.swift
//
// FDC runtime encoder, Steps 4–5 (cookbook §5–§6): match an input text's
// concept bag against the code signatures, then descend the decimal frame to
// the most specific well-supported code.
//
//   Step 4 (§5.2/§5.3): score[code] += bag[term] for every term shared with
//                       the code's signature (inverted-index single-pass scan,
//                       the deterministic equivalent of the spec's Aho-Corasick
//                       scan over concept-id keys). Empty score -> UNRESOLVED.
//   Step 5 (§6):        start at argmax(score) (ties -> lowest code), then walk
//                       down children while a child's bag overlap meets
//                       STOP_THRESHOLD; return the deepest such code.
//
// `encode` is a pure function of the input text and the pinned artifacts
// (lexicon, signatures, frame) — the agreement property.

import Foundation

public struct FDCMatcher: Sendable {

    /// How the per-code overlap is turned into a score. The score function
    /// is applied CONSISTENTLY to both the Step-4 argmax and the Step-5
    /// descent overlap, so the descent target is always scored on the same
    /// footing as the argmax winner. The direct-construction default is
    /// `.raw`; `FDCRuntime` opts in to `.idf` (the shipped runtime mode).
    ///
    /// Over the membership signatures (a code's term SET) and the runtime bag
    /// (term -> count `n`), with overlap `O = bag ∩ sig`:
    ///   - `.raw`:       Σ_{t∈O} bag[t].                 (direct-init default)
    ///   - `.idf`:       Σ_{t∈O} bag[t]·idf(t).
    ///   - `.cosine`:    (Σ_{t∈O} bag[t]) / sqrt(|sig|).
    ///   - `.idfCosine`: (Σ_{t∈O} bag[t]·idf(t)) / sqrt(Σ_{t∈sig} idf(t)²).
    /// where idf(t) = ln(N / df(t)), N = total code signatures, df(t) = number
    /// of signatures containing t. The bag-side norm is constant across codes
    /// for a fixed query, so it is dropped from both `.cosine` and `.idfCosine`
    /// (it cannot change any argmax or descent comparison); the signature-side
    /// norm — what actually penalizes big signatures — is kept.
    public enum ScoreMode: Sendable {
        case raw, idf, cosine, idfCosine
    }

    /// Pinned descent cutoff (§6.1), default `1` (any overlap continues
    /// descent). Tuned empirically: inert across 1...200 on the v1.0 frame
    /// (shallow frame — descent rarely fires), so `1` is the pinned ship value.
    /// Accuracy is governed by within-region scoring (§5), not this cutoff.
    ///
    /// NOTE: the cutoff is compared against the RAW integer overlap (Σ bag[t]),
    /// not the normalized score, so its meaning is mode-independent — a child
    /// must still carry at least `stopThreshold` matching bag occurrences to be
    /// a descent candidate regardless of `scoreMode`. The score (which may be
    /// normalized) only ranks the candidates that clear the cutoff.
    public let stopThreshold: Int

    /// The active scoring scheme (default `.raw` reproduces ship behavior).
    public let scoreMode: ScoreMode

    private let lexicon: CanonicalizationLexicon
    private let frame: FDCFrame
    private let sigTerms: [String: Set<String>]    // code -> signature term set
    private let index: [String: [String]]          // term -> codes (sorted)

    // Precomputed at init from the signatures, so encode() does no df/idf work.
    // Empty/zero unless a mode needs them.
    private let idf: [String: Double]              // term -> ln(N / df(t))
    private let sigNorm: [String: Double]          // code -> sqrt(|sig|)        (.cosine)
    private let sigIDFNorm: [String: Double]        // code -> sqrt(Σ idf(t)²)    (.idfCosine)

    public init(
        lexicon: CanonicalizationLexicon,
        frame: FDCFrame,
        signatures: [String: Set<String>],
        stopThreshold: Int = 1,
        scoreMode: ScoreMode = .raw
    ) {
        self.lexicon = lexicon
        self.frame = frame
        self.sigTerms = signatures
        self.stopThreshold = stopThreshold
        self.scoreMode = scoreMode
        var idx: [String: [String]] = [:]
        for (code, terms) in signatures { for t in terms { idx[t, default: []].append(code) } }
        for k in idx.keys { idx[k]!.sort() }       // deterministic order
        self.index = idx

        // IDF over the code signatures: df(t) = # signatures containing t,
        // N = total code signatures. idf(t) = ln(N / df(t)) (a term in every
        // signature carries idf 0; a term in one signature carries ln(N)).
        // Computed once here so encode() never recomputes; only the modes that
        // use it (.idf, .idfCosine) read these maps, but precomputing for all
        // modes keeps init branch-free and the cost is one pass over df.
        var df: [String: Int] = [:]
        for (_, terms) in signatures { for t in terms { df[t, default: 0] += 1 } }
        let n = Double(signatures.count)
        var idfMap: [String: Double] = [:]
        idfMap.reserveCapacity(df.count)
        for (t, d) in df { idfMap[t] = d > 0 ? Foundation.log(n / Double(d)) : 0 }
        self.idf = idfMap

        // Per-signature norms (the big-signature penalty). `.cosine` divides by
        // sqrt(|sig|); `.idfCosine` divides by the IDF-weighted L2 norm of the
        // signature. A zero norm (empty signature, or all-idf-0 terms) is left
        // at 0 and treated as "no division" at score time.
        var normMap: [String: Double] = [:]
        var idfNormMap: [String: Double] = [:]
        for (code, terms) in signatures {
            normMap[code] = (terms.count > 0) ? Foundation.sqrt(Double(terms.count)) : 0
            // Sum the squared IDF weights in SORTED term order: floating-point
            // addition is non-associative and `terms` is a Set (random iteration
            // order per process), so an unsorted sum yields a per-process-varying
            // norm that flips near-ties in `.idfCosine`. Sorting pins the result.
            var ss = 0.0
            for t in terms.sorted() { let w = idfMap[t] ?? 0; ss += w * w }
            idfNormMap[code] = (ss > 0) ? Foundation.sqrt(ss) : 0
        }
        self.sigNorm = normMap
        self.sigIDFNorm = idfNormMap
    }

    /// Score `code`'s overlap with `bag` under the active `scoreMode`. The
    /// numerator is summed over the overlap (terms shared between the bag and
    /// the code's membership signature); the denominator is the mode's
    /// signature-side normalization (1 for `.raw`/`.idf`). Used for BOTH the
    /// Step-4 argmax and the Step-5 descent ranking so they stay on one footing.
    /// Returns 0.0 when there is no overlap.
    private func score(code: String, bag: ConceptBag) -> Double {
        guard let terms = sigTerms[code] else { return 0 }
        // Sum over the overlap in SORTED term order: floating-point addition is
        // not associative, so a fixed summation order is required for the
        // normalized modes to be bit-reproducible (the `bag` dict's iteration
        // order is randomized per process). For `.raw` the sum is integral and
        // order-independent, but we use the same path for uniformity.
        let overlap = terms.filter { bag[$0] != nil }.sorted()
        var num = 0.0
        switch scoreMode {
        case .raw, .cosine:
            // Raw numerator: Σ bag[t] over the overlap.
            for t in overlap { num += Double(bag[t]!) }
        case .idf, .idfCosine:
            // IDF-weighted numerator: Σ bag[t]·idf(t) over the overlap.
            for t in overlap { num += Double(bag[t]!) * (idf[t] ?? 0) }
        }
        switch scoreMode {
        case .raw, .idf:
            return num
        case .cosine:
            let d = sigNorm[code] ?? 0
            return d > 0 ? num / d : num
        case .idfCosine:
            let d = sigIDFNorm[code] ?? 0
            return d > 0 ? num / d : num
        }
    }

    /// The RAW integer overlap Σ bag[t] over (bag ∩ sig), used for the
    /// mode-independent descent cutoff comparison (see `stopThreshold`).
    private func rawOverlap(code: String, bag: ConceptBag) -> Int {
        guard let terms = sigTerms[code] else { return 0 }
        var o = 0
        for (t, n) in bag where terms.contains(t) { o += n }
        return o
    }

    /// Maximum number of codes that may share the argmax score while still
    /// yielding a classifiable result. When more codes than this are tied at
    /// the top IDF score, the query bag is dominated by common cross-domain
    /// vocabulary (low-IDF terms present in almost every signature) rather
    /// than subject-specific vocabulary. The tie-break (lowest code
    /// lexicographically) then selects an arbitrary code, not a semantically
    /// grounded one — that is a confidently-wrong specific code, which is
    /// worse than the honest "unclassified" sentinel "000".
    ///
    /// Calibration (v1.0 frame, 1 071 code signatures):
    ///   • subject-specific text (e.g. "biology / physiology"): ≤ 2 codes tied
    ///     at the top IDF score — the winning code is in the correct domain.
    ///   • software/technical text (e.g. "wings ADR pipeline"): 10–13 codes
    ///     tied — the "winner" is an arbitrary code in an unrelated domain
    ///     (235 = angels/devotional, 621.2 = hydraulic engineering, etc.).
    ///
    /// Setting the limit to 4 passes genuine subject-specific queries (≤ 2
    /// ties observed on the v1.0 frame) while correctly returning UNRESOLVED
    /// for technical/generic text that would otherwise get a confidently-wrong
    /// code. Mirrors Rust `FdcMatcher::MAX_TIED_WINNERS_FOR_CLASSIFICATION`.
    public static let maximumTiedWinnersForClassification: Int = 4


    /// Encode `text` to an FDC code, or `nil` for UNRESOLVED. Never guesses.
    public func encode(_ text: String) -> String? {
        encodeAnchor(text).code
    }

    /// Encode `text` and also surface the dominant concept of the input.
    /// `code` is the FDC code (`nil` = UNRESOLVED). `conceptQID` is the
    /// highest-weighted Wikidata Q-ID in the concept bag — "what the text is
    /// most about" — or `nil` if the bag carries no Q-ID concept. One pass,
    /// so EideticLib fills an Anchor's code + wikidataQID without re-bagging.
    public func encodeAnchor(_ text: String) -> (code: String?, conceptQID: String?) {
        let bag = BagBuilder.bag(text, lexicon: lexicon)
        let qid = dominantQID(bag)              // independent of whether a code matches
        guard !bag.isEmpty else { return (nil, qid) }

        // Step 4 — match + score (§5.2/§5.3). The inverted index gives the
        // set of candidate codes (any code sharing ≥1 bag term); each
        // candidate is then scored under the active mode. For `.raw` the score
        // is exactly Σ bag[t] (integers held in Double — comparisons exact),
        // reproducing the shipped behavior bit-for-bit.
        var candidateSet: Set<String> = []
        for (term, _) in bag {
            guard let codes = index[term] else { continue }
            for code in codes { candidateSet.insert(code) }
        }
        guard !candidateSet.isEmpty else { return (nil, qid) }   // §5.2.3 — UNRESOLVED, no guess
        // Sorted so the scan order is deterministic regardless of Set hashing.
        // This matters for the normalized modes: two codes can carry equal (or
        // float-rounding-equal) scores, and the lowest-code tie-break only
        // holds if the scan visits codes in a fixed order. The lowest code wins
        // ties here exactly as the `code < node` rule intends.
        let candidates = candidateSet.sorted()

        // argmax: highest score, ties broken by lowest code lexicographically.
        var node = ""
        var nodeScore = -Double.greatestFiniteMagnitude
        for code in candidates {
            let s = score(code: code, bag: bag)
            if s > nodeScore || (s == nodeScore && code < node) {
                node = code; nodeScore = s
            }
        }

        // Tie-count guard (§maximumTiedWinnersForClassification): when many
        // codes share the argmax score, the query bag is dominated by common
        // cross-domain Q-IDs with near-zero IDF weight. The tie-break
        // (lowest code) picks an arbitrary code rather than a semantically
        // grounded one — a confidently-wrong specific code is worse than the
        // honest "000" unclassified sentinel. UNRESOLVED when tied codes
        // exceed the allowed maximum.
        let tiedCount = candidates.filter { score(code: $0, bag: bag) == nodeScore }.count
        guard tiedCount <= Self.maximumTiedWinnersForClassification else {
            return (nil, qid)   // too many tied winners — no discriminating signal
        }

        // Step 5 — frame descent (§6.1). A child must clear the (raw) overlap
        // cutoff to be a candidate; among those, the highest mode score wins
        // (ties -> lowest code). Scoring the descent under the same mode as the
        // argmax keeps the two on one footing.
        while true {
            var best: String?
            var bestScore = 0.0
            for child in frame.children(of: node) {
                guard sigTerms[child.code] != nil else { continue }
                guard rawOverlap(code: child.code, bag: bag) >= stopThreshold else { continue }
                let s = score(code: child.code, bag: bag)
                if best == nil || s > bestScore || (s == bestScore && child.code < best!) {
                    best = child.code; bestScore = s
                }
            }
            guard let next = best else { break }
            node = next
        }
        return (node, qid)
    }

    /// The highest-count Wikidata Q-ID in `bag` (ties broken by lowest Q-ID
    /// lexicographically, so the result is deterministic regardless of the
    /// bag's dictionary iteration order). `nil` if the bag holds no Q-ID key.
    private func dominantQID(_ bag: ConceptBag) -> String? {
        var best: String?
        var bestN = 0
        for (k, n) in bag where k.hasPrefix("Q") {
            if n > bestN || (n == bestN && (best == nil || k < best!)) {
                best = k; bestN = n
            }
        }
        return best
    }
}
