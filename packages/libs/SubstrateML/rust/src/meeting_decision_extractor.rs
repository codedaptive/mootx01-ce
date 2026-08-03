//! meeting_decision_extractor.rs — Rust twin of MeetingDecisionExtractor.swift.
//!
//! DCP M6 — the controlled-decision grammar (DCP_M0_CONTRACT §9, locked).
//! Line-anchored, one decision per line; anything the grammar cannot
//! prove it understands resolves to Unknown WITH a reason — the extractor
//! never guesses, because its output feeds the typed proving lane
//! (conflict_projection) where a wrong parse would manufacture evidence.
//!
//! Three accepted forms:
//!   Decision: <entity>.<dimension> = <value>
//!   Approved <dimension> for <entity>: <value>
//!   Replaces decision <id>: <entity>.<dimension> = <value>
//!
//! Rejected to Unknown (F11/F12): pronoun entities, unregistered
//! dimensions, values the rule's normalizer refuses, quoted spans,
//! hypothetical/reported-speech markers, multiple `=`.

use crate::conflict_projection::{normalize, ConflictRuleRegistry, TypedConflictValue};

/// Stable extractor identity stamped on everything this grammar files.
pub const MEETING_DECISION_EXTRACTOR_ID: &str = "dcp-meeting-v1";

/// Why a line resolved to Unknown. Stable spellings — these appear in
/// extraction reports and tests in both ports.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecisionRejectReason {
    /// The entity slot is a pronoun ("he", "they", "it", ...) — F11.
    PronounEntity,
    /// The dimension has no registered rule (UnknownRule never proves).
    UnregisteredDimension,
    /// The rule's normalizer refused the value — F10 shape.
    ParseAmbiguous,
    /// The line carries a quoted span — reported text, not a decision (F12).
    QuotedSpan,
    /// Hypothetical/reported-speech marker — F12.
    HypotheticalMarker,
    /// More than one `=` on the line.
    MultipleEquals,
    /// The line matches no accepted form at all.
    NoGrammarMatch,
}

impl DecisionRejectReason {
    /// Wire spelling — matches the Swift raw values.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::PronounEntity => "pronoun_entity",
            Self::UnregisteredDimension => "unregistered_dimension",
            Self::ParseAmbiguous => "parse_ambiguous",
            Self::QuotedSpan => "quoted_span",
            Self::HypotheticalMarker => "hypothetical_marker",
            Self::MultipleEquals => "multiple_equals",
            Self::NoGrammarMatch => "no_grammar_match",
        }
    }
}

/// One accepted decision line, fully normalized and ready to file.
#[derive(Debug, Clone, PartialEq)]
pub struct ExtractedDecision {
    /// Entity exactly as written (canonicalization to a scoped conflict
    /// key happens at projection, not here — the extractor preserves
    /// the author's spelling for the KGFact subject).
    pub entity: String,
    /// Canonical dimension (the registered rule's spelling).
    pub dimension: String,
    /// The registered rule that accepted the value.
    pub rule_id: String,
    /// Value exactly as written (the KGFact object).
    pub raw_value: String,
    /// The rule-normalized typed value (proof-grade bytes).
    pub normalized_value: TypedConflictValue,
    /// For the `Replaces decision <id>:` form; None otherwise.
    pub replaces_id: Option<String>,
    /// 1-based line number in the transcript.
    pub line: usize,
}

/// One rejected line with its reason (deviation-only reporting).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RejectedDecisionLine {
    pub line: usize,
    pub reason: DecisionRejectReason,
}

/// One transcript's extraction outcome.
#[derive(Debug, Clone, PartialEq)]
pub struct MeetingDecisionExtraction {
    pub decisions: Vec<ExtractedDecision>,
    /// Lines that LOOKED like decision lines (matched a form prefix)
    /// but were rejected. Ordinary prose lines are not listed.
    pub rejected: Vec<RejectedDecisionLine>,
}

/// Pronoun list for the entity slot (case-insensitive, F11).
const PRONOUNS: &[&str] = &[
    "i", "you", "he", "she", "it", "we", "they", "him", "her", "them", "us", "me", "his",
    "hers", "its", "their", "theirs", "our", "ours", "this", "that", "these", "those",
    "someone", "everyone", "anybody",
];

