---
id: ESTATE_RECALL_CLEARANCE_DECISION_v1.0_2026-06-02
date: 2026-06-02
status: decision
author: Kong (architecture review, root-level, read-only)
scope: packages/kits/LocusKit, packages/kits/GeniusLocusKit, apps/ARIA_MCP
relates_to:
  - MATRIX_ACCESSOR_DECISION_v1.0_2026-06-02.md  (same clearance-leak shape; the precedent)
  - GLK_RUST_ESTATE_RECALL_001  (the mission this re-shapes)
  - SWIFT_LEXICON_GAPS_001  (the Swift honest-refusal arms for the same five nouns)
---

# Estate-Wide Recall (the five `all_*` accessors) — RESHAPED

Kong review of GLK_RUST_ESTATE_RECALL_001: should the five honest-refusal
recall stubs in the Rust GLK coordinator
(`recall_kg_facts`, `recall_diary_entries`, `recall_proposals`,
`recall_associations`, `recall_learned_references`) go live on the back of
new `all_*` accessors on the `DrawerStore` trait?

## Verdict

**(C) RESHAPED. The mission as conceived — unfiltered `all_kg_facts()`,
`all_proposals()`, etc. — is REJECTED. A clearance-bounded variant is
BUILDABLE for the four sensitivity-bearing nouns, but only as a different
primitive than the mission assumed, and only behind a prerequisite that
does not exist today.**

Same shape as the matrix accessor. There the leak was through aggregate
statistics; here it is direct — a raw `all_*` scan returns the secret rows
verbatim. The matrix decision blocked the cleaner case. This one is worse.

## The decisive finding (verified, not remembered)

The clearance gate is **drawer-only**. It does not exist for these nouns.

- `BitmapEvaluator::evaluate(frame, drawers: &[Drawer], store)` is
  hard-typed to `&[Drawer]` → `Vec<Drawer>`
  (`LocusKit/rust/src/bitmap_evaluator.rs:159`). The Swift mirror
  `BitmapEvaluator.evaluate(frame:drawers:store:)` is `[Drawer]` →
  `[Drawer]` (`LocusKit/Sources/LocusKit/BitmapEvaluator.swift:148`).
  Neither accepts a KGFact, Proposal, Association, LearnedReference, or
  DiaryEntry. The §9.2 `SensitivityAtMost(Normal)` default
  (`bitmap_evaluator.rs:249-259`; Swift `BitmapEvaluator.swift:234`) is
  injected **inside that drawer-typed path only.**
- The `DrawerStore` trait's existing per-noun reads
  (`kg_facts_for_drawer`, `proposals_for_target`, `associations_from`,
  `learned_references_from_source`, `read_diary`) are SQL-predicate
  filters on foreign keys / agent name. **None of them applies a
  sensitivity ceiling.** They are scoped by relationship, not clearance.
- The model the mission would copy, `all_drawers()`
  (`drawer_store_inmemory.rs:894`), is a raw
  `query(T_DRAWERS, None, ...)` — no sensitivity predicate. It is safe
  *only because* every caller funnels it through `BitmapEvaluator::evaluate`
  before exposure. A `all_kg_facts()` modelled on it would have no such
  funnel, because the evaluator cannot take KGFacts.

So the mission's premise — "the gate exists; just add an estate-wide read
and the existing machinery clears it" — is false. For these five nouns the
gate has never been built. Building an unfiltered `all_*` does not bypass
the gate; it ships a noun whose gate does not exist yet. That is the
violation.

## Per-noun sensitivity reality

| Noun | Sensitivity axis | Gateable? |
|---|---|---|
| KGFact | `adjective_bitmap`, Drawer layout (bits 6–11) | Yes, if a gate is built |
| Proposal | `adjective_bitmap`, Drawer layout | Yes, if a gate is built |
| Association | `adjective_bitmap`, Drawer layout | Yes, if a gate is built |
| LearnedReference | `adjective_bitmap`, Drawer layout | Yes, if a gate is built |
| DiaryEntry | **`operational_bitmap` only** — event class / severity / actor / batch (`diary_entry.rs:73-79`). **No sensitivity field exists.** | No axis to gate on |

