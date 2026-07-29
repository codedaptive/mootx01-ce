// token_compaction.rs
//
// The token-compaction transform (SPEC_DISTILLATION_STORAGE §7.6) and the
// token-count estimator (§6). Rust twin of TokenCompaction.swift —
// BIT-IDENTICAL output required for every input (conformance vectors in
// token_compaction_conformance.rs mirror TokenCompactionConformanceTests).
//
// Everything here is fixed-table, integer, and ASCII-case arithmetic — no
// locale, no Unicode case folding beyond the fixed decorative-punctuation
// map. See the Swift file for the full rule rationale (§5.3 priority
// order; conservative drop tables; fidelity guards).

/// The Phase 1 distillation format + pipeline contract identifier
/// (SPEC §4). Mirrors Swift `DistillationPipelineVersion.current`.
pub const DISTILLATION_PIPELINE_VERSION: &str = "p1";

/// Single-word drops (rule 2), matched against the lowercase word core.
/// MUST stay identical to Swift `TokenCompaction.stopwords`.
const STOPWORDS: &[&str] = &[
    // articles
    "a", "an", "the",
    // intensifier fillers
    "really", "very", "quite", "actually", "basically", "literally",
    "honestly", "frankly",
    // discourse
    "anyway",
    // pleasantries
    "please",
    // bare present copulas
    "is", "are", "am",
];

/// Multi-word rewrites (rule 3), longest match first at each position.
/// MUST stay identical to Swift `TokenCompaction.phrases`.
const PHRASES: &[(&[&str], &[&str])] = &[
    (&["due", "to", "the", "fact", "that"], &["because"]),
    (&["at", "this", "point", "in", "time"], &["now"]),
    (&["in", "the", "event", "that"], &["if"]),
    (&["as", "a", "result", "of"], &["because", "of"]),
    (&["with", "regard", "to"], &["regarding"]),
    (&["in", "order", "to"], &["to"]),
    (&["make", "sure", "to"], &[]),
    (&["has", "been"], &[]),
    (&["have", "been"], &[]),
    (&["had", "been"], &[]),
    (&["kind", "of"], &[]),
    (&["sort", "of"], &[]),
    (&["of", "course"], &[]),
];

fn is_clause_punct(c: char) -> bool {
    matches!(c, '.' | ',' | ';' | ':' | '!' | '?')
}

fn is_strippable_punct(c: char) -> bool {
    matches!(
        c,
        '.' | ',' | ';' | ':' | '!' | '?' | '"' | '\'' | '(' | ')' | '[' | ']'
            | '{' | '}' | '-' | '*' | '_' | '`'
    )
}

/// Apply the §7.6 transform. Pure; deterministic; Swift-bit-identical.
pub fn compact(text: &str) -> String {
    let normalized = normalize_unicode_punctuation(text);
    let tokens: Vec<&str> = normalized.split_whitespace().collect();
    if tokens.is_empty() {
        return String::new();
    }
    let cores: Vec<String> = tokens.iter().map(|t| lowercase_core(t)).collect();

    let mut out: Vec<String> = Vec::new();
    let mut i = 0;
    while i < tokens.len() {
        // Rule 3: longest phrase match at this position.
        if let Some((match_len, replacement)) = phrase_match(&cores, i) {
            let trailing = trailing_punctuation(tokens[i + match_len - 1]);
            if replacement.is_empty() {
                migrate(&trailing, &mut out);
            } else {
                let mut words: Vec<String> =
                    replacement.iter().map(|w| (*w).to_string()).collect();
                let last = words.len() - 1;
                words[last].push_str(&trailing);
                out.extend(words);
            }
            i += match_len;
            continue;
        }
        // Rule 2: single-word drop (rule 1 guards by construction — a core
        // containing a digit or uppercase never matches the lowercase table).
        if STOPWORDS.contains(&cores[i].as_str()) {
            let trailing = trailing_punctuation(tokens[i]);
            migrate(&trailing, &mut out);
            i += 1;
            continue;
        }
        out.push(tokens[i].to_string());
        i += 1;
    }

    recapitalize_sentences(&out.join(" "))
}

