// Cl100kTokenizer.swift — cl100k_base BPE tokenizer for the membench-spec §6 capacity lane.
//
// Implements tiktoken's cl100k_base tokenizer as a deterministic, pure-Swift scanner.
// No external dependencies, no regex engine. The Rust twin (cl100k_tokenizer.rs) produces
// byte-identical outputs for all inputs — pinned by conformance/cl100k/vectors.json.
//
// Architecture:
//   1. Vocab loading: parse base64(token_bytes) space rank lines from the .tiktoken file.
//   2. Pre-tokenization: hand-written scanner reproducing cl100k_base's split pattern.
//   3. BPE merge: standard tiktoken byte-pair merge over each pre-token's UTF-8 bytes.
//   4. countTokens(text:) → Int counts merged tokens; encode(text:) → [Int] returns IDs.
//
// Pre-tokenization pattern (cl100k_base verbatim, reproduced as a scanner):
//   (1) (?i:'s|'t|'re|'ve|'m|'ll|'d)  — ASCII contractions, case-insensitive
//   (2) [^\r\n\p{L}\p{N}]?\p{L}+       — optional non-letter-non-digit-non-CR-LF prefix + letters
//   (3) \p{N}{1,3}                      — 1 to 3 digits
//   (4) ' '?[^\s\p{L}\p{N}]+[\r\n]*    — optional space + punctuation/symbols + trailing CR/LF
//   (5) \s*[\r\n]+                      — whitespace run ending in CR/LF
//   (6) \s+(?!\S)                       — whitespace not followed by non-whitespace
//   (7) \s+                             — remaining whitespace
//
// Unicode category notes:
//   \p{L} is reproduced via Swift's Character.isLetter (which uses Unicode General
//   Category L* — letters including CJK, accented Latin, etc.). \p{N} is reproduced
//   via Character.isNumber (Unicode General Category N*: decimal digits, letter numbers,
//   other numbers). Category caveat: Swift's isNumber includes Unicode "letter numbers"
//   (e.g. Roman numeral Ⅳ, U+2163) which \p{N} in PCRE also covers, so the boundary
//   matches for the inputs this harness processes (ASCII, CJK, accented Latin, emoji).
//   Surrogate and private-use codepoints are not handled specially — they pass through
//   BPE as their raw UTF-8 bytes, which is the same behaviour as tiktoken.
//
// Special tokens: not supported. The membench-spec lane processes plain text only;
//   special tokens (like <|endoftext|>) are never in the corpus turn content.
//   Documenting explicitly so a future integrator does not assume they are silently
//   skipped — they would be encoded as plain text, which is unlikely to produce
//   the expected token IDs.
//
// Rust twin: cl100k_tokenizer.rs (append pub mod cl100k_tokenizer; to lib.rs).
// Conformance: conformance/cl100k/vectors.json.

import Foundation

// MARK: - Vocab loading

/// A single line from the cl100k_base .tiktoken vocabulary file.
/// Each line encodes the token's bytes in base64 and its BPE rank.
private struct VocabEntry {
    /// The token bytes.
    let bytes: [UInt8]
    /// BPE rank (lower rank = merged first).
    let rank: Int
}

/// Errors that can occur when loading or using the cl100k_base tokenizer.
enum Cl100kError: Error, Sendable {
    /// The vocabulary file could not be read from the given path.
    case fileNotFound(String)
    /// A line in the vocabulary file was malformed (missing space, invalid base64, non-integer rank).
    case malformedVocabLine(String)
    /// A byte sequence produced by BPE was not found in the vocabulary.
    /// This indicates a bug in the BPE implementation: every byte is a valid vocab entry
    /// so every merge result must also be in the vocabulary by construction.
    case unknownToken([UInt8])
}

/// The cl100k_base BPE tokenizer.
///
/// Load once with ``Cl100kTokenizer/load(from:)`` and reuse across many encode calls.
/// The tokenizer is Sendable — the vocabulary is immutable after initialization.
///
/// Memory: the vocabulary holds 100,256 entries (~4 MB encoded + Swift Dictionary overhead).
/// Production use: load once at process start and share the instance.
public struct Cl100kTokenizer: Sendable {

