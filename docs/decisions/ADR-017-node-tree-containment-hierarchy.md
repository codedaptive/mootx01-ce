---
status: decided
question: The estate was designed as a tree of nodes (estate, wing, room, drawer) where every entity is a node and nodes contain other nodes. During implementation the hierarchy was abandoned in favor of flat string tags on the drawer table, so wings and rooms have no independent existence, the containment tree does not exist in storage, and the substrate cannot traverse or reason about its own structure. How does the system recover the node tree, and what storage-layer properties (snapshots, content-integrity, erasure) must land with it so they are not bolted on later?
authors: MOOTx01 maintainers
date: 2026-06-28
version: 1.5.0
relates_to:
  - docs/decisions/ADR-016-wings-provenance-role-axis.md
  - docs/decisions/DECISION_LOCUSKIT_BUNDLE_HIERARCHY_2026-05-20.md
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
  - docs/concepts/TOPOLOGY.md
complements:
  - docs/decisions/ADR-016-wings-provenance-role-axis.md
description: The estate's containment hierarchy (estate, wing, room, drawer) is restored as a first-class node tree stored in a new `nodes` table in LocusKit, at fixed depth four with strict single containment. Wings and rooms become real entities with their own IDs, lifecycle state, and metadata. Drawers gain a `parent_node_id` foreign key; the legacy `wing` and `room` string columns are removed. Alongside the tree, three storage-layer capabilities land in the same pass because each is a write-path or read-path property that cannot be added later without re-opening the schema: ZFS-inspired copy-on-write estate snapshots, Merkle content-integrity (per-wing and per-estate roots), and lineage-wide erasure with keyed-commitment provenance. These capabilities are generic primitives in PersistenceKit and SubstrateLib, consumed equally by LocusKit and by standalone CorpusKit, so a CorpusKit-only SDK user is a first-class citizen. All capabilities are defined against the storage contract and implemented on all three backends (InMemory, SQLite, PostgreSQL), conformance-gated. The FDC classification tree remains a separate, orthogonal axis.
---

# ADR-017: Node tree containment hierarchy, with snapshots, Merkle integrity, and erasure

## Mission header summary (the layer map — read before authoring or implementing any NT mission)

Every NT-family mission carries this block in its header. It exists so agents
build to the layer map rather than inventing placement. Two hard rules govern
the whole family:

1. **No primitive may be pushed up out of its layer.** Merkle hashing is not a
   LocusKit feature. It is a SubstrateLib hash function, plus a PersistenceKit
   hash-on-write hook, plus a kit-supplied roll-up chain. Snapshots are not a
   GeniusLocusKit feature. They are a PersistenceKit registry and as-of filter,
   plus kit-supplied verbs. Erasure mechanics are PersistenceKit; erasure
   *meaning* (lineage-wide drawer scrub) is LocusKit.
2. **No capability may be implemented on one backend only.** Every
   storage-contract capability is defined once against the
   `Storage` / `RowStore` / `BlobStore` / `AuditLog` protocols and implemented
   with full fidelity on InMemory, SQLite, and PostgreSQL, conformance-gated.
   No raw `CREATE TABLE`, no recursive CTE, no SQLite-only trick that strands
   the InMemory or PostgreSQL backend. InMemory is a first-class deployment
   target (apps that run wholly in RAM), not a test double.

| Layer | Kit | Owns (for this ADR) | Already present |
|---|---|---|---|
| Foundation values | SubstrateTypes | HLC, RowState, RowVerb, Fingerprint256, CountVector256, AuditEvent; snapshot-id / as-of coordinate type (added) | HLC, RowState, Fingerprint256, AuditEvent |
| Foundation algorithms | SubstrateLib | SHA256 (the Merkle hash), AuditGate, GSetAuditLog (grow-only audit chain), RowStateAutomaton; keyed-commitment audit entry kind (added) | SHA256, AuditGate, GSetAuditLog |
| Storage contract | PersistenceKit | Generic primitives: HLC append-and-supersede mode, content-hash-on-write hook, up-chain aggregate invalidation (via StorageObserver), as-of read filter, snapshot registry + GC pin, keyed-commitment destruction mechanics, temporal-aware cache. Knows nothing about drawers/sources/wings/chunks. On all three backends, conformance-gated | StorageObserver dirty-set, HLC-watermark replication, three backends, real transactions |
| Queue / Sync | QueueKit, ConvergenceKit | Unchanged in shape. QueueKit absorbs write-path hashing/roll-up cost. ConvergenceKit replicates snapshots via the existing HLC-watermark cursor | HLC-watermark incremental replication |
| Standalone substrate | LocusKit | Node tree, drawer parent_node_id, node lifecycle + no-resurrection guard, lineage-wide expunge, containment roll-up chain (room→wing→estate), per-wing + per-estate Merkle roots, snapshot verbs | append-and-supersede drawers, lineage, state automaton, expunge (head-scrub today) |
| Standalone substrate | CorpusKit | **First-class peer.** BundleStore + remove adopt the PersistenceKit primitives; own roll-up chain; per-corpus Merkle root; corpus snapshots | append-only BundleStore, BM25, VectorStore fan-out, remove(sourceID:) |
| Composition | GeniusLocusKit | Composes LocusKit + CorpusKit; verbs; coordinates the cross-kit erasure it already choreographs | nine verbs, cross-kit expunge orchestration |
| Consumers | NeuronKit, CognitionKit, AriaMcpKit, VaultKit | Consume node tree + snapshots; own no new primitive | — |

The write-surface fork is canon (TOPOLOGY.md): in estate mode every write goes
through GLK; in standalone-SDK mode a CorpusKit/LocusKit/VectorKit write goes
directly to the kit. This is *why* snapshots, Merkle, and erasure must live
below the fork (PersistenceKit + SubstrateLib): both paths must inherit them.

## Context

The estate was conceived as a tree of nodes. Estate contains wings, wings
contain rooms, rooms contain drawers. Everything is a node, and nodes can
contain other nodes, with the single exception that a drawer is a leaf and
contains nothing. The node's type is not an intrinsic label; it is a function
of the node's superposition relative to other nodes. A node directly under the
estate root is a wing. A node under a wing is a room. A leaf is a drawer.

Two independent trees were intended to exist over the same data:

1. The **containment tree** (estate/wing/room/drawer), answering "where does
   this live" and providing the zoom capability: navigate from estate down to
   wing down to room down to drawer, with roll-up data at each level.

2. The **FDC classification tree**, answering "what is this about" and providing
   multidimensional subject navigation. This tree is derived from the per-drawer
   lattice anchors produced by EideticLib/LatticeLib.