/// Approximate BPE token count (§6). Integer fixed-point blend:
/// est = (3*B + 16*W + 12) / 24, B = UTF-8 bytes, W = words.
/// Mirrors Swift `TokenCompaction.estimateTokenCount` exactly.
pub fn estimate_token_count(text: &str) -> i64 {
    let word_count = text.split_whitespace().count() as i64;
    if word_count == 0 {
        return 0;
    }
    let bytes = text.len() as i64;
    (3 * bytes + 16 * word_count + 12) / 24
}

/// Fixed decorative-Unicode → ASCII map (rule 4).
pub fn normalize_unicode_punctuation(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        match ch {
            '\u{2018}' | '\u{2019}' | '\u{201B}' => out.push('\''),
            '\u{201C}' | '\u{201D}' | '\u{201F}' => out.push('"'),
            '\u{2013}' | '\u{2014}' | '\u{2015}' => out.push('-'),
            '\u{2026}' => out.push_str("..."),
            '\u{00A0}' | '\u{2007}' | '\u{202F}' => out.push(' '),
            _ => out.push(ch),
        }
    }
    out
}

/// The token's word core: leading/trailing ASCII punctuation stripped,
/// ASCII letters lowercased (ASCII-only fold). Mirrors Swift
/// `lowercaseCore(of:)`.
fn lowercase_core(token: &str) -> String {
    let chars: Vec<char> = token.chars().collect();
    let mut start = 0;
    let mut end = chars.len();
    while start < end && is_strippable_punct(chars[start]) {
        start += 1;
    }
    while end > start && is_strippable_punct(chars[end - 1]) {
        end -= 1;
    }
    chars[start..end]
        .iter()
        .map(|c| {
            if c.is_ascii_uppercase() {
                c.to_ascii_lowercase()
            } else {
                *c
            }
        })
        .collect()
}

/// The token's trailing run of clause punctuation (".,;:!?").
fn trailing_punctuation(token: &str) -> String {
    let chars: Vec<char> = token.chars().collect();
    let mut idx = chars.len();
    while idx > 0 && is_clause_punct(chars[idx - 1]) {
        idx -= 1;
    }
    chars[idx..].iter().collect()
}

/// Migrate a dropped token's trailing clause punctuation onto the
/// previous emitted token — unless it already ends with clause
/// punctuation (no doubling) or there is no previous token.
fn migrate(punctuation: &str, out: &mut [String]) {
    if punctuation.is_empty() {
        return;
    }
    let Some(last) = out.last_mut() else { return };
    let Some(last_char) = last.chars().last() else { return };
    if is_clause_punct(last_char) {
        return;
    }
    last.push_str(punctuation);
}

/// Longest phrase-table match at token position `i`.
fn phrase_match(cores: &[String], i: usize) -> Option<(usize, &'static [&'static str])> {
    let mut best: Option<(usize, &'static [&'static str])> = None;
    for (pattern, replacement) in PHRASES {
        let len = pattern.len();
        if i + len > cores.len() {
            continue;
        }
        if let Some((best_len, _)) = best {
            if len <= best_len {
                continue;
            }
        }
        let matched = (0..len).all(|k| cores[i + k] == pattern[k]);
        if matched {
            best = Some((len, *replacement));
        }
    }
    best
}

