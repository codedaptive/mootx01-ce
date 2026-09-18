// BenchmarkRowFieldTests.swift
//
// Four-field gate assertions for benchmark row types.
//
// Each of the four field concepts defined in the arm-register + four-row-fields
// mission must be present on the row type AND filled by the collect() call.
// Tests are OBSERVED: they drive the real collect() seam and read the encoded
// JSON — no hand-constructed structs are used to assert field presence.
//
// Field concepts under test:
//   1. testname-arm-serial: benchmark_test_name, benchmark_arm, benchmark_run_serial
//   2. converter identity:  converter_id, converter_version
//   3. hosting mode:        hosting_mode
//   4. CE SHA:              ce_sha (present when MOOT_BENCH_CE_SHA is set)
//
// Wire key assertions check the encoded JSON so the CodingKeys mapping is
// also verified. Missing keys in JSON = missing field or wrong CodingKey.

import Testing
import Foundation
import Darwin   // setenv / unsetenv
@testable import mcp_benchmarker

// ── Helpers ──────────────────────────────────────────────────────────────────

/// Runs a closure with specific env vars set, restoring originals after.
/// Uses POSIX setenv/unsetenv so ProcessInfo.processInfo.environment (which
/// reads POSIX environ[] dynamically) sees the changes.
private func withEnvVars(
    _ overrides: [String: String?],
    run body: () throws -> Void
) rethrows {
    var saved: [String: String?] = [:]
    for (key, value) in overrides {
        // Snapshot the current C-level value before overriding.
        if let current = getenv(key) {
            saved[key] = String(cString: current)
        } else {
            saved[key] = nil
        }
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
    defer {
        for (key, original) in saved {
            if let original {
                setenv(key, original, 1)
            } else {
                unsetenv(key)
            }
        }
    }
    try body()
}

private func encodedJSON(_ value: some Codable) throws -> String {
    let data = try JSONEncoder().encode(value)
    return String(decoding: data, as: UTF8.self)
}

// ── RunEnvironment — collect-time fields ─────────────────────────────────────

// Marked .serialized because several tests mutate POSIX env vars (setenv /
// unsetenv), and ProcessInfo.processInfo.environment reads the live environ[]
// on each call. Parallel env-mutation tests from different suites would race
// on shared keys (MOOT_BENCH_CE_SHA). All ce_sha and hosting env tests live
// in this one suite; IdentityEnvironment tests use structural checks only.
@Suite("RunEnvironment — collect stamps new row fields", .serialized)
struct RunEnvironmentRowFieldTests {

    /// collect() with nil binary path: all collect-time fields should be set
    /// to their "unknown" defaults. Tests drive the REAL collect() seam.
    @Test("hosting_mode present after collect(nil)")
    func hostingModeNilBinary() throws {
        let env = RunEnvironment.collect(mootx01BinaryPath: nil)
        let json = try encodedJSON(env)
        #expect(json.contains("\"hosting_mode\""),
                "hosting_mode must appear in encoded JSON")
        #expect(env.hostingMode == "unknown",
                "hostingMode must be 'unknown' when binary path is nil, got \(env.hostingMode ?? "<nil>")")
    }

    @Test("hosting_mode is separately-launched-stdio when binary path non-nil")
    func hostingModeBinaryPresent() throws {
        // Use /usr/bin/true as a proxy binary path (present on every macOS machine).
        let env = RunEnvironment.collect(mootx01BinaryPath: "/usr/bin/true")
        let json = try encodedJSON(env)
        #expect(json.contains("\"hosting_mode\""),
                "hosting_mode must appear in encoded JSON")
        #expect(env.hostingMode == "separately-launched-stdio",
                "hostingMode must be 'separately-launched-stdio' when binary path is provided, got \(env.hostingMode ?? "<nil>")")
    }

    @Test("converter_id present and non-nil after collect()")
    func converterIDPresent() throws {
        let env = RunEnvironment.collect(mootx01BinaryPath: nil)
        let json = try encodedJSON(env)
        #expect(json.contains("\"converter_id\""),
                "converter_id must appear in encoded JSON")
        #expect(env.converterID != nil,
                "converterID must be non-nil after collect()")
    }

    @Test("converter_version present and non-nil after collect()")
    func converterVersionPresent() throws {
        let env = RunEnvironment.collect(mootx01BinaryPath: nil)
        let json = try encodedJSON(env)
        #expect(json.contains("\"converter_version\""),
                "converter_version must appear in encoded JSON")
        #expect(env.converterVersion != nil,
                "converterVersion must be non-nil after collect()")
    }

    @Test("ce_sha present when MOOT_BENCH_CE_SHA set")
    func ceShaFromEnv() throws {
        try withEnvVars(["MOOT_BENCH_CE_SHA": "abc123"]) {
            let env = RunEnvironment.collect(mootx01BinaryPath: nil)
            let json = try encodedJSON(env)
            #expect(json.contains("\"ce_sha\""),
                    "ce_sha must appear in JSON when MOOT_BENCH_CE_SHA is set")
            #expect(env.ceSha == "abc123",
                    "ceSha must equal MOOT_BENCH_CE_SHA value, got \(env.ceSha ?? "<nil>")")
        }
    }

    @Test("ce_sha absent from JSON when MOOT_BENCH_CE_SHA unset")
    func ceShaAbsentWhenEnvUnset() throws {
        try withEnvVars(["MOOT_BENCH_CE_SHA": nil]) {
            let env = RunEnvironment.collect(mootx01BinaryPath: nil)
            let json = try encodedJSON(env)
            #expect(!json.contains("\"ce_sha\""),
                    "ce_sha must NOT appear in JSON when MOOT_BENCH_CE_SHA is unset")
        }
    }

    // ── testname-arm-serial (writer-set fields) ──────────────────────────────

    @Test("benchmark_test_name absent from JSON before writer sets it")
    func benchmarkTestNameAbsentBeforeSet() throws {
        let env = RunEnvironment.collect(mootx01BinaryPath: nil)
        let json = try encodedJSON(env)
        #expect(!json.contains("\"benchmark_test_name\""),
                "benchmark_test_name must be absent from JSON before the writer sets it")
    }

    @Test("benchmark_arm absent from JSON before writer sets it")
    func benchmarkArmAbsentBeforeSet() throws {
        let env = RunEnvironment.collect(mootx01BinaryPath: nil)
        let json = try encodedJSON(env)
        #expect(!json.contains("\"benchmark_arm\""),
                "benchmark_arm must be absent from JSON before the writer sets it")
    }

    @Test("benchmark_run_serial absent from JSON before writer sets it")
    func benchmarkRunSerialAbsentBeforeSet() throws {
        let env = RunEnvironment.collect(mootx01BinaryPath: nil)
        let json = try encodedJSON(env)
        #expect(!json.contains("\"benchmark_run_serial\""),
                "benchmark_run_serial must be absent from JSON before the writer sets it")
    }

    @Test("testname-arm-serial triple present in JSON after writer sets them")
    func testSerialTriplePresentAfterWriterSets() throws {
        var env = RunEnvironment.collect(mootx01BinaryPath: nil)
        env.benchmarkTestName   = "gauntlet"
        env.benchmarkArm        = "product-default"
        env.benchmarkRunSerial  = "001"

        let json = try encodedJSON(env)
        #expect(json.contains("\"benchmark_test_name\""),
                "benchmark_test_name must appear in JSON after writer sets it")
        #expect(json.contains("\"benchmark_arm\""),
                "benchmark_arm must appear in JSON after writer sets it")
        #expect(json.contains("\"benchmark_run_serial\""),
                "benchmark_run_serial must appear in JSON after writer sets it")
        #expect(json.contains("\"gauntlet\""),   "test name value must be in JSON")
        #expect(json.contains("\"product-default\""), "arm value must be in JSON")
        #expect(json.contains("\"001\""),        "serial value must be in JSON")
    }

    // ── wire key parity between ports ────────────────────────────────────────

    @Test("wire keys match Rust port constants")
    func wireKeysMatchRustPort() throws {
        // Encode a row with all new fields populated and assert wire key names.
        // This test cannot run the Rust port directly, but it pins the Swift
        // wire keys so a Rust conformance test can assert the same set.
        var env = RunEnvironment.collect(mootx01BinaryPath: nil)
        env.benchmarkTestName  = "gauntlet"
        env.benchmarkArm       = "product-default"
        env.benchmarkRunSerial = "001"

        let json = try encodedJSON(env)
        let expectedKeys = [
            "\"benchmark_test_name\"",
            "\"benchmark_arm\"",
            "\"benchmark_run_serial\"",
            "\"converter_id\"",
            "\"converter_version\"",
            "\"hosting_mode\"",
        ]
        for key in expectedKeys {
            #expect(json.contains(key), "Expected wire key \(key) in JSON")
        }
    }
}

