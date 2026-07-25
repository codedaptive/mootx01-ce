---
title: moot-mgr Specification
version: 1.1.0
status: active
spec_type: kit
authors: MOOTx01 maintainers
date: 2026-06-14
description: Specification for moot-mgr, the GUI control and monitor surface for the headless mootx01 daemon — store ownership, the global monitoring switch, retention, the CLI read/status surface, and the read-plane wire deltas.
relates_to:
  - docs/engineering/STANDARD_CODE_AUTHORING_PRACTICE.md#dependency-manifest-rule
  - docs/reference/OBSERVERSINK_SPEC.md
  - docs/reference/PERSISTENCEKIT_SPEC.md
  - docs/reference/ARIA_MCP_SPEC.md
---

# moot-mgr Specification

## 1. Purpose

`moot-mgr` is the standalone **GUI control + monitor surface for the headless
mootx01 daemon** — the way people who do not use the command line watch and
control mootx01. mootx01 itself is the headless resident server that owns the
whole stack (ARIA → substrate) and triggers its own autonomic governor
cycles (ARIA_MCP_SPEC.md §17); moot-mgr never owns that stack.

"**Pure observer**" is therefore scoped precisely: moot-mgr **never hosts an
estate DB or runs the substrate stack**. It does both **observe** mootx01
(reading the central stats store it owns) **and control/signal** it — the global
monitoring on/off switch, the retention window, the admin lifecycle
(provision / quiesce / drain / destroy), and governor signals all flow from
moot-mgr to the mootx01 daemon over the control channel.

This spec describes the **manager spine**: store
ownership, the on/off control, retention, and the CLI read/status surface, plus
the read-plane wire deltas (§11). The HTTP read-plane dashboard and the macOS
menu-bar shell extend this surface and are documented where they are built.

`moot-mgr` is an **app** (a peer to the aria-mcp surface). Swift is the
macOS build. **Both** a Swift (macOS) and a **Rust (PC/Linux)** version are
provided: the PC/Linux build is the Rust host serving the same web dashboard
assets. Swift and Rust ship at parity; Swift-only is not
the end state.

## 2. Component layout

`apps/moot-mgr`:

| Target | Kind | Contents |
|---|---|---|
| `MootManager` | library | The manager core (store ownership, switch, retention, status). Testable in-process. |
| `moot-mgr` | executable | The thin CLI entry point: parse subcommand → drive `MootManager`. |
| `MootManagerTests` | test | Swift Testing suites, including the end-to-end verify line. |

Dependency hierarchy (downstream → upstream, no inversion):

```
IntellectusLib (floor) → PersistenceKit (kit) → ObserverSink (lib) → moot-mgr (app)
```

In-repo dependencies are declared in `Package.swift` per
the package-dependency rule. Zero external (third-party) Swift dependencies.

## 3. Store ownership

`moot-mgr` provisions and owns exactly one `ObserverSink.StatsStore` (SQLite).
The store path resolves from the environment:

| Env var | Meaning | Default |
|---|---|---|
| `MOOT_MGR_STORE` | Stats-store file path (verbatim) | `<app-support>/com.mootx01.ce/moot-mgr/stats.sqlite` |

The default reuses the `com.mootx01.ce` data-dir convention so manager data sits
with other MOOTx01 CE data. `MootManager.start()` creates the parent directory,
constructs the `StatsStore`, and calls `open()`, which applies the schema and
seeds the control rows **only if absent** (so an operator-set monitoring flag
survives a manager restart).

The store schema (four tables: `metric_samples`, `event_samples`, `control`,
`topology_snapshots`) is owned by `ObserverSink` and documented in
OBSERVERSINK_SPEC.md. The `topology_snapshots` table (schema v2, additive
migration) holds one row per estate: `estate TEXT PRIMARY KEY,
generated_at TEXT NOT NULL (ISO-8601), payload TEXT NOT NULL (GraphPayload JSON)`.
The autonomic governor upserts this row on each topology duty cycle; moot-mgr's
`GET /api/graph` reads it. Consumers write their dropbox rows **directly** into
this store; SQLite WAL handles concurrent writers.

