# Blast Radius Report — CVK-TEST-01 (ConvergenceKit library test leg → swift-testing)

Mission: `docs/missions/inflight/MISSION_CVK_TEST_01.md`
Stream: cv · Branch: `stream/cv-convergencekit-test-leg`
Baseline commit: `16c0579` · Head: (this report = pre-implementation commit)
Tier: **net-new / test-only** — no production source touched. Converts 5 XCTest
files to swift-testing (12 methods preserved) and adds peer suites for the
3 source files lacking any test coverage. No-cap tier; the actual footprint is
test files + docs only.

## Status: PROCEED — no RESCOPE required

Smythe pre-flight verdict: **GREEN — proceed**, zero blockers
(`docs/blast_radius/CVK_TEST_01_PREFLIGHT.md`). One documentation inaccuracy
noted below (non-blocking). Smythe carry-forward: `CKRecordMapping.decode()`
loses the `.bitmap` discriminator (NSNumber integers decode as `.int`) — the
CKRecord roundtrip test asserts `.int(...)`, not `.bitmap(...)`, on integer
values. Existing characteristic, not a bug.

Baseline test counts (verified, this branch @ `16c0579`):
- Swift `cd packages/kits/ConvergenceKit && swift test`: exit 0.
  **XCTest runner: 12 executed, 0 failures.**
  **swift-testing runner: "Test run with 0 tests in 0 suites passed"** — the
  bug this mission fixes. 5 files import `XCTest`.
- Rust: `rust/` has **32** `#[test]` functions (none_engine_tests 8 +
  wire_format_tests 14 + federation_tests 10). Rust is OUT OF SCOPE per the
  mission (no Rust parity step). See "Documentation inaccuracy" below.

## MUST_UPDATE list (reality vs mission's "Files You Will Modify" table)

The mission table lists "all 5 XCTest files" + new per-type suites + a
conditional Package.swift change. Package.swift resolves to a no-op (Swift
6.3.2 bundles swift-testing). Real, in-scope blast radius: **5 files converted
+ 3 files created + 3 docs**. Fully accounted for.

### Part 1 — convert (5 files, 12 methods)

| File | Target test target | Methods | Classification |
|---|---|---|---|
| `Tests/ConvergenceKitTests/ConvergenceKitCoreTypeTests.swift` | ConvergenceKitTests | 5 (manifest roundtrip, syncRecord roundtrip, packedHLC roundtrip, fingerprint roundtrip, syncError equality) | MUST_UPDATE |
| `Tests/ConvergenceKitNoneTests/NoSyncEngineTests.swift` | ConvergenceKitNoneTests | 4 (enableThenDisable, pushWithoutEnableFails, pushPullEmpty, doubleEnableFails) | MUST_UPDATE |
| `Tests/ConvergenceKitCloudKitTests/CloudKitStubTests.swift` | ConvergenceKitCloudKitTests | 1 (stubExists) | MUST_UPDATE |
| `Tests/ConvergenceKitFederationTests/FederationStubTests.swift` | ConvergenceKitFederationTests | 1 (stubExists) | MUST_UPDATE |
| `Tests/ConvergenceKitFederationTests/FederationPairingTests.swift` | ConvergenceKitFederationTests | 1 (inProcessPairingPushPull) | MUST_UPDATE |

Total: **12 methods → 12 `@Test` functions, every assertion preserved.**

### Part 2 — fill per-source-type gaps (3 files CREATE)

Source files with **zero** peer test suite today:

| New test file | Test target | Source covered | Deterministic surface |
|---|---|---|---|
| `Tests/ConvergenceKitFederationTests/FederationIdentityTests.swift` | ConvergenceKitFederationTests | `Sources/ConvergenceKitFederation/FederationIdentity.swift` (LocalIdentity, PeerIdentity, FederationSignature) | Ed25519 sign→verify roundtrip; verify rejects tampered payload + wrong key; `init(privateKeyBytes:)` reproduces same public key; PeerIdentity Equatable/Hashable. All deterministic, no platform gate. |
| `Tests/ConvergenceKitFederationTests/HyperplaneFamilyExchangeTests.swift` | ConvergenceKitFederationTests | `Sources/ConvergenceKitFederation/HyperplaneFamilyExchange.swift` (HyperplaneFamilySpec, PairingProposal, PairingAcceptance) | default `dimension == 256`; Codable roundtrip for all 3 structs; HyperplaneFamilySpec Hashable. Deterministic. |
| `Tests/ConvergenceKitCloudKitTests/CKRecordMappingTests.swift` | ConvergenceKitCloudKitTests | `Sources/ConvergenceKitCloudKit/CKRecordMapping.swift` (CKRecordMapping, DecodedRecord) | `recordType(kitID:table:)` format; `record()`→`decode()` roundtrip preserves values/hlc/schemaVersion/kitID via in-memory CKRecord (no network — the deterministic reference path, same as the existing CloudKit stub test runs CKRecord types on macOS). | 

