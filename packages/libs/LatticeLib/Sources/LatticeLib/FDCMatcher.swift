// FDCMatcher.swift
//
// FDC runtime encoder, Steps 4–5 (cookbook §5–§6): match an input text's
// concept bag against the code signatures, then descend the decimal frame to
// the most specific well-supported code.
//
//   Step 4 (§5.2/§5.3): score[code] += bag[term] for every term shared with
//                       the code's signature (inverted-index single-pass scan,
//                       the deterministic equivalent of the spec's Aho-Corasick
//                       scan over concept-id keys). Empty score -> UNRESOLVED.
//   Step 5 (§6):        start at argmax(score) (ties -> lowest code), then walk
//                       down children while a child's bag overlap meets
//                       STOP_THRESHOLD; return the deepest such code.
//
// `encode` is a pure function of the input text and the pinned artifacts
// (lexicon, signatures, frame) — the agreement property.
//
// PERFORMANCE — String→Int term interning (#31 Phase 2):
// The codebook (sigTerms / index / idf) is built once at init from the pinned
// FDCSignatures.json and never mutated. Every term in the signatures is
// assigned a dense integer id at init (ascending String order so Int sort ==
// String sort, preserving all deterministic sort operations). The per-call hot
// path (encodeFromBag → score / rawOverlap) then operates on Int-keyed
// structures, eliminating the per-lookup String.hash / Hasher.combine / dict
// find that appeared as the dominant hot frame in the profiler on a 49k-drawer
// palace import.

import Foundation

/// Source-owned signature terms for one FDC code. These remain separate at
/// runtime so label/title/article evidence can be weighted without treating
/// inherited ancestor terms as proof for a narrow heading.
public struct FDCSignatureSources: Sendable {
    public let label: Set<String>
    public let alias: Set<String>
    public let title: Set<String>
    public let article: Set<String>

    public init(label: Set<String>, alias: Set<String>, title: Set<String>, article: Set<String>) {
        self.label = label
        self.alias = alias
        self.title = title
        self.article = article
    }
}

public struct FDCMatcher: Sendable {

    /// How the per-code overlap is turned into a score. The score function
    /// is applied CONSISTENTLY to both the Step-4 argmax and the Step-5
    /// descent overlap, so the descent target is always scored on the same
    /// footing as the argmax winner. The direct-construction default is
    /// `.raw`; `FDCRuntime` opts in to `.idf` (the shipped runtime mode).
    ///
    /// Over the membership signatures (a code's term SET) and the runtime bag
    /// (term -> count `n`), with overlap `O = bag ∩ sig`:
    ///   - `.raw`:       Σ_{t∈O} bag[t].                 (direct-init default)
    ///   - `.idf`:       Σ_{t∈O} bag[t]·idf(t).
    ///   - `.cosine`:    (Σ_{t∈O} bag[t]) / sqrt(|sig|).
    ///   - `.idfCosine`: (Σ_{t∈O} bag[t]·idf(t)) / sqrt(Σ_{t∈sig} idf(t)²).
    /// where idf(t) = ln(N / df(t)), N = total code signatures, df(t) = number
    /// of signatures containing t. The bag-side norm is constant across codes
    /// for a fixed query, so it is dropped from both `.cosine` and `.idfCosine`
    /// (it cannot change any argmax or descent comparison); the signature-side
    /// norm — what actually penalizes big signatures — is kept.
    public enum ScoreMode: Sendable {
        case raw, idf, cosine, idfCosine
    }

    /// Pinned descent cutoff (§6.1), default `1` (any overlap continues
    /// descent). Tuned empirically: inert across 1...200 on the v1.0 frame
    /// (shallow frame — descent rarely fires), so `1` is the pinned ship value.
    /// Accuracy is governed by within-region scoring (§5), not this cutoff.
    ///
    /// NOTE: the cutoff is compared against the RAW integer overlap (Σ bag[t]),
    /// not the normalized score, so its meaning is mode-independent — a child
    /// must still carry at least `stopThreshold` matching bag occurrences to be
    /// a descent candidate regardless of `scoreMode`. The score (which may be
    /// normalized) only ranks the candidates that clear the cutoff.
    public let stopThreshold: Int

    /// The active scoring scheme (default `.raw` reproduces ship behavior).
    public let scoreMode: ScoreMode

    /// When true, production classification ranks source-owned evidence and
    /// returns the deepest supported common ancestor instead of allowing
    /// inherited/article recall terms to certify a narrow code.
    public let useHierarchicalResolution: Bool

    /// Optional portable semantic evidence. Directly constructed matchers keep
    /// v3 behavior unless a ranker is supplied; the bundled runtime enables it.
    private let semanticRanker: FDCSemanticRanker?