During implementation, the containment tree was never built. A decision recorded
in `DECISION_LOCUSKIT_BUNDLE_HIERARCHY_2026-05-20.md` explicitly ratified the
flat model: "The node tree is the existing wing and room grouping" and "No new
hierarchy concept is introduced." Wings and rooms became free-form text columns
on the `drawers` table, derived at query time by `SELECT DISTINCT`. There is no
`wings` table, no `rooms` table, no `nodes` table, and no `parent_id` on any
entity. The system comments in `drawer.rs` state this as policy: "Wing and room
are metadata-only strings ... there is no wings or rooms table."

The `NodeTopologyProvider` protocol/trait in GeniusLocusKit acknowledges the
need for a tree but delegates it to the host application. The substrate stores
nothing about the host tree; it reads a snapshot at recall start and discards
it when the recall completes. The tree the substrate should own was handed to
someone else to carry.

The FDC classification tree is correctly implemented per-drawer through lattice
anchors and is not affected by this decision.

No data is in the wild. The system is pre-beta. There is no migration
constraint.

### Why three storage capabilities land in the same pass

This ADR also commits three capabilities that are not the node tree but must be
built with it, because each is a property of *how writes and reads happen*, not
a feature layered above the tree. Adding any of them after the node tree ships
would re-open the write path of all three backends and re-open the node and
drawer schema a second time — the exact bolt-on this project avoids.

- **Snapshots** (ZFS-inspired copy-on-write): an estate-wide consistency root
  that lets a reader see the whole memory as it was at a point in time. This is
  an as-of read filter plus a registry plus a GC pin — all storage-contract
  behaviors.
- **Merkle content-integrity**: a content hash per payload, rolled up to
  per-wing and per-estate roots, giving tamper-evidence and bit-rot detection.
  This is a hash computed on the write path with up-chain invalidation.
- **Lineage-wide erasure**: expunge that destroys content across every version
  and every snapshot, with keyed-commitment provenance, satisfying data-
  destruction obligations without defeating temporal travel for non-erased
  content.

The substrate is already most of the way to all three: drawers are
append-and-supersede (lineage chains, retained Superseded/Withdrawn/Expired
states), several tables are `append_only` (update/delete return
`AppendOnlyViolation`), transactions are real (BEGIN/COMMIT/ROLLBACK with
isolation), replication is already HLC-watermark-based, SHA256 and a grow-only
audit log already exist in SubstrateLib, and InMemory is already a co-equal
backend. What is missing is the estate-wide consistency root, the content-hash
roll-up, and lineage-wide (rather than head-only) erasure. This ADR adds those.

## Decision

### 1. Node model: containers and leaves

Every entity in the estate is a node. The implementation splits them by role:

- **Container nodes** (estate, wing, room) live in the `nodes` table. These are
  the structural skeleton of the tree: small in number (one estate, tens of
  wings, hundreds of rooms), long-lived, and carry lifecycle state and roll-up
  metadata including the per-node Merkle root.

- **Drawer leaf nodes** live in the `drawers` table and participate in the tree
  through `drawers.parent_node_id`, which references their parent room node.
  Drawers are numerous and carry content, bitmaps, vectors, and lattice anchors.

This split keeps the `nodes` table small and fast (the read-path hot table)
while the `drawers` table retains its existing row shape for the math pipeline.

### 2. The `nodes` table

```
nodes
  id              TEXT PRIMARY KEY    -- UUID
  parent_id       TEXT                -- UUID of parent node (NULL for estate root)
  display_name    TEXT NOT NULL       -- canonical display name (first-write casing)
  lookup_name     TEXT NOT NULL       -- normalized: NFC, casefolded, whitespace-collapsed (§8)
  depth           INT  NOT NULL       -- 0=estate, 1=wing, 2=room
  lifecycle       INT  NOT NULL       -- 0=active, 1=tombstoned (see §5)
  created_hlc     HLC  NOT NULL       -- HLC at node creation (temporal floor for as-of, §15)
  tombstoned_hlc  HLC  NULLABLE       -- HLC at tombstone; NULL while active (temporal ceiling, §15)
  tombstoned_at   TIMESTAMP           -- ISO8601 TEXT wall-clock mirror of tombstoned_hlc (display only)
  merkle_root     TEXT                -- content-integrity root for this node's subtree (§16)
  created_at      TIMESTAMP
  updated_at      TIMESTAMP
  ext             JSON NULLABLE       -- forward-compat slot
```

`depth` is denormalized from the tree for query efficiency; it is write-once
(no rename or reparent in 1.0) and cannot drift.

**HLC-versioned lifecycle (the as-of filter is uniform over nodes and drawers).**
A node carries `created_hlc` and `tombstoned_hlc` (NULL while active), not a
single creation HLC plus a wall-clock tombstone. This is required for snapshots:
an as-of-T read must decide whether a node was active *at T*, which is an
HLC comparison (`created_hlc <= T AND (tombstoned_hlc IS NULL OR
tombstoned_hlc > T)`), not a wall-clock comparison. `tombstoned_at` is a
display-only mirror and is never used in temporal filtering — wall time is not
comparable to HLC. Node lifecycle is therefore append-and-supersede in the same
sense drawers are: a tombstone is an HLC-stamped transition, not an in-place flag
flip, so the as-of filter and the replication watermark operate identically over
the `nodes` and `drawers` tables.

**Display vs lookup name (§8).** `display_name` preserves the first writer's
casing; `lookup_name` is the normalized key. Resolution and active-uniqueness use
`lookup_name`, never `display_name`. "First casing wins, later casing resolves
the existing node" is enforced because both casings normalize to the same
`lookup_name`.

`merkle_root` holds the per-node content-integrity root (§16); for wing and estate
nodes this is the attested per-wing and per-estate root.

Indices: `parent_id`; `(parent_id, lookup_name)` UNIQUE on active nodes;
`(depth, lookup_name)`.

### 3. Drawer parent reference: `parent_node_id`

```
drawers.parent_node_id  TEXT NOT NULL   -- UUID of the room node this drawer belongs to
```

The legacy `wing` and `room` text columns are removed. `parent_node_id` is the
single source of containment truth. Consumers needing the wing/room name join
through the tree (drawer → room node → wing node), two indexed lookups. No
compatibility shim reconstructing the string columns is permitted; a derived
wing/room name may appear only as a transient join result at a display
boundary, never as a stored column.

Index: `parent_node_id`.

### 4. Schema invariants

**I-NT-1 (single root):** Exactly one node has `parent_id = NULL`, with
`depth = 0` and `lookup_name = 'estate'`. The write path checks for an existing
root before inserting (the unique index cannot enforce this because NULL != NULL).

**I-NT-2 (depth consistency):** A node whose parent has depth N has depth N+1.
No node has depth > 2.

**I-NT-3 (drawer parent is room):** A drawer's `parent_node_id` references a
node with `depth = 2` and `lifecycle = 0`.

