#if MOOTX01_MINERS
import Foundation
import Testing
@testable import AdornmentLib

/// Golden conformance: the Swift byte-level BPE must produce the exact
/// id sequences the reference tokenizer produces (fixture generated from
/// the vendored qwen2 tokenizer.json via the reference implementation).
@Suite struct QwenTokenizerTests {

    /// The reference qwen2 `tokenizer.json`, named by the environment variable
    /// `MOOT_QWEN2_TOKENIZER_JSON`. The file is a third-party model asset that
    /// is not vendored; when the variable is unset or the file is absent the
    /// golden suite is skipped rather than pinned to any machine's path.
    static let tokenizerURL: URL? = {
        guard let path = ProcessInfo.processInfo.environment["MOOT_QWEN2_TOKENIZER_JSON"],
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }()

    private struct Fixture: Decodable {
        struct Case: Decodable { let text: String; let ids: [Int32] }
        let cases: [Case]
        let special: [String: Int32]
    }

    private func loadFixture() throws -> Fixture {
        let url = Bundle.module.url(
            forResource: "qwen2-tokenizer-golden", withExtension: "json",
            subdirectory: "Fixtures")!
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    @Test("encode matches the reference on every golden case")
    func encodeGolden() throws {
        guard let tokenizerURL = Self.tokenizerURL else {
            return  // MOOT_QWEN2_TOKENIZER_JSON unset — golden pins run where the reference tokenizer lives
        }
        let tok = try QwenTokenizer(tokenizerJSON: tokenizerURL)
        let fixture = try loadFixture()
        for c in fixture.cases {
            #expect(tok.encode(c.text) == c.ids, "mismatch for \(c.text.prefix(40))")
        }
        for (token, id) in fixture.special {
            #expect(tok.specialID(token) == id)
        }
    }

    @Test("decode round-trips every golden case")
    func decodeGolden() throws {
        guard let tokenizerURL = Self.tokenizerURL else { return }
        let tok = try QwenTokenizer(tokenizerJSON: tokenizerURL)
        let fixture = try loadFixture()
        for c in fixture.cases {
            #expect(tok.decode(c.ids) == c.text)
        }
    }
}

/// Codex finding 3cf82eb4: `bpe` merges every non-overlapping occurrence
/// of the best-ranked pair per pass. These tests hold the shipped
/// encoder against `referenceBPE`, a verbatim copy of the one-merge-
/// per-pass loop it replaced, so the ids are pinned byte-identical while
/// a long run of a mergeable byte no longer costs quadratic time.
@Suite struct QwenTokenizerBPETests {

