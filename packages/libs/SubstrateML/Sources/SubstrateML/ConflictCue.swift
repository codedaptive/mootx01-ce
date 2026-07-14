// ConflictCue.swift
//
// Deterministic pairwise text-conflict screen — the substrate-owned
// primitive behind the contradiction hunter (dreaming's content-driven
// phase and the `moot_hunt_contradictions` sweep).
//
// Given two content strings, answer: do these look like the SAME claim
// in tension — one negating, contradicting, or superseding the other?
// The screen runs on candidate pairs the vector index already found to
// be semantically close, so its job is precision, not recall: fire only
// on cheap, explainable lexical evidence and leave paraphrased
// contradictions to the BYOAI client's judgment (the borderline band).
//
// THREE CUES, checked strongest-first:
//
//   1. valueDivergence — the two token streams are the same template
//      differing ONLY in value-bearing positions (tokens containing a
//      digit): "meeting at 3pm" vs "meeting at 5pm", "timeout is 30s"
//      vs "timeout is 90s", "shipped in 1.0.29" vs "shipped in 1.0.30".
//      Same sentence shape + different values is the highest-precision
//      contradiction signal available lexically.
//
//   2. negationAsymmetry — the two strings say substantially the same
//      thing (high shingle similarity AFTER negation cues are removed)
//      but exactly one side carries a negation cue: "X lives in Paris"
//      vs "X does not live in Paris", "the flag is enabled" vs "the
//      flag is no longer enabled".
//
//   3. markerRevision — one side carries an explicit revision/
//      supersession marker (deprecated, superseded, replaced, instead
//      of, moved to, ...) over substantially similar content: "use the
//      staging endpoint" vs "the staging endpoint is deprecated".
//
// DETERMINISM AND CONFORMANCE. Pure function of the two input strings —
// no locale-sensitive transforms beyond ASCII-safe lowercasing, no
// stemming, no randomness, no clock. Scores derive from
// `ShingleSimilarity` (already conformance-gated to f32 bit-identity)
// and integer ratios, so results are bit-identical across the Swift and
// Rust ports; mirrored test vectors pin both legs to the same
// (kind, score) outputs.
//
// TOKENIZER CONTRACT (mirrored exactly in Rust): lowercase the input,
// then a token is a maximal run of [a-z0-9.]; leading/trailing '.' are
// trimmed from each token (so "paris." → "paris" but "1.0.30" stays
// whole). Tokens that become empty after trimming are dropped.
//
// Used by:
//   GeniusLocusKit ContradictionScoutSignal — dreaming's content phase
//   AriaMcpKit moot_hunt_contradictions — the on-demand sweep

import Foundation

/// The kind of lexical conflict evidence found between two strings.
public enum ConflictCueKind: String, Sendable, Equatable {
    /// Same token template, differing only in digit-bearing positions.
    case valueDivergence = "value_divergence"
    /// Same content with a negation cue on exactly one side.
    case negationAsymmetry = "negation_asymmetry"
    /// Revision/supersession marker over substantially similar content.
    case markerRevision = "marker_revision"
    /// No conflict evidence.
    case none = "none"
}

/// Result of a pairwise conflict screen: the strongest cue found and a
/// confidence score in [0, 1]. `kind == .none` always carries score 0.
public struct ConflictCueResult: Sendable, Equatable {
    public let kind: ConflictCueKind
    public let score: Float
    public init(kind: ConflictCueKind, score: Float) {
        self.kind = kind
        self.score = score
    }
}

/// Deterministic pairwise text-conflict screen. See the file header for
/// the cue taxonomy and the tokenizer contract.
public enum ConflictCue {

    /// Score at or above which a cue is STRONG evidence — the hunter
    /// auto-proposes a `contradicts` tunnel (lifecycle `.proposed`, still
    /// user-reviewable; this is a proposal threshold, not a verdict).
    public static let strongThreshold: Float = 0.70

    /// Score at or above which (but below `strongThreshold`) a cue is
    /// BORDERLINE — surfaced as a candidate pair for the BYOAI client to
    /// adjudicate, never auto-proposed.
    public static let borderlineThreshold: Float = 0.45

    /// Standalone negation cue tokens. Deliberately excludes bare "no"
    /// (too common in benign contexts); contractions arrive as token
    /// PAIRS under the tokenizer contract and live in
    /// `negationBigrams`.
    static let negationTokens: Set<String> = [
        "not", "never", "without", "stopped", "cannot",
    ]

    /// Negation cue bigrams (adjacent token pairs after tokenizing).
    /// Contractions split at the apostrophe — "isn't" tokenizes to
    /// ("isn", "t") — plus the "no longer" phrase.
    static let negationBigrams: Set<String> = [
        "isn t", "aren t", "wasn t", "weren t", "won t", "don t",
        "doesn t", "didn t", "couldn t", "shouldn t", "wouldn t",
        "hasn t", "haven t", "no longer",
    ]

    /// Revision/supersession marker tokens.
    static let markerTokens: Set<String> = [
        "deprecated", "superseded", "replaced", "obsolete", "reverted",
        "cancelled", "canceled", "renamed", "retracted",
    ]

    /// Revision/supersession marker bigrams.
    static let markerBigrams: Set<String> = [
        "instead of", "moved to", "changed to", "switched to",
    ]