**I-NT-4 (name uniqueness within parent):** No two active nodes under the same
parent share a `lookup_name` (the normalized key, §8). A tombstoned node does not
block a fresh active node of the same `lookup_name` (§5).

**I-NT-5 (referential integrity):** Every `drawers.parent_node_id` references an
existing `nodes` row. Every non-NULL `nodes.parent_id` references an existing
`nodes` row.

**I-NT-6 (gate ordering):** Node scope is a candidate-narrowing step that runs
**before** the adjective/bitmap evaluator, never after. Node scope narrows →
the bitmap evaluator runs the sensitivity, state, and content gates on the
narrowed set → results return. A secret-tier drawer in a scoped wing is gated
exactly as in an unscoped recall.

### 5. Node lifecycle and the no-resurrection guard

Container nodes carry `lifecycle`: active (0) or tombstoned (1). This prevents
silent resurrection of an erased container by create-on-demand resolution.

- A container node is never row-deleted by erasure; it is tombstoned
  (`lifecycle = 1`, `tombstoned_hlc` set to the transition HLC, `tombstoned_at`
  set as the display mirror). The tombstone is an HLC-stamped transition (§2), so
  an as-of-T read can decide whether the node was active at T.
- Create-on-demand resolution (§7) matches only active nodes. A tombstoned node
  of the same `lookup_name` is invisible to resolution; the resolver mints a fresh
  active node rather than reattaching.
- `UNIQUE(parent_id, lookup_name)` is scoped to active nodes, so a fresh active
  node may carry the `lookup_name` of a prior tombstoned one.
- Resolution never flips a tombstoned node back to active. Reactivation, if ever
  supported, is an explicit audited management operation, never a capture or
  import side effect.

This makes no-resurrection structural, established in NT-L1 with the first
version of the node store, not patched at the import boundary.

### 6. Read path: tree-scoped queries

Recall gains optional node-scope.

- **Unscoped** (default): scans all drawers.
- **Wing-scoped**: select active room nodes under the wing, then drawers whose
  `parent_node_id` is in that room set. Two indexed joins.
- **Room-scoped**: drawers whose `parent_node_id` equals the room node ID. One
  indexed join.

Per I-NT-6, node scope narrows before the adjective gate. The fingerprint-
pruning path in `estate_verbs.recall`, which already walks wing-then-room via
`container_fingerprints`, changes from string-keyed hash-map lookups to
node-ID-keyed index lookups; the algorithmic structure is identical.

The ARIA MCP surface continues to accept wing/room names as strings; the tool
dispatch layer resolves strings to node IDs before calling the verb surface.

### 7. Write path: create-on-demand resolution

The capture verb accepts wing/room as strings and resolves them at the write
boundary:

1. Derive `lookup_name` from the wing string (§8); look up the active wing node
   by `lookup_name` under the estate root; create if absent (storing the original
   string as `display_name`).
2. Derive `lookup_name` from the room string; look up the active room node by
   `lookup_name` under that wing; create if absent.
3. Set the drawer's `parent_node_id` to the room node's ID.

This resolution lives in the shared core, conformance-gated across ports.
INSERT OR IGNORE then SELECT must be byte-identical on the race edge (two
simultaneous captures of the same new name) in Swift and Rust. Tombstoned nodes
are excluded (§5). On the write path this latency is absorbed by QueueKit.

### 8. Name normalization: display vs lookup

Each node stores two names. `display_name` is what the user sees, preserving the
first writer's casing. `lookup_name` is the resolution key, derived at the write
boundary by: Unicode NFC, trim, collapse internal whitespace to single spaces,
then Unicode casefold. All resolution (§7), all active-uniqueness enforcement
(I-NT-4), and all index keys use `lookup_name`; `display_name` is never used for
matching. "First casing wins, later casing resolves the existing node" is
therefore enforced structurally: two writes differing only in casing produce the
same `lookup_name` and resolve to the same active node, while the original
`display_name` is retained. The casefold algorithm is fixed and conformance-gated
across Swift and Rust so the two ports derive byte-identical `lookup_name` values.

### 9. Roll-up tables rekeyed

`node_bundles` (count-vector roll-ups) and `container_fingerprints` (bitmap
OR-aggregates) are rekeyed from `(wing TEXT, room TEXT)` to `node_id TEXT`
references. The merge follows the parent chain. The count-vector and fingerprint
math is key-agnostic; only the key type changes. The Merkle roll-up (§16) joins
this same aggregate path.

### 10. NodeTopologyProvider becomes substrate-native

The estate's containment tree becomes the canonical implementation of
`NodeTopologyProvider`. `parentID` reads `parent_id`; `childIDs` queries
`WHERE parent_id = ?` on active nodes; `treeEdges` builds the induced edge set
from `nodes` plus `drawers.parent_node_id`. The host-side adapter remains
available for external trees, but the estate's tree is no longer delegated.

**NT-G0 rename (2026-06-21):** The GLK Swift protocol was renamed from
`NodeTopologyProvider` to `GLKNodeTopologyProvider` to resolve a naming
collision with LocusKit's substrate-native `NodeTopologyProvider` protocol
(which uses UUID identifiers rather than String). The Rust trait retains
the unprefixed name. Historical references to `NodeTopologyProvider` in
§10 above refer to the GLK-layer protocol now named `GLKNodeTopologyProvider`.

### 11. Fixed depth, strict containment, and where unbounded structure lives

The tree is fixed at four levels: estate (0), wing (1), room (2), drawer (3).
Containment is strict: every node has exactly one parent (except the root). A
drawer belongs to exactly one room.

Fixed depth is a deliberate decision, stress-tested against three reference
systems and reaffirmed:

- A **file system** moved organization into tags, search, and links over a
  deliberately shallow hierarchy (Spotlight, not deeper folders).
- The **LLM Wiki** pattern is a backlink graph of pages, not a containment-depth
  tree; navigation is link-following.
- **ZFS** keeps the navigable layer (named datasets) shallow and puts unbounded
  depth in the invisible addressing/integrity layer (the block-pointer Merkle
  tree), which no user descends; its powerful structure (snapshots, clones,
  dedup) is reference-based, not containment-based.

Unbounded structure therefore lives in the **edge/tunnel graph** (where depth is
free) and the **FDC classification axis** (subject depth), not in the
containment table (where depth is expensive: recursive roll-up and recursive
scoped queries). An application needing an arbitrary-depth outline (e.g. a task
outliner) is supported without arbitrary containment: its items are flat drawers
under one wing and per-project rooms, and the outline is a typed parent edge
between those flat drawers. Ancestor-dependent computation walks the parent edge
as a sequence of point lookups (optionally accelerated by a denormalized
materialized path recomputed on the rare reparent), not a recursive subtree
scan. Depth lives in edges; containment stays four.