### Conditional

| File | In mission table? | Change | Classification |
|---|---|---|---|
| `packages/kits/ConvergenceKit/Package.swift` | yes (conditional) | **no change** — swift-testing bundled in Swift 6.3.2; `import Testing` resolves with no package dep (LatticeKit/SubstrateTypes/ENGRAM-TEST-01 precedent). Conditional "add dep only if absent" → the dep is the toolchain's, nothing to add. | NOT MODIFIED (conditional no-op) |

## Source types NOT given a new suite (and why — anti-over-engineering)

- **Internal actors** (`StateActor`, `CloudKitStateActor`, `FederationStateActor`):
  implementation details, exercised through the public engine API already under
  test. No public surface to cover directly; adding `@testable` reach into them
  would be scope creep.
- **Already-covered core types** (SyncManifest, SyncedTable, SyncRecord,
  SyncEventKind, PackedHLC, SyncValueMap, SyncValueBox, FingerprintWire,
  SyncError, SyncReceipt, SyncState, NoSyncEngine, CloudKitSyncEngine,
  FederationSyncEngine, FederationRelay, SignedMessage): peer coverage already
  exists in the converted suites. Not re-covered.
- **CloudKit network path** (`CloudKitSyncEngine.push/pull` against a live
  container): platform/network path, gated exactly as the existing
  `CloudKitStubTests` gates it (engine instantiated, state checked, no live
  iCloud). Not exercised against a real container — matches the mission's
  "test the deterministic reference path; gate the platform path."

## Stated approach (Bilby, per Smythe's pre-flight ask)

1. Part 1 — convert each of the 5 files: `import XCTest` → `import Testing`;
   `XCTestCase` class → `@Suite("…") struct`; each `func testX()` → `@Test`
   func; `XCTAssertEqual(a,b)` → `#expect(a == b)`, `XCTAssertNotEqual` →
   `#expect(a != b)`, `XCTAssertGreaterThan(a,b,msg)` → `#expect(a > b, "msg")`,
   `XCTFail("m")` → `Issue.record("m")`, the `do{try…;XCTFail}catch SyncError.x`
   pattern → `await #expect(throws: SyncError.x) { try await … }`. Preserve every
   assertion. Async tests stay `async throws`.
2. Part 2 — create the 3 peer suites above, deterministic paths only.
3. `Package.swift`: leave unchanged (verified no-op on Swift 6.3.2).
4. NOT doing: no `Sources/**` touched, no `rust/**` touched, no
   `docs/validation/**`, no other package, no new production behavior, no
   assertion dropped or weakened.

## Files NOT modified (per mission's MUST NOT list)

- `packages/kits/ConvergenceKit/Sources/**` — released production code. Untouched.
- `packages/kits/ConvergenceKit/rust/**` — out of scope. Untouched.
- `docs/validation/**` — off-limits conformance harness. Untouched.
- Any other package. Untouched.

## Documentation inaccuracy surfaced (non-blocking)

Mission Context says: "Its Rust leg has 0 `#[test]` functions (no Rust test
parity to mirror)." Reality: the Rust leg has **32** `#[test]` functions across
`rust/tests/{none_engine_tests,wire_format_tests,federation_tests}.rs`. This
does **not** change the work — Rust is explicitly out of scope and the mission
correctly has no Rust parity step regardless of the count — but the stated
count is wrong. Recorded for Skippy; not a blocker.

## Test verification (filled at completion)

- `swift test`: exit 0, ≥12 (target: 12 converted + new Part-2 @Test) registered
  under the swift-testing runner, zero `import XCTest`, zero warnings. Recorded
  verbatim at completion.
