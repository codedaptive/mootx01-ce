import Foundation
import GeniusLocusKit
import PersistenceKit
import PersistenceKitSQLite
import Testing

private final class PreferenceCommandBundleFinder {}

@Suite("Preference command estate provisioning")
struct PreferenceCommandTests {
    /// Exercise the built CLI, including catalog selection and storage close.
    private func run(_ arguments: [String], estate: URL) throws -> String {
        let binary = Bundle(for: PreferenceCommandBundleFinder.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("mootx01")
        try #require(FileManager.default.isExecutableFile(atPath: binary.path))
        let process = Process()
        process.executableURL = binary
        process.arguments = ["preference"] + arguments + ["--db", estate.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        try #require(process.terminationStatus == 0, "\(text)")
        return text
    }

    @Test func freshEstateHasManifestDatabaseAndPersistentPreference() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("preference-command-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("nested/scratch")
        #expect(try run(["set", "fact_extraction", "off"], estate: directory) == "fact_extraction off\n")
        #expect(try run(["get", "fact_extraction"], estate: directory) == "off\n")
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))
            == Set(["estate.json", "estate.sqlite"]))
        let record = EstateRecord(name: "scratch", directory: directory, kind: .transient)
        let manifest = try EstateCatalog.readManifest(of: record)
        #expect(manifest.name == "scratch")
        #expect(manifest.schemaVersion == GeniusLocusKitSchema.version)
        #expect(manifest.formatVersion == .current)
        #expect(manifest.encryption == .plaintext)
        let originalManifest = try Data(contentsOf: record.manifestURL)

        // A subsequent preference write must not rewrite estate identity or
        // advance the database's format on an existing estate.
        let storage = try SQLiteStorage(configuration: EstateConfiguration(
            estateID: UUID(), backend: .sqlite(url: record.databaseURL, busyTimeout: 5.0)))
        do {
            let format = EstateFormatStore(storage: storage)
            #expect(try await format.readIfPresent() == .current)
            try await format.stamp(.v1_8, now: Date(timeIntervalSince1970: 0))
            #expect(try run(["set", "consolidation", "off"], estate: directory) == "consolidation off\n")
            #expect(try await format.readIfPresent() == .v1_8)
            #expect(try Data(contentsOf: record.manifestURL) == originalManifest)
            await storage.close()
        } catch {
            await storage.close()
            throw error
        }
    }
}
