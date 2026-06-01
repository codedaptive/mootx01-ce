# Stream Completion Report — PK-TEST-01

**Mission:** PersistenceKit library test leg (swift-testing conversion)
**Stream:** pk · **Branch:** `stream/pk-persistencekit-test-leg`
**Base commit:** `16c0579` · **Head:** `5a8e6d2`
**Priority:** P1 · **Status:** ⛔ **STUCK — escalating to Bob.** Conversion complete and clean;
82 of 83 tests pass deterministically, but one faithfully-converted test
(`InMemoryObserverTests.insertNotification`) intermittently fails under swift-testing's
parallel runner because it exposes a **real production ordering race** in the InMemory
observer. The mission forbids touching `Sources/**` and forbids weakening assertions, so
the only two resolutions both require Bob's decision (see **Discovery / Blocker**).

---

## Summary

Converted the entire PersistenceKit Swift test leg from XCTest to swift-testing
(`import Testing` / `@Test` / `#expect` / `#require`), preserving every one of the 45 prior
assertions and the per-test fixture lifecycle, then added 6 peer suites (38 `@Test`) covering
core source types that lacked direct coverage. TEST-ONLY — no production source, Rust leg,
`Package.swift`, or conformance harness modified.

- **Swift test leg:** 14 XCTest files / 45 `func test*` (registering 0 under swift-testing)
  → **83 `@Test` across 19 suites**. Zero `import XCTest` remains.
- **Part 1 (conversion):** 45 assertions preserved exactly; `swift test` exit 0 at commit time.
- **Part 2 (gaps):** 38 new `@Test` for GeneratedExpression, TypedValue, Column/ColumnType,
  StorageError, Schema declarations/defaults, NoOpObserver.
- **82 of 83 tests pass deterministically.** The 83rd (`insertNotification`) is flaky under
  full-suite parallel load (~1 in 5), surfacing a pre-existing production race.

---

## Commits (3)

| Commit | Description |
|---|---|
| `469b55a` | docs(pktest): mission + Smythe pre-flight (YELLOW) + Blast Radius Report (first stream commit, hard gate) |
| `5b7bae4` | test(persistencekit): convert XCTest suites to swift-testing (assertions preserved) — Part 1 |
| `5a8e6d2` | test(persistencekit): per-type coverage gaps filled (Swift) — Part 2 |

---

## Test Verification Log

### Baseline (@ `16c0579`)
- Swift: **14 XCTest files, 45 `func test*`**, all `import XCTest`, **0 `@Test`** → registers "0 tests in 0 suites" under the swift-testing runner.
- Rust: **22 `#[test]`** in `rust/tests/inmemory_tests.rs` — **mission prose ("0 #[test]") is wrong** (recurrent "mission-prose-wrong-on-Rust" pattern, confirmed by Smythe). No parity step, no impact.

### Final (@ `5a8e6d2`)
- `cd packages/kits/PersistenceKit && swift test`
  - `@Test` count: **83** · Suites: **19** · `import XCTest`: **0**
  - **Deterministic subsets (verified):**
    - Full suite minus observer (`--skip InMemoryObserverTests`): **80 tests, exit 0**, 3/3 runs green.
    - Observer suite alone (`--filter InMemoryObserverTests`): **8/8 runs green**.
  - **Full suite (all 83, parallel): intermittent.** 5-run sample: exit 0 ×4, **exit 1 ×1**.
    Verbatim failing tail:
    `Test run with 83 tests in 19 suites failed after 0.768 seconds with 1 issue.`
    Failing assertion (Adams Method-B re-run + my run 3, identical):
    `InMemoryObserverTests.swift:81 Expectation failed: (changes[0].rowKey → 7AA3F475…) == (id1 → 443A2915…)`
    `changes.count == 2` PASSED — both events were delivered, but **out of order**.
- Warnings: **0 in test code** (`swift build --build-tests` shows warnings only in
  pre-existing `Sources/PersistenceKitPostgreSQL/**` and `Sources/PersistenceKitInMemory/InMemoryObserver.swift`, none introduced by this stream).
- Rust: not run — out of scope, no parity step.

---

## Discovery / Blocker — production ordering race in the InMemory observer

The conversion is faithful; the failing test's assertion is unchanged and legitimate. The
failure is a **real, pre-existing production bug** that XCTest's serial-by-default runner
masked and swift-testing's parallel-by-default runner exposes. Two fire-and-forget Tasks are
the cause:

1. **Out-of-order notification delivery (the actual failure).**
   `InMemoryStateActor.notify` (`Sources/PersistenceKitInMemory/InMemoryStorage.swift:103-107`)
   dispatches **one unstructured `Task { await registry.notify(change) }` per change**.
   Unstructured Tasks carry no ordering guarantee, so two sequential inserts (id1 then id2)
   can have their notifications delivered to the stream in either order. `insertNotification`
   asserts `changes[0].rowKey == id1` — a legitimate in-order-delivery expectation that the
   production code violates under load.

2. **Subscription-registration race (secondary).**
   `ObserverRegistry.register` (`Sources/PersistenceKitInMemory/InMemoryObserver.swift:18-20`)
   adds the subscriber via fire-and-forget `Task { await self.add(sub) }`, so a notification
   fired immediately after `observe()` can find no subscriber yet. The test's 50 ms settle
   sleep mitigates this; the compiler already flags the same line
   (`warning: no 'async' operations occur within 'await' expression`).