/// Hypothetical / reported-speech markers (whole-word, lowercased).
const HYPOTHETICAL_MARKERS: &[&str] = &["if", "would", "might", "reportedly"];
/// Multi-word marker checked as a substring of the lowercased line.
const REPORTED_SPEECH_PHRASE: &str = "according to";

/// A line participates in the grammar only when it opens with one of
/// the three accepted form prefixes (case-sensitive by design — the
/// controlled register is part of the contract).
fn looks_like_decision_line(line: &str) -> bool {
    line.starts_with("Decision:")
        || line.starts_with("Approved ")
        || line.starts_with("Replaces decision ")
}

/// Extract every decision from `transcript` under `registry`.
pub fn extract(transcript: &str, registry: &ConflictRuleRegistry) -> MeetingDecisionExtraction {
    let mut decisions = Vec::new();
    let mut rejected = Vec::new();

    for (index, raw_line) in transcript.split('\n').enumerate() {
        let line_number = index + 1;
        let line = raw_line.trim();
        if !looks_like_decision_line(line) {
            continue;
        }
        match parse(line, registry) {
            Ok(mut decision) => {
                decision.line = line_number;
                decisions.push(decision);
            }
            Err(reason) => rejected.push(RejectedDecisionLine { line: line_number, reason }),
        }
    }
    MeetingDecisionExtraction { decisions, rejected }
}

fn parse(
    line: &str,
    registry: &ConflictRuleRegistry,
) -> Result<ExtractedDecision, DecisionRejectReason> {
    // Whole-line rejections first (M0 §9): quoted spans, markers,
    // multiple `=` — these veto regardless of form.
    if line.contains('"') || line.contains('\u{201C}') || line.contains('\u{201D}')
        || line.contains('\'')
    {
        return Err(DecisionRejectReason::QuotedSpan);
    }
    let lowered = line.to_lowercase();
    let words: Vec<&str> = lowered.split(|c: char| !c.is_alphabetic()).collect();
    if HYPOTHETICAL_MARKERS.iter().any(|m| words.contains(m)) {
        return Err(DecisionRejectReason::HypotheticalMarker);
    }
    if lowered.contains(REPORTED_SPEECH_PHRASE) {
        return Err(DecisionRejectReason::HypotheticalMarker);
    }
    if line.matches('=').count() > 1 {
        return Err(DecisionRejectReason::MultipleEquals);
    }

    // Form 3 first (its prefix contains no `:` before the id).
    if let Some(rest) = line.strip_prefix("Replaces decision ") {
        let Some(colon) = rest.find(':') else {
            return Err(DecisionRejectReason::NoGrammarMatch);
        };
        let replaced_id = rest[..colon].trim();
        if replaced_id.is_empty() {
            return Err(DecisionRejectReason::NoGrammarMatch);
        }
        return parse_assignment(&rest[colon + 1..], Some(replaced_id.to_string()), registry);
    }

    // Form 1: `Decision: <entity>.<dimension> = <value>`.
    if let Some(assignment) = line.strip_prefix("Decision:") {
        return parse_assignment(assignment, None, registry);
    }

    // Form 2: `Approved <dimension> for <entity>: <value>`.
    if let Some(rest) = line.strip_prefix("Approved ") {
        let Some(for_pos) = rest.find(" for ") else {
            return Err(DecisionRejectReason::NoGrammarMatch);
        };
        let dimension_raw = &rest[..for_pos];
        let tail = &rest[for_pos + " for ".len()..];
        let Some(colon) = tail.find(':') else {
            return Err(DecisionRejectReason::NoGrammarMatch);
        };
        let entity = tail[..colon].trim();
        let value = tail[colon + 1..].trim();
        return finish(entity, dimension_raw, value, None, registry);
    }
    Err(DecisionRejectReason::NoGrammarMatch)
}

