// TimingLandscape.swift — where the timing lane's landscape rows come from.
//
// The timing benchmark measures latency against a database holding a fixed
// number of rows. Those rows are the landscape: unmeasured background that
// gives the measured operation something to work against.
//
// Two sources.
//
// SYNTHETIC is one templated sentence per row with an index and seed
// substituted in. It needs no corpus, so the lane runs anywhere, but every row
// has the same length and vocabulary. That uniformity is invisible in read and
// write timing and decisive in the third cycle tier, which measures retrieval
// of terms new to the index vocabulary — a template has almost no new terms
// after the first row.
//
// CORPUS takes rows from a published data set. The landscape then has the
// length distribution and vocabulary growth of real text, and — the reason it
// exists — anyone can rebuild it. A recipe of corpus name, variant, row count
// and selection seed is enough for another team to construct the same
// landscape and run the same benchmark against their own system. A synthetic
// landscape exists only inside this harness and cannot be reproduced outside
// it.
//
// Both sources are deterministic: the same recipe yields the same rows in the
// same order, on both ports.
//
// PORT PARITY. `rust/src/timing_landscape.rs` is the twin. Same names, same
// selection order, same record contents. `conformance/timing-landscape.sh`
// compares the two ports' output for a given recipe.

import Foundation

/// Where the landscape rows come from.
enum TimingLandscapeSource: String, Sendable, Codable, CaseIterable {
    /// Templated rows generated from the seed. No corpus required.
    case synthetic
    /// Rows taken from a published data set.
    case corpus
}

/// Which published data set the corpus source draws from.
///
/// LongMemEval is the default. Of the four data sets this harness fetches, its
/// licence is the one that permits an outside team to reproduce a published
/// landscape without a further permission question: LongMemEval is CC BY 4.0,
/// LMEB is MIT, and LoCoMo is CC BY-NC, whose non-commercial clause makes it
/// the wrong basis for a recipe published for others to run.
enum TimingLandscapeCorpus: String, Sendable, Codable, CaseIterable {
    case longmemeval
    case lmeb

    /// The licence a reproducing team is bound by, recorded in the report so
    /// the recipe carries its own terms.
    var licence: String {
        switch self {
        case .longmemeval: return "CC BY 4.0"
        case .lmeb:        return "MIT"
        }
    }
}

/// The recipe that identifies a landscape. Recorded in the timing report; it
/// is what another team follows to build the same rows.
struct TimingLandscapeRecipe: Sendable, Codable, Equatable {
    let source: String
    /// Absent for the synthetic source.
    let corpus: String?
    /// Absent for the synthetic source.
    let corpusVariant: String?
    /// Absent for the synthetic source.
    let corpusLicence: String?
    /// Row count of the landscape at measurement time.
    let rows: Int
    /// Seed governing selection order.
    let seed: UInt64

    // snake_case on the wire, matching every other field in the report.
    enum CodingKeys: String, CodingKey {
        case source
        case corpus
        case corpusVariant = "corpus_variant"
        case corpusLicence = "corpus_licence"
        case rows
        case seed
    }

    static func synthetic(rows: Int, seed: UInt64) -> TimingLandscapeRecipe {
        TimingLandscapeRecipe(
            source: TimingLandscapeSource.synthetic.rawValue,
            corpus: nil, corpusVariant: nil, corpusLicence: nil,
            rows: rows, seed: seed)
    }

    static func corpus(
        _ corpus: TimingLandscapeCorpus, variant: String, rows: Int, seed: UInt64
    ) -> TimingLandscapeRecipe {
        TimingLandscapeRecipe(
            source: TimingLandscapeSource.corpus.rawValue,
            corpus: corpus.rawValue, corpusVariant: variant,
            corpusLicence: corpus.licence, rows: rows, seed: seed)
    }
}

// MARK: - Corpus rows

/// One landscape row drawn from a corpus, before it becomes a seed record.
///
/// Kept separate from `TimingSeedRecord` so the selection order is testable
/// without constructing ids or timestamps: two ports agreeing on this list is
/// what makes their landscapes identical.
struct TimingLandscapeRow: Sendable, Equatable {
    /// The text filed as one row.
    let content: String
    /// Stable identity of the source turn, used to derive the row id so the
    /// same corpus turn always lands under the same id.
    let sourceKey: String
}

