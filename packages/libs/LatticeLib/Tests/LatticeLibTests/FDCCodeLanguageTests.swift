import Foundation
import Testing
@testable import LatticeLib

private struct CodeLanguageFixture: Decodable {
    struct Vector: Decodable {
        let name: String
        let input: String
        let identifier: String
        let qid: String
    }

    let version: String
    let vectors: [Vector]
}

@Suite("FDC v4.2 code classification")
struct FDCCodeLanguageTests {
    private func fixture(sourceFile: String = #filePath) throws -> CodeLanguageFixture {
        let packageRoot = URL(fileURLWithPath: sourceFile)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = packageRoot.appendingPathComponent(
            "rust/tests/fixtures/fdc_code_language_conformance.json")
        return try JSONDecoder().decode(
            CodeLanguageFixture.self, from: Data(contentsOf: url))
    }

    @Test("Swift and Rust share pinned language refinements")
    func languageConformance() throws {
        let fixture = try fixture()
        #expect(fixture.version == "1.0.0")
        for vector in fixture.vectors {
            let language = FDCCodeLanguageDetector.detect(in: vector.input)
            #expect(language?.identifier == vector.identifier, Comment(rawValue: vector.name))
            #expect(language?.wikidataQID == vector.qid, Comment(rawValue: vector.name))
            let anchor = FDC.encodeAnchor(vector.input)
            #expect(anchor.code == "005", Comment(rawValue: vector.name))
            #expect(anchor.conceptQID == vector.qid, Comment(rawValue: vector.name))
        }
    }

    @Test("explicit code kind classifies even a short ambiguous snippet")
    func explicitCodeKind() {
        let anchor = FDC.encodeAnchor(
            "x += 1", contentKind: .code, recordNovel: false)
        #expect(anchor.code == "005")
        #expect(anchor.conceptQID == nil)
    }

    @Test("syntax-heavy source is programming but shell transcripts remain operational")
    func syntaxAndShell() {
        let source = "if (value != nil) { result = value; return result; }"
        let shell = """
        ```bash
        git worktree prune
        rm -f .git/index.lock
        ```
        """
        #expect(FDC.encode(source) == "005")
        #expect(FDC.encode(shell) == "000")
        #expect(FDC.encodeAnchor(
            shell, contentKind: .code, recordNovel: false).code == "005")
    }

    @Test("unlabeled source fences classify without turning prose into TypeScript")
    func fenceAndProseBoundaries() {
        let fencedJSON = """
        ```
        {"name": "Ada", "active": true}
        ```
        """
        let prose = "The interface should feel natural and modern for every user."
        #expect(FDC.encode(fencedJSON) == "005")
        #expect(FDCCodeLanguageDetector.detect(in: prose) == nil)
        #expect(FDC.encode(prose) != "005")
    }
}
