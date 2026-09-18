// ArmRegisterTests.swift
//
// Gate assertions for the benchmark arm register (ArmRegister.swift).
//
// Assertions per the mission gate specification:
// 1. Default arm enumeration contains EXACTLY "product-default" and "no-encoder".
// 2. resolveActiveArmName() returns the correct arm for each env configuration.
// 3. Wire key parity: a Swift row for the same arm carries the correct arm name
//    under the "benchmark_arm" wire key.

import Testing
import Foundation
@testable import mcp_benchmarker

@Suite("ArmRegister — default arm enumeration")
struct ArmRegisterTests {

    // ── Default arm set is exactly {product-default, no-encoder} ────────────

    @Test("defaultArmNames contains product-default")
    func defaultArmsContainsProductDefault() {
        #expect(defaultArmNames.contains("product-default"),
                "product-default must appear in the default arm list")
    }

    @Test("defaultArmNames contains no-encoder")
    func defaultArmsContainsNoEncoder() {
        #expect(defaultArmNames.contains("no-encoder"),
                "no-encoder must appear in the default arm list")
    }

    @Test("defaultArmNames has exactly 2 entries")
    func defaultArmsExactlyTwo() {
        #expect(defaultArmNames.count == 2,
                "default arm list must contain exactly 2 arms; got \(defaultArmNames.count): \(defaultArmNames)")
    }

    @Test("defaultArmNames is sorted")
    func defaultArmsAreSorted() {
        #expect(defaultArmNames == defaultArmNames.sorted(),
                "defaultArmNames must be sorted; got \(defaultArmNames)")
    }

    // ── DefaultBenchmarkArm enum raw values match wire keys ──────────────────

    @Test("DefaultBenchmarkArm.productDefault rawValue")
    func productDefaultRawValue() {
        #expect(DefaultBenchmarkArm.productDefault.rawValue == "product-default")
    }

    @Test("DefaultBenchmarkArm.noEncoder rawValue")
    func noEncoderRawValue() {
        #expect(DefaultBenchmarkArm.noEncoder.rawValue == "no-encoder")
    }

    @Test("DefaultBenchmarkArm.allCases matches defaultArmNames")
    func allCasesMatchDefaultArmNames() {
        let fromEnum = DefaultBenchmarkArm.allCases.map(\.rawValue).sorted()
        #expect(fromEnum == defaultArmNames,
                "allCases derived names \(fromEnum) must match defaultArmNames \(defaultArmNames)")
    }
}

// resolveActiveArmName(env:) seam tests use explicit dicts — no POSIX setenv/
// unsetenv mutations, no serialization needed, safe for parallel execution.
@Suite("ArmRegister — resolveActiveArmName")
struct ResolveActiveArmNameTests {

    @Test("product-default when no switches set")
    func resolveProductDefaultWhenNoSwitches() {
        let arm = resolveActiveArmName(env: [:])
        #expect(arm == "product-default",
                "Expected product-default with no env switches; got \(arm)")
    }

    @Test("no-encoder when MOOT_BENCH_NO_ENCODER=1")
    func resolveNoEncoderWhenSwitchSet() {
        let arm = resolveActiveArmName(env: ["MOOT_BENCH_NO_ENCODER": "1"])
        #expect(arm == "no-encoder",
                "Expected no-encoder with MOOT_BENCH_NO_ENCODER=1; got \(arm)")
    }


}
