---
status: draft
authors: Bob Pankratz (via/ claude)
date: 2026-05-06
supersedes: nothing — this is the founding Loci document
relates_to:
  - docs/concepts/MOOTX01_SPEC.md
  - GeniusLocusKit/README.md (shipped via TASK-NEX-2026-0008/0009)
scope: Nexus product line, ARIA_MCP standalone deployment
review_cycle: morning review by Bob, then revise → /draft revisions → mission authoring
---

# Loci Mode — Product Specification (v0.1 draft)

## 0. Document purpose

This document specifies **Loci Mode** of ARIA_MCP — the standalone, AI-support-only deployment of the Genius Locus memory engine. Loci Mode is the drop-in MemPalace replacement that ships first; **Genius Mode** (full Simple Machines integration with FNode anchoring) is a separate spec authored later when Fulcrum integration begins.

The reader's expected goal is to understand the full Loci product top to bottom — what it is, what it ships in each rev, what its data model and API look like, how it preserves MemPalace's design pillars, how it beats MemPalace's performance honestly, what the open questions are, and which Bilby missions decompose from this spec.

This is a draft for Bob's morning review. After review and any revisions, individual Bilby missions will be authored from §16's mission decomposition.

---

## 1. Executive summary

**Loci Mode** is a standalone macOS command-line tool that exposes a Model Context Protocol (MCP) server over stdio. AI harnesses — Claude Desktop, Claude Code, any MCP-aware agent — connect to it as a memory backend. It indexes content the user feeds it (initially: directory walks of code repos and arbitrary files) and answers semantic search and knowledge-graph queries.

The tool ships from the existing `nexus` repository as a Swift binary built on top of the existing `GeniusLocusKit` package (shipped via TASK-NEX-2026-0008/0009), a not-yet-merged `CorpusKit` vector storage package, a new `LociKit` package that adds the MemPalace surface (drawers, wings, rooms, tunnels, diary), and a new `nexus-mcp` executable target that wires those layers to the MCP protocol.

**Rev 1.0 ships:** macOS binary, drop-in MemPalace replacement, three pluggable embedding providers (MiniLM compatibility, mpnet alternative, **EmbeddingGemma 300M as production default**), directory-walking ingest, hybrid re-rank with hierarchy-as-boost, a master-key capability model with read-only external access, a benchmark harness using AAAK as a comparison side-track. No iCloud sync. No iOS. No public write access.

**Deferred to later revs:** soft-delete cascade machinery (Rev 2.0), iCloud sync via CKSyncEngine (Rev 2.x), iOS variant (Rev 3.0), domain-based security (Rev 3.x), Apple-system-shipped embedding model post-WWDC June 2026 (Rev 2.x).

The architecture is grounded in three findings from the scope-mode session that preceded this draft:

1. **MemPalace's 96.6% LongMemEval-S score is the ChromaDB-defaults score**, not a MemPalace-architecture-specific number, per their own issue #214. We can match it with any reasonable bi-encoder + verbatim storage. We can exceed it with a better encoder + better chunking + hierarchy-as-boost without violating MemPalace's design pillars or cheating the benchmark.
2. **MemPalace's three-backend storage split (ChromaDB + SQLite + tunnels.json)** was a Python-stack pragmatism choice honoring their "two-dependency promise." Apple's stack lets us collapse to a single SQLite file with sqlite-vec without violating any design pillar.
3. **Hierarchy as a hard `WHERE` filter hurts recall** (binary cliff on wrong room prediction). Hierarchy as a soft re-rank boost mathematically cannot hurt recall vs no-hierarchy and often helps. We do the latter.

---

## 2. Identity and positioning

### 2.1 Two ARIA_MCP modes

ARIA_MCP is a single binary that operates in one of two modes, locked at startup by configuration:

- **Genius Mode** — full Simple Machines integration. Knows about FNodes, anchors entities to the FNode tree, exposes the brain to Fulcrum, Inclined, and Nexus apps via App Group + shared CloudKit container. AI Assist (Apple Foundation Models) is wired in. Internal apps have RW master access; external MCP clients have whatever cap-key the user issues. Not the subject of this spec.
- **Loci Mode** — standalone Apple ecosystem memory product. No FNode awareness, no Simple Machines integration. Drop-in MemPalace replacement plus the wins available to a Swift/Apple stack reimplementation. Subject of this spec.

The names trace to the product brand. *Genius locus* is a Latin tag for the spirit of a place — the full integration carries the whole spirit. *Loci* alone are the sites of memory in the classical mnemonic tradition — the standalone product is the memory system without the place that authored it. Both modes use the same `GeniusLocusKit` engine; the mode is a startup configuration that selects which surface and which storage shape the binary exposes.

### 2.2 Positioning vs MemPalace

Loci Mode is a faithful port of MemPalace plus the wins available to an Apple-native rewrite. Faithfulness means:

- All MemPalace concepts must exist in Loci: Drawer, Wing, Room, Tunnel, Diary, KG entity, KG triple. None are dropped. AAAK compression is preserved as an opt-in benchmark harness, not as a search mode (more in §13).
- The default search behavior matches what MemPalace's "raw mode" does — verbatim drawers, semantic embedding, BM25 hybrid re-rank — so a user pointed at a Loci server should not feel a behavior gap from a MemPalace server.
- The MCP tool surface adopts standard verb patterns (search, status, get, list, query, add, invalidate) from programming conventions, RDF semantics, and information science. Tool names are designed for discoverability and consistency across operations.

The wins beyond faithfulness:

- **Single SQLite file** with sqlite-vec virtual tables instead of three storage backends — Apple stack lets us collapse without breaking design pillars (§4 and §10).
- **CoreML/Metal embeddings** on the Neural Engine — same model weights, hardware-accelerated, ~5–15× faster ingest (§6 and §13).
- **In-process actor** when called as a library (Genius Mode case) — microsecond dispatch instead of Python subprocess startup. Loci Mode itself is still a separate process binary (Claude Desktop pattern).
- **Multi-threaded HNSW** — MemPalace pinned `hnsw:num_threads=1` because of a `hnswlib` SIGSEGV on macOS ARM. Our stack doesn't have that bug.
- **Hierarchy-as-boost** instead of hierarchy-as-filter (§8) — measurable recall improvement instead of regression.
- **Pluggable embedding providers** with per-row `modelID` tagging (§6) — accommodates Apple's June release of system-shipped models without redesign.

### 2.3 The five MemPalace design pillars (preserved)

These are the architectural commitments inherited from MemPalace verbatim. Loci Mode does not violate any of them.

1. **Verbatim-first storage.** Raw text goes in. No LLM at write time. No extraction. No summarization. The system stores everything verbatim and lets semantic search surface it later. Zero token cost on the write path. The peer-reviewed result is that this beats extraction-based competitors (Mem0 ~49%, Zep ~85%) at 96.6% R@5 on LongMemEval-S. We do not deviate from this.
2. **Spatial metaphor for users, not algorithms.** Wing → Hall → Room → Closet → Drawer is a mnemonic — Method of Loci. The hierarchy is interface design, not algorithm design. Loci preserves the metaphor for users while using it correctly inside the algorithm (boost, never filter).
3. **Layered loading (L0–L3).** L0 identity (~100 tokens, plain text), L1 essential story (~500–800), L2 on-demand by topic, L3 deep search. Boot cost ~170 tokens. Loci preserves these layers as separate retrieval entry points with cached L1 generation (one of the honest performance wins).
4. **Two-dependency-spirit.** The original "ChromaDB + PyYAML" promise was a Python-stack constraint. The Apple-stack equivalent is "ship without third-party packages where reasonable." We use system SQLite, sqlite-vec as one Swift Package, CoreML and Metal as system frameworks. Direct dependencies stay minimal (§4.4). This honors the spirit of the pillar even though the specific number changes.
5. **Local-first.** Nothing leaves the user's machine. No API keys. No telemetry. Models run locally via CoreML. The user can `cp -r ~/Library/Application\ Support/Loci/` and have a complete backup. The iCloud sync (Rev 2.x) is opt-in and respects this — it goes to the user's iCloud, not ours.

---

## 3. Reference architecture

### 3.1 The four-layer stack

```
┌──────────────────────────────────────────────────────────────┐
│ nexus-mcp (executable)                                       │
│   stdio MCP server — speaks Model Context Protocol           │
│   capability key gating                                      │
│   handler → LociKit dispatch                                 │
└────────────────┬─────────────────────────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────────────────────────┐
│ ARIA_MCP (library) — APP COORDINATION                        │
│   AI provider abstraction (BYOAI for Genius Mode)            │
│   MCP server library code (used by both nexus-mcp binary     │
│       and Nexus app's inbound-MCP feature in Genius Mode)    │
│   Capability key model                                       │
└────────────────┬─────────────────────────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────────────────────────┐
│ LociKit (library) — MEMPALACE SURFACE                        │
│   Drawer / Wing / Room / Tunnel / Diary types                │
│   EmbeddingProvider protocol + 3 implementations             │
│   Search pipeline (hybrid re-rank + hierarchy boost)         │
│   Directory walker / miner                                   │
│   AAAK harness (benchmark target)                            │
└──────┬──────────────────────┬────────────────────────────────┘
       │                      │
       ▼                      ▼
┌──────────────────┐  ┌──────────────────────────────────────┐
│ GeniusLocusKit   │  │ CorpusKit                               │
│ (SHIPPED)        │  │ (NOT YET BUILT — RAG-1 mission)      │
│                  │  │                                      │
│ Entities + facts │  │ sqlite-vec backend                   │
│ Temporal queries │  │ Metal cosine compute                 │
│ Vanilla mode     │  │ Dimension-agnostic                   │
│ NodeTreeNative   │  │ Sidecar storage                      │
└──────────────────┘  └──────────────────────────────────────┘
                 │              │
                 ▼              ▼
        ┌─────────────────────────────────┐
        │ ~/Library/Application Support/  │
        │   Loci/store.sqlite              │
        │   ↳ KG tables (GLK)              │
        │   ↳ vec_embeddings (CorpusKit)      │
        │   ↳ drawers, tunnels, etc.(LociKit)│
        │ ~/Library/Application Support/  │
        │   Loci/identity.txt              │
        │ ~/Library/Application Support/  │
        │   Loci/config.json               │
        └─────────────────────────────────┘
```

