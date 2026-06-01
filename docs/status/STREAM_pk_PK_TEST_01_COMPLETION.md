# Stream Completion Report — PK-TEST-01

**Mission:** PersistenceKit library test leg (swift-testing conversion)
**Stream:** pk · **Branch:** `stream/pk-persistencekit-test-leg`
**Base commit:** `16c0579` · **Head:** `0b68584`
**Priority:** P1 · **Status:** ✅ **COMPLETE — Swift leg green, Adams PASS.**

The conversion + coverage landed clean. One faithfully-converted test surfaced a **real
production ordering race** in the InMemory observer (masked by XCTest's serial runner, exposed
by swift-testing's parallel runner). Per the mission's "test reveals a real bug → STOP and
report" rule, work was paused and escalated; **Bob authorized Path B (production fix)**, which
was applied, verified, and re-reviewed to PASS.

---

## Summary

Converted the entire PersistenceKit Swift test leg from XCTest to swift-testing
(`import Testing` / `@Test` / `#expect`), preserving every one of the 45 prior assertions and
the per-test fixture lifecycle, then added 6 peer suites (38 `@Test`) covering core source
types that lacked direct coverage. The conversion exposed a latent InMemory-observer
concurrency bug, fixed under an authorized scope expansion into `Sources/PersistenceKitInMemory`.

- **Swift test leg:** 14 XCTest files / 45 `func test*` (registering 0 under swift-testing)
  → **83 `@Test` across 19 suites**. Zero `import XCTest` remains.
- **Part 1 (conversion):** 45 assertions preserved exactly.
- **Part 2 (gaps):** 38 new `@Test` (GeneratedExpression, TypedValue, Column/ColumnType,
  StorageError, Schema declarations/defaults, NoOpObserver).
- **Path B production fix:** ordered observer notifications + synchronous subscription
  registration. **No test assertion changed.**
- **swift test: 83/83 green, exit 0, verified across 20 consecutive runs (Bilby 12 + Adams 8).**

---

## Commits (5)

| Commit | Description |
|---|---|
| `469b55a` | docs(pktest): mission + Smythe pre-flight (YELLOW) + Blast Radius Report (first stream commit, hard gate) |
| `5b7bae4` | test(persistencekit): convert XCTest suites to swift-testing (assertions preserved) — Part 1 |
| `5a8e6d2` | test(persistencekit): per-type coverage gaps filled (Swift) — Part 2 |
| `22d8009` | docs(pktest): completion report (interim STUCK) + Adams first post-flight (CHANGES-REQUIRED) |
| `0b68584` | fix(persistencekit): order InMemory observer notifications; register subscriptions synchronously — **Path B** |

---

## Test Verification Log

### Baseline (@ `16c0579`)
- Swift: **14 XCTest files, 45 `func test*`**, all `import XCTest`, **0 `@Test`** → "0 tests in 0 suites".
- Rust: **22 `#[test]`** in `rust/tests/inmemory_tests.rs` — **mission prose ("0 #[test]") is wrong** (recurrent "mission-prose-wrong-on-Rust" pattern, confirmed by Smythe). No parity step, no impact.

### Final (@ `0b68584`)
- `cd packages/kits/PersistenceKit && swift test`
  - Exit code: **0**
  - `@Test` count: **83** · Suites: **19** · `import XCTest`: **0**
  - Tail (verbatim): `Test run with 83 tests in 19 suites passed after 0.068 seconds.`
  - **Flake check:** the previously-intermittent `insertNotification` now passes reliably —
    **12/12 consecutive full-suite runs (Bilby)** + **8/8 (Adams Method-B re-run)** = 20/20 green.
  - Warnings: **0** in test code AND in the changed Sources; the pre-existing
    `InMemoryObserver.swift` "no 'async' operations" warning is **removed** by the fix.
- Rust: not run — out of scope, no parity step.

---

## The bug, and the Path B fix (authorized scope expansion)

The conversion is faithful; the failure was a **real, pre-existing production bug** that
XCTest's serial-by-default runner masked and swift-testing's parallel-by-default runner exposed.
Two fire-and-forget Tasks in `Sources/PersistenceKitInMemory`:

1. **Out-of-order notification delivery (the observed failure).** `InMemoryStateActor.notify`
   spawned **one unstructured `Task { await registry.notify(change) }` per change** — no
   ordering guarantee, so two sequential inserts could be observed out of order. (Failure
   signature: both events delivered, `changes[0].rowKey == id2` not `id1`.)
2. **Subscription-registration race.** `ObserverRegistry.register` added the subscriber via
   fire-and-forget `Task { await self.add(sub) }`.

**Fix (`0b68584`, confined to `Sources/PersistenceKitInMemory/`):**
- `InMemoryStateActor.notify` is now `async` and **awaits** delivery; `insertRow`/`upsertRow`/
  `updateRows`/`deleteRows` became `async` to await it in mutation order. Callers
  (`InMemoryRowStore`) already used `try await` — zero caller changes.
- `ObserverRegistry.register` now uses `AsyncStream.makeStream` and records the subscription
  **synchronously** (actor-isolated) before returning the stream; dead `add(_:)` helper removed.
- **No test assertion was changed** — `changes[0].rowKey == id1` (the strict ordering check) is
  intact. The production code was corrected to honor it.

**Process note:** Path B was chosen by Bob after the interim STUCK escalation. Path A (relax the
ordering assertion) was explicitly rejected — it would have masked the bug. SQLite/PostgreSQL
backends were unaffected (their conformance suites pass).

**Residual INFO (Adams, non-blocking):** `InMemoryObserver.observe()` still hops onto the actor
via a bridge `Task` for the now-synchronous `register()`; the test's 50 ms settle sleep covers
the scheduling window. Not a race — cosmetic asymmetry, candidate for a future cleanup.

---

## Smythe Pre-flight (step 7) — verdict YELLOW (no blockers)

Full report: `docs/blast_radius/PK_TEST_01_PREFLIGHT.md`.
- Blast radius confirmed (14 files / 45 methods / all XCTest / 0 Testing). Rust prose error
  confirmed (22, not 0). ConformanceRunner non-test `.target` → convert runner first.
  PostgreSQL `XCTSkip` → guard-return. No Package.swift edit (Swift 6.3.2 bundles Testing).
  Cautions YELLOW-1/YELLOW-2 honored.

## Adams Post-flight (steps 12–15)

Full report: `docs/blast_radius/PK_TEST_01_POSTFLIGHT.md`.

### First pass — CHANGES-REQUIRED (1 CRITICAL)
- **CRITICAL #1:** `insertNotification()` failed on Method-B re-run (the production observer
  race). Adams confirmed the assertion was faithfully preserved and must NOT be weakened;
  flagged Path A vs Path B for Bob. **Drove the interim STUCK escalation.**
