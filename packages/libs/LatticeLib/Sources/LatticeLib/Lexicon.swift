// Lexicon.swift
//
// The FDC canonicalization lexicon (cookbook §3.1) and its deterministic
// build procedure. The lexicon is a flat map `stem(normalize(token)) ->
// conceptID` used by Step 2 of the encoder: a surface token is normalized
// and Porter2-stemmed, then looked up here to collapse synonyms onto one
// concept identity so two independent devices land the same code.
//
// Built from two public-domain sources (cookbook §2/§3.1). Wikidata provides
// the concept IDs (the shared Q-ID is the federation identity); WordNet fills
// the coverage gaps and disambiguates word senses:
//   - Wikidata: surface forms (rdfs:label + skos:altLabel) -> Q-ID, plus the
//     WordNet-synset -> Q-ID mapping (property P8814). The primary concept-ID
//     source. Strong on named entities and multilingual coverage.
//   - WordNet (Princeton): a lemma's synsets in frequency order (sense 0 =
//     primary). Used to disambiguate which Q-ID a common word means, and — only
//     where no Q-ID exists for the concept — to supply a stable "wn:<offset>-
//     <pos>" fallback (the genuine coverage gap).
//
// Build procedure and the deterministic conflict-resolution rule are
// specified in FDC_ENCODER_COOKBOOK_v1.0 § "Lexicon Build Procedure".
// The key derivation (Normalizer.normalize then Stemmer.stem) is identical
// to the runtime so build-time and runtime keys agree bit-for-bit.

import Foundation

/// A pinned, versioned canonicalization lexicon: `stem(normalize(token)) ->
/// conceptID`. Codable for the bundled JSON artifact; entry order is not
/// significant (lookup is by key) but is emitted sorted for byte-stable diffs.
public struct CanonicalizationLexicon: Sendable, Codable, Equatable {
    /// Pinned lexicon version. Part of the FDC agreement protocol: two
    /// encoders must share this version or their bags can diverge.
    public let version: String
    /// Language scope (ISO code). English ("en") ships by default.
    public let language: String
    /// The flat map. Keys are stemmed/normalized surface forms; values are
    /// concept IDs — a Wikidata Q-ID ("Q144") or a WordNet fallback
    /// ("wn:02086723-n").
    public let entries: [String: String]

    public init(version: String, language: String, entries: [String: String]) {
        self.version = version
        self.language = language
        self.entries = entries
    }
}

/// Deterministic builder for the canonicalization lexicon. Pure: no clock, no
/// RNG, no network. Same inputs produce a byte-identical artifact across runs
/// and machines.
public enum LexiconBuilder {

    public struct Inputs: Sendable {
        /// Path to the WordNet `dict/` directory (contains `index.noun`,
        /// `index.verb`, `index.adj`, `index.adv`).
        public let wordNetDictDir: String
        /// Path to the Wikidata P8814 extraction TSV (columns:
        /// item, wn, label, alias — as emitted by the seed query).
        public let wikidataTSV: String
        public let version: String
        public let language: String
        public init(wordNetDictDir: String, wikidataTSV: String, version: String, language: String = "en") {
            self.wordNetDictDir = wordNetDictDir
            self.wikidataTSV = wikidataTSV
            self.version = version
            self.language = language
        }
    }

    // Candidate tier — lower wins. Wikidata is the primary concept-ID source
    // (cookbook §2: "Wikidata provides the concept IDs; WordNet fills the
    // coverage gaps"). So a Q-ID is always the identity when one exists; the
    // `wn:` fallback is genuine gap-fill, used only when no sense maps to any
    // Q-ID. WordNet earns its keep by *disambiguating* which Q-ID a common word
    // means (its frequency-ordered senses), not by outranking Q-IDs.
    private enum Tier: Int {
        case wordNetSenseQID = 1   // Q-ID reached via a WordNet sense of this lemma
        case wikidataAliasQID = 2  // Q-ID from a Wikidata surface/alias only
        case wordNetFallback = 3   // wn:<synset> — no Q-ID exists for this concept
    }

    private struct Candidate {
        let conceptID: String   // "Q144" or "wn:02086723-n"
        let tier: Tier
        let senseIndex: Int     // WordNet sense rank (0 = primary); .max for aliases
        let support: Int        // surface-form support for alias Q-IDs
    }

    /// Build the lexicon from the two sources. Throws if an input file is
    /// missing or unreadable.
    public static func build(_ inputs: Inputs) throws -> CanonicalizationLexicon {
        let (synsetToQID, wikidataSurfaces) = try parseWikidata(inputs.wikidataTSV)

        var byKey: [String: Candidate] = [:]
        func consider(_ key: String, _ cand: Candidate) {
            guard !key.isEmpty else { return }
            guard let existing = byKey[key] else { byKey[key] = cand; return }
            byKey[key] = resolve(existing, cand)
        }

        // WordNet senses (frequency order): a sense maps to its Q-ID via P8814
        // when one exists (tier 1, the lexical sense of the word), else to the
        // synset-ID fallback (tier 3, gap-fill).
        for (lemma, synsetID, senseIndex) in try parseWordNet(inputs.wordNetDictDir) {
            guard let key = singleTokenKey(lemma) else { continue }
            if let qid = synsetToQID[synsetID] {
                consider(key, Candidate(conceptID: qid, tier: .wordNetSenseQID, senseIndex: senseIndex, support: 0))
            } else {
                consider(key, Candidate(conceptID: "wn:\(synsetID)", tier: .wordNetFallback, senseIndex: senseIndex, support: 0))
            }
        }

        // Wikidata aliases (tier 2): the primary Q-ID source for keys not
        // covered by a WordNet sense (named entities, multilingual). Support =
        // times a Q-ID is named by any surface form.
        var qidSupport: [String: Int] = [:]
        for (_, qid) in wikidataSurfaces { qidSupport[qid, default: 0] += 1 }
        for (surface, qid) in wikidataSurfaces {
            guard let key = singleTokenKey(surface) else { continue }
            consider(key, Candidate(conceptID: qid, tier: .wikidataAliasQID, senseIndex: .max, support: qidSupport[qid] ?? 1))
        }

        return CanonicalizationLexicon(version: inputs.version, language: inputs.language, entries: byKey.mapValues { $0.conceptID })
    }