### 3.2 What's already shipped

- **GeniusLocusKit** — Vanilla composition (entities + facts + temporal queries + single-hop reasoning) and NodeTreeNative composition (FNode anchoring + topology reasoning + multi-hop). Migration CLI (`migrate-from-mempalace`) imports MemPalace JSON exports of entities and facts. 98 tests passing as of develop @ 108753a. Apple Silicon, macOS 15 / iOS 18, zero external dependencies, system SQLite.

### 3.3 What this spec adds

- **CorpusKit** — vector storage layer. Builds against the existing `MISSION_RAG_1_RAGKIT.md` spec (already authored). Resurrects in Rev 1.0 (see §16 mission LOCI-3).
- **LociKit** — new Swift Package wrapping GeniusLocusKit + CorpusKit with MemPalace's drawer/wing/room/tunnel/diary surface, embedding provider abstraction, and search pipeline.
- **ARIA_MCP** — populated with the MCP server library code and capability key model. (The directory exists; no code yet.)
- **nexus-mcp executable** — new target, either inside `ARIA_MCP/Package.swift` or as a top-level Swift Package with ARIA_MCP as a dependency. Standalone binary that Claude Desktop invokes.

### 3.4 Why the layering this way

LociKit composes GeniusLocusKit and CorpusKit rather than inheriting either. Three reasons:

1. **GeniusLocusKit stays focused.** The KG side has its own value — Genius Mode uses it via NodeTreeNative anchoring against FNodes. Bolting drawers and embeddings into it would muddy the abstraction.
2. **CorpusKit stays generic.** Vector storage is a general-purpose primitive. Other Simple Machines apps may want to use CorpusKit for things that are not Loci's drawers (e.g., FNode content embeddings in Genius Mode). Keeping it separate preserves reuse.
3. **LociKit is the consolidation point.** The MemPalace surface is opinionated — it has specific table shapes for drawers, tunnels, diary entries, with specific reference relationships. Putting that opinion in its own kit means changes to the Loci shape don't ripple into the substrates.

ARIA_MCP hosts the MCP server because the MCP server is shared infrastructure — it's used by Loci Mode (this spec) and by Genius Mode's inbound-MCP feature (future spec). Both modes call into ARIA_MCP's MCP server code with different `LociKit` instances configured.

The standalone `nexus-mcp` binary is a thin wrapper: parse argv, load config, instantiate LociKit + ARIA_MCP, run the MCP loop. ~150 lines of Swift, mostly plumbing.

---

## 4. Data model

### 4.1 Storage shape — one SQLite file

The store lives at `~/Library/Application Support/Loci/store.sqlite`. A single file. Every Loci concern reads from and writes to this file. Three reasons:

1. **Atomic transactional cascades.** Recursive remove (Rev 2.0) needs to tombstone a drawer plus every triple citing it plus every tunnel referencing it in a single transaction. Three storage backends would require distributed two-phase commit coordination, adding complexity and coordination overhead. A single file enables atomic cascades with one `BEGIN` / `COMMIT`.
2. **Backup is `cp`.** User can copy the file. Done. No "did I get the WAL too?" ambiguity (we use journal_mode=WAL but the WAL collapses on close).
3. **iCloud sync via CKSyncEngine (Rev 2.x) is per-row.** Multiple files complicate sync. One file simplifies it.

The file layout inside the SQLite database is partitioned by table prefix:

```
Prefix:     Owned by:           Purpose:
  entities  GeniusLocusKit      KG entities (existing schema)
  facts     GeniusLocusKit      KG triples with temporal validity (existing)
  drawers   LociKit             verbatim atoms with embeddings (new)
  tunnels   LociKit             cross-domain links (new)
  diary     LociKit             per-agent journal entries (new)
  vec_*     CorpusKit + sqlite-vec virtual tables for vector indexing (new)
  meta      LociKit             store metadata, schema version (new)
```

Each owner kit is responsible for its own `CREATE TABLE IF NOT EXISTS` migrations. They coexist by table name; no cross-kit table modification. CorpusKit's `vec_*` tables are sqlite-vec virtual tables and live in the same database — sqlite-vec is designed for this.

### 4.2 Loci-owned table shapes (new in this spec)

Schema is descriptive here; the actual `CREATE TABLE` statements live in mission specs.

#### `drawers` — verbatim atoms

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PRIMARY KEY | UUID v4, generated at insert time |
| `content` | TEXT NOT NULL | verbatim chunk content, no transformation |
| `wing` | TEXT NOT NULL | metadata only — no FK, no separate wings table (per Q9 finding) |
| `room` | TEXT NOT NULL | metadata only — same rationale |
| `sourceFile` | TEXT | optional — origin file path for ingested content |
| `chunkIndex` | INTEGER | optional — position in source for re-ingest dedup |
| `addedBy` | TEXT NOT NULL | agent or process name that filed this drawer |
| `filedAt` | TEXT NOT NULL | ISO8601 fleet rule |
| `embeddingModelID` | TEXT NOT NULL | which model produced this drawer's vector — see §6 |
| `tombstonedAt` | TEXT | NULL when alive, ISO8601 when soft-deleted (Rev 2.0+) |
| `removedByBatch` | TEXT | batch UUID for receipt-based rollback (Rev 2.0+) |

The drawer's vector lives in a sqlite-vec virtual table keyed by `id`. Same database file. Joined at query time.

#### `tunnels` — cross-domain links

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PRIMARY KEY | symmetric hash of endpoints, MemPalace-compatible |
| `sourceWing` | TEXT NOT NULL | |
| `sourceRoom` | TEXT NOT NULL | |
| `sourceDrawerId` | TEXT | optional — drawer that motivated this link |
| `targetWing` | TEXT NOT NULL | |
| `targetRoom` | TEXT NOT NULL | |
| `targetDrawerId` | TEXT | optional |
| `label` | TEXT | free-form description of the link |
| `addedBy` | TEXT NOT NULL | |
| `filedAt` | TEXT NOT NULL | |
| `tombstonedAt` | TEXT | Rev 2.0+ |
| `removedByBatch` | TEXT | Rev 2.0+ |

Tunnels do not get embeddings. They're navigational metadata, not searchable content. (MemPalace's `tunnels.json` matches.)

#### `diary` — per-agent journal entries

| Column | Type | Notes |
|---|---|---|
| `id` | TEXT PRIMARY KEY | UUID v4 |
| `agentName` | TEXT NOT NULL | |
| `entry` | TEXT NOT NULL | usually AAAK-formatted but no enforcement |
| `topic` | TEXT NOT NULL | free-form tag |
| `wing` | TEXT NOT NULL | conventionally `wing_{agentName}` if not specified |
| `room` | TEXT NOT NULL | conventionally `diary` |
| `filedAt` | TEXT NOT NULL | |
| `embeddingModelID` | TEXT NOT NULL | diary entries are searchable |
| `tombstonedAt` | TEXT | Rev 2.0+ |
| `removedByBatch` | TEXT | Rev 2.0+ |

Diary entries get embeddings — they're searchable content like drawers. In MemPalace they share the ChromaDB collection with drawers, distinguished by a `type=diary_entry` metadata field. We give them their own table because the soft-delete cascade rules differ slightly (a triple can cite a drawer but never a diary entry).

#### `meta` — store metadata

| Column | Type | Notes |
|---|---|---|
| `key` | TEXT PRIMARY KEY | |
| `value` | TEXT NOT NULL | |

Schema version, default embedding modelID, last reclaim sweep timestamp, store identity UUID, etc.

### 4.3 The reference graph

This is the cascade rule we worked out in scope mode (Q8 = reference-counted cascade). The reference relationships across tables are:

| From | To | Via |
|---|---|---|
| `facts.subjectID` | `entities.id` | FK (existing) |
| `facts.objectID` | `entities.id` | FK (existing) |
| `facts.sourceDrawerId` | `drawers.id` | NEW — added in Rev 1.0 schema |
| `tunnels.sourceDrawerId` | `drawers.id` | NEW |
| `tunnels.targetDrawerId` | `drawers.id` | NEW |
| `drawers.wing`, `.room` | (metadata, not FK) | strings only |
| `diary.wing`, `.room` | (metadata, not FK) | strings only |

For Rev 2.0 cascade (soft delete + receipts + reclaim): when a row is tombstoned, the rule is **remove the citing reference, decrement the cited row's reference count, tombstone the cited row only when the reference count hits zero**. Implementation note: we use a `SELECT COUNT(*)` indexed query rather than maintaining a counter column, because the indexed COUNT is drift-free and the index already exists for the foreign-key columns.

### 4.4 Direct dependencies — honoring the two-dependency spirit

Direct package dependencies of `nexus-mcp` (the binary) and its supporting kits:

| Package | Source | Why |
|---|---|---|
| sqlite-vec | github.com/asg017/sqlite-vec (Swift Package distribution) | Vector virtual tables in SQLite. The single new dependency. |
| swift-mcp | TBD — see §11 | MCP protocol stdio implementation. Apple has not shipped a first-party MCP library; we use a community one or hand-roll. |

Everything else is system frameworks: SQLite (system), CoreML (system), Metal (system), Foundation (system), OSLog (system), NaturalLanguage (system, used for sentence-boundary chunking).

This is one or two more direct dependencies than MemPalace's "ChromaDB + PyYAML" promise. It honors the spirit (no third-party Python world, no NPM install dance) while embracing Apple-stack idioms.

---

## 5. Public API surface

### 5.1 Library surface — LociKit

LociKit exposes a Swift actor much like GeniusLocusKit. Genius Mode and Loci Mode both consume it; they differ in configuration.

