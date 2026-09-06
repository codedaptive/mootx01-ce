//! `result_composer.rs`
//!
//! The one shared result composer for every ARIA MCP return shape
//! (ARIA_MCP_SPEC 2.0.0 § 8 composer invariant). Tools supply typed result
//! data — `CandidateRowData`, `ControlSignals`, surface-specific records —
//! and never rendered text; this module is the only code path that renders
//! text payloads and builds structuredContent JSON, so text/structured parity
//! holds by construction and a new retrieval technique cannot emit an
//! off-contract payload.
//!
//! ## Shape coverage
//!
//! - S1 — ranked memory candidates (§11.2): `render_s1_surface`
//! - S2 — unranked memory rows (§11.5): `render_s2_listing`, `render_s2_batch_get`
//! - S3 — full record hydration (§11.6): `render_s3_record`
//! - S4 — fact rows (§11.7): `render_s4_fact_search`, `render_s4_fact_timeline`
//! - S5 — graph-edge rows (§11.8): `render_s5_edges`
//! - S6 — tabular rows (§11.9): `render_s6_query`, `render_s6_stats`
//! - Synthesis — grounded synthesis document (§11.4): `render_synthesis`
//! - Vague — two-tier vague recall (§11.2): `render_vague_recall`
//! - Distilled — distilled recall with continuation lines (§11.2): `render_distilled_recall`
//! - Federated — per-estate sections (§11.2): `render_federated_recall`
//! - Empty — zero-count header with optional hint (§11.1 rule 7):
//!   `render_empty_s1`, `render_empty_s2_listing`
//!
//! ## Normalization rules (§11.1)
//!
//! `normalize_value` applies to EVERY S1/S2/S4/S5 field value:
//!   - embedded newlines → single space
//!   - whitespace runs → one space (trim leading/trailing)
//!   - literal U+00B7 middle-dot → `-`
//!
//! S6 values are EXEMPT from normalization — they use lossless quoting.
//! The separator is ` · ` (space U+00B7 space); never occurs in values
//! after normalization.
//!
//! ## Absent-field contract (fixed columns)
//!
//! S1 and S2 have FIXED column counts. An absent optional renders as
//! `-` occupying its whole column. A bestSpan byte-identical to subject
//! (after normalization) also renders `-`. An absent sscFacts renders `-`.
//!
//! ## Structured content parity invariant (§8.9)
//!
//! - One entry per rendered text row, same order, same cap.
//! - An optional field is ABSENT from the structured row when its text
//!   column renders the placeholder (`-`) — never null, never empty-string.
//! - Score absent on S2 surfaces.
//!
//! ## Swift twin
//!
//! `ResultComposer.swift` — same functions, same fixture file,
//! byte-identical outputs proven by `ComposerConformanceTests` ∥
//! `composer_conformance.rs` over `Tests/Conformance/composer_fixtures.json`.

use serde_json::{json, Value};

// ─── separator ───────────────────────────────────────────────────────────────

/// The three-character S1/S2/S4/S5 field separator (space, U+00B7, space).
/// Guaranteed never to appear inside a value after normalization.
pub const SEP: &str = " \u{00B7} ";

// ─── redaction and absence markers (twin of Swift ResultComposer) ────────────

/// Subject-slot marker for a restricted drawer (sensitivity: restricted).
/// Canonical sensitivity-marker vocabulary, identical in both ports; grant
/// workflows key off this exact string.
pub const RESTRICTED_MARKER: &str = "[sensitivity: restricted — content redacted]";

/// Subject-slot marker for a secret drawer (sensitivity: secret).
/// Canonical sensitivity-marker vocabulary, identical in both ports.
pub const SECRET_MARKER: &str =
    "[sensitivity: secret — content access requires explicit grant]";

/// Subject-slot marker when the drawer has no stored subject (subject-debt signal).
pub const NO_SUBJECT_MARKER: &str = "(no subject)";

// ─── epoch rendering helpers ─────────────────────────────────────────────────

/// Milliseconds/seconds discriminator threshold. The Rust `Drawer` carries bare
/// `i64` instants and BOTH conventions are live: the aria-mcp write path stamps
/// epoch-ms while LocusKit fixtures use epoch-seconds. Any value ≥ this threshold
/// (~5138 CE in seconds, ~1973 in ms) is unambiguously milliseconds. No clock
/// consulted — deterministic.
const MS_THRESHOLD: i64 = 100_000_000_000;

/// Unit-normalising ISO8601 renderer for drawer instants: accepts epoch-seconds
/// or epoch-milliseconds and renders to second precision. Twin of Swift
/// `ResultComposer.iso8601`.
pub fn iso8601_flex(epoch: i64) -> String {
    if epoch.abs() >= MS_THRESHOLD {
        iso8601_utc(epoch.div_euclid(1000))
    } else {
        iso8601_utc(epoch)
    }
}

