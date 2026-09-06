// ResultComposer.swift
//
// The one shared result composer for every ARIA MCP return shape
// (ARIA_MCP_SPEC 2.0.0 § 8 composer invariant). Tools supply typed
// result data — CandidateRowData, ControlSignals, surface-specific
// records — and never rendered text; this file is the only code path
// that renders text payloads and builds structuredContent JSON, so
// text/structured parity holds by construction and a new retrieval
// technique cannot emit an off-contract payload.
//
// ## Shape coverage
//
// S1 — ranked memory candidates (§11.2)
//   renderS1Surface(rows:control:)
// S2 — unranked memory rows (§11.5)
//   renderS2Listing(wing:room:rows:)
//   renderS2BatchGet(rows:resolved:requested:)
// S3 — full record hydration (§11.6)
//   renderS3Record(_:)
// S4 — fact rows (§11.7)
//   renderS4FactSearch(facts:)
//   renderS4FactTimeline(facts:)
// S5 — graph-edge rows (§11.8)
//   renderS5Edges(direction:edges:)
// S6 — tabular rows (§11.9)
//   renderS6Query(_:)
//   renderS6Stats(_:)
// Synthesis — grounded synthesis document (§11.4)
//   renderSynthesis(_:)
// Vague — two-tier vague recall (§11.2)
//   renderVagueRecall(summaries:originals:control:)
// Distilled — distilled recall with continuation lines (§11.2)
//   renderDistilledRecall(rows:control:)
// Federated — per-estate sections (§11.2)
//   renderFederatedRecall(estates:)
// Empty — zero-count header with optional hint (§11.1 rule 7)
//   renderEmptyS1(hint:)
//   renderEmptyS2Listing(wing:room:)
//
// ## Normalization rules (§11.1)
//
//   normalizeValue(_:) applies to EVERY S1/S2/S4/S5 field value:
//     - embedded newlines → single space
//     - whitespace runs → one space (trim leading/trailing)
//     - literal U+00B7 middle-dot → '-'
//   S6 values are EXEMPT from normalization — they use lossless quoting.
//   The separator is ' · ' (space U+00B7 space); never occurs in values
//   after normalization.
//
// ## Absent-field contract (fixed columns)
//
//   S1 and S2 have FIXED column counts (ARIA_MCP_SPEC 2.4.0 §8.3):
//     S1 six cols: uuid · subject · bestSpan · sscFacts · eventTime · score
//     S2 five cols: uuid · subject · bestSpan · sscFacts · eventTime
//   An absent optional renders as '-' occupying its whole column.
//   A bestSpan byte-identical to subject (after normalization) renders '-'.
//   An absent sscFacts renders '-'.
//
// ## Structured content parity invariant (§8.9)
//
//   - One entry per rendered text row, same order, same cap.
//   - An optional field is ABSENT from the structured row when its text
//     column renders the placeholder ('-') — never null, never empty-string.
//   - Score absent on S2 surfaces.
//
// ## Rust twin
//
//   result_composer.rs — same functions, same fixture file, byte-identical
//   outputs proven by ComposerConformanceTests ∥ composer_conformance.rs
//   over Tests/Conformance/composer_fixtures.json.

import Foundation

// MARK: - Candidate Row Data (S1 / S2 typed intermediate)

/// The typed intermediate for one memory row on any S1 or S2 surface.
/// Tools produce these; the composer renders them. No rendered text is
/// accepted as input; the composer is the sole rendering path.
///
/// Surface extensions (connected/distilled/vague/federated/lens) are
/// optional fields. Set only the extensions relevant to the surface.
/// Mirrors Rust `CandidateRowData`.
///
/// Row format (ARIA_MCP_SPEC 2.4.0 §8.3):
///   S1 (6 cols): uuid · subject · bestSpan · sscFacts · eventTime · score
///   S2 (5 cols): uuid · subject · bestSpan · sscFacts · eventTime
public struct CandidateRowData: Sendable {
    // MARK: Core columns (S1 six / S2 five columns)

    /// The drawer UUID (column 1 of every memory row).
    public let id: String

    /// The drawer subject, ≤120 chars by capture contract (column 2).
    /// Absent subject renders '-'.
    public let subject: String?

    /// Best span: content words [start, end) from the rerank hit, capped at
    /// 60 words. When no span hit is available, falls back to the first body
    /// sentence (same truncation and dedup logic as before). Column 3.
    /// Absent renders '-'.
    public let bestSpan: String?

    /// SSC facts raw string read from the ssc_facts column (W1 schema 19).
    /// Format: "kind: X" | "kind: X, entity: Y" | "kind: X, entities: Y1; Y2".
    /// Column 4. Absent renders '-'.
    public let sscFacts: String?

    /// Event time in ISO-8601 form with trailing Z (column 5).
    public let eventTime: String

    /// Final relevance score to four decimal places (column 6, S1 only).
    /// Nil on S2 surfaces.
    public let score: Double?

    // MARK: Optional room (structured output only)

    /// Room name for the structured row's `room` field. Not rendered in text.
    public let room: String?

    // MARK: Surface extensions (structured output only)

    /// Connected recall: "anchor" | "walk" | "both" (§11.10 extensions).
    public let retrievalSource: String?

    /// Distilled recall: the distillate text (present = distilled representation).
    public let distilled: String?

    /// Distilled recall: always "distilled" — inline rendering via ContextDistillLib.
    public let representation: String?

    /// Vague recall: "summary" | "original".
    public let tier: String?

    /// Federated search: the estate UUID string.
    public let estateID: String?

    /// Memory get full depth: verbatim content.
    public let content: String?

    /// Lens concepts / associations: full extent array (structured only).
    public let extents: [String]?

