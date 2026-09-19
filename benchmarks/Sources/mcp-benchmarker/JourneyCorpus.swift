import Foundation

// JourneyCorpus.swift — deterministic corpus generators for the two journey-
// measurement lanes.
//
// WHY JOURNEY LANES EXIST. Public benchmarks provision a fresh estate per
// question and ask binary retrieval questions: was the right item in the top k?
// That design cannot measure two retrieval failure modes that appear only when
// a memory system is used across multi-step agent journeys:
//
//   PRECISE-MISS: the correct fact is in the store, but a near-duplicate DECOY
//     that repeats the query's distinctive tokens more densely outranks it.
//     A BM25-only system fails this reliably; a system with date-aware scoring
//     or dense vector recall may pass it. The lane measures the gap.
//
//   VAGUE-NARROW: the agent must resolve a vague, open-ended query ("which
//     entry addresses X?") against a cluster of on-topic siblings, only one of
//     which carries the specific answer detail. Keyword overlap alone cannot
//     distinguish the true member from the siblings.
//
// Both corpora are pure functions of their seed — same seed, same bytes. The
// conformance gate enforces this across the Swift and Rust legs.
//
// FAIRNESS RULE — load-bearing, do not relax it. Every scored behaviour must
// be achievable in principle by any competent retrieval system. Nothing here
// requires a moot-specific feature. A benchmark only our product can pass is
// marketing; a benchmark that is simply harder, and that we happen to be good
// at, is measurement.

// MARK: - PRECISE-MISS corpus model

/// A single record in a PRECISE-MISS corpus — either the target, the decoy,
/// or a filler for a given scenario.
struct PreciseMissRecord: Codable, Sendable, Equatable {
    /// Stable identifier. Format: "pm-<scenarioIndex>-t" (target),
    /// "pm-<scenarioIndex>-d" (decoy), "pm-<scenarioIndex>-f<n>" (filler).
    let id: String
    /// The text content that would be filed into the memory system.
    let content: String
    /// ISO8601 instant (UTC). All four records in a scenario share the same
    /// instant — eventTime is not the scored dimension here.
    let eventTime: String
}

/// Ground truth and corpus identifiers for one PRECISE-MISS scenario.
struct PreciseMissScenario: Codable, Sendable, Equatable {
    let id: String
    /// The query the agent would issue.
    let question: String
    /// The record that carries the specific answer the question asks for.
    let targetRecordID: String
    /// The near-duplicate record engineered to outrank the target on lexical
    /// overlap alone. It densely repeats the query's distinctive tokens but
    /// deliberately omits the answer detail.
    ///
    /// WHY A DECOY. A recall system that ranks by bag-of-words similarity
    /// will surface the decoy over the target because the decoy accumulates
    /// more token-overlap weight. The target mentions the query tokens once
    /// each, then states the answer. The decoy repeats the tokens many times,
    /// filling its content with them, but never states the answer. Measuring
    /// how often the target outranks the decoy tests whether the system goes
    /// beyond pure frequency ranking to semantic or structural precision.
    let decoyRecordID: String
    /// Filler records: on-topic for the scenario's domain but carry no answer.
    /// Their presence prevents the scenario's true target from being trivially
    /// findable by topic alone (without the query).
    let fillerRecordIDs: [String]
}

/// The complete PRECISE-MISS corpus: records to ingest and scenarios to score.
struct PreciseMissCorpus: Codable, Sendable, Equatable {
    let seed: UInt64
    let scenarioCount: Int
    let records: [PreciseMissRecord]
    let scenarios: [PreciseMissScenario]
}

// MARK: - VAGUE-NARROW corpus model

/// A single member record in a VAGUE-NARROW cluster.
struct VagueNarrowRecord: Codable, Sendable, Equatable {
    let id: String
    let content: String
    let eventTime: String
}

/// One cluster of on-topic member records, exactly one of which carries the
/// answer for the cluster's vague query.
struct VagueNarrowCluster: Codable, Sendable, Equatable {
    let id: String
    /// A deliberately open-ended query that does not name the true member.
    /// The agent (or scorer) must search the cluster and identify which member
    /// has the specific answer detail.
    let question: String
    /// All member record ids in this cluster.
    let memberIDs: [String]
    /// The one member that carries the answer. The other members are plausible
    /// on-topic siblings that look semantically similar but lack the specific
    /// fact the question targets.
    let trueID: String
}

/// The complete VAGUE-NARROW corpus.
struct VagueNarrowCorpus: Codable, Sendable, Equatable {
    let seed: UInt64
    let clusterCount: Int
    let membersPerCluster: Int
    let records: [VagueNarrowRecord]
    let clusters: [VagueNarrowCluster]
}

