import Foundation

// ReplayLane.swift — deterministic-replay lane fingerprint, comparison, and
// table printing for the supersession benchmarker; plus lane-capture types
// and utilities for per-query, per-lane score snapshots (--lane-capture flag).
//
// Shape, and why it is separate from the supersession lane:
//
//   The supersession lane measures whether the CURRENT version of a changed
//   fact outranks its superseded versions in recall — a product quality signal.
//   The REPLAY lane asks a different question: given the same seed, does the
//   same product produce bit-identical scored outcomes on two independent runs?
//   That is a determinism claim, not a quality claim. The two concerns are
//   orthogonal, so they live in separate types.
//
// Determinism surface:
//
//   Only fields that are a pure function of the seed and the product's
//   deterministic state are fingerprinted. Wall-clock and timing fields
//   (p50LatencySeconds, huntSeconds, tierSeconds) are EXCLUDED: they
//   legitimately vary between runs, and including them would generate false
//   drift alarms on healthy hardware.
//
//   Doubles are compared with exact == on purpose: the claim under test is
//   bit-identical determinism. If two runs produce even a 1-ULP difference,
//   something non-deterministic is happening in the product, and an epsilon
//   comparison would hide it. The replay lane is the wrong place for
//   approximate comparisons.

// MARK: - ReplayFieldDiff

/// One field comparison row returned by `compareReplayFingerprints`.
/// `fieldName` is the dotted path (e.g. "contradiction.detectedProposed"),
/// `baselineValue` and `candidateValue` are the string-formatted values from
/// run 1 and run N respectively.
struct ReplayFieldDiff: Sendable {
    let fieldName: String
    let baselineValue: String
    let candidateValue: String
}

// MARK: - ReplayFingerprint

/// The deterministic-eligible fields from one supersession lane run.
///
/// Wall-clock fields are absent by design:
/// - `SupersessionScores.p50LatencySeconds` — excluded; query latency varies
///   with system load even when the computation is deterministic.
/// - `SupersessionContradictionOutcome.huntSeconds` — excluded; same reason.
/// - `StructuredTierOutcome.tierSeconds` — excluded; same reason.
///
/// Twin of Rust `ReplayFingerprint` in replay_lane.rs.
struct ReplayFingerprint: Sendable, Equatable {

    // ── Supersession scores ───────────────────────────────────────────────

    let queryCount: Int
    let currentWinRate: Double
    let currentFoundRate: Double
    let meanStaleInTopK: Double
    /// Mean rank of the current version among queries that found it.
    let meanCurrentRank: Double

    // ── Contradiction sweep ───────────────────────────────────────────────

    /// Fingerprint of the contradiction sweep when it ran. Nil if the sweep
    /// was skipped (--skip-contradictions) or not configured.
    struct ContradictionFingerprint: Sendable, Equatable {
        let plantedCount: Int
        let detectedAnyTier: Int
        let detectedProposed: Int
        let flaggedOutsidePlanted: Int
    }
    let contradiction: ContradictionFingerprint?

    // ── Structured tier ───────────────────────────────────────────────────

    /// Fingerprint of the typed proving tier when it ran. Nil if
    /// --structured-tier was absent.
    struct StructuredTierFingerprint: Sendable, Equatable {
        let plantedCount: Int
        let provenPlanted: Int
        let provenOutsidePlanted: Int
        let provenReported: Int
        let historicalReported: Int
        let coverageProjected: Int
        let coverageScanned: Int
    }
    let structuredTier: StructuredTierFingerprint?

    // ── Tiered scoring ────────────────────────────────────────────────────

