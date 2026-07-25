---
version: v0.1
mission: FAB5-I2
stream: i2-workpacket-aria-verbs
completed: 2026-07-24
author: Bilby
---

# Completion Report — FAB5-I2: Work-Packet ARIA Verbs

## Outcome: COMPLETE

All mission success criteria met. Adams post-flight cleared after CRITICAL fix applied.

---

## Commits

| SHA | Message |
|---|---|
| `80980fdd` | `feat(aria): work-packet verbs (file/get/list/trace)` |
| `04f7c093` | `test(aria): packet round-trip over MCP surface` |
| `7b359279` | `fix(aria): moot_packet_list emits drawer_id not packet.id (Adams CRITICAL)` |

## Tool Surface Delivered

| Tool | Description |
|---|---|
| `moot_file_packet` | Create and store a WorkPacket; returns estate drawer ID |
| `moot_packet_get` | Fetch a single packet by estate drawer ID |
| `moot_packet_list` | List packets newest-first (drawer IDs for round-trip) |
| `moot_packet_lineage` | BFS lineage traversal from a root drawer ID |

Grammar verdict: FITS GRAMMAR (Kong, FAB5-I2) — packets are typed content
(structuredJSON drawers in room "work-packets"), not a new noun. Tool naming
follows `moot_<noun>_<verb>` / `moot_file_<noun>` convention.

---

## Test Verification Log

### Baseline (mission start)
- Pre-existing failures: 12 (GLK 1.1 migration tests, unrelated to this mission)
- Total at baseline: 534 (522 passing, 12 failing)

### Final
- Command: `swift test --package-path packages/kits/AriaMcpKit 2>&1 | tail -5`
- Exit code: 1 (baseline; 12 pre-existing GLK failures, same count as start)
- Total tests: 543 (+9 new packet tests)
- New failures introduced: 0
- Tail output (verbatim):
  ```
  Suite "Vault tools" passed after 4.954 seconds.
  Test run with 543 tests in 55 suites failed after 4.954 seconds with 12 issues.
  Note: Some test targets reported failures:
    - AriaMCPTests (Swift Testing)
  ```

### Packet tests (filtered)
- Command: `swift test --package-path packages/kits/AriaMcpKit --filter "PacketTools"`
- Exit code: 0
- Tests: 9/9 pass
  - toolListContainsFourPacketTools
  - packetToolsCarryInterfaceProvenance
  - filePacketGetRoundTrip
  - listPacketsContainsFiledPacket (includes list→get drawer_id round-trip)
  - packetLineageTwoNodeChain
  - filePacketMissingObjectiveIsError
  - getPacketMissingDrawerIDIsError
  - getPacketUnknownDrawerIDReturnsError
  - e2eFilePacketRetrievableViaMemoryGetAndPacketGet

---

## Adams Post-Flight

Verdict: BLOCKED → CLEARED after fix commit `7b359279`.

**CRITICAL finding (resolved):** `moot_packet_list` was emitting `packet_id`
(WorkPacket's own UUID) instead of the estate drawer ID. Fixed by bypassing
`WorkPacketStore.list()` and calling `listDrawers` directly via `EstateAdapter`,
so each row carries `drawer_id: drawer.id` — the value usable in
`moot_packet_get` and `moot_packet_lineage`.

**WARNING findings (resolved):**
- `v1ToolsListReturns71Tools` renamed to `v1ToolsListReturns75Tools`.
- Exit code documented as 1 (not 0) — pre-existing GLK baseline.

---

## Blast Radius Compliance

All 8 MUST_UPDATE items from `docs/blast_radius/FAB5_I2_BLAST_RADIUS.md` addressed.
No prohibited patterns (no bridges, no shims, no deprecated annotations, no TODO
on changed symbols). Scope stayed within Tier 1 bounds.

---

## MCP Smoke Verification

Demonstrated via `e2eFilePacketRetrievableViaMemoryGetAndPacketGet`:
- Filed packet via `moot_file_packet` → got drawer_id
- Retrieved via `moot_memory_get` (generic drawer surface) → objective present in content
- Retrieved via `moot_packet_get` (packet-specific) → all fields decoded correctly

Packets are first-class estate drawers reachable from any surface that knows the drawer ID.