    /// Lens associations: exemplar drawer-UUID array (structured only).
    public let exemplars: [String]?

    public init(
        id: String,
        subject: String? = nil,
        bestSpan: String? = nil,
        sscFacts: String? = nil,
        eventTime: String,
        score: Double? = nil,
        room: String? = nil,
        retrievalSource: String? = nil,
        distilled: String? = nil,
        representation: String? = nil,
        tier: String? = nil,
        estateID: String? = nil,
        content: String? = nil,
        extents: [String]? = nil,
        exemplars: [String]? = nil
    ) {
        self.id = id
        self.subject = subject
        self.bestSpan = bestSpan
        self.sscFacts = sscFacts
        self.eventTime = eventTime
        self.score = score
        self.room = room
        self.retrievalSource = retrievalSource
        self.distilled = distilled
        self.representation = representation
        self.tier = tier
        self.estateID = estateID
        self.content = content
        self.extents = extents
        self.exemplars = exemplars
    }
}

// MARK: - Temporal Capability (structured capabilities object)

/// Structured representation of the temporal recall capability signal,
/// mirroring the `temporal:` control line for `capabilities.temporal` in
/// structuredContent. Absent when no temporal narration applies or when
/// the narration is the loose date-seeking variant (which has no
/// mode/source/grab/from/to structure).
/// Mirrors Rust `TemporalCapability`.
public struct TemporalCapability: Sendable, Equatable {
    public let mode: String
    public let source: String
    public let grab: String
    public let from: String
    public let to: String
    /// Widened days when the window was broadened; absent if not widened.
    public let widenedDays: Int?

    public init(mode: String, source: String, grab: String,
                from: String, to: String, widenedDays: Int? = nil) {
        self.mode = mode
        self.source = source
        self.grab = grab
        self.from = from
        self.to = to
        self.widenedDays = widenedDays
    }
}

// MARK: - Control Signals

/// Deviation-only capability signals that trail S1 rows in a fixed absolute
/// order (§11.3): discrimination → temporal|walk → degradation → tie note → hint.
/// Every field is absent (nil/false) at the nominal happy path; the composer
/// emits lines only for non-default states.
/// Mirrors Rust `ControlSignals`.
public struct ControlSignals: Sendable {
    /// Discrimination level: "low" or "medium". Nil = absent (high separation
    /// or single result — no line rendered).
    public let discrimination: String?

    /// Full temporal narration text for the `temporal:` line.
    /// Includes the `temporal: ` prefix. Nil = line absent.
    public let temporalNarration: String?

    /// Structured capabilities data for the `capabilities.temporal` key.
    /// Nil = absent from structuredContent even when temporalNarration present
    /// (e.g. loose date-seeking variant has no parseable structure).
    public let temporalCapability: TemporalCapability?

    /// Walk stage name (e.g. "expansion"). Nil = line absent.
    public let walkStage: String?

    /// Walk early-stop flag. Only consulted when walkStage is non-nil.
    public let walkStoppedEarly: Bool?

    /// True = emit the degradation line.
    public let degraded: Bool

    /// True = emit the non-deterministic tie note line.
    public let tieNote: Bool

    /// Coaching hint text (without the `hint: ` prefix). Nil = line absent.
    public let hint: String?

    public init(
        discrimination: String? = nil,
        temporalNarration: String? = nil,
        temporalCapability: TemporalCapability? = nil,
        walkStage: String? = nil,
        walkStoppedEarly: Bool? = nil,
        degraded: Bool = false,
        tieNote: Bool = false,
        hint: String? = nil
    ) {
        self.discrimination = discrimination
        self.temporalNarration = temporalNarration
        self.temporalCapability = temporalCapability
        self.walkStage = walkStage
        self.walkStoppedEarly = walkStoppedEarly
        self.degraded = degraded
        self.tieNote = tieNote
        self.hint = hint
    }
}

// MARK: - S3 Full Record Data

/// One tunnel edge for the S3 full-record tunnels block.
public struct FullRecordTunnel: Sendable {
    /// True = outgoing (→); false = incoming (←).
    public let isOutgoing: Bool
    /// Target / source drawer UUID.
    public let otherID: String
    /// Edge label (e.g. "relates", "precedes").
    public let label: String

    public init(isOutgoing: Bool, otherID: String, label: String) {
        self.isOutgoing = isOutgoing
        self.otherID = otherID
        self.label = label
    }
}

/// Typed intermediate for the S3 full-record shape (§11.6).
/// The subject line is present only when subject is non-nil.
/// Mirrors Rust `FullRecordData`.
public struct FullRecordData: Sendable {
    public let id: String
    public let room: String
    public let wing: String
    public let subject: String?
    public let filedAt: String       // ISO-8601 with Z
    public let eventTime: String     // ISO-8601 with Z
    public let state: String
    public let trust: String
    public let sensitivity: String
    public let exportability: String
    public let confirmation: String
    public let lineageID: String
    /// Confirmed-active tunnels only; capped at 50 in the renderer.
    public let tunnels: [FullRecordTunnel]
    public let content: String

    public init(
        id: String, room: String, wing: String, subject: String? = nil,
        filedAt: String, eventTime: String,
        state: String, trust: String, sensitivity: String,
        exportability: String, confirmation: String,
        lineageID: String, tunnels: [FullRecordTunnel], content: String
    ) {
        self.id = id; self.room = room; self.wing = wing
        self.subject = subject
        self.filedAt = filedAt; self.eventTime = eventTime
        self.state = state; self.trust = trust
        self.sensitivity = sensitivity; self.exportability = exportability
        self.confirmation = confirmation; self.lineageID = lineageID
        self.tunnels = tunnels; self.content = content
    }
}

// MARK: - S4 Fact Row Data

