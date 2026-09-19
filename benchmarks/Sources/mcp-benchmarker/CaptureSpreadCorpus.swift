import Foundation

// CaptureSpreadCorpus.swift — deterministic corpus generator for the
// Capture-spread corpus generator and scorer input.
//
// PURPOSE
//
//   The capture-spread benchmark measures whether the estate's decayed
//   co-occurrence matrix ranks FRESH evidence above a STALE bulk cluster
//   when queried for the CURRENT value of a changing fact. The control cell
//   (burst variant, same records captured at one instant) must reproduce the
//   counts-weighting null. The spread variant gives each record its designed
//   capture date so the HLC clock — and thus the decay projection — sees the
//   real age difference.
//
// CORPUS SHAPE (per spec)
//
//   N probe topics (default 50). Each topic is a small domain fact that changes
//   over time. Per topic:
//     STALE cluster: 6–10 items captured at T0..T0+14d (early, high count).
//     FRESH cluster: 2–3 items captured at T0+56d..T0+70d (late, low count,
//       new value supersedes the old one as a plain ordinary capture — no
//       explicit retirement, so decay must win on time signal alone).
//   eventTime mirrors captureDate (no confound from event vs capture split)
//   in the v1 spread and burst variants.
//
//   M distractor topics (default 150), 2–4 items each, uniform dates T0+14d..T0+42d.
//
// TWO PROBE CLASSES
//
//   current_value:   "what is <entity>'s current <attribute>?"
//     Gold answer = fresh cluster record IDs.
//   what_was_before: "what was <entity>'s <attribute> before the change?"
//     Gold answer = stale cluster record IDs.
//   The second class is the over-decay guard: decay must not collapse stale
//   history so deeply that the what-was-before queries fail.
//
// DETERMINISM
//
//   All generation uses SplitMix64 seeded from the caller's seed. Same seed
//   = identical corpus (record IDs, content, dates, probe text, gold sets).
//   The seed is embedded in every output's identity section.
//
// TEMPORAL PROJECTION — THREE VARIANTS
//
//   The corpus generator produces one shared record set; the PROJECTION step
//   (captureSpreadSeedRecords) fills temporal fields differently per variant:
//
//   v1 spread:   captureDate = designed per-record date (O-side alive).
//                eventTime   = captureDate (T-side == O-side, no confound).
//   v1 burst:    captureDate = nil → importer uses batch wall-clock (O-side
//                collapsed). eventTime = captureDate (T-side alive).
//   v2 splitcap: captureDate = designed per-record date (O-side alive).
//                eventTime   = T0 constant for ALL records (T-side killed).
//                Scientific contract: splitcap decayed-vs-balanced difference
//                measures the O projection alone. Comparing against the v1
//                burst difference (T-side alone) completes the decomposition.

// MARK: - Vocabulary tables

// Synthetic neutral vocabulary. Real entity names and real attribute labels
// avoid any LLM-training-data leakage. All values are fabricated.

private let entityPrefixes = [
    "Alvex", "Borven", "Caltex", "Drewin", "Elquen", "Fastor",
    "Grevon", "Helmax", "Inlux", "Jorten", "Klaven", "Lorven",
    "Mextun", "Norvel", "Orvex", "Pelvon", "Qorven", "Relmax",
    "Senvex", "Torvun", "Uxlev", "Veltun", "Welvor", "Xelvon",
    "Yelmax", "Zorven",
]

private let attributeLabels = [
    "primary contact", "assigned zone", "current project", "assigned tier",
    "home region", "preferred protocol", "active role", "main classifier",
    "reference index", "dispatch group",
]

