# Blast Radius Report — GUARDIAN_001

**Baseline:** swift test pass count at mission start: 516
**Mission:** GUARDIAN_001 — SwiftSyntax Guardian cross-layer bitmap invariant linter
**Branch:** main (merge-base 38f300c56e8d2ebebc4772a55d47467193d6516b == main HEAD)
**Codegraph:** not queried — this is a predominantly additive mission (new
tool, new test file, sentinel-comment edits to existing files). No existing
symbols are renamed, removed, or semantically changed.

---

## Nature of Changes

GUARDIAN_001 is predominantly additive:

1. **NEW**: `tools/guardian/` — SwiftPM executable package (new directory,
   no prior existence).
2. **NEW**: `tools/guardian/Tests/GuardianTests/` — self-test suite.
3. **NEW**: `tools/guardian/fixtures/` — deliberately-desynced fixture pair.
4. **NEW**: `tools/guardian/README.md` — operator documentation.
5. **COMMENT-ONLY edits** to seven existing watched source files: sentinel
   block (`@guardian-pair:` line + human explanation block). Zero behavior
   change to any declaration or expression.
6. **NEW**: `packages/kits/LocusKit/Tests/LocusKitTests/GuardianPairParityTests.swift`
   — new test file (additive; no existing symbols changed).
7. **NEW**: `docs/blast_radius/GUARDIAN_001_BLAST_RADIUS.md` — this file.

The only existing files touched are the four watched source files. All
touches are comment-only — no declaration, expression, or type is modified.
Swift test output is unaffected by comment edits.

---

## Watched Files — Comment-only Edits

| File | Pairs Added | Classification |
|---|---|---|
| `packages/libs/SubstrateLib/Sources/SubstrateLib/AuditGate.swift` | 1, 2, 3, 4 (basis legalValues) | MUST_UPDATE (sentinel comment) |
| `packages/libs/SubstrateLib/Sources/SubstrateLib/RowStateAutomaton.swift` | 5 (I-22 raws), 6 (S-1 threshold) | MUST_UPDATE (sentinel comment) |
| `packages/kits/LocusKit/Sources/LocusKit/Adjectives.swift` | 1, 2, 3, 4 (canonical side) | MUST_UPDATE (sentinel comment) |
| `packages/kits/LocusKit/Sources/LocusKit/DrawerStore.swift` | 4b (mutateState + expungeGated stateSlots) | MUST_UPDATE (sentinel comment) |

---

## Pair Correspondence Table — Verified at HEAD

All values verified by reading source files before implementation.
No live drift found at HEAD.

| Pair | Lower site | Lower value | Canonical site | Canonical value | Status |
|---|---|---|---|---|---|
| 1 | AuditGate basis state legalValues | `{0,1,2,3,16,17,18,19,32,33}` | Adjectives.swift State allCases | same 10 raws | MATCH |
| 2 | AuditGate basis sensitivity legalValues | `{0,16,32,48}` | Adjectives.swift AdjectiveSensitivity allCases | same 4 raws | MATCH |
| 3 | AuditGate basis exportability legalValues | `{0,32}` | Adjectives.swift AdjectiveExportability allCases | same 2 raws | MATCH |
| 4 | AuditGate basis trust legalValues | `{0,1,2,3,4,5,6}` | Adjectives.swift Trust allCases | same 7 raws | MATCH |
| 4b-a | DrawerStore.mutateState stateSlot legalValues | `{0,1,2,3,16,17,18,19,32,33}` | Adjectives.swift State allCases | same 10 raws | MATCH |
| 4b-b | DrawerStore.expungeGated stateSlot legalValues | `{0,1,2,3,16,17,18,19,32,33}` | Adjectives.swift State allCases | same 10 raws | MATCH |
| 5 | RowStateAutomaton I-22 sensitivity raw | `48` | AdjectiveSensitivity.secret.rawValue | `48` | MATCH |
| 5b | RowStateAutomaton I-22 exportability raw | `32` | AdjectiveExportability.public_.rawValue | `32` | MATCH |
| 6 | RowStateAutomaton S-1 trust threshold `< 3` | `3` | Trust.canonical.rawValue | `3` | MATCH |

**No live drift found at HEAD. Zero pre-existing violations.**

---

## Parity Test Placement Decision

**Decision:** `GuardianPairParityTests.swift` placed in
`packages/kits/LocusKit/Tests/LocusKitTests/`.

**Rationale:**

The LocusKitTests target depends on `LocusKit`, which depends on
`SubstrateLib`. All public symbols needed for parity assertions are
reachable via `import LocusKit` (which re-exposes SubstrateLib's public
API). Specifically:

- `Vocabulary.basis` is `public static let` in `SubstrateLib/AuditGate.swift`
  — reachable through `import SubstrateLib` (which LocusKit re-exports
  transitively via its own import).
- `AdjectiveSensitivity`, `AdjectiveExportability`, `Trust`, `State` are
  all `public` in `LocusKit/Adjectives.swift`.
- `ForbiddenCombinations` constants are asserted via the public enum values
  and the cross-layer comment citations, not by inspecting private internals.

The alternative — a SubstrateLib test target that imports LocusKit — would
violate the layering invariant (lower layer importing upper) even in a test
target. Not permitted.

The existing `AdjectiveBitmapConformanceTests.swift` covers §2.8 single-axis
raw-value correctness per cookbook spec rows. `GuardianPairParityTests.swift`
covers §3 cross-layer correspondence: do the lower-tier duplicate integer
literals agree with the upper-tier canonical enum rawValues? Complementary,
not overlapping.

---

## Summary

- MUST_UPDATE (sentinel comment edits): 4 files
- New additive files: guardian package, README, BRR, test file
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

Mission proceeds.