    /// Fingerprint of the MXE-CT3 P4 tiered scoring when it ran. Nil if the
    /// contradiction sweep was skipped, which means the tiered purpose runs
    /// never executed. Timing fields (tier*PurposeSeconds,
    /// synthesisWallSeconds) are excluded — they measure wall time and
    /// legitimately vary between runs. Twin of Rust `TieredFingerprint`.
    struct TieredFingerprint: Sendable, Equatable {
        let tier2PlantedCount: Int
        let tier2Detected: Int
        let tier3PlantedCount: Int
        let tier3Detected: Int
        let tierInflation: Int
        /// Hard decoy hits: marker-supersession and distinct-entity decoys
        /// flagged in any tiered section or legacy PROPOSED output. Must be 0.
        let decoyHitsHard: Int
        /// Known-limitation decoy hits: unit-equivalent decoys flagged,
        /// reported separately and never treated as a hard failure.
        let decoyHitsKnownLimitation: Int
    }
    let tiered: TieredFingerprint?
}

extension ReplayFingerprint {

    /// Builds a fingerprint from the lane's aggregate scores and outcome.
    ///
    /// Timing fields (`p50LatencySeconds`, `huntSeconds`, `tierSeconds`) are
    /// NOT carried into the fingerprint: they measure wall time and
    /// legitimately vary between runs even when the product is deterministic.
    init(scores: SupersessionScores, outcome: SupersessionLaneOutcome) {
        queryCount       = scores.queryCount
        currentWinRate   = scores.currentWinRate
        currentFoundRate = scores.currentFoundRate
        meanStaleInTopK  = scores.meanStaleInTopK
        meanCurrentRank  = scores.meanCurrentRank

        contradiction = outcome.contradiction.map {
            ContradictionFingerprint(
                plantedCount:          $0.plantedCount,
                detectedAnyTier:       $0.detectedAnyTier,
                detectedProposed:      $0.detectedProposed,
                flaggedOutsidePlanted: $0.flaggedOutsidePlanted)
        }

        structuredTier = outcome.structured.map {
            StructuredTierFingerprint(
                plantedCount:         $0.plantedCount,
                provenPlanted:        $0.provenPlanted,
                provenOutsidePlanted: $0.provenOutsidePlanted,
                provenReported:       $0.provenReported,
                historicalReported:   $0.historicalReported,
                coverageProjected:    $0.coverageProjected,
                coverageScanned:      $0.coverageScanned)
        }

        // Timing fields (tier*PurposeSeconds, synthesisWallSeconds) are
        // intentionally excluded — see type-level comment.
        tiered = outcome.tiered.map {
            TieredFingerprint(
                tier2PlantedCount:          $0.tier2PlantedCount,
                tier2Detected:              $0.tier2Detected,
                tier3PlantedCount:          $0.tier3PlantedCount,
                tier3Detected:              $0.tier3Detected,
                tierInflation:              $0.tierInflation,
                decoyHitsHard:              $0.decoyHits.hard,
                decoyHitsKnownLimitation:   $0.decoyHits.knownLimitation)
        }
    }
}

// MARK: - Comparison