    /// Tokenize per the mirrored contract: lowercase; maximal runs of
    /// [a-z0-9.]; trim leading/trailing '.'; drop empties.
    ///
    /// Iterates at the Unicode SCALAR level (not grapheme cluster) so that
    /// a character like U+0130 İ — which lowercases to "i" + U+0307
    /// (combining dot above) — does not swallow the combining mark into
    /// an ASCII token. Rust mirrors this via `chars()` + `is_ascii_*`,
    /// which also operates at scalar level; the two legs are now
    /// byte-identical for all inputs. See conflict_cue.rs `tokenize`.
    static func tokenize(_ s: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        // REQUIRED: locale-independent lowercased() — lowercased(with: Locale.current) maps I→ı in Turkish/Azeri, breaking Rust cross-leg determinism. Never change.
        for scalar in s.lowercased().unicodeScalars {
            let v = scalar.value
            // ASCII lowercase a–z (0x61–0x7A), digits 0–9 (0x30–0x39), dot (0x2E).
            // Mirrors Rust: ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '.'
            if (v >= 97 && v <= 122) || (v >= 48 && v <= 57) || v == 46 {
                current.append(Character(scalar))
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.compactMap { raw in
            var t = Substring(raw)
            while t.first == "." { t = t.dropFirst() }
            while t.last == "." { t = t.dropLast() }
            return t.isEmpty ? nil : String(t)
        }
    }

    /// Count negation cues in a token stream (standalone tokens plus
    /// bigrams). A bigram consumes its tokens so "no longer" counts once
    /// and the bare "longer" never counts.
    static func negationCount(_ tokens: [String]) -> Int {
        var count = 0
        var i = 0
        while i < tokens.count {
            if i + 1 < tokens.count,
               negationBigrams.contains("\(tokens[i]) \(tokens[i + 1])") {
                count += 1
                i += 2
                continue
            }
            if negationTokens.contains(tokens[i]) { count += 1 }
            i += 1
        }
        return count
    }

    /// True when the token stream carries a revision marker (standalone
    /// or bigram).
    static func hasMarker(_ tokens: [String]) -> Bool {
        var i = 0
        while i < tokens.count {
            if i + 1 < tokens.count,
               markerBigrams.contains("\(tokens[i]) \(tokens[i + 1])") {
                return true
            }
            if markerTokens.contains(tokens[i]) { return true }
            i += 1
        }
        return false
    }

    /// Remove negation cues from a token stream so the underlying-claim
    /// similarity is measured without the negation itself dragging it
    /// down (a bigram removes both of its tokens).
    static func stripNegation(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < tokens.count {
            if i + 1 < tokens.count,
               negationBigrams.contains("\(tokens[i]) \(tokens[i + 1])") {
                i += 2
                continue
            }
            if negationTokens.contains(tokens[i]) {
                i += 1
                continue
            }
            out.append(tokens[i])
            i += 1
        }
        return out
    }

    /// Evaluate the conflict screen over two content strings. Returns the
    /// strongest cue found (checked valueDivergence → negationAsymmetry →
    /// markerRevision) with its score, or `.none` with score 0.
    public static func evaluate(_ a: String, _ b: String) -> ConflictCueResult {
        let tokensA = tokenize(a)
        let tokensB = tokenize(b)
        guard !tokensA.isEmpty, !tokensB.isEmpty else {
            return ConflictCueResult(kind: .none, score: 0)
        }
        // Identical claims are agreement, not conflict.
        guard tokensA != tokensB else {
            return ConflictCueResult(kind: .none, score: 0)
        }

        // ── Cue 1: value divergence ────────────────────────────────────
        // Same-length streams of ≥ 4 tokens whose differing positions ALL
        // carry a digit. Score: fraction of shared template, so a single
        // changed value in a long sentence scores near 1.
        if tokensA.count == tokensB.count, tokensA.count >= 4 {
            var diffs = 0
            var allDiffsAreValues = true
            for (ta, tb) in zip(tokensA, tokensB) where ta != tb {
                diffs += 1
                let bothCarryDigit =
                    ta.contains(where: { $0.isNumber }) && tb.contains(where: { $0.isNumber })
                if !bothCarryDigit { allDiffsAreValues = false }
            }
            if diffs > 0, allDiffsAreValues {
                let score = Float(tokensA.count - diffs) / Float(tokensA.count)
                return ConflictCueResult(kind: .valueDivergence, score: score)
            }
        }

        // Underlying-claim similarity with negation cues stripped, so the
        // negation itself does not depress the overlap it is evidence for.
        let strippedA = stripNegation(tokensA).joined(separator: " ")
        let strippedB = stripNegation(tokensB).joined(separator: " ")
        let claimSimilarity = ShingleSimilarity.similarity(strippedA, strippedB)

        // ── Cue 2: negation asymmetry ──────────────────────────────────
        let negatedA = negationCount(tokensA) > 0
        let negatedB = negationCount(tokensB) > 0
        if negatedA != negatedB, claimSimilarity >= borderlineThreshold {
            return ConflictCueResult(kind: .negationAsymmetry, score: claimSimilarity)
        }

        // ── Cue 3: revision marker ─────────────────────────────────────
        if hasMarker(tokensA) != hasMarker(tokensB),
           claimSimilarity >= borderlineThreshold {
            return ConflictCueResult(kind: .markerRevision, score: claimSimilarity)
        }

        return ConflictCueResult(kind: .none, score: 0)
    }
}
