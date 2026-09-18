//! ARIASessionProtocol — the static orientation string appended to every
//! `moot_estate_status` response.
//!
//! Mirrors Swift `SessionProtocol.swift` (ARIA_SESSION_PROTOCOL constant).
//! Content is byte-identical to the Swift constant so the two servers
//! produce the same wire output for `moot_estate_status`.

/// Static orientation block appended to every `moot_estate_status` response.
/// Instructs the AI client on the ARIA surface and coaching workflow.
///
/// Parity: byte-identical to Swift `SessionProtocol.ARIASessionProtocol`.
pub const ARIA_SESSION_PROTOCOL: &str = "\n\nprotocol:\
\n  \u{2014} Call moot_estate_status with teachme:true to receive the orientation guide (no status payload is returned).\
\n  \u{2014} Call moot_list_lenses to see available cognition tools.\
\n  \u{2014} Add teachme:true to any tool to learn it before using it.\
\n  \u{2014} Watch for hint: lines in responses \u{2014} they contain coaching for better results.\
\n  \u{2014} Declare a mode with mode:\"Recall=Auto\" on any call to set the session default; full global-modifiers grammar in moot_help directory.\
\n  \u{2014} File memories: moot_file_memory (content + subject + location required).\
\n  \u{2014} Search memories: moot_memory_search (query required).\
\n  \u{2014} Write journal entries: moot_write_journal after meaningful sessions.\
\n  \u{2014} Store structured facts: moot_file_fact (subject + predicate + object).";

/// Render the modes section for every `moot_estate_status` response.
///
/// Produces a string byte-identical to Swift `SessionProtocol.modesStatusSection`
/// by calling `MootMode::status_line()` on each mode (the single canonical renderer
/// for this surface). Swift's computed property reads the same mode-registry data
/// at startup; both ports therefore agree whenever the registry changes.
///
/// The section is rendered at call time rather than stored as a const so that
/// the Rust and Swift outputs are provably derived from the same renderer logic
/// rather than two independently hand-typed strings. A shared-fixture byte-
/// identity test in `modes_tests.rs` / `PeriodicCoachTests.swift` pins the
/// rendered output.
pub fn modes_status_section() -> String {
    use crate::mode_registry::MootMode;
    let lines: Vec<String> = MootMode::all_cases()
        .iter()
        .map(|m| format!("  {}", m.status_line()))
        .collect();
    // The string starts with a single \n so that when appended after
    // ARIA_SESSION_PROTOCOL (which itself ends with a newline), the
    // concatenation on the wire reads as two blank-line-separated
    // sections. Mirrors Swift's modesStatusSection which also starts
    // with a single leading newline from its multiline literal.
    format!(
        "\nmodes (advisory bundles \u{2014} add mode:\"Recall=Auto\" etc. to any call):\
         \n{}\
         \n  \u{2014} Modes change session defaults (e.g. Recall=Auto sets answer:auto on search).\
         \n  \u{2014} Add teachme:true to moot_estate_status for variants and decision guidance.",
        lines.join("\n")
    )
}
