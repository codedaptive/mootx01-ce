# Smythe Pre-flight: NOUN-ASC-01

## Status

YELLOW — clear to proceed. No RESCOPE required.

---

## Status details

- **Blast radius:** Mission table lists 6 files. Real additive shape is 12 — confirmed within scope,
  identical pattern to NOUN-PRO-01. No symbols renamed; all net-new.
- **Prior art:** None conflicting. `find … -iname '*Association*'` returns empty. No half-built
  association code anywhere in the Rust source tree. NOUN-PRO-01 is fully merged and the Proposal
  files are present and clean as confirmed templates.
- **Environment:** Branch `stream/nas-association-noun-substrate` is active; head commit `93363c7`
  includes NOUN-PRO-01 merge. Baseline test counts (422 Swift / 367 Rust) are the inherited clean
  slate.
- **Dependencies:** None listed. Parallel-safe with NOUN-LRF-01 — the only shared edit is
  `LocusKitSchema.swift` + `schema.rs`; confirmed distinct from all NOUN-PRO-01 / NOUN-LRF-01
  symbols. Both schema files currently carry proposals but not associations; the additive insert is
  unambiguous.

---

## Blockers

None.

---

## Real blast radius — 12 files (vs mission's 6)

The mission table lists 6 files. The real additive shape is 12, identical to the NOUN-PRO-01
pattern. The extra 6 are explicitly required by Parts 2 and 3 but omitted from the table — purely
additive, no rescope warranted.

| File | In mission table? | Change | Why in scope |
|---|---|---|---|
| `Sources/LocusKit/Association.swift` | yes (CREATE) | new type | Part 1 |
| `Sources/LocusKit/AssociationOperational.swift` | yes (CREATE) | new accessors | Part 1 |
| `rust/src/association.rs` | yes (CREATE) | new type | Part 1 |
| `rust/src/association_operational.rs` | **no** | new accessors | Part 1 rust leg; mirrors tunnel_operational.rs split |
| `Sources/LocusKit/LocusKitSchema.swift` | yes (edit) | register `associations` table + indices | Part 2 |
| `rust/src/schema.rs` | **no** | register `associations` table; update `table_count_and_order` + `index_names_match_swift_order` tests | Part 2 |
| `Sources/LocusKit/DrawerStore.swift` | **no** | add addAssociation / getAssociation / associations(forSourceDrawerId:) + helpers | Part 3 |
| `rust/src/drawer_store.rs` | **no** | add trait default methods | Part 3 |
| `rust/src/drawer_store_inmemory.rs` | **no** | implement methods + helpers + const + import | Part 3 |
| `rust/src/lib.rs` | **no** | register association, association_operational, association_tests modules | required for new Rust files to compile |
| `Tests/LocusKitTests/AssociationTests.swift` | yes (CREATE) | conformance + store suite | Part 3 |
| `rust/src/association_tests.rs` | yes (CREATE) | store conformance suite | Part 3 |

---

## Tunnel template — confirmed field inventory

Verified at source. Fields Bilby must mirror case-for-case:

**Swift `Tunnel.swift`:**
```
id: String
sourceWing: String
sourceRoom: String
sourceDrawerId: String?
targetWing: String
targetRoom: String
targetDrawerId: String?
label: String
kind: TunnelKind          (separate kind_id column in schema)
adjectiveBitmap: Int64
operationalBitmap: Int64
provenanceBitmap: Int64
addedBy: String
filedAt: Date
tombstonedAt: Date?
removedByBatch: String?
```

Conformances: `Equatable, Hashable, Codable, Sendable`

**Rust `tunnel.rs`:** Identical shape with Swift-to-Rust conventions:
- `Date` → `i64` (epoch seconds); `Date?` → `Option<i64>`
- `String?` → `Option<String>`
- Derives: `Debug, Clone, PartialEq, Eq, Hash`

**IMPORTANT: Tunnel does NOT carry a lattice anchor.** Neither `Tunnel.swift` nor `tunnel.rs` has
`udcCode` / `udcFacets` / `wikidataQID` / `wikidataQidsSecondary`. The tunnels schema table
(`LocusKitSchema.swift:204`, `schema.rs:181`) also carries NO lattice anchor columns.

Cookbook §2.7 (I-16) states Associations are "anchored to lattice-midpoint of endpoints". This
means **Association must carry a lattice anchor even though Tunnel does not**. Mirror the
Proposal pattern (four columns: `udcCode NOT NULL DEFAULT ''` + `udcFacets` + `wikidataQID` +
`wikidataQidsSecondary`) for the anchor, not Tunnel's anchor-absent schema. The
`addAssociation` validator must reject an empty `udcCode` (same gate as `addProposal`).

---

## Tunnel operational bitmap — exact layout

**Source: `TunnelOperational.swift:101–112`, `tunnel_operational.rs:14–22`**

