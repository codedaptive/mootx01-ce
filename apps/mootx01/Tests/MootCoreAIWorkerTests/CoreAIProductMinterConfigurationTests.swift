#if os(macOS) && canImport(CoreAI)
import Foundation
import Testing
@testable import MootCoreAIWorker

@Suite("Core AI product minter configuration")
struct CoreAIProductMinterConfigurationTests {
    private func fixture() throws -> (root: URL, asset: URL, tokenizer: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let asset = root.appendingPathComponent("nuextract.aimodel", isDirectory: true)
        try FileManager.default.createDirectory(
            at: asset, withIntermediateDirectories: true)
        for name in ["metadata.json", "main.mlirb", "main.hash"] {
            try Data("fixture".utf8).write(to: asset.appendingPathComponent(name))
        }
        let tokenizer = root.appendingPathComponent("tokenizer.json")
        try Data("{}".utf8).write(to: tokenizer)
        return (root, asset, tokenizer)
    }

    @Test("absent selection is disabled")
    func absentSelection() throws {
        #expect(try CoreAIProductMinterConfiguration.resolve(environment: [:]) == nil)
    }

    @Test("fixed NuExtract selection resolves fixed style, budget, and identity")
    func fixedSelection() throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.root) }
        let resolved = try CoreAIProductMinterConfiguration.resolve(
            environment: [
                CoreAIProductMinterConfiguration.selectionKey:
                    CoreAIProductMinterConfiguration.nuextractB1Q8Selection,
                CoreAIProductMinterConfiguration.assetPathKey: files.asset.path,
                CoreAIProductMinterConfiguration.tokenizerPathKey: files.tokenizer.path,
            ]
        )
        let config = try #require(resolved)
        #expect(config.identity == "nuextract-tiny-v1.5-b1-q8-p1-s1")
        #expect(config.style.rawValue == "nuextract")
        #expect(config.maxNewTokens == 256)
        #expect(config.recipe.parameters["batch_width"] == "1")
    }

    @Test("unsupported selection is rejected")
    func unsupportedSelection() throws {
        #expect(throws: CoreAIProductMinterConfiguration.ConfigurationError.self) {
            try CoreAIProductMinterConfiguration.resolve(environment: [
                CoreAIProductMinterConfiguration.selectionKey: "qwen-anything"
            ])
        }
    }

    @Test("relative paths are rejected before filesystem access")
    func relativePath() throws {
        #expect(throws: CoreAIProductMinterConfiguration.ConfigurationError.self) {
            try CoreAIProductMinterConfiguration.resolve(environment: [
                CoreAIProductMinterConfiguration.selectionKey:
                    CoreAIProductMinterConfiguration.nuextractB1Q8Selection,
                CoreAIProductMinterConfiguration.assetPathKey: "model.aimodel",
                CoreAIProductMinterConfiguration.tokenizerPathKey: "/tmp/tokenizer.json",
            ])
        }
    }

    @Test("incomplete aimodel bundle is rejected")
    func incompleteAsset() throws {
        let files = try fixture()
        defer { try? FileManager.default.removeItem(at: files.root) }
        try FileManager.default.removeItem(
            at: files.asset.appendingPathComponent("main.hash"))
        #expect(throws: CoreAIProductMinterConfiguration.ConfigurationError.self) {
            try CoreAIProductMinterConfiguration.resolve(environment: [
                CoreAIProductMinterConfiguration.selectionKey:
                    CoreAIProductMinterConfiguration.nuextractB1Q8Selection,
                CoreAIProductMinterConfiguration.assetPathKey: files.asset.path,
                CoreAIProductMinterConfiguration.tokenizerPathKey: files.tokenizer.path,
            ])
        }
    }
}
#endif
