# COMPLETION: ARIA_MCP_RUST_001

**Status:** COMPLETE

**Stream:** worktree-agent-a32e66f507da8a278
**Branch:** worktree-agent-a32e66f507da8a278

## What Was Done

- **Parts 1-6 (single commit):** feat(aria-mcp-rust) — 5ef0665
  - Part 1: JSON-RPC 2.0 wire types + stdio framing (newline-delimited JSON,
    mirrors Swift wire contract, tests mirror JSONRPCTests.swift +
    StdioFramingTests.swift)
  - Part 2: Estate registry (in-memory default estate, UUID routing, invalidParams
    on malformed/unknown estateID) + method dispatcher
  - Part 3: moot_list_recipes + 14 hard-bound reasoning-lens tools with
    catalog-driven descriptions (byte-identical to Swift catalog strings)
  - Part 4: moot_grounded_synthesis + moot_run_migration_benchmark +
    moot_confirm_migration_promotion (confirm v1 gap: stateless server cannot
    retain CoreReport between calls — documented in README as behavioral fact)
  - Part 5: moot_capture_drawer + moot_drawer_recall + moot_capture_tunnel
    (v1 lexicon minimum; wire-identical arg names to Swift server)
  - Part 6: README.md with v1 surface, v1 boundaries as behavioral facts,
    no-FFI rationale, architecture diagram

## Test Verification Log

### aria-mcp crate (apps/ARIA_MCP/rust)
```
cargo test (exit 0):
  running 3 tests   — src/lib unit tests
  test result: ok. 3 passed; 0 failed
  running 8 tests   — tests/jsonrpc_tests.rs
  test result: ok. 8 passed; 0 failed
  running 7 tests   — tests/stdio_framing_tests.rs
  test result: ok. 7 passed; 0 failed
  Total: 18 tests, 0 failed, exit 0
```

### cargo clippy -- -D warnings
```
exit 0 — clean (no warnings in aria-mcp source)
```

### cargo fmt
```
exit 0 — all files formatted
```

### CognitionKit/rust (kit correctness baseline)
```
cargo test (exit 0):
  running 62 tests
  test result: ok. 62 passed; 0 failed — kit untouched
```

### NeuronKit/rust (kit correctness baseline)
```
cargo test (exit 0):
  running 157 tests
  test result: ok. 157 passed; 0 failed — kit untouched
```

## v1 Surface Shipped

| Tool | Status |
|---|---|
| moot_list_recipes | shipped |
| moot_keystones | shipped |
| moot_constellation | shipped |
| moot_free_association | shipped |
| moot_theme_weather | shipped |
| moot_latent_themes | shipped |
| moot_bias | shipped |
| moot_drift | shipped |
| moot_contradiction | shipped |
| moot_trust_grounded_synthesis | shipped |
| moot_partial_cue_recall | shipped |
| moot_anticipate | shipped |
| moot_tunnel_successor | shipped |
| moot_mind_overlap | shipped |
| moot_estate_divergence | shipped |
| moot_grounded_synthesis | shipped |
| moot_run_migration_benchmark | shipped |
| moot_confirm_migration_promotion | advertised; v1 gap (see below) |
| moot_capture_drawer | shipped |
| moot_drawer_recall | shipped |
| moot_capture_tunnel | shipped |

## Documented v1 Boundaries

1. **In-memory estates only.** Persistent storage backends (SQLite, CloudKit)
   are v2. The estate_registry module uses InMemoryStorage + InMemoryDrawerStore;
   the README states this plainly.

2. **moot_confirm_migration_promotion gap.** The confirm step requires the
   CoreReport from moot_run_migration_benchmark. The server is stateless across
   tool calls; without session state (v2) the report cannot be retained between
   run and confirm calls. The tool is advertised (agents can discover it) and
   returns a clear informational error_result explaining the v1 boundary. The
   kit's `confirm_migration_promotion` function is reachable — the gap is the
   MCP server's stateless boundary, not a kit limitation. README documents this
   plainly as a behavioral fact.

3. **Full lexicon projection is v2.** v1 ships three tools (capture_drawer,
   drawer_recall, capture_tunnel). The full Swift surface (mutate, withdraw,
   expunge, reanchor, learn, cross_estate_recall, federation) is listed in the
   README as the v2 boundary.

## Blast Radius

NET-NEW (Tier 3). No existing source modified. git diff shows only new files
under apps/ARIA_MCP/rust/. Both kit test suites unchanged (62 + 157 = 219
passing tests, all untouched).

## Discoveries

- `ContentKind::StructuredJson` (Rust) vs `StructuredJSON` (Swift convention):
  the Rust enum uses the standard Rust PascalCase for abbreviations. Tool schemas
  still accept the string `"structuredJSON"` (wire-identical to Swift) and map
  it to the correct variant.
- `CaptureChannel::from_raw()` returns `CaptureChannel` directly (not `Option`) —
  falls back to `Typed` for unknown values. This is correct; the Swift server's
  `channelName` in LensTools has the same semantics.
- `TunnelCaptureFrame::new` takes 6 args (no `now` — the timestamp is passed to
  `capture_tunnel`). The Swift server's `TunnelCaptureFrame` mirrors this shape.
- `EstateHandle` implements `Copy` — no `.clone()` needed.
- `AdjectiveSensitivity::raw_value()` not `.as_raw()`. Minor naming delta between
  the two versions' internal APIs; the wire surface is unaffected.
- `NeuronKitCapability` has a `RunTournament` variant not yet present in the Swift
  catalog. The match arm is covered with `"runTournament"` as its raw value string.

## Outstanding

None. The mission is complete within the contracted scope.
