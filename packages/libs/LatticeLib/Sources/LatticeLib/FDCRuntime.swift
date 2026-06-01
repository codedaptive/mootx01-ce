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

    /// Pinned descent cutoff (cookbook §6.1). TODO: tune empirically against
    /// the real signatures; `1` is the testing default and MUST NOT ship as-is.
    public static let stopThreshold = 1

    /// Encode `text` to an FDC code, or `nil` for UNRESOLVED (or if the bundled
    /// artifacts are unavailable). Pure over the pinned artifacts.
    public static func encode(_ text: String) -> String? { matcher?.encode(text) }

    /// True when the bundled artifacts loaded and the engine is ready.
    public static var isAvailable: Bool { matcher != nil }

    // MARK: - artifact loading (once per process)

    private struct SignaturesFile: Decodable {
        struct Entry: Decodable { let code: String; let terms: [String] }
        let codes: [Entry]
    }

    private static let matcher: FDCMatcher? = {
        guard let lexicon: CanonicalizationLexicon = load("Lexicon"),
              let frame: FDCFrame = load("FDCFrame"),
              let sigs: SignaturesFile = load("FDCSignatures") else { return nil }
        var terms: [String: Set<String>] = [:]
        for e in sigs.codes { terms[e.code] = Set(e.terms) }
        return FDCMatcher(lexicon: lexicon, frame: frame, signatures: terms, stopThreshold: stopThreshold)
    }()

    private static func load<T: Decodable>(_ name: String) -> T? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
