# Blast Radius Report — QK-TEST-01 (QueueKit library test leg → swift-testing)

Mission: `docs/missions/inflight/MISSION_QK_TEST_01.md`
Stream: qk · Branch: `stream/qk-queuekit-test-leg`
Baseline commit: `16c0579` · Head: (this report = first commit)
Tier: **net-new / test-only** — no production source touched. Converts 5 XCTest
files to swift-testing and adds peer suites for uncovered source types. No-cap
tier; the actual footprint is the QueueKit test target plus this doc set.

## Status: PROCEED — no RESCOPE required

Smythe pre-flight verdict: **GREEN — proceed** (`docs/blast_radius/QK_TEST_01_PREFLIGHT.md`).
All six verification items confirmed independently; zero blockers. The Rust
`#[test]` count inaccuracy (0 claimed / 4 actual) is recorded non-blocking.

Baseline test counts (verified, this branch @ `16c0579`):
- Swift `swift test`: exit 0. **XCTest runner: 33 executed, 0 failures.**
  **swift-testing runner: "Test run with 0 tests in 0 suites passed"** — the bug
  this mission fixes. All 5 test files import `XCTest`.
- Rust `cargo test` (in `rust/`): exit 0. **4 passed** — all in
  `rust/tests/conformance.rs` (byte-identical conformance fixtures). 0 in lib,
  0 doc-tests.

## Mission claim vs reality — Rust `#[test]` count (non-blocking inaccuracy)

The mission Context says "Its Rust leg has 0 `#[test]` functions (no Rust test
parity to mirror)." Reality: `rust/tests/conformance.rs` contains **4** `#[test]`
functions (byte-conformance against the committed `Tests/QueueKitTests/Fixtures/`).
This does **not** change the mission: those 4 are cross-language byte-conformance
tests, not behavioral unit tests, and `rust/**` is explicitly on the MUST-NOT
list. The mission's operative intent — "there is NO Rust parity step; do not
mirror Rust behaviors" — stands. Recorded for Skippy; not a blocker.

## MUST_UPDATE list (reality vs mission's "Files You Will Modify" table)

| File | In mission table? | Change | Classification |
|---|---|---|---|
| `Tests/QueueKitTests/ConformanceTests.swift` | yes | XCTest → swift-testing; preserve all assertions (6 methods, Area 1–6) | MUST_UPDATE |
| `Tests/QueueKitTests/FilesystemBackendTests.swift` | yes | XCTest → swift-testing (9 methods) | MUST_UPDATE |
| `Tests/QueueKitTests/PersistenceKitBackendTests.swift` | yes | XCTest → swift-testing (7 methods) | MUST_UPDATE |
| `Tests/QueueKitTests/SupportingTypeTests.swift` | yes | XCTest → swift-testing (9 methods) | MUST_UPDATE |
| `Tests/QueueKitTests/FixtureGenerator.swift` | yes | XCTest → swift-testing (2 methods: `testGenerate` generator + `testFixturesByteIdenticalToCommitted`) | MUST_UPDATE |
| `Tests/QueueKitTests/IdentifierTypeTests.swift` | yes (CREATE — Part 2) | new swift-testing suite covering source types lacking a peer suite: `StreamID`, `SessionID`, `ToolName`, `MissionContext` | MUST_UPDATE (new) |
| `Package.swift` | yes (conditional) | **no change** — swift-testing bundled in toolchain; `import Testing` resolves with no package dep (LatticeKit/SubstrateTypes precedent). Conditional "add only if absent" → no-op. | NOT MODIFIED (conditional no-op) |

## The 33 methods (assertion inventory, all preserved)

| File | Methods | Notes |
|---|---|---|
| ConformanceTests | 6 | Area 1 schema, Area 2 transitions, Area 3 signal, Area 4 concurrent-claim (TaskGroup; `XCTFail`→`Issue.record`), Area 5 extensions, Area 6 stale-tmp. Helpers `countIn`, actor `AtomicArray` preserved. |
| FilesystemBackendTests | 9 | maildir init, send/drain, atomic transitions, signal-before-move, reply rejects non-terminal (`do/catch QueueError.invalidTerminalStatus` + `XCTFail`→`Issue.record`), reply job-not-found, stale-tmp, drain-empty, HLC drain order. Helpers `makeKit`, `filesIn` preserved. |
| PersistenceKitBackendTests | 7 | write/drain, drain-empty, complete→done, complete job-not-found, complete rejects running, table not append-only, required indices. Helper `makeBackend` preserved. |
| SupportingTypeTests | 9 | ObservationStatus rawValues + isTerminal, JobID 32-hex, sortableHLC, filename, Job JSON round-trip, base64url, SignalFile JSON shape, ArtifactRef round-trip. |
| FixtureGenerator | 2 | `testGenerate` (fixture producer, no asserts — preserved as a `@Test`), `testFixturesByteIdenticalToCommitted` (1 `XCTAssertEqual` → `#expect`; fixtures ARE bundled so the assertion runs). Static `fixtures`/`logicalInput` helpers preserved. |

## Conversion strategy (faithful, no behavior change)

1. `import XCTest` → `import Testing` (keep `import SubstrateTypes`,
   `@testable import QueueKit`, `import PersistenceKit*` as-is).