/// Compares two replay fingerprints field by field and returns one
/// `ReplayFieldDiff` per drifted field. An empty result means deterministic.
///
/// Doubles are compared with exact == on purpose: the claim under test is
/// bit-identical determinism across runs from the same seed. An epsilon
/// comparison would hide a real non-determinism bug — a 1-ULP difference is
/// not a rounding artefact here but evidence of a state leak in the product.
///
/// Section-presence is itself a drift class: if the contradiction sweep or
/// structured tier ran in one fingerprint but not the other, that is reported
/// as a section-presence diff (e.g. "contradiction.present": "true" vs
/// "false") rather than silently comparing nil against a real value.
///
/// Twin of Rust `compare_replay_fingerprints`.
func compareReplayFingerprints(
    baseline: ReplayFingerprint,
    candidate: ReplayFingerprint
) -> [ReplayFieldDiff] {
    var diffs: [ReplayFieldDiff] = []

    func checkInt(_ name: String, _ a: Int, _ b: Int) {
        guard a != b else { return }
        diffs.append(ReplayFieldDiff(fieldName: name,
                                     baselineValue: "\(a)",
                                     candidateValue: "\(b)"))
    }

    // Exact == is intentional — see function-level comment.
    func checkDouble(_ name: String, _ a: Double, _ b: Double) {
        guard a != b else { return }
        diffs.append(ReplayFieldDiff(fieldName: name,
                                     baselineValue: "\(a)",
                                     candidateValue: "\(b)"))
    }

    // ── Scores ────────────────────────────────────────────────────────────
    checkInt   ("queryCount",       baseline.queryCount,       candidate.queryCount)
    checkDouble("currentWinRate",   baseline.currentWinRate,   candidate.currentWinRate)
    checkDouble("currentFoundRate", baseline.currentFoundRate, candidate.currentFoundRate)
    checkDouble("meanStaleInTopK",  baseline.meanStaleInTopK,  candidate.meanStaleInTopK)
    checkDouble("meanCurrentRank",  baseline.meanCurrentRank,  candidate.meanCurrentRank)

    // ── Contradiction sweep ────────────────────────────────────────────────
    switch (baseline.contradiction, candidate.contradiction) {
    case (.none, .none):
        break   // both absent: consistent, nothing to report
    case (.some, .none):
        // Contradiction ran in the baseline but not the candidate: presence drift.
        diffs.append(ReplayFieldDiff(
            fieldName: "contradiction.present",
            baselineValue: "true", candidateValue: "false"))
    case (.none, .some):
        diffs.append(ReplayFieldDiff(
            fieldName: "contradiction.present",
            baselineValue: "false", candidateValue: "true"))
    case let (.some(a), .some(b)):
        checkInt("contradiction.plantedCount",
                 a.plantedCount,          b.plantedCount)
        checkInt("contradiction.detectedAnyTier",
                 a.detectedAnyTier,       b.detectedAnyTier)
        checkInt("contradiction.detectedProposed",
                 a.detectedProposed,      b.detectedProposed)
        checkInt("contradiction.flaggedOutsidePlanted",
                 a.flaggedOutsidePlanted, b.flaggedOutsidePlanted)
    }

    // ── Structured tier ───────────────────────────────────────────────────
    switch (baseline.structuredTier, candidate.structuredTier) {
    case (.none, .none):
        break
    case (.some, .none):
        diffs.append(ReplayFieldDiff(
            fieldName: "structuredTier.present",
            baselineValue: "true", candidateValue: "false"))
    case (.none, .some):
        diffs.append(ReplayFieldDiff(
            fieldName: "structuredTier.present",
            baselineValue: "false", candidateValue: "true"))
    case let (.some(a), .some(b)):
        checkInt("structuredTier.plantedCount",
                 a.plantedCount,         b.plantedCount)
        checkInt("structuredTier.provenPlanted",
                 a.provenPlanted,        b.provenPlanted)
        checkInt("structuredTier.provenOutsidePlanted",
                 a.provenOutsidePlanted, b.provenOutsidePlanted)
        checkInt("structuredTier.provenReported",
                 a.provenReported,       b.provenReported)
        checkInt("structuredTier.historicalReported",
                 a.historicalReported,   b.historicalReported)
        checkInt("structuredTier.coverageProjected",
                 a.coverageProjected,    b.coverageProjected)
        checkInt("structuredTier.coverageScanned",
                 a.coverageScanned,      b.coverageScanned)
    }

    // ── Tiered scoring ────────────────────────────────────────────────────
    // Section-presence is itself a drift class: if the tiered scoring ran in
    // one fingerprint but not the other, that asymmetry is reported via the
    // presence row rather than silently comparing nil against a real value.
    switch (baseline.tiered, candidate.tiered) {
    case (.none, .none):
        break   // both absent: consistent
    case (.some, .none):
        diffs.append(ReplayFieldDiff(
            fieldName: "tiered.present",
            baselineValue: "true", candidateValue: "false"))
    case (.none, .some):
        diffs.append(ReplayFieldDiff(
            fieldName: "tiered.present",
            baselineValue: "false", candidateValue: "true"))
    case let (.some(a), .some(b)):
        checkInt("tiered.tier2PlantedCount",
                 a.tier2PlantedCount,        b.tier2PlantedCount)
        checkInt("tiered.tier2Detected",
                 a.tier2Detected,            b.tier2Detected)
        checkInt("tiered.tier3PlantedCount",
                 a.tier3PlantedCount,        b.tier3PlantedCount)
        checkInt("tiered.tier3Detected",
                 a.tier3Detected,            b.tier3Detected)
        checkInt("tiered.tierInflation",
                 a.tierInflation,            b.tierInflation)
        checkInt("tiered.decoyHits.hard",
                 a.decoyHitsHard,            b.decoyHitsHard)
        checkInt("tiered.decoyHits.knownLimitation",
                 a.decoyHitsKnownLimitation, b.decoyHitsKnownLimitation)
    }

    return diffs
}

