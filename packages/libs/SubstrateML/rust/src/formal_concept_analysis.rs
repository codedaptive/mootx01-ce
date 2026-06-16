//! Bounded Formal Concept Analysis over a materialized `FormalContext`
//! — Rust parity for `FormalConceptAnalysis.swift`. See
//! SUBSTRATEML_SPEC.md § 5.21 for the authoritative contract.
//! Per CLAUDE.md neither leg leads; both run identical math and are
//! gated against the shared hand-computed fixtures in the inline tests
//! below (the same cases the Swift `FormalConceptAnalysisTests` encode).
//!
//! The engine is pure data-in / data-out: it takes a fully
//! materialized context (rows × attributes) and reads no estate, no
//! `MatrixO`, no clocks, no randomness. Building a context from the
//! estate lives in the cognition tier (CognitionKit `FormalConcepts`),
//! NOT this pure engine.
//!
//! Bounding contract (the reason this is "bounded" FCA):
//!   - NO full concept-lattice enumeration anywhere. Concepts are
//!     seeded by default only from frequent single attributes (`Single`
//!     mode). `Multi` mode additionally seeds from frequent 2-attribute
//!     pairs (capped by `max_seeds`); still one closure per seed;
//!     deduplicated by intent.
//!   - NO exact Kuznetsov stability. Exact stability is exponential
//!     (subset enumeration over the extent); `FormalConcept::stability`
//!     is `None` when `stability_budget == 0` (the default). Set
//!     `stability_budget > 0` to populate it via `StabilityEstimator`
//!     (sampled Bernoulli approximation — never exact subset enumeration).

use std::collections::{HashMap, HashSet};
use crate::random_walks::SplitMix64;
use substrate_types::fnv;

/// Selects which seed pass(es) the miner uses when exploring the
/// concept lattice. Mirrors `SeedMode` in the Swift implementation.
///
/// The default is `Single` — equivalent to the v1 bounded-FCA
/// behaviour (seed only from frequent single attributes). `Multi`
/// adds a second pass that seeds from frequent 2-attribute pairs,
/// letting the miner discover concepts whose minimal generator is a
/// pair rather than a single attribute.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SeedMode {
    /// Seed only from frequent single attributes — v1 behaviour.
    Single,
    /// Seed from frequent single attributes AND frequent 2-attribute
    /// pairs. Finds more concepts at higher cost (O(|frequent|²)
    /// additional closures, bounded by `max_seeds`).
    Multi,
}

/// One cover delta: `lowerIntent` plus `addedAttributes`, where
/// `lowerIntent` is the more-general concept's intent and
/// `addedAttributes` = `more_specific.intent − lowerIntent`.
/// Both fields are sorted and disjoint; `lowerIntent ∪ addedAttributes`
/// equals the more-specific concept's intent.
///
/// Cover deltas are STRUCTURAL — they describe the concept order in
/// the emitted set; they do not assert that every row carrying
/// `lowerIntent` also carries `addedAttributes`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoverDelta {
    /// The more-general concept's intent (sorted, no duplicates).
    pub lower_intent: Vec<FormalAttribute>,
    /// `more_specific.intent − lower_intent` (sorted, non-empty).
    pub added_attributes: Vec<FormalAttribute>,
}

/// The cover-delta set over an emitted concept set — a structural
/// lens over the concept order. Produced by
/// `ConceptCoverDeltas::covering`; every delta in `cover_deltas` is a
/// direct cover in the concept's intent order (no intermediate concept
/// exists between `lower_intent` and `lower_intent ∪ added_attributes`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConceptCoverDeltas {
    /// Cover deltas, sorted by `lower_intent` size ascending,
    /// then lexicographic on `lower_intent`, then lexicographic on
    /// `added_attributes` — the same deterministic order as the Swift
    /// output.
    pub cover_deltas: Vec<CoverDelta>,
}

impl ConceptCoverDeltas {
    /// Derives the cover-delta set from an emitted concept set. Each
    /// delta `A → (B \ A)` is emitted when `A.intent ⊂ B.intent` and
    /// no `C` in the input has `A.intent ⊂ C.intent ⊂ B.intent`.
    ///
    /// Complexity: O(n² × n) over the concept count — quadratic
    /// concept scan plus a linear intermediate check per candidate
    /// cover pair. Suitable for the bounded concept sets this engine
    /// emits (hundreds, not millions).
    ///
    /// Structural only: cover deltas hold within the emitted concept
    /// set, not universally across all context rows. See the Swift
    /// `ConceptCoverDeltas.covering` for the definitive semantics.
    pub fn covering(concepts: &[FormalConcept]) -> ConceptCoverDeltas {
        if concepts.len() < 2 {
            return ConceptCoverDeltas { cover_deltas: Vec::new() };
        }

        // Sort by intent size ascending so that for any cover pair
        // (i, j), any intermediate concept k (si ⊂ sk ⊂ sj) must
        // satisfy |si| < |sk| < |sj| and therefore appear at an
        // index strictly between i and j.
        let mut sorted = concepts.to_vec();
        sorted.sort_by(|l, r| {
            l.intent.len().cmp(&r.intent.len())
                .then_with(|| l.intent.cmp(&r.intent))
        });

        // Pre-build HashSets for subset testing.
        let intent_sets: Vec<HashSet<&FormalAttribute>> = sorted
            .iter()
            .map(|c| c.intent.iter().collect())
            .collect();

        let mut cover_deltas: Vec<CoverDelta> = Vec::new();

        for i in 0..sorted.len() {
            for j in (i + 1)..sorted.len() {
                let si = &intent_sets[i];
                let sj = &intent_sets[j];

                // si must be a proper subset of sj.
                if !si.iter().all(|a| sj.contains(a)) {
                    continue;
                }

                // Check for any intermediate k between i and j.
                // Since the array is size-sorted, any intermediate
                // concept must sit at an index strictly between i
                // and j. Note: equal-size intents are fully distinct
                // (the concept set is deduplicated), so no false
                // positives from equal-size concepts.
                let has_intermediate = (i + 1..j).any(|k| {
                    let sk = &intent_sets[k];
                    si.iter().all(|a| sk.contains(a))
                        && sk.iter().all(|a| sj.contains(a))
                        && sk != si
                        && sk != sj
                });

                if has_intermediate {
                    continue;
                }

                // Emit A → (B \ A), added_attributes sorted.
                let mut added_attributes: Vec<FormalAttribute> = sorted[j]
                    .intent
                    .iter()
                    .filter(|a| !si.contains(a))
                    .cloned()
                    .collect();
                added_attributes.sort();

                cover_deltas.push(CoverDelta {
                    lower_intent: sorted[i].intent.clone(),
                    added_attributes,
                });
            }
        }

        // Sort: lower_intent size asc, then lex on lower_intent, then
        // lex on added_attributes — mirrors the Swift output order.
        cover_deltas.sort_by(|l, r| {
            l.lower_intent.len().cmp(&r.lower_intent.len())
                .then_with(|| l.lower_intent.cmp(&r.lower_intent))
                .then_with(|| l.added_attributes.cmp(&r.added_attributes))
        });

        ConceptCoverDeltas { cover_deltas }
    }
}

