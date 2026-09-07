// GLKResultsPackager.swift
//
// Post-recall, pre-presentation packager for the adaptive answer+pile surface.
//
// Consumes a GLKRecallResult and an optional pre-composed answer text
// (supplied by the AriaMcpKit layer via GroundedSynthesis) and produces a
// GLKPackagedResult that AriaMcpKit serializes into the MCP response.
//
// ## Design constraints
//
// - GLKResultsPackager lives in GeniusLocusKit; it does NOT call
//   GroundedSynthesis (that type is in CognitionKit, above this layer).
//   The answer text is injected by the caller.
// - All signals (m1–m4) are computed deterministically from the supplied
//   GLKRecallResult and answer text — no additional substrate reads.
// - answer:"never" is the default. When the packager is called with .never
//   it returns a rowsOnly result that is byte-identical to the pre-packager
//   path (the caller must still render it identically).
// - Thresholds are read from RecallTuningManifest (the existing manifest-key
//   family) so the quality optimizer owns them.
//
// ## Response levels (spec §3)
//
//   L0 — answer only: answer_text, citation ids, confidence, result_count.
//   L1 — answer + dense pile: L0 block plus rows.
//   rowsOnly — rows only, no answer block (WEAK gate or answer:"never").
//
// ## Confidence gate (spec §4)
//
//   Signals (all from GLKRecallResult; no new retrieval):
//     m1 top-margin          = (score[0] − score[1]) / max(score[0], ε)
//     m2 lane agreement      = normalised Spearman footrule agreement between
//                              the lexical and span order of span-scored hits
//                              in hits.prefix(10)
//     m3 span spread         = population std deviation of span cosines over
//                              the span-scored hits in hits.prefix(10)
//     m4 containment         = word-boundary containment of answer text in
//                              top citation content (1.0 = contained)
//
//   Gate:
//     CONFIDENT  iff m1 ≥ t1 AND m2 ≥ t2 AND m4 = true
//     WEAK       iff m1 < t1' OR  m3 < t3'
//     else INTERMEDIATE
//
// ## Row cutoff by score cliff (spec §6)
//
//   Include rows until score(i) − score(i+1) ≥ c × (score(1) − score(k)),
//   bounded by [k_min, k_max]. Flat curves send more rows; cliffed curves
//   stop early.

import Foundation
import LocusKit

// MARK: - Answer mode

/// The `answer` adjective on `moot_memory_search`.
///
/// Mirrors the three values in the MCP schema. `never` is the default and
/// is byte-identical to today's dense-rows-only response so existing callers
/// observe no change.
public enum PackagerAnswerMode: String, Sendable {
    /// Dense rows only — no answer block. Byte-identical to pre-packager
    /// behaviour. This is the default and ships on every new `GLKPackagedResult`
    /// unless the caller explicitly passes `.always` or `.auto`.
    case never
    /// Always compose and prepend the answer block plus rows (L1-full).
    case always
    /// Server picks the response level by the confidence gate (§4).
    /// CONFIDENT → L0, INTERMEDIATE → L1-full, WEAK → rowsOnly.
    case auto
}

// MARK: - Confidence level

/// Categorical confidence for the answer block (spec §5).
public enum PackagerConfidenceLevel: String, Sendable, Equatable {
    case confident
    case intermediate
    case weak
}

// MARK: - Response level

/// Which response shape the packager selected.
public enum GLKResponseLevel: Sendable, Equatable {
    /// Answer only: answer block (text + citations + confidence), no rows.
    case l0AnswerOnly
    /// Answer + dense pile: answer block followed by rows.
    case l1Full
    /// Rows only: no answer block (WEAK gate or answer:never).
    case rowsOnly
}

// MARK: - Confidence signals

/// The four gate signals computed by the packager, rounded to 2 decimals per
/// spec §5 (keeps tokens flat).
public struct GLKConfidenceSignals: Sendable, Equatable {
    /// m1: (score[0] − score[1]) / max(score[0], ε). Top-margin.
    public let margin: Double
    /// m2: normalised Spearman footrule agreement between the lexical and span
    /// order of span-scored hits in the top-10. 1.0 = both orders agree
    /// exactly; 0.0 = completely reversed.
    public let laneAgreement: Double
    /// m3: population std deviation of span cosines over the span-scored hits
    /// in the top-10. Near 0 = no semantic spread; near 1 = strong spread.
    public let denseSpread: Double
    /// m4: word-boundary containment of answer text in top citation.
    public let containment: Bool

