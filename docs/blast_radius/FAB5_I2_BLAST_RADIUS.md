---
version: v0.1
mission: FAB5-I2
stream: i2-workpacket-aria-verbs
author: Bilby
date: 2026-07-24
---

# Blast Radius Report — FAB5-I2: Work-Packet ARIA Verbs

## Summary

Expose `WorkPacketKit` to connected AI models through four MCP tools on the
ARIA/MCP surface. Tier 1 (≤3 existing-file edits + net-new files). Grammar
fit confirmed by Kong: packets are typed content (structuredJSON drawers), not
a new noun — no STOP required.

## Scope Classification: Tier 1

Kong verdict: FITS GRAMMAR (packets = typed content like datasets).
Existing-file edits: Package.swift, ToolProjection.swift, ToolDispatch.swift,
three test-count assertions. Net-new: PacketTools.swift, PacketToolsTests.swift.

---

## Files You Will Modify

| File | Change |
|---|---|
| `packages/kits/AriaMcpKit/Package.swift` | Add WorkPacketKit package dep + AriaMCP target product dep |
| `packages/kits/AriaMcpKit/Sources/AriaMCP/ToolProjection.swift` | Append `PacketTools.tools()` after DatasetTools; update count comment |
| `packages/kits/AriaMcpKit/Sources/AriaMCP/ToolDispatch.swift` | Insert PacketTools dispatch branch after DatasetTools block |
| `packages/kits/AriaMcpKit/Tests/AriaMCPTests/ToolProjectionTests.swift` | 71 → 75 in testTotalToolCount |
| `packages/kits/AriaMcpKit/Tests/AriaMCPTests/VaultToolsTests.swift` | 65 → 69 (vault-off), 71 → 75 (vault-on) |
| `packages/kits/AriaMcpKit/Tests/AriaMCPTests/V1ConformanceTests.swift` | 71 → 75 in v1ToolsListReturns71Tools; update comment |

## Files You MUST NOT Modify

- `WorkPacketKit/` — consumed as-is; no changes to WorkPacketStore, LineageGraph,
  WorkPacket, WorkPacketEstateClient.
- `AriaLexiconLib/` — grammar acceptance matrix is read-only.
- Any Rust file — Swift-only, no Rust twin per spec.
- Any entity type (Drawer, Tunnel, KGFact, DiaryEntry) — schema invariants intact.

## Net-New Files

| File | Purpose |
|---|---|
| `packages/kits/AriaMcpKit/Sources/AriaMCP/PacketTools.swift` | Four-verb MCP handler namespace |
| `packages/kits/AriaMcpKit/Tests/AriaMCPTests/PacketToolsTests.swift` | Handler unit tests with stubbed store |

---

## Blast Radius Scope

### Tool names (Kong-corrected from mission spec)

| Verb | Tool name | Handler |
|---|---|---|
| file-packet | `moot_file_packet` | Create + store WorkPacket, return drawer ID |
| get-packet | `moot_packet_get` | Fetch single packet by drawer ID |
| list-packets | `moot_packet_list` | List packets in estate room with optional limit |
| trace-lineage | `moot_packet_lineage` | BFS lineage traversal from a drawer ID |

### Symbol blast radius

- `PacketTools` (new) — wired into `ToolProjection.tools()` and `ToolDispatch.dispatch()`
- `ToolProjection.tools(environment:)` — one-line append after DatasetTools
- `ToolDispatch.dispatch()` — one `else if` branch after DatasetTools block
- Tool count: 71 → 75 (+4 tools, none vault-gated)

### Pre-existing test failures (accepted baseline)

Smythe pre-flight (YELLOW verdict): 12 failures in AriaMCPTests unrelated to
packet work — GLK 1.1 migration tests (DurableSemanticRecallTests,
InMemorySemanticRecallTests, DreamRunnerTests). Baseline is 534 pass / 12 fail.
These 12 failures are pre-existing and do not block this mission.

---

## MUST_UPDATE Checklist

- [x] Package.swift: WorkPacketKit dep + product
- [x] PacketTools.swift: four verb handlers
- [x] ToolProjection.swift: PacketTools.tools() append + comment update
- [x] ToolDispatch.swift: PacketTools.isPacketTool branch
- [x] ToolProjectionTests.swift: 71 → 75
- [x] VaultToolsTests.swift: 65 → 69 and 71 → 75
- [x] V1ConformanceTests.swift: 71 → 75
- [x] PacketToolsTests.swift: stubbed-store handler tests

## RESCOPE_REQUIRED

None identified.
