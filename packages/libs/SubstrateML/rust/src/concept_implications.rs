//! Sound logical implications over a `FormalContext` via bounded
//! Duquenne–Guigues canonical basis enumeration.
//!
//! # Algorithm
//!
//! Size-ordered pseudo-intent enumeration (Ganter & Wille, "Formal Concept
//! Analysis: Mathematical Foundations", Chapter 7). The Rust implementation
//! is a direct port of `ConceptImplications.swift` and must produce
//! bit-identical output on the shared conformance vectors in
//! `docs/engineering/substrate_reference/test-harness/vectors/concept_implications.json`.
//!
//! A set P is a Duquenne–Guigues pseudo-intent iff:
//!   (1) closure_context(P) ≠ P  (P is not a concept intent / closed set)
//!   (2) For every D-G pseudo-intent Q with Q ⊊ P: Q'' ⊆ P
//!       (all conclusions from smaller pseudo-intents fit inside P)
//!
//! The algorithm enumerates all subsets of size 0..maxPremiseSize in
//! non-decreasing size order (lexicographic within each size). For each
//! subset P, conditions (1) and (2) are tested against the implication set
//! built so far. When P passes both conditions it is a pseudo-intent and
//! yields `Implication { premise: P, conclusion: closure(P) \ P }`.
//!
//! # Soundness
//!
//! Every emitted implication holds in the context: if a row carries every
//! attribute in `premise`, it carries every attribute in `conclusion`.
//! This follows because `conclusion = closure_context(premise) \ premise`,
//! and the closure operator returns exactly the attributes shared by every
//! row carrying `premise`.
//!
//! # Bounding
//!
//! Two caps limit the output:
//! - `max_implications`: hard cap on the number of emitted implications.
//!   When reached, `is_truncated = true`.
//! - `max_premise_size`: pseudo-intents with `|premise| > max_premise_size`
//!   are silently skipped (not emitted, enumeration continues). This is a
//!   filter, not a terminator; it does not set `is_truncated` by itself.
//!
//! # Rust–Swift contract
//!
//! The attribute universe is sorted by the `Ord` on `FormalAttribute`
//! (lexicographic over `(namespace, key, value)`), identical to the Swift
//! `Comparable` order. The combination enumeration visits subsets in
//! lexicographic order on the sorted universe — identical to Swift.
//! Implication output is sorted: premise size ascending, lex premise,
//! lex conclusion.

use std::collections::BTreeSet;
use crate::formal_concept_analysis::{FormalAttribute, FormalContext};

// MARK: - Types

/// One sound logical implication: every row carrying all attributes in
/// `premise` also carries all attributes in `conclusion`.
///
/// `premise` and `conclusion` are disjoint: `conclusion` is
/// `closure_context(premise) \ premise`. Both are stored as sorted
/// `Vec<FormalAttribute>` for deterministic output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Implication {
    /// The premise attribute set (sorted ascending).
    pub premise: Vec<FormalAttribute>,
    /// The conclusion: `closure(premise) \ premise` (sorted ascending).
    pub conclusion: Vec<FormalAttribute>,
}

/// Sound logical implications over a `FormalContext` via bounded
/// Duquenne–Guigues canonical basis enumeration.
///
/// The basis is *sound*: every emitted implication holds universally.
/// The basis may be *incomplete* when bounding caps bind
/// (`is_truncated == true`).
#[derive(Debug, Clone, PartialEq)]
pub struct ConceptImplications {
    /// Emitted implications, sorted for determinism.
    pub implications: Vec<Implication>,
    /// True when the `max_implications` cap terminated enumeration early.
    pub is_truncated: bool,
}