**Why it cannot be resolved within this mission's scope:**
- A **production fix** (make `notify` ordered/awaited; make `register` add the subscription
  synchronously) touches `Sources/PersistenceKitInMemory/**`, which PK-TEST-01 lists under
  "Files You MUST NOT Modify."
- The only **test-side** change that makes the test green is to drop the `changes[0] == id1`
  ordering check (e.g. assert the *set* {id1,id2}), which **weakens an assertion** — forbidden
  by "preserve EVERY assertion" / "Do not change what is asserted."
- A `.serialized` suite trait + larger sleep was trialled and **rejected**: it addresses
  registration timing, not intra-test notification ordering, and a full-suite run still failed
  (it does not isolate the suite from other suites' parallel scheduler pressure).

**Recommended resolution (needs Bob):**
- **Path B (preferred):** authorize a small production follow-up mission for
  `PersistenceKitInMemory` — make `InMemoryStateActor.notify` deliver changes in order
  (await the registry, or enqueue on the actor) and make `ObserverRegistry.register` add the
  subscription synchronously. Removes both races; the test then passes unmodified.
- **Path A (only if production is frozen):** explicit waiver to relax `insertNotification` to
  assert the observed change *set* rather than order — accepts the conversion-time
  assertion change. Not taken without Bob's sign-off.

Per the mission's standing rule — *"Sources/** … If a test reveals a real bug, STOP and
report"* — work is stopped here and escalated rather than papered over or pushed out of scope.

---

## Smythe Pre-flight (step 7) — verdict YELLOW (no blockers)

Full report: `docs/blast_radius/PK_TEST_01_PREFLIGHT.md`.

- Blast-radius confirmed: 14 files / 45 methods / all `import XCTest` / 0 `import Testing`.
- Rust prose error confirmed (22 `#[test]`, not 0); no impact.
- `ConformanceRunner.swift` is a non-test `.target` importing XCTest — Testing links in a
  regular target under Swift 6.3.2; convert runner first, then its three callers.
- PostgreSQL `XCTSkip` → early-return guard.
- No Package.swift edit needed (Swift 6.3.2 bundles Testing; LatticeKit reference confirms).
- Cautions YELLOW-1 (runner-first ordering) and YELLOW-2 (XCTSkip→guard) both honored.

## Adams Post-flight (step 12) — verdict CHANGES-REQUIRED (1 CRITICAL)

Full report: `docs/blast_radius/PK_TEST_01_POSTFLIGHT.md`. Reviewed the committed state
(`469b55a~1..HEAD`).

- **CRITICAL #1:** `insertNotification()` fails on Adams' Method-B re-run — the production
  observer race above. Adams confirmed the assertion is faithfully preserved and should NOT
  be weakened; framed it as a real bug to bring to Bob (Path A vs Path B). **This is the
  blocker driving the STUCK status.**
- **INFO #2:** `ConformanceTests.runnerExists()` body is trivially true (compilation is the
  real test) — non-blocking.
- **Everything else CLEAN:** scope (20 test files + 3 docs, zero `Sources/rust/Package.swift/
  validation` touches), zero `import XCTest`, all 45 assertions faithfully preserved
  (ConformanceRunner XCTestCase params dropped + `#expect` messages intact; `.constraintViolation`
  guards preserved; PostgreSQL guard correct; `XCTAssertThrowsErrorAsync` helper removed), all
  6 Part-2 suites non-tautological, zero test-code warnings, no anti-patterns.

(The iterate-until-PASS loop, steps 13–15, is not run: the only fix paths are out of test-only
scope or require an assertion waiver — both Bob decisions — so this escalates instead of looping.)

---

## Self-Review (step 11)

- **Files changed (this stream, `469b55a~1..HEAD`):** 14 converted test files + 6 new test
  files + 3 docs (mission, blast radius, pre-flight). **Nothing outside
  `packages/kits/PersistenceKit/Tests/**` and `docs/**`.** (`main` has diverged with parallel
  test-leg streams; scope was verified against this stream's own commit range, not `main`.)
- **Production untouched:** `git diff 469b55a~1..HEAD` shows zero `Sources/**`, `rust/**`,
  `Package.swift`, or `docs/validation/**` changes.
- **Assertions:** all 45 preserved exactly; 38 added. No weakening anywhere — which is exactly
  why the observer test cannot be silently made green.
- **Anti-patterns:** none (no bridges, shims, deprecation stubs, silenced warnings, orphan
  helpers, secrets). Explicit `import Foundation` added where XCTest previously supplied it
  transitively.

---

## Conditional Agents (steps 14–17)

- **Simms / Friedlander / Nert:** N/A — test-only, no user-facing or UI change.
- **Perkins:** N/A for the conversion itself. Note: the discovered observer race is a
  correctness/ordering defect, not a security boundary issue.

---

## Success Criteria — status

| Criterion | Status |
|---|---|
| 14 suites converted, assertions intact and registering | ✅ |
| Zero `import XCTest` remains | ✅ |
| Source surface covered (6 new peer suites) | ✅ |
| Production untouched | ✅ |
| Swift leg green | ⛔ **82/83 deterministic; 1 test exposes a production race — BLOCKED on Bob** |

**Net:** conversion + coverage are done and clean. Shipping is blocked on a single
pre-existing production ordering bug that this faithful conversion legitimately surfaced and
that cannot be fixed inside test-only scope without weakening an assertion. Awaiting Bob's
choice of Path B (production follow-up) or Path A (assertion waiver).
