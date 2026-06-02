// word_class.rs — Word class label for FDC encoder Step 1
//
// Port of WordClass.swift. The enum is string-backed (noun/verb/other) to match
// the Swift serialization contract and the shared conformance vectors.

use serde::{Deserialize, Serialize};

/// The word class of a single token under FDC encoder Step 1.
/// `.other` is the discard bucket: any token the encoder will not carry forward.
/// String-backed so it serializes to the same JSON as the Swift port.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum WordClass {
    Noun,
    Verb,
    Other,
}
