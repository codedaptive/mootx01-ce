import FactExtractionKit
import FactExtractionKitProviders
import Foundation
import GeniusLocusKit
import MootProductIdentity
import Testing
@testable import MootFactExtractorActivation

@Test("Swift builder obeys the master gate and selects Apple or NuExtract")
func builderSelectionAndMasterGate() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("fact-extractor-builder-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let asset = root.appendingPathComponent("model.aimodel", isDirectory: true)
    try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: true)
    let tokenizer = root.appendingPathComponent("tokenizer.json")
    try Data("{}".utf8).write(to: tokenizer)
    let config = """
    {"fact_extraction":{"coreai_asset":"\(asset.path)","coreai_tokenizer":"\(tokenizer.path)","model_version":"test-v1"}}
    """
    try Data(config.utf8).write(to: root.appendingPathComponent("config.json"))
    let settings = MootProductIdentity.Settings.load(configurationDirectory: root)

    let appleSpec = FactExtractorModelSpec(
        providerID: "apple-test", modelID: "apple", modelVersion: "1",
        schemaVersion: "kgfact-extraction-v1", extractorKind: .foundationModel,
        maximumInputCharacters: 10, maximumFactsPerSource: 1)
    let nuSpec = FactExtractorModelSpec(
        providerID: "nu-test", modelID: "nu", modelVersion: "1",
        schemaVersion: "kgfact-extraction-v1", extractorKind: .specializedModel,
        maximumInputCharacters: 10, maximumFactsPerSource: 1)
    let apple = ClosureFactExtractor(spec: appleSpec) { request in
        FactExtractionResponse(
            sourceDigest: request.sourceDigest, providerID: appleSpec.providerID,
            modelID: appleSpec.modelID, modelVersion: appleSpec.modelVersion,
            schemaVersion: appleSpec.schemaVersion, candidates: [])
    }
    let nu = ClosureFactExtractor(spec: nuSpec) { request in
        FactExtractionResponse(
            sourceDigest: request.sourceDigest, providerID: nuSpec.providerID,
            modelID: nuSpec.modelID, modelVersion: nuSpec.modelVersion,
            schemaVersion: nuSpec.schemaVersion, candidates: [])
    }

    let off = FactExtractorBuilder.build(
        masterSetting: .off, extractorSetting: .apple, settings: settings,
        settingsDirectory: root, workerExecutableURL: root,
        appleAvailable: { true }, makeApple: { apple },
        makeNuExtract: { _, _, _ in nu }, log: { _ in })
    #expect(off == nil)

    let selectedApple = FactExtractorBuilder.build(
        masterSetting: .on, extractorSetting: .apple, settings: settings,
        settingsDirectory: root, workerExecutableURL: root,
        appleAvailable: { true }, makeApple: { apple },
        makeNuExtract: { _, _, _ in nu }, log: { _ in })
    #expect(selectedApple?.spec.providerID == "apple-test")

    let selectedNuExtract = FactExtractorBuilder.build(
        masterSetting: .on, extractorSetting: .nuextract, settings: settings,
        settingsDirectory: root, workerExecutableURL: root,
        appleAvailable: { true }, makeApple: { apple },
        makeNuExtract: { assetURL, tokenizerURL, version in
            #expect(assetURL == asset)
            #expect(tokenizerURL == tokenizer)
            #expect(version == "test-v1")
            return nu
        }, log: { _ in })
    #expect(selectedNuExtract?.spec.providerID == "nu-test")
}
