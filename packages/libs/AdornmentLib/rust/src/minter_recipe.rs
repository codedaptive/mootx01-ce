//! Compile-time minter recipes and the generic mint-output normalizer
//! (ADORNMENTLIB_SPEC 0.6.0 § Minter recipes). Rust twin of
//! `MinterRecipe.swift`.
//!
//! A RECIPE is the complete generation contract of one product minter:
//! model + prompt template + generation settings + output payload kind.
//! The composed ID `<model>-p<promptVersion>-s<settingsVersion>` is the
//! minter identity written to the `adornment_minters` master and stamped
//! on every adornment row — the SAME identity regardless of which port
//! minted (rows are interchangeable across ports and sync freely; the
//! port is the executor, never part of the contract).
//!
//! Model choice is a DEVELOPER BUILD-TIME decision (Bob, 2026-08-26):
//! the recipes below are plain constants, flippable at compile time via
//! the Makefile/sed. There is no runtime model discovery and no
//! user-facing swap surface in this edition.
//!
//! ── RECIPE VERSION LEDGER ──────────────────────────────────────────────
//! Git is the history: this block always states ONLY the current recipes;
//! retired recipe content lives in `git log` on this file, and retired
//! IDs live forever in every estate's `adornment_minters` rows (with
//! digests proving which recipe they were).
//!
//!   qwen2-0.5b-q4km   p1  s1   (quantized in-process engine default GGUF)
//!
//! RULES (mirror of the bitmap-bit doctrine):
//!   - NEVER reuse a version number. A retired p2 means the next prompt is
//!     p3 even if p2 lived for a day — estates may carry rows minted
//!     under it and the digest must stay unambiguous.
//!   - Any change to the prompt template bumps pN; any change to a
//!     generation-affecting setting bumps sN; a different model artifact
//!     is a different model token. Bump in the SAME commit as the change.
//!   - The digests below are recomputed from the live constants at
//!     runtime, so an edit without a version bump is mechanically
//!     detectable against the registered master row.
//! ───────────────────────────────────────────────────────────────────────

use std::collections::BTreeMap;

use crate::adornment_identity::AdornmentMinterDescriptor;

// ── Output payload kinds ────────────────────────────────────────────────────

/// The payload shape a minting model emits. There are exactly two shapes
/// in the wild — a prose line, or JSON — and one normalizer handles both,
/// so any model of either shape is a recipe entry, never new code.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MintOutputKind {
    /// Model emits the claim as prose; first meaningful line wins.
    Text,
    /// Model emits JSON; the normalizer flattens it deterministically
    /// into the semicolon-separated claim line.
    Json,
}

// ── Recipe ──────────────────────────────────────────────────────────────────

/// One complete minter generation contract. Pure value; the built-in
/// recipes below are the compile-time constants block. Mirrors Swift
/// `MinterRecipe`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MinterRecipe {
    /// Model token of the composed ID (e.g. "qwen2-0.5b-q4km"). Names the
    /// model ARTIFACT contract, never the executing port.
    pub model: &'static str,
    /// Prompt-template version (the `pN` component).
    pub prompt_version: u32,
    /// Generation-settings version (the `sN` component).
    pub settings_version: u32,
    /// The system/instruction prompt template this recipe mints with.
    pub system_prompt: &'static str,
    /// The full prompt wrapper for raw-completion engines, with `{system}`
    /// and `{input}` placeholders (e.g. the Qwen2 chatml wrapper, or
    /// NuExtract's plain extraction format). Session-based engines (Apple)
    /// pass `system_prompt` to their session API and never render this.
    /// Part of the prompt contract: covered by `prompt_digest`, so a
    /// wrapper change without a pN bump is mechanically detectable.
    pub chat_template: &'static str,
    /// Every generation-affecting setting as (key, value) pairs; kept
    /// sorted here so the canonical serialization is the literal order.
    pub parameters: &'static [(&'static str, &'static str)],
    /// Payload shape the model emits; drives the normalizer branch.
    pub output: MintOutputKind,
    /// Minter family for the master row (e.g. "apple", "quantized").
    pub family: &'static str,
}

impl MinterRecipe {
    /// The composed minter identity: `<model>-p<promptVersion>-s<settingsVersion>`.
    /// This exact string is the cross-port minter identity on adornment rows.
    pub fn id(&self) -> String {
        format!("{}-p{}-s{}", self.model, self.prompt_version, self.settings_version)
    }

    /// Digest of the live prompt contract (FNV-1a 64, hex): the chat
    /// template with `{system}` resolved (leaving `{input}`), so BOTH the
    /// instruction text and the wrapper shape are covered. Registration
    /// compares this against the master row's stored digest — a prompt
    /// edit without a pN bump fails that comparison mechanically.
    pub fn prompt_digest(&self) -> String {
        fnv1a64_hex(&self.chat_template.replace("{system}", self.system_prompt))
    }

    /// Render the full prompt for a raw-completion engine: `{system}` and
    /// `{input}` substituted into the chat template.
    pub fn assemble_prompt(&self, raw_input: &str) -> String {
        self.chat_template
            .replace("{system}", self.system_prompt)
            .replace("{input}", raw_input.trim())
    }

