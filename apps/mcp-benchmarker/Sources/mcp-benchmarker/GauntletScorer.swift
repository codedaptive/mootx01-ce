import Foundation

// GauntletScorer.swift — pure, deterministic per-needle scoring (Phase 2.2).
//
// The scorer takes ONE needle's ground truth and ONE backend's returned result
// set (the ordered items the backend gave for that needle's query) and produces
// the per-needle metrics. It is intentionally pure — no live server contact, no
// Date() — so it is fully unit-testable against synthetic fixture result-sets,
// the same discipline DegeneracyGuard follows.
//
// IDENTITY ACROSS BACKENDS. The two backends do NOT share an id space, and one
// of them (MemPalace `search`) returns NO id at all — only content. So scoring
// matches a returned item to a corpus record by CONTENT, using the same
// normalization the benchmarker's cross-server comparison uses (trim, lowercase,
// collapse whitespace, bounded prefix). Content is the only identity both
// backends expose for a search hit. An id, when present, is retained for
// diagnosis but is NOT the matching key (a content match is authoritative and
// works for both backends uniformly).
//
// METRICS (plan line 132):
//   found@k    — is the needle's content present in the returned top-k? The hard
//                gate. k ∈ {1,5,10}. A split needle (T4) is "found" only when
//                BOTH its halves are present in the top-k.
//   rank       — 1-based position of the needle in the returned order (nil if
//                absent). For a split needle, the rank of the LATER of its two
//                halves (the join is complete only once both are seen).
//   completeness — byte-compare of the content the REAL needle query already
//                RETURNED (the returned item identified as the needle by the
//                found@k content match) against the needle's verbatim content.
//                1.0 = exact byte match, else 0.0. Conditional on the needle
//                being found: if the needle is absent from the returned items,
//                completeness is 0 (you did not return the answer). Measuring
//                completeness from the item the query actually returned — rather
//                than from a separate self-retrieval fetch — treats both backends
//                identically and asks the real question: "is the content this
//                query returned the whole right answer verbatim?" A separate
//                self-retrieval query (the record's own content as the query)
//                gets crowded by the planted near-duplicate distractors and
//                double-measures precision-under-distractors, not completeness.
//                (Partial credit is deliberately NOT given: completeness is "did
//                we get the whole right answer verbatim", a yes/no.)
//   contamination — count of this needle's planted distractors appearing in the
//                returned top-k. Lower is better.
//
// The runner supplies latency + bytes/tokens (transport-level facts the scorer
// cannot see); the scorer owns the retrieval-quality facts above.

/// One returned item, reduced to what the scorer needs: its content (the match
/// key) and its id when the backend supplied one (diagnosis only).
struct ScoredItem: Sendable, Equatable {
    let id: String?
    let content: String?
}

/// The per-needle score for one backend/strategy. Carries the hard-gate found@k
/// flags, the rank, completeness, and contamination, plus the runner-supplied
/// transport metrics so a row is self-contained in the report.
struct NeedleScore: Sendable, Equatable {
    let needleID: String
    let tier: NoiseTier
    /// found@1 / @5 / @10 — the hard gate. Keyed by k.
    let foundAtK: [Int: Bool]
    /// 1-based rank of the needle in the returned order, nil if not found at any
    /// depth scored.
    let rank: Int?
    /// 1.0 when the returned item identified as the needle byte-matches the
    /// needle's verbatim content (for a split needle, when BOTH halves byte-match
    /// the returned items identified as each half), else 0.0. 0.0 when the needle
    /// is not found in the returned items.
    let completeness: Double
    /// Count of the needle's planted distractors present in the returned top-k
    /// (k = max k scored, i.e. 10).
    let contamination: Int
    /// Recall latency in seconds (runner-supplied).
    let latencySeconds: Double
    /// Bytes the backend returned for this query's result (runner-supplied).
    let bytesReturned: Int

    /// Reciprocal rank for MRR aggregation: 1/rank, or 0 when not found.
    var reciprocalRank: Double { rank.map { 1.0 / Double($0) } ?? 0.0 }
}

/// The pure scorer. Construct it once with the k values to score; call `score`
/// per needle with that needle's ground truth and the backend's returned items.
struct GauntletScorer: Sendable {
    /// The depths to evaluate found@k at. Default {1,5,10} (the plan's gate).
    let kValues: [Int]

    init(kValues: [Int] = [1, 5, 10]) {
        // Sorted + de-duplicated so found@k keys are stable and rank-vs-k logic
        // can rely on ascending order.
        self.kValues = Array(Set(kValues)).sorted()
    }

