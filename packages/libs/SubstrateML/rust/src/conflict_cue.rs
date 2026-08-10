//! Deterministic pairwise text-conflict screen — the substrate-owned
//! primitive behind the contradiction hunter (dreaming's content-driven
//! phase and the `moot_hunt_contradictions` sweep). Rust mirror of
//! `SubstrateML/ConflictCue.swift`; see that file's header for the full
//! cue taxonomy, precision rationale, and tokenizer contract.
//!
//! Four cues, checked strongest-first: `ValueDivergence` (same token
//! template differing only in digit-bearing positions),
//! `NegationAsymmetry` (same claim, negation cue on exactly one side),
//! `MarkerRevision` (revision/supersession marker over substantially
//! similar content), and `WordExclusion` (shared leading anchor with
//! word-valued digit-free divergent tails on both sides — reached only
//! when the first three cues all declined, and structurally clamped
//! below `STRONG_THRESHOLD` so it never auto-proposes). Scores derive
//! from the conformance-gated `shingle_similarity` plus integer ratios,
//! so results are bit-identical across the Swift and Rust ports; the
//! mirrored test vectors below pin both legs to the same (kind, score)
//! outputs.

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
    /// Shared leading anchor with word-valued (digit-free) divergent
    /// tails on both sides — mutually exclusive word values over the
    /// same subject ("works at Acme Robotics" vs "works at Northwind
    /// Analytics"). Score is structurally clamped below
    /// `STRONG_THRESHOLD`; see `evaluate`.
    WordExclusion,
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
            ConflictCueKind::WordExclusion => "word_exclusion",
            ConflictCueKind::None => "none",
        }
    }

    /// The contradiction tier this cue kind feeds, or `None` for
    /// `ConflictCueKind::None`.
    ///
    /// Tier taxonomy: tier 1 is the typed-KGFact lane — structured
    /// subject/predicate collisions produced elsewhere in the estate,
    /// never by this lexical screen, which is why no variant maps to 1
    /// here. Tier 2 is a CONFLICT CANDIDATE — cheap lexical evidence
    /// that two claims are in tension (`NegationAsymmetry`,
    /// `MarkerRevision`, `WordExclusion`). Tier 3 is DIVERGENCE — the
    /// same template with different values (`ValueDivergence`), the
    /// highest-precision lexical signal. Mirrors Swift
    /// `ConflictCueKind.contradictionTier`.
    pub fn contradiction_tier(&self) -> Option<u8> {
        match self {
            ConflictCueKind::ValueDivergence => Some(3),
            ConflictCueKind::NegationAsymmetry
            | ConflictCueKind::MarkerRevision
            | ConflictCueKind::WordExclusion => Some(2),
            ConflictCueKind::None => None,
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

/// Ceiling for `WordExclusion` scores — one hundredth below
/// `STRONG_THRESHOLD` so the cue can NEVER cross into auto-propose
/// territory. Structural enforcement of "maybe?", not a tuning knob.
/// Mirrors Swift `ConflictCue.wordExclusionCeiling`.
const WORD_EXCLUSION_CEILING: f32 = 0.69;

/// Width of the `WordExclusion` scoring band above
/// `BORDERLINE_THRESHOLD`. Deliberately 0.24 (not the full 0.25 gap to
/// `STRONG_THRESHOLD`) so even a hypothetical anchor fraction of 1.0
/// lands exactly on `WORD_EXCLUSION_CEILING`, still below
/// `STRONG_THRESHOLD`. Mirrors Swift `ConflictCue.wordExclusionBandWidth`.
const WORD_EXCLUSION_BAND_WIDTH: f32 = 0.24;

/// Minimum shared leading tokens for a substantial anchor. Two tokens
/// ("riley nakamura", "the flag") is the smallest run that plausibly
/// names a subject; one shared leading token is too weak. Mirrors
/// Swift `ConflictCue.wordExclusionMinAnchorTokens`.
const WORD_EXCLUSION_MIN_ANCHOR_TOKENS: usize = 2;

/// Minimum fraction of the LONGER token stream the shared anchor must
/// cover. 0.5 admits the "<entity> is a staff engineer" shape (3-token
/// anchor over 6 tokens) while rejecting sentences that merely open
/// with the same couple of words. Mirrors Swift
/// `ConflictCue.wordExclusionMinAnchorFraction`.
const WORD_EXCLUSION_MIN_ANCHOR_FRACTION: f32 = 0.5;

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
    let marker_a = has_marker(&tokens_a);
    let marker_b = has_marker(&tokens_b);
    if marker_a != marker_b && claim_similarity >= BORDERLINE_THRESHOLD {
        return ConflictCueResult { kind: ConflictCueKind::MarkerRevision, score: claim_similarity };
    }

    // ── Cue 4: word exclusion ────────────────────────────────────────
    // The weakest cue — reached ONLY after cues 1-3 all declined, so
    // the three original cue outcomes stay byte-identical to the
    // pre-cue-4 screen. Guards mirror Swift exactly: negation/marker
    // asymmetry stays with cues 2/3 (declined pairs stay none rather
    // than downgrading); digit-bearing tails on BOTH sides are value
    // territory (digit-vs-digit diffs belong to ValueDivergence, and
    // the pure-digit "sarah chen 3" vs "sarah chen 7" shape is a
    // cross-ENTITY difference — the known false-positive class); the
    // shared anchor must be substantial so unrelated sentences score
    // none. See Swift `ConflictCue.evaluate` cue 4 for the full design
    // rationale.
    if negated_a == negated_b && marker_a == marker_b {
        // Shared leading token run — the subject/predicate anchor.
        let mut anchor = 0usize;
        while anchor < tokens_a.len()
            && anchor < tokens_b.len()
            && tokens_a[anchor] == tokens_b[anchor]
        {
            anchor += 1;
        }
        let tail_a = &tokens_a[anchor..];
        let tail_b = &tokens_b[anchor..];
        // Both value phrases must exist: a pure prefix/extension pair
        // ("… in paris" vs "… in paris anymore") is not an exclusion.
        if anchor >= WORD_EXCLUSION_MIN_ANCHOR_TOKENS && !tail_a.is_empty() && !tail_b.is_empty() {
            let tail_a_carries_digit =
                tail_a.iter().any(|t| t.chars().any(|c| c.is_ascii_digit()));
            let tail_b_carries_digit =
                tail_b.iter().any(|t| t.chars().any(|c| c.is_ascii_digit()));
            if !(tail_a_carries_digit && tail_b_carries_digit) {
                // Anchor overlap vs divergence: fraction of the LONGER
                // stream covered by the shared anchor, so a long
                // unmatched tail on either side dilutes it.
                let total = tokens_a.len().max(tokens_b.len());
                let anchor_fraction = anchor as f32 / total as f32;
                if anchor_fraction >= WORD_EXCLUSION_MIN_ANCHOR_FRACTION {
                    // Map the anchor fraction into the borderline band
                    // and clamp: the score can NEVER reach
                    // STRONG_THRESHOLD — "maybe?" is enforced
                    // structurally, not by tuning.
                    let raw = BORDERLINE_THRESHOLD + WORD_EXCLUSION_BAND_WIDTH * anchor_fraction;
                    let score = raw.min(WORD_EXCLUSION_CEILING);
                    return ConflictCueResult { kind: ConflictCueKind::WordExclusion, score };
                }
            }
        }
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
        // Both sides negated → same stance; and the tail is a pure
        // extension (no divergent value phrase on one side), so
        // WordExclusion must not claim it either.
        assert_eq!(
            evaluate("Bob does not live in Paris", "Bob does not live in Paris anymore").kind,
            ConflictCueKind::None
        );
        // Different word (non-value) in the same template must NOT fire
        // ValueDivergence — but it IS the word-valued exclusion class,
        // so cue 4 surfaces it as a borderline candidate for the agent.
        assert_eq!(
            evaluate("Bob lives in Paris today", "Bob lives in Rome today").kind,
            ConflictCueKind::WordExclusion
        );
        assert_eq!(evaluate("", "Bob lives in Paris").kind, ConflictCueKind::None);
    }

    // Mirrors Swift ConflictCueTests::wordExclusionCorpusClasses.
    #[test]
    fn word_exclusion_corpus_classes() {
        let pairs: &[(&str, &str)] = &[
            // employer — 6 tokens each, 4-token anchor
            ("Riley Nakamura works at Acme Robotics.",
             "Riley Nakamura works at Northwind Analytics."),
            // city — 5 tokens each, 4-token anchor
            ("Riley Nakamura lives in Lisbon.",
             "Riley Nakamura lives in Toronto."),
            // role — 6 tokens each, 3-token anchor ("a" vs "an" diverges)
            ("Riley Nakamura is a staff engineer.",
             "Riley Nakamura is an engineering manager."),
            // language — 5 tokens each, 4-token anchor
            ("Riley Nakamura primarily writes Swift.",
             "Riley Nakamura primarily writes Rust."),
        ];
        for (a, b) in pairs {
            let r = evaluate(a, b);
            assert_eq!(r.kind, ConflictCueKind::WordExclusion, "pair: {a:?} vs {b:?}");
            assert!(r.score >= BORDERLINE_THRESHOLD);
            assert!(r.score <= WORD_EXCLUSION_CEILING);
            assert!(r.score < STRONG_THRESHOLD);
        }
    }

    // Mirrors Swift ConflictCueTests::wordExclusionGuards.
    #[test]
    fn word_exclusion_guards() {
        // Digit-valued diff is ValueDivergence's lane — unchanged.
        let timeout = evaluate("the API timeout is 30 seconds", "the API timeout is 90 seconds");
        assert_eq!(timeout.kind, ConflictCueKind::ValueDivergence);

        // Cross-entity pure-digit tails — the RCA's false-positive
        // class — must stay none.
        assert_eq!(evaluate("Sarah Chen 3", "Sarah Chen 7").kind, ConflictCueKind::None);

        // Single shared leading token is not a substantial anchor.
        assert_eq!(
            evaluate("the deploy pipeline is green", "the build server is fast").kind,
            ConflictCueKind::None
        );

        // Anchor fraction below half the longer stream stays none.
        assert_eq!(
            evaluate("the team met", "the team shipped four features early today").kind,
            ConflictCueKind::None
        );

        // Asymmetric negation with low claim similarity stays none —
        // never downgrades into cue 4.
        assert_eq!(
            evaluate("Bob lives in Paris", "the deploy pipeline is not green").kind,
            ConflictCueKind::None
        );
    }

    // Mirrors Swift ConflictCueTests::wordExclusionDoesNotStealStrongerCues.
    #[test]
    fn word_exclusion_does_not_steal_stronger_cues() {
        let negated = evaluate("Riley Nakamura lives in Lisbon", "Riley Nakamura does not live in Lisbon");
        assert_eq!(negated.kind, ConflictCueKind::NegationAsymmetry);

        let marker = evaluate(
            "use the staging endpoint for uploads",
            "the staging endpoint for uploads is deprecated",
        );
        assert_eq!(marker.kind, ConflictCueKind::MarkerRevision);
    }

    // Mirrors Swift ConflictCueTests::contradictionTierClassifier.
    #[test]
    fn contradiction_tier_classifier() {
        // Tier 1 is the typed-KGFact lane, produced elsewhere — this
        // screen never emits it, so no variant maps to 1.
        assert_eq!(ConflictCueKind::ValueDivergence.contradiction_tier(), Some(3));
        assert_eq!(ConflictCueKind::NegationAsymmetry.contradiction_tier(), Some(2));
        assert_eq!(ConflictCueKind::MarkerRevision.contradiction_tier(), Some(2));
        assert_eq!(ConflictCueKind::WordExclusion.contradiction_tier(), Some(2));
        assert_eq!(ConflictCueKind::None.contradiction_tier(), None);
        // Wire-stable string, mirrored with Swift's raw value.
        assert_eq!(ConflictCueKind::WordExclusion.as_str(), "word_exclusion");
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

        // WordExclusion scores are borderline + band_width * anchor
        // fraction (anchor tokens / longer stream length), computed in
        // f32 in this exact op order in both legs. Pinned per corpus
        // class — mirrored verbatim in Swift pinnedScoreBits.
        let we_score = |anchor: usize, total: usize| -> f32 {
            (BORDERLINE_THRESHOLD + WORD_EXCLUSION_BAND_WIDTH * (anchor as f32 / total as f32))
                .min(WORD_EXCLUSION_CEILING)
        };
        // employer: anchor 4 of 6 tokens.
        let employer = evaluate(
            "Riley Nakamura works at Acme Robotics.",
            "Riley Nakamura works at Northwind Analytics.",
        );
        assert_eq!(employer.kind, ConflictCueKind::WordExclusion);
        assert_eq!(employer.score.to_bits(), we_score(4, 6).to_bits());
        // city: anchor 4 of 5 tokens.
        let city = evaluate("Riley Nakamura lives in Lisbon.", "Riley Nakamura lives in Toronto.");
        assert_eq!(city.kind, ConflictCueKind::WordExclusion);
        assert_eq!(city.score.to_bits(), we_score(4, 5).to_bits());
        // role: anchor 3 of 6 tokens ("a" vs "an" diverges at index 3).
        let role = evaluate(
            "Riley Nakamura is a staff engineer.",
            "Riley Nakamura is an engineering manager.",
        );
        assert_eq!(role.kind, ConflictCueKind::WordExclusion);
        assert_eq!(role.score.to_bits(), we_score(3, 6).to_bits());
        // language: anchor 4 of 5 tokens.
        let language = evaluate(
            "Riley Nakamura primarily writes Swift.",
            "Riley Nakamura primarily writes Rust.",
        );
        assert_eq!(language.kind, ConflictCueKind::WordExclusion);
        assert_eq!(language.score.to_bits(), we_score(4, 5).to_bits());
    }
}