    public init(margin: Double, laneAgreement: Double,
                denseSpread: Double, containment: Bool) {
        self.margin = margin
        self.laneAgreement = laneAgreement
        self.denseSpread = denseSpread
        self.containment = containment
    }
}

// MARK: - Answer block

/// The answer block in the packaged result (spec §5).
public struct GLKAnswerBlock: Sendable, Equatable {
    /// Composed answer text (supplied by the caller via GroundedSynthesis).
    public let text: String
    /// UUIDs of the top citations whose content the answer is grounded in.
    public let citationIDs: [RowID]
    /// Categorical confidence level ("confident" or "intermediate").
    /// WEAK responses carry no answer block, so this is never `.weak`.
    public let confidence: PackagerConfidenceLevel
    /// The four gate signals, rounded to 2 decimals.
    public let signals: GLKConfidenceSignals

    public init(text: String, citationIDs: [RowID],
                confidence: PackagerConfidenceLevel,
                signals: GLKConfidenceSignals) {
        self.text = text
        self.citationIDs = citationIDs
        self.confidence = confidence
        self.signals = signals
    }
}

// MARK: - Packaged result

/// The output of `GLKResultsPackager.package(...)`.
///
/// AriaMcpKit serializes this into the MCP response. The level field drives
/// the response shape: L0 = answer only, L1 = answer+rows, rowsOnly = today.
public struct GLKPackagedResult: Sendable {
    /// Which response shape was selected.
    public let level: GLKResponseLevel
    /// Optional answer block (nil for rowsOnly and when answer:"never").
    public let answerBlock: GLKAnswerBlock?
    /// Rows selected by the score-cliff cutoff (or all hits for rowsOnly).
    /// Empty for L0AnswerOnly.
    public let rows: [RecallHit]
    /// Total hits in the recall result (before cliff cutoff). Always set.
    public let totalCount: Int

    public init(level: GLKResponseLevel, answerBlock: GLKAnswerBlock?,
                rows: [RecallHit], totalCount: Int) {
        self.level = level
        self.answerBlock = answerBlock
        self.rows = rows
        self.totalCount = totalCount
    }
}

// MARK: - Packager thresholds

/// Per-estate packager thresholds read from the `recall_tuning` manifest key.
///
/// All values default to the spec constants when absent from the manifest so
/// an estate with no `recall_tuning` key behaves as if the defaults were set.
/// The quality optimizer tunes these from the per-question register offline;
/// agents never set them by hand.
public struct PackagerThresholds: Sendable, Equatable {
    // MARK: CONFIDENT gate
    /// m1 minimum margin for CONFIDENT. Spec default: 0.25.
    public let t1: Double
    /// m2 minimum lane agreement for CONFIDENT. Spec default: 0.5.
    public let t2: Double

    // MARK: WEAK gate
    /// m1 below which WEAK is triggered regardless of other signals. Spec default: 0.05.
    public let t1Prime: Double
    /// m3 (span cosine spread) below which WEAK is triggered regardless of other
    /// signals. Spec default: 0.10.
    public let t3Prime: Double

    // MARK: Row cutoff
    /// Score-cliff ratio threshold (spec §6). Spec default: 0.20.
    public let c: Double
    /// Minimum rows to return. Spec default: 3.
    public let kMin: Int
    /// Maximum rows to return. Spec default: 20.
    public let kMax: Int

    // MARK: Defaults

    public static let `default` = PackagerThresholds()

    public init(
        t1: Double = 0.25,
        t2: Double = 0.50,
        t1Prime: Double = 0.05,
        t3Prime: Double = 0.10,
        c: Double = 0.20,
        kMin: Int = 3,
        kMax: Int = 20
    ) {
        self.t1 = t1
        self.t2 = t2
        self.t1Prime = t1Prime
        self.t3Prime = t3Prime
        self.c = c
        self.kMin = kMin
        self.kMax = kMax
    }
}

// MARK: - GLKResultsPackager