// ── IdentityEnvironment — collect-time fields ────────────────────────────────

@Suite("IdentityEnvironment — collect stamps new row fields")
struct IdentityEnvironmentRowFieldTests {

    @Test("hosting_mode present after collect(nil)")
    func hostingModeNilBinary() throws {
        let ident = IdentityEnvironment.collect(mootx01BinaryPath: nil)
        let json = try encodedJSON(ident)
        #expect(json.contains("\"hosting_mode\""),
                "hosting_mode must appear in IdentityEnvironment encoded JSON")
        #expect(ident.hostingMode == "unknown",
                "hostingMode must be 'unknown' when binary path is nil")
    }

    @Test("converter_id present after collect()")
    func converterIDPresent() throws {
        let ident = IdentityEnvironment.collect(mootx01BinaryPath: nil)
        let json = try encodedJSON(ident)
        #expect(json.contains("\"converter_id\""),
                "converter_id must appear in IdentityEnvironment encoded JSON")
        #expect(ident.converterID != nil,
                "converterID must be non-nil after collect()")
    }

    @Test("converter_version present after collect()")
    func converterVersionPresent() throws {
        let ident = IdentityEnvironment.collect(mootx01BinaryPath: nil)
        let json = try encodedJSON(ident)
        #expect(json.contains("\"converter_version\""),
                "converter_version must appear in IdentityEnvironment encoded JSON")
        #expect(ident.converterVersion != nil,
                "converterVersion must be non-nil after collect()")
    }

    // Note: the env-var-dependent ce_sha test lives in RunEnvironmentRowFieldTests
    // (serialized) to prevent inter-suite races on MOOT_BENCH_CE_SHA. This
    // suite verifies only that the ce_sha field EXISTS on the struct — structural
    // gate, no env mutation needed.
    @Test("ceSha field exists on IdentityEnvironment (structural gate)")
    func ceShaFieldExistsStructural() throws {
        let ident = IdentityEnvironment.collect(mootx01BinaryPath: nil)
        // Access the property to confirm it compiles and is part of the struct.
        // The value may be nil (when MOOT_BENCH_CE_SHA is unset) or a string —
        // both are valid; the field must exist.
        let _ = ident.ceSha   // structural access
        // When nil, must be absent from JSON (optional field).
        let json = try encodedJSON(ident)
        if ident.ceSha == nil {
            #expect(!json.contains("\"ce_sha\""),
                    "nil ce_sha must be absent from IdentityEnvironment JSON")
        }
    }

    @Test("existing explicit init still compiles and produces valid struct")
    func explicitInitStillWorks() throws {
        // Ensures the SE-0242-compatible explicit init() signature (with nil-
        // defaulted new var fields) is intact and existing call sites are not broken.
        let ident = IdentityEnvironment(
            mootx01BinarySha256: "deadbeef",
            mootx01Version:      "1.1",
            protocolVersion:     "v0.1"
        )
        #expect(ident.mootx01BinarySha256 == "deadbeef")
        #expect(ident.mootx01Version      == "1.1")
        #expect(ident.protocolVersion     == "v0.1")
        // New var fields must default to nil.
        #expect(ident.hostingMode      == nil)
        #expect(ident.converterID      == nil)
        #expect(ident.converterVersion == nil)
        #expect(ident.ceSha            == nil)
    }
}

