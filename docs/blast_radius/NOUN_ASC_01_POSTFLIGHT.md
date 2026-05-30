# Post-Flight Report — NOUN-ASC-01

**Mission:** Association noun substrate (type + table + store, both legs)
**Reviewer:** Adams
**Date:** 2026-05-30
**Baseline:** `93363c7` · Head: `e3eac3b`
**Commits reviewed:** d83db8a / c3e2d9d / e3eac3b

---

## Final Verdict: PASS — CLEAN

Zero CRITICAL findings. Zero WARNING findings. Tests independently
verified, exit 0, counts match Bilby's claims exactly.

---

## First Pass Findings

| # | Severity | Finding | File:Line | Resolution | Status |
|---|---|---|---|---|---|
| — | — | No findings. | — | — | — |

---

## §9 — Blast Radius Verification

**§9.1 BRR exists.** `docs/blast_radius/NOUN_ASC_01_BLAST_RADIUS.md` — present.

**§9.2 Baseline test pass count recorded.** BRR records 422 Swift / 367
Rust at mission start. Smythe pre-flight confirms these baseline counts.

**§9.3 MUST_UPDATE files in diff.** Twelve files claimed; twelve files in
diff. Match is exact.

| BRR MUST_UPDATE | In diff? |
|---|---|
| `Sources/LocusKit/Association.swift` | yes |
| `Sources/LocusKit/AssociationOperational.swift` | yes |
| `Sources/LocusKit/LocusKitSchema.swift` | yes |
| `rust/src/association.rs` | yes |
| `rust/src/association_operational.rs` | yes |
| `rust/src/schema.rs` | yes |
| `Sources/LocusKit/DrawerStore.swift` | yes |
| `rust/src/drawer_store.rs` | yes |
| `rust/src/drawer_store_inmemory.rs` | yes |
| `rust/src/lib.rs` | yes |
| `Tests/LocusKitTests/AssociationTests.swift` | yes |
| `rust/src/association_tests.rs` | yes |

**§9.4 INTENTIONALLY_LEFT justifications.** N/A — no INTENTIONALLY_LEFT
entries in the BRR. Every MUST_UPDATE file is in the diff.

**§9.5 Grep drift.** Checked manually: no new call sites for the new
symbols have appeared in non-diff files. All new surface
(`addAssociation`, `getAssociation`, `associationsFrom`, `associationsTo`,
`add_association`, `get_association`, `associations_from`,
`associations_to`) is reached only by the new test files.

**§9.6 Prohibited patterns.** Git diff scanned. Zero instances of
`legacy`, `compat`, `bridge`, `shim`, `@available(*,deprecated)`,
TODO/FIXME on changed symbols. None.

**§9 Overall: PASS.**

---

## §9 Additive-only verification (0 deletions claim)

```
git diff --stat 93363c7 HEAD
12 files changed, 1898 insertions(+)
```

Zero deletions. Confirmed. No existing symbol's semantics were altered.
Verified by reading every changed file: all edits are appends or new
files. The two existing-file edits (`LocusKitSchema.swift`,
`DrawerStore.swift`, `drawer_store.rs`, `drawer_store_inmemory.rs`,
`lib.rs`, `schema.rs`) are additive — new table/index registration,
new trait defaults, new impl methods, new module declarations, updated
test vectors in two schema tests.

---

## §9 Four deliberate deviations from Tunnel template — verified

**Deviation 1 — No `kind`/`kind_id`.**
`Association.swift` has no `kind` field. `association.rs` has no
`kind_id` field. `associationsTable` in `LocusKitSchema.swift` has no
`kind_id` column. The `associations_table()` fn in `schema.rs` has no
`kind_id` column. Confirmed correct.

**Deviation 2 — Required `latticeAnchor` with empty-udcCode rejection.**
`Association.swift` carries `latticeAnchor: LatticeAnchor` as a stored
property. `association.rs` carries `lattice_anchor: LatticeAnchor`.
`addAssociation` in `DrawerStore.swift` calls
`Self.validateNonEmpty(a.latticeAnchor.udcCode, label: "latticeAnchor.udcCode")`
before insert. `add_association` in `drawer_store_inmemory.rs` calls
`validate_non_empty(&association.lattice_anchor.udc_code, "latticeAnchor.udcCode")`
before insert. Both tested by `latticeAnchorRequired` / `lattice_anchor_required_rejects_empty`.
Confirmed correct.

