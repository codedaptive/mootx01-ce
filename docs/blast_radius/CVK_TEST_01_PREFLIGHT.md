# Smythe Pre-flight: CVK-TEST-01

## Status
GREEN

## Status details
- Blast radius: verified — 5 files, 12 methods, "0 tests in 0 suites" bug confirmed real
- Prior art: none conflicting
- Environment: clean — branch `stream/cv-convergencekit-test-leg`, worktree has one
  untracked doc file only
- Dependencies: satisfied — swift-testing bundled (Swift 6.0 tools, no package dep needed);
  Crypto reachable transitively via ConvergenceKitFederation for federation tests

## Blockers
None.

## Verification findings (per verification prompt)

### 1. Codebase vs mission claim — CONFIRMED ACCURATE

File count: 5 XCTest files confirmed.
- `Tests/ConvergenceKitTests/ConvergenceKitCoreTypeTests.swift` — 5 methods (testManifestRoundtripCodable, testSyncRecordRoundtrip, testPackedHLCRoundtrip, testFingerprintRoundtrip, testSyncErrorEquality)
- `Tests/ConvergenceKitNoneTests/NoSyncEngineTests.swift` — 4 methods (testEnableThenDisable, testPushWithoutEnableFails, testPushPullEmpty, testDoubleEnableFails)
- `Tests/ConvergenceKitCloudKitTests/CloudKitStubTests.swift` — 1 method (testStubExists)
- `Tests/ConvergenceKitFederationTests/FederationStubTests.swift` — 1 method (testStubExists)
- `Tests/ConvergenceKitFederationTests/FederationPairingTests.swift` — 1 method (testInProcessPairingPushPull)

Total: **12 methods across 5 files.** Matches mission exactly.

"0 tests in 0 suites" claim: confirmed. All 5 files use `import XCTest` / `XCTestCase` with zero `import Testing` / `@Test`. Swift-testing runner sees nothing. The XCTest runner executes the 12. This is precisely the bug the mission fixes.

A sixth file exists under `Tests/ConvergenceKitConformance/ConformancePlaceholder.swift` — this is a non-test `.target` (not `.testTarget`), it is a library fixture with no test methods. Not in scope. Does not affect count.

### 2. Rust #[test] count — CONFIRMED INACCURACY (non-blocking)

Mission Context states "Rust leg has 0 `#[test]` functions." Reality: **32** `#[test]` functions confirmed across `rust/tests/` (none_engine_tests 8 + wire_format_tests 14 + federation_tests 10). The BRR already captured this. Rust is explicitly out of scope; no Rust parity step; the inaccuracy changes nothing about what Bilby builds. Recorded for Skippy. Non-blocking.

### 3. Part-2 gap coverage — CONFIRMED

Three source files have zero peer test suites today:
- `Sources/ConvergenceKitFederation/FederationIdentity.swift` — `LocalIdentity`, `PeerIdentity`, `FederationSignature` have no test file. Confirmed.
- `Sources/ConvergenceKitFederation/HyperplaneFamilyExchange.swift` — `HyperplaneFamilySpec`, `PairingProposal`, `PairingAcceptance` have no test file. Confirmed.
- `Sources/ConvergenceKitCloudKit/CKRecordMapping.swift` — `CKRecordMapping`, `DecodedRecord` have no test file. Confirmed.

All other source types are exercised through the 5 existing suites.

### 4. Part-2 deterministic surface — CONFIRMED TESTABLE

**FederationIdentity.swift:**
- `LocalIdentity` — `public struct`, public `init()`, public `init(privateKeyBytes:) throws`, public `sign(_:) throws`. All public, no `@testable` needed. Ed25519 sign→verify roundtrip is fully deterministic and in-process. `init(privateKeyBytes:)` reproduces same public key — deterministic, testable.
- `PeerIdentity` — `public struct`, `Hashable`. Equatable/Hashable testable directly.
- `FederationSignature` — `public enum` with `public static func verify(...)`. Pure function, deterministic.
- Crypto dependency: `ConvergenceKitFederationTests` depends on `ConvergenceKitFederation` which pulls `Crypto` as a product dep. Transitive access confirmed. No explicit Crypto dep needed in the test target.

**HyperplaneFamilyExchange.swift:**
- `HyperplaneFamilySpec` — `public struct`, `Codable`, `Hashable`. `init(seed:dimension:)` with `dimension` defaulting to 256. Default dimension test is pure value assertion, deterministic.
- `PairingProposal`, `PairingAcceptance` — both `public struct`, `Codable`. Codable roundtrip is deterministic, no network, no iCloud.
- No platform gate needed. All three types are pure value types.