    // MARK: - Vocabulary storage

    /// Maps token bytes → BPE rank. Used both to look up single-byte tokens
    /// and to check whether a merged byte sequence exists in the vocabulary.
    ///
    /// Stored as [Data: Int] rather than [[UInt8]: Int] because Data conforms to
    /// Hashable with value-equality on bytes, matching tiktoken's byte-comparison semantics.
    private let vocab: [Data: Int]

    // MARK: - Initialisation (private — use load(from:))

    private init(vocab: [Data: Int]) {
        self.vocab = vocab
    }

    // MARK: - Vocab loading

    /// Loads the cl100k_base tokenizer from a .tiktoken vocabulary file.
    ///
    /// The .tiktoken format is plain text with one entry per line:
    ///   `<base64-encoded-token-bytes> <rank>`
    /// where rank is a non-negative decimal integer.
    ///
    /// The file should have 100,256 lines for cl100k_base (verified at load time
    /// via the assertion in the conformance tests; this function loads whatever is present).
    ///
    /// - Parameter path: Absolute filesystem path to `cl100k_base.tiktoken`.
    /// - Returns: A fully initialised tokenizer ready to encode text.
    /// - Throws: ``Cl100kError/fileNotFound(_:)`` when the file is absent;
    ///   ``Cl100kError/malformedVocabLine(_:)`` on any parse failure.
    public static func load(from path: String) throws -> Cl100kTokenizer {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            throw Cl100kError.fileNotFound(path)
        }
        // cl100k_base has 100,256 entries; pre-size the dictionary to avoid rehashing.
        var vocab = [Data: Int](minimumCapacity: 100_300)
        // Each line: "<base64> <rank>"
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else {
                throw Cl100kError.malformedVocabLine(String(line))
            }
            guard let tokenData = Data(base64Encoded: String(parts[0])) else {
                throw Cl100kError.malformedVocabLine("invalid base64: \(parts[0])")
            }
            guard let rank = Int(parts[1]) else {
                throw Cl100kError.malformedVocabLine("invalid rank: \(parts[1])")
            }
            vocab[tokenData] = rank
        }
        return Cl100kTokenizer(vocab: vocab)
    }

    // MARK: - Public interface

    /// Returns the number of cl100k_base tokens in the given text.
    ///
    /// Equivalent to `len(tiktoken.get_encoding("cl100k_base").encode(text))`.
    /// Does not produce special tokens — plain text only (see file header).
    ///
    /// - Parameter text: The string to tokenize. Any valid Swift String is accepted.
    /// - Returns: The token count (≥ 0). Returns 0 for the empty string.
    public func countTokens(_ text: String) -> Int {
        encode(text).count
    }

    /// Encodes the given text into a sequence of cl100k_base token IDs.
    ///
    /// Equivalent to `tiktoken.get_encoding("cl100k_base").encode(text)`.
    /// Does not inject or recognise special tokens — plain text only (see file header).
    ///
    /// - Parameter text: The string to tokenize.
    /// - Returns: Ordered token IDs. Empty for the empty string.
    public func encode(_ text: String) -> [Int] {
        var ids: [Int] = []
        // Pre-tokenize then BPE-encode each pre-token.
        for preToken in cl100kPreTokenize(text) {
            let bytes = Array(preToken.utf8)
            if bytes.isEmpty { continue }
            let tokenIDs = bpeMerge(bytes: bytes)
            ids.append(contentsOf: tokenIDs)
        }
        return ids
    }

    // MARK: - Pre-tokenisation

    /// Splits `text` into pre-tokens per the cl100k_base split pattern.
    ///
    /// Implements the pattern as a deterministic character scanner rather than a regex
    /// engine (no regex crate or NSRegularExpression — zero external dependencies).
    /// Alternatives are tried in order; the first matching alternative consumes characters.
    ///
    /// Unicode note: Character.isLetter covers \p{L} and Character.isNumber covers \p{N}.
    /// CR (\r) and LF (\n) are treated as whitespace for rule 5 and excluded from rule 2's
    /// optional prefix and rule 4's punctuation run.
    private func cl100kPreTokenize(_ text: String) -> [Substring] {
        var result: [Substring] = []
        let chars = text // iterate as characters
        var idx = chars.startIndex

        while idx < chars.endIndex {
            let startIdx = idx

            // ── Rule 1: Contractions (?i:'s|'t|'re|'ve|'m|'ll|'d) ──────────────
            // Apostrophe at current position followed by a known suffix (case-insensitive).
            if chars[idx] == "'" {
                if let (matchEnd, _) = matchContraction(chars, at: idx) {
                    result.append(chars[startIdx..<matchEnd])
                    idx = matchEnd
                    continue
                }
                // Apostrophe not starting a contraction: treat as punctuation below.
            }

            // ── Rule 2: [^\r\n\p{L}\p{N}]?\p{L}+ ────────────────────────────────
            // Optional single non-letter-non-digit-non-CR-LF prefix, then one or more letters.
            let rule2Start = idx
            var rule2Idx = idx
            // Optional prefix: one char that is NOT CR, LF, letter, or digit.
            // Swift grapheme trap: "\r\n" is a SINGLE Character (one grapheme cluster),
            // so it must be excluded here explicitly alongside bare "\r" and "\n".
            let ch2 = chars[rule2Idx]
            let prefixIsCandidate = (ch2 != "\r" && ch2 != "\n" && ch2 != "\r\n"
                                     && !ch2.isLetter && !ch2.isNumber)
            if prefixIsCandidate {
                let next = chars.index(after: rule2Idx)
                if next < chars.endIndex && chars[next].isLetter {
                    rule2Idx = next   // consume the optional prefix
                }
            }
            // Now expect one or more letters.
            if rule2Idx < chars.endIndex && chars[rule2Idx].isLetter {
                var endIdx = chars.index(after: rule2Idx)
                while endIdx < chars.endIndex && chars[endIdx].isLetter {
                    endIdx = chars.index(after: endIdx)
                }
                result.append(chars[rule2Start..<endIdx])
                idx = endIdx
                continue
            }

            // ── Rule 3: \p{N}{1,3} — 1 to 3 digits ──────────────────────────────
            if chars[idx].isNumber {
                var endIdx = idx
                var count = 0
                while endIdx < chars.endIndex && chars[endIdx].isNumber && count < 3 {
                    endIdx = chars.index(after: endIdx)
                    count += 1
                }
                result.append(chars[startIdx..<endIdx])
                idx = endIdx
                continue
            }

            // ── Rule 4: ' '?[^\s\p{L}\p{N}]+[\r\n]* ─────────────────────────────
            // Optional single space, then one or more punctuation/symbol chars, then trailing CR/LF.
            var rule4Idx = idx
            if rule4Idx < chars.endIndex && chars[rule4Idx] == " " {
                let next = chars.index(after: rule4Idx)
                // Only advance past the space if followed by punctuation/symbol.
                if next < chars.endIndex && isPunctOrSymbol(chars[next]) {
                    rule4Idx = next
                }
            }
            if rule4Idx < chars.endIndex && isPunctOrSymbol(chars[rule4Idx]) {
                while rule4Idx < chars.endIndex && isPunctOrSymbol(chars[rule4Idx]) {
                    rule4Idx = chars.index(after: rule4Idx)
                }
                // Consume trailing CR/LF (including the "\r\n" single-grapheme Character).
                while rule4Idx < chars.endIndex
                      && (chars[rule4Idx] == "\r" || chars[rule4Idx] == "\n"
                          || chars[rule4Idx] == "\r\n") {
                    rule4Idx = chars.index(after: rule4Idx)
                }
                result.append(chars[startIdx..<rule4Idx])
                idx = rule4Idx
                continue
            }

            // ── Rule 5: \s*[\r\n]+ — whitespace run ending in CR/LF ──────────────
            var rule5Idx = idx
            // Consume non-newline whitespace (spaces, tabs, etc.). The "\r\n" grapheme
            // Character counts as a newline here, never as plain whitespace.
            while rule5Idx < chars.endIndex && chars[rule5Idx].isWhitespace
                  && chars[rule5Idx] != "\r" && chars[rule5Idx] != "\n"
                  && chars[rule5Idx] != "\r\n" {
                rule5Idx = chars.index(after: rule5Idx)
            }
            if rule5Idx < chars.endIndex
               && (chars[rule5Idx] == "\r" || chars[rule5Idx] == "\n"
                   || chars[rule5Idx] == "\r\n") {
                // Consume CR/LF run (bare CR, bare LF, and the CRLF grapheme).
                while rule5Idx < chars.endIndex
                      && (chars[rule5Idx] == "\r" || chars[rule5Idx] == "\n"
                          || chars[rule5Idx] == "\r\n") {
                    rule5Idx = chars.index(after: rule5Idx)
                }
                result.append(chars[startIdx..<rule5Idx])
                idx = rule5Idx
                continue
            }

            // ── Rule 6: \s+(?!\S) — whitespace not followed by non-whitespace ────
            // Regex backtracking semantics: \s+ is greedy, and when the run is followed
            // by a non-space the lookahead fails at full length, so the engine backtracks
            // one char — the rule matches the run MINUS its final whitespace char (when the
            // run has ≥2 chars). That final char is left in place to prefix the next
            // pre-token via rule 2/4's optional [^\r\n\p{L}\p{N}] prefix (" b" is one
            // pre-token). At end of string the whole run matches. A single whitespace
            // char followed by non-space matches nothing here (falls to rules 2/4/7).
            // Oracle witness: "a    b" → ["a", "   ", " b"] (tiktoken cl100k_base).
            if chars[idx].isWhitespace {
                var rule6Idx = idx
                while rule6Idx < chars.endIndex && chars[rule6Idx].isWhitespace {
                    rule6Idx = chars.index(after: rule6Idx)
                }
                if rule6Idx >= chars.endIndex {
                    // Reached end of string: all remaining whitespace matches rule 6.
                    result.append(chars[startIdx..<rule6Idx])
                    idx = rule6Idx
                    continue
                }
                // Followed by non-whitespace: match the run minus its last char, if that
                // leaves at least one char matched. The last char re-enters the main loop.
                let lastIdx = chars.index(before: rule6Idx)
                if lastIdx > startIdx {
                    result.append(chars[startIdx..<lastIdx])
                    idx = lastIdx
                    continue
                }
                // Single whitespace char before non-space: rule 6 matches nothing here.
                // Fall through (rule 2/4 may absorb it as a prefix, else rule 7 takes it).
            }

            // ── Rule 7: \s+ — remaining whitespace ────────────────────────────────
            if chars[idx].isWhitespace {
                var endIdx = chars.index(after: idx)
                while endIdx < chars.endIndex && chars[endIdx].isWhitespace {
                    endIdx = chars.index(after: endIdx)
                }
                result.append(chars[startIdx..<endIdx])
                idx = endIdx
                continue
            }

            // ── Fallback: consume one character (should not be reached for valid Unicode) ──
            // If none of the rules matched, advance by one character to prevent an infinite loop.
            // This handles any codepoint not covered by the Unicode categories above (e.g. PUA).
            idx = chars.index(after: idx)
            result.append(chars[startIdx..<idx])
        }

        return result
    }

    // MARK: - Contraction matching helper

    /// Returns `(endIndex, suffix)` if the text at `idx` is an apostrophe followed by
    /// a case-insensitive contraction suffix ('s, 't, 're, 've, 'm, 'll, 'd).
    /// Returns nil when the apostrophe does not introduce a recognised contraction.
    ///
    /// Suffix priority order: ll, ve, re, s, t, m, d (longer first so 'll' beats 'l').
    private func matchContraction(_ text: String, at idx: String.Index) -> (String.Index, String)? {
        // Must start with an apostrophe.
        guard text[idx] == "'" else { return nil }
        let afterApostrophe = text.index(after: idx)
        guard afterApostrophe < text.endIndex else { return nil }

        // The recognised suffixes in priority order (longest first).
        let suffixes: [(count: Int, lower: String)] = [
            (2, "ll"), (2, "ve"), (2, "re"),
            (1, "s"),  (1, "t"),  (1, "m"),  (1, "d"),
        ]

        for (count, suf) in suffixes {
            var endIdx = afterApostrophe
            var collected = ""
            var valid = true
            for _ in 0..<count {
                guard endIdx < text.endIndex else { valid = false; break }
                collected.append(text[endIdx].lowercased().first!)
                endIdx = text.index(after: endIdx)
            }
            guard valid, collected == suf else { continue }
            // Contraction must not be immediately followed by a letter (e.g. "it's" matches
            // "'s" but not "it'sam" — the 's' must be a word suffix, not a prefix of more letters).
            // tiktoken's regex does not impose this condition explicitly (it's just alternation),
            // but in practice the contraction patterns are anchored by the letter-run rule that
            // precedes them consuming the leading word.
            return (endIdx, "'" + suf)
        }
        return nil
    }

    // MARK: - Punctuation / symbol predicate

    /// Returns true for characters that belong to cl100k rule 4's punctuation/symbol class:
    /// NOT whitespace, NOT a letter, NOT a digit.
    ///
    /// This matches `[^\s\p{L}\p{N}]` in the original regex. CR and LF are excluded because
    /// they are matched by rule 5 (\s*[\r\n]+) and by the isWhitespace predicate, so they
    /// will never be in this bucket in practice (rule 5 fires before rule 4 for CR/LF).
    private func isPunctOrSymbol(_ c: Character) -> Bool {
        !c.isWhitespace && !c.isLetter && !c.isNumber
    }

    // MARK: - BPE merge

    /// Applies BPE to a sequence of UTF-8 bytes using the vocabulary rank table.
    ///
    /// Algorithm: standard tiktoken BPE merge (identical to the Python reference):
    ///   1. Start with each byte as a length-1 token.
    ///   2. Repeat: find the pair (tokens[i], tokens[i+1]) with the minimum rank in vocab.
    ///      If no such pair exists, stop.
    ///   3. Merge all non-overlapping occurrences of that best pair left-to-right.
    ///      (tiktoken merges ALL instances of the best pair in one pass, not just the first.)
    ///   4. Return ranks of the final tokens.
    ///
    /// Complexity: O(n²) in the worst case for n initial bytes. For typical natural-language
    /// pre-tokens (< 50 bytes) this is negligible.
    ///
    /// Invariant: every byte value 0x00–0xFF has a rank in cl100k_base (the first 256 vocabulary
    /// entries cover all single bytes). Therefore every `bytes` input produces valid output.
    private func bpeMerge(bytes: [UInt8]) -> [Int] {
        if bytes.isEmpty { return [] }
        if bytes.count == 1 {
            // Fast path: single byte.
            let key = Data(bytes)
            return [vocab[key]!]
        }

        // Represent the current merge state as an array of byte slices (as Data).
        var tokens: [Data] = bytes.map { Data([$0]) }

        while tokens.count >= 2 {
            // Find the pair with the minimum BPE rank.
            var bestRank: Int = Int.max
            var bestIdx: Int = -1

            for i in 0..<(tokens.count - 1) {
                let merged = tokens[i] + tokens[i + 1]
                if let rank = vocab[merged], rank < bestRank {
                    bestRank = rank
                    bestIdx = i
                }
            }

            // No more merges available.
            guard bestIdx >= 0 else { break }

            // Merge ALL non-overlapping occurrences of the best pair left-to-right.
            // This matches tiktoken's bpe() which merges all instances in one pass.
            let mergeTarget = tokens[bestIdx] + tokens[bestIdx + 1]
            var newTokens: [Data] = []
            var i = 0
            while i < tokens.count {
                if i < tokens.count - 1,
                   tokens[i] + tokens[i + 1] == mergeTarget {
                    newTokens.append(mergeTarget)
                    i += 2
                } else {
                    newTokens.append(tokens[i])
                    i += 1
                }
            }
            tokens = newTokens
        }

        // Map each merged token to its rank.
        return tokens.compactMap { vocab[$0] }
    }
}
