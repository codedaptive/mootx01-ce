---
title: FAB5-I1 Completion Report
version: v0.1
status: COMPLETE
date: 2026-07-24
stream: i1
---

# Completion Report: FAB5-I1
# WorkPacketKit: Schema + Persistence

Status: COMPLETE

## What Was Done

FAB5-I1 delivers WorkPacketKit — a new Swift-only SPM package that persists
Work Packets as typed projections over LocusKit drawers (kind `structuredJSON`,
room `work-packets`) plus typed tunnels (`derivesFrom` / `respondsTo`). Zero new
persistence machinery: packets ride the existing estate substrate and are
immediately searchable, sync-eligible, and federation-compatible.

### Part 1 — Schema v1 (commit 0a203571)

- `Package.swift`: swift-tools-version 6.2, platforms macOS 26 / iOS 26;
  depends only on LocusKit (path: `../LocusKit`); one library product, one
  test target.
- `WorkPacketKit.swift`: module umbrella (no executable code).
- `WorkPacketKitError.swift`: `public enum WorkPacketKitError: Error, Sendable,
  Equatable` with `.encodingFailure(String)` / `.decodingFailure(String)`.
- `JSONValue.swift`: recursive type-erased enum (null, bool, int, double, string,
  array, object) for unknown-field preservation in Codable.
- `WorkPacket.swift`: schema v1. Sections: `objective`, `sources[]`,
  `claims[]` (confidence + supportingSourceIDs), `uncertainties[]`,
  `nextSteps[]`, `provenance` (model, agent, ISO8601 timestamps),
  `lineageLinks[]`, `schemaVersion`. Custom Codable: dual-container pattern
  captures unknown keys into `additionalFields: [String: JSONValue]` and
  re-emits them verbatim on encode. `knownCodingKeys` is a static literal
  Set — avoids the private-CodingKeys CaseIterable limitation.
- `LineageLinkKind`: `.derivesFrom` / `.respondsTo` as String-raw enums.

Kong design gate: **GREEN**.

### Part 2 — Store + lineage over drawers (commit 6f4f208b)