**CKRecordMapping.swift:**
- `CKRecordMapping.recordType(kitID:table:)` — `public static func` returns `"\(kitID)_\(table)"`. Deterministic string, no network.
- `CKRecordMapping.record(from:table:rowKey:hlc:schemaVersion:kitID:zone:)` — `public static func throws -> CKRecord`. Uses `CKRecord` in memory. On macOS, `CKRecord` and `CKRecordZone.ID` are fully instantiable in-process without network (they are local objects; only CKDatabase operations are network-bound). The existing `CloudKitStubTests` already instantiates `CloudKitSyncEngine()` and checks `engine.state` — proving CKKit types work in tests without iCloud configuration. `record()/decode()` roundtrip is deterministic once `CKRecord` is in memory.
- `CKRecordMapping.decode(_:)` — `public static func throws -> DecodedRecord`. `DecodedRecord` is `public struct`. Both accessible without `@testable`.
- One precision note for Bilby: the `record()` function encodes `.bitmap(Int64)` and `.int(Int64)` both as `NSNumber`. When `decode()` reads them back via `typedValue(from:)`, it uses the ObjC type encoding (`"q"` for Int64) — both decode as `.int`, not `.bitmap`. The roundtrip for `.bitmap` values through CKRecord will lose the bitmap discriminator (decoded as `.int`). This is an existing implementation characteristic, not a bug introduced by Bilby. The test must assert `.int(value)` not `.bitmap(value)` for bitmap-typed fields, or avoid bitmap in the CKRecord roundtrip test. **Warning for Bilby when writing CKRecordMappingTests.**

### 5. Package.swift no-op — CONFIRMED

`Package.swift` uses `swift-tools-version:6.0`. Swift 6.x bundles swift-testing as part of the toolchain — `import Testing` resolves without a package dep. Precedent confirmed across LatticeKit (CodeTests.swift uses `import Testing` with no swift-testing package dep), EngramLib (ENGRAM-TEST-01), and SubstrateTypes. No Package.swift modification needed. Conditional "add dep only if absent" → dep is absent, condition is not met → no-op. Confirmed.

### 6. Prior art, parallel churn, prerequisites — CLEAR

No prior-art conflicts. No other stream touches ConvergenceKit test files. Mission states "parallel safe with all other test-leg streams (disjoint packages)" — confirmed, other cv/test streams target separate packages. `git status` shows only the BRR as an untracked doc file; no stale modifications in working tree. No prerequisites listed; none needed.

## Bilby's stated approach
Part 1: convert each of the 5 files — `import XCTest` → `import Testing`; `XCTestCase` class → `@Suite` struct; each `func testX()` → `@Test` func; `XCTAssert*` macros → `#expect`/`#require`; `do{try…;XCTFail}catch` error-check patterns → `await #expect(throws:)`; async tests stay `async throws`. Part 2: create 3 peer suites (FederationIdentityTests, HyperplaneFamilyExchangeTests, CKRecordMappingTests) covering deterministic paths only. Package.swift: unchanged (no-op confirmed). Not doing: no Sources/** touched, no rust/** touched, no docs/validation/**, no other package.

Assessment: **accepted.** One precision note carried forward to Bilby (see §4, CKRecordMapping bitmap/int decode characteristic).

## Actions (Bilby proceeds)
1. Convert `ConvergenceKitCoreTypeTests.swift` — 5 methods, pure value assertions, straightforward.
2. Convert `NoSyncEngineTests.swift` — 4 methods; `do{try…;XCTFail}catch SyncError.x` patterns become `await #expect(throws: SyncError.x)`.
3. Convert `CloudKitStubTests.swift` — 1 method, trivial `if case` pattern check.
4. Convert `FederationStubTests.swift` — 1 method, same pattern.
5. Convert `FederationPairingTests.swift` — 1 method; `XCTAssertGreaterThan(a,b,msg)` → `#expect(a > b, "msg")`; three `XCTAssertEqual` → `#expect(a == b)`.
6. Commit Part 1. Verify: `swift test` exit 0, ≥12 registered under swift-testing runner, zero `import XCTest`.
7. Create `FederationIdentityTests.swift` — sign/verify roundtrip, tampered payload rejection, wrong key rejection, `init(privateKeyBytes:)` key reproduction, PeerIdentity Equatable/Hashable.
8. Create `HyperplaneFamilyExchangeTests.swift` — default dimension == 256, Codable roundtrip for HyperplaneFamilySpec/PairingProposal/PairingAcceptance, HyperplaneFamilySpec Hashable.
9. Create `CKRecordMappingTests.swift` — `recordType` format; `record()/decode()` roundtrip via in-memory CKRecord. Note: assert decoded bitmap fields as `.int`, not `.bitmap` (see §4).
10. Commit Part 2. Verify: `swift test` exit 0, all new @Test functions registering, zero warnings, zero `import XCTest`.

## Decision needed
None. GREEN. Proceed.
