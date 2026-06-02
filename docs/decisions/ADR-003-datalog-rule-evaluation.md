# ADR-003 — Datalog Rule Evaluation: Semi-Naive Bottom-Up over the Estate's Fact Sources

- Status: Proposed
- Date: 2026-06-01
- Deciders: Bob (Commander)
- Scope: a future rule-evaluation component in SubstrateLib; SubstrateTypes fact
  sources (read-only); GeniusLocusKit scheduling (orchestration only)
- Evidence: `packages/libs/SubstrateTypes/Sources/SubstrateTypes/ThreeDBitTensor.swift`
  (the (row, field, value) attribute relation — 36 fields × 6-bit values, I-6),
  `packages/libs/SubstrateTypes/Sources/SubstrateTypes/MatrixO.swift`
  (co-occurrence counts keyed (field_i, value_i, field_j, value_j)),
  `packages/libs/SubstrateTypes/Sources/SubstrateTypes/MatrixT.swift`
  (temporal-causality counts keyed (source, target, lag_bucket)),
  `packages/libs/SubstrateTypes/Sources/SubstrateTypes/MatrixF.swift` and
  `packages/libs/SubstrateTypes/Sources/SubstrateTypes/MatrixC.swift`
  (population statistics — surveyed and excluded from the extensional base),
  `packages/libs/SubstrateLib/Sources/SubstrateLib/RowStateAutomaton.swift` and
  `packages/libs/SubstrateLib/Sources/SubstrateLib/AuditGate.swift`
  (forbidden-combination invariants I-22 — the substrate's existing rule-shaped
  machinery, and the placement precedent). Companion to ADR-001
  (transcendental-isolation invariant: derived facts stay on integer math).

## Context

**Decision in one line: Datalog-style rules over the estate are evaluated
semi-naive bottom-up — a monotone least fixpoint computed by joining each rule
against only the delta of newly derived facts per round.**

The substrate already accumulates rule-shaped structure: forbidden-combination
invariants (RowStateAutomaton/AuditGate, I-22), MatrixO co-occurrence, MatrixT
causality, and — pending in parallel streams — association rules and formal
concepts. The natural next capability is *deductive* rules: deriving new facts
from logical rules with joins and recursion (e.g. "if a row has (field 12,
value 5) and that value co-occurs strongly with (field 7, value 3), derive a
candidate tag"). Before any engine is built, this ADR settles the evaluation
strategy and the four decisions that hang off it.

Datalog vocabulary, defined here because no prior doc uses it: the **EDB**
(extensional database) is the set of ground facts read from existing storage;
the **IDB** (intensional database) is the set of facts derived by rules. A
rule's **head** is derived when its **body** atoms all match.

### The fact sources (what the EDB can be)

- **The row-attribute relation** — `ThreeDBitTensor` stores every row's
  field-value assignments (N_rows × 36 fields × 6-bit values). Each cell is a
  ground fact `attr(row, field, value)`. This is the primary base relation,
  and its bit-sliced layout already answers the body-atom question "rows where
  field f = v" in O(N_rows / 64) word operations.
- **MatrixO** — sparse counts keyed `(field_i, value_i, field_j, value_j)`:
  ground facts `cooccur(f_i, v_i, f_j, v_j, count)` about value pairs.
- **MatrixT** — sparse counts keyed `(source, target, lag_bucket)`: ground
  facts `precedes(f_s, v_s, f_t, v_t, lag, count)`, asymmetric by design.
