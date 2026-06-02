# Blast Radius Report — SUBSTRATE_TYPED_LEVEL_CONVERGE_001

- **Stream:** tl
- **Branch:** stream/tl-typed-level-converge
- **Worktree:** /Users/bob/devlop/mootx01-ce-tl-typed-level-converge
- **Mission:** docs/missions/inflight/MISSION_SUBSTRATE_TYPED_LEVEL_CONVERGE_001.md
- **Tier:** 1 (≤3 file edits; comment-only)
- **Date:** 2026-06-01

## Nature of change

Comment-only convergence mission. No symbol is renamed, removed, or has
its semantics changed — there is **no call-site blast radius to chase**.
The diff is one source-of-truth header paragraph in
`LocusKit/Adjectives.swift`, one stale-comment correction in the same
file, and one-line citation comments at the class-C raw extraction
sites. No behavior, storage, bit-layout, or audit-wire change.

## Baseline (Step 0)

| Package | Command | Exit | Pass count |
|---|---|---|---|
| LocusKit | `swift test` | 0 | 516 tests in 47 suites |
| SubstrateLib | `swift test` | 0 | 129 tests in 12 suites |
| PersistenceKit | `swift test` | 0 | 83 tests in 19 suites (final test-target summary) |

## Part 0 audit results (re-run against this worktree, 2026-06-01)

**Grep 1 — duplicate level enums:** only the three canonical
definitions:
- `packages/kits/LocusKit/Sources/LocusKit/Adjectives.swift:108` `Trust` (class A, already `Comparable`)
- `packages/kits/LocusKit/Sources/LocusKit/Adjectives.swift:134` `AdjectiveSensitivity` (class A)
- `packages/kits/LocusKit/Sources/LocusKit/Adjectives.swift:150` `AdjectiveExportability` (class A)

**Class B (importable duplicate → replace with import): NONE.**
**Class D (non-importable duplicate → record/recommend): NONE.**
Part 3 is therefore EMPTY, as the mission expected.

**Grep 2 — shadow enums:** one additional hit,
`packages/kits/LocusKit/Sources/LocusKit/Provenance.swift:178`
`enum Sensitivity` (raws 0/16/32/48). **Classified NOT a duplicate**:
it is a distinct axis — sensitivity-at-capture on the *provenance*
bitmap (bits 30–35, accessor at Provenance.swift:242 `shift: 30,
width: 6`) — that deliberately mirrors `AdjectiveSensitivity` raw
values and already cross-cites it in its doc comment. Verified by
Smythe pre-flight (Claim 5).

**Grep 3 — raw extractions (`>> 6/12/18 & 0x3F`), source files only**
(test files excluded per mission):
- `packages/libs/SubstrateLib/Sources/SubstrateLib/RowStateAutomaton.swift:252,253,263,297` — class C (SubstrateLib sits below LocusKit; cannot import it)
- `packages/kits/PersistenceKit/Sources/PersistenceKit/GeneratedColumn.swift:7` — class C (LocusKit/Package.swift:49 declares PersistenceKit a dependency of LocusKit, so PersistenceKit cannot import LocusKit)

## MUST_UPDATE

| File | Change | Class |
|---|---|---|
| `packages/kits/LocusKit/Sources/LocusKit/Adjectives.swift` | Source-of-truth header paragraph; fix stale comment at lines 126–127 (provenance `Sensitivity` described as "2-bit contiguous at bits 16–17" — actual: 6-bit scale-gapped at bits 30–35) | Part 1 |
| `packages/libs/SubstrateLib/Sources/SubstrateLib/RowStateAutomaton.swift` | One-line citation comments at the 4 raw extraction sites in `ForbiddenCombinations.check` | Part 2, class C |
| `packages/kits/PersistenceKit/Sources/PersistenceKit/GeneratedColumn.swift` | One-line citation in the bitmap-layout doc comment (line ~7) | Part 2, class C |

## INTENTIONALLY_LEFT

- `ForbiddenCombinationValidator.swift:44–45` — stale comment ("numeric
  encoding at bits 4–11" should read "bits 6–17" post-F11). File is on
  the mission's MUST NOT modify list; recorded in the completion
  report's Outstanding section for a follow-up. Its class-C-style
  citation ("the numeric encoding is the contract; the enum names are
  documentation") is already present and is the model for Part 2.
- All raw-shift assertions in test files (`SealedBitTests.swift`,
  `SimHashTests.swift`, `AuditGateTests.swift`,
  `GeneratedExpressionTests.swift`) — excluded by the mission.
- The raw integer encodings themselves — they are the cross-layer
  contract; comments only, no value changes.
- `Verbs.swift` — owned by `fc` (landed at e002112); its raw
  extractions were deleted by `fc` and are not citation targets.

## RESCOPE_REQUIRED

None. Part 0 matches the mission's pre-run exactly; the comment-only
scope holds. Edit count: 3 files (Tier 1 cap ≤3 — at cap, within cap).
