//! Named, recorded policy controlling what text each index lane indexes.
//!
//! Swift twin: `CorpusKit/Sources/CorpusKit/IndexCompositionPolicy.swift`
//!
//! Each policy carries:
//!   - `lexical_source` — what text feeds the BM25 inverted index
//!   - `dense_source`   — what text feeds the float embedding / dense vector lane
//!
//! The policy id is a stable string: `"lex=<value>;dense=<value>"`.
//!
//! Gauntlet cells (CDL-03):
//!   A — lex=original; dense=distilled           (`.current`, production default)
//!   B — lex=originalPlusAdornments; dense=distilled
//!   C — lex=original; dense=distilledPlusAdornments
//!   D — lex=originalPlusAdornments; dense=distilledPlusAdornments
//!   E — lex=original; dense=original             (lexical-only ablation baseline)
//!
//! The id is stored in `corpus_index_state.composition_policy` on every row
//! the engine indexes (the Swift engine compares it to the configured policy
//! at open; `mootx01 db composition --set` rebuilds every row under a new
//! policy in both ports). The policy an estate runs under is a stored estate
//! setting (LocusKit manifest key `index_composition_policy`), read by
//! GeniusLocusKit at every open.

/// What text feeds the BM25 inverted index for one content row.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LexicalIndexSource {
    /// Verbatim drawer content — production default.
    Original,
    /// Verbatim content with active adornments appended on separate lines in
    /// ascending minter-ID order. No adornments → same as `Original`.
    OriginalPlusAdornments,
    /// Distillate text; falls back to verbatim when nil.
    Distilled,
    /// Distillate (or verbatim fallback) plus active adornments.
    DistilledPlusAdornments,
}

impl LexicalIndexSource {
    /// Raw string value matching the Swift enum `rawValue` and id format.
    pub fn raw_value(&self) -> &'static str {
        match self {
            LexicalIndexSource::Original => "original",
            LexicalIndexSource::OriginalPlusAdornments => "originalPlusAdornments",
            LexicalIndexSource::Distilled => "distilled",
            LexicalIndexSource::DistilledPlusAdornments => "distilledPlusAdornments",
        }
    }

    /// Parse from a raw value string (matches Swift `init(rawValue:)`).
    pub fn from_raw_value(s: &str) -> Option<LexicalIndexSource> {
        match s {
            "original" => Some(LexicalIndexSource::Original),
            "originalPlusAdornments" => Some(LexicalIndexSource::OriginalPlusAdornments),
            "distilled" => Some(LexicalIndexSource::Distilled),
            "distilledPlusAdornments" => Some(LexicalIndexSource::DistilledPlusAdornments),
            _ => None,
        }
    }
}

/// What text feeds the float embedding / dense vector lane.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DenseIndexSource {
    /// Distillate text — production default; falls back to verbatim when nil.
    Distilled,
    /// Distillate with active adornments appended.
    DistilledPlusAdornments,
    /// Verbatim content. Used for ablation (cell E).
    Original,
}

impl DenseIndexSource {
    /// Raw string value matching the Swift enum `rawValue` and id format.
    pub fn raw_value(&self) -> &'static str {
        match self {
            DenseIndexSource::Distilled => "distilled",
            DenseIndexSource::DistilledPlusAdornments => "distilledPlusAdornments",
            DenseIndexSource::Original => "original",
        }
    }

    /// Parse from a raw value string.
    pub fn from_raw_value(s: &str) -> Option<DenseIndexSource> {
        match s {
            "distilled" => Some(DenseIndexSource::Distilled),
            "distilledPlusAdornments" => Some(DenseIndexSource::DistilledPlusAdornments),
            "original" => Some(DenseIndexSource::Original),
            _ => None,
        }
    }
}