A first-class typed `parent`/outline edge (with an order key for sibling
ordering) is the clean primitive for such outlines, and it is built in this run
(mission NT-L5). The decision is deliberate: the Fulcrum-on-mootx01 case is the
proof that validated fixed-depth containment in the first place, and that proof
depends on the edge graph being able to express an ordered parent relationship
between flat drawers. Deferring the edge would leave the central architectural
argument of this ADR resting on a capability the substrate does not actually
have. The edge is a typed relation in the tunnel graph carrying a parent
reference and an order key; it does not touch the node schema. Building it now
closes the loop rather than asserting it.

VaultKit handles impedance with infinite-depth external trees (Obsidian, LLM
Wiki): on import the deepest folder maps to the room, the vault root to the
wing, middle folders concatenated into the room name with a path separator;
on export the wing/room path reconstructs the structure. Collision handling
follows §7 including the §5 no-resurrection guard.

### 12. Compatibility and lifecycle semantics

**Create:** Wings and rooms are created on demand at capture, or explicitly via
the estate management surface. The estate root and the ADR-016 default wings
(§13) are created at estate initialization.

**Rename:** Not supported in 1.0. No denormalized strings on drawers need
backfilling because none exist.

**Delete (erasure/withdrawal):** Erasing a container tombstones it (§5).
Cascade erasure (tombstone a wing and everything under it) is an explicit
operation on the erasure verb surface.

**Import collision:** Two imports targeting the same active wing/room name
resolve to the same active node. An import naming a tombstoned node mints a
fresh active node, never resurrecting the tombstoned one (§5).

### 13. Seeding: ADR-016 default wings as nodes (complements ADR-016)

ADR-016 establishes seven seeded default wings (Agentic Memory, User Canon,
Source Corpus, Personal, Professional, Projects, Temp), each self-documented by
a charter memory at a reserved `_charter` room. ADR-017 makes those wings and
rooms into node rows; the two decisions compose.

At estate initialization, after the root node is created:

1. Create a depth-1 active wing node under the root for each default wing.
2. Create a depth-2 active `_charter` room node under each wing.
3. Write each wing's charter as a drawer under its `_charter` room.

The seven defaults are a suggestion, not a constraint: the AI may create any
additional wing on demand through §7 and writes that wing's charter the same
way. `estate_map` surfaces each wing with its charter inline by reading the
`_charter` room's drawer (a tree walk under the node model). Charters travel
with their wing through vault export/import as ordinary drawers under ordinary
room nodes.

ADR-016 is complemented, not superseded: its provenance/role semantics,
seeding set, and charter mechanism all stand; ADR-017 changes only their storage
representation from string tags to node rows.

### 14. The FDC tree is separate

The FDC classification tree is a second, independent axis, not stored in
`nodes`. It is derived from per-drawer lattice anchors (`udcCode`,
`wikidataQID`) through EideticLib/LatticeLib. It is variable-depth and read-only
from the substrate's perspective. Containment answers "where does this live";
classification answers "what is this about"; a consumer can slice either axis or
combine them. A future materialization of the FDC tree as navigable structure is
deferred; the `nodes` table (depth-limited 0/1/2) does not accommodate FDC
codes, which would use a separate `fdc_nodes` table.

### 15. Snapshots: copy-on-write over the skeleton, payload by reference

The estate gains ZFS-inspired point-in-time snapshots. The mechanism rests on a
single principle: a drawer has two layers, and they are treated differently.

- The **skeleton** (node and drawer rows, lineage, state, bitmaps, parent,
  timestamps, audit trail) is copy-on-write, append-only, HLC-stamped,
  snapshot-retained, and GC-pinned.
- The **payload** (drawer content text and vectors) is referenced, not copied
  into a snapshot, and is recoverable for the past through the existing
  append-and-supersede lineage.

A snapshot is therefore not a data copy. It is:

1. A **snapshot registry** row: `(snapshot_id, hlc, label, created_at)`, plus a
   **`snapshot_attestations`** table that stores the attested Merkle roots for the
   snapshot, keyed by subject:
   ```
   snapshot_attestations
     snapshot_id   TEXT NOT NULL    -- FK → snapshot registry
     subject_kind  TEXT NOT NULL    -- 'estate' | 'wing' | 'corpus'
     subject_id    TEXT NOT NULL    -- node id (estate/wing) or corpus id
     merkle_root   TEXT NOT NULL    -- root hash attested at snapshot time
     key_version   INT  NULLABLE    -- HMAC key version if commitment-bearing (§17)
     PRIMARY KEY (snapshot_id, subject_kind, subject_id)
   ```
   The registry records *when*; the attestations record *what the roots were* at
   that HLC. §17's "old snapshot attested roots are retained" lives here. The
   registry is keyed on the same HLC watermark the incremental-replication cursor
   uses.
2. An **as-of read filter** on the RowStore query surface: "rows active as of
   HLC T," evaluated in HLC space against `created_hlc`/`tombstoned_hlc` for nodes
   and the lineage HLCs for drawers (never against wall-clock columns). Past
   content resolves to the lineage version active at T; present reads resolve to
   the head.
3. A **GC pin**: the maintenance daemon and dream-aging may not physically vacuum
   any skeleton row (tombstone, superseded lineage version) older than the oldest
   live snapshot references. The pin protects the skeleton only.

Snapshot reads, taken against a pinned immutable as-of view, are safely
cacheable (§18). These are generic storage-contract capabilities: PersistenceKit
knows nothing about wings or drawers; LocusKit supplies the snapshot verbs and
CorpusKit supplies corpus snapshots over the same primitive.

**Replication is a conformance requirement, not an assumption.** A snapshot
(registry row + its `snapshot_attestations` rows) and the skeleton rows it pins
must replicate atomically as a unit. This is *not* assumed to fall out of the
existing HLC cursor for free: the StorageObserver delivery contract differs per
backend (the InMemory observer is an `mpsc` channel hub; SQLite has its own
observer registry; the ConvergenceKit engines yield to subscriber/continuation
lists), so per-backend timing and ordering must be proven. NT-P3 carries an
explicit conformance test for atomic registry-plus-attestations-plus-pinned-rows
replication across all three backends. A prior package audit found Swift
InMemory observer timing drift; the live observer tree is re-checked as part of
NT-P3 rather than trusted.

### 16. Merkle content-integrity: per-wing and per-estate roots

The estate gains content-addressed integrity, the property ZFS has that the
substrate lacked. This is distinct from SimHash (similarity); it is
tamper-evidence and bit-rot detection.