/// One fact row for the S4 fact-search surface (§11.7).
public struct FactSearchRow: Sendable {
    public let factID: String
    public let subject: String
    public let predicate: String
    public let object: String
    /// Source drawer UUID, or nil for a freestanding assertion (renders '-').
    public let sourceDrawerID: String?
    public let filedAt: String

    public init(factID: String, subject: String, predicate: String,
                object: String, sourceDrawerID: String?, filedAt: String) {
        self.factID = factID; self.subject = subject
        self.predicate = predicate; self.object = object
        self.sourceDrawerID = sourceDrawerID; self.filedAt = filedAt
    }
}

/// One fact row for the S4 fact-timeline surface (§11.7).
public struct FactTimelineRow: Sendable {
    public let filedAt: String
    /// Lifecycle label: "active", "retired(B)", "retired(C)", "unknown(<raw>)".
    public let lifecycle: String
    public let factID: String
    public let subject: String
    public let predicate: String
    public let object: String
    /// Source drawer UUID, or nil for a freestanding assertion.
    public let sourceDrawerID: String?

    public init(filedAt: String, lifecycle: String, factID: String,
                subject: String, predicate: String, object: String,
                sourceDrawerID: String?) {
        self.filedAt = filedAt; self.lifecycle = lifecycle
        self.factID = factID; self.subject = subject
        self.predicate = predicate; self.object = object
        self.sourceDrawerID = sourceDrawerID
    }
}

// MARK: - S5 Edge Row Data

/// One edge row for the S5 graph-edge surface (§11.8).
/// The far endpoint renders the S2 pick fields (UUID, subject, first sentence,
/// SSC, adornment, event time) without a score column.
public struct EdgeRow: Sendable {
    public let tunnelID: String
    /// The edge kind/label. Lifecycle suffix "(lifecycle)" appended when not active.
    public let kindLabel: String
    /// Lifecycle; nil or "active" = no suffix appended to kindLabel.
    public let lifecycle: String?
    /// Far endpoint rendered as S2 pick fields.
    public let farEndpoint: CandidateRowData

    public init(tunnelID: String, kindLabel: String, lifecycle: String? = nil,
                farEndpoint: CandidateRowData) {
        self.tunnelID = tunnelID; self.kindLabel = kindLabel
        self.lifecycle = lifecycle; self.farEndpoint = farEndpoint
    }
}

// MARK: - S6 Tabular Data

/// A typed S6 tabular column definition.
public struct S6Column: Sendable, Equatable {
    public let name: String
    /// "text" | "int" | "float" | "bool"
    public let type: String

    public init(name: String, type: String) {
        self.name = name; self.type = type
    }
}

/// A typed S6 dataset query result.
public struct TabularQueryData: Sendable {
    public let datasetID: String
    public let datasetName: String
    /// Number of rows returned in this reply.
    public let returned: Int
    /// Total matching rows before the limit; nil when computing it would
    /// require a separate full scan (never silently paid per §8.10).
    public let total: Int?
    public let limit: Int
    public let orderColumn: String
    public let orderDirection: String
    public let columns: [String]
    /// Rows in caller order. Each element is one column value (nil = NULL).
    /// Values must already be in the `columns` order.
    public let rows: [[TabularCellValue?]]

    public init(datasetID: String, datasetName: String, returned: Int,
                total: Int? = nil, limit: Int,
                orderColumn: String, orderDirection: String,
                columns: [String], rows: [[TabularCellValue?]]) {
        self.datasetID = datasetID; self.datasetName = datasetName
        self.returned = returned; self.total = total; self.limit = limit
        self.orderColumn = orderColumn; self.orderDirection = orderDirection
        self.columns = columns; self.rows = rows
    }
}

/// A typed S6 tabular cell value. Used by TabularQueryData.
public enum TabularCellValue: Sendable, Equatable {
    case text(String)
    case integer(Int64)
    case float(Double)
    case bool(Bool)
}

/// Per-column statistics for one column in an S6 dataset stats result.
public struct TabularColumnStats: Sendable {
    public let name: String
    public let count: Int
    public let nulls: Int
    public let distinct: Int
    /// Numeric stats; nil for text columns.
    public let min: String?
    public let max: String?
    public let mean: String?
    public let stddev: String?

    public init(name: String, count: Int, nulls: Int, distinct: Int,
                min: String? = nil, max: String? = nil,
                mean: String? = nil, stddev: String? = nil) {
        self.name = name; self.count = count; self.nulls = nulls
        self.distinct = distinct; self.min = min; self.max = max
        self.mean = mean; self.stddev = stddev
    }
}

/// A typed S6 dataset stats result.
public struct TabularStatsData: Sendable {
    public let datasetID: String
    public let datasetName: String
    public let totalRows: Int
    public let totalColumns: Int
    public let columns: [TabularColumnStats]

    public init(datasetID: String, datasetName: String,
                totalRows: Int, totalColumns: Int,
                columns: [TabularColumnStats]) {
        self.datasetID = datasetID; self.datasetName = datasetName
        self.totalRows = totalRows; self.totalColumns = totalColumns
        self.columns = columns
    }
}

// MARK: - Synthesis Document Data

/// Typed intermediate for the grounded synthesis document (§11.4).
public struct SynthesisData: Sendable {
    public let drawerCount: Int
    /// Normalized extracted cue terms; nil for whole-estate digest (no query: line).
    public let cueTerms: [String]?
    /// Plain prose summary paragraph (no label).
    public let summary: String
    /// Candidate section rows (rendered as S1 candidate block after summary).
    public let rows: [CandidateRowData]
    public let control: ControlSignals

