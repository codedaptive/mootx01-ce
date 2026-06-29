# NeuronKit Changelog

## 2026-06-28 — SECFIX-PUNT-NEURON: Planned hardening — unbounded governor/topology computations

**Branch:** `secfix/punt-neuron`

Three planned security-hardening items implemented across Swift and Rust ports,
bounding previously uncapped computations in the AutonomicGovernor and topology
analysis path.

### Finding 1 — Unbounded autonomous graph-centrality scan (DoS / memory)

**Surfaces:** `AutonomicGovernor.graphCentralityScan` (Swift),
`graph_centrality_duty` (Rust, `autonomic_governor.rs`).

**Cap:** `graphCentralityScanNodeCap = 10 000` (Swift) /
`GRAPH_CENTRALITY_SCAN_NODE_CAP: usize = 10_000` (Rust, `pub const`).

Each governor tick calls `graphCentralityScan`, which previously read ALL live
drawers and fed them into the adjacency builder. On an estate with tens of
thousands of drawers the edge-build is O(n²) in the worst case (dense KGFact
groups) and the keystones oracle runs on an unbounded node set.

Fix: filter to live (non-tombstoned) drawers, sort ascending by id (for
determinism, parity with the internal ordering `GraphCentralityAdjacency.build`
uses), and truncate to the first `graphCentralityScanNodeCap` (10 000) before
calling the adjacency builder. Drawers beyond the cap score 0.0 (spec C-16 —
correct: identical to "no cache registered for that drawer"). A `logger.warning`
/ `eprintln!` fires once per over-limit scan. Parity: both ports apply the cap
before `build_centrality_graph` / `GraphCentralityAdjacency.build`, producing
the same capped subset from the same estate state.

### Finding 2 — Unbounded automatic pool reduction (OOM / stall)

**Surfaces:** `AutonomicGovernor.tick()` pool-reduce block (Swift),
`AutonomicGovernor::tick()` pool-reduce block (Rust, `autonomic_governor.rs`).

**Cap:** `poolReduceFileCap = 500` (Swift private static let) /
`POOL_REDUCE_FILE_CAP: usize = 500` (Rust, `pub const`).

The pool reducer was called unconditionally whenever the cadence elapsed,
regardless of how many files had accumulated in the pool directory. Under high
capture load, hundreds or thousands of files could pile up, causing each reduce
tick to consume unbounded time and memory.

Fix: before advancing `lastPoolReduceFired` / `last_pool_reduce_secs` and
calling the reducer, count the files in the pool directory
(`FileManager.default.contentsOfDirectory` / `std::fs::read_dir(...).count()`).
If the count exceeds `poolReduceFileCap` (500), log a warning and **skip the
reduce without advancing the last-fired timestamp** — so the next tick retries
immediately (near-realtime back-pressure; no file is lost). Normal operation
(≤ 500 files) is unaffected. Parity: both ports apply the same threshold and
the same defer-without-advance logic.

### Finding 3 — Unbounded KGFact graph clique (O(2^n) / DoS)

**Surfaces:**
- `NeuronKit.graphTopology` KGFact loop (Swift, `TopologyAnalysis.swift`) —
  `kgFactCliqueCap = 50`
- `GraphCentralityAdjacency.build` KGFact loop (Swift, `GraphCentralityProducer.swift`) —
  `kgFactGroupCap = 50` (same ceiling, separate constant for the centrality path)
- `graph_topology` KGFact loop (Rust, `topology_analysis.rs`) —
  `KGFACT_CLIQUE_CAP: usize = 50` (already `pub const`)

A KGFact subject shared by `n` drawers generates `n*(n-1)/2` edges — O(n²)
per subject. A generic subject shared by hundreds of drawers (e.g., a
common topic or category) causes the adjacency builder to produce thousands of
edges per tick, with potentially exponential downstream impact on the community
detection algorithm.

Fix: after sorting/deduplicating each subject's drawer list, truncate to the
first `kgFactCliqueCap` / `KGFACT_CLIQUE_CAP` (50) drawers before the nested
pair loop. Drawers beyond the cap receive no bond for that subject but remain
in the node set and can still be bonded by tunnels or other subjects. The cap
limits each subject's contribution to at most 50×49/2 = 1 225 edges. A warning
is logged once per over-limit group.

**Determinism fix (Swift only):** the Swift topology path previously used
`Array(Set(drawerIDs))` whose iteration order is insertion-dependent. Changed
to `Array(Set(drawerIDs)).sorted()` — matching the Rust port's
`sort_unstable()` + `dedup()` — so both ports produce the same edge multiset
from the same facts. This also ensures the capped prefix is consistent across
ports.

### Tests added

**Swift** (`NeuronKitTests/GraphCentralityCapTests.swift`):
- `kgFactCliqueCap_is_50` — cap constant value assertion
- `kgFactGroupCap_is_50` — centrality-path constant parity assertion
- `build_caps_kgfact_group_at_50_drawers` — 51 drawers → ≤ 1 225 edges
- `build_does_not_cap_at_limit_boundary` — exactly 50 drawers → exactly 1 225 edges
- `build_excludes_tombstoned_drawers` — tombstoned drawers excluded from node set
- `poolReduce_defers_when_overloaded` — 501-file pool dir → poolReduceFired false
- `poolReduce_fires_normally_with_empty_dir` — empty pool dir → poolReduceFired true
- Constant doc anchor for `graphCentralityScanNodeCap` (private)

**Rust** (`tests/governor_hardening_tests.rs`):
- `kgfact_clique_cap_is_50` — constant value assertion (parity with Swift)
- `pool_reduce_file_cap_is_500` — constant value assertion (parity with Swift)
- `graph_topology_caps_kgfact_group_at_50_drawers` — 51 drawers → ≤ 1 225 kgFact edges
- `graph_topology_does_not_cap_at_limit_boundary` — exactly 50 → exactly 1 225
- `pool_reduce_defers_when_pool_dir_overloaded` — 501-file pool dir → pool_reduce_fired false
- `pool_reduce_fires_normally_with_empty_dir` — empty pool dir → pool_reduce_fired true

### Build / test verification

Swift: `swift build` exit 0, `swift test` exit 0, 501 tests (baseline 493 + 8 new), all passing.

Rust: `cargo build --offline` exit 0, `cargo test --offline` exit 0, all tests passing
(new hardening suite: 6 passing, no warnings from new tests).
