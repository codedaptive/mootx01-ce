// fdc_runtime.rs — Runtime FDC entry point
//
// Port of FDCRuntime.swift. Loads the bundled pinned artifacts (Lexicon.json,
// FDCFrame.json, FDCSignatures.json, WordClassTable.json) once per process
// via `include_bytes!` and exposes `Fdc::encode(text) -> Option<String>`.
// Compact v2 signatures retain code-owned label, alias, title, and article
// terms separately from inherited ancestor terms. Classifier v4 fuses that
// hierarchy-first policy with portable integer semantic evidence.
//
// The Swift runtime loads via `Bundle.module.url(forResource:...)`. The Rust
// equivalent is `include_bytes!` at compile time — same pinning guarantee,
// zero runtime I/O.
//
// Artifact paths are relative to this source file (the macro resolves
// relative to the source file location, not the crate root). The JSON files
// live at:
//   ../../Sources/LatticeLib/Resources/{Lexicon,FDCFrame,FDCSignatures,WordClassTable}.json
// which is correct for the position of this file at
//   packages/libs/LatticeLib/rust/src/fdc_runtime.rs

use std::sync::Arc;
use std::sync::OnceLock;
use crate::fdc_frame::FdcFrame;
use crate::fdc_matcher::{FdcMatcher, ScoreMode};
use crate::fdc_semantic_ranker::{FdcSemanticCandidate, FdcSemanticDecision, FdcSemanticRanker};
use crate::fdc_signatures::FdcSignatures;
use crate::lexicon::CanonicalizationLexicon;
use crate::novel_pool_submitter::default_table_artifact;
use crate::novel_token_cache::init_shared_cache;
use crate::word_class_table;

// Pinned descent cutoff (cookbook §6.1). 1 = any overlap continues descent.
// Tuned empirically: a sweep over 1...200 produced identical results on the
// v1.0 frame (shallow frame — descent rarely fires), so the cutoff is inert
// here. `1` is the pinned ship value; classification accuracy is governed by
// within-region scoring (§5), not this cutoff. Mirrors Swift FDCRuntime.swift.
const STOP_THRESHOLD: usize = 1;
const CLASSIFIER_VERSION: &str = "4.2.0";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FdcContentKind {
    Text,
    Code,
}

/// The bundled artifacts and the assembled matcher — loaded once per process.
struct Bundle {
    matcher: FdcMatcher,
    semantic_ranker: Arc<FdcSemanticRanker>,
    version: String,
    lexicon_version: String,
    // Retained for label lookups. FdcFrame derives Clone so we clone before moving
    // into FdcMatcher, which takes ownership. This matches Swift's bundle tuple
    // which stores (matcher, frame, version) together.
    frame: FdcFrame,
}

static BUNDLE: OnceLock<Option<Bundle>> = OnceLock::new();