// MARK: - Table printer

/// Prints the rendered MATCH/DRIFT table (see `renderReplayFieldTable`).
/// Kept as a thin writer so the rendering itself is unit-testable — the
/// first live shakedown found a crash in the (then untested) formatting
/// path that no pure comparison test could have caught.
func printReplayFieldTable(
    baseline: ReplayFingerprint,
    candidate: ReplayFingerprint,
    diffs: [ReplayFieldDiff],
    candidateRunIndex: Int,
    seed: UInt64,
    totalRuns: Int
) {
    let rendered = renderReplayFieldTable(
        baseline: baseline, candidate: candidate, diffs: diffs,
        candidateRunIndex: candidateRunIndex, seed: seed, totalRuns: totalRuns)
    FileHandle.standardOutput.write(Data(rendered.utf8))
}

/// Renders a per-field MATCH/DRIFT table comparing `baseline` (run 1) against
/// `candidate` (run `candidateRunIndex`), ending with the verdict line.
///
/// ALL fields are shown — including matching ones — so the report demonstrates
/// exactly what was checked, not only what changed. The presence rows for the
/// optional contradiction/structured-tier sections always appear; the
/// sub-field rows only appear when BOTH fingerprints have that section (the
/// section-presence row already captures the asymmetric case).
///
/// `diffs` must be the result of calling
/// `compareReplayFingerprints(baseline:candidate:)` on the same pair —
/// passing a pre-computed result avoids recomputing inside the renderer.
func renderReplayFieldTable(
    baseline: ReplayFingerprint,
    candidate: ReplayFingerprint,
    diffs: [ReplayFieldDiff],
    candidateRunIndex: Int,
    seed: UInt64,
    totalRuns: Int
) -> String {
    // Field names in drifted diffs, for O(1) verdict lookup.
    let driftedNames = Set(diffs.map(\.fieldName))

    let col0 = 40   // field name
    let col1 = 22   // run 1 value
    let col2 = 22   // run N value
    // verdict column: no width constraint — always "MATCH" or "DRIFT"

    // Left-pads with spaces to a fixed column width. String(format:) with
    // %s is NOT used here on purpose: Swift Strings are not C strings, and
    // passing one to %s is undefined behavior (it segfaulted in the first
    // live shakedown). Pure-Swift padding is safe and sufficient.
    func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    // A formatted row. `verdict` reads from `driftedNames`.
    func row(_ field: String, _ v1: String, _ v2: String) -> String {
        let verdict = driftedNames.contains(field) ? "DRIFT" : "MATCH"
        return pad(field, col0) + "  " + pad(v1, col1) + "  " + pad(v2, col2)
            + "  " + verdict
    }

    let header = pad("field", col0) + "  " + pad("run 1", col1) + "  "
        + pad("run \(candidateRunIndex)", col2) + "  verdict"
    // Separator spans all four columns plus spacing.
    let sep = String(repeating: "-", count: col0 + col1 + col2 + 20)

    var lines: [String] = ["", header, sep]

    // ── Scores ────────────────────────────────────────────────────────────
    lines.append(row("queryCount",
        "\(baseline.queryCount)",
        "\(candidate.queryCount)"))
    lines.append(row("currentWinRate",
        String(format: "%.6f", baseline.currentWinRate),
        String(format: "%.6f", candidate.currentWinRate)))
    lines.append(row("currentFoundRate",
        String(format: "%.6f", baseline.currentFoundRate),
        String(format: "%.6f", candidate.currentFoundRate)))
    lines.append(row("meanStaleInTopK",
        String(format: "%.6f", baseline.meanStaleInTopK),
        String(format: "%.6f", candidate.meanStaleInTopK)))
    lines.append(row("meanCurrentRank",
        String(format: "%.6f", baseline.meanCurrentRank),
        String(format: "%.6f", candidate.meanCurrentRank)))

    // ── Contradiction sweep ────────────────────────────────────────────────
    // Presence row always appears; sub-field rows only when both have the section.
    lines.append(row("contradiction.present",
        baseline.contradiction != nil    ? "present" : "absent",
        candidate.contradiction != nil   ? "present" : "absent"))
    if let a = baseline.contradiction, let b = candidate.contradiction {
        lines.append(row("contradiction.plantedCount",
            "\(a.plantedCount)", "\(b.plantedCount)"))
        lines.append(row("contradiction.detectedAnyTier",
            "\(a.detectedAnyTier)", "\(b.detectedAnyTier)"))
        lines.append(row("contradiction.detectedProposed",
            "\(a.detectedProposed)", "\(b.detectedProposed)"))
        lines.append(row("contradiction.flaggedOutsidePlanted",
            "\(a.flaggedOutsidePlanted)", "\(b.flaggedOutsidePlanted)"))
    }

    // ── Structured tier ───────────────────────────────────────────────────
    lines.append(row("structuredTier.present",
        baseline.structuredTier != nil   ? "present" : "absent",
        candidate.structuredTier != nil  ? "present" : "absent"))
    if let a = baseline.structuredTier, let b = candidate.structuredTier {
        lines.append(row("structuredTier.plantedCount",
            "\(a.plantedCount)", "\(b.plantedCount)"))
        lines.append(row("structuredTier.provenPlanted",
            "\(a.provenPlanted)", "\(b.provenPlanted)"))
        lines.append(row("structuredTier.provenOutsidePlanted",
            "\(a.provenOutsidePlanted)", "\(b.provenOutsidePlanted)"))
        lines.append(row("structuredTier.provenReported",
            "\(a.provenReported)", "\(b.provenReported)"))
        lines.append(row("structuredTier.historicalReported",
            "\(a.historicalReported)", "\(b.historicalReported)"))
        lines.append(row("structuredTier.coverageProjected",
            "\(a.coverageProjected)", "\(b.coverageProjected)"))
        lines.append(row("structuredTier.coverageScanned",
            "\(a.coverageScanned)", "\(b.coverageScanned)"))
    }

    // ── Tiered scoring ────────────────────────────────────────────────────
    // Presence row always appears; sub-field rows only when both fingerprints
    // carry the section. The presence row already captures the asymmetric case.
    lines.append(row("tiered.present",
        baseline.tiered != nil ? "present" : "absent",
        candidate.tiered != nil ? "present" : "absent"))
    if let a = baseline.tiered, let b = candidate.tiered {
        lines.append(row("tiered.tier2PlantedCount",
            "\(a.tier2PlantedCount)", "\(b.tier2PlantedCount)"))
        lines.append(row("tiered.tier2Detected",
            "\(a.tier2Detected)", "\(b.tier2Detected)"))
        lines.append(row("tiered.tier3PlantedCount",
            "\(a.tier3PlantedCount)", "\(b.tier3PlantedCount)"))
        lines.append(row("tiered.tier3Detected",
            "\(a.tier3Detected)", "\(b.tier3Detected)"))
        lines.append(row("tiered.tierInflation",
            "\(a.tierInflation)", "\(b.tierInflation)"))
        lines.append(row("tiered.decoyHits.hard",
            "\(a.decoyHitsHard)", "\(b.decoyHitsHard)"))
        lines.append(row("tiered.decoyHits.knownLimitation",
            "\(a.decoyHitsKnownLimitation)", "\(b.decoyHitsKnownLimitation)"))
    }

    lines.append(sep)

    // Verdict line: DETERMINISTIC if no diffs; DRIFT with field count otherwise.
    let verdictLine: String
    if diffs.isEmpty {
        verdictLine = "[replay] verdict: DETERMINISTIC (\(totalRuns) runs, seed \(seed))"
    } else {
        verdictLine = "[replay] verdict: DRIFT — \(diffs.count) field(s) differ across runs"
    }
    lines.append(verdictLine)
    lines.append("")

    // The trailing empty element gives the joined string its final newline;
    // the writer emits this string verbatim.
    return lines.joined(separator: "\n")
}

