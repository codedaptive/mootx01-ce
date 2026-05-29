# EideticLib

A deterministic text-to-anchor utility: pass a term, get back a Universal Decimal Classification code and an optional Wikidata Q-ID. Pure Swift and pure Rust, conformance-gated, ships with a frozen reference snapshot of UDC (CC-BY-SA) and Wikidata (CC0).

The gnomon is the pointer on a sundial, the part that casts the shadow which tells you the time. Cast a shadow at a term, get an angle back. The thing that points.

## What it does

```rust
use gnomon_kit::lookup;

let anchor = lookup("organic chemistry");
// anchor.udc_code     = "547"
// anchor.wikidata_qid = Some("Q2329")
// anchor.confidence   = 48
```

```swift
import EideticLib

let anchor = EideticLib.lookup("organic chemistry")
// anchor.udcCode      == "547"
// anchor.wikidataQID  == "Q2329"
// anchor.confidence   == 48
```

The pipeline tokenizes (UAX 29 word boundaries), normalizes (case fold), stems (Snowball English Porter2), matches against a gazetteer of 198 UDC codes with 2026 Wikidata anchors, classifies by weighted vote, and resolves the best Wikidata Q-ID by multi-criterion lexicographic ranking. The whole thing is deterministic against the pinned reference data; no network calls at lookup time.

## Why it exists

Several systems need an inexpensive, offline, deterministic way to map terms to a controlled classification. Library systems, knowledge management tools, document classifiers, federated memory substrates. The usual options trade off badly: pay an LLM API for every lookup, ship a neural inference runtime, or roll your own gazetteer from scratch. EideticLib is the third path with the rolling-your-own already done: a small static dataset, a small algorithm, a single function call.

## Installation

### Rust

```toml
[dependencies]
gnomon-kit = "0.1"
```

Note: the Rust crate is not yet on `crates.io`. For now, add a `path = "..."` or `git = "..."` dependency. See [INSTALL.md](INSTALL.md) for the path-based dependency form.

### Swift

```swift
.package(url: "https://github.com/bob-codedaptive/gnomon-kit", from: "0.1.0"),
```

The Swift Package Index publication tracks the same versions as the Rust crate.

## API

The public surface is one function. Same shape in both languages.

**`lookup(term: String) -> Anchor`**

Composes the full pipeline against the bundled reference data and returns an `Anchor` carrying the UDC code (empty when no match), the Wikidata Q-ID (nil when no confident match), the confidence (0/16/32/48/56 mapping to the substrate's 6-bit provenance field), and the data version that produced the answer.

The `Anchor` type is byte-identical between languages under JSON serialization, so callers can persist and exchange anchors across the boundary.

For lower-level access, the resolver and classifier are also public and documented.

## Data

EideticLib bundles two reference data files at `Sources/EideticLib/Resources/`:

**`UDCSchedule.json`** carries 275 UDC codes: all 10 main classes at depth 1, 67 active subdivisions at depth 2, and 198 representative codes at depth 3 covering computing, philosophy, social sciences, mathematics, physics, chemistry, biology, medicine, engineering, arts, language, and history. Each entry has a label, description, parent reference, and a list of gazetteer terms (single words and multi-word phrases) used by the matcher.

**`WikidataSubset.json`** carries 2026 Wikidata Q-IDs: 244 canonical concepts directly anchored to UDC codes (Section A) plus 1782 common-knowledge entities stratified across the UDC main classes (Section B). Each entry has a Q-ID, label, aliases, a UDC anchor hint, and a section discriminator.

Both files carry `schema_version` and `data_version` at their roots. Schema changes require a version bump and a migration; data refreshes do not. The assembly scripts that produced today's data are committed at `tools/`; re-running them against today's Wikidata produces a comparable subset with mild drift.

## Cross-language conformance

The Swift and Rust ports are not just two implementations of the same idea; they are gated against a shared contract file. `Tests/SharedVectors/lookup_vectors.json` lists 26 input/expected-output pairs; both languages must produce byte-identical anchors for every vector. Any divergence is a hard conformance failure.

This isn't accidental discipline. The cross-language conformance is what makes EideticLib safe to use from heterogeneous estate substrates: a Swift app and a Rust daemon can persist anchors to the same store and trust that lookups produced the same answer in both halves of the system.

## Performance

Single lookup on Apple Silicon is sub-millisecond. The first call also pays for parsing the bundled JSON; subsequent calls use a cached parse.

Measured on an M-series Mac with the bundled v0.1.0 data (275 UDC codes, 2026 Wikidata entries):

| Operation | Rust |
|---|---|
| Cold start (parse JSON, build indexes) | ~1.5 ms |
| Single lookup, warm | ~360 µs |
| 1000 lookups, warm | ~360 ms |

The warm lookup is dominated by the resolver's linear scan across the Wikidata subset. At 2026 entries that's fast enough for substrate-scale use; if you need to drive much higher throughput, the resolver can be pre-indexed by token (a follow-on optimization, not yet in v0.1.0). Run `cargo run --release --example benchmark` from `rust/` to measure on your hardware.

The Swift port shows similar shape. Both languages perform comparably because both spend their time in hashmap lookups; the algorithmic shape is identical between ports.

## Licensing

Two licenses inside this repo, kept on separate files so the boundary is unambiguous.

The **code** is dual-licensed under [MIT](LICENSE-MIT) or [Apache 2.0](LICENSE-APACHE). Pick whichever fits your project.

The **UDC reference data** at `Sources/EideticLib/Resources/UDCSchedule.json` is licensed under [CC-BY-SA 3.0](LICENSE-DATA). It is derived from the Universal Decimal Classification Summary published by the UDC Consortium under the same license.

The **Wikidata reference data** at `Sources/EideticLib/Resources/WikidataSubset.json` is licensed under [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/), matching Wikidata's own dedication.

CC-BY-SA only affects the UDC data file. Code that depends on EideticLib through its public API and uses the lookup function's outputs is unaffected by share-alike: the outputs are fact data (UDC codes and Wikidata Q-IDs are facts), and the "mere aggregation" doctrine covers software linkage to a separately-licensed data file. See [LICENSE-DATA](LICENSE-DATA) for the full boundary explanation.

If you redistribute the data files, you must comply with their respective licenses. If you only consume the lookup outputs, no obligations propagate.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Contributions welcome especially for gazetteer term improvements, UDC depth-3 expansion, and Wikidata corpus refinements; algorithmic changes require a conformance regression check against the shared vectors.

## Status

v0.1.0. Phase 1 of a three-phase plan:

- Phase 1 (this release): frozen snapshot, deterministic lookup, both languages, cross-language conformance.
- Phase 2 (future): an opt-in `gnomon-kit-cache` companion crate that opportunistically warms a local cache against the live Wikidata API for callers that want freshness over determinism.
- Phase 3 (future): a patch-snapshot publishing cadence so the bundled data tracks Wikidata and UDC updates without breaking the deterministic-snapshot contract.

The base EideticLib's deterministic behavior is stable across all three phases; callers who never opt into the cache or upgrade past the pinned snapshot get the same answer in perpetuity.

## Background

EideticLib started as a substrate primitive for the MOOTx01 deep-memory project: a way to anchor stored content to a controlled classification without depending on neural inference at write time. It separated from the substrate because the dataset turned out to be useful in its own right. The substrate now consumes EideticLib like any other public dependency.

The architecture and the algorithm specifications live in the source: each module's leading comment is the contract its implementation realizes. Reading `Sources/EideticLib/WikidataResolver.swift` (or the matching `rust/src/wikidata_resolver.rs`) gives you both the spec and the code.
