// DbCompositionCommandExecTests.swift — `mootx01 db composition` end to end
// through the built binary, against a throwaway unencrypted estate under a
// temporary MOOTX01_DATA_DIR. MOOTX01_ESTATE_LIFETIME=ephemeral keeps identity
// keys in memory so no login-Keychain item is written or left behind.

#if os(macOS)
import Foundation
import Testing

private final class CompositionExecBundleFinder {}

@Suite("db composition — exec through the built mootx01 binary", .serialized)
struct DbCompositionCommandExecTests {

    private func builtBinaryURL() throws -> URL {
        let url = Bundle(for: CompositionExecBundleFinder.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("mootx01", isDirectory: false)
        try #require(FileManager.default.isExecutableFile(atPath: url.path),
                     "built mootx01 binary not found at \(url.path)")
        return url
    }

    private func exec(_ args: [String], dataDir: URL) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = try builtBinaryURL()
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["MOOTX01_DATA_DIR"] = dataDir.path
        environment["MOOTX01_SKIP_CHARTERS"] = "1"
        // ephemeral lifetime: the spawned binary uses InMemoryEstateIdentityKeyStore
        // so no login-Keychain item is created for this throwaway estate.
        environment["MOOTX01_ESTATE_LIFETIME"] = "ephemeral"
        environment.removeValue(forKey: "ARIA_MCP_SQLITE_PATH")
        // The estate is created under the production default, whatever the
        // test runner's environment says.
        environment.removeValue(forKey: "MOOT_INDEX_COMPOSITION")
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = Pipe()
        try process.run()
        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: stdoutData, as: UTF8.self),
                String(decoding: stderrData, as: UTF8.self))
    }

    @Test("shows the stored policy; --set stores a new one, rebuilds every row under it, and the next show reports it")
    func showThenSet() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("composition-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let created = try exec(["db", "create", "bench", "--no-encrypt"], dataDir: dataDir)
        #expect(created.status == 0, "db create failed: \(created.stderr)")

        // A fresh estate is born under the production default.
        let shown = try exec(["db", "composition", "--db", "bench"], dataDir: dataDir)
        #expect(shown.status == 0, "show failed: \(shown.stderr)")
        #expect(shown.stdout.contains("estate: bench"))
        #expect(shown.stdout.contains("index_composition_policy: lex=original;dense=distilled"))
        #expect(!shown.stdout.contains("rows reindexed"))

        // Change it: the setting is stored and every lane is rebuilt.
        let newID = "lex=originalPlusAdornments;dense=distilled"
        let set = try exec(["db", "composition", "--db", "bench", "--set", newID], dataDir: dataDir)
        #expect(set.status == 0, "set failed: \(set.stderr)")
        #expect(set.stdout.contains("index_composition_policy: \(newID)"))
        #expect(set.stdout.contains("rows reindexed: "))
        #expect(set.stdout.contains("elapsed: "))

        // The next show reports the stored id: a second open under the new
        // policy succeeds and reads the setting back.
        let shownAgain = try exec(["db", "composition", "--db", "bench"], dataDir: dataDir)
        #expect(shownAgain.status == 0, "second show failed: \(shownAgain.stderr)")
        #expect(shownAgain.stdout.contains("index_composition_policy: \(newID)"))
    }

    @Test("an invalid policy id is refused before anything is written")
    func invalidIDIsRefused() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("composition-exec-invalid-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let created = try exec(["db", "create", "bench", "--no-encrypt"], dataDir: dataDir)
        #expect(created.status == 0, "db create failed: \(created.stderr)")

        let refused = try exec(["db", "composition", "--db", "bench", "--set", "cell B"], dataDir: dataDir)
        #expect(refused.status != 0)
        #expect(refused.stderr.contains("not an index composition policy id"))
        // Nothing was opened or written: the estate file was never created.
        let estateFile = dataDir.appendingPathComponent("databases/bench/estate.sqlite")
        #expect(!FileManager.default.fileExists(atPath: estateFile.path),
                "a refused --set must not open the estate")

        let shown = try exec(["db", "composition", "--db", "bench"], dataDir: dataDir)
        #expect(shown.status == 0, "show failed: \(shown.stderr)")
        #expect(shown.stdout.contains("index_composition_policy: lex=original;dense=distilled"))
    }

    @Test("an unknown estate is refused")
    func unknownEstateIsRefused() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("composition-exec-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let missing = try exec(["db", "composition", "--db", "nope"], dataDir: dataDir)
        #expect(missing.status != 0)
        #expect(missing.stderr.contains("not found"))
    }
}
#endif
