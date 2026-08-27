/// Moot Mode registry — the five-mode roster, variant sets, and declaration parsing.
///
/// ## What a mode is
///
/// A mode is a named tool bundle (Recall / Filing / Lenses / Vault / Curator)
/// that tells an AI where to look first and lets a client that supports deferred
/// tool loading preload only the active bundle. Modes are ADVISORY and
/// fail-open: every tool keeps working in every mode. No tool is gated by the
/// active mode.
///
/// ## Mode declaration grammar
///
/// The MCP `mode` argument carries a declaration string:
///   `"Recall=Auto"` — mode name + variant (= signals that variants exist)
///   `"Recall"`       — bare name, advisory only
///
/// The `=` deliberately signals other variants to LLM readers.
///
/// ## Unknown mode / variant behavior
///
/// Unknown mode names and unknown variants are ACCEPTED but IGNORED, with a
/// hint line appended to the response. This is fail-open by spec design — in
/// deliberate contrast to the `answer` arg, which is fail-closed (unknown value
/// → invalidParams). Comments in ToolDispatch.swift call this out explicitly
/// so future contributors do not accidentally invert the intent.
///
/// ## Recall variants
///
/// Recall is the only mode with declared variants that change behavior:
///   Recall=Auto    → answer:"auto" session default for moot_memory_search
///   Recall=Rows    → answer:"never" session default (rows-only, current default)
///   Recall=Answer  → answer:"always" session default
///
/// Per-call `answer` arg always overrides the sticky session default (most
/// specific wins). Bare `Recall` clears any sticky variant without setting a new one.

import Foundation

// MARK: - Mode roster

/// The five advisory mode names.
///
/// Each mode corresponds to a verb-family bundle (spec §2).
/// The raw value is the name as it appears in the `mode` argument and the echo tag.
public enum MootMode: String, CaseIterable, Sendable {
    case recall  = "Recall"
    case filing  = "Filing"
    case lenses  = "Lenses"
    case vault   = "Vault"
    case curator = "Curator"

    /// One-line contract for this mode, shown in `moot_estate_status` modes section.
    var contract: String {
        switch self {
        case .recall:  return "Find and read memories; hydrate only winners."
        case .filing:  return "Capture and organize; one fact per drawer."
        case .lenses:  return "Analyze the estate's shape; read-only."
        case .vault:   return "Import/export/reconcile; verify counts."
        case .curator: return "Review, confirm, retire; supersede not delete."
        }
    }

    /// Core tools for this mode (advisory; not enforced).
    var coreTools: [String] {
        switch self {
        case .recall:
            return ["moot_memory_search", "moot_memory_get", "moot_synthesize",
                    "moot_recall_temporal", "moot_recall_precise", "moot_recall_vague"]
        case .filing:
            return ["moot_file_memory", "moot_file_fact", "moot_link_memories",
                    "moot_move_memory", "moot_update_memory"]
        case .lenses:
            return ["moot_list_lenses"] // plus the moot_lens_* family
        case .vault:
            return ["moot_vault_export", "moot_vault_import",
                    "moot_palace_import", "moot_json_import"]
        case .curator:
            return ["moot_confirm_memory", "moot_retire_fact",
                    "moot_hunt_contradictions", "moot_review_tunnel",
                    "moot_fact_timeline"]
        }
    }

    /// Core tools description for the teachme modes guide.
    ///
    /// For Lenses, appends "(plus the moot_lens_* family)" to make the full family
    /// visible in the guide text without listing every individual tool — the comment
    /// in `coreTools` promoted to the rendered string. Matches Rust
    /// `MootMode::core_tools_description()` for byte-identity on the
    /// `modesTeachmeGuide` surface.
    var coreToolsDescription: String {
        switch self {
        case .lenses: return "moot_list_lenses (plus the moot_lens_* family)"
        default:
            return coreTools.isEmpty ? "(applies broadly)" : coreTools.joined(separator: ", ")
        }
    }

    /// Infer the most likely mode for a given tool name (used for mode-attribution
    /// counters when no explicit mode arg is present).
    static func inferredBundle(for toolName: String) -> MootMode? {
        for mode in MootMode.allCases {
            if mode.coreTools.contains(toolName) { return mode }
        }
        // Fallback heuristics for tools not in any core list.
        if toolName.hasPrefix("moot_lens_") { return .lenses }
        if toolName.hasPrefix("moot_vault_") { return .vault }
        if toolName == "moot_memory_search" || toolName == "moot_memory_get" { return .recall }
        if toolName == "moot_file_memory" || toolName == "moot_update_memory" { return .filing }
        return nil
    }