// Two pools of values per attribute slot: first half is "stale" values,
// second half is "fresh" values. Generator picks by parity of the topic index.
// This guarantees stale ≠ fresh and both are syntactically stable.
private let valuePool: [[String]] = [
    ["Alpha-7", "Bravo-3", "Charlie-9", "Delta-2", "Echo-5",
     "Foxtrot-8", "Golf-1", "Hotel-6", "India-4", "Juliet-0"],
    ["Zone-Amber", "Zone-Blue", "Zone-Cedar", "Zone-Delta", "Zone-Echo",
     "Zone-Foxtrot", "Zone-Gamma", "Zone-Hotel", "Zone-Indigo", "Zone-Juliet"],
    ["Crestfall", "Dawnbridge", "Edgepath", "Faultline", "Greystone",
     "Harbour-One", "Irongate", "Jaderun", "Keystep", "Lodestar"],
    ["Tier-I", "Tier-II", "Tier-III", "Tier-IV", "Tier-V",
     "Tier-VI", "Tier-VII", "Tier-VIII", "Tier-IX", "Tier-X"],
    ["North-A", "North-B", "South-A", "South-B", "East-A",
     "East-B", "West-A", "West-B", "Central-A", "Central-B"],
    ["Proto-One", "Proto-Two", "Proto-Three", "Proto-Four", "Proto-Five",
     "Proto-Six", "Proto-Seven", "Proto-Eight", "Proto-Nine", "Proto-Ten"],
    ["Analyst", "Coordinator", "Director", "Evaluator", "Facilitator",
     "Guide", "Handler", "Inspector", "Liaison", "Monitor"],
    ["Class-Cyan", "Class-Dusk", "Class-Ember", "Class-Fawn", "Class-Gold",
     "Class-Haze", "Class-Iris", "Class-Jade", "Class-Khaki", "Class-Lime"],
    ["Ref-0011", "Ref-0022", "Ref-0033", "Ref-0044", "Ref-0055",
     "Ref-0066", "Ref-0077", "Ref-0088", "Ref-0099", "Ref-0110"],
    ["Dispatch-A", "Dispatch-B", "Dispatch-C", "Dispatch-D", "Dispatch-E",
     "Dispatch-F", "Dispatch-G", "Dispatch-H", "Dispatch-I", "Dispatch-J"],
]

// Filler phrases injected into stale and fresh cluster items to give each
// record distinct content even when they share the same entity+attribute+value.
private let staleFillers = [
    "confirmed by internal review",
    "recorded in the audit log",
    "verified by the coordinating team",
    "noted during the quarterly check",
    "registered at the status meeting",
    "documented by the assigned analyst",
    "logged under the oversight protocol",
    "flagged in the periodic report",
    "captured in the intake summary",
    "referenced in the progress update",
]

private let freshFillers = [
    "updated after the transition",
    "revised following the handover",
    "changed in the new cycle",
    "corrected per the latest record",
    "adjusted after the review session",
]

private let distractorTemplates = [
    "%@ has tracking code %@ as of the last sync.",
    "The reference entry for %@ shows code %@ in the current listing.",
    "%@ is indexed under %@ per the maintenance record.",
    "Current registry entry: %@ → %@.",
]

// T0 = 2026-01-01T00:00:00Z. All offsets are in whole days.
// Stale window:    days 0–14  (T0..T0+2 weeks, captured early).
// Fresh window:    days 56–70 (T0+8 weeks..T0+10 weeks, captured late).
// Distractor window: days 14–42 (T0+2 weeks..T0+6 weeks, uniform).
private let t0EpochSeconds: Int = 1_767_225_600  // 2026-01-01T00:00:00Z in Unix seconds

// MARK: - Output model

/// One generated record in the corpus. Carries both the content and the
/// metadata the runner needs to build seed-file records (for both spread and
/// burst variants) and to score recall against.
struct CaptureSpreadRecord: Sendable, Codable, Equatable {
    /// Stable record id: unique within the corpus, stable across runs with
    /// the same seed.
    let id: String
    /// Verbatim content text filed into the estate.
    let content: String
    /// UTC ISO8601 capture timestamp (same shape as event_time).
    /// Used as both captureDate (spread variant) and eventTime.
    let captureDate: String
    /// Which cluster this record belongs to within its topic (or nil for
    /// distractor records).
    let clusterKind: ClusterKind
    /// Zero-based topic index (or distractor index).
    let topicIndex: Int

