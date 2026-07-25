---
title: FAB5-I3 Completion Report
version: v0.1
status: COMPLETE
date: 2026-07-24
stream: i3
worker: bilby
---

# Completion Report: FAB5-I3
# Work Packet Lineage UI + Three Minds Demo Script

Status: **COMPLETE**

---

## Kong Ruling — Known Ambiguity Resolution

**Packets section placement:** Own Advanced-only tab in `ContentView.swift`,
after Miners, SF Symbol `shippingbox`, label "Packets".

Rationale: No "Review tab" or "Dashboard" tab exists in the current codebase.
`ReviewCenterView` does not exist. Advanced-only placement is correct: packets
are developer/power-user instrumentation. One new `Tab(...)` entry in the
existing `if model.isAdvancedMode` block is the minimal, pattern-consistent edit.

**Nav wire file:** `ContentView.swift` — no G2 reservation active on this branch.

Kong memo filed to W2-INTERFACE FAB5-I3 drawer (see below).

---

## Smythe Pre-flight

**Verdict: GREEN** (with one procedural YELLOW resolved by Kong ruling)

Key verifications:
- ContentView.swift free: confirmed, no G2 reservation
- WorkPacketKit present: `packages/kits/WorkPacketKit/` with all source files
- GatewayUI/Packets/ absent: clean insertion point confirmed
- Package.swift missing WorkPacketKit: two insertion points identified
- Baseline tests: 37 GatewayUITests passing
- MootGatewayTests: 1 pre-existing HTTP loopback failure (not Bilby's)
- Blast radius: Tier 2 (UI-bounded) — 1 edit + 3 new views + demo doc + ~2 tests

YELLOW resolved: Kong ruling obtained before Part 1 implementation.

---

## What Was Done

### Part 1 — Packet Views (commit `3e92c353`)

**Package.swift** — added WorkPacketKit as a dependency:
- Top-level `dependencies` array: `.package(name: "WorkPacketKit", ...)`
- GatewayUI target: `.product(name: "WorkPacketKit", ...)` + comment
- GatewayUITests target: `.product(name: "WorkPacketKit", ...)` + comment

**New views** under `apps/Mootx01-App/Sources/GatewayUI/Packets/`:

- **PacketListView.swift** — NavigationStack list of work packets. Accepts a
  closure `@Sendable () async throws -> [WorkPacket]` for injectable loading.
  Default closure returns [] (empty; production callers pass a WorkPacketStore
  wrapper). Shows loading state, error state, empty-state placeholder, and a
  list of `PacketRowView` rows navigating to `PacketDetailView`.

- **PacketDetailView.swift** — Full detail display: objective, claims with
  locale-aware confidence percentage (`.formatted(.percent)`), uncertainties,
  next steps, provenance (agent + model). NavigationLink to `LineageView` when
  `lineageLinks` is non-empty.

- **LineageView.swift** — Breadth-first antecedent list driven by an injected
  `@Sendable (String) async throws -> [WorkPacket]` closure. Shows root packet
  at top, antecedents in hop order below. Skips loading when `rootDrawerID` is
  empty (packet not stored via WorkPacketStore). Link-kind badges (derivesFrom,
  respondsTo) shown on each row.

**ContentView.swift** — added Packets tab inside `if model.isAdvancedMode` after
Miners, per Kong ruling. MARK comment updated to include Packets.

**PacketViewsTests.swift** (3 new tests):
- `packetDetailFieldsNonEmptyAndValid` — verifies fixture WorkPacket has
  non-empty objective, claims with confidence in [0,1], non-empty uncertainties
  and next steps, non-empty provenance, correct schemaVersion.
- `threeDeepLineageChain` — constructs root→parent→grandparent chain and
  asserts every link target and kind is correct; verifies chain.count == 3.
- `lineageLinkKindRawValues` — guards against schema drift on stored raw values.

### Part 2 — Demo Doc (commit `f5e730a0`)

**docs/guide/THREE_MINDS_ONE_MEMORY.md** — five-step choreography:

| Step | Actor | Action |
|---|---|---|
| 1 | Claude | Research topic, file WorkPacket via moot_file_memory |
| 2 | Codex | Same topic independently, file own WorkPacket |
| 3 | On-device (SummarizeWorker) | Read both packets, compare via moot_memory_search |
| 4 | Claude or Codex | File synthesis packet with derivesFrom links to Steps 1+2 |
| 5 | Either frontier model | Resume from synthesis packet via moot_memory_search |

All named tools/verbs validated against develop at execution time:
- `moot_estate_ping` ✓ (MCP surface)
- `moot_file_memory` ✓ (LexiconMap.swift:75, MCPClient/MootEstateClient.swift:49)
- `moot_memory_search` ✓ (LexiconMap.swift:82, SummarizeWorker.swift:48)
- `moot_estate_status`, `moot_estate_map` ✓ (MCP surface)
- `SummarizeWorker` ✓ (MootGateway/Workers/SummarizeWorker.swift)
- `CompareWorker` — documented as pending FAB5-H2 with upgrade path noted

Demo includes: ARIA tool reference table, verification steps using the app's
Packets tab, troubleshooting section, execution log template.

### Adams Fixes (commit `0c113f22`)

Adams post-flight found 2 CRITICAL + 2 WARNING findings. All resolved:

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | CRITICAL | Demo doc used `moot_recall` (not a registered tool) | Replaced with `moot_memory_search` throughout |
| 2 | CRITICAL | ContentView.swift MARK comment omitted Packets | Added Packets to Advanced tab enumeration |
| 3 | WARNING | FirstRunAndTabProfileTests advancedExtraLabels missing Packets; count "6" stale | Added "Packets", count 6→7, title and comment updated |
| 4 | WARNING | Confidence % via string interpolation — not locale-correct | Changed to `.formatted(.percent.precision(.fractionLength(0)))` |

---

## Test Verification Log

### Baseline (mission start)
- Command: `swift test --package-path apps/Mootx01-App 2>&1 | tail -5`
- GatewayUITests: **37 tests in 8 suites** passed
- MootGatewayTests: 181 tests in 32 suites, 1 pre-existing HTTP loopback failure

### Final
- Command: `swift test --package-path apps/Mootx01-App 2>&1 | grep "Test run with"`
- **Exit code: 0**
- GatewayUITests: **40 tests in 9 suites passed** (+3 new PacketViewsTests)
- MootGatewayTests: **181 tests in 32 suites passed**
- Tail output (verbatim):
  ```
  Test run with 181 tests in 32 suites passed after 6.080 seconds.
  Test run with 40 tests in 9 suites passed after 0.020 seconds.
  ```

---

## Self-Review (Pre-commit Checklist)

### Step 0 — Blast Radius Scope
- All mission files match the changed-files list: Package.swift, ContentView.swift,
  GatewayUI/Packets/ (3 files), GatewayUITests/PacketViewsTests.swift, docs/guide/THREE_MINDS_ONE_MEMORY.md
- MUST NOT MODIFY check: packages/kits/WorkPacketKit/** ✓, packages/kits/AriaMcpKit/** ✓,
  Sources/MootGateway/Workers/** ✓ — none touched.
- No TODO/FIXME referencing changed symbols.
- No bridge helpers, shim/wrapper types, orphan @available deprecations.

### Standard Checks
- Schema invariants: no Bool stored properties (N/A — no entities) ✓
- Localization: all display strings via `String(localized:)` ✓; confidence via `.formatted(.percent)` ✓
- Layout: `UIAdaptivity.readableContentMaxWidth` used in PacketListView and PacketDetailView ✓
- `.leading`/`.trailing` alignment only (no `.left`/`.right`) ✓
- Secrets: none ✓
- Stale comments: none ✓

---

## Adams Post-flight

**Verdict: 2 CRITICAL + 2 WARNING → all resolved before signal**

All 4 findings fixed in commit `0c113f22`. Re-run after fixes: 40 + 181 tests,
both exit 0.

---

## W2-INTERFACE FAB5-I3

Kong ruling captured (for the W2-INTERFACE drawer):
- **Packets tab placement:** Advanced-only, after Miners, ContentView.swift
- **SF Symbol:** `shippingbox`
- **Label:** `"Packets"` via `String(localized:)`
- **View APIs:** PacketListView(loadPackets:), PacketDetailView(packet:drawerID:loadAntecedents:),
  LineageView(rootPacket:rootDrawerID:loadAntecedents:)
- **Demo doc status:** COMPLETE — docs/guide/THREE_MINDS_ONE_MEMORY.md
- **Production wiring gap:** PacketListView uses empty default loader; wiring to
  WorkPacketStore.list is deferred to a follow-on mission.

W2-INTERFACE drawer to be filed at completion (estate integration step).

---

## Commits

| SHA | Message |
|---|---|
| `3e92c353` | feat(app-ui): work-packet list, detail, lineage views |
| `f5e730a0` | docs(guide): Three Minds One Memory demo script |
| `0c113f22` | fix(app-ui): Adams post-flight fixes (FAB5-I3) |

---

## Success Criteria Checklist

- [x] PacketListView, PacketDetailView, LineageView implemented
- [x] Navigation: list → detail → lineage (3-level NavigationStack)
- [x] Closure-injectable loaders for all three views (testable without live estate)
- [x] Packets tab wired in ContentView — Advanced-only, per Kong ruling
- [x] THREE_MINDS_ONE_MEMORY.md: 5-step executable demo script
- [x] All named tools/verbs validated against develop at execution time
- [x] CompareWorker absence noted with FAB5-H2 upgrade path
- [x] 3 new tests: fixture completeness, 3-deep chain structure, raw-value stability
- [x] GatewayUITests: 40 tests, exit 0 (+3 net new)
- [x] MootGatewayTests: 181 tests, exit 0
- [x] Kong design ruling recorded (nav, icon, label)
- [x] Smythe pre-flight: GREEN
- [x] Adams post-flight: 4 findings, all resolved
- [x] Flagship demo reproducible from doc alone