- `WorkPacketEstateClient.swift`: protocol with four verbs (`capture`,
  `captureTunnel`, `listDrawers`, `getDrawers`). `EstateAdapter` wraps a
  production `Estate` actor; `listDrawers` collects all `RecallStream` pages
  internally (RecallStream.init is LocusKit-internal; cross-package @testable
  doesn't work).
- `WorkPacketStore.swift` (`public actor`): encodes packets as JSON →
  `structuredJSON` drawers, room `"work-packets"`, `channel = .actuator`,
  `udcCode = "004"`. Lineage links filed as best-effort tunnels (`try?`);
  JSON lineageLinks are the source of truth. Optional `latticeAnchor` override
  parameter for domain-specific UDC classification (Kong binding condition #2).
- `LineageGraph.swift` (`public struct Sendable`): batched BFS — one
  `getDrawers(ids:)` call per hop level (Kong binding condition #4). Cycle-safe
  via visited set. `trace(from:maxDepth:)` returns antecedent IDs; `antecedents(of:maxDepth:)`
  returns decoded packets in traversal order.

### Part 3 — Fixtures + tests (commit ae026a1a)

- `MockEstateClient`: `final class` implementing `WorkPacketEstateClient`;
  in-memory drawers/tunnels with counters; `plant(_ packet:)` helper encodes
  packet to JSON and inserts as a drawer keyed by `packet.id`.
- `WorkPacketCodableTests` (9 tests): round-trip equality, schemaVersion=1,
  unknown-field preservation across version bump, confidence bounds (0.0/1.0),
  empty optional collections, LineageLinkKind raw string encoding, ISO8601 dates.
- `WorkPacketStoreTests` (10 tests): one drawer per store, tunnels per link,
  no tunnels for no links, fetch by ID, fetch nil for unknown, list all planted,
  list respects limit, list empty, JSON content validity, custom LatticeAnchor.
- `LineageGraphTests` (8 tests): trace no links, one hop, two hops BFS order,
  maxDepth limit, cycle detection, both link kinds, antecedents() decoded,
  antecedents empty for no links.

## Test Verification Log

### Baseline (mission start)
- Pass count at mission start: 0 (net-new package — no prior tests)
- Adjacent packages (WorkPacketKit's LocusKit dependency): untouched, lane green

### Final
- Command: `swift test` (in `packages/kits/WorkPacketKit`)
- Exit code: **0**
- Pass count: **26 tests in 3 suites**
- Tail output (verbatim):
  ```
  Test run with 26 tests in 3 suites passed after 0.002 seconds.
  ```

## Pre-flight (Smythe)

Verdict: **GREEN**

Key verifications:
- Terrain: `TunnelKind.derivesFrom` (raw 5) and `.respondsTo` (raw 8) confirmed
  present in LocusKit. `LatticeAnchor.udc(_:)` confirmed public factory.
  `CaptureChannel.actuator` (raw 5) confirmed — `.aiGenerated` does not exist.
- `RecallStream.init` confirmed internal to LocusKit (cross-package @testable
  does not work); protocol redesigned to return `[Drawer]` instead.
- All APIs verified on disk before implementation.
- No parallel-stream churn, no prerequisite gaps.

## Self-Review (Pre-commit Checklist)

### Step 0 — Blast Radius Scope
- All files in diff are under `packages/kits/WorkPacketKit/` — net-new only.
- Zero edits to LocusKit, GeniusLocusKit, AriaMcpKit, or ConvergenceKit.
- No TODO/FIXME referencing changed symbols.
- No bridge helpers, shim/wrapper types, or orphan `@available` deprecations.

### Standard Checks
- Schema invariants: no Bool stored properties on entities (N/A — WorkPacket is a Codable struct, not a LocusKit entity with bitmap schema). ✅
- Dates: ISO8601 throughout (both JSONEncoder/Decoder and the `WorkPacketProvenance` fields). ✅
- Secrets: no credentials. ✅
- Stale comments: none (all comments describe current code). ✅
- Localization: not applicable (no UI). ✅
- Prohibited patterns: none. ✅

## Post-flight (Adams)

Verdict: **BLOCKED → resolved** (all findings closed before signal)

### Findings

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | CRITICAL | `store()` returned `packet.id` but the estate assigns a fresh UUID as `drawer.id` at capture time. `fetch(drawerID: packet.id)` always returns nil in production. | Fixed: `let captured = try await client.capture(frame)` → `return captured.id`. |
| 2 | CRITICAL | `LineageGraph.trace()` used `link.targetPacketID` (populated from `WorkPacket.id`) as keys for `getDrawers(ids:)`. Production estate doesn't recognize `WorkPacket.id` as a drawer ID — lineage traversal silently fails on every non-trivial chain. | Fixed by #1: `storeTunnel` now passes `captured.id` as `sourcePacketID`; `targetPacketID` docstring updated to require estate-assigned drawer IDs. |
| 3 | WARNING | `fetchReturnsStoredPacket` test had a dead first block (`_ = client`); actual test exercised `mock2.plant()` which explicitly sets `drawer.id = packet.id`, hiding finding #1. | Fixed: test rewritten to `let estateID = try await store.store(...); store.fetch(drawerID: estateID)` — exercises the real round-trip. |
| 4 | INFO | `WorkPacketStore.init` used unqualified `defaultWingName`; fleet convention in non-LocusKit code is the qualified `LocusKit.defaultWingName`. | Fixed: changed to `LocusKit.defaultWingName`. |
| 5 | INFO | `MockEstateClient.listDrawers()` ignores filterChain (room/wing filters). | Documented as known coverage gap; does not block. |

### Adams Test Verification (re-run after fix commit 5819e7a7)
- exit 0, 26 tests in 3 suites — confirmed
- Blast radius: all files in diff under `packages/kits/WorkPacketKit/` — scope clean
- No MUST_NOT_TOUCH violations

## W2-INTERFACE Drawer

Filed to MOOTx01 estate:
- Drawer ID: `DFA470F5-4D6C-48E6-AF8C-56E535F1DD43`
- Wing: Agentic Memory
- Location: fab5-w2
- Content: `W2-INTERFACE FAB5-I1:` — schema v1, store API, lineage API,
  key decisions, gaps, downstream hooks.

## Commits

| SHA | Message |
|---|---|
| `0a203571` | feat(wpk): WorkPacket schema v1 |
| `6f4f208b` | feat(wpk): drawer-backed store and lineage graph |
| `ae026a1a` | test(wpk): fixtures + interface writeback |
| `5819e7a7` | fix(wpk): estate drawer ID ≠ packet.id — propagate captured.id |

## Success Criteria Checklist

- [x] WorkPacket schema v1 with typed sections
- [x] Unknown future fields preserved on decode/re-encode (additionalFields)
- [x] Store encodes to `structuredJSON` drawers in `"work-packets"` room
- [x] Lineage links indexed as best-effort tunnels; JSON is source of truth
- [x] `list` / `fetch` / `trace` / `antecedents` APIs implemented
- [x] Batched BFS traversal (one getDrawers call per hop level)
- [x] LatticeAnchor override parameter for domain-specific UDC
- [x] MockEstateClient stub — no direct SQL, no estate actor required in tests
- [x] 26/26 tests pass, exit 0
- [x] Kong design gate GREEN
- [x] W2-INTERFACE drawer filed to estate (fab5-w2, Agentic Memory)
- [x] Adams post-flight: 2 CRITICAL + 1 WARNING + 2 INFO found and resolved before signal