    /// The one-merge-per-pass loop: pick the lowest-ranked adjacent
    /// pair (lowest index on ties), replace that single occurrence,
    /// rescan. Kept here as the oracle; it is the loop the finding
    /// measured as quadratic.
    private static func referenceBPE(
        symbols start: [String], mergeRanks: [String: Int], vocab: [String: Int32]
    ) -> [Int32] {
        var symbols = start
        guard symbols.count > 1 else { return symbols.compactMap { vocab[$0] } }
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

    /// Writes a minimal tokenizer.json (vocab + merges, no specials) and
    /// returns its URL plus the parsed tables the oracle needs. The
    /// vocab strings are printable ASCII, which the byte↔unicode table
    /// maps to themselves, so the oracle can work on the raw characters.
    private static func synthesize(vocab: [String], merges: [String]) throws
        -> (url: URL, ranks: [String: Int], ids: [String: Int32]) {
        var vocabMap: [String: Int] = [:]
        for (i, t) in vocab.enumerated() { vocabMap[t] = i }
        let root: [String: Any] = [
            "model": ["vocab": vocabMap, "merges": merges],
            "added_tokens": [[String: Any]](),
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-bpe-\(UUID().uuidString).json")
        try data.write(to: url)
        var ranks: [String: Int] = [:]
        for (r, m) in merges.enumerated() { ranks[m] = r }
        var ids: [String: Int32] = [:]
        for (t, i) in vocabMap { ids[t] = Int32(i) }
        return (url, ranks, ids)
    }

    /// Powers-of-two run vocabulary: a, aa, aaaa, a×8, a×16 with the
    /// merges that build them, so a run of "a" collapses in four passes.
    private static func runTable() throws
        -> (url: URL, ranks: [String: Int], ids: [String: Int32]) {
        let lengths = [1, 2, 4, 8, 16]
        let vocab = lengths.map { String(repeating: "a", count: $0) }
        let merges = [1, 2, 4, 8].map { n in
            "\(String(repeating: "a", count: n)) \(String(repeating: "a", count: n))"
        }
        return try synthesize(vocab: vocab, merges: merges)
    }

    @Test("a 4,000-byte run of a mergeable byte matches the reference loop, fast")
    func longRunMatchesReference() throws {
        let table = try Self.runTable()
        defer { try? FileManager.default.removeItem(at: table.url) }
        let tok = try QwenTokenizer(tokenizerJSON: table.url)
        let text = String(repeating: "a", count: 4_000)
        let expected = Self.referenceBPE(
            symbols: text.map { String($0) }, mergeRanks: table.ranks, vocab: table.ids)
        // 4000 = 250 × 16: every symbol lands in the a×16 token.
        #expect(expected == [Int32](repeating: 4, count: 250))
        let clock = ContinuousClock()
        let started = clock.now
        let ids = tok.encode(text)
        let elapsed = clock.now - started
        #expect(ids == expected)
        // The reference loop needs ~4000 full rescans here; the sweep
        // needs four. One second is an order of magnitude above the
        // sweep's cost on any supported machine.
        #expect(elapsed < .seconds(1), "encode took \(elapsed)")
    }

    @Test("run lengths that leave remainders match the reference loop")
    func remainderRunsMatchReference() throws {
        let table = try Self.runTable()
        defer { try? FileManager.default.removeItem(at: table.url) }
        let tok = try QwenTokenizer(tokenizerJSON: table.url)
        for n in [1, 2, 3, 5, 7, 15, 17, 31, 33, 100, 4_003] {
            let text = String(repeating: "a", count: n)
            let expected = Self.referenceBPE(
                symbols: text.map { String($0) }, mergeRanks: table.ranks, vocab: table.ids)
            #expect(tok.encode(text) == expected, "run of \(n)")
        }
    }

    @Test("a table whose merges consume earlier merges matches the reference loop")
    func chainedMergesMatchReference() throws {
        // (a,a)→aa ranks first; (aa,a)→aaa and (b,aaa)→baaa then consume
        // it, and (a,b) sits between: the sweep must yield the reference
        // ids on every mix of the two letters.
        let table = try Self.synthesize(
            vocab: ["a", "b", "aa", "aaa", "ab", "baaa", "aab"],
            merges: ["a a", "aa a", "a b", "b aaa", "aa b"])
        defer { try? FileManager.default.removeItem(at: table.url) }
        let tok = try QwenTokenizer(tokenizerJSON: table.url)
        // Deterministic a/b mixes at every length 1...64.
        var texts: [String] = []
        for n in 1...64 {
            var word = ""
            for i in 0..<n { word.append((i * 7 + n) % 3 == 0 ? "b" : "a") }
            texts.append(word)
        }
        texts += ["ab", "ba", "aba", "abab", "baaab", "aabaaab", "bbbaaaab"]
        for text in texts {
            let expected = Self.referenceBPE(
                symbols: text.map { String($0) }, mergeRanks: table.ranks, vocab: table.ids)
            #expect(tok.encode(text) == expected, "text \(text)")
        }
    }

    @Test("the vendored qwen2 table agrees with the reference loop on long runs")
    func vendoredTableMatchesReference() throws {
        guard let url = QwenTokenizerTests.tokenizerURL else {
            return  // MOOT_QWEN2_TOKENIZER_JSON unset; the synthetic tables above still run
        }
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let model = root["model"] as! [String: Any]
        var ranks: [String: Int] = [:]
        if let merges = model["merges"] as? [String] {
            for (r, m) in merges.enumerated() { ranks[m] = r }
        } else if let merges = model["merges"] as? [[String]] {
            for (r, m) in merges.enumerated() where m.count == 2 { ranks["\(m[0]) \(m[1])"] = r }
        }
        var ids: [String: Int32] = [:]
        for (t, i) in model["vocab"] as! [String: Int] { ids[t] = Int32(i) }
        let tok = try QwenTokenizer(tokenizerJSON: url)
        // Single pre-tokens of printable ASCII (byte table maps them to
        // themselves): a 4,000-letter run and a repeated word.
        for text in [String(repeating: "a", count: 4_000),
                     String(repeating: "tomato", count: 300),
                     String(repeating: "=", count: 1_000)] {
            let expected = Self.referenceBPE(
                symbols: text.map { String($0) }, mergeRanks: ranks, vocab: ids)
            #expect(tok.encode(text) == expected, "text \(text.prefix(12))…")
        }
    }
}
#endif // MOOTX01_MINERS: the library compiles to nothing with the switch off, so do its tests.