**Deviation 3 — Association is NOT Hashable.**
`LatticeAnchor` in `EstateTypes.swift` (line 55):
`public struct LatticeAnchor: Sendable, Equatable, Codable` — not Hashable.
`Association.swift` (line 67): `public struct Association: Equatable, Codable, Sendable` —
not Hashable. This is the exact reason stated: synthesised Hashable
requires all stored properties to be Hashable; LatticeAnchor is not.
Rust `Association`: `#[derive(Debug, Clone, PartialEq, Eq)]` — no Hash.
Rust `LatticeAnchor`: `#[derive(Debug, Clone, PartialEq, Eq)]` — no Hash.
Swift/Rust parity is exact. Confirmed correct.

**Deviation 4 — §2.4 operational layout.**
Cookbook §2.4 "Association operational" specifies:
- bits 0–11: `signal_sources_seen` [bitset]
- bits 12–17: `decay_class` [scale-gapped, 0/16/32/48]
- bits 18–19: `arity` [contiguous, 0/1]

Swift `AssociationOperational.swift`:
- `AssociationSignalSources.mask: Int64 = 0xFFF` (12-bit mask, bits 0–11)
- `decayClass`: `BitField.extractField(operationalBitmap, shift: 12, width: 6)` — bits 12–17
- `arity`: `BitField.extractField(operationalBitmap, shift: 18, width: 2)` — bits 18–19
- Scale-gapped raws: `case pinned = 0`, `slow = 16`, `normal = 32`, `fast = 48`

Rust `association_operational.rs`:
- `MASK: i64 = 0xFFF`
- `decay_class()`: `bit_field::extract_field(operational_bitmap, 12, 6)`
- `arity()`: `bit_field::extract_field(operational_bitmap, 18, 2)`
- Scale-gapped raws: `Pinned = 0`, `Slow = 16`, `Normal = 32`, `Fast = 48`

Swift and Rust bit constants are byte-identical. Scale-gap encoding is
identical. Fallback to zero-case for unrecognised raws is identical on
both legs. Cookbook §2.4 agreement is exact.

---

## §10 — Test Execution Verification

Method: **B (re-run)** — mission changes schema and engine-adjacent store code.

### Swift

```
cd packages/kits/LocusKit && swift test 2>&1 | tail -8
EXIT: 0
```

Output (verbatim tail):
```
Test run with 441 tests in 40 suites passed after 1.157 seconds.
EXIT: 0
```

Bilby's claim: exit 0, 441 tests.
My verification: exit 0, 441 tests.
**MATCH.**

### Rust

```
cd packages/kits/LocusKit/rust && cargo test --lib 2>&1 | tail -8
EXIT: 0
```

Output (verbatim tail):
```
test result: ok. 390 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s
EXIT: 0
```

Bilby's claim: exit 0, 390 tests.
My verification: exit 0, 390 tests.
**MATCH.**

### Warning verification

```
cargo test --lib 2>&1 | grep -i warning
```

Output:
```
warning: variable does not need to be mutable
warning: `locus-kit` (lib test) generated 1 warning (run `cargo fix --lib -p locus-kit --tests` to apply 1 suggestion)
```

Location: `src/drawer_store_inmemory.rs:3007` — `let mut e1 = DiaryEntry { ... }`.
At baseline `93363c7`: same warning, same cause, at line 2784.
Line shift (2784 → 3007 = 223 lines) is consistent with the 223-line
addition to `drawer_store_inmemory.rs` in this mission.
Byte-identical-in-cause at baseline. **Pre-existing. Zero new warnings.**

Swift: zero warnings (verified via `swift build 2>&1 | grep warning` —
empty output).

**§10 Overall: PASS. Tests actually ran with exit 0. Counts match.
Warning count confirmed.**

---

## Scope verification

Mission specified net-new files + one existing schema file. Diff is
exactly those 12 files, 1898 insertions, 0 deletions.

No scope violations. No out-of-scope edits.

`docs/validation/**` — untouched.
`Tunnel.swift`, `KGFact.swift`, `Proposal.swift` — untouched.
`SubstrateLib` primitives — untouched (used, not changed).
The `tunnels` table declaration — untouched.

---