## 4. The global monitoring on/off switch

The manager owns the global report/don't-report switch. It is the `control`
table's `monitoring` flag row (`"1"` = on, `"0"` = off) — the **flag-row signal**.
Setting it IS the broadcast: every consumer's
`PersistenceStatsSink` reads the row on each `receive(_:)` and discards samples
when the flag is `"0"`.

| Operation | Effect |
|---|---|
| `MootManager.setMonitoring(true)` / `false` | Write the flag row (the broadcast). |
| `MootManager.isMonitoring()` | Read the current flag value. |

The switch is **persistent**: it survives a manager restart (`open()` seeds
defaults only when absent).

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

The retention pass is invoked via the CLI (`retention run`); the
cadence env is carried for the resident loop that a later phase will host.

## 6. Read / status surface (CLI)

The read surface is exposed as a CLI summary (`status`).
`MootManager.status(now:recentEventLimit:)` returns a `StatusReport`:

- **monitoring** — the global flag state.
- **totals** — metric and event sample counts.
- **by dropbox** — per-dropbox metric + event counts.
- **by estate** — per-estate event counts (estate is an event-level field;
  metric samples carry no estate id).
- **recent events** — newest-first, capped by `recentEventLimit` (default 20).
- **store health** — the store's own DB-layer stats (size, page/freelist counts,
  WAL frames, cache-hit) via PersistenceKit's `StorageIntrospection`
  (`as? StorageIntrospection` → `StorageStats`).

By-dropbox **and** by-estate granularity is a settled contract:
all-estates views show per-group breakdowns rather than a single collapsed figure.

### Registration

Registration is consumers emitting rows carrying a `dropbox_id`; the
manager reads and groups by it. A formal registrations/heartbeat table is a
noted **follow-up**.

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

## 8. One real consumer wired end-to-end (headless aria-mcp)

A headless aria-mcp server is wired as the first real
consumer. The wiring is **executable-only and opt-in**: when
`ARIA_MCP_STATS_STORE` is set, the server opens the manager's store, installs a
`PersistenceStatsSink`, drives `Intellectus.setEnabled` from the store flag, and
emits a startup metric. When the env var is unset, the MCP wire surface is
unchanged. The AriaMcpKit JSON-RPC library is untouched. (A finer-grained
per-tool-call metric is a follow-up.)

**Resident-daemon note.** The consumer that
matters for an installed user is the **resident `mootx01` HTTP daemon** —
`mootx01` is the headless server that wraps the full stack and triggers its own
autonomic governor (ARIA_MCP_SPEC.md §17). It carries the
same env-gated self-report wiring, and `mootx01 install` sets
`ARIA_MCP_STATS_STORE` to this manager's store path so the daemon is observable
out of the box. Because the daemon is resident, its self-report is continuous
rather than per-session — which is what makes the dashboard's "observed estates"
view populate. The off-by-default monitoring flag still governs whether any
sample flows.

## 9. Verification

The authoritative proof is the end-to-end integration test: manager monitoring
ON → consumer `PersistenceStatsSink` reports a metric + event → rows land →
retention with a cutoff rolls off old rows but keeps new → manager monitoring
OFF → consumer emission stops. Each step is asserted. The pipeline is also
verified across the two real binaries (`moot-mgr` + `aria-mcp`) sharing one store.

## 10. Follow-ups

- A formal **registrations / heartbeat** table (instance → dropbox liveness).
- A resident **retention-loop daemon** driven by the cadence env.
- A **per-tool-call** aria-mcp metric (requires the AriaMcpKit library + its tests).
- The macOS **menu-bar shell**.

## 11. Read-plane wire deltas

The HTTP read-plane carries these wire fields for the topology visualization.
Recorded here pending a dedicated read-plane spec.

### `GET /api/events` — `drawerId`

