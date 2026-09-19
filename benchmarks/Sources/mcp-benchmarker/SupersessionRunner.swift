import Foundation

// SupersessionRunner.swift — drives the supersession / contradiction lane.
//
// Shape, and how it differs from every other lane in this harness:
//
//   ONE estate for the whole run. The other lanes provision a fresh scratch
//   estate per question, which is correct for pure retrieval but makes
//   history-dependent behaviour unmeasurable — matrix priors are 0.0 without
//   an audit trail to compute them from. Here the whole timeline is ingested
//   into a single estate, in chronological order, and only then is anything
//   asked. That is the condition a deployed memory system actually runs in.
//
//   Ingest carries `event_time`, so the estate's timeline matches the
//   corpus's fiction rather than collapsing to ingestion order.
//
// SCORED BEHAVIOURS
//
//   1. Current-over-stale. For each chain, does the still-true version outrank
//      every superseded version of the same fact? This is the question the
//      public benchmarks do not ask: they score "was the right item found",
//      which a system passes while also returning two stale contradictions of
//      it. Retrieval alone cannot distinguish a right answer from a right
//      answer buried in wrong ones.
//   2. Stale contamination@k. How many superseded versions ride along in the
//      top k. A consumer pasting top-k into a prompt gets every one of them.
//   3. Contradiction detection. For claim pairs that cannot both be true and
//      carry NO temporal ordering, recency cannot help; the correct behaviour
//      is to surface the conflict.

struct SupersessionQueryResult: Sendable {
    let queryID: String
    /// Rank of the current version, 1-based. nil when it never appeared.
    let currentRank: Int?
    /// Ranks of superseded versions that appeared, 1-based.
    let staleRanks: [Int]
    /// True when the current version outranks every stale version present.
    let currentWins: Bool
    /// Superseded versions inside the top-k window.
    let staleInTopK: Int
    let latencySeconds: Double
    /// False when the degeneracy guard refused this query (query-invariant
    /// frozen-ranking detected, C5). A refused query is excluded from all
    /// published accuracy figures.
    let guardHealthy: Bool
}

struct SupersessionRunConfig: Sendable {
    let mootBinaryPath: String
    let seed: UInt64
    let entityCount: Int
    let versionsPerChain: Int
    let contradictionCount: Int
    /// Contamination window. 10 mirrors the recall@10 cut-off used elsewhere.
    let topK: Int
    /// RecallShape preset, or nil for plain `moot_memory_search`.
    let recallShape: String?
    let scratchDir: URL
    /// Scratch posture. Ephemeral by default — see runSupersessionLane.
    let posture: ScratchEstatePosture
    /// Run the contradiction sweep (scored behaviour 3). On by default;
    /// `--skip-contradictions` turns it off for ranking-only runs.
    let contradictionSweep: Bool
    /// Run `moot_dream` after the drain barrier and before the ranking
    /// queries. This is the UN-STARVING step: moot_dream rebuilds and
    /// registers the estate's MatrixTier from the audit log (keyed off
    /// eventTime, so the corpus's fictional timeline drives the temporal
    /// matrix), which is the ONLY thing that makes the fieldFit /
    /// coOccurrence / temporal score columns non-zero — and with them the
    /// temporal / connection / field / preference presets measurable.
    /// Proven the hard way: six matrix-steering presets returned
    /// byte-identical rankings on undreamed estates because the columns
    /// were all 0.0 by contract. On by default; `--skip-dream` produces
    /// the virgin-estate comparison cell. The two cells are different
    /// estate states and every published figure names which one it is.
    let dreamBeforeQueries: Bool
    /// Typed proving tier: after everything else, file one KGFact per corpus
    /// record (anchored to its ingest drawer) and score the TYPED proving
    /// lane against the planted pairs — the measurement the lexical hunter's
    /// 0/10 baseline motivated. Off by default; `--structured-tier`.
    let structuredTier: Bool
    /// How the corpus is loaded into the estate. `batch` (the default, ruling
    /// 8D5B8053): emit seed-file schema v1 → one `moot_json_import` → the
    /// encode barrier → attribution pass. `live` is the retained slow lane
    /// (per-record `moot_file_memory`) for periodic equivalence re-proving.
    let seedPath: SeedPathMode
    /// When true, thread `explain: true` into each recall call and parse the
    /// RecallExplainer output into a `LaneCapture` returned in the outcome.
    /// Off by default so existing callers compile without modification.
    var laneCapture: Bool = false
    /// Backend persistence shape for the scratch estate (C1).
    /// `.disk` = SQLite (default); `.ram` = PersistenceKit InMemory via
    /// --in-memory injected into the serve command.
    var shape: LMEShape = .disk
    /// How often the DegeneracyGuard probe is issued within the query leg (C5).
    /// `.oncePerLeg` (default): probe on the first query only, cache the verdict.
    /// `.perUnit`: re-probe on every query (debug only — adds 3 MCP calls per query).
    var guardSamplingPolicy: GuardSamplingPolicy = .oncePerLeg
    /// ISO8601 instant to pin as the bench-clock epoch (`MOOT_BENCH_EPOCH_NOW`).
    ///
    /// When non-nil, the serve command for this run carries
    /// `MOOT_BENCH_EPOCH_NOW=<value>` so the product server pins its clock to
    /// that instant. Derived deterministically from `seed` in replay runs so
    /// same seed → same `filedAt` stamps and temporal scores across runs. Nil
    /// (default) in non-replay production lanes — wall-clock mode, production
    /// behaviour unchanged.
    var benchClockEpoch: String? = nil
}

/// Projects supersession corpus records (in the caller's order — file order
/// is ingestion order) onto seed-file records. Pure. Wing is omitted so the
/// import files into the same default wing ("Agentic Memory") the live
/// `moot_file_memory` path uses; the room mirrors the live `location`.
///
/// Determinism note: `captureDate` is set to `eventTime` for every record.
/// Without it, all records in the batch share the same `filedAt` (the single
/// `Date()` call inside `captureBatch`) and SQLite `ORDER BY filedAt DESC, id
/// DESC` resolves ties by UUID — which differs between replay runs (UUIDs are
/// minted fresh per drawer). Setting `captureDate = eventTime` gives each
/// drawer a unique, seed-deterministic `filedAt` that is identical across
/// runs of the same seed, so the locus-lane fetch order and the
/// `agreementBonus` bit-counts are identical across all replay runs.
func supersessionSeedRecords(from records: [SupersessionRecord]) -> [SeedFileRecord] {
    records.map { record in
        SeedFileRecord(
            id: record.id,
            content: record.content,
            eventTime: record.eventTime,
            room: "supersession/" + record.attribute,
            captureDate: record.captureDate ?? record.eventTime)
    }
}

/// Everything one supersession lane run produces: the ranking results and,
/// when the sweep ran, the contradiction-detection outcome.
struct SupersessionLaneOutcome: Sendable {
    let queryResults: [SupersessionQueryResult]
    let contradiction: SupersessionContradictionOutcome?
    /// Typed proving tier, when it ran.
    let structured: StructuredTierOutcome?
    /// MXE-CT3 P4 tiered scoring (purpose runs + synthesis exactly-once +
    /// decoys), when the contradiction sweep ran.
    let tiered: TieredScoringOutcome?
    /// Per-query, per-lane score snapshots captured when `laneCapture` was
    /// active. Nil when the flag was off. Off by default to preserve existing
    /// callers without requiring `laneCapture:` in their memberwise init call.
    var laneCapture: LaneCapture? = nil
}

