---
title: VaultKit Interface
version: 1.1
status: active
spec_type: kit
authors: Bilby (stream vk), Newton (stream w2-vaultkit)
date: 2026-06-05
relates_to:
  - docs/decisions/ADR-VAULTKIT-001.md
  - docs/reference/GENIUSLOCUSKIT_INTERFACE_v0.8.md
  - docs/reference/LOCUSKIT_INTERFACE_v0.8.md
---

# VaultKit Interface

> **Recovery note (2026-06-03):** this document and the kit it describes
> were authored in stream `vk` but the worktree was reclaimed by the
> dispatch daemon before commit. This is the recovered interface spec;
> place it at `docs/reference/VAULTKIT_INTERFACE.md` when the kit is
> re-dispatched and merged. See the completion report.

> **Swift/Rust parity (2026-06-05):** the Rust crate
> `packages/kits/VaultKit/rust/` was added in stream `w2-vaultkit`
> (Newton). All public types now have Rust equivalents. See
> §§ Swift/Rust Concordance below.

VaultKit bridges a MOOT estate to a human-readable Markdown vault in both
directions. The substrate stays authoritative; the vault is a projection
(export) or an external source (import). Obsidian is the first adapter,
behind a modular `VaultAdapter` seam.

## Layer

VaultKit sits **above** GeniusLocusKit. It consumes the GLK verb surface
and LocusKit value types through their public products only. It modifies
no substrate primitive, schema, bitmap, or enum.

## Public types

### `NoteIR` (+ `Block`, `WikiLink`, `SourceRef`, `OccurredAt`)

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
    public var flattenedBody: String { get }
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

### `DrawerMapping`

`NoteIR` ⇄ `Drawer`/`Tunnel` over the GLK/LocusKit public API. Export
projects drawers + `.references` tunnels to notes. Import builds a
`CaptureFrame` per note (channel `.importedFile`, all five I-5 fields
non-empty, UDC from EideticLib or the `"000"` fallback, deterministic
`lineageID` from `stableSourceKey`) and `.references`/`.imported` tunnels
per wikilink.

### `VaultBridge` (facade)

```swift
public struct VaultBridge: Sendable {
    public init(kit: GeniusLocusKit,
                adapter: VaultAdapter = ObsidianAdapter(),
                mapping: DrawerMapping = DrawerMapping())
    public func export(estate handle: EstateHandle, to vaultURL: URL) async throws
    public func importVault(at vaultURL: URL, into handle: EstateHandle) async throws -> ImportReport
}

public struct ImportReport: Sendable, Equatable {
    public var drawersWritten, drawersUpdated, tunnelsCreated: Int
    public var itemsSkipped, fdcClassified, fdcUnclassified: Int
}
```

## ARIA_MCP tool family — `moot_vault_*` (stream va, ADR-VAULTKIT-002)

The Swift ARIA_MCP dispatch exposes `VaultBridge` (plus drift detection
and a candidate seam) as four tools, dispatched by name above the lexicon
projection like the recipe and lens tools (`ToolProvenance.vault`). The
shipped MCP binary is the Swift port, so this is the shipped surface; the
Rust mirror is deliberately deferred (ADR-VAULTKIT-002 decision a). All
four require `vaultPath`; `export`/`import` accept an optional `estateID`
(omit for the default estate).

| Tool | Args | Effect |
|---|---|---|
| `moot_vault_export` | `vaultPath`, `estateID?` | `VaultBridge.export`, then stamp the drift manifest. Result: note count + path. |
| `moot_vault_import` | `vaultPath`, `estateID?` | `VaultBridge.importVault`. Result: `ImportReport` counts. |
| `moot_vault_status` | `vaultPath` | Report manifest presence + note count + last-export time. Pure filesystem read. |
| `moot_vault_reconcile` | `vaultPath` | Re-hash notes, diff vs the manifest, return the drift set + candidates. |

### Drift manifest (A2-owned)

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
mounted in the MCP dispatch context (ADR-VAULTKIT-002 decision d). A2
produces candidates only: it writes no Proposal noun, and deletions are
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
`vault-kit`, lib target `vault_kit`). It was added in stream `w2-vaultkit`
(2026-06-05). One row per ported type.

