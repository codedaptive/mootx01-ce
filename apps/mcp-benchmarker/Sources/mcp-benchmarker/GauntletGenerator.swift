import Foundation

// GauntletGenerator.swift — builds a GauntletCorpus from a seed + difficulty
// profile (Phase 2.1). Pure and deterministic: one SplitMix64 threads the whole
// pass, so the same (seed, profile) yields a byte-identical corpus.jsonl and
// needles.json. No Date(), no global RNG, no filesystem — the engine returns the
// in-memory corpus; serialization lives in the runner/CLI.
//
// Each needle is built from a SUBJECT (a fictional entity) and an ATTRIBUTE (a
// fact about it with a definite value). The subject/attribute pools are fixed,
// fictional, and self-contained so the corpus never collides with real-world
// knowledge a backend's base model might "know" — every answer must come from
// retrieval, not from the model's priors. The query for a needle names the
// subject + attribute; the correct value appears ONLY in the needle record.
//
// The five tier constructors each plant `distractorsPerNeedle` records around
// the needle in their tier-specific way (see GauntletCorpus.swift for the
// retriever weakness each one targets).

/// The difficulty profile for a generation run: how many needles per tier and
/// how many distractors to plant around each needle. Both are CLI-driven so one
/// generator emits an easy or a brutal corpus.
struct GauntletProfile: Sendable, Equatable {
    /// Needles to generate per tier. A tier with count 0 is omitted entirely.
    let tierCounts: [NoiseTier: Int]
    /// Distractors planted around each needle (the difficulty dial). For T4 the
    /// split partner is in addition to these; for T3 the superseded version is
    /// one of these.
    let distractorsPerNeedle: Int

    init(tierCounts: [NoiseTier: Int], distractorsPerNeedle: Int) {
        self.tierCounts = tierCounts
        self.distractorsPerNeedle = max(distractorsPerNeedle, 1)
    }

    /// An even mix of all five tiers, `perTier` needles each — the default when
    /// the CLI is given only a needle count.
    static func evenMix(perTier: Int, distractorsPerNeedle: Int) -> GauntletProfile {
        var counts: [NoiseTier: Int] = [:]
        for tier in NoiseTier.allCases { counts[tier] = perTier }
        return GauntletProfile(tierCounts: counts, distractorsPerNeedle: distractorsPerNeedle)
    }
}

/// The deterministic adversarial corpus generator.
struct GauntletGenerator {
    /// The fixed pool of fictional subjects. Invented place/org names with no
    /// real-world referent, so retrieval cannot be shortcut by a model prior.
    /// Order is fixed — it is part of the deterministic draw space.
    private static let subjects = [
        "the Velrath Combine", "Mirelle Station", "the Korthane Accord",
        "Sundabar Holdings", "the Ashfen Protocol", "Caldwynn Foundry",
        "the Threnody Exchange", "Olwen Reservoir", "the Pellucid Mandate",
        "Brackwater Hall", "the Yarrow Concordat", "Stillhaven Depot",
        "the Marrowgate Trust", "Verisade Labs", "the Quillon Charter",
        "Drossel Yards", "the Ambergris League", "Fenmark Atelier",
        "the Castellan Pact", "Halloway Reach",
    ]

    /// The fixed pool of attributes, each a (phrase, value-generator) pair. The
    /// value generator turns an integer draw into a definite, checkable value.
    /// Order is fixed — part of the deterministic draw space.
    private struct Attribute: Sendable {
        let phrase: String                 // e.g. "was chartered in the year"
        let queryNoun: String              // e.g. "charter year"
        let makeValue: @Sendable (Int) -> String  // integer draw → concrete value
    }