    private let lexicon: CanonicalizationLexicon
    private let frame: FDCFrame

    // MARK: - Interning table (#31 Phase 2)
    //
    // Terms are interned to dense Int ids once at init so encodeFromBag runs
    // Int-keyed lookups instead of String-keyed ones. The id assignment order
    // is ascending String order (alphabetical), which means Int sort order ==
    // String sort order — every `.sorted()` call on a Set<Int> of term ids
    // produces the same iteration sequence as `.sorted()` on the original
    // Set<String>. This is required to keep the floating-point summation order
    // for IDF-weighted scores bit-identical to the pre-interning implementation.

    /// term String → dense Int id. IDs are 0-based, contiguous, assigned in
    /// ascending String order so that Int-order and String-order are the same.
    private let termToID: [String: Int]

    // MARK: - Int-keyed internal structures (hot path)

    /// code → Set<TermID>. Replaces the old `sigTerms: [String: Set<String>]`.
    /// Membership check is O(1) via Set hash (Int hash is trivial), and the
    /// Set can be iterated in sorted TermID order (== String order) for the
    /// deterministic overlap filter in score().
    private let sigTermIDs: [String: Set<Int>]

    /// TermID → sorted [String] codes (inverted index). Replaces the old
    /// `index: [String: [String]]`. Key is a dense Int so dict find is a
    /// single integer hash.
    private let indexByID: [Int: [String]]

    /// TermID → idf value. Replaces the old `idf: [String: Double]`. Keyed
    /// by dense Int id; only the IDF and IdfCosine modes read this map.
    private let idfByID: [Int: Double]

    // MARK: - Code-keyed norm tables (unchanged from pre-interning)

    /// code → sqrt(|sig|) for `.cosine` mode. Keyed by code string (not term),
    /// so no interning benefit here — this map is read once per descent step,
    /// not once per term.
    private let sigNorm: [String: Double]

    /// code → sqrt(Σ idf(t)²) for `.idfCosine` mode. Summed in sorted TermID
    /// order (== sorted String order) to produce a bit-identical result to the
    /// pre-interning init.
    private let sigIDFNorm: [String: Double]

    private struct SourceTermIDs: Sendable {
        let label: [Int]
        let alias: [Int]
        let title: [Int]
        let article: [Int]

        var all: Set<Int> { Set(label).union(alias).union(title).union(article) }
    }

    /// Code-owned evidence retained from the source-separated artifact. Unlike `sigTermIDs`,
    /// this excludes inherited ancestor terms.
    private let sourceTermIDs: [String: SourceTermIDs]

    /// IDF computed over code-owned terms only. The legacy IDF table is built
    /// over flattened signatures and therefore cannot distinguish inherited
    /// evidence from a code's own subject evidence.
    private let ownIDFByID: [Int: Double]

    /// A term-interned bag: TermID → count. Used internally for all scoring
    /// operations. Built from a ConceptBag in `encodeFromBag` by looking up
    /// each term's dense integer id. Terms absent from the codebook have no id
    /// and are silently dropped (they cannot match any signature).
    private typealias InternedBag = [Int: Int]