```
bits 0–2    TunnelDirection    (3 bits, contiguous)
              0=directional  1=bidirectional  2=symmetric  3=hub
bits 3–5    TunnelLifecycle    (3 bits, contiguous)
              0=active  1=proposed  2=superseded  3=withdrawn
bits 6–8    TunnelOriginClass  (3 bits, contiguous)
              0=userExplicit  1=derived  2=imported  3=federatedSync  4=migration
bits 9–11   TunnelStrength     (3 bits, scale-gapped: raws 0/2/4/6)
              weak=0  normal=2  strong=4  loadBearing=6
bit  12     has_inverse        (1 bit flag)
bits 13–63  reserved
```

`BitField.extractField` / `bit_field::extract_field` with correct shift/width. All fallback to
zero-case on unrecognised raw values.

---

## Association operational bitmap — exact layout

**Source: cookbook §2.4 "Association operational (empirical-dominant, 6-bit floor)"**

```
bits 0–11   signal_sources_seen    [empirical, bitset]
              bit 0  co_recall
              bit 1  co_confirmed
              bit 2  dream_pairing
              bit 3  vector_similarity
              bit 4  shared_entity
              bit 5  explicit_human
              bit 6  fingerprint_similarity
              bit 7  cross_estate
              bit 8  cross_tier
              bit 9  action_outcome
              bits 10–11  reserved
bits 12–17  decay_class            [temporal, scale-gapped]
              0=pinned  16=slow  32=normal  48=fast
bits 18–19  arity                  [spatial, contiguous]
              0=binary  1=n-ary
              v1 always 0; v2+ may use 1
bits 20–63  reserved
```

This is a bitset for the first 12 bits (not a contiguous encoded field) — each bit is an
independent flag. The `decay_class` is scale-gapped (sentinels at values not in
{0,16,32,48} fall back to 0=pinned). The `arity` field (bits 18–19) uses 2 bits, not 3; ship
contiguous with 2 cases.

**There is NO TunnelKind-equivalent `kind_id` column for Association.** The operational bitmap
carries all Association-specific semantics. No separate integer column needed.

---

## Adjective bitmap for graph-side nouns (§9.5.1)

Cookbook §9.5.1 covers the content-vs-graph distinction for the `expunge` verb. Key finding:

- Association is graph-side. When a drawer is expunged, the association's contribution to graph
  structures becomes stale. The `dreaming_recalc_required` flag (adjective bit 26, §2.3) is set
  synchronously on the affected Association row by `expunge`.
- **This does NOT affect the substrate shape of the Association type.** The `adjectiveBitmap`
  column carries the same cross-noun layout as every other noun (state cluster bits 0–5, sensitivity
  bits 4–6, etc.). No special adjective column or layout for graph-side nouns.
- The graph-side implication is a verb-layer concern (expunge sets bit 26 on neighbour rows), not a
  substrate-shape concern. This mission adds NO verb behavior. Document in inline comments but no
  special field.

---

## Lattice anchor — §2.7 (I-16)

I-16 requires lattice anchor on all nouns. Associations specifically: "anchored to
lattice-midpoint of endpoints." The Tunnel template does NOT carry an anchor (predates I-16;
same omission as KGFact, noted in NOUN-PRO-01 report). Association must carry it.

Pattern: mirror the Proposal anchor — four columns in the schema plus validation in the store.
The `addAssociation` method must reject empty `udcCode` with `LocusKitError::InvalidContent`
(Rust) / `LocusKitError.invalidContent` (Swift).

---

## Acceptance matrix — confirmed

`Acceptance.swift:29`:
```
case .association:
    return [.mutate, .expunge, .recall]
```

- Accepts: `mutate`, `expunge`, `recall`
- Does NOT accept: `capture`, `withdraw`
- `Noun.swift:36`: association role = `.structure` (same as tunnel and diaryEntry)

No substrate-shape impact. No capture verb means no capture-channel column is needed.
No withdraw means no `withdrawnAt` / `tombstonedAt` soft-delete lifecycle equivalent to tunnel.
However, Tunnel carries `tombstonedAt` + `removedByBatch` from Rev 1.0 for the future soft-delete
workflow — mirror those columns on Association for parity (reserved for Rev 2.0).

---

## Schema table — what the tunnels table has that Association must mirror

**`LocusKitSchema.swift:204–227`, `schema.rs:181–208`**

Tunnels schema columns (both legs):
```
id (TEXT, PK)
sourceWing (TEXT)
sourceRoom (TEXT)
sourceDrawerId (TEXT, nullable)
targetWing (TEXT)
targetRoom (TEXT)
targetDrawerId (TEXT, nullable)
label (TEXT)
addedBy (TEXT)
filedAt (timestamp)
tombstonedAt (timestamp, nullable)
removedByBatch (TEXT, nullable)
kind_id (INT, default 1)
adjectiveBitmap (bitmap / Int64)
operationalBitmap (bitmap / Int64)
provenanceBitmap (bitmap / Int64)
ext (json, nullable)
```

No generated columns on tunnels. No lattice anchor columns on tunnels.

**Association schema must add over tunnels:**
- Lattice anchor: `udcCode TEXT NOT NULL DEFAULT ''`, `udcFacets TEXT nullable`,
  `wikidataQID TEXT nullable`, `wikidataQidsSecondary TEXT nullable`