    /// Digest of the canonical settings serialization (lexical key order,
    /// `key=value` lines). Same mechanical-mismatch role as prompt_digest.
    pub fn parameters_digest(&self) -> String {
        let mut pairs: Vec<_> = self.parameters.to_vec();
        pairs.sort_by_key(|(k, _)| *k);
        let canonical = pairs
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("\n");
        fnv1a64_hex(&canonical)
    }

    /// Build the master-row descriptor for this recipe. `row_id` is the
    /// persistence-assigned row identifier; the recipe's composed ID
    /// travels as `name`, and the digests + parameters carry the
    /// verification material. The parameters map includes the settings
    /// digest under `settings_digest` so the stored row is self-checking.
    pub fn descriptor(&self, row_id: &str, is_active: bool) -> AdornmentMinterDescriptor {
        let mut params: BTreeMap<String, String> = self
            .parameters
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        params.insert("settings_digest".to_string(), self.parameters_digest());
        AdornmentMinterDescriptor::new(
            row_id,
            self.id(),
            self.family,
            self.model,
            format!("p{}-s{}", self.prompt_version, self.settings_version),
            self.prompt_digest(),
            params,
            is_active,
        )
    }
}

// ── Built-in recipes (the compile-time constants block) ─────────────────────

/// The Qwen2-family chatml wrapper: system + user turns, ending at the
/// assistant sentinel so the model generates the turn directly.
pub const CHATML_TEMPLATE: &str = "<|im_start|>system\n{system}\n<|im_end|>\n<|im_start|>user\n{input}\n<|im_end|>\n<|im_start|>assistant\n";

/// The Rust port's quantized in-process engine recipe. The GGUF at
/// `<data>/goldminer/model.gguf` is EXPECTED to be the artifact this
/// model token names; swapping the artifact is a build-time decision
/// that changes this constant in the same commit.
pub const QUANTIZED_RECIPE: MinterRecipe = MinterRecipe {
    model: "qwen2-0.5b-q4km",
    prompt_version: 1,
    settings_version: 1,
    system_prompt: "You are a precise knowledge minter. \
Given a memory record and a minting instruction, output exactly ONE \
short, dense claim line. No preamble, no explanation, no markdown \
fences, no list markers. Output the claim and nothing else.",
    chat_template: CHATML_TEMPLATE,
    parameters: &[
        ("max_length", "280"),
        ("max_new_tokens", "96"),
        ("sampling", "greedy"),
    ],
    output: MintOutputKind::Text,
    family: "quantized",
};

// ── Digest (FNV-1a 64) ──────────────────────────────────────────────────────

/// FNV-1a 64-bit digest, lowercase hex. Deliberately NOT cryptographic:
/// its job is mechanical recipe-mismatch detection, and it must produce
/// IDENTICAL values in both ports with zero dependencies. Twin of the
/// Swift `fnv1a64Hex`; golden-pinned in both test suites.
pub fn fnv1a64_hex(s: &str) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in s.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

// ── Output normalizer ───────────────────────────────────────────────────────

/// Normalize a raw model emission into the claim line, per the recipe's
/// output kind. ONE implementation covers every model shape:
///   - `Text`: first meaningful prose line (fences, list markers, and
///     control tokens stripped).
///   - `Json`: deterministic flattening — lexical key order, nested
///     values recursed, fragments joined with "; ". A JSON payload that
///     fails to parse falls back to the text path (deterministic salvage
///     of a non-compliant emission).
/// Returns "" when nothing usable remains (per-prompt failure upstream).
/// Twin of the Swift `normalizeMintOutput`; shared golden fixtures.
pub fn normalize_mint_output(raw: &str, kind: MintOutputKind) -> String {
    match kind {
        MintOutputKind::Text => extract_claim_line(raw),
        MintOutputKind::Json => {
            let stripped = strip_code_fences(raw);
            match serde_json::from_str::<serde_json::Value>(&stripped) {
                Ok(value) => {
                    let mut fragments = Vec::new();
                    flatten_json(&value, &mut fragments);
                    fragments.join("; ")
                }
                Err(_) => extract_claim_line(raw),
            }
        }
    }
}

/// First meaningful prose line: skip fence lines, strip leading list
/// markers, drop chat-template control tokens, trim. The canonical
/// claim-line extraction shared by every text-shaped engine.
pub fn extract_claim_line(raw: &str) -> String {
    for line in raw.lines() {
        let mut s = line.trim();
        if s.starts_with("```") {
            continue;
        }
        while let Some(rest) = s
            .strip_prefix('-')
            .or_else(|| s.strip_prefix('*'))
            .or_else(|| s.strip_prefix('•'))
        {
            s = rest.trim();
        }
        let s = s.replace("<|im_end|>", "").replace("<|endoftext|>", "");
        let s = s.trim();
        if !s.is_empty() {
            return s.to_string();
        }
    }
    String::new()
}

