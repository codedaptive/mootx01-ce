---
title: VaultKit Interface
version: 1.11.0
status: active
spec_type: kit
authors: MOOTx01 maintainers
date: 2026-06-28
description: Public interface contract for VaultKit — bidirectional bridge between a MOOTx01 estate and human-readable Markdown vaults, programmatic exchange formats, and MemPalace.
relates_to:
  - docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#62-note-identity-and-import-semantics
  - docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#61-ownership-and-trust-posture
  - docs/engineering/SYSTEM_ENGINEERING_REFERENCE.md#63-export-scope-and-drift
  - docs/reference/GENIUSLOCUSKIT_INTERFACE.md
  - docs/reference/LOCUSKIT_INTERFACE.md
---

# VaultKit Interface

VaultKit bridges a MOOTx01 estate to a human-readable Markdown vault in both
directions. The substrate stays authoritative; the vault is a projection
(export) or an external source (import). Obsidian is the first adapter,
behind a modular `VaultAdapter` seam.

## Layer

VaultKit sits **above** GeniusLocusKit. It consumes the GLK verb surface
and LocusKit value types through their public products only. It modifies
no substrate primitive, schema, bitmap, or enum.

## Public types

### `NoteIR` (+ `Block`, `WikiLink`, `SourceRef`, `OccurredAt`, `FactIR`)

The language-neutral intermediate representation. All `Codable`, flat,
no Swift-only boundary types — so a future non-Swift producer emits the
same IR with a mechanical port. `Block.kind` is an open string vocabulary.

```swift
public struct NoteIR: Codable, Sendable, Equatable {
    public var stableSourceKey: String
    public var body: [Block]
    public var frontmatter: [String: String]
    public var links: [WikiLink]
    public var tags: [String]
    public var originalPath: String
    public var originDate: OccurredAt?
    public var source: SourceRef?
    /// Stable substrate lineage UUID from the `moot_id` frontmatter key.
    /// When present, used as the lineageID on re-import instead of FNV(stableSourceKey),
    /// making the note's identity rename-safe. Set on export by DrawerMapping.noteIR;
    /// parsed on import by ObsidianAdapter. Carries drawer.lineageID (the STABLE UUID,
    /// not drawer.id which supersession re-mints).
    public var mootID: UUID?
    /// Full-fidelity fields (the data-movement contract Decision 1). All defaulted;
    /// JSON serialized before the extension decodes with these defaults.
    public var facts: [FactIR]            // default []
    public var pathComponents: [String]   // default [] — full hierarchy, ancestor → leaf; authoritative over originalPath (the joined back-compat view)
    public var scope: [String: String]    // default [:] — tool-defined namespace ids (per-user / per-agent / per-session); empty for Obsidian
    public var kind: String               // default "note" — open vocabulary; well-known: "note", "fact", "journal"
    public var flattenedBody: String { get }
}
```

### `FactIR`

One subject / predicate / object assertion riding a note — a KG fact in
the substrate, a graph relation in programmatic external memory tools.
Mapping facts to substrate nouns is adapter/bridge territory;
the IR guarantees no fact is lost in transit.

```swift
public struct FactIR: Codable, Sendable, Equatable {
    public var subject: String
    public var predicate: String
    public var object: String
    public var validFrom: String?    // ISO8601, consistent with OccurredAt; nil = valid since unknown/always
    public var validTo: String?      // ISO8601; nil = still valid / no recorded end
    public var confidence: Double?   // producer-reported, [0, 1]; nil = unscored
}
```

### `CorpusDocument` + `VaultKitError` (Swift)

THE versioned canonical interchange JSON per the data-movement contract Decision 1 — the
serialized form of a corpus; the JSON is the payload, never a per-tool
mapping DSL.

```swift
public enum VaultKitError: Error, Equatable, Sendable {
    case unsupportedFormatVersion(Int)
}

public struct CorpusDocument: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1
    public var formatVersion: Int
    public var name: String
    public var notes: [NoteIR]
    public init(name: String, notes: [NoteIR])      // stamps currentFormatVersion
    public func canonicalJSON() throws -> Data       // deterministic canonical encode
    public static func decode(_ data: Data) throws -> CorpusDocument  // strict versioned decode
}
```

**formatVersion policy.** Decode is strict: `formatVersion` is read FIRST
and any value other than `currentFormatVersion` throws
`VaultKitError.unsupportedFormatVersion(n)` before any note is parsed —
never silent best-effort decoding of an unknown shape. Bumping the
version requires a deliberate, versioned interface and conformance update; the
shapes are frozen within a format version. Decoding a
pre-extension `NoteIR` JSON (no `facts`/`pathComponents`/`scope`/`kind`
keys) succeeds with the documented defaults.

**Canonical form (cross-language byte-equality contract).** Object keys
sorted ascending; compact output; forward slashes unescaped; optional
fields omit their key when nil; the four full-fidelity fields always
serialize, even when empty; `mootID` serializes as the uppercase
hyphenated UUID string. Swift: `JSONEncoder` with
`[.sortedKeys, .withoutEscapingSlashes]`. Rust: serialize through
`serde_json::Value` (BTree-backed map → sorted keys). A shared golden
corpus-document fixture is exercised byte-for-byte by both test suites.

### `VaultExportScope`

Controls which drawers are included in an export. Mirrors LocusKit `Filter` chains.
Default is `.believed` — fixes the confirmed-drop bug of the old hard-coded `.unconfirmed`.

**Privacy-tier semantics (the data-movement contract Decision 2).** Sensitivity is NOT part
of any scope's `filterChain` — the bulk channel enforces the tier rules by
partition so exclusions are counted, never silent. Secret tier never rides
bulk export under any scope. Private tier (`.restricted`) is excluded by
default; only the explicit `.believedIncludingPrivate` opt-in includes it
(`includesPrivateTier == true`). Normal tier (`.normal` + `.elevated`)
exports freely. `DrawerMapping.export` appends `.sensitivityAtMost(.secret)`
to the chain so the recall evaluator's implicit `.normal` ceiling is
suppressed and every tier is visible for the partition. The owner-key
ceremony that will gate selecting `.believedIncludingPrivate` is
access-surface work; the scope is its enforcement hook.

```swift
public enum VaultExportScope: String, Sendable, CaseIterable {
    case believed    // [.currentlyBelieve, .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly]),
                     //  .any([.trustworthy, .requiresConfirmation])] — DEFAULT
    case believedIncludingPrivate = "believed-including-private"
                     // believed's chain; private tier admitted by the partition
    case exportable  // [.exportable, .currentlyBelieve, .any([.userConfirmed, .unconfirmed, .automatedConfirmedOnly])]
    case confirmed   // [.userConfirmed, .currentlyBelieve]
    case unconfirmed // [.unconfirmed, .currentlyBelieve] — the old hard-coded behavior
    public var includesPrivateTier: Bool { get }  // true only for .believedIncludingPrivate
    public var filterChain: [Filter] { get }
}
```

### `VaultAdapter` (protocol)

```swift
public protocol VaultAdapter: Sendable {
    func toIR(vaultURL: URL) throws -> [NoteIR]
    func fromIR(_ notes: [NoteIR], to vaultURL: URL) throws
}
```

### `ObsidianAdapter: VaultAdapter`

Markdown/YAML/wikilink/tag ⇄ `NoteIR`. One `.md` file → one `NoteIR`.
Round-trip safe: `toIR(fromIR(x)) == x` for Obsidian-representable fields.

