---
title: Progressive Discourse
version: 0.4.0
status: active
date: 2026-09-05
description: "The journey model of the ARIA surface: travel on subjects, confirm on distilled, read full text terminal-only — with the three canonical journeys as worked examples."
spec_type: protocol
authors: MOOTx01 maintainers
relates_to:
  - docs/reference/ARIA_VERB_FAMILIES.md  (the tiered verb surface journeys run over)
  - docs/reference/ARIA_MCP_SPEC.md  (per-verb behavioral contracts)
---

# Progressive Discourse

The front door to using the ARIA recall surface well.

## The model

A memory tool that answers a narrow question with twenty full texts has
not helped the AI — it has swamped it, and every unread paragraph sits
in context being reprocessed on every subsequent turn. The ARIA surface
is therefore shaped as a PROGRESSIVE DISCOURSE: the smallest true answer
first, widened only by follow-up questions the AI chooses to ask.

Three rules govern every journey:

1. **Travel on candidate rows.** Survey and Focus replies are the
   canonical candidate row (ARIA_MCP_SPEC 2.4.0 § 8.3) — six fixed
   columns: `uuid · subject · bestSpan · sscFacts · event_time · score`,
   absent optional values rendered `-`. The subject is a one-sentence
   assertion written for exactly this moment: an AI deciding which rows
   are worth pursuing; bestSpan (the best content span, capped at 60
   words) and sscFacts (structured findability facts) are the
   verification evidence beside it. Row cost is near-uniform per estate
   (each pick field is capped), so a reply's cost is its row count, not
   its luck.
2. **Confirm on distilled.** When a shortlist needs judging, hydrate it
   at the distilled tier — compressed representations sized for
   comparison, not narration. `moot_memory_get ids:[...]
   depth:distilled` is one call for the whole shortlist.
3. **Full text is terminal.** Verbatim content is read once, at the end
   of a journey, for the row that won — `depth:full` (the default
   single-id shape). Showing a human is the other legitimate use.

The UUID is the conversational cursor: every reply row is an address the
next call can pull on — `moot_memory_get`, `near:<uuid>`,
`moot_connection_search`, a lifecycle verb. Narration is
deviation-only: a clear result carries no commentary; a discrimination
or provenance line APPEARING is itself information.

## The three canonical journeys

Written over the real verb surface; these are the shapes the journey
benchmarks exercise (JOURNEY_PROTOCOL.md in the benchmarker).

### 1. Certain-fact pivot (Survey → Pinpoint)

"When did the quarterly planning meeting move?"

    moot_memory_search { "query": "quarterly planning meeting moved" }
    → found 3 candidate memories, one per line
      7C31… · Quarterly planning moved to Thursday · user: The quarterly planning meeting moves to Thursday. · kind: decision, entity: Sarah · Thursday; Sarah invites Monday; quarterly planning · 2026-07-14T09:12:00Z · 0.8102
      91DA… · Planning cadence discussion, monthly review unchanged · - · kind: note, entity: planning · monthly review unchanged; cadence · 2026-06-02T15:40:00Z · 0.4419
      B220… · - · Deploy window notes from the standup. · - · - · 2026-05-30T11:05:00Z · 0.2210

The first subject already answers the question. If the exact wording is
needed (quoting to the user), one terminal hop:

    moot_memory_get { "id": "7C31…" }        ← depth:full by default

Two calls, one full text read, done. A low-discrimination line here
would have redirected the journey to `moot_recall_precise` instead of a
blind widening.

### 2. Vague winnow (Survey → Focus → Pinpoint)

"What do we know about the deploy-gate situation?" — a formed topic, no
single target.

    moot_memory_search { "query": "deploy gate approvals staging" }
    → found 9 candidate memories, one per line

Winnow the plausible five in ONE call at the confirm tier:

    moot_memory_get { "ids": ["A1…","B2…","C3…","D4…","E5…"],
                      "depth": "distilled" }
    → resolved 5 of 5 requested memories, in request order

Each returns its candidate row (no score — a get is not a ranking) plus
the distilled text as an unlabeled indented continuation (distillation
is computed inline at read time via ContextDistiller). Judge, then
terminal-read the winner at depth:full — or pivot sideways from the
best row:

    moot_memory_search { "near": "C3…" }

`near:` inherits every filter and limit and excludes the anchor itself:
the neighborhood of a good answer is often the rest of the answer.

### 3. Temporal thread (Survey → Anchor → Pinpoint)

"How did our position on encryption evolve?"

    moot_fact_timeline { "entity": "encryption" }
    → time-major fact rows in filing order, active and retired, with
      lifecycle tags and fact ids (facts have no validity windows —
      active until retired)

or, memory-side:

    moot_memory_search { "query": "encryption position decision",
                         "ordering": "byCaptureTimeAsc" }
    → candidate rows in capture order (event_time visible per row)

Anchor on the inflection row and read its causal neighborhood:

    moot_lens_precedence { "id": "D4…" }      ← what led to it
    moot_lens_successors { "id": "D4…" }      ← what followed (candidate rows)

Terminal-read only the turning points. The thread's shape came from
subjects and timestamps; full text paid for two rows, not twenty.

## Cost discipline

The journey metric is the TOKEN·TURN RESIDENCY INTEGRAL: every token a
reply puts in context is paid again on every later turn it survives.
The candidate row keeps residency near-uniform per hit (every pick
field is capped); depth tiers keep text out of context until it is
chosen; deviation-only control lines keep the envelope a small fraction
of a nominal reply. When a journey feels
expensive, the defect is usually a tier skipped — full texts hauled at
Survey, or a winnow done one `id` at a time instead of one `ids` batch.

## Subject debt on the journey

Rows filed before subjects existed (or via bulk intake, by design)
render `-` in the subject column (fixed-column absence, ARIA_MCP_SPEC
2.0.0 § 8). They are still addressable — judge them by the remaining
pick fields or fetch by id — and `moot_estate_status` counts
them (`subjects: N/M (K missing)`). The standing behavior: offer the
user an interactive backfill and proceed only with their consent
(`moot_memory_list filter:missing_subject` → `moot_memory_get` →
`moot_update_memory mutation=setSubject`).

## Changelog

### 0.4.0 -- 2026-09-05

ENC-W6B: removed the `source: content (not yet distilled)` fallback marker from the
journey-2 narrative. Distillation is now computed inline at read time via ContextDistiller;
every `depth:distilled` response carries a rendered representation with no stored-distillate
prerequisite.

### 0.2.1 -- 2026-08-26

Vocabulary (mission SSC-RENAME): SSC defined at first prose use —
Semantic Search Candle. Terminology only; row grammar unchanged.


### 0.2.0 -- 2026-08-25

Realigned to the ARIA_MCP_SPEC/INTERFACE 2.0.0 retrieval contract: rule 1
travels on the seven-column canonical candidate row (fixed columns, `-`
absence); journey samples updated to the 2.0.0 headers and row grammar
(`found N candidate memories, one per line`; batch get `resolved N of M
requested memories, in request order`; unlabeled distilled
continuations); fact_timeline example corrected to the `entity` argument
and the no-validity-window fact model; `(no subject)` marker replaced by
the `-` column; residency prose updated (control lines, capped pick
fields).

### 0.1.0 -- 2026-08-02

Initial guide (progressive recall PR-11): the three rules, the three
canonical journeys as worked examples, cost discipline, subject debt.
