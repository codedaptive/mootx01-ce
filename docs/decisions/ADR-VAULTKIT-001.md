---
status: decided
question: How does VaultKit bridge a MOOT estate to a human-readable Markdown vault in both directions without altering the substrate?
authors: MOOTx01 maintainers
date: 2026-06-03
relates_to:
  - docs/reference/VAULTKIT_INTERFACE.md
  - docs/reference/GENIUSLOCUSKIT_INTERFACE_v0.8.md
  - docs/reference/LOCUSKIT_INTERFACE_v0.8.md
supersedes: none
context:
  - Net-new Tier-3 implementation task; zero edits to existing code.
  - Inverts Karpathy's "LLM maintains a Markdown wiki" pattern — the substrate stays authoritative; the vault is a projection (export) or external source (import).
  - First adapter is Obsidian, behind a modular VaultAdapter seam.
---

# ADR-VAULTKIT-001 — VaultKit: Obsidian bidirectional core

## Context

`VaultKit` is a new kit one layer above `GeniusLocusKit`. It exports a
MOOT estate to a Markdown vault (drawers → notes, `.references` tunnels →
wikilinks, wing/room → folders, provenance/anchors → frontmatter) and
imports a vault back into an estate through the public capture seam. The
substrate is never the wiki; the vault is a view of, or a source for, the
authoritative substrate.

This record captures the seven load-bearing decisions taken while
building the V1 core.

## Decision (a) — Imported content folds into FDC, it is not a sealed estate

Imported notes are captured as ordinary drawers in the holding estate via
the GeniusLocusKit `capture` verb. They participate in the same lattice,
recall, and audit machinery as natively-captured content. We did **not**
build a separate "sealed import estate." Rationale: the whole point of the
bridge is that an imported vault becomes first-class memory; quarantining
it behind a second estate boundary would defeat recall and cross-linking.

## Decision (b) — Attachments are referenced by file, not blobbed

`SourceRef` is a pointer (`path` + `contentHash` + optional `mime` /
`byteSize`), never the bytes. VaultKit does not copy attachment blobs into
the substrate. Rationale: vaults can hold large binaries; the substrate's
verbatim-content pillar is about text, and blob custody is a separate
concern. Promotion of `SourceRef` to a substrate primitive is a future
Tier-1 mission (Stream bp); here it is a kit-level value type that rides
frontmatter.

## Decision (c) — A modular `VaultAdapter` seam

The format-specific logic (Markdown/YAML/wikilink/tag parsing and
emission) lives behind a `VaultAdapter` protocol. `ObsidianAdapter` is the
first conformer. `DrawerMapping` and `VaultBridge` never name a concrete
adapter, so a Joplin / Bear / Logseq / plain-Markdown adapter adds with no
core change. Rationale: the substrate-facing mapping and the format-facing
parsing change for different reasons and at different rates.

## Decision (d) — Imported tunnels are tagged `.imported`

Each `[[wikilink]]` becomes a `Tunnel(kind: .references, originClass:
.imported)`. The `.imported` origin class (raw 2, already in
`TunnelOriginClass`) records that the edge entered via the import path, so
later drift detection and provenance queries can distinguish imported
edges from user-asserted or agent-derived ones. No new enum case was
introduced.

## Decision (e) — Swift-first V1

V1 ships Swift only (Bob-confirmed). The bridge's heavy lifting is
filesystem traversal and Markdown/YAML parsing, and the only V1 consumers
are the macOS app and the ARIA_MCP Swift side. No Rust `VaultKit` target
is added in this implementation task.

> **Superseded (2026-06-06).** This decision no longer holds. A subsequent
> workstream ported the entire VaultKit crate to Rust
> (`packages/kits/VaultKit/rust/` — NoteIR, VaultBridge, DrawerMapping,
> ObsidianAdapter, VaultAdapter) and wired the Rust `moot_vault_*` tools
> (`apps/ARIA_MCP/rust/src/vault_tools.rs`), conformance-gated
> (PARITY_WAVE_PROGRESS, 2026-06-05). VaultKit ships **Swift + Rust at
> parity**. Per the parity-is-absolute standing rule (Bob, 2026-06-06 —
> "we wouldn't do a swift-only version"), Swift-only is not a shippable
> end state.

