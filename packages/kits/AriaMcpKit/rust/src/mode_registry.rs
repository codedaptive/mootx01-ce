//! Moot Mode registry — the five-mode roster, variant sets, and declaration parsing.
//!
//! ## What a mode is
//!
//! A mode is a named tool bundle (Recall / Filing / Lenses / Vault / Curator)
//! that tells an AI where to look first and lets a client that supports deferred
//! tool loading preload only the active bundle. Modes are ADVISORY and fail-open:
//! every tool keeps working in every mode.
//!
//! ## Mode declaration grammar
//!
//! The MCP `mode` argument carries a declaration string:
//!   `"Recall=Auto"` — mode name + variant
//!   `"Recall"`       — bare name, advisory only
//!
//! ## Fail-open contract
//!
//! Unknown mode names and unknown variants are ACCEPTED but IGNORED, with a hint
//! line appended to the response. This is fail-open by spec design — in deliberate
//! contrast to the `answer` arg, which is fail-closed (unknown value → invalidParams).
//!
//! ## Recall variants
//!
//! Recall is the only mode with declared variants that change behavior:
//!   Recall=Auto    → answer:"auto" session default for moot_memory_search
//!   Recall=Rows    → answer:"never" session default (rows-only, current default)
//!   Recall=Answer  → answer:"always" session default
//!
//! Parity: Rust twin of Swift mode registry (v1, removed in ARIA v2).

// MARK: - Mode roster

/// The five advisory mode names.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum MootMode {
    Recall,
    Filing,
    Lenses,
    Vault,
    Curator,
}

impl MootMode {
    /// All modes in canonical order (Recall first — the primary use-case mode).
    pub fn all_cases() -> &'static [MootMode] {
        use MootMode::*;
        &[Recall, Filing, Lenses, Vault, Curator]
    }

    /// The raw string value as it appears in the `mode` argument.
    pub fn raw_value(&self) -> &'static str {
        match self {
            MootMode::Recall  => "Recall",
            MootMode::Filing  => "Filing",
            MootMode::Lenses  => "Lenses",
            MootMode::Vault   => "Vault",
            MootMode::Curator => "Curator",
        }
    }

    /// Parse a mode name string → MootMode. Returns None for unrecognized names.
    pub fn parse(name: &str) -> Option<MootMode> {
        match name {
            "Recall"  => Some(MootMode::Recall),
            "Filing"  => Some(MootMode::Filing),
            "Lenses"  => Some(MootMode::Lenses),
            "Vault"   => Some(MootMode::Vault),
            "Curator" => Some(MootMode::Curator),
            _ => None,
        }
    }

    /// One-line contract for this mode, shown in `moot_estate_status` modes section.
    pub fn contract(&self) -> &'static str {
        match self {
            MootMode::Recall  => "Find and read memories; hydrate only winners.",
            MootMode::Filing  => "Capture and organize; one fact per drawer.",
            MootMode::Lenses  => "Analyze the estate's shape; read-only.",
            MootMode::Vault   => "Import/export/reconcile; verify counts.",
            MootMode::Curator => "Review, confirm, retire; supersede not delete.",
        }
    }

    /// Core tools for this mode (advisory; not enforced).
    pub fn core_tools(&self) -> &'static [&'static str] {
        match self {
            MootMode::Recall => &[
                "moot_memory_search", "moot_memory_get", "moot_synthesize",
                "moot_recall_temporal", "moot_recall_precise", "moot_recall_vague",
            ],
            MootMode::Filing => &[
                "moot_file_memory", "moot_file_fact", "moot_link_memories",
                "moot_move_memory", "moot_update_memory",
            ],
            MootMode::Lenses => &["moot_list_lenses"],
            MootMode::Vault  => &[
                "moot_vault_export", "moot_vault_import",
                "moot_palace_import", "moot_json_import",
            ],
            MootMode::Curator => &[
                "moot_confirm_memory", "moot_retire_fact",
                "moot_hunt_contradictions", "moot_review_tunnel",
                "moot_fact_timeline",
            ],
        }
    }

    /// Infer the bundle a tool belongs to by its name prefix, or None when the
    /// tool spans multiple modes (estate-management tools, for example).
    pub fn inferred_bundle(tool_name: &str) -> Option<MootMode> {
        if tool_name == "moot_memory_search"
            || tool_name == "moot_memory_get"
            || tool_name == "moot_synthesize"
            || tool_name.starts_with("moot_recall_")
        {
            return Some(MootMode::Recall);
        }
        if tool_name == "moot_file_memory"
            || tool_name == "moot_file_fact"
            || tool_name == "moot_link_memories"
            || tool_name == "moot_move_memory"
            || tool_name == "moot_update_memory"
            || tool_name == "moot_confirm_memory"
        {
            return Some(MootMode::Filing);
        }
        if tool_name.starts_with("moot_lens_") || tool_name == "moot_list_lenses" {
            return Some(MootMode::Lenses);
        }
        if tool_name.starts_with("moot_vault_")
            || tool_name == "moot_palace_import"
            || tool_name == "moot_json_import"
        {
            return Some(MootMode::Vault);
        }
        if tool_name == "moot_retire_fact"
            || tool_name == "moot_hunt_contradictions"
            || tool_name == "moot_review_tunnel"
            || tool_name == "moot_fact_timeline"
        {
            return Some(MootMode::Curator);
        }
        None
    }

    /// Status line for the `moot_estate_status` modes section.
    ///
    /// Format matches Swift mode registry statusLine exactly for byte-identity:
    ///   with variants:    "Recall [Auto|Rows|Answer]: contract"
    ///   without variants: "ModeName: contract"
    ///
    /// The `—` (em-dash) format used before this fix was wrong parity;
    /// Swift uses `: ` as the separator, not ` — `.
    pub fn status_line(&self) -> String {
        let variant_names = if *self == MootMode::Recall {
            vec!["Auto", "Rows", "Answer"]
        } else {
            vec![]
        };
        if variant_names.is_empty() {
            format!("{}: {}", self.raw_value(), self.contract())
        } else {
            format!("{} [{}]: {}", self.raw_value(), variant_names.join("|"), self.contract())
        }
    }

    /// Core tools description for the teachme modes guide.
    ///
    /// Returns the core tool list as a comma-joined string. For Lenses,
    /// appends "(plus the moot_lens_* family)" to make the family visible
    /// in the guide without listing every individual lens tool. Mirrors
    /// the comment promoted to a string in Swift's `modesTeachmeGuide`.
    pub fn core_tools_description(&self) -> String {
        match self {
            MootMode::Lenses => "moot_list_lenses (plus the moot_lens_* family)".to_string(),
            _ => {
                let tools = self.core_tools();
                if tools.is_empty() {
                    "(applies broadly)".to_string()
                } else {
                    tools.join(", ")
                }
            }
        }
    }
}

