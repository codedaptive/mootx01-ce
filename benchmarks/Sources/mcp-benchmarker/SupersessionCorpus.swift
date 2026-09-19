import Foundation

// SupersessionCorpus.swift — a temporally-phased corpus for the supersession
// and contradiction lanes.
//
// WHY THIS EXISTS. Every public memory benchmark (LongMemEval, LoCoMo, LMEB)
// scores one question: was the right item retrieved. None of them scores the
// question a memory system actually faces once it has been running for a
// while: when the store holds three versions of the same fact, does the
// CURRENT one win and do the SUPERSEDED ones lose?
//
// That gap is structural rather than accidental. Those benchmarks provision a
// fresh estate per question, so there is no history for a temporal prior to be
// computed from — measured directly: six shaped-recall presets that steer
// matrix-prior columns returned byte-identical rankings on LongMemEval,
// because on a fresh estate those columns are all 0.0 by contract
// (GeniusLocusKit.swift:152-154). A benchmark that never accumulates history
// cannot see a capability that only exists once history accumulates.
//
// So this corpus is built the other way round: ONE persistent estate, facts
// ingested in chronological order with real `event_time` values, and queries
// asked only after the whole timeline is in place.
//
// FAIRNESS RULE — load-bearing, do not relax it. Every scored behaviour here
// must be achievable in principle by any competent BM25 + vector system that
// tracks recency. Nothing is scored that requires a moot-specific feature to
// pass. A benchmark only our product can pass is marketing; a benchmark that
// is simply harder, and that we happen to be good at, is measurement. If a
// future tier cannot be passed by any well-built system of that class, it
// does not belong in this file.

// MARK: - Corpus model

/// One assertion about an entity's attribute at a point in time.
struct SupersessionRecord: Codable, Sendable, Equatable {
    let id: String
    /// Subject the claim is about ("Sarah Chen").
    let entity: String
    /// Attribute being asserted ("employer").
    let attribute: String
    /// The asserted value at this point in the timeline ("Acme Robotics").
    let value: String
    /// Natural-language rendering — what actually gets filed.
    let content: String
    /// ISO8601 instant this claim was made. Ingestion uses it as `event_time`,
    /// so the estate's timeline matches the corpus's fiction.
    let eventTime: String
    /// Position in this entity+attribute's chain: 0 = oldest.
    let versionIndex: Int
    /// True for the final, still-true version of this chain.
    let isCurrent: Bool
    /// ISO8601 instant the record is FILED (drives `filedAt`). Defaults to
    /// `eventTime`. Contradiction pairs share `eventTime` BY DESIGN (no
    /// recency rule can pick a winner) but must NOT share `filedAt`: a tied
    /// filedAt makes the locus lane's `ORDER BY filedAt DESC, id DESC` fall
    /// to per-run-random UUIDs, drifting replay ranks. Filing order is a
    /// real-world sequence, not the semantic clock, so a +1s offset on the
    /// second record of each pair is faithful and deterministic.
    var captureDate: String? = nil
}

/// One scored query over the corpus.
struct SupersessionQuery: Codable, Sendable, Equatable {
    let id: String
    let question: String
    let entity: String
    let attribute: String
    /// The value that is true at query time.
    let currentValue: String
    /// Record id carrying the current value — must outrank every stale id.
    let currentRecordID: String
    /// Record ids carrying superseded values — every one of these ranking
    /// above `currentRecordID` is a failure.
    let supersededRecordIDs: [String]
}

/// A planted pair of claims that cannot both be true, with NO temporal
/// ordering between them — neither supersedes the other, so a recency rule
/// cannot resolve it. Detection, not ranking, is the scored behaviour.
struct ContradictionPair: Codable, Sendable, Equatable {
    let id: String
    let leftRecordID: String
    let rightRecordID: String
    let entity: String
    let attribute: String
}

