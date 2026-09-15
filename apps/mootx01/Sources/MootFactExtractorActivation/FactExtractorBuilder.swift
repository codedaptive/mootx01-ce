import FactExtractionKit
import FactExtractionKitProviders
import Foundation
import FoundationModels
import GeniusLocusKit
import MootFoundationModelsKit
import MootProductIdentity

/// Product composition for the Swift fact-extraction providers. The estate
/// preference decides the provider; the on/off preference remains the master
/// gate. Model paths are loaded through MootProductIdentity.Settings, with the
/// staged product model directory as the no-config fallback.
public enum FactExtractorBuilder {
    public static let bundledModelID = "nuextract-tiny-v1.5"
    public static let bundledModelVersion = "63e2e80c804d9c97f3f19a4aa25613e7beca83c9"
    public static let bundledCoreAIAssetName = "nuextract-tiny-v1.5-v11s-8k-b1-q8.aimodel"
    public static let bundledTokenizerName = "tokenizer.json"

    public static func build(
        masterSetting: EstatePreferenceValue,
        extractorSetting: EstatePreferenceValue,
        settingsDirectory: URL,
        workerExecutableURL: URL,
        log: @escaping @Sendable (String) -> Void = { line in
            guard let data = "\(line)\n".data(using: .utf8) else { return }
            try? FileHandle.standardError.write(contentsOf: data)
        }
    ) -> (any FactExtractor)? {
#if os(macOS)
        build(
            masterSetting: masterSetting,
            extractorSetting: extractorSetting,
            settings: MootProductIdentity.Settings.load(
                configurationDirectory: settingsDirectory),
            settingsDirectory: settingsDirectory,
            workerExecutableURL: workerExecutableURL,
            appleAvailable: {
                SystemLanguageModel.default.availability == .available
            },
            makeApple: {
                AppleFoundationFactExtractor.systemDefault()
            },
            makeNuExtract: { asset, tokenizer, version in
                try CoreAINuExtractFactExtractor(
                    workerExecutableURL: workerExecutableURL,
                    workerArgumentsPrefix: ["coreai-nuextract-worker"],
                    assetURL: asset,
                    tokenizerURL: tokenizer,
                    modelVersion: version)
            },
            log: log)
#else
        if masterSetting == .on, extractorSetting == .nuextract {
            log("mootx01: NuExtract fact extractor is selected but unavailable on iOS")
            return nil
        }
        return build(
            masterSetting: masterSetting,
            extractorSetting: extractorSetting,
            settings: MootProductIdentity.Settings.load(
                configurationDirectory: settingsDirectory),
            settingsDirectory: settingsDirectory,
            workerExecutableURL: workerExecutableURL,
            appleAvailable: {
                SystemLanguageModel.default.availability == .available
            },
            makeApple: {
                AppleFoundationFactExtractor.systemDefault()
            },
            makeNuExtract: { _, _, _ in
                throw FactExtractionError.unavailable(
                    "CoreAI NuExtract is unavailable on iOS")
            },
            log: log)
#endif
    }

    static func build(
        masterSetting: EstatePreferenceValue,
        extractorSetting: EstatePreferenceValue,
        settings: MootProductIdentity.Settings,
        settingsDirectory: URL,
        workerExecutableURL: URL,
        appleAvailable: () -> Bool,
        makeApple: () -> any FactExtractor,
        makeNuExtract: (URL, URL, String) throws -> any FactExtractor,
        log: (String) -> Void
    ) -> (any FactExtractor)? {
        guard masterSetting == .on else { return nil }

        switch extractorSetting {
        case .apple:
            guard appleAvailable() else {
                log("mootx01: Apple Foundation Models fact extractor is selected but unavailable")
                return nil
            }
            return makeApple()

        case .nuextract:
            guard let assets = resolveNuExtractAssets(
                settings: settings,
                settingsDirectory: settingsDirectory,
                workerExecutableURL: workerExecutableURL)
            else {
                log("mootx01: NuExtract fact extractor is selected but no configured or bundled model is available")
                return nil
            }
            do {
                return try makeNuExtract(
                    assets.assetURL, assets.tokenizerURL, assets.modelVersion)
            } catch {
                log("mootx01: NuExtract fact extractor is unavailable: \(error)")
                return nil
            }

        case .on, .off:
            log("mootx01: unsupported fact_extractor preference \(extractorSetting.rawValue.debugDescription)")
            return nil
        }
    }

    private struct NuExtractAssets {
        let assetURL: URL
        let tokenizerURL: URL
        let modelVersion: String
    }

    private static func resolveNuExtractAssets(
        settings: MootProductIdentity.Settings,
        settingsDirectory: URL,
        workerExecutableURL: URL
    ) -> NuExtractAssets? {
        let configuredAsset = settings.factExtractionCoreAIAsset
        let configuredTokenizer = settings.factExtractionCoreAITokenizer
        if configuredAsset != nil || configuredTokenizer != nil {
            guard let configuredAsset, let configuredTokenizer else { return nil }
            return NuExtractAssets(
                assetURL: URL(fileURLWithPath: configuredAsset),
                tokenizerURL: URL(fileURLWithPath: configuredTokenizer),
                modelVersion: settings.factExtractionModelVersion ?? bundledModelVersion)
        }

        let executableDirectory = workerExecutableURL
            .resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            settingsDirectory
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(bundledModelID, isDirectory: true),
            executableDirectory.deletingLastPathComponent()
                .appendingPathComponent("share/mootx01/models", isDirectory: true)
                .appendingPathComponent(bundledModelID, isDirectory: true),
        ]
        let fileManager = FileManager.default
        for directory in candidates {
            let asset = directory.appendingPathComponent(
                bundledCoreAIAssetName, isDirectory: true)
            let tokenizer = directory.appendingPathComponent(
                bundledTokenizerName, isDirectory: false)
            var assetIsDirectory: ObjCBool = false
            guard fileManager.fileExists(
                    atPath: asset.path, isDirectory: &assetIsDirectory),
                  assetIsDirectory.boolValue,
                  fileManager.isReadableFile(atPath: tokenizer.path) else { continue }
            return NuExtractAssets(
                assetURL: asset,
                tokenizerURL: tokenizer,
                modelVersion: settings.factExtractionModelVersion ?? bundledModelVersion)
        }
        return nil
    }
}
