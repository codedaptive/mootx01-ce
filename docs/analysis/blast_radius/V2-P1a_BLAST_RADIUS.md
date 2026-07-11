# Blast Radius Report — V2-P1a

**Baseline:** swift test pass count at mission start: 508 (505 pass / 3 fail — pre-existing C-4/C-12
in MaintenanceDaemonTests; gate deviation authorized by orchestrator on 2026-07-09)
**Mission:** V2-P1a — NeuronKit: carry udcCode through the topology graph (both legs)
**codegraph:** unavailable — grep-only blast radius

---

## Symbol 1: `GraphTopologyNode.udcCode` (Swift)

**Change class:** additive — new field (never removing, renaming, or changing existing fields)
**Scope:** public

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `Lenses/TopologyAnalysis.swift` | 108 | grep | MUST_UPDATE | init signature — new parameter added |
| `Lenses/TopologyAnalysis.swift` | 404 | grep | MUST_UPDATE | live drawer constructor call site |
| `Lenses/TopologyAnalysis.swift` | 422 | grep | MUST_UPDATE | dead drawer constructor call site |
| `Governor/AutonomicGovernor.swift` | 1033 | grep | MUST_UPDATE | TopologySnapshotNode field-copy from GraphTopologyNode |
| `Tests/…/TopologyAnalysisTests.swift` | — | grep | MUST_UPDATE | new test added for udcCode contract |

### Summary
- MUST_UPDATE: 5 sites
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## Symbol 2: `TopologySnapshotNode.udcCode` (Swift)

**Change class:** additive — new field on wire-shape type
**Scope:** internal (file-private to NeuronKit governor)

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `Governor/AutonomicGovernor.swift` | 1207 | grep | MUST_UPDATE | struct definition |
| `Governor/AutonomicGovernor.swift` | 1217 | grep | MUST_UPDATE | CodingKeys enum |
| `Governor/AutonomicGovernor.swift` | 1222 | grep | MUST_UPDATE | encode(to:) |
| `Governor/AutonomicGovernor.swift` | 1033 | grep | MUST_UPDATE | field-copy from GraphTopologyNode (shared with Symbol 1) |

### Summary
- MUST_UPDATE: 4 sites (1 shared with Symbol 1)
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## Symbol 3: `GraphTopologyNode.udc_code` (Rust)

**Change class:** additive — new field on the Rust output struct
**Scope:** pub (crate-public)

### Call sites

| File | Line | Source | Classification | Justification |
|---|---|---|---|---|
| `rust/src/topology_analysis.rs` | 111 | grep | MUST_UPDATE | struct definition |
| `rust/src/topology_analysis.rs` | 363 | grep | MUST_UPDATE | live drawer constructor |
| `rust/src/topology_analysis.rs` | 378 | grep | MUST_UPDATE | dead drawer constructor |
| `rust/src/autonomic_governor.rs` | 2053 | grep | MUST_UPDATE | hand-built json! node map — conditional "udcCode" insert |
| `rust/src/topology_analysis.rs` | tests | grep | MUST_UPDATE | new Rust tests for udc_code contract |

### Summary
- MUST_UPDATE: 5 sites
- INTENTIONALLY_LEFT: 0
- RESCOPE_REQUIRED: 0

---

## Gate deviation

Pre-existing test failures at mission start: C-4/C-12 in MaintenanceDaemonTests (AuditChainVerifier
not flagging tampered UnifiedAuditLog). These were unrelated to topology and under investigation by
a parallel agent. Orchestrator authorized gate deviation on 2026-07-09: exit criterion adjusted to
"same failure set before and after." At mission end, a separate agent fixed the failures and the
full suite passes: 511/511 (0 failures).

---

## Out-of-scope (noted for follow-up)

- `apps/moot-mgr/rust/src/api_payloads.rs` `GraphNodePayload` — already has `udc_code` from V2-P1b
  with tolerant decode; no additional changes needed here
- `apps/moot-mgr/Sources/MootManager/APIPayloads.swift` `GraphNodePayload` — same; follow-up scope
- `apps/moot-mgr/rust/src/manager.rs` `graph_payload()` — compact `codes`/`codeIndex` arrays built
  in V2-P1b; not touched here