- Each payload (drawer content + vectors) gets a content hash on write, computed
  with SubstrateLib's existing SHA256, conformance-gated byte-identical across
  Swift scalar, Swift Metal, Rust scalar, and Rust NEON.
- The hash rolls up the containment chain: a room node's hash summarizes its
  drawers' hashes, a wing node's hash summarizes its rooms, the estate carries
  one root. **Per-wing roots and the per-estate root both persist** in
  `nodes.merkle_root`. The wing hash is an intermediate value in the estate
  roll-up, so persisting it is one column and free to compute; building per-wing
  roots later would mean re-opening the roll-up and migrating the snapshot
  registry. Per-wing roots let a Fulcrum-style single-wing app verify or snapshot
  its wing without the whole estate.
- On read, a drawer's stored hash is checked against its content; a mismatch
  (bit-rot, bad write) is detectable rather than silently served.
- The roll-up rides the same StorageObserver up-chain invalidation as the cache
  and the replication dirty-set: a drawer write invalidates the room hash, then
  the wing hash, then the estate root. One invalidation mechanism, three
  consumers (cache, replication, Merkle).

The hash-on-write hook and the up-chain invalidation are generic PersistenceKit
primitives; the hash function is SubstrateLib; the meaning of the roll-up chain
(which aggregate is a room, which is a wing) is supplied by LocusKit (containment
chain) and independently by CorpusKit (its own source/chunk chain, per-corpus
root). The primitive is shared; the semantics are per-kit.

**Merkle determinism specification (required before NT-P2; conformance-gated).**
A hash that is not byte-deterministic across ports and backends turns the
four-way conformance test into a ghost hunt. The following are fixed and frozen:

- **Leaf payload bytes (v2, 2026-06-28).** A drawer's hashed payload is the
  canonical concatenation of: a domain-separation tag, the drawer id (16 bytes,
  big-endian UUID), the content bytes with a u64 big-endian length prefix, then
  the vectors. Vectors are sorted by (model_id ascending, vector_index ascending).
  Per-vector layout (v2): u32 BE model_id-length | model_id UTF-8 bytes | u32 BE
  vector_index | u32 BE float-count | IEEE-754 LE floats. A drawer with no vectors
  hashes only the u32 BE count prefix zero. The v2 layout writes vector identity
  (model_id + vector_index) into the preimage before the float payload, binding
  the vector's provenance to the hash. v1 used these fields only for sort order —
  a binding gap that allowed keyed commitments to accept vector substitutions
  without hash mismatch (security finding WS2-F4). The exact per-vector field
  order and prefix widths are pinned in the conformance vectors; v2 cross-port
  pin: cb18e8a5dcff4eb955f731bf75c078b9390a175ff225cc67a1ff0f1d3fa192dc (SHA-256
  of domain=0x00, drawer=12345678-1234-1234-1234-123456789abc, content="hello",
  one vector model-a/idx=0/[1.0f, 2.0f]).
- **Child ordering.** An interior node hashes its children's hashes concatenated
  in ascending child-id order (lexicographic over the 16-byte UUID), never
  insertion order. This makes the roll-up independent of write order.
- **Domain separation.** Leaf hashes, interior (node) hashes, and tombstone
  hashes each carry a distinct one-byte domain tag prepended before hashing, so a
  leaf hash can never collide with or be substituted for an interior hash.
- **Tombstone hash.** An expunged payload's leaf hash is a fixed tombstone hash:
  the tombstone domain tag followed by the drawer id, and nothing else (no
  content, no vectors — they are destroyed). This is what re-roots the live tree
  after expunge (§17) and is identical across ports.
- **Hash function.** SubstrateLib SHA256, the existing implementation, with the
  four-way conformance gate (Swift scalar, Swift Metal, Rust scalar, Rust NEON)
  applied to the full leaf-and-rollup pipeline, not just the raw hash, against
  canonical vectors on the shared seed.

The keyed commitment (§17) uses HMAC-SHA256 over the same canonical leaf payload
bytes, so a commitment and a content hash are computed from one byte encoding.

### 17. Erasure under temporal travel: the expunge / snapshot resolution

Expunge (content destruction, legally required) and snapshots (history
retention) are in direct tension only if content and structure are the same
object. They are not. The two-layer split (§15) resolves it, giving three
operations with three temporal behaviors:

- **Ordinary edit** is append-and-supersede. The old lineage row keeps its
  content. Temporal travel works for edits: an as-of-T read resolves to the
  lineage version active at T.
- **Withdraw** is a skeleton operation: state → Withdrawn, content retained,
  recall-excluded. Snapshots before and after both see the content; they differ
  only in state.
- **Expunge** is the one operation that reaches across every snapshot and every
  version to destroy the payload, by design. It scrubs content and fail-closed
  deletes the vectors, sets Tombstoned and `tombstoned_at`. The skeleton and the
  audit trail survive in all temporal views; the payload is gone in all temporal
  views. A snapshot of last month still shows that a drawer existed and was
  later expunged, never its content.

**Expunge MUST be lineage-wide.** It scrubs the content and deletes the vectors
of every version in the lineage chain, not only the head, so no past snapshot can
resurface destroyed payload. **This is a confirmed gap in the current
implementation, not an open question.** `expunge_gated` (drawer store, all three
backends) tombstones a single drawer id and scrubs only that one row's content
via a `WHERE id = ?` update; it does not walk the lineage chain. Today, without
snapshots, a superseded predecessor retaining its content is latent. The moment
NT-P1 ships the as-of read filter, an as-of-T read can resolve to a superseded
lineage row whose content was never scrubbed, resurfacing legally-destroyed
payload — a live data-governance defect. NT-L4 therefore carries a hard
requirement: expunge walks the lineage chain and scrubs content plus deletes
vectors for every version, and a conformance test proves a superseded
predecessor's content is empty after expunge, on all three backends.

**Erasure is a global overlay, applied outside normal temporal filtering.**
Lineage-wide scrubbing is the destruction mechanism; the overlay is the read-time
guarantee that makes destruction impossible to bypass through any temporal path.
Every read — present or as-of-T — is two-phase:

1. **As-of row selection.** Select the rows active at the requested HLC
   (present, or snapshot T) by the normal temporal filter.
2. **Global erasure overlay (fail-closed).** Apply an estate-scoped erasure
   ledger over the selected rows' payloads. Any drawer (by id, across all
   lineage versions) recorded in the erasure ledger returns with its payload
   nulled, regardless of which temporal version was selected. The overlay runs
   after selection and cannot be skipped; a read path that selects a row whose id
   is in the erasure ledger and returns its content is a fail-closed violation,
   not a silent fallthrough.

