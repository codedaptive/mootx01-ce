COMPLETION: lme-07

Status: COMPLETE

## What Was Done

**Part 1: New cache primitives**
- `EstateCache.swift` (Swift): `EstateCacheMode`, `mootBinaryFingerprint`, `estateCacheEntryURL`, `defaultCacheDir`, `saveEstateCacheEntry`, `restoreEstateCacheEntry`
- `estate_cache.rs` (Rust twin): same functions; `copy_dir_all` helper for recursive dir copy (Rust std has no equivalent)
- Both include module-level docs explaining key components, deletion discipline, and cross-twin sharing

**Part 2: Runner integration — all three benchmarks, both legs**
- Swift: `LMEBRunner`, `LoCoMoRunner`, `LongMemEvalRunner` — `EstateCacheMode` + `cacheDir` in RunConfig; cache restore at ingest start; snapshot after drain
- Rust: `lmeb_runner`, `locomo_runner`, `longmemeval_runner` — matching changes
- `main.swift` + `main.rs` — `--estate-cache` and `--cache-dir` CLI flags wired to all three subcommands
- Cache key includes binary fingerprint (mtime+size) for automatic rebuild invalidation

**Part 3: Report JSON additive keys (BENCHMARKER_OPTIMIZER_CONTRACT)**
- Swift scorers: `LMEReport`, `LoCoMoReport`, `LmebReport` + per-question/query structs
- Rust scorers: matching structs + `build_*_report` signatures
- Additive keys: `estate_cache` (mode string), `cache_hits`, `cache_misses` (aggregate), `cache_hit: bool?` per-unit
- All new fields are optional or have skip_serializing_if = nil to preserve backward compatibility

**Part 4: Tests**
- `EstateCacheTests.swift` (13 tests): key construction, fingerprint format, defaultCacheDir, save+restore round-trip, isolation guarantee, miss, partial hit
- `estate_cache.rs` (10 tests): same coverage on Rust twin
- Existing test file fixes: `LoCoMoScorerTests`, `LongMemEvalScorerTests`, `LongMemEvalRunnerTests` — updated for new required struct fields

## Test Verification Log

### Baseline (from mission start)
- swift test: exit 0, 251 tests passing
- cargo test: exit 0, 181 tests passing

### Final (post-commit a60ca884)

**swift test:**
```
Test run with 264 tests in 54 suites passed after 6.995 seconds.
```
- Exit code: 0
- Pass count: 264 (baseline 251, +13 new estate cache tests)
- Fail count: 0

**cargo test:**
```
test result: ok. 146 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.02s
test result: ok. 44 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
test result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
```
- Exit code: 0
- Total: 191 tests (baseline 181, +10 new estate cache tests)
- Fail count: 0

## Self-Review

### Step 0 — Blast Radius Scope Check
N/A for new files. For modified files: all MUST_UPDATE sites enumerated in
`docs/blast_radius/lme07_BLAST_RADIUS.md` (gitignored) — all 9 sites updated in this commit.

### Standard Checks
- Files changed: 21 (3 new, 18 modified)
- Scope: all within apps/mcp-benchmarker/** ✓
- No secrets ✓
- No UI code ✓
- Prohibited Blast Radius patterns: none ✓
- BENCHMARKER_OPTIMIZER_CONTRACT compliance: all new report fields additive, optional, or with skip_serializing_if ✓

## Discoveries

- Rust `std::fs` has no recursive directory copy — required `copy_dir_all` helper (walks the tree with `read_dir` + `copy`). All file metadata except permissions is preserved, which is sufficient for mootx01 estate snapshots.
- Rust doctests parse code fences in doc comments. Unicode arrows (← →) in pseudocode blocks cause parse failures. Fixed by changing `\`\`\`` to `\`\`\`text` in those blocks.
- `LoCoMoManifestEntry` already had `serde::Serialize/Deserialize` from prior session; `LmebManifestEntry` is a new struct added to `lmeb_runner.rs` for cache serialization since LMEB uses an inline `HashMap<String,String>` that needs a serializable form.

## Outstanding

None.