## Decision (f) — Language-neutral `NoteIR` boundary

`NoteIR` (and `Block`, `WikiLink`, `SourceRef`, `OccurredAt`) is the
contract a future non-Swift producer — the Feature-B archive/email engine,
which may be Rust or Python-via-Rust — will also emit. Its shape is
therefore serializable JSON: every type is `Codable`, fields are flat, and
no boundary type uses a Swift-only enum with associated values. `Block.kind`
is an **open string vocabulary** rather than a closed enum precisely so an
outliner adapter can introduce a new block kind without reshaping the IR.
The Swift types are the V1 *home* of the contract, not the contract
itself. This is the one decision expensive to reverse; the whole adapter
and archive family inherits `NoteIR`.

## Decision (g) — I-5 fallback-UDC policy

Invariant I-5 binds: `capture` rejects any frame with an empty `content`,
`room`, `addedBy`, `embeddingModelID`, or `latticeAnchor.udcCode`. Import
must therefore supply a non-empty UDC on every drawer. The policy, in
priority order:

1. An explicit frontmatter `udc` (a pre-classified note) is used as-is.
2. Otherwise, when FDC classification is enabled, `EideticLib.lookup`
   is consulted; a **live, resolved** anchor (non-empty `.code`) is used.
3. Otherwise the deterministic fallback `"000"` is used — the repo's
   established sentinel for unclassified/migrated content (GeniusLocusKit
   `MigrationAPI`).

FDC classification is a **soft, feature-flagged dependency**. EideticLib's
Rust `lookup` is a stub today and the Swift side resolves only when its
FDC bundle is present; the bridge keys on `anchor.code.isEmpty`, so when
classification is unavailable the drawer lands with the fallback UDC plus
full provenance and original-path frontmatter. Classification is skipped,
never faked. The `ImportReport` counts FDC-classified vs. unclassified so
the asymmetry is visible to the caller.

### Idempotency note (consequence of the capture seam)

Import is idempotent on `stableSourceKey`. VaultKit derives a
deterministic `lineageID` from that key (FNV-1a 128-bit over the key's
UTF-8 bytes — non-cryptographic, dependency-free, language-neutral). A
re-import of the same note carries the same lineage, so the substrate's
**supersession cascade** updates the drawer rather than duplicating it;
the currently-believed drawer count stays stable.

For tunnels, the substrate's standalone tunnel capture performs a bare
insert with no native canonicalisation, and the supersession cascade
re-mints the drawer id, so a drawer-id-based dedup would not hold across
re-imports. VaultKit therefore keys tunnel idempotency on a **stable
endpoint+label signature** (`sourceWing`, `sourceRoom`, `targetRoom`,
`label`, `kind`), checked against the existing tunnels read back before
insert. This is read-check-before-insert over the substrate's own read
API, not a second dedup store. Known V1 limitation: two notes in the same
room linking the same target with the same label collapse to one tunnel;
disambiguation is deferred to A2 (Stream va), which owns drift detection.

## Disposition

Decided and implemented. All seven decisions are reflected in
`packages/kits/VaultKit/` and the V1 test suite (round-trip, idempotency,
feature-flag-off, I-5 guard, end-to-end export→import). No substrate enum
case, bitmap bit, or SQLite column was introduced.

## Open questions (deferred, not blocking)

- Substrate-level origin-date field (currently rides frontmatter) — a
  future Tier-1 primitive implementation task.
- `SourceRef` promotion to a substrate primitive — a future implementation task.
- Attachment blob custody — out of scope; pointer-only in V1.
- Per-note tunnel-source disambiguation — a subsequent implementation task.
- RAG bundling of imported bodies (CorpusKit) — a later implementation task.