/// The typed proving lane scored against the planted pairs. Two figures:
/// the recency-unresolvable pairs must prove (target: all of them), and
/// zero PROVEN pairs outside the planted set — the supersession CHAINS
/// (same coordinate, DIFFERENT event times) must resolve as historical
/// succession, never as proof.
struct StructuredTierOutcome: Sendable {
    /// Planted pairs (the proven-planted denominator).
    let plantedCount: Int
    /// Planted pairs that surfaced as PROVEN blocks.
    let provenPlanted: Int
    /// PROVEN pairs whose two source drawers are NOT a planted pair —
    /// the false-proof figure; any non-zero value here is a false proof.
    let provenOutsidePlanted: Int
    /// The report's own `proven:` count line.
    let provenReported: Int
    /// The report's `historical:` count (the chains, resolved by time).
    let historicalReported: Int
    /// The report's `coverage: projected/scanned` figures.
    let coverageProjected: Int
    let coverageScanned: Int
    /// Wall time of the fact filing + lens call.
    let tierSeconds: Double
}

/// One PROVEN block parsed from the typed conflict-projection section:
/// the two source-drawer UUIDs cited as dense rows under the block.
struct ReportedProvenPair: Sendable, Equatable {
    let a: String
    let b: String
}

/// Parses the typed section (M0 §7) out of a contradiction-surface
/// report: the `proven:`/`historical:`/`coverage:` count lines plus the
/// source-drawer UUID pair under each `PROVEN` block (dense-row first
/// tokens). Redacted (`[restricted]`) and secret blocks carry no ids and
/// parse as counts only.
func parseTypedConflictSection(
    _ text: String
) -> (proven: Int, historical: Int, projected: Int, scanned: Int,
      pairs: [ReportedProvenPair]) {
    var proven = 0, historical = 0, projected = 0, scanned = 0
    var pairs: [ReportedProvenPair] = []
    var currentBlockIDs: [String] = []
    func closeBlock() {
        if currentBlockIDs.count == 2 {
            pairs.append(ReportedProvenPair(a: currentBlockIDs[0], b: currentBlockIDs[1]))
        }
        currentBlockIDs = []
    }
    var inBlock = false
    for rawLine in text.components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("proven: "), let n = Int(line.dropFirst("proven: ".count)) {
            proven = n
        } else if line.hasPrefix("historical: "),
                  let n = Int(line.dropFirst("historical: ".count)) {
            historical = n
        } else if line.hasPrefix("coverage: ") {
            let parts = line.dropFirst("coverage: ".count).split(separator: "/")
            if parts.count == 2, let p = Int(parts[0]), let s = Int(parts[1]) {
                projected = p
                scanned = s
            }
        } else if line.hasPrefix("PROVEN ") {
            closeBlock()
            inBlock = true
        } else if inBlock {
            // Inside a block: detail lines are `key: value`; the two
            // dense rows open with the drawer UUID followed by the
            // ` · ` separator. Any non-detail, non-dense line ends the
            // block.
            if line.contains(" · ") {
                if let first = line.split(separator: " ").first {
                    currentBlockIDs.append(String(first))
                }
            } else if !line.contains(": ") {
                closeBlock()
                inBlock = false
            }
        }
    }
    closeBlock()
    return (proven, historical, projected, scanned, pairs)
}

/// Scores the typed section's PROVEN pairs against the planted pairs,
/// through the same UUID attribution map the lexical scorer uses.
func scoreStructuredTier(
    planted: [ContradictionPair],
    uuidByRecordID: [String: String],
    parsed: (proven: Int, historical: Int, projected: Int, scanned: Int,
             pairs: [ReportedProvenPair]),
    tierSeconds: Double
) -> StructuredTierOutcome {
    var plantedSets: [Set<String>] = []
    for pair in planted {
        guard let l = uuidByRecordID[pair.leftRecordID],
              let r = uuidByRecordID[pair.rightRecordID] else {
            plantedSets.append([])
            continue
        }
        plantedSets.append([l, r])
    }
    var provenPlanted = 0
    for set in plantedSets where !set.isEmpty {
        if parsed.pairs.contains(where: { Set([$0.a, $0.b]) == set }) {
            provenPlanted += 1
        }
    }
    let outside = parsed.pairs.filter { !plantedSets.contains(Set([$0.a, $0.b])) }.count
    return StructuredTierOutcome(
        plantedCount: planted.count,
        provenPlanted: provenPlanted,
        provenOutsidePlanted: outside,
        provenReported: parsed.proven,
        historicalReported: parsed.historical,
        coverageProjected: parsed.projected,
        coverageScanned: parsed.scanned,
        tierSeconds: tierSeconds)
}

/// The contradiction sweep's outcome against the planted pairs.
struct SupersessionContradictionOutcome: Sendable {
    /// Planted pairs in the corpus (the denominator).
    let plantedCount: Int
    /// Planted pairs the hunter surfaced at ANY tier (PROPOSED or CANDIDATE),
    /// either drawer order.
    let detectedAnyTier: Int
    /// Planted pairs surfaced at the PROPOSED tier (auto-recorded edges).
    let detectedProposed: Int
    /// Reported pairs whose two drawers are NOT a planted pair. NOT labelled
    /// false positives: superseded chain versions genuinely conflict too —
    /// they are just resolvable by recency, which the planted pairs are not.
    let flaggedOutsidePlanted: Int
    /// Wall time of the sweep call.
    let huntSeconds: Double
}

/// One reported pair from the hunt output.
enum ContradictionReportTier: String, Sendable { case proposed, candidate }
struct ReportedContradictionPair: Sendable, Equatable {
    let a: String
    let b: String
    let tier: String
}

/// Parses `moot_hunt_contradictions` plain-text output into reported drawer
/// pairs. Recognized lines (leading whitespace ignored):
///   `PROPOSED <a> contradicts <b> (<cue>, score S, tunnel T)`
///   `CANDIDATE <a> vs <b> (<cue>, score S)`
/// Anything else (headers, snippets, guidance) is skipped.
func parseHuntContradictionsReport(_ text: String) -> [ReportedContradictionPair] {
    var pairs: [ReportedContradictionPair] = []
    for rawLine in text.components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("PROPOSED ") {
            let rest = line.dropFirst("PROPOSED ".count)
            let parts = rest.components(separatedBy: " contradicts ")
            guard parts.count == 2 else { continue }
            let b = parts[1].components(separatedBy: " (").first ?? parts[1]
            pairs.append(ReportedContradictionPair(
                a: parts[0], b: b, tier: ContradictionReportTier.proposed.rawValue))
        } else if line.hasPrefix("CANDIDATE ") {
            let rest = line.dropFirst("CANDIDATE ".count)
            let parts = rest.components(separatedBy: " vs ")
            guard parts.count == 2 else { continue }
            let b = parts[1].components(separatedBy: " (").first ?? parts[1]
            pairs.append(ReportedContradictionPair(
                a: parts[0], b: b, tier: ContradictionReportTier.candidate.rawValue))
        }
    }
    return pairs
}

