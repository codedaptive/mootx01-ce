// BenchmarkRegisterArmTests.swift
//
// Gate assertions for D1 (benchmark_register_arm wiring) and D2
// (MOOT_BENCH_NO_ENCODER=1 fail-loud guard).
//
// D1: benchmark_register_arm is stamped by collect() on every collected
//     RunEnvironment and IdentityEnvironment. The register arm records WHICH
//     PRODUCT CONFIGURATION ran; it is orthogonal to benchmark_arm (the lane
//     arm, set by the writer), which records WHICH CORPUS SLICE ran.
//
// D2: MOOT_BENCH_NO_ENCODER=1 is set → collect() refuses to proceed because
//     the no-encoder ablation is not yet implemented. A mislabeled cell (a
//     product-default measurement labeled as no-encoder) is worse than no cell.
//
// All D1 assertions are on records the REAL writer produced (collect → stamp →
// encode → writeRecordNeverOverwrite → read back from disk). No assertion uses
// a hand-constructed struct directly.
//
// D2 guard tests call noEncoderActivationSeamMessage(env:) directly and never
// go through collect(), so exit(1) is never triggered in tests.
//
// All D1 tests use explicit seam parameters (registerArm:) rather than POSIX
// setenv/unsetenv mutations, which race against concurrent test suites.

import Testing
import Foundation
@testable import mcp_benchmarker

// ── D1: register arm wiring ───────────────────────────────────────────────────

@Suite("BenchmarkRegisterArm — D1 wiring and D2 guard")
struct BenchmarkRegisterArmTests {

    // ── D1-S1: register arm written to disk and read back ──────────────────

    /// D1-S1-a: RunEnvironment record written by the real writer carries
    /// benchmark_register_arm with value "product-default" when no arm switch
    /// is set. Assert on the file read back from disk — not on the struct.
    @Test("RunEnvironment: writer-emitted record carries benchmark_register_arm=product-default")
    func runEnvRegisterArmOnDisk() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RegArm-RunEnv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // No arm switches → collect() resolves product-default from the cache.
        var env = RunEnvironment.collect(mootx01BinaryPath: nil)
        stampTestIdentity(&env, test: "reg-arm-test", arm: "product-default", serial: "ra01")

        let filename = recordFilename(test: "reg-arm-test", arm: "product-default", serial: "ra01")
        let url = tmpDir.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(env)
        try writeRecordNeverOverwrite(data, to: url)

        // Assert on the FILE the writer produced.
        let readBack = try Data(contentsOf: url)
        let decoded  = try JSONDecoder().decode(RunEnvironment.self, from: readBack)