/// Epoch seconds → ISO8601 UTC with seconds precision
/// (`2026-08-02T12:00:00Z`). Howard Hinnant's civil_from_days algorithm;
/// no external time crate (C-1). Byte-identical to Swift's ISO8601DateFormatter
/// `.withInternetDateTime` output.
pub fn iso8601_utc(epoch_secs: i64) -> String {
    let days = epoch_secs.div_euclid(86_400);
    let secs_of_day = epoch_secs.rem_euclid(86_400);
    let (h, m, s) = (secs_of_day / 3600, (secs_of_day % 3600) / 60, secs_of_day % 60);
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

// ─── S2 row from Drawer ────────────────────

/// Render an S2 fallback row for an unhydrated hit (id only).
/// All optional fields render their absence placeholder.
/// Twin of Swift `ResultComposer.renderUnhydratedS2Row`.
pub fn render_s2_row_unhydrated(id: &str) -> String {
    // Subject uses NO_SUBJECT_MARKER so absence is visible (subject-debt signal).
    let row = CandidateRowData::new(
        id,
        Some(NO_SUBJECT_MARKER),
        None::<String>,
        None::<String>,
        "-",
        None,
    );
    render_s2_row(&row)
}

/// Build a `CandidateRowData` from a hydrated `Drawer`, ready for S2 rendering.
///
/// Redaction wins over subject: restricted/secret sensitivity replaces the
/// subject field with the appropriate marker. The empty `RecallFrame` filter
/// chain in `s2_rows_by_id` prevents restricted/secret rows from reaching the
/// renderer at all, but callers that hydrate outside that path (lens arms, etc.)
/// still get a safe row.
///
/// `best_span` is extracted from `drawer.content` (first 60 words of content
/// body). SSC facts are absent at structured hydration level — they render as `-`.
/// The score field is None (S2 is unranked).
pub fn candidate_from_drawer(drawer: &locus_kit::drawer::Drawer) -> CandidateRowData {
    use locus_kit::provenance::Sensitivity;
    let sens = drawer.sensitivity();
    let subject = match sens {
        Sensitivity::Restricted => Some(RESTRICTED_MARKER.to_string()),
        Sensitivity::Secret    => Some(SECRET_MARKER.to_string()),
        _ => drawer.subject.clone().or_else(|| Some(NO_SUBJECT_MARKER.to_string())),
    };
    // Redaction boundary: best_span is body-derived content.
    // Restricted/secret drawers MUST NOT leak body text through the best_span
    // column — the same access control that gates the subject field applies here.
    // Non-redacted drawers: use content as the best span (capped at 60 words).
    let best_span: Option<String> = match sens {
        Sensitivity::Restricted | Sensitivity::Secret => None, // never leak body
        _ => {
            let body = drawer.content.trim();
            if body.is_empty() {
                None
            } else {
                let normalized = normalize_value(body);
                if normalized.is_empty() { None } else { Some(normalized) }
            }
        }
    };
    let event_time = iso8601_flex(drawer.event_time);
    CandidateRowData::new(
        drawer.id.clone(),
        subject,
        best_span,
        None::<String>, // sscFacts stubbed nil until W1 schema-19 Drawer.ssc_facts lands
        event_time,
        None,           // S2 is unranked — no score
    )
}

// ─── candidate row data (S1 / S2 typed intermediate) ─────────────────────────

/// The typed intermediate for one memory row on any S1 or S2 surface.
/// Tools produce these; the composer renders them. No rendered text is
/// accepted as input; the composer is the sole rendering path.
///
/// Row format (ENC-W6B): uuid · subject · bestSpan · sscFacts · eventTime · score (S1)
///                       uuid · subject · bestSpan · sscFacts · eventTime (S2)
///
/// Surface extensions (connected/distilled/vague/federated/lens) are
/// optional fields. Set only the extensions relevant to the surface.
/// Mirrors Swift `CandidateRowData`.
#[derive(Debug, Clone)]
pub struct CandidateRowData {
    // MARK: Core columns (all six S1 / five S2 columns)

    /// The drawer UUID (column 1 of every memory row).
    pub id: String,

    /// The drawer subject, ≤120 chars by capture contract (column 2).
    /// Absent subject renders `-`.
    pub subject: Option<String>,

    /// Best content span: content words [bestSpanStart, bestSpanEnd) from a
    /// SpanRerankHit, capped at 60 words; no hit → first body sentence (column 3).
    /// Renders `-` when absent or when byte-identical to subject after normalization.
    pub best_span: Option<String>,

    /// SSC (Semantic Search Candle) facts as a raw string (column 4).
    /// Format: "kind: hobby, entity: painting". Stubbed nil until W1 schema-19
    /// Drawer.ssc_facts lands. Absent renders `-`.
    pub ssc_facts: Option<String>,

    /// Event time in ISO-8601 form with trailing Z (column 5).
    pub event_time: String,

    /// Final relevance score to four decimal places (column 6, S1 only).
    /// None on S2 surfaces.
    pub score: Option<f64>,

    // Optional room (structured output only)

    /// Room name for the structured row's `room` field. Not rendered in text.
    pub room: Option<String>,

    // Surface extensions (structured output only)

    /// Connected recall: "anchor" | "walk" | "both" (§11.10 extensions).
    pub retrieval_source: Option<String>,

    /// Distilled recall: the distillate text (present = distilled representation).
    pub distilled: Option<String>,

    /// Distilled recall: "distilled" | "contentFallback".
    pub representation: Option<String>,

    /// Vague recall: "summary" | "original".
    pub tier: Option<String>,

    /// Federated search: the estate UUID string.
    pub estate_id: Option<String>,

    /// Memory get full depth: verbatim content.
    pub content: Option<String>,

    /// Lens concepts / associations: full extent array (structured only).
    pub extents: Option<Vec<String>>,

    /// Lens associations: exemplar drawer-UUID array (structured only).
    pub exemplars: Option<Vec<String>>,
}

impl CandidateRowData {
    /// Construct a minimal S1 candidate row (all optional extensions absent).
    pub fn new(
        id: impl Into<String>,
        subject: Option<impl Into<String>>,
        best_span: Option<impl Into<String>>,
        ssc_facts: Option<impl Into<String>>,
        event_time: impl Into<String>,
        score: Option<f64>,
    ) -> Self {
        Self {
            id: id.into(),
            subject: subject.map(|s| s.into()),
            best_span: best_span.map(|s| s.into()),
            ssc_facts: ssc_facts.map(|s| s.into()),
            event_time: event_time.into(),
            score,
            room: None,
            retrieval_source: None,
            distilled: None,
            representation: None,
            tier: None,
            estate_id: None,
            content: None,
            extents: None,
            exemplars: None,
        }
    }
}

// ─── temporal capability (structured capabilities object) ────────────────────

/// Structured representation of the temporal recall capability signal,
/// mirroring the `temporal:` control line for `capabilities.temporal` in
/// structuredContent. Absent when no temporal narration applies or when
/// the narration is the loose date-seeking variant (which has no
/// mode/source/grab/from/to structure).
/// Mirrors Swift `TemporalCapability`.
#[derive(Debug, Clone, PartialEq)]
pub struct TemporalCapability {
    pub mode: String,
    pub source: String,
    pub grab: String,
    pub from: String,
    pub to: String,
    /// Widened days when the window was broadened; absent if not widened.
    pub widened_days: Option<i64>,
}

// ─── control signals ─────────────────────────────────────────────────────────

/// Deviation-only capability signals that trail S1 rows in a fixed absolute
/// order (§11.3): discrimination → temporal|walk → degradation → tie note → hint.
/// Every field is absent (None/false) at the nominal happy path; the composer
/// emits lines only for non-default states.
/// Mirrors Swift `ControlSignals`.
#[derive(Debug, Clone, Default)]
pub struct ControlSignals {
    /// Discrimination level: "low" or "medium". None = absent (high separation
    /// or single result — no line rendered).
    pub discrimination: Option<String>,

    /// Full temporal narration text for the `temporal:` line.
    /// Includes the `temporal: ` prefix. None = line absent.
    pub temporal_narration: Option<String>,

    /// Structured capabilities data for the `capabilities.temporal` key.
    /// None = absent from structuredContent even when temporal_narration present
    /// (e.g. loose date-seeking variant has no parseable structure).
    pub temporal_capability: Option<TemporalCapability>,

    /// Walk stage name (e.g. "expansion"). None = line absent.
    pub walk_stage: Option<String>,

    /// Walk early-stop flag. Only consulted when walk_stage is Some.
    pub walk_stopped_early: Option<bool>,

    /// True = emit the degradation line.
    pub degraded: bool,

    /// True = emit the non-deterministic tie note line.
    pub tie_note: bool,

    /// Coaching hint text (without the `hint: ` prefix). None = line absent.
    pub hint: Option<String>,
}

// ─── S3 full record data ─────────────────────────────────────────────────────

/// One tunnel edge for the S3 full-record tunnels block.
pub struct FullRecordTunnel {
    /// True = outgoing (→); false = incoming (←).
    pub is_outgoing: bool,
    /// Target / source drawer UUID.
    pub other_id: String,
    /// Edge label (e.g. "relates", "precedes").
    pub label: String,
}

/// Typed intermediate for the S3 full-record shape (§11.6).
/// The subject line is present only when subject is Some.
/// Mirrors Swift `FullRecordData`.
pub struct FullRecordData {
    pub id: String,
    pub room: String,
    pub wing: String,
    pub subject: Option<String>,
    pub filed_at: String,       // ISO-8601 with Z
    pub event_time: String,     // ISO-8601 with Z
    pub state: String,
    pub trust: String,
    pub sensitivity: String,
    pub exportability: String,
    pub confirmation: String,
    pub lineage_id: String,
    /// Confirmed-active tunnels only; capped at 50 in the renderer.
    pub tunnels: Vec<FullRecordTunnel>,
    pub content: String,
}

// ─── S4 fact row data ────────────────────────────────────────────────────────

/// One fact row for the S4 fact-search surface (§11.7).
pub struct FactSearchRow {
    pub fact_id: String,
    pub subject: String,
    pub predicate: String,
    pub object: String,
    /// Source drawer UUID, or None for a freestanding assertion (renders `-`).
    pub source_drawer_id: Option<String>,
    pub filed_at: String,
}

/// One fact row for the S4 fact-timeline surface (§11.7).
pub struct FactTimelineRow {
    pub filed_at: String,
    /// Lifecycle label: "active", "retired(B)", "retired(C)", "unknown(<raw>)".
    pub lifecycle: String,
    pub fact_id: String,
    pub subject: String,
    pub predicate: String,
    pub object: String,
    /// Source drawer UUID, or None for a freestanding assertion.
    pub source_drawer_id: Option<String>,
}

// ─── S5 edge row data ────────────────────────────────────────────────────────

/// One edge row for the S5 graph-edge surface (§11.8).
/// The far endpoint renders the S2 pick fields (UUID, subject, first sentence,
/// SSC, event time) without a score column.
pub struct EdgeRow {
    pub tunnel_id: String,
    /// The edge kind/label. Lifecycle suffix "(lifecycle)" appended when not active.
    pub kind_label: String,
    /// Lifecycle; None or "active" = no suffix appended to kind_label.
    pub lifecycle: Option<String>,
    /// Far endpoint rendered as S2 pick fields.
    pub far_endpoint: CandidateRowData,
}

// ─── S6 tabular data ─────────────────────────────────────────────────────────

/// A typed S6 tabular cell value.
#[derive(Debug, Clone, PartialEq)]
pub enum TabularCellValue {
    Text(String),
    Integer(i64),
    Float(f64),
    Bool(bool),
}

/// A typed S6 dataset query result.
pub struct TabularQueryData {
    pub dataset_id: String,
    pub dataset_name: String,
    /// Number of rows returned in this reply.
    pub returned: usize,
    /// Total matching rows before the limit; None when computing it would
    /// require a separate full scan (never silently paid per §8.10).
    pub total: Option<usize>,
    pub limit: usize,
    pub order_column: String,
    pub order_direction: String,
    pub columns: Vec<String>,
    /// Rows in caller order. Each element is one column value (None = NULL).
    /// Values must already be in the `columns` order.
    pub rows: Vec<Vec<Option<TabularCellValue>>>,
}

/// Per-column statistics for one column in an S6 dataset stats result.
pub struct TabularColumnStats {
    pub name: String,
    pub count: usize,
    pub nulls: usize,
    pub distinct: usize,
    /// Numeric stats; None for text columns.
    pub min: Option<String>,
    pub max: Option<String>,
    pub mean: Option<String>,
    pub stddev: Option<String>,
}

/// A typed S6 dataset stats result.
pub struct TabularStatsData {
    pub dataset_id: String,
    pub dataset_name: String,
    pub total_rows: usize,
    pub total_columns: usize,
    pub columns: Vec<TabularColumnStats>,
}

// ─── synthesis document data ──────────────────────────────────────────────────

/// Typed intermediate for the grounded synthesis document (§11.4).
pub struct SynthesisData {
    pub drawer_count: usize,
    /// Normalized extracted cue terms; None for whole-estate digest (no query: line).
    pub cue_terms: Option<Vec<String>>,
    /// Plain prose summary paragraph (no label).
    pub summary: String,
    /// Candidate section rows (rendered as S1 candidate block after summary).
    pub rows: Vec<CandidateRowData>,
    pub control: ControlSignals,
}

// ─── federated estate section ─────────────────────────────────────────────────

/// One per-estate section for federated recall (§11.2).
pub struct FederatedSection {
    pub estate_name: String,
    pub estate_id: String,
    pub rows: Vec<CandidateRowData>,
    pub control: ControlSignals,
}

// ─── S2 batch get entry ───────────────────────────────────────────────────────

/// One entry in a S2 batch-get result (found row or not-found id).
pub enum BatchGetEntry {
    Found(CandidateRowData),
    NotFound(String),
}

// ─── composed result ──────────────────────────────────────────────────────────

/// The full dual-format output from the composer: text payload and
/// structuredContent JSON. The text is the AI surface and audit fallback;
/// the structured block is the machine-consumption target.
pub struct ComposedResult {
    /// Text payload (the MCP `content[0].text` value).
    pub text: String,
    /// structuredContent JSON value, or None for surfaces that do not
    /// declare a structuredContent schema (S3/S4/S5/S6 text-only surfaces).
    pub structured: Option<Value>,
}

// ─── ResultComposer ───────────────────────────────────────────────────────────

// All functions are free functions in this module (no struct; mirrors the Swift
// `enum ResultComposer` with static methods — no-instance pattern).

// ─── value normalization (§11.1 rule 1) ──────────────────────────────────────

/// Normalize a field value for use in S1/S2/S4/S5 rows:
///   - embedded newlines (CR/LF/CRLF) → single space
///   - whitespace runs → one space (trim leading/trailing)
///   - literal U+00B7 middle-dot → `-` (prevents separator injection)
///
/// S6 tabular values are EXEMPT from this normalization — they use
/// lossless quoting instead.
pub fn normalize_value(raw: &str) -> String {
    // Replace newline variants with a space before collapsing whitespace.
    let replaced = raw
        .replace("\r\n", " ")
        .replace('\r', " ")
        .replace('\n', " ")
        .replace('\u{00B7}', "-");
    // Collapse whitespace runs and trim.
    replaced
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

// ─── first-sentence truncation (§11.1 rule 3) ────────────────────────────────

/// Hard cut the first sentence at 120 characters with no ellipsis.
/// Operates on char boundaries (Swift String.prefix is also char-based).
pub fn truncate_first_sentence(raw: &str) -> &str {
    // Find the char boundary for the 120th Unicode scalar, matching Swift.
    let mut char_count = 0;
    for (byte_pos, _ch) in raw.char_indices() {
        if char_count == 120 {
            return &raw[..byte_pos];
        }
        char_count += 1;
    }
    raw   // fewer than 120 chars
}

// ─── single row rendering ─────────────────────────────────────────────────────

fn normalized_subject(row: &CandidateRowData) -> String {
    row.subject.as_deref().map(normalize_value).unwrap_or_else(|| "-".to_string())
}

fn normalized_best_span(row: &CandidateRowData, subject_normalized: &str) -> String {
    let Some(bs) = &row.best_span else { return "-".to_string() };
    let truncated = truncate_first_sentence(bs);
    let normalized = normalize_value(truncated);
    if normalized.is_empty() || normalized == subject_normalized {
        "-".to_string()
    } else {
        normalized
    }
}

fn ssc_text(row: &CandidateRowData) -> String {
    row.ssc_facts.as_deref().unwrap_or("-").to_string()
}

/// Render one S1 row (six fixed columns). The score is mandatory;
/// pass the actual score value — callers must not omit it.
///
/// Column order: uuid · subject · bestSpan · sscFacts · eventTime · score%.4f
pub fn render_s1_row(row: &CandidateRowData) -> String {
    let subject_text = normalized_subject(row);
    let span_text = normalized_best_span(row, &subject_text);
    let ssc = ssc_text(row);
    let score_text = format!("{:.4}", row.score.unwrap_or(0.0));
    [row.id.as_str(), &subject_text, &span_text, &ssc,
     &row.event_time, &score_text].join(SEP)
}

/// Render one S2 row (five fixed columns, no score).
///
/// Column order: uuid · subject · bestSpan · sscFacts · eventTime
pub fn render_s2_row(row: &CandidateRowData) -> String {
    let subject_text = normalized_subject(row);
    let span_text = normalized_best_span(row, &subject_text);
    let ssc = ssc_text(row);
    [row.id.as_str(), &subject_text, &span_text, &ssc,
     &row.event_time].join(SEP)
}

// ─── S1 ranked surface (§11.2) ────────────────────────────────────────────────

/// Render the full S1 ranked surface: header + rows + control lines.
///
/// The header is singular when rows.count == 1:
///   "found 1 candidate memory, one per line"
///   "found N candidate memories, one per line"
///
/// Control lines follow in the absolute fixed order (§11.3):
///   discrimination → temporal|walk → degradation → tie note → hint
pub fn render_s1_surface(rows: &[CandidateRowData], control: &ControlSignals) -> ComposedResult {
    let n = rows.len();
    let header = if n == 1 {
        "found 1 candidate memory, one per line".to_string()
    } else {
        format!("found {} candidate memories, one per line", n)
    };
    let mut lines = vec![header];
    for row in rows {
        lines.push(render_s1_row(row));
    }
    lines.extend(control_lines(control));
    ComposedResult {
        text: lines.join("\n"),
        structured: Some(structured_s1(rows, control)),
    }
}

/// Render the S1 empty-result surface: header + optional hint (§11.1 rule 7).
pub fn render_empty_s1(hint: Option<&str>) -> ComposedResult {
    let mut lines = vec!["found 0 candidate memories, one per line".to_string()];
    if let Some(h) = hint {
        lines.push(format!("hint: {}", h));
    }
    ComposedResult {
        text: lines.join("\n"),
        structured: Some(json!({"results": []})),
    }
}

// ─── S2 unranked memory rows (§11.5) ──────────────────────────────────────────

/// Render the S2 memory-list surface (filing order, unranked).
pub fn render_s2_listing(wing: &str, room: &str, rows: &[CandidateRowData]) -> ComposedResult {
    let n = rows.len();
    let header = format!("listing {} memories in {} / {} — filing order, unranked", n, wing, room);
    let mut lines = vec![header];
    for row in rows {
        lines.push(render_s2_row(row));
    }
    ComposedResult { text: lines.join("\n"), structured: None }
}

/// Render the S2 empty listing header only.
pub fn render_empty_s2_listing(wing: &str, room: &str) -> ComposedResult {
    ComposedResult {
        text: format!("listing 0 memories in {} / {} — filing order, unranked", wing, room),
        structured: None,
    }
}

/// Render the S2 batch-get surface (request order, exactly one line per
/// requested id in position; duplicates duplicate; not-found lines in place).
pub fn render_s2_batch_get(
    entries: &[BatchGetEntry],
    resolved: usize,
    requested: usize,
) -> ComposedResult {
    let header = format!("resolved {} of {} requested memories, in request order", resolved, requested);
    let mut lines = vec![header];
    for entry in entries {
        match entry {
            BatchGetEntry::Found(row) => lines.push(render_s2_row(row)),
            BatchGetEntry::NotFound(id) => lines.push(format!("not found: {}", id)),
        }
    }
    ComposedResult { text: lines.join("\n"), structured: None }
}

// ─── S3 full record (§11.6) ───────────────────────────────────────────────────

/// Render the S3 full-record shape.
/// The `subject:` line is omitted when the drawer carries none.
/// Tunnels are capped at 50.
pub fn render_s3_record(record: &FullRecordData) -> ComposedResult {
    let mut lines = vec![
        format!("memory {}", record.id),
        format!("room: {}  wing: {}", record.room, record.wing),
    ];
    if let Some(subject) = &record.subject {
        lines.push(format!("subject: {}", subject));
    }
    lines.push(format!("filed_at: {}", record.filed_at));
    lines.push(format!("event_time: {}", record.event_time));
    lines.push(format!("state: {}", record.state));
    lines.push(format!("trust: {}", record.trust));
    lines.push(format!("sensitivity: {}", record.sensitivity));
    lines.push(format!("exportability: {}", record.exportability));
    lines.push(format!("confirmation: {}", record.confirmation));
    lines.push(format!("lineage: {}", record.lineage_id));
    lines.push(format!("tunnels: {}", record.tunnels.len()));
    for tunnel in record.tunnels.iter().take(50) {
        let arrow = if tunnel.is_outgoing { "→" } else { "←" };
        lines.push(format!("  {} {}  [{}]", arrow, tunnel.other_id, tunnel.label));
    }
    lines.push("content:".to_string());
    lines.push(record.content.clone());
    ComposedResult { text: lines.join("\n"), structured: None }
}

// ─── S4 fact rows (§11.7) ─────────────────────────────────────────────────────

/// Render the S4 fact-search surface: six fixed columns.
///   factID · subject · predicate · object · sourceDrawerUUID|-  · filedAt
pub fn render_s4_fact_search(facts: &[FactSearchRow]) -> ComposedResult {
    let n = facts.len();
    let header = if n == 1 {
        "found 1 fact, one per line".to_string()
    } else {
        format!("found {} facts, one per line", n)
    };
    let mut lines = vec![header];
    for fact in facts {
        let source = fact.source_drawer_id.as_deref().unwrap_or("-");
        let row = [fact.fact_id.as_str(), &fact.subject, &fact.predicate,
                   &fact.object, source, &fact.filed_at].join(SEP);
        lines.push(row);
    }
    ComposedResult { text: lines.join("\n"), structured: None }
}

/// Render the S4 fact-timeline surface: seven time-major columns.
///   filedAt · lifecycle · factID · subject · predicate · object · source|-
pub fn render_s4_fact_timeline(facts: &[FactTimelineRow]) -> ComposedResult {
    let n = facts.len();
    let header = format!("fact timeline: {} fact{} in filing order (active and retired)",
                         n, if n == 1 { "" } else { "s" });
    let mut lines = vec![header];
    for fact in facts {
        let source = fact.source_drawer_id.as_deref().unwrap_or("-");
        let row = [fact.filed_at.as_str(), &fact.lifecycle, &fact.fact_id,
                   &fact.subject, &fact.predicate, &fact.object, source].join(SEP);
        lines.push(row);
    }
    ComposedResult { text: lines.join("\n"), structured: None }
}

// ─── S5 edge rows (§11.8) ─────────────────────────────────────────────────────

/// Render the S5 graph-edge surface.
/// direction: "outgoing" | "incoming"
///
/// Row shape: tunnelID · kind/label[(lifecycle)] · <S2 pick fields no score>
pub fn render_s5_edges(direction: &str, edges: &[EdgeRow]) -> ComposedResult {
    let n = edges.len();
    let noun = if n == 1 { "connection" } else { "connections" };
    let header = format!("found {} {} {}, one per line", n, direction, noun);
    let mut lines = vec![header];
    for edge in edges {
        let kind_field = match &edge.lifecycle {
            Some(lc) if lc != "active" => format!("{} ({})", edge.kind_label, lc),
            _ => edge.kind_label.clone(),
        };
        // Far endpoint: S2 pick fields (six columns without a score prefix).
        let far = render_s2_row(&edge.far_endpoint);
        let row = [edge.tunnel_id.as_str(), &kind_field, &far].join(SEP);
        lines.push(row);
    }
    ComposedResult { text: lines.join("\n"), structured: None }
}

// ─── S6 tabular rows (§11.9) ──────────────────────────────────────────────────

/// Encode one S6 cell value for presentation.
/// Applies lossless quoting when the value requires it.
pub fn s6_encode_cell(value: &TabularCellValue) -> String {
    match value {
        TabularCellValue::Text(s) => s6_quote_if_needed(s),
        TabularCellValue::Integer(i) => i.to_string(),
        TabularCellValue::Float(d) => {
            // Shortest exact decimal — matches Swift's String(d) for most values.
            // Use Rust's default Display for f64 which gives shortest round-trip.
            format_float(*d)
        }
        TabularCellValue::Bool(b) => if *b { "true" } else { "false" }.to_string(),
    }
}

/// Format a float as the shortest exact decimal, matching Swift's String(d).
/// For values like 3.14, 0.0, -1.5 this is straightforward.
fn format_float(d: f64) -> String {
    // Use Rust's default float formatting, which gives shortest round-trip representation.
    // For integers stored as float (e.g. 0.0), this gives "0", but we need "0".
    // Swift's String(d) gives "0.0" for 0.0. To match: format as Rust does.
    let s = format!("{}", d);
    s
}

/// Quote an S6 text cell when it contains the separator sequence, a
/// double-quote, a newline, or leading/trailing whitespace.
/// Embedded newlines render as the two-character escape `\n` inside quotes.
/// Embedded double-quotes render as `""`.
/// Other content is left as-is inside the double-quote envelope.
pub fn s6_quote_if_needed(s: &str) -> String {
    let needs_quoting = s.contains(SEP)
        || s.contains('"')
        || s.contains('\n')
        || s.contains('\r')
        || s.starts_with(' ')
        || s.ends_with(' ');
    if !needs_quoting {
        return s.to_string();
    }
    // Empty string → ""
    if s.is_empty() {
        return "\"\"".to_string();
    }
    let escaped = s
        .replace("\r\n", "\\n")
        .replace('\r', "\\n")
        .replace('\n', "\\n")
        .replace('"', "\"\"");
    format!("\"{}\"", escaped)
}

/// Render the S6 dataset query surface with lossless value encoding.
/// Values round-trip exactly; the §11.1 `·`→`-` replacement NEVER applies.
pub fn render_s6_query(data: &TabularQueryData) -> ComposedResult {
    let total_part = data.total
        .map(|t| format!(" of {}", t))
        .unwrap_or_default();
    let header = format!(
        "dataset {} \"{}\": returned{} matching rows (limit {}, ordered by {} {})",
        data.dataset_id, data.dataset_name,
        format!(" {}{}", data.returned, total_part),
        data.limit, data.order_column, data.order_direction
    );
    let col_header = data.columns.join(SEP);
    let mut lines = vec![header, col_header];
    for row_vals in &data.rows {
        let fields: Vec<String> = row_vals.iter().map(|v| {
            match v {
                None => String::new(),   // NULL = empty unquoted
                Some(val) => s6_encode_cell(val),
            }
        }).collect();
        lines.push(fields.join(SEP));
    }
    // Structured columns + rows for the capabilities block.
    let structured_cols: Value = Value::Array(data.columns.iter().map(|c| json!(c)).collect());
    let structured_rows: Value = Value::Array(data.rows.iter().map(|row| {
        Value::Array(row.iter().map(|v| {
            match v {
                None => Value::Null,
                Some(TabularCellValue::Text(s)) => json!(s),
                Some(TabularCellValue::Integer(i)) => json!(i),
                Some(TabularCellValue::Float(d)) => json!(d),
                Some(TabularCellValue::Bool(b)) => json!(b),
            }
        }).collect())
    }).collect());
    let structured = json!({"columns": structured_cols, "rows": structured_rows});
    ComposedResult { text: lines.join("\n"), structured: Some(structured) }
}

/// Render the S6 dataset stats surface.
pub fn render_s6_stats(data: &TabularStatsData) -> ComposedResult {
    let header = format!(
        "dataset {} \"{}\": {} rows, {} columns",
        data.dataset_id, data.dataset_name, data.total_rows, data.total_columns
    );
    let mut lines = vec![header];
    for col in &data.columns {
        let mut parts = vec![
            col.name.clone(),
            format!("count={}", col.count),
            format!("nulls={}", col.nulls),
            format!("distinct={}", col.distinct),
        ];
        if let Some(min) = &col.min { parts.push(format!("min={}", min)); }
        if let Some(max) = &col.max { parts.push(format!("max={}", max)); }
        if let Some(mean) = &col.mean { parts.push(format!("mean={}", mean)); }
        if let Some(sd) = &col.stddev { parts.push(format!("stddev={}", sd)); }
        lines.push(parts.join(SEP));
    }
    ComposedResult { text: lines.join("\n"), structured: None }
}

// ─── synthesis document (§11.4) ──────────────────────────────────────────────

/// Render the grounded synthesis document.
/// When cue_terms is None, the `query:` line is omitted (whole-estate form).
/// No scaffold fields (no `summary:`, `patterns:`, etc. labels).
pub fn render_synthesis(data: &SynthesisData) -> ComposedResult {
    let drawer = if data.drawer_count == 1 { "drawer" } else { "drawers" };
    let mut lines = vec![format!("grounded_synthesis: {} {}", data.drawer_count, drawer)];
    if let Some(cues) = &data.cue_terms {
        lines.push(format!("query: {}", cues.join(", ")));
    }
    lines.push(data.summary.clone());
    // Candidate section: S1 sub-block (header + rows).
    let n = data.rows.len();
    let candidate_header = if n == 1 {
        "found 1 candidate memory, one per line".to_string()
    } else {
        format!("found {} candidate memories, one per line", n)
    };
    lines.push(candidate_header);
    for row in &data.rows {
        lines.push(render_s1_row(row));
    }
    lines.extend(control_lines(&data.control));

    // Structured: top-level cues + summary + results.
    let mut struct_obj = serde_json::Map::new();
    struct_obj.insert("results".to_string(), Value::Array(
        data.rows.iter().map(structured_row_object).collect()
    ));
    if let Some(cues) = &data.cue_terms {
        struct_obj.insert("cues".to_string(), Value::Array(
            cues.iter().map(|c| json!(c)).collect()
        ));
    }
    struct_obj.insert("summary".to_string(), json!(&data.summary));
    if let Some(caps) = structured_capabilities(&data.control) {
        struct_obj.insert("capabilities".to_string(), caps);
    }
    ComposedResult {
        text: lines.join("\n"),
        structured: Some(Value::Object(struct_obj)),
    }
}

// ─── vague recall (§11.2) ────────────────────────────────────────────────────

/// Render the two-tier vague-recall surface:
///   "found N vague summaries|summary, one per line"  + summary rows
///   "found M hydrated originals|original, one per line" + original rows
/// Both headers use their own singular/plural form.
pub fn render_vague_recall(
    summaries: &[CandidateRowData],
    originals: &[CandidateRowData],
    control: &ControlSignals,
) -> ComposedResult {
    let ns = summaries.len();
    let no = originals.len();
    let sum_header = if ns == 1 {
        "found 1 vague summary, one per line".to_string()
    } else {
        format!("found {} vague summaries, one per line", ns)
    };
    let orig_header = if no == 1 {
        "found 1 hydrated original, one per line".to_string()
    } else {
        format!("found {} hydrated originals, one per line", no)
    };
    let mut lines = vec![sum_header];
    for row in summaries {
        lines.push(render_s1_row(row));
    }
    lines.push(orig_header);
    for row in originals {
        lines.push(render_s1_row(row));
    }
    lines.extend(control_lines(control));
    let all_rows: Vec<&CandidateRowData> = summaries.iter().chain(originals.iter()).collect();
    ComposedResult {
        text: lines.join("\n"),
        structured: Some(structured_s1_ref(&all_rows, control)),
    }
}

// ─── distilled recall (§11.2) ────────────────────────────────────────────────

/// Render the distilled recall surface: each row followed by its
/// distilled text as a four-space indented unlabeled continuation.
/// A row still owing a distillate (representation == "contentFallback")
/// receives the fallback marker then the verbatim content.
pub fn render_distilled_recall(rows: &[CandidateRowData], control: &ControlSignals) -> ComposedResult {
    let n = rows.len();
    let header = if n == 1 {
        "found 1 candidate memory, one per line".to_string()
    } else {
        format!("found {} candidate memories, one per line", n)
    };
    let mut lines = vec![header];
    for row in rows {
        lines.push(render_s1_row(row));
        if let Some(distilled_text) = &row.distilled {
            if row.representation.as_deref() == Some("contentFallback") {
                lines.push("    source: content (not yet distilled)".to_string());
                lines.push(format!("    {}", distilled_text));
            } else {
                // "distilled" or unknown — render as clean continuation.
                lines.push(format!("    {}", distilled_text));
            }
        }
    }
    lines.extend(control_lines(control));
    ComposedResult {
        text: lines.join("\n"),
        structured: Some(structured_s1(rows, control)),
    }
}

// ─── federated recall (§11.2) ────────────────────────────────────────────────

/// Render the federated recall surface: one section per estate with
/// `estate: <name> [<uuid>]` header before each S1 block.
pub fn render_federated_recall(estates: &[FederatedSection]) -> ComposedResult {
    let mut lines: Vec<String> = Vec::new();
    let mut all_rows: Vec<&CandidateRowData> = Vec::new();
    for section in estates {
        lines.push(format!("estate: {} [{}]", section.estate_name, section.estate_id));
        let n = section.rows.len();
        let h = if n == 1 {
            "found 1 candidate memory, one per line".to_string()
        } else {
            format!("found {} candidate memories, one per line", n)
        };
        lines.push(h);
        for row in &section.rows {
            lines.push(render_s1_row(row));
        }
        lines.extend(control_lines(&section.control));
        all_rows.extend(section.rows.iter());
    }
    // Structured: all rows combined (per §8.9, one entry per rendered row).
    ComposedResult {
        text: lines.join("\n"),
        structured: Some(json!({
            "results": Value::Array(all_rows.iter().map(|r| structured_row_object(r)).collect())
        })),
    }
}

// ─── control lines (§11.3) ────────────────────────────────────────────────────

/// Emit the deviation-only trailing control lines in the absolute fixed
/// order: discrimination → temporal|walk → degradation → tie note → hint.
pub fn control_lines(signals: &ControlSignals) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    // 1. Discrimination (deviation-only: only low/medium render).
    if let Some(disc) = &signals.discrimination {
        match disc.as_str() {
            "low" => lines.push("discrimination: low — top results within epsilon.".to_string()),
            "medium" => lines.push("discrimination: medium — partial separation.".to_string()),
            _ => {} // "high" or unknown: no line
        }
    }
    // 2. Tool-specific narration: temporal XOR walk (at most one).
    if let Some(narration) = &signals.temporal_narration {
        lines.push(narration.clone());
    } else if let Some(stage) = &signals.walk_stage {
        let stopped = if signals.walk_stopped_early.unwrap_or(false) { "yes" } else { "no" };
        lines.push(format!("walk: stage={} stoppedEarly={}", stage, stopped));
    }
    // 3. Degradation.
    if signals.degraded {
        lines.push("retrieval: degraded — one or more ranking stages unavailable".to_string());
    }
    // 4. Non-determinate tie note.
    if signals.tie_note {
        lines.push("note: additional results share this score on a non-deterministic tie; refine the query".to_string());
    }
    // 5. Coaching hint.
    if let Some(hint) = &signals.hint {
        lines.push(format!("hint: {}", hint));
    }
    lines
}

// ─── structured S1 output (§11.10) ───────────────────────────────────────────

/// Build the structuredContent JSON for an S1 surface (base schema +
/// surface extensions + capabilities object).
fn structured_s1(rows: &[CandidateRowData], control: &ControlSignals) -> Value {
    let mut obj = serde_json::Map::new();
    obj.insert("results".to_string(), Value::Array(
        rows.iter().map(structured_row_object).collect()
    ));
    if let Some(caps) = structured_capabilities(control) {
        obj.insert("capabilities".to_string(), caps);
    }
    Value::Object(obj)
}

/// Build the structuredContent JSON for an S1 surface from a reference slice.
fn structured_s1_ref(rows: &[&CandidateRowData], control: &ControlSignals) -> Value {
    let mut obj = serde_json::Map::new();
    obj.insert("results".to_string(), Value::Array(
        rows.iter().map(|r| structured_row_object(r)).collect()
    ));
    if let Some(caps) = structured_capabilities(control) {
        obj.insert("capabilities".to_string(), caps);
    }
    Value::Object(obj)
}

/// Build one structured row object for a CandidateRowData.
/// Optional fields are ABSENT (not null) when text column renders `-`.
pub fn structured_row_object(row: &CandidateRowData) -> Value {
    let mut obj = serde_json::Map::new();
    obj.insert("id".to_string(), json!(row.id));

    // Subject: absent when None.
    if let Some(subject) = &row.subject {
        obj.insert("subject".to_string(), json!(subject));
    }

    // Best span: absent when None or when byte-identical to subject
    // after normalization (same rule as text rendering).
    let subj_norm = row.subject.as_deref().map(normalize_value).unwrap_or_default();
    if let Some(bs) = &row.best_span {
        let truncated = truncate_first_sentence(bs);
        let bs_norm = normalize_value(truncated);
        if !bs_norm.is_empty() && bs_norm != subj_norm {
            obj.insert("bestSpan".to_string(), json!(bs_norm));
        }
    }

    // SSC facts: absent when None. Raw string (e.g. "kind: hobby, entity: painting").
    if let Some(ssc) = &row.ssc_facts {
        obj.insert("sscFacts".to_string(), json!(ssc));
    }

    obj.insert("eventTime".to_string(), json!(row.event_time));

    // Score: absent on S2 surfaces (score == None).
    if let Some(score) = row.score {
        obj.insert("score".to_string(), json!(score));
    }

    // Room: absent when None.
    if let Some(room) = &row.room {
        obj.insert("room".to_string(), json!(room));
    }

    // Surface extensions: absent when None.
    if let Some(retrieval_source) = &row.retrieval_source {
        obj.insert("retrievalSource".to_string(), json!(retrieval_source));
    }
    if let Some(distilled) = &row.distilled {
        obj.insert("distilled".to_string(), json!(distilled));
    }
    if let Some(representation) = &row.representation {
        obj.insert("representation".to_string(), json!(representation));
    }
    if let Some(tier) = &row.tier {
        obj.insert("tier".to_string(), json!(tier));
    }
    if let Some(estate_id) = &row.estate_id {
        obj.insert("estateID".to_string(), json!(estate_id));
    }
    if let Some(content) = &row.content {
        obj.insert("content".to_string(), json!(content));
    }
    if let Some(extents) = &row.extents {
        obj.insert("extent".to_string(), Value::Array(extents.iter().map(|e| json!(e)).collect()));
    }
    if let Some(exemplars) = &row.exemplars {
        obj.insert("exemplars".to_string(), Value::Array(exemplars.iter().map(|e| json!(e)).collect()));
    }

    Value::Object(obj)
}

// ─── cap line ────────────────────────────────────────────────────────────────

/// Render the cap line appended to an S1 or S2 surface when the result set
/// is truncated at the given limit. Callers append this line when
/// `rows.len() == limit`; the composer does not append it automatically
/// because the caller owns the limit policy.
///
/// Format: "listing capped at N — narrow with <arg>"
pub fn render_cap_line(limit: usize, narrowing_arg: &str) -> String {
    format!("listing capped at {} \u{2014} narrow with {}", limit, narrowing_arg)
}

// ─── structured capabilities ──────────────────────────────────────────────────

/// Build the capabilities object from ControlSignals.
/// Each key is ABSENT when its control line does not render.
pub fn structured_capabilities(signals: &ControlSignals) -> Option<Value> {
    let mut caps = serde_json::Map::new();

    if let Some(disc) = &signals.discrimination {
        if disc == "low" || disc == "medium" {
            caps.insert("discrimination".to_string(), json!(disc));
        }
    }

    if let Some(tc) = &signals.temporal_capability {
        let mut temporal = serde_json::Map::new();
        temporal.insert("mode".to_string(), json!(tc.mode));
        temporal.insert("source".to_string(), json!(tc.source));
        temporal.insert("grab".to_string(), json!(tc.grab));
        temporal.insert("from".to_string(), json!(tc.from));
        temporal.insert("to".to_string(), json!(tc.to));
        if let Some(wd) = tc.widened_days {
            temporal.insert("widenedDays".to_string(), json!(wd));
        }
        caps.insert("temporal".to_string(), Value::Object(temporal));
    }

    if let Some(stage) = &signals.walk_stage {
        caps.insert("walk".to_string(), json!({
            "stage": stage,
            "stoppedEarly": signals.walk_stopped_early.unwrap_or(false),
        }));
    }

    if signals.degraded {
        caps.insert("degraded".to_string(), json!(true));
    }

    if caps.is_empty() { None } else { Some(Value::Object(caps)) }
}
