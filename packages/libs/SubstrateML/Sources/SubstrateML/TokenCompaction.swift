// TokenCompaction.swift
//
// The token-compaction transform (SPEC_DISTILLATION_STORAGE §7.6) and the
// token-count estimator (§6). ONE pure transform, two uses:
//
//   • the short-item distillation path (§7.5) — items under 3 sentences
//     get their distilled rendering by compacting the content directly;
//   • the tokenized-on-read hydration variants (§10.1) —
//     `content_tokenized` / `distilled_tokenized` are computed at
//     retrieval time by this same transform and never stored.
//
// The matrix-path Stage 5 rendering (§7.4) also compacts each unit
// sentence through this transform.
//
// DETERMINISM CONTRACT (§5.3 rule 6): given the same input string the
// output is byte-identical across runs and bit-identical between this
// implementation and the Rust twin (token_compaction.rs). Everything here
// is fixed-table, integer, and ASCII-case arithmetic — no locale, no ICU,
// no Foundation string APIs whose behavior could differ across platforms.
// Conformance vectors: TokenCompactionConformanceTests (Swift) and
// token_compaction_conformance.rs (Rust) assert identical outputs.
//
// FORMAT RULES implemented (SPEC §5.3, priority order):
//   1. Propositional fidelity — negation and quantifiers ALWAYS survive
//      (they are never in the drop tables); entities, numbers, units,
//      dates pass through verbatim (a token containing a digit or an
//      uppercase first letter never matches the lowercase drop tables).
//   2. Stopword/filler removal — a fixed, deliberately CONSERVATIVE list:
//      only words whose removal cannot flip or ambiguate a proposition
//      (articles, intensifier fillers, pleasantries, bare present
//      copulas). Ambiguous words ("well", "just", "mean") are excluded
//      because they have noun/adjective readings rule 1 protects.
//   3. Dense wording — a fixed phrase-rewrite table (longest match wins).
//      Perfect-passive auxiliaries compress ("has been moved" → "moved");
//      tense-CHANGING rewrites (e.g. "will be" → "") are deliberately
//      absent because rule 1 outranks rule 3.
//   4. Minimal markup — decorative Unicode punctuation normalizes to
//      ASCII; no markdown is produced.
//   5. Single spacing — whitespace runs collapse; a dropped token's
//      trailing clause punctuation migrates to the previous token so
//      clause structure survives.

import Foundation

/// The Phase 1 distillation format + pipeline contract identifier
/// (SPEC §4). Stored in `distilled_pipeline_version`; a row whose stored
/// value differs from this constant is a regeneration candidate for the
/// sweep. Bump this string whenever the rendering contract changes
/// (compaction tables, Stage 5 ordering, estimator formula) — stored
/// renderings regenerate lazily against the new contract.
public enum DistillationPipelineVersion {
    /// Phase 1 contract: TokenCompaction tables v1 + Stage 5 core-first
    /// ordering + the (3B + 16W + 12)/24 token estimator, all pinned to
    /// `DistillationPipeline.defaultExtractor` (the extractor present and
    /// bit-identical on both legs).
    public static let current = "p1"
}

/// The §7.6 token-compaction transform and §6 token estimator. No
/// instances — a namespace of pure functions.
public enum TokenCompaction {

    // MARK: - Fixed tables (v1 — changing ANY entry is a pipeline-version bump)

    /// Single-word drops (rule 2), matched against the lowercase word core.
    /// Conservative by construction: articles, unambiguous intensifier
    /// fillers, pleasantries, discourse adverbs, and the bare present
    /// copulas. NO negations, NO quantifiers, NO modality words
    /// (maybe/might/possibly change a proposition's force and stay),
    /// NO past copulas (was/were carry tense).
    static let stopwords: Set<String> = [
        // articles
        "a", "an", "the",
        // intensifier fillers
        "really", "very", "quite", "actually", "basically", "literally",
        "honestly", "frankly",
        // discourse
        "anyway",
        // pleasantries
        "please",
        // bare present copulas (identity/property assertions keep their
        // meaning telegraphically: "color is blue" → "color blue")
        "is", "are", "am",
    ]

