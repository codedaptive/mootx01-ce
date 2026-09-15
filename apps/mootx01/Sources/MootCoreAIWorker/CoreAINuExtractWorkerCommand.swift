import ArgumentParser
import FactExtractionKitProviders
import Foundation

#if os(macOS) && canImport(CoreAI)
public struct CoreAINuExtractWorkerCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "coreai-nuextract-worker",
        abstract: "Resident CoreAI NuExtract worker (internal).",
        shouldDisplay: false)

    @Option(name: .customLong("asset"), help: .hidden)
    var assetPath: String

    @Option(name: .customLong("tokenizer"), help: .hidden)
    var tokenizerPath: String

    @Option(name: .customLong("model-version"), help: .hidden)
    var modelVersion: String

    @Option(name: .customLong("maximum-input-characters"), help: .hidden)
    var maximumInputCharacters: Int = 12_000

    @Option(name: .customLong("maximum-facts"), help: .hidden)
    var maximumFacts: Int = 16

    @Option(name: .customLong("maximum-new-tokens"), help: .hidden)
    var maximumNewTokens: Int = 1_024

    public init() {}

    public mutating func run() async throws {
        guard #available(macOS 27.0, *) else {
            throw ValidationError(
                "coreai-nuextract-worker requires macOS 27 or newer")
        }
        let worker = try CoreAINuExtractWorkerConfiguration(
            assetURL: URL(fileURLWithPath: assetPath),
            tokenizerURL: URL(fileURLWithPath: tokenizerPath),
            modelVersion: modelVersion,
            maximumInputCharacters: maximumInputCharacters,
            maximumFactsPerSource: maximumFacts,
            maximumNewTokens: maximumNewTokens)
        try await CoreAINuExtractWorkerServer.serve(configuration: worker)
    }
}
#elseif os(macOS)
public struct CoreAINuExtractWorkerCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "coreai-nuextract-worker",
        abstract: "CoreAI NuExtract worker unavailable in this SDK.",
        shouldDisplay: false)

    public init() {}

    public mutating func run() async throws {
        throw ValidationError(
            "coreai-nuextract-worker requires a CoreAI-capable SDK")
    }
}
#endif
