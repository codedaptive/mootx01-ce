# Blast Radius Report — VK-PERF-FIX-2026-07-13

**Baseline:** swift test pass count at mission start: 206
**Mission:** Fix two local-DoS vectors in VectorKit (recentItemIDs full-scan, findByKeyword payload over-fetch)
**Symbols being changed:**

## Symbol 1: VectorStore.schemaDeclaration (Swift) / VectorStore::schema_declaration() (Rust)
**Change class:** additive semantic — version bump 3→4, new composite index added, migration from v3→v4
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification (if INTENTIONALLY_LEFT) |
|---|---|---|---|---|
| packages/kits/VectorKit/Sources/VectorKit/VectorStore.swift | 330 | grep | MUST_UPDATE | Schema declaration itself — version bump + new index + migration |
| packages/kits/VectorKit/rust/src/vector_store.rs | 301 | grep | MUST_UPDATE | Rust schema declaration — version bump + new index + migration |
| packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/GeniusLocusKitSchema.swift | 35,59 | grep | MUST_UPDATE | Comment says "VectorKit v3" and "= 17" — stale after v4 bump |
| packages/kits/GeniusLocusKit/Tests/GeniusLocusKitTests/HydrateRoundTripTests.swift | 59,63,73,77,87,92 | grep | MUST_UPDATE | Hardcoded `== 17` assertions; also test names and doc comment say "17" — will fail when composite becomes 18 |
| packages/kits/GeniusLocusKit/rust/src/hydration.rs | 144,168,186,200 | grep | MUST_UPDATE | Hardcoded `assert_eq!(s.version, 17)` and three comments saying "= 17" |
| packages/kits/CorpusKit/Sources/CorpusKit/CorpusKit.swift | 746,953 | grep | INTENTIONALLY_LEFT | Calls `storage.migrate(to: VectorStore.schemaDeclaration)` — no change needed; migration framework auto-applies v3→v4 migration |
| packages/kits/VectorKit/Tests/VectorKitTests/*.swift | many | grep | INTENTIONALLY_LEFT | Call `storage.open(schema: VectorStore.schemaDeclaration)` — no change; fresh opens include v4 schema automatically |
| packages/kits/GeniusLocusKit/Sources/GeniusLocusKit/GeniusLocusKitSchema.swift | 67-70,115,119 | grep | INTENTIONALLY_LEFT | Live references (not hardcoded); auto-correct when schemaDeclaration.version bumps |
| packages/kits/GeniusLocusKit/rust/src/hydration.rs | 147-149 | grep | INTENTIONALLY_LEFT | Composite computed from live `.version` values — auto-corrects |

### Summary
- MUST_UPDATE: 5 files
- INTENTIONALLY_LEFT: numerous (all callers that use the schema via live reference or migration framework)
- RESCOPE_REQUIRED: 0

## Symbol 2: VectorStore.findByKeyword (Swift) / VectorStore::find_by_keyword (Rust)
**Change class:** internal implementation (adds column projection to rowStore.query; no signature change)
**Scope:** public (signature unchanged)

### Call sites

| File | Line | Source | Classification | Justification (if INTENTIONALLY_LEFT) |
|---|---|---|---|---|
| packages/kits/VectorKit/Sources/VectorKit/VectorStore.swift | 1365 | grep | MUST_UPDATE | rowStore.query call gains `columns: ["item_id"]` projection |
| packages/kits/VectorKit/rust/src/vector_store.rs | 1465 | grep | MUST_UPDATE | Use query_projected to project item_id only |

### Summary
- MUST_UPDATE: 2 (both in VectorStore implementation files)
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

## Symbol 3: VectorStore.recentItemIDs (Swift) / VectorStore::recent_item_ids (Rust)
**Change class:** internal implementation (adds column projection; no signature change)
**Scope:** public (signature unchanged)

### Call sites

| File | Line | Source | Classification | Justification (if INTENTIONALLY_LEFT) |
|---|---|---|---|---|
| packages/kits/VectorKit/Sources/VectorKit/VectorStore.swift | 1420 | grep | MUST_UPDATE | rowStore.query call gains `columns: ["item_id", "filed_at"]` projection |
| packages/kits/VectorKit/rust/src/vector_store.rs | 1585 | grep | MUST_UPDATE | Use query_projected to project item_id + filed_at only |

### Summary
- MUST_UPDATE: 2 (both in VectorStore implementation files)
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0
