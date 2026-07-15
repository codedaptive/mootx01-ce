//! Deterministic pairwise text-conflict screen — the substrate-owned
//! primitive behind the contradiction hunter (dreaming's content-driven
//! phase and the `moot_hunt_contradictions` sweep). Rust mirror of
//! `SubstrateML/ConflictCue.swift`; see that file's header for the full
//! cue taxonomy, precision rationale, and tokenizer contract.
//!
//! Three cues, checked strongest-first: `ValueDivergence` (same token
//! template differing only in digit-bearing positions),
//! `NegationAsymmetry` (same claim, negation cue on exactly one side),
//! `MarkerRevision` (revision/supersession marker over substantially
//! similar content). Scores derive from the conformance-gated
//! `shingle_similarity` plus integer ratios, so results are
//! bit-identical across the Swift and Rust ports; the mirrored test
//! vectors below pin both legs to the same (kind, score) outputs.

use crate::shingle_similarity;

/// The kind of lexical conflict evidence found between two strings.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConflictCueKind {
    /// Same token template, differing only in digit-bearing positions.
    ValueDivergence,
    /// Same content with a negation cue on exactly one side.
    NegationAsymmetry,
    /// Revision/supersession marker over substantially similar content.
    MarkerRevision,
    /// No conflict evidence.
    None,
}

impl ConflictCueKind {
    /// Wire-stable string form, matching Swift's raw values.
    pub fn as_str(&self) -> &'static str {
        match self {
            ConflictCueKind::ValueDivergence => "value_divergence",
            ConflictCueKind::NegationAsymmetry => "negation_asymmetry",
            ConflictCueKind::MarkerRevision => "marker_revision",
            ConflictCueKind::None => "none",
        }
    }
}

/// Result of a pairwise conflict screen: the strongest cue found and a
/// confidence score in [0, 1]. `None` always carries score 0.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ConflictCueResult {
    pub kind: ConflictCueKind,
    pub score: f32,
}

/// Score at or above which a cue is STRONG evidence — the hunter
/// auto-proposes a `contradicts` tunnel (lifecycle `Proposed`, still
/// user-reviewable). Mirrors Swift `ConflictCue.strongThreshold`.
pub const STRONG_THRESHOLD: f32 = 0.70;

/// Score at or above which (but below `STRONG_THRESHOLD`) a cue is
/// BORDERLINE — surfaced for the BYOAI client to adjudicate, never
/// auto-proposed. Mirrors Swift `ConflictCue.borderlineThreshold`.
pub const BORDERLINE_THRESHOLD: f32 = 0.45;

/// Standalone negation cue tokens. Mirrors Swift `negationTokens`
/// (bare "no" deliberately excluded — too common in benign contexts).
const NEGATION_TOKENS: &[&str] = &["not", "never", "without", "stopped", "cannot"];

/// Negation cue bigrams (adjacent token pairs). Contractions split at
/// the apostrophe under the tokenizer contract. Mirrors Swift
/// `negationBigrams`.
const NEGATION_BIGRAMS: &[&str] = &[
    "isn t", "aren t", "wasn t", "weren t", "won t", "don t", "doesn t",
    "didn t", "couldn t", "shouldn t", "wouldn t", "hasn t", "haven t",
    "no longer",
];

/// Revision/supersession marker tokens. Mirrors Swift `markerTokens`.
const MARKER_TOKENS: &[&str] = &[
    "deprecated", "superseded", "replaced", "obsolete", "reverted",
    "cancelled", "canceled", "renamed", "retracted",
];

/// Revision/supersession marker bigrams. Mirrors Swift `markerBigrams`.
const MARKER_BIGRAMS: &[&str] = &["instead of", "moved to", "changed to", "switched to"];