    public init(
        lexicon: CanonicalizationLexicon,
        frame: FDCFrame,
        signatures: [String: Set<String>],
        sourceSignatures: [String: FDCSignatureSources] = [:],
        stopThreshold: Int = 1,
        scoreMode: ScoreMode = .raw,
        useHierarchicalResolution: Bool = false,
        semanticRanker: FDCSemanticRanker? = nil
    ) {
        self.lexicon = lexicon
        self.frame = frame
        self.stopThreshold = stopThreshold
        self.scoreMode = scoreMode
        self.useHierarchicalResolution = useHierarchicalResolution
        self.semanticRanker = semanticRanker

        // 1. Collect every unique term across all signatures, sort alphabetically,
        //    and assign a dense integer id. Ascending String order → Int order ==
        //    String order, so any `.sorted()` on a Set<Int> of term ids visits terms
        //    in the same sequence as `.sorted()` on the original Set<String>.
        var allTerms = Set<String>()
        for (_, terms) in signatures { allTerms.formUnion(terms) }
        for (_, sources) in sourceSignatures {
            allTerms.formUnion(sources.label)
            allTerms.formUnion(sources.alias)
            allTerms.formUnion(sources.title)
            allTerms.formUnion(sources.article)
        }
        let sortedTerms = allTerms.sorted()
        var termToID: [String: Int] = Dictionary(minimumCapacity: sortedTerms.count)
        for (id, term) in sortedTerms.enumerated() { termToID[term] = id }
        self.termToID = termToID

        // 2. Rebuild the signature term sets as Set<Int> (sigTermIDs).
        var sigTermIDs: [String: Set<Int>] = Dictionary(minimumCapacity: signatures.count)
        for (code, terms) in signatures {
            // Every term in `signatures` is in `termToID` by construction above,
            // so compactMap drops nothing here. The compactMap is defensive.
            sigTermIDs[code] = Set(terms.compactMap { termToID[$0] })
        }
        self.sigTermIDs = sigTermIDs

        // 3. Rebuild the inverted index as [Int: [String]] (indexByID).
        var idxByID: [Int: [String]] = [:]
        for (code, termIDs) in sigTermIDs {
            for id in termIDs { idxByID[id, default: []].append(code) }
        }
        // Sort each code list for deterministic scan order (same invariant as
        // the old `for k in idx.keys { idx[k]!.sort() }`).
        for id in idxByID.keys { idxByID[id]!.sort() }
        self.indexByID = idxByID

        // 4. Compute IDF over the code signatures.
        //    df(t) = # signatures containing t, N = total code signatures.
        //    idf(t) = ln(N / df(t)). A term in every signature carries idf 0.
        //    Stored as [Int: Double] keyed by TermID.
        var df: [String: Int] = [:]
        for (_, terms) in signatures { for t in terms { df[t, default: 0] += 1 } }
        let n = Double(signatures.count)
        var idfByID: [Int: Double] = Dictionary(minimumCapacity: df.count)
        for (t, d) in df {
            if let id = termToID[t] {
                idfByID[id] = d > 0 ? Foundation.log(n / Double(d)) : 0
            }
        }
        self.idfByID = idfByID

        // 5. Per-signature norms (the big-signature penalty).
        //    `.cosine`    divides by sqrt(|sig|).
        //    `.idfCosine` divides by the IDF-weighted L2 norm of the signature.
        //    A zero norm (empty sig or all-idf-0 terms) is stored as 0 and
        //    treated as "no division" at score time.
        //
        //    The IDF norm sum uses SORTED TermID order, which is identical to the
        //    pre-interning `terms.sorted()` String order (IDs assigned in ascending
        //    String order). This preserves bit-identical floating-point results:
        //    addition is non-associative, and Set iteration order is randomized.
        var normMap: [String: Double] = Dictionary(minimumCapacity: signatures.count)
        var idfNormMap: [String: Double] = Dictionary(minimumCapacity: signatures.count)
        for (code, terms) in signatures {
            normMap[code] = terms.count > 0 ? Foundation.sqrt(Double(terms.count)) : 0
            var ss = 0.0
            // Sort by TermID (== ascending String order) to match the pre-interning
            // `terms.sorted()` summation order for bit-identical IDF norms.
            let sortedIDs = (sigTermIDs[code] ?? []).sorted()
            for id in sortedIDs { let w = idfByID[id] ?? 0; ss += w * w }
            idfNormMap[code] = ss > 0 ? Foundation.sqrt(ss) : 0
        }
        self.sigNorm = normMap
        self.sigIDFNorm = idfNormMap

        var sourceIDs: [String: SourceTermIDs] = Dictionary(minimumCapacity: frame.codes.count)
        for (code, sources) in sourceSignatures {
            sourceIDs[code] = SourceTermIDs(
                label: sources.label.compactMap { termToID[$0] }.sorted(),
                alias: sources.alias.compactMap { termToID[$0] }.sorted(),
                title: sources.title.compactMap { termToID[$0] }.sorted(),
                article: sources.article.compactMap { termToID[$0] }.sorted())
        }

        var ownDF: [Int: Int] = [:]
        for sources in sourceIDs.values {
            for id in sources.all { ownDF[id, default: 0] += 1 }
        }
        let ownN = Double(max(sourceIDs.count, 1))
        var ownIDF: [Int: Double] = Dictionary(minimumCapacity: ownDF.count)
        for (id, count) in ownDF {
            ownIDF[id] = count > 0 ? Foundation.log(ownN / Double(count)) : 0
        }
        self.sourceTermIDs = sourceIDs
        self.ownIDFByID = ownIDF

    }