    enum ClusterKind: String, Sendable, Codable {
        case stale
        case fresh
        case distractor
    }
}

/// One probe topic: the entity, attribute, stale value, fresh value, and the
/// record ids in each cluster.
struct CaptureSpreadTopic: Sendable, Codable, Equatable {
    let topicIndex: Int
    let entityName: String
    let attributeLabel: String
    let staleValue: String
    let freshValue: String
    let staleRecordIDs: [String]
    let freshRecordIDs: [String]
}

/// One probe question emitted by the generator.
struct CaptureSpreadProbe: Sendable, Codable, Equatable {
    let probeID: String
    let topicIndex: Int
    /// `.currentValue` → gold = fresh record IDs.
    /// `.whatWasBefore` → gold = stale record IDs.
    let probeClass: ProbeClass
    let queryText: String
    let goldIDs: [String]

    enum ProbeClass: String, Sendable, Codable {
        case currentValue    = "current_value"
        case whatWasBefore   = "what_was_before"
    }
}

/// The complete generated corpus.
struct CaptureSpreadCorpus: Sendable, Codable {
    let seed: UInt64
    let probeTopicCount: Int
    let distractorCount: Int
    let records: [CaptureSpreadRecord]
    let topics: [CaptureSpreadTopic]
    let probes: [CaptureSpreadProbe]

    /// All record ids that are probe-topic records (stale or fresh clusters).
    var probeRecordIDs: Set<String> {
        Set(records.filter { $0.clusterKind != .distractor }.map(\.id))
    }
}

// MARK: - Generator