/// Context-local 0-based row index. Module-scoped (unlike Swift,
/// where the alias nests inside `FormalContext` to avoid colliding
/// with `LocusKit.RowID` on the module surface — Rust module scoping
/// already isolates it).
pub type RowId = u32;

/// One typed attribute in the formal context: a `(namespace, key,
/// value)` triple. The derived `Ord` is lexicographic over the three
/// fields in declaration order — identical to the Swift
/// `Comparable` — which fixes the deterministic attribute ordering
/// every other guarantee in this file builds on.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct FormalAttribute {
    pub namespace: String,
    pub key: String,
    pub value: String,
}

impl FormalAttribute {
    pub fn new(namespace: &str, key: &str, value: &str) -> Self {
        FormalAttribute {
            namespace: namespace.to_string(),
            key: key.to_string(),
            value: value.to_string(),
        }
    }
}

/// One formal concept: a maximal `(extent, intent)` pair where every
/// row in `extent` carries every attribute in `intent`. Both sides
/// are materialized as sorted vectors at the boundary so output
/// order is deterministic and language-agnostic.
#[derive(Debug, Clone, PartialEq)]
pub struct FormalConcept {
    /// Rows carrying every attribute in `intent`, ascending.
    pub extent: Vec<RowId>,
    /// Attributes common to every row in `extent`, ascending.
    pub intent: Vec<FormalAttribute>,
    /// `extent.len()`, the standard FCA support measure.
    pub support: usize,
    /// Sampled Kuznetsov stability estimate. `None` when the miner
    /// runs with `stability_budget == 0` (the default, preserving
    /// v1 behaviour). Populated by `StabilityEstimator::estimate`
    /// when `stability_budget > 0`. Never exact subset enumeration.
    pub stability: Option<f64>,
}

/// A materialized formal context: `row_count` rows × a deduplicated,
/// sorted attribute universe, stored as bitsets in both directions
/// (rows-per-attribute and attributes-per-row) so the two derivation
/// operators are plain word-wise intersections. Rows are addressed
/// by a context-local 0-based index; the deferred estate wrapper
/// maps estate row identifiers to these indices.
pub struct FormalContext {
    /// The deduplicated attribute universe, ascending. Index in this
    /// vector is the attribute's bit position in row bitsets.
    attributes: Vec<FormalAttribute>,
    /// Number of rows the context was materialized over.
    row_count: usize,
    /// `attributes[i]` → bitset over rows carrying that attribute.
    attribute_rows: Vec<FcaBitSet>,
    /// row → bitset over attribute indices that row carries.
    row_attributes: Vec<FcaBitSet>,
    /// attribute → its index in `attributes` (closure-operator lookup).
    attribute_index: HashMap<FormalAttribute, usize>,
}

impl FormalContext {
    /// Materializes a context from per-row attribute sets. Row `i`
    /// of `rows` becomes `RowId` `i`. Duplicate attributes within a
    /// row are collapsed; the attribute universe is the sorted union
    /// across all rows.
    pub fn new(rows: &[Vec<FormalAttribute>]) -> Self {
        let row_count = rows.len();
        let mut universe: Vec<FormalAttribute> = rows
            .iter()
            .flatten()
            .cloned()
            .collect::<HashSet<_>>()
            .into_iter()
            .collect();
        universe.sort();

        let mut attribute_index: HashMap<FormalAttribute, usize> =
            HashMap::with_capacity(universe.len());
        for (i, attribute) in universe.iter().enumerate() {
            attribute_index.insert(attribute.clone(), i);
        }

        let mut attribute_rows = vec![FcaBitSet::new(row_count, false); universe.len()];
        let mut row_attributes = vec![FcaBitSet::new(universe.len(), false); row_count];
        for (row, row_attrs) in rows.iter().enumerate() {
            for attribute in row_attrs {
                // Indexing is safe: `universe` is the union of all
                // row attributes, so every attribute has an index.
                let a = attribute_index[attribute];
                attribute_rows[a].set(row);
                row_attributes[row].set(a);
            }
        }

        FormalContext {
            attributes: universe,
            row_count,
            attribute_rows,
            row_attributes,
            attribute_index,
        }
    }

    /// Builds a `FormalContext` from row-attribute-view data.
    /// Each element of `views` is the attribute list for one row,
    /// expressed as `(field, value)` pairs. Each pair maps to
    /// `FormalAttribute { namespace: "row", key: field.to_string(),
    /// value: value.to_string() }` — the same convention as the
    /// Swift `FormalContext.from(rowAttributeViews:)` factory.
    pub fn from_row_attribute_views(views: &[Vec<(u8, u8)>]) -> Self {
        let rows: Vec<Vec<FormalAttribute>> = views
            .iter()
            .map(|attrs| {
                attrs
                    .iter()
                    .map(|(field, value)| {
                        FormalAttribute::new("row", &field.to_string(), &value.to_string())
                    })
                    .collect()
            })
            .collect();
        FormalContext::new(&rows)
    }

    /// The deduplicated, sorted attribute universe.
    pub fn attributes(&self) -> &[FormalAttribute] {
        &self.attributes
    }

    /// Number of rows the context was materialized over.
    pub fn row_count(&self) -> usize {
        self.row_count
    }

    // -- Derivation operators --------------------------------------

    /// The extent of an intent: every row carrying *all* of the given
    /// attributes, ascending. Standard FCA semantics: the empty
    /// intent's extent is all rows; an attribute absent from the
    /// context constrains the extent to empty.
    pub fn extent(&self, intent: &[FormalAttribute]) -> Vec<RowId> {
        self.extent_bits(intent)
            .set_bits()
            .into_iter()
            .map(|b| b as RowId)
            .collect()
    }

    /// The intent of an extent: every attribute carried by *all* of
    /// the given rows, ascending. Standard FCA semantics: the empty
    /// extent's intent is all attributes. Row indices `>= row_count`
    /// never occur in engine output and are ignored here (they
    /// reference no row, so they cannot constrain the intersection).
    pub fn intent(&self, extent: &[RowId]) -> Vec<FormalAttribute> {
        let mut bits = FcaBitSet::new(self.attributes.len(), true);
        for &row in extent {
            if (row as usize) < self.row_count {
                bits.intersect(&self.row_attributes[row as usize]);
            }
        }
        bits.set_bits()
            .into_iter()
            .map(|a| self.attributes[a].clone())
            .collect()
    }