Each event row carries `drawerId`: the estate row UUID
(`EventRow.rowIDStr`; the `event_samples` schema always stored it — this
projects it onto the wire). Empty string maps to an explicit JSON `null`.
UUID only — content-safe. The SSE stream emits the identical shape
(`projectEvent` is the single projection for both paths). Consumers: the
dashboard's live node-pulse targeting and radar-loop playback.

### `GET /api/graph` — store-read + community enrichment

moot-mgr reads the topology snapshot from its own `topology_snapshots` table
(the same stats.sqlite the aria-mcp daemon's sink writes — §3 store ownership).
Source of truth: `StatsStore.latestTopologySnapshot(estate:)`. When a snapshot
is present, moot-mgr decodes the stored `StoredGraphPayload` and enriches
`communities` at the content boundary: the governor's `{id, size, dominantUdcCode}`
becomes `{id, code, label, size}` where `label = FDC.label(for: dominantUdcCode)`
(LatticeLib; every code resolves to its own frame label) or `null` when
unresolvable, and `code` is the dominant classification code passed through
(`null` when empty/absent). The code crosses on the same basis as
`GET /api/lattice`, which already serves raw codes: a classification code is a
pure function of the pinned public frame, never memory content. The dashboard
derives community colors from the code digits (hundreds → hue, tens → shade,
ones → brightness). `generatedTs` from the stored snapshot is forwarded
verbatim on the `GraphPayload` wire.

When no snapshot has been written yet (governor first duty cycle not complete),
or when no estate key is provided, the local fallback serves `{id: runningIndex,
code: null, label: null, size: 0}` rows derived from the `community.assignment`
analytic metric and `structurePending: true` with empty `nodes`/`edges`.

Full node/edge contract (createdTs, tombstonedTs, Louvain communityId, normalised
centrality): ARIA_MCP_SPEC.md § response shapes.

### `GET /api/graph` — Topology V3 levels and compact positions

V3 snapshots add stable `communityKey`/`foldKey` identities, normalized
coordinates, folds, aggregate bridges, representative ids, and classification
purity. The read API accepts `level=estate|community|local|full` plus an
optional stable `focus` key:

- `estate` returns community aggregates and community bridges; it does not
  allocate or serialize individual node/edge geometry. The level is capped at
  96 aggregates. Overflow reconciles into the neutral `__other__` aggregate.
- `community&focus=<communityKey>` returns that community's fold aggregates
  and fold bridges. Fold production is capped at 64 per community.
- `local&focus=<foldKey|communityKey>` returns real nodes and edges for the
  focused structure, capped at 2,000 nodes and 12,000 edges. Edge truncation
  retains a deterministic non-classification spanning forest before ranked
  detail edges.
- `full` is the compatibility view. Omitting `level` preserves this behavior.

`totalNodeCount`, `totalEdgeCount`, and `lodTruncated` make every budget
explicit. `activityIds`/`activityKeys` map up to 2,000 recent exact drawer ids
to visible aggregates so activity replay never guesses a substitute node.

Per-node coordinates use `positionQ16`: RFC 4648 base64 over interleaved
little-endian signed 16-bit normalized values (`x0,y0,z0,...`). This is a
fixed 6 bytes per node before base64 and keeps the 50k-node/70k-edge full-view
fixture below 5 MB in both ports. `representatives` is a sparse node-index list.

### `GET /api/graph` — per-node classification codes (`codes`/`codeIndex`)

Stored topology snapshots carry an optional per-node `udcCode` (the node's
FDC/UDC classification code) so the dashboard can color nodes by meaning.
moot-mgr decodes it tolerantly — absent key or empty string both mean "no
code" — and both legs (Swift `GraphNodePayload.udcCode: String?`, Rust
`GraphNodePayload.udc_code: Option<String>` with `#[serde(default)]`)
decode a snapshot written before this field existed without error.

The code never crosses the wire per-node. `GraphPayload` dictionary-encodes
it into two new top-level members, built from the decoded node array in the
same pass as the other parallel arrays (`ids`, `communityId`, …):

