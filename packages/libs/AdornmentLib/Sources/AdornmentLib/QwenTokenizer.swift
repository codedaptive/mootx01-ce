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

    private func bpe(_ piece: String) -> [Int32] {
        // Bytes → mapped characters, one symbol per byte.
        var symbols: [String] = piece.utf8.map { String(byteToChar[$0]!) }
        guard symbols.count > 1 else {
            return symbols.compactMap { vocab[$0] }
        }
        while true {
            var bestRank = Int.max
            var bestIndex = -1
            for i in 0..<(symbols.count - 1) {
                if let rank = mergeRanks["\(symbols[i]) \(symbols[i + 1])"],
                   rank < bestRank {
                    bestRank = rank
                    bestIndex = i
                }
            }
            guard bestIndex >= 0 else { break }
            symbols.replaceSubrange(bestIndex...(bestIndex + 1),
                                    with: [symbols[bestIndex] + symbols[bestIndex + 1]])
        }
        return symbols.compactMap { vocab[$0] }
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
