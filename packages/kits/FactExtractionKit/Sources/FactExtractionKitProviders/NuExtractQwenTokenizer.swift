import Foundation

/// Byte-level BPE tokenizer for NuExtract 1.5's Qwen2.5 tokenizer.json.
final class NuExtractQwenTokenizer: Sendable {
    private let vocab: [String: Int32]
    private let idToToken: [Int32: String]
    private let mergeRanks: [String: Int]
    private let specials: [(token: String, id: Int32)]
    private let pretokenizer: NSRegularExpression
    private let byteToCharacter: [UInt8: Character]
    private let characterToByte: [Character: UInt8]

    enum TokenizerError: Error, CustomStringConvertible {
        case unreadable(String)
        case malformed(String)

        var description: String {
            switch self {
            case .unreadable(let path): "cannot read tokenizer at \(path)"
            case .malformed(let reason): "malformed tokenizer: \(reason)"
            }
        }
    }

    init(tokenizerJSON url: URL) throws {
        guard let data = try? Data(contentsOf: url) else {
            throw TokenizerError.unreadable(url.path)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = root["model"] as? [String: Any],
              let rawVocabulary = model["vocab"] as? [String: Any] else {
            throw TokenizerError.malformed("missing model.vocab")
        }

        var vocabulary: [String: Int32] = [:]
        for (token, rawID) in rawVocabulary {
            if let id = rawID as? Int { vocabulary[token] = Int32(id) }
        }
        guard !vocabulary.isEmpty else {
            throw TokenizerError.malformed("empty model.vocab")
        }
        vocab = vocabulary

        var reverse = Dictionary(uniqueKeysWithValues: vocabulary.map { ($0.value, $0.key) })
        var addedTokens: [(String, Int32)] = []
        if let added = root["added_tokens"] as? [[String: Any]] {
            for row in added {
                guard let token = row["content"] as? String,
                      let rawID = row["id"] as? Int else { continue }
                let id = Int32(rawID)
                addedTokens.append((token, id))
                reverse[id] = token
            }
        }
        specials = addedTokens.sorted { $0.0.count > $1.0.count }
        idToToken = reverse

        var ranks: [String: Int] = [:]
        if let merges = model["merges"] as? [String] {
            for (rank, merge) in merges.enumerated() { ranks[merge] = rank }
        } else if let merges = model["merges"] as? [[String]] {
            for (rank, merge) in merges.enumerated() where merge.count == 2 {
                ranks["\(merge[0]) \(merge[1])"] = rank
            }
        } else {
            throw TokenizerError.malformed("missing model.merges")
        }
        mergeRanks = ranks

        pretokenizer = try NSRegularExpression(pattern:
            "(?i:'s|'t|'re|'ve|'m|'ll|'d)|" +
            "[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}|" +
            " ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+")

        let printable = Set(Array(33...126) + Array(161...172) + Array(174...255))
        var forward: [UInt8: Character] = [:]
        var backward: [Character: UInt8] = [:]
        var extra = 0
        for byte in 0...255 {
            let scalarValue: Int
            if printable.contains(byte) {
                scalarValue = byte
            } else {
                scalarValue = 256 + extra
                extra += 1
            }
            let character = Character(UnicodeScalar(scalarValue)!)
            forward[UInt8(byte)] = character
            backward[character] = UInt8(byte)
        }
        byteToCharacter = forward
        characterToByte = backward
    }

    func encode(_ text: String) -> [Int32] {
        var segments: [(String, Int32?)] = [(text, nil)]
        for (token, id) in specials {
            var next: [(String, Int32?)] = []
            for (segment, specialID) in segments {
                if specialID != nil {
                    next.append((segment, specialID))
                    continue
                }
                var remainder = Substring(segment)
                while let range = remainder.range(of: token) {
                    next.append((String(remainder[..<range.lowerBound]), nil))
                    next.append((token, id))
                    remainder = remainder[range.upperBound...]
                }
                next.append((String(remainder), nil))
            }
            segments = next
        }

        var ids: [Int32] = []
        for (segment, specialID) in segments {
            if let specialID {
                ids.append(specialID)
                continue
            }
            guard !segment.isEmpty else { continue }
            let bridged = segment as NSString
            for match in pretokenizer.matches(
                in: segment, range: NSRange(location: 0, length: bridged.length)) {
                ids.append(contentsOf: bpe(bridged.substring(with: match.range)))
            }
        }
        return ids
    }

    func decode(_ ids: [Int32]) -> String {
        var bytes: [UInt8] = []
        for id in ids {
            guard let token = idToToken[id] else { continue }
            if specials.contains(where: { $0.id == id }) {
                bytes.append(contentsOf: token.utf8)
            } else {
                for character in token {
                    if let byte = characterToByte[character] { bytes.append(byte) }
                }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func specialID(_ token: String) -> Int32? {
        specials.first(where: { $0.token == token })?.id
    }

    private struct Pair: Hashable {
        let left: Int
        let right: Int
    }

    private func bpe(_ piece: String) -> [Int32] {
        var names: [String] = []
        var identifiers: [String: Int] = [:]
        func intern(_ name: String) -> Int {
            if let existing = identifiers[name] { return existing }
            let id = names.count
            names.append(name)
            identifiers[name] = id
            return id
        }

        var symbols = piece.utf8.map { intern(String(byteToCharacter[$0]!)) }
        guard symbols.count > 1 else {
            return symbols.compactMap { vocab[names[$0]] }
        }
        var rankCache: [Pair: Int?] = [:]
        func rank(_ pair: Pair) -> Int? {
            if let cached = rankCache[pair] { return cached }
            let value = mergeRanks["\(names[pair.left]) \(names[pair.right])"]
            rankCache[pair] = value
            return value
        }

        while symbols.count > 1 {
            var bestRank = Int.max
            var bestPair: Pair?
            for index in 0..<(symbols.count - 1) {
                let pair = Pair(left: symbols[index], right: symbols[index + 1])
                if let candidateRank = rank(pair), candidateRank < bestRank {
                    bestRank = candidateRank
                    bestPair = pair
                }
            }
            guard let bestPair else { break }
            let merged = intern(names[bestPair.left] + names[bestPair.right])
            var next: [Int] = []
            var index = 0
            while index < symbols.count {
                if index + 1 < symbols.count,
                   symbols[index] == bestPair.left,
                   symbols[index + 1] == bestPair.right {
                    next.append(merged)
                    index += 2
                } else {
                    next.append(symbols[index])
                    index += 1
                }
            }
            symbols = next
        }
        return symbols.compactMap { vocab[names[$0]] }
    }
}
