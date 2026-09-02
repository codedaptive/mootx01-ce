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
//! Model choice is an OPERATOR START-TIME decision (Bob D4 ruling,
//! 2026-08-31, superseding the 2026-08-26 build-time ruling): the serve
//! process selects a recipe from the registry below via `MOOT_MINT_MODEL`
//! (default `qwen2-0.5b-q4km`). There is no runtime model discovery and
//! no user-facing swap surface in this edition.
//!
//! ── RECIPE VERSION LEDGER ──────────────────────────────────────────────
//! Git is the history: this block always states ONLY the current recipes;
//! retired recipe content lives in `git log` on this file, and retired
//! IDs live forever in every estate's `adornment_minters` rows (with
//! digests proving which recipe they were).
//!
//!   qwen2-0.5b-q4km      p2  s1   (quantized in-process engine default GGUF)
//!   qwen2.5-0.5b-q4km    p2  s1
//!   nuextract-tiny-q4km  p1  s2   (native extraction template, no chat frame)
//!   qwen2.5-1.5b-q4km    p2  s1   (quality-ceiling reference arm)
//!   qwen3-0.6b-q8        p1  s1   (wave-1 roster; candle qwen3 graph)
//!   osmosis-structure-0.6b-q8  p1  s1  (Qwen3 fine-tune, structured output)
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

/// The Qwen2-family chatml wrapper: a single USER turn ending at the
/// assistant sentinel so the model generates the turn directly. No
/// system turn — the minting instruction rides inside the user prompt
/// (`build_adornment_prompt`), and the frame is byte-identical to the
/// Swift Core AI `.chat` frame (D1 frame ruling, Bob 2026-08-31: the
/// user-only frame won; the system-turn wrapper is retired as p1).
pub const CHATML_TEMPLATE: &str = "<|im_start|>user\n{input}<|im_end|>\n<|im_start|>assistant\n";

/// The Rust port's DEFAULT quantized in-process engine recipe. The GGUF
/// at `<data>/goldminer/model.gguf` is EXPECTED to be the artifact the
/// selected recipe's model token names: the recipe is selected at serve
/// start (`MOOT_MINT_MODEL`, default this constant), and pairing the
/// matching artifact with the selection is the operator's contract —
/// the minter identity row records which recipe minted every claim.
pub const QUANTIZED_RECIPE: MinterRecipe = MinterRecipe {
    model: "qwen2-0.5b-q4km",
    // p2 (2026-08-31): user-only frame — the p1 system-turn wrapper is
    // retired; estates carry p1 rows forever, digests disambiguate.
    prompt_version: 2,
    settings_version: 1,
    // Empty by the D1 ruling: chat recipes carry no system text; the
    // whole instruction lives in the assembled user prompt.
    system_prompt: "",
    chat_template: CHATML_TEMPLATE,
    parameters: &[
        ("max_length", "280"),
        ("max_new_tokens", "96"),
        ("sampling", "greedy"),
    ],
    output: MintOutputKind::Text,
    family: "quantized",
};

/// Qwen2.5-0.5B-Instruct Q4_K_M: same architecture and prompt contract
/// as the default — a pure model-token change.
pub const QWEN25_05B_RECIPE: MinterRecipe = MinterRecipe {
    model: "qwen2.5-0.5b-q4km",
    ..QUANTIZED_RECIPE
};

/// NuExtract-tiny v1.5 Q4_K_M: extraction-specialized Qwen2.5-0.5B.
/// Trained on its own plain input/output format (no chatml, no system
/// turn) and emits JSON against the template — the normalizer's Json
/// branch flattens it to the claim line deterministically.
pub const NUEXTRACT_TINY_RECIPE: MinterRecipe = MinterRecipe {
    model: "nuextract-tiny-q4km",
    // Pinned p1: the native template is unchanged by the D1 frame
    // ruling (it never had a chat frame), so inheriting the chat
    // recipes' p2 would falsely retire a prompt that never changed.
    prompt_version: 1,
    // s2 (NUEXTRACT-TAIL, 2026-08-31): JSON emissions scale with record
    // entity count — at the shared 96-token cap, long records truncated
    // mid-object and salvaged to a bare "{" claim (~28% of a 272-record
    // locomo run, length-correlated, identical at F16 and Q8). 256
    // tokens covers the observed JSON sizes; the engine reads this
    // setting per recipe.
    settings_version: 2,
    system_prompt: "",
    chat_template: "<|input|>\n### Template:\n{\"claim\": \"\", \"entities\": [], \"dates\": [], \"quantities\": []}\n### Text:\n{input}\n<|output|>\n",
    parameters: &[
        ("max_length", "280"),
        ("max_new_tokens", "256"),
        ("sampling", "greedy"),
    ],
    output: MintOutputKind::Json,
    ..QUANTIZED_RECIPE
};

