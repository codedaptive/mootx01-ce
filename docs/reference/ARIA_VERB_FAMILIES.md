---
title: ARIA Verb Families
version: 0.1.0
status: active
date: 2026-08-02
description: "The ARIA verb surface documented in the ratified six-family, three-tier taxonomy: every live verb with its use, arguments, default reply shape, and follow-up affordances."
spec_type: protocol
authors: MOOTx01 maintainers
relates_to:
  - docs/concepts/ARIA_LEXICON.md  (the grammar this surface reifies)
  - docs/reference/ARIA_MCP_SPEC.md  (behavioral contracts per verb)
  - docs/reference/ARIA_MCP_INTERFACE.md  (schemas and port concordance)
  - docs/reference/PROGRESSIVE_DISCOURSE.md  (the journey model these tiers serve)
---

# ARIA Verb Families

The ARIA surface is organized as six FAMILIES, each with three TIERS
running broad (Tier 1) to tight (Tier 3). The tiers are the progressive
discourse: a session starts wide, narrows deliberately, and finishes on
an address. Family and tier definitions were ratified 2026-08-02; verb
placements follow the populated outline of the same date. 75 live verbs;
each appears exactly once below.

Reply-shape vocabulary used throughout:

- **dense row** — `uuid · subject · fdc:<code> · qid:<QID> ·
  <event_time>`: the default hit/citation row across the recall family.
  The UUID is the conversational cursor; the subject is the assertion;
  the other three fields are lattice coordinates. Absence markers are
  uniform (`(no subject)`, `-`); provenance-redacted rows carry the
  redaction marker in place of the subject.
- **deviation-only narration** — status lines appear only when something
  is off-nominal (low/medium discrimination, dark dense lane, degraded
  stages, fallback service). Silence means nominal.
- **teachme** — every verb accepts `teachme: true` and returns its usage
  guide instead of executing.

---

## RECALL

Recall is how the estate answers: it turns a question, an anchor, or a
structure into remembered content, and it is the only family whose
replies the consuming AI reads as substance rather than acknowledgment.
Every other family exists so that what Recall returns is true, current,
and worth the tokens it costs.

### Tier 1 — Survey

Answers "what does the estate hold about this?" — wide, cheap, orienting
recall that maps the territory before any commitment to a line of
inquiry. Its contribution is candidacy.

- **moot_memory_search** — hybrid BM25+vector recall by `query`, or the
  similar-to-this pivot by `near:<uuid>` (exactly one of the two).
  Args: query|near, limit, filter, wing, media_type, scoring, ordering,
  explain. Reply: `found N memory(s)` + dense rows; deviation-only
  discrimination and provenance lines. Follow-ups: moot_memory_get
  (depth tiers) on any row; `near:` again to walk the neighborhood;
  moot_recall_precise when discrimination reads low.
- **moot_recall_vague** — two-hop pondering: hop 1 probes the
  consolidated vague tier, hop 2 hydrates constituent originals through
  `_consolidated_from` tunnels. Args: query, hit_limit,
  constituents_per_hit, total_constituents. Reply: vague-hit dense rows
  tagged `[vague L<n>]`, then `originals:` dense rows. Follow-ups:
  moot_memory_get on any original; normal recall when the vague tier is
  empty.
- **moot_federated_search** — fan a frame across every estate holding an
  active grant for the requester. Args: filter, hydrationLevel,
  ordering, limit, requesterEstateID (omit for the caller estate).
  Reply: one section per contributing estate (grant header + dense
  rows). Follow-ups: moot_memory_get against the source estate's id.