/// Generates a deterministic capture-spread corpus from `seed`.
///
/// - Parameters:
///   - seed: Controls all randomness. Same seed = identical output.
///   - probeTopicCount: Number of probe topics (default 50 per spec).
///   - distractorCount: Number of distractor topics (default 150 per spec).
/// - Returns: A fully-resolved `CaptureSpreadCorpus`.
func generateCaptureSpreadCorpus(
    seed: UInt64,
    probeTopicCount: Int = 50,
    distractorCount: Int = 150
) -> CaptureSpreadCorpus {
    var rng = SplitMix64(seed: seed)

    var records: [CaptureSpreadRecord] = []
    var topics: [CaptureSpreadTopic] = []
    var probes: [CaptureSpreadProbe] = []

    // --- Probe topics ---
    for topicIdx in 0 ..< probeTopicCount {
        let entityIdx = rng.upTo(entityPrefixes.count)
        let entityName = "\(entityPrefixes[entityIdx])-\(topicIdx)"

        let attrIdx = rng.upTo(attributeLabels.count)
        let attributeLabel = attributeLabels[attrIdx]

        let pool = valuePool[attrIdx % valuePool.count]
        // First five entries of the pool are "stale" values, last five "fresh".
        // Pick the stale value from the first half and fresh from the second,
        // with per-topic offsets so they differ across topics.
        let stalePoolIdx = rng.upTo(pool.count / 2)
        let freshPoolIdx = (pool.count / 2) + rng.upTo(pool.count / 2)
        let staleValue = pool[stalePoolIdx]
        let freshValue = pool[freshPoolIdx]

        // STALE cluster: 6–10 items captured at T0 + day[0..14].
        let staleCount = 6 + rng.upTo(5)  // 6, 7, 8, 9, or 10
        var staleIDs: [String] = []
        for itemIdx in 0 ..< staleCount {
            let dayOffset = rng.upTo(15)  // days 0..14
            let secondOffset = dayOffset * 86400 + rng.upTo(3600)
            let captureDate = iso8601UTC(epochSeconds: t0EpochSeconds + secondOffset)
            let filler = staleFillers[rng.upTo(staleFillers.count)]
            let content =
                "\(entityName)'s \(attributeLabel) is \(staleValue). \(filler)."
            let id = "cs-s-\(topicIdx)-\(itemIdx)"
            records.append(CaptureSpreadRecord(
                id: id,
                content: content,
                captureDate: captureDate,
                clusterKind: .stale,
                topicIndex: topicIdx))
            staleIDs.append(id)
        }

        // FRESH cluster: 2–3 items captured at T0 + day[56..70].
        // The fresh value supersedes the stale value as an ordinary capture —
        // no explicit retirement (decay must win on time signal alone).
        let freshCount = 2 + rng.upTo(2)  // 2 or 3
        var freshIDs: [String] = []
        for itemIdx in 0 ..< freshCount {
            let dayOffset = 56 + rng.upTo(15)  // days 56..70
            let secondOffset = dayOffset * 86400 + rng.upTo(3600)
            let captureDate = iso8601UTC(epochSeconds: t0EpochSeconds + secondOffset)
            let filler = freshFillers[rng.upTo(freshFillers.count)]
            let content =
                "\(entityName)'s \(attributeLabel) is now \(freshValue). \(filler)."
            let id = "cs-f-\(topicIdx)-\(itemIdx)"
            records.append(CaptureSpreadRecord(
                id: id,
                content: content,
                captureDate: captureDate,
                clusterKind: .fresh,
                topicIndex: topicIdx))
            freshIDs.append(id)
        }

        topics.append(CaptureSpreadTopic(
            topicIndex: topicIdx,
            entityName: entityName,
            attributeLabel: attributeLabel,
            staleValue: staleValue,
            freshValue: freshValue,
            staleRecordIDs: staleIDs,
            freshRecordIDs: freshIDs))

        // Probe class 1: current_value — gold = fresh IDs.
        probes.append(CaptureSpreadProbe(
            probeID: "probe-cv-\(topicIdx)",
            topicIndex: topicIdx,
            probeClass: .currentValue,
            queryText: "What is \(entityName)'s current \(attributeLabel)?",
            goldIDs: freshIDs))

        // Probe class 2: what_was_before — gold = stale IDs.
        probes.append(CaptureSpreadProbe(
            probeID: "probe-wb-\(topicIdx)",
            topicIndex: topicIdx,
            probeClass: .whatWasBefore,
            queryText:
                "What was \(entityName)'s \(attributeLabel) before the change?",
            goldIDs: staleIDs))
    }

    // --- Distractor topics ---
    for distractorIdx in 0 ..< distractorCount {
        let entityIdx = rng.upTo(entityPrefixes.count)
        let entityName = "\(entityPrefixes[entityIdx])-d\(distractorIdx)"

        let templateIdx = rng.upTo(distractorTemplates.count)
        let template = distractorTemplates[templateIdx]

        let pool = valuePool[rng.upTo(valuePool.count)]
        let codeValue = pool[rng.upTo(pool.count)]

        let itemCount = 2 + rng.upTo(3)  // 2, 3, or 4
        for itemIdx in 0 ..< itemCount {
            // Uniform capture window: T0+14d..T0+42d.
            let dayOffset = 14 + rng.upTo(29)  // days 14..42
            let secondOffset = dayOffset * 86400 + rng.upTo(3600)
            let captureDate = iso8601UTC(epochSeconds: t0EpochSeconds + secondOffset)
            let content = String(format: template, entityName, codeValue)
            let id = "cs-d-\(distractorIdx)-\(itemIdx)"
            records.append(CaptureSpreadRecord(
                id: id,
                content: content,
                captureDate: captureDate,
                clusterKind: .distractor,
                topicIndex: distractorIdx))
        }
    }

    return CaptureSpreadCorpus(
        seed: seed,
        probeTopicCount: probeTopicCount,
        distractorCount: distractorCount,
        records: records,
        topics: topics,
        probes: probes)
}

// MARK: - Seed-record projection

