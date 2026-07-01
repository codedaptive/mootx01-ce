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
// SCORING MODES
// FDCMatcher supports four ScoreMode variants (mirrors Swift FDCMatcher.ScoreMode):
//   Raw:       Σ_{t∈O} bag[t]                     (direct-init default)
//   Idf:       Σ_{t∈O} bag[t] · idf(t)            (shipped runtime mode via FdcRuntime)
//   Cosine:    (Σ_{t∈O} bag[t]) / sqrt(|sig|)
//   IdfCosine: (Σ_{t∈O} bag[t] · idf(t)) / sqrt(Σ_{t∈sig} idf(t)²)
// where idf(t) = ln(N / df(t)), N = total code signatures, df(t) = # signatures
// containing t. The bag-side norm is dropped (constant across codes for a fixed
// query; cannot change any argmax). Per-signature norms are precomputed at init.
//
// DETERMINISM GUARANTEES
// - argmax tie-break: highest score wins; ties broken by lowest code
//   lexicographically. Same rule as Swift.
// - frame descent tie-break: highest mode score wins; ties broken by lowest
//   code lexicographically. Same rule as Swift.
// - Sorted summation: floating-point addition is non-associative. Swift sums
//   idf² terms (init) and numerator overlap (score) in SORTED term order to
//   produce a deterministic result regardless of hash iteration order. Rust
//   mirrors this: all f64 sums over term sets are computed in sorted order.
// - The descent cutoff (stop_threshold) is compared against the RAW integer
//   overlap, not the normalized score — mode-independent, as in Swift.
// - No HashMap iteration order dependencies: ties are resolved by explicit
//   comparison, not by iteration order.

use std::collections::HashMap;
use crate::concept_bag::{ConceptBag, build_encoder_bag};
use crate::fdc_frame::FdcFrame;
use crate::lexicon::CanonicalizationLexicon;
use crate::fdc_signatures::FdcSignatures;

/// Scoring mode applied to both the Step-4 argmax and the Step-5 descent
/// ranking. Mirrors `FDCMatcher.ScoreMode` in Swift exactly.
///
/// The descent cutoff (`stop_threshold`) is always compared against the RAW
/// integer overlap regardless of mode — only the ranking of candidates that
/// clear the cutoff uses `score()`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ScoreMode {
    /// Σ bag[t] over the overlap. Integral, order-independent, reproduces the
    /// original ship behavior.
    Raw,
    /// Σ bag[t]·idf(t) over the overlap. IDF-weighted: distinctive terms
    /// (few signatures) contribute more than common terms.
    Idf,
    /// (Σ bag[t]) / sqrt(|sig|). Penalizes big signatures.
    Cosine,
    /// (Σ bag[t]·idf(t)) / sqrt(Σ_{t∈sig} idf(t)²). Combined IDF + signature
    /// L2 normalization.
    IdfCosine,
}

/// Maximum number of codes that may share the argmax score while still yielding
/// a classifiable result. When more codes than this are tied at the top IDF
/// score, the query bag is dominated by common cross-domain vocabulary (low-IDF
/// terms present in almost every signature) rather than subject-specific
/// vocabulary. The tie-break (lowest code lexicographically) then selects an
/// arbitrary code, not a semantically grounded one — that is a
/// confidently-wrong specific code, which is worse than the honest
/// "unclassified" sentinel "000".
///
/// Calibration (v1.0 frame, 1 071 code signatures):
///   • subject-specific text (e.g. "biology / physiology"): ≤ 2 codes tied at
///     the top IDF score — the winning code is in the correct domain.
///   • software/technical text (e.g. "wings ADR pipeline"): 10–13 codes tied
///     — the "winner" is an arbitrary code in an unrelated domain (235 =
///     angels/devotional, 621.2 = hydraulic engineering, etc.).
///
/// Setting the limit to 4 passes genuine subject-specific queries (≤ 2 ties
/// observed on the v1.0 frame) while correctly returning UNRESOLVED for
/// technical/generic text that would otherwise get a confidently-wrong code.
/// Mirrors Swift `FDCMatcher.maximumTiedWinnersForClassification`.
pub const MAX_TIED_WINNERS_FOR_CLASSIFICATION: usize = 4;

