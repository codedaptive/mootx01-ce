// FDCRuntime.swift
//
// The runtime FDC entry point: loads the bundled pinned artifacts (the
// canonicalization lexicon, the FDC frame, and the compact code signatures)
// once per process and exposes `FDC.encode(text) -> code`. This is what
// consumers (EideticLib and above) call to classify text.
//
// The bundled signatures are the *compact* form (code -> term list): the
// matcher uses only term membership (§5.2/§6), never the source weights, so
// the weighted FDCSignatures.json is kept only as a build/seed record (and for
// the future SimHash fingerprint).

import Foundation

public enum FDC {

    /// Pinned descent cutoff (cookbook §6.1), value `1`. Tuned empirically: a
    /// sweep over 1...200 produced identical results on the v1.0 frame, so the
    /// cutoff is inert here — the frame is shallow (most codes are integer-head,
    /// average encoded depth ~1.3), so Step-5 descent rarely fires. `1` is the
    /// pinned ship value; classification accuracy is governed by within-region
    /// scoring (§5), not this cutoff.
    public static let stopThreshold = 1

    /// Encode `text` to an FDC code, or `nil` for UNRESOLVED (or if the bundled
    /// artifacts are unavailable). Pure over the pinned artifacts.
    public static func encode(_ text: String) -> String? { bundle?.matcher.encode(text) }

    /// Encode `text` and surface the dominant concept Q-ID of the input (see
    /// `FDCMatcher.encodeAnchor`). Returns `(nil, nil)` if the artifacts are
    /// unavailable. This is the entry point EideticLib uses to fill an Anchor.
    public static func encodeAnchor(_ text: String) -> (code: String?, conceptQID: String?) {
        bundle?.matcher.encodeAnchor(text) ?? (nil, nil)
    }

    /// True when the bundled artifacts loaded and the engine is ready.
    public static var isAvailable: Bool { bundle != nil }

    /// The bundled signatures version — the pinned-artifact version that
    /// produced an encode answer. Callers record it as provenance.
    public static var dataVersion: String { bundle?.version ?? "0.0.0-unavailable" }

    /// Return the human-readable heading label for a classification code, or
    /// `nil` if the code is not in the frame (UNRESOLVED, empty, or the
    /// artifacts are unavailable). Used by dashboard surfaces to display
    /// readable names next to raw lattice address codes.
    ///
    /// For 3-digit integer codes (no decimal subdivision), the leaf label is
    /// often a compound of multiple subject terms joined with " + " (e.g.
    /// "683" → "Firearms + Locksmithing"). The parent code carries a broader,
    /// single-topic heading — walk up one level for these, so the dashboard
    /// shows "Handicraft" (680) rather than the raw multi-term cluster.
    /// Decimal codes retain their own specific label (e.g. "615.84" →
    /// "Radiology, Medical").
    ///
    /// Mirrors Rust `Fdc::label()` in fdc_runtime.rs.
    public static func label(for code: String) -> String? {
        guard !code.isEmpty, let frame = bundle?.frame else { return nil }
        // Decimal codes are already specific enough — use their own label.
        // 3-digit integer codes walk up one parent level for a cleaner heading.
        let lookup: String
        if !code.contains("."), let parent = FDCFrame.decimalParent(of: code) {
            lookup = parent
        } else {
            lookup = code
        }
        return frame.codes.first(where: { $0.code == lookup })?.label
    }

    // MARK: - artifact loading (once per process)

    private struct SignaturesFile: Decodable {
        struct Entry: Decodable { let code: String; let terms: [String] }
        let version: String
        let codes: [Entry]
    }

    /// The matcher, the FDC frame (for label lookup), and the signatures
    /// version, all loaded together once per process.
    private static let bundle: (matcher: FDCMatcher, frame: FDCFrame, version: String)? = {
        guard let lexicon: CanonicalizationLexicon = load("Lexicon"),
              let frame: FDCFrame = load("FDCFrame"),
              let sigs: SignaturesFile = load("FDCSignatures") else { return nil }
        var terms: [String: Set<String>] = [:]
        for e in sigs.codes { terms[e.code] = Set(e.terms) }
        // The runtime ships `.idf` scoring (Mission #4): IDF-weighting the
        // overlap — penalizing concept terms common across many signatures,
        // rewarding distinctive ones — improved within-region code selection
        // over raw overlap (exact 31→36%, wrong-branch 63→58% on the v1.0
        // frame). The matcher default stays `.raw`; the runtime opts in here.
        let m = FDCMatcher(lexicon: lexicon, frame: frame, signatures: terms,
                           stopThreshold: stopThreshold, scoreMode: .idf)
        return (m, frame, sigs.version)
    }()

    private static func load<T: Decodable>(_ name: String) -> T? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
