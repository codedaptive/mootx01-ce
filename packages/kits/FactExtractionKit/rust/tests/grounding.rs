use fact_extraction_kit::*;
use serde::Deserialize;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OffsetVector {
    source: String,
    evidence_quote: String,
    subject: String,
    predicate: String,
    object: String,
    expected_start: usize,
    expected_end: usize,
    expected_start_utf8_byte: usize,
    expected_end_utf8_byte: usize,
}

fn spec() -> FactExtractorModelSpec {
    FactExtractorModelSpec {
        provider_id: "test".into(),
        model_id: "fixture".into(),
        model_version: "1".into(),
        schema_version: "fact-v1".into(),
        extractor_kind: FactExtractorKind::SpecializedModel,
        maximum_input_characters: 4096,
        maximum_facts_per_source: 8,
    }
}

#[test]
fn accepts_one_uniquely_grounded_fact() {
    let source = "Meeting notes. Jack's birthday is June 20th. Bring cake.";
    let request = FactExtractionRequest {
        source_id: "drawer-1".into(),
        source_digest: "digest".into(),
        source_text: source.into(),
        eligible_source_spans: vec![FactSourceSpan {
            start: 0,
            end: source.chars().count(),
            start_utf8_byte: 0,
            end_utf8_byte: source.len(),
        }],
        maximum_facts: 4,
    };
    let response = FactExtractionResponse {
        source_digest: "digest".into(),
        provider_id: "test".into(),
        model_id: "fixture".into(),
        model_version: "1".into(),
        schema_version: "fact-v1".into(),
        candidates: vec![FactCandidate {
            subject: "Jack".into(),
            predicate: "birthday".into(),
            object: "June 20th".into(),
            evidence_quote: "Jack's birthday is June 20th.".into(),
            confidence: 0.98,
            assertion_kind: FactAssertionKind::Asserted,
            search_aliases: vec!["Jack birthday".into(), "date of birth".into()],
        }],
    };
    let report = FactGroundingValidator::validate(&response, &request, source, &spec());
    assert!(report.rejected.is_empty());
    assert_eq!(report.accepted.len(), 1);
    assert_eq!(report.accepted[0].evidence_span.start, 15);
    assert_eq!(
        report.accepted[0].search_projection,
        "Jack birthday June 20th Jack birthday date of birth"
    );
}

#[test]
fn rejects_ambiguous_outside_and_fabricated_evidence() {
    let source = "Alice likes tea. Alice likes tea. Bob likes coffee.";
    let request = FactExtractionRequest {
        source_id: "drawer-2".into(),
        source_digest: "digest".into(),
        source_text: source.into(),
        eligible_source_spans: vec![FactSourceSpan {
            start: 0,
            end: 33,
            start_utf8_byte: 0,
            end_utf8_byte: 33,
        }],
        maximum_facts: 4,
    };
    let response = FactExtractionResponse {
        source_digest: "digest".into(),
        provider_id: "test".into(),
        model_id: "fixture".into(),
        model_version: "1".into(),
        schema_version: "fact-v1".into(),
        candidates: vec![
            candidate("Alice", "tea", "Alice likes tea."),
            candidate("Bob", "coffee", "Bob likes coffee."),
            candidate("Carol", "water", "Carol likes water."),
        ],
    };
    let report = FactGroundingValidator::validate(&response, &request, source, &spec());
    assert!(report.accepted.is_empty());
    assert_eq!(
        report.rejected,
        vec![
            FactGroundingRejection::AmbiguousEvidence,
            FactGroundingRejection::EvidenceOutsideSelectedSpans,
            FactGroundingRejection::EvidenceNotFound,
        ]
    );
}