fn get_bundle() -> Option<&'static Bundle> {
    BUNDLE.get_or_init(|| {
        // Embed the JSON artifacts at compile time.
        // Paths are relative to this source file.
        const LEXICON_JSON: &[u8] = include_bytes!(
            "../../Sources/LatticeLib/Resources/Lexicon.json"
        );
        const FRAME_JSON: &[u8] = include_bytes!(
            "../../Sources/LatticeLib/Resources/FDCFrame.json"
        );
        const SIGS_JSON: &[u8] = include_bytes!(
            "../../Sources/LatticeLib/Resources/FDCSignatures.json"
        );
        const SEMANTIC_METADATA_JSON: &[u8] = include_bytes!(
            "../../Sources/LatticeLib/Resources/FDCSemanticRanker.json"
        );
        const SEMANTIC_MODEL: &[u8] = include_bytes!(
            "../../Sources/LatticeLib/Resources/FDCSemanticRanker.bin"
        );
        const TABLE_JSON: &[u8] = include_bytes!(
            "../../Sources/LatticeLib/Resources/WordClassTable.json"
        );

        let lexicon = CanonicalizationLexicon::from_json(LEXICON_JSON)?;
        let frame = FdcFrame::from_json(FRAME_JSON)?;
        let signatures = FdcSignatures::from_json(SIGS_JSON)?;
        let semantic_ranker = Arc::new(FdcSemanticRanker::from_artifacts(
            SEMANTIC_METADATA_JSON,
            SEMANTIC_MODEL,
        )?);

        // Parse the bundled table first to extract the version string. The version
        // is pinned and does not change with the writable artifact — it is the
        // table_version of the bundled table that gates pool submissions (cookbook
        // §2.3). The merged artifact must carry the same table_version.
        let raw_bundled: crate::word_class_table::WordClassTable =
            serde_json::from_slice(TABLE_JSON).ok()?;
        let table_version_str = raw_bundled.table_version.clone();

        // Seed the LIVE process-global word-class table with writable-artifact
        // precedence (cookbook §1.3/§2.2):
        //   1. Writable merged artifact at `default_table_artifact()`, if present.
        //   2. Compile-time bundled bytes, as fallback (the OnceLock seed).
        // This implements cross-reload learning at startup (a previous
        // `pool_reduce` run is picked up here) AND establishes the holder the
        // live in-session swap publishes into post-reduce. The encode path and
        // the public `word_class` free fn read this same holder, so a swap is
        // observed in-session — no process restart (mirrors the Swift live
        // `WordClassTableCache`). If the writable artifact resolves, it replaces
        // the bundled seed; if not, the bundled seed already loaded is left in
        // place.
        let artifact_path = default_table_artifact();
        word_class_table::seed_global_table(&artifact_path);

        // Initialize the process-wide novel-token cache, stamped with the bundled
        // table version. Mirrors Swift's `sharedNovelCache` static let which reads
        // `WordClassTableCache.table?.tableVersion ?? ""` at initialization.
        // OnceLock contract: if called more than once (e.g., in tests), the second
        // call is a no-op.
        init_shared_cache(&table_version_str);

        let version = signatures.version.clone();
        let lexicon_version = lexicon.version.clone();
        // The runtime ships ScoreMode::Idf (Mission #4 Phase B.2): IDF-weighting
        // the overlap — penalizing concept terms common across many signatures,
        // rewarding distinctive ones — improved within-region code selection
        // over raw overlap on the v1.0 frame. Mirrors Swift FDCRuntime.swift
        // which passes `.idf` to FDCMatcher at construction time. The matcher
        // default stays Raw; the runtime opts in here. The matcher reads the
        // live global word-class table at encode time (it no longer owns one).
        let matcher = FdcMatcher::new_with_mode_hierarchy_and_semantic(
            lexicon,
            frame.clone(),   // matcher takes ownership; clone is retained below for label lookups
            &signatures,
            STOP_THRESHOLD,
            ScoreMode::Idf,
            true,
            Some(Arc::clone(&semantic_ranker)),
        );

        Some(Bundle { matcher, semantic_ranker, version, lexicon_version, frame })
    }).as_ref()
}

/// The runtime FDC encoder. All entry points are free functions delegating to
/// the bundle singleton, matching the Swift `FDC` enum's static interface.
pub struct Fdc;

impl Fdc {
    pub const CLASSIFIER_VERSION: &'static str = CLASSIFIER_VERSION;

    /// Encode `text` to an FDC code. Nonempty text without defensible subject
    /// evidence returns `000`; None is reserved for empty input or unavailable
    /// bundled artifacts. Pure over the pinned artifacts.
    pub fn encode(text: &str) -> Option<String> {
        get_bundle().and_then(|b| b.matcher.encode(text))
    }

    /// Encode `text` and surface the dominant concept Q-ID.
    /// Returns (code, conceptQID). Returns (None, None) if artifacts unavailable.
    pub fn encode_anchor(text: &str) -> (Option<String>, Option<String>) {
        Self::classify_anchor(text, FdcContentKind::Text, true)
    }

    /// Non-recording variant of `encode_anchor` (secfix/fdc-pool).
    ///
    /// Identical result to `encode_anchor` — the (code, conceptQID) pair is
    /// byte-for-byte the same. Novel tokens encountered during FDC concept-bag
    /// construction are NOT accumulated into `SHARED_NOVEL_CACHE` when this
    /// variant is used.
    ///
    /// Use this when `text` is user-supplied memory content that must not leak
    /// plaintext tokens into the pool pipeline — specifically the capture seam
    /// in `intake.rs` (`capture_with_mode`), where FDC classification runs
    /// before the capture write, so even rejected or empty-room captures would
    /// otherwise spill tokens to plaintext pool files.
    ///
    /// Delegates to `FdcMatcher::encode_anchor_no_record` →
    /// `build_encoder_bag_no_record` → `WordClassTableCache::word_class_no_record`
    /// (which skips the `SHARED_NOVEL_CACHE.record` call for novel tokens).
    ///
    /// Mirrors Swift `FDC.encodeAnchor(_:recordNovel:)` in FDCRuntime.swift.
    pub fn encode_anchor_no_record(text: &str) -> (Option<String>, Option<String>) {
        Self::classify_anchor(text, FdcContentKind::Text, false)
    }