KGFact/Proposal/Association/LearnedReference all carry `adjective_bitmap`
with the same sensitivity nibble as Drawer — so an unfiltered scan returns
their Restricted/Secret rows, which drawer-equivalent recall would never
return. **Direct clearance bypass on four nouns.**

DiaryEntry is a different problem, not a smaller one. It has no sensitivity
axis at all. "Clearance-bounded diary recall" is not expressible today — there
is nothing to bound on. The wing-per-agent convention (`wing_<agent_name>`,
`diary_entry.rs:9-13`) is the *only* isolation diaries have, and it is a
naming convention callers honor, not an enforced boundary. An estate-wide
`all_diary_entries()` collapses even that — it returns every agent's
first-person record across all wings in one call. That is the highest-value
target in the estate and the one noun with the weakest existing control.

## Ruling on the six design questions

1. **Clearance semantics.** Yes, estate-wide recall of the four
   sensitivity-bearing nouns MUST route through clearance-gated machinery
   equivalent to drawer recall. It cannot today: the evaluator is
   drawer-typed. The gate does not exist for these nouns. Building
   unfiltered access is the violation, not a shortcut around it.

2. **Is the gate satisfiable.** The "≤Normal until access claims land"
   default is the correct *posture* — but it is satisfiable for drawers
   only because the drawer path runs the evaluator. For these nouns there
   is no path to satisfy, because there is no gate to default. "Returns
   ≤Normal until access claims land" is a sound v1 *once the gate exists
   for the noun.* It is not a substitute for the gate. The access-claim
   gap (§9.2) is a real second prerequisite, but it is downstream of the
   first: a default-deny gate that does not yet exist cannot have its
   default tightened by access claims.

3. **Primitive shape.** Unfiltered `all_kg_facts()` is the wrong
   primitive — confirmed. The right primitive, if pursued, is a
   **filter-threaded estate-wide read** that mirrors how drawer recall
   threads the chain: the read takes a `Filter` chain (or at minimum a
   sensitivity ceiling), and the gate's default-deny is applied
   *structurally inside the read*, the way `insert_defaults` does for
   drawers. The signature must make the gate non-optional — a caller must
   not be able to obtain an ungated estate-wide scan of a sensitive noun.
   Do NOT add a raw `all_*` to the trait. A raw `all_*` is a loaded weapon
   left on the trait surface for every future caller; the matrix decision's
   condition 1 logic applies — the primitive itself must carry the
   partition, not rely on every caller remembering to gate.

4. **Two-leg.** Swift is in the identical state: drawer-only evaluator,
   same five nouns ungated, same honest-refusal arms (SWIFT_LEXICON_GAPS).
   This is not "Swift leads the wire and Rust follows" — the gate is absent
   on *both* legs. Sequencing: the sensitivity-gate-for-non-drawer-nouns
   design is led on Swift (design surface, per CognitionKit lens-parity
   doctrine), Rust mirrors, and because the accessor is internal,
   conformance is by output comparison. **Shared conformance vectors are
   mandatory** — vectors must prove both legs return the *same
   clearance-bounded set* given a corpus containing Secret/Restricted rows.
   A vector that omits elevated-sensitivity rows would pass a broken gate.

5. **Blast radius / second-order.** The wire contract does NOT change:
   the aria-mcp recall tools already exist and already advertise
   (`apps/ARIA_MCP/rust/src/lexicon_tools.rs:725-770`, `tool_list.rs`); they
   currently return `error_result(NotSupportedByEstate)`. Flipping stub→live
   returns rows under the same tool schemas — correct, and not a contract
   break. But the matrix decision's discipline applies in full: **clearance-
   partition the noun first (the hard part), then ship the live recall —
   never bundled.** The temptation here is exactly the temptation the matrix
   decision named: the read is cheap, so it looks like "just plumbing." It
   is not plumbing. The gate is the work.