```swift
public actor LociKit {

    public init(databaseURL: URL,
                embeddingProvider: any EmbeddingProvider,
                config: Config = .default) async throws

    // Drawer surface
    public func addDrawer(_ drawer: Drawer) async throws
    public func getDrawer(id: String) async throws -> Drawer?
    public func searchDrawers(_ query: SearchQuery) async throws -> [SearchResult]

    // Wing/Room queries (DISTINCT against metadata)
    public func listWings() async throws -> [WingSummary]
    public func listRooms(in wing: String?) async throws -> [RoomSummary]
    public func taxonomy() async throws -> Taxonomy

    // Tunnel surface
    public func addTunnel(_ tunnel: Tunnel) async throws
    public func tunnelsFrom(wing: String, room: String?) async throws -> [Tunnel]

    // Diary surface
    public func writeDiaryEntry(_ entry: DiaryEntry) async throws
    public func readDiary(agentName: String, lastN: Int = 10, in wing: String?) async throws -> [DiaryEntry]

    // KG passthrough — delegates to GeniusLocusKit Vanilla composition
    public func upsertEntity(_ entity: Entity) async throws
    public func addFact(_ fact: Fact, sourceDrawerId: String? = nil) async throws
    public func subjectsOf(predicate: String, object: String, at: Date) async throws -> [Entity]
    public func objectsOf(predicate: String, subject: String, at: Date) async throws -> [Entity]
    public func factsValid(at: Date) async throws -> [Fact]
    public func invalidateFact(id: String, at: Date) async throws

    // Stats and operational
    public func status() async throws -> StoreStatus
    public func reindex() async throws

    // Rev 2.0+ surface (hidden behind capability check until then)
    // public func removeDrawer(id: String, by: String, batch: String) async throws -> Receipt
    // public func removeTunnel(id: String, by: String, batch: String) async throws -> Receipt
    // public func restore(receiptID: String) async throws
    // public func reclaimTombstones(olderThan: Duration) async throws -> ReclaimReport
}
```

`SearchQuery` carries the query string, optional wing/room filters (which become *boost signals*, not hard filters — see §8), result limit, and max-distance threshold. `SearchResult` carries the drawer, similarity score, and a hierarchy-boost score breakdown for explainability.

`Drawer`, `Tunnel`, `DiaryEntry`, `WingSummary`, `RoomSummary`, `Taxonomy`, `StoreStatus`, `Receipt`, `ReclaimReport` are public Codable Sendable structs — full shapes in mission specs.

### 5.2 MCP tool surface — exposed by nexus-mcp

The MCP tools mirror MemPalace's tool surface 1-to-1 in shape, renamed for namespace cleanliness. Rev 1.0 ships read tools only (external clients have no write access; internal Nexus apps in Genius Mode use the LociKit library directly with master capability).

| MCP Tool | Maps To | Cap Required |
|---|---|---|
| `loci_status` | `LociKit.status()` | read |
| `loci_search` | `LociKit.searchDrawers(_:)` | read |
| `loci_get_drawer` | `LociKit.getDrawer(id:)` | read |
| `loci_list_wings` | `LociKit.listWings()` | read |
| `loci_list_rooms` | `LociKit.listRooms(in:)` | read |
| `loci_get_taxonomy` | `LociKit.taxonomy()` | read |
| `loci_kg_query` | `LociKit.subjectsOf` / `objectsOf` | read |
| `loci_kg_timeline` | `GeniusLocusKit.factsValid(at:)` over a window | read |
| `loci_kg_stats` | counts | read |
| `loci_diary_read` | `LociKit.readDiary(agentName:lastN:in:)` | read |
| `loci_get_aaak_spec` | static — returns AAAK dialect documentation | read |
| `loci_add_drawer` | `LociKit.addDrawer(_:)` | **write** (Rev 1.0: master only) |
| `loci_add_tunnel` | `LociKit.addTunnel(_:)` | **write** |
| `loci_diary_write` | `LociKit.writeDiaryEntry(_:)` | **write** |
| `loci_kg_add` | `LociKit.upsertEntity` + `addFact` | **write** |
| `loci_kg_invalidate` | `LociKit.invalidateFact(id:at:)` | **write** |
| `loci_remove_*` | (Rev 2.0+) | **restructure** (Rev 2.0+) |

The naming pattern is `loci_<noun>_<verb>` for query tools and `loci_<verb>_<noun>` for action tools, following standard conventions for API discoverability.

A user importing a MemPalace setup into Loci Mode rewrites their Claude Desktop config from:

```json
{
  "mcpServers": {
    "mempalace": { "command": "mempalace-mcp" }
  }
}
```

to:

```json
{
  "mcpServers": {
    "loci": { "command": "/usr/local/bin/nexus-mcp", "args": ["--mode", "loci"] }
  }
}
```

and gets the same tool surface with renamed tool names. We provide a one-page migration crib in Rev 1.0 docs (§9, mission LOCI-9).

### 5.3 CLI surface — nexus-mcp commands

The `nexus-mcp` binary supports several subcommands beyond the default MCP-server mode:

```
nexus-mcp serve [--mode loci|genius] [--config <path>]
    Run the MCP stdio server. Default mode is loci.

nexus-mcp init [--store <path>]
    Create a fresh Loci store at the given path. Initializes schema,
    writes a default identity.txt, generates a master capability key.

nexus-mcp mine <directory> [--wing <name>] [--room <name>] [--exclude <pattern>...]
    Walk a directory tree and ingest text files as drawers. Idempotent
    (re-mining same directory updates only changed drawers). Honors
    .gitignore by default. Skips binary files. See §9.

nexus-mcp status [--store <path>]
    Print store stats: drawer count by wing/room, last reclaim sweep,
    schema version, embedding model in use.

nexus-mcp issue-key [--mode read|write] [--label <description>]
    Issue a new capability key. Prints the key once; never retrievable
    again. Requires master key auth.

nexus-mcp list-keys
    List issued cap keys (label, mode, created, last used). Requires
    master key auth.

nexus-mcp revoke-key <id>
    Revoke a capability key. Requires master key auth.

nexus-mcp benchmark [--suite longmemeval-s|loco-mo|...] [--mode raw|aaak]
    Run a benchmark suite against the current store. See §13.

nexus-mcp migrate-from-mempalace --source <export.json> --dest <store.sqlite>
    Existing tool, extended in Rev 1.0 to cover drawers/wings/tunnels/diary
    on top of the entities/facts already supported.
```

The `init`, `mine`, `status`, `issue-key`, `list-keys`, `revoke-key`, `benchmark`, `migrate-from-mempalace` subcommands take `--store <path>` to operate on stores other than the default.

---

## 6. Embedding provider abstraction

### 6.1 The protocol

```swift
public protocol EmbeddingProvider: Sendable {
    /// Stable string identifier for this model, written into every drawer
    /// row's `embeddingModelID` column. Vectors with different modelIDs
    /// are never compared by the search pipeline.
    var modelID: String { get }

    /// The vector dimension this provider produces. CorpusKit enforces
    /// dimension consistency on first write to any given store.
    var dimensions: Int { get }

    /// Maximum input tokens the provider accepts. Inputs longer than
    /// this are truncated by the chunker (NOT silently — the chunker
    /// emits a smaller chunk).
    var maxTokens: Int { get }

    /// Embed a single string. Provider implementations MAY batch
    /// internally for efficiency; the protocol surface is per-call.
    func embed(_ text: String) async throws -> [Float]

    /// Embed a batch. Default implementation calls embed(_:) in a loop;
    /// providers SHOULD override for hardware-batched paths.
    func embed(_ texts: [String]) async throws -> [[Float]]
}
```

### 6.2 Three Rev 1.0 implementations

| Implementation | modelID | dimensions | tokens | Bundle weight | License | Role |
|---|---|---|---|---|---|---|
| `MiniLMProvider` | `minilm-l6-v2` | 384 | 256 | ~46 MB | Apache 2.0 | **Compatibility floor.** Reproduces 96.6% on LongMemEval-S exactly. Default for users importing existing MemPalace data. |
| `MpnetProvider` | `mpnet-base-v2` | 768 | 384 | ~110 MB | Apache 2.0 | English-only alternative. Targets 98%+ on LongMemEval-S. Cleaner license than EmbeddingGemma. |
| `EmbeddingGemmaProvider` | `embedding-gemma-300m` | 768 | 2048 | ~600 MB (or ~200 MB int4 quantized) | Gemma Terms of Use | **Production default for new stores.** 100+ languages, longest context, best-in-class under 500M parameters. |

All three are CoreML-converted at build time. The conversion tooling lives in `LociKit/Tools/coreml-convert/` (see §16, mission LOCI-2). Conversion produces `.mlmodelc` bundles that ship in the binary's resource bundle.

### 6.3 The license caveat for EmbeddingGemma

EmbeddingGemma 300M (released September 2025) is under the **older custom Gemma Terms of Use**, not Apache 2.0. The terms include a Prohibited Use Policy incorporated by reference and a clause where Google reserves the right to "restrict (remotely or otherwise) usage." Gemma 4 LLM (released April 2026) is under Apache 2.0 — but EmbeddingGemma has not yet been re-released under Apache.

For Simple Machines specifically, the prohibited uses (CSAM, attacks on critical infrastructure, etc.) are uncontroversial. Bob has explicitly said: ship EmbeddingGemma as the production default because we want it tested in production. We document the license status clearly in the Rev 1.0 README so users can make their own call. If they prefer Apache-only, they switch to `mpnet-base-v2` via config — one line change.

### 6.4 Per-row modelID tagging

Every drawer and diary entry row carries `embeddingModelID`. The search pipeline:

- Records the user's currently configured provider's modelID at startup.
- When walking the vector index, only considers rows whose `embeddingModelID` matches the active provider.
- Surfaces a warning at startup if rows exist with non-matching modelIDs (probable model switch).

Re-embedding under a different model is a separate explicit operation:

```
nexus-mcp reindex --provider mpnet-base-v2 --confirm
```

This reads each drawer's content, runs it through the new provider, and writes a new vector under the new modelID. Old vectors stay until explicitly removed (preserves rollback).

### 6.5 Provider dispatch — accommodating Apple's June release

