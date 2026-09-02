// CoreAIMintWorkerCommand.swift
//
// Hidden `mootx01 coreai-mint-worker` process boundary for Core AI minting.
// The worker owns exactly one CoreAIEngine for its lifetime and speaks the
// same capability-probed, NUL-framed resident protocol as AdornmentLib's
// ResidentMintSession. Closing stdin releases the engine by ending the
// process; the parent can therefore recycle before runtime memory pressure or
// idle-reap without placing Core AI state inside the long-lived moot server.

#if os(macOS) && canImport(CoreAI)
import AdornmentLib
import ArgumentParser
import Foundation

public struct CoreAIMintWorkerCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "coreai-mint-worker",
        abstract: "Resident Core AI mint worker (internal).",
        shouldDisplay: false
    )

    @Flag(name: .customLong("mint-capabilities"), help: .hidden)
    var mintCapabilities = false

    @Flag(name: .customLong("batch"), help: .hidden)
    var batch = false

    @Option(name: .customLong("asset"), help: .hidden)
    var assetPath: String?

    @Option(name: .customLong("tokenizer"), help: .hidden)
    var tokenizerPath: String?

    @Option(name: .customLong("style"), help: .hidden)
    var style: String?

    @Option(name: .customLong("max-new-tokens"), help: .hidden)
    var maxNewTokens: Int?

    @Option(name: .customLong("identity"), help: .hidden)
    var identity: String?

    public init() {}

    enum Mode: Equatable {
        case capabilities
        case batch(CoreAIMintWorkerConfiguration)
    }

    func resolvedMode() throws -> Mode {
        if mintCapabilities {
            guard !batch else {
                throw ValidationError(
                    "--mint-capabilities and --batch are mutually exclusive")
            }
            return .capabilities
        }

        guard batch else {
            throw ValidationError("coreai-mint-worker requires --batch")
        }
        guard let assetPath else {
            throw ValidationError("coreai-mint-worker --batch requires --asset")
        }
        guard let tokenizerPath else {
            throw ValidationError("coreai-mint-worker --batch requires --tokenizer")
        }
        guard let style else {
            throw ValidationError("coreai-mint-worker --batch requires --style")
        }
        guard let maxNewTokens else {
            throw ValidationError(
                "coreai-mint-worker --batch requires --max-new-tokens")
        }

        do {
            return .batch(try CoreAIMintWorkerConfiguration(
                assetPath: assetPath,
                tokenizerPath: tokenizerPath,
                styleRawValue: style,
                maxNewTokens: maxNewTokens,
                identity: identity
            ))
        } catch let error as CoreAIMintWorkerConfiguration.Error {
            throw ValidationError(error.description)
        }
    }

    public mutating func run() async throws {
        switch try resolvedMode() {
        case .capabilities:
            FileHandle.standardOutput.write(CoreAIMintWorker.capabilityPayload)
        case .batch(let configuration):
            try await CoreAIMintWorker.serveBatch(
                configuration: configuration,
                input: .standardInput,
                output: .standardOutput
            )
        }
    }
}

struct CoreAIMintWorkerConfiguration: Equatable, Sendable {
    enum Error: Swift.Error, CustomStringConvertible, Equatable {
        case assetPathMustBeAbsolute
        case tokenizerPathMustBeAbsolute
        case unsupportedStyle(String)
        case invalidMaxNewTokens(Int)
        case emptyIdentity

        var description: String {
            switch self {
            case .assetPathMustBeAbsolute:
                return "--asset must be an absolute path"
            case .tokenizerPathMustBeAbsolute:
                return "--tokenizer must be an absolute path"
            case .unsupportedStyle(let style):
                return "unsupported --style '\(style)' (expected chat, chat3, plain, plain-json, or nuextract)"
            case .invalidMaxNewTokens(let value):
                return "--max-new-tokens must be positive (got \(value))"
            case .emptyIdentity:
                return "--identity must not be empty"
            }
        }
    }