**OKF v0.1 superset (default mode).** In default mode (`pureObsidianLinks = false`
/ `pure_obsidian_links: false`) the adapter emits output that is a valid OKF v0.1
document AND readable by Obsidian:

- **`type:` frontmatter key** (OKF's only required field): derived deterministically
  from `NoteIR.kind` — `"note"→"Note"`, `"fact"→"Fact"`, `"journal"→"Journal"`,
  else the kind with its first character uppercased. An existing `type:` frontmatter
  key from the producer is preserved.
- **Standard-md relationship links**: `[alias](relpath.md)` instead of `[[wikilinks]]`.
  The target name is resolved from a `name → stableSourceKey` map built from the
  full `notes` slice passed to `fromIR`; the vault-relative path is computed
  relative to the emitting note's folder. Unresolvable targets fall back to
  `[target](slug.md)` — never a dangling `[[ ]]`.
- **Frontmatter `tags:` array**: `tags: [a, b, c]` emitted in addition to any
  inline `#tag` tokens already in the body — OKF consumers read the frontmatter
  form; Obsidian reads both.
- **`index.md` per folder**: a minimal OKF progressive-disclosure index listing
  child notes as standard-md links. `index.md` and `log.md` are **skipped** during
  `toIR` / `to_ir` so they never import as spurious notes.

**Pure-Obsidian mode (`pureObsidianLinks = true` / `pure_obsidian_links: true`).**
Emits literal `[[Target]]` / `[[Target|Alias]]` wikilinks (legacy behaviour). The
`type:` and frontmatter `tags:` keys are still emitted in both modes — they are
harmless to Obsidian and required for OKF.

```swift
public struct ObsidianAdapter: VaultAdapter {
    public let pureObsidianLinks: Bool
    public init()                              // default: pureObsidianLinks = false
    public init(pureObsidianLinks: Bool)       // explicit control
    // internal OKF helpers
    static func okfType(from kind: String) -> String   // "note"→"Note" etc.
    static func parseAllLinks(in body: String) -> [WikiLink]   // wikilinks ∪ standard-md links
    static func parseStandardMDLinks(in body: String) -> [WikiLink]
    static func relativeMDPath(from sourceFolder: String, to targetPath: String) -> String
}
```

```rust
// Rust: vault_kit::obsidian_adapter
pub struct ObsidianAdapter {
    pub pure_obsidian_links: bool,
}
impl ObsidianAdapter {
    pub fn new() -> Self           // default: pure_obsidian_links = false
    pub fn with_options(pure_obsidian_links: bool) -> Self
}
// helpers
pub(crate) fn okf_type(kind: &str) -> String
pub(crate) fn parse_all_links(body: &str) -> Vec<WikiLink>
pub(crate) fn parse_standard_md_links(body: &str) -> Vec<WikiLink>
fn relative_md_path(source_folder: &str, target_path: &str) -> String
```

**Skip rule.** `toIR` / `to_ir` skips any `.md` file whose stem is `"index"` or
`"log"`. These are OKF navigation / diary files emitted by `fromIR` / `from_ir`
and must not round-trip as notes.

**Round-trip contract per mode.**
- Default OKF mode: link *targets* survive the round-trip (raw encoding may change
  wikilink → standard-md → back, but `WikiLink.target` is preserved).
- Pure-Obsidian mode: full `WikiLink` equality holds (body bytes are stable).
- Both modes: `type:`, frontmatter `tags:`, and all existing frontmatter keys survive.

### `ExchangeAdapter: VaultAdapter` + `ExchangeExport` (read + write)

The first programmatic-tool adapter (the data-movement contract Decision 1), both
directions. Decodes the external memory-tool JSON export
`{ name, entries: [{ id, content, tags?, facts?, pathComponents?, scope?, kind? }] }`
into `[NoteIR]` on the full-fidelity IR: `id` → `stableSourceKey`,
`content` → one `"markdown"` body block, `tags` → `tags`, extended
fields populated when present and defaulted when absent. Notes are
sorted by `stableSourceKey` (the `VaultAdapter` deterministic-order
contract). For this adapter the "vault" is the export FILE, not a
directory.

```swift
public struct ExchangeExport: Sendable, Equatable {
    public let name: String        // corpus-level metadata from the export
    public let notes: [NoteIR]
}

public struct ExchangeAdapter: VaultAdapter {
    public init()
    public func toIR(vaultURL: URL) throws -> [NoteIR]          // reads the export file
    public func decode(_ data: Data) throws -> ExchangeExport   // pure transform (wire path, read)
    public func fromIR(_ notes: [NoteIR], to vaultURL: URL) throws       // writes the export file
    public func encode(_ export: ExchangeExport) throws -> Data  // pure transform (wire path, write)
}
```

**Write side (the exit promise).** Per the data-movement contract Decision 4
gold item 7 ("programmatic export-my-data — exit promise real in both
forms"), the human-form exit is the Obsidian projection and the
programmatic form is this adapter's `fromIR`: a user can produce a
faithful, tier-respecting export document of their estate in the
external tool's own format, in both languages, with audit receipts.
`encode` is the canonical inverse of `decode` — `decode(encode(x)) == x`
for format-representable notes, and `encode(decode(bytes))` is
idempotent (byte-stable re-encode). Canonical form follows the
`CorpusDocument` conventions: entries sorted ascending by `id`, object
keys sorted, compact output, slashes unescaped — with one addition:
extended entry keys (`tags`/`facts`/`pathComponents`/`scope`/`kind`)
are omitted at their documented `NoteIR` defaults, so a legacy flat
note re-encodes in the legacy flat shape. A shared canonical-encode
fixture (the canonical encode of the golden fixture) is asserted
byte-for-byte by both suites.

The `VaultAdapter` protocol carries no corpus name, so `fromIR` derives
the document's `name` from the destination filename without its
extension (`…/my-estate.json` → `"my-estate"`); callers needing an
explicit name use `encode` with a `ExchangeExport`. Intermediate
directories are created as needed.

Fields the export format cannot carry (never silently dropped — this is
the documented enumeration, mirrored in the `encode` doc comments):
`frontmatter`, `links`, `originDate`, `source`, `mootID`, and `body`
block structure (`content` is the flattened body; blocks collapse to one
`"markdown"` block on re-read, non-`"markdown"` kinds not preserved).
`originalPath` is derived, not lost: it re-materializes as
`pathComponents.joined(separator: "/")` on decode.

The adapter is a pure transform of exactly the notes handed in: tier
filtering and audit receipts happen upstream in `VaultBridge.export`
before the adapter sees notes — the write side never
re-implements tier logic.

### `MemPalaceChromaAdapter: VaultAdapter` (MemPalace direct import)

The direct MemPalace → MOOTx01 importer. Reads ALL THREE MemPalace
stores under one palace root (`~/.mempalace`) **read-only**
(`SQLITE_OPEN_READONLY`; the palace is never written) and maps every
field into `NoteIR` — full fidelity, nothing dropped; anything without
a native `NoteIR` home rides `frontmatter` verbatim (keys un-prefixed).

```swift
public struct MemPalaceChromaAdapter: VaultAdapter {
    public var drawersCollection: String   // default "mempalace_drawers"
    public var closetsCollection: String   // default "mempalace_closets"
    public init(drawersCollection: String = "mempalace_drawers",
                closetsCollection: String = "mempalace_closets")
    /// vaultURL = the PALACE ROOT directory (e.g. ~/.mempalace)
    public func toIR(vaultURL: URL) throws -> [NoteIR]
    /// Always throws VaultKitError.adapterError — MemPalace is a source,
    /// never a destination (writes go through MemPalace itself).
    public func fromIR(_ notes: [NoteIR], to vaultURL: URL) throws
}
```

Palace layout read: `palace/chroma.sqlite3` (required — ChromaDB;
collections → METADATA segment → `embeddings` ⨝ `embedding_metadata`),
`tunnels.json` (optional; absent == empty, MemPalace `_load_tunnels`
semantics), `knowledge_graph.sqlite3` (optional; tables `entities`,
`triples`). Output sorted by `stableSourceKey` UTF-8 bytes.

**Field → NoteIR mapping (the complete contract; normative copy in the
Swift adapter header, implemented identically by the Rust port):**

| Store / field | NoteIR home |
|---|---|
| chroma `embedding_id` | `stableSourceKey` (raw, un-namespaced) |
| chroma `chroma:document` | `body` (single `"markdown"` block) |
| chroma `wing` / `hall` / `room` | `frontmatter` verbatim + `pathComponents` (in order, present components only); joined `"/"` → `originalPath` |
| chroma `filed_at` | `frontmatter["filed_at"]` verbatim + `originDate` (normalized, naive == UTC, fraction → milliseconds) |
| chroma `date` (diary) | `frontmatter["date"]` verbatim (+ `originDate` fallback) |
| chroma `source_file` | `frontmatter["source_file"]` + `source` (`SourceRef`, empty `contentHash` — MemPalace records no hash) |
| chroma `source_mtime` / `chunk_index` / `drawer_count` / `normalize_version` | `frontmatter[...]` — stringified BY SQLITE (`CAST(... AS TEXT)`), the cross-port float-determinism anchor |
| chroma `added_by` / `agent` / `topic` / `type` | `frontmatter[...]` verbatim |
| chroma `entities` (`"A;B;C"`) | `frontmatter["entities"]` verbatim + one `FactIR` per name: `(entity, "mentioned_in", embedding_id)` |
| chroma — any other metadata key | `frontmatter[key]` verbatim (unknown keys ride through) |
| chroma collection membership | `kind`: `"closet_summary"` (closets collection) / `"diary_entry"` (`type=diary_entry`) / `"drawer"` |
| tunnel `id` | `stableSourceKey` |
| tunnel `label` | `body` + `links[0].raw` (endpoint-rendered fallback when empty, I-5) |
| tunnel `target.wing/room` | `links[0].target = "<wing>/<room>"` + `frontmatter["target_wing"/"target_room"]` |
| tunnel `source.wing/room` | `pathComponents` + `frontmatter["source_wing"/"source_room"]` |
| tunnel `created_at` | `frontmatter["created_at"]` verbatim + `originDate`; `kind = "tunnel"` |
| KG entity `id` / `name` / `type` / `properties` / `created_at` | `stableSourceKey` / `body` (+`frontmatter["name"]`) / `frontmatter` verbatim / `originDate`; `kind = "kg_entity"`, placed `knowledge_graph/entities` |
| KG triple `subject`/`predicate`/`object`/`valid_from`/`valid_to`/`confidence` | `facts[0]` (`FactIR`; validity strings verbatim) + body `"s p o"`; `kind = "kg_triple"`, placed `knowledge_graph/triples` |
| KG triple `source_closet`/`source_file`/`source_drawer_id`/`adapter_name`/`extracted_at` | `frontmatter[...]` verbatim (non-NULL only); `source_file` also → `source`; `extracted_at` → `originDate` |

Timestamp normalization (`canonicalISO8601(fromMemPalace:)` /
`canonical_iso8601_from_mem_palace`) is a pure string transform of the
four MemPalace shapes (naive microseconds, `+00:00` offset, SQLite
`CURRENT_TIMESTAMP`, date-only) to LocusKit's canonical
`YYYY-MM-DDTHH:MM:SS.fffZ`; non-UTC offsets yield no `originDate` (the
verbatim string stays in frontmatter — nothing lost).

A shared fixture palace is asserted identically by both suites; a
guarded integration test in each suite reads the real `~/.mempalace`
when present.

### Palace exchange — outbound pump (`PalacePump` + the four-noun surface)

VaultKit is the canonical home for MemPalace exchange **with fidelity**, in
both directions (the Palace pump contract). The reverse
direction is `MemPalaceChromaAdapter` (above); the outbound direction is
`PalacePump` and its supporting types. The pump moves the WHOLE mootx01 data
model — drawers, tunnels, KG facts, diary entries — into a live MemPalace MCP
server, one item at a time, verified by read-back, paced, and resumable.

**The read seam.** VaultKit sits above GeniusLocusKit and does NOT read the
four nouns itself (that would invert the layering). The caller reads each noun
through GLK's public verbs and projects it to a `PalaceItem` — a noun
discriminator plus a native-field / envelope-field split. The caller injects
the `[PalaceItem]` stream into the pump; the pump owns the wire format.
`NoteIR` remains the drawer/Obsidian IR; `PalaceItem` is the generic
four-noun pump carrier.

**One versioned envelope.** Whatever a noun's MemPalace tool cannot carry
natively rides `PalacePayloadEnvelope` under a single fenced, versioned marker
`<!-- MOOT-ENVELOPE v1 … MOOT-ENVELOPE -->`. The body (drawer content, diary
entry, tunnel label) stays above the marker so MemPalace search still indexes
real prose; the unmappable fields are canonical JSON (sorted keys, no slash
escaping) so the Swift and Rust ports emit byte-identical envelopes. An empty
field map emits no envelope. `decode` refuses an unknown version rather than
silently dropping fields.

**Per-noun mapping (`PalacePumpMapping.call(for:)`).** Each noun maps to its
MemPalace write tool with the envelope folded into the tool's text-bearing arg:

| Noun | Tool | Native args | Envelope rides | Read-back verify |
|---|---|---|---|---|
| drawer | `mempalace_add_drawer` | wing, room, content, added_by | `content` (after body) | `get_drawer(drawer_id)` — id + body |
| tunnel | `mempalace_create_tunnel` | the four endpoints (+ drawer-id endpoints) | `label` (after human label) | `list_tunnels(wing)` — id present |
| KG fact | `mempalace_kg_add` | subject, predicate, object, valid_from | `source_closet` (unbounded) | `kg_query(entity)` — clean triple |
| diary | `mempalace_diary_write` | agent_name, entry, topic, wing | `entry` (after body) | `diary_read(agent_name)` — body |

The KG fact's envelope rides `source_closet` and **never** the `object` field:
MemPalace caps entity-name fields at 128 chars (`MAX_NAME_LENGTH`), so a large
envelope on the object is rejected — the original write-failure bug. The triple
stays clean and queryable.

**Drift gate (`PalaceDriftDetector`).** Before any write the pump diffs the live
`tools/list` against the expected manifest (the four write tools + the
`get_drawer`/`list_tunnels`/`kg_query`/`diary_read`/`list_drawers`/`search` read
tools), asserting name presence and required-arg facts. A renamed tool, a
removed required arg, or a new required arg the pump cannot supply halts the run
with a precise finding list — nothing is written.

**Response parsing (`PalaceResponseParsing`).** The assigned row id is parsed
per noun: `add_drawer`→`drawer_id`, `create_tunnel`→`id`, `kg_add`→`triple_id`,
`diary_write`→`entry_id`. The `already_exists` shape
carries the same key, so a duplicate still yields its id.

**Checkpoint / resume.** The Swift `PalacePump` checkpoints with QueueKit (each
item a job; resume from `new/`); the Rust port uses a dependency-free
maildir-style `CheckpointQueue` (it cannot enable serde_json's `preserve_order`
feature without breaking the kit-wide canonical-JSON byte-equality). The
caller keeps a human-inspectable flat-file `Checkpoint` for kill-resume
zero-duplicate semantics.

```swift
public enum PalaceNoun: String, Sendable, CaseIterable, Codable, Equatable {
    case drawer, tunnel, kgFact, diaryEntry
}
public struct PalaceItem: Sendable, Equatable {
    public let noun: PalaceNoun
    public let sourceID: String
    public let body: String
    public let nativeFields: [String: PalaceJSONValue]
    public let envelopeFields: [String: PalaceJSONValue]
}
public enum PalacePumpMapping {
    public static func call(for item: PalaceItem) throws -> PalaceCall
}
extension PalacePayloadEnvelope {
    public static func encodeFields(body: String, fields: [String: PalaceJSONValue]) throws -> String
    public static func decodeFields(content: String) throws -> DecodedFields
}
public struct PalacePump: Sendable {
    public func runItems(_ items: [PalaceItem]) async throws -> PalacePumpResult
}
```

### `CorpusProjection`

Feeds GLK's `verifyMigration` and the in-product fidelity benchmark from
the adapter pipeline: `stableSourceKey` → `id`, `flattenedBody` →
`content`, `tags` → `tags`. The retired GLK flat import verb's
remaining consumers read `ExternalCorpus` built here (or inline from
wire args), never from a kit-side JSON decode.

```swift
public enum CorpusProjection {
    public static func externalCorpus(name: String, notes: [NoteIR]) -> ExternalCorpus
}
```

### `DrawerMapping`

`NoteIR` ⇄ `Drawer`/`Tunnel` over the GLK/LocusKit public API. Export
projects drawers + `.references` tunnels to notes. Import builds a
`CaptureFrame` per note (channel `.importedFile`, all five I-5 fields
non-empty, UDC from EideticLib or the `"000"` fallback, deterministic
`lineageID` from `stableSourceKey`) and `.references`/`.imported` tunnels
per wikilink.

Export filename rule (Decision B1): stableSourceKey = `"<room>/<slug>"` where slug is
the first Markdown heading, else the first non-empty line, sanitized to `[a-z0-9-]`
max 60 characters, with UUID-prefix fallback. Wing rides the `wing:` frontmatter key
(not the path). `moot_id` frontmatter key carries `drawer.lineageID` (the STABLE UUID).

Identity resolution on import (priority order):
1. `NoteIR.mootID` (set by `ObsidianAdapter.toIR` from `moot_id` frontmatter)
2. `frontmatter["moot_id"]` → parse as UUID
3. FNV-1a 128-bit hash of `stableSourceKey`

### `VaultBridge` (Interface)

```swift
public struct VaultBridge: Sendable {
    /// Receipts are filed under this diary agent name ("vaultkit").
    public static let receiptAgentName: String
    public init(kit: GeniusLocusKit,
                adapter: VaultAdapter = ObsidianAdapter(),
                mapping: DrawerMapping = DrawerMapping())
    /// `scope` defaults to `.believed`. `now` is caller-supplied
    /// (determinism rule) and stamped on the audit receipt.
    @discardableResult
    public func export(estate handle: EstateHandle,
                       to vaultURL: URL,
                       scope: VaultExportScope = .believed,
                       now: Date) async throws -> ExportReport
    public func importVault(at vaultURL: URL,
                            into handle: EstateHandle,
                            now: Date,
                            mode: EncodeSpeed = .foreground) async throws -> ImportReport
    /// Path-scoped import: identical to importVault but restricts the
    /// import to notes whose vault-relative path is in `includingPaths`.
    /// Used by moot_vault_reconcile apply mode so only the M candidates
    /// (added + modified) are actioned, not the full N-note vault.
    /// Rust: import_vault_filtered(vault_path, &candidate_paths, handle, now).
    public func importVault(at vaultURL: URL,
                            includingPaths: Set<String>,
                            into handle: EstateHandle,
                            now: Date) async throws -> ImportReport
    /// Direct MemPalace import: all three palace stores read by
    /// MemPalaceChromaAdapter, then the same idempotent capture path
    /// as importVault (stable keys, tunnel dedup, audit receipt).
    public func importMemPalace(at palaceRoot: URL,
                                into handle: EstateHandle,
                                now: Date,
                                adapter: MemPalaceChromaAdapter = MemPalaceChromaAdapter()
                                ) async throws -> ImportReport
}

### `PalaceBridge` (direct palace import)

```swift
public struct PalaceBridge: Sendable {
    public init(kit: GeniusLocusKit)
    /// Import a MemPalace at `palaceRoot` directly into `handle`, bypassing NoteIR.
    ///
    /// Reads all three palace stores:
    ///   1. palace/chroma.sqlite3 — collections `mempalace_drawers` + `mempalace_closets`
    ///   2. tunnels.json — cross-wing connections
    ///   3. knowledge_graph.sqlite3 — KG entities and triples
    ///
    /// Applies four import guards: tombstone protection, content-idempotent dedup,
    /// sensitivity floor (never downgrades tier on re-import), and tunnel signature
    /// dedup (endpoint+kind pair). Files a diary receipt under VaultBridge.receiptAgentName.
    /// Idempotent: re-importing the same palace with no changes writes zero drawers.
    ///
    /// `now` is caller-supplied (determinism rule — never call Date() inside).
    @discardableResult
    public func importPalace(at palaceRoot: URL,
                             into handle: EstateHandle,
                             now: Date,
                             mode: EncodeSpeed = .foreground) async throws -> ImportReport
}
```

Rust: `PalaceBridge::new(&mut EstateCoordinator)` + `import_palace(palace_root: &Path, handle: &EstateHandle, now: i64, progress, mode: EncodeSpeed) -> Result<ImportReport, VaultKitError>` (synchronous). `ImportReport` fields: `drawers_written`, `drawers_updated`, `drawers_skipped_unchanged`, `drawers_skipped_tombstoned`, `tunnels_created`, `items_skipped`.

`mode` (`EncodeSpeed.foreground` default / `.background`) sets the post-import encode SPEED (drain QoS) only. The WRITE strategy is chosen automatically by source size (`streamThreshold` = 250k chroma rows): at or below → one bulk `captureBatch` transaction; above → per-item streaming so no single transaction holds the write lock across hundreds of thousands of rows. The caller never selects the write strategy.

Exposed as the `moot_palace_import` MCP tool (PAR-PB-1). Tool requires `estateID` + `palace_path` (absolute path to the palace root directory).

public struct ExportReport: Sendable, Equatable {
    public var notesExported: Int
    /// the data-movement contract Decision 2 tier-exclusion counts — reported, never silent.
    public var excludedSecretTier: Int   // secret never rides bulk export
    public var excludedPrivateTier: Int  // restricted, absent the explicit opt-in scope
    public var scope: VaultExportScope
}

public struct ImportReport: Sendable, Equatable {
    public var drawersWritten, drawersUpdated, tunnelsCreated: Int
    public var itemsSkipped, fdcClassified, fdcUnclassified: Int
    /// Zero-loss accounting (invariant C-13): per-field count of
    /// imported notes whose NoteIR value the mapping does not yet
    /// persist (tags, facts, scope, non-"note" kind, multi-level
    /// pathComponents). Recorded, never silent; full mapping deferred.
    public var fieldsDropped: [String: Int]
}
```

### Audit receipts (the data-movement contract Decision 2)

Every successful `export` and `importVault` run writes exactly ONE receipt
into the estate diary — "what left, where, when, how many." The bitmap-audit
trail is per-row and cannot carry an estate-level payload, so receipts use
the diary: the estate-level event log whose `migration` event class
(spec § 5.6) exists for data moving in or out of an estate.

Receipt diary entry shape (both ports):

| Field | Value |
|---|---|
| `agentName` | `"vaultkit"` (`VaultBridge.receiptAgentName`) |
| `topic` | `"vault-receipt"` |
| `wing` / `room` | `"wing_vaultkit"` / `"receipts"` |
| `filedAt` | caller-supplied `now` (Rust: `now / 1000`, the diary's epoch-seconds convention) |
| `embeddingModelID` | `"no-embedding"` |
| `operationalBitmap` | `DiaryEventClass.migration` ∣ `DiarySeverity.info << 4` ∣ `DiaryActorClass.migrationTool << 7` |
| `entry` | canonical JSON, fixed key order, identical across ports |

Entry JSON — export:
`{"operation":"vault-export","scope":"<raw>","destination":"<path>","notesExported":N,"excludedSecretTier":N,"excludedPrivateTier":N,"occurredAt":"<ISO8601>"}`

Entry JSON — import:
`{"operation":"vault-import","source":"<path>","drawersWritten":N,"drawersUpdated":N,"itemsSkipped":N,"tunnelsCreated":N,"occurredAt":"<ISO8601>"}`

Receipts are read back via the existing diary query surface:
`GeniusLocusKit.readDiaryEntries(in:agentName:lastN:)` (Swift) /
`EstateCoordinator::diary_entries(handle, agent_name, last_n)` (Rust)
with `agentName == VaultBridge.receiptAgentName`.

### Sensitivity frontmatter passthrough (the data-movement contract Decision 2)

Export writes a `sensitivity:` frontmatter key (`elevated` / `restricted` /
`secret` labels; `normal` omitted as the default) so the tier survives a
round trip. Import reads the key into `CaptureFrame.sensitivity` when the
adapter supplies it; absent or unrecognised labels land at the `.normal`
capture default. Import itself is ungated — arrival is free.

**Sensitivity floor on re-import (declassification defense).** A re-import
may RAISE a drawer's tier but never LOWER it. `moot_id` values ride exported
notes by design (round-trip identity), so without a floor a hostile vault
file carrying a victim's `moot_id` plus `sensitivity: normal` would
downgrade the victim drawer through the supersession cascade and then ride
bulk export. `VaultBridge.importVault` snapshots the current tier of every
believed drawer across all sensitivity levels and `DrawerMapping.importNote`
raises the incoming `CaptureFrame.sensitivity` to `max(incoming, existing)`
before capture. Both ports.

The raise direction is intentional: a re-import MAY promote a drawer to a
higher tier. A hostile vault file can therefore raise (but not lower) a
victim drawer's tier — a bounded, reversible denial of bulk export of that
one drawer. The owner re-lowers via the in-app sensitivity control
(`Estate.mutate(.correctSensitivity(...))`), NOT through the file channel —
lowering via an untrusted file is the exact attack the floor blocks, so the
asymmetry is by design.

## aria-mcp tool family — `moot_vault_*` (the Vault MCP contract)

The aria-mcp server exposes `VaultBridge` (plus drift detection and a
candidate seam) as four tools. Both the Swift and Rust ports are live. All
four require `vaultPath`; `export`/`import` accept an optional `estateID`
(omit for the default estate). `moot_vault_export` accepts an optional
`scope` argument (any `VaultExportScope` raw value, including
`"believed-including-private"` — the tool layer parses scopes
data-driven from the enum, so the private-tier case flows through with no
tool-surface change).

| Tool | Args | Effect |
|---|---|---|
| `moot_vault_export` | `vaultPath`, `estateID?`, `scope?` | `VaultBridge.export(scope:)`, then stamp the drift manifest. Result: note count + path + scope used. `scope` defaults to `"believed"`. |
| `moot_vault_import` | `vaultPath`, `estateID?` | `VaultBridge.importVault`. Result: `ImportReport` counts. |
| `moot_vault_status` | `vaultPath` | Report manifest presence + note count + last-export time. Pure filesystem read. |
| `moot_vault_reconcile` | `vaultPath` | Re-hash notes, diff vs the manifest, return the drift set + candidates. |

### Drift manifest (tool-layer owned)

VaultKit's export stamps no per-note hash, so the tool layer owns it.
`moot_vault_export` writes a sidecar manifest at `.moot/export-manifest.json`
inside the vault (a hidden dir → invisible to `ObsidianAdapter.toIR`'s
`.skipsHiddenFiles` enumerator), mapping each note's vault-relative path →
**SHA-256** (CryptoKit, a system framework). `reconcile` recomputes each
current `.md` file's SHA-256 and classifies: **added** (not in manifest),
**modified** (hash differs), **deleted** (in manifest, gone from disk).

### Candidate seam (return-only)

`reconcile` surfaces each added/modified file as a candidate
(`stableSourceKey`, vault path, new content hash) for the downstream
dreaming/Proposal loop. It is **return-only** — no QueueKit instance is
mounted in the MCP dispatch context (the Vault MCP contract decision d). The
tool layer produces candidates only: it writes no Proposal noun, and deletions are
reported, never actioned (no drawer is expunged).

## Invariants honoured

- **I-5**: every captured drawer carries non-empty content/room/udcCode/
  addedBy/embeddingModelID. Empty-content notes are skipped, never emitted.
- **No new substrate enum case, bitmap bit, or SQLite column.**
- **Idempotent on `stableSourceKey`**: re-import supersedes (drawer count
  stable) and de-duplicates tunnels by stable endpoint+label signature.
- **Dates** serialized in LocusKit's ISO8601 form (`.withInternetDateTime`
  + `.withFractionalSeconds`).

## Swift/Rust Concordance

The Rust crate lives at `packages/kits/VaultKit/rust/` (crate name
`vault-kit`, lib target `vault_kit`). One row per ported type.

| Swift type | Rust type | Module | Notes |
|---|---|---|---|
| `Block` | `Block` | `vault_kit::note_ir` | Identical field names (`kind`, `text`). `Block::markdown(text)` convenience matches Swift default. |
| `WikiLink` | `WikiLink` | `vault_kit::note_ir` | `alias: Option<String>` matches Swift `alias: String?`. |
| `SourceRef` | `SourceRef` | `vault_kit::note_ir` | `byte_size: Option<i64>` (Rust) vs `byteSize: Int?` (Swift). |
| `OccurredAt` | `OccurredAt` | `vault_kit::note_ir` | `iso8601: String` in both. No `Date`-typed field in Rust (language-neutral boundary). |
| `NoteIR` | `NoteIR` | `vault_kit::note_ir` | `flattenedBody` -> `flattened_body()`. `frontmatter: [String:String]` -> `HashMap<String,String>`. `mootID: UUID?` -> `moot_id: Option<Uuid>`. `NoteIR(mootID:)` -> `NoteIR::with_moot_id(…, moot_id)`. Full-fidelity fields: `facts` -> `facts: Vec<FactIR>`, `pathComponents` -> `path_components`, `scope: [String:String]` -> `scope: BTreeMap<String,String>` (deterministic iteration), `kind` -> `kind`. Rust derives `PartialEq` (not `Eq` — `FactIR.confidence: Option<f64>`). JSON keys are the Swift Codable names verbatim via serde renames. |
| `FactIR` | `FactIR` | `vault_kit::note_ir` | `validFrom`/`validTo`/`confidence` -> `valid_from`/`valid_to`/`confidence` (serde-renamed to the Swift keys). `FactIR::new(s, p, o)` = bare triple convenience. |
| `CorpusDocument` | `CorpusDocument` | `vault_kit::corpus_document` | `currentFormatVersion` -> `CURRENT_FORMAT_VERSION` (`i64`). `canonicalJSON()` -> `canonical_json() -> Result<String, VaultKitError>`. `decode(_:)` -> `CorpusDocument::decode(&str)`. Same strict version gate; same golden fixture byte-for-byte. |
| `VaultExportScope` | `VaultExportScope` | `vault_kit::vault_export_scope` | Same 5 cases (incl. `believedIncludingPrivate` -> `BelievedIncludingPrivate`). `filterChain: [Filter]` -> `filter_chain() -> Vec<Filter>`. `includesPrivateTier` -> `includes_private_tier()`. `rawValue` -> `as_str()`; `allCases` -> `all_cases()`. Rust `Default` = `Believed`. Rust uses `Filter::AutomatedConfirmedOnly` (mirrors Swift `automatedConfirmedOnly`). |
| `VaultAdapter` (protocol) | `VaultAdapter` (trait) | `vault_kit::vault_adapter` | `toIR(vaultURL:)` -> `to_ir(&Path)`. `fromIR(_:to:)` -> `from_ir(&[NoteIR], &Path)`. |
| `ObsidianAdapter` | `ObsidianAdapter` | `vault_kit::obsidian_adapter` | OKF v0.1 superset in default mode. `pureObsidianLinks: Bool` (Swift) / `pure_obsidian_links: bool` (Rust), default `false`. `init(pureObsidianLinks:)` (Swift) / `with_options(pure_obsidian_links)` (Rust). Default `init()`/`new()` unchanged (source-compatible). Emits `type:` frontmatter key, frontmatter `tags:` array, standard-md links (default) or wikilinks (pure mode), `index.md` per folder. Skips `index.md`/`log.md` on read. Both ports parse wikilinks AND standard-md links on read (`parseAllLinks`/`parse_all_links`). Hidden files skipped. Parses `moot_id` frontmatter key into `NoteIR.moot_id`. |
| `ExchangeAdapter` | `ExchangeAdapter` | `vault_kit::exchange_adapter` | `decode(_:)` -> `decode(&[u8])`; `encode(_:) -> Data` -> `encode(&ExchangeExport) -> Result<String, VaultKitError>`. Identical field mapping, stable-source-key sort, canonical write form, and filename-derived corpus name in `fromIR`/`from_ir`. Decode failure: Foundation `DecodingError` (Swift) / `VaultKitError::Serialization` (Rust); encode failure: Foundation `EncodingError` (Swift) / `VaultKitError::Serialization` (Rust). Shared decode and canonical-encode fixtures (the latter byte-for-byte) exercised by both suites. |
| `ExchangeExport` | `ExchangeExport` | `vault_kit::exchange_adapter` | `name` + `notes`, identical. |
| `MemPalaceChromaAdapter` | `MemPalaceChromaAdapter` | `vault_kit::mem_palace_chroma_adapter` | Identical three-store read (chroma collections, tunnels.json, KG), identical field mapping, byte-identical `originDate` normalization (`canonicalISO8601(fromMemPalace:)` -> `canonical_iso8601_from_mem_palace`). Numeric metadata stringified by SQLite `CAST` in both. Swift speaks the system SQLite3 C API; Rust uses `rusqlite` (bundled, same declaration as persistence-kit) — both `SQLITE_OPEN_READONLY`. A shared fixture palace is asserted by both suites. |
| `MCPStdioClient` | `McpStdioClient` | `vault_kit::mcp_stdio_client` | Local stdio MCP client (JSON-RPC 2.0, one object per line). Swift is an `actor` with `async` methods (`connect`/`listTools`/`callTool(_:arguments:)`/`disconnect`); Rust is a blocking struct (`connect(command)`/`list_tools`/`call_tool(name, Value)`). Both launch via `/usr/bin/env` with leading `KEY=value` env-prefix tokens. `MCPCallResult.textBlocks`/`rawResultJSON` -> `McpCallResult.text_blocks`/`raw_result_json`. |
| `PalaceJSONValue` | `serde_json::Value` | `vault_kit` (Swift `PalaceJSONValue.swift`) | The loosely-typed JSON carrier for the four-noun envelope-field maps. Swift defines a `PalaceJSONValue` Codable enum (null/bool/number/string/array/object) with canonical encoding + a `.foundationValue` bridge for `callTool`; Rust uses `serde_json::Value` natively. Both serialize maps key-sorted (Swift `.sortedKeys`; Rust `BTreeMap`) so envelopes are byte-identical. |
| `PalaceNoun` | `PalaceNoun` | `vault_kit::palace_item` | The four-noun discriminator (`drawer`/`tunnel`/`kgFact`/`diaryEntry`). Swift `enum: String` (lowerCamelCase raw values); Rust enum with `#[serde(rename)]` to the same raw values. Drives tool choice, the assigned-id key, the verify strategy. |
| `PalaceItem` | `PalaceItem` | `vault_kit::palace_item` | The language-neutral four-noun pump carrier: `noun`, `sourceID`/`source_id`, `body`, `nativeFields`/`native_fields`, `envelopeFields`/`envelope_fields`. The read seam — the caller projects each GLK noun to a `PalaceItem` and injects the stream (the Palace pump contract). Swift maps use `[String: PalaceJSONValue]`; Rust uses `BTreeMap<String, serde_json::Value>`. |
| `PalaceEnvelopePayload` | `PalaceEnvelopePayload` | `vault_kit::palace_payload_envelope` | The typed `NoteIR`-drawer envelope payload (frontmatter, links, tags, facts, …). Field names match the Swift Codable keys verbatim via serde renames. Used by the drawers-only `NoteIR` pump path. |
| `PalacePayloadEnvelope` (codec) | `palace_payload_envelope` (fns) | `vault_kit::palace_payload_envelope` | The ONE versioned envelope codec for all four nouns. Typed-payload path: `encode(body:payload:)`/`decode(content:)`/`reconstructNote(content:fallbackKey:)`. Generic four-noun path: `encodeFields(body:fields:)`/`decodeFields(content:)` -> `encode_fields`/`decode_fields`. Marker `<!-- MOOT-ENVELOPE v1 … MOOT-ENVELOPE -->`; canonical JSON (sorted keys, no slash escaping). Empty field map -> body unchanged (no empty envelope). `DecodeError`/`EnvelopeDecodeError`: `unsupportedVersion`/`unterminated`/`malformedJSON`. Byte-identical envelopes both ports — shared conformance vectors (bitmaps as integers to match Swift `JSONEncoder`). |
| `PalaceDrawerArgs` | `PalaceDrawerArgs` | `vault_kit::palace_pump_mapping` | The drawer-only `NoteIR` mapping result (wing/room/content/sourceFile/addedBy). `PalacePumpMapping.makeArgs(for:)` -> `make_args(note)`. |
| `PalaceCall` | `PalaceCall` | `vault_kit::palace_pump_mapping` | The four-noun mapping result: `tool` + `arguments` (`[String: PalaceJSONValue]` / `BTreeMap<String, serde_json::Value>`). `PalacePumpMapping.call(for:)` -> `call(item)` dispatches per noun to add_drawer / create_tunnel / kg_add / diary_write. KG envelope rides `source_closet` (never the 128-capped object); tunnel envelope rides `label`; an empty envelope sends no `source_closet`. |
| `PalacePumpMapping` | `palace_pump_mapping` | `vault_kit::palace_pump_mapping` | Tool-name constants (`addDrawerTool`/`createTunnelTool`/`kgAddTool`/`diaryWriteTool`/`getDrawerTool` -> `ADD_DRAWER_TOOL` etc.), `pumpActor`/`PUMP_ACTOR`, and the per-noun `placement`/`sanitize` for drawers. Pure, deterministic, byte-identical. |
| `PalaceResponseParsing` | `palace_response_parsing` | `vault_kit::palace_response_parsing` | `parseAddDrawerID`/`parseGetDrawer` -> `parse_add_drawer_id`/`parse_get_drawer`; `parseAssignedID(textBlocks:idKey:)` -> `parse_assigned_id`; `assignedIDKey(for:)` -> `assigned_id_key` (drawer→`drawer_id`, tunnel→`id`, kgFact→`triple_id`, diaryEntry→`entry_id`). `PalaceFetchedDrawer`/`PalaceResponseError` mirrored. |
| `PalaceDriftDetector` | `palace_drift_detector` | `vault_kit::palace_drift_detector` | `expectedManifest` -> `expected_manifest()`: the four write tools (one per noun) + read/verify tools (`get_drawer`/`list_tunnels`/`kg_query`/`diary_read`/`list_drawers`/`search`). `diff(live:expected:)` -> `diff(&live, &expected)`. `PalaceExpectedTool`/`PalaceLiveTool`/`PalaceDriftFinding`/`PalaceDriftError` mirrored; findings in deterministic order. |
| `PalacePump` | `PalacePump` | `vault_kit::palace_pump` | The outbound pump. Drawers-only `NoteIR` path: `enqueue`/`drain`/`run(estate:kit:scope:)`. Canonical four-noun path: `enqueueItems`/`drainItems`/`runItems(_:)` -> `enqueue_items`/`drain_items`/`run_items` (caller injects `[PalaceItem]`). Drift gate runs first. Per-noun write → assigned-id parse → read-back verify → checkpoint. Swift checkpoints with QueueKit (`PalaceItemJobPayload`); Rust uses a dependency-free maildir-style `CheckpointQueue` (avoids serde_json `preserve_order` feature unification — see module header). `PalacePumpItemResult`/`PalacePumpResult`/`PalacePumpError` mirrored. |
| `CorpusProjection.externalCorpus(name:notes:)` | `corpus_projection::external_corpus(name, notes)` | `vault_kit::corpus_projection` | Identical mapping to `genius_locus_kit::ExternalCorpus`. |
| `DrawerMapping` | `DrawerMapping` | `vault_kit::drawer_mapping` | `classifyOnImport` -> `classify_on_import`. EideticLib not linked in Rust V1 (feature-flag-off path). `slug(from:id:)` -> `slug(content, id)`. `sanitizeSlug(_:)` -> `sanitize_slug(input)`. `noteIR(from:references:)` -> `note_ir_from(drawer, refs)`. `export(kit:handle:scope:)` -> `export(coord, handle, now, scope)` — both return the tier-partitioned projection. `sensitivityLabel` / `sensitivity(fromLabel:)` -> `sensitivity_label` / `sensitivity_from_label` (identical label strings). |
| `DrawerMapping.ExportProjection` | `ExportProjection` | `vault_kit::drawer_mapping` | `notes` + `excludedSecretTier`/`excludedPrivateTier` -> `excluded_secret_tier`/`excluded_private_tier`. |
| `DrawerMapping.ImportOutcome` | `ImportOutcome` | `vault_kit::drawer_mapping` | Same three cases: `Written`, `Updated`, `Skipped`. |
| `DrawerMapping.importNote(…existingSensitivityByLineage:…)` | `import_note(…existing_sensitivity_by_lineage…)` | `vault_kit::drawer_mapping` | Both take a `[UUID:AdjectiveSensitivity]` / `HashMap<Uuid,AdjectiveSensitivity>` map and enforce the no-downgrade sensitivity floor (`max(incoming, existing)`). |
| `DrawerMapping.lineageID(forStableSourceKey:)` | `DrawerMapping::lineage_id(key)` | `vault_kit::drawer_mapping` | FNV-1a 128-bit. Produces byte-identical `UUID`/`Uuid` for all inputs, verified by a shared conformance vector. |
| `ImportReport` | `ImportReport` | `vault_kit::vault_bridge` | `drawersWritten` -> `drawers_written`, etc. `Int` -> `usize`. `fieldsDropped: [String: Int]` -> `fields_dropped: BTreeMap<String, usize>` (BTree for deterministic iteration). |
| `VaultBridge` | `VaultBridge<'a>` | `vault_kit::vault_bridge` | Rust is synchronous (no `async`); `now: i64` (ms-since-epoch) passed by caller (Swift: `now: Date`). `export(estate:to:scope:now:)` -> `export(handle, vault_path, now, scope)` — both return `ExportReport`. `receiptAgentName` -> `RECEIPT_AGENT_NAME`. `importMemPalace(at:into:now:adapter:)` -> `import_mem_palace(palace_root, handle, now, &adapter)` (Rust takes the adapter explicitly; Swift defaults it). Path-scoped import: `importVault(at:includingPaths:into:now:)` -> `import_vault_filtered(vault_path, &candidate_paths, handle, now)` — used by reconcile apply mode to action only the M candidates, not the full vault. Both share one private import core (`importNotes` / `import_notes`) with `importVault`. Both write the same diary receipts (see Audit receipts above). |
| `PalaceBridge` | `PalaceBridge<'a>` | `vault_kit::palace_bridge` | Direct MemPalace → substrate import that bypasses NoteIR entirely. Reads all three palace stores (chroma.sqlite3 with collections `mempalace_drawers` / `mempalace_closets`, tunnels.json, knowledge_graph.sqlite3) and constructs native `CaptureFrame`/`TunnelCaptureFrame` calls. Swift: `init(kit: GeniusLocusKit)`; Rust: `new(&mut EstateCoordinator)`. Applies four import guards (both ports): tombstone protection (withdrawn lineages not resurrected), content-idempotent dedup (unchanged active drawers skipped), sensitivity floor (re-import never downgrades tier), tunnel signature dedup (endpoint+kind signature prevents duplicates on re-import). KG entity and triple import also applies tombstone and content-idempotent guards. Files a diary receipt under `VaultBridge.receiptAgentName` (`"vaultkit"`) after each run. Swift: `async throws`; Rust: synchronous. `importPalace(at:into:now:)` -> `import_palace(palace_root, handle, now)` — both return `ImportReport`. Exposed as `moot_palace_import` MCP tool (PAR-PB-1). |
| `ExportReport` | `ExportReport` | `vault_kit::vault_bridge` | `notesExported` -> `notes_exported`, `excludedSecretTier` -> `excluded_secret_tier`, `excludedPrivateTier` -> `excluded_private_tier`, `scope` -> `scope`. |
| `VaultKitError` | `VaultKitError` | `vault_kit::error` | Rust: `Io`, `AdapterError`, `I5Violation`, `VerbError`, `UnsupportedFormatVersion`, `Serialization` cases. Swift: `unsupportedFormatVersion(Int)` + `adapterError(String)` (mirrors Rust `AdapterError`; used by `MemPalaceChromaAdapter`) — other adapter/bridge paths rethrow GLK and Foundation errors, and malformed corpus JSON surfaces as Foundation `DecodingError` (Rust's `Serialization` analogue). |
| `MCPClientError` | `McpClientError` | `vault_kit::mcp_stdio_client` | Swift: `public struct MCPClientError: Error` (a plain-struct error with a `message: String` field, wraps any JSON-RPC protocol failure as a single string). Rust: `pub enum McpClientError` with two cases: `Io(std::io::Error)` (wraps OS-level I/O) and `Protocol(String)` (any JSON-RPC protocol failure). Conceptually paired: both represent `MCPStdioClient`/`McpStdioClient` call failures. Names differ (`MCPClientError` / `McpClientError`) and shapes differ (Swift single-case struct / Rust two-case enum) — the Rust enum is more specific about the failure cause. | 
| `PalacePayloadEnvelope.Decoded` | `Decoded` | `vault_kit::palace_payload_envelope` | Swift: `public struct Decoded` nested inside `PalacePayloadEnvelope`; carries a typed-payload `decode(content:)` result with `body: String` and `payload: PalaceEnvelopePayload`. Rust: top-level `pub struct Decoded` — same fields, flat not nested. Shape difference: Swift nested / Rust flat — sanctioned Swift-nested / Rust-flat idiom. |
| `PalacePayloadEnvelope.DecodedFields` | `DecodedFields` | `vault_kit::palace_payload_envelope` | Swift: `public struct DecodedFields` nested inside `PalacePayloadEnvelope`; carries a generic-field `decodeFields(content:)` result with `body: String` and `fields: [String: PalaceJSONValue]`. Rust: top-level `pub struct DecodedFields` — same fields, flat not nested. Shape difference: Swift nested / Rust flat — sanctioned Swift-nested / Rust-flat idiom. |
| `PumpJobPayload` (Swift internal) | `PumpJobPayload` | `vault_kit::palace_pump` | Swift: `struct PumpJobPayload: Codable, Sendable, Equatable` (internal); QueueKit job payload for checkpointing a pump item. Rust: `pub struct PumpJobPayload` — same fields. Shape: Swift internal struct (used within Swift QueueKit checkpointing path); Rust pub struct (exposed because Rust's `CheckpointQueue` writes the payload directly, and callers may need the type for deserialization). Behaviour is parity-bound via the pump item round-trip tests. |

### Conformance anchor

`DrawerMapping::lineage_id` (Rust) and `DrawerMapping.lineageID(forStableSourceKey:)` (Swift) are cross-language conformance anchors. Both implement FNV-1a 128-bit over the key's UTF-8 bytes with the standard constants, then pack the 128-bit result big-endian into 16 UUID bytes. A shared conformance vector asserts bit-identical output for five canonical inputs including the empty string (which hashes to the raw FNV-1a offset basis).

### Deferred (Rust V1)

- EideticLib FDC classification (structural support present, `classify_on_import` flag honoured, lookup always returns `None` — equivalent to the feature-flag-off path in Swift).
- Async `VaultBridge` methods (synchronous in Rust V1; the GLK Rust coordinator is synchronous).
Note: the aria-mcp `moot_vault_*` Rust mirror is delivered (see the Vault identity-and-scope contract). the Vault MCP contract decision a is superseded by that document.

## Out of scope (later missions)

CorpusKit RAG bundling; substrate-level origin-date and `SourceRef` primitive;
attachment blob custody; the watched-source scheduler and the real
QueueKit enqueue (leg a) + dream → Proposal → Debrief consumption (a later,
separately-gated mission).

---

## Changelog

| Version | Date | Change |
|---|---|---|
| 1.11.0 | 2026-06-28 | Path-traversal hardening (planned lockdown). `ObsidianAdapter.fromIR(_:to:)` and `ExchangeAdapter.decode(_:)` now enforce vault containment as a security boundary. A shared `containedVaultURL(forRelativePath:under:)` helper (Swift) / `contained_vault_path` free function (Rust) validates every vault-relative path before any filesystem access: rejects `..`, absolute prefixes, backslash separators, empty and `.` components (lexical phase). A second pass via `ensureContainedInVault(_:under:)` (Swift) / `write_contained_file` (Rust) re-checks the fully-resolved path with symlink expansion (`resolvingSymlinksInPath` / `canonicalize`) and rejects pre-existing symlinks at the destination. `ExchangeAdapter.decode` validates `pathComponents` entries with the same lexical rules before projecting them to `NoteIR`. Both phases share identical rejection vocabulary across Swift and Rust. Errors surface as `VaultKitError.adapterError` (Swift) / `VaultKitError::AdapterError` (Rust) — fail-closed, never silent. Both ports. |
| 1.10.0 | 2026-06-25 | T7 (one engine, many gates): `importVault` / `importVault(includingPaths:)` / `importMemPalace` and the shared `importNotes` core replace `batch: bool` with `mode: EncodeSpeed` — matching `importPalace` (T1). All source gates (MemPalace, Obsidian, OKF, Markdown vaults) now run the SAME ingest policy: encode SPEED is caller-declared, the bulk-vs-stream WRITE strategy is size-gated automatically via the new single-source `ImportPolicy` (`streamThreshold` = 250k; Rust `import_policy`). Each importer calls `setEncodeSpeed(mode)` then size-gates by item count, so adding a gate never re-invents the write strategy. Both ports. |
| 1.9.0 | 2026-06-25 | T1 (encode mode): `importPalace` / `import_palace` replace the `batch: bool` arg with `mode: EncodeSpeed` (`.foreground` default / `.background`) — encode SPEED (drain QoS) only. The WRITE strategy is now chosen automatically by source size (`streamThreshold` = 250k rows): ≤ threshold → one bulk `captureBatch` transaction; above → per-item streaming. The caller no longer selects the write strategy. Both ports. |
| 1.8.0 | 2026-06-22 | Added `PalaceBridge` — direct MemPalace → substrate import bypassing NoteIR (PAR-PB-1). Reads three palace stores (chroma.sqlite3, tunnels.json, knowledge_graph.sqlite3). Four import guards: tombstone, content-idempotent dedup, sensitivity floor, tunnel signature dedup. Swift `async`; Rust synchronous. Exposed as `moot_palace_import` MCP tool. Added concordance row and public struct documentation. |
| 1.7.0 | 2026-06-18 | `ObsidianAdapter` extended to be an OKF v0.1 superset. Added `pureObsidianLinks` flag (Swift `Bool`) / `pure_obsidian_links: bool` (Rust), default `false`. Default mode emits `type:` frontmatter key (OKF required), frontmatter `tags:` array, standard-md `[alias](relpath.md)` links, and one `index.md` per folder. Pure-Obsidian mode (`true`) emits `[[wikilinks]]` (legacy). Both ports read unified wikilinks + standard-md links via `parseAllLinks`/`parse_all_links`. `index.md`/`log.md` skipped on import. All existing callers of `ObsidianAdapter()`/`new()` remain source-compatible (defaulted param). |
| 1.6.0 | 2026-06-14 | (prior) |