- **moot_memory_list** — structural enumeration of a wing (optionally a
  room): dense rows, capped at 200. `filter: missing_subject` is the
  subject-debt enumerator (id-only rows). Args: wing, room, filter.
  Follow-ups: moot_memory_get; moot_update_memory mutation=setSubject
  on debt rows (with the user's consent).
- **moot_fact_timeline** — the temporal read of the fact layer: a
  subject's assertions in event-time order with validity windows. Args:
  subject, limit. Reply: dated fact lines with ids and standing.
  Follow-ups: moot_fact_search to narrow; moot_retire_fact on a stale
  assertion.

### Tier 2 — Focus

Answers a formed question: ranked, shaped, precision-tuned retrieval
judged on whether the right item surfaces at the top. The working tier.

- **moot_recall_precise** — coarse-grab then precision re-rank
  (distinctive numbers/proper nouns) to lift the exact answer above
  near-duplicates. Args: query, limit, pool, composition, filter, wing.
  Reply: dense rows, same shape as memory_search; the containment gate
  returns `found 0` + not_found discrimination rather than confident
  wrong answers. Follow-ups: moot_memory_get depth:full on the top row.
- **moot_recall_shaped** — recall under a named RecallShape preset that
  steers the fusion lanes; accepts `near:<uuid>` for anchored fan-out
  under the preset. Args: query|near, preset, limit, filter, wing.
  Reply: dense rows. Follow-ups: switch preset; moot_recall_precise for
  precision.
- **moot_recall_distilled** — the confirm tier's text: dense row THEN
  the distilled rendering per hit; rows still owing a distillate fall
  back to verbatim content behind a `source: content (not yet
  distilled)` marker. Args: query, limit, filter, echo_query, ack.
  Follow-ups: moot_memory_get depth:full for the verbatim terminal;
  moot_distill to pay representation debt.
- **moot_fact_search** — structured triples by substring or exact
  field. Args: query, subject_exact, predicate_exact, object_exact,
  source_id_exact, limit. Reply: fact lines with ids and grounding.
  Follow-ups: moot_fact_timeline on the subject; moot_retire_fact.
- **moot_dataset_query** — typed rows from a dataset handle by
  predicate. Args: dataset id/handle plus query fields per the dataset
  tools schema. Reply: matching rows. Follow-ups: moot_dataset_stats;
  moot_memory_get on the handle drawer.
- **moot_synthesize** — composed recall: hybrid-recall a set and
  synthesize a grounded context document (patterns, success rate,
  recommendations, key insights). Args: filter, limit. Reply: the
  document. Follow-ups: the cited memories via moot_memory_get.

### Tier 3 — Pinpoint

Operates on an address, not a question. The cursor of progressive
discourse; everything above exists to hand this tier a UUID worth
pulling on.

- **moot_memory_get** — one hydration verb, three depths: `subject`
  (dense row only — travel), `distilled` (dense row + distilled text;
  fallback marker on rows owing one — confirm), `full` (default; the
  complete record with verbatim content — terminal). Batch with
  `ids: [...]` to winnow a shortlist in one call. Args: id|ids, depth.
  Follow-ups: moot_connection_search/map from the id; near:<uuid> to
  pivot; lifecycle verbs to act on it.
- **moot_connection_search** — outgoing edges of a memory: each edge
  line carries the tunnel id, label, and the endpoint's dense-row
  citation. Args: from_id. Follow-ups: moot_memory_get on any endpoint;
  moot_review_tunnel on proposed edges.
- **moot_connection_map** — incoming edges of a memory; the mirror of
  connection_search. Args: to_id.

The former similar-to-UUID gap is closed by the `near:` argument on
memory_search and recall_shaped, not by a separate verb.

---

## CAPTURE

Capture is how knowledge enters the estate: it accepts content, facts,
links, and imports at the moment they exist, and stamps them with the
identity and time that every later verb depends on.

### Tier 1 — Intake

Admits knowledge in bulk; nothing enters without identity and time.
Intake writes NULL subjects by design — imported rows surface as
subject debt for the consent-gated backfill rather than receiving
fabricated summaries at import speed.

- **moot_palace_import** — bulk import from a palace SQLite export;
  vault-gated (hidden under `MOOTX01_VAULT=0`). Args: path + import
  options per schema. Reply: import report. Follow-ups:
  moot_drain_status while encoding settles; moot_reindex.
- **moot_vault_import** — restore/import from a vault archive. Args:
  job parameters per the vault schema. Follow-ups: moot_vault_job,
  moot_vault_reconcile.
- **moot_file_dataset** — admit a typed tabular dataset behind a
  dataset-handle drawer (the only sanctioned path for
  `contentKind == .dataset`). Args: dataset definition + rows.
  Follow-ups: moot_dataset_query, moot_dataset_stats.
- **moot_file_packet** — admit a structured JSON packet (typed content,
  not a new noun) with lineage. Args: packet fields per schema.
  Follow-ups: moot_packet_get/list/lineage.

### Tier 2 — Filing

The single deliberate act of remembering something.

- **moot_file_memory** — file one memory. REQUIRED: content, subject
  (one sentence ≤120 chars in the AI-facing register — telegraphic,
  entities and claims front-loaded; returned in recall rows, never
  searched), location. Optional: wing, sensitivity, exportability,
  kind, event_time, impatient. Reply: `filed memory <uuid>` + room +
  lineage. Follow-ups: moot_memory_search to confirm recall;
  moot_link_memories to connect it.

### Tier 3 — Assertion

The tightest statement the language allows: one claim, precise enough
to be superseded, retired, or contradicted as a unit.

- **moot_file_fact** — assert a subject–predicate–object triple with
  source grounding. Args: subject, predicate, object, source_id.
  Follow-ups: moot_fact_search, moot_fact_timeline, moot_retire_fact.
- **moot_link_memories** — a typed edge between two identified
  memories; `proposed: true` files it for adjudication instead of
  active. Args: from_id, to_id, label, kind, proposed. Follow-ups:
  moot_review_tunnel; moot_connection_search/map.

---

## LIFECYCLE

Lifecycle is how belief changes without history being lost. Content is
never edited; its standing is.

### Tier 1 — Circulation

Changes reach, not truth — the broadest, most reversible tier.

- **moot_withdraw_memory** — soft-remove from active circulation
  (reversible via the revive mutation). Args: id, reason.
- **moot_move_memory** — reanchor to a new room (and optionally wing).
  Args: id, location, wing.

### Tier 2 — Belief

Standing between rival accounts, on the record.

- **moot_update_memory** — the named-mutation verb. Belief mutations:
  confirm, reject, contest, resolve, supersede, revive, accept.
  Exportability corrections: correctExportability(public|private).
  Subject correction: setSubject (dedicated `subject` argument; the
  backfill/correction path for subject-debt rows). Args: id, mutation,
  note, subject. Follow-ups: moot_memory_get to verify standing.
- **moot_confirm_memory** — shortcut for mutation=confirm. Args: id,
  note.

### Tier 3 — Disposition

Terminal, narrow, gated acts.

- **moot_erase_memory** — permanent expunge; requires
  `confirmed: true` + reason after explicit owner review. Args: id,
  reason, confirmed.
- **moot_retire_fact** — end one assertion's validity (the fact-layer
  supersession mechanism's terminal half). Args: fact id, reason per
  schema.
- **moot_review_tunnel** — settle one PROPOSED edge: accept → active,
  reject → withdrawn (durable; the pair is never re-proposed). Args:
  tunnel_id, verdict, reason.

---

## LENSES

Lenses are how the estate reasons about itself: each computes a reading
no single memory contains. Every lens finding is followable to its
evidence: memory citations render as dense rows, and set-level findings
carry the drawer UUIDs they were computed from (extents capped at 20
with a `+N more` overflow; association-rule exemplars capped at 5).

### Tier 1 — Climate

Reads the whole estate — the weather over the territory.

- **moot_lens_theme_weather** — which themes are rising and fading.
- **moot_lens_drift** — how the estate's structure has moved over time.
- **moot_lens_rhythm** — temporal cadence of capture and recall.
- **moot_lens_constellation** — the estate's cluster structure.
- **moot_lens_keystones** — load-bearing memories (cited as dense rows).
- **moot_lens_bias** — skew in sources and confirmation standing.
- **moot_lens_divergence** — how two estates differ.
- **moot_lens_overlap** — what two estates share.

### Tier 2 — Frame

Reasons over a recalled set — "what does this collection mean."

- **moot_lens_latent_themes** — themes latent in a recalled set.
- **moot_lens_cohesion** — how well a set holds together (members cited
  as dense rows).
- **moot_lens_complexity** — structural complexity of a set.
- **moot_lens_concepts** — formal concepts with their extents listed as
  drawer UUIDs (cap 20, `+N more`), hydratable end-to-end.
- **moot_lens_associations** — mined association rules; estate-mode
  rules carry exemplarDrawerIDs (cap 5, deterministic order) that
  satisfy both labels; dataset-mode rules cite rows, not drawers.
- **moot_lens_apriori** — frequent itemsets over labels.
- **moot_lens_contradiction** — contradiction candidates in a set; pair
  members cited as dense rows. Follow-up: moot_review_tunnel on
  proposed contradicts edges.
- **moot_lens_trust_synthesis** — trust-weighted reading of a set
  (members cited as dense rows).

### Tier 3 — Anchor

Reasons from one point — the analytical arm of Pinpoint.

- **moot_lens_partial_cue** — completion from a fragment (matches cited
  as dense rows).
- **moot_lens_free_association** — the associative neighborhood of one
  memory (dense rows).
- **moot_lens_successors** — what tends to follow this memory (dense
  rows).
- **moot_lens_node_motion** — how one node has moved structurally.
- **moot_lens_moment** — memories resembling this memory's moment.
- **moot_lens_precedence** — what preceded this memory causally.
- **moot_lens_anticipate** — what this point suggests comes next.

---

## MAINTENANCE

Maintenance is how the estate stays trustworthy between conversations.
Its verbs are invoked rarely and change no beliefs; they renew the
machinery the other families stand on.

### Tier 1 — Renewal

Broad, idempotent, safe to repeat; changes no beliefs.

- **moot_dream** — rebuild the matrix tier, run one dreaming cycle and
  one contradiction-hunt sweep. Reply: cycle summary. Follow-ups:
  moot_review_tunnel on proposed edges.
- **moot_reindex** — rebuild recall indexes over captured truth.

### Tier 2 — Sweeps

Bounded passes with a specific product; settled work skipped on rerun.
(The subject-backfill sweep is the same pattern, rider-gated: it renders
as the `subject_backfill` drain lane only while a subject producer —
e.g. the user-enabled Apple miniLLM rider — is registered.)

- **moot_distill** — populate distilled representations (bounded,
  budget-scoped, reported). Follow-ups: moot_recall_distilled.
- **moot_hunt_contradictions** — content screen over lexically-near
  pairs; strong conflicts persist as PROPOSED contradicts edges.
  Follow-ups: moot_review_tunnel.
- **moot_reclassify_fdc** — audit or repair stored FDC anchors under
  the current classifier; `apply`/`mode` gate the write side.

### Tier 3 — Surgery

One irreversible structural decision, never implicit.

- **moot_run_migration** — derive migration branches and benchmark
  them.
- **moot_confirm_migration** — promote exactly one benchmarked branch.

---

## UTILITY

Utility is how the operator and the AI orient: the verbs that describe
the estate and its session rather than its knowledge.

### Tier 1 — Presence

- **moot_estate_ping** — is the estate alive, which build. One call,
  two lines, no estate knowledge needed.

### Tier 2 — Orientation

Discovery without side effects.

- **moot_estate_status** — the estate's counts and health, including
  the subject-debt line `subjects: N/M (K missing)`; when K > 0 the
  STANDING BEHAVIOR is to offer the user a consent-gated interactive
  backfill (never silent). Also fdc recalculation state, sync token,
  trace rows, shared-content reclaim state.
- **moot_estate_map** — wings and rooms with counts.
- **moot_list_lenses** — the cognition-tool catalogue; terse by default
  (name + one-liner), `verbose: true` for full descriptions and
  required args.
- **moot_list_recipes** — the recipe catalogue; same terse/verbose
  contract.
- **moot_monitoring_status** — observer/monitoring surface state.
- **moot_dataset_stats** — a dataset's shape and counts.
- **moot_vault_status** — vault configuration and posture.

### Tier 3 — Operations

One job or one thread of continuity, read or appended precisely.

- **moot_drain_status** — every long-running drain's frontier
  (corpus_encode queue depth; the distillation eligibility count; the
  rider-gated subject_backfill lane). Pollable; no orientation block.
- **moot_vault_export** — start/drive a vault export job.
- **moot_vault_job** — one vault job's progress.
- **moot_vault_reconcile** — reconcile vault state against the estate.
- **moot_packet_get** — one packet by id.
- **moot_packet_list** — packets, filtered.
- **moot_packet_lineage** — one packet's derivation thread.
- **moot_read_journal** — the agent journal's recent entries.
- **moot_write_journal** — append one journal entry (session
  continuity).

---

## Placement notes

Judgment-call placements recorded at ratification, unchanged here:
fact_timeline in Survey; synthesize in Recall/Focus (composed recall,
not a lens); update_memory in Belief though its revive mutation is
Circulation-tier; dataset_query in Focus while dataset_stats is
Orientation; vault_export in Operations. `moot_recollect` is retired
(notice-only stub; removal queued for the next major).

## Changelog

### 0.1.0 -- 2026-08-02

Initial family pages from the ratified 2026-08-02 taxonomy: six
families × three tiers, all 75 live verbs documented with use,
arguments, default reply shape (dense row), and follow-up affordances
(progressive recall PR-11).