impl ConceptImplications {
    /// Computes the bounded D-G canonical basis for `context`.
    ///
    /// Uses size-ordered pseudo-intent enumeration. Subsets of the attribute
    /// universe are tested in non-decreasing size order (lexicographic within
    /// each size) against the D-G pseudo-intent conditions. Sound implications
    /// are emitted and accumulated into the stem base for minimality checking
    /// of subsequent candidates.
    ///
    /// # Parameters
    ///
    /// - `context`: the fully-materialised `FormalContext`.
    /// - `max_implications`: maximum number of implications to emit. Set to
    ///   `usize::MAX` for uncapped enumeration.
    /// - `max_premise_size`: maximum premise size to emit. Pseudo-intents
    ///   with `|premise| > max_premise_size` are skipped silently.
    ///
    /// Returns an empty basis when the context has no rows or no attributes.
    pub fn compute(
        context: &FormalContext,
        max_implications: usize,
        max_premise_size: usize,
    ) -> ConceptImplications {
        let universe = context.attributes();
        let n = universe.len();

        if n == 0 || context.row_count() == 0 {
            return ConceptImplications { implications: Vec::new(), is_truncated: false };
        }

        // stem_base accumulates all found pseudo-intents (premise, conclusion)
        // including those not emitted due to max_premise_size.
        let mut stem_base: Vec<(BTreeSet<FormalAttribute>, BTreeSet<FormalAttribute>)> = Vec::new();
        let mut emitted: Vec<Implication> = Vec::new();
        let mut is_truncated = false;

        let cap_size = n.min(max_premise_size);

        // Size 0: test the empty set.
        {
            let premise = BTreeSet::new();
            let closure = context_closure_set(context, &premise);
            if !closure.is_empty() {
                // {} is a pseudo-intent (global attributes exist).
                let conclusion: BTreeSet<FormalAttribute> = closure.difference(&premise).cloned().collect();
                stem_base.push((premise.clone(), conclusion.clone()));

                if max_implications == 0 {
                    return ConceptImplications {
                        implications: Vec::new(),
                        is_truncated: true,
                    };
                }
                emitted.push(Implication {
                    premise: sorted_vec(&premise),
                    conclusion: sorted_vec(&conclusion),
                });
                if emitted.len() >= max_implications {
                    let has_next = has_more_pseudo_intents_after(
                        &[], 0, context, &stem_base, cap_size,
                    );
                    return ConceptImplications {
                        implications: sort_implications(emitted),
                        is_truncated: has_next,
                    };
                }
            }
        }

        // Sizes 1..cap_size.
        if cap_size == 0 {
            return ConceptImplications {
                implications: sort_implications(emitted),
                is_truncated: false,
            };
        }

        for size in 1..=cap_size {
            // Enumerate all C(n, size) combinations of attribute indices.
            let mut indices: Vec<usize> = (0..size).collect();
            loop {
                // Build premise set from current combination.
                let premise: BTreeSet<FormalAttribute> = indices.iter()
                    .map(|&i| universe[i].clone())
                    .collect();

                if is_dg_pseudo_intent(&premise, context, &stem_base) {
                    let closure = context_closure_set(context, &premise);
                    let conclusion: BTreeSet<FormalAttribute> = closure.difference(&premise).cloned().collect();
                    stem_base.push((premise.clone(), conclusion.clone()));

                    if max_implications == 0 {
                        is_truncated = true;
                        break;
                    }
                    emitted.push(Implication {
                        premise: sorted_vec(&premise),
                        conclusion: sorted_vec(&conclusion),
                    });
                    if emitted.len() >= max_implications {
                        let has_next = has_more_pseudo_intents_after(
                            &indices, size, context, &stem_base, cap_size,
                        );
                        return ConceptImplications {
                            implications: sort_implications(emitted),
                            is_truncated: has_next,
                        };
                    }
                }

                // Advance to next combination in lexicographic order.
                match next_combination(&mut indices, n) {
                    true => {}
                    false => break,
                }
            }
            if is_truncated { break; }
        }

        ConceptImplications {
            implications: sort_implications(emitted),
            is_truncated,
        }
    }
}

// MARK: - Internal helpers

/// Tests whether `premise` is a D-G pseudo-intent w.r.t. the context
/// and the current stem base.
///
/// Conditions:
///   (1) closure_context(premise) ≠ premise  (not closed)
///   (2) For every (p, q) in stem_base where p ⊊ premise: q ⊆ premise
fn is_dg_pseudo_intent(
    premise: &BTreeSet<FormalAttribute>,
    context: &FormalContext,
    stem_base: &[(BTreeSet<FormalAttribute>, BTreeSet<FormalAttribute>)],
) -> bool {
    // Condition (1): not closed.
    let closure = context_closure_set(context, premise);
    if closure == *premise {
        return false;
    }

    // Condition (2): all conclusions of strict-subset pseudo-intents are in premise.
    for (p, q) in stem_base {
        if p.len() < premise.len() && p.is_subset(premise) {
            if !q.is_subset(premise) {
                return false;
            }
        }
    }
    true
}

