---
status: decided
question: How does aria-mcp expose VaultKit's VaultBridge as a tool family, detect vault drift, and feed vault edits to the downstream loop without touching the substrate, QueueKit, or the Rust port?
authors: MOOTx01 maintainers
date: 2026-06-06
relates_to:
  - docs/reference/VAULTKIT_INTERFACE.md
  - docs/decisions/ADR-VAULTKIT-001.md
  - docs/decisions/DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28.md
supersedes: none
context:
  - Additive change; adds a moot_vault_* tool family to the aria-mcp dispatch.
  - Prerequisite VaultKit implementation is merged — VaultBridge (export/importVault) is importable.
  - As authored (2026-06-06), the shipped MCP binary was the Swift port and the Rust aria-mcp bin was a parity sibling. Decision (a)'s Swift-only premise was superseded the same day by the Addendum — VaultKit and the Rust moot_vault_* mirror now ship at parity. The ADR as a whole remains decided and implemented.
---

# ADR-VAULTKIT-002 — aria-mcp VaultKit tool family, drift detection, candidate seam

> **Decision (a) below is SUPERSEDED (2026-06-06).** VaultKit now ships
> Swift + Rust at parity; the Swift-only premise and the "do not flag the
> unmirrored Rust side as drift" guidance no longer apply. See the
> [Addendum](#addendum-2026-06-06--decision-a-superseded-vaultkit-is-swift--rust-at-parity).

## Context

This change exposes VaultKit's `VaultBridge` to MCP clients as the
`moot_vault_*` tool family (`export`, `import`, `status`, `reconcile`),
adds drift detection, and wires a candidate-enqueue seam so vault edits
become queued candidates for the downstream dreaming/Proposal loop. It
produces candidates only; it never builds the dreaming loop or writes
Proposals. This record captures the three load-bearing decisions flagged
in scope, plus the two seam decisions reality forced.

## Decision (a) — The Swift-only tool family is intentional, not unresolved drift

> **SUPERSEDED 2026-06-06** — see the Addendum. VaultKit now ships a Rust
> target and the Rust mirror exists; the reasoning below is retained for
> the historical record only.

The shipped MCP binary is the **Swift** port, built with
`swift build -c release --product mootx01-mcp`. The Rust
`aria-mcp` bin is a parity/test sibling, not the shipped runtime. VaultKit
is Swift-first and ships **no Rust target** (ADR-VAULTKIT-001 decision e),
so there is nothing on the Rust side to mirror yet. The `moot_vault_*`
family is therefore wired in the Swift dispatch only. The Rust
`moot_vault_*` mirror is **deliberately deferred** to a future
VaultKit-Rust-port implementation. This asymmetry is documented
and intentional; a post-implementation review must not flag the unmirrored
Rust side as drift.
The tools carry a dedicated `ToolProvenance.vault` so the projection is
self-describing.

## Decision (b) — Drift = exact SHA-256 compare against an export manifest owned by the tool family

Drift detection compares each vault file's current content hash to the
hash stamped at export. **VaultBridge stamps no per-note hash:**
`DrawerMapping.noteIR` writes no hash frontmatter key, `ObsidianAdapter`
renders only frontmatter + body, and the only `contentHash` in VaultKit
is `NoteIR.Attachment.contentHash` (attachment-only, never populated on
note export — `source: nil`). `VaultBridge` itself records that drift
detection is the tool family's responsibility, not its own.

So the tool family owns the stamp. `moot_vault_export` writes a **sidecar manifest** at
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
no third-party dependency, consistent with the Metal carve-out in the package-dependency policy.

`moot_vault_reconcile` re-hashes the current `.md` set and diffs against
the manifest: a path absent from the manifest is **added**, a path whose
SHA-256 differs is **modified**, a path in the manifest but gone from disk
is **deleted**. Deletions are **reported, never actioned** — no drawer is
expunged; deletion handling is a human-confirmed downstream decision.

## Decision (c) — The tool family produces candidates only; it never consumes or writes Proposals

The candidate-enqueue seam stops at "here are the changed files." For each
added/modified file, reconcile surfaces a candidate carrying the
`stableSourceKey` (the vault-relative path without `.md` — the same key
`DrawerMapping` derives on export), the vault path, and the new content
hash — enough for the downstream loop to parse and stage. **The tool
family does not parse edits into Proposals and writes to no Proposal
noun.** Consumption (dream → staged Proposal → Debrief) is later,
separately-gated work.

## Decision (d) — Candidate seam is return-only

QueueKit's only public enqueue is `QueueKit.send(_ job: Job)`, which
requires a **mounted QueueKit instance** (a root URL + an `HLCGenerator`
clock). The `ToolDispatcher` carries only `kit` + `handle` — no queue
instance — and wiring one (choosing a queue root, threading an HLC clock
through `Server` → dispatcher) would exceed this change's additive
scope and break the determinism rule (an HLC clock is wall-clock state).
A `Job` is also a dispatch record, not a natural "vault candidate." So
reconcile **returns** the candidate list in its tool result; enqueue is
deferred to the gated downstream work. No QueueKit API is invented or
extended; QueueKit is left unmodified.

## Decision (e) — AriaMcpKit gains an in-repo dependency on VaultKit

AriaMcpKit's package manifest adds a path dependency on VaultKit (package
`dependencies`, the `AriaMCP` target, and its test target) so the
handlers can call `VaultBridge`. This is permitted under
`DECISION_LIFT_PACKAGE_SWIFT_RULE_2026-05-28`: an in-repo dependency added
because a recorded architectural decision (this ADR) requires it. Layering
is downstream → upstream (aria-mcp app → VaultKit kit); no inversion.
VaultKit is in-repo, so the C-1 zero-external-dependency constraint is
unaffected.