    public init(drawerCount: Int, cueTerms: [String]? = nil,
                summary: String, rows: [CandidateRowData],
                control: ControlSignals = ControlSignals()) {
        self.drawerCount = drawerCount; self.cueTerms = cueTerms
        self.summary = summary; self.rows = rows; self.control = control
    }
}

// MARK: - Federated Estate Section

/// One per-estate section for federated recall (§11.2).
public struct FederatedSection: Sendable {
    public let estateName: String
    public let estateID: String
    public let rows: [CandidateRowData]
    public let control: ControlSignals

    public init(estateName: String, estateID: String,
                rows: [CandidateRowData], control: ControlSignals = ControlSignals()) {
        self.estateName = estateName; self.estateID = estateID
        self.rows = rows; self.control = control
    }
}

// MARK: - Composed Result

/// The full dual-format output from the composer: text payload and
/// structuredContent JSON. The text is the AI surface and audit fallback;
/// the structured block is the machine-consumption target.
public struct ComposedResult: Sendable {
    /// Text payload (the MCP `content[0].text` value).
    public let text: String
    /// structuredContent JSON value, or nil for surfaces that do not
    /// declare a structuredContent schema (S3/S4/S5/S6).
    public let structured: JSONValue?

    public init(text: String, structured: JSONValue? = nil) {
        self.text = text; self.structured = structured
    }
}

// MARK: - ResultComposer

/// The shared result composer for all ARIA MCP return shapes (§8 composer
/// invariant). No instances — all methods are static.
///
/// One call to any render function emits BOTH the text payload and the
/// structuredContent JSON from the same typed intermediate, guaranteeing
/// parity by construction.
public enum ResultComposer {

    // MARK: - Separator constant

    /// The three-character S1/S2/S4/S5 field separator (space, U+00B7, space).
    static let sep = " \u{00B7} "

    // MARK: - Sensitivity redaction markers

    /// Subject-column redaction marker for provenance-restricted content.
    /// The subject is content-derived; restricted provenance sensitivity means
    /// the body's access control must not be bypassable through its summary.
    public static let restrictedMarker = "[sensitivity: restricted — content redacted]"

    /// Subject-column redaction marker for provenance-secret content.
    public static let secretMarker = "[sensitivity: secret — content access requires explicit grant]"

    /// Absence marker when a drawer carries no subject.
    public static let noSubjectMarker = "(no subject)"

    // MARK: - ISO-8601 UTC date formatter

