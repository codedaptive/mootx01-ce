// CoreAIProductMinterConfiguration.swift
//
// Fixed product composition for the first Core AI minter candidate. This is
// intentionally narrower than the benchmark harness: selecting Core AI does
// not expose an arbitrary command, model family, prompt style, or token budget.

#if os(macOS) && canImport(CoreAI)
import AdornmentLib
import Foundation

public struct CoreAIProductMinterConfiguration: Sendable, Equatable {
    public enum ConfigurationError: Swift.Error, CustomStringConvertible, Equatable {
        case unsupportedSelection(String)
        case missingEnvironmentValue(String)
        case pathMustBeAbsolute(String)
        case invalidAsset(String)
        case invalidTokenizer(String)

        public var description: String {
            switch self {
            case .unsupportedSelection(let value):
                return "unsupported Core AI minter selection '\(value)'"
            case .missingEnvironmentValue(let key):
                return "Core AI minter requires \(key)"
            case .pathMustBeAbsolute(let key):
                return "\(key) must be an absolute path"
            case .invalidAsset(let reason):
                return "Core AI asset is unavailable or malformed (\(reason))"
            case .invalidTokenizer(let reason):
                return "Core AI tokenizer is unavailable or malformed (\(reason))"
            }
        }
    }

    public static let selectionKey = "MOOTX01_COREAI_MINTER"
    public static let assetPathKey = "MOOTX01_COREAI_ASSET"
    public static let tokenizerPathKey = "MOOTX01_COREAI_TOKENIZER"
    public static let productSelectionMetaKey = "adornment.product_minter"
    public static let nuextractB1Q8Selection = "nuextract-tiny-v1.5-b1-q8"

    public let assetPath: String
    public let tokenizerPath: String

    public var recipe: MinterRecipe { .nuextractTinyV15B1Q8 }
    public var identity: String { recipe.id }
    public var style: CoreAIPromptStyle { .nuextract }
    public var maxNewTokens: Int { 256 }

    public init(assetPath: String, tokenizerPath: String) {
        self.assetPath = assetPath
        self.tokenizerPath = tokenizerPath
    }

    /// Resolve the fixed candidate from host-supplied asset locations. An
    /// absent selection is the supported disabled state. The paths are inputs
    /// because distribution differs between the CLI install and app bundle;
    /// neither benchmark volumes nor a developer home path belongs in product
    /// code.
    public static func resolve(
        environment: [String: String],
        fileManager: FileManager = .default
    ) throws -> CoreAIProductMinterConfiguration? {
        guard let rawSelection = environment[selectionKey],
              !rawSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        let selection = rawSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selection == nuextractB1Q8Selection else {
            throw ConfigurationError.unsupportedSelection(selection)
        }

        let assetPath = try requiredAbsolutePath(assetPathKey, environment: environment)
        let tokenizerPath = try requiredAbsolutePath(
            tokenizerPathKey, environment: environment)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: assetPath, isDirectory: &isDirectory),
              isDirectory.boolValue,
              URL(fileURLWithPath: assetPath).pathExtension == "aimodel"
        else {
            throw ConfigurationError.invalidAsset("expected a readable .aimodel directory")
        }
        for component in ["metadata.json", "main.mlirb", "main.hash"] {
            let path = URL(fileURLWithPath: assetPath)
                .appendingPathComponent(component, isDirectory: false).path
            guard fileManager.isReadableFile(atPath: path) else {
                throw ConfigurationError.invalidAsset("missing \(component)")
            }
        }

        var tokenizerIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
                atPath: tokenizerPath, isDirectory: &tokenizerIsDirectory),
              !tokenizerIsDirectory.boolValue,
              URL(fileURLWithPath: tokenizerPath).lastPathComponent == "tokenizer.json",
              fileManager.isReadableFile(atPath: tokenizerPath)
        else {
            throw ConfigurationError.invalidTokenizer("expected readable tokenizer.json")
        }

        return CoreAIProductMinterConfiguration(
            assetPath: assetPath,
            tokenizerPath: tokenizerPath
        )
    }

    private static func requiredAbsolutePath(
        _ key: String,
        environment: [String: String]
    ) throws -> String {
        guard let raw = environment[key],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ConfigurationError.missingEnvironmentValue(key)
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (value as NSString).isAbsolutePath else {
            throw ConfigurationError.pathMustBeAbsolute(key)
        }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }
}
#endif