## Disposition

Decided and implemented. The four `moot_vault_*` tools list
and dispatch on the Swift binary; drift detection is an exact SHA-256
compare against the owned manifest; the candidate seam is return-only;
no substrate, schema, or QueueKit API changed. Existing aria-mcp dispatch
tests pass unchanged (additive-only). **Note:** the Swift-only framing of
Decision (a) was subsequently superseded — VaultKit and its Rust
`moot_vault_*` mirror now ship at parity. See the Addendum.

## Open questions (deferred, not blocking)

- Rust `moot_vault_*` mirror — **CLOSED (done)**; VaultKit and its Rust mirror now ship at parity (see Addendum).
- Wiring a real QueueKit instance into aria-mcp so reconcile enqueues
  instead of returning — gated downstream work that also
  builds the dream → Proposal → Debrief consumption side.
- Deletion handling (human-confirmed drawer expunge) — downstream.
- Per-note tunnel-source disambiguation (carried over from ADR-VAULTKIT-001) — still open.

## Addendum (2026-06-06) — Decision (a) superseded: VaultKit is Swift + Rust at parity

Decision (a) recorded a **Swift-only** `moot_vault_*` tool family with the
Rust mirror "deliberately deferred," on the premise (ADR-VAULTKIT-001
Decision (e)) that VaultKit ships no Rust target. **That premise is
superseded.** A subsequent parity workstream (2026-06-05 — two days after
this ADR) completed:

- the **VaultKit Rust crate** (NoteIR, VaultBridge, DrawerMapping with
  FNV-1a 128-bit lineageID, VaultAdapter, ObsidianAdapter),
  conformance-gated; and
- the **Rust `moot_vault_*` wiring** in AriaMcpKit's Rust port, backed by
  the VaultKit Rust crate.

VaultKit now ships **Swift + Rust at parity**. The open question "Rust
`moot_vault_*` mirror — future implementation task" is therefore **CLOSED
(done)**, and the guidance about not flagging the unmirrored Rust side as
drift no longer applies — the Rust side **is** mirrored and parity *is* the
bar. Per the project's parity-is-absolute standard, a Swift-only kit is not
a shippable end state.