/// Projects corpus records onto `SeedFileRecord` for emission via
/// `emitSeedJSON`. The variant controls which temporal fields are populated:
///
///   spread:   captureDate = record.captureDate (distinct historical HLC values);
///             eventTime   = captureDate (v1 no-confound: T-side == O-side).
///   burst:    captureDate = nil (importer uses batch wall-clock for all records,
///             the null-control cell); eventTime = captureDate (T-side alive).
///   splitcap: captureDate = record.captureDate (O-side alive);
///             eventTime   = T0 constant ("2026-01-01T00:00:00Z") for all records
///             (T-side killed). Comparing splitcap decayed-vs-balanced isolates
///             the O projection alone.
///
/// - Parameters:
///   - corpus: The generated corpus.
///   - variant: Which temporal projection to apply (spread, burst, or splitcap).
/// - Returns: `[SeedFileRecord]` in corpus order (file order is ingestion order).
func captureSpreadSeedRecords(
    from corpus: CaptureSpreadCorpus,
    variant: CaptureSpreadVariant
) -> [SeedFileRecord] {
    // T0 string used by the splitcap variant to kill the T-side signal.
    let t0String = iso8601UTC(epochSeconds: t0EpochSeconds)
    return corpus.records.map { record in
        // eventTime and captureDate are set according to the variant:
        let eventTime: String
        let captureDate: String?
        switch variant {
        case .spread:
            // v1: both sides carry the designed per-record date. No confound.
            eventTime = record.captureDate
            captureDate = record.captureDate
        case .burst:
            // v1: O-side collapsed (nil → batch wall-clock); T-side alive.
            eventTime = record.captureDate
            captureDate = nil
        case .splitcap:
            // v2: O-side alive (designed captureDate); T-side killed (T0 constant).
            eventTime = t0String
            captureDate = record.captureDate
        }
        // Room is TOPIC-keyed, never cluster-keyed: stale and fresh records
        // about the same entity share a room (where a real estate files
        // them), and distractor topics take offset indexes. Encoding
        // stale/fresh in the room would write the measured signal into
        // retrievable metadata.
        let roomIndex = record.clusterKind == .distractor
            ? record.topicIndex + 1000 : record.topicIndex
        return SeedFileRecord(
            id: record.id,
            content: record.content,
            eventTime: eventTime,
            room: "capturespread/topic-\(roomIndex)",
            captureDate: captureDate)
    }
}

// MARK: - Output file helpers

/// Emits the corpus as two JSON files: the seed-import file (records in
/// corpus order for the requested variant) and the probe file (probes +
/// topic metadata for scoring). Returns the paths of both files.
///
/// - Parameters:
///   - corpus: The generated corpus.
///   - variant: Which temporal projection to apply (spread, burst, or splitcap).
///   - outDir: Destination directory (must exist).
///   - baseName: Filename stem; files are `<baseName>.seed.json` and
///     `<baseName>.probes.json`.
/// - Returns: (seedURL, probesURL)
func writeCaptureSpreadFiles(
    corpus: CaptureSpreadCorpus,
    variant: CaptureSpreadVariant,
    outDir: URL,
    baseName: String
) throws -> (seed: URL, probes: URL) {
    let seedRecords = captureSpreadSeedRecords(from: corpus, variant: variant)
    let seedData = emitSeedJSON(
        name: baseName,
        records: seedRecords)
    let seedURL = outDir.appendingPathComponent("\(baseName).seed.json")
    try seedData.write(to: seedURL, options: .atomic)

    let probeData = try JSONEncoder().encode(corpus)
    let probesURL = outDir.appendingPathComponent("\(baseName).probes.json")
    try probeData.write(to: probesURL, options: .atomic)

    return (seedURL, probesURL)
}

// MARK: - ISO8601 helper

