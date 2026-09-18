import Foundation
import Testing
@testable import mcp_benchmarker

// RunEnvironmentTests.swift — RunEnvironment struct and deferred-judge coverage (JB-01).
//
// Synthetic tests require no live estate or product binary. The final test is
// explicitly opt-in and reads two already-built product binaries only through
// `--version`.
//   A: JSON round-trip — encode a constructed RunEnvironment, decode back, verify fields.
//   B: collect smoke  — call RunEnvironment.collect(nil), verify non-empty strings and
//      non-zero ram_bytes. No subprocess asserted (binaries absent in CI).
//   C: JSONL format   — verify deferred-judge JSONL header/question line shapes.
//   D: judge-batch    — verify judge-batch verdict file parsing (synthetic JSONL).
//   E: live identity  — collect the declared recall converter from both ports.

/// The live identity proof is deliberately opt-in: it launches each supplied
/// binary with `--version`, which reads no estate. Run it with:
/// `MOOT_BENCH_SWIFT_BINARY_PATH=<swift-bin>
///  MOOT_BENCH_RUST_BINARY_PATH=<rust-bin>
///  SWIFT_TEST_ARGS="--filter RunEnvironmentTests/liveBinaryRecallIdentity"
///  make test-one DIR=<this harness package's path from the repository root>`.
private let liveIdentityBinaryPaths: [String] = [
    "MOOT_BENCH_SWIFT_BINARY_PATH",
    "MOOT_BENCH_RUST_BINARY_PATH",
].compactMap { key in
    guard let path = ProcessInfo.processInfo.environment[key],
          FileManager.default.isExecutableFile(atPath: path)
    else { return nil }
    return path
}

@Suite("RunEnvironmentTests")
struct RunEnvironmentTests {

    // MARK: - Test A: JSON round-trip