// MARK: - Lane Capture

/// Score decomposition for one recall hit, parsed from a RecallExplainer
/// `score:` line. Only non-zero components appear in the explainer output;
/// absent components default to 0.0. Field names match the explainer's
/// score tokens verbatim so a product format change fails the fixture test
/// instead of silently capturing zeros.
///
/// Possible score tokens (RecallExplainer.swift:39-47):
///   locus, bm25, vector, dense, fieldFit, coOccurrence, temporal, graph, preference
///
/// Twin of Rust `HitLaneScores` in replay_lane.rs.
struct HitLaneScores: Sendable {
    let locus: Double
    let bm25: Double
    let vector: Double
    let dense: Double
    let fieldFit: Double
    let coOccurrence: Double
    let temporal: Double
    let graph: Double
    let preference: Double
}

/// Per-query lane snapshot for one replay run.
///
/// Twin of Rust `QueryLaneSnapshot` in replay_lane.rs.
struct QueryLaneSnapshot: Sendable {
    let queryID: String
    /// ISO8601 wall-clock timestamp when the query was issued.
    let queryTimestamp: String
    /// One entry per selected hit in result order (top-1 first).
    let hitScores: [HitLaneScores]
}

/// Per-run collection of per-query lane snapshots. Created by
/// `runSupersessionLane` when `config.laneCapture` is true.
///
/// `importTimestamp` records when the encode queue converged for this run.
/// Because each replay run builds a fresh estate at a different wall-clock
/// instant, comparing `importTimestamp` values across runs identifies whether
/// drifting lane magnitudes correlate with clock differences — when they do,
/// the clock is the variable, not the product's scoring logic.
///
/// Twin of Rust `LaneCapture` in replay_lane.rs.
struct LaneCapture: Sendable {
    /// ISO8601 wall-clock when the estate's encode queue converged.
    let importTimestamp: String
    let snapshots: [QueryLaneSnapshot]
}