    /// The closure of an intent: `intent(extent(intent))` — the
    /// largest attribute set shared by exactly the rows the input
    /// selects. Idempotent: `closure(closure(x)) == closure(x)`.
    pub fn closure(&self, intent: &[FormalAttribute]) -> Vec<FormalAttribute> {
        let rows = self.extent_bits(intent);
        self.intent_attributes_of_row_bits(&rows)
    }

    // -- Internal bitset forms (shared by the miner) ----------------

    /// `extent` in bitset form, before the sorted-vector boundary.
    fn extent_bits(&self, intent: &[FormalAttribute]) -> FcaBitSet {
        let mut bits = FcaBitSet::new(self.row_count, true);
        for attribute in intent {
            match self.attribute_index.get(attribute) {
                Some(&a) => bits.intersect(&self.attribute_rows[a]),
                // Unknown attribute: no row carries it.
                None => return FcaBitSet::new(self.row_count, false),
            }
        }
        bits
    }

    /// Rows carrying the attribute at universe index `a` (the
    /// miner's single-attribute support source).
    fn rows_bits_of_attribute(&self, a: usize) -> &FcaBitSet {
        &self.attribute_rows[a]
    }

    /// The intent (as sorted attributes) of a row bitset — the
    /// miner's closure step without re-deriving the extent.
    fn intent_attributes_of_row_bits(&self, rows: &FcaBitSet) -> Vec<FormalAttribute> {
        let mut bits = FcaBitSet::new(self.attributes.len(), true);
        for row in rows.set_bits() {
            bits.intersect(&self.row_attributes[row]);
        }
        bits.set_bits()
            .into_iter()
            .map(|a| self.attributes[a].clone())
            .collect()
    }
}

/// Bounded concept mining over a materialized `FormalContext`.
///
/// "Bounded" is the contract, not a tuning detail: the miner seeds
/// only from frequent single attributes (support ≥ `min_support`),
/// takes ONE closure per seed, deduplicates by intent, and truncates
/// to `max_concepts` — it never enumerates the full concept lattice.
/// Cost is O(|attributes| × closure), closure being plain bitset
/// intersections — polynomial, no exponential path.
///
/// With `seed_mode: SeedMode::Multi`, a second pass seeds from
/// frequent 2-attribute pairs (both attributes at or above
/// `min_support` individually). This discovers concepts whose minimal
/// generator is a pair rather than a singleton. Cost for the extra
/// pass is O(|frequent|² × closure), bounded by `max_seeds` pairs.
///
/// Set `stability_budget > 0` to compute sampled Kuznetsov stability
/// on every emitted concept via `StabilityEstimator`. The default
/// `stability_budget = 0` preserves v1 nil-stability behaviour.
///
/// Deterministic by construction: seeds are visited in the context's
/// sorted attribute order, and the result ordering is fully
/// specified (support desc, then intent size asc, then lexicographic
/// intent), so equal inputs yield identical output across runs and
/// across the Swift and Rust versions.
pub struct BoundedConceptMiner {
    /// Minimum extent size for a seed attribute and for an emitted
    /// concept. `0` is clamped to 1 (an empty-extent concept is
    /// never emitted) — mirrors the Swift clamp of non-positive
    /// values.
    pub min_support: usize,
    /// Maximum intent size of an emitted concept; closures larger
    /// than this are skipped.
    pub max_intent_size: usize,
    /// Maximum number of concepts returned (post-sort truncation).
    pub max_concepts: usize,
    /// Whether to seed from frequent 2-attribute pairs in addition
    /// to single attributes. Default is `Single` (v1 behaviour).
    pub seed_mode: SeedMode,
    /// Maximum number of 2-attribute pairs to try in the multi-seed
    /// pass. Caps computational cost; `usize::MAX` is unlimited.
    /// Ignored when `seed_mode == Single`.
    pub max_seeds: usize,
    /// Number of Bernoulli trials per concept for the sampled
    /// Kuznetsov stability estimator. `0` (default) skips estimation
    /// and leaves `stability` as `None` on every emitted concept.
    pub stability_budget: usize,
    /// Seed for the stability PRNG. XOR'd with FNV-1a-64 of each
    /// concept's canonical key to produce an independent per-concept
    /// stream. Default is the canonical conformance seed
    /// `0xCAFEBABEDEADBEEF`. Ignored when `stability_budget == 0`.
    pub stability_seed: u64,
}

impl BoundedConceptMiner {
    /// Creates a miner with `seed_mode: Single`, no pair-seed cap,
    /// and `stability_budget: 0` — identical to the v1 behaviour
    /// (stability is always `None` on emitted concepts).
    pub fn new(min_support: usize, max_intent_size: usize, max_concepts: usize) -> Self {
        BoundedConceptMiner {
            min_support,
            max_intent_size,
            max_concepts,
            seed_mode: SeedMode::Single,
            max_seeds: usize::MAX,
            stability_budget: 0,
            stability_seed: 0xCAFE_BABE_DEAD_BEEF,
        }
    }

    /// Creates a miner with explicit seed mode and max-seeds cap.
    /// `stability_budget` defaults to `0` (no stability estimation).
    pub fn new_with_seed_mode(
        min_support: usize,
        max_intent_size: usize,
        max_concepts: usize,
        seed_mode: SeedMode,
        max_seeds: usize,
    ) -> Self {
        BoundedConceptMiner {
            min_support,
            max_intent_size,
            max_concepts,
            seed_mode,
            max_seeds,
            stability_budget: 0,
            stability_seed: 0xCAFE_BABE_DEAD_BEEF,
        }
    }