// ── Writer-emitted record gate tests ─────────────────────────────────────────
//
// REQUIREMENT: Every assertion here is on a file the REAL writer produced.
// Never on a struct the test built and mutated directly.
//
// The writer pipeline used: stampTestIdentity → JSONEncoder → writeRecordNeverOverwrite
// → read back → decode → assert.
//
// Gates:
// G1. Writer-emitted IdentityEnvironment record carries testname-arm-serial triple;
//     values are consistent with the three components PARSED from the record's own
//     filename. The arm used contains '/' (rewritten to '_' in the filename by
//     recordFilename) — a test that never exercises '/' cannot catch a parse that
//     ignores the rewrite.
// G2. Same record carries hosting_mode, converter_id, converter_version in JSON.
// G3. IdentityEnvironment wire key set matches the cross-port contract (Swift + Rust).

@Suite("Writer-emitted record field gate", .serialized)
struct WriterEmittedRecordFieldGateTests {

    /// G1: record carries testname-arm-serial consistent with parsed filename components.
    ///
    /// The arm "matrix/dense" contains '/'. recordFilename rewrites it to '_' in
    /// the filename; stampTestIdentity preserves the original '/'. The test parses
    /// the filename back to its three components and verifies that the decoded record
    /// fields are consistent — i.e. the arm field (with '/' restored) matches what
    /// was stamped, and the test/serial fields match the filename segments exactly.
    @Test("writer-emitted IdentityEnvironment record carries testname-arm-serial matching filename")
    func writerEmittedRecordTripleMatchesFilename() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BenchRowGateG1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Arm intentionally contains '/' so recordFilename must rewrite it to '_'.
        // This proves the parse is the inverse of recordFilename, not of a simpler
        // assumption about the arm being slash-free.
        let testComp   = "gate-test"
        let armComp    = "matrix/dense"
        let serialComp = "001"

