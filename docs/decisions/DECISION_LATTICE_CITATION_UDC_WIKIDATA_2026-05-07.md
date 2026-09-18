---
status: decided
question: What universal lattice citation does GeniusLocusKit commit to for v1?
authors: MOOTx01 maintainers
date: 2026-05-07
relates_to:
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
supersedes: none
context:
  - GeniusLocusKit needs a universal coordinate system for drawers and estates.
  - The lattice must be open-licensed, depth-disciplined, and concept-resolvable across languages.
  - The chosen lattice must be replaceable but ship with a concrete v1 reference.
---

# Lattice Citation: UDC + Wikidata (v1 commitment)

## Decision

GeniusLocusKit v1 cites **UDC (Universal Decimal Classification)
depth coordinates anchored to Wikidata Q-IDs as concept identifiers**
as its universal lattice. Every drawer carries a UDC code; the
optional Wikidata Q-ID resolves the concept's identity in any
language.

The lattice is replaceable — the architecture defines how to plug
in alternatives — but UDC + Wikidata is the v1 published reference
and the basis of the v1 reference implementation.

## Why this combination

### Why UDC over alternatives

Five candidate systems were considered as the universal coordinate
system:

| System | Strengths | Weaknesses |
|---|---|---|
| Dewey Decimal Classification (DDC) | universal recognition, simple mental model, every schoolchild has touched it | OCLC-licensed (problematic for open spec), Western-centric (religion class is 80% Christianity), increasingly criticized as biased |
| Universal Decimal Classification (UDC) | open license, continuously developed since 1895, supports faceted classification, decimal mental model identical to Dewey | less recognized by laypeople, facet syntax is intimidating |
| Library of Congress Classification (LCC) | granular at the research level, better for specialized work | US-centric, less internationally adopted, alphanumeric system harder to reason about than decimals |
| Wikipedia/Wikidata categorical structure | global, multilingual, AI-readable, free, constantly updated | organic and inconsistent, not depth-disciplined, the same concept can appear in multiple unrelated branches |
| Roget's Thesaurus structure | philosophically grounded, organizes by how concepts relate | dated, English-centric, optimized for synonyms not hierarchy |

UDC was chosen for the lattice's depth structure because:

- **Open license** (the UDC Consortium, a Dutch nonprofit, releases
  the summary classification under Creative Commons-compatible
  terms). Citing UDC in an open architecture spec does not create
  licensing entanglement.
- **Hundred-year continuous development** (1895 to present). The
  scheme has survived more technological transitions than any
  single AI memory tool will likely encounter.
- **Faceted classification** (a single concept can cite multiple
  branches simultaneously, e.g., `336.71:347.7` = "banking law").
  This matches how AI memory actually wants to work — drawers
  often span multiple conceptual domains.
- **Decimal depth** maps directly to the absolute-depth coordinate
  model. UDC `5` is "Mathematics, Natural Sciences" at depth 1;
  UDC `54` is "Chemistry" at depth 2; UDC `547` is "Organic
  Chemistry" at depth 3. The depth of the code IS the depth in
  the universal lattice.
- **International adoption**, particularly in Europe. Use in over
  150,000 libraries worldwide.

### Why Wikidata as concept anchor

UDC provides depth coordinates but the codes themselves are
language-neutral abstractions. A drawer tagged `547` is "in the
organic chemistry zone" but the system needs to know what
"organic chemistry" *means* to reason across drawers, federate
across languages, and resolve ambiguity.

Wikidata Q-IDs solve this:

- **Stable global identifiers** — `Q11165` is "organic chemistry"
  forever. Unlike Wikipedia URLs, Q-IDs do not change when articles
  are renamed.
- **Multilingual labels** — every Q-ID has labels in hundreds of
  languages. An AI agent reading an estate in any language can
  resolve the concept.
- **Typed relationships** — Wikidata has `instance of`, `subclass
  of`, `part of`, and many other property types. The graph
  structure is queryable.
- **AI-native vocabulary** — the AI/ML community has spent the
  last decade encoding world knowledge into Wikidata. It is the
  substrate that backs Wikipedia, which is the substrate of
  half of all GPT-class training corpora.
- **Free, open, permissively-licensed** — CC0 for the data.
- **Active maintenance** — the global community keeps it current
  in a way no proprietary ontology can match.

### Why both, not one or the other

**UDC alone** gives depth without identity. A drawer tagged `547`
is positioned in the lattice but the engine cannot resolve the
concept beyond "whatever UDC means by 547."

**Wikidata alone** gives identity without depth. A drawer linked
to `Q11165` (organic chemistry) is identified but the engine
cannot reason about its position relative to other drawers — there
is no stable depth ordering across the Wikidata graph.

**UDC + Wikidata together** give both. UDC anchors depth; Wikidata
anchors meaning. A drawer cites `UDC: 547 / Wikidata: Q11165` and
the engine knows both where it sits in the universal scheme and
what concept it represents.

This combination has not been published as a memory architecture
substrate before. The combination is part of the contribution.

