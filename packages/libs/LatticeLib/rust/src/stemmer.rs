// stemmer.rs — Snowball English stemmer (Porter2)
//
// Port of Stemmer.swift, which is a hand-port of the canonical Snowball-language
// source at https://snowballstem.org/algorithms/english/stemmer.html.
//
// This Rust implementation is a direct, line-by-line translation of the Swift
// hand-port. It does NOT use the `rust-stemmers` crate or any other off-the-shelf
// stemmer crate. The reason: the conformance contract requires bit-identical stems
// to the Swift engine, which is itself a hand-port. Any crate that diverges on even
// one corpus vector would break the contract. The algorithm is hand-ported from the
// same canonical Snowball source as the Swift version, so the two legs agree by
// construction. Verification is the SnowballEnglish.json reference corpus.
//
// ALGORITHM OVERVIEW (same as Swift)
//   Pre-processing: leading apostrophe drop; consonant-Y marking (→ 'Y')
//   R1/R2 region computation with "gener"/"commun"/"arsen" special cases
//   Step 0:  possessive endings ('s', 's', ')
//   Step 1a: plurals and possessives
//   Step 1b: past-tense and gerund endings
//   Step 1c: terminal Y → i
//   Step 2:  common derivational suffixes
//   Step 3:  other derivational suffixes
//   Step 4:  residual long suffixes (R2)
//   Step 5:  final cleanup (terminal e, doubled l)
//   Post-processing: restore 'Y' marker → 'y'
//   Exception 0 (before all steps): irregular forms
//   Exception 2 (after step 1a): invariant-after-step-1a words

use std::collections::HashMap;

/// Stem an English word using the Snowball Porter2 algorithm.
/// Returns the stem (lowercased). Deterministic: no random or time-dependent
/// components. Mirrors `Stemmer.stem` in Swift.
pub fn stem(token: &str) -> String {
    if token.is_empty() {
        return token.to_owned();
    }

    // Snowball spec: words of fewer than 3 letters are returned unchanged.
    if token.chars().count() < 3 {
        return token.to_owned();
    }

    // Lowercase.
    let lowered: String = token.to_lowercase();
    let mut w: Vec<char> = lowered.chars().collect();

    // Exception 0: irregular forms handled before any suffix removal.
    let s: String = w.iter().collect();
    if let Some(exc) = irregular_exceptions().get(s.as_str()) {
        return exc.to_string();
    }

    // Pre-processing: leading apostrophe and consonant-Y marking.
    w = preprocess(w);

    // Compute R1 and R2.
    let r1 = compute_r1(&w);
    let r2 = compute_r2(&w, r1);

    // Apply each step.
    w = step0(w);
    w = step1a(w);

    // Exception 2: invariant after step 1a.
    let s: String = w.iter().collect();
    if invariant_after_step1a().contains(&s.as_str()) {
        return s;
    }

    w = step1b(w, r1);
    w = step1c(w);
    w = step2(w, r1);
    w = step3(w, r1, r2);
    w = step4(w, r2);
    w = step5(w, r1, r2);

    // Restore 'Y' marker → 'y'.
    let result: String = w.iter().collect();
    result.replace('Y', "y")
}

// ---------------------------------------------------------------------------
// Vowel helpers
// ---------------------------------------------------------------------------

/// Snowball treats 'y' as a vowel when preceded by a consonant.
/// The preprocess pass marks such Ys with uppercase 'Y' so the algorithm
/// treats them uniformly as vowels in region computation.
fn is_vowel(c: char) -> bool {
    matches!(c, 'a' | 'e' | 'i' | 'o' | 'u' | 'y' | 'Y')
}

/// Pre-process: drop leading apostrophe; mark consonant-Y patterns with 'Y'.
fn preprocess(mut chars: Vec<char>) -> Vec<char> {
    if chars.first() == Some(&'\'') {
        chars.remove(0);
    }
    if chars.first() == Some(&'y') {
        chars[0] = 'Y';
    }
    let len = chars.len();
    for i in 1..len {
        if chars[i] == 'y' && !is_vowel(chars[i - 1]) {
            chars[i] = 'Y';
        }
    }
    chars
}

/// R1 is the region after the first non-vowel following a vowel, or the end of
/// the word if no such position exists. Special-cases "gener", "commun", "arsen".
fn compute_r1(chars: &[char]) -> usize {
    let s: String = chars.iter().collect();
    for prefix in &["gener", "commun", "arsen"] {
        if s.starts_with(prefix) {
            return prefix.len();
        }
    }
    region_start(chars, 0)
}