        // Real writer pipeline: collect → stamp → encode → write.
        var identity = IdentityEnvironment.collect(mootx01BinaryPath: nil)
        stampTestIdentity(&identity, test: testComp, arm: armComp, serial: serialComp)

        let filename = recordFilename(test: testComp, arm: armComp, serial: serialComp)
        let url = tmpDir.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(identity)
        try writeRecordNeverOverwrite(data, to: url)

        // Assertions on the FILE the writer produced — decode from disk.
        let readBack = try Data(contentsOf: url)
        let decoded  = try JSONDecoder().decode(IdentityEnvironment.self, from: readBack)

        // Parse the filename back into (test, safeArm, serial) using a two-pass
        // last-dash extraction. This is a fixture-local shortcut that holds only
        // because this test's arm "matrix/dense" becomes "matrix_dense" after
        // underscore substitution — no dashes remain in the arm component.
        //
        // recordFilename format: "{test}-{safeArm}-{serial}.json"
        // where safeArm = arm.replacingOccurrences(of: "/", with: "_")
        //
        // A dash-bearing arm such as "lme-s" (no slash, stays "lme-s" after
        // substitution) cannot be recovered from the filename by this rule:
        // "gate-test-lme-s-001.json" splits into ["gate","test","lme","s","001"],
        // yielding safeArm = "s" and test = "gate-test-lme", both wrong. A real
        // orphan-identification tool must match against the known arm list rather
        // than relying on last-dash extraction.
        //
        // Two-pass: strip ".json", extract serial (last dash segment), extract
        // safeArm (last dash segment of remainder), test = what remains.
        let base = filename.hasSuffix(".json")
            ? String(filename.dropLast(".json".count))
            : filename
        let parts = base.components(separatedBy: "-")
        // parts: ["gate", "test", "matrix_dense", "001"]
        // serial is the last segment; safeArm is the second-to-last —
        // but only because this fixture's arm is dash-free after sanitisation.
        #expect(parts.count >= 3, "filename must have at least 3 dash-separated segments")
        let parsedSerial  = parts.last!
        let parsedSafeArm = parts[parts.count - 2]
        let parsedTest    = parts.dropLast(2).joined(separator: "-")

