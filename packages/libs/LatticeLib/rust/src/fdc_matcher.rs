// fdc_matcher.rs — FDC runtime encoder Steps 4–5
//
// Port of FDCMatcher.swift.
//
// Step 4 (§5.2/§5.3): score[code] += bag[term] for every term shared with the
//                      code's signature (inverted-index single-pass scan).
//                      Empty score -> UNRESOLVED.
// Step 5 (§6):        start at argmax(score) (ties -> lowest code), then walk
//                      down children while a child's bag overlap meets
//                      stop_threshold; return the deepest such code.
//
// `encode` is a pure function of the input text and the pinned artifacts —
// the agreement property.
//
// DETERMINISM GUARANTEES
// - argmax tie-break: highest score wins; ties broken by lowest code
//   lexicographically. Same rule as Swift.
// - frame descent tie-break: highest overlap wins; ties broken by lowest code
//   lexicographically. Same rule as Swift.
// - No HashMap iteration order dependencies: ties are resolved by explicit
//   comparison, not by iteration order.

use std::collections::HashMap;
use crate::concept_bag::{ConceptBag, build_encoder_bag};
use crate::fdc_frame::FdcFrame;
use crate::lexicon::CanonicalizationLexicon;
use crate::word_class_table::WordClassTableCache;
use crate::fdc_signatures::FdcSignatures;

pub struct FdcMatcher {
    /// Pinned descent cutoff (cookbook §6.1). v1.0 default is 1.
    pub stop_threshold: usize,
    lexicon: CanonicalizationLexicon,
    frame: FdcFrame,
    table: WordClassTableCache,
    /// code -> signature term set
    sig_terms: HashMap<String, std::collections::HashSet<String>>,
    /// term -> sorted list of codes (inverted index)
    index: HashMap<String, Vec<String>>,
}

impl FdcMatcher {
    pub fn new(
        lexicon: CanonicalizationLexicon,
        frame: FdcFrame,
        table: WordClassTableCache,
        signatures: &FdcSignatures,
        stop_threshold: usize,
    ) -> Self {
        let sig_terms = signatures.sig_terms.clone();

        // Build inverted index: term -> sorted Vec<code>
        let mut index: HashMap<String, Vec<String>> = HashMap::new();
        for (code, terms) in &sig_terms {
            for term in terms {
                index.entry(term.clone()).or_default().push(code.clone());
            }
        }
        // Sort each code list for deterministic iteration order.
        for codes in index.values_mut() {
            codes.sort();
        }

        FdcMatcher {
            stop_threshold,
            lexicon,
            frame,
            table,
            sig_terms,
            index,
        }
    }

    /// Encode `text` to an FDC code, or None for UNRESOLVED. Never guesses.
    pub fn encode(&self, text: &str) -> Option<String> {
        self.encode_anchor(text).0
    }

    /// Encode `text` and surface the dominant concept Q-ID.
    /// Returns (code, conceptQID).
    /// `code` is None for UNRESOLVED.
    /// `conceptQID` is the highest-weighted Wikidata Q-ID in the bag, or None.
    pub fn encode_anchor(&self, text: &str) -> (Option<String>, Option<String>) {
        let bag = build_encoder_bag(text, &self.lexicon, &self.table);
        let qid = dominant_qid(&bag);

        if bag.is_empty() {
            return (None, qid);
        }

        // Step 4 — match + score (§5.2/§5.3).
        let mut score: HashMap<String, usize> = HashMap::new();
        for (term, n) in &bag {
            if let Some(codes) = self.index.get(term) {
                for code in codes {
                    *score.entry(code.clone()).or_insert(0) += n;
                }
            }
        }

        if score.is_empty() {
            return (None, qid); // §5.2.3 — UNRESOLVED, no guess
        }

        // argmax: highest score, ties broken by lowest code lexicographically.
        let mut node = String::new();
        let mut node_score = 0usize;
        for (code, &s) in &score {
            if s > node_score || (s == node_score && (node.is_empty() || code < &node)) {
                node = code.clone();
                node_score = s;
            }
        }

        // Step 5 — frame descent (§6.1).
        loop {
            let children = self.frame.children(&node);
            let mut best: Option<String> = None;
            let mut best_overlap = 0usize;

            for child in children {
                let terms = match self.sig_terms.get(&child.code) {
                    Some(t) => t,
                    None => continue,
                };
                let mut overlap = 0usize;
                for (term, n) in &bag {
                    if terms.contains(term) {
                        overlap += n;
                    }
                }
                if overlap < self.stop_threshold {
                    continue;
                }
                if overlap > best_overlap
                    || (overlap == best_overlap && (best.is_none() || child.code < *best.as_ref().unwrap()))
                {
                    best = Some(child.code.clone());
                    best_overlap = overlap;
                }
            }

            match best {
                Some(next) => node = next,
                None => break,
            }
        }

        (Some(node), qid)
    }
}

/// The highest-count Wikidata Q-ID in `bag`, ties broken by lowest Q-ID
/// lexicographically. None if the bag holds no Q-ID key. Mirrors
/// `FDCMatcher.dominantQID` in Swift.
fn dominant_qid(bag: &ConceptBag) -> Option<String> {
    let mut best: Option<String> = None;
    let mut best_n = 0usize;
    for (k, &n) in bag {
        if k.starts_with('Q') {
            if n > best_n || (n == best_n && (best.is_none() || k < best.as_ref().unwrap())) {
                best = Some(k.clone());
                best_n = n;
            }
        }
    }
    best
}
