// Stemmer.swift
//
// Snowball English stemmer (Porter2 / English Snowball
// algorithm). Hand-ported from the canonical Snowball-language
// source published by the Snowball project. Conformance-gated
// against the reference test corpus shipped at
// Resources/SnowballEnglish.json: both this Swift port and the
// Rust port (via the `rust-stemmers` crate) MUST produce
// byte-identical stems for every input in that corpus.
//
// ALGORITHM
//
// Porter2 (also called "English Snowball") is the successor to
// Porter's 1980 stemmer, published by Martin Porter in 2001.
// It removes English suffixes via five steps, each applied
// once in order:
//
//   Step 1a: handle plural and possessive endings
//   Step 1b: handle past tense and gerund endings
//   Step 1c: handle terminal y
//   Step 2:  handle common derivational suffixes (-ization,
//            -ational, etc.)
//   Step 3:  handle other derivational suffixes
//   Step 4:  remove residual long suffixes
//   Step 5:  final cleanup (terminal e, doubled l)
//
// The algorithm operates on "regions" R1 and R2 of the word,
// defined as the substrings after the first and second
// vowel-consonant transitions. Most suffix removals only
// apply when the suffix lies in R1 or R2.
//
// Two exception lists handle words the algorithm would
// otherwise mishandle: a step-0 list of irregular forms
// (e.g. "skis" -> "ski" but "skies" -> "sky"), and a
// special-stem list for words where Porter2 produces a
// known-wrong stem.
//
// REFERENCES
//
// The canonical Snowball source:
//   https://snowballstem.org/algorithms/english/stemmer.html
//
// Porter's 2001 paper:
//   "Snowball: A language for stemming algorithms"
//   https://snowballstem.org/texts/introduction.html

import Foundation

public enum Stemmer {