    // MARK: - Conflict resolution (cookbook § Lexicon Build Procedure)
    //
    // Wikidata-primary, WordNet-disambiguated. Lower tier wins:
    //   1. A Q-ID from a WordNet sense of the word (frequency-ranked) — this is
    //      where WordNet disambiguates which Q-ID a common word means, so
    //      "dog" -> Q144 (the dog, sense 0), not the sausage sense.
    //   2. A Q-ID from a Wikidata alias only — fills keys with no WordNet sense.
    //   3. A `wn:<synset>` fallback — only when no Q-ID exists for the concept.
    // Within a tier: tier 1 by lowest sense rank (then support, then lowest
    // Q-number); tier 2 by most support (then lowest Q-number); tier 3 by lowest
    // sense rank (then lowest synset ID). Fully deterministic, order-independent.
    private static func resolve(_ a: Candidate, _ b: Candidate) -> Candidate {
        if a.tier != b.tier { return a.tier.rawValue < b.tier.rawValue ? a : b }
        switch a.tier {
        case .wordNetSenseQID:
            if a.senseIndex != b.senseIndex { return a.senseIndex < b.senseIndex ? a : b }
            if a.support != b.support { return a.support > b.support ? a : b }
            return qNumber(a.conceptID) <= qNumber(b.conceptID) ? a : b
        case .wikidataAliasQID:
            if a.support != b.support { return a.support > b.support ? a : b }
            return qNumber(a.conceptID) <= qNumber(b.conceptID) ? a : b
        case .wordNetFallback:
            if a.senseIndex != b.senseIndex { return a.senseIndex < b.senseIndex ? a : b }
            return a.conceptID <= b.conceptID ? a : b
        }
    }

    private static func qNumber(_ qid: String) -> Int { Int(qid.dropFirst()) ?? Int.max }

    // MARK: - Key derivation (identical to runtime: normalize then stem)
    //
    // Only single-token surfaces become keys — the runtime looks up one stemmed
    // token at a time, so a multi-word surface cannot key a single entry.
    private static func singleTokenKey(_ surface: String) -> String? {
        let tokens = Tokenizer.tokenize(surface)
        guard tokens.count == 1 else { return nil }
        let key = Stemmer.stem(Normalizer.normalize(tokens[0]))
        return key.isEmpty ? nil : key
    }

    // MARK: - Wikidata TSV parse
    // Columns (tab-separated, header `?item ?wn ?label ?alias`):
    //   item=<.../Qnnn>  wn="02086723-n"  label="dog"@en  alias="domestic dog"@en
    private static func parseWikidata(_ path: String) throws -> (synsetToQID: [String: String], surfaces: [(String, String)]) {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var synsetToQID: [String: String] = [:]
        var surfaces: [(String, String)] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("?item") { continue }
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 2, let qid = qidFromEntity(cols[0]) else { continue }
            let synset = literal(cols[1])
            if !synset.isEmpty, synsetToQID[synset] == nil { synsetToQID[synset] = qid }
            if cols.count >= 3 { let lbl = literal(cols[2]); if !lbl.isEmpty { surfaces.append((lbl, qid)) } }
            if cols.count >= 4 { let al = literal(cols[3]); if !al.isEmpty { surfaces.append((al, qid)) } }
        }
        return (synsetToQID, surfaces)
    }

    private static func qidFromEntity(_ field: String) -> String? {
        guard let slash = field.lastIndex(of: "/") else { return nil }
        let tail = field[field.index(after: slash)...].drop(while: { $0 == " " })
        let q = tail.prefix(while: { $0 != ">" })
        return q.hasPrefix("Q") ? String(q) : nil
    }

    private static func literal(_ field: String) -> String {
        var s = Substring(field)
        guard let open = s.firstIndex(of: "\"") else { return field.trimmingCharacters(in: .whitespaces) }
        s = s[s.index(after: open)...]
        guard let close = s.lastIndex(of: "\"") else { return String(s) }
        return String(s[..<close])
    }

    // MARK: - WordNet index parse
    // Each data line: `lemma pos synset_cnt p_cnt [ptr...] sense_cnt
    // tagsense_cnt synset_offset...`. The last `synset_cnt` tokens are the
    // offsets, in frequency order. License-header lines start with a space.
    // Synset ID is `<offset>-<pos>` to match Wikidata P8814.
    private static func parseWordNet(_ dictDir: String) throws -> [(lemma: String, synsetID: String, senseIndex: Int)] {
        let files = ["index.noun", "index.verb", "index.adj", "index.adv"]
        var out: [(String, String, Int)] = []
        for file in files {
            let path = (dictDir as NSString).appendingPathComponent(file)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix(" ") { continue }
                let f = line.split(separator: " ").map(String.init)
                guard f.count >= 4, let synsetCnt = Int(f[2]), synsetCnt > 0, f.count >= synsetCnt else { continue }
                let lemma = f[0]
                if lemma.contains("_") { continue }            // multi-word lemma
                let pos = f[1]
                for (idx, off) in f.suffix(synsetCnt).enumerated() {
                    out.append((lemma, "\(off)-\(pos)", idx))
                }
            }
        }
        return out
    }
}