pub struct FdcMatcher {
    /// Pinned descent cutoff (cookbook §6.1). v1.0 default is 1.
    pub stop_threshold: usize,
    /// Active scoring mode. Default is Raw (reproduces original ship behavior).
    pub score_mode: ScoreMode,
    lexicon: CanonicalizationLexicon,
    frame: FdcFrame,
    /// code -> signature term set
    sig_terms: HashMap<String, std::collections::HashSet<String>>,
    /// term -> sorted list of codes (inverted index)
    index: HashMap<String, Vec<String>>,
    /// term -> ln(N / df(t)) — precomputed IDF over the code signatures.
    /// idf[t] = 0 for a term present in every signature. Only non-trivial for
    /// ScoreMode::Idf and ScoreMode::IdfCosine, but always precomputed so the
    /// init path is branch-free (cost: one pass over df at construction time).
    idf: HashMap<String, f64>,
    /// code -> sqrt(|sig|) — precomputed for ScoreMode::Cosine.
    sig_norm: HashMap<String, f64>,
    /// code -> sqrt(Σ_{t∈sig} idf(t)²) — precomputed for ScoreMode::IdfCosine.
    /// Summed in SORTED term order to match Swift's deterministic init.
    sig_idf_norm: HashMap<String, f64>,
}

impl FdcMatcher {
    pub fn new(
        lexicon: CanonicalizationLexicon,
        frame: FdcFrame,
        signatures: &FdcSignatures,
        stop_threshold: usize,
    ) -> Self {
        Self::new_with_mode(lexicon, frame, signatures, stop_threshold, ScoreMode::Raw)
    }

    pub fn new_with_mode(
        lexicon: CanonicalizationLexicon,
        frame: FdcFrame,
        signatures: &FdcSignatures,
        stop_threshold: usize,
        score_mode: ScoreMode,
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

        // IDF over the code signatures: df(t) = # signatures containing t,
        // N = total code signatures. idf(t) = ln(N / df(t)).
        // A term in every signature carries idf 0; a term in one signature
        // carries ln(N). Precomputed for all modes (cost: one df pass at init).
        let n = sig_terms.len() as f64;
        let mut df: HashMap<String, usize> = HashMap::new();
        for (_, terms) in &sig_terms {
            for t in terms {
                *df.entry(t.clone()).or_insert(0) += 1;
            }
        }
        let mut idf: HashMap<String, f64> = HashMap::with_capacity(df.len());
        for (t, d) in &df {
            idf.insert(t.clone(), if *d > 0 { (n / *d as f64).ln() } else { 0.0 });
        }

        // Per-signature norms (big-signature penalty).
        //   sig_norm[code]     = sqrt(|sig|)             for ScoreMode::Cosine
        //   sig_idf_norm[code] = sqrt(Σ idf(t)²)         for ScoreMode::IdfCosine
        //
        // The IDF norm sum MUST be in SORTED term order: floating-point addition
        // is non-associative, and HashSet iteration order is randomized. Sorting
        // pins the result to match Swift's init (which does `terms.sorted()`).
        let mut sig_norm: HashMap<String, f64> = HashMap::with_capacity(sig_terms.len());
        let mut sig_idf_norm: HashMap<String, f64> = HashMap::with_capacity(sig_terms.len());
        for (code, terms) in &sig_terms {
            sig_norm.insert(
                code.clone(),
                if terms.is_empty() { 0.0 } else { (terms.len() as f64).sqrt() },
            );
            // Collect terms into a sorted Vec, then sum idf(t)² in that order.
            let mut sorted_terms: Vec<&str> = terms.iter().map(|s| s.as_str()).collect();
            sorted_terms.sort_unstable();
            let mut ss = 0.0f64;
            for t in &sorted_terms {
                let w = idf.get(*t).copied().unwrap_or(0.0);
                ss += w * w;
            }
            sig_idf_norm.insert(code.clone(), if ss > 0.0 { ss.sqrt() } else { 0.0 });
        }

        FdcMatcher {
            stop_threshold,
            score_mode,
            lexicon,
            frame,
            sig_terms,
            index,
            idf,
            sig_norm,
            sig_idf_norm,
        }
    }