    /// Bundled reference corpus for the Snowball English
    /// stemmer, exposed for the conformance test that
    /// verifies the Swift implementation matches the Rust
    /// port byte-for-byte.
    public static func bundledReferenceCorpus() -> Data? {
        guard let url = Bundle.module.url(
            forResource: "SnowballEnglish",
            withExtension: "json"
        ) else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// Stem an English word using the Snowball Porter2
    /// algorithm. Returns the stem (lowercased). Determinism
    /// is structural: the algorithm has no random or
    /// time-dependent components.
    public static func stem(_ token: String) -> String {
        if token.isEmpty { return token }

        // Snowball spec: words of fewer than 3 letters are
        // returned unchanged (case preserved).
        if token.count < 3 { return token }

        // Lowercase and convert to a mutable character array.
        var w = Array(token.lowercased())

        // Exception 0: irregular forms that the algorithm
        // would otherwise mishandle. Handled before any
        // suffix removal.
        if let exception = irregularExceptions[String(w)] {
            return exception
        }

        // Pre-processing: handle leading apostrophe and y.
        w = preprocess(w)

        // Compute R1 and R2.
        let r1 = computeR1(w)
        let r2 = computeR2(w, r1: r1)

        // Apply each step.
        w = step0(w)
        w = step1a(w)

        // Exception 2: words for which step 1a's output is
        // the final stem (rare; Snowball spec includes this
        // as the "invariant after step 1a" list).
        if invariantAfterStep1a.contains(String(w)) {
            return String(w)
        }

        w = step1b(w, r1: r1)
        w = step1c(w)
        w = step2(w, r1: r1)
        w = step3(w, r1: r1, r2: r2)
        w = step4(w, r2: r2)
        w = step5(w, r1: r1, r2: r2)

        // Restore Y to y (we converted vowel-position Y to a
        // capital marker during preprocess).
        return String(w).replacingOccurrences(of: "Y", with: "y")
    }

    // MARK: - Vowel helpers

    /// Snowball treats 'y' as a vowel when preceded by a
    /// consonant. The preprocess pass marks such Ys with an
    /// uppercase 'Y' marker so the algorithm can treat them
    /// uniformly as vowels in region computation.
    private static func isVowel(_ c: Character) -> Bool {
        return "aeiouy".contains(c) || c == "Y"
    }

    /// Preprocess: drop a leading apostrophe and mark
    /// consonant-Y patterns by uppercasing the Y.
    private static func preprocess(_ chars: [Character]) -> [Character] {
        var w = chars
        if w.first == "'" { w.removeFirst() }
        if w.first == "y" { w[0] = "Y" }
        for i in 1..<w.count {
            if w[i] == "y" && !isVowel(w[i - 1]) {
                w[i] = "Y"
            }
        }
        return w
    }

    /// R1 is the region after the first non-vowel following
    /// a vowel, or the empty region at the end of the word
    /// if no such position exists. Snowball special-cases
    /// "gener", "commun", and "arsen" as having R1 fixed
    /// after that prefix.
    private static func computeR1(_ chars: [Character]) -> Int {
        let s = String(chars)
        for prefix in ["gener", "commun", "arsen"] {
            if s.hasPrefix(prefix) { return prefix.count }
        }
        return regionStart(chars, from: 0)
    }

    /// R2 is the region after the first non-vowel following
    /// a vowel within R1.
    private static func computeR2(_ chars: [Character], r1: Int) -> Int {
        return regionStart(chars, from: r1)
    }

    private static func regionStart(_ chars: [Character], from: Int) -> Int {
        guard from < chars.count else { return chars.count }
        var i = from
        // Find a vowel.
        while i < chars.count && !isVowel(chars[i]) { i += 1 }
        // Find a non-vowel after it.
        while i < chars.count && isVowel(chars[i]) { i += 1 }
        if i < chars.count { return i + 1 }
        return chars.count
    }

    // MARK: - Suffix helpers

    private static func endsWith(_ chars: [Character], _ suffix: String) -> Bool {
        if suffix.count > chars.count { return false }
        let sChars = Array(suffix)
        let offset = chars.count - sChars.count
        for i in 0..<sChars.count {
            if chars[offset + i] != sChars[i] { return false }
        }
        return true
    }

    private static func replaceSuffix(
        _ chars: [Character],
        _ suffix: String,
        with replacement: String
    ) -> [Character] {
        var w = chars
        let count = suffix.count
        w.removeLast(count)
        w.append(contentsOf: replacement)
        return w
    }

    private static func suffixInRegion(
        _ chars: [Character],
        _ suffix: String,
        region: Int
    ) -> Bool {
        guard endsWith(chars, suffix) else { return false }
        return chars.count - suffix.count >= region
    }

    // MARK: - Steps

    /// Step 0: drop possessive endings.
    private static func step0(_ chars: [Character]) -> [Character] {
        for suffix in ["'s'", "'s", "'"] {
            if endsWith(chars, suffix) {
                var w = chars
                w.removeLast(suffix.count)
                return w
            }
        }
        return chars
    }

    /// Step 1a: handle plural and possessive endings.
    private static func step1a(_ chars: [Character]) -> [Character] {
        if endsWith(chars, "sses") {
            return replaceSuffix(chars, "sses", with: "ss")
        }
        if endsWith(chars, "ied") || endsWith(chars, "ies") {
            let suffix = endsWith(chars, "ied") ? "ied" : "ies"
            // "ied" / "ies" of length > 4 becomes -i, else -ie.
            if chars.count > suffix.count + 1 {
                return replaceSuffix(chars, suffix, with: "i")
            }
            return replaceSuffix(chars, suffix, with: "ie")
        }
        if endsWith(chars, "ss") || endsWith(chars, "us") {
            return chars
        }
        if endsWith(chars, "s") {
            // Drop s only if the word contains a vowel before
            // the last letter.
            if chars.count >= 3 {
                let prefix = chars.dropLast(2)
                if prefix.contains(where: isVowel) {
                    var w = chars
                    w.removeLast()
                    return w
                }
            }
        }
        return chars
    }

    /// Step 1b: handle past tense and gerund endings.
    private static func step1b(_ chars: [Character], r1: Int) -> [Character] {
        // The eed/eedly rule preempts ed/ing: even if eed/
        // eedly is NOT in R1, the word is left unchanged.
        // This is critical for words like "feed" where the
        // ed suffix would otherwise be incorrectly stripped.
        if endsWith(chars, "eedly") {
            if chars.count - 5 >= r1 {
                return replaceSuffix(chars, "eedly", with: "ee")
            }
            return chars
        }
        if endsWith(chars, "eed") {
            if chars.count - 3 >= r1 {
                return replaceSuffix(chars, "eed", with: "ee")
            }
            return chars
        }

        for suffix in ["ingly", "edly", "ing", "ed"] {
            if endsWith(chars, suffix) {
                let stemLen = chars.count - suffix.count
                let stem = Array(chars[..<stemLen])
                if stem.contains(where: isVowel) {
                    var w = stem
                    if w.count >= 2 {
                        let last2 = String(w.suffix(2))
                        if ["at", "bl", "iz"].contains(last2) {
                            w.append("e")
                            return w
                        }
                        if isDoubleConsonant(w) {
                            w.removeLast()
                            return w
                        }
                    }
                    if isShortWord(w) {
                        w.append("e")
                    }
                    return w
                }
                return chars
            }
        }
        return chars
    }

    /// Step 1c: terminal Y -> i if preceded by a consonant
    /// and the word is at least 3 characters long.
    private static func step1c(_ chars: [Character]) -> [Character] {
        if chars.count < 3 { return chars }
        let last = chars.last!
        if last == "y" || last == "Y" {
            let prev = chars[chars.count - 2]
            if !isVowel(prev) {
                var w = chars
                w[w.count - 1] = "i"
                return w
            }
        }
        return chars
    }

    /// Step 2: common derivational suffixes.
    private static let step2Rules: [(String, String)] = [
        ("ational", "ate"), ("tional", "tion"), ("enci", "ence"),
        ("anci", "ance"), ("abli", "able"), ("entli", "ent"),
        ("izer", "ize"), ("ization", "ize"), ("ation", "ate"),
        ("ator", "ate"), ("alism", "al"), ("aliti", "al"),
        ("alli", "al"), ("fulness", "ful"), ("ousli", "ous"),
        ("ousness", "ous"), ("iveness", "ive"), ("iviti", "ive"),
        ("biliti", "ble"), ("bli", "ble"), ("ogi", "og"),
        ("fulli", "ful"), ("lessli", "less"),
    ]

    private static func step2(_ chars: [Character], r1: Int) -> [Character] {
        // Special: "logi" rule requires preceding "l".
        if suffixInRegion(chars, "logi", region: r1) {
            if chars.count >= 5 && chars[chars.count - 5] == "l" {
                return replaceSuffix(chars, "logi", with: "log")
            }
        }
        // Special: "li" rule requires preceding valid li-ending.
        if suffixInRegion(chars, "li", region: r1) {
            if chars.count >= 3 {
                let prev = chars[chars.count - 3]
                if "cdeghkmnrt".contains(prev) {
                    var w = chars
                    w.removeLast(2)
                    return w
                }
            }
        }
        for (suffix, replacement) in step2Rules {
            if suffixInRegion(chars, suffix, region: r1) {
                return replaceSuffix(chars, suffix, with: replacement)
            }
        }
        return chars
    }

    /// Step 3: other derivational suffixes.
    private static let step3Rules: [(String, String)] = [
        ("ational", "ate"), ("tional", "tion"), ("alize", "al"),
        ("icate", "ic"), ("iciti", "ic"), ("ical", "ic"),
        ("ful", ""), ("ness", ""),
    ]

    private static func step3(_ chars: [Character], r1: Int, r2: Int) -> [Character] {
        for (suffix, replacement) in step3Rules {
            if suffixInRegion(chars, suffix, region: r1) {
                return replaceSuffix(chars, suffix, with: replacement)
            }
        }
        if suffixInRegion(chars, "ative", region: r2) {
            var w = chars
            w.removeLast(5)
            return w
        }
        return chars
    }

    /// Step 4: residual long suffixes (R2 region only).
    private static let step4Suffixes: [String] = [
        "ement", "ance", "ence", "able", "ible", "ment",
        "ant", "ent", "ism", "ate", "iti", "ous", "ive",
        "ize", "al", "er", "ic",
    ]

    private static func step4(_ chars: [Character], r2: Int) -> [Character] {
        // Snowball longest-match rule: find the longest
        // matching suffix from the table; if it's in R2,
        // strip it; if not, leave the word unchanged. NO
        // fall-through to shorter suffixes.
        var longest: String? = nil
        for suffix in step4Suffixes {
            if endsWith(chars, suffix) {
                if longest == nil || suffix.count > longest!.count {
                    longest = suffix
                }
            }
        }
        // The "ion" rule (requires preceding s or t) is
        // checked separately because it has a constraint
        // the table can't express.
        if endsWith(chars, "ion") {
            if longest == nil || "ion".count > longest!.count {
                if chars.count >= 4 {
                    let prev = chars[chars.count - 4]
                    if prev == "s" || prev == "t" {
                        longest = "ion"
                    }
                }
            }
        }
        guard let suffix = longest else { return chars }
        let start = chars.count - suffix.count
        if start >= r2 {
            var w = chars
            w.removeLast(suffix.count)
            return w
        }
        return chars
    }

    /// Step 5: final cleanup. Drop terminal e in R2, or in R1
    /// when the preceding word is not short. Drop terminal
    /// double-l in R2.
    private static func step5(_ chars: [Character], r1: Int, r2: Int) -> [Character] {
        var w = chars
        if w.last == "e" {
            if chars.count - 1 >= r2 {
                w.removeLast()
            } else if chars.count - 1 >= r1 && !endsWithShortSyllable(Array(chars.dropLast())) {
                w.removeLast()
            }
        } else if w.last == "l" && chars.count >= r2 + 1 {
            if chars.count >= 2 && chars[chars.count - 2] == "l" {
                w.removeLast()
            }
        }
        return w
    }

    // MARK: - Syllable helpers

    /// A short syllable per Snowball: a vowel followed by a
    /// non-vowel non-w-x-Y at the end of the word, OR a
    /// vowel-non-vowel pair at the start of the word.
    private static func endsWithShortSyllable(_ chars: [Character]) -> Bool {
        if chars.count < 2 { return false }
        let n = chars.count
        let last = chars[n - 1]
        let secondLast = chars[n - 2]
        if n == 2 {
            // (vowel)(non-vowel) at start of word.
            return isVowel(secondLast) && !isVowel(last)
        }
        // (non-vowel)(vowel)(non-vowel-w-x-Y).
        let thirdLast = chars[n - 3]
        if "wxY".contains(last) { return false }
        return !isVowel(thirdLast) && isVowel(secondLast) && !isVowel(last)
    }

    private static func isShortWord(_ chars: [Character]) -> Bool {
        // Short word: R1 is at or after the end AND ends in
        // a short syllable.
        let r1 = computeR1(chars)
        if r1 < chars.count { return false }
        return endsWithShortSyllable(chars)
    }

    private static func isDoubleConsonant(_ chars: [Character]) -> Bool {
        guard chars.count >= 2 else { return false }
        let n = chars.count
        let last = chars[n - 1]
        let prev = chars[n - 2]
        if last != prev { return false }
        return "bdfgmnprt".contains(last)
    }

    // MARK: - Exception lists

    /// Words for which the algorithm produces an
    /// algorithmically-correct-but-semantically-wrong stem,
    /// and the desired stem. From the Snowball spec.
    private static let irregularExceptions: [String: String] = [
        "skis": "ski",
        "skies": "sky",
        "dying": "die",
        "lying": "lie",
        "tying": "tie",
        "idly": "idl",
        "gently": "gentl",
        "ugly": "ugli",
        "early": "earli",
        "only": "onli",
        "singly": "singl",
        "sky": "sky",
        "news": "news",
        "howe": "howe",
        "atlas": "atlas",
        "cosmos": "cosmos",
        "bias": "bias",
        "andes": "andes",
    ]

    /// Words that are invariant after step 1a (no further
    /// stemming applied).
    private static let invariantAfterStep1a: Set<String> = [
        "inning", "outing", "canning", "herring",
        "earring", "proceed", "exceed", "succeed",
    ]
}