- Drop `kind_id` — Association has no TunnelKind-equivalent integer kind column.
- Keep `label` (free-form relationship label) — carried on Tunnel, appropriate for Association
  (describes the nature of the association).
- `tombstonedAt` + `removedByBatch` — mirror Tunnel's reservation for Rev 2.0 soft-delete.

**Indices for Association** (mirror tunnels pattern + add lattice anchor index):
```
idx_associations_source  → (sourceWing, sourceRoom)   — edge lookup from source
idx_associations_target  → (targetWing, targetRoom)   — edge lookup from target
idx_associations_udcCode → (udcCode)                  — lattice anchor resolution
```

Three indices (tunnels has 2; the third mirrors the proposals anchor-index pattern, appropriate
because I-16 requires the anchor and the cookbook designates anchor-code queries as a primary
access path).

---

## Schema test updates required in schema.rs

Two existing tests will need updating:

1. `table_count_and_order` — must add `"associations"` to the expected names vector. Current
   order ends `[…, "proposals", "node_bundles", "container_fingerprints", "recall_trace"]`;
   `associations` should follow `proposals` (both noun substrate tables).
2. `index_names_match_swift_order` — must add
   `"idx_associations_source"`, `"idx_associations_target"`, `"idx_associations_udcCode"` to the
   expected names vector, after the proposal indices and before `idx_recall_trace_*`.

Swift schema registers 10 tables (including `keysTable` which Rust does not yet mirror — pre-existing
divergence per NOUN-PRO-01 report). Rust test currently verifies 9. Adding `associations` brings
Rust to 10 tables — but `keys` is still absent. The test comment already documents this; update
the count to 10 and add the `associations` entry.

---

## Conflicts / prior art / prerequisites

- `find … -iname '*Association*'` → empty. Net-new confirmed.
- Rust `lib.rs` currently registers `proposal`, `proposal_operational`, `proposal_tests` (the
  NOUN-PRO-01 additions). No `association` modules present. Clean registration point.
- `Acceptance.swift` and `Noun.swift` both already carry `association` as a case — the vocabulary
  is registered; only the substrate (type + table + store) is absent. Confirmed.
- Parallel safety with NOUN-LRF-01: the only shared edit files are `LocusKitSchema.swift` and
  `schema.rs`. Serialize schema edits: npr → nas → nlr as the mission states.
- No half-built branches. Current branch is `stream/nas-association-noun-substrate`; mission is
  assigned to this stream. Clean.

---

## Bilby's stated approach

Mirror Tunnel exactly for the type + operational + store structure (both legs), with two deliberate
deviations: (1) carry the lattice anchor (four columns) that Tunnel omits — required by cookbook
I-16, same pattern as Proposal; (2) use the §2.4 Association operational bitmap layout in place of
Tunnel's five-axis operational layout. Register the `associations` table after `proposals` in both
schema legs, with three indices (source edge, target edge, udcCode). Tests prove round-trip
persist/fetch, bitmap byte-identity, source/target resolution, edge-index lookup, and
lattice-anchor-required gate. Rust mirrors Swift case-for-case. No verb behavior.

**Assessment: accepted.** No concerns. The two deviations from Tunnel (anchor + bitmap layout) are
correct and supported by cookbook authority. Bilby can start coding immediately.

---

## Actions (proceeding)

1. Part 1: Write `Association.swift` and `association.rs` + `association_operational.rs`. Use
   the §2.4 layout verbatim. Carry lattice anchor as four fields (mirror Proposal, not Tunnel).
   No `kind_id` field. Register modules in `lib.rs`. Build clean both legs.
2. Part 2: Register `associations` table in `LocusKitSchema.swift` (after proposalsTable) and in
   `schema.rs` (after proposals_table). Add three indices. Update `table_count_and_order` and
   `index_names_match_swift_order` tests. Build clean both legs.
3. Part 3: Add `addAssociation` / `getAssociation` / `associations(forSourceDrawerId:)` to Swift
   `DrawerStore.swift`. Add trait defaults in `drawer_store.rs`; implement in
   `drawer_store_inmemory.rs`. Write `AssociationTests.swift` (+~20) and `association_tests.rs`.
   Tests cover: round-trip; bitmap byte-identity; lattice-anchor-required gate; edge-index lookup
   (source); miss returns nil/None; table isolation. `swift test` green; `cargo test --lib` green;
   zero new warnings.

---

## YELLOW flag — one item to watch

**Tunnel has no lattice anchor; Association must.** This is the one structural deviation from
"mirror Tunnel exactly." The mission prose says "mirror Tunnel" but also "lattice anchor required
per cookbook 2.7." Those two statements are in tension because Tunnel does not carry an anchor.
Resolution confirmed above: carry the anchor (four columns), mirror Proposal's schema pattern for
the anchor columns, apply the same `addAssociation` validation gate as `addProposal`. The YELLOW
is not a blocker — the path is clear — but Bilby must not skip the anchor columns assuming the
Tunnel template is sufficient on its own.
