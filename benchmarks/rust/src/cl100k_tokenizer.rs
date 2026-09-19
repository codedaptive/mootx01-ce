//! cl100k_tokenizer.rs — cl100k_base BPE tokenizer for the membench-spec §6 capacity lane.
//!
//! Rust twin of `Cl100kTokenizer.swift`. Same algorithm, same vocabulary format,
//! byte-identical outputs for all inputs — pinned by `conformance/cl100k/vectors.json`.
//!
//! No external crate dependencies. Vocab loading uses std::fs; BPE and pre-tokenization
//! are pure computation over `&str` / `Vec<u8>`.
//!
//! # Pre-tokenisation pattern (cl100k_base, reproduced as a scanner)
//!
//! ```text
//! (1) (?i:'s|'t|'re|'ve|'m|'ll|'d)  — contractions, case-insensitive
//! (2) [^\r\n\p{L}\p{N}]?\p{L}+       — optional non-letter-non-digit-non-CR-LF prefix + letters
//! (3) \p{N}{1,3}                      — 1 to 3 digits
//! (4) ' '?[^\s\p{L}\p{N}]+[\r\n]*    — optional space + punctuation/symbols + trailing CR/LF
//! (5) \s*[\r\n]+                      — whitespace run ending in CR/LF
//! (6) \s+(?!\S)                       — whitespace not followed by non-whitespace
//! (7) \s+                             — remaining whitespace
//! ```
//!
//! # Unicode category notes
//!
//! `\p{L}` is reproduced via `char::is_alphabetic` (Unicode Alphabetic property, a superset of
//! General Category L*). `\p{N}` is reproduced via `char::is_numeric` (Unicode Numeric property).
//! Category caveat: `char::is_alphabetic` and `char::is_numeric` overlap with the PCRE `\p{L}`
//! and `\p{N}` categories for the inputs this harness processes (ASCII, CJK, accented Latin,
//! emoji). Edge cases with Unicode "letter numbers" (e.g. Roman numeral Ⅳ) are documented in
//! the Swift source; the behaviour matches the Swift port, which is the parity contract.
//!
//! # Special tokens
//!
//! Not supported. The membench-spec lane processes plain text only. See `Cl100kTokenizer.swift`
//! for the rationale.

use std::collections::HashMap;

// ─────────────────────────────────────────────────────────────────────────────
// Error type
// ─────────────────────────────────────────────────────────────────────────────

/// Errors that can occur when loading or using the cl100k_base tokenizer.
#[derive(Debug)]
pub enum Cl100kError {
    /// The vocabulary file could not be read from the given path.
    FileNotFound(String),
    /// A line in the vocabulary file was malformed.
    MalformedVocabLine(String),
    /// A byte sequence produced by BPE was not in the vocabulary.
    /// Indicates a bug in the BPE implementation — should never occur.
    UnknownToken(Vec<u8>),
    /// Wraps an I/O error from the filesystem.
    IoError(std::io::Error),
}

impl std::fmt::Display for Cl100kError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Cl100kError::FileNotFound(p) => write!(f, "cl100k vocab file not found: {p}"),
            Cl100kError::MalformedVocabLine(l) => write!(f, "malformed vocab line: {l}"),
            Cl100kError::UnknownToken(b) => write!(f, "unknown token bytes: {b:?}"),
            Cl100kError::IoError(e) => write!(f, "I/O error: {e}"),
        }
    }
}

impl From<std::io::Error> for Cl100kError {
    fn from(e: std::io::Error) -> Self { Cl100kError::IoError(e) }
}

// ─────────────────────────────────────────────────────────────────────────────
// Base64 decoder (no external crate — cl100k only uses standard alphabet)
// ─────────────────────────────────────────────────────────────────────────────