    /// Multi-word rewrites (rule 3), matched on lowercase word cores,
    /// longest match first at each position. Replacement words are
    /// emitted lowercase; sentence recapitalization repairs casing.
    /// An empty replacement drops the phrase (perfect-passive
    /// auxiliaries, filler idioms).
    static let phrases: [(match: [String], replacement: [String])] = [
        (["due", "to", "the", "fact", "that"], ["because"]),
        (["at", "this", "point", "in", "time"], ["now"]),
        (["in", "the", "event", "that"], ["if"]),
        (["as", "a", "result", "of"], ["because", "of"]),
        (["with", "regard", "to"], ["regarding"]),
        (["in", "order", "to"], ["to"]),
        (["make", "sure", "to"], []),
        (["has", "been"], []),
        (["have", "been"], []),
        (["had", "been"], []),
        (["kind", "of"], []),
        (["sort", "of"], []),
        (["of", "course"], []),
    ]

    /// ASCII clause punctuation that migrates when its carrier token drops.
    private static let clausePunctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]

    // MARK: - compact

    /// Apply the §7.6 transform. Pure; deterministic; Rust-bit-identical.
    public static func compact(_ text: String) -> String {
        // Rule 4: normalize decorative Unicode punctuation to ASCII first
        // so the tokenizer and tables see one spelling.
        let normalized = normalizeUnicodePunctuation(text)

        // Rule 5: tokenize on any whitespace run (spaces, tabs, newlines,
        // blank-line runs all collapse).
        let tokens = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return "" }

        // Word cores (lowercased, ASCII case fold only) for table matching.
        let cores = tokens.map { lowercaseCore(of: $0) }

        var out: [String] = []
        var i = 0
        while i < tokens.count {
            // Rule 3: longest phrase match at this position.
            if let (matchLen, replacement) = phraseMatch(cores: cores, at: i) {
                // Trailing clause punctuation of the LAST matched token
                // survives the rewrite (the clause boundary is real content).
                let trailing = trailingPunctuation(of: tokens[i + matchLen - 1])
                if replacement.isEmpty {
                    migrate(punctuation: trailing, onto: &out)
                } else {
                    var words = replacement
                    words[words.count - 1] += trailing
                    out.append(contentsOf: words)
                }
                i += matchLen
                continue
            }
            // Rule 2: single-word drop, guarded by rule 1 (a token whose
            // core contains a digit or an uppercase letter never matches
            // the lowercase tables, so numbers/dates/entities survive).
            if stopwords.contains(cores[i]) {
                migrate(punctuation: trailingPunctuation(of: tokens[i]), onto: &out)
                i += 1
                continue
            }
            out.append(tokens[i])
            i += 1
        }

        // Rule 5: single spaces; then repair sentence-initial casing that
        // article drops exposed ("the plan works." → "plan works." →
        // "Plan works."). ASCII-only uppercase so both legs agree.
        return recapitalizeSentences(out.joined(separator: " "))
    }

    // MARK: - estimateTokenCount (§6)

    /// Approximate BPE token count of `text` on cl100k-class vocabularies
    /// for English-dominant prose. Integer fixed-point blend of the two
    /// classic estimators (bytes/4 and words*4/3), averaged and rounded:
    ///
    ///     est = (3*B + 16*W + 12) / 24     (integer division)
    ///
    /// where B = UTF-8 byte count and W = whitespace-separated word count.
    /// Chosen because dense stopword-stripped prose runs closer to one
    /// token per word than chars/4 alone predicts; the blend lands within
    /// the ±20% §6 accuracy target on the conformance corpus. Advisory
    /// only — never load-bearing. Bit-identical in the Rust twin (pure
    /// integer arithmetic).
    public static func estimateTokenCount(_ text: String) -> Int64 {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return 0 }
        let bytes = Int64(text.utf8.count)
        let wordCount = Int64(words.count)
        return (3 * bytes + 16 * wordCount + 12) / 24
    }

    // MARK: - Internals

    /// Fixed decorative-Unicode → ASCII map (rule 4). Only unambiguous
    /// typographic variants are mapped; everything else passes through.
    static func normalizeUnicodePunctuation(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "\u{2018}", "\u{2019}", "\u{201B}": out.append("'")
            case "\u{201C}", "\u{201D}", "\u{201F}": out.append("\"")
            case "\u{2013}", "\u{2014}", "\u{2015}": out.append("-")
            case "\u{2026}": out.append("...")
            case "\u{00A0}", "\u{2007}", "\u{202F}": out.append(" ")
            default: out.append(ch)
            }
        }
        return out
    }

    /// The token's word core: leading/trailing ASCII punctuation stripped,
    /// ASCII letters lowercased (ASCII-only fold — no locale). Internal
    /// apostrophes/hyphens stay, so "doesn't" cores to "doesn't" and never
    /// matches a drop table (negation survival, rule 1).
    static func lowercaseCore(of token: String) -> String {
        let scalars = Array(token.unicodeScalars)
        var start = 0
        var end = scalars.count
        while start < end, isStrippablePunct(scalars[start]) { start += 1 }
        while end > start, isStrippablePunct(scalars[end - 1]) { end -= 1 }
        var out = String.UnicodeScalarView()
        for s in scalars[start..<end] {
            if s.value >= 65 && s.value <= 90 { // A-Z → a-z
                out.append(Unicode.Scalar(s.value + 32)!)
            } else {
                out.append(s)
            }
        }
        return String(out)
    }

    /// ASCII punctuation strippable at token edges for core extraction.
    private static func isStrippablePunct(_ s: Unicode.Scalar) -> Bool {
        switch s {
        case ".", ",", ";", ":", "!", "?", "\"", "'", "(", ")", "[", "]",
             "{", "}", "-", "*", "_", "`":
            return true
        default:
            return false
        }
    }

    /// The token's trailing run of clause punctuation (".,;:!?").
    private static func trailingPunctuation(of token: String) -> String {
        var suffix = ""
        for ch in token.reversed() {
            if clausePunctuation.contains(ch) {
                suffix.insert(ch, at: suffix.startIndex)
            } else {
                break
            }
        }
        return suffix
    }

    /// Migrate a dropped token's trailing clause punctuation onto the
    /// previous emitted token — unless it already ends with clause
    /// punctuation (no doubling, rule 5) or there is no previous token.
    private static func migrate(punctuation: String, onto out: inout [String]) {
        guard !punctuation.isEmpty, let last = out.last, let lastChar = last.last,
              !clausePunctuation.contains(lastChar) else { return }
        out[out.count - 1] += punctuation
    }

    /// Uppercase the character at each sentence start IF it is an ASCII
    /// lowercase letter — the repair for casing that article drops expose
    /// ("the plan works." → "plan works." → "Plan works."). A sentence
    /// start is the beginning of the string, or the first non-whitespace
    /// character after a sentence terminator. A terminator is ".", "!",
    /// or "?" followed by whitespace/end — but NOT a dot inside an
    /// ellipsis ("wait... done" does not start a new sentence) and NOT a
    /// dot inside a number ("3.5"). A boundary whose first character is
    /// not a lowercase ASCII letter (a quote, a digit, an entity already
    /// capitalized) is left untouched. ASCII-only case arithmetic so both
    /// legs agree byte-for-byte.
    static func recapitalizeSentences(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        var atSentenceStart = true
        for i in 0..<scalars.count {
            let s = scalars[i]
            let isWhitespace = s == " " || s == "\t" || s == "\n" || s == "\r"
            if atSentenceStart && !isWhitespace {
                if s.value >= 97 && s.value <= 122 { // a-z
                    scalars[i] = Unicode.Scalar(s.value - 32)! // → A-Z
                }
                atSentenceStart = false
            }
            // Terminator detection with look-around: ".", "!", "?" ends a
            // sentence only when followed by whitespace or end-of-string,
            // and a "." preceded by another "." is an ellipsis member,
            // not a terminator.
            if s == "." || s == "!" || s == "?" {
                let followedByBreak = i + 1 == scalars.count
                    || scalars[i + 1] == " " || scalars[i + 1] == "\t"
                    || scalars[i + 1] == "\n" || scalars[i + 1] == "\r"
                let ellipsisMember = s == "." && i > 0 && scalars[i - 1] == "."
                if followedByBreak && !ellipsisMember {
                    atSentenceStart = true
                }
            }
        }
        var out = String.UnicodeScalarView()
        for s in scalars { out.append(s) }
        return String(out)
    }

    /// Longest phrase-table match at token position `i`, or nil.
    private static func phraseMatch(
        cores: [String], at i: Int
    ) -> (length: Int, replacement: [String])? {
        var best: (length: Int, replacement: [String])? = nil
        for (match, replacement) in phrases {
            let len = match.count
            guard i + len <= cores.count else { continue }
            guard best == nil || len > best!.length else { continue }
            var matched = true
            for k in 0..<len where cores[i + k] != match[k] {
                matched = false
                break
            }
            if matched {
                best = (len, replacement)
            }
        }
        return best
    }
}
