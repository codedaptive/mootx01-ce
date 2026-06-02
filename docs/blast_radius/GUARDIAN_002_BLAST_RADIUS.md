# Blast Radius Report — GUARDIAN_002

**Baseline:** guardian self-tests: 12 passing (4 suites). LocusKit swift test: 529/48.
SubstrateLib swift test: 129/12. (Watched-file edits are comment-only; test floors
must remain unchanged.)
**Mission:** GUARDIAN_002 — singleton-raw extraction + member-of comparison for I-22/S-1 desk coverage
**Branch:** main (merge-base f4c09b7ae65d8742ce64bca0f647c2f709e4db90 == main HEAD)

---

## Nature of Changes

GUARDIAN_002 is mixed additive + comment-only:

1. **MODIFIED**: `tools/guardian/Sources/Guardian/Extractor.swift` — new singleton-raw
   extraction strategy (Strategy 5: named case rawValue; Strategy 3 extended with
   variable-name hint for named-comparison extraction). `extract()` gains an optional
   `description` parameter. No existing extraction paths changed.
2. **MODIFIED**: `tools/guardian/Sources/Guardian/Checker.swift` — threads description
   through to extractor. No diagnostic shape or comparison logic changed.
3. **MODIFIED**: `tools/guardian/README.md` — sentinel grammar extended; Non-goals entry
   updated to reflect the gap is now closed; registered-pairs table extended to 9 pairs.
4. **MODIFIED**: `tools/guardian/Tests/GuardianTests/GuardianTests.swift` — new tests for
   singleton-raw mode (clean singleton pair, desynced singleton, --strict path, --list
   count). Self-test count grows from 12 to 16 tests.
5. **NEW**: `tools/guardian/Tests/GuardianTests/fixtures/singleton-clean/` — two fixture
   files for a clean singleton-raw pair (SingletonSiteA.swift, SingletonSiteB.swift).
6. **NEW**: `tools/guardian/Tests/GuardianTests/fixtures/singleton-desynced/` — two fixture
   files for a desynced singleton-raw pair (SingletonDesyncedSiteA.swift, SingletonDesyncedSiteB.swift).
7. **COMMENT-ONLY edits** to two existing watched source files:
   - `packages/libs/SubstrateLib/Sources/SubstrateLib/RowStateAutomaton.swift` — three
     new `@guardian-pair:` sentinel lines added to the existing Guardian comment block
     (i22-sensitivity-raw, i22-exportability-raw, s1-trust-threshold). Zero behavior change.
   - `packages/kits/LocusKit/Sources/LocusKit/Adjectives.swift` — three new
     `@guardian-pair:` sentinel lines on the canonical side of the same three pairs.
     Zero behavior change.

---

## Symbol Changes

### `SentinelExtractor.extract(filePath:sentinelLine:)` (Extractor.swift)

**Change class:** signature extension (additive default parameter `description: String = ""`)
**Scope:** public

No callers outside the Guardian package. Checker.swift is the only caller; it is
updated to pass description. The default `""` preserves backward compatibility for
any test that calls `extract` directly without description.

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `tools/guardian/Sources/Guardian/Checker.swift` | ~70-71 | grep | MUST_UPDATE | Only caller; needs to pass siteA/siteB description |
| `tools/guardian/Tests/GuardianTests/GuardianTests.swift` | ~135,152 | grep | INTENTIONALLY_LEFT | Tests call `extract(filePath:sentinelLine:)` directly on set-equality fixtures; default `description:""` preserves behavior |

### Comment-only edits to watched files

No Swift symbol changes. These are pure sentinel comment additions.

| File | Classification | Justification |
|---|---|---|
| `RowStateAutomaton.swift` | MUST_UPDATE | Three new singleton sentinel lines in existing Guardian comment block |
| `Adjectives.swift` | MUST_UPDATE | Three new singleton sentinel lines (canonical side) |
| `tools/guardian/README.md` | MUST_UPDATE | Non-goals stale after gap is closed; grammar and pair table must update |

---

## Summary

- MUST_UPDATE (code): 1 file (Checker.swift)
- MUST_UPDATE (comment/docs): 3 files (RowStateAutomaton.swift, Adjectives.swift, README.md)
- MUST_UPDATE (modified): 2 files (Extractor.swift, GuardianTests.swift)
- NEW additive: 2 fixture directories (4 files)
- INTENTIONALLY_LEFT: 1 (GuardianTests direct extract() calls — default param preserves)
- RESCOPE_REQUIRED: 0

Mission proceeds.
