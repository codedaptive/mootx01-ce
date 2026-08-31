// MinterRecipe.swift
//
// Compile-time minter recipes and the generic mint-output normalizer
// (ADORNMENTLIB_SPEC 0.6.0 § Minter recipes).
//
// A RECIPE is the complete generation contract of one product minter:
// model + prompt template + generation settings + output payload kind.
// The composed ID `<model>-p<promptVersion>-s<settingsVersion>` is the
// minter identity written to the `adornment_minters` master and stamped
// on every adornment row — the SAME identity regardless of which port
// minted (rows are interchangeable across ports and sync freely; the
// port is the executor, never part of the contract).
//
// Model choice is a DEVELOPER BUILD-TIME decision (Bob, 2026-08-26):
// the recipes below are plain constants, flippable at compile time via
// the Makefile/sed. There is no runtime model discovery and no
// user-facing swap surface in this edition.
//
// ── RECIPE VERSION LEDGER ───────────────────────────────────────────────
// Git is the history: this block always states ONLY the current recipes;
// retired recipe content lives in `git log` on this file, and retired
// IDs live forever in every estate's `adornment_minters` rows (with
// digests proving which recipe they were).
//
//   apple-fm             p1  s1   (Apple FoundationModels; OS-resident weights)
//   qwen2-0.5b-q4km      p2  s1   (Rust quantized engine default GGUF;
//                                  p2 = user-only frame, D1 ruling 2026-08-31)
//   qwen2.5-0.5b-q4km    p2  s1   (Rust registry)
//   nuextract-tiny-q4km  p1  s1   (Rust registry; native template unchanged)
//   qwen2.5-1.5b-q4km    p2  s1   (Rust registry; reference arm)
//
// RULES (mirror of the bitmap-bit doctrine):
//   - NEVER reuse a version number. A retired p2 means the next prompt is
//     p3 even if p2 lived for a day — estates may carry rows minted
//     under it and the digest must stay unambiguous.
//   - Any change to the prompt template bumps pN; any change to a
//     generation-affecting setting bumps sN; a different model artifact
//     is a different model token. Bump in the SAME commit as the change.
//   - The digests below are recomputed from the live constants at
//     runtime, so an edit without a version bump is mechanically
//     detectable against the registered master row.
// ────────────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Output payload kinds

/// The payload shape a minting model emits. There are exactly two shapes
/// in the wild — a prose line, or JSON — and one normalizer handles both,
/// so any model of either shape is a recipe entry, never new code.
public enum MintOutputKind: String, Sendable, Equatable {
    /// Model emits the claim as prose; first non-empty content line wins.
    case text
    /// Model emits JSON; the normalizer flattens it deterministically
    /// into the semicolon-separated claim line.
    case json
}

// MARK: - Recipe

/// One complete minter generation contract. Pure value; the built-in
/// recipes below are the compile-time constants block.
public struct MinterRecipe: Sendable, Equatable {
    /// Model token of the composed ID (e.g. "qwen2-0.5b-q4km"). Names the
    /// model ARTIFACT contract, never the executing port.
    public let model: String
    /// Prompt-template version (the `pN` component).
    public let promptVersion: Int
    /// Generation-settings version (the `sN` component).
    public let settingsVersion: Int
    /// The system/instruction prompt template this recipe mints with.
    public let systemPrompt: String
    /// The full prompt wrapper for raw-completion engines, with `{system}`
    /// and `{input}` placeholders. Session-based engines (Apple) pass
    /// `systemPrompt` to their session API and never render this; their
    /// recipes carry the trivial wrapper. Part of the prompt contract:
    /// covered by `promptDigest`.
    public let chatTemplate: String
    /// Every generation-affecting setting, canonical string map
    /// (serialized in lexical key order everywhere).
    public let parameters: [String: String]
    /// Payload shape the model emits; drives the normalizer branch.
    public let output: MintOutputKind
    /// Minter family for the master row (e.g. "apple", "quantized").
    public let family: String

    public init(
        model: String,
        promptVersion: Int,
        settingsVersion: Int,
        systemPrompt: String,
        chatTemplate: String,
        parameters: [String: String],
        output: MintOutputKind,
        family: String
    ) {
        self.model = model
        self.promptVersion = promptVersion
        self.settingsVersion = settingsVersion
        self.systemPrompt = systemPrompt
        self.chatTemplate = chatTemplate
        self.parameters = parameters
        self.output = output
        self.family = family
    }

    /// The composed minter identity: `<model>-p<promptVersion>-s<settingsVersion>`.
    /// This exact string is the cross-port minter identity on adornment rows.
    public var id: String { "\(model)-p\(promptVersion)-s\(settingsVersion)" }

    /// Digest of the live prompt contract (FNV-1a 64, hex): the chat
    /// template with `{system}` resolved (leaving `{input}`), so BOTH the
    /// instruction text and the wrapper shape are covered. A prompt edit
    /// without a pN bump fails the registration comparison mechanically.
    public var promptDigest: String {
        fnv1a64Hex(chatTemplate.replacingOccurrences(of: "{system}", with: systemPrompt))
    }