2. `final class X: XCTestCase` → suite type. **Suites needing teardown**
   (ConformanceTests, FilesystemBackendTests — they `removeItem` the temp dir)
   become `final class` suites with `init() throws` (was `setUp`) and `deinit`
   (was `tearDown`; synchronous `try? removeItem` is deinit-safe). swift-testing
   instantiates the suite once per test, so init/deinit keep per-test semantics.
   Pure/in-memory suites (SupportingType, PersistenceKit, FixtureGenerator,
   IdentifierType) become `struct`.
3. `func testX()` → `@Test func x()`; `async throws` preserved where present.
4. Assertion mapping (1:1, semantics exact):
   - `XCTAssertEqual(a, b)` → `#expect(a == b)`
   - `XCTAssertTrue(x)` → `#expect(x)`; `XCTAssertFalse(x)` → `#expect(!x)` /
     `#expect(x == false)`
   - `XCTAssertTrue(fileExists)` / `XCTAssertFalse(...)` preserved as `#expect`
   - `do { … XCTFail("expected throw") } catch QueueError.case { }` → keep the
     `do/catch` (preserves the **specific** error-case assertion) and replace
     `XCTFail` with `Issue.record`. (Not collapsing to `#expect(throws:)` because
     QueueError is not Equatable and the tests assert a *specific* case.)
   - `XCTFail("drain failed: …")` inside Area 4 TaskGroup → `Issue.record(…)`.
5. Serialization: filesystem-touching suites (ConformanceTests,
   FilesystemBackendTests, FixtureGenerator) get `.serialized` to honor the
   mission's ordering-sensitivity caution. Correctness does not depend on it —
   each test uses a unique UUID temp dir or fresh in-memory storage, so they are
   already isolated — but `.serialized` is a harmless belt-and-suspenders that
   matches XCTest's in-class serial execution. Pure/in-memory suites stay parallel.
6. `Package.swift`: leave unchanged (verified no-op — toolchain-bundled Testing).

## Part 2 — per-source-type gap analysis

Source types and their peer coverage after Part 1:

| Source type (file) | Public? | Covered by | Gap? |
|---|---|---|---|
| `FilesystemBackend` | yes | FilesystemBackendTests, ConformanceTests | no |
| `PersistenceKitBackend` / `QueueKitSchema` | yes | PersistenceKitBackendTests | no |
| `QueueKit` (facade) | yes | exercised throughout | no |
| `QueueBackend` (protocol) | yes | via both backend suites | no |
| `Job` | yes | SupportingTypeTests, Conformance | no |
| `JobID` | yes | SupportingTypeTests | no |
| `ObservationStatus` | yes | SupportingTypeTests | no |
| `ArtifactRef` | yes | SupportingTypeTests | no |
| `CodableValue` | yes | extensions round-trips (Area 5, Job round-trip) | no |
| `WireFormat` / `SignalFile` | yes | SupportingTypeTests, Conformance | no |
| `QueueError` | yes | jobNotFound + invalidTerminalStatus exercised by backends | adequate (no dedicated suite; behavior asserted at call sites) |
| **`StreamID`** | yes | used as a field everywhere, **no dedicated assertion** | **FILL** |
| **`SessionID`** | yes | returned by drain; `.mint()` **never asserted** | **FILL** |
| **`ToolName`** | yes | **no test references it** | **FILL** |
| **`MissionContext`** | yes | **no test references it** | **FILL** |
| `Watcher` (internal enum) | no | exercised indirectly by `FilesystemBackend.watch()` | **NOT FILLED — see below** |

**`IdentifierTypeTests.swift` (new)** adds a peer suite covering `StreamID`
(RawRepresentable round-trip + Codable single-value), `SessionID` (`.mint()`
shape + lowercase + RawRepresentable + Codable), `ToolName` (RawRepresentable +
Codable), and `MissionContext` (full Codable round-trip incl. optional
`priorTrajectoryID` and `inheritedSkills` defaults). All deterministic, no IO,
no timing.

**`Watcher` deliberately not given a direct unit suite.** It is internal
(`enum Watcher`, no `public`), and on Darwin (this platform) `watchKQueue` parks
on `await box.wait()` until the DispatchSource is cancelled — there is no
cancellation path reachable from a unit test without risking a hang, and the
kqueue wake is inherently timing-dependent (flaky). It is exercised indirectly
through `FilesystemBackend.watch()`. Adding a direct test would violate the
mission's "green, zero warnings, no flaky/timing-sensitive additions" intent.
Documented as a conscious scope decision, not an oversight.

## Files NOT modified (per mission's MUST NOT list)

- `packages/kits/QueueKit/Sources/**` — released production code. Untouched.
- `packages/kits/QueueKit/rust/**` — out of scope (4 conformance `#[test]`
  left as-is). Untouched.
- `docs/validation/**` — off-limits conformance harness. Untouched.
- Any other package. Untouched.

## Test verification (filled at completion)

- `swift test`: exit 0, ≥33 `@Test` registered under the swift-testing runner.
  To be recorded verbatim.
- `cargo test`: exit 0, 4 passed (unchanged — Rust leg not touched). To be
  recorded.