// MARK: - Bundled corpus (for conformance vectors + CLI dump)

/// Both sub-corpora bundled into one serialisable unit, so the conformance
/// vector file and `--dump-seed` path carry everything in one file.
struct JourneyCorpus: Codable, Sendable, Equatable {
    let seed: UInt64
    let preciseMiss: PreciseMissCorpus
    let vagueNarrow: VagueNarrowCorpus
}

// MARK: - Deterministic generation

/// Generates both journey sub-corpora from `seed`. Same seed → same bytes on
/// every run and on both the Swift and Rust legs (conformance-gated).
///
/// - Parameters:
///   - seed: Deterministic seed. Appears in filenames and report headers.
///   - preciseMissCount: Number of PRECISE-MISS scenarios to generate.
///   - clusterCount: Number of VAGUE-NARROW clusters.
///   - membersPerCluster: Members per VAGUE-NARROW cluster (≥2).
func generateJourneyCorpus(
    seed: UInt64,
    preciseMissCount: Int = 20,
    clusterCount: Int = 10,
    membersPerCluster: Int = 6
) -> JourneyCorpus {
    var rng = SplitMix64(seed: seed)

    // Fixed epoch — never Date() — so the corpus never changes with the wall
    // clock. Same epoch as SupersessionCorpus for consistency.
    let epoch: Double = 1_580_000_000.0  // 2020-01-26T00:53:20Z
    let iso = ISO8601DateFormatter()
    iso.timeZone = TimeZone(secondsFromGMT: 0)

    let pm = generatePreciseMissCorpus(
        seed: seed, count: preciseMissCount, rng: &rng,
        epoch: epoch, iso: iso)
    let vn = generateVagueNarrowCorpus(
        seed: seed, clusterCount: clusterCount, membersPerCluster: membersPerCluster,
        rng: &rng, epoch: epoch, scenarioOffset: preciseMissCount, iso: iso)

    return JourneyCorpus(seed: seed, preciseMiss: pm, vagueNarrow: vn)
}

// MARK: - PRECISE-MISS generation internals

// Topic definitions for PRECISE-MISS scenarios. Four topic types cycle across
// scenarios (matching the SupersessionCorpus pattern of four attribute types).
// Each topic specifies:
//   - attr: stable internal name used for content selection.
//   - names: pool of entity names drawn with the shared RNG.
//   - answers: pool of specific answer values drawn with the shared RNG.
//   - questionForm: printf-style template (%@ = entity name).
//
// WHY FOUR TOPICS. Four topics means the four attributes of a realistic
// memory workload (observations, experiments, sensor readings, route checks)
// rotate across every four consecutive scenarios, preventing systematic
// topic-level effects from dominating the aggregate score.
private let preciseMissTopics: [(attr: String, names: [String], answers: [String], questionForm: String)] = [
    ("count-survey",
     ["Harrow", "Pelton", "Ridgemark", "Calwen", "Forley", "Dunmore"],
     ["12", "38", "7", "54", "21", "9"],
     "What did the %@ count survey record for the north zone?"),
    ("batch-test",
     ["B14", "B7", "B22", "B5", "B31", "B9"],
     ["74 units", "120 units", "31 units", "88 units", "215 units", "17 units"],
     "What output did batch %@ produce in the lab test?"),
    ("station-log",
     ["S-3", "S-7", "S-11", "S-4", "S-9", "S-6"],
     ["412 kPa", "1.8 m/s", "19 C", "220 V", "64 pct", "38 kPa"],
     "What reading did station %@ log in the pressure report?"),
    ("route-check",
     ["Mallow", "Tenby", "Corvin", "Aldren", "Fenwick", "Dray"],
     ["14.2 km", "8.7 km", "23.1 km", "5.6 km", "19.4 km", "11.3 km"],
     "What distance did the %@ route check record for the north segment?"),
]