The two together are belt and suspenders for the data-destruction obligation:
lineage-wide scrub destroys the bytes at rest; the overlay guarantees that even
if a byte survived somewhere (a backend quirk, a not-yet-vacuumed page, a
replication lag window), no temporal read can surface it. The erasure ledger is a
grow-only, HLC-stamped table; it is itself skeleton (it records *that* an id was
erased, never the content) and is GC-pinned and replicated like other skeleton.

**ZFS divergence (stated explicitly):** ZFS has no expunge — it chose
immutability over erasure and cannot destroy a block a snapshot references.
mootx01 has a data-destruction obligation ZFS lacks, so it inherits ZFS's
temporal model for the skeleton and *adds* an erasure primitive on the
referenced payload layer that ZFS deliberately cannot provide. This is the
one place mootx01 departs from the ZFS model, and it does so deliberately.

**Merkle interaction:** expunge replaces a destroyed payload's leaf hash with the
fixed tombstone hash (§16) and re-roots the live estate. The old snapshot's
attested root, stored in `snapshot_attestations` (§15), is retained as a
historical attestation; it is not re-derived from current content (the content is
gone, and re-derivation would require retaining what was destroyed). Integrity
verification therefore checks the *live* estate against the *live* root; the
*history* of destructive operations is attested by the audit chain. You never
Merkle-verify destroyed content.

**Provenance and key lifecycle (decided knob).** The audit entry for an expunge
retains a **keyed commitment** — HMAC-SHA256 over the canonical leaf payload
bytes (§16), keyed by an estate-held secret — not the raw prior hash, so
tamper-evidence survives without retaining a reversible fingerprint of destroyed
personal data. The keyed-commitment entry kind is added to SubstrateLib's
grow-only audit log. The key lifecycle is specified, not left implicit:

- **Location.** The HMAC key is estate-scoped and lives in the existing estate
  key store (the same store grants and scope keys use). It is not per-drawer and
  not global.
- **Replication.** The key does **not** leave the estate and is not replicated to
  peers as cleartext; a federated peer receives the commitments and the
  `key_version`, not the key. A peer can verify a commitment only if it has been
  granted the key through the normal key-custody path, never automatically.
- **Rotation.** Rotation mints a new key version. Commitments are tagged with the
  `key_version` that wrote them (carried in `snapshot_attestations.key_version`
  and on the audit entry); past commitments stay bound to their writing version,
  so rotation never invalidates prior tamper-evidence.
- **Loss.** If a key version is lost, commitments written under it become
  unverifiable, but the **fact** of erasure survives independently in the
  grow-only audit log and the erasure ledger. The commitment is a tamper-evidence
  enhancement on top of the erasure record, never the erasure record itself —
  losing the key weakens proof, it does not resurrect content or erase the
  audit fact.

**GC pin interaction:** the pin (§15) protects skeleton rows from automatic
vacuum so snapshots stay coherent. Expunge operates on the payload layer, not the
skeleton row, so it does not conflict with the pin: the pin keeps the structural
row alive for the snapshot; expunge has already nulled the content that row
points to. Both hold simultaneously.

### 18. Backend orthogonality and cache temporal-awareness

**Backend orthogonality.** Every capability in §§5–17 is defined against the
`Storage`/`RowStore`/`BlobStore`/`AuditLog` contract and implemented with full
fidelity on InMemory, SQLite, and PostgreSQL, conformance-gated. InMemory is a
first-class deployment target for applications that run wholly in RAM, not a
test double. PersistenceKit is the orthogonal center; LocusKit, CorpusKit, and
every consumer stand on identical primitives, so RAM, SQLite, and PostgreSQL
behave identically for snapshots, Merkle, and erasure.

**Cache temporal-awareness.** `CachingRowStore` is an LRU decorator driven by
StorageObserver invalidation; the transaction-context row store is deliberately
not wrapped (caching uncommitted reads is wrong). Two rules are added:

1. The cache key incorporates the read's temporal coordinate (present, or a
   snapshot HLC), so a snapshot read and a present read of the same row are
   distinct entries. Snapshot reads against a pinned immutable as-of view are
   safely cacheable.
2. A node's Merkle hash is a cached aggregate; a drawer write invalidates the
   hash up the parent chain (room → wing → estate root) through the same
   StorageObserver invalidation. Roll-up and cache invalidation are one
   mechanism.

### 19. CorpusKit as a first-class peer

CorpusKit is independently consumable via the SDK (its own `ingest` and
`remove(sourceID:)`, its own append-only BundleStore, its own BM25 and
VectorStore). A CorpusKit-only user must receive Merkle integrity, snapshots,
and true erasure equally. Because those are PersistenceKit/SubstrateLib
primitives (not LocusKit features), CorpusKit inherits them by adopting the same
primitives: its BundleStore and `remove` route through the hash-on-write hook,
the as-of filter, the snapshot registry, and the keyed-commitment destruction
mechanics; it carries a per-corpus Merkle root and supports corpus snapshots.
This is its own mission track, parallel to LocusKit's, both standing on the
PersistenceKit layer. The cost (CorpusKit adopting the primitives) is real but is
strictly less than building Merkle and snapshots twice with implementations that
drift.

## Supersedes

`DECISION_LOCUSKIT_BUNDLE_HIERARCHY_2026-05-20.md` is superseded. It ratified the
flat model; this ADR reverses that: wings and rooms become first-class node
entities in a stored containment tree. The bundle-hierarchy storage design
(count-vectors keyed by wing and room) is preserved in substance; only the key
type changes from string composites to node-ID references.

`ADR-016-wings-provenance-role-axis.md` is complemented, not superseded (§13).

## Consequences

- The containment tree exists in storage; the substrate owns its structure and
  traverses it without host assistance.
- Wings and rooms are real entities with IDs, HLC-versioned lifecycle
  (`created_hlc`/`tombstoned_hlc`), Merkle root, display/lookup names, and
  extension slots.
- No legacy string columns; `parent_node_id` is the only containment reference.
- Erased containers cannot be silently resurrected (§5). Erased content cannot be
  resurrected from a past snapshot (lineage-wide expunge, §17).
- Recall scoping is gate-safe (I-NT-6) and more canonical (node-ID index lookups
  instead of string hash-map walks); whether it is faster is measured at the
  read-path mission, not asserted.
- The estate has point-in-time snapshots, a capability no markdown-file or
  flat-pool competitor has — the differentiating wedge for an AI memory product.
- The estate has content-integrity verification (bit-rot and tamper detection),
  with per-wing and per-estate roots.
- Expunge satisfies data-destruction obligations without defeating temporal
  travel for non-erased content; the ZFS divergence is deliberate and stated.
- CorpusKit is a first-class peer; a CorpusKit-only SDK user gets snapshots,
  Merkle, and erasure.
- Every capability runs identically on InMemory, SQLite, and PostgreSQL; an app
  can run wholly in RAM.
