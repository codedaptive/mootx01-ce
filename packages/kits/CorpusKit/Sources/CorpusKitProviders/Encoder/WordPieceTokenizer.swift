// WordPieceTokenizer.swift
//
// BERT uncased WordPiece over a vendored `vocab.txt`, the tokenizer the
// MiniLM family (and every other BERT-vocabulary encoder) expects. Emits
// `[CLS] … [SEP]` and truncates to the model's maximum sequence.
//
// Behaviour follows the reference BasicTokenizer + WordpieceTokenizer pair:
// clean control characters, lowercase, strip accents (NFD then drop
// combining marks), isolate CJK ideographs and punctuation as their own
// pieces, then greedy longest-match with the `##` continuation prefix and
// `[UNK]` for any word that does not decompose or is longer than
// `maxWordLength`.
//
// The Rust port reaches the same behaviour through the `tokenizers` crate's
// `tokenizer.json` (candle provider); both ports hash the same `vocab.txt`
// for `EncoderModelSpec.tokenizerHash`, so a vocabulary swap is caught on
// either side before a single span is encoded.
//
// `tokenizePair` is the cross-encoder form: `[CLS] query [SEP] span [SEP]`
// with segment ids 0 / 1 and longest-first truncation, the shape a BERT
// sequence classifier was trained on. The Rust twin is the `tokenizers`
// crate's pair encode with `TruncationStrategy::LongestFirst`.

import Foundation
import CorpusKit

/// One tokenized (query, span) pair for a cross encoder.
///
/// `ids` and `tokenTypeIDs` have the same count; every position is a real
/// token (no padding here, the inference runtime pads to its own shape).
public struct PairTokens: Sendable, Equatable {
    /// `[CLS] q… [SEP] s… [SEP]`.
    public let ids: [Int32]
    /// `0` for `[CLS] q… [SEP]`, `1` for `s… [SEP]`.
    public let tokenTypeIDs: [Int32]

    /// Memberwise.
    public init(ids: [Int32], tokenTypeIDs: [Int32]) {
        self.ids = ids
        self.tokenTypeIDs = tokenTypeIDs
    }
}

/// BERT uncased WordPiece tokenizer over a `vocab.txt` vocabulary.
public struct WordPieceTokenizer: Tokenizer {
    public let vocabID: String
    public let maxTokens: Int
    public let padTokenID: Int32
    public let unknownTokenID: Int32
    /// `[CLS]` id, emitted first.
    public let classTokenID: Int32
    /// `[SEP]` id, emitted last.
    public let separatorTokenID: Int32

    /// Reference WordpieceTokenizer limit: a longer word is `[UNK]` outright.
    public static let maxWordLength = 100

    private let vocabulary: [String: Int32]

    /// Build from the vocabulary lines (one piece per line, id = line index).
    ///
    /// - Throws: `CorpusKitError.tokenizerUnavailable` when any of the four
    ///   special tokens is absent: a vocabulary without them is not a BERT
    ///   vocabulary and no model in the registry could consume its ids.
    public init(vocabularyLines: [String], vocabID: String, maxTokens: Int) throws {
        var table: [String: Int32] = [:]
        table.reserveCapacity(vocabularyLines.count)
        for (index, line) in vocabularyLines.enumerated() {
            // Trailing newline / CR artefacts are not part of the piece.
            let piece = line.trimmingCharacters(in: .newlines)
            if piece.isEmpty { continue }
            if table[piece] == nil { table[piece] = Int32(index) }
        }
        guard let pad = table["[PAD]"], let unk = table["[UNK]"],
              let cls = table["[CLS]"], let sep = table["[SEP]"] else {
            throw CorpusKitError.tokenizerUnavailable(
                "\(vocabID): vocab.txt lacks one of [PAD] [UNK] [CLS] [SEP]")
        }
        self.vocabulary = table
        self.vocabID = vocabID
        self.maxTokens = maxTokens
        self.padTokenID = pad
        self.unknownTokenID = unk
        self.classTokenID = cls
        self.separatorTokenID = sep
    }

