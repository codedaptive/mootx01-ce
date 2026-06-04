---
title: VaultKit Interface
version: 1.0
status: draft
spec_type: kit
authors: Bilby (stream vk)
date: 2026-06-03
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

## Out of scope (later missions)

Rust `moot_vault_*` mirror (future VaultKit-Rust-port mission); CorpusKit
RAG bundling; substrate-level origin-date and `SourceRef` primitive
(stream bp); attachment blob custody; the watched-source scheduler and the
real QueueKit enqueue (leg a) + dream → Proposal → Debrief consumption (a
later, separately-gated mission). The ARIA_MCP `moot_vault_*` tool family
and drift detection are **delivered** by stream va (see the tool-family
section above and ADR-VAULTKIT-002).