/// Sentence-start recapitalization. Mirrors Swift
/// `recapitalizeSentences(_:)` exactly: a sentence start is the string
/// start or the first non-whitespace char after ".", "!", "?" followed by
/// whitespace/end (ellipsis members and in-number dots excluded); only an
/// ASCII lowercase letter at the boundary is uppercased.
pub fn recapitalize_sentences(text: &str) -> String {
    let mut scalars: Vec<char> = text.chars().collect();
    let mut at_sentence_start = true;
    for i in 0..scalars.len() {
        let s = scalars[i];
        let is_ws = s == ' ' || s == '\t' || s == '\n' || s == '\r';
        if at_sentence_start && !is_ws {
            if s.is_ascii_lowercase() {
                scalars[i] = s.to_ascii_uppercase();
            }
            at_sentence_start = false;
        }
        if s == '.' || s == '!' || s == '?' {
            let followed_by_break = i + 1 == scalars.len()
                || matches!(scalars[i + 1], ' ' | '\t' | '\n' | '\r');
            let ellipsis_member = s == '.' && i > 0 && scalars[i - 1] == '.';
            if followed_by_break && !ellipsis_member {
                at_sentence_start = true;
            }
        }
    }
    scalars.into_iter().collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    // Mirrors Swift TokenCompactionTests case-for-case (twin-parity gate).

    #[test]
    fn drops_articles_and_fillers() {
        assert_eq!(compact("the cat sat on a mat"), "Cat sat on mat");
        assert_eq!(compact("this is really very important"), "This important");
    }

    #[test]
    fn drops_bare_copulas() {
        assert_eq!(compact("my favorite color is blue"), "My favorite color blue");
    }

    #[test]
    fn negation_survives() {
        let out = compact("I really do not want the deluxe package");
        assert!(out.contains("not"));
        assert!(!out.contains("really"));
        assert_eq!(out, "I do not want deluxe package");
    }

    #[test]
    fn contracted_negation_survives() {
        assert_eq!(
            compact("She doesn't like the very loud music"),
            "She doesn't like loud music"
        );
    }

    #[test]
    fn quantifiers_survive() {
        assert_eq!(compact("all of the tests pass"), "All of tests pass");
        assert_eq!(compact("never delete the audit log"), "Never delete audit log");
    }

    #[test]
    fn numbers_and_dates_survive() {
        assert_eq!(
            compact("The meeting moved from Tuesday, March 3rd to Thursday, March 5th"),
            "Meeting moved from Tuesday, March 3rd to Thursday, March 5th"
        );
    }

    #[test]
    fn entities_survive() {
        assert_eq!(
            compact("Sarah will send out the updated calendar invites"),
            "Sarah will send out updated calendar invites"
        );
    }

    #[test]
    fn perfect_auxiliaries_compress() {
        assert_eq!(
            compact("The meeting has been moved to Thursday"),
            "Meeting moved to Thursday"
        );
    }

    #[test]
    fn verbose_rewrites() {
        assert_eq!(compact("call me in order to confirm"), "Call me to confirm");
        assert_eq!(
            compact("delayed due to the fact that the vendor slipped"),
            "Delayed because vendor slipped"
        );
        assert_eq!(
            compact("please make sure to update your travel plans"),
            "Update your travel plans"
        );
    }

    #[test]
    fn phrase_rewrite_carries_punctuation() {
        assert_eq!(compact("The invoice has been paid."), "Invoice paid.");
    }

    #[test]
    fn unicode_punctuation_normalizes() {
        assert_eq!(
            compact("the \u{201C}quoted\u{201D} value \u{2014} right"),
            "\"quoted\" value - right"
        );
        assert_eq!(compact("wait\u{2026} done"), "Wait... done");
    }

    #[test]
    fn whitespace_collapses() {
        assert_eq!(compact("one   two\n\n\nthree\t four"), "One two three four");
        assert_eq!(compact("  padded  "), "Padded");
    }

    #[test]
    fn punctuation_migrates_on_drop() {
        assert_eq!(compact("first the, second"), "First, second");
    }

    #[test]
    fn sentence_recapitalization() {
        assert_eq!(compact("the plan works. the team agrees."), "Plan works. Team agrees.");
    }

    #[test]
    fn empty_and_determinism() {
        assert_eq!(compact(""), "");
        assert_eq!(compact("   "), "");
        assert_eq!(
            compact("The quick brown fox, really."),
            compact("The quick brown fox, really.")
        );
    }

    #[test]
    fn all_stopwords_compact_to_empty() {
        assert_eq!(compact("the a an really"), "");
    }

    // Estimator (mirrors Swift TokenCountEstimateTests)

    #[test]
    fn estimator_empty_is_zero() {
        assert_eq!(estimate_token_count(""), 0);
    }

    #[test]
    fn estimator_known_values() {
        assert_eq!(estimate_token_count("Favorite color blue."), 5);
        assert_eq!(estimate_token_count("hi"), 1);
    }

    #[test]
    fn estimator_monotone_growth() {
        let short = estimate_token_count("Quarterly planning meeting moved.");
        let long = estimate_token_count(
            "Quarterly planning meeting moved Tuesday March 3 to Thursday March 5; \
             4th floor conference room under renovation.",
        );
        assert!(long > short);
        assert!(short >= 1);
    }

    #[test]
    fn estimator_utf8_bytes() {
        assert_eq!(estimate_token_count("café"), 1);
    }
}