/// Post-recall, pre-presentation packager.
///
/// Consumes a `GLKRecallResult`, an optional pre-composed answer text (supplied
/// by the caller — this packager does not call GroundedSynthesis directly), and
/// the thresholds from the `recall_tuning` manifest. Returns a `GLKPackagedResult`
/// that the MCP serialization layer renders into the final response.
///
/// ## One-seam guarantee
///
/// Every consumer of the recall surface (moot_memory_search, moot_synthesize,
/// and future recipe tools) routes through this type. The gate and cutoff logic
/// live here once; callers provide the answer text but never re-implement the
/// gate.
///
/// ## Determinism
///
/// All computations are deterministic given the same `GLKRecallResult` and
/// `composedAnswer`. No Date() calls, no randomness.
public struct GLKResultsPackager: Sendable {

    public init() {}

    // MARK: - Public API

    /// Package a recall result into the response shape demanded by `mode`.
    ///
    /// - Parameters:
    ///   - result: The `GLKRecallResult` from `GeniusLocusKit.recall(_:_:)`.
    ///   - mode: The caller-requested answer mode (never/always/auto).
    ///   - composedAnswer: Pre-composed answer text from the synthesis path.
    ///     Required when `mode != .never`. Nil for mode == .never.
    ///   - thresholds: Gate thresholds read from the recall_tuning manifest.
    ///     Use `PackagerThresholds.default` when no manifest is provisioned.
    /// - Returns: A `GLKPackagedResult` ready for serialization.
    public func package(
        result: GLKRecallResult,
        mode: PackagerAnswerMode,
        composedAnswer: String?,
        thresholds: PackagerThresholds = .default
    ) -> GLKPackagedResult {
        // Fast path: answer:never bypasses all gate computation and is
        // byte-equivalent to the pre-packager dense-rows path. The cliff
        // cutoff is NOT applied in never mode — the caller renders hits
        // directly as before.
        if mode == .never {
            return GLKPackagedResult(
                level: .rowsOnly,
                answerBlock: nil,
                rows: result.hits,
                totalCount: result.hits.count
            )
        }

        // Compute gate signals from the recall result.
        let signals = computeSignals(
            result: result,
            composedAnswer: composedAnswer,
            thresholds: thresholds
        )

        // Classify confidence.
        let confidence = classifyConfidence(signals: signals, thresholds: thresholds)

        // Compute row cutoff by score cliff.
        let cutoffRows = cliffCutoff(hits: result.hits, thresholds: thresholds)

        // Determine the citation IDs from the top hits (up to 5).
        let citationIDs = Array(result.hits.prefix(5).compactMap { $0.drawer?.id })

        // Build the answer block when the confidence gate passes (not WEAK)
        // and a composed answer text is available.
        let answerBlock: GLKAnswerBlock? = {
            guard confidence != .weak, let text = composedAnswer, !text.isEmpty else {
                return nil
            }
            // Map internal confidence to the two public levels (spec §5: WEAK
            // carries no block so only confident/intermediate appear here).
            let blockConfidence: PackagerConfidenceLevel =
                confidence == .confident ? .confident : .intermediate
            return GLKAnswerBlock(
                text: text,
                citationIDs: citationIDs,
                confidence: blockConfidence,
                signals: signals
            )
        }()

        // Select response level based on mode and gate.
        let level: GLKResponseLevel
        let rows: [RecallHit]
        switch mode {
        case .never:
            // Unreachable: handled by the fast path above.
            level = .rowsOnly
            rows = result.hits
        case .always:
            // Always L1: answer block (if confidence >= INTERMEDIATE) + rows.
            // If answer is unavailable (nil), emit rowsOnly.
            if answerBlock != nil {
                level = .l1Full
                rows = cutoffRows
            } else {
                level = .rowsOnly
                rows = cutoffRows
            }
        case .auto:
            switch confidence {
            case .confident:
                // CONFIDENT → L0: answer only, no rows. result_count is in
                // the block so the caller knows rows exist server-side.
                level = answerBlock != nil ? .l0AnswerOnly : .rowsOnly
                rows = []
            case .intermediate:
                // INTERMEDIATE → L1: answer + rows.
                level = answerBlock != nil ? .l1Full : .rowsOnly
                rows = cutoffRows
            case .weak:
                // WEAK → rowsOnly: do not compose a probably-wrong answer.
                level = .rowsOnly
                rows = cutoffRows
            }
        }

        return GLKPackagedResult(
            level: level,
            answerBlock: answerBlock,
            rows: rows,
            totalCount: result.hits.count
        )
    }