    /// Normalizes content to the cross-backend match key: lowercase, collapse
    /// whitespace, bounded 64-char prefix. This MUST match
    /// `BenchmarkEngine.normalizedContentOrder`'s per-item normalization so a
    /// hit identified here is the same notion of "same item" the rest of the
    /// tool uses. (The prefix bound absorbs MemPalace preview truncation vs
    /// mootx01 full content on the shared leading text.)
    static func normalize(_ content: String) -> String {
        let collapsed = content
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(64))
    }

    /// Scores one needle against a backend's returned items.
    ///
    /// - Parameters:
    ///   - needle: the ground truth.
    ///   - returned: the backend's ordered result items for the needle's query.
    ///   - distractorContents: the verbatim contents of the needle's planted
    ///     distractors, keyed by distractor id (so contamination can count them
    ///     by content match — the only key MemPalace exposes).
    ///   - splitPartnerContent: the partner half's verbatim content for a T4
    ///     split needle (nil for non-split). Required for the split found/rank
    ///     logic — both halves must appear.
    ///   - latencySeconds / bytesReturned: runner-supplied transport metrics.
    ///
    /// Completeness is derived in-scorer from the returned items themselves: the
    /// returned item whose normalized content matches the needle (the same item
    /// found@k identifies) is byte-compared against the needle's verbatim content.
    /// There is no separate full-record fetch — completeness measures what this
    /// query actually returned, identically for both backends.
    func score(needle: Needle,
               returned: [ScoredItem],
               distractorContents: [String: String],
               splitPartnerContent: String?,
               latencySeconds: Double,
               bytesReturned: Int) -> NeedleScore {
        // Returned content, in order, with no-content items dropped from the match
        // space (they cannot be matched, but are still counted in the raw returned
        // length the runner measures). `returnedContents` keeps the verbatim
        // content for the completeness byte-compare; `returnedKeys` is its
        // normalized form for the match. Both share the same index space, so a
        // match index resolves to both the same item's key and its verbatim text.
        let returnedContents = returned.compactMap { $0.content }
        let returnedKeys = returnedContents.map(Self.normalize)

        let needleKey = Self.normalize(needle.content)
        // 1-based index of the needle's first appearance, if any.
        let needleIndex = returnedKeys.firstIndex(of: needleKey)

        // For a split needle, both halves must appear; the effective rank is the
        // LATER of the two positions (the join completes only once both are seen).
        // partnerIndex is captured here and reused by the completeness compare.
        let partnerIndex: Int?
        if needle.splitPartnerID != nil, let partnerContent = splitPartnerContent {
            partnerIndex = returnedKeys.firstIndex(of: Self.normalize(partnerContent))
        } else {
            partnerIndex = nil
        }
        let rank: Int?
        if needle.splitPartnerID != nil {
            if let n = needleIndex, let p = partnerIndex {
                rank = max(n, p) + 1   // 1-based; later of the two halves
            } else {
                rank = nil             // a missing half means the answer is incomplete
            }
        } else {
            rank = needleIndex.map { $0 + 1 }
        }

        // found@k: the needle's (effective) rank is within k.
        var foundAtK: [Int: Bool] = [:]
        for k in kValues {
            foundAtK[k] = (rank.map { $0 <= k }) ?? false
        }

        // Completeness: the returned item identified as the needle (by the
        // found@k content match) byte-matches the needle's verbatim content. This
        // is the content the real query ACTUALLY returned — not a separate
        // self-retrieval fetch — so both backends are measured identically and a
        // not-found needle scores 0 (the answer was not returned). For a split
        // needle BOTH halves' returned items must byte-match their records.
        let needleReturned = needleIndex.map { returnedContents[$0] }
        let completeness: Double
        if needle.splitPartnerID != nil {
            let needleOK = (needleReturned == needle.content)
            // partnerIndex nil means the partner half was not returned → not
            // complete; guard so a nil==nil compare can't read as a match.
            let partnerOK: Bool = partnerIndex.map {
                returnedContents[$0] == splitPartnerContent
            } ?? false
            completeness = (needleOK && partnerOK) ? 1.0 : 0.0
        } else {
            completeness = (needleReturned == needle.content) ? 1.0 : 0.0
        }

        // Contamination: distractors of THIS needle appearing in the returned
        // top-k (k = the max scored depth). Counted by normalized content match.
        let maxK = kValues.max() ?? 10
        let topKKeys = Set(returnedKeys.prefix(maxK))
        var contamination = 0
        for (_, dContent) in distractorContents {
            if topKKeys.contains(Self.normalize(dContent)) { contamination += 1 }
        }

        return NeedleScore(needleID: needle.id,
                           tier: needle.tier,
                           foundAtK: foundAtK,
                           rank: rank,
                           completeness: completeness,
                           contamination: contamination,
                           latencySeconds: latencySeconds,
                           bytesReturned: bytesReturned)
    }
}
