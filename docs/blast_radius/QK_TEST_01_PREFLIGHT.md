# Smythe Pre-flight: QK-TEST-01

## Status
GREEN

## Status details
- Blast radius: verified — 5 files, 33 methods, counts exact
- Prior art: none conflicting
- Environment: clean — `swift test` exit 0, 33 executed, 0 failures; swift-testing
  runner "0 tests in 0 suites" confirmed (the bug this mission fixes)
- Dependencies: satisfied — `import Testing` resolves with no Package.swift dep

## Blockers
None.

---

## Verification findings (each item below)

### 1. Blast-radius reality — file count and method counts

5 XCTest files present. All confirmed by filesystem scan:

```
Tests/QueueKitTests/ConformanceTests.swift
Tests/QueueKitTests/FilesystemBackendTests.swift
Tests/QueueKitTests/FixtureGenerator.swift
Tests/QueueKitTests/PersistenceKitBackendTests.swift
Tests/QueueKitTests/SupportingTypeTests.swift
```

`func test` count per file:

| File | BRR claim | Actual |
|---|---|---|
| ConformanceTests | 6 | 6 |
| FilesystemBackendTests | 9 | 9 |
| PersistenceKitBackendTests | 7 | 7 |
| SupportingTypeTests | 9 | 9 |
| FixtureGenerator | 2 | 2 |
| **Total** | **33** | **33** |

Import state: all 5 files import `XCTest`. Zero `import Testing` present. Baseline
is exactly as described.

### 2. Baseline test state

`cd packages/kits/QueueKit && swift test` run:

- Exit: 0
- XCTest runner: "Executed 33 tests, with 0 failures" — confirmed.
- swift-testing runner: "Test run with 0 tests in 0 suites passed after 0.001 seconds" — confirmed.

Baseline clean. The "0 tests in 0 suites" defect is present and this mission fixes it.

### 3. Rust #[test] count — non-blocking prose inaccuracy

Mission Context: "Its Rust leg has 0 `#[test]` functions."
Reality: `rust/tests/conformance.rs` contains **4** `#[test]` functions (lines 89, 104, 116, 149).

Non-blocking. The BRR correctly identifies and explains this: those 4 are byte-conformance
fixtures, not behavioral unit tests; `rust/**` is on MUST-NOT-modify. The operative intent
("no Rust parity step") stands. Skippy should note the prose is inaccurate for future
mission authoring; it is not a blocker for Bilby.

### 4. swift-testing wiring — Package.swift change is a no-op

`import Testing` resolves in the toolchain with no Package.swift dependency:

- `packages/kits/LatticeKit/Tests/LatticeKitTests/CodeTests.swift`: `import Testing` only,
  no Testing package dep in Package.swift.
- `packages/libs/SubstrateTypes/Package.swift`: no Testing entry; 20+ test files use
  `import Testing` with no issues.
- QueueKit's `Package.swift` already lists no Testing dep. No change required. The
  "conditional: add only if absent" → confirmed no-op.

### 5. Part 2 gap analysis — source types and Watcher exclusion

**Gap types confirmed in source:**

| Type | File | Public? | Dedicated suite? |
|---|---|---|---|
| `StreamID` | `Job.swift:51` | yes | no — used as field input in tests but never asserted on directly |
| `SessionID` | `Job.swift:68` | yes | no — `.mint()` never asserted |
| `ToolName` | `Job.swift:80` | yes | no — zero test references |
| `MissionContext` | `Job.swift:254` | yes | no — zero test references |

Note: `testJobJSONRoundTrip` in SupportingTypeTests asserts `decoded.streamID == original.streamID`
(via `Job` round-trip), touching `StreamID` incidentally. No dedicated RawRepresentable
or Codable single-value assertions exist. BRR's "no dedicated assertion" is accurate.

**Watcher exclusion — assessment: ACCEPTED.**

Read `Watcher.swift` in full. `watchKQueue` parks on `await box.wait()` until
`source.cancelHandler` is called, which fires when the DispatchSource is cancelled.
There is no cancellation path accessible from a unit test without Task.cancel being
coordinated with the DispatchSource lifecycle. On Darwin (this machine, macOS 14),
the code path requires opening a real file descriptor with `O_EVTONLY`, creating a
DispatchSource against it, and then triggering cancellation — inherently timing-
dependent. The type is `internal` (not `public`), so it is not part of the public
API surface. The BRR's rationale is technically sound. NOT FILLED is correct.

