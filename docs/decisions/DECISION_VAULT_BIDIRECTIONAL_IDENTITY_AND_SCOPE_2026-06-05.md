---
status: decided
question: How should VaultKit export/import preserve identity across round-trips, and how should export scope be selected?
authors: MOOTx01 maintainers
date: 2026-06-05
description: Records how VaultKit export/import preserves identity across round-trips and how export scope is selected.
relates_to:
  - docs/reference/VAULTKIT_INTERFACE.md
  - docs/decisions/ADR-VAULTKIT-001.md
  - docs/decisions/ADR-VAULTKIT-002.md
supersedes: none
context:
  - Export hard-coded the recall filter to `.unconfirmed`, silently dropping user-confirmed drawers from every export.
  - Export keyed files on `"<wing>/<room>/<drawer.id>"` — the random, supersession-re-minted capture UUID — so human filenames and wings did not survive a round-trip.
  - VaultKit ships both a Swift and a Rust port; both must stay at parity.
---

## Context

A review of VaultKit (2026-06-05) surfaced two correctness/design gaps in the
export/import bridge, both confirmed against source:

1. **Export scope.** `DrawerMapping.export` recalled with `filterChain: [.unconfirmed]`,
   rationalised as "everything I captured." But `.unconfirmed` is a confirmation-axis
   filter: the moment a user confirms an imported note (`mutate(.confirm)`), it no longer
   matches and drops from the next export. For a surface pitched as "the vault is a
   projection of the substrate," confirmed memories silently vanishing is a defect, not a
   nuance.

2. **Round-trip identity.** Export built the note's key as
   `"\(drawer.wing)/\(drawer.room)/\(drawer.id)"`. `drawer.id` is re-minted by the
   supersession cascade, and the random UUID is not human-readable. A human-authored
   `Area/Note.md`, imported then exported, came back as `wing_<owner>/<room>/<uuid>.md` —
   filename and wing lost. Import keyed identity on the vault path (`FNV(stableSourceKey)`),
   which the re-export then changed, so genuine bidirectional round-trips were lossy.

## Decision 1 — Export scope is a user preference; default `believed`

Introduce `VaultExportScope` (Swift + Rust) with four cases, threaded
`DrawerMapping.export(…scope:)` → `VaultBridge.export(…scope:)` → the `moot_vault_export`
MCP tool's optional `scope` argument (default `believed`):

| Scope | Filter chain (intent) |
|---|---|
| `believed` (default) | `currentlyBelieve ∧ any-confirmation ∧ any-trust` — the true projection of the estate; **fixes the confirmed-drop bug** |
| `exportable` | `exportable ∧ currentlyBelieve ∧ any-confirmation` — honours per-drawer export intent |
| `confirmed` | `userConfirmed ∧ currentlyBelieve` |
| `unconfirmed` | `unconfirmed ∧ currentlyBelieve` — the prior capture-inbox behaviour, made explicit |

Sensitivity stays at the evaluator's `sensitivityAtMost(.normal)` default for **all** scopes —
sensitive content is never written to a plaintext vault unless a future scope opts in.
`any-confirmation`/`any-trust` are expressed as `.any([...])` over the axis cases, which the
recall evaluator's per-axis default-insertion treats as "axis addressed" (so its implicit
`userConfirmed`/`trustworthy` defaults are suppressed).

## Decision 2 — Identity in frontmatter (Plan B1); human-slug filenames

- **`moot_id` frontmatter** carries `drawer.lineageID` — the **stable** lineage UUID, **not**
  `drawer.id` (which supersession re-mints). This is the round-trip identity.
- **Filename `"<room>/<slug>.md"`** — no `wing_<owner>` prefix (one owner per vault; wing
  rides frontmatter). `slug` derives from the first `# heading`, else the first non-empty
  line, sanitised to `[a-z0-9-]`, max 60 chars.
- **Import identity resolution order:** `NoteIR.mootID` > frontmatter `moot_id` >
  `FNV(stableSourceKey)`. A vault-side file rename with `moot_id` present produces
  `drawersUpdated = 1`, not a duplicate — **rename-safe**.

### Rejected alternatives

- **B2 — persist each drawer's origin path as a new `Drawer` attribute** (for exact
  original-filename fidelity). Rejected: it pushes a vault-presentation concern into the
  substrate schema (both ports + storage + conformance) for a cosmetic gain over B1, whose
  frontmatter identity already makes round-trips lossless and rename-safe.
- **UUID filenames** — rejected: not human-readable; a vault is for people.
- **`drawer.id` as the identity key** — rejected: re-minted by the supersession cascade, so
  it cannot be a stable round-trip identity.

## Parity note — closed

The work surfaced a pre-existing LocusKit-Rust drift: Rust `Filter::ModelConfirmedOnly`
versus the renamed Swift `Filter.automatedConfirmedOnly` (the Rust port had kept the old
name). This is now closed in both ports: Rust `Filter::AutomatedConfirmedOnly` mirrors
Swift `Filter.automatedConfirmedOnly`, and the `bitmap_evaluator` call sites and tests use
the renamed variant. The drift was found and closed in both ports together.

## Status

Decided and implemented on both ports; all four test suites green (Swift VaultKit and
aria-mcp; Rust VaultKit and aria-mcp).