    private static let attributes: [Attribute] = [
        Attribute(phrase: "was chartered in the year", queryNoun: "charter year",
                  makeValue: { "\(1700 + $0 % 320)" }),
        Attribute(phrase: "is headquartered in the district of", queryNoun: "headquarters district",
                  makeValue: { ["Tarn", "Vael", "Ostry", "Brenne", "Cawl", "Dunmere"][$0 % 6] }),
        Attribute(phrase: "operates a fleet numbering exactly", queryNoun: "fleet size",
                  makeValue: { "\(12 + $0 % 488) vessels" }),
        Attribute(phrase: "is governed by the steward named", queryNoun: "presiding steward",
                  makeValue: { ["Oren Vask", "Lysa Crale", "Bertram Idle", "Nessa Pyke",
                                "Calder Wren", "Imogen Strake"][$0 % 6] }),
        Attribute(phrase: "holds a reserve valued at", queryNoun: "reserve value",
                  makeValue: { "\(3 + $0 % 97) million marks" }),
        Attribute(phrase: "maintains its primary archive on the level called",
                  queryNoun: "archive level",
                  makeValue: { ["Sublevel Closed", "the Cinder Tier", "Vault Nine",
                                "the Lower Stacks", "Gallery Zero", "the Deep Index"][$0 % 6] }),
    ]

    /// Topical wings/rooms a record can be filed under. The needle's "home"
    /// location is derived from its subject index so topical neighbours cluster;
    /// the T5 scatter tier deliberately files the needle elsewhere.
    private static let wings = ["Ledger", "Charter", "Fleet", "Steward", "Reserve", "Archive"]

    let profile: GauntletProfile

    init(profile: GauntletProfile) {
        self.profile = profile
    }

    /// Generates the corpus. One SplitMix64 seeded with `seed` threads the whole
    /// pass; the draw order is fixed (tiers in `NoiseTier.allCases` order, needles
    /// in sequence, distractors in plant order), which is what makes the output
    /// byte-identical for a given seed.
    func generate(seed: UInt64) -> GauntletCorpus {
        var rng = SplitMix64(seed: seed)
        var records: [GauntletRecord] = []
        var needles: [Needle] = []
        var needleSerial = 0

        // Iterate tiers in their canonical order so the emission order is stable.
        for tier in NoiseTier.allCases {
            let count = profile.tierCounts[tier] ?? 0
            for _ in 0..<count {
                let nid = String(format: "n%04d", needleSerial)
                needleSerial += 1
                let built = buildNeedle(id: nid, tier: tier, rng: &rng)
                records.append(contentsOf: built.records)
                needles.append(built.needle)
            }
        }

        return GauntletCorpus(
            seed: seed,
            records: records,
            needles: needles,
            tierCounts: profile.tierCounts.filter { $0.value > 0 },
            distractorsPerNeedle: profile.distractorsPerNeedle)
    }

    // MARK: - Needle construction

    /// One generated needle plus all the records that go into the corpus for it
    /// (the needle record, its distractors, and any split partner).
    private struct BuiltNeedle {
        let needle: Needle
        let records: [GauntletRecord]
    }

    /// Draws a subject + attribute + value for a needle, then dispatches to the
    /// tier-specific distractor constructor. The needle's CONTENT, QUERY, and
    /// home LOCATION are common to every tier; only the planted noise differs.
    private func buildNeedle(id: String, tier: NoiseTier,
                             rng: inout SplitMix64) -> BuiltNeedle {
        let subjectIdx = rng.upTo(Self.subjects.count)
        let attrIdx = rng.upTo(Self.attributes.count)
        let valueDraw = rng.upTo(10_000)

        let subject = Self.subjects[subjectIdx]
        let attribute = Self.attributes[attrIdx]
        let value = attribute.makeValue(valueDraw)

        // The needle states the fact in full. Completeness is derived from
        // returned result items, not a separate fetch-and-byte-compare.
        let content = "\(subject) \(attribute.phrase) \(value)."
        // The query names the subject and the attribute noun. The correct value
        // appears ONLY in the needle, so a correct retrieval must return it.
        let query = "What is the \(attribute.queryNoun) of \(subject)?"
        // The home location clusters topical neighbours by attribute.
        let homeWing = Self.wings[attrIdx % Self.wings.count]
        let homeLocation = "\(homeWing)/\(subjectSlug(subject))"

        switch tier {
        case .lexical:
            return buildLexical(id: id, subject: subject, attribute: attribute,
                                value: value, valueDraw: valueDraw, content: content,
                                query: query, location: homeLocation, rng: &rng)
        case .semantic:
            return buildSemantic(id: id, subject: subject, attribute: attribute,
                                 value: value, valueDraw: valueDraw, content: content,
                                 query: query, location: homeLocation, rng: &rng)
        case .temporal:
            return buildTemporal(id: id, subject: subject, attribute: attribute,
                                 value: value, valueDraw: valueDraw, content: content,
                                 query: query, location: homeLocation, rng: &rng)
        case .split:
            return buildSplit(id: id, subject: subject, attribute: attribute,
                              value: value, content: content, query: query,
                              location: homeLocation, rng: &rng)
        case .scatter:
            return buildScatter(id: id, subject: subject, subjectIdx: subjectIdx,
                                attribute: attribute, value: value, valueDraw: valueDraw,
                                content: content, query: query, homeLocation: homeLocation,
                                rng: &rng)
        }
    }