/// Named policy controlling which texts each index lane consumes.
///
/// The `id()` string is the persistence anchor, stored verbatim in
/// `corpus_index_state.composition_policy` and in the estate's stored
/// setting. A policy change on an existing estate goes through
/// `mootx01 db composition --set`, which rewrites the setting and rebuilds
/// every index row, so rows indexed under different policies never mix.
///
/// `Copy`: two unit enums, so the policy travels inside the `Copy`
/// `CorpusContentConfiguration` without allocation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct IndexCompositionPolicy {
    /// What text the BM25 inverted index lane consumes.
    pub lexical_source: LexicalIndexSource,
    /// What text the dense embedding lane consumes.
    pub dense_source: DenseIndexSource,
}

impl IndexCompositionPolicy {
    /// Construct a policy from its two sources.
    pub fn new(lexical_source: LexicalIndexSource, dense_source: DenseIndexSource) -> Self {
        IndexCompositionPolicy { lexical_source, dense_source }
    }

    /// Stable human-readable id used as the persistence anchor.
    ///
    /// Format: `"lex=<lexical_source.raw_value()>;dense=<dense_source.raw_value()>"`.
    /// Stored in `corpus_index_state.composition_policy`. Changing raw values
    /// is a BREAKING change requiring a migration.
    pub fn id(&self) -> String {
        format!(
            "lex={};dense={}",
            self.lexical_source.raw_value(),
            self.dense_source.raw_value()
        )
    }

    // MARK: - Named policies

    /// Production default — original text for BM25, distillate for dense
    /// (cell A). An estate whose setting was seeded without
    /// `MOOT_INDEX_COMPOSITION` in the creating process runs this policy.
    pub fn current() -> IndexCompositionPolicy {
        IndexCompositionPolicy::new(LexicalIndexSource::Original, DenseIndexSource::Distilled)
    }

    /// Gauntlet cell B — original+adornments for BM25, distillate for dense.
    pub fn lexical_adornments() -> IndexCompositionPolicy {
        IndexCompositionPolicy::new(
            LexicalIndexSource::OriginalPlusAdornments,
            DenseIndexSource::Distilled,
        )
    }

    /// Gauntlet cell C — original for BM25, distillate+adornments for dense.
    pub fn dense_adornments() -> IndexCompositionPolicy {
        IndexCompositionPolicy::new(
            LexicalIndexSource::Original,
            DenseIndexSource::DistilledPlusAdornments,
        )
    }

    /// Gauntlet cell D — adornments in both lanes.
    pub fn both_adornments() -> IndexCompositionPolicy {
        IndexCompositionPolicy::new(
            LexicalIndexSource::OriginalPlusAdornments,
            DenseIndexSource::DistilledPlusAdornments,
        )
    }

    /// Gauntlet cell E — lexical-only ablation (dense = verbatim too).
    pub fn lexical_baseline() -> IndexCompositionPolicy {
        IndexCompositionPolicy::new(LexicalIndexSource::Original, DenseIndexSource::Original)
    }

    // MARK: - Policy id parser

    /// Parse an `IndexCompositionPolicy` from its id string.
    ///
    /// Accepted format: `"lex=<lex>;dense=<dense>"` where both parts use the
    /// raw values of `LexicalIndexSource` and `DenseIndexSource`. Returns
    /// `None` for unrecognised or malformed strings. The stored estate
    /// setting, the `mootx01 db composition --set` argument, and the
    /// creation-time `MOOT_INDEX_COMPOSITION` seed all use this form.
    pub fn from_environment_value(value: &str) -> Option<IndexCompositionPolicy> {
        let mut parts = value.splitn(2, ';');
        let lex_part = parts.next()?;
        let dense_part = parts.next()?;
        let lex_raw = lex_part.strip_prefix("lex=")?;
        let dense_raw = dense_part.strip_prefix("dense=")?;
        let lex = LexicalIndexSource::from_raw_value(lex_raw)?;
        let dense = DenseIndexSource::from_raw_value(dense_raw)?;
        Some(IndexCompositionPolicy::new(lex, dense))
    }

    // MARK: - Lane-need predicates

    /// Whether the lexical lane requires adornment texts for this policy.
    pub fn lexical_needs_adornments(&self) -> bool {
        matches!(
            self.lexical_source,
            LexicalIndexSource::OriginalPlusAdornments | LexicalIndexSource::DistilledPlusAdornments
        )
    }