private func generatePreciseMissCorpus(
    seed: UInt64, count: Int,
    rng: inout SplitMix64,
    epoch: Double,
    iso: ISO8601DateFormatter
) -> PreciseMissCorpus {
    var records: [PreciseMissRecord] = []
    var scenarios: [PreciseMissScenario] = []

    for i in 0..<count {
        let topicIdx = i % preciseMissTopics.count
        let (attr, names, answers, questionForm) = preciseMissTopics[topicIdx]

        let name = names[Int(rng.next() % UInt64(names.count))]
        let answer = answers[Int(rng.next() % UInt64(answers.count))]

        // All four records in a scenario share one timestamp. Scenarios are
        // spaced one week apart on the fixed epoch timeline.
        let when = epoch + Double(i) * 7.0 * 86_400.0
        let timestamp = iso.string(from: Date(timeIntervalSince1970: when))

        let targetID = "pm-\(i)-t"
        let decoyID = "pm-\(i)-d"
        let filler0ID = "pm-\(i)-f0"
        let filler1ID = "pm-\(i)-f1"

        records.append(PreciseMissRecord(id: targetID,
            content: preciseMissTargetContent(attr: attr, name: name, answer: answer),
            eventTime: timestamp))
        records.append(PreciseMissRecord(id: decoyID,
            content: preciseMissDecoyContent(attr: attr, name: name),
            eventTime: timestamp))
        records.append(PreciseMissRecord(id: filler0ID,
            content: preciseMissFillerContent(attr: attr, name: name, index: 0),
            eventTime: timestamp))
        records.append(PreciseMissRecord(id: filler1ID,
            content: preciseMissFillerContent(attr: attr, name: name, index: 1),
            eventTime: timestamp))

        scenarios.append(PreciseMissScenario(
            id: "pm-q-\(i)",
            question: String(format: questionForm, name),
            targetRecordID: targetID,
            decoyRecordID: decoyID,
            fillerRecordIDs: [filler0ID, filler1ID]))
    }

    return PreciseMissCorpus(seed: seed, scenarioCount: count,
                             records: records, scenarios: scenarios)
}

/// The target carries the specific answer detail the question asks for.
/// It mentions the query tokens exactly once each, then states the answer.
/// This gives it lower lexical frequency for the query's distinctive tokens
/// than the decoy, which is the point: frequency is insufficient for recall
/// quality.
private func preciseMissTargetContent(attr: String, name: String, answer: String) -> String {
    switch attr {
    case "count-survey":
        return "\(name) count survey north zone result: \(answer). Field crew verified the total."
    case "batch-test":
        return "Batch \(name) lab test output: \(answer). Technician sign-off on file."
    case "station-log":
        return "Station \(name) pressure report: reading was \(answer) at 0800."
    case "route-check":
        return "\(name) route check north segment distance: \(answer). Inspector sign-off complete."
    default:
        return "\(name) \(attr) result: \(answer)."
    }
}

/// The decoy repeats the query's distinctive tokens many times without
/// ever stating the answer. This makes it superficially more relevant to
/// the query on a bag-of-words or cosine-similarity measure — the token
/// overlap is higher. A system that ranks purely by lexical frequency will
/// surface the decoy first, which is the failure mode being measured.
private func preciseMissDecoyContent(attr: String, name: String) -> String {
    switch attr {
    case "count-survey":
        return "The \(name) count survey examined north zone data. \(name) count survey north zone readings were logged. Count survey \(name) north zone figures are on record."
    case "batch-test":
        return "Batch \(name) lab test batch \(name) data was processed. The lab test for batch \(name) examined lab test batch parameters. Batch \(name) lab test logs are on file."
    case "station-log":
        return "Station \(name) pressure report readings were taken at station \(name). The \(name) pressure report station \(name) log was filed. Pressure report station \(name) data is archived."
    case "route-check":
        return "The \(name) route check north segment records were filed. \(name) route check north segment measurements are on file. Route check \(name) north segment data was recorded."
    default:
        return "\(name) \(attr) \(name) data was recorded. \(name) \(attr) activity \(name)."
    }
}

/// Filler records are on-topic for the domain but carry no answer to the
/// scenario's question. Their purpose is to prevent the target from being
/// identifiable by topic alone — the retrieval system must actually match
/// on the query's specific details to rank the target over the fillers.
private func preciseMissFillerContent(attr: String, name: String, index: Int) -> String {
    switch (attr, index) {
    case ("count-survey", 0): return "\(name) count survey equipment was staged before deployment."
    case ("count-survey", _): return "North zone observations were noted in \(name) count survey records."
    case ("batch-test", 0):   return "Batch \(name) materials were staged before the lab test."
    case ("batch-test", _):   return "The lab test protocol was verified for batch \(name)."
    case ("station-log", 0):  return "Station \(name) equipment was inspected last quarter."
    case ("station-log", _):  return "The pressure team reviewed station \(name) logs."
    case ("route-check", 0):  return "\(name) route check team departed at first light."
    case ("route-check", _):  return "North segment conditions were noted in the \(name) route check."
    default:                   return "\(name) \(attr) general notes are on file."
    }
}

// MARK: - VAGUE-NARROW generation internals