    /// Render the full prompt for a raw-completion engine: `{system}` and
    /// `{input}` substituted into the chat template.
    public func assemblePrompt(_ rawInput: String) -> String {
        chatTemplate
            .replacingOccurrences(of: "{system}", with: systemPrompt)
            .replacingOccurrences(of: "{input}", with: rawInput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Digest of the canonical settings serialization (lexical key order,
    /// `key=value` lines). Same mechanical-mismatch role as promptDigest.
    public var parametersDigest: String {
        let canonical = parameters.keys.sorted()
            .map { "\($0)=\(parameters[$0] ?? "")" }
            .joined(separator: "\n")
        return fnv1a64Hex(canonical)
    }

    /// Build the master-row descriptor for this recipe. `id` is the
    /// persistence-assigned row identifier; the recipe's composed ID
    /// travels as `name`, and the digests + parameters carry the
    /// verification material. The parameters map includes the settings
    /// digest under `settings_digest` so the stored row is self-checking.
    public func descriptor(id rowID: String, isActive: Bool) -> AdornmentMinterDescriptor {
        var params = parameters
        params["settings_digest"] = parametersDigest
        return AdornmentMinterDescriptor(
            id: rowID,
            name: self.id,
            family: family,
            modelID: model,
            modelVersion: "p\(promptVersion)-s\(settingsVersion)",
            promptDigest: promptDigest,
            parameters: params,
            isActive: isActive
        )
    }
}

// MARK: - Built-in recipes (the compile-time constants block)

extension MinterRecipe {
    /// Apple FoundationModels minter. The weights are OS-resident and move
    /// with OS updates, so the model token is coarser than the GGUF
    /// families by platform necessity; OS/framework version is recorded as
    /// provenance at registration time, not identity.
    public static let apple = MinterRecipe(
        model: "apple-fm",
        promptVersion: 1,
        settingsVersion: 1,
        systemPrompt: "You are a precise fact extractor. Output exactly one concise factual claim and nothing else.",
        // Session-based engine: the OS API takes instructions + prompt
        // directly, so the wrapper is the trivial form.
        chatTemplate: "{system}\n{input}",
        parameters: [
            "sampling": "greedy",
            "max_length": "280",
        ],
        output: .text,
        family: "apple"
    )
}

// MARK: - Digest (FNV-1a 64)

/// FNV-1a 64-bit digest, lowercase hex. Deliberately NOT cryptographic:
/// its job is mechanical recipe-mismatch detection, and it must produce
/// IDENTICAL values in both ports with zero dependencies. Twin of the
/// Rust `fnv1a64_hex`; golden-pinned in both test suites.
public func fnv1a64Hex(_ s: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in Array(s.utf8) {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return String(format: "%016llx", hash)
}

// MARK: - Output normalizer

/// Normalize a raw model emission into the claim line, per the recipe's
/// output kind. ONE implementation covers every model shape:
///   - `.text`: first meaningful prose line (fences, list markers, and
///     control tokens stripped).
///   - `.json`: deterministic flattening — lexical key order, nested
///     values recursed, fragments joined with "; ". A JSON payload that
///     fails to parse falls back to the text path (deterministic salvage
///     of a non-compliant emission).
/// Returns "" when nothing usable remains (per-prompt failure upstream).
/// Twin of the Rust `normalize_mint_output`; shared golden fixtures.
public func normalizeMintOutput(_ raw: String, kind: MintOutputKind) -> String {
    switch kind {
    case .text:
        return extractClaimLine(raw)
    case .json:
        let stripped = stripCodeFences(raw)
        guard let data = stripped.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return extractClaimLine(raw)
        }
        var fragments: [String] = []
        flattenJSON(parsed, into: &fragments)
        return fragments.joined(separator: "; ")
    }
}

/// First meaningful prose line: skip fence lines, strip leading list
/// markers, drop chat-template control tokens, trim. The canonical
/// claim-line extraction shared by every text-shaped engine.
public func extractClaimLine(_ raw: String) -> String {
    for line in raw.split(separator: "\n") {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("```") { continue }
        while let first = s.first, "-*•".contains(first) {
            s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        s = s.replacingOccurrences(of: "<|im_end|>", with: "")
            .replacingOccurrences(of: "<|endoftext|>", with: "")
            .trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { return s }
    }
    return ""
}

/// Remove a surrounding markdown code fence (``` or ```json) so fenced
/// JSON parses. Interior lines are preserved verbatim.
private func stripCodeFences(_ raw: String) -> String {
    let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Deterministic JSON flattening: strings pass through (trimmed, empties
/// skipped), numbers and bools render canonically, null is skipped,
/// arrays recurse in order, objects recurse in LEXICAL key order.
private func flattenJSON(_ value: Any, into fragments: inout [String]) {
    switch value {
    case let s as String:
        let t = s.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { fragments.append(t) }
    case let n as NSNumber:
        // JSONSerialization surfaces bools as NSNumber; render true/false
        // rather than 1/0 so both ports agree byte-for-byte.
        if CFGetTypeID(n) == CFBooleanGetTypeID() {
            fragments.append(n.boolValue ? "true" : "false")
        } else {
            fragments.append(canonicalNumber(n))
        }
    case let a as [Any]:
        for item in a { flattenJSON(item, into: &fragments) }
    case let o as [String: Any]:
        for key in o.keys.sorted() {
            if let item = o[key] { flattenJSON(item, into: &fragments) }
        }
    default:
        break // null (NSNull) and anything unrenderable: skipped
    }
}

/// Integer-backed numbers render via int64Value so values beyond
/// Double's 53-bit mantissa stay exact (twin of Rust's as_i64-first
/// path); float-backed numbers render via the Double description.
private func canonicalNumber(_ n: NSNumber) -> String {
    if !CFNumberIsFloatType(n) {
        return String(n.int64Value)
    }
    let d = n.doubleValue
    if d == d.rounded(.towardZero), abs(d) < 1e15 {
        return String(Int64(d))
    }
    return "\(d)"
}
