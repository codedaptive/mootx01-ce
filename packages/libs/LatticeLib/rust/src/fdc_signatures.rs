// fdc_signatures.rs — FDC compact code signatures
//
// Port of the FDCRuntime.swift `SignaturesFile` inner struct and the term-set
// build step. The compact signature form is: code -> Set<term> where terms
// are concept IDs or stemmed surface forms. The matcher uses only term
// membership, never the source weights.

use std::collections::{HashMap, HashSet};
use serde::Deserialize;

/// One entry in the compact FDCSignatures.json: a code and its term list.
#[derive(Debug, Deserialize)]
struct SignatureEntry {
    code: String,
    terms: Vec<String>,
}

/// The compact signatures file. Version is tracked for provenance.
#[derive(Debug, Deserialize)]
struct SignaturesFile {
    version: String,
    // source_weights present in the JSON but not used by the runtime.
    codes: Vec<SignatureEntry>,
}

/// Parsed signatures: code -> term membership set. The version is
/// surfaced so `FdcRuntime.data_version()` can report it.
pub struct FdcSignatures {
    pub version: String,
    pub sig_terms: HashMap<String, HashSet<String>>,
}

impl FdcSignatures {
    /// Deserialize from JSON bytes (the bundled FDCSignatures.json artifact).
    pub fn from_json(data: &[u8]) -> Option<Self> {
        let file: SignaturesFile = serde_json::from_slice(data).ok()?;
        let mut sig_terms: HashMap<String, HashSet<String>> = HashMap::new();
        for entry in file.codes {
            sig_terms.insert(entry.code, entry.terms.into_iter().collect());
        }
        Some(FdcSignatures {
            version: file.version,
            sig_terms,
        })
    }
}