/// Qwen2.5-1.5B-Instruct Q4_K_M: the quality-ceiling reference arm.
/// Same contract as the 0.5B chat recipes; ~3x the compute per token
/// and over the 1 GiB product residency budget.
pub const QWEN25_15B_RECIPE: MinterRecipe = MinterRecipe {
    model: "qwen2.5-1.5b-q4km",
    ..QUANTIZED_RECIPE
};

/// Qwen3-0.6B Q8_0 (QWEN3-ENGINE, roster wave 1): a generation newer in
/// instruction-following than the qwen2.5 tier at nearly the same size.
/// Same chatml sentinels and user-only frame as the qwen2 family; the
/// engine dispatches it to candle's quantized_qwen3 graph by this model
/// token. p1 starts fresh — its own template history, not the qwen2
/// ladder's.
pub const QWEN3_06B_RECIPE: MinterRecipe = MinterRecipe {
    model: "qwen3-0.6b-q8",
    prompt_version: 1,
    // Qwen3 is a THINKING model by default: bare chatml framing makes it
    // open a <think> block (observed live at bring-up). The empty
    // think-block prefix after the assistant sentinel is the model's
    // documented non-thinking form — generation starts directly on the
    // claim.
    chat_template: "<|im_start|>user\n{input}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n",
    ..QUANTIZED_RECIPE
};

/// Osmosis-Structure-0.6B Q8_0 (roster wave 1): a Qwen3-0.6B fine-tune
/// RL-trained for schema-faithful structured output. Its TRAINED
/// contract is a SYSTEM turn carrying the JSON schema plus the source
/// text as the user turn (model card usage) — a model-native format
/// like NuExtract's bare template, so the D1 user-only ruling for the
/// shared chat minters does not apply here. Bare-template prompting was
/// tried first at bring-up and the model echoed schema fragments
/// instead of data. Empty-think prefix per the Qwen3 base. Normalizer's
/// Json branch flattens the emission; 256-token budget per the
/// NUEXTRACT-TAIL finding.
pub const OSMOSIS_STRUCTURE_RECIPE: MinterRecipe = MinterRecipe {
    model: "osmosis-structure-0.6b-q8",
    prompt_version: 1,
    system_prompt: "You are a helpful assistant that understands and translates text to JSON format according to the following schema. {\"type\": \"object\", \"properties\": {\"claim\": {\"type\": \"string\"}, \"entities\": {\"type\": \"array\", \"items\": {\"type\": \"string\"}}, \"dates\": {\"type\": \"array\", \"items\": {\"type\": \"string\"}}, \"quantities\": {\"type\": \"array\", \"items\": {\"type\": \"string\"}}}, \"required\": [\"claim\"]}",
    chat_template: "<|im_start|>system\n{system}<|im_end|>\n<|im_start|>user\n{input}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n",
    parameters: &[
        ("max_length", "280"),
        ("max_new_tokens", "256"),
        ("sampling", "greedy"),
    ],
    output: MintOutputKind::Json,
    ..QUANTIZED_RECIPE
};

/// Resolve a swappable engine recipe by its model token. The registry
/// is the vocabulary of models the port can run — selection happens at
/// serve start; an unknown token is a configuration error the caller
/// surfaces loudly (never a silent fallback).
pub fn recipe_for_model(token: &str) -> Option<MinterRecipe> {
    match token {
        "qwen2-0.5b-q4km" => Some(QUANTIZED_RECIPE),
        "qwen2.5-0.5b-q4km" => Some(QWEN25_05B_RECIPE),
        "nuextract-tiny-q4km" => Some(NUEXTRACT_TINY_RECIPE),
        "qwen2.5-1.5b-q4km" => Some(QWEN25_15B_RECIPE),
        "qwen3-0.6b-q8" => Some(QWEN3_06B_RECIPE),
        "osmosis-structure-0.6b-q8" => Some(OSMOSIS_STRUCTURE_RECIPE),
        _ => None,
    }
}