- ADR-016 composes cleanly; seeded wings and charters become nodes at init.
- The ARIA API stays backward-compatible; wing/room names remain valid string
  arguments, resolved to node IDs internally.
- Blast radius is mechanical, not architectural. Every `WHERE wing=? AND room=?`
  predicate becomes a `parent_node_id` join. Every test constructing drawers with
  string wings/rooms updates to resolve through the node store — a large but
  mechanical test-code change, mitigated by a shared test helper. The math
  (bitmaps, fingerprints, matrices, vectors) is untouched. The new write-path
  costs (node resolution, content hashing, roll-up) are absorbed by QueueKit.

## Implementation plan

The family is layered strictly bottom-up, matching the canonical kit stack
(TOPOLOGY.md): the storage-contract primitives land first, then the two
standalone-substrate consumers in parallel, then composition, then the remaining
consumers, then cleanup. Every mission records the full baseline test count of
both ports at start; no compatibility shim reconstructing `wing`/`room` strings
is permitted in any diff; the shared test-skeleton helper is used by all
tree-touching missions; resolution and conformance logic live in the shared core.

**Layer 0 (design lock):** This ADR.

**Layer 1 — Foundation primitives (serial):**
- NT-F1: SubstrateTypes — snapshot-id / as-of coordinate value type; confirm HLC
  and RowState carry everything snapshots and lineage need. Both ports.
- NT-F2: SubstrateLib — keyed-commitment audit entry kind on the grow-only audit
  log; confirm SHA256 is exposed for the hash-on-write hook with four-way
  conformance. Both ports.

**Layer 2 — PersistenceKit primitives (serial; the orthogonal center):**
- NT-P1: HLC append-and-supersede write mode as a first-class storage behavior;
  as-of read filter on the RowStore query surface (HLC-space selection over
  `created_hlc`/`tombstoned_hlc` and lineage HLCs). All three backends,
  conformance-gated. **The as-of read surface ships feature-gated OFF and stays
  off until NT-L4 lands** (see sequencing constraint below).
- NT-P2: content-hash-on-write hook with up-chain aggregate invalidation via
  StorageObserver (generic; no kit semantics). The Merkle determinism spec (§16)
  is implemented and conformance-gated here: canonical leaf bytes, child
  ordering, domain separation, tombstone hash. All three backends.
- NT-P3: snapshot registry + `snapshot_attestations` table + GC pin; erasure
  ledger (grow-only, HLC-stamped) and the global erasure overlay (§17, two-phase
  fail-closed read); keyed-commitment destruction mechanics with key-version
  tagging. **Atomic registry-plus-attestations-plus-pinned-rows replication is
  conformance-tested across all three backends** (the observer delivery contract
  differs per backend; re-check the live observer tree, do not assume). All three
  backends.
- NT-P4: cache temporal-awareness (temporal cache key incorporating the read's
  HLC coordinate; Merkle-aggregate invalidation edge). All three backends.

**Sequencing constraint (hard):** the NT-P1 as-of read surface must not become
callable before NT-L4 lineage-wide expunge and the NT-P3 global erasure overlay
are in place, or the run ships the exact governance defect this ADR identifies
(an as-of read resurfacing un-erased payload). Enforce by one of: (a) a single
integration train that lands NT-P1's as-of surface, NT-P3's overlay, and NT-L4
together before the surface is enabled; or (b) the as-of surface stays
feature-gated off (NT-P1) until both NT-P3 and NT-L4 merge. Nagatha treats any
mission that enables as-of reads ahead of NT-L4 as a blocked prerequisite, not a
mergeable change.

**Layer 3 — Standalone substrate, two PARALLEL tracks on Layer 2:**

LocusKit track (serial within track):
- NT-L1: Node entity (HLC-versioned lifecycle: `created_hlc`/`tombstoned_hlc`;
  `display_name`/`lookup_name` split; `merkle_root`), `nodes` table, NodeStore,
  CRUD, tree navigation, active-only create-on-demand resolution keyed on
  `lookup_name` with the no-resurrection guard, shared test-skeleton helper. Both
  ports.
- NT-L2: Drawer schema change — remove `wing`/`room`, add `parent_node_id NOT
  NULL`; capture-path resolution (§7). Both ports.
- NT-L3: Read-path queries join through `parent_node_id`;
  `container_fingerprints` and `node_bundles` rekeyed to node IDs;
  per-wing/per-estate Merkle roll-up wired into the NT-P2 hook; recall
  performance baseline. Both ports.
- NT-L4: Lineage-wide expunge (walk the lineage chain; scrub content and delete
  vectors for every version; conformance test proving a superseded predecessor's
  content is empty post-expunge, all three backends); snapshot verbs over the
  NT-P3 registry. Both ports.
- NT-L5: Typed `parent`/outline edge in the tunnel graph (parent reference +
  order key for sibling ordering); does not touch the node schema; the primitive
  the Fulcrum-on-mootx01 outline depends on (§11). Both ports.

CorpusKit track (parallel to LocusKit track, serial within):
- NT-C1: BundleStore + `remove` adopt the NT-P1/P2/P3 primitives (as-of filter,
  hash-on-write, keyed-commitment destruction). Both ports.
- NT-C2: per-corpus Merkle root; corpus snapshots over the NT-P3 registry. Both
  ports.

**Layer 4 — Composition (serial after Layer 3):**
- NT-G1: GeniusLocusKit — VerbSurface/EstateCoordinator updated for node IDs;
  node-scoped recall with I-NT-6; estate-init seeding of ADR-016 wings/charters
  as nodes (§13); cross-kit expunge confirmed lineage-wide across LocusKit and
  CorpusKit. Both ports.
- NT-G2: RecallDirector node integration; substrate-native NodeTopologyProvider;
  grant scope migration; snapshot/Merkle exposure through the verb surface. Both
  ports.

**Layer 5 — Consumers (parallel after Layer 4):**
- NT-N1: NeuronKit — dreaming/maintenance adapters; maintenance-daemon
  verification of node invariants (I-NT-1..6) and Merkle-root consistency; GC-pin
  enforcement in dream-aging.
- NT-K1: CognitionKit recipes (Consolidate, DistilledRecall, ExpandMemory,
  ShapedRecall, ExploratoryRecall).
- NT-K2: CognitionKit lenses (Complexity, Drift, Bias, LatentThemes,
  FormalConcepts, EstateDivergence, Constellation, Keystones).
- NT-A1: AriaMcpKit — tool dispatch, string-to-node-ID resolution at the MCP
  boundary, snapshot/Merkle tool descriptors.
- NT-V1: VaultKit — import/export mapping through the node tree, including the §5
  no-resurrection guard at the import boundary.