    // MARK: - T1 lexical distractors

    /// T1: distractors SHARE the needle's salient tokens (the subject name and,
    /// where the value is a date/number, a nearby number) but assert a DIFFERENT
    /// fact (a different attribute of the same subject). High lexical overlap,
    /// wrong answer — the trap for a token-match retriever.
    private func buildLexical(id: String, subject: String, attribute: Attribute,
                              value: String, valueDraw: Int, content: String,
                              query: String, location: String,
                              rng: inout SplitMix64) -> BuiltNeedle {
        let needleRecord = GauntletRecord(id: id, content: content, location: location,
                                        tier: .lexical, role: .needle, needleID: id)
        var records = [needleRecord]
        var distractorIDs: [String] = []

        for k in 0..<profile.distractorsPerNeedle {
            // Pick a DIFFERENT attribute of the SAME subject so the subject token
            // overlaps but the stated fact is unrelated to the query's attribute.
            let otherAttr = Self.attributes[(rng.upTo(Self.attributes.count - 1) + 1
                + indexOf(attribute)) % Self.attributes.count]
            let otherValue = otherAttr.makeValue(rng.upTo(10_000))
            let did = "\(id)-t1-\(k)"
            let dContent = "\(subject) \(otherAttr.phrase) \(otherValue)."
            records.append(GauntletRecord(id: did, content: dContent, location: location,
                                        tier: .lexical, role: .distractor, needleID: id))
            distractorIDs.append(did)
        }

        let needle = Needle(id: id, query: query, content: content, tier: .lexical,
                            location: location, distractorIDs: distractorIDs,
                            splitPartnerID: nil, expectedRank: 1)
        return BuiltNeedle(needle: needle, records: records)
    }

    // MARK: - T2 semantic distractors

    /// T2: paraphrases with CLOSE meaning but a WRONG value. Each distractor
    /// restates the needle's exact attribute about the same subject using
    /// different wording, but with a different (wrong) value. The embedding sits
    /// near the needle's; only the value distinguishes right from wrong — the
    /// trap for a pure-vector retriever.
    private func buildSemantic(id: String, subject: String, attribute: Attribute,
                               value: String, valueDraw: Int, content: String,
                               query: String, location: String,
                               rng: inout SplitMix64) -> BuiltNeedle {
        let needleRecord = GauntletRecord(id: id, content: content, location: location,
                                        tier: .semantic, role: .needle, needleID: id)
        var records = [needleRecord]
        var distractorIDs: [String] = []

        // Paraphrase templates for the SAME attribute — close meaning, different
        // surface form. The value is drawn wrong (and forced to differ from the
        // needle's value so the distractor is genuinely incorrect).
        let templates = [
            "Records indicate that \(subject), as to its \(attribute.queryNoun), shows %@.",
            "The \(attribute.queryNoun) attributed to \(subject) is reported as %@.",
            "Per the filing, \(subject) \(attribute.phrase) %@.",
            "It is widely noted that \(subject)'s \(attribute.queryNoun) stands at %@.",
        ]
        for k in 0..<profile.distractorsPerNeedle {
            var wrongValue = attribute.makeValue(rng.upTo(10_000))
            // Guarantee the distractor's value differs from the needle's, else it
            // would accidentally be correct. Re-draw deterministically until it
            // differs; the attribute value spaces are large enough that this
            // terminates immediately in practice.
            while wrongValue == value { wrongValue = attribute.makeValue(rng.upTo(10_000)) }
            let template = templates[k % templates.count]
            let dContent = String(format: template, wrongValue)
            let did = "\(id)-t2-\(k)"
            records.append(GauntletRecord(id: did, content: dContent, location: location,
                                        tier: .semantic, role: .distractor, needleID: id))
            distractorIDs.append(did)
        }

        let needle = Needle(id: id, query: query, content: content, tier: .semantic,
                            location: location, distractorIDs: distractorIDs,
                            splitPartnerID: nil, expectedRank: 1)
        return BuiltNeedle(needle: needle, records: records)
    }