/// Parse ` <entity>.<dimension> = <value>` (forms 1 and 3).
fn parse_assignment(
    assignment: &str,
    replaces_id: Option<String>,
    registry: &ConflictRuleRegistry,
) -> Result<ExtractedDecision, DecisionRejectReason> {
    let Some(equals) = assignment.find('=') else {
        return Err(DecisionRejectReason::NoGrammarMatch);
    };
    let lhs = assignment[..equals].trim();
    let value = assignment[equals + 1..].trim();
    // Entity may itself contain dots (scoped ids); the DIMENSION is the
    // last dot component.
    let Some(last_dot) = lhs.rfind('.') else {
        return Err(DecisionRejectReason::NoGrammarMatch);
    };
    if last_dot == 0 {
        return Err(DecisionRejectReason::NoGrammarMatch);
    }
    let entity = lhs[..last_dot].trim();
    let dimension_raw = &lhs[last_dot + 1..];
    finish(entity, dimension_raw, value, replaces_id, registry)
}

/// Shared validation tail: entity → dimension → value, in the precedence
/// the tests pin (pronoun before unregistered before value).
fn finish(
    entity: &str,
    dimension_raw: &str,
    value: &str,
    replaces_id: Option<String>,
    registry: &ConflictRuleRegistry,
) -> Result<ExtractedDecision, DecisionRejectReason> {
    if entity.is_empty() || value.is_empty() {
        return Err(DecisionRejectReason::NoGrammarMatch);
    }
    if PRONOUNS.contains(&normalize::enum_token(entity).as_str()) {
        return Err(DecisionRejectReason::PronounEntity);
    }
    // Exact dimension lookup first; then the `decision:` namespace —
    // the grammar's forms say "Decision"/"Approved", so a bare
    // `launch_date` reaches `decision:launch_date` without the author
    // spelling the namespace. Both lookups are exact-match; nothing fuzzy.
    let dimension = normalize::dimension_key(dimension_raw);
    let rule = registry
        .rule_for_dimension(&dimension)
        .or_else(|| registry.rule_for_dimension(&format!("decision:{dimension}")));
    let Some(rule) = rule else {
        return Err(DecisionRejectReason::UnregisteredDimension);
    };
    let Some(normalized) = (rule.normalize)(value) else {
        return Err(DecisionRejectReason::ParseAmbiguous);
    };
    Ok(ExtractedDecision {
        entity: entity.to_string(),
        dimension: rule.dimension.to_string(),
        rule_id: rule.rule_id.to_string(),
        raw_value: value.to_string(),
        normalized_value: normalized,
        replaces_id,
        line: 0,
    })
}

// DCP M6 golden corpus — Rust leg. Mirrors
// MeetingDecisionExtractorTests.swift one-for-one; the accepted
// canonical values and reject reasons are the cross-port fixture.
// Ledger cases F11 and F12 live here per DCP_M0_CONTRACT §10.
#[cfg(test)]
mod tests {
    use super::*;

    fn reg() -> ConflictRuleRegistry {
        ConflictRuleRegistry::v01()
    }

    /// Form 1 — the bare dimension reaches the `decision:` namespace.
    #[test]
    fn form1_decision_assignment() {
        let out = extract("Decision: project-phoenix.launch_date = 2026-09-15", &reg());
        assert!(out.rejected.is_empty());
        let d = &out.decisions[0];
        assert_eq!(d.entity, "project-phoenix");
        assert_eq!(d.dimension, "decision:launch_date");
        assert_eq!(d.rule_id, "dim.decision.launch_date");
        assert_eq!(d.raw_value, "2026-09-15");
        assert_eq!(d.normalized_value.canonical_bytes(), "dt:2026-09-15");
        assert_eq!(d.replaces_id, None);
        assert_eq!(d.line, 1);
    }

    /// Form 2 — `Approved <dimension> for <entity>: <value>`.
    #[test]
    fn form2_approved_for() {
        let out = extract("Approved employer for Sarah Chen C0: Acme Robotics", &reg());
        let d = &out.decisions[0];
        assert_eq!(d.entity, "Sarah Chen C0");
        assert_eq!(d.rule_id, "dim.person.employer");
        assert_eq!(
            d.normalized_value.canonical_bytes(),
            "e:dim.person.employer#acme robotics"
        );
    }

