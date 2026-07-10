// fdc_signatures.rs — FDC compact code signatures
//
// Port of the FDCRuntime.swift `SignaturesFile` inner struct and the term-set
// build step. Compact v2 retains each code's label, alias, title, and article
// terms separately from inherited ancestor terms. Terms are concept IDs or
// stemmed surface forms; classifier v3 applies source-specific runtime weights.

use serde::Deserialize;
use std::collections::{HashMap, HashSet};

/// One entry in compact FDCSignatures.json: a code and source-owned term lists.
#[derive(Debug, Deserialize)]
struct SignatureEntry {
    code: String,
    #[serde(default)]
    terms: Vec<String>,
    #[serde(default)]
    label_terms: Vec<String>,
    #[serde(default)]
    alias_terms: Vec<String>,
    #[serde(default)]
    title_terms: Vec<String>,
    #[serde(default)]
    article_terms: Vec<String>,
    #[serde(default)]
    ancestor_terms: Vec<String>,
}

#[derive(Debug, Default)]
pub struct FdcSignatureSources {
    pub label: HashSet<String>,
    pub alias: HashSet<String>,
    pub title: HashSet<String>,
    pub article: HashSet<String>,
}

/// The compact signatures file. Version is tracked for provenance.
#[derive(Debug, Deserialize)]
struct SignaturesFile {
    version: String,
    // source_weights is provenance; classifier weights are pinned in matcher code.
    codes: Vec<SignatureEntry>,
}

/// Parsed signatures include a broad recall set and source-owned evidence.
/// The version is surfaced so `FdcRuntime.data_version()` can report it.
pub struct FdcSignatures {
    pub version: String,
    pub sig_terms: HashMap<String, HashSet<String>>,
    pub source_terms: HashMap<String, FdcSignatureSources>,
}

impl FdcSignatures {
    /// Deserialize from JSON bytes (the bundled FDCSignatures.json artifact).
    pub fn from_json(data: &[u8]) -> Option<Self> {
        let file: SignaturesFile = serde_json::from_slice(data).ok()?;
        let mut sig_terms: HashMap<String, HashSet<String>> = HashMap::new();
        let mut source_terms: HashMap<String, FdcSignatureSources> = HashMap::new();
        for entry in file.codes {
            let code = entry.code;
            let mut recall: HashSet<String> = entry.terms.into_iter().collect();
            recall.extend(entry.label_terms.iter().cloned());
            recall.extend(entry.alias_terms.iter().cloned());
            recall.extend(entry.title_terms.iter().cloned());
            recall.extend(entry.article_terms.iter().cloned());
            recall.extend(entry.ancestor_terms);
            sig_terms.insert(code.clone(), recall);
            source_terms.insert(
                code,
                FdcSignatureSources {
                    label: entry.label_terms.into_iter().collect(),
                    alias: entry.alias_terms.into_iter().collect(),
                    title: entry.title_terms.into_iter().collect(),
                    article: entry.article_terms.into_iter().collect(),
                },
            );
        }
        Some(FdcSignatures {
            version: file.version,
            sig_terms,
            source_terms,
        })
    }
}
