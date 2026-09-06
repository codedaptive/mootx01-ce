#if MOOTX01_MINERS
// QwenTokenizer.swift — byte-level BPE for the qwen2 tokenizer family
// (Core AI minter arms, operator mandate 2026-08-31).
//
// Loads a Hugging Face `tokenizer.json` (vocab + merges + added special
// tokens) and implements GPT-2-style byte-level BPE: text is
// pre-tokenized with the qwen2 split pattern, each pre-token's UTF-8
// bytes are mapped through the byte↔unicode table, merged by rank, and
// looked up in the vocab. Decode reverses the mapping. Golden-pinned
// against the reference implementation (Tests/Fixtures/
// qwen2-tokenizer-golden.json) — the pins are the conformance gate.
//
// Zero external dependencies by kit rule: JSONSerialization +
// NSRegularExpression only.

import Foundation

/// Byte-level BPE tokenizer over a HF tokenizer.json.
public final class QwenTokenizer: Sendable {
    private let vocab: [String: Int32]
    private let idToToken: [Int32: String]
    private let mergeRanks: [String: Int]
    /// Added tokens (specials like <|im_start|>) matched verbatim before
    /// pre-tokenization; longest-first so overlapping specials resolve.
    private let specials: [(token: String, id: Int32)]
    private let pretokenizer: NSRegularExpression

    /// GPT-2 byte→printable-unicode mapping (and its inverse), so every
    /// byte is a distinct printable character inside vocab strings.
    private let byteToChar: [UInt8: Character]
    private let charToByte: [Character: UInt8]

    public enum TokenizerError: Error {
        case unreadable(String)
        case malformed(String)
    }

