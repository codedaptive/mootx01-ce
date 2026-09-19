//! locomo_spec_scorer.rs — Official LoCoMo QA evaluation metrics, §1–§5.
//!
//! Source of truth: LOCOMO_OFFICIAL_PROTOCOL.md §1–§5, which verbatim-extracts
//! snap-research/locomo task_eval/{evaluation,evaluate_qa,evaluation_stats}.py.
//!
//! The scoring pipeline is entirely rule-based — no LLM judge.
//!
//! # Conformance contract
//!
//! Both this Rust file and `LoCoMoSpecScorer.swift` must produce byte-identical
//! metric values on every vector in
//! `conformance/locomo-spec/scorer_vectors.json`.
//!
//! # Algorithm source
//!
//! Porter stemmer: NLTK 3.9.2 `PorterStemmer()` in its default
//! `NLTK_EXTENSIONS` mode, which extends M.F. Porter's 1980 algorithm.
//! Normalisation and scoring: verbatim from LOCOMO_OFFICIAL_PROTOCOL.md §1–§2.

// ─────────────────────────────────────────────────────────────────────────────
// §1 Answer normalisation
// ─────────────────────────────────────────────────────────────────────────────

/// Python `string.punctuation` character set:
///   `!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~`
/// §1: `remove_punc` strips exactly this set from the lowercased string.
fn is_spec_punctuation(c: char) -> bool {
    matches!(
        c,
        '!' | '"'
        | '#'
        | '$'
        | '%'
        | '&'
        | '\''
        | '('
        | ')'
        | '*'
        | '+'
        | ','
        | '-'
        | '.'
        | '/'
        | ':'
        | ';'
        | '<'
        | '='
        | '>'
        | '?'
        | '@'
        | '['
        | '\\'
        | ']'
        | '^'
        | '_'
        | '`'
        | '{'
        | '|'
        | '}'
        | '~'
    )
}

/// Normalises a raw answer string following the verbatim pipeline in §1.
///
/// Order of operations (must be preserved):
///   1. Strip all commas from the raw string.
///   2. Lowercase.
///   3. Remove Python `string.punctuation` characters.
///   4. Remove whole-word articles: a / an / the / and.
///   5. Collapse consecutive whitespace to a single space and strip.
///
/// §1 of LOCOMO_OFFICIAL_PROTOCOL.md.
pub fn normalize_answer(s: &str) -> String {
    // Step 1: strip commas.  §1: s = s.replace(',', "")
    let no_commas: String = s.chars().filter(|&c| c != ',').collect();

    // Step 2: lowercase.  §1: lower(s)
    let lower = no_commas.to_lowercase();

    // Step 3: remove Python string.punctuation.  §1: remove_punc
    let no_punc: String = lower.chars().filter(|&c| !is_spec_punctuation(c)).collect();

    // Step 4: remove whole-word articles a / an / the / and.
    // §1: regex.sub(r'\b(a|an|the|and)\b', ' ', text)
    // After punctuation removal, words are delimited by spaces only, so
    // splitting on whitespace and filtering article tokens is equivalent.
    let articles: &[&str] = &["a", "an", "the", "and"];
    let filtered: Vec<&str> = no_punc
        .split_whitespace()
        .filter(|tok| !articles.contains(tok))
        .collect();

    // Step 5: collapse whitespace.  §1: white_space_fix — ' '.join(text.split())
    filtered.join(" ")
}

// ─────────────────────────────────────────────────────────────────────────────
// NLTK Porter stemmer (default NLTK_EXTENSIONS mode)
// ─────────────────────────────────────────────────────────────────────────────

/// Returns true when position `i` in `chars` is a vowel.
/// A vowel is a, e, i, o, u, or y when preceded by a consonant.
/// §2: classic Porter 1980 vowel definition.
fn is_vowel_at(chars: &[char], i: usize) -> bool {
    match chars[i] {
        'a' | 'e' | 'i' | 'o' | 'u' => true,
        'y' => i > 0 && !is_vowel_at(chars, i - 1),
        _ => false,
    }
}

/// Computes the measure m of chars[0..end] — the number of VC sequences.
/// §2: [C](VC)^m[V] gives measure m for a stem.
fn measure_of(chars: &[char], end: usize) -> usize {
    let mut m = 0usize;
    let mut i = 0usize;
    // Skip any leading consonants.
    while i < end && !is_vowel_at(chars, i) {
        i += 1;
    }
    while i < end {
        // Skip a vowel run.
        while i < end && is_vowel_at(chars, i) {
            i += 1;
        }
        // Skip a consonant run; each such run after a vowel run adds 1 to m.
        if i < end {
            while i < end && !is_vowel_at(chars, i) {
                i += 1;
            }
            m += 1;
        }
    }
    m
}

