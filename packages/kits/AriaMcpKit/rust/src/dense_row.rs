//! The progressive-recall dense row (PR-03) — the DEFAULT reply row for
//! every recall-family hit and citation:
//!
//!   `<uuid> · <subject> · fdc:<code> · qid:<QID> · <event_time ISO8601>`
//!
//! Five fields, near-uniform context cost (~45–50 tokens/row): UUID
//! (the address / conversational cursor), subject (the assertion,
//! AI-facing, SPEC § 14), fdc (lattice domain), qid (primary Wikidata
//! entity), event_time (when it happened in the world, ISO8601 UTC).
//!
//! Absence markers are UNIFORM AND FIXED — never a content-prefix
//! fallback. A missing subject renders `(no subject)` so absence is
//! visible (it IS the subject-debt signal at the reply surface).
//!
//! Redaction wins over subject: a restricted/secret row's redaction
//! marker REPLACES the subject field — the body's access control must
//! not be bypassable through its summary. fdc/qid/event_time are
//! lattice metadata, not content, and stay visible.
//!
//! Twin of Swift `DenseRow.swift`; the shared golden fixture proves the
//! two ports render byte-identical rows.

use locus_kit::drawer::Drawer;
use locus_kit::provenance::Sensitivity;

/// Fixed absence marker for a NULL subject (subject debt, B-21).
pub const NO_SUBJECT_MARKER: &str = "(no subject)";
/// Fixed absence marker for an empty/sentinel-free field.
pub const ABSENT_FIELD: &str = "-";
/// Field separator. Middle dot: visually scannable, never appears in
/// UUIDs/codes, and single-token cheap.
pub const SEPARATOR: &str = " · ";

/// Redaction markers, keyed by provenance sensitivity. Same strings the
/// pre-dense reply surface used, so grant workflows keep one vocabulary.
pub const RESTRICTED_MARKER: &str = "[sensitivity: restricted — content redacted]";
pub const SECRET_MARKER: &str =
    "[sensitivity: secret — content access requires explicit grant]";

/// Milliseconds/seconds discriminator threshold. The Rust `Drawer`
/// carries bare `i64` instants and BOTH conventions are live today:
/// the aria-mcp write path stamps `wall_now()` (epoch ms) while
/// LocusKit fixtures and the seeding path use epoch seconds (the
/// documented i64 unit trap — KI-003 re-types this in v1.1). Any value
/// at or above this threshold (~5138 CE in seconds, ~1973 in ms) is
/// unambiguously milliseconds. Deterministic, no clock consulted.
const MS_THRESHOLD: i64 = 100_000_000_000;

/// Unit-normalizing ISO8601 renderer for drawer instants: accepts
/// either epoch seconds or epoch milliseconds and renders seconds
/// precision either way. The dense row is the default reply surface —
/// it must not print year-56xx garbage for ms-written rows while the
/// unit re-type (KI-003) is pending.
pub fn iso8601_flex(epoch: i64) -> String {
    if epoch.abs() >= MS_THRESHOLD {
        iso8601_utc(epoch.div_euclid(1000))
    } else {
        iso8601_utc(epoch)
    }
}

/// Epoch seconds → ISO8601 UTC with seconds precision
/// (`2026-08-02T12:00:00Z`) — byte-identical to Swift's
/// `ISO8601DateFormatter` `.withInternetDateTime` output. Proleptic
/// Gregorian civil-from-days conversion; no external time crate (C-1).
pub fn iso8601_utc(epoch_secs: i64) -> String {
    let days = epoch_secs.div_euclid(86_400);
    let secs_of_day = epoch_secs.rem_euclid(86_400);
    let (h, m, s) = (secs_of_day / 3600, (secs_of_day % 3600) / 60, secs_of_day % 60);
    // Howard Hinnant's civil_from_days algorithm.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mth = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mth <= 2 { y + 1 } else { y };
    format!("{y:04}-{mth:02}-{d:02}T{h:02}:{m:02}:{s:02}Z")
}

/// Render one dense row for a drawer.
///
/// The subject slot resolves in priority order: redaction marker
/// (restricted/secret provenance sensitivity) → stored subject →
/// `NO_SUBJECT_MARKER`. Everything else is verbatim lattice metadata.
pub fn render(drawer: &Drawer) -> String {
    let subject_field: &str = match drawer.sensitivity() {
        Sensitivity::Restricted => RESTRICTED_MARKER,
        Sensitivity::Secret => SECRET_MARKER,
        _ => drawer.subject.as_deref().unwrap_or(NO_SUBJECT_MARKER),
    };
    let fdc: &str = if drawer.udc_code.is_empty() { ABSENT_FIELD } else { &drawer.udc_code };
    let qid: &str = match drawer.wikidata_qid.as_deref() {
        Some(q) if !q.is_empty() => q,
        _ => ABSENT_FIELD,
    };
    [
        drawer.id.as_str(),
        subject_field,
        &format!("fdc:{fdc}"),
        &format!("qid:{qid}"),
        &iso8601_flex(drawer.event_time),
    ]
    .join(SEPARATOR)
}

/// Render a dense row for a hit returned without a hydrated drawer
/// (defensive: structured-tier callers). The address is still useful;
/// every other field shows its absence marker so row cost stays uniform.
pub fn render_unhydrated(id: &str) -> String {
    [
        id,
        NO_SUBJECT_MARKER,
        &format!("fdc:{ABSENT_FIELD}"),
        &format!("qid:{ABSENT_FIELD}"),
        ABSENT_FIELD,
    ]
    .join(SEPARATOR)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso8601_matches_known_instants() {
        assert_eq!(iso8601_utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601_utc(1_700_000_000), "2023-11-14T22:13:20Z");
        // Leap-year boundary.
        assert_eq!(iso8601_utc(951_782_400), "2000-02-29T00:00:00Z");
        // Pre-epoch (negative seconds).
        assert_eq!(iso8601_utc(-86_400), "1969-12-31T00:00:00Z");
    }
}
