import Foundation
import Testing
@testable import AdornmentLib

/// Golden conformance: the Swift byte-level BPE must produce the exact
/// id sequences the reference tokenizer produces (fixture generated from
/// the vendored qwen2 tokenizer.json via the reference implementation).
@Suite struct QwenTokenizerTests {

    static let tokenizerURL = URL(fileURLWithPath:
        "/Volumes/llm_models/hf/Qwen2-0.5B-Instruct/tokenizer.json")

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
        guard FileManager.default.fileExists(atPath: Self.tokenizerURL.path) else {
            return  // model volume absent (CI machine) — pins run where the vendored tokenizer lives
        }
        let tok = try QwenTokenizer(tokenizerJSON: Self.tokenizerURL)
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
        guard FileManager.default.fileExists(atPath: Self.tokenizerURL.path) else { return }
        let tok = try QwenTokenizer(tokenizerJSON: Self.tokenizerURL)
        let fixture = try loadFixture()
        for c in fixture.cases {
            #expect(tok.decode(c.ids) == c.text)
        }
    }
}