    /// Whether the dense lane requires adornment texts for this policy.
    pub fn dense_needs_adornments(&self) -> bool {
        matches!(self.dense_source, DenseIndexSource::DistilledPlusAdornments)
    }

    /// Whether any lane requires adornment texts.
    pub fn needs_adornments(&self) -> bool {
        self.lexical_needs_adornments() || self.dense_needs_adornments()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // -- id format --

    #[test]
    fn id_format_current() {
        assert_eq!(
            IndexCompositionPolicy::current().id(),
            "lex=original;dense=distilled"
        );
    }

    #[test]
    fn id_format_lexical_adornments() {
        assert_eq!(
            IndexCompositionPolicy::lexical_adornments().id(),
            "lex=originalPlusAdornments;dense=distilled"
        );
    }

    #[test]
    fn id_format_dense_adornments() {
        assert_eq!(
            IndexCompositionPolicy::dense_adornments().id(),
            "lex=original;dense=distilledPlusAdornments"
        );
    }

    #[test]
    fn id_format_both_adornments() {
        assert_eq!(
            IndexCompositionPolicy::both_adornments().id(),
            "lex=originalPlusAdornments;dense=distilledPlusAdornments"
        );
    }

    #[test]
    fn id_format_lexical_baseline() {
        assert_eq!(
            IndexCompositionPolicy::lexical_baseline().id(),
            "lex=original;dense=original"
        );
    }

    // -- env parse --

    #[test]
    fn parse_valid_cell_a() {
        let p = IndexCompositionPolicy::from_environment_value("lex=original;dense=distilled");
        assert_eq!(p, Some(IndexCompositionPolicy::current()));
    }

    #[test]
    fn parse_valid_cell_b() {
        let p = IndexCompositionPolicy::from_environment_value(
            "lex=originalPlusAdornments;dense=distilled",
        );
        assert_eq!(p, Some(IndexCompositionPolicy::lexical_adornments()));
    }

    #[test]
    fn parse_empty_returns_none() {
        assert_eq!(IndexCompositionPolicy::from_environment_value(""), None);
    }

    #[test]
    fn parse_garbage_returns_none() {
        assert_eq!(
            IndexCompositionPolicy::from_environment_value("notaformat"),
            None
        );
    }

    #[test]
    fn parse_unknown_lex_returns_none() {
        assert_eq!(
            IndexCompositionPolicy::from_environment_value("lex=unknown;dense=distilled"),
            None
        );
    }

    #[test]
    fn roundtrip_all_named_policies() {
        for policy in &[
            IndexCompositionPolicy::current(),
            IndexCompositionPolicy::lexical_adornments(),
            IndexCompositionPolicy::dense_adornments(),
            IndexCompositionPolicy::both_adornments(),
            IndexCompositionPolicy::lexical_baseline(),
        ] {
            let parsed = IndexCompositionPolicy::from_environment_value(&policy.id());
            assert_eq!(parsed.as_ref(), Some(policy), "roundtrip failed for {}", policy.id());
        }
    }

    // -- adornment predicates --

    #[test]
    fn current_needs_no_adornments() {
        let p = IndexCompositionPolicy::current();
        assert!(!p.lexical_needs_adornments());
        assert!(!p.dense_needs_adornments());
        assert!(!p.needs_adornments());
    }

    #[test]
    fn lexical_adornments_needs_lex_only() {
        let p = IndexCompositionPolicy::lexical_adornments();
        assert!(p.lexical_needs_adornments());
        assert!(!p.dense_needs_adornments());
        assert!(p.needs_adornments());
    }

    #[test]
    fn dense_adornments_needs_dense_only() {
        let p = IndexCompositionPolicy::dense_adornments();
        assert!(!p.lexical_needs_adornments());
        assert!(p.dense_needs_adornments());
        assert!(p.needs_adornments());
    }

    #[test]
    fn both_adornments_needs_both() {
        let p = IndexCompositionPolicy::both_adornments();
        assert!(p.lexical_needs_adornments());
        assert!(p.dense_needs_adornments());
        assert!(p.needs_adornments());
    }
}