- **MatrixF / MatrixC** — population statistics (per-(field, bit) counts and
  marginals). Surveyed and **excluded**: F is an aggregate the attribute
  relation already determines, and C is a Float32 marginal — neither is a
  ground fact over entities, and floats have no place in a relational base
  (and would brush against ADR-001's float-divergence hazards).

### The strategy space

1. **Naive bottom-up** — apply every rule to the *entire* fact set each round
   until no new fact appears. Computes the least fixpoint; re-derives every
   already-known fact every round.
2. **Semi-naive bottom-up** — identical fixpoint, but each round joins rule
   bodies against the *delta* (facts new in the previous round), plus the full
   set only for the other body atoms. Every derivation needs at least one new
   input, so redundant re-derivation is eliminated.
3. **Magic sets** — rewrite rules so bottom-up evaluation derives only facts
   relevant to a given *query*. A strong optimization once query-directed
   evaluation exists; pure overhead for full materialization.
4. **Top-down SLD/QSQ** — start from a goal and resolve backwards
   (Prolog-style; QSQ adds memoization for termination). Goal-directed, good
   for selective ad-hoc queries; poor for materializing all consequences.

## Decision

The five open decisions, resolved:

1. **Fact sources (EDB).** The extensional base is the row-attribute relation
   (`ThreeDBitTensor`) plus MatrixO and MatrixT, read as the annotated
   relations above. MatrixF and MatrixC are excluded (aggregates, not ground
   facts). Count annotations are consumed at fact-extraction time — a rule
   references a *thresholded* atom (e.g. `cooccur(...) with count ≥ k`), so
   the extracted EDB snapshot is a fixed set of ground atoms and evaluation
   stays purely monotone.

2. **Evaluation strategy: semi-naive bottom-up.** Same least fixpoint as
   naive, substantially less redundant work as the estate's fact base grows
   between decay cycles. This matches the substrate's existing forward
   pattern: the dreaming daemon already materializes structure (matrices,
   decay) bottom-up on a schedule; rule evaluation joins that cadence.
   - *Naive* — rejected: correct but re-derives the entire IDB every round;
     pure cost with zero benefit over semi-naive.
   - *Magic sets* — rejected for now: only pays off when evaluation is driven
     by selective queries. No query API exists; full materialization is the
     workload. Deferred to a future ADR if/when a query surface ships.
   - *Top-down SLD/QSQ* — rejected: goal-directed evaluation inverts the
     substrate's forward/bottom-up pattern, needs memoization machinery just
     to terminate, and is the wrong shape for "derive everything once per
     epoch, then read cheaply."

3. **Recursion and negation.** Recursion is permitted and terminates without
   special machinery: the Herbrand base is finite (≤ 36 fields × 64 values
   per I-6/I-15, rows bounded by the estate), so the monotone
   immediate-consequence operator reaches its least fixpoint in finitely many
   rounds. **Negation is omitted in v1** — no negated body atoms — preserving
   a single well-defined least fixpoint. Stratified negation is the recorded
   extension path (deferred work), chosen over admitting it now because no
   motivating rule set exists yet to justify the stratification machinery.

4. **Rule representation: rule-as-data.** Rules live as stored, serializable
   values (a rule table: head atom + body atoms over field/value constants,
   variables, and count thresholds) — not Swift predicate combinators and not
   a text DSL. Rationale: every kit ships Swift and Rust legs gated against
   shared test vectors; rule-as-data lets one canonical rule set be the
   conformance vector for both legs. Combinators are unportable and ungateable
   as data; a DSL is a parse layer that can sit on top of the rule table later
   (deferred), with the table remaining the canonical form.

5. **Package placement: a SubstrateLib component.** The engine is
   deterministic compute over SubstrateTypes values — exactly the
   RowStateAutomaton/AuditGate precedent (rule-shaped logic in SubstrateLib
   reading SubstrateTypes). It spans fact sources, so it sits below the kits;
   it is not NeuronKit material (not a recall/ranking algorithm) and not a new
   package (no consumer yet justifies one). Scheduling — *when* evaluation
   runs — belongs to GeniusLocusKit's Brain layer alongside the matrix and
   decay cadence, exactly as MatrixO/MatrixT updates are driven today.

## Consequences

- A follow-on implementation mission gets an unambiguous design envelope:
  semi-naive engine in SubstrateLib (Swift + Rust, conformance-gated against
  shared rule/fact/fixpoint test vectors), fact-extraction adapters for
  ThreeDBitTensor/MatrixO/MatrixT, and a rule-table schema.
- All derived facts are integer-relational. The IDB stays off the
  fingerprint/identity path by construction, consistent with ADR-001; counts
  enter only through thresholds at extraction time.
- Decay and expunge are non-monotone, so a computed fixpoint is valid only for
  the EDB snapshot it was derived from. The IDB is recomputed per epoch (the
  dreaming-daemon cadence); semi-naive deltas optimize *within* a run, not
  across runs. Incremental cross-epoch maintenance (DRed/counting) is
  explicitly out of scope until measurement shows per-epoch recomputation is
  too slow.
- Determinism obligations carry over unchanged: canonical (sorted) iteration
  orders, `now` passed as a parameter, identical results on both language legs.
- Rule evaluation gains a recorded boundary with the existing invariant
  machinery: I-22 forbidden combinations remain AuditGate's lane (synchronous,
  per-mutation, constitutional); Datalog rules are asynchronous derivation and
  may not veto mutations.

## Deferred / non-goals

None of the following is decided or built by this ADR; each is follow-on work:

- The rule engine implementation (both legs, conformance vectors, benchmarks).
- The rule-table schema and any authoring DSL/parser above it.
- Magic-sets optimization and any query-directed evaluation (future ADR,
  contingent on a query API existing).
- A query API over the IDB.
- Fact-extraction wiring from the matrices (thresholds, snapshot mechanics).
- Stratified negation (the recorded extension path for v1's no-negation rule).
- Incremental view maintenance across decay epochs (DRed/counting).
