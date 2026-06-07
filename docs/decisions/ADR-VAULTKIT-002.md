---
status: decided
question: How does ARIA_MCP expose VaultKit's VaultBridge as a tool family, detect vault drift, and feed vault edits to the downstream loop without touching the substrate, QueueKit, or the Rust port?
authors: MOOTx01 maintainers
date: 2026-06-03
relates_to:
  - docs/reference/VAULTKIT_INTERFACE.md
  - docs/decisions/ADR-VAULTKIT-001.md
  - docs/decisions/DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.md
supersedes: none
context:
  - Bounded-additive change; adds a moot_vault_* tool family to the Swift ARIA_MCP dispatch.
  - Prerequisite: VaultBridge (export/importVault) is importable.
  - The shipped MCP binary is the Swift port (installer/install.sh builds mootx01-mcp via swift build); the Rust aria-mcp bin is a parity sibling.
---

# ADR-VAULTKIT-002 — ARIA_MCP VaultKit tool family, drift detection, candidate seam

## Context

This change exposes VaultKit's `VaultBridge` to MCP clients as the
`moot_vault_*` tool family (`export`, `import`, `status`, `reconcile`),
adds drift detection, and wires a candidate-enqueue seam so vault edits
become queued candidates for the downstream dreaming/Proposal loop. It
produces candidates only; it never builds the dreaming loop or writes
Proposals. This record captures the three load-bearing decisions, plus
the two seam decisions reality forced.

## Decision (a) — The Swift-only tool family is intentional, not drift

The shipped MCP binary is the **Swift** port: `installer/install.sh`
builds it with `swift build -c release --product mootx01-mcp`. The Rust
`aria-mcp` bin is a parity/test sibling, not the shipped runtime. VaultKit
is Swift-first and ships **no Rust target** (ADR-VAULTKIT-001 decision e),
so there is nothing on the Rust side to mirror yet. The `moot_vault_*`
family is therefore wired in the Swift dispatch (`Sources/AriaMCP/...`)
only. The Rust `moot_vault_*` mirror is **deliberately deferred** to the
future VaultKit Rust port. This asymmetry is documented and
intentional; the unmirrored Rust side is not drift.
The tools carry a dedicated `ToolProvenance.vault` so the projection is
self-describing.

## Decision (b) — Drift = exact SHA-256 compare against an A2-owned export manifest

Drift detection compares each vault file's current content hash to the
hash stamped at export. **Stream vk stamps no per-note hash:**
`DrawerMapping.noteIR` writes no hash frontmatter key, `ObsidianAdapter`
renders only frontmatter + body, and the only `contentHash` in VaultKit
is `NoteIR.Attachment.contentHash` (attachment-only, never populated on
note export — `source: nil`). `VaultBridge` itself records that drift
detection "is A2 (Stream va), not here."

So A2 owns the stamp. `moot_vault_export` writes a **sidecar manifest** at
`.moot/export-manifest.json` inside the vault after a successful bridge
export, mapping each note's vault-relative path → **SHA-256** content hash
(plus an `exportedAt` ISO8601 timestamp and note count for `status`). The
`.moot` directory is hidden, so `ObsidianAdapter.toIR`'s `.skipsHiddenFiles`
enumerator never mis-reads the manifest as a note on re-import.

SHA-256 is chosen because drift needs **file-identity** detection (did
these bytes change?), not semantic similarity. The substrate's SimHash /
Fingerprint256 primitives answer a different question and are not used
here. SHA-256 is supplied by **CryptoKit**, an Apple system framework
already used across the repo (LocusKit, PersistenceKit, ConvergenceKit) —
no third-party dependency, consistent with the Metal carve-out in CLAUDE.md.

`moot_vault_reconcile` re-hashes the current `.md` set and diffs against
the manifest: a path absent from the manifest is **added**, a path whose
SHA-256 differs is **modified**, a path in the manifest but gone from disk
is **deleted**. Deletions are **reported, never actioned** — no drawer is
expunged; deletion handling is a human-confirmed downstream decision.