- `codes: [String]` — the deduped code dictionary, first-seen order over the
  node array.
- `codeIndex: [Int]` — parallel to `ids`; the index into `codes` for that
  node, or `-1` when the node has no code.

At up to 50k nodes and ~10^2 distinct codes, dictionary encoding keeps this
addition inside the existing 5 MB `/api/graph` ceiling (§ size ceiling
above) — a per-node string would have cost tens of bytes × 50k nodes,
the dictionary costs bytes × ~135 distinct codes plus one small integer per
node. Both arrays are always present, even on the local-fallback path
(`codes: []`, `codeIndex: []`), never omitted or null. Codes cross this
surface on the same basis as `GET /api/lattice` and the community `code`
field above: a classification code is a pure function of the pinned public
FDC/UDC frame, never memory content.

### `GET /api/graph` — enrichment cache

The proxy caches the decoded + FDC-enriched product of the latest snapshot
in a single slot keyed by `(estate filter, raw snapshot bytes)`
(`MootManager.topologyEnrichmentCache`). The governor rewrites the snapshot
only when estate content changes (see ARIA_MCP_SPEC.md §topology duty —
fingerprint dirty-check), while the dashboard polls far more often: a cache
hit skips the ~1MB `JSONDecoder` pass and every `FDC.label` lookup, leaving
a SQLite row read + byte compare (~50µs) + response encode. Measured serve
time ~55 ms warm at 2,220 nodes (from ~115 ms uncached; the residual is the
per-request encode, kept because `snapshotTs` is stamped per response).
Invalidation is the key itself: new snapshot bytes miss and repopulate.

### Topology content picker (dashboard)

The Topology view carries a content filter panel (`#topoCommPicker`) listing
the estate's knowledge domains — community FDC labels plus the
`(unlabeled)` / `fragments` buckets — with member counts, sorted by size.
Facet-filter multiselect: clicking a row toggles that domain (the first
click starts a selection containing just it); emptying the selection or
re-checking everything resets to All. Filtering HIDES deselected content
entirely while preserving the persisted coordinate frame. Wheel, trackpad, and
pinch continuously cross Estate → Community → Local: projected aggregate size
prefetches the adjacent bounded API level, a larger threshold commits a 220 ms
stable-position morph, and reverse zoom uses a wider hysteresis threshold.
The previous frame remains visible until the next scene is ready; graph payloads
are cached in a six-entry, 60-second LRU and stale render responses cannot replace
the current view. Aggregate click/Enter drills immediately, +/- follows the same
camera path, and Up reverses the hierarchy. All semantic level changes preserve
the replay event set and exact playhead.
Structural identity is the stable community/fold key, never the FDC label;
classification is only the color/label overlay. Community colors are
digit-derived from each community's FDC code (hundreds → hue, tens → shade,
ones → brightness), so a code renders the same color on every host and
refresh; code-less communities fall back to a static palette pinned per
label from the full-estate ranking. Picker rows always derive from the FULL
estate regardless of the active filter (a layout reset or snapshot refresh
mid-selection must never collapse the available choices). The panel renders
as a fixed right-hand column beside the canvas (never an overlay above it)
and scrolls horizontally when a label exceeds the column width. Client-side
only — no API surface.

### Node query-to-clipboard (dashboard)

Right-clicking a node copies a paste-ready natural-language query to the
clipboard (and selects the node): it asks the user's own AI session to look
up that memory by id, its hop-1 neighbors (capped list), and what the
neighborhood is likely about, citing the MOOTx01 tools by name. Browsers
that grant contextmenu events no user activation (Safari) refuse
programmatic clipboard writes — the dashboard then opens a fallback dialog
with the query pre-selected and a Copy button, whose click carries the
activation. The query is
built entirely from metadata already on the wire (drawer id, domain label,
classification code, neighbor ids) — retrieval of memory CONTENT happens in
the user's AI session under its own authorization, never through this
console. Content-safety boundary is unchanged; no API surface.