## How drawers cite the lattice

Every drawer carries (proposed schema, subject to refinement):

- `udc_code` — the UDC classification, primary depth coordinate.
  Required.
- `wikidata_qid` — the Wikidata Q-ID for the drawer's primary
  concept. Optional but strongly recommended; populated by the
  enrichment daemon when initially absent.
- `udc_facets` — additional UDC codes for cross-cutting concerns
  (e.g., a drawer about chemistry safety regulations might have
  primary `547` and facet `614.8`). Optional.
- `wikidata_qids_secondary` — additional Q-IDs for secondary
  concepts. Optional.

The exact column shape is not yet finalized — it may be a
single-column array, a separate `lattice_citations` table, or
inline columns. Resolved during specification drafting.

## How estates cite the lattice

The estate manifest declares a **zoom window** — the depth range
within UDC the estate operates in. Examples:

- General-life estate: UDC zoom window `0–9` (broad, top-level)
- Woodworking-hobby estate: UDC zoom window `684.08` (narrow, deep)
- Professional-coding estate: UDC zoom window `004.42` (medium)

The zoom window controls:

- Validation of incoming drawers (a drawer tagged outside the zoom
  window triggers a soft warning at write time or is reclassified
  at enrichment time)
- Federation overlap detection (two estates with non-overlapping
  zoom windows have no semantic territory to share)
- Search reranking (drawers within the active zoom window are
  weighted higher; drawers outside it are dimmer but still
  reachable)

## How federation uses the lattice

Two estates federate at whatever band of the universal lattice
their zoom windows overlap. The federation primitive is **shared
rooms** — rooms marked as visible across the federated group.

- One general-life estate (`0–9`) and another general-life
  estate (`0–9`) overlap fully on the lattice. Their family wing
  rooms (`649` family living, `316.356.2` family relations) can
  share fluidly.
- A woodworking-hobby estate (`684.08`) and a general-life
  estate (`0–9`) overlap at the broad level (the
  woodworking zoom is contained within `6` Applied Sciences) but
  not at the deep level. Sharing is possible but limited to
  wide-angle topics.

The agent reading a federated group's manifest can see exactly
where the zoom windows overlap and reason about cross-estate
queries accordingly.

## Replaceability

The lattice is plug-in. The architecture defines:

- The contract a lattice citation must satisfy (depth coordinate,
  optional concept identifier, range comparison operators)
- The interface for a `LatticeProvider` that resolves codes,
  computes depth, computes overlap, etc.

Alternative lattices a future user might plug in:

- **DDC** if licensing is acquired and Western-centrism is not a
  concern for the use case
- **LCC** for academic-research-heavy use cases
- **SUMO** or **BFO** for biomedical or industrial applications
  where existing ontologies are mandatory
- **A custom domain-specific lattice** for highly specialized
  scientific use cases (e.g., taxonomy of physical particles,
  taxonomy of musical works)

UDC + Wikidata is the v1 commitment because the durability claim
*requires* a specific citation. A pluggable slot with no example
is not actually durable. By committing to UDC + Wikidata as the
v1 reference, the architecture has a working answer; alternative
implementations can plug in their own lattice without negotiating
the meta-question of what a lattice is.

## Documentation requirements

UDC and Wikidata are both substantial topics. The spec must
include or reference:

- A short tutorial on UDC structure (what the codes mean, how to
  navigate them)
- A short tutorial on Wikidata Q-IDs (what they are, how to look
  them up)
- A worked example showing how a drawer is tagged
- A worked example showing how an estate declares its zoom window
- Citations to the UDC Consortium and to Wikidata for authoritative
  references

The 8th-grade reading level constraint applies to the primer; the
spec can assume more technical familiarity but must remain
accessible.

## Open questions about the lattice

- **What level of UDC detail does the engine validate?** Strict
  validation means rejecting drawers with codes not in the UDC
  Summary; permissive validation accepts any well-formed code.
  The reference implementation needs a UDC code validator; what's
  its source of truth?
- **How does the engine resolve Wikidata Q-IDs?** Online lookup,
  cached snapshot, embedded subset? Performance and offline
  reliability tradeoffs.
- **Multilingual UDC alternatives.** UDC has been published in
  several languages (English, French, Spanish, Russian, others).
  Does the engine support reading codes in any UDC language, or
  only one canonical language?
- **Faceted UDC depth.** A drawer tagged `336.71:347.7` is
  technically at "depth 4 / depth 4" (each side is a 4-character
  code). How does the depth-coordinate system handle the
  composition? My initial instinct: store the primary code's
  depth and treat facets as secondary.

These resolve during specification drafting.

## References

- UDC Consortium: `udcc.org`
- UDC Summary (open access): `udcsummary.info`
- Wikidata: `wikidata.org`
- Library of Congress format description for VPF (the architectural
  pattern that inspired this approach):
  `loc.gov/preservation/digital/formats/fdd/fdd000302.shtml`

---

*End of decision record.*