    /// Score `code`'s overlap with the interned `bag` under the active
    /// `scoreMode`. The numerator is summed over the overlap in SORTED TermID
    /// order, which (by the ascending-String-order ID assignment) is identical
    /// to the pre-interning sorted-String-term order — required for
    /// bit-reproducible IDF-weighted sums. Returns 0.0 when there is no overlap.
    ///
    /// Used for BOTH the Step-4 argmax and the Step-5 descent ranking so they
    /// stay on one footing. Mirrors the pre-interning `score(code:bag:)`.
    private func score(code: String, bag: InternedBag) -> Double {
        guard let termIDs = sigTermIDs[code] else { return 0 }
        // Collect the overlap in SORTED TermID order.
        // Int-order == String-order (IDs assigned in ascending String order),
        // so this is equivalent to the pre-interning `terms.filter{}.sorted()`.
        let overlap = termIDs.filter { bag[$0] != nil }.sorted()
        var num = 0.0
        switch scoreMode {
        case .raw, .cosine:
            // Raw numerator: Σ bag[t] over the overlap.
            for id in overlap { num += Double(bag[id]!) }
        case .idf, .idfCosine:
            // IDF-weighted numerator: Σ bag[t]·idf(t) over the overlap.
            for id in overlap { num += Double(bag[id]!) * (idfByID[id] ?? 0) }
        }
        switch scoreMode {
        case .raw, .idf:
            return num
        case .cosine:
            let d = sigNorm[code] ?? 0
            return d > 0 ? num / d : num
        case .idfCosine:
            let d = sigIDFNorm[code] ?? 0
            return d > 0 ? num / d : num
        }
    }

    /// The RAW integer overlap Σ bag[t] over (bag ∩ sig), used for the
    /// mode-independent descent cutoff comparison (see `stopThreshold`).
    /// Iterates the signature's TermID set and looks each up in the
    /// interned bag — O(K) where K is signature size (typically 5–20 terms).
    private func rawOverlap(code: String, bag: InternedBag) -> Int {
        guard let termIDs = sigTermIDs[code] else { return 0 }
        var o = 0
        for id in termIDs { if let n = bag[id] { o += n } }
        return o
    }

    private struct OwnedEvidence {
        let code: String
        let score: Double
        let distinctTerms: Int
        let trustedTerms: Int
        let sourceCount: Int
    }

    /// Score code-owned source evidence using term presence, not query term
    /// frequency. Repeating one word cannot increase either score or coverage.
    private func ownedEvidence(code: String, bag: InternedBag) -> OwnedEvidence {
        guard let sources = sourceTermIDs[code] else {
            return OwnedEvidence(
                code: code, score: 0, distinctTerms: 0, trustedTerms: 0, sourceCount: 0)
        }
        var score = 0.0
        var matched: Set<Int> = []
        var trusted: Set<Int> = []
        var matchedSources = 0

        func add(_ ids: [Int], weight sourceWeight: Double, trusted isTrusted: Bool) -> Bool {
            var found = false
            for id in ids where bag[id] != nil {
                let weight = ownIDFByID[id] ?? 0
                guard weight > 0 else { continue }
                score += sourceWeight * weight
                matched.insert(id)
                if isTrusted { trusted.insert(id) }
                found = true
            }
            return found
        }

        if add(sources.label, weight: 6, trusted: true) { matchedSources += 1 }
        if add(sources.alias, weight: 4, trusted: true) { matchedSources += 1 }
        if add(sources.title, weight: 3, trusted: true) { matchedSources += 1 }
        if add(sources.article, weight: 0.25, trusted: false) { matchedSources += 1 }
        return OwnedEvidence(
            code: code,
            score: score,
            distinctTerms: matched.count,
            trustedTerms: trusted.count,
            sourceCount: matchedSources)
    }

    private static func isMainClass(_ code: String) -> Bool {
        let chars = Array(code)
        return chars.count == 3
            && chars.allSatisfy { $0.isASCII && $0.isNumber }
            && chars[1] == "0" && chars[2] == "0"
    }

    private func precisionIsSupported(_ evidence: OwnedEvidence) -> Bool {
        let depth = frame.ancestors(of: evidence.code).count
        if depth <= 2 {
            return evidence.trustedTerms >= 1
                || evidence.distinctTerms >= 2
                || (Self.isMainClass(evidence.code) && evidence.distinctTerms >= 1)
        }
        return evidence.distinctTerms >= 2
            && evidence.trustedTerms >= 1
            && evidence.score >= Self.minimumTrustedEvidenceScore
    }

    private func broadFallback(for code: String) -> String {
        frame.ancestors(of: code)
            .reversed()
            .first(where: Self.isMainClass) ?? "000"
    }

    private func commonAncestor(_ lhs: String, _ rhs: String) -> String {
        let left = frame.ancestors(of: lhs) + [lhs]
        let right = frame.ancestors(of: rhs) + [rhs]
        var common = "000"
        for (a, b) in zip(left, right) {
            guard a == b else { break }
            common = a
        }
        return common
    }

