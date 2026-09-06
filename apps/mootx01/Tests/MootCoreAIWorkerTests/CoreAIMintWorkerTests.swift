#if MOOTX01_MINERS && os(macOS) && canImport(CoreAI)
import Foundation
import Testing
@testable import MootCoreAIWorker

@Suite("Core AI resident worker arguments")
struct CoreAIMintWorkerArgumentTests {
    @Test("capability probe needs no model arguments")
    func capabilityProbeNeedsNoModelArguments() throws {
        let command = try CoreAIMintWorkerCommand.parse(["--mint-capabilities"])
        #expect(try command.resolvedMode() == .capabilities)
        #expect(CoreAIMintWorker.capabilityPayload == Data("batch\n".utf8))
    }

    @Test("batch mode resolves every explicit model argument")
    func batchModeResolvesArguments() throws {
        let command = try CoreAIMintWorkerCommand.parse([
            "--batch",
            "--asset", "/models/qwen3-q8.aimodel",
            "--tokenizer", "/models/qwen3/tokenizer.json",
            "--style", "chat3",
            "--max-new-tokens", "256",
            "--identity", "qwen3-q8",
        ])

        let expected = try CoreAIMintWorkerConfiguration(
            assetPath: "/models/qwen3-q8.aimodel",
            tokenizerPath: "/models/qwen3/tokenizer.json",
            styleRawValue: "chat3",
            maxNewTokens: 256,
            identity: "qwen3-q8"
        )
        #expect(try command.resolvedMode() == .batch(expected))
    }

    @Test("identity defaults to the asset basename")
    func identityDefaultsToAssetBasename() throws {
        let config = try CoreAIMintWorkerConfiguration(
            assetPath: "/models/nuextract-q8.aimodel",
            tokenizerPath: "/models/nuextract/tokenizer.json",
            styleRawValue: "nuextract",
            maxNewTokens: 256,
            identity: nil
        )
        #expect(config.identity == "nuextract-q8")
    }

    @Test("batch mode requires its four operational arguments", arguments: [
        ["--batch"],
        ["--batch", "--asset", "/a"],
        ["--batch", "--asset", "/a", "--tokenizer", "/t"],
        ["--batch", "--asset", "/a", "--tokenizer", "/t", "--style", "chat3"],
    ])
    func batchModeRequiresArguments(arguments: [String]) throws {
        let command = try CoreAIMintWorkerCommand.parse(arguments)
        #expect(throws: (any Error).self) {
            _ = try command.resolvedMode()
        }
    }

    @Test("batch rejects unsafe or invalid values")
    func batchRejectsInvalidValues() throws {
        for arguments in [
            ["--batch", "--asset", "relative", "--tokenizer", "/t", "--style", "chat3", "--max-new-tokens", "96"],
            ["--batch", "--asset", "/a", "--tokenizer", "relative", "--style", "chat3", "--max-new-tokens", "96"],
            ["--batch", "--asset", "/a", "--tokenizer", "/t", "--style", "unknown", "--max-new-tokens", "96"],
            ["--batch", "--asset", "/a", "--tokenizer", "/t", "--style", "chat3", "--max-new-tokens", "0"],
        ] {
            let command = try CoreAIMintWorkerCommand.parse(arguments)
            #expect(throws: (any Error).self) {
                _ = try command.resolvedMode()
            }
        }
    }

    @Test("capability probe and batch are mutually exclusive")
    func modesAreExclusive() throws {
        let command = try CoreAIMintWorkerCommand.parse([
            "--mint-capabilities", "--batch",
        ])
        #expect(throws: (any Error).self) {
            _ = try command.resolvedMode()
        }
    }
}

@Suite("Core AI resident worker protocol")
struct CoreAIMintWorkerProtocolTests {
    private actor FakeEngine: CoreAIMintWorkerEngine {
        private(set) var prompts: [String] = []

        func mint(prompt: String) -> String? {
            prompts.append(prompt)
            return prompt == "fail" ? nil : "claim:\(prompt)"
        }
    }

    private actor FactoryCounter {
        private(set) var calls = 0
        func record() { calls += 1 }
    }

    @Test("decoder accepts split and multiple NUL frames")
    func decoderAcceptsSplitAndMultipleFrames() {
        var decoder = NULFrameDecoder()
        #expect(decoder.append(Data("one\u{0}tw".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["one"])
        #expect(decoder.append(Data("o\u{0}\u{0}four\u{0}tail".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["two", "", "four"])
        #expect(String(decoding: decoder.pending, as: UTF8.self) == "tail")
    }

    @Test("batch constructs one engine, preserves order, and exits on EOF")
    func batchConstructsOneEngineAndExitsOnEOF() async throws {
        let input = Pipe()
        let output = Pipe()
        let engine = FakeEngine()
        let counter = FactoryCounter()
        input.fileHandleForWriting.write(Data("first\u{0}fail\u{0}third\u{0}".utf8))
        try input.fileHandleForWriting.close()

        let config = try CoreAIMintWorkerConfiguration(
            assetPath: "/models/model.aimodel",
            tokenizerPath: "/models/tokenizer.json",
            styleRawValue: "chat3",
            maxNewTokens: 96,
            identity: "test"
        )
        try await CoreAIMintWorker.serveBatch(
            configuration: config,
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            makeEngine: { _ in
                await counter.record()
                return engine
            }
        )
        try output.fileHandleForWriting.close()

        #expect(await counter.calls == 1)
        #expect(await engine.prompts == ["first", "fail", "third"])
        #expect(output.fileHandleForReading.readDataToEndOfFile()
            == Data("claim:first\u{0}\u{0}claim:third\u{0}".utf8))
    }

    @Test("response framing strips embedded NUL bytes")
    func responseFramingStripsEmbeddedNUL() {
        #expect(CoreAIMintWorker.responseFrame("ab\u{0}cd") == Data("abcd\u{0}".utf8))
    }
}
#endif