    let assetPath: String
    let tokenizerPath: String
    let style: CoreAIPromptStyle
    let maxNewTokens: Int
    let identity: String

    init(
        assetPath: String,
        tokenizerPath: String,
        styleRawValue: String,
        maxNewTokens: Int,
        identity: String?
    ) throws {
        guard (assetPath as NSString).isAbsolutePath else {
            throw Error.assetPathMustBeAbsolute
        }
        guard (tokenizerPath as NSString).isAbsolutePath else {
            throw Error.tokenizerPathMustBeAbsolute
        }
        guard let parsedStyle = CoreAIPromptStyle(rawValue: styleRawValue) else {
            throw Error.unsupportedStyle(styleRawValue)
        }
        guard maxNewTokens > 0 else {
            throw Error.invalidMaxNewTokens(maxNewTokens)
        }
        let resolvedIdentity = identity
            ?? URL(fileURLWithPath: assetPath).deletingPathExtension().lastPathComponent
        guard !resolvedIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.emptyIdentity
        }

        self.assetPath = assetPath
        self.tokenizerPath = tokenizerPath
        self.style = parsedStyle
        self.maxNewTokens = maxNewTokens
        self.identity = resolvedIdentity
    }
}

protocol CoreAIMintWorkerEngine: Sendable {
    func mint(prompt: String) async -> String?
}

@available(macOS 27.0, *)
extension CoreAIEngine: CoreAIMintWorkerEngine {}

enum CoreAIMintWorker {
    typealias EngineFactory = @Sendable (
        CoreAIMintWorkerConfiguration
    ) async throws -> any CoreAIMintWorkerEngine

    static let capabilityPayload = Data("batch\n".utf8)

    static func serveBatch(
        configuration: CoreAIMintWorkerConfiguration,
        input: FileHandle,
        output: FileHandle,
        makeEngine: EngineFactory = makeCoreAIEngine
    ) async throws {
        // Construct exactly once. This local is the sole model owner in the
        // child and remains alive until EOF or a fatal stream error.
        let engine = try await makeEngine(configuration)
        var decoder = NULFrameDecoder()

        while true {
            let chunk = input.availableData
            if chunk.isEmpty {
                return
            }
            for frame in decoder.append(chunk) {
                let prompt = String(decoding: frame, as: UTF8.self)
                let claim = await engine.mint(prompt: prompt) ?? ""
                output.write(responseFrame(claim))
            }
        }
    }

    static func responseFrame(_ claim: String) -> Data {
        var data = Data(claim.utf8.filter { $0 != 0 })
        data.append(0)
        return data
    }

    private static func makeCoreAIEngine(
        configuration: CoreAIMintWorkerConfiguration
    ) async throws -> any CoreAIMintWorkerEngine {
        guard #available(macOS 27.0, *) else {
            throw ValidationError("coreai-mint-worker requires macOS 27 or newer")
        }
        return try await CoreAIEngine(
            assetPath: configuration.assetPath,
            tokenizerPath: configuration.tokenizerPath,
            identity: configuration.identity,
            style: configuration.style,
            maxNewTokens: configuration.maxNewTokens
        )
    }
}

struct NULFrameDecoder: Sendable {
    private(set) var pending = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var frames: [Data] = []
        while let nul = pending.firstIndex(of: 0) {
            frames.append(pending.prefix(upTo: nul))
            pending.removeSubrange(...nul)
        }
        return frames
    }
}
#elseif os(macOS)
import ArgumentParser

/// SDK fallback keeps the unified CLI buildable when Core AI is absent.
/// Operational invocations fail before reading stdin; no model path exists.
public struct CoreAIMintWorkerCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "coreai-mint-worker",
        abstract: "Resident Core AI mint worker (unavailable in this SDK).",
        shouldDisplay: false
    )

    public init() {}

    public mutating func run() async throws {
        throw ValidationError("coreai-mint-worker requires a Core AI capable SDK")
    }
}
#endif