/// Scores the hunter's reported pairs against the planted pairs. Mapping is
/// through the write-assigned drawer UUIDs captured at ingest; a planted pair
/// whose records never got a UUID counts as undetected (truthful — the
/// hunter could not have reported it, but the lane failed to plant it).
func scoreContradictionSweep(
    planted: [ContradictionPair],
    uuidByRecordID: [String: String],
    reported: [ReportedContradictionPair],
    huntSeconds: Double
) -> SupersessionContradictionOutcome {
    // Unordered planted UUID pairs → detection tiers seen for that pair.
    var plantedSets: [Set<String>] = []
    for pair in planted {
        guard let l = uuidByRecordID[pair.leftRecordID],
              let r = uuidByRecordID[pair.rightRecordID] else {
            plantedSets.append([])  // unmappable: never matches
            continue
        }
        plantedSets.append([l, r])
    }
    var detectedAny = 0
    var detectedProposed = 0
    for set in plantedSets where !set.isEmpty {
        let hits = reported.filter { Set([$0.a, $0.b]) == set }
        if !hits.isEmpty { detectedAny += 1 }
        if hits.contains(where: { $0.tier == ContradictionReportTier.proposed.rawValue }) {
            detectedProposed += 1
        }
    }
    let outside = reported.filter { rep in
        let s = Set([rep.a, rep.b])
        return !plantedSets.contains(s)
    }.count
    return SupersessionContradictionOutcome(
        plantedCount: planted.count,
        detectedAnyTier: detectedAny,
        detectedProposed: detectedProposed,
        flaggedOutsidePlanted: outside,
        huntSeconds: huntSeconds)
}

// MARK: - Tiered report parsing (MXE-CT3 P4)

/// Per-lane counts parsed from a synthesis digest's `lane:` line.
struct ParsedTierLaneCounts: Sendable, Equatable {
    let fetched: Int
    let returned: Int
    let promotedAway: Int
    let backfilled: Int
}

/// One parsed tier section: the drawer pairs it reported, the lane counts
/// (synthesis mode only), and whether its header appeared at all — a
/// single-tier purpose report carries exactly one present section.
struct ParsedTierSection: Sendable, Equatable {
    var pairs: [ReportedProvenPair] = []
    var counts: ParsedTierLaneCounts? = nil
    var present = false
}

/// One `label=seconds` entry from the digest's `lane_seconds:` line.
struct ParsedLaneSeconds: Sendable, Equatable {
    let label: String
    let seconds: Double
}

/// Everything parsed out of a tiered report (synthesis digest or single-tier
/// purpose report).
struct ParsedTieredReport: Sendable, Equatable {
    var tier1 = ParsedTierSection()
    var tier2 = ParsedTierSection()
    var tier3 = ParsedTierSection()
    var laneSeconds: [ParsedLaneSeconds] = []
    var synthesisWallSeconds: Double? = nil

    func section(_ tier: Int) -> ParsedTierSection {
        switch tier {
        case 1: return tier1
        case 2: return tier2
        default: return tier3
        }
    }
}

/// Parses the MXE-CT3 tiered sections out of a `moot_hunt_contradictions`
/// report — either the synthesis digest appended to the legacy sweep report
/// (tier absent/"all") or a single-tier purpose report.
///
/// Line formats are pinned against the ONE shared renderer both surfaces
/// route through — RecipeTools.swift `tieredSectionLines` (:1368-1424) and
/// its Rust twin recipe_tools.rs `tiered_section_lines` (:291-388):
///   `TIER 1 — CONTRADICTION (proven)` / `TIER 2 — CONFLICT CANDIDATE` /
///   `TIER 3 — DIVERGENCE`                       (headers, unindented)
///   `  lane: fetched F, returned R, promotedAway P, backfilled B`
///   `  PROVEN <resultID> at <digest> (rule <ruleID>)` + two dense rows
///   `    <drawerUUID> · … · … · … · …`           (tier-1 pair source)
///   `  a conflicting claim exists at <digest> [restricted]` (no ids)
///   `  <a> vs <b> (<cueKind>, score S)`          (tiers 2/3)
///   `lane_seconds: label=S.SSS label=S.SSS` / `synthesis_wall_seconds: S.SSS`
///
/// Tolerant of the legacy report prefix: everything before the first tier
/// header is ignored, which also keeps the legacy `PROPOSED`/`CANDIDATE`
/// lines and the typed conflict-projection section out of this parser.
func parseTieredSections(_ text: String) -> ParsedTieredReport {
    // Header strings must match the renderer byte for byte (the em dash is
    // part of the wire contract — RecipeTools.tier1Header etc.).
    let tier1Header = "TIER 1 — CONTRADICTION (proven)"
    let tier2Header = "TIER 2 — CONFLICT CANDIDATE"
    let tier3Header = "TIER 3 — DIVERGENCE"

    var report = ParsedTieredReport()
    var currentTier: Int? = nil
    var pendingTier1IDs: [String] = []

    func closeTier1Block() {
        if pendingTier1IDs.count == 2 {
            report.tier1.pairs.append(
                ReportedProvenPair(a: pendingTier1IDs[0], b: pendingTier1IDs[1]))
        }
        pendingTier1IDs = []
    }
    func withSection(_ tier: Int, _ mutate: (inout ParsedTierSection) -> Void) {
        switch tier {
        case 1: mutate(&report.tier1)
        case 2: mutate(&report.tier2)
        default: mutate(&report.tier3)
        }
    }

    for rawLine in text.components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line == tier1Header || line == tier2Header || line == tier3Header {
            closeTier1Block()
            currentTier = line == tier1Header ? 1 : (line == tier2Header ? 2 : 3)
            withSection(currentTier!) { $0.present = true }
            continue
        }
        if line.hasPrefix("lane_seconds: ") {
            closeTier1Block()
            currentTier = nil
            for part in line.dropFirst("lane_seconds: ".count).split(separator: " ") {
                let kv = part.split(separator: "=", maxSplits: 1)
                if kv.count == 2, let s = Double(kv[1]) {
                    report.laneSeconds.append(
                        ParsedLaneSeconds(label: String(kv[0]), seconds: s))
                }
            }
            continue
        }
        if line.hasPrefix("synthesis_wall_seconds: ") {
            closeTier1Block()
            currentTier = nil
            report.synthesisWallSeconds =
                Double(line.dropFirst("synthesis_wall_seconds: ".count))
            continue
        }
        guard let tier = currentTier else { continue }
        if line.hasPrefix("lane: fetched ") {
            // "lane: fetched F, returned R, promotedAway P, backfilled B"
            let fields = line.dropFirst("lane: ".count)
                .components(separatedBy: ", ")
            var values: [String: Int] = [:]
            for field in fields {
                let parts = field.split(separator: " ")
                if parts.count == 2, let n = Int(parts[1]) {
                    values[String(parts[0])] = n
                }
            }
            if let f = values["fetched"], let r = values["returned"],
               let p = values["promotedAway"], let b = values["backfilled"] {
                withSection(tier) {
                    $0.counts = ParsedTierLaneCounts(
                        fetched: f, returned: r, promotedAway: p, backfilled: b)
                }
            }
            continue
        }
        switch tier {
        case 1:
            if line.hasPrefix("PROVEN ") {
                closeTier1Block() // a new block opens; ids follow as dense rows
            } else if line.hasPrefix("a conflicting claim exists") {
                closeTier1Block() // restricted finding: coordinate digest only, no ids
            } else if line.contains(" · ") {
                // Dense row: the drawer UUID is the first token (same
                // contract parseTypedConflictSection reads).
                if let first = line.split(separator: " ").first {
                    pendingTier1IDs.append(String(first))
                }
            }
        default:
            // Tier 2/3 finding: `<a> vs <b> (<cueKind>, score S)`.
            if let range = line.range(of: " vs ") {
                let a = String(line[..<range.lowerBound])
                let rest = String(line[range.upperBound...])
                let b = rest.components(separatedBy: " (").first ?? rest
                withSection(tier) {
                    $0.pairs.append(ReportedProvenPair(a: a, b: b))
                }
            }
        }
    }
    closeTier1Block()
    return report
}