/// Computes the context closure of `attrs` as a `BTreeSet`.
///
/// Uses `FormalContext::closure` (which returns a sorted `Vec`) and converts
/// to a `BTreeSet` for set operations. Mirrors the Swift
/// `context.closure(of:)` call.
fn context_closure_set(
    context: &FormalContext,
    attrs: &BTreeSet<FormalAttribute>,
) -> BTreeSet<FormalAttribute> {
    let attrs_vec: Vec<FormalAttribute> = attrs.iter().cloned().collect();
    context.closure(&attrs_vec).into_iter().collect()
}

/// Advances `indices` to the next combination of `size` values from [0, n)
/// in lexicographic order. Returns `true` on success, `false` when `indices`
/// is the last combination.
fn next_combination(indices: &mut Vec<usize>, n: usize) -> bool {
    let k = indices.len();
    let mut i = k;
    loop {
        if i == 0 {
            return false;
        }
        i -= 1;
        if indices[i] < n - (k - i) {
            indices[i] += 1;
            for j in (i + 1)..k {
                indices[j] = indices[j - 1] + 1;
            }
            return true;
        }
    }
}

/// Checks whether any more pseudo-intents exist after the current position.
/// Used to set `is_truncated` correctly when the `max_implications` cap hits.
fn has_more_pseudo_intents_after(
    current_indices: &[usize],
    current_size: usize,
    context: &FormalContext,
    stem_base: &[(BTreeSet<FormalAttribute>, BTreeSet<FormalAttribute>)],
    cap_size: usize,
) -> bool {
    let n = context.attributes().len();
    let universe = context.attributes();

    // Continue within the current size.
    if current_size > 0 {
        let mut indices = current_indices.to_vec();
        while next_combination(&mut indices, n) {
            let premise: BTreeSet<FormalAttribute> = indices.iter()
                .map(|&i| universe[i].clone())
                .collect();
            if is_dg_pseudo_intent(&premise, context, stem_base) {
                return true;
            }
        }
    }

    // Check larger sizes.
    for next_size in (current_size + 1)..=cap_size {
        if next_size > n { break; }
        let mut indices: Vec<usize> = (0..next_size).collect();
        loop {
            let premise: BTreeSet<FormalAttribute> = indices.iter()
                .map(|&i| universe[i].clone())
                .collect();
            if is_dg_pseudo_intent(&premise, context, stem_base) {
                return true;
            }
            if !next_combination(&mut indices, n) { break; }
        }
    }
    false
}

/// Converts a `BTreeSet<FormalAttribute>` to a sorted `Vec<FormalAttribute>`.
/// Since `BTreeSet` is already sorted, this is a direct collect.
fn sorted_vec(set: &BTreeSet<FormalAttribute>) -> Vec<FormalAttribute> {
    set.iter().cloned().collect()
}

