---
version: v0.1
---

# COMPLETION: FIND4

**Status:** COMPLETE

**Branch:** develop/1.0.x  
**BRR commit:** f9eb4fd2  
**Implementation commit:** 516a5215

---

## What Was Done

**Part 1 — Blast Radius Report**
Committed BRR at `f9eb4fd2`. Documents 8 MUST_UPDATE sites, 5 INTENTIONALLY_LEFT,
0 RESCOPE_REQUIRED. Decision: option (a) — add `lifecycle == .active` filter inside
`allActiveTunnels` because every caller semantically wants only confirmed-active tunnels.

**Part 2 — Swift implementation** (committed in `516a5215`)
- `DrawerStore.allActiveTunnels`: added `&& $0.lifecycle == .active`; docstring updated
- `Estate.allActiveTunnels`: docstring aligned; added public `Estate.addTunnel(_:)`
  passthrough (needed for cross-module test seeding — `store` is internal)
- `ToolDispatch.runConnectionSearch` / `runConnectionMap`: added `&& $0.lifecycle == .active`
  with "Lifecycle gate (FIND4)" comments
- `DreamingReads.allActiveTunnels(in:)`: docstring updated; OMEGA semantics note added

**Part 3 — Rust implementation** (committed in `516a5215`)
- `drawer_store.rs all_active_tunnels`: added `&& t.lifecycle() == TunnelLifecycle::Active`
- `interface_tools.rs run_connection_search` / `run_connection_map`: same gate added

**Part 4 — Tests** (committed in `516a5215`)
- `TunnelRetirementTests.swift`: +4 `allActiveTunnels` lifecycle exclusion tests
  (proposed, withdrawn, superseded excluded; mixed active+proposed returns only active)
- `TunnelLifecycleDisclosureTests.swift` (new file): +7 MCP disclosure boundary tests
  for `moot_connection_search` / `moot_connection_map`
- `drawer_store_inmemory.rs`: +4 `all_active_tunnels` lifecycle exclusion tests
- `dispatch_tests.rs`: +6 connection search/map lifecycle gate tests

**DO NOT TOUCH — LensTools.swift contradiction path intentionally preserved.**
Lines 497 and 532 gate `lifecycle == .active || lifecycle == .proposed` for contradiction
hunting. This is correct: proposed tunnels are valid contradiction candidates. Not changed.

---

## Test Verification Log

- `swift build` (AriaMcpKit): exit 0
- `swift test` (AriaMcpKit): exit 0, **502 tests** (+7 from baseline 495), all passing
- `swift test` (LocusKit): exit 0, **810 tests** (stable, 4 lifecycle tests from prior run included), all passing
- Rust tests (LocusKit): 875 → 879 (+4 lifecycle tests)
- Rust tests (AriaMcpKit): 413 → 419 (+6 lifecycle tests)

---

## Discoveries

- `estate.store` is `internal` on `LocusKit.Estate`, blocking cross-module test seeding.
  Adding `public Estate.addTunnel(_:)` is the minimal fix — `DrawerStore.addTunnel` was
  already `public`; just needed the Estate-level passthrough. The FIND4 comment on the
  docstring makes the intent clear (primarily a test-seeding API).
- Rust `run_connection_search` does a drawer lookup by ID first (`coord.recall`), so
  Rust dispatch tests must use real drawers (from `file_one_memory`) rather than synthetic
  drawer IDs — unlike Swift which can use arbitrary strings for source/target drawer IDs
  in tunnel inserts. The dispatch_tests.rs helper `insert_lifecycle_tunnel_for_drawer`
  handles this by resolving the actual wing from a real filed memory.

## Outstanding

None. RESCOPE_REQUIRED: 0.