The provider abstraction is the design lever for Apple's announced June release of system-shipped Google models. The runtime dispatch chain at LociKit init:

```
1. Config requests modelID = X.
2. If X is "system-default" and OS version supports system embedding → use SystemEmbeddingProvider.
3. If X is named explicitly and a bundled provider matches → use that.
4. If X is unrecognized → error at init, do not fall back silently.
```

When Apple ships system embedding (likely iOS 27 / macOS 27 in June 2026), we add a `SystemEmbeddingProvider` implementation that dispatches to the new system framework. Existing stores keep working — their rows have the bundled-modelID tag and their vectors are still queryable via the bundled provider. New stores can opt into `system-default` for OS-managed model updates.

This is also why we don't ship our own copy of any model Apple bundles into the OS. We ship the providers users want today; we delete bundled models from our binary when the OS provides equivalents.

---

## 7. Search and retrieval pipeline

### 7.1 Default pipeline — bi-encoder + hybrid re-rank

For Rev 1.0 the default `loci_search` flow is:

```
1. Embed the query string via the active EmbeddingProvider.
2. sqlite-vec KNN — retrieve top N candidates (default N=50) by cosine
   similarity over the active model's vectors.
3. BM25 score — compute Okapi BM25 over the candidate set using the
   query terms tokenized against each drawer's content.
4. Hierarchy boost — for each candidate, compute room_match score
   (1.0 if drawer.room == query.predicted_room, else 0).
5. Combine: final_score = vector*0.7 + bm25*0.2 + room_match*0.1.
6. Sort descending, return top K (default K=5).
```

This is the boost-not-filter pattern (§8). The vector retrieval is unfiltered — every drawer with the active modelID is a candidate. Hierarchy contributes only at the rank-fusion step, where it can elevate but never exclude.

The 0.7 / 0.2 / 0.1 weighting is the proposed default. It's tunable via config. It comes from the MemPalace baseline's empirical 60/40 vector/BM25 balance, adjusted to make room for hierarchy as a small additional signal. Final values get tuned during Rev 1.x against the LongMemEval-S benchmark suite, NOT against the test split (§13).

### 7.2 Optional cross-encoder rerank

A cross-encoder reranker (e.g., `ms-marco-MiniLM-L-6-v2`, ~22 MB CoreML-converted) is offered as opt-in. When enabled:

```
2.5. Cross-encoder rerank — for each of the N=50 candidates, run the
     cross-encoder on (query, drawer.content) to produce a richer
     relevance score. Cross-encoder score replaces BM25 in step 5.
```

The cross-encoder runs ~10–30 ms on the Neural Engine for N=50, which is acceptable for interactive search but not negligible. Default OFF in Rev 1.0. Opt-in via config or per-query flag. Targets ~98% recall@5 paired with MiniLM (matches mpnet baseline without changing the embedding model).

### 7.3 Multi-stage retrieval (Pattern 2)

For users with many wings, an alternate retrieval mode tries narrower-first:

```
1. Predict query's likely wing/room from query text (lightweight classifier
   using the embedding model + cached wing/room centroids).
2. Stage 1: top-20 from predicted room.
3. Stage 2: top-20 from predicted wing.
4. Stage 3: top-10 from full corpus.
5. Merge via rank-based boost favoring narrower stages.
6. Apply BM25 + cross-encoder if enabled.
```

This pays three vector queries per search instead of one, costing ~3× the latency on the vector path, still under 50 ms total on Apple Silicon. Default OFF in Rev 1.0. Opt-in for users with very large stores (~100K+ drawers).

### 7.4 Pure-Loci fast path — when wing/room filter is desired anyway

If a caller explicitly passes `wing` or `room` parameters to `loci_search`, the pipeline shifts:

- The wing/room is treated as a STRONG hint — vector retrieval still scans the full corpus, but the boost weight rises (room_match*0.5 instead of *0.1).
- This is a configurable behavior — strict callers who want hard filtering can set `strictHierarchy: true` in the search request and get MemPalace's old behavior. Documented as an anti-pattern with a recall warning.

### 7.5 The pipeline preserves verbatim-first

At no stage does the pipeline transform drawer content before search. Tokenization for BM25 is per-query (not stored). Embeddings are derived once at ingest and stored. The drawer's `content` column is the immutable source of truth. This honors the verbatim-first pillar.

---

## 8. Hierarchy as soft boost (the math)

### 8.1 Why hierarchy as filter hurts recall

MemPalace's room-filtering mode regressed to 89.4% on LongMemEval-S (vs the 96.6% raw-mode score). The mechanism:

```
build_where_filter(wing="X", room="Y") → {"$and": [{"wing": "X"}, {"room": "Y"}]}
ChromaDB executes vector search WHERE wing="X" AND room="Y".
```

If the query's relevant drawer is in `wing="X" AND room="Z"` (room mispredicted), it's invisible to this query. The hard filter creates a binary cliff. Wrong room prediction on one query loses all candidates from the right room.

### 8.2 Why hierarchy as boost cannot hurt

Boost-not-filter:

```
candidates = full_corpus.knn(query, k=50)              ← always scans everything
score(c) = α·vector(c) + β·bm25(c) + γ·room_match(c)   ← hierarchy as +γ
return top_k_by_score(candidates)
```

`room_match(c)` is 1.0 when `c.room == predicted_room`, else 0. The boost is additive. For two candidates with identical vector and BM25 scores, the one in the predicted room ranks higher. For two candidates where vector strongly favors one and the other has the room-match, the room-match contributes a small lift but does not flip ranking unless `γ` is large enough relative to vector difference.

Mathematical guarantee: setting `γ=0` reduces the system to pure vector + BM25 (no hierarchy, equivalent to raw mode). Any `γ>0` only changes ranking when vector + BM25 ties exist or are close. **In the limit of `γ→0+`, recall is identical to raw mode.** For any `γ` we'd reasonably set, the worst case is recall equal to raw mode; the typical case is small lift.

### 8.3 The empirical experiment

We don't take the math at face value. The Rev 1.x benchmark cycle (§13) sweeps `γ ∈ [0.0, 0.5]` against the LongMemEval-S held-out split (NOT the dev split, NOT the full split with the 17-question controversy) and picks the value that maximizes recall@5. If the answer is `γ=0`, hierarchy provides no signal on this benchmark and we configure default to 0. We're honest about whatever the data shows.

### 8.4 Label-embedding as Pattern 3 (deferred to Rev 1.x)

A second pattern that lets hierarchy help: prepend `[wing: X] [room: Y]` to the drawer's content before embedding. The embedding model treats the hierarchy as semantic content — queries that mention the room name land closer to its drawers naturally. This is free at query time; the cost is at ingest.

We defer to Rev 1.x because:

- It changes ingest behavior, so changing it later requires re-embedding the whole corpus.
- The boost-as-rerank pattern (§8.1–8.2) gives most of the benefit with no ingest-time commitment.
- We want empirical numbers from the boost variant before adding label-embedding on top.

If Rev 1.x experimentation shows label-embedding adds another point or two of recall, we add it as a Rev 2.0 ingest option with a one-time re-embed migration tool.

---

## 9. Ingest pipeline — the directory walker

### 9.1 What `nexus-mcp mine` does

Bob's primary use case: "remine the code repos nightly while I sleep." So the miner needs to be:

- **Idempotent.** Running it twice in a row on the same directory produces the same store state (modulo updated timestamps for actually-changed content).
- **Resume-safe.** Killing and restarting picks up where it left off without duplicate drawers or lost progress.
- **Fast.** Walking a 100K-file repo should not take an hour.
- **Quiet.** No spam in the terminal during nightly runs. Errors are loud; success is silent unless `--verbose` is passed.

### 9.2 The walking algorithm

```
1. Resolve directory path. Reject non-directories or non-readable paths.
2. Read .gitignore in the target if present (and in each subdirectory
   walked); honor exclusion patterns. Honor a baseline skip list for
   common build artifact directories (node_modules, .git, dist, build,
   __pycache__, .next, .ruff_cache, target, venv, etc.).
3. Honor user-supplied --exclude patterns layered on top.
4. For each non-excluded file:
   a. Skip binary files (extension blacklist + magic-byte sniff).
   b. Skip files larger than --max-file-size (default 5 MB; large config
      from MemPalace was 500 MB, that was too generous in practice).
   c. Read content. Compute SHA256 of content + relative path.
   d. Look up existing drawer where sourceFile = relative_path.
      - If none: chunk + ingest as new drawers.
      - If exists and stored hash matches current hash: skip (idempotent).
      - If exists and hash differs: tombstone old drawers for this file
        (Rev 1.0: hard delete since soft-delete is Rev 2.0); ingest new.
5. Periodically (every N files) commit the current SQLite transaction
   so a crash doesn't lose all progress.
6. Print final summary: files seen, files ingested, files skipped,
   drawers created, drawers updated, drawers retired, total time.
```

Per-file hash lookups cost ~1 μs on a small `meta` table; the throughput bottleneck is embedding generation (which we batch).

### 9.3 Chunking

For Rev 1.0 we use **paragraph-aware chunking with sentence-boundary fallback**. Concretely:

- Target chunk size: 800 characters (matching MemPalace).
- Overlap: 100 characters.
- Boundaries (in priority order):
  1. Two consecutive newlines (paragraph break).
  2. Markdown heading (`#`, `##`, etc. on a line by itself).
  3. Sentence boundary detected by Apple's `NaturalLanguage.NLTokenizer(unit: .sentence)`.
  4. Hard cut at 800 chars if no boundary in range.
- Minimum chunk size: 50 characters (skip trailing fragments).
- Maximum chunk size: 1200 characters (hard cap, prevents pathological cases).

Apple's NaturalLanguage framework is Foundation-level — no dependency, no model load. It handles English well; for the multilingual case (Rev 1.x with EmbeddingGemma's 100+ languages), NLTokenizer auto-detects script. We document any per-language quirks in the Rev 1.x release notes.

### 9.4 What gets ingested