**Layer 6 (cleanup, serial):**
- NT-Z1: Final parity sweep, test coverage audit, dead code removal,
  Merkle/snapshot conformance-vector audit across all backends.

## Findings carried into the missions

The design questions are resolved (v1.4 closed the six storage-contract gaps an
independent review identified). What remains are facts the missions must honor,
not decisions to make.

- **Lineage-wide expunge is a confirmed gap (§17), fixed in NT-L4.**
  `expunge_gated` scrubs only the head row's content; it must walk the lineage
  chain. Stated as a hard NT-L4 requirement with a conformance test, on all
  three backends.
- **The typed parent/outline edge is built in NT-L5 (§11).** Decided, not
  deferred: the Fulcrum-on-mootx01 proof that validated fixed-depth containment
  depends on it.
- **FDC "LatticeKit" vs "LatticeLib" vocabulary drift is reassigned to the
  documentation custodian (Nagatha), out of ADR scope.** It is a canon
  vocabulary fix between a diagram and prose; it gates nothing in this run and is
  handled as a custodian task during run setup, not as a design item.

## Changelog

- 1.0.0 (2026-06-20): Initial decision. Containment tree restored as a
  first-class node hierarchy. Fixed-depth, strict containment, positional node
  typing. FDC tree separate. Supersedes the 2026-05-20 bundle hierarchy.
- 1.1.0 (2026-06-20): Code-review amendments. Invariants I-NT-1..5; name
  normalization; concurrent create-on-demand contract; legacy string columns
  removed; container-vs-leaf split; lifecycle section; performance claims
  softened; NT-02 split; VaultKit import collision handling.
- 1.2.0 (2026-06-20): Team-review amendments (three conditions). §13 ADR-016
  reconciliation (seeded wings/charters as nodes; complemented not superseded);
  §5 node lifecycle + no-resurrection guard; I-NT-6 gate-ordering invariant.
  Baseline-count requirement, shared test-skeleton helper, shared-core
  conformance-gated resolution, no-shim rule recorded.
- 1.3.0 (2026-06-20): Scope expansion — three storage capabilities folded in to
  be built in the same pass, because each is a write- or read-path property that
  cannot be added later without re-opening the schema. Added: §15 ZFS-inspired
  copy-on-write snapshots (registry, as-of filter, GC pin); §16 Merkle
  content-integrity with per-wing and per-estate roots; §17 lineage-wide expunge
  with keyed-commitment provenance and the explicit ZFS divergence; §18 backend
  orthogonality (InMemory first-class) and cache temporal-awareness; §19 CorpusKit
  as a first-class peer. Added the mission-header layer map with the two hard
  rules (no primitive leaves its layer; no capability is single-backend). Added
  HLC and merkle_root columns to the nodes table (§2). Re-layered the
  implementation plan PersistenceKit-first (Layers 1–2 foundation/storage
  primitives; Layer 3 two parallel substrate tracks LocusKit and CorpusKit;
  Layers 4–6 composition, consumers, cleanup). Decided knobs: keyed-commitment
  expunge provenance; per-wing and per-estate Merkle roots from the start.
  Recorded open items: typed parent edge, lineage-wide expunge verification, FDC
  vocabulary reconciliation. Confirmed against the v1.1 topology SVG: layer order,
  CorpusKit-as-peer, and InMemory-as-first-class-backend all match the canonical
  diagram. Closed all three open items: lineage-wide expunge confirmed as a gap
  in `expunge_gated` (single-row scrub, no lineage walk) and made a hard NT-L4
  requirement; typed parent/outline edge decided as NT-L5 (the Fulcrum proof
  depends on it); FDC vocabulary drift reassigned to the documentation custodian.
  The ADR now carries no open design questions.
- 1.4.0 (2026-06-20): Independent-review (Codex) amendments — six storage-contract
  details tightened, one claim downgraded to a conformance requirement, one
  sequencing gate added. (1) HLC-versioned node lifecycle: `created_hlc` +
  `tombstoned_hlc` replace single creation HLC + wall-clock tombstone, so the
  as-of filter decides node activity in HLC space (§2, §5). (2)
  `snapshot_attestations` table added to store attested Merkle roots per
  snapshot/subject; §17's retained roots now have a home (§15). (3) Merkle
  determinism specification added: canonical leaf bytes, vector encoding, child
  ordering, domain separation, tombstone hash format, frozen and conformance-gated
  (§16). (4) Global erasure overlay added: every as-of read is two-phase
  (temporal selection, then fail-closed erasure-ledger overlay over payloads), so
  no temporal path can resurface destroyed content even if a byte survived; the
  lineage-wide scrub remains the destruction mechanism (§17). (5) Display vs
  lookup name: `display_name` + normalized `lookup_name`; resolution and
  uniqueness use the lookup key (§2, §8, I-NT-1/4, §7). (6) Keyed-commitment key
  lifecycle specified: location (estate key store), non-replication, rotation via
  key-version tagging, loss semantics (audit fact survives; only proof weakens)
  (§17). (7) ConvergenceKit snapshot replication downgraded from assumption to a
  per-backend conformance requirement (atomic registry+attestations+pinned-rows;
  observer delivery differs per backend; re-check the live tree) (§15, NT-P3).
  Mission plan: hard sequencing constraint — the as-of read surface ships gated
  off and stays off until NT-L4 (lineage-wide expunge) and NT-P3 (erasure overlay)
  land. Updated NT-P1/P2/P3 and NT-L1 scopes accordingly.
- 1.5.0 (2026-06-28): Security-fix amendments (WS2 findings). (1) §16 leaf
  payload bytes upgraded to v2 encoding: per-vector layout now writes model_id
  (u32 BE length + UTF-8 bytes) and vector_index (u32 BE) into the preimage
  BEFORE the float payload, binding vector provenance to the hash. v1 used these
  fields only for sort order — a binding gap that allowed keyed-commitment vector
  substitution (WS2-F4). Cross-port conformance pin:
  cb18e8a5dcff4eb955f731bf75c078b9390a175ff225cc67a1ff0f1d3fa192dc. (2) §16
  snapshot completeness: computeRoomMerkleRoot now excludes withdrawn drawers
  (state 18, bits 0-5 of adjectiveBitmap, mask 0x3F) as well as tombstoned ones
  (WS2-F1). (3) Expunge rollup completeness: lineage-wide expunge now rolls up
  ALL rooms containing any lineage member, not just the initiating drawer's room
  (WS2-F2). (4) CorpusKit open-time backfill: recomputeAllCorpusMerkleRoots
  called on every Corpus init so pre-v3 corpora get their first corpus_metadata
  row without waiting for the next insert (WS2-F3). (5) Withdraw matrix fix:
  withdraw verb now updates MatrixF and MatrixO with the state delta, matching
  the mutate/expunge pattern (WS2-F5).