/// Per-lane drift summary comparing two captures. Produced by
/// `diffLaneCaptures(baseline:candidate:)`.
///
/// `deltaAbs` is `|baselineMean - candidateMean|`. Lanes are sorted by
/// `deltaAbs` descending in the result of `diffLaneCaptures`.
///
/// Twin of Rust `LaneDiff` in replay_lane.rs.
struct LaneDiff: Sendable {
    let laneName: String
    let baselineMean: Double
    let candidateMean: Double
    var deltaAbs: Double { abs(baselineMean - candidateMean) }
}

// MARK: - Lane capture parsing

/// Parses RecallExplainer output from the text blocks of one recall call.
///
/// The explainer emits 4 lines per selected hit, directly after the UUID
/// result line (RecallExplainer.swift:8-11). This function finds each UUID
/// line, then scans the next 4 lines for `score: <tokens>`, and extracts
/// per-lane values from the token list. Lines that don't start with a UUID
/// (e.g. the sources/mode/why explainer lines themselves) are skipped by
/// the UUID test. Returns a snapshot with an empty `hitScores` array if no
/// explain lines are found — callers should treat that as "explain not active
/// for this call" rather than a parse error.
///
/// This function is testable against a verbatim fixture: if the product's
/// RecallExplainer format changes, the fixture test in `SeedPathTests.swift`
/// will fail loudly instead of silently capturing zeros.
///
/// Twin of Rust `parse_lane_capture_lines` in replay_lane.rs.
func parseLaneCaptureLines(
    _ textBlocks: [String],
    queryID: String,
    timestamp: String
) -> QueryLaneSnapshot {
    let text = textBlocks.joined(separator: "\n")
    var hitScores: [HitLaneScores] = []

    // Walk lines; a UUID-prefixed line starts a new hit. The next score:
    // line within the following 4 lines is the per-lane breakdown.
    let lines = text.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
        let line = lines[i].trimmingCharacters(in: .whitespaces)
        if isUUIDPrefixedLine(line) {
            // Look for `score:` in the next 1-4 lines (explainer order:
            // sources, score, mode, why — score is always line 2).
            let limit = min(i + 5, lines.count)
            for j in (i + 1)..<limit {
                let next = lines[j].trimmingCharacters(in: .whitespaces)
                if next.hasPrefix("score: ") {
                    hitScores.append(parseScoreTokens(String(next.dropFirst("score: ".count))))
                    break
                }
            }
        }
        i += 1
    }

    return QueryLaneSnapshot(queryID: queryID, queryTimestamp: timestamp, hitScores: hitScores)
}

