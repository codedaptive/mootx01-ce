# Blast Radius Report — MIGRATION_10X

**Baseline:** swift test pass count at mission start:
- GeniusLocusKit (MigrationFloor1_0 trait): 12 tests
- VaultKit: 192 tests

**Mission:** 1.0.x → 1.1.x Distillation Storage Migration (SPEC_DISTILLATION_STORAGE Appendix A)

**Stream:** stream/migration-10x

**Symbols being changed:**

---

## Symbol 1: `DrawerMapping.noteIR(from:wing:room:references:kgFacts:)` (internal static method)

**Change class:** semantic — removes `distilled_from_sources` frontmatter key from export output; removes `provenanceTunnels`/`contentTunnels` split; simplifies tunnel handling to content-reference tunnels only

**Scope:** internal static (called from `export()` batch path and tests)

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| VaultKit/Sources/VaultKit/DrawerMapping.swift | 282 | codegraph | MUST_UPDATE | The call site in `export()` builds `outgoing` tunnels and passes them to this function; the `_distilled_from` filter in the caller also needs cleanup |
| VaultKit/Tests/VaultKitTests/VaultBridgeTests.swift | 1662–1663 | grep | MUST_UPDATE | Direct assertion that `distilled_from_sources` is present in export output — must flip to verify absence |
| VaultKit/Tests/VaultKitTests/PrivacyTierAndReceiptTests.swift | 487,556,617 | grep | MUST_UPDATE | Three CAND-EXP-PROV tests verify `distilled_from_sources` privacy behavior; retired since the key is removed |

### Summary

- MUST_UPDATE: 3 sites
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## Symbol 2: `DrawerMapping.export(estate:handle:to:scope:now:)` (public batch export)

**Change class:** semantic — removes `includedWingRooms` computation and `_distilled_from`-label filter from the tunnel outgoing selection; simplifies to `kind == .references` only

**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| VaultKit/Sources/VaultKit/DrawerMapping.swift | 261–279 | grep | MUST_UPDATE | `includedWingRooms` and provenance-tunnel filter are dead code once `_distilled_from` tunnels are retired |
| VaultKit/Tests/VaultKitTests/PrivacyTierAndReceiptTests.swift | 488,556,617 | grep | MUST_UPDATE | Same three CAND-EXP-PROV tests call `bridge.export()` and inspect the tunnel-privacy output |

### Summary

- MUST_UPDATE: 2 files
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## Symbol 3: `GLKMigrationCatalog.prepare(kit:handle:now:)` (public static)

**Change class:** semantic — adds call to `runDistillationStorageMigration` before `runSharedContentMigration`

**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| GeniusLocusKit/Sources/GeniusLocusKitMigrations/MigrationCatalog.swift | 81 | grep | MUST_UPDATE | The `#if GLK_MIGRATION_V1_0_TO_V1_1` block must call the new migration before SharedContent |
| GeniusLocusKit/Tests/GeniusLocusKitTests/* | various | codegraph | INTENTIONALLY_LEFT | Existing GLK tests do not call `prepare()` directly; they call kit.open() which does not invoke the migration catalog |

### Summary

- MUST_UPDATE: 1 site
- INTENTIONALLY_LEFT: N existing GLK tests
- RESCOPE_REQUIRED: 0

---

## New files (additive — no blast radius on existing symbols)

| File | Purpose |
|---|---|
| GeniusLocusKit/Sources/GLKMigrationV1_0ToV1_1/DistillationStorageMigration.swift | A.1 migration steps (b)–(e) + vault protocol API |
| GeniusLocusKit/Tests/GLKMigrationV1_0ToV1_1Tests/DistillationStorageMigrationTests.swift | A.2 verification fixture and acceptance criterion 13.8 |
| GeniusLocusKit/rust-migrations/src/distillation_storage_migration.rs | Rust twin of DistillationStorageMigration |

---

## Non-code references

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| VaultKit/Sources/VaultKit/DrawerMapping.swift | 257–259 | grep | MUST_UPDATE | Comment references `distilled_from_sources` round-trip behavior — stale post-change |
| VaultKit/Sources/VaultKit/DrawerMapping.swift | 1038 | grep | MUST_UPDATE | Structural keys comment lists `distilled_from_sources` — stale post-change |
| GeniusLocusKit/Sources/GeniusLocusKitMigrations/MigrationCatalog.swift | 45–50 | grep | MUST_UPDATE | `compiledFloor` comment may need update to reflect new migration |