    /// Fuse v3's source-owned lexical result with the semantic hierarchy
    /// decision. Agreement preserves v3's defensible precision. A confident
    /// disagreement replaces the result with the semantic safe ancestor and
    /// clears the QID so provenance from the rejected branch cannot leak into
    /// the stored anchor.
    private func fuseSemantic(
        _ result: (code: String?, conceptQID: String?),
        text: String,
        conceptBag: ConceptBag
    ) -> (code: String?, conceptQID: String?) {
        guard useHierarchicalResolution,
              let semanticRanker else {
            return result
        }
        let lexicalCode = result.code ?? "000"
        if lexicalCode != "000", hasReviewedAliasEvidence(for: lexicalCode, in: conceptBag) {
            return result
        }
        let candidates = semanticRanker.rank(text, limit: semanticRanker.metadata.codeCount)
        guard let decision = semanticRanker.hierarchyDecision(candidates, frame: frame) else {
            return result
        }
        let lexicalMain = Self.isMainClass(lexicalCode)
            ? lexicalCode
            : frame.ancestors(of: lexicalCode).reversed().first(where: Self.isMainClass) ?? "000"
        if lexicalCode != "000", lexicalMain == decision.mainClass {
            return result
        }
        if lexicalCode != "000",
           let top = candidates.first,
           let lexicalCandidate = candidates.first(where: { $0.code == lexicalCode }),
           lexicalCandidate.score * 3 >= top.score * 2 {
            return result
        }
        return (decision.code, nil)
    }

    private func hasReviewedAliasEvidence(for code: String, in bag: ConceptBag) -> Bool {
        guard let aliases = sourceTermIDs[code]?.alias, !aliases.isEmpty else { return false }
        for term in bag.keys {
            if let id = termToID[term], aliases.contains(id) { return true }
        }
        return false
    }

    /// Production v3 resolution: rank only code-owned evidence, require more
    /// than one distinct term before returning a narrow code, and fall back to
    /// the shared/supported parent when evidence is ambiguous or shallow.
    private func hierarchicalResolution(
        candidates: [String],
        bag: InternedBag,
        conceptBag: ConceptBag
    ) -> (code: String?, conceptQID: String?) {
        let ranked = candidates
            .map { ownedEvidence(code: $0, bag: bag) }
            .filter { $0.score > 0 }
            .sorted {
                if $0.trustedTerms != $1.trustedTerms { return $0.trustedTerms > $1.trustedTerms }
                if $0.distinctTerms != $1.distinctTerms { return $0.distinctTerms > $1.distinctTerms }
                if $0.sourceCount != $1.sourceCount { return $0.sourceCount > $1.sourceCount }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.code < $1.code
            }

        guard let winner = ranked.first else { return ("000", nil) }
        var chosen: String
        if precisionIsSupported(winner) {
            chosen = winner.code
        } else if winner.trustedTerms == 0 {
            chosen = "000"
        } else {
            chosen = broadFallback(for: winner.code)
        }

        if ranked.count > 1 {
            let runnerUp = ranked[1]
            if winner.trustedTerms == runnerUp.trustedTerms,
               winner.distinctTerms == runnerUp.distinctTerms,
               winner.score < runnerUp.score * Self.minimumBranchDominanceRatio {
                chosen = commonAncestor(winner.code, runnerUp.code)
            }
        }

        guard chosen != "000" else { return ("000", nil) }
        return (chosen, dominantQID(conceptBag, supporting: chosen, internedBag: bag))
    }

    /// Maximum number of codes that may share the argmax score while still
    /// yielding a classifiable result. When more codes than this are tied at
    /// the top IDF score, the query bag is dominated by common cross-domain
    /// vocabulary (low-IDF terms present in almost every signature) rather
    /// than subject-specific vocabulary. The tie-break (lowest code
    /// lexicographically) then selects an arbitrary code, not a semantically
    /// grounded one — that is a confidently-wrong specific code, which is
    /// worse than the honest "unclassified" sentinel "000".
    ///
    /// Calibration (v1.0 frame, 1 071 code signatures):
    ///   • subject-specific text (e.g. "biology / physiology"): ≤ 2 codes tied
    ///     at the top IDF score — the winning code is in the correct domain.
    ///   • software/technical text (e.g. "wings ADR pipeline"): 10–13 codes
    ///     tied — the "winner" is an arbitrary code in an unrelated domain
    ///     (235 = angels/devotional, 621.2 = hydraulic engineering, etc.).
    ///
    /// Setting the limit to 4 passes genuine subject-specific queries (≤ 2
    /// ties observed on the v1.0 frame) while correctly returning UNRESOLVED
    /// for technical/generic text that would otherwise get a confidently-wrong
    /// code. Mirrors Rust `FdcMatcher::MAX_TIED_WINNERS_FOR_CLASSIFICATION`.
    public static let maximumTiedWinnersForClassification: Int = 4