/// Returns true if chars[0..end] contains at least one vowel.
/// §2: *v* condition.
fn contains_vowel(chars: &[char], end: usize) -> bool {
    (0..end).any(|i| is_vowel_at(chars, i))
}

/// Returns true if chars[0..end] ends with a double consonant.
/// §2: *d condition (e.g. -TT, -SS, -MM).
fn ends_double_consonant(chars: &[char], end: usize) -> bool {
    if end < 2 {
        return false;
    }
    chars[end - 1] == chars[end - 2] && !is_vowel_at(chars, end - 1)
}

/// Returns true if chars[0..end] ends with the pattern CVC where the final
/// consonant is not W, X, or Y.
/// §2: *o condition.
fn ends_cvc(chars: &[char], end: usize) -> bool {
    // NLTK_EXTENSIONS adds a two-letter VC form to the paper's CVC rule.
    if end == 2 {
        return is_vowel_at(chars, 0) && !is_vowel_at(chars, 1);
    }
    if end < 3 {
        return false;
    }
    !is_vowel_at(chars, end - 3)
        && is_vowel_at(chars, end - 2)
        && !is_vowel_at(chars, end - 1)
        && !matches!(chars[end - 1], 'w' | 'x' | 'y')
}

/// Attempts to strip `suffix` from `chars` and replace it with `replacement`
/// if `condition(chars, stem_len)` returns true.
/// Returns true and mutates `chars` on success; otherwise leaves `chars` unchanged.
fn apply_rule<F>(chars: &mut Vec<char>, suffix: &str, replacement: &str, condition: F) -> bool
where
    F: Fn(&[char], usize) -> bool,
{
    let sfx: Vec<char> = suffix.chars().collect();
    let n = chars.len();
    let sfx_len = sfx.len();
    if n < sfx_len {
        return false;
    }
    let stem_len = n - sfx_len;
    // Fast suffix check.
    for (i, &sc) in sfx.iter().enumerate() {
        if chars[stem_len + i] != sc {
            return false;
        }
    }
    // Condition receives the chars slice (before modification) and stem_len.
    if !condition(chars, stem_len) {
        return false;
    }
    // Apply: remove suffix, append replacement.
    chars.truncate(stem_len);
    chars.extend(replacement.chars());
    true
}

fn nltk_porter_irregular(word: &str) -> Option<&'static str> {
    match word {
        "sky" | "skies" => Some("sky"),
        "dying" => Some("die"),
        "lying" => Some("lie"),
        "tying" => Some("tie"),
        "news" => Some("news"),
        "innings" | "inning" => Some("inning"),
        "outings" | "outing" => Some("outing"),
        "cannings" | "canning" => Some("canning"),
        "howe" => Some("howe"),
        "proceed" => Some("proceed"),
        "exceed" => Some("exceed"),
        "succeed" => Some("succeed"),
        _ => None,
    }
}

/// NLTK Step 2, including recursive ALLI and NLTK-only FULLI/LOGI rules.
/// A matching suffix whose condition fails ends the step, just like NLTK's
/// `_apply_rule_list`; a shorter suffix is not tried afterward.
fn apply_nltk_porter_step2(chars: &mut Vec<char>) {
    let word: String = chars.iter().collect();
    if word.ends_with("alli") {
        let stem_len = chars.len() - 4;
        if measure_of(chars, stem_len) > 0 {
            chars.truncate(stem_len);
            chars.extend("al".chars());
            apply_nltk_porter_step2(chars);
        }
        return;
    }

    let rules: &[(&str, &str)] = &[
        ("ational", "ate"), ("tional", "tion"), ("enci", "ence"),
        ("anci", "ance"), ("izer", "ize"), ("bli", "ble"),
        ("alli", "al"), ("entli", "ent"), ("eli", "e"),
        ("ousli", "ous"), ("ization", "ize"), ("ation", "ate"),
        ("ator", "ate"), ("alism", "al"), ("iveness", "ive"),
        ("fulness", "ful"), ("ousness", "ous"), ("aliti", "al"),
        ("iviti", "ive"), ("biliti", "ble"), ("fulli", "ful"),
    ];
    for &(suffix, replacement) in rules {
        if word.ends_with(suffix) {
            let _ = apply_rule(chars, suffix, replacement, |c, e| measure_of(c, e) > 0);
            return;
        }
    }
    if word.ends_with("logi") {
        // NLTK measures word[:-3], intentionally keeping `l` with the stem.
        let _ = apply_rule(chars, "logi", "log", |c, _| {
            c.len() >= 3 && measure_of(c, c.len() - 3) > 0
        });
    }
}