    // MARK: - Signal computation

    /// Compute the four gate signals from the recall result and answer text.
    private func computeSignals(
        result: GLKRecallResult,
        composedAnswer: String?,
        thresholds: PackagerThresholds
    ) -> GLKConfidenceSignals {
        let hits = result.hits

        // m1: top-margin = (score[0] − score[1]) / max(score[0], ε)
        let m1: Double
        if hits.count >= 2 {
            let s0 = Double(hits[0].score.final)
            let s1 = Double(hits[1].score.final)
            let denom = max(s0, 1e-9)
            m1 = (s0 - s1) / denom
        } else if hits.count == 1 {
            m1 = 1.0  // Single hit: max margin.
        } else {
            m1 = 0.0  // No hits.
        }

        // scored: the SpanRerankHit of every hit in hits.prefix(10) that carries
        // one, in returned order. Used for m2 (footrule agreement) and m3 (spread).
        let scored = hits.prefix(10).compactMap { $0.spanHit }

        // m2: normalised Spearman footrule agreement between the lexical and span
        // order of span-scored hits. 1.0 = both orders agree; 0.0 = reversed.
        let m2 = spanRerankAgreement(Array(scored))

        // m3: population std deviation of span cosines over span-scored hits in
        // the top-10. A result with no hits reads 0.0; a single hit reads 1.0
        // so a lone result is never penalised by the WEAK gate for lacking spread.
        // Multiple hits with fewer than 2 span-scored reads 0.0 (no usable signal
        // from the encoder), which may trigger the WEAK gate.
        let m3: Double
        if hits.isEmpty {
            m3 = 0.0
        } else if hits.count == 1 {
            m3 = 1.0
        } else {
            m3 = spanCosineSpread(Array(scored))
        }

        // m4: word-boundary containment of the composed answer in the top
        // citation's content. Returns true if every word in a 5-word sliding
        // window from the answer appears in the top hit's content.
        // Uses the same word-boundary primitive as the judge-audit checker.
        let m4: Bool
        if let text = composedAnswer, !text.isEmpty,
           let topContent = hits.first?.drawer?.content, !topContent.isEmpty {
            m4 = wordBoundaryContains(answer: text, inSource: topContent)
        } else {
            // No answer or no top content: containment undefined → false.
            m4 = false
        }

        // Round margin and laneAgreement to 2 decimals for token economy
        // (spec §5). denseSpread is also rounded; containment is boolean.
        let round2 = { (v: Double) -> Double in
            (v * 100).rounded() / 100
        }
        return GLKConfidenceSignals(
            margin: round2(m1),
            laneAgreement: round2(m2),
            denseSpread: round2(m3),
            containment: m4
        )
    }

    /// Classify the confidence level from computed signals and thresholds.
    private func classifyConfidence(
        signals: GLKConfidenceSignals,
        thresholds: PackagerThresholds
    ) -> PackagerConfidenceLevel {
        // WEAK check first (fast exit for clearly uncertain results).
        if signals.margin < thresholds.t1Prime || signals.denseSpread < thresholds.t3Prime {
            return .weak
        }
        // CONFIDENT check.
        if signals.margin >= thresholds.t1
            && signals.laneAgreement >= thresholds.t2
            && signals.containment {
            return .confident
        }
        // Default: INTERMEDIATE.
        return .intermediate
    }

    // MARK: - Row cutoff by score cliff

