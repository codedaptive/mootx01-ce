import Foundation
import Testing
@testable import CorpusKitProviders

@Suite("Arctic model-directory resolution")
struct ArcticModelDirectoryResolverTests {
    private func temporaryDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeArcticModelDirectory(_ modelDirectory: URL) throws {
        let compiledModel = modelDirectory
            .appendingPathComponent("ArcticEmbedS.mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: compiledModel, withIntermediateDirectories: true)
        let fixtureDirectory = try #require(
            Bundle.module.resourceURL?.appendingPathComponent(
                "minilm-l6-v2-w60", isDirectory: true))
        try FileManager.default.copyItem(
            at: fixtureDirectory.appendingPathComponent("vocab.txt"),
            to: modelDirectory.appendingPathComponent("vocab.txt"))
    }

    private func makeArcticResourceBundle(in root: URL) throws -> (Bundle, URL) {
        let bundleURL = root.appendingPathComponent("ArcticFixture.bundle", isDirectory: true)
        let resources = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let modelDirectory = resources
            .appendingPathComponent(EncoderModelSeed.modelID, isDirectory: true)
        try writeArcticModelDirectory(modelDirectory)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.mootx01.tests.ArcticFixture",
            "CFBundleName": "ArcticFixture",
            "CFBundlePackageType": "BNDL",
            "CFBundleVersion": "1",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        return (try #require(Bundle(url: bundleURL)), modelDirectory)
    }

    @Test("active Arctic seed resolves from the download slot")
    func seededArcticDownloadSlotResolves() throws {
        #expect(EncoderModelSeed.modelID == "arctic-embed-s-w60")
        let dataDirectory = try temporaryDirectory("arctic-resolver")
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let modelDirectory = dataDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(EncoderModelSeed.modelID, isDirectory: true)
        try writeArcticModelDirectory(modelDirectory)

        let resolved = ModelDirectoryResolver.encoderModelDirectory(
            for: EncoderModelSeed.modelID,
            dataDirectory: dataDirectory,
            bundle: .main)
        #expect(resolved == modelDirectory)
    }

    @Test("active Arctic seed resolves from a normal resource bundle")
    func seededArcticBundleSlotResolves() throws {
        let root = try temporaryDirectory("arctic-bundle-resolver")
        defer { try? FileManager.default.removeItem(at: root) }
        let (bundle, modelDirectory) = try makeArcticResourceBundle(in: root)

        let resolved = ModelDirectoryResolver.encoderModelDirectory(
            for: EncoderModelSeed.modelID,
            dataDirectory: root.appendingPathComponent("empty-data", isDirectory: true),
            bundle: bundle)
        #expect(resolved?.resolvingSymlinksInPath() == modelDirectory.resolvingSymlinksInPath())
    }

    @Test("download slot takes precedence over a valid bundle")
    func seededArcticDownloadPrecedesBundle() throws {
        let root = try temporaryDirectory("arctic-precedence")
        defer { try? FileManager.default.removeItem(at: root) }
        let (bundle, _) = try makeArcticResourceBundle(in: root)
        let dataDirectory = root.appendingPathComponent("data", isDirectory: true)
        let download = dataDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(EncoderModelSeed.modelID, isDirectory: true)
        try writeArcticModelDirectory(download)

        let resolved = ModelDirectoryResolver.encoderModelDirectory(
            for: EncoderModelSeed.modelID,
            dataDirectory: dataDirectory,
            bundle: bundle)
        #expect(resolved == download)
    }

    @Test("active Arctic seed rejects a missing compiled model")
    func seededArcticMissingFileReturnsNil() throws {
        let dataDirectory = try temporaryDirectory("arctic-missing-file")
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let modelDirectory = dataDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(EncoderModelSeed.modelID, isDirectory: true)
        try writeArcticModelDirectory(modelDirectory)
        try FileManager.default.removeItem(
            at: modelDirectory.appendingPathComponent("ArcticEmbedS.mlmodelc"))

        #expect(ModelDirectoryResolver.encoderModelDirectory(
            for: EncoderModelSeed.modelID,
            dataDirectory: dataDirectory,
            bundle: .main) == nil)
    }

    @Test("active Arctic seed rejects a tokenizer hash mismatch")
    func seededArcticVocabMismatchReturnsNil() throws {
        let dataDirectory = try temporaryDirectory("arctic-bad-vocab")
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let modelDirectory = dataDirectory
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(EncoderModelSeed.modelID, isDirectory: true)
        try writeArcticModelDirectory(modelDirectory)
        try Data("wrong-vocab".utf8).write(
            to: modelDirectory.appendingPathComponent("vocab.txt"), options: .atomic)

        #expect(ModelDirectoryResolver.encoderModelDirectory(
            for: EncoderModelSeed.modelID,
            dataDirectory: dataDirectory,
            bundle: .main) == nil)
    }
}