    /// Mines bounded concepts from `context`. Returns concepts
    /// sorted by support descending, then intent size ascending,
    /// then lexicographic intent (the stable key), truncated to
    /// `max_concepts`.
    pub fn mine(&self, context: &FormalContext) -> Vec<FormalConcept> {
        if self.max_concepts == 0 || self.max_intent_size == 0 || context.row_count() == 0 {
            return Vec::new();
        }
        let support = std::cmp::max(1, self.min_support);

        // Pass 1: seed from frequent single attributes.
        // Collect frequent attribute indices for the optional pair
        // pass — this avoids re-scanning all attributes in pass 2.
        let mut seen_intents: HashSet<Vec<FormalAttribute>> = HashSet::new();
        let mut concepts: Vec<FormalConcept> = Vec::new();
        let mut frequent_attr_indices: Vec<usize> = Vec::new();

        for a in 0..context.attributes().len() {
            let rows = context.rows_bits_of_attribute(a);
            if rows.popcount() < support {
                continue;
            }
            // Track frequent indices for the pair pass regardless of
            // whether this seed's closure survives the intent-size cap.
            frequent_attr_indices.push(a);

            // closure([seed]) — extent is exactly the seed's rows
            // (single-attribute intent), so the closure is one
            // intent-derivation over that row bitset.
            let intent = context.intent_attributes_of_row_bits(rows);
            if intent.len() > self.max_intent_size {
                continue;
            }
            if !seen_intents.insert(intent.clone()) {
                continue;
            }

            concepts.push(FormalConcept {
                extent: rows.set_bits().into_iter().map(|b| b as RowId).collect(),
                support: rows.popcount(),
                intent,
                stability: None,
            });
        }

        // Pass 2 (multi-seed only): seed from frequent 2-attribute
        // pairs. Pairs are enumerated in sorted-attribute order so
        // the pass is deterministic. `max_seeds` caps the total
        // number of pairs tried (not the number of concepts produced).
        if self.seed_mode == SeedMode::Multi {
            let mut pairs_tried = 0usize;
            'outer: for i in 0..frequent_attr_indices.len() {
                for j in (i + 1)..frequent_attr_indices.len() {
                    if pairs_tried >= self.max_seeds {
                        break 'outer;
                    }
                    pairs_tried += 1;

                    let ai = frequent_attr_indices[i];
                    let aj = frequent_attr_indices[j];

                    // Extent of the pair seed = rows carrying BOTH
                    // attributes — a bitset intersection.
                    let mut pair_rows = context.rows_bits_of_attribute(ai).clone();
                    pair_rows.intersect(context.rows_bits_of_attribute(aj));

                    if pair_rows.popcount() < support {
                        continue;
                    }

                    let intent = context.intent_attributes_of_row_bits(&pair_rows);
                    if intent.len() > self.max_intent_size {
                        continue;
                    }
                    if !seen_intents.insert(intent.clone()) {
                        continue;
                    }

                    concepts.push(FormalConcept {
                        extent: pair_rows
                            .set_bits()
                            .into_iter()
                            .map(|b| b as RowId)
                            .collect(),
                        support: pair_rows.popcount(),
                        intent,
                        stability: None,
                    });
                }
            }
        }

        // Fully-specified ordering: support desc, intent size asc,
        // then lexicographic intent as the stable key.
        concepts.sort_by(|l, r| {
            r.support
                .cmp(&l.support)
                .then(l.intent.len().cmp(&r.intent.len()))
                .then_with(|| l.intent.cmp(&r.intent))
        });
        concepts.truncate(self.max_concepts);

        // Populate sampled Kuznetsov stability when requested.
        if self.stability_budget > 0 {
            for c in &mut concepts {
                c.stability = Some(StabilityEstimator::estimate(
                    c,
                    context,
                    self.stability_budget,
                    self.stability_seed,
                ));
            }
        }

        concepts
    }
}

// -- StabilityEstimator -------------------------------------------

/// Sampled Kuznetsov stability estimator for a `FormalConcept`.
///
/// Stability measures how "robust" a concept is: what fraction of
/// Bernoulli(p=0.5) subsets of its extent share the same intent.
/// Exact computation is exponential (enumerate all 2^|extent| subsets);
/// this estimator draws `budget` independent Bernoulli samples and
/// returns the hit fraction. Result is in `[0.0, 1.0]`.
///
/// Per-concept RNG isolation: the per-concept seed is
/// `global_seed XOR fnv64(canonical_key(concept))` so each concept
/// gets its own independent PRNG stream regardless of call order.
/// Canonical key format: `"rowID0,rowID1,...|ns:key:val|ns:key:val|..."`
/// (extent indices comma-joined, intent attributes pipe-joined,
/// each attribute as `namespace:key:value`).
pub struct StabilityEstimator;

impl StabilityEstimator {
    /// Estimates sampled Kuznetsov stability for `concept` in `context`.
    ///
    /// Returns `0.0` immediately when `budget == 0` or the extent is
    /// empty. Otherwise runs `budget` Bernoulli trials using SplitMix64
    /// seeded with `seed XOR fnv64(canonical_key(concept))`.
    pub fn estimate(
        concept: &FormalConcept,
        context: &FormalContext,
        budget: usize,
        seed: u64,
    ) -> f64 {
        if budget == 0 || concept.extent.is_empty() {
            return 0.0;
        }
        let per_concept_seed = seed ^ fnv::hash64(&Self::canonical_key(concept));
        let mut rng = SplitMix64::new(per_concept_seed);
        let mut hits: usize = 0;
        for _ in 0..budget {
            let subset: Vec<RowId> = concept
                .extent
                .iter()
                .filter(|_| rng.next() & 1 == 1)
                .copied()
                .collect();
            if context.intent(&subset) == concept.intent {
                hits += 1;
            }
        }
        hits as f64 / budget as f64
    }

    /// Canonical key for per-concept seed derivation.
    /// Format: `"row0,row1,...|ns:key:val|ns:key:val|..."`.
    /// Extent indices are comma-joined; intent attributes (already
    /// sorted ascending) are pipe-joined as `namespace:key:value`.
    fn canonical_key(concept: &FormalConcept) -> String {
        let extent_part: Vec<String> =
            concept.extent.iter().map(|r| r.to_string()).collect();
        let intent_part: Vec<String> = concept
            .intent
            .iter()
            .map(|a| format!("{}:{}:{}", a.namespace, a.key, a.value))
            .collect();
        format!("{}|{}", extent_part.join(","), intent_part.join("|"))
    }
}

// -- Bitset ---------------------------------------------------------

/// Minimal fixed-width bitset over `u64` words. Private so the
/// context and the miner share one implementation; mirrors the Swift
/// `FCABitSet` word-for-word.
#[derive(Debug, Clone, PartialEq, Eq)]
struct FcaBitSet {
    words: Vec<u64>,
    bit_count: usize,
}

impl FcaBitSet {
    /// All-zero (`all_set: false`) or all-one over exactly
    /// `bit_count` bits. The trailing partial word is masked on the
    /// all-set path so iteration and popcount never see phantom bits.
    fn new(bit_count: usize, all_set: bool) -> Self {
        let word_count = bit_count.div_ceil(64);
        let words = if all_set {
            let mut words = vec![u64::MAX; word_count];
            let trailing = bit_count % 64;
            if trailing != 0 && word_count > 0 {
                words[word_count - 1] = (1u64 << trailing) - 1;
            }
            words
        } else {
            vec![0u64; word_count]
        };
        FcaBitSet { words, bit_count }
    }

    fn set(&mut self, bit: usize) {
        self.words[bit / 64] |= 1u64 << (bit % 64);
    }

    fn intersect(&mut self, other: &FcaBitSet) {
        for i in 0..self.words.len() {
            self.words[i] &= other.words[i];
        }
    }

    /// Number of set bits.
    fn popcount(&self) -> usize {
        self.words.iter().map(|w| w.count_ones() as usize).sum()
    }