6. **Perkins.** Yes — unequivocally. This is a privacy-level enforcement
   surface with a direct clearance-bypass attack surface across four nouns
   plus an unbounded cross-agent diary read. Perkins reviews the
   implementation before merge, with the conformance vectors (condition 4
   below) as the artifact under review. Root's lean is correct.

## Conditions (binding on any build of this capability)

1. **No raw `all_*` reaches the `DrawerStore` trait surface for a
   sensitivity-bearing noun.** The estate-wide read for KGFact / Proposal /
   Association / LearnedReference threads a filter chain and applies the
   §9.2 default-deny structurally, mirroring drawer recall. The gate is in
   the primitive, not bolted on by the caller.

2. **DiaryEntry is split out and BLOCKED pending a sensitivity-axis
   decision.** DiaryEntry has no sensitivity field. Estate-wide diary
   recall cannot be clearance-bounded because there is nothing to bound.
   Either (a) DiaryEntry gains a sensitivity axis (a schema decision, its
   own mission, both legs) before any `all_diary_entries()` ships, or (b)
   estate-wide diary recall is explicitly declined and the honest-refusal
   arm stays. Do not ship an ungated cross-agent diary scan. This is the
   single most dangerous line item in the mission.

3. **Sequencing mirrors the matrix decision.** Mission 1: build the
   non-drawer clearance gate (filter-threaded estate-wide reads + the
   §9.2 default), both legs, atomic, with conformance vectors proving
   identical clearance-bounded output on a corpus seeded with
   Restricted/Secret rows. Mission 2: flip the four coordinator stubs and
   the four aria-mcp dispatch arms stub→live. Never bundle 1 and 2.

4. **Perkins reviews Mission 1's implementation before merge.** The
   conformance vectors are the artifact. A vector suite that does not
   include elevated-sensitivity rows is an incomplete proof and Perkins
   rejects it.

5. **The "≤Normal until access claims land" posture is acceptable as the
   gate's default** — it is the same default drawers run today — but it is
   the gate's *behavior*, not a replacement for building the gate. Do not
   read condition 5 as "the gate is satisfied because everything is ≤Normal
   anyway." Until the gate exists for the noun, there is no ceiling being
   enforced — there is no ceiling at all.

## What's not asked, surfaced

The mission frames this as a trait-accessor gap. The real gap is
**architectural: clearance enforcement for estate nouns is drawer-shaped,
and four other nouns carry the same `adjective_bitmap` with no enforcement
path.** That is a doctrine-level observation worth its own finding: the
sensitivity gate should be expressible over any `adjective_bitmap`-bearing
noun, not re-implemented per noun. Whoever builds Mission 1 should design the
gate to generalize, or this same review recurs for the next noun. Recommend
a separate spec captures the generalized-gate question; sequence it ahead of,
or fold it into, Mission 1's design.

## Notes for the audit trail

- The matrix accessor was blocked for an aggregate-statistics leak. This is
  the same shape, direct: a raw `all_*` returns the Secret rows themselves.
  If the matrix accessor was correctly blocked, this is blocked a fortiori.
- The wire is safe to keep advertising the tools as honest refusals; the tool
  schemas are already correct for the live shape. The block is on the read
  primitive, not the tool surface.
- DiaryEntry is the asymmetric risk: no sensitivity axis, weakest existing
  control (wing convention only), highest-value content. It must not ride the
  same mission as the four `adjective_bitmap` nouns.
- Verified against HEAD 37f24d6, both legs. The drawer-only typing of
  `BitmapEvaluator::evaluate` is the load-bearing fact; if a future change
  generalizes the evaluator to accept any sensitivity-bearing noun, this
  decision should be revisited — that change would *build* the prerequisite
  this memo names as missing.
