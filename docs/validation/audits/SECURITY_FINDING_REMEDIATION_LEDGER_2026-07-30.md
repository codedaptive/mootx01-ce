---
status: recorded
created: 2026-07-30
review_window: 2026-07-28 through 2026-07-30
base_revision: 9771533d (develop/1.0.x)
findings_closed: 4
---

# CE 1.0.x Substrate Security Remediation Record — July 30, 2026

Four findings closed on `develop/1.0.x` at `9771533d`. All four were reported
against the published SDK venue mirrors (`moot-system`, `moot-memory`,
`moot-semantics`); the affected sources are maintained in this repository under
`packages/`, so the fixes land here and reach the venue repositories on their
next publish.

Every fix was implemented in both the Swift and Rust ports, and each ships a
regression test confirmed to fail against the unfixed code before the fix was
applied.

## Closed

| # | Severity | Issue | Reported against | Fix commit |
|---:|---|---|---|---|
| 1 | High | Federation last-writer-wins ordering state lived only on the live application row, so a delete removed the row together with its comparison baseline and a later replay of an older but validly signed envelope was accepted | mirror `8d03ae8` | `9771533d` |
| 2 | Medium | Corpus recall-index teardown called the whole-store vector destruction primitive, which deletes the vectors table without an ownership predicate | mirror `17bbbdf` | `9771533d` |
| 3 | Medium | The Rust tokenizer did not split ASCII colons, diverging from Foundation's word tokenizer and dropping colon-joined terms from classifier evidence | mirror `e0edede` | `9771533d` |
| 4 | Medium | The writable word-class table could be loaded from a process-relative path, and that table takes precedence over the bundled one when seeding the process-global classifier | mirror `07ade13` | `9771533d` |

## Remediation detail

**1 — Federation delete ordering.** Last-writer-wins compared an inbound record
only against the `_syncHLC` column on the existing row. A winning delete
hard-deleted that row, taking the ordering state with it, so a subsequent stale
record found no baseline. The fix introduces a durable side table,
`_fed_sync_meta`, keyed by `(table_name, primary_key)` and carrying the winning
HLC in full-width wire form. It is written on every apply that wins the
comparison and, on the delete path, before the row is removed — so the entry
outlives the row and serves as the tombstone. The gate compares against the
newer of the live row's `_syncHLC` and the side-table entry rather than the side
table alone, so an estate that synced before this table existed retains the
ordering already recorded on its rows.

**2 — Corpus teardown scope.** `destroyRecallIndex` /
`destroy_recall_index` now deletes only the rows this corpus owns: its own chunk
IDs under its held models' model IDs, with the chunk inventory taken from the
append-only chunks table. Whole-table teardown remains reserved for the
estate-level destruction path.

**3 — Tokenizer parity.** UAX #29 classifies ASCII `:` as MidLetter, so the Rust
segmentation crate kept colon-joined words as a single token while Foundation's
`.byWords` split them. Merged tokens missed the word-class table and lexicon and
were discarded during concept-bag construction, so compact colon-delimited rows
resolved differently between the two ports. The compatibility split is restored
and covered by a cross-port conformance vector.

**4 — Word-class table load path.** Both ports now refuse a non-absolute
artifact path and fall back to the bundled table. The writable artifact is
always expected at an absolute per-user location; a relative path indicates that
base-directory resolution did not produce one.

## Suite counts

| Suite | Count |
|---|---:|
| `ConvergenceKit` Swift | 100 |
| `ConvergenceKit` Rust | 71 |
| `CorpusKit` Swift | 341 |
| `CorpusKit` Rust | 138 |
| `LatticeLib` Swift | 161 |
| `LatticeLib` Rust | 150 |
| `VectorKit` Swift | 212 |
| `VectorKit` Rust | 186 |

Swift and Rust counts are reported together for each affected package as the
cross-language parity check.

## Dispositions

Finding 4 was reported against a platform-specific code path that does not exist
on this release line. The underlying condition — a classifier table reachable
through a process-relative path — was confirmed present by a different route on
this line and is closed as recorded above.