    /// Minimum summed IDF from trusted code-owned sources required to certify
    /// a displayable heading. This blocks one weak term such as
    /// "engineering" from dragging software/process text into steam engineering,
    /// while still allowing strong own-heading phrases like "blind"+"deaf" or
    /// "computer graphics".
    private static let minimumTrustedEvidenceScore = 2.5

    /// A branch must beat the next candidate by this ratio to retain its own
    /// precision. Otherwise the classifier returns their deepest common parent.
    private static let minimumBranchDominanceRatio = 1.15

    private static let shellCommandStarts: Set<String> = [
        "awk", "bash", "cargo", "chmod", "cp", "git", "grep", "jq", "mkdir",
        "mv", "node", "npm", "python", "python3", "rg", "rm", "sed", "set",
        "sh", "sqlite3", "swift", "xcodebuild", "yarn"
    ]

    private static let codeLikeSignals: [String] = [
        "```", "#!/", ".git/", "index.lock", "read_signal", " set -",
        "$(", "&&", "||", "==", "!=", "=>", "->", "{", "}", ";",
        "func ", "let ", "var ", "class ", "struct ", "enum ", "import ",
        "return ", "const ", "function "
    ]

    private static let codeSymbolCharacters: Set<Character> =
        Set("{}[]();=$|/\\<>")

    private static let sourceDeclarationModifiers: Set<String> = [
        "fileprivate", "final", "internal", "open", "override", "private",
        "public", "static"
    ]

    private static let sourceDeclarationStarts: [String] = [
        "class ", "const ", "enum ", "extension ", "func ", "function ",
        "import ", "interface ", "let ", "protocol ", "struct ",
        "typealias ", "var "
    ]

    /// Route non-prose fragments before lexical scoring: operational commands
    /// stay in Generalities (`000`), while recognizable source declarations use
    /// Computer programming (`005`) instead of an incidental topical heading.
    private static func specialClassification(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowered = trimmed.lowercased()

        if FDCCodeLanguageDetector.detect(in: trimmed) != nil {
            return "005"
        }
        if case .operational? = FDCCodeLanguageDetector.fencedHint(in: trimmed) {
            return "000"
        }

        if lowered.contains("#!/") ||
            lowered.contains(".git/") ||
            lowered.contains("index.lock") ||
            lowered.contains("read_signal") {
            return "000"
        }

        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var commandLineCount = 0
        for line in lines {
            let commandText = line.drop(while: { "$#>%".contains($0) || $0.isWhitespace })
            guard let first = commandText.split(whereSeparator: \.isWhitespace).first else { continue }
            let command = String(first)
                .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                .lowercased()
            if shellCommandStarts.contains(command) { commandLineCount += 1 }
        }
        if commandLineCount >= 2 || (commandLineCount == 1 && lines.count <= 6) {
            return "000"
        }
        if FDCCodeLanguageDetector.fencedHint(in: trimmed) != nil {
            return "005"
        }

        let declarationLineCount = lines.reduce(0) { count, line in
            var words = line.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            while let first = words.first,
                  sourceDeclarationModifiers.contains(
                    first.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
                  ) {
                words.removeFirst()
            }
            let body = words.joined(separator: " ")
            guard sourceDeclarationStarts.contains(where: body.hasPrefix) else { return count }
            let declaratorNeedsSyntax = body.hasPrefix("let ") || body.hasPrefix("var ") ||
                body.hasPrefix("const ")
            let functionNeedsSyntax = body.hasPrefix("func ") || body.hasPrefix("function ")
            if declaratorNeedsSyntax && !line.contains(":") && !line.contains("=") { return count }
            if functionNeedsSyntax && !line.contains("(") { return count }
            return count + 1
        }
        if declarationLineCount >= 2 {
            return "005"
        }

        let signalCount = codeLikeSignals.reduce(0) { count, signal in
            lowered.contains(signal) ? count + 1 : count
        }
        if signalCount >= 3 { return "005" }

        let nonWhitespaceCount = trimmed.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
        guard nonWhitespaceCount > 0 else { return nil }
        let symbolCount = trimmed.reduce(0) { codeSymbolCharacters.contains($1) ? $0 + 1 : $0 }
        let codeLike = lines.count >= 2 && signalCount >= 2 &&
            Double(symbolCount) / Double(nonWhitespaceCount) > 0.08
        return codeLike ? "005" : nil
    }