// MARK: - Tiered scoring (MXE-CT3 P4)

/// Unordered LOWERCASED UUID sets for the planted pairs. All tiered matching
/// is case-insensitive: Swift `UUID.uuidString` is UPPERCASE while Rust's
/// `Uuid::to_string()` is lowercase (precedent c95910dff), so both sides of
/// every comparison are lowercased before matching. An unmappable pair
/// yields an empty set, which never matches.
func lowercasedPlantedSets(
    _ planted: [ContradictionPair],
    uuidByRecordID: [String: String]
) -> [Set<String>] {
    planted.map { pair in
        guard let l = uuidByRecordID[pair.leftRecordID],
              let r = uuidByRecordID[pair.rightRecordID] else { return [] }
        return [l.lowercased(), r.lowercased()]
    }
}

/// Counts planted pairs present (either drawer order, case-insensitive) in
/// a list of reported pairs — the per-tier purpose-run recall numerator.
func countDetectedPlanted(
    planted: [ContradictionPair],
    uuidByRecordID: [String: String],
    reportedPairs: [ReportedProvenPair]
) -> Int {
    let reportedSets = reportedPairs.map { Set([$0.a.lowercased(), $0.b.lowercased()]) }
    var detected = 0
    for set in lowercasedPlantedSets(planted, uuidByRecordID: uuidByRecordID)
    where !set.isEmpty {
        if reportedSets.contains(set) { detected += 1 }
    }
    return detected
}

/// Counts synthesis dedup failures: planted pairs (word-valued AND
/// divergence) appearing in MORE than one tier section of the synthesis
/// digest. The synthesis contract is exactly-once at the highest applicable
/// tier (promote-to-highest + backfill), so any pair in two sections is a
/// tier-inflation / dedup failure. Absence from all sections is undetected,
/// not inflation.
func countTierInflation(
    planted: [ContradictionPair],
    uuidByRecordID: [String: String],
    synthesis: ParsedTieredReport
) -> Int {
    let sectionSets: [[Set<String>]] = [1, 2, 3].map { tier in
        synthesis.section(tier).pairs.map { Set([$0.a.lowercased(), $0.b.lowercased()]) }
    }
    var inflated = 0
    for set in lowercasedPlantedSets(planted, uuidByRecordID: uuidByRecordID)
    where !set.isEmpty {
        let sectionsHolding = sectionSets.filter { $0.contains(set) }.count
        if sectionsHolding > 1 { inflated += 1 }
    }
    return inflated
}

/// Decoy hit counts, split by severity.
struct DecoyHitCounts: Sendable, Equatable {
    /// Marker-supersession and distinct-entity decoys flagged anywhere that
    /// counts (tier sections, legacy PROPOSED). MUST be 0.
    let hard: Int
    /// Unit-equivalent decoys flagged — the known limitation (the lexical
    /// digit cue cannot equate "90s" and "1.5min"), reported separately and
    /// never as a hard failure.
    let knownLimitation: Int
}

/// Scores the planted decoys against every tiered report from the run plus
/// the legacy sweep's reported pairs.
///
/// What counts as a decoy hit — pinned deliberately:
///   - ANY tier section (1, 2, or 3) of any tiered report — synthesis digest
///     or purpose run — containing the decoy's drawer pair.
///   - A legacy `PROPOSED` line (an auto-filed contradiction tunnel).
/// What does NOT count:
///   - Legacy `CANDIDATE` lines: the borderline feed is an adjudication
///     request to the BYOAI client, not a filed finding.
///   - Typed-section `HISTORICAL` lines: historical succession is the
///     CORRECT classification for the marker-supersession decoy shape.
func countDecoyHits(
    decoys: [DecoyPair],
    uuidByRecordID: [String: String],
    tieredReports: [ParsedTieredReport],
    legacyReported: [ReportedContradictionPair]
) -> DecoyHitCounts {
    var flaggedSets: [Set<String>] = []
    for report in tieredReports {
        for tier in 1...3 {
            flaggedSets.append(contentsOf: report.section(tier).pairs.map {
                Set([$0.a.lowercased(), $0.b.lowercased()])
            })
        }
    }
    flaggedSets.append(contentsOf: legacyReported
        .filter { $0.tier == ContradictionReportTier.proposed.rawValue }
        .map { Set([$0.a.lowercased(), $0.b.lowercased()]) })

    var hard = 0
    var knownLimitation = 0
    for decoy in decoys {
        guard let l = uuidByRecordID[decoy.leftRecordID],
              let r = uuidByRecordID[decoy.rightRecordID] else { continue }
        let set: Set<String> = [l.lowercased(), r.lowercased()]
        guard flaggedSets.contains(set) else { continue }
        if decoy.kind == DecoyPair.kindUnitEquivalent {
            knownLimitation += 1
        } else {
            hard += 1
        }
    }
    return DecoyHitCounts(hard: hard, knownLimitation: knownLimitation)
}

/// Everything the P4 tiered scoring produced: per-tier purpose-run recall,
/// decoy hits, the synthesis exactly-once check, and timing (purpose-run
/// wall clocks measured by the harness; synthesis lane/wall seconds parsed
/// from the report's own timing lines).
struct TieredScoringOutcome: Sendable {
    let tier2PlantedCount: Int
    let tier2Detected: Int
    let tier2PurposeSeconds: Double
    let tier3PlantedCount: Int
    let tier3Detected: Int
    let tier3PurposeSeconds: Double
    /// Tier-1 figures are nil unless --structured-tier ran: the typed lane
    /// has no material before fact filing, so a tier-1 purpose run without
    /// facts would score a structural 0 and label it measured.
    let tier1PlantedCount: Int?
    let tier1Detected: Int?
    let tier1PurposeSeconds: Double?
    let decoyHits: DecoyHitCounts
    let tierInflation: Int
    /// Parsed from the synthesis digest's `lane_seconds:` line.
    let laneSeconds: [ParsedLaneSeconds]
    /// Parsed from the synthesis digest's `synthesis_wall_seconds:` line.
    let synthesisWallSeconds: Double?
}

