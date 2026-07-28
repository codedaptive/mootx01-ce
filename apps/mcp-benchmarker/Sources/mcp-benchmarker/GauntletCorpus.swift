import Foundation

// GauntletCorpus.swift — the adversarial corpus data model + the deterministic,
// seeded generator (Phase 2.1 of MOOT_RETRIEVAL_GAUNTLET_PLAN.md).
//
// The corpus is a set of NEEDLES (facts with known ground truth) buried under
// NOISE TIERS — distractor records engineered to defeat a naive retriever in a
// specific, named way. The whole construction is a function of one 64-bit seed:
// same seed → byte-identical corpus.jsonl + needles.json. That determinism is a
// hard test gate and the reason the generator threads ONE SplitMix64 through the
// entire pass (a single sequential draw order is what makes the bytes stable).
//
// Two artifacts are emitted:
//   - corpus.jsonl : every record (needles + distractors), one JSON object per
//     line, in the deterministic emission order. This is what gets loaded into
//     both scratch backends verbatim.
//   - needles.json : the ground-truth manifest — per needle, the single query
//     that should retrieve it, its verbatim content (for the completeness
//     byte-compare), its tier, and the ids of the distractors planted around it
//     (so the scorer can count contamination in a backend's top-k).
//
// The five tiers (plan lines 117-122), each defeating a different retriever
// weakness:
//   T1 lexical    — distractors that SHARE the needle's salient tokens (names,
//                   dates) but state a DIFFERENT fact. Defeats pure BM25/lexical
//                   overlap: the distractor scores high on token match yet is
//                   the wrong answer.
//   T2 semantic   — paraphrases with CLOSE meaning but a WRONG value. Defeats a
//                   pure-vector retriever: the embedding sits near the needle's
//                   yet the asserted value is wrong.
//   T3 temporal   — a SUPERSEDED earlier version of the needle's own fact, plus
//                   the CURRENT version (the needle). Defeats a retriever with no
//                   recency/validity sense: both match, the stale one must lose.
//   T4 split      — the answer is split across TWO records; neither alone is
//                   sufficient. Tests whether the backend can surface both halves
//                   (the needle is the PRIMARY half; its partner is recorded so
//                   completeness can require both).
//   T5 scatter    — the needle is filed FAR from its topical neighbours (a
//                   distant location/room), and topical decoys are filed where
//                   the needle "should" live. Defeats a location-biased retriever.
//
// Difficulty dial (plan line 124): distractor-count-per-needle and the tier mix
// are CLI flags, so the same generator emits an easy or a brutal corpus from one
// code path.

// MARK: - Tier

/// The five adversarial noise tiers. The raw value is the stable wire tag used
/// in needles.json and in record metadata; do not renumber (the conformance
/// tests and any pinned regression seeds depend on these exact strings).
enum NoiseTier: String, Codable, Sendable, CaseIterable, Comparable {
    case lexical = "T1"
    case semantic = "T2"
    case temporal = "T3"
    case split = "T4"
    case scatter = "T5"

    /// Ordering by tier number so per-tier report tables are stably sorted.
    static func < (lhs: NoiseTier, rhs: NoiseTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Records and needles

/// The role a record plays in the corpus: it is either the needle (the single
/// correct answer for its query) or a distractor planted to defeat retrieval.
/// `splitPartner` is the second half of a T4 split fact — itself a correct-but-
/// insufficient record, distinct from a distractor.
enum RecordRole: String, Codable, Sendable, Equatable {
    case needle
    case distractor
    case splitPartner
}

/// One record in corpus.jsonl. Carries everything a backend write needs (content
/// + location) plus the generator metadata (tier, role, the needle it belongs
/// to) so the scorer can classify a returned hit without re-deriving it.
///
/// `location` is the per-record filing target. Both backends file by location:
/// mootx01's `moot_file_memory` takes a single `location` path; MemPalace's
/// `mempalace_add_drawer` takes wing+room. The runner derives wing/room from the
/// first two path segments of `location`, so one field drives both backends and
/// the T5 scatter tier can place a record anywhere by setting this string.
struct GauntletRecord: Codable, Sendable, Equatable {
    /// Stable corpus-local id (e.g. `n0007` for a needle, `n0007-t1-2` for its
    /// second T1 distractor). NOT the backend-assigned id — the backends mint
    /// their own on write; this id keys ground truth within the corpus.
    let id: String
    /// The verbatim content filed into the backend. For a needle this is the
    /// exact string the completeness check byte-compares against.
    let content: String
    /// The filing location, `wing/room[/...]` form. The runner maps the first
    /// two segments to MemPalace wing+room and passes the whole string as the
    /// mootx01 location.
    let location: String
    /// Which tier this record belongs to (the needle and all its distractors
    /// share the needle's tier).
    let tier: NoiseTier
    /// Whether this record is the needle, a distractor, or a split partner.
    let role: RecordRole
    /// The id of the needle this record orbits (a needle points at itself).
    let needleID: String
}

/// The ground truth for one needle: the single query that should retrieve it at
/// rank 1, its verbatim content, its tier, the location it was filed at, and the
/// ids of the records planted as noise around it (so contamination — distractors
/// appearing in a backend's top-k — can be counted).
struct Needle: Codable, Sendable, Equatable {
    /// The needle's corpus id (matches the `id` of its needle record).
    let id: String
    /// The single query expected to retrieve this needle at rank 1.
    let query: String
    /// The needle's verbatim content. Completeness is derived from returned
    /// query result items; no separate full-record fetch is performed.
    let content: String
    /// The needle's tier.
    let tier: NoiseTier
    /// Where the needle was filed (for diagnosis; the T5 tier scatters this).
    let location: String
    /// Ids of the distractor records planted around this needle. Used to count
    /// contamination in a backend's returned top-k.
    let distractorIDs: [String]
    /// For a T4 split needle, the id of the partner record that holds the other
    /// half of the answer. Empty for non-split needles. Completeness for a split
    /// needle requires BOTH the needle and this partner to be retrievable.
    let splitPartnerID: String?
    /// Expected rank of the needle in a correct backend's results. Always 1 — the
    /// needle is, by construction, the single best answer for its query. Carried
    /// explicitly so the ground-truth file is self-describing.
    let expectedRank: Int
}

/// The complete generated corpus: the ordered records and the ground-truth
/// needles, plus the seed and the difficulty parameters that produced them.
struct GauntletCorpus: Sendable {
    let seed: UInt64
    let records: [GauntletRecord]
    let needles: [Needle]
    /// The tier mix actually used (needle count per tier), echoed so the report
    /// header can state the difficulty profile exactly.
    let tierCounts: [NoiseTier: Int]
    /// Distractors planted per needle (the difficulty dial), echoed for the
    /// report header.
    let distractorsPerNeedle: Int
}