// Topic definitions for VAGUE-NARROW clusters. Four cluster types cycle.
// Each topic specifies:
//   - attr: stable internal name.
//   - areas: pool of area/context names drawn with the shared RNG.
//   - questionForm: template (%@ = area name). The question is vague —
//     it asks which member addresses something, without naming the true one.
private let vagueNarrowTopics: [(attr: String, areas: [String], questionForm: String)] = [
    ("protocol-set",
     ["Harrow", "Pelton", "Ridgemark", "Calwen", "Forley", "Dunmore"],
     "Which entry in the %@ protocol set handles the critical path procedure?"),
    ("equipment-list",
     ["Lab-A", "Lab-B", "Lab-C", "Lab-D", "Lab-E", "Lab-F"],
     "Which item on the %@ equipment list measures peak load?"),
    ("log-book",
     ["Mallow", "Tenby", "Corvin", "Aldren", "Fenwick", "Dray"],
     "Which entry in the %@ log book records the initial calibration?"),
    ("reference-set",
     ["Atlas", "Cairn", "Dunbar", "Elwick", "Folton", "Greyson"],
     "Which document in the %@ reference set confirms the operating limit?"),
]

private func generateVagueNarrowCorpus(
    seed: UInt64, clusterCount: Int, membersPerCluster: Int,
    rng: inout SplitMix64,
    epoch: Double, scenarioOffset: Int,
    iso: ISO8601DateFormatter
) -> VagueNarrowCorpus {
    var records: [VagueNarrowRecord] = []
    var clusters: [VagueNarrowCluster] = []

    for i in 0..<clusterCount {
        let topicIdx = i % vagueNarrowTopics.count
        let (attr, areas, questionForm) = vagueNarrowTopics[topicIdx]

        let area = areas[Int(rng.next() % UInt64(areas.count))]
        // True member index: which of the membersPerCluster members carries the answer.
        let trueIdx = Int(rng.next() % UInt64(membersPerCluster))

        // Clusters placed after the PRECISE-MISS scenarios on the timeline,
        // one week apart. Members within a cluster share the cluster's timestamp.
        let when = epoch + Double(scenarioOffset + i) * 7.0 * 86_400.0
        let timestamp = iso.string(from: Date(timeIntervalSince1970: when))

        var memberIDs: [String] = []
        for j in 0..<membersPerCluster {
            let memberID = "vn-\(i)-\(j)"
            memberIDs.append(memberID)
            let content = j == trueIdx
                ? vagueNarrowTrueContent(attr: attr, area: area, memberIndex: j)
                : vagueNarrowSiblingContent(attr: attr, area: area, memberIndex: j)
            records.append(VagueNarrowRecord(id: memberID, content: content, eventTime: timestamp))
        }

        clusters.append(VagueNarrowCluster(
            id: "vn-q-\(i)",
            question: String(format: questionForm, area),
            memberIDs: memberIDs,
            trueID: "vn-\(i)-\(trueIdx)"))
    }

    return VagueNarrowCorpus(seed: seed, clusterCount: clusterCount,
                             membersPerCluster: membersPerCluster,
                             records: records, clusters: clusters)
}

/// The true member carries the specific answer detail for the cluster's vague
/// query — a fact (procedure step, measurement range, calibration reference,
/// or operating limit) that the question asks about.
private func vagueNarrowTrueContent(attr: String, area: String, memberIndex: Int) -> String {
    switch attr {
    case "protocol-set":
        return "\(area) protocol set entry \(memberIndex): critical path procedure requires 48-hour hold and dual sign-off. Verified effective."
    case "equipment-list":
        return "\(area) equipment list item \(memberIndex): peak load meter, calibrated range 0-500 N. In service."
    case "log-book":
        return "\(area) log book entry \(memberIndex): initial calibration completed, reference value 1.00. Accepted."
    case "reference-set":
        return "\(area) reference set document \(memberIndex): operating limit is 85 C. Confirmed."
    default:
        return "\(area) \(attr) entry \(memberIndex): answer detail confirmed."
    }
}

/// Sibling members are plausible on-topic entries — same domain, same format,
/// but they carry no answer to the cluster's specific question. Their presence
/// tests whether the recall system can distinguish answer-bearing content from
/// semantically similar but non-answering content.
private func vagueNarrowSiblingContent(attr: String, area: String, memberIndex: Int) -> String {
    switch attr {
    case "protocol-set":
        return "\(area) protocol set entry \(memberIndex): general administration procedures. Standard reference."
    case "equipment-list":
        return "\(area) equipment list item \(memberIndex): general monitoring equipment. Routine maintenance."
    case "log-book":
        return "\(area) log book entry \(memberIndex): routine check, no anomalies noted. Closed."
    case "reference-set":
        return "\(area) reference set document \(memberIndex): background reference material. For information only."
    default:
        return "\(area) \(attr) entry \(memberIndex): general information on file."
    }
}
