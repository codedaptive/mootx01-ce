---
title: moot-mgr Specification
version: 1.0
status: draft
spec_type: kit
authors: MOOTx01 maintainers
date: 2026-06-06
relates_to:
  - docs/decisions/DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.md
  - docs/reference/OBSERVERSINK_SPEC.md
  - docs/reference/PERSISTENCEKIT_SPEC.md
---

# moot-mgr Specification v1.0 (Phase 1 — Manager Spine)

## 1. Purpose

`moot-mgr` is the standalone MOOTx01 observer/manager process. It is a **pure
observer**: it never hosts an estate DB. It owns the central stats store, the
global monitoring on/off switch, and the retention window
(MANAGER_1.0_PLAN.md §1).

This spec describes the **Phase 1 manager spine** (MANAGER_1.0_PLAN.md §3): store
ownership, the on/off control, retention, and the CLI read/status surface. The
HTTP read-plane dashboard (Phase 3) and the macOS menu-bar shell (Phase 5) are
out of scope for this document and will extend it when built.

`moot-mgr` is an **app** (a peer to the ARIA surfaces). Swift is the prototype /
macOS build. Post-prototype, **both** a Swift (macOS) and a **Rust (PC/Linux)**
version are on the roadmap: the PC/Linux build is the Rust host serving the same
web dashboard assets (`ARIA_MCP_DESKTOP_APP_CONCEPTS.md` §9 — "the same assets are
served by the PC/Linux (Rust) build"), sequenced after the mac binary is posted.
Per parity-is-absolute, Swift-only is not the end state.

## 2. Component layout

`apps/moot-mgr` (MANAGER_1.0_PLAN.md §4, RESOLVED name):

| Target | Kind | Contents |
|---|---|---|
| `MootManager` | library | The manager core (store ownership, switch, retention, status). Testable in-process. |
| `moot-mgr` | executable | The thin CLI entry point: parse subcommand → drive `MootManager`. |
| `MootManagerTests` | test | Swift Testing suites, including the Phase-1 end-to-end verify line. |

Dependency hierarchy (downstream → upstream, no inversion):

```
IntellectusLib (floor) → PersistenceKit (kit) → ObserverSink (lib) → moot-mgr (app)
```

In-repo dependencies are declared in `Package.swift` per
DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28. Zero external (third-party) Swift
dependencies.

## 3. Store ownership

`moot-mgr` provisions and owns exactly one `ObserverSink.StatsStore` (SQLite,
the §5 default). The store path resolves from the environment:

| Env var | Meaning | Default |
|---|---|---|
| `MOOT_MGR_STORE` | Stats-store file path (verbatim) | `<app-support>/com.mootx01.ce/moot-mgr/stats.sqlite` |

The default reuses the `com.mootx01.ce` data-dir convention so manager data sits
with other MOOTx01 CE data. `MootManager.start()` creates the parent directory,
constructs the `StatsStore`, and calls `open()`, which applies the schema and
seeds the control rows **only if absent** (so an operator-set monitoring flag
survives a manager restart).

The store schema (three tables: `metric_samples`, `event_samples`, `control`) is
owned by `ObserverSink` and documented in OBSERVERSINK_SPEC.md. Consumers write
their dropbox rows **directly** into this store (direct-dropbox-writes, the §5
confirmed default); SQLite WAL handles concurrent writers.

## 4. The global monitoring on/off switch

The manager owns the global report/don't-report switch. It is the `control`
table's `monitoring` flag row (`"1"` = on, `"0"` = off) — the **flag-row signal**
(§5 item 3, confirmed by Bob). Setting it IS the broadcast: every consumer's
`PersistenceStatsSink` reads the row on each `receive(_:)` and discards samples
when the flag is `"0"`.

| Operation | Effect |
|---|---|
| `MootManager.setMonitoring(true)` / `false` | Write the flag row (the broadcast). |
| `MootManager.isMonitoring()` | Read the current flag value. |

The switch is **persistent**: it survives a manager restart (Phase 1
implementation: `open()` seeds defaults only when absent).

## 5. Retention

`moot-mgr` runs a retention loop that rolls off samples older than a configurable
window:

| Env var | Meaning | Default |
|---|---|---|
| `MOOT_MGR_RETENTION_SECONDS` | Retention window (whole seconds) | `604800` (7 days) |
| `MOOT_MGR_RETENTION_CADENCE_SECONDS` | Resident-loop cadence | `3600` (1 hour) |

`MootManager.runRetention(now:)` computes `cutoff = now - retentionWindow` and
deletes metric and event rows with `ts < cutoff`. The app reads the clock at this
boundary (its own loop); the computed cutoff is then passed **into**
`StatsStore`'s retention engine, which takes the cutoff as a parameter — no
`Date()` inside the engine (determinism). A non-positive or non-numeric window
env value falls back to the default (a zero window would roll off everything
immediately).

In Phase 1 the retention pass is invoked via the CLI (`retention run`); the
cadence env is carried for the resident loop that a later phase will host.

## 6. Read / status surface (CLI)

Phase 1 exposes the read surface as a CLI summary (`status`). The HTTP dashboard
is Phase 3. `MootManager.status(now:recentEventLimit:)` returns a `StatusReport`:

- **monitoring** — the global flag state.
- **totals** — metric and event sample counts.
- **by dropbox** — per-dropbox metric + event counts.
- **by estate** — per-estate event counts (estate is an event-level field;
  metric samples carry no estate id).
- **recent events** — newest-first, capped by `recentEventLimit` (default 20).
- **store health** — the store's own DB-layer stats (size, page/freelist counts,
  WAL frames, cache-hit) via PersistenceKit's `StorageIntrospection`
  (`as? StorageIntrospection` → `StorageStats`).

