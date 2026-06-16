//! ARIASessionProtocol — the static orientation string appended to every
//! `moot_estate_status` response.
//!
//! Mirrors Swift `SessionProtocol.swift` (ARIA_SESSION_PROTOCOL constant).
//! Content is byte-identical to the Swift constant so the two servers
//! produce the same wire output for `moot_estate_status`.

/// Static orientation block appended to every `moot_estate_status` response.
/// Instructs the AI client on the ARIA surface and coaching workflow.
pub const ARIA_SESSION_PROTOCOL: &str = "\n\nprotocol:\
\n  \u{2014} Call moot_estate_status with teachme:true for a full orientation guide.\
\n  \u{2014} Call moot_list_lenses to see available cognition tools.\
\n  \u{2014} Add teachme:true to any tool to learn it before using it.\
\n  \u{2014} Watch for hint: lines in responses \u{2014} they contain coaching for better results.\
\n  \u{2014} File memories: moot_file_memory (content + location required).\
\n  \u{2014} Search memories: moot_memory_search (query required).\
\n  \u{2014} Write journal entries: moot_write_journal after meaningful sessions.\
\n  \u{2014} Store structured facts: moot_file_fact (subject + predicate + object).";
