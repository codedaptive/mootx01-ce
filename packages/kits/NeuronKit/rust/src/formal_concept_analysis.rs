//! Bounded Formal Concept Analysis over a materialized `FormalContext`
//! — Rust version of the Swift `FormalConceptAnalysis.swift`, per
//! MISSION_NEURON_BOUNDED_FCA_001. Per CLAUDE.md neither leg leads;
//! both run identical math and are gated against the shared
//! hand-computed fixtures in the inline tests below (the same cases
//! the Swift `FormalConceptAnalysisTests` encode).
//!
//! The engine is pure data-in / data-out: it takes a fully
//! materialized context (rows × attributes) and reads no estate, no
//! `MatrixO`, no clocks, no randomness. Building a context from the
//! estate is deferred to a Brain-layer seam/wrapper — NOT this file.
//!
//! Bounding contract (the reason this is "bounded" FCA):
//!   - NO full concept-lattice enumeration anywhere. Concepts are
//!     seeded only from frequent single attributes; one closure per
//!     seed; deduplicated by intent.
//!   - NO exact Kuznetsov stability. Exact stability is exponential
//!     (subset enumeration over the extent); v1 omits the computation
//!     entirely. `FormalConcept::stability` is carried as an `Option`
//!     so a future *sampled* estimator (fixed, seeded budget) is a
//!     non-breaking addition; it is always `None` in v1.

use std::collections::{HashMap, HashSet};

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
    /// Sampled Kuznetsov stability estimate. **Always `None` in
    /// v1** — the exact computation is exponential and is
    /// deliberately omitted; the field reserves the shape for a
    /// future sampled estimator with a fixed, seeded budget (never
    /// exact subset enumeration).
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
/// to `max_concepts` — it never enumerates the full concept lattice,
/// and it computes no stability (see `FormalConcept::stability`).
/// Cost is O(|attributes| × closure), closure being plain bitset
/// intersections — polynomial, no exponential path.
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
}

impl BoundedConceptMiner {
    pub fn new(min_support: usize, max_intent_size: usize, max_concepts: usize) -> Self {
        BoundedConceptMiner {
            min_support,
            max_intent_size,
            max_concepts,
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

        // Seed pass: one closure per frequent single attribute,
        // deduplicated by intent. Sorted-attribute iteration order
        // makes the dedup set's insertion history deterministic.
        let mut seen_intents: HashSet<Vec<FormalAttribute>> = HashSet::new();
        let mut concepts: Vec<FormalConcept> = Vec::new();
        for a in 0..context.attributes().len() {
            let rows = context.rows_bits_of_attribute(a);
            if rows.popcount() < support {
                continue;
            }

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

        // Fully-specified ordering: support desc, intent size asc,
        // then lexicographic intent as the stable key.
        concepts.sort_by(|l, r| {
            r.support
                .cmp(&l.support)
                .then(l.intent.len().cmp(&r.intent.len()))
                .then_with(|| l.intent.cmp(&r.intent))
        });
        concepts.truncate(self.max_concepts);
        concepts
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
}