- **INFO #2:** `ConformanceTests.runnerExists()` body trivially true (compilation is the test).
- Everything else CLEAN: scope, zero `import XCTest`, 45 assertions preserved, 6 Part-2 suites
  non-tautological, zero test-code warnings, no anti-patterns.

### Verification pass (after Path B fix `0b68584`) — **PASS**
> "Clean. Ship it."
- Re-ran `swift test` **8/8** green; flake confirmed gone (not one lucky run).
- Fix correct & minimal: both races closed; mutation methods async only as needed; callers
  unchanged; **ordering assertion intact, not worked around**.
- Scope confined to the two authorized `Sources/PersistenceKitInMemory/` files; no collateral
  damage (SQLite/PostgreSQL conformance pass); zero new warnings; pre-existing warning removed.

---

## Self-Review (step 11)

- **Files changed (this stream, `16c0579..HEAD`):** 14 converted test files + 6 new test files
  + 2 production files (authorized Path B) + 4 docs (mission, blast radius, pre-flight,
  post-flight) + this report. Verified against the stream's own commit range (`main` has
  diverged with parallel test-leg streams).
- **Scope:** test changes are test-only; the sole production change is the Bob-authorized
  observer fix in `Sources/PersistenceKitInMemory/{InMemoryObserver,InMemoryStorage}.swift`.
  No `rust/**`, `Package.swift`, `docs/validation/**`, or other-package changes.
- **Assertions:** all 45 preserved exactly; 38 added; none weakened (the bug was fixed in
  production rather than hidden in the test).
- **Anti-patterns:** none. Explicit `import Foundation` added where XCTest previously supplied
  it transitively. Dead `add(_:)` helper removed as part of the fix.

---

## Conditional Agents (steps 14–17)

- **Simms / Friedlander / Nert:** N/A — test-only conversion; the production fix is an internal
  concurrency-ordering correction with no user-facing or UI surface.
- **Perkins:** N/A — no CloudKit/schema/privacy/API-key/NL/URL/Keychain surface. The observer
  fix is correctness/ordering, not a security boundary.

---

## Success Criteria — met

✅ 14 suites converted; all 45 assertions intact and registering.
✅ Zero `import XCTest` remains.
✅ Source surface covered (6 new peer suites; 38 `@Test`).
✅ Swift leg green — **83/83, exit 0, 20/20 consecutive runs**, zero warnings.
✅ Production correctness preserved — the one production change (authorized Path B) fixes a
   real ordering race and changes no observable behavior beyond honoring in-order delivery.