/// Flattens a LongMemEval variant into landscape rows in corpus order.
///
/// Order is the corpus's own: questions in file order, each question's haystack
/// sessions in order, each session's turns in order. No shuffle. A landscape is
/// described by its row COUNT, and taking a deterministic prefix means the 2k
/// landscape is the first 2k rows of the 10k one — which is what makes a
/// scaling curve a curve over one corpus rather than three unrelated samples.
///
/// `role: content` is the filed text, matching how the conversational lanes
/// file a turn, so the landscape's rows have the shape the substrate sees in
/// ordinary use.
func longMemEvalLandscapeRows(corpus: LMECorpus) -> [TimingLandscapeRow] {
    var rows: [TimingLandscapeRow] = []
    for question in corpus.questions {
        for (sessionIndex, session) in question.haystackSessions.enumerated() {
            for (turnIndex, turn) in session.enumerated() {
                let text = turn.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                rows.append(TimingLandscapeRow(
                    content: "\(turn.role): \(text)",
                    sourceKey: "\(question.questionID)/\(sessionIndex)/\(turnIndex)"))
            }
        }
    }
    return rows
}

// MARK: - Records

/// A UUIDv4-format id derived from a corpus row's source key.
///
/// Derived rather than drawn from the run's RNG so a given corpus turn always
/// lands under the same id, on both ports and across runs. That makes a
/// landscape addressable: a row can be found again in a rebuilt landscape.
///
/// FNV-1a over the source key, expanded to the 16 bytes a UUID needs. Not a
/// cryptographic hash: it names rows in a benchmark database.
func landscapeRowID(sourceKey: String) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in sourceKey.utf8 {
        h ^= UInt64(byte)
        h = h &* 0x0000_0100_0000_01b3
    }
    // Second independent value so the id has 128 bits of derived material
    // rather than one 64-bit value repeated.
    var g: UInt64 = h ^ 0x9e37_79b9_7f4a_7c15
    g = g &* 0xff51_afd7_ed55_8ccd
    g ^= g >> 33

    return String(format: "%08x-%04x-%04x-%04x-%012llx",
                  UInt32(truncatingIfNeeded: h >> 32),
                  UInt16(truncatingIfNeeded: h >> 16),
                  (UInt16(truncatingIfNeeded: h) & 0x0FFF) | 0x4000,       // version 4
                  (UInt16(truncatingIfNeeded: g >> 48) & 0x3FFF) | 0x8000,  // variant bits
                  g & 0x0000_FFFF_FFFF_FFFF)
}

/// Builds landscape records for the half-open index range `from..<to` from
/// corpus rows.
///
/// The range is a prefix selection over `rows`, matching the synthetic
/// generator's contract so the two sources are interchangeable at the call
/// site. When the requested range runs past the corpus, the corpus is cycled
/// and the repeat count is folded into the source key, so ids stay unique and
/// a landscape larger than its corpus is still deterministic and still
/// addressable.
///
/// Event times are the same monotonic sequence the synthetic source uses:
/// timing measures a database of a given size, and a landscape whose rows
/// carry the corpus's own timestamps would vary its recency distribution with
/// the corpus rather than with the row count under test.
func corpusLandscapeRecords(
    rows: [TimingLandscapeRow], from: Int, to: Int, room: String = "timing/bench"
) -> [TimingSeedRecord] {
    guard !rows.isEmpty, to > from else { return [] }
    var records: [TimingSeedRecord] = []
    records.reserveCapacity(to - from)
    for i in from..<to {
        let cycle = i / rows.count
        let row = rows[i % rows.count]
        // A row reused on a later cycle is a distinct database row and needs a
        // distinct id; the cycle number is what makes it one.
        let key = cycle == 0 ? row.sourceKey : "\(row.sourceKey)#\(cycle)"
        records.append(TimingSeedRecord(
            id: landscapeRowID(sourceKey: key),
            content: row.content,
            eventTime: syntheticEventTime(offsetSeconds: i),
            room: room))
    }
    return records
}