### 6. Conversion hazards — init/deinit semantics and do/catch mapping

**setUp/tearDown → init/deinit:**

Confirmed: ConformanceTests and FilesystemBackendTests both use `override func setUp() async throws`
and `override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }`.

The BRR's plan: convert to `final class` with `init() throws` + `deinit`. The key
property: `try? removeItem` is **synchronous** — `FileManager.default.removeItem(at:)`
is not async. Deinit cannot be async or throwing, but `try?` on a synchronous call is
legal in deinit. swift-testing instantiates a new instance per `@Test`, so
init/deinit preserve per-test setUp/tearDown semantics exactly. Assessment: **sound.**

PersistenceKitBackendTests and SupportingTypeTests: no setUp/tearDown. Correctly
identified as `struct` candidates.

FixtureGenerator: no setUp/tearDown either (writes to a fresh UUID tmpDir per test,
no shared teardown state). The BRR assigns it `.serialized` as "belt-and-suspenders"
— harmless but not mechanically required. Noted, not a concern.

**do/catch QueueError mapping:**

Two patterns confirmed in FilesystemBackendTests (lines 121–128, 132–139):
```swift
do {
    // ... action
    XCTFail("expected throw")
} catch QueueError.invalidTerminalStatus { }

do {
    // ... action
    XCTFail("expected throw")
} catch QueueError.jobNotFound { }
```

`QueueError` is `public enum QueueError: Error, Sendable` — **no `Equatable` conformance.**
BRR's rationale is correct: `#expect(throws:)` with a value would not compile (requires
`Equatable`). The `do/catch` → `Issue.record` mapping is the right call and preserves
the specific-case assertion faithfully.

ConformanceTests (line 147–153): `XCTFail("drain failed: \(error)")` inside Area 4
TaskGroup catch — maps to `Issue.record("drain failed: \(error)")`. Straightforward.

---

## Bilby's stated approach

Per BRR "Conversion strategy" and "Part 2" sections:

Part 1: Replace `import XCTest` with `import Testing` across all 5 files. Convert
`final class X: XCTestCase` to suite types (class with init/deinit for
ConformanceTests and FilesystemBackendTests; struct for the others). Rename
`func testX()` to `@Test func x()`. Map all assertions 1:1 per the enumerated
mapping. Apply `.serialized` to filesystem-touching suites. No behavior change.
Commit when `swift test` green and ≥33 registered under swift-testing runner.

Part 2: Create `IdentifierTypeTests.swift` covering StreamID (RawRepresentable
round-trip + single-value Codable), SessionID (.mint() shape + lowercase +
RawRepresentable + Codable), ToolName (RawRepresentable + Codable), and
MissionContext (full Codable round-trip including optional `priorTrajectoryID`
and `inheritedSkills` defaults). All deterministic, no IO, no timing.

Assessment: **accepted.** The approach is complete, faithful, and contains no
surprises. Every assertion is preserved. Production source is untouched.
Package.swift is a confirmed no-op. The FixtureGenerator `testGenerate` correctly
preserved as a `@Test` with no assertions (it's a fixture producer, not a test gate).
The `testFixturesByteIdenticalToCommitted` assertion survives because fixtures ARE
bundled in the test target resources.

---

## Actions (proceeding)

1. Read all 5 existing test files in full before touching any.
2. Part 1 — convert ConformanceTests.swift first (most complex: async setUp, TaskGroup
   Area 4, actor AtomicArray helper).
3. FilesystemBackendTests, PersistenceKitBackendTests, SupportingTypeTests, FixtureGenerator
   in sequence.
4. `swift test` — verify exit 0, swift-testing runner shows ≥33 tests. Commit Part 1.
5. Part 2 — create `IdentifierTypeTests.swift`. `swift test` green. Commit Part 2.
6. Write signal file to `/Users/bob/devlop/ddfactory/control/signals/.done-qk`.

## Decision needed
None.

---

**Verdict: GREEN. Terrain clear. Proceed.**