    public init(tokenizerJSON url: URL) throws {
        guard let data = try? Data(contentsOf: url) else {
            throw TokenizerError.unreadable(url.path)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              let vocabRaw = model["vocab"] as? [String: Any]
        else { throw TokenizerError.malformed("missing model.vocab") }

        var vocab: [String: Int32] = [:]
        vocab.reserveCapacity(vocabRaw.count)
        for (token, id) in vocabRaw {
            guard let n = id as? Int else { continue }
            vocab[token] = Int32(n)
        }
        self.vocab = vocab
        var reverse: [Int32: String] = [:]
        reverse.reserveCapacity(vocab.count)
        for (t, i) in vocab { reverse[i] = t }

        // Merges: either ["a b", ...] or [["a","b"], ...] depending on
        // tokenizer.json vintage.
        var ranks: [String: Int] = [:]
        if let merges = model["merges"] as? [String] {
            for (rank, m) in merges.enumerated() { ranks[m] = rank }
        } else if let merges = model["merges"] as? [[String]] {
            for (rank, m) in merges.enumerated() where m.count == 2 {
                ranks["\(m[0]) \(m[1])"] = rank
            }
        } else {
            throw TokenizerError.malformed("missing model.merges")
        }
        self.mergeRanks = ranks

        var specials: [(String, Int32)] = []
        if let added = root["added_tokens"] as? [[String: Any]] {
            for entry in added {
                if let content = entry["content"] as? String,
                   let id = entry["id"] as? Int {
                    specials.append((content, Int32(id)))
                    reverse[Int32(id)] = content
                }
            }
        }
        self.specials = specials.sorted { $0.0.count > $1.0.count }
        self.idToToken = reverse

        // Qwen2 pre-tokenization pattern (tokenizer.json pre_tokenizer):
        // contractions | words (with optional leading non-letter) | digit |
        // punctuation runs | newline runs | trailing space | spaces.
        let pattern = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|" +
            "[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}|" +
            " ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"
        self.pretokenizer = try NSRegularExpression(pattern: pattern)

        // bytes_to_unicode: printable ASCII + latin ranges keep their own
        // codepoint; everything else maps to 256+n in order.
        var b2c: [UInt8: Character] = [:]
        var c2b: [Character: UInt8] = [:]
        var printable: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var extra = 0
        for byte in 0...255 {
            let scalarValue: Int
            if printable.contains(byte) {
                scalarValue = byte
            } else {
                scalarValue = 256 + extra
                extra += 1
            }
            let ch = Character(UnicodeScalar(scalarValue)!)
            b2c[UInt8(byte)] = ch
            c2b[ch] = UInt8(byte)
        }
        printable.removeAll()
        self.byteToChar = b2c
        self.charToByte = c2b
    }

    // MARK: - Encode

    public func encode(_ text: String) -> [Int32] {
        var ids: [Int32] = []
        // Split on special tokens first (verbatim, longest-first).
        var segments: [(String, Int32?)] = [(text, nil)]
        for (token, id) in specials {
            var next: [(String, Int32?)] = []
            for (segment, special) in segments {
                if special != nil { next.append((segment, special)); continue }
                var rest = Substring(segment)
                while let range = rest.range(of: token) {
                    next.append((String(rest[..<range.lowerBound]), nil))
                    next.append((token, id))
                    rest = rest[range.upperBound...]
                }
                next.append((String(rest), nil))
            }
            segments = next
        }
        for (segment, special) in segments {
            if let special { ids.append(special); continue }
            guard !segment.isEmpty else { continue }
            let ns = segment as NSString
            let matches = pretokenizer.matches(
                in: segment, range: NSRange(location: 0, length: ns.length))
            for match in matches {
                let piece = ns.substring(with: match.range)
                ids.append(contentsOf: bpe(piece))
            }
        }
        return ids
    }

    /// Rank-lookup memo key: two interned symbol ids. Interning the
    /// symbols once per pre-token means the merge-table probe for a
    /// given adjacent pair interpolates its `"\(a) \(b)"` key exactly
    /// once, however many passes re-examine that pair.
    private struct PairKey: Hashable {
        let left: Int
        let right: Int
    }

    /// Byte-level BPE over one pre-token: the GPT-2 reference loop.
    /// Each pass picks the lowest-ranked adjacent pair and merges EVERY
    /// non-overlapping occurrence of it left to right in one sweep, so
    /// a pass shrinks the symbol array by the whole occurrence count
    /// rather than by one. A trained merge table is rank-monotone (a
    /// merge that consumes token T ranks after the merge that produced
    /// T), so the sweep yields the same ids as merging one occurrence
    /// per pass; the golden fixture and the oracle test in
    /// QwenTokenizerTests pin that equivalence. This closes Codex
    /// finding 3cf82eb4: one merge per full rescan made a long run of a
    /// mergeable byte quadratic, with a String allocation per candidate
    /// pair on every rescan.
    private func bpe(_ piece: String) -> [Int32] {
        // Symbol interning: `names[id]` is the vocab string of symbol
        // `id`; every distinct symbol seen in this pre-token gets one id
        // so the merge loop compares Ints and only touches Strings when
        // a pair is probed for the first time or a merge creates a new
        // symbol.
        var names: [String] = []
        var idOf: [String: Int] = [:]
        func intern(_ name: String) -> Int {
            if let id = idOf[name] { return id }
            let id = names.count
            names.append(name)
            idOf[name] = id
            return id
        }
        // Bytes → mapped characters, one symbol per byte.
        var symbols: [Int] = piece.utf8.map { intern(String(byteToChar[$0]!)) }
        guard symbols.count > 1 else {
            return symbols.compactMap { vocab[names[$0]] }
        }
        // Memo of merge-table probes: `nil` records a pair the table
        // lacks, so a miss is as cheap as a hit on later passes. The
        // probe key is the table's own `"\(a) \(b)"` form, so vocabulary
        // and merge semantics are exactly the loaded tokenizer.json's.
        var rankMemo: [PairKey: Int?] = [:]
        func rank(_ left: Int, _ right: Int) -> Int? {
            let key = PairKey(left: left, right: right)
            if let known = rankMemo[key] { return known }
            let found = mergeRanks["\(names[left]) \(names[right])"]
            rankMemo[key] = found
            return found
        }
        while symbols.count > 1 {
            var bestRank = Int.max
            var bestPair: PairKey? = nil
            for i in 0..<(symbols.count - 1) {
                if let r = rank(symbols[i], symbols[i + 1]), r < bestRank {
                    bestRank = r
                    bestPair = PairKey(left: symbols[i], right: symbols[i + 1])
                }
            }
            guard let pair = bestPair else { break }
            let merged = intern(names[pair.left] + names[pair.right])
            // One left-to-right sweep merging every non-overlapping
            // occurrence: after a merge the scan resumes past the pair,
            // so "aaa" under (a,a) becomes [aa, a], as the reference
            // does.
            var next: [Int] = []
            next.reserveCapacity(symbols.count)
            var i = 0
            while i < symbols.count {
                if i + 1 < symbols.count,
                   symbols[i] == pair.left, symbols[i + 1] == pair.right {
                    next.append(merged)
                    i += 2
                } else {
                    next.append(symbols[i])
                    i += 1
                }
            }
            symbols = next
        }
        return symbols.compactMap { vocab[names[$0]] }
    }

    // MARK: - Decode

    public func decode(_ ids: [Int32]) -> String {
        var bytes: [UInt8] = []
        for id in ids {
            guard let token = idToToken[id] else { continue }
            // Specials decode verbatim (their characters are not byte-mapped).
            if specials.contains(where: { $0.id == id }) {
                bytes.append(contentsOf: Array(token.utf8))
                continue
            }
            for ch in token {
                if let b = charToByte[ch] { bytes.append(b) }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// The id for one added special token, if present.
    public func specialID(_ token: String) -> Int32? {
        specials.first(where: { $0.token == token })?.id
    }
}
#endif // MOOTX01_MINERS