    /// Score `code`'s overlap with `bag` under the active `score_mode`. The
    /// numerator is summed over the overlap (terms shared between bag and the
    /// code's membership signature) in SORTED term order for determinism.
    /// The denominator is the mode's signature-side normalization (1.0 for
    /// Raw/Idf). Returns 0.0 when there is no overlap.
    ///
    /// Used for BOTH the Step-4 argmax and the Step-5 descent ranking so both
    /// are scored on one footing — mirrors Swift `FDCMatcher.score(code:bag:)`.
    fn score(&self, code: &str, bag: &ConceptBag) -> f64 {
        let terms = match self.sig_terms.get(code) {
            Some(t) => t,
            None => return 0.0,
        };
        // Compute the overlap in SORTED term order: floating-point addition is
        // non-associative, so a fixed summation order is required for IDF modes
        // to be bit-reproducible (bag's HashMap iteration order is randomized).
        // For Raw the sum is integral and order-independent, but we use the same
        // sorted path for uniformity — mirroring Swift's score() function.
        let mut overlap: Vec<&str> = terms
            .iter()
            .filter(|t| bag.contains_key(t.as_str()))
            .map(|t| t.as_str())
            .collect();
        overlap.sort_unstable();

        let mut num = 0.0f64;
        match self.score_mode {
            ScoreMode::Raw | ScoreMode::Cosine => {
                // Raw numerator: Σ bag[t] over the overlap.
                for t in &overlap {
                    num += *bag.get(*t).unwrap_or(&0) as f64;
                }
            }
            ScoreMode::Idf | ScoreMode::IdfCosine => {
                // IDF-weighted numerator: Σ bag[t]·idf(t) over the overlap.
                for t in &overlap {
                    let n = *bag.get(*t).unwrap_or(&0) as f64;
                    let w = self.idf.get(*t).copied().unwrap_or(0.0);
                    num += n * w;
                }
            }
        }
        match self.score_mode {
            ScoreMode::Raw | ScoreMode::Idf => num,
            ScoreMode::Cosine => {
                let d = self.sig_norm.get(code).copied().unwrap_or(0.0);
                if d > 0.0 { num / d } else { num }
            }
            ScoreMode::IdfCosine => {
                let d = self.sig_idf_norm.get(code).copied().unwrap_or(0.0);
                if d > 0.0 { num / d } else { num }
            }
        }
    }

    /// The RAW integer overlap Σ bag[t] over (bag ∩ sig), used for the
    /// mode-independent descent cutoff comparison (stop_threshold). Mirrors
    /// Swift `FDCMatcher.rawOverlap(code:bag:)`.
    fn raw_overlap(&self, code: &str, bag: &ConceptBag) -> usize {
        let terms = match self.sig_terms.get(code) {
            Some(t) => t,
            None => return 0,
        };
        let mut o = 0usize;
        for (term, n) in bag {
            if terms.contains(term.as_str()) {
                o += n;
            }
        }
        o
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
        // Read the LIVE process-global word-class table (cookbook §1.3/§2.2):
        // a post-reduce live swap is observed here in-session, exactly as the
        // Swift `BagBuilder.bag` path reads the live `LatticeLib.wordClass`
        // holder. The `Arc` is cloned once (brief read-lock) and the bag build
        // runs against the immutable snapshot — no torn read.
        let table = crate::word_class_table::global_table();
        let bag = build_encoder_bag(text, &self.lexicon, &table);
        self.encode_from_bag(bag)
    }

    /// Non-recording variant of `encode_anchor` (secfix/fdc-pool).
    ///
    /// Identical FDC code and Q-ID result to `encode_anchor`. Novel tokens
    /// encountered while building the concept bag are NOT accumulated into
    /// `SHARED_NOVEL_CACHE`, so user-memory content classified here does not
    /// leak plaintext tokens to the pool pipeline.
    ///
    /// Called from `Fdc::encode_anchor_no_record` → `capture_with_mode` in
    /// GeniusLocusKit `intake.rs`. Mirrors Swift
    /// `FDCMatcher.encodeAnchor(_:recordNovel: false)`.
    pub fn encode_anchor_no_record(&self, text: &str) -> (Option<String>, Option<String>) {
        let table = crate::word_class_table::global_table();
        // Non-recording bag build: SHARED_NOVEL_CACHE.record is not called for
        // novel tokens, so no user-memory content leaks to the pool pipeline.
        let bag = crate::concept_bag::build_encoder_bag_no_record(text, &self.lexicon, &table);
        self.encode_from_bag(bag)
    }

