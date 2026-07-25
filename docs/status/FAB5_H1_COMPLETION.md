---
title: FAB5-H1 Completion Report
mission: FAB5-H1
stream: h1
status: COMPLETE
date: 2026-07-24
worker: bilby
---

# FAB5-H1 — Apple Intelligence Worker Framework + First Three Workers — Completion Report

## Status: COMPLETE

---

## Smythe Pre-flight

**Verdict: YELLOW → GREEN (resolved before implementation)**

One dependency question: `MootGateway` target does not have `MootFoundationModelsKit`
as a Package.swift dependency — only `GatewayUI` does. Smythe asked Bilby to confirm
workers would import `FoundationModels` (system framework) only, not `MootFoundationModelsKit`.

**Resolved:** Workers import `FoundationModels` system framework via `import FoundationModels`
only. `@Generable`, `LanguageModelSession`, `SystemLanguageModel` are all system APIs — no
Package.swift edit required. Terrain cleared to GREEN.

Additional terrain facts confirmed:
- `Sources/MootGateway/Workers/` did not exist — net-new confirmed
- `Sources/MootGateway/Review/` does not exist — MUST NOT MODIFY holds trivially
- `GatewayUI/IntelligenceView.swift` had zero Workers references
- Git clean on `stream/h1-ai-worker-framework`

---

## Test Verification Log

### Baseline (mission start)
- Command: `swift test --package-path apps/Mootx01-App 2>&1 | tail -8`
- Pass count: 34 tests in 7 suites (GatewayUITests visible in tail; MootGatewayTests ran before)

### Final
- Command: `swift test --package-path apps/Mootx01-App 2>&1 | grep "Test run with"`
- Exit code: 0
- MootGatewayTests: **181 tests in 32 suites passed** (after 4.365 seconds)
- GatewayUITests: **34 tests in 7 suites passed** (after 0.020 seconds)
- Tail output (verbatim):
  ```
  Test "posture raw values are stable (no key drift)" passed after 0.001 seconds.
  Test "endSession updates lastSession timestamp on the known peer (real manager)" started.
  Test "endSession updates lastSession timestamp on the known peer (real manager)" passed after 0.002 seconds.
  Suite "FederationPanel — state transitions and F1 invariants (FED-OD-6b)" passed after 0.019 seconds.
  Test run with 34 tests in 7 suites passed after 0.019 seconds.
  ```

**Note on runSafe tests:** Apple Intelligence was live on the M-series Mac during tests.
`SummarizeWorker.runSafe` (5.4s), `ExtractFactsWorker.runSafe` (1.5s), `ClassifyWorker.runSafe`
(4.4s) ran the real model path — not just fallbacks. Both paths verified.

---

## Implementation

### Part 1 — WorkerCore + availability/fallback
Commit: `3f98ef35` `feat(app-ai): MootWorker protocol with availability + fallback`

- `MootWorker` protocol: `Sendable`, `associatedtype Input/Output: Sendable`,
  `static isAvailable: Bool`, `run()` throws, `fallback()` never fails,
  `runSafe()` default impl gates on availability and catches all `run()` errors
- `WorkerPrompts`: typed static `let` prompt templates (summarize, extractFacts, classify)
- `WorkerFallbacks`: one factory per worker — deterministic, zero tool calls

### Part 2 — Summarize / ExtractFacts / Classify
Commit: `1322bf5b` `feat(app-ai): summarize, extract-facts, classify workers`

**SummarizeWorker**
- Input: `SummarizeInput(query: String, limit: Int)`
- Output: `SummarySuggestion` (`@Generable` — `summary: String`)
- run(): `moot_memory_search` → `LanguageModelSession { Instructions }` → `respond(generating: SummarySuggestion.self)`

**ExtractFactsWorker**
- Input: `ExtractFactsInput(query: String, limit: Int)`
- Output: `ExtractFactsResult(triples: [ProposedTriple])`
- `ProposedTriple.isProposed` is `private(set)` and set to `true` in `init` — invariant enforced
  at construction, not clearable externally or by the model path
- Intermediate `@Generable`: `ExtractedTripleSuggestion`; each suggestion is wrapped in a
  `ProposedTriple` that stamps `isProposed = true`