By-dropbox **and** by-estate granularity is per the §5 item 4 ruling (Bob):
all-estates views show per-group breakdowns rather than a single collapsed figure.

### Registration (this cut)

Registration in Phase 1 = consumers emit rows carrying a `dropbox_id`; the
manager reads and groups by it. A formal registrations/heartbeat table is a
noted **follow-up**, not in this cut.

## 7. CLI command surface

```
moot-mgr monitoring on        Enable monitoring fleet-wide (broadcast)
moot-mgr monitoring off       Disable monitoring fleet-wide
moot-mgr monitoring status    Print the current monitoring state (ON/OFF)
moot-mgr retention run        Run one retention pass now
moot-mgr status               Print the full status surface
moot-mgr help                 Print usage
```

Unrecognised commands print usage to stderr and exit `2`; operational failures
print to stderr and exit `1`; success prints to stdout and exits `0`.

## 8. One real consumer wired end-to-end (headless ARIA_MCP)

Per MANAGER_1.0_PLAN.md §3, the headless `aria-mcp` server is wired as the first
real consumer. The wiring is **executable-only and opt-in**: when
`ARIA_MCP_STATS_STORE` is set, `aria-mcp` opens the manager's store, installs a
`PersistenceStatsSink`, drives `Intellectus.setEnabled` from the store flag, and
emits a startup metric. When the env var is unset, the MCP wire surface is
unchanged. The `AriaMCP` JSON-RPC library is untouched. (A finer-grained
per-tool-call metric is a follow-up.)

## 9. Phase-1 verification

The authoritative proof is the end-to-end integration test
(`MootManagerIntegrationTests.endToEndPipeline`): manager monitoring ON →
consumer `PersistenceStatsSink` reports a metric + event → rows land →
retention with a cutoff rolls off old rows but keeps new → manager monitoring
OFF → consumer emission stops. Each step is asserted. The pipeline was also
verified across the two real binaries (`moot-mgr` + `aria-mcp`) sharing one store.

## 10. Follow-ups (out of Phase-1 scope)

- A formal **registrations / heartbeat** table (instance → dropbox liveness).
- The **HTTP read-plane** dashboard (Phase 3).
- A resident **retention-loop daemon** driven by the cadence env.
- A **per-tool-call** ARIA_MCP metric (requires the AriaMCP library + its tests).
- The macOS **menu-bar shell** (Phase 5).