    /// Format a Date as ISO-8601 UTC with seconds precision
    /// (`2026-08-02T12:00:00Z`). Uses civil-from-days arithmetic
    /// (Howard Hinnant algorithm) rather than ISO8601DateFormatter, which
    /// is not Sendable under strict concurrency. The arithmetic path also
    /// matches the Rust twin's implementation exactly, allowing golden-fixture
    /// comparisons between ports without formatter variance.
    public static func iso8601(_ date: Date) -> String {
        let epoch = Int64(date.timeIntervalSince1970.rounded(.down))
        let days = Int64((Double(epoch) / 86_400).rounded(.down))
        let secsOfDay = epoch - days * 86_400
        let (h, m, s) = (secsOfDay / 3600, (secsOfDay % 3600) / 60, secsOfDay % 60)
        // Howard Hinnant's civil_from_days algorithm — twin of result_composer.rs::iso8601_utc.
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

    // MARK: - Value normalization (§11.1 rule 1)

    /// Normalize a field value for use in S1/S2/S4/S5 rows:
    ///   - embedded newlines (CR/LF/CRLF) → single space
    ///   - whitespace runs → one space (trim leading/trailing)
    ///   - literal U+00B7 middle-dot → '-' (prevents separator injection)
    ///
    /// S6 tabular values are EXEMPT from this normalization — they use
    /// lossless quoting instead.
    public static func normalizeValue(_ raw: String) -> String {
        // Replace newline variants with a space.
        var s = raw
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        // Replace embedded middle-dot to prevent separator injection.
        s = s.replacingOccurrences(of: "\u{00B7}", with: "-")
        // Collapse whitespace runs and trim.
        let words = s.split(separator: " ", omittingEmptySubsequences: true)
        return words.joined(separator: " ")
    }

    // MARK: - First-sentence truncation (§11.1 rule 3)

    /// Hard cut the first sentence at 120 characters with no ellipsis.
    /// Applied before normalization so the byte count is over raw UTF-8 chars.
    public static func truncateFirstSentence(_ raw: String) -> String {
        // Hard cut at 120 Unicode scalar values (not bytes) — the spec says
        // "120 characters". Swift String.prefix works on Character/scalar
        // boundaries, which is the correct interpretation for AI-facing text.
        if raw.count <= 120 { return raw }
        return String(raw.prefix(120))
    }

    // MARK: - Single row rendering

    /// Render one S1 row (six fixed columns, ARIA_MCP_SPEC 2.4.0 §8.3).
    /// The score is mandatory; pass the actual score value.
    ///
    /// Column order: uuid · subject · bestSpan · sscFacts · eventTime · score%.4f
    public static func renderS1Row(_ row: CandidateRowData) -> String {
        let subjectText = normalizedSubject(row)
        let spanText = normalizedBestSpan(row, subjectNormalized: subjectText)
        let sscText = row.sscFacts ?? "-"
        let scoreText = String(format: "%.4f", row.score ?? 0.0)
        return [row.id, subjectText, spanText, sscText,
                row.eventTime, scoreText].joined(separator: sep)
    }

    /// Render one S2 row (five fixed columns, no score, ARIA_MCP_SPEC 2.4.0 §8.3).
    ///
    /// Column order: uuid · subject · bestSpan · sscFacts · eventTime
    public static func renderS2Row(_ row: CandidateRowData) -> String {
        let subjectText = normalizedSubject(row)
        let spanText = normalizedBestSpan(row, subjectNormalized: subjectText)
        let sscText = row.sscFacts ?? "-"
        return [row.id, subjectText, spanText, sscText,
                row.eventTime].joined(separator: sep)
    }

    // MARK: - S1 ranked surface (§11.2)

    /// Render the full S1 ranked surface: header + rows + control lines.
    ///
    /// The header is singular when rows.count == 1:
    ///   "found 1 candidate memory, one per line"
    ///   "found N candidate memories, one per line"
    ///
    /// Control lines follow in the absolute fixed order (§11.3):
    ///   discrimination → temporal|walk → degradation → tie note → hint
    public static func renderS1Surface(
        rows: [CandidateRowData],
        control: ControlSignals
    ) -> ComposedResult {
        let n = rows.count
        let header = n == 1
            ? "found 1 candidate memory, one per line"
            : "found \(n) candidate memories, one per line"
        var lines: [String] = [header]
        lines.append(contentsOf: rows.map(renderS1Row))
        lines.append(contentsOf: controlLines(for: control))
        return ComposedResult(
            text: lines.joined(separator: "\n"),
            structured: structuredS1(rows: rows, control: control))
    }

    /// Render the S1 empty-result surface: header + optional hint + optional
    /// control lines (§11.1 rule 7). The `control` parameter carries the walk-
    /// stage annotation for `moot_recall_walk` — empty results still report
    /// which stage was reached so the caller knows escalation occurred.
    public static func renderEmptyS1(
        hint: String? = nil,
        control: ControlSignals = ControlSignals()
    ) -> ComposedResult {
        var lines = ["found 0 candidate memories, one per line"]
        // Trailing order is absolute (§ 8.4): control lines first, hint LAST.
        lines.append(contentsOf: controlLines(for: control))
        if let hint { lines.append("hint: \(hint)") }
        return ComposedResult(
            text: lines.joined(separator: "\n"),
            structured: .object(["results": .array([])]))
    }

    // MARK: - S2 unranked memory rows (§11.5)

    /// Render the S2 memory-list surface (filing order, unranked).
    public static func renderS2Listing(
        wing: String, room: String, rows: [CandidateRowData]
    ) -> ComposedResult {
        let n = rows.count
        let header = "listing \(n) memories in \(wing) / \(room) — filing order, unranked"
        var lines: [String] = [header]
        lines.append(contentsOf: rows.map(renderS2Row))
        return ComposedResult(text: lines.joined(separator: "\n"))
    }

    /// Render the S2 empty listing header only.
    public static func renderEmptyS2Listing(wing: String, room: String) -> ComposedResult {
        return ComposedResult(
            text: "listing 0 memories in \(wing) / \(room) — filing order, unranked")
    }

    /// Render the S2 batch-get surface (request order, exactly one line per
    /// requested id in position; duplicates duplicate; not-found lines in place).
    ///
    /// Each element in `rows` is either a found CandidateRowData or a not-found
    /// UUID string (passed via the two-parameter overload below). Here we accept
    /// the pre-built per-position entries.
    ///
    /// - Parameters:
    ///   - entries: per-position entries in request order; see BatchGetEntry.
    ///   - resolved: count of found rows (caller computes).
    ///   - requested: total number of requested ids.
    public static func renderS2BatchGet(
        entries: [BatchGetEntry], resolved: Int, requested: Int
    ) -> ComposedResult {
        let header = "resolved \(resolved) of \(requested) requested memories, in request order"
        var lines: [String] = [header]
        for entry in entries {
            switch entry {
            case .found(let row): lines.append(renderS2Row(row))
            case .notFound(let id): lines.append("not found: \(id)")
            }
        }
        return ComposedResult(text: lines.joined(separator: "\n"))
    }

    /// One entry in a S2 batch-get result (found row or not-found id).
    public enum BatchGetEntry: Sendable {
        case found(CandidateRowData)
        case notFound(String)
    }

    // MARK: - S3 full record (§11.6)

    /// Render the S3 full-record shape.
    /// The `subject:` line is omitted when the drawer carries none.
    /// Tunnels are capped at 50.
    public static func renderS3Record(_ record: FullRecordData) -> ComposedResult {
        var lines: [String] = [
            "memory \(record.id)",
            "room: \(record.room)  wing: \(record.wing)",
        ]
        if let subject = record.subject {
            lines.append("subject: \(subject)")
        }
        lines.append(contentsOf: [
            "filed_at: \(record.filedAt)",
            "event_time: \(record.eventTime)",
            "state: \(record.state)",
            "trust: \(record.trust)",
            "sensitivity: \(record.sensitivity)",
            "exportability: \(record.exportability)",
            "confirmation: \(record.confirmation)",
            "lineage: \(record.lineageID)",
            "tunnels: \(record.tunnels.count)",
        ])
        for tunnel in record.tunnels.prefix(50) {
            let arrow = tunnel.isOutgoing ? "→" : "←"
            lines.append("  \(arrow) \(tunnel.otherID)  [\(tunnel.label)]")
        }
        lines.append("content:")
        lines.append(record.content)
        return ComposedResult(text: lines.joined(separator: "\n"))
    }

    // MARK: - S4 fact rows (§11.7)

    /// Render the S4 fact-search surface: six fixed columns.
    ///   factID · subject · predicate · object · sourceDrawerUUID|-  · filedAt
    public static func renderS4FactSearch(facts: [FactSearchRow]) -> ComposedResult {
        let n = facts.count
        let header = n == 1
            ? "found 1 fact, one per line"
            : "found \(n) facts, one per line"
        var lines = [header]
        for fact in facts {
            let source = fact.sourceDrawerID ?? "-"
            let row = [fact.factID, fact.subject, fact.predicate,
                       fact.object, source, fact.filedAt].joined(separator: sep)
            lines.append(row)
        }
        return ComposedResult(text: lines.joined(separator: "\n"))
    }

    /// Render the S4 fact-timeline surface: seven time-major columns.
    ///   filedAt · lifecycle · factID · subject · predicate · object · source|-
    public static func renderS4FactTimeline(facts: [FactTimelineRow]) -> ComposedResult {
        let n = facts.count
        let header = "fact timeline: \(n) fact\(n == 1 ? "" : "s") in filing order (active and retired)"
        var lines = [header]
        for fact in facts {
            let source = fact.sourceDrawerID ?? "-"
            let row = [fact.filedAt, fact.lifecycle, fact.factID,
                       fact.subject, fact.predicate, fact.object,
                       source].joined(separator: sep)
            lines.append(row)
        }
        return ComposedResult(text: lines.joined(separator: "\n"))
    }

    // MARK: - S5 edge rows (§11.8)

    /// Render the S5 graph-edge surface.
    /// direction: "outgoing" | "incoming"
    ///
    /// Row shape: tunnelID · kind/label[(lifecycle)] · <S2 pick fields no score>
    public static func renderS5Edges(
        direction: String, edges: [EdgeRow]
    ) -> ComposedResult {
        let n = edges.count
        let noun = n == 1 ? "connection" : "connections"
        let header = "found \(n) \(direction) \(noun), one per line"
        var lines = [header]
        for edge in edges {
            let kindField: String
            if let lc = edge.lifecycle, lc != "active" {
                kindField = "\(edge.kindLabel) (\(lc))"
            } else {
                kindField = edge.kindLabel
            }
            // Far endpoint: S2 pick fields (six columns without a score prefix)
            let far = renderS2Row(edge.farEndpoint)
            let row = [edge.tunnelID, kindField, far].joined(separator: sep)
            lines.append(row)
        }
        return ComposedResult(text: lines.joined(separator: "\n"))
    }

    // MARK: - S6 tabular rows (§11.9)

    /// Render the S6 dataset query surface with lossless value encoding.
    /// Values round-trip exactly; the §11.1 `·`→`-` replacement NEVER applies.
    public static func renderS6Query(_ data: TabularQueryData) -> ComposedResult {
        let totalPart = data.total.map { " of \($0)" } ?? ""
        let header = """
dataset \(data.datasetID) "\(data.datasetName)": \
returned \(data.returned)\(totalPart) matching rows \
(limit \(data.limit), ordered by \(data.orderColumn) \(data.orderDirection))
"""
        let colHeader = data.columns.joined(separator: sep)
        var lines = [header, colHeader]
        for rowVals in data.rows {
            let fields = rowVals.map { v -> String in
                guard let v = v else { return "" }   // NULL = empty unquoted
                return s6EncodeCell(v)
            }
            lines.append(s6JoinRow(fields))
        }
        // Structured columns + rows for the capabilities block.
        let structuredCols: JSONValue = .array(data.columns.map { .string($0) })
        let structuredRows: JSONValue = .array(data.rows.map { row -> JSONValue in
            .array(row.map { v -> JSONValue in
                guard let v = v else { return .null }
                switch v {
                case .text(let s): return .string(s)
                case .integer(let i): return .integer(i)
                case .float(let d): return .double(d)
                case .bool(let b): return .bool(b)
                }
            })
        })
        let structured: JSONValue = .object([
            "columns": structuredCols,
            "rows": structuredRows,
        ])
        return ComposedResult(text: lines.joined(separator: "\n"),
                              structured: structured)
    }

    /// Render the S6 dataset stats surface.
    public static func renderS6Stats(_ data: TabularStatsData) -> ComposedResult {
        let header = """
dataset \(data.datasetID) "\(data.datasetName)": \
\(data.totalRows) rows, \(data.totalColumns) columns
"""
        var lines = [header]
        for col in data.columns {
            var parts = [col.name, "count=\(col.count)", "nulls=\(col.nulls)",
                         "distinct=\(col.distinct)"]
            if let min = col.min { parts.append("min=\(min)") }
            if let max = col.max { parts.append("max=\(max)") }
            if let mean = col.mean { parts.append("mean=\(mean)") }
            if let sd = col.stddev { parts.append("stddev=\(sd)") }
            lines.append(parts.joined(separator: sep))
        }
        return ComposedResult(text: lines.joined(separator: "\n"))
    }

    // MARK: - S6 lossless encoding helpers

    /// Encode one S6 cell value for presentation.
    /// Applies lossless quoting when the value requires it.
    public static func s6EncodeCell(_ value: TabularCellValue) -> String {
        switch value {
        case .text(let s):
            return s6QuoteIfNeeded(s)
        case .integer(let i):
            return String(i)
        case .float(let d):
            // Shortest exact decimal — matches Swift's String(d) for most values.
            return String(d)
        case .bool(let b):
            return b ? "true" : "false"
        }
    }

    /// Join a row of S6-encoded fields using the standard separator.
    /// S6 is exempt from the middle-dot replacement rule, so the separator
    /// CAN appear inside double-quoted values.
    static func s6JoinRow(_ fields: [String]) -> String {
        fields.joined(separator: sep)
    }

    /// Quote an S6 text cell when it contains the separator sequence, a
    /// double-quote, a newline, or leading/trailing whitespace.
    /// Embedded newlines render as the two-character escape `\n` inside quotes.
    /// Embedded double-quotes render as `""`.
    /// Other content is left as-is inside the double-quote envelope.
    public static func s6QuoteIfNeeded(_ s: String) -> String {
        let needsQuoting = s.contains(sep) ||
                           s.contains("\"") ||
                           s.contains("\n") ||
                           s.contains("\r") ||
                           s.hasPrefix(" ") || s.hasSuffix(" ")
        guard needsQuoting else { return s }
        // Empty string → ""
        if s.isEmpty { return "\"\"" }
        let escaped = s
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    // MARK: - Synthesis document (§11.4)

    /// Render the grounded synthesis document.
    /// When cueTerms is nil, the `query:` line is omitted (whole-estate form).
    /// No scaffold fields (no `summary:`, `patterns:`, etc. labels).
    public static func renderSynthesis(_ data: SynthesisData) -> ComposedResult {
        let count = data.drawerCount
        let drawer = count == 1 ? "drawer" : "drawers"
        var lines: [String] = ["grounded_synthesis: \(count) \(drawer)"]
        if let cues = data.cueTerms {
            lines.append("query: \(cues.joined(separator: ", "))")
        }
        lines.append(data.summary)
        // Candidate section: S1 sub-block (header + rows).
        let n = data.rows.count
        let candidateHeader = n == 1
            ? "found 1 candidate memory, one per line"
            : "found \(n) candidate memories, one per line"
        lines.append(candidateHeader)
        lines.append(contentsOf: data.rows.map(renderS1Row))
        lines.append(contentsOf: controlLines(for: data.control))

        // Structured: top-level cues + summary + results.
        var structObj: [String: JSONValue] = [
            "results": .array(data.rows.map { structuredRowObject($0) }),
        ]
        if let cues = data.cueTerms {
            structObj["cues"] = .array(cues.map { .string($0) })
        }
        structObj["summary"] = .string(data.summary)
        if let caps = structuredCapabilities(for: data.control) {
            structObj["capabilities"] = caps
        }
        return ComposedResult(
            text: lines.joined(separator: "\n"),
            structured: .object(structObj))
    }

    // MARK: - Vague recall (§11.2)

    /// Render the two-tier vague-recall surface:
    ///   "found N vague summaries|summary, one per line"  + summary rows
    ///   "found M hydrated originals|original, one per line" + original rows
    /// Both headers use their own singular/plural form.
    public static func renderVagueRecall(
        summaries: [CandidateRowData],
        originals: [CandidateRowData],
        control: ControlSignals
    ) -> ComposedResult {
        let ns = summaries.count
        let no = originals.count
        let sumHeader = ns == 1
            ? "found 1 vague summary, one per line"
            : "found \(ns) vague summaries, one per line"
        let origHeader = no == 1
            ? "found 1 hydrated original, one per line"
            : "found \(no) hydrated originals, one per line"
        var lines: [String] = [sumHeader]
        lines.append(contentsOf: summaries.map(renderS1Row))
        lines.append(origHeader)
        lines.append(contentsOf: originals.map(renderS1Row))
        lines.append(contentsOf: controlLines(for: control))
        let allRows = summaries + originals
        return ComposedResult(
            text: lines.joined(separator: "\n"),
            structured: structuredS1(rows: allRows, control: control))
    }

    // MARK: - Distilled recall (§11.2)

    /// Render the distilled recall surface: each row followed by its inline
    /// distilled text as a four-space indented unlabeled continuation.
    /// Every row renders — ContextDistillLib runs at read time, so there is
    /// no fallback path and no "not yet distilled" state.
    public static func renderDistilledRecall(
        rows: [CandidateRowData],
        control: ControlSignals
    ) -> ComposedResult {
        let n = rows.count
        let header = n == 1
            ? "found 1 candidate memory, one per line"
            : "found \(n) candidate memories, one per line"
        var lines: [String] = [header]
        for row in rows {
            lines.append(renderS1Row(row))
            if let distilledText = row.distilled {
                lines.append("    \(distilledText)")
            }
        }
        lines.append(contentsOf: controlLines(for: control))
        return ComposedResult(
            text: lines.joined(separator: "\n"),
            structured: structuredS1(rows: rows, control: control))
    }

    // MARK: - Federated recall (§11.2)

    /// Render the federated recall surface: one section per estate with
    /// `estate: <name> [<uuid>]` header before each S1 block.
    public static func renderFederatedRecall(
        estates: [FederatedSection]
    ) -> ComposedResult {
        var lines: [String] = []
        var allRows: [CandidateRowData] = []
        for section in estates {
            lines.append("estate: \(section.estateName) [\(section.estateID)]")
            let n = section.rows.count
            let h = n == 1
                ? "found 1 candidate memory, one per line"
                : "found \(n) candidate memories, one per line"
            lines.append(h)
            lines.append(contentsOf: section.rows.map(renderS1Row))
            lines.append(contentsOf: controlLines(for: section.control))
            allRows.append(contentsOf: section.rows)
        }
        // Structured: all rows combined (per §8.9, one entry per rendered row).
        return ComposedResult(
            text: lines.joined(separator: "\n"),
            structured: .object([
                "results": .array(allRows.map { structuredRowObject($0) }),
            ]))
    }

    // MARK: - Control lines (§11.3)

    /// Emit the deviation-only trailing control lines in the absolute fixed
    /// order: discrimination → temporal|walk → degradation → tie note → hint.
    static func controlLines(for signals: ControlSignals) -> [String] {
        var lines: [String] = []
        // 1. Discrimination (deviation-only: only low/medium render).
        if let disc = signals.discrimination {
            switch disc {
            case "low":
                lines.append("discrimination: low — top results within epsilon.")
            case "medium":
                lines.append("discrimination: medium — partial separation.")
            default:
                break   // "high" or unknown: no line
            }
        }
        // 2. Tool-specific narration: temporal XOR walk (at most one).
        if let narration = signals.temporalNarration {
            lines.append(narration)
        } else if let stage = signals.walkStage {
            let stopped = (signals.walkStoppedEarly ?? false) ? "yes" : "no"
            lines.append("walk: stage=\(stage) stoppedEarly=\(stopped)")
        }
        // 3. Degradation.
        if signals.degraded {
            lines.append("retrieval: degraded — one or more ranking stages unavailable")
        }
        // 4. Non-determinate tie note.
        if signals.tieNote {
            lines.append(
                "note: additional results share this score on a non-deterministic tie; refine the query")
        }
        // 5. Coaching hint.
        if let hint = signals.hint {
            lines.append("hint: \(hint)")
        }
        return lines
    }

    // MARK: - Structured S1 output (§11.10)

    /// Build the structuredContent JSON for an S1 surface (base schema +
    /// surface extensions + capabilities object).
    static func structuredS1(
        rows: [CandidateRowData],
        control: ControlSignals
    ) -> JSONValue {
        var obj: [String: JSONValue] = [
            "results": .array(rows.map { structuredRowObject($0) }),
        ]
        if let caps = structuredCapabilities(for: control) {
            obj["capabilities"] = caps
        }
        return .object(obj)
    }

    /// Build one structured row object for a CandidateRowData.
    /// Optional fields are ABSENT (not null) when text column renders '-'.
    static func structuredRowObject(_ row: CandidateRowData) -> JSONValue {
        var obj: [String: JSONValue] = ["id": .string(row.id)]

        // Subject: absent when nil.
        if let subject = row.subject {
            obj["subject"] = .string(subject)
        }

        // Best span: absent when nil or when byte-identical to subject
        // after normalization (same dedup rule as text rendering).
        let subjNorm = row.subject.map(normalizeValue) ?? ""
        if let span = row.bestSpan {
            let truncated = truncateFirstSentence(span)
            let spanNorm = normalizeValue(truncated)
            if !spanNorm.isEmpty && spanNorm != subjNorm {
                obj["bestSpan"] = .string(spanNorm)
            }
        }

        // SSC facts raw string: absent when nil.
        if let sscFacts = row.sscFacts {
            obj["sscFacts"] = .string(sscFacts)
        }

        obj["eventTime"] = .string(row.eventTime)

        // Score: absent on S2 surfaces (score == nil).
        if let score = row.score {
            obj["score"] = .double(score)
        }

        // Room: absent when nil.
        if let room = row.room {
            obj["room"] = .string(room)
        }

        // Surface extensions: absent when nil.
        if let retrievalSource = row.retrievalSource {
            obj["retrievalSource"] = .string(retrievalSource)
        }
        if let distilled = row.distilled {
            obj["distilled"] = .string(distilled)
        }
        if let representation = row.representation {
            obj["representation"] = .string(representation)
        }
        if let tier = row.tier {
            obj["tier"] = .string(tier)
        }
        if let estateID = row.estateID {
            obj["estateID"] = .string(estateID)
        }
        if let content = row.content {
            obj["content"] = .string(content)
        }
        if let extents = row.extents {
            obj["extent"] = .array(extents.map { .string($0) })
        }
        if let exemplars = row.exemplars {
            obj["exemplars"] = .array(exemplars.map { .string($0) })
        }

        return .object(obj)
    }

    /// Build the capabilities object from ControlSignals.
    /// Each key is ABSENT when its control line does not render.
    static func structuredCapabilities(for signals: ControlSignals) -> JSONValue? {
        var caps: [String: JSONValue] = [:]

        if let disc = signals.discrimination, disc == "low" || disc == "medium" {
            caps["discrimination"] = .string(disc)
        }

        if let tc = signals.temporalCapability {
            var temporal: [String: JSONValue] = [
                "mode": .string(tc.mode),
                "source": .string(tc.source),
                "grab": .string(tc.grab),
                "from": .string(tc.from),
                "to": .string(tc.to),
            ]
            if let wd = tc.widenedDays {
                temporal["widenedDays"] = .integer(Int64(wd))
            }
            caps["temporal"] = .object(temporal)
        }

        if let stage = signals.walkStage {
            caps["walk"] = .object([
                "stage": .string(stage),
                "stoppedEarly": .bool(signals.walkStoppedEarly ?? false),
            ])
        }

        if signals.degraded {
            caps["degraded"] = .bool(true)
        }

        return caps.isEmpty ? nil : .object(caps)
    }

    // MARK: - Cap line

    /// Render the cap line appended to an S1 or S2 surface when the result set
    /// is truncated at the given limit. Callers append this line when
    /// `rows.count == limit`; the composer does not append it automatically
    /// because the caller owns the limit policy.
    ///
    /// Format: "listing capped at N — narrow with <arg>"
    public static func renderCapLine(limit: Int, narrowingArg: String) -> String {
        "listing capped at \(limit) — narrow with \(narrowingArg)"
    }

    // MARK: - Private helpers

    /// Resolve the subject column text for S1/S2 rows.
    /// Absent subject renders '-'.
    private static func normalizedSubject(_ row: CandidateRowData) -> String {
        row.subject.map(normalizeValue) ?? "-"
    }

    /// Resolve the best-span column text for S1/S2 rows.
    /// Absent bestSpan renders '-'.
    /// A bestSpan byte-identical to the subject (after normalization)
    /// also renders '-' — never repeated per §11.1 rule 2.
    private static func normalizedBestSpan(
        _ row: CandidateRowData,
        subjectNormalized: String
    ) -> String {
        guard let span = row.bestSpan else { return "-" }
        let truncated = truncateFirstSentence(span)
        let normalized = normalizeValue(truncated)
        if normalized.isEmpty { return "-" }
        if normalized == subjectNormalized { return "-" }
        return normalized
    }
}