    // MARK: - T3 temporal confusion

    /// T3: SUPERSEDED earlier versions of the needle's OWN fact, plus the current
    /// version (the needle). Each distractor is the same subject+attribute with a
    /// stale value and an explicit earlier date, marked superseded. A retriever
    /// with no recency sense sees several matches; the stale ones must lose to the
    /// current needle. The needle itself is marked "current as of" a later date.
    private func buildTemporal(id: String, subject: String, attribute: Attribute,
                               value: String, valueDraw: Int, content: String,
                               query: String, location: String,
                               rng: inout SplitMix64) -> BuiltNeedle {
        // The needle carries an explicit currency marker so it reads as the live
        // version. This augmented string is the needle's verbatim content.
        let currentYear = 2020 + rng.upTo(6)   // 2020..2025
        let needleContent = "\(content) (current as of \(currentYear))"
        let needleRecord = GauntletRecord(id: id, content: needleContent, location: location,
                                        tier: .temporal, role: .needle, needleID: id)
        var records = [needleRecord]
        var distractorIDs: [String] = []

        for k in 0..<profile.distractorsPerNeedle {
            var staleValue = attribute.makeValue(rng.upTo(10_000))
            while staleValue == value { staleValue = attribute.makeValue(rng.upTo(10_000)) }
            // Each superseded version is dated strictly before the current year.
            let staleYear = currentYear - 1 - rng.upTo(20)   // earlier than current
            let dContent = "\(subject) \(attribute.phrase) \(staleValue). "
                + "(superseded; recorded \(staleYear))"
            let did = "\(id)-t3-\(k)"
            records.append(GauntletRecord(id: did, content: dContent, location: location,
                                        tier: .temporal, role: .distractor, needleID: id))
            distractorIDs.append(did)
        }

        let needle = Needle(id: id, query: query, content: needleContent, tier: .temporal,
                            location: location, distractorIDs: distractorIDs,
                            splitPartnerID: nil, expectedRank: 1)
        return BuiltNeedle(needle: needle, records: records)
    }

    // MARK: - T4 split facts

    /// T4: the answer is split across TWO records. The needle holds half the
    /// answer and names a CODE; the partner record holds the other half keyed by
    /// the same code. Neither alone resolves the query — the backend must surface
    /// BOTH. The remaining distractors are near-miss codes (same shape, wrong
    /// code) to make the join non-trivial.
    private func buildSplit(id: String, subject: String, attribute: Attribute,
                            value: String, content: String, query: String,
                            location: String, rng: inout SplitMix64) -> BuiltNeedle {
        // A join code links the two halves. Deterministic from the draw.
        let code = String(format: "REF-%04d", rng.upTo(10_000))
        // The needle states the subject + the existence of the fact under a code,
        // but withholds the value, pointing at the partner record by code.
        let needleContent = "\(subject) records its \(attribute.queryNoun) under reference \(code); "
            + "see the matching reference entry for the value."
        // The partner holds the actual value keyed by the same code.
        let partnerContent = "Reference \(code): the \(attribute.queryNoun) is \(value)."

        let needleRecord = GauntletRecord(id: id, content: needleContent, location: location,
                                        tier: .split, role: .needle, needleID: id)
        let partnerID = "\(id)-partner"
        let partnerRecord = GauntletRecord(id: partnerID, content: partnerContent,
                                         location: location, tier: .split,
                                         role: .splitPartner, needleID: id)
        var records = [needleRecord, partnerRecord]
        var distractorIDs: [String] = []

        // Near-miss reference entries: same shape, different code + value.
        for k in 0..<profile.distractorsPerNeedle {
            let otherCode = String(format: "REF-%04d", rng.upTo(10_000))
            let otherValue = attribute.makeValue(rng.upTo(10_000))
            let dContent = "Reference \(otherCode): the \(attribute.queryNoun) is \(otherValue)."
            let did = "\(id)-t4-\(k)"
            records.append(GauntletRecord(id: did, content: dContent, location: location,
                                        tier: .split, role: .distractor, needleID: id))
            distractorIDs.append(did)
        }

        let needle = Needle(id: id, query: query, content: needleContent, tier: .split,
                            location: location, distractorIDs: distractorIDs,
                            splitPartnerID: partnerID, expectedRank: 1)
        return BuiltNeedle(needle: needle, records: records)
    }