/// Returns true when `line` begins with a canonical UUID token (8-4-4-4-12 hex).
private func isUUIDPrefixedLine(_ line: String) -> Bool {
    guard let spaceOrEnd = line.firstIndex(of: " ").map({ line.distance(from: line.startIndex, to: $0) })
              ?? (line.isEmpty ? nil : Optional(line.count)) else { return false }
    // UUID string is always 36 chars (8+1+4+1+4+1+4+1+12).
    guard spaceOrEnd >= 36 else { return false }
    let candidate = String(line.prefix(36))
    return UUID(uuidString: candidate) != nil
}

/// Parses a `score:` token string into `HitLaneScores`.
///
/// Input is the portion after `score: `, e.g. `"locus=0.82 bm25=0.71"` or
/// `"final=0.55"` (the fallback when all component scores are zero).
/// Unrecognised tokens are silently ignored so new RecallExplainer components
/// don't break parsing of old lanes.
///
/// Twin of Rust `parse_score_tokens` in replay_lane.rs.
func parseScoreTokens(_ tokens: String) -> HitLaneScores {
    var locus = 0.0, bm25 = 0.0, vector = 0.0, dense = 0.0
    var fieldFit = 0.0, coOccurrence = 0.0, temporal = 0.0
    var graph = 0.0, preference = 0.0

    for token in tokens.split(separator: " ") {
        let parts = token.split(separator: "=", maxSplits: 1)
        guard parts.count == 2, let value = Double(parts[1]) else { continue }
        switch String(parts[0]) {
        case "locus":        locus        = value
        case "bm25":         bm25         = value
        case "vector":       vector       = value
        case "dense":        dense        = value
        case "fieldFit":     fieldFit     = value
        case "coOccurrence": coOccurrence = value
        case "temporal":     temporal     = value
        case "graph":        graph        = value
        case "preference":   preference   = value
        default:             break        // forward-compatible: ignore new tokens
        }
    }

    return HitLaneScores(
        locus: locus, bm25: bm25, vector: vector, dense: dense,
        fieldFit: fieldFit, coOccurrence: coOccurrence,
        temporal: temporal, graph: graph, preference: preference)
}

// MARK: - Lane diff