/// One planted adversarial NON-contradiction: a pair that must NOT be
/// flagged at any tier. Three shapes cycle (see `generateSupersessionCorpus`):
/// an explicit supersession-marker chain, a distinct-entity same-value pair,
/// and a unit-equivalent value pair. `kind` names the shape so the scorer can
/// separate hard failures from the known unit-normalization limitation.
struct DecoyPair: Codable, Sendable, Equatable {
    let id: String
    let leftRecordID: String
    let rightRecordID: String
    /// "marker_supersession" | "distinct_entity" | "unit_equivalent".
    let kind: String
}

extension DecoyPair {
    static let kindMarkerSupersession = "marker_supersession"
    static let kindDistinctEntity = "distinct_entity"
    static let kindUnitEquivalent = "unit_equivalent"
}

struct SupersessionCorpus: Codable, Sendable, Equatable {
    let seed: UInt64
    let records: [SupersessionRecord]
    let queries: [SupersessionQuery]
    let contradictions: [ContradictionPair]
    /// MXE-CT3 P4: digit-valued divergence pairs (tier-3 class). Same pair
    /// shape as `contradictions`, so the type is reused.
    let divergences: [ContradictionPair]
    /// MXE-CT3 P4: adversarial non-contradictions that must fire at no tier.
    let decoys: [DecoyPair]

    init(seed: UInt64, records: [SupersessionRecord],
         queries: [SupersessionQuery], contradictions: [ContradictionPair],
         divergences: [ContradictionPair] = [], decoys: [DecoyPair] = []) {
        self.seed = seed
        self.records = records
        self.queries = queries
        self.contradictions = contradictions
        self.divergences = divergences
        self.decoys = decoys
    }

    /// Decode-defaults the P4 fields so pre-P4 dumps — including the
    /// committed conformance vector file, which pins the pre-P4 corpus
    /// classes — still decode. Encoding stays synthesized: dumps always
    /// carry the new keys (empty arrays when the classes are absent),
    /// matching the Rust leg's `#[serde(default)]` fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seed = try c.decode(UInt64.self, forKey: .seed)
        records = try c.decode([SupersessionRecord].self, forKey: .records)
        queries = try c.decode([SupersessionQuery].self, forKey: .queries)
        contradictions = try c.decode([ContradictionPair].self, forKey: .contradictions)
        divergences = try c.decodeIfPresent([ContradictionPair].self, forKey: .divergences) ?? []
        decoys = try c.decodeIfPresent([DecoyPair].self, forKey: .decoys) ?? []
    }
}

// MARK: - Deterministic generation