/// Ingests the whole corpus into ONE estate in chronological order, then runs
/// every query against the settled estate, then (unless skipped) runs the
/// contradiction sweep — strictly AFTER the ranking queries, because the
/// hunter records PROPOSED tunnels and the ranking measurement must not see
/// estate mutations it would not see in a ranking-only run.
func runSupersessionLane(
    corpus: SupersessionCorpus,
    config: SupersessionRunConfig
) async throws -> SupersessionLaneOutcome {
    // Reuses the LME lane's scratch-estate plumbing: the same posture,
    // the same /tmp/lme-bench-* prefix its guarded teardown contracts on.
    // EPHEMERAL posture, always. The estate's SQLCipher key is minted in the
    // serve process's memory and dies with it — no Keychain item, no on-disk
    // key, so a benchmark run cannot leave residue behind. Accumulating
    // orphaned keys is a real system-stability hazard, not just untidiness
    // ( operator ruling 2026-07-31), and a lane that provisions estates in bulk is exactly
    // where that accumulates.
    // C1: pass shape so the serve command receives --in-memory when
    // --shape ram is active. Disk shape is the default (same semantics as before).
    // Thread the bench-clock epoch from config into the endpoint. In replay
    // runs this is non-nil (derived from seed), pinning the serve process's
    // clock so temporal scores and filedAt stamps are bit-identical across runs.
    // In non-replay production lanes it is nil → wall-clock mode.
    let endpoint = try lmeEndpointConfig(
        scratchDir: config.scratchDir,
        mootBinaryPath: config.mootBinaryPath,
        posture: config.posture,
        shape: config.shape,
        benchClockEpoch: config.benchClockEpoch)
    let client = MCPClient(endpoint: endpoint)
    try await client.connect()

    // ── Ingest, chronologically ───────────────────────────────────────────
    // Sorted by event_time with the record id as tiebreak: same-instant
    // records exist by design (every chain's v0, every contradiction pair),
    // and an unstable sort would file them in an order that differs between
    // runs and between the Swift and Rust legs. Filing a chain out of order
    // would test the harness's sorting rather than the product's temporal
    // handling.
    let ordered = corpus.records.sorted {
        ($0.eventTime, $0.id) < ($1.eventTime, $1.id)
    }
    // Corpus record id → the drawer UUID the product assigned on write. The
    // contradiction sweep reports drawer UUIDs, so this map is how a reported
    // pair is attributed back to a planted pair. The batch path fills it from
    // the import receipt's id_map block; the live path fills it from each
    // write's response.
    var uuidByRecordID: [String: String] = [:]
    let seedRecords = supersessionSeedRecords(from: ordered)
    switch config.seedPath {
    case .batch:
        // Batch seeding (ruling 8D5B8053): emit schema v1 in chronological
        // order (file order IS ingestion order) and load it with ONE
        // `moot_json_import`. Zero per-record writes, zero per-item drains.
        let seedData = emitSeedJSON(
            name: "supersession-\(config.seed)", records: seedRecords)
        let seedURL = try writeSeedFile(
            seedData, in: config.scratchDir, name: "supersession-\(config.seed)")
        let imported = try await client.callTool(
            AriaV2Surface.jsonImport,
            arguments: [
                "path": .string(seedURL.path),
                // return_id_map: the reply carries a second text block holding
                // the record-id → drawer-UUID map (see seedIDMap).
                "return_id_map": .bool(true),
            ],
            format: .mootV2,
                    // Bulk tier: seeding an entire corpus in one call.
                    // This is why the LME lane raised its whole client to
                    // 1800s; the ceiling belongs to this call, not the
                    // connection.
                    deadline: MCPDeadline.bulk)
        // v2 surface: drawer count is in structuredContent.data.drawers_written.
        // Anything other than the expected count (validation failure, collision,
        // vault-off) is a hard failure — a partially seeded estate must never be scored.
        guard let written = imported.drawersWritten, written == seedRecords.count else {
            throw MCPError(description:
                "supersession: moot_json_import did not confirm \(seedRecords.count) "
                + "drawers — refusing to score an unseeded estate. Got: "
                + (imported.drawersWritten.map(String.init) ?? "(no structured data)"))
        }
        // The import receipt's id_map names a drawer for every seeded record;
        // seedIDMap throws on a short map rather than let a partial map score.
        uuidByRecordID = try seedIDMap(
            fromImportBlocks: imported.textBlocks,
            expecting: seedRecords.count,
            label: "supersession seed=\(config.seed)")
    case .live:
        // Retained slow lane for periodic equivalence re-proving: per-record
        // live capture, exactly the pre-batch protocol.
        for record in ordered {
            let written = try await client.callTool(
                AriaV2Surface.fileMemory,
                arguments: [
                    "content": JSONValue.string(record.content),
                    "subject": JSONValue.string(deterministicSubject(record.content)),
                    "location": JSONValue.string("supersession/" + record.attribute),
                    "event_time": JSONValue.string(record.eventTime),
                ],
                format: .mootV2)
            if let uuid = written.writeAssignedID {
                uuidByRecordID[record.id] = uuid
            }
        }
    }

    // Settle the encode queue and assert that it settled: querying a
    // partially-indexed estate returns real-looking but understated rankings
    // (e.g. 0.85 where a fully-encoded estate scores 1.00) with no visible
    // signal. The shared encode barrier handles both polling and the fresh-
    // estate grace window; a run whose drain did not converge fails loudly
    // rather than publishing a silently wrong number.
    let barrierOutcome = await waitForEncodeDrain(
        client: client, label: "supersession seed=\(config.seed)")
    guard barrierOutcome.converged else {
        throw MCPError(description:
            "supersession: encode drain did not converge within 300s — refusing to "
            + "query a partially-indexed estate. Re-run on an unloaded machine.")
    }

    // ISO8601 formatter for lane-capture timestamps. Shared across the query
    // loop so construction happens once per run, not once per query.
    let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    // Record the import timestamp (encode converged + UUID map built) when
    // lane capture is active. This is the reference point for clock-delta
    // correlation: if two runs' drifting lane magnitudes correlate with how
    // far apart their import timestamps are, the clock is the variable.
    let importTimestamp = config.laneCapture ? iso8601.string(from: Date()) : ""

    // Accumulates per-query lane snapshots when lane capture is active.
    var querySnapshots: [QueryLaneSnapshot] = []

    // Deterministic in-fiction `now` for dream and hunt: one day past the
    // corpus's last event, so temporal math runs on the corpus's timeline and
    // the output is a pure function of the estate, not the wall clock.
    let fictionNow: String = {
        let lastEvent = corpus.records.map(\.eventTime).max() ?? "2026-01-01T00:00:00Z"
        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        return iso.date(from: lastEvent).map {
            iso.string(from: $0.addingTimeInterval(86_400))
        } ?? lastEvent
    }()

    // MXE-CT3 P4: section size for the tiered digest and the purpose runs —
    // sized to cover every planted tiered pair (word-valued + divergence) so
    // recall is not capped by the section window, clamped to the MCP
    // boundary's 1...50 domain.
    let plantedTiedTotal = corpus.contradictions.count + corpus.divergences.count
    let purposeTopK = min(50, max(1, plantedTiedTotal))

    // One scored contradiction sweep. Factored because its position depends
    // on the mode (see below). Passes top_k so the appended synthesis digest
    // sections can hold every planted pair; the legacy report lines the
    // legacy parser reads are unaffected by top_k (it shapes only the tiered
    // digest). Also returns the parsed synthesis digest and the legacy
    // reported pairs for the P4 tiered scoring.
    func runScoredHunt() async throws -> (
        outcome: SupersessionContradictionOutcome,
        synthesis: ParsedTieredReport,
        legacyReported: [ReportedContradictionPair]
    ) {
        let huntStart = Date()
        let huntResult = try await client.callTool(
            AriaV2Surface.huntContradictions,
            arguments: [
                "now": .string(fictionNow),
                "top_k": .number(Double(purposeTopK)),
            ],
            format: .mootV2)
        let huntSeconds = Date().timeIntervalSince(huntStart)
        let huntText = huntResult.textBlocks.joined(separator: "\n")
        // "no vector index" is a hard failure for a measurement tool: a zero
        // detection rate from an unindexed estate is a plausible-looking
        // wrong number, not a result.
        guard !huntText.contains("no vector index") else {
            throw MCPError(description:
                "supersession: moot_hunt_contradictions reports no vector index "
                + "after a converged drain — the sweep cannot be scored. "
                + "Response: " + String(huntText.prefix(300)))
        }
        let legacyReported = parseHuntContradictionsReport(huntText)
        let outcome = scoreContradictionSweep(
            planted: corpus.contradictions,
            uuidByRecordID: uuidByRecordID,
            reported: legacyReported,
            huntSeconds: huntSeconds)
        return (outcome, parseTieredSections(huntText), legacyReported)
    }

    // One single-tier purpose search (read-only: nothing filed, no writes).
    // The tiered sections here carry no lane counts and no timing lines
    // (synthesis-only renderer arms), so the wall clock is measured by the
    // harness around the call — the same I/O-boundary discipline the MCP
    // layer applies to its own GLK calls.
    func runPurposeSearch(tier: Int) async throws -> (parsed: ParsedTieredReport, seconds: Double) {
        let start = Date()
        let result = try await client.callTool(
            AriaV2Surface.huntContradictions,
            arguments: [
                "now": .string(fictionNow),
                "tier": .number(Double(tier)),
                "top_k": .number(Double(purposeTopK)),
            ],
            format: .mootV2)
        let seconds = Date().timeIntervalSince(start)
        let text = result.textBlocks.joined(separator: "\n")
        // Same hard failure as the scored sweep: the lexical lanes need the
        // vector index (a tier-1 run never reports this).
        guard !text.contains("no vector index") else {
            throw MCPError(description:
                "supersession: tier \(tier) purpose search reports no vector "
                + "index after a converged drain — it cannot be scored. "
                + "Response: " + String(text.prefix(300)))
        }
        return (parseTieredSections(text), seconds)
    }

    var contradiction: SupersessionContradictionOutcome? = nil
    var synthesisParsed: ParsedTieredReport? = nil
    var legacyReportedPairs: [ReportedContradictionPair] = []

    // ── Dream (the un-starving step) ──────────────────────────────────────
    // In dream mode the SCORED HUNT RUNS FIRST: moot_dream runs its own
    // internal hunt sweep whose proposals dedup durably, so a scored hunt
    // AFTER dream would see its planted pairs as already-settled and report
    // no ids — silently undercounting detection. Hunting first captures the
    // PROPOSED ids on a virgin estate; dream's internal hunt then dedups
    // against them, which is harmless. The ranking queries thereafter run
    // against the DREAMED estate — matrix priors registered, dream-derived
    // tunnels present — which is the deployed steady state this lane exists
    // to measure. `--skip-dream` preserves the virgin-estate cell with the
    // original order (queries first, hunt last).
    if config.dreamBeforeQueries {
        // Scored hunt runs whenever ANY tiered class was planted: contradictions,
        // divergences, OR decoys. A run with --contradictions 0 --divergences 5
        // must still score the divergence class.
        if config.contradictionSweep
           && (!corpus.contradictions.isEmpty
               || !corpus.divergences.isEmpty
               || !corpus.decoys.isEmpty) {
            let scored = try await runScoredHunt()
            contradiction = scored.outcome
            synthesisParsed = scored.synthesis
            legacyReportedPairs = scored.legacyReported
        }
        let dreamResult = try await client.callTool(
            AriaV2Surface.dream,
            // Protocol v2: full-coverage association sweep rides the dream.
            arguments: ["now": .string(fictionNow), "associates": .string("all")],
            format: .mootV2,
                // Bulk tier: whole-corpus work that legitimately
                // runs for minutes. A short ceiling here aborts real work
                // rather than detecting a fault.
                deadline: MCPDeadline.bulk)
        // v2 surface: the "matrix rebuilt" text signal was removed. The
        // strongest available confirmation is meta.status == "completed", which
        // proves the dreaming cycle returned successfully. It does NOT prove a
        // matrix rebuild occurred — that confirmation is unavailable on the v2
        // surface. The guard is weaker than the v1 check; the operator should
        // be aware that matrix rebuild cannot be confirmed via the v2 surface.
        guard dreamResult.metaStatus == "completed" else {
            throw MCPError(description:
                "supersession: moot_dream did not complete "
                + "(meta.status: \(dreamResult.metaStatus ?? "nil")) — "
                + "the matrix-steering presets cannot be claimed measurable.")
        }

        // ── Settle gate (2026-08-24) ──────────────────────────────────────
        // This lane previously queried after dream WITHOUT the rest of the
        // settle contract every other lane runs (settleEstateForArtifact:
        // dream → reindex → drain; locomo adds the second drain). The
        // consequence was measured directly: replay runs drifted because the
        // distillation debt — a lane the encode barrier deliberately does
        // NOT gate on ("dreaming pays it down out-of-band",
        // barrierNonGatingLanes) — was at a different point of completion in
        // each run when the 40 queries fired ("43 dreaming job(s) pending at
        // stdio exit" in every replay log). Ranking reads dreaming-derived
        // state (distilled/dense text), so an unsettled estate returns
        // variable results from a single source. B3-01 (39f534353) fixed
        // this same class for MemBench/LMEB; this closes the replay lane.
        _ = try await client.callTool(
            AriaV2Surface.reindex,
            arguments: [:],
            format: .mootV2,
            deadline: MCPDeadline.bulk)
        let postDreamBarrier = await waitForEncodeDrain(
            client: client, label: "supersession post-dream seed=\(config.seed)")
        guard postDreamBarrier.converged else {
            throw MCPError(description:
                "supersession: post-dream encode drain did not converge — "
                + "refusing to query an unsettled estate.")
        }
        try await waitForDistillationSettle(
            client: client, label: "supersession seed=\(config.seed)")
    }

    // ── Query ─────────────────────────────────────────────────────────────
    // C5: one degeneracy-guard sampler for the entire query leg. With the
    // default `.oncePerLeg` policy the real probe (3 distinct moot_memory_search
    // calls) runs on the FIRST query only; all subsequent queries get the cached
    // verdict at zero MCP cost. The probe issues its own distinct queries, so it
    // does not interfere with the benchmark's recall measurement.
    let guardSampler = LegGuardSampler(policy: config.guardSamplingPolicy)
    var results: [SupersessionQueryResult] = []
    // Drawer UUID (lowercased) → record id, so a ranked hit is attributed
    // back to the corpus record that produced it. Both seed paths fill
    // `uuidByRecordID` (live: write responses; batch: the attribution pass),
    // and every recall-family reply row leads with the drawer UUID — so UUID
    // attribution is exact on both paths, where the previous content-prefix
    // line matching depended on the reply carrying content-derived text
    // (true for live-filed subjects, false for batch rows, which render
    // "(no subject)"). Lowercased on both sides: Swift renders UUIDs
    // uppercase, Rust lowercase (precedent c95910dff).
    let recordIDByUUID = Dictionary(
        uniqueKeysWithValues: uuidByRecordID.map { ($0.value.lowercased(), $0.key) })

    for query in corpus.queries {
        // C5: probe the degeneracy guard before issuing the real recall call.
        // With `.oncePerLeg` the real probe (3 moot_memory_search calls) runs
        // on the first iteration only; subsequent iterations get the cached
        // verdict with no MCP cost. A refused result is included in the output
        // so scorers can exclude it from published figures.
        let (guardVerdict, _) = await guardSampler.probe {
            // Issue 3 distinct probe queries using fixed short strings so the
            // guard can detect query-invariant frozen rankings. The probe does
            // NOT modify the estate — these are read-only search calls.
            var rankings: [[String]] = []
            for probe in ["time", "version", "fact"] {
                let probeResult = try? await client.callTool(
                    AriaV2Surface.memorySearch,
                    arguments: ["query": .string(probe)],
                    format: .mootV2)
                rankings.append(probeResult?.orderedIDs ?? [])
            }
            return rankings
        }
        let guardHealthy: Bool
        if case .healthy = guardVerdict {
            guardHealthy = true
        } else {
            guardHealthy = false
        }

        let start = Date()
        let verb = config.recallShape == nil ? AriaV2Surface.memorySearch : AriaV2Surface.recallShaped
        var args: [String: JSONValue] = ["query": .string(query.question)]
        if let shape = config.recallShape { args["preset"] = .string(shape) }
        // Thread explain: true when lane capture is active so RecallExplainer
        // appends per-hit score lines to the text output for parsing below.
        if config.laneCapture { args["explain"] = .bool(true) }
        let result = try await client.callTool(verb, arguments: args, format: .mootV2)
        let latency = Date().timeIntervalSince(start)

        // Capture per-hit lane scores when the flag is active. The snapshot
        // records the query's wall-clock timestamp so run-to-run time-delta
        // correlation is possible across the full query sequence.
        if config.laneCapture {
            querySnapshots.append(parseLaneCaptureLines(
                result.textBlocks, queryID: query.id,
                timestamp: iso8601.string(from: start)))
        }

        // Attribute each ranked reply UUID back to a corpus record.
        let rankedIDs: [String] = result.orderedIDs.compactMap {
            recordIDByUUID[$0.lowercased()]
        }

        let currentRank = rankedIDs.firstIndex(of: query.currentRecordID).map { $0 + 1 }
        let staleRanks = query.supersededRecordIDs.compactMap { sid in
            rankedIDs.firstIndex(of: sid).map { $0 + 1 }
        }
        // A current version that never appears cannot win, however few stale
        // versions surfaced — absence is a loss, not a bye.
        let wins: Bool = {
            guard let cr = currentRank else { return false }
            return staleRanks.allSatisfy { cr < $0 }
        }()
        results.append(SupersessionQueryResult(
            queryID: query.id,
            currentRank: currentRank,
            staleRanks: staleRanks,
            currentWins: wins,
            staleInTopK: staleRanks.filter { $0 <= config.topK }.count,
            latencySeconds: latency,
            guardHealthy: guardHealthy))
    }

    // ── Contradiction sweep, virgin-estate mode ───────────────────────────
    // Without dream, the sweep runs AFTER every ranking query so the ranking
    // measurement never sees the hunter's tunnel writes.
    // Gate: any tiered class planted (contradictions, divergences, or decoys).
    if !config.dreamBeforeQueries,
       config.contradictionSweep,
       !corpus.contradictions.isEmpty || !corpus.divergences.isEmpty || !corpus.decoys.isEmpty {
        let scored = try await runScoredHunt()
        contradiction = scored.outcome
        synthesisParsed = scored.synthesis
        legacyReportedPairs = scored.legacyReported
    }

    // ── MXE-CT3 P4: tier-2/3 purpose runs ─────────────────────────────────
    // Single-tier calls are READ-ONLY purpose searches (nothing filed, no
    // tunnel writes — RecipeTools runHuntContradictions single-tier arm), so
    // running them here — after dream in dream mode, after the ranking
    // queries in both modes — is safe: they cannot mutate the estate, so
    // neither the ranking measurement nor the scored sweep can see anything
    // it would not see in a run without them. The hunt-before-dream ordering
    // above is untouched. Gated on the scored hunt having run: the purpose
    // runs ride the same --skip-contradictions switch, and their planted
    // classes are attributed through the same UUID map.
    var tier2Purpose: (parsed: ParsedTieredReport, seconds: Double)? = nil
    var tier3Purpose: (parsed: ParsedTieredReport, seconds: Double)? = nil
    if synthesisParsed != nil {
        tier2Purpose = try await runPurposeSearch(tier: 2)
        tier3Purpose = try await runPurposeSearch(tier: 3)
    }

    // ── Structured (typed) proving tier ───────────────────────────────────
    // Runs LAST: filing KGFacts mutates the estate, and neither the ranking
    // queries nor the lexical sweep may see those writes. One fact per
    // corpus record, anchored to the record's ingest drawer via source_id —
    // the anchor is what gives the typed lane its validity instants (drawer
    // event times) and its dense-row attribution (proven-planted scoring maps
    // PROVEN source UUIDs back to planted pairs). The chains file too, on
    // purpose: same coordinate at DIFFERENT instants must resolve as
    // historical succession, never proof — that discrimination IS the
    // false-proof measurement.
    var structured: StructuredTierOutcome? = nil
    if config.structuredTier {
        let tierStart = Date()
        for record in ordered {
            guard let drawerUUID = uuidByRecordID[record.id] else { continue }
            _ = try await client.callTool(
                AriaV2Surface.fileFact,
                arguments: [
                    "subject": JSONValue.string(record.entity),
                    "predicate": JSONValue.string(record.attribute),
                    "object": JSONValue.string(record.value),
                    "source_id": JSONValue.string(drawerUUID),
                ],
                format: .mootV2)
        }
        let lensResult = try await client.callTool(
            AriaV2Surface.lensContradiction,
            arguments: [String: JSONValue](),
            format: .mootV2)
        let tierSeconds = Date().timeIntervalSince(tierStart)
        let lensText = lensResult.textBlocks.joined(separator: "\n")
        guard lensText.contains("proven: ") else {
            throw MCPError(description:
                "supersession: moot_lens_contradiction returned no typed "
                + "conflict-projection section — the structured tier cannot be "
                + "scored. Response: " + String(lensText.prefix(300)))
        }
        structured = scoreStructuredTier(
            planted: corpus.contradictions,
            uuidByRecordID: uuidByRecordID,
            parsed: parseTypedConflictSection(lensText),
            tierSeconds: tierSeconds)
    }

    // ── MXE-CT3 P4: tier-1 purpose run ────────────────────────────────────
    // Runs AFTER the fact filing above so the typed lane has material —
    // before --structured-tier files KGFacts there is nothing for tier 1 to
    // prove, and a purpose run against the factless estate would score a
    // structural 0 and label it measured. The call is UNCONDITIONAL inside
    // this branch (f0ede71f2 precedent: a coverage call gated on incidental
    // state silently skips on the alternate path) — only the two deliberate
    // switches gate it: --structured-tier (material exists) and the
    // contradiction sweep having run (the tiered scoring lane is active).
    var tier1Purpose: (parsed: ParsedTieredReport, seconds: Double)? = nil
    if config.structuredTier, synthesisParsed != nil {
        tier1Purpose = try await runPurposeSearch(tier: 1)
    }

    // ── MXE-CT3 P4: assemble the tiered scoring outcome ───────────────────
    // Per-tier recall of each tier's planted class: tier 2 ← the word-valued
    // pairs (wordExclusion cue), tier 3 ← the digit-divergence pairs
    // (valueDivergence cue), tier 1 ← the word-valued pairs proven by the
    // typed lane after fact filing (the F18/F19 structured-tier path).
    var tiered: TieredScoringOutcome? = nil
    if let synthesis = synthesisParsed,
       let t2 = tier2Purpose, let t3 = tier3Purpose {
        var tieredReports = [synthesis, t2.parsed, t3.parsed]
        if let t1 = tier1Purpose { tieredReports.append(t1.parsed) }
        let decoyHits = countDecoyHits(
            decoys: corpus.decoys,
            uuidByRecordID: uuidByRecordID,
            tieredReports: tieredReports,
            legacyReported: legacyReportedPairs)
        tiered = TieredScoringOutcome(
            tier2PlantedCount: corpus.contradictions.count,
            tier2Detected: countDetectedPlanted(
                planted: corpus.contradictions,
                uuidByRecordID: uuidByRecordID,
                reportedPairs: t2.parsed.tier2.pairs),
            tier2PurposeSeconds: t2.seconds,
            tier3PlantedCount: corpus.divergences.count,
            tier3Detected: countDetectedPlanted(
                planted: corpus.divergences,
                uuidByRecordID: uuidByRecordID,
                reportedPairs: t3.parsed.tier3.pairs),
            tier3PurposeSeconds: t3.seconds,
            tier1PlantedCount: tier1Purpose.map { _ in corpus.contradictions.count },
            tier1Detected: tier1Purpose.map {
                countDetectedPlanted(
                    planted: corpus.contradictions,
                    uuidByRecordID: uuidByRecordID,
                    reportedPairs: $0.parsed.tier1.pairs)
            },
            tier1PurposeSeconds: tier1Purpose?.seconds,
            decoyHits: decoyHits,
            tierInflation: countTierInflation(
                planted: corpus.contradictions + corpus.divergences,
                uuidByRecordID: uuidByRecordID,
                synthesis: synthesis),
            laneSeconds: synthesis.laneSeconds,
            synthesisWallSeconds: synthesis.synthesisWallSeconds)
    }

    let capturedLanes: LaneCapture? = config.laneCapture
        ? LaneCapture(importTimestamp: importTimestamp, snapshots: querySnapshots)
        : nil

    return SupersessionLaneOutcome(
        queryResults: results, contradiction: contradiction,
        structured: structured, tiered: tiered, laneCapture: capturedLanes)
}