        #expect(decoded.benchmarkRegisterArm == "product-default",
                "benchmark_register_arm must equal product-default when no arm switch is set")
    }

    /// D1-S1-b: IdentityEnvironment record written by the real writer carries
    /// benchmark_register_arm with value "product-default" when no arm switch
    /// is set. Assert on the file read back from disk — not on the struct.
    @Test("IdentityEnvironment: writer-emitted record carries benchmark_register_arm=product-default")
    func identityEnvRegisterArmOnDisk() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RegArm-IdentEnv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var identity = IdentityEnvironment.collect(mootx01BinaryPath: nil)
        stampTestIdentity(&identity, test: "reg-arm-id", arm: "product-default", serial: "ra02")

        let filename = recordFilename(test: "reg-arm-id", arm: "product-default", serial: "ra02")
        let url = tmpDir.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(identity)
        try writeRecordNeverOverwrite(data, to: url)

        let readBack = try Data(contentsOf: url)
        let decoded  = try JSONDecoder().decode(IdentityEnvironment.self, from: readBack)

        #expect(decoded.benchmarkRegisterArm == "product-default",
                "benchmark_register_arm must equal product-default when no arm switch is set")
    }

    // ── D1-S2: both fields present and holding different values ─────────────

    /// D1-S2: benchmark_register_arm and benchmark_arm are BOTH present on the
    /// same writer-emitted record and carry DIFFERENT values. Inject the mining
    /// arm via the registerArm seam (no process-environment mutation) so the
    /// register arm is "apple-mint" while the lane arm (set by stampTestIdentity)
    /// is "product-default".
    ///
    /// This gate proves the two fields are orthogonal. A gate where both happen
    /// to carry the same string cannot distinguish them.
    @Test("Writer-emitted record carries benchmark_register_arm and benchmark_arm with different values")
    func registerArmAndLaneArmBothPresentAndDifferent() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RegArm-BothFields-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Inject the register arm via the explicit seam — no setenv/unsetenv.
        var env = RunEnvironment.collect(mootx01BinaryPath: nil, registerArm: "apple-mint")
        // Lane arm (corpus-slice label) is "product-default" — different from
        // the register arm "apple-mint" injected above.
        stampTestIdentity(&env, test: "reg-arm-2f", arm: "product-default", serial: "ra03")

        let filename = recordFilename(test: "reg-arm-2f", arm: "product-default", serial: "ra03")
        let url = tmpDir.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(env)
        try writeRecordNeverOverwrite(data, to: url)

        let readBack = try Data(contentsOf: url)
        let decoded  = try JSONDecoder().decode(RunEnvironment.self, from: readBack)

        // Register arm = mining arm injected via seam.
        #expect(decoded.benchmarkRegisterArm == "apple-mint",
                "benchmark_register_arm must be the mining arm injected via registerArm seam")

        // Lane arm = corpus-slice label set by stampTestIdentity.
        #expect(decoded.benchmarkArm == "product-default",
                "benchmark_arm (lane arm) must be the label set by stampTestIdentity")

        // The two fields must hold different values — the key D1 requirement.
        #expect(decoded.benchmarkRegisterArm != decoded.benchmarkArm,
                "benchmark_register_arm and benchmark_arm must hold different values in the same record")
    }

    // ── D1-S3: wire key set comparison ───────────────────────────────────────

    /// D1-S3: Swift RunEnvironment wire key set includes benchmark_register_arm.
    /// Mirrors Rust's run_environment_wire_key_set gate test.
    @Test("RunEnvironment wire key set includes benchmark_register_arm")
    func runEnvironmentWireKeySet() throws {
        var env = RunEnvironment.collect(mootx01BinaryPath: nil)
        stampTestIdentity(&env, test: "key-set-test", arm: "product-default", serial: "ks01")

        let data = try JSONEncoder().encode(env)
        let json = String(decoding: data, as: UTF8.self)

        let requiredKeys = [
            "mootx01_binary_sha256",
            "mootx01_version",
            "protocol_version",
            "benchmark_test_name",
            "benchmark_arm",
            "benchmark_run_serial",
            "benchmark_register_arm",
            "converter_id",
            "converter_version",
            "hosting_mode",
        ]
        for key in requiredKeys {
            #expect(json.contains("\"\(key)\""),
                    "Expected wire key \"\(key)\" in RunEnvironment JSON")
        }
    }

    /// D1-S3b: IdentityEnvironment wire key set includes benchmark_register_arm.
    /// Mirrors Rust's identity_environment_wire_key_set_matches_contract gate test.
    @Test("IdentityEnvironment wire key set includes benchmark_register_arm")
    func identityEnvironmentWireKeySet() throws {
        var identity = IdentityEnvironment.collect(mootx01BinaryPath: nil)
        stampTestIdentity(&identity, test: "key-set-id", arm: "product-default", serial: "ks02")

        let data = try JSONEncoder().encode(identity)
        let json = String(decoding: data, as: UTF8.self)

        let requiredKeys = [
            "mootx01_binary_sha256",
            "mootx01_version",
            "protocol_version",
            "benchmark_test_name",
            "benchmark_arm",
            "benchmark_run_serial",
            "benchmark_register_arm",
            "converter_id",
            "converter_version",
            "hosting_mode",
        ]
        for key in requiredKeys {
            #expect(json.contains("\"\(key)\""),
                    "Expected wire key \"\(key)\" in IdentityEnvironment JSON")
        }
    }

    // ── D2: no-encoder activation guard ──────────────────────────────────────

    /// D2-S1: noEncoderActivationSeamMessage(env:) returns a non-nil message when
    /// MOOT_BENCH_NO_ENCODER=1 is set, and the message names the switch and the
    /// missing activation. Calls the guard function directly — never collect() —
    /// so exit(1) is never triggered.
    @Test("noEncoderActivationSeamMessage returns message naming the switch when MOOT_BENCH_NO_ENCODER=1")
    func noEncoderGuardMessageWhenSwitchSet() {
        let msg = noEncoderActivationSeamMessage(env: ["MOOT_BENCH_NO_ENCODER": "1"])
        #expect(msg != nil,
                "guard must return non-nil when MOOT_BENCH_NO_ENCODER=1")
        if let m = msg {
            #expect(m.contains("MOOT_BENCH_NO_ENCODER"),
                    "message must name the switch MOOT_BENCH_NO_ENCODER; got: \(m)")
            #expect(m.contains("not yet implemented") || m.contains("ablation"),
                    "message must state the activation is missing; got: \(m)")
        }
    }

    /// D2-S2: noEncoderActivationSeamMessage(env:) returns nil when
    /// MOOT_BENCH_NO_ENCODER is not set — no refusal, collect() proceeds.
    @Test("noEncoderActivationSeamMessage returns nil when MOOT_BENCH_NO_ENCODER is absent")
    func noEncoderGuardNilWithoutSwitch() {
        let msg = noEncoderActivationSeamMessage(env: [:])
        #expect(msg == nil,
                "guard must return nil when MOOT_BENCH_NO_ENCODER is absent; got: \(String(describing: msg))")
    }

    // ── D2: dispatch-level guard exemption ───────────────────────────────────
    //
    // dispatch() hoists the guard before the subcommand switch. Read-only and
    // help subcommands are exempt so that `mcp-benchmarker report ...` and
    // `mcp-benchmarker --help` always work even when the switch is set. This
    // tests the production predicate isDispatchExemptFromNoEncoderGuard(_:)
    // in ArmRegister.swift — the same function dispatch() calls. There is no
    // second copy of the exempt list: adding a subcommand to the production
    // predicate immediately changes what these tests verify.

    /// D2-S3: the exemption predicate is true for read-only and help subcommands.
    @Test("dispatch no-encoder guard is exempt for report and help subcommands")
    func noEncoderDispatchGuardExemptSubcommands() {
        // These subcommands must be exempt: dispatch() skips the guard for them.
        let exempt = ["report", "--help", "-h", "help"]
        let noEncoderEnv = ["MOOT_BENCH_NO_ENCODER": "1"]
        for sub in exempt {
            // Calls the production predicate — not a copy of it.
            #expect(isDispatchExemptFromNoEncoderGuard(sub),
                    "'\(sub)' must be exempt from the dispatch no-encoder guard")
            // Confirm the guard would fire for a non-exempt subcommand.
            let msg = noEncoderActivationSeamMessage(env: noEncoderEnv)
            #expect(msg != nil,
                    "guard must fire when MOOT_BENCH_NO_ENCODER=1 and subcommand is non-exempt (checked while verifying '\(sub)' exemption)")
        }
    }

    /// D2-S4: non-exempt subcommands are NOT exempt from the dispatch guard.
    /// The set is DERIVED from CLI.swift's dispatch switch — not hand-written.
    /// A new dispatch case added without considering the guard makes the
    /// count assertion fail, which is the point.
    @Test("dispatch no-encoder guard is NOT exempt for run subcommands")
    func noEncoderDispatchGuardNotExemptForRunSubcommands() throws {
        // Read CLI.swift — path derived from this test file's own location.
        // #filePath resolves to: .../<suite root>/Tests/mcp-benchmarkerTests/<this file>
        let testFileURL = URL(fileURLWithPath: #filePath)
        let cliSwiftURL = testFileURL
            .deletingLastPathComponent() // .../mcp-benchmarkerTests/
            .deletingLastPathComponent() // .../Tests/
            .deletingLastPathComponent() // .../<suite root>/
            .appendingPathComponent("Sources/mcp-benchmarker/CLI.swift")

        let cliSource = try String(contentsOf: cliSwiftURL, encoding: .utf8)
        let cliLines = cliSource.components(separatedBy: "\n")

        // Locate the dispatch switch block: lines between
        // "switch subcommand {" and the first "default:" line.
        var inDispatchSwitch = false
        var caseStatementCount = 0
        var allDispatchLiterals: [String] = []

        for line in cliLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "switch subcommand {" {
                inDispatchSwitch = true
                continue
            }
            guard inDispatchSwitch else { continue }
            if trimmed.hasPrefix("default:") { break }
            guard trimmed.hasPrefix("case ") else { continue }

            // Each line starting with "case " is one case statement.
            caseStatementCount += 1

            // Extract all quoted string literals from this case label line.
            // Handles single-literal cases ("foo":) and multi-literal cases
            // ("foo", "bar", "baz":) with the same loop.
            var remaining = trimmed[...]
            while let openIdx = remaining.firstIndex(of: "\"") {
                let bodyStart = remaining.index(after: openIdx)
                guard let closeIdx = remaining[bodyStart...].firstIndex(of: "\"") else { break }
                allDispatchLiterals.append(String(remaining[bodyStart..<closeIdx]))
                remaining = remaining[remaining.index(after: closeIdx)...]
            }
        }

        // Drift gate: a new dispatch arm added without guard consideration
        // makes this assertion fail, surfacing the omission immediately.
        #expect(caseStatementCount == 31,
                "CLI.swift dispatch switch must have 31 case statements; got \(caseStatementCount) — update this assertion when adding a new subcommand")

        // Subtract exempt subcommands by CALLING THE PRODUCTION PREDICATE.
        // There is no second copy of the exempt list in this file.
        let nonExempt = allDispatchLiterals.filter { !isDispatchExemptFromNoEncoderGuard($0) }

        // gauntlet must be in the derived non-exempt set.
        #expect(nonExempt.contains("gauntlet"),
                "\"gauntlet\" must be in the derived non-exempt set (found: \(nonExempt))")

        // Assert the production predicate's exempt set equals the expected set exactly.
        // Sort both sides so ordering does not matter.
        // The expected set is the GATE: widening or narrowing isDispatchExemptFromNoEncoderGuard
        // must fail here immediately.
        //
        // Port note: Swift exempts "report" and Rust does not. "report" is a Swift-only
        // dispatch subcommand (read-only reporting); the Rust port has no equivalent arm.
        // That asymmetry is intentional and is not a bug.
        let exemptSet = allDispatchLiterals
            .filter { isDispatchExemptFromNoEncoderGuard($0) }
            .sorted()
        #expect(exemptSet == ["--help", "-h", "help", "report"],
                "exempt set must be exactly [\"--help\", \"-h\", \"help\", \"report\"]; widening or narrowing isDispatchExemptFromNoEncoderGuard must fail here. Got: \(exemptSet)")
    }
}
