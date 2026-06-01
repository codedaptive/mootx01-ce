# Blast Radius Report — SK-TEST-01

## Mission
SubstrateKernel Swift library test leg (swift-testing, both legs). TEST-ONLY:
build per-source-file swift-testing suites mirroring the Rust `#[test]` behavior
set; convert the existing XCTest smoke to swift-testing. No production source
modified.

- **Stream:** sktest
- **Branch:** stream/sk-substratekernel-test-leg (worktree of mootx01-ce)
- **Base:** main @ b42db96
- **Task:** SK-TEST-01

## Step 0 — Baseline
- `cd packages/libs/SubstrateKernel && swift test` exits **0** at mission start.
- Swift `@Test` count baseline = **0** (the XCTest smoke registers "0 tests in 0
  suites" under the swift-testing runner; Testing Library 1902 ran, confirming
  swift-testing is toolchain-bundled).
- Rust leg: **33** `#[test]` functions — bit_field.rs=14, sha256.rs=5,
  kernel.rs=10, kernel_simd.rs=2 (gated `#![cfg(feature = "simd-nightly")]`),
  hamming_nn.rs=2.
- Smythe pre-flight verdict: **GREEN**, no blockers.

## Scope classification

This is a **purely additive, test-only** mission. No production symbol in
`Sources/**` is read, written, renamed, removed, or deprecated. The blast radius
on production code is **zero**. The one existing file modified is a test file
(`SubstrateKernelTests.swift`), rewritten in place from XCTest to swift-testing;
its test method symbols are referenced by nothing outside the test target.

| Symbol / File | Kind | Classification | Justification |
|---|---|---|---|
| `Tests/SubstrateKernelTests/SubstrateKernelTests.swift` | existing test file (XCTest smoke, 2 methods) | **MUST_UPDATE** | Rewrite to swift-testing per mission Part 1. Test-only; its symbols (`testScalarKernelHammingDistanceMatchesXorPopcount`, `testScalarKernelOrReduceIsCommutative`) are XCTest-runner-discovered only, referenced nowhere else. |
| `Tests/SubstrateKernelTests/BitFieldTests.swift` | new test file | **ADDITIVE (CREATE)** | Peer suite for `BitField` (mirrors bit_field.rs 14 tests + maskedEquals). |
| `Tests/SubstrateKernelTests/SHA256Tests.swift` | new test file | **ADDITIVE (CREATE)** | Peer suite for `SHA256` (mirrors sha256.rs 5 NIST vectors). |
| `Tests/SubstrateKernelTests/HammingNNTests.swift` | new test file | **ADDITIVE (CREATE)** | Peer suite for `HammingNN` (mirrors hamming_nn.rs 2 tests). |
| `Tests/SubstrateKernelTests/PortableKernelTests.swift` | new test file | **ADDITIVE (CREATE)** | Peer suite for `PortableKernel` + reachable SIMD/NEON/BNNS/Metal backends (mirrors kernel.rs 10 + kernel_simd.rs 2 + cross-kernel bit-identity conformance). |
| `packages/libs/SubstrateKernel/Package.swift` | manifest | **INTENTIONALLY_LEFT** | swift-testing is toolchain-bundled at swift-tools-version 6.0; the test target already deps `["SubstrateKernel", "SubstrateTypes"]`. No additive test-target dep is needed (verified: SubstrateTypes manifest has the same shape, ST-TEST-01 ran clean without editing it). Mission's conditional edit is satisfied by confirming absence. |

## Production symbols touched
**None.** `Sources/SubstrateKernel/**` and `rust/**` are read-only references in
this mission. `docs/validation/**` is off-limits and untouched.

## RESCOPE_REQUIRED items
**None.** Blast radius is within mission scope.

## Backend reachability (this host: Apple Silicon arm64, Darwin)
Per mission Known Ambiguity #1 — test what the host can run, gate as Rust gates:
- ScalarKernel — always.
- SimdKernel — `import simd`; `kernelForCurrentPlatform()` returns it on `arch(arm64)`.
- NeonKernel — `canImport(simd)` true on Darwin.
- BnnsKernel — `canImport(Accelerate)` true on Darwin.
- MetalKernel — `init?` may return nil without a GPU; tests gate defensively on
  whether `PortableKernel.kernel(of: .metal)` yields a real `.metal` kernel vs the
  scalar fallback.