/// Aggregate metrics for the lane.
struct SupersessionScores: Sendable {
    let queryCount: Int
    /// Fraction of chains where the current version outranked every stale one.
    /// The lane's headline: 1.0 means the store never surfaced an outdated
    /// fact above the truth.
    let currentWinRate: Double
    /// Fraction where the current version was retrieved at all.
    let currentFoundRate: Double
    /// Mean superseded versions inside the top-k window.
    let meanStaleInTopK: Double
    /// Mean rank of the current version among the queries that found it.
    let meanCurrentRank: Double
    let p50LatencySeconds: Double
}

func scoreSupersession(_ results: [SupersessionQueryResult], topK: Int) -> SupersessionScores {
    // C5: exclude queries where the guard refused (query-invariant frozen ranking).
    // A refused result carries plausible-looking scores derived from a frozen
    // backend state — including it would silently inflate the win rate.
    let healthy = results.filter(\.guardHealthy)
    let n = max(healthy.count, 1)
    let found = healthy.filter { $0.currentRank != nil }
    let ranks = found.compactMap { $0.currentRank }.map(Double.init)
    let lat = healthy.map(\.latencySeconds).sorted()
    return SupersessionScores(
        queryCount: healthy.count,
        currentWinRate: Double(healthy.filter(\.currentWins).count) / Double(n),
        currentFoundRate: Double(found.count) / Double(n),
        meanStaleInTopK: Double(healthy.map(\.staleInTopK).reduce(0, +)) / Double(n),
        meanCurrentRank: ranks.isEmpty ? 0 : ranks.reduce(0, +) / Double(ranks.count),
        p50LatencySeconds: lat.isEmpty ? 0 : lat[lat.count / 2])
}