    /// Encode `text` to an FDC code. Hierarchy mode returns `000` for nonempty
    /// unresolved text; legacy matcher instances retain the `nil` behavior.
    public func encode(_ text: String) -> String? {
        encodeAnchor(text).code
    }

    public func encode(_ text: String, taggerChoice: NovelTokenTaggerChoice) -> String? {
        encodeAnchor(text, taggerChoice: taggerChoice).code
    }

    /// Encode `text` and also surface the dominant concept of the input.
    /// `code` is the FDC code (`000` = Generalities/unclassified in hierarchy
    /// mode). `conceptQID` is the
    /// highest-weighted Wikidata Q-ID in the concept bag — "what the text is
    /// most about" — or `nil` if the bag carries no Q-ID concept. One pass,
    /// so EideticLib fills an Anchor's code + wikidataQID without re-bagging.
    public func encodeAnchor(_ text: String) -> (code: String?, conceptQID: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, nil)
        }
        if let specialCode = Self.specialClassification(text) {
            return useHierarchicalResolution ? (specialCode, nil) : (nil, nil)
        }
        let bag = BagBuilder.bag(text, lexicon: lexicon)
        let result = fuseSemantic(encodeFromBag(bag), text: text, conceptBag: bag)
        return useHierarchicalResolution && result.code == nil ? ("000", nil) : result
    }

    public func encodeAnchor(
        _ text: String,
        taggerChoice: NovelTokenTaggerChoice
    ) -> (code: String?, conceptQID: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, nil)
        }
        if let specialCode = Self.specialClassification(text) {
            return useHierarchicalResolution ? (specialCode, nil) : (nil, nil)
        }
        let bag = BagBuilder.bag(text, lexicon: lexicon, taggerChoice: taggerChoice)
        let result = fuseSemantic(encodeFromBag(bag), text: text, conceptBag: bag)
        return useHierarchicalResolution && result.code == nil ? ("000", nil) : result
    }

    /// Non-recording variant of `encodeAnchor` (secfix/fdc-pool).
    ///
    /// Identical classification result to `encodeAnchor(_:)` — the FDC code
    /// and concept Q-ID are byte-for-byte the same. The only difference is that
    /// novel tokens encountered while building the concept bag are NOT accumulated
    /// into `sharedNovelCache`. Use this overload when `text` is user-supplied
    /// memory content that must not leak into the plaintext pool pipeline.
    ///
    /// Pass `recordNovel: false` to suppress accumulation. Pass `recordNovel: true`
    /// (or call the single-arg overload) to use the standard recording path.
    ///
    /// Mirrors Rust `FdcMatcher::encode_anchor_no_record` in fdc_matcher.rs.
    public func encodeAnchor(_ text: String, recordNovel: Bool) -> (code: String?, conceptQID: String?) {
        if recordNovel {
            // Delegate to the recording path — identical behaviour, no duplication.
            return encodeAnchor(text)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (nil, nil)
        }
        if let specialCode = Self.specialClassification(text) {
            return useHierarchicalResolution ? (specialCode, nil) : (nil, nil)
        }
        // Non-recording: build bag via the non-recording BagBuilder overload so
        // novel user-memory tokens never accumulate in sharedNovelCache.
        let bag = BagBuilder.bag(text, lexicon: lexicon, recordNovel: false)
        let result = fuseSemantic(encodeFromBag(bag), text: text, conceptBag: bag)
        return useHierarchicalResolution && result.code == nil ? ("000", nil) : result
    }

    /// Score a pre-built concept bag against the FDC signatures (Steps 4–5) and
    /// return the best matching code + dominant Q-ID.
    ///
    /// The bag must be fully constructed before calling this method; whether
    /// novel-token classification was recorded into the pool cache is the
    /// caller's responsibility. Both `encodeAnchor(_:)` and
    /// `encodeAnchor(_:recordNovel:)` delegate here so the scoring logic lives
    /// in exactly one place.
    ///
    /// Converts the String-keyed ConceptBag to an Int-keyed InternedBag once,
    /// then all scoring and overlap operations use Int-keyed lookups. Terms
    /// absent from the codebook (no TermID) are silently dropped from the
    /// interned bag — they cannot match any signature, identical to the
    /// pre-interning `index[term] == nil` skip.
    private func encodeFromBag(_ bag: ConceptBag) -> (code: String?, conceptQID: String?) {
        guard !bag.isEmpty else {
            return useHierarchicalResolution ? ("000", nil) : (nil, nil)
        }

        // Convert the String-keyed concept bag to an Int-keyed interned bag.
        // Terms absent from the codebook have no TermID and are silently
        // dropped — they match no signature entry, identical behaviour to the
        // pre-interning path (which skipped them via `index[term] == nil`).
        var internedBag: InternedBag = Dictionary(minimumCapacity: bag.count)
        for (term, count) in bag {
            if let id = termToID[term] { internedBag[id, default: 0] += count }
        }
        guard !internedBag.isEmpty else {
            return useHierarchicalResolution ? ("000", nil) : (nil, nil)
        }

        // Step 4 — match + score (§5.2/§5.3). The Int-keyed inverted index
        // gives the set of candidate codes (any code sharing ≥1 bag term); each
        // candidate is then scored under the active mode. For `.raw` the score
        // is exactly Σ bag[t] (integers held in Double — comparisons exact),
        // reproducing the shipped behavior bit-for-bit.
        var candidateSet: Set<String> = []
        for (termID, _) in internedBag {
            guard let codes = indexByID[termID] else { continue }
            for code in codes { candidateSet.insert(code) }
        }
        guard !candidateSet.isEmpty else {
            return useHierarchicalResolution ? ("000", nil) : (nil, nil)
        }

        // Sorted so the scan order is deterministic regardless of Set hashing.
        // This matters for the normalized modes: two codes can carry equal (or
        // float-rounding-equal) scores, and the lowest-code tie-break only
        // holds if the scan visits codes in a fixed order. The lowest code wins
        // ties here exactly as the `code < node` rule intends.
        let candidates = candidateSet.sorted()

        if useHierarchicalResolution {
            return hierarchicalResolution(candidates: candidates, bag: internedBag, conceptBag: bag)
        }

        var scoreByCode: [String: Double] = Dictionary(minimumCapacity: candidates.count)
        for code in candidates {
            scoreByCode[code] = score(code: code, bag: internedBag)
        }

        // argmax: highest score, ties broken by lowest code lexicographically.
        var node = ""
        var nodeScore = -Double.greatestFiniteMagnitude
        for code in candidates {
            let s = scoreByCode[code] ?? 0
            if s > nodeScore || (s == nodeScore && code < node) {
                node = code; nodeScore = s
            }
        }

        // Tie-count guard (§maximumTiedWinnersForClassification): when many
        // codes share the argmax score, the query bag is dominated by common
        // cross-domain Q-IDs with near-zero IDF weight. The tie-break
        // (lowest code) picks an arbitrary code rather than a semantically
        // grounded one — a confidently-wrong specific code is worse than the
        // honest "000" unclassified sentinel. UNRESOLVED when tied codes
        // exceed the allowed maximum.
        let tiedCount = candidates.filter { (scoreByCode[$0] ?? 0) == nodeScore }.count
        guard tiedCount <= Self.maximumTiedWinnersForClassification else {
            return (nil, nil)   // too many tied winners — no discriminating signal
        }

        // Step 5 — frame descent (§6.1). A child must clear the (raw) overlap
        // cutoff to be a candidate; among those, the highest mode score wins
        // (ties -> lowest code). Scoring the descent under the same mode as the
        // argmax keeps the two on one footing.
        while true {
            var best: String?
            var bestScore = 0.0
            for child in frame.children(of: node) {
                guard sigTermIDs[child.code] != nil else { continue }
                guard rawOverlap(code: child.code, bag: internedBag) >= stopThreshold else { continue }
                let s = score(code: child.code, bag: internedBag)
                if best == nil || s > bestScore || (s == bestScore && child.code < best!) {
                    best = child.code; bestScore = s
                }
            }
            guard let next = best else { break }
            node = next
        }
        return (node, dominantQID(bag, supporting: node, internedBag: internedBag))
    }

    /// The highest-count Wikidata Q-ID in `bag` that also supports the winning
    /// code (ties broken by lowest Q-ID lexicographically, so the result is
    /// deterministic regardless of the bag's dictionary iteration order). `nil`
    /// if the winner was not supported by a Q-ID term.
    ///
    /// This keeps concept provenance aligned with classification evidence:
    /// unresolved text returns no Q-ID, and a code never borrows an incidental
    /// Q-ID from another part of the bag.
    private func dominantQID(
        _ bag: ConceptBag,
        supporting code: String,
        internedBag: InternedBag
    ) -> String? {
        guard let supportingIDs = sigTermIDs[code] else { return nil }
        var best: String?
        var bestN = 0
        for (k, n) in bag where k.hasPrefix("Q") {
            guard let id = termToID[k],
                  supportingIDs.contains(id),
                  internedBag[id] != nil else { continue }
            if n > bestN || (n == bestN && (best == nil || k < best!)) {
                best = k; bestN = n
            }
        }
        return best
    }
}