        // G1: test and serial match the filename segments exactly.
        #expect(decoded.benchmarkTestName  == parsedTest,
                "benchmark_test_name '\(decoded.benchmarkTestName ?? "nil")' must match parsed test '\(parsedTest)'")
        #expect(decoded.benchmarkRunSerial == parsedSerial,
                "benchmark_run_serial '\(decoded.benchmarkRunSerial ?? "nil")' must match parsed serial '\(parsedSerial)'")
        // The arm field stores the original '/' form; the filename stores the '_' form.
        // Verify they are consistent: sanitising the stored arm must yield the filename component.
        let storedArmSanitised = decoded.benchmarkArm?.replacingOccurrences(of: "/", with: "_") ?? ""
        #expect(storedArmSanitised == parsedSafeArm,
                "benchmark_arm '\(decoded.benchmarkArm ?? "nil")' sanitised to '\(storedArmSanitised)' must match parsed safe-arm '\(parsedSafeArm)'")
    }

    /// G2: same writer-emitted record carries collect-time identity fields.
    @Test("writer-emitted IdentityEnvironment record carries collect-time identity fields")
    func writerEmittedRecordCarriesCollectFields() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BenchRowGateG2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        var identity = IdentityEnvironment.collect(mootx01BinaryPath: nil)
        stampTestIdentity(&identity, test: "gate-test", arm: "product-default", serial: "002")

        let filename = recordFilename(test: "gate-test", arm: "product-default", serial: "002")
        let url = tmpDir.appendingPathComponent(filename)
        let data = try JSONEncoder().encode(identity)
        try writeRecordNeverOverwrite(data, to: url)

        // Assertions on the FILE the writer produced.
        let readBack = try Data(contentsOf: url)
        let json     = String(decoding: readBack, as: UTF8.self)

        // G2: collect-time fields present in the emitted JSON.
        #expect(json.contains("\"hosting_mode\""),
                "hosting_mode must be present in writer-emitted IdentityEnvironment record")
        #expect(json.contains("\"converter_id\""),
                "converter_id must be present in writer-emitted IdentityEnvironment record")
        #expect(json.contains("\"converter_version\""),
                "converter_version must be present in writer-emitted IdentityEnvironment record")
    }

    /// G3: IdentityEnvironment wire key set matches the cross-port contract.
    /// Encodes a fully-populated record and asserts ALL expected wire keys.
    /// The Rust port's identity environment tests assert the same key set.
    @Test("IdentityEnvironment wire key set matches cross-port contract")
    func identityEnvironmentWireKeySetMatchesContract() throws {
        // Real writer pipeline: collect → stamp → encode (no file write needed for key-set check).
        var identity = IdentityEnvironment.collect(mootx01BinaryPath: nil)
        stampTestIdentity(&identity, test: "gate-test", arm: "product-default", serial: "003")

        let data = try JSONEncoder().encode(identity)
        let json = String(decoding: data, as: UTF8.self)

        // Cross-port contract: ALL these keys must be present in a
        // fully-populated record emitted through the real writer pipeline.
        // Any key absent here means a regression in the Swift/Rust parity contract.
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
                    "Expected cross-port wire key \"\(key)\" in IdentityEnvironment JSON")
        }
    }
}