    /// Score a pre-built concept bag against the FDC signatures (Steps 4–5)
    /// and return the best matching code + dominant Q-ID.
    ///
    /// The bag must be fully constructed before calling this method; whether
    /// novel-token classification was recorded into the pool cache is the
    /// caller's responsibility. Both `encode_anchor` and
    /// `encode_anchor_no_record` delegate here so the scoring logic lives in
    /// exactly one place.
    ///
    /// Mirrors Swift `FDCMatcher.encodeFromBag(_:)`.
    fn encode_from_bag(&self, bag: ConceptBag) -> (Option<String>, Option<String>) {
        let qid = dominant_qid(&bag);

        if bag.is_empty() {
            return (None, qid);
        }

        // Step 4 — match + score (§5.2/§5.3). The inverted index gives the
        // set of candidate codes (any code sharing ≥1 bag term); each candidate
        // is then scored under the active mode. For Raw the score is exactly
        // Σ bag[t] (integers held in f64 — comparisons exact), reproducing the
        // original ship behavior.
        let mut candidate_set: std::collections::HashSet<String> =
            std::collections::HashSet::new();
        for (term, _) in &bag {
            if let Some(codes) = self.index.get(term.as_str()) {
                for code in codes {
                    candidate_set.insert(code.clone());
                }
            }
        }

        if candidate_set.is_empty() {
            return (None, qid); // §5.2.3 — UNRESOLVED, no guess
        }

        // Sorted so the scan order is deterministic regardless of HashSet
        // hashing. This matters for the normalized modes: two codes can carry
        // equal (or float-rounding-equal) scores, and the lowest-code tie-break
        // only holds if the scan visits codes in a fixed order.
        let mut candidates: Vec<String> = candidate_set.into_iter().collect();
        candidates.sort();

        // argmax: highest score, ties broken by lowest code lexicographically.
        let mut node = String::new();
        let mut node_score = -f64::MAX;
        for code in &candidates {
            let s = self.score(code, &bag);
            if s > node_score || (s == node_score && (node.is_empty() || code < &node)) {
                node = code.clone();
                node_score = s;
            }
        }

        // Tie-count guard (MAX_TIED_WINNERS_FOR_CLASSIFICATION): when many
        // codes share the argmax score, the query bag is dominated by common
        // cross-domain Q-IDs with near-zero IDF weight. The tie-break
        // (lowest code) picks an arbitrary code rather than a semantically
        // grounded one — a confidently-wrong specific code is worse than the
        // honest "000" unclassified sentinel. UNRESOLVED when tied codes
        // exceed the allowed maximum. Mirrors Swift FDCMatcher.encodeAnchor.
        let tied_count = candidates
            .iter()
            .filter(|c| self.score(c, &bag) == node_score)
            .count();
        if tied_count > MAX_TIED_WINNERS_FOR_CLASSIFICATION {
            return (None, qid); // too many tied winners — no discriminating signal
        }

        // Step 5 — frame descent (§6.1). A child must clear the RAW overlap
        // cutoff (mode-independent) to be a candidate; among those, the highest
        // mode score wins (ties -> lowest code). Scoring the descent under the
        // same mode as the argmax keeps both on one footing.
        loop {
            let children = self.frame.children(&node);
            let mut best: Option<String> = None;
            let mut best_score = 0.0f64;

            for child in children {
                if self.sig_terms.get(&child.code).is_none() {
                    continue;
                }
                // Cutoff check uses raw integer overlap — mode-independent.
                if self.raw_overlap(&child.code, &bag) < self.stop_threshold {
                    continue;
                }
                let s = self.score(&child.code, &bag);
                if best.is_none()
                    || s > best_score
                    || (s == best_score && child.code < *best.as_ref().unwrap())
                {
                    best = Some(child.code.clone());
                    best_score = s;
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