/// R2 is the region after the first non-vowel following a vowel within R1.
fn compute_r2(chars: &[char], r1: usize) -> usize {
    region_start(chars, r1)
}

fn region_start(chars: &[char], from: usize) -> usize {
    if from >= chars.len() {
        return chars.len();
    }
    let mut i = from;
    // Find a vowel.
    while i < chars.len() && !is_vowel(chars[i]) {
        i += 1;
    }
    // Find a non-vowel after it.
    while i < chars.len() && is_vowel(chars[i]) {
        i += 1;
    }
    if i < chars.len() {
        i + 1
    } else {
        chars.len()
    }
}

// ---------------------------------------------------------------------------
// Suffix helpers
// ---------------------------------------------------------------------------

fn ends_with(chars: &[char], suffix: &str) -> bool {
    let s_chars: Vec<char> = suffix.chars().collect();
    if s_chars.len() > chars.len() {
        return false;
    }
    let offset = chars.len() - s_chars.len();
    for (i, &sc) in s_chars.iter().enumerate() {
        if chars[offset + i] != sc {
            return false;
        }
    }
    true
}

fn replace_suffix(mut chars: Vec<char>, suffix: &str, replacement: &str) -> Vec<char> {
    let count = suffix.chars().count();
    chars.truncate(chars.len() - count);
    chars.extend(replacement.chars());
    chars
}

fn suffix_in_region(chars: &[char], suffix: &str, region: usize) -> bool {
    if !ends_with(chars, suffix) {
        return false;
    }
    chars.len() - suffix.chars().count() >= region
}

// ---------------------------------------------------------------------------
// Steps
// ---------------------------------------------------------------------------

/// Step 0: drop possessive endings.
fn step0(chars: Vec<char>) -> Vec<char> {
    for suffix in &["'s'", "'s", "'"] {
        if ends_with(&chars, suffix) {
            let count = suffix.chars().count();
            let mut w = chars;
            w.truncate(w.len() - count);
            return w;
        }
    }
    chars
}

/// Step 1a: handle plural and possessive endings.
fn step1a(chars: Vec<char>) -> Vec<char> {
    if ends_with(&chars, "sses") {
        return replace_suffix(chars, "sses", "ss");
    }
    if ends_with(&chars, "ied") || ends_with(&chars, "ies") {
        let suffix = if ends_with(&chars, "ied") { "ied" } else { "ies" };
        // "ied" / "ies" of length > 4 becomes -i, else -ie.
        if chars.len() > suffix.len() + 1 {
            return replace_suffix(chars, suffix, "i");
        }
        return replace_suffix(chars, suffix, "ie");
    }
    if ends_with(&chars, "ss") || ends_with(&chars, "us") {
        return chars;
    }
    if ends_with(&chars, "s") {
        // Drop s only if the word contains a vowel before the last letter.
        if chars.len() >= 3 {
            let prefix = &chars[..chars.len() - 2];
            if prefix.iter().any(|&c| is_vowel(c)) {
                let mut w = chars;
                w.pop();
                return w;
            }
        }
    }
    chars
}

/// Step 1b: handle past tense and gerund endings.
fn step1b(chars: Vec<char>, r1: usize) -> Vec<char> {
    // eedly / eed preempts ed/ing: even if NOT in R1, word is left unchanged.
    if ends_with(&chars, "eedly") {
        if chars.len() - 5 >= r1 {
            return replace_suffix(chars, "eedly", "ee");
        }
        return chars;
    }
    if ends_with(&chars, "eed") {
        if chars.len() - 3 >= r1 {
            return replace_suffix(chars, "eed", "ee");
        }
        return chars;
    }

    for suffix in &["ingly", "edly", "ing", "ed"] {
        if ends_with(&chars, suffix) {
            let stem_len = chars.len() - suffix.len();
            let stem: Vec<char> = chars[..stem_len].to_vec();
            if stem.iter().any(|&c| is_vowel(c)) {
                let mut w = stem;
                if w.len() >= 2 {
                    let last2: String = w.iter().rev().take(2).collect::<String>().chars().rev().collect();
                    if last2 == "at" || last2 == "bl" || last2 == "iz" {
                        w.push('e');
                        return w;
                    }
                    if is_double_consonant(&w) {
                        w.pop();
                        return w;
                    }
                }
                if is_short_word(&w) {
                    w.push('e');
                }
                return w;
            }
            return chars;
        }
    }
    chars
}