    /// Select rows by the score-cliff cutoff (spec §6).
    ///
    /// Include rows until score(i) − score(i+1) ≥ c × (score(1) − score(k)),
    /// bounded by [k_min, k_max]. Flat curves send k_max rows; cliffed curves
    /// stop at the cliff.
    private func cliffCutoff(
        hits: [RecallHit],
        thresholds: PackagerThresholds
    ) -> [RecallHit] {
        let n = hits.count
        guard n > 0 else { return [] }

        let kMin = max(1, thresholds.kMin)
        let kMax = min(n, thresholds.kMax)
        guard kMin <= kMax else { return Array(hits.prefix(max(1, kMin))) }

        // Reference spread: score(1) − score(k_max).
        let s0 = Double(hits[0].score.final)
        let sK = Double(hits[min(kMax, n) - 1].score.final)
        let spread = s0 - sK
        let threshold = thresholds.c * max(spread, 1e-9)

        // Walk from kMin to kMax, stopping at the first cliff.
        var cutoff = min(kMin, n)
        for i in kMin..<kMax {
            guard i + 1 < n else {
                cutoff = i + 1
                break
            }
            let gap = Double(hits[i].score.final) - Double(hits[i + 1].score.final)
            if gap >= threshold {
                cutoff = i + 1
                break
            }
            cutoff = i + 1
        }
        return Array(hits.prefix(min(cutoff, kMax)))
    }

    // MARK: - Signal helpers

    /// Normalised Spearman footrule agreement between the lexical order and the
    /// span order of `scored`. Returns 1.0 when both orders agree exactly, 0.0
    /// when they are completely reversed.
    ///
    /// Lexical order: sorted by `bm25Rank` ascending.
    /// Span order: sorted by `cosine` descending, ties broken by `bm25Rank` ascending.
    /// Footrule: sum over lexical-enumerated index i of |i - posSpan[itemID]|.
    /// Maximum footrule for n items: (n * n) / 2 (integer division).
    /// Result: 1.0 - footrule / maximum.
    private func spanRerankAgreement(_ scored: [SpanRerankHit]) -> Double {
        let n = scored.count
        guard n > 0 else { return 0.0 }
        guard n > 1 else { return 1.0 }
        let lexical = scored.sorted { $0.bm25Rank < $1.bm25Rank }
        let span = scored.sorted { a, b in
            if a.cosine != b.cosine { return a.cosine > b.cosine }
            return a.bm25Rank < b.bm25Rank
        }
        var posS: [String: Int] = [:]
        for (i, hit) in span.enumerated() { posS[hit.itemID] = i }
        let footrule = lexical.enumerated().reduce(0) { acc, pair in
            let (i, hit) = pair
            return acc + abs(i - (posS[hit.itemID] ?? 0))
        }
        let maximum = (n * n) / 2
        return 1.0 - Double(footrule) / Double(maximum)
    }

    /// Population std deviation of the span cosines over `scored`.
    ///
    /// Returns 0.0 when `scored` has fewer than 2 entries (no usable spread).
    /// Formula: sqrt(sum((x - mean)^2) / n).
    private func spanCosineSpread(_ scored: [SpanRerankHit]) -> Double {
        guard scored.count >= 2 else { return 0.0 }
        let values = scored.map { Double($0.cosine) }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count)
        return variance.squareRoot()
    }

    /// Word-boundary containment: returns true when a representative excerpt
    /// of the answer text (up to 8 words) appears word-by-word in the source.
    ///
    /// This is the same simple word-presence primitive the judge-audit checker
    /// uses — not a substring search, not NLP. A word is a lowercased
    /// alphanumeric token. Returns true if ≥ 60% of the answer's distinctive
    /// words appear in the source (to handle paraphrasing and punctuation
    /// differences while still catching clear non-containment).
    ///
    /// Distinctive words exclude stopwords and short tokens (≤ 3 chars).
    private func wordBoundaryContains(answer: String, inSource source: String) -> Bool {
        let answerWords = tokenise(answer).filter { $0.count > 3 && !stopwords.contains($0) }
        guard !answerWords.isEmpty else {
            // All answer words are short/stopwords: containment indeterminate → true.
            return true
        }
        let sourceWords = Set(tokenise(source))
        let hits = answerWords.filter { sourceWords.contains($0) }
        // Threshold: ≥ 60% match.
        return Double(hits.count) / Double(answerWords.count) >= 0.60
    }

    /// Tokenise text into lowercase alphanumeric tokens.
    private func tokenise(_ text: String) -> [String] {
        text.components(separatedBy: .init(charactersIn: " \t\n.,;:!?\"'()[]{}"))
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
    }

    /// Minimal English stopword list for the containment signal.
    private let stopwords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "from", "have", "not",
        "are", "was", "were", "been", "they", "their", "there", "what",
        "when", "where", "which", "will", "would", "could", "should", "about",
    ]
}
