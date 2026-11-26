// subject_cut_to_contract.rs — the subject backfill sweep's cut of an
// over-length producer answer to the subject length contract.
//
// A producer may answer with more than `SUBJECT_LENGTH_CONTRACT` grapheme
// clusters. Validating that answer as given would reject it as `TooLong`, so
// the sweep cuts it first, at a word boundary, and validates the cut.

use unicode_segmentation::UnicodeSegmentation;

/// `answer` cut to `SUBJECT_LENGTH_CONTRACT` grapheme clusters (the
/// contract's unit) at its last word boundary. An answer within the contract
/// is returned unchanged. Over it, the cut falls on the last whitespace
/// cluster among the first contract + 1 clusters (the cluster just past the
/// limit may itself be the boundary), and the trailing whitespace before it
/// is dropped. An answer with no word boundary in that window (one long
/// identifier) is cut at the limit itself, so a producer that gave text never
/// leaves the subject empty. Twin of Swift
/// `GeniusLocusKit.subjectCutToContract`; both test a cluster's first scalar
/// for White_Space, so the ports cut at the same place.
pub(crate) fn subject_cut_to_contract(answer: &str) -> String {
    let limit = locus_kit::drawer_store::SUBJECT_LENGTH_CONTRACT;
    if locus_kit::drawer_store::subject_length(answer) <= limit {
        return answer.to_string();
    }
    let window: Vec<&str> = answer.graphemes(true).take(limit + 1).collect();
    let is_space = |g: &str| g.chars().next().is_some_and(char::is_whitespace);
    // Index 0 is never a boundary: a cut there would leave nothing.
    if let Some(boundary) = (1..window.len()).rev().find(|&i| is_space(window[i])) {
        let mut kept = &window[..boundary];
        while let Some((last, rest)) = kept.split_last() {
            if !is_space(*last) {
                break;
            }
            kept = rest;
        }
        if !kept.is_empty() {
            return kept.concat();
        }
    }
    window[..limit].concat()
}