    /// Content-aware non-recording classification for capture and estate
    /// recalculation. Explicit code content anchors at FDC `005`; a recognized
    /// programming language supplies its pinned Wikidata Q-ID refinement.
    pub fn encode_anchor_for_content_no_record(
        text: &str,
        content_kind: FdcContentKind,
    ) -> (Option<String>, Option<String>) {
        Self::classify_anchor(text, content_kind, false)
    }

    /// True when the bundled artifacts loaded and the engine is ready.
    pub fn is_available() -> bool {
        get_bundle().is_some()
    }

    /// The bundled signatures version — the pinned-artifact version that
    /// produced an encode answer.
    pub fn data_version() -> &'static str {
        get_bundle()
            .map(|b| b.version.as_str())
            .unwrap_or("0.0.0-unavailable")
    }

    /// Deterministic semantic candidates from the bundled integer model.
    pub fn semantic_candidates(text: &str, limit: usize) -> Vec<FdcSemanticCandidate> {
        get_bundle()
            .map(|bundle| bundle.semantic_ranker.rank(text, limit))
            .unwrap_or_default()
    }

    /// Confidence-gated semantic hierarchy evidence used by classifier v4.
    pub fn semantic_decision(text: &str) -> Option<FdcSemanticDecision> {
        let bundle = get_bundle()?;
        bundle
            .semantic_ranker
            .hierarchy_decision(text, &bundle.frame)
    }

    pub fn semantic_model_version() -> &'static str {
        get_bundle()
            .map(|bundle| bundle.semantic_ranker.metadata.version.as_str())
            .unwrap_or("0.0.0-unavailable")
    }

    pub fn semantic_model_sha256() -> &'static str {
        get_bundle()
            .map(|bundle| bundle.semantic_ranker.metadata.model_sha256.as_str())
            .unwrap_or("unavailable")
    }

    fn classify_anchor(
        text: &str,
        content_kind: FdcContentKind,
        record_novel: bool,
    ) -> (Option<String>, Option<String>) {
        let Some(bundle) = get_bundle() else { return (None, None) };
        if text.trim().is_empty() { return (None, None) }
        if content_kind == FdcContentKind::Code {
            let qid = crate::fdc_code_language::detect_code_language(text)
                .map(|language| language.wikidata_qid.to_string());
            return (Some("005".to_string()), qid);
        }
        let (code, qid) = if record_novel {
            bundle.matcher.encode_anchor(text)
        } else {
            bundle.matcher.encode_anchor_no_record(text)
        };
        if code.as_deref() != Some("005") {
            return (code, qid);
        }
        let refined_qid = crate::fdc_code_language::detect_code_language(text)
            .map(|language| language.wikidata_qid.to_string())
            .or(qid);
        (code, refined_qid)
    }

    /// Composite estate recalculation floor covering algorithm and all pinned
    /// classifier artifacts. Mirrors Swift `FDC.recalculationVersion`.
    pub fn recalculation_version() -> String {
        match get_bundle() {
            Some(bundle) => format!(
                "classifier:{CLASSIFIER_VERSION}|frame:{}|lexicon:{}|signatures:{}|semantic:{}:{}",
                bundle.frame.frame_version,
                bundle.lexicon_version,
                bundle.version,
                bundle.semantic_ranker.metadata.version,
                bundle.semantic_ranker.metadata.model_sha256
            ),
            None => "fdc-unavailable".to_owned(),
        }
    }

    /// The LatticeLib library version string — mirrors Swift `LatticeLib.version`
    /// (`"1.0.0"` pinned at the same value as the Swift constant in LatticeLib.swift).
    ///
    /// Distinct from `data_version()` (the pinned FDC signatures artifact version):
    /// this is the kit's own semantic release version, surfaced in the
    /// `/api/lexicon` `latticeVersion` field of the read-API.
    pub fn version() -> &'static str {
        "1.0.0"
    }

    /// Ancestor chain (root first, excluding `code` itself) for an FDC code,
    /// walked over the bundled frame's decimal hierarchy. Returns an empty
    /// `Vec` when the artifacts are unavailable or when `code` is the root
    /// "000". Mirrors Swift `FDC.ancestors(of:)` in FDCRuntime.swift.
    ///
    /// Delegates to `FdcFrame::ancestors` (already public on `FdcFrame`) —
    /// the math lives in LatticeLib, not in consumers. This façade allows
    /// consumers such as `corpus-kit-providers` to use the FDC ancestor chain
    /// without reaching past the runtime bundle into `FdcFrame` directly.
    ///
    /// # Arguments
    /// * `code` — An FDC decimal code, e.g. `"547.7"`.
    ///
    /// # Returns
    /// The ancestor chain root-first, e.g. `["000", "500", "540", "547"]`.
    pub fn ancestors(code: &str) -> Vec<String> {
        match get_bundle() {
            Some(b) => b.frame.ancestors(code),
            None => Vec::new(),
        }
    }

    /// Return the human-readable heading for an FDC code, or None when
    /// the code is absent from the frame or the artifacts are unavailable.
    ///
    /// Every code resolves to its OWN frame label — never an ancestor's.
    /// Sibling codes must stay distinguishable when listed together: the
    /// lattice address table shows runs of active siblings (651, 652, 657 …),
    /// and coarsening to a shared parent heading renders them as identical
    /// rows that read as duplicated data. Multi-term compound leaf labels
    /// (e.g. "683" → "Firearms + Locksmithing") are shown as-is.
    ///
    /// Mirrors Swift `FDC.label(for:)` in FDCRuntime.swift.
    pub fn label(code: &str) -> Option<String> {
        let bundle = get_bundle()?;
        if code.is_empty() {
            return None;
        }
        bundle.frame.codes.iter()
            .find(|e| e.code == code)
            .map(|e| e.label.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Tests that call Fdc::label() on non-empty input require the bundled
    // artifacts (include_bytes! at compile time) and guard with Fdc::is_available().
    // `label_empty_returns_none` runs unconditionally — it does not need artifacts.
    // In practice the JSON files are always bundled so all tests run.

    #[test]
    fn label_empty_returns_none() {
        // Empty string must return None regardless of artifact availability.
        assert_eq!(Fdc::label(""), None);
    }

    #[test]
    fn label_code_not_in_frame_returns_none() {
        if !Fdc::is_available() {
            return;
        }
        // A clearly invalid code is absent from the frame.
        assert_eq!(Fdc::label("NOTACODE"), None);
    }

    #[test]
    fn label_integer_code_returns_own_label() {
        if !Fdc::is_available() {
            return;
        }
        // Integer codes resolve to their OWN frame label, never an ancestor's —
        // sibling codes listed together must stay distinguishable. "006" and its
        // parent "000" carry distinct labels in the frame, so the lookups differ.
        let leaf = Fdc::label("006");
        let root = Fdc::label("000");
        assert!(leaf.is_some(), "label(\"006\") should resolve to its own frame label");
        assert!(root.is_some(), "label(\"000\") should resolve to its own frame label");
        assert_ne!(leaf, root, "label(\"006\") must be \"006\"'s own label, not the parent's");
    }

    #[test]
    fn label_decimal_code_returns_own_label() {
        if !Fdc::is_available() {
            return;
        }
        // A decimal code (contains '.') returns its own label, distinct from
        // its integer parent's label.
        let decimal_label = Fdc::label("006.6");
        let parent_label = Fdc::label("006");
        if decimal_label.is_some() && parent_label.is_some() {
            assert_ne!(
                decimal_label, parent_label,
                "label(\"006.6\") must return its own label, not \"006\"'s"
            );
        }
    }

    #[test]
    fn bundled_labels_are_clean_and_corrected() {
        assert_eq!(Fdc::label("002").as_deref(), Some("History of the book"));
        assert_eq!(Fdc::label("004").as_deref(), Some("Computers + Computer science"));
        assert_eq!(Fdc::label("615.88").as_deref(), Some("Patent medicines"));
        assert_eq!(Fdc::label("615.89").as_deref(), Some("Traditional medicine"));
        assert_eq!(Fdc::label("971.4").as_deref(), Some("Quebec (Province)"));
    }
}