/// The serve-start recipe selection: `MOOT_MINT_MODEL` names a registry
/// token (unset/empty = the default `QUANTIZED_RECIPE`). An unknown
/// token is a configuration error returned as `Err` — the caller
/// surfaces it loudly and installs NO engine; there is never a silent
/// fallback to a different model, because the minter identity row must
/// record exactly what the operator selected.
pub fn selected_recipe() -> Result<MinterRecipe, String> {
    match std::env::var("MOOT_MINT_MODEL") {
        Err(std::env::VarError::NotPresent) => Ok(QUANTIZED_RECIPE),
        Err(e) => Err(format!("MOOT_MINT_MODEL unreadable: {e}")),
        Ok(token) if token.trim().is_empty() => Ok(QUANTIZED_RECIPE),
        Ok(token) => recipe_for_model(token.trim()).ok_or_else(|| {
            format!(
                "MOOT_MINT_MODEL={token:?} is not a registered model token \
                 (known: qwen2-0.5b-q4km, qwen2.5-0.5b-q4km, \
                 nuextract-tiny-q4km, qwen2.5-1.5b-q4km, \
                 qwen3-0.6b-q8, osmosis-structure-0.6b-q8)"
            )
        }),
    }
}

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
            match top_level_json_object_prefix(&stripped)
                .and_then(|prefix| serde_json::from_str::<serde_json::Value>(prefix).ok())
            {
                Some(value) => {
                    let mut fragments = Vec::new();
                    flatten_json(&value, &mut fragments);
                    fragments.join("; ")
                }
                None => extract_claim_line(raw),
            }
        }
    }
}