/// Returns the stem produced by NLTK 3.9.2 `PorterStemmer()` in its default
/// `NLTK_EXTENSIONS` mode.
///
/// §2 of LOCOMO_OFFICIAL_PROTOCOL.md: all token metrics stem with Porter.
pub fn porter_stem(word: &str) -> String {
    let lowered = word.to_lowercase();
    // NLTK checks the exception pool against the original caller spelling,
    // although all ordinary suffix steps operate on the lowercased stem.
    if let Some(irregular) = nltk_porter_irregular(word) {
        return irregular.to_string();
    }
    let mut chars: Vec<char> = lowered.chars().collect();
    if chars.len() <= 2 {
        return lowered;
    }

    // ── Step 1a ──────────────────────────────────────────────────────────────
    // Unconditional rules; first match wins.
    //   SSES → SS, IES → I, SS → SS, S → ""
    let four_letter_ies = chars.len() == 4 && chars.ends_with(&['i', 'e', 's']);
    if !apply_rule(&mut chars, "sses", "ss", |_, _| true)
        && !apply_rule(
            &mut chars,
            "ies",
            if four_letter_ies { "ie" } else { "i" },
            |_, _| true,
        )
        && !apply_rule(&mut chars, "ss", "ss", |_, _| true)
    {
        apply_rule(&mut chars, "s", "", |_, _| true);
    }

    // ── Step 1b ──────────────────────────────────────────────────────────────
    // (m>0) EED→EE; (*v*) ED→""; (*v*) ING→""
    let mut step1b_applied = false;
    let step1b_word: String = chars.iter().collect();
    if step1b_word.ends_with("ied") {
        let replacement = if chars.len() == 4 { "ie" } else { "i" };
        chars.truncate(chars.len() - 3);
        chars.extend(replacement.chars());
    } else if step1b_word.ends_with("eed") {
        // A failed EED measure ends the step; do not reconsider it as ED.
        let _ = apply_rule(&mut chars, "eed", "ee", |c, e| measure_of(c, e) > 0);
    } else if step1b_word.ends_with("ed") {
        step1b_applied = apply_rule(&mut chars, "ed", "", |c, e| contains_vowel(c, e));
    } else if step1b_word.ends_with("ing") {
        step1b_applied = apply_rule(&mut chars, "ing", "", |c, e| contains_vowel(c, e));
    }

    if step1b_applied {
        // Follow-up after ED or ING removal.
        let n_before = chars.len();
        let applied_follow =
            apply_rule(&mut chars, "at", "ate", |_, _| true)
            || apply_rule(&mut chars, "bl", "ble", |_, _| true)
            || apply_rule(&mut chars, "iz", "ize", |_, _| true);
        if !applied_follow && chars.len() == n_before {
            let end = chars.len();
            let last = chars.last().copied().unwrap_or('_');
            if ends_double_consonant(&chars, end) && last != 'l' && last != 's' && last != 'z' {
                // Reduce double consonant to single.
                chars.pop();
            } else if measure_of(&chars, end) == 1 && ends_cvc(&chars, end) {
                // (m=1 and *o): append E.
                chars.push('e');
            }
        }
    }

    // ── Step 1c ──────────────────────────────────────────────────────────────
    // NLTK: (*c and not c) Y → I. Thus fly→fli, enjoy→enjoy.
    apply_rule(&mut chars, "y", "i", |c, e| {
        e > 1 && !is_vowel_at(c, e - 1)
    });

    // ── Step 2 ───────────────────────────────────────────────────────────────
    // (m>0) Long-suffix mappings; first match wins.
    apply_nltk_porter_step2(&mut chars);

    // ── Step 3 ───────────────────────────────────────────────────────────────
    // (m>0) Moderately-long suffix mappings.
    let step3_rules: &[(&str, &str)] = &[
        ("icate", "ic"),
        ("ative", ""),
        ("alize", "al"),
        ("iciti", "ic"),
        ("ical",  "ic"),
        ("ful",   ""),
        ("ness",  ""),
    ];
    let step3_word: String = chars.iter().collect();
    for &(suffix, replacement) in step3_rules {
        if step3_word.ends_with(suffix) {
            let _ = apply_rule(&mut chars, suffix, replacement, |c, e| measure_of(c, e) > 0);
            break;
        }
    }

    // ── Step 4 ───────────────────────────────────────────────────────────────
    // (m>1) Short-suffix removal; ION also requires *S or *T.
    // Using a macro-less approach: a helper closure for the common m>1 condition.
    let step4_rules = [
        "al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement", "ment",
        "ent", "ion", "ou", "ism", "ate", "iti", "ous", "ive", "ize",
    ];
    let step4_word: String = chars.iter().collect();
    for suffix in step4_rules {
        if step4_word.ends_with(suffix) {
            if suffix == "ion" {
                let _ = apply_rule(&mut chars, suffix, "", |c, e| {
                    measure_of(c, e) > 1 && e > 0 && matches!(c[e - 1], 's' | 't')
                });
            } else {
                let _ = apply_rule(&mut chars, suffix, "", |c, e| measure_of(c, e) > 1);
            }
            break;
        }
    }

    // ── Step 5a ──────────────────────────────────────────────────────────────
    // Remove final E when (m>1) or (m=1 and not *o).
    let end5a = chars.len();
    if end5a > 0 && *chars.last().unwrap() == 'e' {
        let stem_len = end5a - 1;
        let m = measure_of(&chars, stem_len);
        if m > 1 || (m == 1 && !ends_cvc(&chars, stem_len)) {
            chars.pop();
        }
    }

    // ── Step 5b ──────────────────────────────────────────────────────────────
    // (m>1 and *d and *L): reduce final double-L to single L.
    let end5b = chars.len();
    if measure_of(&chars, end5b) > 1
        && ends_double_consonant(&chars, end5b)
        && chars.last() == Some(&'l')
    {
        chars.pop();
    }

    chars.iter().collect()
}