/// Remove surrounding markdown fence lines (``` or ```json) so fenced
/// JSON parses. Interior lines are preserved verbatim.
fn strip_code_fences(raw: &str) -> String {
    raw.lines()
        .filter(|l| !l.trim().starts_with("```"))
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

/// Deterministic JSON flattening: strings pass through (trimmed, empties
/// skipped), numbers and bools render canonically, null is skipped,
/// arrays recurse in order, objects recurse in LEXICAL key order.
fn flatten_json(value: &serde_json::Value, fragments: &mut Vec<String>) {
    use serde_json::Value;
    match value {
        Value::String(s) => {
            let t = s.trim();
            if !t.is_empty() {
                fragments.push(t.to_string());
            }
        }
        Value::Bool(b) => fragments.push(b.to_string()),
        Value::Number(n) => fragments.push(canonical_number(n)),
        Value::Array(items) => {
            for item in items {
                flatten_json(item, fragments);
            }
        }
        Value::Object(map) => {
            // serde_json Map preserves insertion order; sort keys so the
            // rendering matches the Swift lexical-order contract.
            let mut keys: Vec<_> = map.keys().collect();
            keys.sort();
            for key in keys {
                flatten_json(&map[key], fragments);
            }
        }
        Value::Null => {}
    }
}

/// Integral numbers render without a decimal point; everything else uses
/// the f64 display. Matches the Swift NSNumber canonical rendering.
fn canonical_number(n: &serde_json::Number) -> String {
    if let Some(i) = n.as_i64() {
        return i.to_string();
    }
    if let Some(f) = n.as_f64() {
        if f == f.trunc() && f.abs() < 1e15 {
            return format!("{}", f as i64);
        }
        return format!("{f}");
    }
    n.to_string()
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    /// Golden pins shared with Swift `MinterRecipeTests` — one literal
    /// value asserted in BOTH ports (twin-generator doctrine). A digest
    /// divergence here means the ports would register mismatched master
    /// rows for the same recipe.
    #[test]
    fn fnv1a64_golden_pins_match_swift() {
        assert_eq!(fnv1a64_hex(""), "cbf29ce484222325");
        assert_eq!(fnv1a64_hex("abc"), "e71fa2190541574b");
        assert_eq!(
            fnv1a64_hex("gold miner recipe digest test vector é中"),
            "e25b307539822f8e"
        );
    }

    #[test]
    fn composed_id_and_descriptor() {
        assert_eq!(QUANTIZED_RECIPE.id(), "qwen2-0.5b-q4km-p1-s1");
        let d = QUANTIZED_RECIPE.descriptor("row-7", true);
        assert_eq!(d.name, "qwen2-0.5b-q4km-p1-s1");
        assert_eq!(d.model_id, "qwen2-0.5b-q4km");
        assert_eq!(d.model_version, "p1-s1");
        assert_eq!(d.family, "quantized");
        assert_eq!(d.prompt_digest, QUANTIZED_RECIPE.prompt_digest());
        assert_eq!(
            d.parameters.get("settings_digest"),
            Some(&QUANTIZED_RECIPE.parameters_digest())
        );
        assert_eq!(d.parameters.get("sampling"), Some(&"greedy".to_string()));
        assert!(d.is_active);
    }

    /// Shared normalizer fixtures — same inputs and expected outputs are
    /// asserted in Swift `MinterRecipeTests`.
    #[test]
    fn normalizer_text_and_json_golden_fixtures() {
        // Text: fences, markers, control tokens.
        assert_eq!(
            normalize_mint_output("```\n- the claim<|im_end|>\n```", MintOutputKind::Text),
            "the claim"
        );
        assert_eq!(
            normalize_mint_output("\n\n  * spaced claim  \n rest", MintOutputKind::Text),
            "spaced claim"
        );
        assert_eq!(normalize_mint_output("", MintOutputKind::Text), "");

        // JSON object: lexical key order, nested values, arrays in order.
        assert_eq!(
            normalize_mint_output(
                r#"{"entities": ["Alice", "straw"], "claim": "planted 12 saplings", "date": "2026-08-26"}"#,
                MintOutputKind::Json
            ),
            "planted 12 saplings; 2026-08-26; Alice; straw"
        );
        // Fenced JSON parses; numbers/bools render canonically; null and
        // empty strings are skipped.
        assert_eq!(
            normalize_mint_output(
                "```json\n{\"b_count\": 12, \"a_flag\": true, \"c_null\": null, \"d\": \"\"}\n```",
                MintOutputKind::Json
            ),
            "true; 12"
        );
        // Non-JSON emission under a Json recipe: deterministic text salvage.
        assert_eq!(
            normalize_mint_output("- fallback prose line\n", MintOutputKind::Json),
            "fallback prose line"
        );
        // Integer beyond f64's 53-bit mantissa must render exactly
        // (i64-first path both ports): 2^53 + 1.
        assert_eq!(
            normalize_mint_output(r#"{"n": 9007199254740993}"#, MintOutputKind::Json),
            "9007199254740993"
        );
    }
}