/// Tokenize per the mirrored contract: lowercase; maximal runs of
/// [a-z0-9.]; trim leading/trailing '.'; drop empties.
pub(crate) fn tokenize(s: &str) -> Vec<String> {
    let mut tokens: Vec<String> = Vec::new();
    let mut current = String::new();
    for ch in s.to_lowercase().chars() {
        if ch.is_ascii_lowercase() || ch.is_ascii_digit() || ch == '.' {
            current.push(ch);
        } else if !current.is_empty() {
            tokens.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
        .into_iter()
        .filter_map(|raw| {
            let t = raw.trim_matches('.');
            if t.is_empty() { None } else { Some(t.to_string()) }
        })
        .collect()
}

fn bigram_matches(tokens: &[String], i: usize, set: &[&str]) -> bool {
    i + 1 < tokens.len() && set.contains(&format!("{} {}", tokens[i], tokens[i + 1]).as_str())
}

/// Count negation cues (bigrams consume their tokens, matching Swift).
fn negation_count(tokens: &[String]) -> usize {
    let mut count = 0;
    let mut i = 0;
    while i < tokens.len() {
        if bigram_matches(tokens, i, NEGATION_BIGRAMS) {
            count += 1;
            i += 2;
            continue;
        }
        if NEGATION_TOKENS.contains(&tokens[i].as_str()) {
            count += 1;
        }
        i += 1;
    }
    count
}

/// True when the stream carries a revision marker.
fn has_marker(tokens: &[String]) -> bool {
    let mut i = 0;
    while i < tokens.len() {
        if bigram_matches(tokens, i, MARKER_BIGRAMS) {
            return true;
        }
        if MARKER_TOKENS.contains(&tokens[i].as_str()) {
            return true;
        }
        i += 1;
    }
    false
}

/// Remove negation cues so the underlying-claim similarity is measured
/// without the negation depressing the overlap it evidences.
fn strip_negation(tokens: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut i = 0;
    while i < tokens.len() {
        if bigram_matches(tokens, i, NEGATION_BIGRAMS) {
            i += 2;
            continue;
        }
        if NEGATION_TOKENS.contains(&tokens[i].as_str()) {
            i += 1;
            continue;
        }
        out.push(tokens[i].clone());
        i += 1;
    }
    out
}

/// Evaluate the conflict screen over two content strings. Returns the
/// strongest cue found (value divergence → negation asymmetry → marker
/// revision) with its score, or `None` with score 0. Mirrors Swift
/// `ConflictCue.evaluate(_:_:)` exactly.
pub fn evaluate(a: &str, b: &str) -> ConflictCueResult {
    let tokens_a = tokenize(a);
    let tokens_b = tokenize(b);
    if tokens_a.is_empty() || tokens_b.is_empty() || tokens_a == tokens_b {
        return ConflictCueResult { kind: ConflictCueKind::None, score: 0.0 };
    }

    // ── Cue 1: value divergence ──────────────────────────────────────
    if tokens_a.len() == tokens_b.len() && tokens_a.len() >= 4 {
        let mut diffs = 0usize;
        let mut all_diffs_are_values = true;
        for (ta, tb) in tokens_a.iter().zip(tokens_b.iter()) {
            if ta != tb {
                diffs += 1;
                let both_carry_digit = ta.chars().any(|c| c.is_ascii_digit())
                    && tb.chars().any(|c| c.is_ascii_digit());
                if !both_carry_digit {
                    all_diffs_are_values = false;
                }
            }
        }
        if diffs > 0 && all_diffs_are_values {
            let score = (tokens_a.len() - diffs) as f32 / tokens_a.len() as f32;
            return ConflictCueResult { kind: ConflictCueKind::ValueDivergence, score };
        }
    }

    // Underlying-claim similarity with negation cues stripped.
    let stripped_a = strip_negation(&tokens_a).join(" ");
    let stripped_b = strip_negation(&tokens_b).join(" ");
    let claim_similarity = shingle_similarity::similarity(&stripped_a, &stripped_b);

    // ── Cue 2: negation asymmetry ────────────────────────────────────
    let negated_a = negation_count(&tokens_a) > 0;
    let negated_b = negation_count(&tokens_b) > 0;
    if negated_a != negated_b && claim_similarity >= BORDERLINE_THRESHOLD {
        return ConflictCueResult { kind: ConflictCueKind::NegationAsymmetry, score: claim_similarity };
    }

    // ── Cue 3: revision marker ───────────────────────────────────────
    if has_marker(&tokens_a) != has_marker(&tokens_b) && claim_similarity >= BORDERLINE_THRESHOLD {
        return ConflictCueResult { kind: ConflictCueKind::MarkerRevision, score: claim_similarity };
    }

    ConflictCueResult { kind: ConflictCueKind::None, score: 0.0 }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Mirrored verbatim from Swift ConflictCueTests — a change to either
    // leg's lexicons, tokenizer, or scoring must update BOTH mirrors.

    #[test]
    fn tokenizer_contract() {
        assert_eq!(tokenize("Bob lives in Paris."), ["bob", "lives", "in", "paris"]);
        assert_eq!(tokenize("shipped in v1.0.30!"), ["shipped", "in", "v1.0.30"]);
        assert!(tokenize("...").is_empty());
        assert_eq!(tokenize("Isn't  DONE"), ["isn", "t", "done"]);

        // U+0130 İ lowercases (to_lowercase) to "i" + U+0307 (combining dot above).
        // U+0307 is not is_ascii_lowercase, so it acts as a separator.
        // Mirrored verbatim in Swift ConflictCueTests::tokenizerContract.
        assert_eq!(tokenize("İ1 x2 y3 z4"), ["i", "1", "x2", "y3", "z4"]);
        assert_eq!(tokenize("i1 x2 y3 z4"), ["i1", "x2", "y3", "z4"]);
    }

    // Cross-leg Unicode scalar conformance test — mirrors Swift
    // ConflictCueTests::unicodeCombiningMarkTokenizer.
    #[test]
    fn unicode_combining_mark_tokenizer() {
        // İ1 splits at the combining scalar; i1 does not.
        let with_dot = tokenize("İ1 x2 y3 z4");
        let plain_i  = tokenize("i1 x2 y3 z4");
        assert_ne!(with_dot, plain_i);
        assert_eq!(with_dot, ["i", "1", "x2", "y3", "z4"]);

        // evaluate() for "İ1 x2 y3 z4" vs "i1 x2 y3 z4": different token
        // streams, no negation/marker/digit-only diffs — no cue fires.
        let r = evaluate("İ1 x2 y3 z4", "i1 x2 y3 z4");
        assert_eq!(r.kind, ConflictCueKind::None);
    }

    #[test]
    fn negation_asymmetry_fires() {
        let r = evaluate("Bob lives in Paris", "Bob does not live in Paris");
        assert_eq!(r.kind, ConflictCueKind::NegationAsymmetry);
        assert!(r.score >= BORDERLINE_THRESHOLD);

        let contraction = evaluate(
            "the feature flag is enabled in production",
            "the feature flag isn't enabled in production",
        );
        assert_eq!(contraction.kind, ConflictCueKind::NegationAsymmetry);
        assert!(contraction.score >= STRONG_THRESHOLD);

        let no_longer = evaluate(
            "the staging server is reachable from the office network",
            "the staging server is no longer reachable from the office network",
        );
        assert_eq!(no_longer.kind, ConflictCueKind::NegationAsymmetry);
        assert!(no_longer.score >= STRONG_THRESHOLD);
    }

    #[test]
    fn value_divergence_fires() {
        let r = evaluate("the API timeout is 30 seconds", "the API timeout is 90 seconds");
        assert_eq!(r.kind, ConflictCueKind::ValueDivergence);
        assert_eq!(r.score, 5.0f32 / 6.0f32);

        let version = evaluate(
            "the fix shipped in release 1.0.29",
            "the fix shipped in release 1.0.30",
        );
        assert_eq!(version.kind, ConflictCueKind::ValueDivergence);
        assert!(version.score >= STRONG_THRESHOLD);
    }

    #[test]
    fn marker_revision_fires() {
        let r = evaluate(
            "use the staging endpoint for uploads",
            "the staging endpoint for uploads is deprecated",
        );
        assert_eq!(r.kind, ConflictCueKind::MarkerRevision);
        assert!(r.score >= BORDERLINE_THRESHOLD);
    }

    #[test]
    fn precision_guards_do_not_fire() {
        assert_eq!(evaluate("Bob lives in Paris", "Bob lives in Paris").kind, ConflictCueKind::None);
        assert_eq!(
            evaluate("Bob lives in Paris", "the deploy pipeline is not green").kind,
            ConflictCueKind::None
        );
        assert_eq!(
            evaluate("Bob does not live in Paris", "Bob does not live in Paris anymore").kind,
            ConflictCueKind::None
        );
        assert_eq!(
            evaluate("Bob lives in Paris today", "Bob lives in Rome today").kind,
            ConflictCueKind::None
        );
        assert_eq!(evaluate("", "Bob lives in Paris").kind, ConflictCueKind::None);
    }

    #[test]
    fn pinned_score_bits() {
        // Asserted verbatim in Swift ConflictCueTests::pinnedScoreBits.
        let v1 = evaluate("the API timeout is 30 seconds", "the API timeout is 90 seconds");
        assert_eq!(v1.score.to_bits(), (5.0f32 / 6.0f32).to_bits());

        let v2 = evaluate("Bob lives in Paris", "Bob does not live in Paris");
        assert_eq!(v2.kind, ConflictCueKind::NegationAsymmetry);
        let expected = shingle_similarity::similarity("bob lives in paris", "bob does live in paris");
        assert_eq!(v2.score.to_bits(), expected.to_bits());
    }
}