// ─────────────────────────────────────────────────────────────────────────────
// §2 Token metrics
// ─────────────────────────────────────────────────────────────────────────────

/// Tokenises a string into Porter-stemmed tokens of its normalised form.
/// §2: `prediction_tokens = [ps.stem(w) for w in normalize_answer(prediction).split()]`
fn stemmed_tokens(s: &str) -> Vec<String> {
    normalize_answer(s)
        .split_whitespace()
        .map(|w| porter_stem(w))
        .collect()
}

/// Computes the token-level F1 score between a prediction and a single gold answer.
///
/// Uses Porter-stemmed tokens of the normalised strings. Precision and recall
/// are computed over the multiset intersection (Counter & in Python).
/// Returns 0.0 when the intersection is empty.
///
/// §2 of LOCOMO_OFFICIAL_PROTOCOL.md: f1_score(prediction, ground_truth).
pub fn f1_score(prediction: &str, gold_answer: &str) -> f64 {
    let pred_tokens = stemmed_tokens(prediction);
    let gold_tokens = stemmed_tokens(gold_answer);

    // Multiset intersection via count maps.
    let mut pred_counts = std::collections::HashMap::<&str, usize>::new();
    for t in pred_tokens.iter() {
        *pred_counts.entry(t.as_str()).or_insert(0) += 1;
    }
    let mut gold_counts = std::collections::HashMap::<&str, usize>::new();
    for t in gold_tokens.iter() {
        *gold_counts.entry(t.as_str()).or_insert(0) += 1;
    }

    let mut num_same = 0usize;
    for (tok, &pred_count) in &pred_counts {
        if let Some(&gold_count) = gold_counts.get(tok) {
            num_same += pred_count.min(gold_count);
        }
    }

    if num_same == 0 {
        return 0.0;
    }
    let precision = num_same as f64 / pred_tokens.len() as f64;
    let recall    = num_same as f64 / gold_tokens.len() as f64;
    (2.0 * precision * recall) / (precision + recall)
}

/// Computes the multi-answer F1 for category-1 questions.
///
/// Both prediction and gold are split on commas. The score is the mean over
/// gold parts of the maximum F1 of any prediction part against that gold part.
///
/// §2 of LOCOMO_OFFICIAL_PROTOCOL.md:
///   `np.mean([max([f1_score(p, gt) for p in predictions]) for gt in ground_truths])`
pub fn multi_answer_f1(prediction: &str, gold_answer: &str) -> f64 {
    let predictions: Vec<&str> = prediction.split(',').map(str::trim).collect();
    let ground_truths: Vec<&str> = gold_answer.split(',').map(str::trim).collect();

    if ground_truths.is_empty() {
        return 0.0;
    }

    let per_gold: Vec<f64> = ground_truths
        .iter()
        .map(|gt| {
            predictions
                .iter()
                .map(|p| f1_score(p, gt))
                .fold(f64::NEG_INFINITY, f64::max)
                .max(0.0)
        })
        .collect();

    per_gold.iter().sum::<f64>() / per_gold.len() as f64
}