    /// Form 3 — `Replaces decision <id>: <entity>.<dimension> = <value>`.
    #[test]
    fn form3_replaces_decision() {
        let out = extract(
            "Replaces decision abc-123: project-phoenix.budget_ceiling = 1.5m USD",
            &reg(),
        );
        let d = &out.decisions[0];
        assert_eq!(d.replaces_id.as_deref(), Some("abc-123"));
        assert_eq!(d.rule_id, "dim.decision.budget_ceiling");
        assert_eq!(d.normalized_value.canonical_bytes(), "d:1500000");
    }

    /// F11 — pronoun entity → Unknown (pronoun_entity).
    #[test]
    fn f11_pronoun_entity_rejected() {
        let out = extract("Decision: they.launch_date = 2026-09-15", &reg());
        assert!(out.decisions.is_empty());
        assert_eq!(
            out.rejected,
            vec![RejectedDecisionLine { line: 1, reason: DecisionRejectReason::PronounEntity }]
        );
    }

    /// F12 — quoted span → Unknown (quoted_span).
    #[test]
    fn f12_quoted_span_rejected() {
        let out = extract("Approved employer for Sarah Chen C0: \"Acme Robotics\"", &reg());
        assert_eq!(
            out.rejected,
            vec![RejectedDecisionLine { line: 1, reason: DecisionRejectReason::QuotedSpan }]
        );
    }

    /// F12 — hypothetical marker anywhere on the line → Unknown.
    #[test]
    fn f12_hypothetical_rejected() {
        let out = extract(
            "Decision: project-phoenix.launch_date = 2026-09-15 if the vendor confirms",
            &reg(),
        );
        assert_eq!(
            out.rejected,
            vec![RejectedDecisionLine {
                line: 1,
                reason: DecisionRejectReason::HypotheticalMarker
            }]
        );
        let reported = extract(
            "Decision: project-phoenix.launch_date = 2026-09-15 according to Sam",
            &reg(),
        );
        assert_eq!(reported.rejected[0].reason, DecisionRejectReason::HypotheticalMarker);
    }

    /// Unregistered dimension → Unknown (never a guess).
    #[test]
    fn unregistered_dimension_rejected() {
        let out = extract("Decision: project-phoenix.headcount = 12", &reg());
        assert_eq!(
            out.rejected,
            vec![RejectedDecisionLine {
                line: 1,
                reason: DecisionRejectReason::UnregisteredDimension
            }]
        );
    }

    /// Ambiguous date form → Unknown (parse_ambiguous, F10 shape).
    #[test]
    fn ambiguous_date_rejected() {
        let out = extract("Decision: project-phoenix.launch_date = 03/04/26", &reg());
        assert_eq!(
            out.rejected,
            vec![RejectedDecisionLine { line: 1, reason: DecisionRejectReason::ParseAmbiguous }]
        );
    }

    /// Multiple `=` on one line → Unknown.
    #[test]
    fn multiple_equals_rejected() {
        let out = extract(
            "Decision: project-phoenix.launch_date = 2026-09-15 = 2026-10-01",
            &reg(),
        );
        assert_eq!(
            out.rejected,
            vec![RejectedDecisionLine { line: 1, reason: DecisionRejectReason::MultipleEquals }]
        );
    }

    /// Prose lines are ignored entirely; line numbers stay 1-based
    /// transcript positions.
    #[test]
    fn prose_lines_are_ignored() {
        let transcript = "Attendees: Sarah, Noor, and the platform team.\n\
                          We talked about the launch at length.\n\
                          Decision: project-phoenix.launch_date = 2026-09-15\n\
                          Sarah stated a preference for October without objecting.\n\
                          Decision: they.launch_date = 2026-10-01";
        let out = extract(transcript, &reg());
        assert_eq!(out.decisions.len(), 1);
        assert_eq!(out.decisions[0].line, 3);
        assert_eq!(
            out.rejected,
            vec![RejectedDecisionLine { line: 5, reason: DecisionRejectReason::PronounEntity }]
        );
    }
}
