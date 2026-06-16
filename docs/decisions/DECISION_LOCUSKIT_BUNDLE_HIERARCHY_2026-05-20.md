---
status: decided
question: What is a node in the LocusKit estate that count-vectors attach to and roll up through?
authors: MOOTx01 maintainers
date: 2026-05-20
supersedes: none
context:
  - The bundle algebra needs a node tree for count-vectors to attach to and roll up through.
  - This decides what a node is in the LocusKit estate.
---

# Decision, LocusKit Bundle Hierarchy

The bundle algebra needs a node tree for count-vectors to attach to and
roll up through. This decides what a node is in the LocusKit estate.

## The question

`lineageID` is a single UUID per drawer that names a supersession
chain: rows sharing a lineageID are versions of one logical record, and
the active one supersedes its predecessors. It is flat by design, and
it is versioning, not aggregation. The bundle algebra's node tree is a
different thing, so the question is whether to extend lineageID into a
tree, add a separate nodes table, or reuse an existing grouping.

## The decision

The node tree is the existing wing and room grouping. A drawer already
carries `wing` (the project or client) and `room` (the aspect), both
indexed, with a composite wing-room index. The aggregation tree is wing
to room to drawer: a room-level node bundles the drawers in that room,
and a wing-level node is the roll-up of its rooms.

`lineageID` is left untouched and is explicitly not the tree. It
remains the supersession chain within the leaf set. Conflating it with
the hierarchy would break versioning.

This matches the motivating case directly. The redaction example is a
departed client whose patterns continue to inform the model. A client
is a wing. Bundle B, the departed accumulator, at wing level is exactly
that surviving signal, and erasure operates at wing granularity, which
is the unit a data-destruction clause names.

No new hierarchy concept is introduced, no drawer schema change is
needed, and the roll-up is the count-vector merge already built: a
wing's count-vector is the merge of its rooms' count-vectors.

## Storage

Count-vectors live in a new side table keyed by node identity (wing, or
wing and room) and bundle kind, holding the fixed-width `(c, n)` plus
the bundle kind, A active or B departed. The table is not append-only;
Bundle A rows are rewritten on each recompute and Bundle B rows are
updated on each departure. This follows the reserved-width discipline:
the count-vector is fixed size, so a node's storage cost is known and
capacity comes from new reads of the same bytes, not new rows.

The exact column set, the count width (the UInt16 versus UInt32 choice
from the scope, which bounds a node's subtree size), and the recompute
cadence are settled in the two-bundle materialization that follows.

## Consequences

The two-bundle materialization can now proceed. Bundle A recompute
folds a room's active drawer fingerprints with `countFold256` and writes
`(c, n)`; the wing roll-up merges the room vectors; Bundle B accumulates
a departing drawer's fingerprint at wing level. The erasure verbs
operate at wing granularity against this structure.