/// Computes order-independent exact match over normalised token SETS.
///
/// Returns 1.0 when the normalised token sets are equal, 0.0 otherwise.
///
/// §2 of LOCOMO_OFFICIAL_PROTOCOL.md:
///   `set(prediction.split()) == set(ground_truth.split())`
pub fn exact_match(prediction: &str, gold_answer: &str) -> f64 {
    let pred_set: std::collections::HashSet<String> = normalize_answer(prediction)
        .split_whitespace()
        .map(str::to_string)
        .collect();
    let gold_set: std::collections::HashSet<String> = normalize_answer(gold_answer)
        .split_whitespace()
        .map(str::to_string)
        .collect();
    if pred_set == gold_set { 1.0 } else { 0.0 }
}

/// Computes the ROUGE-1 F-score (unigram F) over stemmed normalised tokens.
///
/// Identical to `f1_score` — the official LoCoMo code uses `scores["rouge-1"]["f"]`
/// from the rouge library, which equals token-level F1 on stemmed normalised strings.
/// Implemented as a separate public function for API clarity.
///
/// §2 of LOCOMO_OFFICIAL_PROTOCOL.md.
pub fn rouge1_f(prediction: &str, gold_answer: &str) -> f64 {
    f1_score(prediction, gold_answer)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3 Per-question scoring
// ─────────────────────────────────────────────────────────────────────────────

/// Scores one question given its category, prediction, and gold answer.
///
/// Category routing (§3 of LOCOMO_OFFICIAL_PROTOCOL.md):
///   - Categories 2, 3, 4 → f1_score (category-3 gold truncated at first ';').
///   - Category 1          → multi_answer_f1.
///   - Category 5          → binary: 1.0 iff prediction contains
///       "no information available" or "not mentioned" (case-insensitive).
///   - Any other category  → Err with the invalid category value.
///
/// Returns Ok(score ∈ [0.0, 1.0]) or Err on invalid category.
pub fn score_question(
    category: u8,
    prediction: &str,
    gold_answer: &str,
) -> Result<f64, String> {
    match category {
        2 | 4 => Ok(f1_score(prediction, gold_answer)),

        3 => {
            // §3: category 3 (temporal) — gold answer truncated at first ';'.
            // answer = answer.split(';')[0].strip()
            let truncated = gold_answer
                .splitn(2, ';')
                .next()
                .map(str::trim)
                .unwrap_or(gold_answer);
            Ok(f1_score(prediction, truncated))
        }

        1 => Ok(multi_answer_f1(prediction, gold_answer)),

        5 => {
            // §3: category 5 — binary abstention check (case-insensitive).
            let lower = prediction.to_lowercase();
            Ok(if lower.contains("no information available") || lower.contains("not mentioned") {
                1.0
            } else {
                0.0
            })
        }

        _ => Err(format!("invalid LoCoMo category: {category}")),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4 Evidence recall
// ─────────────────────────────────────────────────────────────────────────────

/// Computes evidence recall for one question.
///
/// `context` is `None` when the context key is absent from the question record.
/// `evidence` is the ground-truth evidence identifier list.
///
/// Two official forms (§4 of LOCOMO_OFFICIAL_PROTOCOL.md):
///   - **Session form** (context entries start with 'S'):
///     Evidence item "D3:12" counts if session "3" is in the context session set.
///   - **Dia form**: evidence item counts if it appears verbatim in the context list.
///
/// No context field or empty evidence → 1.0.
pub fn evidence_recall(context: Option<&[String]>, evidence: &[String]) -> f64 {
    // §4: no context or no evidence → recall 1.
    let ctx = match context {
        Some(c) if !evidence.is_empty() => c,
        _ => return 1.0,
    };

    if ctx.first().map(|s| s.starts_with('S')).unwrap_or(false) {
        // Session form: sessions = [e[1:] for e in ctx]
        let sessions: std::collections::HashSet<&str> =
            ctx.iter().map(|s| &s[1..]).collect();
        let matched = evidence.iter().filter(|ev| {
            // ev.split(':')[0][1:] → session number.
            let session_part = ev.splitn(2, ':').next().unwrap_or("");
            let session = if session_part.len() > 1 { &session_part[1..] } else { "" };
            sessions.contains(session)
        }).count();
        matched as f64 / evidence.len() as f64
    } else {
        // Dia form: direct membership.
        let ctx_set: std::collections::HashSet<&str> =
            ctx.iter().map(String::as_str).collect();
        let matched = evidence.iter().filter(|ev| ctx_set.contains(ev.as_str())).count();
        matched as f64 / evidence.len() as f64
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5 Aggregation
// ─────────────────────────────────────────────────────────────────────────────

/// Per-category accuracy and recall metrics.
/// Twin of Swift `LoCoMoSpecCategoryMetrics`.
#[derive(Debug, Clone)]
pub struct LoCoMoSpecCategoryMetrics {
    /// Integer category (1–5).
    pub category: u8,
    /// Mean score rounded to 3 decimal places.
    /// §5: round(acc_counts[k] / total_counts[k], 3)
    pub accuracy: f64,
    /// Number of questions in this category.
    pub question_count: usize,
    /// Mean evidence recall rounded to 3 decimal places.
    pub mean_recall: f64,
}

/// Full §5 aggregate result.
/// Twin of Swift `LoCoMoSpecAggregate`.
#[derive(Debug)]
pub struct LoCoMoSpecAggregate {
    /// Overall accuracy, rounded to 3 decimals.
    pub overall: f64,
    /// Total question count.
    pub total_questions: usize,
    /// Per-category metrics in order [4, 1, 2, 3, 5].
    /// §5: "reported in category order [4, 1, 2, 3, 5]"
    pub by_category: Vec<LoCoMoSpecCategoryMetrics>,
    /// Overall mean evidence recall, rounded to 3 decimals.
    pub overall_mean_recall: f64,
}

/// Rounds to 3 decimal places (round-half-away-from-zero, via Rust f64::round).
/// §5: round(x, 3) in Python.
fn round3(x: f64) -> f64 {
    (x * 1000.0).round() / 1000.0
}

/// Aggregates per-question scores and evidence recalls into §5 summary metrics.
///
/// Input is a slice of `(category, score, evidence_recall)` triples.
///
/// §5 of LOCOMO_OFFICIAL_PROTOCOL.md:
///   acc_counts[category] += score
///   accuracy = round(acc_counts[k] / total_counts[k], 3)
///   overall  = round(total_correct / total_questions, 3)
///   category order: [4, 1, 2, 3, 5]
pub fn locomo_spec_aggregate(scores: &[(u8, f64, f64)]) -> LoCoMoSpecAggregate {
    let mut acc_counts    = std::collections::HashMap::<u8, f64>::new();
    let mut total_counts  = std::collections::HashMap::<u8, usize>::new();
    let mut recall_sums   = std::collections::HashMap::<u8, f64>::new();

    for &(cat, score, recall) in scores {
        *acc_counts.entry(cat).or_insert(0.0)   += score;
        *total_counts.entry(cat).or_insert(0)   += 1;
        *recall_sums.entry(cat).or_insert(0.0)  += recall;
    }

    // §5: category order [4, 1, 2, 3, 5].
    let category_order: &[u8] = &[4, 1, 2, 3, 5];
    let by_category: Vec<LoCoMoSpecCategoryMetrics> = category_order
        .iter()
        .map(|&cat| {
            let count = *total_counts.get(&cat).unwrap_or(&0);
            let acc = if count > 0 {
                round3(acc_counts.get(&cat).copied().unwrap_or(0.0) / count as f64)
            } else {
                0.0
            };
            let rec = if count > 0 {
                round3(recall_sums.get(&cat).copied().unwrap_or(0.0) / count as f64)
            } else {
                0.0
            };
            LoCoMoSpecCategoryMetrics {
                category: cat,
                accuracy: acc,
                question_count: count,
                mean_recall: rec,
            }
        })
        .collect();

    let total_score: f64    = acc_counts.values().sum();
    let total_questions: usize = total_counts.values().sum();
    let overall = if total_questions > 0 {
        round3(total_score / total_questions as f64)
    } else {
        0.0
    };

    let total_recall: f64 = recall_sums.values().sum();
    let overall_mean_recall = if total_questions > 0 {
        round3(total_recall / total_questions as f64)
    } else {
        0.0
    };

    LoCoMoSpecAggregate {
        overall,
        total_questions,
        by_category,
        overall_mean_recall,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── normalize_answer ─────────────────────────────────────────────────────

    /// Empty string normalises to empty string.
    #[test]
    fn normalize_empty() {
        assert_eq!(normalize_answer(""), "");
    }

    /// Comma stripping, lowercasing, punctuation removal, and whitespace collapse.
    #[test]
    fn normalize_punctuation_and_case() {
        assert_eq!(normalize_answer("Hello, World!"), "hello world");
    }

    /// Whole-word article removal: "a", "an", "the", "and".
    #[test]
    fn normalize_removes_articles() {
        assert_eq!(normalize_answer("a dog and a cat"), "dog cat");
    }

    /// "the" removed as whole word; surrounding words preserved.
    #[test]
    fn normalize_the_quick_brown_fox() {
        assert_eq!(normalize_answer("The quick brown fox"), "quick brown fox");
    }

    // ── porter_stem ──────────────────────────────────────────────────────────

    /// Short words (≤2 chars) are returned unchanged.
    #[test]
    fn stem_short_words_unchanged() {
        assert_eq!(porter_stem(""), "");
        assert_eq!(porter_stem("a"),  "a");
        assert_eq!(porter_stem("in"), "in");
    }

    /// Step 1a: SSES → SS (caresses → caress).
    #[test]
    fn stem_step1a_sses() {
        assert_eq!(porter_stem("caresses"), "caress");
    }

    /// Step 1a with NLTK_EXTENSIONS: four-letter IES → IE.
    #[test]
    fn stem_step1a_ies() {
        assert_eq!(porter_stem("ponies"), "poni");
        assert_eq!(porter_stem("ties"),   "tie");
    }

    /// Step 1a: S → "" (cats → cat).
    #[test]
    fn stem_step1a_s() {
        assert_eq!(porter_stem("cats"), "cat");
    }

    /// Step 1b: (*v*) ING removed, then double-consonant reduction (running → run).
    #[test]
    fn stem_step1b_ing_double_consonant() {
        assert_eq!(porter_stem("running"),  "run");
        assert_eq!(porter_stem("stemming"), "stem");
    }

    /// Step 1b: (*v*) ING removed, no follow-up needed (jumping → jump).
    #[test]
    fn stem_step1b_ing_no_followup() {
        assert_eq!(porter_stem("jumping"), "jump");
    }

    /// Step 1b: (*v*) ED removed, then double-consonant reduction (stemmed → stem).
    #[test]
    fn stem_step1b_ed_double_consonant() {
        assert_eq!(porter_stem("stemmed"), "stem");
    }

    // ── f1_score ─────────────────────────────────────────────────────────────

    /// Identical normalised stems give F1 = 1.0.
    #[test]
    fn f1_identical() {
        assert_eq!(f1_score("cat", "cat"), 1.0);
    }

    /// Stemming unifies "cats" and "cat" → F1 = 1.0.
    #[test]
    fn f1_stems_match() {
        assert_eq!(f1_score("cats", "cat"), 1.0);
    }

    /// Completely disjoint tokens → F1 = 0.0.
    #[test]
    fn f1_no_overlap() {
        assert_eq!(f1_score("hello", "world"), 0.0);
    }

    /// Partial overlap: prediction has extra token.
    /// pred = "hello world" → stems ["hello","world"]
    /// gold = "world"       → stems ["world"]
    /// intersection = {"world":1}, precision=0.5, recall=1.0, F1=2/3
    #[test]
    fn f1_partial_overlap() {
        let f1 = f1_score("hello world", "world");
        let expected = 2.0 / 3.0;
        assert!((f1 - expected).abs() < 1e-9, "expected {expected}, got {f1}");
    }

    // ── multi_answer_f1 ──────────────────────────────────────────────────────

    /// Category-1 multi-answer: prediction "cat, dog", gold "cat, feline".
    /// gold-"cat": max(f1("cat","cat"), f1("dog","cat")) = max(1.0,0.0) = 1.0
    /// gold-"feline": max(f1("cat","feline"), f1("dog","feline")) = 0.0
    /// mean = 0.5
    #[test]
    fn multi_answer_f1_partial() {
        let score = multi_answer_f1("cat, dog", "cat, feline");
        assert!((score - 0.5).abs() < 1e-9, "expected 0.5, got {score}");
    }

    /// Perfect multi-answer match.
    #[test]
    fn multi_answer_f1_perfect() {
        let score = multi_answer_f1("cat, dog", "cat, dog");
        assert!((score - 1.0).abs() < 1e-9, "expected 1.0, got {score}");
    }

    // ── exact_match ──────────────────────────────────────────────────────────

    /// Normalisation unifies "the cat" and "cat" → set {"cat"} == {"cat"} → 1.0.
    #[test]
    fn exact_match_article_stripped() {
        assert_eq!(exact_match("the cat", "cat"), 1.0);
    }

    /// Order-independent: "cat sat" and "sat cat" → equal sets → 1.0.
    #[test]
    fn exact_match_order_independent() {
        assert_eq!(exact_match("cat sat", "sat cat"), 1.0);
    }

    /// Completely different tokens → 0.0.
    #[test]
    fn exact_match_different() {
        assert_eq!(exact_match("hello", "world"), 0.0);
    }

    // ── score_question ────────────────────────────────────────────────────────

    /// Category 5 abstention: "no information available" → 1.0.
    #[test]
    fn score_q_cat5_abstain() {
        assert_eq!(score_question(5, "No information available here.", "anything").unwrap(), 1.0);
    }

    /// Category 5 non-abstention → 0.0.
    #[test]
    fn score_q_cat5_no_abstain() {
        assert_eq!(score_question(5, "The answer is 42.", "anything").unwrap(), 0.0);
    }

    /// Category 3: gold truncated at first ';'.
    /// gold = "2020; other" → truncated = "2020" → f1("2020","2020")=1.0
    #[test]
    fn score_q_cat3_truncates_gold() {
        assert_eq!(score_question(3, "2020", "2020; other data").unwrap(), 1.0);
    }

    /// Invalid category returns Err.
    #[test]
    fn score_q_invalid_category() {
        assert!(score_question(6, "pred", "gold").is_err());
    }

    // ── evidence_recall ───────────────────────────────────────────────────────

    /// No context field → recall 1.0.
    #[test]
    fn recall_no_context() {
        assert_eq!(evidence_recall(None, &["D1:1".to_string()]), 1.0);
    }

    /// Empty evidence → recall 1.0.
    #[test]
    fn recall_empty_evidence() {
        assert_eq!(evidence_recall(Some(&["S1".to_string()]), &[]), 1.0);
    }

    /// Session form: both evidence items' session numbers present → recall 1.0.
    #[test]
    fn recall_session_form_full() {
        let ctx = vec!["S3".to_string(), "S1".to_string()];
        let ev  = vec!["D3:5".to_string(), "D1:2".to_string()];
        assert_eq!(evidence_recall(Some(&ctx), &ev), 1.0);
    }

    /// Session form: only one of two evidence items' session found → recall 0.5.
    #[test]
    fn recall_session_form_half() {
        let ctx = vec!["S3".to_string()];
        let ev  = vec!["D3:5".to_string(), "D1:2".to_string()];
        assert_eq!(evidence_recall(Some(&ctx), &ev), 0.5);
    }

    /// Dia form: direct membership; one of two matches → recall 0.5.
    #[test]
    fn recall_dia_form_half() {
        let ctx = vec!["D3:5".to_string(), "D2:1".to_string()];
        let ev  = vec!["D3:5".to_string(), "D1:2".to_string()];
        assert_eq!(evidence_recall(Some(&ctx), &ev), 0.5);
    }

    // ── aggregate ─────────────────────────────────────────────────────────────

    /// Two category-4 questions with scores 1.0 and 0.0 → category-4 accuracy 0.5.
    /// One category-2 question with score 1.0 → overall (1.0+0.0+1.0)/3 ≈ 0.667.
    #[test]
    fn aggregate_basic() {
        let scores = vec![
            (4u8, 1.0f64, 1.0f64),
            (4u8, 0.0f64, 0.0f64),
            (2u8, 1.0f64, 1.0f64),
        ];
        let result = locomo_spec_aggregate(&scores);
        assert_eq!(result.total_questions, 3);
        // Category 4: (1.0+0.0)/2 = 0.5
        let cat4 = result.by_category.iter().find(|c| c.category == 4).unwrap();
        assert_eq!(cat4.accuracy, 0.5);
        // Overall: (1.0+0.0+1.0)/3 = 0.667 (rounded)
        let expected_overall = round3(2.0 / 3.0);
        assert_eq!(result.overall, expected_overall);
    }

    /// Category order in by_category is [4, 1, 2, 3, 5] per §5.
    #[test]
    fn aggregate_category_order() {
        let scores = vec![
            (1u8, 1.0, 1.0),
            (2u8, 1.0, 1.0),
            (3u8, 1.0, 1.0),
            (4u8, 1.0, 1.0),
            (5u8, 1.0, 1.0),
        ];
        let result = locomo_spec_aggregate(&scores);
        let order: Vec<u8> = result.by_category.iter().map(|c| c.category).collect();
        assert_eq!(order, vec![4, 1, 2, 3, 5]);
    }
}