## Stale call site check

The `associations` table is now registered in both schema lists. Checked
whether any existing test enumerates tables or indices by hardcoded count:
- Swift: no hardcoded table counts in `Tests/`. No stale enumerations.
- Rust: the `table_count_and_order` and `index_names_match_swift_order`
  tests in `schema.rs` were updated by Bilby to include the new
  `associations` entries. Both tests pass. No other Rust code enumerates
  tables or indices by count. Confirmed clean.

---

## Anti-pattern scan

Scanned the full diff for: bridges, shims, silenced warnings, partial
migrations, `@available(*, deprecated)` markers, orphan deprecations,
path-of-least-resistance patterns.

Result: none found.

---

## Verdict

**PASS — CLEAN.**

Tests pass — verified, exit 0. Swift 441 tests. Rust 390 tests. One
pre-existing unrelated cargo warning, zero new warnings. Diff is exactly
12 files, 1898 insertions, 0 deletions. BRR's 12 MUST_UPDATE files all
in the diff. Four documented deviations from Tunnel template are real,
correct, and cookbook-supported. Swift↔Rust parity on bit constants,
enum raws, and accessors is exact. No prohibited files touched. No
prohibited patterns. No stale call sites.

Ship it.

---

## Adams Learning Note — NOUN-ASC-01

**Mission:** Association noun substrate (type + table + store, both legs)
**Files reviewed:** 12 (all new + additive edits to 6 existing)
**Date:** 2026-05-30

### Patterns observed

- **Net-new noun substrate, clean shape:** The 12-file additive pattern
  (type + operational + schema × 2 legs, store × 2 legs, tests × 2
  legs, lib.rs + module registration) is now established twice (NOUN-PRO-01
  and NOUN-ASC-01). This is the canonical shape for a new noun substrate
  mission. Future post-flights against the same pattern can fast-track
  the scope check.
  Recurrence: 2nd time — also seen in NOUN-PRO-01.
  Future signal: if a new noun substrate mission has fewer than 12 files
  in the diff, look for the missing 6 (especially lib.rs, schema.rs,
  drawer_store_inmemory.rs, and the Rust test file).

- **Schema test vector maintenance:** Rust `table_count_and_order` and
  `index_names_match_swift_order` require explicit update each time a
  new table/index block lands. Both were correctly updated here. This is
  a known failure mode; confirmed clean again.
  Recurrence: 2nd time.
  Future signal: after any schema-touching mission, Smythe or Adams
  should grep for these two test names and verify they include the new
  table/index names.

- **Lattice anchor required on new nouns:** The BRR explicitly called
  out that Tunnel (the template) does NOT carry an anchor, but
  Association must. Bilby got this right. The validation gate
  (`validateNonEmpty` on `latticeAnchor.udcCode`) is present on both
  legs and tested on both legs. Clean.
  Recurrence: 2nd time (Proposal had the same requirement).
  Future signal: any new noun mission that reads from NOUN-PRO-01 or
  NOUN-ASC-01 as template will inherit the anchor. The gap only bites
  when Tunnel is the template and the reader forgets Tunnel predates I-16.

- **Non-Hashable due to LatticeAnchor:** Association and Proposal both
  omit Hashable because LatticeAnchor is not Hashable. The comment in
  Association.swift is explicit and complete. This will repeat for any
  noun that carries a lattice anchor.
  Recurrence: 2nd time.

### Surprises

None. The mission was exactly what the BRR and pre-flight said it would
be. The 12-file shape, the two deviations from Tunnel, and the test
counts all matched predictions. This is a well-scoped, well-executed
noun substrate addition.

### File-specific notes

- `AssociationOperational.swift` / `association_operational.rs`: the
  signal-sources-seen bitset is the first OptionSet/newtype in this
  codebase (Tunnel and Proposal use only contiguous-field extracts). The
  `mask: Int64 = 0xFFF` approach is clean and future-proof for bits 10–11
  remaining reserved without code change.

- `DrawerStore.swift` + `drawer_store_inmemory.rs`: the `ext` column is
  declared in the schema but omitted from all `*Values` dictionaries —
  consistent with every other noun type. Not a bug; nullable default NULL.

### Systemic flags

None. The noun substrate pattern is stable and well-understood at this
point. Nothing here warrants surfacing to Skippy or Kong.