/// Formats a Unix epoch second offset as a UTC ISO8601 string matching
/// the schema v1 "YYYY-MM-DDTHH:MM:SSZ" shape.
private func iso8601UTC(epochSeconds: Int) -> String {
    // Decompose into calendar components.
    var rem = epochSeconds
    let s = rem % 60; rem /= 60
    let m = rem % 60; rem /= 60
    let h = rem % 24; rem /= 24
    // `rem` is days since 1970-01-01. Walk the Gregorian calendar from there.
    func isLeap(_ y: Int) -> Bool { y % 4 == 0 && (y % 100 != 0 || y % 400 == 0) }
    let daysInMonth = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    var year = 1970; var month = 1; var day = 1 + rem
    while true {
        let dim = month == 2 && isLeap(year) ? 29 : daysInMonth[month]
        if day <= dim { break }
        day -= dim; month += 1
        if month > 12 { month = 1; year += 1 }
    }
    return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", year, month, day, h, m, s)
}

// MARK: - CLI handler (capturespread-corpus subcommand)

/// Runs the `capturespread-corpus` subcommand: generates a corpus and writes
/// the seed and probe files.
///
/// Options:
///   --seed <uint64>                Generator seed (default 42).
///   --probes <int>                 Number of probe topics (default 50).
///   --distractors <int>            Number of distractor topics (default 150).
///   --variant spread|burst|splitcap  Which seed file to emit (default spread).
///   --out <dir>                    Output directory (default: current working directory).
func runCaptureSpreadCorpus(_ args: [String]) throws {
    var seed: UInt64 = 42
    var probes = 50
    var distractors = 150
    var variantStr = "spread"
    var outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--seed":
            i += 1
            guard i < args.count, let v = UInt64(args[i]) else {
                throw MCPError(description: "--seed requires a uint64 value")
            }
            seed = v
        case "--probes":
            i += 1
            guard i < args.count, let v = Int(args[i]), v > 0 else {
                throw MCPError(description: "--probes requires a positive integer")
            }
            probes = v
        case "--distractors":
            i += 1
            guard i < args.count, let v = Int(args[i]), v >= 0 else {
                throw MCPError(description: "--distractors requires a non-negative integer")
            }
            distractors = v
        case "--variant":
            i += 1
            guard i < args.count,
                  args[i] == "spread" || args[i] == "burst" || args[i] == "splitcap" else {
                throw MCPError(description: "--variant must be 'spread', 'burst', or 'splitcap'")
            }
            variantStr = args[i]
        case "--out":
            i += 1
            guard i < args.count else {
                throw MCPError(description: "--out requires a directory path")
            }
            outDir = URL(fileURLWithPath: args[i])
        default:
            throw MCPError(description: "capturespread-corpus: unknown option '\(args[i])'")
        }
        i += 1
    }

    let corpus = generateCaptureSpreadCorpus(
        seed: seed,
        probeTopicCount: probes,
        distractorCount: distractors)

    // Parse the variant string to the typed enum for the projection call.
    let variant: CaptureSpreadVariant
    switch variantStr {
    case "spread":   variant = .spread
    case "burst":    variant = .burst
    case "splitcap": variant = .splitcap
    default:
        throw MCPError(description: "--variant must be 'spread', 'burst', or 'splitcap'")
    }

    let baseName = "capturespread-seed\(seed)-\(variantStr)"

    try FileManager.default.createDirectory(
        at: outDir, withIntermediateDirectories: true)

    let (seedURL, probesURL) = try writeCaptureSpreadFiles(
        corpus: corpus,
        variant: variant,
        outDir: outDir,
        baseName: baseName)

    let totalRecords = corpus.records.count
    let probeCount = corpus.probes.count
    print("capturespread-corpus: wrote \(totalRecords) records "
        + "(\(probes) probe topics × stale+fresh clusters + "
        + "\(distractors) distractor topics), "
        + "\(probeCount) probes (\(probes) current_value + \(probes) what_was_before)")
    print("  seed file:  \(seedURL.path)")
    print("  probe file: \(probesURL.path)")
}