| Swift type | Rust type | Module | Notes |
|---|---|---|---|
| `Block` | `Block` | `vault_kit::note_ir` | Identical field names (`kind`, `text`). `Block::markdown(text)` convenience matches Swift default. |
| `WikiLink` | `WikiLink` | `vault_kit::note_ir` | `alias: Option<String>` matches Swift `alias: String?`. |
| `SourceRef` | `SourceRef` | `vault_kit::note_ir` | `byte_size: Option<i64>` (Rust) vs `byteSize: Int?` (Swift). |
| `OccurredAt` | `OccurredAt` | `vault_kit::note_ir` | `iso8601: String` in both. No `Date`-typed field in Rust (language-neutral boundary). |
| `NoteIR` | `NoteIR` | `vault_kit::note_ir` | `flattenedBody` -> `flattened_body()`. `frontmatter: [String:String]` -> `HashMap<String,String>`. |
| `VaultAdapter` (protocol) | `VaultAdapter` (trait) | `vault_kit::vault_adapter` | `toIR(vaultURL:)` -> `to_ir(&Path)`. `fromIR(_:to:)` -> `from_ir(&[NoteIR], &Path)`. |
| `ObsidianAdapter` | `ObsidianAdapter` | `vault_kit::obsidian_adapter` | Identical parsing behavior. Round-trip equality holds. Hidden files skipped. |
| `DrawerMapping` | `DrawerMapping` | `vault_kit::drawer_mapping` | `classifyOnImport` -> `classify_on_import`. EideticLib not linked in Rust V1 (feature-flag-off path). |
| `DrawerMapping.ImportOutcome` | `ImportOutcome` | `vault_kit::drawer_mapping` | Same three cases: `Written`, `Updated`, `Skipped`. |
| `DrawerMapping.lineageID(forStableSourceKey:)` | `DrawerMapping::lineage_id(key)` | `vault_kit::drawer_mapping` | FNV-1a 128-bit. Produces byte-identical `UUID`/`Uuid` for all inputs. Verified by `tests/fnv_vector.rs`. |
| `ImportReport` | `ImportReport` | `vault_kit::vault_bridge` | `drawersWritten` -> `drawers_written`, etc. `Int` -> `usize`. |
| `VaultBridge` | `VaultBridge<'a>` | `vault_kit::vault_bridge` | Rust is synchronous (no `async`); `now: i64` (ms-since-epoch) passed by caller. |
| `VaultKitError` (n/a — Swift throws) | `VaultKitError` | `vault_kit::error` | `Io`, `AdapterError`, `I5Violation`, `VerbError` cases. |

### Conformance anchor

`DrawerMapping::lineage_id` (Rust) and `DrawerMapping.lineageID(forStableSourceKey:)` (Swift) are cross-language conformance anchors. Both implement FNV-1a 128-bit over the key's UTF-8 bytes with the standard constants, then pack the 128-bit result big-endian into 16 UUID bytes. The test file `packages/kits/VaultKit/rust/tests/fnv_vector.rs` asserts bit-identical output for five canonical inputs including the empty string (which hashes to the raw FNV-1a offset basis).

### Deferred (Rust V1)

- EideticLib FDC classification (structural support present, `classify_on_import` flag honoured, lookup always returns `None` — equivalent to the feature-flag-off path in Swift).
- Async `VaultBridge` methods (synchronous in Rust V1; the GLK Rust coordinator is synchronous).
- ARIA_MCP `moot_vault_*` Rust mirror (ADR-VAULTKIT-002 decision a; out of scope per mission scope limit).

## Out of scope (later missions)

Rust `moot_vault_*` ARIA_MCP mirror (now that VaultKit-Rust exists, a
follow-up mission wires it); CorpusKit RAG bundling; substrate-level
origin-date and `SourceRef` primitive (stream bp); attachment blob
custody; the watched-source scheduler and the real QueueKit enqueue
(leg a) + dream → Proposal → Debrief consumption (a later,
separately-gated mission). The ARIA_MCP `moot_vault_*` tool family and
drift detection are **delivered** by stream va (see the tool-family
section above and ADR-VAULTKIT-002).