- PROPOSED-only guarantee holds on both the model path and the fallback (empty set)

**ClassifyWorker**
- Input: `ClassifyInput(content: String)` — caller provides text, no estate query
- Output: `ClassificationSuggestion` (`@Generable` — `suggestedRoom: String`, `suggestedTags: [String]`)

### Part 3 — Fixtures + interface drawer
Commit: `0c36cb87` `test(app-ai): worker fixtures + interface writeback`

- `MockCaller: MootToolCalling` actor records called tool names; returns fixture text
- Test suites: Worker fallbacks (4), ExtractFacts PROPOSED invariant (3),
  Workers do not mutate the estate (3), Worker runSafe guarantees (2)
- W2-INTERFACE FAB5-H1 drawer filed to estate (ID: A743A822-2FAD-4958-97A9-81CB1EB2201F,
  location: fab5-w2, wing: Agentic Memory)

### Post-flight fix
Commit: `9787b5f5` `fix(app-ai): localize fallback summary string per localization rule`

- Adams finding: hardcoded English literal in `WorkerFallbacks.summarize()` violated
  localization rule. Wrapped in `String(localized:)` — self-describing key pattern;
  returns English text when no translation table entry exists, extraction-tool-visible.

---

## Adams Post-flight

**Verdict: PASS with one remediated finding**

- Tests: verified 181 + 34 = 215 tests, exit 0, Apple Intelligence ran live ✅
- Scope: six new files only, no existing edits, Package.swift untouched ✅
- PROPOSED invariant: `ProposedTriple.isProposed` private(set), always true ✅
- Zero mutation verbs: confirmed absent from all Workers/ source files ✅
- IntelligenceView, Review/, packages/kits/: untouched ✅

Findings remediated before report:
- **Localization (remediated)**: `WorkerFallbacks.summarize()` hardcoded English →
  wrapped in `String(localized:)` in commit `9787b5f5`

Remaining (advisory, H2 scope):
- Vacuous mock assertion test (no-assertion ClassifyWorker.runSafe test) — tests run but
  don't assert specific model output; acceptable for live-AI path where output varies
- No-assertion pattern in `classifyRunSafeValid` — intent documentation, not enforcement

---

## Self-Review

| Check | Status |
|-------|--------|
| Net-new only — no existing file edits | ✅ |
| Package.swift untouched | ✅ |
| IntelligenceView.swift untouched | ✅ |
| Review/ untouched | ✅ |
| packages/kits/ untouched | ✅ |
| Workers only call `moot_memory_search` (read verb) | ✅ |
| `ProposedTriple.isProposed` always true, private(set) | ✅ |
| `SummarySuggestion.summary` fallback uses `String(localized:)` | ✅ |
| `@Generable` types conform to `Sendable` | ✅ |
| Swift 6 strict concurrency — build clean | ✅ |
| No bridge helpers, shims, orphan deprecations, TODOs on changed symbols | ✅ |
| Comment currency — no stale comments | ✅ |

---

## Files Created

```
apps/Mootx01-App/Sources/MootGateway/Workers/
  WorkerCore.swift          — MootWorker protocol, WorkerPrompts, runSafe default
  WorkerFallbacks.swift     — deterministic fallback factory for all three workers
  SummarizeWorker.swift     — SummarySuggestion, SummarizeInput, SummarizeWorker
  ExtractFactsWorker.swift  — ProposedTriple, ExtractFactsResult, ExtractFactsWorker
  ClassifyWorker.swift      — ClassificationSuggestion, ClassifyInput, ClassifyWorker

apps/Mootx01-App/Tests/MootGatewayTests/Workers/
  WorkerTests.swift         — MockCaller, 4 test suites, 12 tests
```

No existing files modified.

---

## Success Criteria

| Criterion | Status |
|-----------|--------|
| Three workers callable with typed results both on- and off-device | ✅ |
| Unavailable path returns fallback, never throws to UI layer | ✅ |
| ExtractFacts marks every triple PROPOSED — never auto-filed | ✅ |
| Zero estate mutation from any worker | ✅ |
| Worker tests exit 0 | ✅ |
| W2-INTERFACE drawer filed | ✅ |
| IntelligenceView NOT edited (FAB5-H2) | ✅ |