/// Step 1c: terminal Y → i if preceded by a consonant, word >= 3 chars.
fn step1c(mut chars: Vec<char>) -> Vec<char> {
    if chars.len() < 3 {
        return chars;
    }
    let last = *chars.last().unwrap();
    if last == 'y' || last == 'Y' {
        let prev = chars[chars.len() - 2];
        if !is_vowel(prev) {
            let len = chars.len();
            chars[len - 1] = 'i';
        }
    }
    chars
}

/// Step 2: common derivational suffixes.
fn step2_rules() -> &'static [(&'static str, &'static str)] {
    &[
        ("ational", "ate"), ("tional", "tion"), ("enci", "ence"),
        ("anci", "ance"), ("abli", "able"), ("entli", "ent"),
        ("izer", "ize"), ("ization", "ize"), ("ation", "ate"),
        ("ator", "ate"), ("alism", "al"), ("aliti", "al"),
        ("alli", "al"), ("fulness", "ful"), ("ousli", "ous"),
        ("ousness", "ous"), ("iveness", "ive"), ("iviti", "ive"),
        ("biliti", "ble"), ("bli", "ble"), ("ogi", "og"),
        ("fulli", "ful"), ("lessli", "less"),
    ]
}

fn step2(chars: Vec<char>, r1: usize) -> Vec<char> {
    // Special: "logi" rule requires preceding "l".
    if suffix_in_region(&chars, "logi", r1) {
        if chars.len() >= 5 && chars[chars.len() - 5] == 'l' {
            return replace_suffix(chars, "logi", "log");
        }
    }
    // Special: "li" rule requires preceding valid li-ending.
    if suffix_in_region(&chars, "li", r1) {
        if chars.len() >= 3 {
            let prev = chars[chars.len() - 3];
            if "cdeghkmnrt".contains(prev) {
                let mut w = chars;
                w.truncate(w.len() - 2);
                return w;
            }
        }
    }
    for &(suffix, replacement) in step2_rules() {
        if suffix_in_region(&chars, suffix, r1) {
            return replace_suffix(chars, suffix, replacement);
        }
    }
    chars
}

/// Step 3: other derivational suffixes.
fn step3_rules() -> &'static [(&'static str, &'static str)] {
    &[
        ("ational", "ate"), ("tional", "tion"), ("alize", "al"),
        ("icate", "ic"), ("iciti", "ic"), ("ical", "ic"),
        ("ful", ""), ("ness", ""),
    ]
}

fn step3(chars: Vec<char>, r1: usize, r2: usize) -> Vec<char> {
    for &(suffix, replacement) in step3_rules() {
        if suffix_in_region(&chars, suffix, r1) {
            return replace_suffix(chars, suffix, replacement);
        }
    }
    if suffix_in_region(&chars, "ative", r2) {
        let mut w = chars;
        w.truncate(w.len() - 5);
        return w;
    }
    chars
}

/// Step 4: residual long suffixes (R2 region only).
fn step4_suffixes() -> &'static [&'static str] {
    &[
        "ement", "ance", "ence", "able", "ible", "ment",
        "ant", "ent", "ism", "ate", "iti", "ous", "ive",
        "ize", "al", "er", "ic",
    ]
}

fn step4(chars: Vec<char>, r2: usize) -> Vec<char> {
    // Snowball longest-match rule: find the longest matching suffix from the
    // table; if it's in R2, strip it; if not, leave unchanged.
    // No fall-through to shorter suffixes.
    let mut longest: Option<&str> = None;
    for &suffix in step4_suffixes() {
        if ends_with(&chars, suffix) {
            if longest.is_none() || suffix.len() > longest.unwrap().len() {
                longest = Some(suffix);
            }
        }
    }
    // The "ion" rule (requires preceding s or t) is checked separately.
    if ends_with(&chars, "ion") {
        let ion_len = 3;
        if longest.is_none() || ion_len > longest.unwrap().len() {
            if chars.len() >= 4 {
                let prev = chars[chars.len() - 4];
                if prev == 's' || prev == 't' {
                    longest = Some("ion");
                }
            }
        }
    }
    let suffix = match longest {
        None => return chars,
        Some(s) => s,
    };
    let start = chars.len() - suffix.chars().count();
    if start >= r2 {
        let mut w = chars;
        w.truncate(start);
        return w;
    }
    chars
}

/// Step 5: final cleanup.
fn step5(mut chars: Vec<char>, r1: usize, r2: usize) -> Vec<char> {
    if chars.last() == Some(&'e') {
        if chars.len() - 1 >= r2 {
            chars.pop();
        } else if chars.len() - 1 >= r1 && !ends_with_short_syllable(&chars[..chars.len() - 1]) {
            chars.pop();
        }
    } else if chars.last() == Some(&'l') && chars.len() >= r2 + 1 {
        if chars.len() >= 2 && chars[chars.len() - 2] == 'l' {
            chars.pop();
        }
    }
    chars
}