    /// Build from a `vocab.txt` file on disk.
    public init(contentsOf url: URL, vocabID: String, maxTokens: Int) throws {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CorpusKitError.tokenizerUnavailable("\(vocabID): \(url.path): \(error)")
        }
        try self.init(
            vocabularyLines: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
            vocabID: vocabID, maxTokens: maxTokens)
    }

    /// `[CLS]` + word pieces + `[SEP]`, truncated so the whole sequence is at
    /// most `maxTokens` ids (`[SEP]` always survives truncation).
    public func tokenize(_ text: String) -> [Int32] {
        let budget = max(0, maxTokens - 2)
        var ids: [Int32] = [classTokenID]
        ids.reserveCapacity(min(maxTokens, 64))
        var used = 0
        outer: for word in Self.basicTokens(text) {
            for id in wordPieces(word) {
                if used >= budget { break outer }
                ids.append(id)
                used += 1
            }
        }
        ids.append(separatorTokenID)
        return ids
    }

    /// `[CLS]` + query pieces + `[SEP]` + span pieces + `[SEP]`, with
    /// segment ids, truncated longest-first so the whole pair is at most
    /// `maxTokens` ids.
    ///
    /// Longest-first is the reference `truncation="longest_first"`: while
    /// the two piece lists together exceed `maxTokens - 3`, drop the last
    /// piece of the LONGER list; on a tie drop from the query (the first
    /// sequence). Pinned against the reference tokenizer in
    /// `PairTokenizerTests`.
    public func tokenizePair(_ query: String, _ span: String) -> PairTokens {
        let budget = max(0, maxTokens - 3)
        var q = Self.basicTokens(query).flatMap(wordPieces)
        var s = Self.basicTokens(span).flatMap(wordPieces)
        while q.count + s.count > budget {
            if s.count > q.count {
                s.removeLast()
            } else {
                q.removeLast()
            }
        }
        var ids: [Int32] = [classTokenID]
        ids.reserveCapacity(q.count + s.count + 3)
        ids += q
        ids.append(separatorTokenID)
        ids += s
        ids.append(separatorTokenID)
        let tokenTypeIDs = [Int32](repeating: 0, count: q.count + 2) + [Int32](repeating: 1, count: s.count + 1)
        return PairTokens(ids: ids, tokenTypeIDs: tokenTypeIDs)
    }

    // MARK: - Basic tokenisation

    /// Clean, lowercase, strip accents, then split on whitespace with
    /// punctuation and CJK ideographs isolated as single-scalar tokens.
    static func basicTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { tokens.append(current); current = "" }
        }
        // NFD so combining marks become separate scalars we can drop.
        for scalar in text.lowercased().decomposedStringWithCanonicalMapping.unicodeScalars {
            let category = scalar.properties.generalCategory
            if scalar.value == 0 || scalar.value == 0xFFFD || category == .control || category == .format {
                continue    // reference _clean_text drops control/format scalars
            }
            if category == .nonspacingMark {
                continue    // accent stripping (reference _run_strip_accents)
            }
            if scalar.properties.isWhitespace {
                flush()
                continue
            }
            if isPunctuation(scalar) || isCJK(scalar) {
                flush()
                tokens.append(String(scalar))
                continue
            }
            current.unicodeScalars.append(scalar)
        }
        flush()
        return tokens
    }

    /// Reference `_is_punctuation`: the four ASCII symbol ranges count as
    /// punctuation even though Unicode classes some of them as symbols.
    static func isPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if (33...47).contains(v) || (58...64).contains(v) || (91...96).contains(v) || (123...126).contains(v) {
            return true
        }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    /// Reference `_is_chinese_char` ranges (CJK Unified Ideographs and
    /// extensions, compatibility ideographs).
    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x20000...0x2A6DF).contains(v) || (0x2A700...0x2B73F).contains(v)
            || (0x2B740...0x2B81F).contains(v) || (0x2B820...0x2CEAF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FA1F).contains(v)
    }

    // MARK: - WordPiece

    /// Greedy longest-match over scalars; `##` prefixes every piece after
    /// the first. A word with no decomposition, or longer than
    /// `maxWordLength` scalars, is one `[UNK]`.
    func wordPieces(_ word: String) -> [Int32] {
        let scalars = Array(word.unicodeScalars)
        guard !scalars.isEmpty else { return [] }
        guard scalars.count <= Self.maxWordLength else { return [unknownTokenID] }
        var pieces: [Int32] = []
        var start = 0
        while start < scalars.count {
            var end = scalars.count
            var found: Int32? = nil
            while start < end {
                var candidate = String(String.UnicodeScalarView(scalars[start..<end]))
                if start > 0 { candidate = "##" + candidate }
                if let id = vocabulary[candidate] { found = id; break }
                end -= 1
            }
            guard let id = found else { return [unknownTokenID] }
            pieces.append(id)
            start = end
        }
        return pieces
    }
}