    // MARK: - T5 cross-location scatter

    /// T5: the needle is filed FAR from its topical home, and topical decoys are
    /// filed where the needle "should" live. A retriever that biases toward the
    /// topical location surfaces the decoys; the needle is elsewhere. The needle's
    /// content is unchanged — only its location moves, and decoys occupy the home.
    private func buildScatter(id: String, subject: String, subjectIdx: Int,
                              attribute: Attribute, value: String, valueDraw: Int,
                              content: String, query: String, homeLocation: String,
                              rng: inout SplitMix64) -> BuiltNeedle {
        // Scatter the needle to a DISTANT wing/room, deliberately unrelated to its
        // attribute's topical home. The far wing is chosen to differ from home.
        let homeWingName = homeLocation.split(separator: "/").first.map(String.init) ?? "Ledger"
        var farWing = Self.wings[rng.upTo(Self.wings.count)]
        while farWing == homeWingName { farWing = Self.wings[rng.upTo(Self.wings.count)] }
        let farLocation = "\(farWing)/Outpost-\(rng.upTo(900) + 100)"

        let needleRecord = GauntletRecord(id: id, content: content, location: farLocation,
                                        tier: .scatter, role: .needle, needleID: id)
        var records = [needleRecord]
        var distractorIDs: [String] = []

        // Topical decoys filed at the HOME location: same attribute topic, same
        // subject, but a wrong value — they occupy the spot the needle "should"
        // be in, so a location-biased retriever returns them instead.
        for k in 0..<profile.distractorsPerNeedle {
            var decoyValue = attribute.makeValue(rng.upTo(10_000))
            while decoyValue == value { decoyValue = attribute.makeValue(rng.upTo(10_000)) }
            let dContent = "\(subject) \(attribute.phrase) \(decoyValue)."
            let did = "\(id)-t5-\(k)"
            records.append(GauntletRecord(id: did, content: dContent, location: homeLocation,
                                        tier: .scatter, role: .distractor, needleID: id))
            distractorIDs.append(did)
        }

        let needle = Needle(id: id, query: query, content: content, tier: .scatter,
                            location: farLocation, distractorIDs: distractorIDs,
                            splitPartnerID: nil, expectedRank: 1)
        return BuiltNeedle(needle: needle, records: records)
    }

    // MARK: - helpers

    /// Index of an attribute in the fixed pool, by phrase identity. Used by T1 to
    /// offset away from the needle's own attribute deterministically.
    private func indexOf(_ attribute: Attribute) -> Int {
        Self.attributes.firstIndex { $0.phrase == attribute.phrase } ?? 0
    }

    /// A filesystem-safe, deterministic slug for a subject (drop articles and
    /// punctuation, hyphenate). Used to build a stable per-subject room name so
    /// topical neighbours cluster under one room.
    private func subjectSlug(_ subject: String) -> String {
        let lowered = subject.lowercased()
            .replacingOccurrences(of: "the ", with: "")
        let kept = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        // Collapse runs of hyphens and trim, deterministically.
        let collapsed = String(kept).split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "room" : collapsed
    }
}