// ---------------------------------------------------------------------------
// Syllable helpers
// ---------------------------------------------------------------------------

/// A short syllable per Snowball: a vowel followed by a non-vowel non-w-x-Y
/// at the end of the word, OR a vowel-non-vowel pair at the start of the word.
fn ends_with_short_syllable(chars: &[char]) -> bool {
    if chars.len() < 2 {
        return false;
    }
    let n = chars.len();
    let last = chars[n - 1];
    let second_last = chars[n - 2];
    if n == 2 {
        // (vowel)(non-vowel) at start of word.
        return is_vowel(second_last) && !is_vowel(last);
    }
    // (non-vowel)(vowel)(non-vowel-w-x-Y).
    let third_last = chars[n - 3];
    if "wxY".contains(last) {
        return false;
    }
    !is_vowel(third_last) && is_vowel(second_last) && !is_vowel(last)
}

fn is_short_word(chars: &[char]) -> bool {
    // Short word: R1 is at or after the end AND ends in a short syllable.
    let r1 = compute_r1(chars);
    if r1 < chars.len() {
        return false;
    }
    ends_with_short_syllable(chars)
}

fn is_double_consonant(chars: &[char]) -> bool {
    if chars.len() < 2 {
        return false;
    }
    let n = chars.len();
    let last = chars[n - 1];
    let prev = chars[n - 2];
    if last != prev {
        return false;
    }
    "bdfgmnprt".contains(last)
}

// ---------------------------------------------------------------------------
// Exception lists
// ---------------------------------------------------------------------------

fn irregular_exceptions() -> HashMap<&'static str, &'static str> {
    let mut m = HashMap::new();
    m.insert("skis", "ski");
    m.insert("skies", "sky");
    m.insert("dying", "die");
    m.insert("lying", "lie");
    m.insert("tying", "tie");
    m.insert("idly", "idl");
    m.insert("gently", "gentl");
    m.insert("ugly", "ugli");
    m.insert("early", "earli");
    m.insert("only", "onli");
    m.insert("singly", "singl");
    m.insert("sky", "sky");
    m.insert("news", "news");
    m.insert("howe", "howe");
    m.insert("atlas", "atlas");
    m.insert("cosmos", "cosmos");
    m.insert("bias", "bias");
    m.insert("andes", "andes");
    m
}

fn invariant_after_step1a() -> &'static [&'static str] {
    &[
        "inning", "outing", "canning", "herring",
        "earring", "proceed", "exceed", "succeed",
    ]
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_words_unchanged() {
        assert_eq!(stem("a"), "a");
        assert_eq!(stem("an"), "an");
        assert_eq!(stem("be"), "be");
    }

    #[test]
    fn empty_unchanged() {
        assert_eq!(stem(""), "");
    }

    #[test]
    fn irregular_exceptions_applied() {
        assert_eq!(stem("skis"), "ski");
        assert_eq!(stem("skies"), "sky");
        assert_eq!(stem("dying"), "die");
        assert_eq!(stem("lying"), "lie");
        assert_eq!(stem("ugly"), "ugli");
    }

    #[test]
    fn step1a_sses() {
        assert_eq!(stem("sses"), "ss");
    }

    #[test]
    fn step1a_ied_long() {
        // "cries" -> length 5, > 4, so "cri"
        assert_eq!(stem("cries"), "cri");
    }

    #[test]
    fn step1a_ies_short() {
        // "ties" -> length 4, not > 4, so "tie"
        assert_eq!(stem("ties"), "tie");
    }

    #[test]
    fn step1b_ing_fishing() {
        assert_eq!(stem("fishing"), "fish");
    }

    #[test]
    fn step1b_eed_feed() {
        // "feed" — eed not in R1 so unchanged
        assert_eq!(stem("feed"), "feed");
    }

    #[test]
    fn step2_ization() {
        assert_eq!(stem("computerization"), "computer");
    }

    #[test]
    fn chemistry_corpus() {
        assert_eq!(stem("chemistry"), "chemistri");
        assert_eq!(stem("chemical"), "chemic");
    }

    #[test]
    fn compute_corpus() {
        assert_eq!(stem("compute"), "comput");
        assert_eq!(stem("computing"), "comput");
        assert_eq!(stem("computed"), "comput");
        assert_eq!(stem("computer"), "comput");
    }

    #[test]
    fn running_hop() {
        assert_eq!(stem("running"), "run");
        assert_eq!(stem("hopping"), "hop");
    }
}