/// Extract the first complete, strictly valid top-level JSON object.
///
/// Leading whitespace is permitted but excluded from the returned prefix;
/// prose before the opening brace is rejected. Braces inside strings and
/// escaped quotes do not affect nesting depth. Content after the closing brace
/// is deliberately excluded because a decoded token can contain both `}` and a
/// punctuation suffix. The engine stop and normalizer share this exact helper.
pub(crate) fn top_level_json_object_prefix(text: &str) -> Option<&str> {
    let mut start = None;
    let mut depth: usize = 0;
    let mut in_string = false;
    let mut escaped = false;
    let mut last_structural_character = None;

    for (index, ch) in text.char_indices() {
        if start.is_none() {
            if ch == '{' {
                start = Some(index);
                depth = 1;
            } else if !ch.is_whitespace() {
                return None;
            }
            continue;
        }
        if in_string {
            if escaped {
                escaped = false;
            } else if ch == '\\' {
                escaped = true;
            } else if ch == '"' {
                in_string = false;
            }
            continue;
        }
        match ch {
            '"' => {
                in_string = true;
                last_structural_character = Some(ch);
            }
            '{' => {
                depth += 1;
                last_structural_character = Some(ch);
            }
            ']' => {
                if last_structural_character == Some(',') {
                    return None;
                }
                last_structural_character = Some(ch);
            }
            '}' => {
                if last_structural_character == Some(',') {
                    return None;
                }
                depth -= 1;
                if depth == 0 {
                    let candidate = &text[start.unwrap()..index + ch.len_utf8()];
                    return matches!(
                        serde_json::from_str::<serde_json::Value>(candidate),
                        Ok(serde_json::Value::Object(_))
                    )
                    .then_some(candidate);
                }
                last_structural_character = Some(ch);
            }
            _ if !ch.is_whitespace() => last_structural_character = Some(ch),
            _ => {}
        }
    }
    None
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
        assert_eq!(QUANTIZED_RECIPE.id(), "qwen2-0.5b-q4km-p2-s1");
        let d = QUANTIZED_RECIPE.descriptor("row-7", true);
        assert_eq!(d.name, "qwen2-0.5b-q4km-p2-s1");
        assert_eq!(d.model_id, "qwen2-0.5b-q4km");
        assert_eq!(d.model_version, "p2-s1");
        assert_eq!(d.family, "quantized");
        assert_eq!(d.prompt_digest, QUANTIZED_RECIPE.prompt_digest());
        assert_eq!(
            d.parameters.get("settings_digest"),
            Some(&QUANTIZED_RECIPE.parameters_digest())
        );
        assert_eq!(d.parameters.get("sampling"), Some(&"greedy".to_string()));
        assert!(d.is_active);
    }

    /// The D1 user-only frame, byte-pinned against the Swift Core AI
    /// `.chat` frame (CoreAIEngine.frameFor): identical rendered bytes
    /// for the same user prompt is the cross-port frame contract.
    #[test]
    fn user_only_frame_matches_swift_chat_frame() {
        assert_eq!(
            QUANTIZED_RECIPE.assemble_prompt("PROMPT"),
            "<|im_start|>user\nPROMPT<|im_end|>\n<|im_start|>assistant\n"
        );
        // No system turn anywhere in the chat recipes' rendered prompt.
        assert!(!QUANTIZED_RECIPE.assemble_prompt("x").contains("<|im_start|>system"));
    }

    /// Registry contract: every shipped token resolves; unknown tokens
    /// are None (the caller errors loudly, never falls back silently).
    #[test]
    fn recipe_registry_resolves_known_tokens_only() {
        assert_eq!(recipe_for_model("qwen2-0.5b-q4km"), Some(QUANTIZED_RECIPE));
        assert_eq!(recipe_for_model("qwen2.5-0.5b-q4km"), Some(QWEN25_05B_RECIPE));
        assert_eq!(recipe_for_model("nuextract-tiny-q4km"), Some(NUEXTRACT_TINY_RECIPE));
        assert_eq!(recipe_for_model("qwen2.5-1.5b-q4km"), Some(QWEN25_15B_RECIPE));
        assert_eq!(recipe_for_model("qwen3-0.6b-q8"), Some(QWEN3_06B_RECIPE));
        assert_eq!(
            recipe_for_model("osmosis-structure-0.6b-q8"),
            Some(OSMOSIS_STRUCTURE_RECIPE)
        );
        assert_eq!(recipe_for_model("qwen9-77b"), None);
        // Chat descendants share the p2 frame contract; NuExtract's
        // native template never changed, so it stays p1 (explicit pin —
        // struct-update inheritance must not bump it).
        assert_eq!(QWEN25_05B_RECIPE.id(), "qwen2.5-0.5b-q4km-p2-s1");
        assert_eq!(QWEN25_15B_RECIPE.id(), "qwen2.5-1.5b-q4km-p2-s1");
        assert_eq!(NUEXTRACT_TINY_RECIPE.id(), "nuextract-tiny-q4km-p1-s2");
        assert_eq!(QWEN3_06B_RECIPE.id(), "qwen3-0.6b-q8-p1-s1");
        assert_eq!(OSMOSIS_STRUCTURE_RECIPE.id(), "osmosis-structure-0.6b-q8-p1-s1");
        // Osmosis mints JSON through the qwen3 chat frame with the
        // NUEXTRACT-TAIL token budget.
        assert_eq!(OSMOSIS_STRUCTURE_RECIPE.output, MintOutputKind::Json);
        assert!(OSMOSIS_STRUCTURE_RECIPE
            .parameters
            .contains(&("max_new_tokens", "256")));
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

    #[test]
    fn json_same_token_suffixes_retain_and_normalize_only_the_object_prefix() {
        let prefix = r#"{"claim":"kept","nested":[{"literal":"} { \"quoted\""}]}"#;
        let expected_claim = "kept; } { \"quoted\"";
        for suffix in [".", ",", ");\n"] {
            let raw = format!(" {prefix}{suffix}");
            assert_eq!(top_level_json_object_prefix(&raw), Some(prefix));
            assert_eq!(
                normalize_mint_output(&raw, MintOutputKind::Json),
                expected_claim
            );
        }

        assert_eq!(
            top_level_json_object_prefix(
                r#" {"claim":"literal } and \"quoted\"","nested":{"n":1}} trailing"#
            ),
            Some(r#"{"claim":"literal } and \"quoted\"","nested":{"n":1}}"#)
        );
        assert_eq!(
            top_level_json_object_prefix(r#"{"claim":"still open","nested":{"n":1}"#),
            None
        );
        assert_eq!(top_level_json_object_prefix("prose before {\"n\":1}"), None);
        assert_eq!(top_level_json_object_prefix(r#"{"claim":"x",}"#), None);
        assert_eq!(top_level_json_object_prefix(r#"{"a":[1}"#), None);
    }
}