## Decision (c) — A2 produces candidates only; it never consumes or writes Proposals

The candidate-enqueue seam stops at "here are the changed files." For each
added/modified file, reconcile surfaces a candidate carrying the
`stableSourceKey` (the vault-relative path without `.md` — the same key
`DrawerMapping` derives on export), the vault path, and the new content
hash — enough for the downstream loop to parse and stage. **A2 does not
parse edits into Proposals and writes to no Proposal noun.** Consumption
(dream → staged Proposal → Debrief) is later, separately-gated work.

## Decision (d) — Candidate seam is return-only (QueueKit leg b)

QueueKit's only public enqueue is `QueueKit.send(_ job: Job)`, which
requires a **mounted QueueKit instance** (a root URL + an `HLCGenerator`
clock). The `ToolDispatcher` carries only `kit` + `handle` — no queue
instance — and wiring one (choosing a queue root, threading an HLC clock
through `Server` → dispatcher) would exceed this change's bounded-additive
scope and break the determinism rule (an HLC clock is wall-clock state).
A `Job` is also a dispatch record, not a natural "vault candidate." So
reconcile **returns** the candidate list in its tool result; enqueue is
deferred to the gated downstream work. No QueueKit API is invented or
extended (QueueKit is left unmodified).

## Decision (e) — ARIA_MCP gains an in-repo dependency on VaultKit

`apps/ARIA_MCP/Package.swift` adds a path dependency on VaultKit (package
`dependencies`, the `AriaMCP` target, and the `AriaMCPTests` target) so the
handlers can call `VaultBridge`. This is permitted under
`DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28`: an in-repo dependency added
because a recorded architectural decision (this ADR) requires it. Layering
is downstream → upstream (ARIA_MCP app → VaultKit kit); no inversion.
VaultKit is in-repo, so the C-1 zero-external-dependency constraint is
unaffected.

## Disposition

Decided and implemented in stream va. The four `moot_vault_*` tools list
and dispatch on the Swift binary; drift detection is an exact SHA-256
compare against the A2-owned manifest; the candidate seam is return-only;
no substrate, schema, or QueueKit API changed. Existing ARIA_MCP dispatch
tests pass unchanged (additive-only).

## Open questions (deferred, not blocking)

- Rust `moot_vault_*` mirror — the future VaultKit Rust port.
- Wiring a real QueueKit instance into ARIA_MCP so reconcile enqueues
  (leg a) instead of returning — gated downstream work that also
  builds the dream → Proposal → Debrief consumption side.
- Deletion handling (human-confirmed drawer expunge) — downstream.
- Per-note tunnel-source disambiguation (carried over from ADR-VAULTKIT-001) — still open.

## Addendum (2026-06-06) — Decision (a) superseded: VaultKit is Swift + Rust at parity

Decision (a) recorded a **Swift-only** `moot_vault_*` tool family with the
Rust mirror "deliberately deferred," on the premise (ADR-VAULTKIT-001
Decision (e)) that VaultKit ships no Rust target. **That premise is
superseded.** The Rust parity work (2026-06-05 — two days after this ADR)
completed:

- the **VaultKit Rust crate** (`packages/kits/VaultKit/rust/` — NoteIR,
  VaultBridge, DrawerMapping with FNV-1a 128-bit lineageID, VaultAdapter,
  ObsidianAdapter), conformance-gated; and
- the **Rust `moot_vault_*` wiring** (`apps/ARIA_MCP/rust/src/vault_tools.rs`
  + `tool_list.rs`), backed by `vault-kit`.

VaultKit now ships **Swift + Rust at parity**. The open question "Rust
`moot_vault_*` mirror — future work" is therefore **CLOSED (done)**, and
the earlier guidance that the unmirrored Rust side was not drift no longer
applies — the Rust side **is** mirrored and parity *is* the bar.
Per the parity-is-absolute standing rule, a Swift-only kit is not a
shippable end state.
