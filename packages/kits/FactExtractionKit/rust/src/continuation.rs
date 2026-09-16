use crate::FactExtractionError;
use crate::{FactSourceChunk, FactSourceSpan};
use serde::{Deserialize, Serialize};

impl FactExtractionError {
    pub fn code(&self) -> &'static str {
        match self {
            Self::Unavailable(_) => "unavailable",
            Self::InvalidRequest(_) => "invalidRequest",
            Self::InferenceFailed(_) => "inferenceFailed",
            Self::MalformedResponse(_) => "malformedResponse",
            Self::NeedsSubdivision(_) => "needsSubdivision",
            Self::TimedOut(_) => "timedOut",
        }
    }
    pub fn from_wire(code: Option<&str>, message: String) -> Self {
        match code {
            Some("unavailable") => Self::Unavailable(message),
            Some("invalidRequest") => Self::InvalidRequest(message),
            Some("malformedResponse") => Self::MalformedResponse(message),
            Some("needsSubdivision") => Self::NeedsSubdivision(message),
            Some("timedOut") => Self::TimedOut(message),
            _ => Self::InferenceFailed(message),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FactExtractionOutcome {
    Pending,
    Partial,
    Completed,
    CompletedEmpty,
    NotApplicable,
    NeedsSubdivision,
    Rejected,
    RetryScheduled,
    BlockedProvider,
}

impl FactExtractionOutcome {
    pub fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Completed | Self::CompletedEmpty | Self::NotApplicable | Self::Rejected
        )
    }
}

/// Only allocate the next bounded source-exact slice, with explicit scalar/byte cursors.
pub fn next_fact_source_chunk(
    source: &str,
    start: usize,
    start_utf8_byte: usize,
    maximum_characters: usize,
) -> Option<FactSourceChunk> {
    let tail = source.get(start_utf8_byte..)?;
    if tail.is_empty() || maximum_characters == 0 {
        return None;
    }
    let mut end = 0;
    let mut count = 0;
    let mut boundary = None;
    for (offset, character) in tail.char_indices().take(maximum_characters) {
        end = offset + character.len_utf8();
        count += 1;
        if count >= maximum_characters / 2 && character == '\n' {
            boundary = Some((end, count));
        }
    }
    if end < tail.len() {
        if let Some(value) = boundary {
            (end, count) = value;
        }
    }
    Some(FactSourceChunk {
        text: tail[..end].to_owned(),
        span: FactSourceSpan {
            start,
            end: start + count,
            start_utf8_byte,
            end_utf8_byte: start_utf8_byte + end,
        },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn continuation_preserves_unicode_offsets() {
        let source = "é😀\nJack's birthday";
        let first = next_fact_source_chunk(source, 0, 0, 6).unwrap();
        assert_eq!(first.text, "é😀\n");
        assert_eq!((first.span.end, first.span.end_utf8_byte), (3, 7));
        let next = next_fact_source_chunk(source, 3, 7, 50).unwrap();
        assert_eq!(next.text, "Jack's birthday");
        assert_eq!(next.span.end_utf8_byte, source.len());
        assert!(next_fact_source_chunk(source, 1, 1, 6).is_none());
    }
}

impl crate::FactGroundingValidator {
    /// The caller supplies an exact chunk of its original-source snapshot.
    /// Bound scalar allocation/search to that chunk and restore global offsets.
    pub fn validate_chunk(
        response: &crate::FactExtractionResponse,
        request: &crate::FactExtractionRequest,
        chunk: &FactSourceChunk,
        expected_spec: &crate::FactExtractorModelSpec,
    ) -> crate::FactGroundingReport {
        let scalar_count = chunk.text.chars().count();
        if request.source_text != chunk.text
            || !request.eligible_source_spans.contains(&chunk.span)
            || chunk.span.end.checked_sub(chunk.span.start) != Some(scalar_count)
            || chunk
                .span
                .end_utf8_byte
                .checked_sub(chunk.span.start_utf8_byte)
                != Some(chunk.text.len())
        {
            return crate::FactGroundingReport {
                accepted: vec![],
                rejected: vec![crate::FactGroundingRejection::EvidenceOutsideSelectedSpans],
            };
        }
        let local = crate::FactExtractionRequest {
            source_id: request.source_id.clone(),
            source_digest: request.source_digest.clone(),
            source_text: chunk.text.clone(),
            eligible_source_spans: vec![FactSourceSpan {
                start: 0,
                end: scalar_count,
                start_utf8_byte: 0,
                end_utf8_byte: chunk.text.len(),
            }],
            maximum_facts: request.maximum_facts,
        };
        let mut result = Self::validate(response, &local, &chunk.text, expected_spec);
        for fact in &mut result.accepted {
            fact.evidence_span.start += chunk.span.start;
            fact.evidence_span.end += chunk.span.start;
            fact.evidence_span.start_utf8_byte += chunk.span.start_utf8_byte;
            fact.evidence_span.end_utf8_byte += chunk.span.start_utf8_byte;
        }
        result
    }
}