/// Builds a corpus that is a pure function of `seed`: same seed, same bytes.
/// Determinism is a hard gate — a benchmark whose corpus drifts between runs
/// cannot support a claim, and a published benchmark must be reproducible by
/// someone who does not have our code.
/// `divergenceCount` and `decoyCount` default to 0 HERE (the CLI default is
/// 5 for each): pre-P4 call sites — the replay lane and the committed
/// conformance vector file's regeneration check — keep producing the exact
/// pre-P4 corpus without a signature break. New classes draw from the RNG
/// strictly AFTER all pre-P4 classes, so the RNG draw sequence (every name
/// and value pick) is identical to the pre-P4 output for any seed. Record
/// CONTENT additionally carries the embedding-visibility sentence (see
/// notedSentence below, REPLAY_DRIFT_RCA addendum 2026-08-26) — the
/// committed conformance vectors pin the current content exactly.
func generateSupersessionCorpus(
    seed: UInt64,
    entityCount: Int = 40,
    versionsPerChain: Int = 3,
    contradictionCount: Int = 10,
    divergenceCount: Int = 0,
    decoyCount: Int = 0
) -> SupersessionCorpus {
    var rng = SplitMix64(seed: seed)

    // Vocabulary kept deliberately plain. Ornate distractors would make the
    // lane hard for reasons unrelated to supersession, which is not what is
    // being measured here.
    let firstNames = ["Sarah", "Marcus", "Priya", "Tomas", "Ines", "Kwame",
                      "Lena", "Hiroshi", "Amara", "Diego"]
    let lastNames  = ["Chen", "Okafor", "Lindqvist", "Baptiste", "Yamamoto",
                      "Novak", "Reyes", "Adeyemi", "Kowalski", "Haddad"]
    // (attribute, values, statement verb, QUESTION form). The question is
    // stored separately because "Where does X <verb> now?" is only grammatical
    // for one of these — a malformed question measures the harness's grammar,
    // not the product's retrieval.
    let attributes: [(String, [String], String, String)] = [
        ("employer", ["Acme Robotics", "Northwind Analytics", "Beta Corp",
                      "Vireo Systems", "Halcyon Labs"],
         "works at", "Where does %@ work now?"),
        ("city", ["Lisbon", "Toronto", "Osaka", "Nairobi", "Reykjavik"],
         "lives in", "Where does %@ live now?"),
        ("role", ["staff engineer", "engineering manager", "principal architect",
                  "director of platform", "technical lead"],
         "is a", "What is %@'s current role?"),
        ("primary language", ["Swift", "Rust", "Elixir", "OCaml", "Zig"],
         "mostly writes", "What language does %@ mostly write now?"),
    ]

    var records: [SupersessionRecord] = []
    var queries: [SupersessionQuery] = []
    var contradictions: [ContradictionPair] = []

    // Embedding-visibility sentence (REPLAY_DRIFT_RCA addendum 2026-08-26).
    // The deterministic dense embedding treats proper names as
    // out-of-vocabulary, so two records that differed ONLY by names (two
    // entities updating to the same employer) projected to byte-identical
    // vectors. Identical vectors exhaust the content-stable tie-break
    // (distance, then vecHash) and fall to per-run UUIDs at the dense k-cut
    // — and this lane re-imports its estate every replay run, so the UUID
    // order flips between runs, drifting meanStaleInTopK by 1/40. Every
    // record family therefore appends one plain in-vocabulary sentence,
    // unique per family ordinal: weekday(7) × period(5) × month(12) = 420
    // distinct combos (lcm 420), far above the default 60 families. Two
    // records can now only share a vector if they share entity/pair — and
    // within-family twins are metric-neutral. Index-derived: consumes NO
    // RNG draws, so the draw sequence (every name and value pick) is
    // unchanged from the pre-addendum corpus.
    let notedWeekdays = ["Monday", "Tuesday", "Wednesday", "Thursday",
                         "Friday", "Saturday", "Sunday"]
    let notedPeriods = ["morning", "noon", "afternoon", "evening", "night"]
    let notedMonths = ["January", "February", "March", "April", "May",
                       "June", "July", "August", "September", "October",
                       "November", "December"]
    func notedSentence(family: Int) -> String {
        " Noted one \(notedWeekdays[family % 7]) \(notedPeriods[family % 5])"
            + " in \(notedMonths[family % 12])."
    }

    // Timeline spans four years so version gaps are unambiguous. Fixed epoch —
    // never Date() — so the corpus does not change with the wall clock.
    let epoch = 1_580_000_000.0  // 2020-01-26T00:53:20Z
    let iso = ISO8601DateFormatter()
    iso.timeZone = TimeZone(secondsFromGMT: 0)

    for entityIndex in 0..<entityCount {
        let fn = firstNames[Int(rng.next() % UInt64(firstNames.count))]
        let ln = lastNames[Int(rng.next() % UInt64(lastNames.count))]
        // Index suffix guarantees entity uniqueness across the corpus.
        let name = fn + " " + ln + " " + String(entityIndex)
        let (attrName, values, verb, questionForm) = attributes[entityIndex % attributes.count]

        // Pick distinct values for the chain so each version is a real change.
        var pool = values
        var chainValues: [String] = []
        for _ in 0..<min(versionsPerChain, pool.count) {
            let idx = Int(rng.next() % UInt64(pool.count))
            chainValues.append(pool.remove(at: idx))
        }

        var chainIDs: [String] = []
        for (v, value) in chainValues.enumerated() {
            let id = "sup-\(entityIndex)-\(v)"
            chainIDs.append(id)
            // Versions land 200-400 days apart, strictly increasing.
            let dayOffset = Double(v) * (200.0 + Double(rng.next() % 200))
            // Add entityIndex seconds to guarantee unique filedAt values across
            // all (entity, version) pairs. Without this offset, all v=0 records
            // share epoch (dayOffset = 0.0) and the locus-lane SQL
            // ORDER BY filedAt DESC, id DESC falls back to UUID (minted fresh
            // per replay run) for tied filedAt — producing different locus
            // rank positions between runs and drifting meanStaleInTopK by 1/40.
            let when = epoch + dayOffset * 86_400.0 + Double(entityIndex)
            let isCurrent = (v == chainValues.count - 1)
            // Phrasing marks the change without naming the previous value —
            // a retriever must use the timeline, not a lexical cue like
            // "no longer", to decide which version is live.
            let content = (v == 0
                ? "\(name) \(verb) \(value)."
                : "Update: \(name) now \(verb) \(value).")
                + notedSentence(family: entityIndex)
            records.append(SupersessionRecord(
                id: id, entity: name, attribute: attrName, value: value,
                content: content, eventTime: iso.string(from: Date(timeIntervalSince1970: when)),
                versionIndex: v, isCurrent: isCurrent))
        }

        queries.append(SupersessionQuery(
            id: "q-\(entityIndex)",
            question: String(format: questionForm, name),
            entity: name, attribute: attrName,
            currentValue: chainValues[chainValues.count - 1],
            currentRecordID: chainIDs[chainIDs.count - 1],
            supersededRecordIDs: Array(chainIDs.dropLast())))
    }

    // Contradiction pairs: mutually exclusive claims sharing ONE event_time,
    // so no recency rule can pick a winner. The correct behaviour is to
    // surface the conflict, not to silently rank one first.
    for c in 0..<contradictionCount {
        let cfn = firstNames[Int(rng.next() % UInt64(firstNames.count))]
        let cln = lastNames[Int(rng.next() % UInt64(lastNames.count))]
        let name = cfn + " " + cln + " C" + String(c)
        let (attrName, values, verb, _) = attributes[c % attributes.count]
        let a = values[Int(rng.next() % UInt64(values.count))]
        var b = values[Int(rng.next() % UInt64(values.count))]
        if b == a { b = values[(values.firstIndex(of: a)! + 1) % values.count] }
        let when = iso.string(from: Date(timeIntervalSince1970: epoch + Double(c) * 86_400.0))
        let lid = "con-\(c)-a", rid = "con-\(c)-b"
        let conNoted = notedSentence(family: entityCount + c)
        records.append(SupersessionRecord(
            id: lid, entity: name, attribute: attrName, value: a,
            content: "\(name) \(verb) \(a)." + conNoted, eventTime: when,
            versionIndex: 0, isCurrent: false))
        // Second record of the pair files one second later: eventTime stays
        // SHARED (the semantic tie the pair exists to create) while filedAt
        // becomes unique and seed-deterministic (see captureDate doc above).
        let whenPlusOne = iso.string(from: Date(timeIntervalSince1970: epoch + Double(c) * 86_400.0 + 1.0))
        records.append(SupersessionRecord(
            id: rid, entity: name, attribute: attrName, value: b,
            content: "\(name) \(verb) \(b)." + conNoted, eventTime: when,
            versionIndex: 0, isCurrent: false, captureDate: whenPlusOne))
        contradictions.append(ContradictionPair(
            id: "con-\(c)", leftRecordID: lid, rightRecordID: rid,
            entity: name, attribute: attrName))
    }

    // ── MXE-CT3 P4: divergence pairs (tier-3 class) ─────────────────────────
    // Digit-valued twins of the contradiction pairs: same entity, same
    // attribute template, two claims differing ONLY in a numeric value token,
    // sharing ONE event_time so recency cannot resolve them. Units are
    // ATTACHED to the value ("45ms", not "45 ms") so the single differing
    // token carries a digit on both sides — the exact shape ConflictCue's
    // valueDivergence cue (tier 3) fires on (ConflictCue.swift:286-299:
    // same-length streams, every differing position digit-bearing).
    // NOTE: these score >= strongThreshold, so the LEGACY sweep auto-proposes
    // them too — they surface in `flagged outside planted` (context, not
    // error) while the tier-3 purpose run scores them as its planted class.
    var divergences: [ContradictionPair] = []
    // (attribute, values, content template "…%@… is/takes %v<unit>.").
    // Duration/latency attributes per the P4 spec — value-bearing claims a
    // real estate accumulates.
    let divergenceAttributes: [(String, [String], (String, String) -> String)] = [
        ("response time", ["30", "45", "90", "120", "250"],
         { name, v in "Response time for \(name) is \(v)ms." }),
        ("build duration", ["8", "12", "25", "40", "55"],
         { name, v in "The nightly build for \(name) takes \(v)min." }),
        ("request timeout", ["15", "60", "300", "600", "900"],
         { name, v in "The request timeout for \(name) is \(v)s." }),
    ]
    for n in 0..<divergenceCount {
        let dfn = firstNames[Int(rng.next() % UInt64(firstNames.count))]
        let dln = lastNames[Int(rng.next() % UInt64(lastNames.count))]
        let name = dfn + " " + dln + " D" + String(n)
        let (attrName, values, template) = divergenceAttributes[n % divergenceAttributes.count]
        let a = values[Int(rng.next() % UInt64(values.count))]
        var b = values[Int(rng.next() % UInt64(values.count))]
        if b == a { b = values[(values.firstIndex(of: a)! + 1) % values.count] }
        let when = iso.string(from: Date(timeIntervalSince1970: epoch + Double(400 + n) * 86_400.0))
        let lid = "div-\(n)-a", rid = "div-\(n)-b"
        let divNoted = notedSentence(family: entityCount + contradictionCount + n)
        records.append(SupersessionRecord(
            id: lid, entity: name, attribute: attrName, value: a,
            content: template(name, a) + divNoted, eventTime: when,
            versionIndex: 0, isCurrent: false))
        records.append(SupersessionRecord(
            id: rid, entity: name, attribute: attrName, value: b,
            content: template(name, b) + divNoted, eventTime: when,
            versionIndex: 0, isCurrent: false))
        divergences.append(ContradictionPair(
            id: "div-\(n)", leftRecordID: lid, rightRecordID: rid,
            entity: name, attribute: attrName))
    }

    // ── MXE-CT3 P4: decoy pairs (adversarial NON-contradictions) ────────────
    // Three shapes cycle; each is a pair the tiers must NOT flag. Decoy-hit
    // scoring (SupersessionRunner) counts appearances in tier sections and
    // legacy PROPOSED lines only — CANDIDATE (borderline adjudication feed)
    // and typed-section HISTORICAL lines are not hits.
    var decoys: [DecoyPair] = []
    // Shape (a)/(b) reuse the employer value pool so decoy claims read like
    // the genuine corpus claims rather than standing out lexically.
    let employerValues = attributes[0].1
    for n in 0..<decoyCount {
        let dfn = firstNames[Int(rng.next() % UInt64(firstNames.count))]
        let dln = lastNames[Int(rng.next() % UInt64(lastNames.count))]
        let lid = "dec-\(n)-a", rid = "dec-\(n)-b"
        let decNoted = notedSentence(family: entityCount + contradictionCount + divergenceCount + n)
        let kind: String
        switch n % 3 {
        case 0:
            // (a) Explicit supersession-marker chain: v0 claim, then an
            // "Update: … moved to …" revision 250 days later. Genuinely a
            // supersession (resolvable by recency), NOT a contradiction —
            // marker_revision territory the tiers must leave alone. The
            // typed lane classifies the same coordinate at different
            // instants as historicalSuccession, never proof.
            kind = DecoyPair.kindMarkerSupersession
            let name = dfn + " " + dln + " X" + String(n)
            let a = employerValues[Int(rng.next() % UInt64(employerValues.count))]
            var b = employerValues[Int(rng.next() % UInt64(employerValues.count))]
            if b == a { b = employerValues[(employerValues.firstIndex(of: a)! + 1) % employerValues.count] }
            let t0 = epoch + Double(500 + n) * 86_400.0
            records.append(SupersessionRecord(
                id: lid, entity: name, attribute: "employer", value: a,
                content: "\(name) works at \(a)." + decNoted,
                eventTime: iso.string(from: Date(timeIntervalSince1970: t0)),
                versionIndex: 0, isCurrent: false))
            records.append(SupersessionRecord(
                id: rid, entity: name, attribute: "employer", value: b,
                content: "Update: \(name) moved to \(b)." + decNoted,
                eventTime: iso.string(from: Date(timeIntervalSince1970: t0 + 250.0 * 86_400.0)),
                versionIndex: 1, isCurrent: false))
        case 1:
            // (b) Distinct entities, same attribute, SAME value — two people
            // at the same employer is agreement about different subjects,
            // not conflict. The second first name is forced distinct so the
            // leading token always differs: a name collision would leave
            // only the digit-bearing suffix differing, which reads as
            // valueDivergence — the exact false positive this shape probes.
            kind = DecoyPair.kindDistinctEntity
            var dfn2 = firstNames[Int(rng.next() % UInt64(firstNames.count))]
            let dln2 = lastNames[Int(rng.next() % UInt64(lastNames.count))]
            if dfn2 == dfn {
                dfn2 = firstNames[(firstNames.firstIndex(of: dfn)! + 1) % firstNames.count]
            }
            let name1 = dfn + " " + dln + " Y" + String(n)
            let name2 = dfn2 + " " + dln2 + " Y" + String(n)
            let v = employerValues[Int(rng.next() % UInt64(employerValues.count))]
            let when = iso.string(from: Date(timeIntervalSince1970: epoch + Double(600 + n) * 86_400.0))
            records.append(SupersessionRecord(
                id: lid, entity: name1, attribute: "employer", value: v,
                content: "\(name1) works at \(v)." + decNoted, eventTime: when,
                versionIndex: 0, isCurrent: false))
            records.append(SupersessionRecord(
                id: rid, entity: name2, attribute: "employer", value: v,
                content: "\(name2) works at \(v)." + decNoted, eventTime: when,
                versionIndex: 0, isCurrent: false))
        default:
            // (c) Unit-equivalent duration pair: 90s == 1.5min semantically,
            // but the tokens are lexically divergent and both digit-bearing,
            // so ConflictCue's valueDivergence fires — a KNOWN limitation
            // (the lexical cue cannot normalize units). Scored in the
            // separate known-limitation row, never as a hard decoy failure.
            kind = DecoyPair.kindUnitEquivalent
            let name = dfn + " " + dln + " Z" + String(n)
            let when = iso.string(from: Date(timeIntervalSince1970: epoch + Double(700 + n) * 86_400.0))
            records.append(SupersessionRecord(
                id: lid, entity: name, attribute: "deploy duration", value: "90s",
                content: "The deploy pipeline for \(name) runs in 90s." + decNoted,
                eventTime: when, versionIndex: 0, isCurrent: false))
            records.append(SupersessionRecord(
                id: rid, entity: name, attribute: "deploy duration", value: "1.5min",
                content: "The deploy pipeline for \(name) runs in 1.5min." + decNoted,
                eventTime: when, versionIndex: 0, isCurrent: false))
        }
        decoys.append(DecoyPair(
            id: "dec-\(n)", leftRecordID: lid, rightRecordID: rid, kind: kind))
    }

    return SupersessionCorpus(seed: seed, records: records,
                              queries: queries, contradictions: contradictions,
                              divergences: divergences, decoys: decoys)
}