/// Sorts a vector of `Implication` for deterministic output.
///
/// Order: premise size ascending, lex premise, lex conclusion.
/// Identical to the Swift `sortedImplications` function.
fn sort_implications(mut implications: Vec<Implication>) -> Vec<Implication> {
    implications.sort_by(|a, b| {
        a.premise.len().cmp(&b.premise.len())
            .then_with(|| a.premise.cmp(&b.premise))
            .then_with(|| a.conclusion.cmp(&b.conclusion))
    });
    implications
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use crate::formal_concept_analysis::FormalContext;
    // HashSet is test-only (premise/conclusion set comparisons below);
    // importing it at module scope would warn on non-test builds.
    use std::collections::HashSet;

    fn a() -> FormalAttribute { FormalAttribute::new("t", "k", "a") }
    fn b() -> FormalAttribute { FormalAttribute::new("t", "k", "b") }
    fn c() -> FormalAttribute { FormalAttribute::new("t", "k", "c") }

    // ci-001: empty context.
    #[test]
    fn ci001_empty_context() {
        let ctx = FormalContext::new(&[]);
        let result = ConceptImplications::compute(&ctx, 100, 100);
        assert!(result.implications.is_empty());
        assert!(!result.is_truncated);
    }

    // ci-002: two-row context. Row0:{a}, Row1:{b,c}. D-G basis: {b}->{c}, {c}->{b}.
    #[test]
    fn ci002_two_row_three_attribute() {
        let ctx = FormalContext::new(&[
            vec![a()],
            vec![b(), c()],
        ]);
        let result = ConceptImplications::compute(&ctx, 100, 100);
        assert!(!result.is_truncated);
        assert_eq!(result.implications.len(), 2);
        // {b} -> {c}
        assert_eq!(result.implications[0].premise, vec![b()]);
        assert_eq!(result.implications[0].conclusion, vec![c()]);
        // {c} -> {b}
        assert_eq!(result.implications[1].premise, vec![c()]);
        assert_eq!(result.implications[1].conclusion, vec![b()]);
    }

    // ci-003: three singletons, maxImplications=2. Truncated.
    #[test]
    fn ci003_cap_truncation() {
        let ctx = FormalContext::new(&[
            vec![a()],
            vec![b()],
            vec![c()],
        ]);
        let result = ConceptImplications::compute(&ctx, 2, 100);
        assert!(result.is_truncated);
        assert_eq!(result.implications.len(), 2);
        // First two implications in size-lex order: {a,b}->{c}, {a,c}->{b}.
        assert_eq!(result.implications[0].premise, vec![a(), b()]);
        assert_eq!(result.implications[0].conclusion, vec![c()]);
        assert_eq!(result.implications[1].premise, vec![a(), c()]);
        assert_eq!(result.implications[1].conclusion, vec![b()]);
    }

    // ci-004: global attribute. Row0:{a,b}, Row1:{b,c}. D-G basis: {}->{b}.
    #[test]
    fn ci004_global_attribute() {
        let ctx = FormalContext::new(&[
            vec![a(), b()],
            vec![b(), c()],
        ]);
        let result = ConceptImplications::compute(&ctx, 100, 100);
        assert!(!result.is_truncated);
        assert_eq!(result.implications.len(), 1);
        assert_eq!(result.implications[0].premise, Vec::<FormalAttribute>::new());
        assert_eq!(result.implications[0].conclusion, vec![b()]);
    }

    // Soundness: for every emitted implication (premise -> conclusion),
    // every row that carries all of premise also carries all of conclusion.
    #[test]
    fn soundness_holds_for_every_row() {
        let ctx = FormalContext::new(&[
            vec![a()],
            vec![b(), c()],
        ]);
        let result = ConceptImplications::compute(&ctx, 100, 100);
        let rows: Vec<std::collections::HashSet<FormalAttribute>> = vec![
            vec![a()].into_iter().collect(),
            vec![b(), c()].into_iter().collect(),
        ];
        for impl_ in &result.implications {
            let premise_set: HashSet<FormalAttribute> = impl_.premise.iter().cloned().collect();
            let conclusion_set: HashSet<FormalAttribute> = impl_.conclusion.iter().cloned().collect();
            for row in &rows {
                if premise_set.is_subset(row) {
                    assert!(
                        conclusion_set.is_subset(row),
                        "Soundness violation: row {:?} satisfies premise {:?} but not conclusion {:?}",
                        row, impl_.premise, impl_.conclusion
                    );
                }
            }
        }
    }

    // Determinism: two runs produce identical output.
    #[test]
    fn determinism() {
        let ctx = FormalContext::new(&[
            vec![a()],
            vec![b(), c()],
        ]);
        let first = ConceptImplications::compute(&ctx, 100, 100);
        let second = ConceptImplications::compute(&ctx, 100, 100);
        assert_eq!(first, second);
    }

    // maxPremiseSize filter: three singletons context with maxPremiseSize=1.
    // All D-G implications have size-2 premises -> none emitted, not truncated.
    #[test]
    fn max_premise_size_filters() {
        let ctx = FormalContext::new(&[
            vec![a()],
            vec![b()],
            vec![c()],
        ]);
        let result = ConceptImplications::compute(&ctx, 100, 1);
        assert!(result.implications.is_empty());
        assert!(!result.is_truncated);
    }

    // maxImplications=0: truncated when pseudo-intents exist.
    #[test]
    fn max_implications_zero_truncates() {
        let ctx = FormalContext::new(&[
            vec![a()],
            vec![b(), c()],
        ]);
        let result = ConceptImplications::compute(&ctx, 0, 100);
        assert!(result.implications.is_empty());
        assert!(result.is_truncated);
    }
}