// MARK: - Recall variants

/// Variants of the Recall mode that change the answer default on moot_memory_search.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecallVariant {
    /// answer:auto — server decides whether to synthesize (confidence-gated).
    Auto,
    /// answer:never — dense rows only, no synthesis (fastest). The pre-modes default.
    Rows,
    /// answer:always — always compose a synthesis block over the result rows.
    Answer,
}

impl RecallVariant {
    /// Parse from the variant string (the part after `=`). Case-sensitive.
    pub fn parse(variant: &str) -> Option<RecallVariant> {
        match variant {
            "Auto"   => Some(RecallVariant::Auto),
            "Rows"   => Some(RecallVariant::Rows),
            "Answer" => Some(RecallVariant::Answer),
            _ => None,
        }
    }

    /// The `answer` arg raw value this variant maps to.
    pub fn answer_mode_raw_value(&self) -> &'static str {
        match self {
            RecallVariant::Auto   => "auto",
            RecallVariant::Rows   => "never",
            RecallVariant::Answer => "always",
        }
    }
}

// MARK: - Mode declaration

/// A parsed mode declaration from the `mode` argument string.
///
/// The grammar is: `"ModeName"` (bare) or `"ModeName=Variant"`.
///
/// Parse is always successful (fail-open): unrecognized names and unrecognized
/// variants produce a `ModeDeclaration` with `recognized_mode == None` /
/// `recognized_recall_variant == None`, and `unknown_hint` returns the advisory text.
#[derive(Debug, Clone)]
pub struct ModeDeclaration {
    /// The mode name as supplied by the caller (not normalized).
    pub mode_name: String,
    /// The variant string (the part after `=`), if present in the declaration.
    pub variant: Option<String>,
}

impl ModeDeclaration {
    /// Parse a mode declaration string. Always succeeds (fail-open).
    pub fn parse(raw: &str) -> ModeDeclaration {
        if let Some(eq_pos) = raw.find('=') {
            let name = raw[..eq_pos].to_string();
            let variant = raw[eq_pos + 1..].to_string();
            ModeDeclaration {
                mode_name: name,
                variant: Some(variant),
            }
        } else {
            ModeDeclaration {
                mode_name: raw.to_string(),
                variant: None,
            }
        }
    }

    /// The recognized MootMode for this declaration's name, or None for unrecognized names.
    pub fn recognized_mode(&self) -> Option<MootMode> {
        MootMode::parse(&self.mode_name)
    }

    /// The recognized RecallVariant for this declaration, or None when:
    ///   - the mode is not Recall
    ///   - no variant was specified (bare mode name)
    ///   - the variant string is unrecognized
    pub fn recognized_recall_variant(&self) -> Option<RecallVariant> {
        if self.recognized_mode() != Some(MootMode::Recall) {
            return None;
        }
        self.variant.as_deref().and_then(RecallVariant::parse)
    }

    /// Advisory hint text to append when the declaration contains something
    /// unrecognized (unknown mode or unknown variant). None when fully recognized.
    pub fn unknown_hint(&self) -> Option<String> {
        // Returns bare message text — the caller (append_hint_to_result in dispatcher.rs)
        // prepends "hint: " when embedding this in the wire text. Returning without the
        // prefix here prevents the double "hint: hint: …" that results when the dispatcher
        // also adds the prefix.
        let known_names: &[&str] = &["Recall", "Filing", "Lenses", "Vault", "Curator"];
        if !known_names.contains(&self.mode_name.as_str()) {
            return Some(format!(
                "mode \"{}\" is not in the mode roster (Recall, Filing, Lenses, Vault, Curator). \
                 Mode was accepted but has no effect — try mode:\"Recall\" or mode:\"Recall=Auto\".",
                self.mode_name
            ));
        }
        // Known mode name — check variant if present.
        if let Some(variant_str) = &self.variant {
            if self.recognized_recall_variant().is_none() {
                if self.recognized_mode() == Some(MootMode::Recall) {
                    return Some(format!(
                        "Recall variant \"{}\" is not recognized (Auto, Rows, Answer). \
                         Variant was accepted but has no effect — try mode:\"Recall=Auto\".",
                        variant_str
                    ));
                }
                // Non-Recall mode with a variant — not an error; variants don't apply.
                return Some(format!(
                    "mode \"{}\" does not support variants. \
                     Variant was accepted but has no effect — omit the ={}.",
                    self.mode_name, variant_str
                ));
            }
        }
        None
    }
}
