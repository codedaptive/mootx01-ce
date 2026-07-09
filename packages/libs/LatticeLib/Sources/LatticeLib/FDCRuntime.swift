// FDCRuntime.swift
//
// The runtime FDC entry point: loads the bundled pinned artifacts (the
// canonicalization lexicon, the FDC frame, and the compact code signatures)
// once per process and exposes `FDC.encode(text) -> code`. This is what
// consumers (EideticLib and above) call to classify text.
//
// The bundled compact v2 signatures retain code-owned label, alias, title, and
// article terms separately from inherited ancestor terms. Classifier v4 fuses
// that hierarchy-first policy with portable integer semantic evidence.

import Foundation

public enum FDC {

    /// Pinned descent cutoff (cookbook §6.1), value `1`. Tuned empirically: a
    /// sweep over 1...200 produced identical results on the v1.0 frame, so the
    /// cutoff is inert here — the frame is shallow (most codes are integer-head,
    /// average encoded depth ~1.3), so Step-5 descent rarely fires. `1` is the
    /// pinned ship value; classification accuracy is governed by within-region
    /// scoring (§5), not this cutoff.
    public static let stopThreshold = 1

    /// Encode `text` to an FDC code. Nonempty text without defensible subject
    /// evidence returns `000`; `nil` is reserved for empty input or unavailable
    /// bundled artifacts. Pure over the pinned artifacts.
    public static func encode(_ text: String) -> String? { bundle?.matcher.encode(text) }

    /// Explicit-tagger variant used by cross-runtime conformance tests and
    /// estates that pin novel-token classification policy.
    public static func encode(
        _ text: String,
        taggerChoice: NovelTokenTaggerChoice
    ) -> String? {
        bundle?.matcher.encode(text, taggerChoice: taggerChoice)
    }

    /// Encode `text` and surface the dominant concept Q-ID of the input (see
    /// `FDCMatcher.encodeAnchor`). Returns `(nil, nil)` if the artifacts are
    /// unavailable. This is the entry point EideticLib uses to fill an Anchor.
    public static func encodeAnchor(_ text: String) -> (code: String?, conceptQID: String?) {
        bundle?.matcher.encodeAnchor(text) ?? (nil, nil)
    }

    /// Non-recording variant of `encodeAnchor` (secfix/fdc-pool).
    ///
    /// Identical result to `encodeAnchor(_:)` — the FDC code and Q-ID are
    /// byte-for-byte the same. Novel tokens encountered during concept-bag
    /// construction are NOT accumulated into `sharedNovelCache`, so user-memory
    /// content classified here does not leak plaintext tokens to the pool
    /// pipeline. Pass `recordNovel: false` from the GLK capture seam
    /// (`EideticLib.lookup(_:recordNovel:)`) and its Rust equivalent.
    ///
    /// Mirrors Rust `Fdc::encode_anchor_no_record` in fdc_runtime.rs.
    public static func encodeAnchor(_ text: String, recordNovel: Bool) -> (code: String?, conceptQID: String?) {
        bundle?.matcher.encodeAnchor(text, recordNovel: recordNovel) ?? (nil, nil)
    }

    /// True when the bundled artifacts loaded and the engine is ready.
    public static var isAvailable: Bool { bundle != nil }

    /// The bundled signatures version — the pinned-artifact version that
    /// produced an encode answer. Callers record it as provenance.
    public static var dataVersion: String { bundle?.version ?? "0.0.0-unavailable" }

    /// Deterministic semantic candidates from the bundled micro-ranker. This
    /// surface exposes model evidence for diagnostics and conformance; FDC's
    /// hierarchy policy remains responsible for the final stored code.
    public static func semanticCandidates(
        _ text: String,
        limit: Int = 8
    ) -> [FDCSemanticCandidate] {
        bundle?.semanticRanker.rank(text, limit: limit) ?? []
    }

    public static var semanticModelVersion: String {
        bundle?.semanticRanker.metadata.version ?? "0.0.0-unavailable"
    }

    public static var semanticModelSHA256: String {
        bundle?.semanticRanker.metadata.modelSHA256 ?? "unavailable"
    }

    /// Confidence-gated semantic hierarchy evidence used by classifier v4.
    public static func semanticDecision(_ text: String) -> FDCSemanticDecision? {
        guard let bundle else { return nil }
        return bundle.semanticRanker.hierarchyDecision(text, frame: bundle.frame)
    }

    /// Version of the deterministic classifier algorithm itself.
    public static let classifierVersion = "4.0.0"

    /// Estate-wide recalculation floor. This covers every input that can change
    /// an assigned code: algorithm, frame, lexicon, and signatures.
    public static var recalculationVersion: String {
        guard let bundle else { return "fdc-unavailable" }
        return "classifier:\(classifierVersion)|frame:\(bundle.frame.frameVersion)" +
            "|lexicon:\(bundle.lexiconVersion)|signatures:\(bundle.version)" +
            "|semantic:\(bundle.semanticRanker.metadata.version):" +
            bundle.semanticRanker.metadata.modelSHA256
    }