Default behavior: text files with extensions in a known whitelist (`.md`, `.txt`, `.py`, `.swift`, `.js`, `.ts`, `.go`, `.rs`, `.c`, `.h`, `.cpp`, `.java`, `.json`, `.yaml`, `.toml`, `.html`, `.css`, etc.). Non-whitelisted extensions are skipped unless `--include-extensions` overrides.

Every drawer carries:

- `content` = the chunk text, verbatim
- `sourceFile` = relative path from the mine root
- `chunkIndex` = position in the file
- `wing` = supplied via `--wing` flag, default = the mine root's basename
- `room` = supplied via `--room` flag, or auto-detected from folder structure via simple heuristics ported from MemPalace's `room_detector_local.py` (frontend → "frontend", tests → "tests", docs → "documentation", etc.)
- `addedBy` = `"miner"` (or whatever process is doing the ingest)
- `embeddingModelID` = active provider's modelID

### 9.5 Resume-safety detail

The miner writes a `.mining-progress` row to the `meta` table at each batch commit, recording the mine root and the file path it last processed. On restart, the miner reads this row and skips files lexicographically before that path. This is sufficient because the walk order is deterministic (alphabetical within each directory level via Foundation's `enumerator`).

### 9.6 What's deferred

- **Apple ecosystem ingest sources** (Calendar, Mail, Contacts, Messages with consent) — Q22 from scope. Each source has its own permission flow and EventKit/EKEventStore plumbing. Rev 3.x once iOS variant exists.
- **PDF/Office document extraction** — needs PDFKit / NSAttributedString parsing. Rev 1.x via a separate `nexus-mcp mine --documents` subcommand with extension-specific handlers.
- **Spotlight integration on macOS** — let Spotlight tell us what's indexable. Rev 2.x stretch goal.

---

## 10. MemPalace compatibility and migration

### 10.1 The existing migrate-from-mempalace tool

The `migrate-from-mempalace` executable (shipped via TASK-NEX-2026-0008) currently handles **entities and facts only**. It reads MemPalace's JSON export, imports into a vanilla-mode GeniusLocusKit store, and runs a parity check.

### 10.2 Rev 1.0 extension scope

The Rev 1.0 work extends this tool to cover the full MemPalace surface:

- **Drawers.** Read MemPalace's ChromaDB SQLite dump (or its JSON export of drawers), import as Loci drawers, embed via the configured provider. The migration tool handles the case where MemPalace's vectors used MiniLM (bundled all-MiniLM-L6-v2): if the user's chosen Loci provider is also MiniLM, vectors are imported verbatim with `embeddingModelID = "minilm-l6-v2"`. If the user chose a different provider, drawers are re-embedded under the new model.
- **Wings/rooms.** Imported as drawer metadata. No separate import step.
- **Tunnels.** Read MemPalace's `tunnels.json`, import into Loci's `tunnels` table. Field mapping is direct.
- **Diary entries.** Read MemPalace's `type=diary_entry` ChromaDB rows, import into Loci's `diary` table.
- **Knowledge graph.** Already handled by the existing tool. Extended with `sourceDrawerId` propagation now that drawers are present.

### 10.3 Field mapping reference

| MemPalace concept | MemPalace storage | Loci storage | Notes |
|---|---|---|---|
| Drawer content + metadata | ChromaDB row | `drawers` table | content verbatim |
| Drawer wing/room | ChromaDB metadata strings | `drawers.wing`, `drawers.room` | verbatim copy |
| Drawer embedding | ChromaDB HNSW | sqlite-vec virtual table | re-import or re-embed depending on model |
| Tunnel | `tunnels.json` entry | `tunnels` table | direct |
| Diary entry | ChromaDB row with `type=diary_entry` | `diary` table | direct |
| Entity | KG SQLite `entities` row | `entities` table (GLK existing) | direct |
| Triple | KG SQLite `triples` row | `facts` table (GLK existing) | predicate naming convention preserved; `source_drawer_id` field maps to Loci's drawer `id` if drawers were imported in same run |
| AAAK closet | ChromaDB `closets` collection | (NOT migrated — see §13) | Rev 1.x benchmark harness only |
| Identity layer | `~/.mempalace/identity.txt` | `~/Library/Application Support/Loci/identity.txt` | direct file copy |

### 10.4 Parity verification

The Rev 1.0 migration tool extends the existing parity-check to cover the new types:

- **Drawer parity**: Random-sample 100 drawers from the source, embed the same query against both source and Loci, verify top-5 results overlap by ≥80%.
- **Tunnel parity**: Compare tunnel counts and verify a sample of tunnels resolve from the same source drawer to the same target wing/room.
- **Diary parity**: Confirm count match and verify a few entries by ID round-trip.
- **KG parity**: Existing — count match plus sample query equivalence.

A `--strict` flag fails the migration if any parity check falls below threshold. Default behavior is to report parity numbers and exit successfully even with mild drift (some drift is expected when models differ).

### 10.5 What we're not migrating

- **AAAK closets in active use.** AAAK regressed scores by 12 points on MemPalace's own benchmarks. We don't carry it forward as a search mode. We carry the spec as a benchmark harness only (§13).
- **MemPalace's HNSW config.** MemPalace pinned `num_threads=1` to work around a `hnswlib` SIGSEGV; sqlite-vec doesn't have this constraint and the migration tool doesn't honor the old config.
- **MemPalace's room-filter behavior.** Loci's hierarchy is boost-not-filter (§8). We don't carry forward the binary-cliff filter behavior even though it's expressible in the new MCP tools — we document `strictHierarchy: true` as an anti-pattern.

---

## 11. Capability key security model

### 11.1 The model

Loci stores capability keys in a `capabilities` SQLite table (or, preferably, in the macOS Keychain via Security framework). Each key has:

- `id` — UUID, the public-facing identifier
- `secret` — random 256-bit value, hashed for storage (never stored cleartext)
- `mode` — one of `master`, `read`, `write`, `restructure`
- `label` — human-readable description ("Bob's Claude Desktop", "weekly cron miner")
- `createdAt`
- `lastUsedAt`
- `revokedAt` — null when active

Caller authentication: every MCP call carries a `cap` field (in the MCP request metadata, or as the first positional argument). The server hashes the supplied secret, looks up by hash, verifies mode permits the requested operation, updates `lastUsedAt`, proceeds or rejects.

### 11.2 Mode permissions for Rev 1.0

| Mode | Read tools | Write tools | Restructure tools | Notes |
|---|---|---|---|---|
| `master` | ✓ | ✓ | ✓ | One per store, generated at `nexus-mcp init`. Required for `issue-key`, `revoke-key`, `migrate-from-mempalace`. |
| `read` | ✓ | ✗ | ✗ | Default for external MCP clients. Issued by `nexus-mcp issue-key --mode read`. |
| `write` | ✓ | ✓ | ✗ | Allows adding drawers, tunnels, diary entries, KG facts. **Rev 1.0: not exposed externally** — write tools are master-only on the MCP surface. Internal Nexus apps in Genius Mode hold master and use the LociKit library directly. |
| `restructure` | ✓ | ✓ | ✓ | Allows soft-delete and reclaim operations. **Rev 2.0+ only.** |

In Rev 1.0, the practical security posture is: **the user holds the master key, gives Claude Desktop a read-only key, and external agents cannot mutate the brain.** This matches Bob's clarification: external MCP clients are read-only in Rev 1.0; internal apps and the master-key holder have full RW from day one.

### 11.3 Key issuance flow

```
$ nexus-mcp init --store ~/Library/Application\ Support/Loci/store.sqlite
Initialized store at ~/Library/Application Support/Loci/store.sqlite.
Master key (save this — it will not be shown again):
    LOCI-MASTER-7f3a9e12-...-d4b8

$ nexus-mcp issue-key --mode read --label "Claude Desktop"
Read-only key (save this):
    LOCI-READ-2c1f8b04-...-9e7a
```

The master key is shown once at init. Losing it is recoverable only by accessing the SQLite file directly with another master-key-holding process — practically, by re-init on a fresh store. We document this as a "store the master key in your password manager" instruction in the README.

### 11.4 Defer to Fulcrum spec

The full capability key model — token rotation, scope delegation, wing-level access — is already specified in the Fulcrum spec. Rev 1.0 implements only the master + read flavors above. Rev 2.0 (when write tools are exposed externally) adopts the rest of the Fulcrum-specified model, which by then will be battle-tested in Fulcrum integration. Skippy will read the relevant Fulcrum sections at Rev 2.0 design time rather than re-inventing.

### 11.5 Configuration of Claude Desktop

The user's Claude Desktop `claude_desktop_config.json` looks like:

```json
{
  "mcpServers": {
    "loci": {
      "command": "/usr/local/bin/nexus-mcp",
      "args": ["serve", "--mode", "loci"],
      "env": {
        "LOCI_CAP_KEY": "LOCI-READ-2c1f8b04-...-9e7a",
        "LOCI_STORE": "/Users/bob/Library/Application Support/Loci/store.sqlite"
      }
    }
  }
}
```

The cap key passes through environment variables (Claude Desktop's standard config-injection mechanism). The server reads `LOCI_CAP_KEY` at startup and uses it as the default for incoming requests; we can also accept per-request override via tool arguments for advanced setups.

---

## 12. Phasing — Rev 1.0 through Rev 3.x

### 12.1 Rev 1.0 — macOS standalone, read-only external MCP

**Ship target: 2 days from /draft completion.**

**Scope:**
- macOS-only Swift binary (`nexus-mcp serve --mode loci`).
- Storage: single SQLite file at `~/Library/Application Support/Loci/store.sqlite`.
- LociKit Swift Package added to nexus repo with Drawer/Wing/Room/Tunnel/Diary types.
- CorpusKit built per existing MISSION_RAG_1_RAGKIT.md spec — sqlite-vec backend, Metal cosine.
- Three embedding providers via CoreML: MiniLM, mpnet, EmbeddingGemma. Default = EmbeddingGemma.
- Search pipeline with hybrid re-rank and hierarchy-as-boost (`γ` = 0.1 default, tunable).
- Directory walker subcommand (`nexus-mcp mine`), idempotent, .gitignore-aware.
- Master + read capability keys. External MCP clients are read-only.
- MemPalace migration tool extended to cover drawers, tunnels, diary.
- Static `loci_get_aaak_spec` MCP tool returning AAAK documentation (no AAAK ingest, no AAAK search).
- README + MCP tool reference + install guide.

**Out of scope for Rev 1.0:**
- iOS variant
- iCloud sync
- Soft delete / receipts / reclaim
- Cross-encoder reranker
- Multi-stage retrieval (Pattern 2)
- Label-embedding (Pattern 3)
- Apple ecosystem ingest sources
- Domain-based security model
- Public write tools on MCP surface

**Mission count: 8.** See §16.

### 12.2 Rev 1.x — production hardening, benchmark suite

**Ship target: 1–2 weeks after Rev 1.0 ships.**

**Scope:**
- Comprehensive benchmark suite: LongMemEval-S, LoCoMo, BEAM. Reproducibility scripts.
- AAAK harness as a separate target — for honest comparison runs against MemPalace's published numbers.
- Cross-encoder reranker as opt-in (mission LOCI-1X-1).
- Multi-stage retrieval (Pattern 2) for users with many wings.
- Search pipeline parameter tuning (γ, vector/BM25 weights) against held-out splits.
- PDF / Office document ingest via PDFKit handlers.
- Performance profiling and optimization passes.
- Better installation (Homebrew formula, signed pkg installer).

**Mission count target: 6.**

### 12.3 Rev 2.0 — write/restructure on public MCP, soft delete, receipts

**Ship target: 4–6 weeks after Rev 1.x.**

**Scope:**
- Cascade-aware soft delete: `tombstonedAt` columns, reference-counted cascade rule, no-orphans guarantee.
- Batch IDs on adds and removes — receipt-based rollback (Q5 from scope).
- Reclaim sweep on actor open if >24h since last (Q6).
- 30-day default retention before tombstones are purged.
- `loci_remove_*` and `loci_restore` tools on MCP surface.
- `write` and `restructure` capability modes exposed externally.
- Capability key model expansion per Fulcrum spec.
- Label-embedding (Pattern 3) as opt-in ingest mode with one-time re-embed migration.

**Mission count target: 8–10.**

### 12.4 Rev 2.x — iCloud sync, Apple system embedding

**Ship target: post-WWDC June 2026, ~6–8 weeks after Rev 2.0.**

**Scope:**
- iCloud sync via CKSyncEngine (iOS 17+ required for the API). Per-row sync as CKRecord. Conflict resolution at row level. Preserves SQLite as local store.
- App Group + shared CloudKit container — sets up the foundation for Genius Mode integration even before Genius Mode ships.
- `SystemEmbeddingProvider` implementation that dispatches to Apple's June-shipped models. Default for new stores on supported OS versions.
- Sync footprint optimization: re-embed lazy/on-demand for large stores.

**Mission count target: 5–7.**

### 12.5 Rev 3.0 — iOS variant, standalone Mac app shell (Case 2 from scope)

**Ship target: post-Rev 2.x, ~8–10 weeks.**

**Scope:**
- iOS app target (`ARIA_iOS`) wrapping LociKit. Just-the-MCP-no-other-Nexus-parts per Bob's framing.
- macOS app shell — minimal UI for "Genius Locus" standalone product. Brain management, ingest sources, capability key issuance.
- App Store and Mac App Store readiness.
- Apple ecosystem ingest sources begin: Calendar (EventKit), Reminders, Contacts (with user consent flows).

**Mission count target: 8–10.**

### 12.6 Rev 3.x — domain-based security, multi-source ingest, Genius Mode entry

**Ship target: open-ended.**

**Scope:**
- Wing-level access tokens issued via the standalone app's UI.
- Per-MCP-client wing scope ("Claude can see wing_personal but not wing_work").
- Mail / Messages ingest with consent.
- Spotlight integration.
- Genius Mode integration scaffolding (FNode anchoring, AI Assist wiring) — this is a separate spec but the data layer it shares with Loci stabilizes here.

---

## 13. Benchmark methodology

### 13.1 Headline metric

**Recall@5 on LongMemEval-S held-out split.** This is the metric we publish. Three modes get measured:

- **Compatibility mode** — MiniLM provider, MemPalace-equivalent chunking, hybrid re-rank with γ=0. Target: **96.6% reproducible**.
- **Default mode** — EmbeddingGemma provider, sentence-boundary chunking, hierarchy boost γ=0.1. Target: **≥98%**.
- **AAAK harness** — MiniLM provider, AAAK-compressed drawers (closets), search through compressed corpus. Target: **document the regression honestly**, no production claim.

### 13.2 Reproducibility

The benchmark harness lives in a separate Swift target inside `LociKit/`:

```
LociKit/Sources/LociKitBench/
├── LongMemEvalRunner.swift
├── LoCoMoRunner.swift
├── BEAMRunner.swift
├── BenchmarkConfig.swift
└── BenchmarkReport.swift
```

Each runner takes a benchmark dataset path, a Loci store, and a config; produces a JSON report with per-question results and aggregate metrics. Reports are committed to `docs/benchmarks/` so results are diffable across revs.

Datasets are downloaded by a script (the user runs it; we never bundle benchmark data). Sources documented in the README.

### 13.3 The 100% trap — never tune on test split

MemPalace's original 100% score came from inspecting their 17 wrong test answers and engineering targeted fixes (`hybrid_v4` with quoted-phrase boost, person-name boost, "nostalgia" patterns), then rerunning on the same set. Held-out score was 98.4%. The MemPalace team acknowledges this in their `BENCHMARKS.md` as "teaching to the test."

**Rule for all Loci benchmarking:**

- LongMemEval-S has a published 50-question dev split and 450-question held-out split (per MemPalace's own docs). All parameter tuning happens on the dev split. The held-out split is run only for final evaluation — never as a target.
- We never publish a "tuned" full-500 number. If we cite a single recall@5 figure, it's the held-out 450.
- Configuration parameters tuned on the dev split (γ, vector/BM25 weights, k for KNN, retrieval N) are documented in the report so the configuration is auditable.

### 13.4 The AAAK harness

AAAK (MemPalace's compressed-symbolic format) regressed scores by ~12 points on MemPalace's own benchmarks. We don't ship it as a search mode. We do ship the **harness** — a benchmark target that:

1. Reads a Loci drawer corpus.
2. Runs MemPalace's AAAK compression algorithm on each drawer's content (port the algorithm from MemPalace's `dialect.py`).
3. Stores compressed versions in a parallel sqlite-vec table.
4. Runs the same benchmark queries against the compressed corpus.
5. Reports the recall delta vs raw mode.

This serves two purposes: (a) lets us validate that the AAAK algorithm port is correct (the port should reproduce MemPalace's regression), and (b) gives a continuous baseline against which "the rest of the system is faster" claims can be measured. If we ever change Loci's chunking or retrieval and the AAAK harness number changes, we know the change isn't algorithmic — it's pipeline.

The harness is opt-in (its own target, its own subcommand). It does not ship enabled in the main binary.

### 13.5 Latency benchmarks

In addition to recall, we publish per-call latencies for representative operations:

- Cold start (binary launch to first MCP response).
- Single search query, store ≤10K drawers.
- Single search query, store ≤100K drawers.
- Single search query, store ≤1M drawers.
- Ingest throughput (drawers/sec).

Target: substantial multipliers over MemPalace's Python implementation. Specific numbers documented post-implementation in the Rev 1.0 report (we don't promise specific multipliers in the spec — we measure and publish).

---

## 14. Operational concerns

### 14.1 Configuration

Config lives at `~/Library/Application Support/Loci/config.json`:

```json
{
  "store": "~/Library/Application Support/Loci/store.sqlite",
  "embedding": {
    "provider": "embedding-gemma-300m",
    "quantization": "int4"
  },
  "search": {
    "k_candidates": 50,
    "k_results": 5,
    "weights": { "vector": 0.7, "bm25": 0.2, "room": 0.1 },
    "cross_encoder": { "enabled": false, "model": "ms-marco-minilm-l6-v2" },
    "multi_stage": { "enabled": false }
  },
  "ingest": {
    "chunk_size": 800,
    "chunk_overlap": 100,
    "min_chunk_size": 50,
    "max_chunk_size": 1200,
    "max_file_size": 5242880,
    "include_extensions": null,
    "exclude_patterns": []
  },
  "logging": { "level": "info", "subsystem": "com.mootx01.kit" }
}
```

The defaults are sane out of the box. Power users can override. `nexus-mcp init` writes a default config; `nexus-mcp config show` prints the active config; `nexus-mcp config set <key> <value>` mutates it.

### 14.2 Logging

Per the Nexus fleet rule: Apple OSLog with subsystem `"com.mootx01.kit"` and category = module name. LociKit logs as category `LociKit`, ARIA_MCP's MCP server as `ARIA_MCP`, CorpusKit as `CorpusKit`, embedding providers as `EmbeddingProvider/<modelID>`.

Log levels: debug for per-query traces, info for ingest progress, default for state changes, error for failures. Ingest spam goes to debug; `nexus-mcp mine` with `--verbose` raises the floor to info.

### 14.3 Error handling

Per the Nexus fleet rule: structured error enums, no optionals + logging. Each module owns its error type:

- `LociKitError` — store-level, surface-level, MemPalace migration errors.
- `CorpusKitError` — vector storage and Metal compute errors (already specified in MISSION_RAG_1_RAGKIT.md).
- `GeniusLocusError` — KG layer (already exists).
- `EmbeddingProviderError` — model load, inference, dimension mismatches.
- `ARIA_MCPError` — protocol violations, capability denials, transport errors.

The MCP server translates Swift errors into MCP error responses with descriptive messages. We never leak file paths or internal state in error responses sent to MCP clients.

### 14.4 File locations

```
~/Library/Application Support/Loci/
├── store.sqlite                  ← single SQLite database
├── store.sqlite-wal              ← WAL file (SQLite-managed)
├── store.sqlite-shm              ← shared memory file (SQLite-managed)
├── config.json
├── identity.txt                  ← L0 identity (user-edited plain text)
├── capabilities.sqlite           ← OR Keychain-backed (TBD §11.1)
└── logs/                         ← optional, only if file logging enabled
    └── loci.log
```

Models ship inside the binary's resource bundle, not in user files.

### 14.5 Performance budgets

These are aspirational targets for Rev 1.0 — not contractual. We measure and adjust during Rev 1.x.

| Operation | Target |
|---|---|
| Binary cold start (no work) | < 200 ms |
| First MCP response after launch | < 500 ms |
| Single embedding (single drawer, EmbeddingGemma int4) | < 20 ms |
| Single search query (10K drawers, vector + BM25) | < 30 ms |
| Single search query with cross-encoder rerank | < 60 ms |
| Ingest throughput (small files, EmbeddingGemma int4 batch=16) | ≥ 100 drawers/sec |
| Reclaim sweep (Rev 2.0+, 100K drawers, 10% tombstoned) | < 5 sec |

---

## 15. Testing strategy

### 15.1 Unit tests

Each kit owns its unit tests:

- `LociKitTests` — Drawer/Tunnel/Diary CRUD, schema migration, hierarchy boost math, query construction, AAAK port correctness (against fixture inputs).
- `CorpusKitTests` — already specified in MISSION_RAG_1_RAGKIT.md.
- `GeniusLocusKitTests` — already in place.
- `EmbeddingProviderTests` — mock provider tests, dimension contracts, model-load round-trips.
- `ARIA_MCPTests` — capability gating, tool dispatch, error translation.

Coverage target: ≥80% line coverage on net-new code.

### 15.2 Integration tests

A separate `LociIntegrationTests` target that:

1. Builds a small fixture corpus (~100 drawers across 3 wings).
2. Runs the full pipeline: ingest → search → KG add → search again with KG context.
3. Verifies expected results.
4. Runs against all three embedding providers (MiniLM, mpnet, EmbeddingGemma) — providers are smoke-tested but not benchmark-tested in unit pass.

This is the "canary" suite that runs on every commit to develop.

### 15.3 Migration parity tests

The migrate-from-mempalace tool gets parity tests for the new types:

- Migrate a fixture MemPalace export.
- Run the same query against (a) MemPalace MCP server and (b) Loci server.
- Compare top-5 result IDs. Require ≥80% overlap.

This requires a MemPalace fixture file checked into `Tests/MigrateTests/Fixtures/`. We use synthetic data (we don't ship Bob's real palace as a test fixture).

### 15.4 MCP smoke test

A `nexus-mcp serve` instance is launched in a subprocess, a test harness sends MCP requests over stdio, asserts responses match the protocol contract. Covers:

- Tool discovery (`tools/list`).
- Each MCP tool with valid inputs.
- Capability-key denial paths.
- Error responses for malformed inputs.

### 15.5 Benchmark regression tests

The benchmark harness (§13) runs nightly on a small subset of LongMemEval-S (50 questions) against a fixture corpus. Recall@5 must not regress more than 1 percentage point between commits. A larger run (full held-out 450) runs weekly and against pre-merge to develop.

---

## 16. Mission decomposition for Rev 1.0

Eight missions, parallelizable into three streams. Each is sized to fit the dispatch-ops `≤3 files preferred` rule (some exceed slightly; those need SARC-1 spec validation per the standing process).

### Wave 1 — foundation, parallel

**LOCI-1 — LociKit package skeleton + Drawer/Wing/Room types**
- Branch: `stream/lc-loci-types`
- New Swift Package at `LociKit/` with public API skeleton, Drawer/Tunnel/DiaryEntry/WingSummary/RoomSummary types as Codable Sendable structs, error enum.
- DrawerStore class with SQLite schema (no embeddings yet — that lands in LOCI-3).
- Tests for type round-trips and store CRUD.
- ~6–8 files, net-new.
- **Depends on:** nothing.
- **Parallel safe with:** LOCI-2, LOCI-3.

**LOCI-2 — EmbeddingProvider protocol + MiniLM CoreML implementation**
- Branch: `stream/le-embeddings-minilm`
- New module `LociKit/Sources/LociKit/Embedding/` with the `EmbeddingProvider` protocol.
- CoreML conversion script (Python, lives in `Tools/coreml-convert/`) for MiniLM.
- `MiniLMProvider` Swift implementation.
- Bundled `.mlmodelc` artifact in `LociKit/Resources/`.
- Tests for provider round-trips, dimension contract, batch handling.
- ~5 files, net-new.
- **Depends on:** nothing (parallel with LOCI-1).
- **Parallel safe with:** LOCI-1, LOCI-3.

**LOCI-3 — CorpusKit Swift Package per existing MISSION_RAG_1_RAGKIT.md**
- Branch: `stream/lr-ragkit`
- Resurrects the RAG-1 mission scoped at TASK-NEX-2026-0004. Specification already exists; mission file already authored. We re-dispatch.
- ~12 files, net-new.
- **Depends on:** nothing.
- **Parallel safe with:** LOCI-1, LOCI-2.

### Wave 2 — additional providers, parallel

**LOCI-4 — mpnet + EmbeddingGemma providers**
- Branch: `stream/lp-embeddings-rest`
- Two more `EmbeddingProvider` implementations following the LOCI-2 pattern.
- CoreML conversion script extensions for both models.
- Bundled `.mlmodelc` artifacts.
- Tests parallel to LOCI-2.
- ~5 files, net-new.
- **Depends on:** LOCI-2 (the protocol shape).

### Wave 3 — composition, sequential

**LOCI-5 — LociKit search pipeline + KG passthrough**
- Branch: `stream/ls-search-pipeline`
- Wires LociKit to GeniusLocusKit (Vanilla composition) for KG ops.
- Wires LociKit to CorpusKit for embedding storage and KNN.
- Implements the hybrid re-rank pipeline (§7).
- Hierarchy-as-boost computation.
- Tunnels and Diary CRUD.
- Tests for the full search path against a fixture.
- ~6 files, net-new.
- **Depends on:** LOCI-1, LOCI-2, LOCI-3.

**LOCI-6 — Directory walker / miner**
- Branch: `stream/lm-miner`
- `nexus-mcp mine` subcommand and supporting code.
- Idempotent walking, .gitignore handling, chunking via NaturalLanguage.
- Resume-safety via `.mining-progress` meta row.
- Tests against a fixture directory.
- ~4 files, net-new.
- **Depends on:** LOCI-5.

**LOCI-7 — ARIA_MCP MCP server library + nexus-mcp executable**
- Branch: `stream/ln-mcp-server`
- ARIA_MCP module with MCP stdio handler, capability key model, tool dispatch.
- `nexus-mcp` Swift executable target wrapping ARIA_MCP + LociKit.
- Subcommand parsing for `serve`, `init`, `mine`, `status`, `issue-key`, etc.
- Tests for capability gating and tool dispatch.
- ~8 files, net-new.
- **Depends on:** LOCI-5, LOCI-6.

**LOCI-8 — Migration tool extension + AAAK harness skeleton + docs**
- Branch: `stream/ld-docs-migration`
- Extend existing `migrate-from-mempalace` to cover drawers, tunnels, diary.
- AAAK harness target skeleton (algorithm port from MemPalace's `dialect.py`, no benchmark data yet).
- README, MCP tool reference, install guide, Claude Desktop config example.
- Migration parity tests.
- ~6 files, edits to existing CLI plus net-new harness.
- **Depends on:** LOCI-1 (drawer schema), LOCI-5 (search for parity check).

### Mission risk profile

| Mission | Risk | Reason |
|---|---|---|
| LOCI-1 | low | Net-new types, no integration |
| LOCI-2 | medium | First CoreML conversion — MiniLM has well-trodden conversion path, but first time in our build |
| LOCI-3 | medium | RAG-1 was previously scoped, marked merged in task record but never landed in develop — needs re-investigation |
| LOCI-4 | medium-high | EmbeddingGemma CoreML conversion is the longest pole — may need 4–8 hours dedicated |
| LOCI-5 | medium | Cross-kit composition, multiple correctness invariants |
| LOCI-6 | low | Standalone subcommand, well-bounded |
| LOCI-7 | medium | First MCP server in our codebase, protocol implementation needs care |
| LOCI-8 | low | Builds on LOCI-1 and LOCI-5; mostly mechanical |

### Parallelization plan

Three Bilby streams running simultaneously can bring this in within Bob's 2-day window:

```
Day 1:
  Stream A: LOCI-1 → LOCI-5 (sequential, blocks on CorpusKit timing)
  Stream B: LOCI-2 → LOCI-4 (sequential, embeddings)
  Stream C: LOCI-3 (CorpusKit, isolated)

Day 2:
  Stream A: LOCI-6 (after LOCI-5)
  Stream B: LOCI-4 finishes if not done
  Stream C: LOCI-7 (after LOCI-5 + LOCI-6)
  Stream D (joining): LOCI-8 (after all the above)
```

The critical path is LOCI-3 → LOCI-5 → LOCI-7 → LOCI-8. If LOCI-3 (CorpusKit) lands fast, the rest pipelines smoothly.

---

## 17. Open questions and known risks

### 17.1 Open questions for Bob

| # | Question | Default |
|---|---|---|
| Q22 | Case 2 standalone-app general-purpose RAG ingest sources — Calendar, Mail, Contacts via consent flows; Spotlight; ad-hoc folders. Which first? Defer to Rev 3.0 mission spec. | folders + .gitignore-aware miner shipped Rev 1.0; everything else Rev 3.0 |
| Q23 | Domain-based security model — wing-level access tokens vs entitlement-based gating. Defer to Rev 3.x mission spec. | wing-level via cap key scoping |
| Q30 | MCP installation — Homebrew formula, signed pkg installer, ship inside Nexus.app helper bundle, or all of the above? Rev 1.x decision. | start with raw binary + manual config edit; Homebrew formula in Rev 1.x |
| Q31 | EmbeddingGemma quantization default — int4 (smaller, faster, ~1pt recall loss) or fp16 (full quality, larger). Rev 1.x measure-and-decide. | int4 default for Rev 1.0 ship; revisit after benchmarks |
| Q32 | Should `loci_get_aaak_spec` actually return the AAAK spec doc, or just be a stub for MemPalace-compatibility namespace? | return the spec, port from MemPalace's `dialect.py` constants |
| Q33 | Cross-encoder reranker model — `ms-marco-MiniLM-L-6-v2` is the obvious pick but there are larger/better options. Rev 1.x decision. | `ms-marco-MiniLM-L-6-v2` for Rev 1.x, evaluate alternatives |

### 17.2 Known technical risks

**EmbeddingGemma CoreML conversion** — September-2025 model on Gemma 3 architecture. Conversion is doable; the transformer-style attention is well-understood by Apple's `coremltools`. Risk is in tokenizer handling — Gemma uses a SentencePiece-style tokenizer that needs to ship as a separate artifact alongside the `.mlmodelc`. Time budget: 4–8 hours of one Bilby stream. Mitigation: LOCI-2 (MiniLM only) ships first to validate the conversion path; LOCI-4 (mpnet + EmbeddingGemma) follows.

**RAG-1 mystery** — The task record TASK-NEX-2026-0004 is marked `status: "merged"` but no commits touch `CorpusKit/` on develop. Investigation needed before LOCI-3 dispatches. Possible causes: mission was abandoned, mission was completed on a different branch that wasn't pushed, task record was prematurely marked merged. Skippy reads the recovery notes and the mission spec carefully before re-dispatching; if CorpusKit code does exist somewhere we should locate and resurrect rather than rebuild. (Action item for Skippy: investigate before LOCI-3 mission goes out. Outcome captured as a note in the LOCI-3 mission spec.)

**MCP Swift library** — there's no first-party Apple MCP library. We either: (a) hand-roll a stdio MCP server (~300 lines, well-bounded, MCP protocol is straightforward JSON-RPC), or (b) use a community Swift MCP package if one exists with a license we like. LOCI-7 mission spec investigates and chooses; if hand-rolled, the implementation is small enough to live entirely inside ARIA_MCP.

**Concurrent Bilby streams hitting the same Package.swift** — LOCI-1 and LOCI-3 both need to add new Swift Package files; they don't conflict on Package.swift directly because each ships a separate Package.swift in its own subdirectory. LOCI-7 introduces the new executable target and may need to touch an existing Package.swift — that's the one mission with cross-stream serialization risk. The dispatch ordering above handles it (LOCI-7 runs after the embedding-side streams have stabilized).

**Cross-encoder addition to default pipeline** — If Rev 1.x finds the cross-encoder is "always on" worthy, we re-evaluate the default-OFF stance. Latency budget allows it; the question is whether the extra recall justifies the per-query cost.

### 17.3 What we're explicitly choosing not to ship

These were considered and rejected for Rev 1.0:

- **iCloud Drive sync of the SQLite file.** Corruption risk from WAL desync during sync. CKSyncEngine in Rev 2.x is the right path.
- **Core Data + CloudKit.** Forces Core Data over our SQLite; fights sqlite-vec virtual tables. Wrong abstraction.
- **AAAK as a search mode.** Empirically regressive on benchmarks. Harness only.
- **Hard wing/room WHERE filters as default.** Recall regression. Available via opt-in `strictHierarchy: true` flag, documented as anti-pattern.
- **Bundling all three embedding models on every install.** Increases binary size unnecessarily. Rev 1.x lazy-download or build-time selection (config + just-in-time CoreML compilation). Rev 1.0 ships with all three for simplicity, accepting the ~750 MB bundled-model cost.
- **Real-time streaming search results.** MCP supports streaming; we don't use it for search because the latency budget is small enough that batching the full result is simpler. Revisit Rev 1.x if measured cold-start dominates.

---

## 18. Glossary

| Term | Definition |
|---|---|
| **AAAK** | MemPalace's compressed-symbolic dialect for representing memories. Lossy. Documented but not used as a search mode in Loci. |
| **bi-encoder** | Embedding model that produces a single vector per input. Fast, parallelizable, used for the candidate retrieval step. |
| **closet** | MemPalace's term for AAAK-compressed pointers to drawers. Not present in Loci as a first-class entity. |
| **cross-encoder** | Reranker model that takes (query, document) as joint input and produces a relevance score. Slower than bi-encoder, more accurate. Used optionally in Rev 1.x. |
| **drawer** | Verbatim text atom — the unit of storage. Has content, wing, room, embedding, source, timestamps. |
| **EmbeddingProvider** | Protocol abstraction for "convert text → vector." Three Rev 1.0 implementations: MiniLM, mpnet, EmbeddingGemma. |
| **fact** | Directed typed relationship between two entities, with optional validity window. Owned by GeniusLocusKit. |
| **Genius Mode** | ARIA_MCP deployment mode for full Simple Machines integration. Not in this spec. |
| **GLK / GeniusLocusKit** | Existing Swift Package — temporal entity-relationship graph. Vanilla and NodeTreeNative compositions. |
| **identity.txt** | Plain-text file at known path. L0 of the layered loading model. User-authored. |
| **L0/L1/L2/L3** | MemPalace's layered loading levels. L0=identity, L1=essential story, L2=on-demand, L3=deep search. |
| **LociKit** | New Swift Package this spec proposes — MemPalace surface composing GeniusLocusKit + CorpusKit. |
| **Loci Mode** | ARIA_MCP deployment mode for standalone AI memory. Subject of this spec. |
| **master key** | Capability key with full access. One per store. Generated at `nexus-mcp init`. |
| **MCP** | Model Context Protocol — JSON-RPC-over-stdio standard for AI agents to call tools. |
| **modelID** | Stable string tag identifying which embedding model produced a vector. Stored on every drawer/diary row. |
| **ARIA_MCP** | The standalone Swift binary `nexus-mcp` plus the ARIA_MCP library code that powers it. |
| **CorpusKit** | Vector storage Swift Package (sqlite-vec backend). Not yet built; mission scoped. |
| **read key** | Capability key permitting read tools only. Default for external MCP clients in Rev 1.0. |
| **room** | Metadata string on a drawer — second-level mnemonic grouping. Not a first-class table row. |
| **room_match** | Search-time signal: 1.0 if drawer's room matches query's predicted room, else 0. Contributes to hybrid re-rank score. |
| **soft delete** | Setting `tombstonedAt` on a row instead of removing it. Rev 2.0+. |
| **strictHierarchy** | Opt-in search flag that switches hierarchy from boost to filter. Anti-pattern; documented for compatibility. |
| **tombstone** | A row marked soft-deleted via `tombstonedAt`. Rev 2.0+. |
| **tunnel** | Cross-domain link between (wing, room) pairs. Optional drawer source. Stored in own table. |
| **Vanilla** | GeniusLocusKit composition: own SQLite store, no FNode coupling. The composition Loci uses for its KG side. |
| **verbatim-first** | MemPalace design pillar: store raw text without transformation; let semantic search surface it. Loci preserves this. |
| **wing** | Metadata string on a drawer — top-level mnemonic grouping. Not a first-class table row. |

---

## 19. References

- `/Users/bob/devlop/mootx01/docs/concepts/MOOTX01_SPEC.md` — current Nexus spec
- `/Users/bob/devlop/mootx01/GeniusLocusKit/README.md` — GLK shipped surface
- `/Users/bob/devlop/mootx01/docs/_internal/missions/MISSION_RAG_1_RAGKIT.md` — CorpusKit spec (re-used as LOCI-3)
- `/Users/bob/devlop/mootx01/docs/_internal/missions/MISSION_GLK_1_VANILLA.md` — GLK Phase 1 (shipped)
- `/Users/bob/devlop/mootx01/docs/_internal/missions/MISSION_GLK_2_NODETREE_NATIVE.md` — GLK Phase 2 (shipped)
- `github.com/asg017/sqlite-vec` — sqlite-vec extension and Swift distribution
- `huggingface.co/google/embeddinggemma-300m` — EmbeddingGemma 300M
- `huggingface.co/sentence-transformers/all-MiniLM-L6-v2` — MiniLM
- `huggingface.co/sentence-transformers/all-mpnet-base-v2` — mpnet
- Apple Foundation Models framework docs — `developer.apple.com/documentation/FoundationModels` (referenced for Genius Mode AI Assist, not Loci)
- Apple CKSyncEngine documentation (referenced for Rev 2.x sync)
- Apple NaturalLanguage framework (used for sentence-boundary chunking)
- Apple CoreML documentation (for embedding model conversion)

---

## 20. Notes for the morning review

This is a v0.1 draft. Expected revision points:

1. **The "RAG-1 mystery"** in §17.2 — Skippy investigates the actual state before LOCI-3 dispatches. Outcome may simplify or complicate the mission decomposition.
2. **Mode-naming stability** — "Genius" / "Loci" was locked. Confirm the inner-actor `Mode` enum case naming (`.loci(databaseURL:embeddingProvider:)`) is consistent with the product surface.
3. **Capability key storage** — Keychain vs SQLite table. Spec leaves this slightly open in §11.1; resolve before LOCI-7.
4. **Mission count and parallelization** — eight missions with three parallel streams is the proposed plan. Bob may want to compress further or add streams. Worth a sanity check against actual machine capacity.
5. **EmbeddingGemma license** — Bob said ship as default; spec documents the license caveat but does not ask Bob to re-confirm. If reviewing changes the call (e.g. Bob decides Apache-only is the right ethical position for a memory product), `mpnet-base-v2` becomes the default with a single config-default change in LOCI-4.
6. **AAAK harness as `LOCI-8`** — bundled with docs/migration. Could split out as `LOCI-9` if Bilby capacity allows. Sequencing-irrelevant; cosmetic.
7. **Q22/Q23/Q30–Q33** — answer or accept defaults at any time. Defaults won't block Rev 1.0 ship.

After Bob's review, Skippy revises this artifact, then authors individual Bilby mission files for LOCI-1 through LOCI-8 and dispatches them in waves per §16.

---

*End of draft v0.1.*