// MARK: - Estate-mode comparison delta

/// The encrypted-minus-unencrypted difference between two SupersessionScores
/// runs, one per posture. Printed by --estate-mode both so the operator can
/// see what changes when encryption is enabled, independent of what is measured.
///
/// Positive values for rate metrics mean the encrypted run scored higher.
/// Positive values for latency mean the encrypted run was slower.
struct SupersessionEstateDelta: Sendable {
    /// Encrypted minus unencrypted: positive means encrypted performed better.
    let currentWinRateDiff: Double
    let currentFoundRateDiff: Double
    /// Positive means more stale contamination in the encrypted run.
    let meanStaleInTopKDiff: Double
    /// Positive means a higher (worse) mean rank in the encrypted run.
    let meanCurrentRankDiff: Double
    /// Latency overhead in milliseconds (encrypted minus unencrypted).
    let queryP50DiffMs: Double
    /// Relative latency overhead as a percentage of the unencrypted p50.
    /// Nil when the unencrypted p50 is zero (division undefined).
    let queryP50PercentDiff: Double?
}

/// Computes the encrypted-minus-unencrypted delta between two SupersessionScores.
/// Argument order is fixed: `unencrypted` first, `encrypted` second — the
/// result always reads as "what changed when encryption was enabled," and the
/// calling code is unambiguous about which run is which.
///
/// Pure function over two `SupersessionScores` — unit-testable without a live
/// estate.
func computeSupersessionEstateDelta(
    unencrypted: SupersessionScores,
    encrypted: SupersessionScores
) -> SupersessionEstateDelta {
    let p50Unenc = unencrypted.p50LatencySeconds * 1_000.0
    let p50Enc   = encrypted.p50LatencySeconds   * 1_000.0
    return SupersessionEstateDelta(
        currentWinRateDiff:   encrypted.currentWinRate   - unencrypted.currentWinRate,
        currentFoundRateDiff: encrypted.currentFoundRate - unencrypted.currentFoundRate,
        meanStaleInTopKDiff:  encrypted.meanStaleInTopK  - unencrypted.meanStaleInTopK,
        meanCurrentRankDiff:  encrypted.meanCurrentRank  - unencrypted.meanCurrentRank,
        queryP50DiffMs:       p50Enc - p50Unenc,
        queryP50PercentDiff:  p50Unenc > 0 ? (p50Enc - p50Unenc) / p50Unenc * 100.0 : nil)
}