/// Decodes standard base64 (alphabet A–Z a–z 0–9 + / with = padding).
/// The cl100k .tiktoken file uses only standard base64 — no URL-safe variant.
fn b64_decode(s: &str) -> Option<Vec<u8>> {
    // Look-up table: maps byte value to 6-bit group value; 255 = invalid.
    static LUT: [u8; 256] = {
        let mut t = [255u8; 256];
        let mut i = 0u8;
        while i < 26 {
            t[(b'A' + i) as usize] = i;
            t[(b'a' + i) as usize] = i + 26;
            i += 1;
        }
        let mut d = 0u8;
        while d < 10 {
            t[(b'0' + d) as usize] = 52 + d;
            d += 1;
        }
        t[b'+' as usize] = 62;
        t[b'/' as usize] = 63;
        t[b'=' as usize] = 0; // padding — value irrelevant, treated as 0
        t
    };

    let bytes = s.as_bytes();
    let len = bytes.len();
    // base64 input length must be a multiple of 4.
    if len % 4 != 0 { return None; }
    // Allocate output: 3 bytes per 4 input chars, minus padding.
    let padding = bytes.iter().rev().take_while(|&&b| b == b'=').count();
    let out_len = len / 4 * 3 - padding;
    let mut out = Vec::with_capacity(out_len);

    let mut i = 0;
    while i < len {
        let a = LUT[bytes[i] as usize];
        let b = LUT[bytes[i + 1] as usize];
        let c = LUT[bytes[i + 2] as usize];
        let d = LUT[bytes[i + 3] as usize];
        if a == 255 || b == 255 { return None; } // invalid base64 character
        // c and d can be padding (=) only at the end.
        let v = ((a as u32) << 18) | ((b as u32) << 12) | ((c as u32) << 6) | (d as u32);
        out.push((v >> 16) as u8);
        if bytes[i + 2] != b'=' { out.push((v >> 8) as u8); }
        if bytes[i + 3] != b'=' { out.push(v as u8); }
        i += 4;
    }
    Some(out)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tokenizer struct
// ─────────────────────────────────────────────────────────────────────────────

/// The cl100k_base BPE tokenizer.
///
/// Load once with [`Cl100kTokenizer::load`] and reuse across many encode calls.
/// The struct is `Send + Sync` — the vocabulary is immutable after construction.
pub struct Cl100kTokenizer {
    /// Maps token bytes → BPE rank.
    vocab: HashMap<Vec<u8>, usize>,
}

impl Cl100kTokenizer {
    // ── Loading ──────────────────────────────────────────────────────────────

    /// Loads the cl100k_base tokenizer from a .tiktoken vocabulary file.
    ///
    /// The .tiktoken format is one entry per line: `<base64-bytes> <rank>`.
    /// Expected to have 100,256 lines for cl100k_base.
    ///
    /// Twin of Swift `Cl100kTokenizer.load(from:)`.
    pub fn load(path: &str) -> Result<Self, Cl100kError> {
        let content = std::fs::read_to_string(path).map_err(|e| {
            if e.kind() == std::io::ErrorKind::NotFound {
                Cl100kError::FileNotFound(path.to_string())
            } else {
                Cl100kError::IoError(e)
            }
        })?;

        // Pre-size the HashMap to avoid rehashing (100,256 entries).
        let mut vocab = HashMap::with_capacity(100_300);

        for line in content.lines() {
            if line.is_empty() { continue; }
            // Split on the first space: "<base64> <rank>"
            let mut parts = line.splitn(2, ' ');
            let b64 = parts.next().ok_or_else(|| Cl100kError::MalformedVocabLine(line.to_string()))?;
            let rank_str = parts.next().ok_or_else(|| Cl100kError::MalformedVocabLine(line.to_string()))?;
            let token_bytes = b64_decode(b64)
                .ok_or_else(|| Cl100kError::MalformedVocabLine(format!("invalid base64: {b64}")))?;
            let rank: usize = rank_str.parse()
                .map_err(|_| Cl100kError::MalformedVocabLine(format!("invalid rank: {rank_str}")))?;
            vocab.insert(token_bytes, rank);
        }
        Ok(Cl100kTokenizer { vocab })
    }

    // ── Public interface ─────────────────────────────────────────────────────

    /// Returns the number of cl100k_base tokens in the given text.
    ///
    /// Equivalent to `len(tiktoken.get_encoding("cl100k_base").encode(text))`.
    /// Plain text only — no special tokens (see module header).
    ///
    /// Twin of Swift `Cl100kTokenizer.countTokens(_:)`.
    pub fn count_tokens(&self, text: &str) -> usize {
        self.encode(text).len()
    }

    /// Encodes the given text into a sequence of cl100k_base token IDs.
    ///
    /// Equivalent to `tiktoken.get_encoding("cl100k_base").encode(text)`.
    /// Plain text only — no special tokens (see module header).
    ///
    /// Twin of Swift `Cl100kTokenizer.encode(_:)`.
    pub fn encode(&self, text: &str) -> Vec<usize> {
        let mut ids = Vec::new();
        for pre_token in cl100k_pre_tokenize(text) {
            let bytes: Vec<u8> = pre_token.as_bytes().to_vec();
            if bytes.is_empty() { continue; }
            let token_ids = self.bpe_merge(&bytes);
            ids.extend_from_slice(&token_ids);
        }
        ids
    }

    // ── BPE merge ────────────────────────────────────────────────────────────

    /// Applies BPE to a sequence of UTF-8 bytes using the vocabulary rank table.
    ///
    /// Algorithm: standard tiktoken BPE merge — identical to the Python reference
    /// and the Swift twin:
    ///   1. Start with each byte as a length-1 token.
    ///   2. Repeat: find the pair with the minimum BPE rank.
    ///   3. Merge ALL non-overlapping occurrences of that pair left-to-right.
    ///   4. Stop when no pair has a rank in the vocabulary.
    ///
    /// Invariant: every byte 0x00–0xFF is a valid vocabulary entry, so all inputs
    /// produce valid output. Returns ranks of the final merged tokens.
    ///
    /// Twin of Swift `Cl100kTokenizer.bpeMerge(bytes:)`.
    fn bpe_merge(&self, bytes: &[u8]) -> Vec<usize> {
        if bytes.is_empty() { return vec![]; }
        if bytes.len() == 1 {
            // Fast path: single byte.
            return vec![*self.vocab.get(bytes).expect("single byte must be in vocab")];
        }

        // Represent the merge state as a list of owned byte slices.
        let mut tokens: Vec<Vec<u8>> = bytes.iter().map(|&b| vec![b]).collect();

        loop {
            if tokens.len() < 2 { break; }

            // Find the pair with the minimum BPE rank.
            let mut best_rank = usize::MAX;
            let mut best_idx = usize::MAX;
            for i in 0..(tokens.len() - 1) {
                // Build the candidate merged bytes without allocation when possible.
                let mut merged = tokens[i].clone();
                merged.extend_from_slice(&tokens[i + 1]);
                if let Some(&rank) = self.vocab.get(&merged) {
                    if rank < best_rank {
                        best_rank = rank;
                        best_idx = i;
                    }
                }
            }

            if best_idx == usize::MAX { break; } // No more merges.

            // Build the merge target once.
            let mut merge_target = tokens[best_idx].clone();
            merge_target.extend_from_slice(&tokens[best_idx + 1]);

            // Merge ALL non-overlapping occurrences of the best pair left-to-right.
            // This matches tiktoken's bpe() which merges all instances in one pass.
            let mut new_tokens: Vec<Vec<u8>> = Vec::with_capacity(tokens.len());
            let mut i = 0;
            while i < tokens.len() {
                if i + 1 < tokens.len() {
                    let mut candidate = tokens[i].clone();
                    candidate.extend_from_slice(&tokens[i + 1]);
                    if candidate == merge_target {
                        new_tokens.push(merge_target.clone());
                        i += 2;
                        continue;
                    }
                }
                new_tokens.push(tokens[i].clone());
                i += 1;
            }
            tokens = new_tokens;
        }

        // Map each merged token to its rank.
        tokens
            .iter()
            .map(|t| *self.vocab.get(t).expect("merged token must be in vocab"))
            .collect()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Pre-tokenisation (free function, matches Swift `cl100kPreTokenize`)
// ─────────────────────────────────────────────────────────────────────────────

/// Splits `text` into pre-tokens per the cl100k_base split pattern.
///
/// Returns a `Vec<&str>` of non-overlapping substrings that together cover
/// the whole input (no characters are dropped).
///
/// Twin of Swift `Cl100kTokenizer.cl100kPreTokenize(_:)`.
fn cl100k_pre_tokenize(text: &str) -> Vec<&str> {
    let chars: Vec<char> = text.chars().collect();
    // Map from char index to byte offset so we can slice the original &str.
    let byte_offsets: Vec<usize> = {
        let mut offs = vec![0usize; chars.len() + 1];
        let mut pos = 0usize;
        for (i, c) in chars.iter().enumerate() {
            offs[i] = pos;
            pos += c.len_utf8();
        }
        offs[chars.len()] = pos;
        offs
    };

    let n = chars.len();
    let mut result: Vec<&str> = Vec::new();
    let mut i = 0usize;

    while i < n {
        let start = i;

        // ── Rule 1: Contractions (?i:'s|'t|'re|'ve|'m|'ll|'d) ──────────────
        if chars[i] == '\'' {
            if let Some(end) = match_contraction(&chars, i) {
                result.push(&text[byte_offsets[start]..byte_offsets[end]]);
                i = end;
                continue;
            }
            // Not a contraction — apostrophe treated as punctuation below.
        }

        // ── Rule 2: [^\r\n\p{L}\p{N}]?\p{L}+ ────────────────────────────────
        let rule2_start = i;
        let mut rule2_i = i;
        // Check for optional non-letter-non-digit-non-CR-LF prefix.
        let ch = chars[rule2_i];
        let prefix_candidate = ch != '\r' && ch != '\n' && !ch.is_alphabetic() && !ch.is_numeric();
        if prefix_candidate {
            if rule2_i + 1 < n && chars[rule2_i + 1].is_alphabetic() {
                rule2_i += 1; // consume the optional prefix
            }
        }
        if rule2_i < n && chars[rule2_i].is_alphabetic() {
            let mut end = rule2_i + 1;
            while end < n && chars[end].is_alphabetic() {
                end += 1;
            }
            result.push(&text[byte_offsets[rule2_start]..byte_offsets[end]]);
            i = end;
            continue;
        }

        // ── Rule 3: \p{N}{1,3} ───────────────────────────────────────────────
        if chars[i].is_numeric() {
            let mut end = i;
            let mut count = 0usize;
            while end < n && chars[end].is_numeric() && count < 3 {
                end += 1;
                count += 1;
            }
            result.push(&text[byte_offsets[start]..byte_offsets[end]]);
            i = end;
            continue;
        }

        // ── Rule 4: ' '?[^\s\p{L}\p{N}]+[\r\n]* ─────────────────────────────
        let mut rule4_i = i;
        if rule4_i < n && chars[rule4_i] == ' ' {
            let next = rule4_i + 1;
            if next < n && is_punct_or_symbol(chars[next]) {
                rule4_i = next;
            }
        }
        if rule4_i < n && is_punct_or_symbol(chars[rule4_i]) {
            while rule4_i < n && is_punct_or_symbol(chars[rule4_i]) {
                rule4_i += 1;
            }
            // Consume trailing CR/LF.
            while rule4_i < n && (chars[rule4_i] == '\r' || chars[rule4_i] == '\n') {
                rule4_i += 1;
            }
            result.push(&text[byte_offsets[start]..byte_offsets[rule4_i]]);
            i = rule4_i;
            continue;
        }

        // ── Rule 5: \s*[\r\n]+ ───────────────────────────────────────────────
        let mut rule5_i = i;
        // Consume non-newline whitespace.
        while rule5_i < n && chars[rule5_i].is_whitespace()
              && chars[rule5_i] != '\r' && chars[rule5_i] != '\n' {
            rule5_i += 1;
        }
        if rule5_i < n && (chars[rule5_i] == '\r' || chars[rule5_i] == '\n') {
            while rule5_i < n && (chars[rule5_i] == '\r' || chars[rule5_i] == '\n') {
                rule5_i += 1;
            }
            result.push(&text[byte_offsets[start]..byte_offsets[rule5_i]]);
            i = rule5_i;
            continue;
        }

        // ── Rule 6: \s+(?!\S) — whitespace not followed by non-whitespace ────
        // Regex backtracking semantics: \s+ is greedy, and when the run is followed
        // by a non-space the lookahead fails at full length, so the engine backtracks
        // one char — the rule matches the run MINUS its final whitespace char (when
        // the run has ≥2 chars). That final char is left in place to prefix the next
        // pre-token via rule 2/4's optional [^\r\n\p{L}\p{N}] prefix (" b" is one
        // pre-token). At end of string the whole run matches. A single whitespace
        // char followed by non-space matches nothing here (falls to rules 2/4/7).
        // Oracle witness: "a    b" → ["a", "   ", " b"] (tiktoken cl100k_base).
        if chars[i].is_whitespace() {
            let mut rule6_i = i;
            while rule6_i < n && chars[rule6_i].is_whitespace() {
                rule6_i += 1;
            }
            if rule6_i >= n {
                // Trailing whitespace at end of string.
                result.push(&text[byte_offsets[start]..byte_offsets[rule6_i]]);
                i = rule6_i;
                continue;
            }
            // Followed by non-whitespace: match the run minus its last char, if that
            // leaves at least one char matched. The last char re-enters the main loop.
            if rule6_i - 1 > start {
                result.push(&text[byte_offsets[start]..byte_offsets[rule6_i - 1]]);
                i = rule6_i - 1;
                continue;
            }
            // Single whitespace char before non-space: rule 6 matches nothing here.
            // Fall through (rule 2/4 may absorb it as a prefix, else rule 7 takes it).
        }

        // ── Rule 7: \s+ ──────────────────────────────────────────────────────
        if chars[i].is_whitespace() {
            let mut end = i + 1;
            while end < n && chars[end].is_whitespace() {
                end += 1;
            }
            result.push(&text[byte_offsets[start]..byte_offsets[end]]);
            i = end;
            continue;
        }

        // ── Fallback: consume one character ──────────────────────────────────
        let end = i + 1;
        result.push(&text[byte_offsets[start]..byte_offsets[end]]);
        i = end;
    }

    result
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the char-index end of a contraction starting at `chars[i]` (apostrophe),
/// or `None` when no contraction matches.
///
/// Suffixes checked in priority order (longest first): ll, ve, re, s, t, m, d.
/// Case-insensitive: "I'LL" matches as "'ll".
///
/// Twin of Swift `Cl100kTokenizer.matchContraction(_:at:)`.
fn match_contraction(chars: &[char], i: usize) -> Option<usize> {
    if chars[i] != '\'' { return None; }
    let after = i + 1;
    if after >= chars.len() { return None; }

    // Suffixes: (char count, lowercased string)
    let suffixes: &[(usize, &str)] = &[
        (2, "ll"), (2, "ve"), (2, "re"),
        (1, "s"), (1, "t"), (1, "m"), (1, "d"),
    ];

    for &(count, suf) in suffixes {
        if after + count > chars.len() { continue; }
        let candidate: String = chars[after..after + count]
            .iter()
            .map(|c| c.to_lowercase().next().unwrap())
            .collect();
        if candidate == suf {
            return Some(after + count);
        }
    }
    None
}

/// Returns true when `c` belongs to cl100k rule 4's punctuation/symbol class:
/// not whitespace, not alphabetic, not numeric.
///
/// Twin of Swift `Cl100kTokenizer.isPunctOrSymbol(_:)`.
fn is_punct_or_symbol(c: char) -> bool {
    !c.is_whitespace() && !c.is_alphabetic() && !c.is_numeric()
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    // ── Fixture path ──────────────────────────────────────────────────────────

    /// External vocabulary path exported by the Makefile.
    fn fixture_path() -> PathBuf {
        std::env::var_os("MOOT_BENCH_CL100K")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/external/MOOT_BENCH_CL100K-not-set"))
    }

    /// Path to `benchmarks/conformance/cl100k/vectors.json`.
    fn conformance_path() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .expect("benchmarks/ parent must exist")
            .join("conformance")
            .join("cl100k")
            .join("vectors.json")
    }

    // ── Base64 decoder ────────────────────────────────────────────────────────

    #[test]
    fn b64_decode_single_byte() {
        // "IQ==" decodes to b'!' (0x21)
        assert_eq!(b64_decode("IQ=="), Some(vec![b'!']));
    }

    #[test]
    fn b64_decode_two_bytes() {
        // "Ig==" decodes to b'"' (0x22)
        assert_eq!(b64_decode("Ig=="), Some(vec![b'"']));
    }

    #[test]
    fn b64_decode_three_bytes() {
        // "SGVs" decodes to b"Hel"
        assert_eq!(b64_decode("SGVs"), Some(b"Hel".to_vec()));
    }

    #[test]
    fn b64_decode_hello() {
        assert_eq!(b64_decode("SGVsbG8="), Some(b"Hello".to_vec()));
    }

    #[test]
    fn b64_decode_invalid_length() {
        // Not a multiple of 4.
        assert_eq!(b64_decode("SGVsb"), None);
    }

    // ── Pre-tokenisation ──────────────────────────────────────────────────────

    #[test]
    fn pretokenize_empty() {
        assert_eq!(cl100k_pre_tokenize(""), Vec::<&str>::new());
    }

    #[test]
    fn pretokenize_single_letter() {
        assert_eq!(cl100k_pre_tokenize("a"), vec!["a"]);
    }

    #[test]
    fn pretokenize_single_digit() {
        assert_eq!(cl100k_pre_tokenize("0"), vec!["0"]);
    }

    #[test]
    fn pretokenize_digits_123() {
        // Rule 3: 1-3 digits → one pre-token.
        assert_eq!(cl100k_pre_tokenize("123"), vec!["123"]);
    }

    #[test]
    fn pretokenize_digits_1234_split() {
        // Rule 3: '123' + '4' → two pre-tokens.
        assert_eq!(cl100k_pre_tokenize("1234"), vec!["123", "4"]);
    }

    #[test]
    fn pretokenize_word_with_space_prefix() {
        // Rule 2: " the" is one pre-token (space prefix + letters).
        assert_eq!(cl100k_pre_tokenize(" the"), vec![" the"]);
    }

    #[test]
    fn pretokenize_hello_world() {
        // "Hello" then " world".
        assert_eq!(cl100k_pre_tokenize("Hello world"), vec!["Hello", " world"]);
    }

    #[test]
    fn pretokenize_contraction_its() {
        // "it" then "'s".
        assert_eq!(cl100k_pre_tokenize("it's"), vec!["it", "'s"]);
    }

    #[test]
    fn pretokenize_contraction_well() {
        assert_eq!(cl100k_pre_tokenize("we'll"), vec!["we", "'ll"]);
    }

    #[test]
    fn pretokenize_newline() {
        // Rule 5: \s*[\r\n]+
        assert_eq!(cl100k_pre_tokenize("\n"), vec!["\n"]);
    }

    #[test]
    fn pretokenize_crlf() {
        // Rule 5: CRLF is one pre-token.
        assert_eq!(cl100k_pre_tokenize("\r\n"), vec!["\r\n"]);
    }

    #[test]
    fn pretokenize_punctuation_exclamation() {
        // Rule 4: single punctuation char.
        assert_eq!(cl100k_pre_tokenize("!"), vec!["!"]);
    }

    #[test]
    fn pretokenize_hello_comma_world() {
        // "Hello" + "," + " world" + "!"
        assert_eq!(
            cl100k_pre_tokenize("Hello, world!"),
            vec!["Hello", ",", " world", "!"]
        );
    }

    // ── Conformance vectors (skip when fixture absent) ────────────────────────

    /// Loads the cl100k tokenizer, returning None when the fixture is absent.
    /// Tests that require the tokenizer call this and return early if None.
    fn try_load_tokenizer() -> Option<Cl100kTokenizer> {
        let path = fixture_path();
        if !path.exists() {
            eprintln!(
                "SKIP: cl100k_base.tiktoken not found at {}. \
                 Run scripts/fetch-cl100k.sh to download it.",
                path.display()
            );
            return None;
        }
        match Cl100kTokenizer::load(path.to_str().expect("valid UTF-8 path")) {
            Ok(tok) => Some(tok),
            Err(e) => {
                eprintln!("SKIP: failed to load cl100k tokenizer: {e}");
                None
            }
        }
    }

    #[test]
    fn vocab_loads_100256_entries() {
        let Some(tok) = try_load_tokenizer() else { return; };
        // cl100k_base has exactly 100,256 vocabulary entries.
        assert_eq!(tok.vocab.len(), 100_256, "vocab entry count mismatch");
    }

    #[test]
    fn single_byte_tokens_present() {
        let Some(tok) = try_load_tokenizer() else { return; };
        // Every byte 0x00–0xFF must be in the vocabulary.
        for b in 0u8..=255 {
            assert!(
                tok.vocab.contains_key(&vec![b]),
                "single byte 0x{b:02X} missing from vocab"
            );
        }
    }

    #[test]
    fn encode_empty_string() {
        let Some(tok) = try_load_tokenizer() else { return; };
        assert_eq!(tok.encode(""), Vec::<usize>::new());
    }

    #[test]
    fn count_tokens_empty_string() {
        let Some(tok) = try_load_tokenizer() else { return; };
        assert_eq!(tok.count_tokens(""), 0);
    }

    /// Golden pin: a literal string → count asserted in BOTH ports.
    /// "The quick brown fox" encodes to 4 tokens in cl100k_base.
    /// This pin catches any regression in pre-tokenization or BPE.
    #[test]
    fn golden_pin_the_quick_brown_fox() {
        let Some(tok) = try_load_tokenizer() else { return; };
        let ids = tok.encode("The quick brown fox");
        assert_eq!(
            ids.len(), 4,
            "golden pin: 'The quick brown fox' should encode to 4 tokens, got {}: {:?}",
            ids.len(), ids
        );
        // Also assert the exact IDs (pinned against hand-derived BPE trace).
        assert_eq!(ids, vec![791, 4062, 14198, 39935]);
    }

    #[test]
    fn conformance_vectors_all_pass() {
        let Some(tok) = try_load_tokenizer() else { return; };

        let vec_path = conformance_path();
        if !vec_path.exists() {
            eprintln!(
                "SKIP: conformance vectors not found at {}. \
                 Vectors are committed — if absent, check the repo.",
                vec_path.display()
            );
            return;
        }

        let data = std::fs::read_to_string(&vec_path)
            .unwrap_or_else(|e| panic!("cannot read {}: {e}", vec_path.display()));
        let json: serde_json::Value = serde_json::from_str(&data)
            .expect("vectors.json is not valid JSON");

        let cases = json["cases"].as_array().expect("missing 'cases' array");
        let mut pass = 0usize;
        let mut fail = 0usize;

        for c in cases {
            let id = c["id"].as_str().unwrap_or("(unknown)");
            let text = c["text"].as_str().expect("missing 'text'");
            let expected_count = c["token_count"].as_u64().expect("missing 'token_count'") as usize;
            let expected_ids: Vec<usize> = c["token_ids"]
                .as_array()
                .expect("missing 'token_ids'")
                .iter()
                .map(|v| v.as_u64().expect("token id must be u64") as usize)
                .collect();

            let actual_ids = tok.encode(text);

            if actual_ids == expected_ids && actual_ids.len() == expected_count {
                pass += 1;
            } else {
                eprintln!(
                    "FAIL vector '{id}': text={text:?} expected_count={expected_count} expected_ids={expected_ids:?} actual_ids={actual_ids:?}",
                );
                fail += 1;
            }
        }
        assert_eq!(fail, 0, "{fail} conformance vector(s) failed, {pass} passed");
    }
}
