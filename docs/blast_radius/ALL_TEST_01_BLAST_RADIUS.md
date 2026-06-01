# Blast Radius Report — ALL-TEST-01 (AriaLexiconLib library test leg, swift-testing)

Mission: `docs/missions/inflight/MISSION_ALL_TEST_01.md`
Stream: alltest · Branch: `stream/al-arialexiconlib-test-leg`
Baseline commit: `b42db96` · Head: (this report = first commit)
Tier: **test-only** — no production source modified. Adds per-source-type
swift-testing peer suites; the XCTest→swift-testing conversion the mission
describes is already present in the tree (see premise correction below).

## Status: PROCEED — no RESCOPE required

Smythe pre-flight verdict: **YELLOW** (`docs/blast_radius/ALL_TEST_01_PREFLIGHT.md`).
Premise correction (not a blocker), zero CRITICAL items, no RESCOPE. Scope is
*narrower* than the mission claims, not wider.

Baseline test counts (Smythe-verified + Bilby-confirmed, this branch @ `b42db96`):
- Swift `swift test`: **9 passed in 1 suite, 0 failed** (exit 0).
  Tail: `Test run with 9 tests in 1 suite passed after 0.001 seconds.`
- Rust `cargo test`: **9 passed, 0 failed** (exit 0).
  Tail: `test result: ok. 9 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out`.

## Premise correction — MUST READ

The mission states the Swift leg is `LexiconTests.swift` using `import XCTest`,
registering "0 tests in 0 suites." **This is false against the actual tree.**
The file already uses `import Testing`, declares `@Suite("AriaLexiconLibTests")`,
holds 9 `@Test` methods, and registers 9 tests at baseline (verified above). The
XCTest→swift-testing conversion in mission Part 1 is **already done**; there is no
`import XCTest` anywhere under `Tests/`. The real remaining work is the per-type
peer suites (the four CREATE files). The Part 1 commit message is adjusted to
reflect this reality (see below).

## MUST_UPDATE list (reality vs mission's "Files You Will Modify" table)

The mission table listed 6 files (1 convert + 4 CREATE + 1 conditional Package.swift).
Real in-scope blast radius is **4 files**, all net-new test files. Two mission-table
entries are no-ops: the "convert" (already done) and the Package.swift dep.

| File | In mission table? | Change | Classification |
|---|---|---|---|
| `Tests/AriaLexiconLibTests/AcceptanceTests.swift` | yes (CREATE) | new per-type suite | MUST_UPDATE (new) |
| `Tests/AriaLexiconLibTests/NounTests.swift` | yes (CREATE) | new per-type suite | MUST_UPDATE (new) |
| `Tests/AriaLexiconLibTests/AdjectiveTests.swift` | yes (CREATE) | new per-type suite (thin by design) | MUST_UPDATE (new) |
| `Tests/AriaLexiconLibTests/VerbTests.swift` | yes (CREATE) | new per-type suite | MUST_UPDATE (new) |
| `Tests/AriaLexiconLibTests/LexiconTests.swift` | yes (convert) | **NO CHANGE** — already swift-testing; Y1→Option A leaves it intact to preserve all 9 assertions literally | NOT MODIFIED |
| `Package.swift` | yes (conditional) | **NO CHANGE** — swift-testing available via tools-version 6.0 (Finding 4); a dep would be a no-op | NOT MODIFIED |

## What each new suite asserts (grounded strictly in Sources/)

- **AcceptanceTests.swift** — mirrors Rust `acceptance_matrix`, `accepts_agrees`,
  `verb_applicability`. Full 8-noun matrix via `Acceptance.verbs(for:)` using
  `Set<Verb>` equality (Y3 — no ordering assumed; Swift returns `Set<Verb>`).
  Exhaustive `accepts(_:_:) == verbs(for:).contains` cross-check over every
  noun×verb pair. Vector accepts none. Learn only on learnedReference; capture
  only on drawer+tunnel.
- **NounTests.swift** — mirrors Rust `drawer_is_primary`, `non_drawer_shapes_have_roles`.
  Adds: `Noun.allCases.count == 8`, `primary == .drawer`, per-case `role` for all
  8, role-partition counts (1 primary / 2 rung / 3 structure / 2 product),
  `NounRole.allCases.count == 4`, rawValue identity round-trip (String/Codable enum).
- **VerbTests.swift** — mirrors Rust `verb_count_is_nine`, `verb_flows_partition`.
  Adds: `Verb.allCases.count == 9` + declaration-order identity, per-case `flow`
  for all 9, flow-partition counts (6 caller / 2 substrate / 1 grounding),
  `Flow.allCases.count == 3`, rawValue identity.
- **AdjectiveTests.swift** — mirrors Rust `adjective_count_is_four`. Thin by design
  (Y2): `Adjective.allCases.count == 4`, the four category identities
  `[.state, .trust, .sensitivity, .exportability]`, rawValues. No axis-value
  semantics invented — the Swift `Adjective` has none (Known Ambiguity 1 resolved
  by reading source).

Top-level `AriaLexiconLib.grammar` stays covered by `LexiconTests.grammarStated`
(mirrors Rust `grammar_stated`). All 9 Rust behaviors retain a Swift peer; the new
suites add depth, not just relocation.

## Files NOT modified (per mission's MUST NOT list)

- `Sources/AriaLexiconLib/**` — released production code. Read only.
- `rust/**` — behavior reference only. Read only.
- `docs/validation/**` — off-limits (EE-only conformance harness; not coverage).
- Any other package.
- `Package.swift` — no swift-testing dep needed (Finding 4).
- `LexiconTests.swift` — left intact (Y1 Option A).

## Parity statement

Swift↔Rust parity is at the behavior level (CognitionKit/LocusKit lens parity
rule does not apply — this is a library vocabulary, Swift is the design surface
and already leads). The 9 Rust `#[test]` behaviors each have ≥1 Swift `@Test`
peer after this mission; the Swift side asserts a superset (added type-local
depth). No production semantics are under test that differ across legs — both
ports encode the identical fixed vocabulary.

## Commit plan

- Part 1: `test(arialexiconlib): per-type swift-testing peer suites (Swift) — conversion already in tree`
- Part 2: `test(arialexiconlib): Swift/Rust library-test parity confirmed`

## Test verification (filled at completion)

- `swift test`: exit 0, NN passed (9 baseline + new). To be recorded.
- `cargo test`: exit 0, 9 passed (unchanged — no Rust edit). To be recorded.
