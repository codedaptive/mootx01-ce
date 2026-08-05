// DenseRow.swift
//
// The progressive-recall dense row (PR-03) — the DEFAULT reply row for
// every recall-family hit and citation:
//
//   <uuid> · <subject> · fdc:<code> · qid:<QID> · <event_time ISO8601>
//
// Five fields, near-uniform context cost (~45–50 tokens/row):
//   UUID       — the address; the conversational cursor for follow-up
//                (memory_get, near:, link/mutate verbs).
//   subject    — the assertion (AI-facing, ≤120 chars, SPEC § 14).
//   fdc        — the lattice anchor (udcCode), the domain coordinate.
//   qid        — the primary Wikidata entity, the who/what coordinate.
//   event_time — when the content happened in the world (ISO8601 UTC).
//
// Absence markers are UNIFORM AND FIXED — never a content-prefix
// fallback. A missing subject renders "(no subject)" so absence is
// visible (it IS the subject-debt signal at the reply surface); a
// content prefix here would silently reward never writing subjects.
//
// Redaction wins over subject: the subject is content-derived text, so
// a restricted/secret row's redaction marker REPLACES the subject
// field — the body's access control must not be bypassable through its
// summary. The other three coordinates (fdc/qid/event_time) are
// lattice metadata, not content, and stay visible.
//
// The Rust twin (`dense_row.rs`) must produce byte-identical rows —
// proven by the shared golden fixture (DenseRowGoldenTests ↔
// dense_row_golden test).

import Foundation
import LocusKit

enum DenseRow {

    /// Fixed absence marker for a NULL subject (subject debt, B-21).
    static let noSubjectMarker = "(no subject)"
    /// Fixed absence marker for an empty/sentinel-free field.
    static let absentField = "-"
    /// Field separator. Middle dot: visually scannable, never appears
    /// in UUIDs/codes, and single-token cheap.
    static let separator = " · "

    /// Redaction markers, keyed by provenance sensitivity. Same strings
    /// the pre-dense reply surface used, so grant workflows and tests
    /// keep one vocabulary.
    static let restrictedMarker = "[sensitivity: restricted — content redacted]"
    static let secretMarker = "[sensitivity: secret — content access requires explicit grant]"

    /// ISO8601 UTC with seconds precision (`2026-08-02T12:00:00Z`),
    /// rendered arithmetically (civil-from-days) rather than through
    /// `ISO8601DateFormatter` — the formatter is not Sendable under
    /// strict concurrency, and the arithmetic path is the SAME algorithm
    /// the Rust twin uses, so the golden fixture proves byte identity
    /// directly.
    static func iso8601(_ date: Date) -> String {
        let epoch = Int64(date.timeIntervalSince1970.rounded(.down))
        let days = Int64((Double(epoch) / 86_400).rounded(.down))
        let secsOfDay = epoch - days * 86_400
        let (h, m, s) = (secsOfDay / 3600, (secsOfDay % 3600) / 60, secsOfDay % 60)
        // Howard Hinnant's civil_from_days algorithm — twin of
        // dense_row.rs::iso8601_utc.
        let z = days + 719_468
        let era = Int64((Double(z) / 146_097).rounded(.down))
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        var y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let mth = mp < 10 ? mp + 3 : mp - 9
        if mth <= 2 { y += 1 }
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", y, mth, d, h, m, s)
    }

    /// Render one dense row for a drawer.
    ///
    /// The subject slot resolves in priority order: redaction marker
    /// (restricted/secret provenance sensitivity) → stored subject →
    /// `noSubjectMarker`. Everything else is verbatim lattice metadata.
    static func render(_ drawer: Drawer) -> String {
        let subjectField: String
        switch drawer.sensitivity {
        case .restricted: subjectField = restrictedMarker
        case .secret: subjectField = secretMarker
        case .normal, .elevated:
            subjectField = drawer.subject ?? noSubjectMarker
        }
        let fdc = drawer.udcCode.isEmpty ? absentField : drawer.udcCode
        let qid = (drawer.wikidataQID?.isEmpty ?? true) ? absentField : drawer.wikidataQID!
        return [
            drawer.id,
            subjectField,
            "fdc:\(fdc)",
            "qid:\(qid)",
            iso8601(drawer.eventTime),
        ].joined(separator: separator)
    }

    /// Render a dense row for a hit that was returned without a
    /// hydrated drawer (defensive: structured-tier callers). The
    /// address is still useful; every other field shows its absence
    /// marker so the row cost stays uniform.
    static func renderUnhydrated(id: String) -> String {
        [id, noSubjectMarker, "fdc:\(absentField)", "qid:\(absentField)", absentField]
            .joined(separator: separator)
    }
}