/// Computes per-lane mean scores for each capture and returns a `LaneDiff`
/// per lane, sorted by `deltaAbs` descending (highest-drift lane first).
///
/// The mean is over all hits in all snapshots in the capture. Queries with
/// zero hits (explain not active or no results) contribute nothing to the
/// count; if the entire capture is empty, means are 0.0.
///
/// Twin of Rust `diff_lane_captures` in replay_lane.rs.
func diffLaneCaptures(baseline: LaneCapture, candidate: LaneCapture) -> [LaneDiff] {
    func means(_ capture: LaneCapture) -> HitLaneScores {
        var s = (l: 0.0, b: 0.0, v: 0.0, d: 0.0, ff: 0.0, co: 0.0, t: 0.0, g: 0.0, p: 0.0)
        var n = 0
        for snap in capture.snapshots {
            for h in snap.hitScores {
                s.l += h.locus;  s.b += h.bm25;         s.v += h.vector
                s.d += h.dense;  s.ff += h.fieldFit;     s.co += h.coOccurrence
                s.t += h.temporal; s.g += h.graph;       s.p += h.preference
                n += 1
            }
        }
        let c = n > 0 ? Double(n) : 1.0
        return HitLaneScores(
            locus: s.l/c, bm25: s.b/c, vector: s.v/c, dense: s.d/c,
            fieldFit: s.ff/c, coOccurrence: s.co/c,
            temporal: s.t/c, graph: s.g/c, preference: s.p/c)
    }

    let bm = means(baseline)
    let cm = means(candidate)

    let lanes: [(String, Double, Double)] = [
        ("locus",        bm.locus,        cm.locus),
        ("bm25",         bm.bm25,         cm.bm25),
        ("vector",       bm.vector,       cm.vector),
        ("dense",        bm.dense,        cm.dense),
        ("fieldFit",     bm.fieldFit,     cm.fieldFit),
        ("coOccurrence", bm.coOccurrence, cm.coOccurrence),
        ("temporal",     bm.temporal,     cm.temporal),
        ("graph",        bm.graph,        cm.graph),
        ("preference",   bm.preference,   cm.preference),
    ]

    return lanes.map { name, b, c in
        LaneDiff(laneName: name, baselineMean: b, candidateMean: c)
    }.sorted { $0.deltaAbs > $1.deltaAbs }
}

// MARK: - Lane diff table renderer

/// Renders a per-lane mean-score diff table comparing two captures, ending
/// with the import-timestamp delta for clock correlation.
///
/// All lanes are shown (including zero-delta lanes) so the report proves
/// exactly what was checked, not only what changed.
///
/// Twin of Rust `render_lane_diff_table` in replay_lane.rs.
func renderLaneDiffTable(
    baseline: LaneCapture,
    candidate: LaneCapture,
    diffs: [LaneDiff],
    label1: String = "run 1",
    label2: String = "run 2"
) -> String {
    let col0 = 16   // lane name
    let col1 = 12   // baseline mean
    let col2 = 12   // candidate mean
    let col3 = 12   // |delta|

    func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    let header = pad("lane", col0) + "  " + pad(label1, col1) + "  "
        + pad(label2, col2) + "  " + pad("|delta|", col3) + "  verdict"
    let sep = String(repeating: "-", count: col0 + col1 + col2 + col3 + 22)

    var lines: [String] = [
        "import timestamps:",
        "  \(label1): \(baseline.importTimestamp)",
        "  \(label2): \(candidate.importTimestamp)",
        "",
        header,
        sep,
    ]

    // Use the diff list's order (sorted by deltaAbs descending).
    for d in diffs {
        let verdict = d.deltaAbs > 0.0 ? "DRIFT" : "match"
        lines.append(
            pad(d.laneName, col0) + "  "
            + pad(String(format: "%.6f", d.baselineMean), col1) + "  "
            + pad(String(format: "%.6f", d.candidateMean), col2) + "  "
            + pad(String(format: "%.6f", d.deltaAbs), col3) + "  " + verdict)
    }

    lines.append(sep)
    lines.append("")

    return lines.joined(separator: "\n")
}
