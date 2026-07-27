# Completion Report — fix-glk-migration

**Status: COMPLETE**

**Stream:** stream/fix-glk-migration
**Worktree:** /Users/bob/devlop/mootx01-ce-fix-glk
**Branch base:** stream/fix-fanout @ 76f23866

---

## What Was Done

**Part 1: Investigation** — classified the 12 failures as Type (a): test infrastructure fix.

All 12 failing tests called `kit.wireGLKSubstores` on freshly-created estates without
first calling `GLKMigrationCatalog.prepare`. The gate in `wireSubstores` calls
`EstateFormatStore.requireCurrent()`, which throws `migrationRequired(current: .current)`
when no format stamp exists.

The production path (`ServeCommand`) correctly calls `GLKMigrationCatalog.prepare` between
`kit.open` and `kit.wireGLKSubstores`. The migration catalog's fast path for fresh estates
(no `chunks` table) stamps `.current` immediately and returns — no migration data written,
O(1) cost.

Evidence this is NOT (b) — missing migration:
- `runSharedContentMigration` has an explicit fresh-estate fast path at lines 416–424 in
  `SharedContentMigration.swift`: detects no legacy layout → stamps `.current` → returns.
- The full 8-step migration (canonicalValidated → complete) only runs when `layout != nil`
  (legacy chunks table present).
- The gate is CORRECT — it prevents OLD estates without a format stamp from opening
  semantic substores without migration. It's not spurious (type c).

**Part 2: Fix** — commit 3e639c66.

- `AriaMcpKit/Package.swift`: Added `GeniusLocusKitMigrations` to `AriaMCPTests` deps.
- 6 test files: Added `import GeniusLocusKitMigrations` and one
  `_ = try await GLKMigrationCatalog.prepare(kit: kit, handle: handle)` call between
  `kit.open(...)` and `kit.wireGLKSubstores(...)` in each setup helper.
- Also fixed the env-gated PostgreSQL helper in `InMemorySemanticRecallTests` (wasn't
  in the 12 failures since env var wasn't set, but would fail the same way).

Files modified:
1. `packages/kits/AriaMcpKit/Package.swift`
2. `Tests/AriaMCPTests/InMemorySemanticRecallTests.swift`
3. `Tests/AriaMCPTests/RecallProvenanceSurfacingTests.swift`
4. `Tests/AriaMCPTests/DreamRunnerTests.swift`
5. `Tests/AriaMCPTests/WithdrawRecallDropDispatchTests.swift`
6. `Tests/AriaMCPTests/DurableSemanticRecallTests.swift`
7. `Tests/AriaMCPTests/ContradictionHunterEndToEndTests.swift`

---

## Test Verification Log

### Baseline (mission start)
- Command: `cd packages/kits/AriaMcpKit && swift test`
- Exit code: 1
- Pass count: 542 (of 554), 12 failing
- All 12 failing with: "estate migration required before GLK 1.1 can open semantic substores"

### Final (post-commit)
- Command: `cd packages/kits/AriaMcpKit && swift test`
- Exit code: 0
- Pass count: 554 (all)
- Fail count: 0
- Delta: +12 (all 12 previously-failing tests now pass)

Verbatim tail output:
```
Test vault_job_unknown_id_returns_error() passed after 0.008 seconds.
Test import_job_surfaces_skip_counts() passed after 0.329 seconds.
Test vaultJobCapIsEnforcedAtomically() passed after 0.001 seconds.
Test vaultJobCapFreesSlotOnCompletion() passed after 0.001 seconds.
Test hashAllNotes_skips_directory_named_md() passed after 0.002 seconds.
Test import_cap_not_exhausted_after_directory_md_vault() passed after 0.537 seconds.
Test import_cap_enforced_before_expensive_preflight() passed after 0.001 seconds.
Test import_throwing_preflight_releases_slot() passed after 0.012 seconds.
Test vaultJobCapNeverExceededUnderConcurrentLaunches() passed after 0.001 seconds.
Test writeManifest_refusesPreExistingSymlinkAtManifestPath() passed after 0.001 seconds.
Test writeManifest_refusesSymlinkedMootParentDir() passed after 0.001 seconds.
Suite "Vault tools" passed after 4.959 seconds.
Test run with 554 tests in 56 suites passed after 4.959 seconds.
```

---

## Discoveries

1. **GLK format stamp gap in old open path**: The `Estate.create + kit.open + wireGLKSubstores`
   pattern predates the GLK 1.1 format gate. Production code (`ServeCommand`) was updated
   to call `GLKMigrationCatalog.prepare` between `open` and `wire`. Tests replicate the
   production open sequence but were never updated to include the `prepare` call. The gap
   went unnoticed because the tests were written before the format gate was introduced.

2. **docs/blast_radius/ is gitignored in CE**: This directory is excluded from the CE repo
   since 2026-07-20 (leak remediation). BRR analysis is preserved here instead.

3. **Blast radius scope**: `docs/blast_radius/` is gitignored in this repo as of
   2026-07-20 (leak remediation). The BRR was written locally but cannot be committed.

4. **PostgreSQL test also needed the fix**: The `postgresCaptureThenSearchWhenEnvSet` test
   in `InMemorySemanticRecallTests` was also missing `prepare` but it's env-gated
   (`ARIA_MCP_POSTGRES_URL` absent → early return). Fixed proactively since the import
   was already in-scope.

---

## Commits

- 3e639c66 — fix(test): add GLKMigrationCatalog.prepare to 6 AriaMCPTests estate helpers

---

## Outstanding

Nothing outside mission scope. All 12 failures resolved. Test suite at 554/554.
