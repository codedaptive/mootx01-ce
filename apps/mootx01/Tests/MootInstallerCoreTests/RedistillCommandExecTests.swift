// RedistillCommandExecTests.swift — `mootx01 redistill` end to end through
// the built binary, against a throwaway unencrypted estate under a temporary
// MOOTX01_DATA_DIR. MOOTX01_ESTATE_LIFETIME=ephemeral keeps identity keys
// in memory so no login-Keychain item is written or left behind.

#if os(macOS)
import Foundation
import Testing

private final class RedistillExecBundleFinder {}

@Suite("redistill — exec through the built mootx01 binary", .serialized)
struct RedistillCommandExecTests {

    private func builtBinaryURL() throws -> URL {
        let url = Bundle(for: RedistillExecBundleFinder.self).bundleURL
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

    @Test("dry run reports the converter and stale count and writes nothing; a real run dispatches moot_redistill")
    func dryRunThenRun() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redistill-exec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }

        let created = try exec(["db", "create", "bench", "--no-encrypt"], dataDir: dataDir)
        #expect(created.status == 0, "db create failed: \(created.stderr)")

        let dry = try exec(["redistill", "--db", "bench", "--dry-run"], dataDir: dataDir)
        #expect(dry.status == 0, "dry run failed: \(dry.stderr)")
        #expect(dry.stdout.contains("estate: bench"))
        #expect(dry.stdout.contains("converter: "))
        #expect(dry.stdout.contains("rows stale under the active converter: "))
        #expect(dry.stdout.contains("dry run: no rows written"))
        #expect(!dry.stdout.contains("moot_redistill: sweep complete"))

        let run = try exec(["redistill", "--db", "bench"], dataDir: dataDir)
        #expect(run.status == 0, "run failed: \(run.stderr)")
        #expect(run.stdout.contains("moot_redistill: sweep complete"))
        #expect(run.stdout.contains("itemsRedistilled: "))
        #expect(run.stdout.contains("reindexed: both lanes (BM25 + dense)"))
        #expect(run.stdout.contains("elapsed: "))
    }

    @Test("an unknown estate is refused")
    func unknownEstateIsRefused() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("redistill-exec-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let missing = try exec(["redistill", "--db", "nope"], dataDir: dataDir)
        #expect(missing.status != 0)
        #expect(missing.stderr.contains("not found"))
    }
}
#endif