    @Test("round-trip: encode then decode preserves all fields")
    func testRoundTrip() throws {
        let original = RunEnvironment(
            hostname:         "build-mac-01",
            modelIdentifier:  "Mac16,11",
            modelName:        "MacBook Air (M4, 2025)",
            chipName:         "Apple M4",
            ramBytes:         UInt64(16) * 1024 * 1024 * 1024,
            diskBytes:        UInt64(500) * 1024 * 1024 * 1024,
            macosVersion:     "macOS 15.4",
            mootx01Version:   "1.1",
            mootx01BuildDate: "2026-08-05",
            mootx01WorkingTreeHead: "abc1234",
            mootx01BinarySha256: "deadbeef",
            runMode:          "quiet",
            protocolVersion:  "v0.1",
            loadAverage1m:    1.25,
            logicalCpus:      8
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(RunEnvironment.self, from: data)

        #expect(decoded.hostname         == original.hostname)
        #expect(decoded.modelIdentifier  == original.modelIdentifier)
        #expect(decoded.modelName        == original.modelName)
        #expect(decoded.chipName         == original.chipName)
        #expect(decoded.ramBytes         == original.ramBytes)
        #expect(decoded.diskBytes        == original.diskBytes)
        #expect(decoded.macosVersion     == original.macosVersion)
        #expect(decoded.mootx01Version   == original.mootx01Version)
        #expect(decoded.mootx01BuildDate == original.mootx01BuildDate)
        #expect(decoded.mootx01WorkingTreeHead == original.mootx01WorkingTreeHead)
        #expect(decoded.mootx01BinarySha256 == original.mootx01BinarySha256)
        #expect(decoded.runMode          == original.runMode)
        #expect(decoded.protocolVersion  == original.protocolVersion)
    }

    // MARK: - C7: binary digest and report stamps

    // Known-answer vectors pin fileSha256Hex to standard SHA-256 — the Rust
    // twin (sha256_hex / file_sha256_hex) is pinned against the same vectors,
    // which keeps the two ports' mootx01_binary_sha256 fields byte-comparable.
    @Test("fileSha256Hex matches known SHA-256 vectors")
    func testFileSha256KnownAnswers() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-env-sha-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let empty = dir.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(fileSha256Hex(path: empty.path)
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        let abc = dir.appendingPathComponent("abc")
        try Data("abc".utf8).write(to: abc)
        #expect(fileSha256Hex(path: abc.path)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        #expect(fileSha256Hex(path: dir.appendingPathComponent("missing").path) == nil)
    }

    @Test("collect stamps protocol version, run mode, and binary digest")
    func testCollectStampsC7Fields() throws {
        // nil binary: digest unknown, protocol version still stamped.
        let env = RunEnvironment.collect(mootx01BinaryPath: nil, runMode: "quiet")
        #expect(env.runMode == "quiet")
        #expect(env.protocolVersion == benchmarkProtocolVersion)
        #expect(env.mootx01BinarySha256 == "unknown")

        // Default run mode is "unspecified".
        #expect(RunEnvironment.collect(mootx01BinaryPath: nil).runMode == "unspecified")

        // Measured load: sampled (>= 0 on any healthy host; -1 only when
        // getloadavg fails) with a real core count.
        #expect(env.loadAverage1m >= 0 || env.loadAverage1m == -1)
        #expect(env.logicalCpus >= 1)
    }

    @Test("round-trip: JSON uses snake_case field names")
    func testSnakeCaseKeys() throws {
        let env = RunEnvironment(
            hostname:         "h",
            modelIdentifier:  "m",
            modelName:        "n",
            chipName:         "c",
            ramBytes:         0,
            diskBytes:        0,
            macosVersion:     "v",
            mootx01Version:   "1.1",
            mootx01BuildDate: "2026-01-01",
            mootx01WorkingTreeHead: "abc",
            mootx01BinarySha256: "d",
            runMode:          "u",
            protocolVersion:  "p",
            loadAverage1m:    0,
            logicalCpus:      1
        )
        let data = try JSONEncoder().encode(env)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Verify snake_case contract — these are the keys the Rust twin must also emit.
        #expect(json["hostname"]           != nil)
        #expect(json["model_identifier"]   != nil)
        #expect(json["model_name"]         != nil)
        #expect(json["chip_name"]          != nil)
        #expect(json["ram_bytes"]          != nil)
        #expect(json["disk_bytes"]         != nil)
        #expect(json["macos_version"]      != nil)
        #expect(json["mootx01_version"]    != nil)
        #expect(json["mootx01_build_date"] != nil)
        #expect(json["mootx01_working_tree_head"] != nil)
        #expect(json["load_average_1m"]    != nil)
        #expect(json["logical_cpus"]       != nil)
        // camelCase must NOT appear
        #expect(json["modelIdentifier"]    == nil)
        #expect(json["modelName"]          == nil)
        #expect(json["chipName"]           == nil)
        #expect(json["ramBytes"]           == nil)
        #expect(json["diskBytes"]          == nil)
        #expect(json["macosVersion"]       == nil)
        #expect(json["mootx01Version"]     == nil)
        #expect(json["mootx01BuildDate"]   == nil)
        #expect(json["mootx01GitHead"]     == nil)
        #expect(json["mootx01_git_head"]  == nil, "old key must be gone after the working-tree rename")
    }

    // MARK: - Test B: collect smoke

    @Test("collect smoke: collect(nil) returns non-empty hostname and nonzero ramBytes")
    func testCollectSmoke() {
        // mootx01BinaryPath = nil → mootx01 fields are "unknown"; machine fields are real.
        let env = RunEnvironment.collect(mootx01BinaryPath: nil)

        #expect(!env.hostname.isEmpty,         "hostname must not be empty")
        #expect(env.ramBytes > 0,              "ramBytes must be positive")
        // When binary path is nil, provenance fields degrade to "unknown".
        #expect(env.mootx01Version   == "unknown")
        #expect(env.mootx01BuildDate == "unknown")
        #expect(env.mootx01WorkingTreeHead == "unknown")
    }

    @Test("collect parses version and recall converter identity")
    func testVersionAndRecallConverterParsing() throws {
        // Reach the private parser through a synthetic binary. The product keeps
        // its stable first line, then emits both converter roles on later lines.
        let tmpScript = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mock-mootx01-\(Int.random(in: 100_000...999_999))")
        let scriptContent = """
        #!/bin/sh
        echo '1.1.0-beta-14 EE (2026-08-05)'
        echo 'converter hydration complete-form@complete-form-visible-v6 complete-form-visible-v6'
        echo 'converter recall intent-span-v23-attributed@intent-span-v23.2-attributed-prose intent-span-v23.2-attributed-prose'
        """
        try scriptContent.write(to: tmpScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: tmpScript.path)
        defer { try? FileManager.default.removeItem(at: tmpScript) }

        let env = RunEnvironment.collect(mootx01BinaryPath: tmpScript.path)
        #expect(env.mootx01Version   == "1.1",
                "parser must strip patch + prerelease suffix: '1.1.0-beta-14 EE' → '1.1'")
        #expect(env.mootx01BuildDate == "2026-08-05",
                "parser must extract ISO date from parentheses: '(2026-08-05)'")
        #expect(env.converterID == "intent-span-v23-attributed@intent-span-v23.2-attributed-prose")
        #expect(env.converterVersion == "intent-span-v23.2-attributed-prose")

        let identity = IdentityEnvironment.collect(mootx01BinaryPath: tmpScript.path)
        #expect(identity.converterID == env.converterID)
        #expect(identity.converterVersion == env.converterVersion)
    }

    @Test("live binaries report and collect recall converter identity", .enabled(
        if: liveIdentityBinaryPaths.count == 2,
        "opt-in: set MOOT_BENCH_SWIFT_BINARY_PATH and MOOT_BENCH_RUST_BINARY_PATH"
    ))
    func liveBinaryRecallIdentity() {
        let expectedID = "intent-span-v23-attributed@intent-span-v23.2-attributed-prose"
        for path in liveIdentityBinaryPaths {
            let run = RunEnvironment.collect(mootx01BinaryPath: path)
            let identity = IdentityEnvironment.collect(mootx01BinaryPath: path)
            #expect(run.converterID == expectedID)
            #expect(run.converterVersion != "unknown")
            #expect(identity.converterID == expectedID)
            #expect(identity.converterVersion == run.converterVersion)
        }
    }

}
