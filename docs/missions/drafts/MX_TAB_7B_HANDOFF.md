---
title: MX-TAB-7b — MX-TAB-7 remainder: Rust tool leg + VaultKit round-trip
version: v0.1
status: draft-ready-for-dispatch
date: 2026-07-12
assignee: Bilby (NOT Newton — standing directive 2026-07-11)
relates_to:
  - docs/missions/drafts/MX_TABULAR_SPEC.md
---

# MX-TAB-7b — Finish the ARIA/vault surface (Rust leg + VaultKit)

MX-TAB-7's Swift tool leg landed (DatasetTools.swift: moot_file_dataset /
moot_dataset_query / moot_dataset_stats, dataset_id on the three lens
tools, CSV/JSONL import, csv_path security, MX-TAB-5 signature wiring).
This mission ships the remainder. Parent contract: MX_TABULAR_SPEC.md
sections 4–6.

## Scope

1. **Rust tool leg** — mirror DatasetTools.swift byte-identically:
   - New `dataset_tools.rs` in AriaMcpKit rust following the Swift file's
     header design notes (dispatch shape, provenance tier, constants).
   - Tool schemas in `tool_list.rs` byte-identical to the Swift
     projections (three new tools + dataset_id/params on the three lens
     tools — Swift LensTools.swift is the reference).
   - Dispatch in `interface_tools.rs` (or the Rust dispatch seam matching
     Swift's ToolDispatch insertion point: after vault, before interface).
   - Constants: CSV_SIZE_CAP_BYTES = 100 MiB; type inference
     Int64 → f64 → text, empty → null; identical to Swift.
   - Signature wiring: call `compute_dataset_signatures` (GLK rust,
     landed 6e18a31f) after handle capture; non-fatal on failure
     ("signatures: pending"), same as Swift.
   - Withdrawn refusal via the Rust `resolve_active_dataset_handle`.

2. **VaultKit round-trip** — both legs (spec §6, locked v1 behavior):
   - `moot_vault_export`: dataset exported as CSV beside the handle
     note; export scope rules unchanged; private handles never export.
   - `moot_vault_import`: recreate the table through the SAME code path
     as moot_file_dataset (validator, transaction, signatures
     recomputed); reattach handle metadata from the note.
   - `moot_vault_reconcile`: compares the TABLE signature only;
     mismatch = ordinary content conflict on the handle; never silently
     drops a dataset.

3. **Integration tests** (the MX-TAB-7 list not yet covered):
   end-to-end file→query→stats→lens over dataset_id; withdraw → all
   three surfaces refuse; export → import on fresh estate → same table
   signature; malicious column names end-to-end; csv_path
   traversal/symlink/size-cap rejections. Cross-leg: same fixture, same
   tool JSON out of both legs.

## Read first

- `packages/kits/AriaMcpKit/Sources/AriaMCP/DatasetTools.swift` — the
  Swift reference; its header documents every design decision.
- MX-TAB-5 call contract: `GeniusLocusKit/rust/src/dataset_signatures.rs`
  module docs (fenced as text) + Swift `Intake/DatasetSignatures.swift`.
- `docs/blast_radius/MX-TAB-3_BLAST_RADIUS.md` for the lens rejection
  arms already in place.

## Post-flight

Adams (standard suite) + Perkins (user column names as SQL identifiers,
csv_path filesystem ingestion, export surface — spec §5 security gate
names him for exactly this mission's surface).

## Baselines (do not re-litigate)

LocusKit Swift: 3 pre-existing failures (39c274fe). CognitionKit Swift:
2 pre-existing PrecedenceTests issues. `make build-rust`: red in the
conformance harness (audit_log_fold.rs, pre-existing). Queued: MX-TAB-Q1
(TypedValueComparator byte-order parity, own blast radius).