    /// Ancestor chain (root first, excluding `code` itself) for an FDC code,
    /// walked over the bundled frame's decimal hierarchy. Empty if the artifacts
    /// are unavailable or if `code` is the root "000". Mirrors Rust `Fdc::ancestors`
    /// in fdc_runtime.rs.
    ///
    /// Delegates to `FDCFrame.ancestors(of:)` (already public) — the math lives
    /// in LatticeLib, not in consumers. This façade accessor allows consumers such
    /// as CorpusKitProviders to use the FDC ancestor chain without reaching past the
    /// runtime bundle into `FDCFrame` directly.
    ///
    /// - Parameter code: An FDC decimal code, e.g. "547.7".
    /// - Returns: The ancestor chain root-first, e.g. ["000", "500", "540", "547"].
    public static func ancestors(of code: String) -> [String] {
        bundle?.frame.ancestors(of: code) ?? []
    }

    /// Return the human-readable heading label for a classification code, or
    /// `nil` if the code is not in the frame (UNRESOLVED, empty, or the
    /// artifacts are unavailable). Used by dashboard surfaces to display
    /// readable names next to raw lattice address codes.
    ///
    /// Every code resolves to its OWN frame label — never an ancestor's.
    /// Sibling codes must stay distinguishable when listed together: the
    /// lattice address table shows runs of active siblings (651, 652, 657 …),
    /// and any coarsening to a shared parent heading renders them as identical
    /// rows that read as duplicated data. The frame ships a distinct label per
    /// code (e.g. "651" → "Office management", "657" → "Accounting +
    /// Bookkeeping"); multi-term compounds like "683" → "Firearms +
    /// Locksmithing" are shown as-is.
    ///
    /// Mirrors Rust `Fdc::label()` in fdc_runtime.rs.
    public static func label(for code: String) -> String? {
        guard !code.isEmpty, let frame = bundle?.frame else { return nil }
        return frame.codes.first(where: { $0.code == code })?.label
    }

    // MARK: - artifact loading (once per process)

    private struct SignaturesFile: Decodable {
        struct Entry: Decodable {
            let code: String
            let terms: [String]?
            let labelTerms: [String]?
            let aliasTerms: [String]?
            let titleTerms: [String]?
            let articleTerms: [String]?
            let ancestorTerms: [String]?

            private enum CodingKeys: String, CodingKey {
                case code, terms
                case labelTerms = "label_terms"
                case aliasTerms = "alias_terms"
                case titleTerms = "title_terms"
                case articleTerms = "article_terms"
                case ancestorTerms = "ancestor_terms"
            }
        }
        let version: String
        let codes: [Entry]
    }

    /// The matcher, the FDC frame (for label lookup), and the signatures
    /// version, all loaded together once per process.
    private static let bundle: (
        matcher: FDCMatcher,
        semanticRanker: FDCSemanticRanker,
        frame: FDCFrame,
        version: String,
        lexiconVersion: String
    )? = {
        guard let lexicon: CanonicalizationLexicon = load("Lexicon"),
              let frame: FDCFrame = load("FDCFrame"),
              let sigs: SignaturesFile = load("FDCSignatures"),
              let semanticMetadata = loadData("FDCSemanticRanker", extension: "json"),
              let semanticModel = loadData("FDCSemanticRanker", extension: "bin"),
              let semanticRanker = FDCSemanticRanker(
                metadataData: semanticMetadata, modelData: semanticModel) else { return nil }
        var terms: [String: Set<String>] = [:]
        var sources: [String: FDCSignatureSources] = [:]
        for e in sigs.codes {
            var recallTerms = Set(e.terms ?? [])
            recallTerms.formUnion(e.labelTerms ?? [])
            recallTerms.formUnion(e.aliasTerms ?? [])
            recallTerms.formUnion(e.titleTerms ?? [])
            recallTerms.formUnion(e.articleTerms ?? [])
            recallTerms.formUnion(e.ancestorTerms ?? [])
            terms[e.code] = recallTerms
            sources[e.code] = FDCSignatureSources(
                label: Set(e.labelTerms ?? []),
                alias: Set(e.aliasTerms ?? []),
                title: Set(e.titleTerms ?? []),
                article: Set(e.articleTerms ?? []))
        }
        // The runtime ships `.idf` scoring (Mission #4): IDF-weighting the
        // overlap — penalizing concept terms common across many signatures,
        // rewarding distinctive ones — improved within-region code selection
        // over raw overlap (exact 31→36%, wrong-branch 63→58% on the v1.0
        // frame). The matcher default stays `.raw`; the runtime opts in here.
        let m = FDCMatcher(lexicon: lexicon, frame: frame, signatures: terms,
                           sourceSignatures: sources,
                           stopThreshold: stopThreshold, scoreMode: .idf,
                           useHierarchicalResolution: true,
                           semanticRanker: semanticRanker)
        return (m, semanticRanker, frame, sigs.version, lexicon.version)
    }()

    private static func load<T: Decodable>(_ name: String) -> T? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func loadData(_ name: String, extension fileExtension: String) -> Data? {
        guard let url = Bundle.module.url(forResource: name, withExtension: fileExtension) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }
}