    /// Set bit positions, ascending — the deterministic iteration
    /// order every sorted-vector boundary derives from.
    fn set_bits(&self) -> Vec<usize> {
        let mut bits = Vec::with_capacity(self.popcount());
        for (w, &word) in self.words.iter().enumerate() {
            let mut word = word;
            while word != 0 {
                let bit = word.trailing_zeros() as usize;
                bits.push(w * 64 + bit);
                word &= word - 1;
            }
        }
        bits
    }
}

#[cfg(test)]
mod tests {
    //! Conformance fixtures — mirror the Swift
    //! `FormalConceptAnalysisTests` hand-computed vectors EXACTLY.
    //! Five attributes in one namespace; sorted universe order (by
    //! (namespace, key, value)) is [C, A, E, B, D]:
    //!
    //! ```text
    //!   C=(adj,color,blue) < A=(adj,color,red) < E=(adj,shape,round)
    //!     < B=(adj,size,large) < D=(adj,size,small)
    //!
    //! Cohort fixture — 6 rows, two clean cohorts plus a singleton:
    //!   rows 0,1,2: {A,B}   rows 3,4: {C,D}   row 5: {E}
    //! Hand-computed closures (min_support=2 seeds A,B,C,D; E support 1):
    //!   closure([A]) = closure([B]) = [A,B]  extent [0,1,2] support 3
    //!   closure([C]) = closure([D]) = [C,D]  extent [3,4]   support 2
    //! → two concepts after intent-dedup, ordered support desc.
    //! ```
    use super::*;

    fn attr_a() -> FormalAttribute {
        FormalAttribute::new("adj", "color", "red")
    }
    fn attr_b() -> FormalAttribute {
        FormalAttribute::new("adj", "size", "large")
    }
    fn attr_c() -> FormalAttribute {
        FormalAttribute::new("adj", "color", "blue")
    }
    fn attr_d() -> FormalAttribute {
        FormalAttribute::new("adj", "size", "small")
    }
    fn attr_e() -> FormalAttribute {
        FormalAttribute::new("adj", "shape", "round")
    }

    fn cohort_context() -> FormalContext {
        FormalContext::new(&[
            vec![attr_a(), attr_b()], // 0
            vec![attr_a(), attr_b()], // 1
            vec![attr_a(), attr_b()], // 2
            vec![attr_c(), attr_d()], // 3
            vec![attr_c(), attr_d()], // 4
            vec![attr_e()],           // 5
        ])
    }

    /// Nested fixture — closures of different intent sizes:
    ///   rows 0,1,2: {A,B}   rows 3,4: {A}
    ///   closure([A]) = [A]    extent [0,1,2,3,4] support 5
    ///   closure([B]) = [A,B]  extent [0,1,2]     support 3
    fn nested_context() -> FormalContext {
        FormalContext::new(&[
            vec![attr_a(), attr_b()],
            vec![attr_a(), attr_b()],
            vec![attr_a(), attr_b()],
            vec![attr_a()],
            vec![attr_a()],
        ])
    }

    // -- 1. Derivation operators ------------------------------------

    #[test]
    fn extent_operator_boundaries() {
        let ctx = cohort_context();
        assert_eq!(ctx.extent(&[]), vec![0, 1, 2, 3, 4, 5]);
        let unknown = FormalAttribute::new("adj", "color", "green");
        assert!(ctx.extent(&[unknown]).is_empty());
        assert_eq!(ctx.extent(&[attr_a()]), vec![0, 1, 2]);
        assert_eq!(ctx.extent(&[attr_a(), attr_b()]), vec![0, 1, 2]);
        assert!(ctx.extent(&[attr_a(), attr_c()]).is_empty());
    }

    #[test]
    fn intent_operator_boundaries() {
        let ctx = cohort_context();
        // Sorted universe: [C, A, E, B, D] per the fixture comment.
        assert_eq!(
            ctx.intent(&[]),
            vec![attr_c(), attr_a(), attr_e(), attr_b(), attr_d()]
        );
        assert_eq!(ctx.intent(&[0, 1, 2]), vec![attr_a(), attr_b()]);
        assert_eq!(ctx.intent(&[3, 4]), vec![attr_c(), attr_d()]);
        assert!(ctx.intent(&[0, 3]).is_empty());
    }

    #[test]
    fn closure_derives_shared_intent() {
        let ctx = cohort_context();
        assert_eq!(ctx.closure(&[attr_a()]), vec![attr_a(), attr_b()]);
        assert_eq!(ctx.closure(&[attr_c()]), vec![attr_c(), attr_d()]);
        assert_eq!(ctx.closure(&[attr_e()]), vec![attr_e()]);
    }

    #[test]
    fn closure_is_idempotent() {
        let ctx = cohort_context();
        let seeds: Vec<Vec<FormalAttribute>> = vec![
            vec![attr_a()],
            vec![attr_b()],
            vec![attr_c()],
            vec![attr_e()],
            vec![],
            vec![attr_a(), attr_c()],
        ];
        for seed in seeds {
            let once = ctx.closure(&seed);
            assert_eq!(ctx.closure(&once), once);
        }
    }

    // -- 2. Miner: cohorts, dedup, ordering --------------------------