#[test]
fn rejects_real_quote_paired_with_hallucinated_subject_or_object() {
    let source = "Jack's birthday is June 20th.";
    let request = FactExtractionRequest {
        source_id: "drawer-values".into(),
        source_digest: "digest".into(),
        source_text: source.into(),
        eligible_source_spans: vec![FactSourceSpan {
            start: 0,
            end: source.chars().count(),
            start_utf8_byte: 0,
            end_utf8_byte: source.len(),
        }],
        maximum_facts: 2,
    };
    let response = FactExtractionResponse {
        source_digest: "digest".into(),
        provider_id: "test".into(),
        model_id: "fixture".into(),
        model_version: "1".into(),
        schema_version: "fact-v1".into(),
        candidates: vec![
            candidate("Jill", "June 20th", source),
            candidate("Jack", "July 4th", source),
        ],
    };
    let report = FactGroundingValidator::validate(&response, &request, source, &spec());
    assert!(report.accepted.is_empty());
    assert_eq!(
        report.rejected,
        vec![
            FactGroundingRejection::UnsupportedValues,
            FactGroundingRejection::UnsupportedValues,
        ]
    );
}

#[test]
fn source_offsets_distinguish_unicode_scalars_from_utf8_bytes() {
    let source = "📝 Zoë's birthday is June 20th.";
    let request = FactExtractionRequest {
        source_id: "drawer-unicode".into(),
        source_digest: "digest".into(),
        source_text: source.into(),
        eligible_source_spans: vec![FactSourceSpan {
            start: 0,
            end: source.chars().count(),
            start_utf8_byte: 0,
            end_utf8_byte: source.len(),
        }],
        maximum_facts: 1,
    };
    let response = FactExtractionResponse {
        source_digest: "digest".into(),
        provider_id: "test".into(),
        model_id: "fixture".into(),
        model_version: "1".into(),
        schema_version: "fact-v1".into(),
        candidates: vec![FactCandidate {
            subject: "Zoë".into(),
            predicate: "birthday".into(),
            object: "June 20th".into(),
            evidence_quote: "Zoë's birthday is June 20th.".into(),
            confidence: 1.0,
            assertion_kind: FactAssertionKind::Asserted,
            search_aliases: vec![],
        }],
    };
    let report = FactGroundingValidator::validate(&response, &request, source, &spec());
    assert!(report.rejected.is_empty());
    assert_eq!(report.accepted[0].evidence_span.start, 2);
    assert_eq!(report.accepted[0].evidence_span.start_utf8_byte, 5);
    assert_eq!(report.accepted[0].evidence_span.end_utf8_byte, source.len());
}

#[test]
fn non_bmp_grounding_offsets_match_the_shared_scalar_vector() {
    let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../Tests/Conformance/fact_grounding_offsets.json");
    let vector: OffsetVector =
        serde_json::from_str(&std::fs::read_to_string(fixture).unwrap()).unwrap();
    let source = vector.source.as_str();
    let request = FactExtractionRequest {
        source_id: "drawer-shared-vector".into(),
        source_digest: "digest".into(),
        source_text: source.into(),
        eligible_source_spans: vec![FactSourceSpan {
            start: 0,
            end: source.chars().count(),
            start_utf8_byte: 0,
            end_utf8_byte: source.len(),
        }],
        maximum_facts: 1,
    };
    let response = FactExtractionResponse {
        source_digest: "digest".into(),
        provider_id: "test".into(),
        model_id: "fixture".into(),
        model_version: "1".into(),
        schema_version: "fact-v1".into(),
        candidates: vec![FactCandidate {
            subject: vector.subject,
            predicate: vector.predicate,
            object: vector.object,
            evidence_quote: vector.evidence_quote,
            confidence: 1.0,
            assertion_kind: FactAssertionKind::Asserted,
            search_aliases: vec![],
        }],
    };

    let report = FactGroundingValidator::validate(&response, &request, source, &spec());
    assert!(report.rejected.is_empty());
    let span = &report.accepted[0].evidence_span;
    assert_eq!(span.start, vector.expected_start);
    assert_eq!(span.end, vector.expected_end);
    assert_eq!(span.start_utf8_byte, vector.expected_start_utf8_byte);
    assert_eq!(span.end_utf8_byte, vector.expected_end_utf8_byte);
}

fn candidate(subject: &str, object: &str, evidence: &str) -> FactCandidate {
    FactCandidate {
        subject: subject.into(),
        predicate: "likes".into(),
        object: object.into(),
        evidence_quote: evidence.into(),
        confidence: 0.9,
        assertion_kind: FactAssertionKind::Asserted,
        search_aliases: vec![],
    }
}