    /// Variants defined for this mode, or empty when the mode has no behavior variants.
    var variantNames: [String] {
        switch self {
        case .recall:  return ["Auto", "Rows", "Answer"]
        default:       return []
        }
    }
}

// MARK: - Recall variants

/// Behavior variant for the Recall mode. Each variant maps to a default
/// `PackagerAnswerMode` for `moot_memory_search` calls in this session.
///
/// Per-call `answer` arg always overrides the variant default (most specific wins).
public enum RecallVariant: String, CaseIterable, Sendable {
    /// answer:"auto" — server picks response level by confidence gate.
    case auto   = "Auto"
    /// answer:"never" — rows only; byte-identical to the pre-packager path. Default.
    case rows   = "Rows"
    /// answer:"always" — compose answer block + rows.
    case answer = "Answer"

    /// The `PackagerAnswerMode` rawValue this variant corresponds to.
    /// Used to inject the session default into `moot_memory_search` decode.
    var answerModeRawValue: String {
        switch self {
        case .auto:   return "auto"
        case .rows:   return "never"
        case .answer: return "always"
        }
    }
}

// MARK: - ModeDeclaration

/// A parsed `mode` argument value: an optional variant on top of a mode name.
///
/// Parse rules:
///   "Recall=Auto"  → ModeDeclaration(modeName: "Recall", variant: "Auto")
///   "Recall"       → ModeDeclaration(modeName: "Recall", variant: nil)
///   "UnknownMode"  → ModeDeclaration(modeName: "UnknownMode", variant: nil) — unknown, accepted
///
/// Unknown mode names and unknown variant names are both accepted but ignored
/// (fail-open), with a hint returned to the caller explaining what is available.
public struct ModeDeclaration: Sendable, Equatable {
    public let modeName: String
    public let variant: String?

    public init(modeName: String, variant: String?) {
        self.modeName = modeName
        self.variant = variant
    }

    /// Parse a raw `mode` argument string into a `ModeDeclaration`.
    public static func parse(_ raw: String) -> ModeDeclaration {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let eqIdx = trimmed.firstIndex(of: "=") {
            let name = String(trimmed[..<eqIdx])
            let after = trimmed[trimmed.index(after: eqIdx)...]
            let variant = after.trimmingCharacters(in: .whitespaces)
            return ModeDeclaration(modeName: name, variant: variant.isEmpty ? nil : variant)
        }
        return ModeDeclaration(modeName: trimmed, variant: nil)
    }

    /// The recognized MootMode for this declaration, or nil when the name is unknown.
    public var recognizedMode: MootMode? {
        MootMode(rawValue: modeName)
    }

    /// The recognized RecallVariant for this declaration (Recall mode only), or nil.
    ///
    /// Returns nil when:
    ///   - The mode is not Recall
    ///   - No variant is declared (bare "Recall")
    ///   - The variant name is unknown
    public var recognizedRecallVariant: RecallVariant? {
        guard recognizedMode == .recall, let v = variant else { return nil }
        return RecallVariant(rawValue: v)
    }

    /// A hint string to append when the mode name or variant is unknown.
    /// Returns nil when both mode name and variant are recognized (or when there
    /// is no variant to check).
    ///
    /// ## Why hint, not invalidParams
    ///
    /// Unknown mode values are fail-open by spec design. The AI may be
    /// running ahead of the server's mode registry (e.g. a variant declared
    /// in a newer spec version). Refusing with invalidParams would break the
    /// AI's session; a hint lets it continue while informing it of the issue.
    /// This is the OPPOSITE of the `answer` arg's fail-closed discipline.
    public var unknownHint: String? {
        let modeNames = MootMode.allCases.map(\.rawValue).joined(separator: ", ")
        if recognizedMode == nil {
            return "unknown mode '\(modeName)' ignored; available: \(modeNames)"
        }
        // Mode is known but variant is unknown (only Recall has variants).
        if let v = variant, recognizedMode == .recall,
           RecallVariant(rawValue: v) == nil {
            let variantNames = RecallVariant.allCases.map(\.rawValue).joined(separator: ", ")
            return "unknown Recall variant '\(v)' ignored; available: \(variantNames)"
        }
        if let v = variant, let mode = recognizedMode, mode != .recall {
            return "mode '\(modeName)' has no variants; '\(v)' ignored"
        }
        return nil
    }
}

// MARK: - Mode status line (for moot_estate_status)

extension MootMode {
    /// One-line status entry for the modes section of `moot_estate_status`.
    var statusLine: String {
        if variantNames.isEmpty {
            return "\(rawValue): \(contract)"
        }
        return "\(rawValue) [\(variantNames.joined(separator: "|"))]: \(contract)"
    }
}