    #[test]
    fn two_cohorts_yield_two_concepts() {
        let miner = BoundedConceptMiner::new(2, 8, 8);
        let out = miner.mine(&cohort_context());
        // Four seeds (A,B,C,D) collapse to two intents; E gated by
        // min_support. Support 3 cohort precedes support 2 cohort.
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].extent, vec![0, 1, 2]);
        assert_eq!(out[0].intent, vec![attr_a(), attr_b()]);
        assert_eq!(out[0].support, 3);
        assert_eq!(out[1].extent, vec![3, 4]);
        assert_eq!(out[1].intent, vec![attr_c(), attr_d()]);
        assert_eq!(out[1].support, 2);
    }

    #[test]
    fn equal_support_tie_breaks_on_intent_key() {
        // Two cohorts of 2: both concepts support 2, intent size 2.
        // [C,D] starts at (adj,color,blue) < (adj,color,red), so the
        // [C,D] concept precedes [A,B].
        let ctx = FormalContext::new(&[
            vec![attr_a(), attr_b()],
            vec![attr_a(), attr_b()],
            vec![attr_c(), attr_d()],
            vec![attr_c(), attr_d()],
        ]);
        let out = BoundedConceptMiner::new(2, 8, 8).mine(&ctx);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].intent, vec![attr_c(), attr_d()]);
        assert_eq!(out[1].intent, vec![attr_a(), attr_b()]);
    }

    #[test]
    fn smaller_intent_precedes_larger_at_equal_support() {
        // rows 0,1: {A}; rows 2,3: {C,D} — both concepts support 2;
        // intent sizes 1 vs 2 → [A] first despite blue < red.
        let ctx = FormalContext::new(&[
            vec![attr_a()],
            vec![attr_a()],
            vec![attr_c(), attr_d()],
            vec![attr_c(), attr_d()],
        ]);
        let out = BoundedConceptMiner::new(2, 8, 8).mine(&ctx);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].intent, vec![attr_a()]);
        assert_eq!(out[1].intent, vec![attr_c(), attr_d()]);
    }

    // -- 3. Caps ------------------------------------------------------

    #[test]
    fn max_intent_size_cap_excludes() {
        // Nested fixture: closure([A]) has intent size 1, closure([B])
        // size 2. Cap at 1 keeps only the [A] concept.
        let out = BoundedConceptMiner::new(2, 1, 8).mine(&nested_context());
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].extent, vec![0, 1, 2, 3, 4]);
        assert_eq!(out[0].intent, vec![attr_a()]);
        assert_eq!(out[0].support, 5);

        // Cap at 2 admits both, support-desc ordered.
        let both = BoundedConceptMiner::new(2, 2, 8).mine(&nested_context());
        assert_eq!(both.len(), 2);
        assert_eq!(both[0].intent, vec![attr_a()]);
        assert_eq!(both[1].intent, vec![attr_a(), attr_b()]);
        assert_eq!(both[1].support, 3);
    }

    #[test]
    fn max_concepts_truncates() {
        let out = BoundedConceptMiner::new(2, 8, 1).mine(&cohort_context());
        // Truncation keeps the sort's head: the support-3 cohort.
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].intent, vec![attr_a(), attr_b()]);
        assert_eq!(out[0].support, 3);
    }

    #[test]
    fn min_support_gates() {
        let ctx = cohort_context();
        // min_support=3: only the A/B cohort survives.
        let three = BoundedConceptMiner::new(3, 8, 8).mine(&ctx);
        assert_eq!(three.len(), 1);
        assert_eq!(three[0].intent, vec![attr_a(), attr_b()]);
        // min_support=4: nothing survives.
        assert!(BoundedConceptMiner::new(4, 8, 8).mine(&ctx).is_empty());
        // min_support=0 clamps to 1: the singleton E concept appears.
        let zero = BoundedConceptMiner::new(0, 8, 8).mine(&ctx);
        assert_eq!(zero.len(), 3);
        assert_eq!(zero[2].extent, vec![5]);
        assert_eq!(zero[2].intent, vec![attr_e()]);
        assert_eq!(zero[2].support, 1);
    }

    // -- 4. Edges -----------------------------------------------------

    #[test]
    fn empty_context_mines_empty() {
        let ctx = FormalContext::new(&[]);
        assert!(BoundedConceptMiner::new(1, 8, 8).mine(&ctx).is_empty());
        assert!(ctx.extent(&[]).is_empty());
    }

    #[test]
    fn non_positive_caps_mine_empty() {
        let ctx = cohort_context();
        assert!(BoundedConceptMiner::new(2, 8, 0).mine(&ctx).is_empty());
        assert!(BoundedConceptMiner::new(2, 0, 8).mine(&ctx).is_empty());
    }

    // -- 5. Determinism and v1 stability omission ---------------------

    #[test]
    fn two_runs_are_identical() {
        let miner = BoundedConceptMiner::new(1, 8, 8);
        let first = miner.mine(&cohort_context());
        let second = miner.mine(&cohort_context());
        assert_eq!(first, second);
    }

    #[test]
    fn stability_is_none_in_v1() {
        let out = BoundedConceptMiner::new(1, 8, 8).mine(&cohort_context());
        assert!(!out.is_empty());
        assert!(out.iter().all(|c| c.stability.is_none()));
    }

    // -- 6. Multi-seed -----------------------------------------------

    /// Bridge context — same as the Swift multi-seed fixture:
    ///   row 0: {A, B}
    ///   row 1: {A, B}
    ///   row 2: {A, C}
    ///   row 3: {B, C}
    /// Single-seed finds {A},{B},{C}; multi-seed additionally finds {A,B}.
    fn bridge_context() -> FormalContext {
        FormalContext::new(&[
            vec![attr_a(), attr_b()],
            vec![attr_a(), attr_b()],
            vec![attr_a(), attr_c()],
            vec![attr_b(), attr_c()],
        ])
    }

    #[test]
    fn single_seed_default_matches_explicit_single() {
        let default_miner = BoundedConceptMiner::new(2, 8, 8);
        let explicit_single = BoundedConceptMiner::new_with_seed_mode(2, 8, 8, SeedMode::Single, usize::MAX);
        assert_eq!(
            default_miner.mine(&bridge_context()),
            explicit_single.mine(&bridge_context())
        );
    }

    #[test]
    fn single_seed_finds_three_concepts_on_bridge() {
        let out = BoundedConceptMiner::new(2, 8, 8).mine(&bridge_context());
        assert_eq!(out.len(), 3);
        // {A} and {B} both support 3, {C} supports 2.
        let intents: Vec<&Vec<FormalAttribute>> = out.iter().map(|c| &c.intent).collect();
        assert!(intents.contains(&&vec![attr_a()]));
        assert!(intents.contains(&&vec![attr_b()]));
        assert!(intents.contains(&&vec![attr_c()]));
    }

    #[test]
    fn multi_seed_finds_more_concepts_on_bridge() {
        let single = BoundedConceptMiner::new(2, 8, 8).mine(&bridge_context());
        let multi  = BoundedConceptMiner::new_with_seed_mode(2, 8, 8, SeedMode::Multi, usize::MAX)
            .mine(&bridge_context());
        assert!(multi.len() > single.len(), "multi-seed must find more concepts than single-seed");
    }

    #[test]
    fn multi_seed_discovers_ab_concept() {
        let miner = BoundedConceptMiner::new_with_seed_mode(2, 8, 8, SeedMode::Multi, usize::MAX);
        let out = miner.mine(&bridge_context());
        let intents: Vec<Vec<FormalAttribute>> = out.iter().map(|c| c.intent.clone()).collect();
        let ab = vec![attr_a(), attr_b()];
        assert!(intents.contains(&ab), "multi-seed must include {{A,B}} concept");
    }

    #[test]
    fn max_seeds_zero_equals_single_mode() {
        let capped = BoundedConceptMiner::new_with_seed_mode(2, 8, 8, SeedMode::Multi, 0)
            .mine(&bridge_context());
        let single = BoundedConceptMiner::new(2, 8, 8).mine(&bridge_context());
        assert_eq!(capped, single, "max_seeds=0 must produce identical results to single-seed");
    }

    #[test]
    fn max_intent_size_cap_applies_in_multi_mode() {
        let capped = BoundedConceptMiner::new_with_seed_mode(2, 1, 8, SeedMode::Multi, usize::MAX)
            .mine(&bridge_context());
        assert!(capped.iter().all(|c| c.intent.len() <= 1));
    }

    #[test]
    fn max_concepts_cap_applies_in_multi_mode() {
        let capped = BoundedConceptMiner::new_with_seed_mode(2, 8, 2, SeedMode::Multi, usize::MAX)
            .mine(&bridge_context());
        assert!(capped.len() <= 2);
    }

    #[test]
    fn multi_seed_is_deterministic() {
        let miner = BoundedConceptMiner::new_with_seed_mode(2, 8, 8, SeedMode::Multi, usize::MAX);
        let first  = miner.mine(&bridge_context());
        let second = miner.mine(&bridge_context());
        assert_eq!(first, second);
    }

    // -- 7. ConceptCoverDeltas ----------------------------------------

    fn t(value: &str) -> FormalAttribute {
        FormalAttribute::new("t", "k", value)
    }

    fn chain_concepts() -> Vec<FormalConcept> {
        vec![
            FormalConcept { extent: vec![0,1,2,3,4], intent: vec![t("a")],               support: 5, stability: None },
            FormalConcept { extent: vec![0,1,2],     intent: vec![t("a"), t("b")],        support: 3, stability: None },
            FormalConcept { extent: vec![0,1],       intent: vec![t("a"), t("b"), t("c")], support: 2, stability: None },
        ]
    }

    #[test]
    fn concept_cover_deltas_empty_input() {
        assert!(ConceptCoverDeltas::covering(&[]).cover_deltas.is_empty());
    }

    #[test]
    fn concept_cover_deltas_single_concept() {
        let single = vec![FormalConcept { extent: vec![0, 1], intent: vec![t("a")], support: 2, stability: None }];
        assert!(ConceptCoverDeltas::covering(&single).cover_deltas.is_empty());
    }

    #[test]
    fn concept_cover_deltas_disjoint_concepts() {
        let disjoint = vec![
            FormalConcept { extent: vec![0,1], intent: vec![t("a")], support: 2, stability: None },
            FormalConcept { extent: vec![2,3], intent: vec![t("b")], support: 2, stability: None },
        ];
        assert!(ConceptCoverDeltas::covering(&disjoint).cover_deltas.is_empty());
    }

    #[test]
    fn chain_yields_two_cover_deltas() {
        let deltas = ConceptCoverDeltas::covering(&chain_concepts());
        assert_eq!(deltas.cover_deltas.len(), 2);
        // Cover A→B: lower_intent {a}, added_attributes {b}
        assert_eq!(deltas.cover_deltas[0].lower_intent, vec![t("a")]);
        assert_eq!(deltas.cover_deltas[0].added_attributes, vec![t("b")]);
        // Cover B→C: lower_intent {a,b}, added_attributes {c}
        assert_eq!(deltas.cover_deltas[1].lower_intent, vec![t("a"), t("b")]);
        assert_eq!(deltas.cover_deltas[1].added_attributes, vec![t("c")]);
    }

    #[test]
    fn direct_cover_yields_one_delta() {
        let direct = vec![
            FormalConcept { extent: vec![0,1,2], intent: vec![t("a")],               support: 3, stability: None },
            FormalConcept { extent: vec![0,1],   intent: vec![t("a"), t("b"), t("c")], support: 2, stability: None },
        ];
        let deltas = ConceptCoverDeltas::covering(&direct);
        assert_eq!(deltas.cover_deltas.len(), 1);
        assert_eq!(deltas.cover_deltas[0].lower_intent, vec![t("a")]);
        let mut expected_added = vec![t("b"), t("c")];
        expected_added.sort();
        assert_eq!(deltas.cover_deltas[0].added_attributes, expected_added);
    }

    #[test]
    fn lower_intent_and_union_are_concept_intents() {
        let concepts = chain_concepts();
        let deltas = ConceptCoverDeltas::covering(&concepts);
        let all_intents: Vec<Vec<FormalAttribute>> = concepts.iter().map(|c| c.intent.clone()).collect();
        for delta in &deltas.cover_deltas {
            assert!(all_intents.contains(&delta.lower_intent), "lower_intent must be a concept's intent");
            let mut full: Vec<FormalAttribute> = delta.lower_intent.iter().chain(delta.added_attributes.iter()).cloned().collect();
            full.sort();
            full.dedup();
            assert!(all_intents.contains(&full), "lower_intent ∪ added_attributes must be a concept's intent");
        }
    }

    #[test]
    fn concept_cover_deltas_is_deterministic() {
        let first  = ConceptCoverDeltas::covering(&chain_concepts());
        let second = ConceptCoverDeltas::covering(&chain_concepts());
        assert_eq!(first, second);
    }

    #[test]
    fn concept_cover_deltas_input_order_independent() {
        let canonical = ConceptCoverDeltas::covering(&chain_concepts());
        let mut reversed_input = chain_concepts();
        reversed_input.reverse();
        let reversed = ConceptCoverDeltas::covering(&reversed_input);
        assert_eq!(canonical, reversed);
    }

    // -- 8. FormalContext::from_row_attribute_views ------------------

    #[test]
    fn from_rav_empty_produces_empty_context() {
        let ctx = FormalContext::from_row_attribute_views(&[]);
        assert_eq!(ctx.row_count(), 0);
        assert!(ctx.attributes().is_empty());
    }

    #[test]
    fn from_rav_attribute_namespace_convention() {
        // field=7, value=42 → FormalAttribute("row","7","42")
        let ctx = FormalContext::from_row_attribute_views(&[vec![(7u8, 42u8)]]);
        let expected = FormalAttribute::new("row", "7", "42");
        assert_eq!(ctx.attributes(), &[expected]);
    }

    #[test]
    fn from_rav_mining_integration() {
        // Two cohorts of 2 rows each:
        //   group A: (field 0 value 1, field 1 value 2) — rows 0,1
        //   group B: (field 0 value 3, field 1 value 4) — rows 2,3
        let views = vec![
            vec![(0u8, 1u8), (1u8, 2u8)],
            vec![(0u8, 1u8), (1u8, 2u8)],
            vec![(0u8, 3u8), (1u8, 4u8)],
            vec![(0u8, 3u8), (1u8, 4u8)],
        ];
        let ctx = FormalContext::from_row_attribute_views(&views);
        let miner = BoundedConceptMiner::new(2, 8, 8);
        let out = miner.mine(&ctx);
        assert_eq!(out.len(), 2, "two distinct cohorts → two concepts");
        let fa = |f: u8, v: u8| FormalAttribute::new("row", &f.to_string(), &v.to_string());
        let intent_a: Vec<FormalAttribute> = { let mut v = vec![fa(0,1), fa(1,2)]; v.sort(); v };
        let intent_b: Vec<FormalAttribute> = { let mut v = vec![fa(0,3), fa(1,4)]; v.sort(); v };
        let intents: Vec<Vec<FormalAttribute>> = out.iter().map(|c| c.intent.clone()).collect();
        assert!(intents.contains(&intent_a));
        assert!(intents.contains(&intent_b));
    }

    // -- 9. StabilityEstimator ------------------------------------------

    const CANONICAL_SEED: u64 = 0xCAFE_BABE_DEAD_BEEF;

    /// Dense 3-row context: all rows carry {k1, k2}.
    fn dense_context() -> FormalContext {
        let k1 = FormalAttribute::new("cv", "k1", "v1");
        let k2 = FormalAttribute::new("cv", "k2", "v2");
        FormalContext::new(&[
            vec![k1.clone(), k2.clone()],
            vec![k1.clone(), k2.clone()],
            vec![k1.clone(), k2.clone()],
        ])
    }

    /// Dense concept: extent=[0,1,2], intent=[k1,k2].
    fn dense_concept() -> FormalConcept {
        let k1 = FormalAttribute::new("cv", "k1", "v1");
        let k2 = FormalAttribute::new("cv", "k2", "v2");
        FormalConcept {
            extent: vec![0, 1, 2],
            intent: vec![k1, k2],
            support: 3,
            stability: None,
        }
    }

    /// Nested 2-row context: row 0 has {k1,k2}, row 1 has {k1} only.
    fn nested_context_stability() -> FormalContext {
        let k1 = FormalAttribute::new("cv", "k1", "v1");
        let k2 = FormalAttribute::new("cv", "k2", "v2");
        FormalContext::new(&[vec![k1.clone(), k2.clone()], vec![k1.clone()]])
    }

    #[test]
    fn stability_budget_zero_returns_zero() {
        let ctx = dense_context();
        let c = dense_concept();
        assert_eq!(
            StabilityEstimator::estimate(&c, &ctx, 0, CANONICAL_SEED),
            0.0,
            "budget=0 must return 0.0 without calling the RNG"
        );
    }

    #[test]
    fn dense_concept_stability_is_one() {
        // All Bernoulli subsets of a fully-dense extent (including the
        // empty subset, whose intent = all context attributes = concept.intent)
        // produce intent equal to concept.intent. Stability must be 1.0 exactly.
        let ctx = dense_context();
        let c = dense_concept();
        for budget in [1, 10, 100] {
            let s = StabilityEstimator::estimate(&c, &ctx, budget, CANONICAL_SEED);
            assert_eq!(s, 1.0, "dense concept stability must be exactly 1.0 at budget {budget}");
        }
    }

    #[test]
    fn stability_is_in_range() {
        let ctx = nested_context_stability();
        let k1 = FormalAttribute::new("cv", "k1", "v1");
        let c = FormalConcept { extent: vec![0, 1], intent: vec![k1], support: 2, stability: None };
        let s = StabilityEstimator::estimate(&c, &ctx, 200, CANONICAL_SEED);
        assert!(s >= 0.0 && s <= 1.0, "stability must be in [0.0, 1.0], got {s}");
    }

    #[test]
    fn stability_is_deterministic() {
        let ctx = nested_context_stability();
        let k1 = FormalAttribute::new("cv", "k1", "v1");
        let c = FormalConcept { extent: vec![0, 1], intent: vec![k1], support: 2, stability: None };
        let s1 = StabilityEstimator::estimate(&c, &ctx, 50, CANONICAL_SEED);
        let s2 = StabilityEstimator::estimate(&c, &ctx, 50, CANONICAL_SEED);
        assert_eq!(s1, s2, "same inputs must produce identical stability");
    }

    #[test]
    fn nested_concept_stability_near_half() {
        // Row 0: {k1,k2}, row 1: {k1}. Concept: extent=[0,1], intent=[k1].
        // Bernoulli draws: {} miss, {0} miss, {1} hit, {0,1} hit.
        // Theoretical expected = 2/4 = 0.5. Tolerance ±0.12 at budget=1000.
        let ctx = nested_context_stability();
        let k1 = FormalAttribute::new("cv", "k1", "v1");
        let c = FormalConcept { extent: vec![0, 1], intent: vec![k1], support: 2, stability: None };
        let s = StabilityEstimator::estimate(&c, &ctx, 1000, CANONICAL_SEED);
        assert!(
            (s - 0.5).abs() < 0.12,
            "nested concept stability must be near 0.5, got {s}"
        );
    }

    #[test]
    fn miner_budget_zero_leaves_stability_none() {
        // Default miner (stability_budget=0) must leave stability None.
        let out = BoundedConceptMiner::new(1, 8, 8).mine(&cohort_context());
        assert!(!out.is_empty());
        assert!(
            out.iter().all(|c| c.stability.is_none()),
            "default miner must leave stability None"
        );
    }

    #[test]
    fn miner_budget_positive_populates_stability() {
        // Miner with stability_budget > 0 must populate stability on all concepts.
        let mut miner = BoundedConceptMiner::new(1, 8, 8);
        miner.stability_budget = 50;
        miner.stability_seed = CANONICAL_SEED;
        let out = miner.mine(&cohort_context());
        assert!(!out.is_empty());
        for c in &out {
            assert!(c.stability.is_some(), "stability must be non-None for concept {:?}", c.intent);
            let s = c.stability.unwrap();
            assert!(s >= 0.0 && s <= 1.0, "stability out of [0,1]: {s}");
        }
    }

    #[test]
    fn miner_stability_is_deterministic() {
        let mut miner = BoundedConceptMiner::new(1, 8, 8);
        miner.stability_budget = 100;
        miner.stability_seed = CANONICAL_SEED;
        let first  = miner.mine(&cohort_context());
        let second = miner.mine(&cohort_context());
        assert_eq!(first.len(), second.len());
        for (a, b) in first.iter().zip(second.iter()) {
            assert_eq!(
                a.stability, b.stability,
                "stability mismatch: {:?} vs {:?}", a.stability, b.stability
            );
        }
    }

    // Conformance vector test: fcs-002-nested — verifies the Rust
    // stability estimator produces bit-identical output to the Swift
    // implementation for the canonical seed and budget=1000.
    // Expected value 0.519 was computed by running the production
    // Swift code; the Rust port must match exactly (same PRNG, same FNV).
    #[test]
    fn conformance_fcs002_nested_matches_swift() {
        let ctx = nested_context_stability();
        let k1 = FormalAttribute::new("cv", "k1", "v1");
        let c = FormalConcept { extent: vec![0, 1], intent: vec![k1], support: 2, stability: None };
        let s = StabilityEstimator::estimate(&c, &ctx, 1000, CANONICAL_SEED);
        assert_eq!(s, 0.519, "fcs-002-nested: Rust must match Swift value 0.519");
    }
}
