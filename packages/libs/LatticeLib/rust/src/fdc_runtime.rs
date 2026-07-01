// fdc_runtime.rs — Runtime FDC entry point
//
// Port of FDCRuntime.swift. Loads the bundled pinned artifacts (Lexicon.json,
// FDCFrame.json, FDCSignatures.json, WordClassTable.json) once per process
// via `include_bytes!` and exposes `Fdc::encode(text) -> Option<String>`.
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

use std::sync::OnceLock;
use crate::fdc_frame::FdcFrame;
use crate::fdc_matcher::{FdcMatcher, ScoreMode};
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

/// The bundled artifacts and the assembled matcher — loaded once per process.
struct Bundle {
    matcher: FdcMatcher,
    version: String,
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
        const TABLE_JSON: &[u8] = include_bytes!(
            "../../Sources/LatticeLib/Resources/WordClassTable.json"
        );

        let lexicon = CanonicalizationLexicon::from_json(LEXICON_JSON)?;
        let frame = FdcFrame::from_json(FRAME_JSON)?;
        let signatures = FdcSignatures::from_json(SIGS_JSON)?;

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
        // The runtime ships ScoreMode::Idf (Mission #4 Phase B.2): IDF-weighting
        // the overlap — penalizing concept terms common across many signatures,
        // rewarding distinctive ones — improved within-region code selection
        // over raw overlap on the v1.0 frame. Mirrors Swift FDCRuntime.swift
        // which passes `.idf` to FDCMatcher at construction time. The matcher
        // default stays Raw; the runtime opts in here. The matcher reads the
        // live global word-class table at encode time (it no longer owns one).
        let matcher = FdcMatcher::new_with_mode(
            lexicon,
            frame.clone(),   // matcher takes ownership; clone is retained below for label lookups
            &signatures,
            STOP_THRESHOLD,
            ScoreMode::Idf,
        );

        Some(Bundle { matcher, version, frame })
    }).as_ref()
}

/// The runtime FDC encoder. All entry points are free functions delegating to
/// the bundle singleton, matching the Swift `FDC` enum's static interface.
pub struct Fdc;

impl Fdc {
    /// Encode `text` to an FDC code, or None for UNRESOLVED (or if the bundled
    /// artifacts are unavailable). Pure over the pinned artifacts.
    pub fn encode(text: &str) -> Option<String> {
        get_bundle().and_then(|b| b.matcher.encode(text))
    }

    /// Encode `text` and surface the dominant concept Q-ID.
    /// Returns (code, conceptQID). Returns (None, None) if artifacts unavailable.
    pub fn encode_anchor(text: &str) -> (Option<String>, Option<String>) {
        match get_bundle() {
            Some(b) => b.matcher.encode_anchor(text),
            None => (None, None),
        }
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
        match get_bundle() {
            Some(b) => b.matcher.encode_anchor_no_record(text),
            None => (None, None),
        }
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
    /// 3-digit integer codes (no decimal point) walk up one parent level so
    /// the dashboard shows a single-topic heading rather than a raw compound
    /// cluster label (e.g. "683" → parent "680" → "Handicraft", not the
    /// raw "Firearms + Locksmithing" leaf label).
    /// Decimal codes return their own label unchanged.
    ///
    /// Mirrors Swift `FDC.label(for:)` in FDCRuntime.swift.
    pub fn label(code: &str) -> Option<String> {
        let bundle = get_bundle()?;
        if code.is_empty() {
            return None;
        }
        // Walk up one level for plain 3-digit codes; keep decimal codes as-is.
        let lookup = if !code.contains('.') {
            FdcFrame::decimal_parent(code).unwrap_or_else(|| code.to_owned())
        } else {
            code.to_owned()
        };
        bundle.frame.codes.iter()
            .find(|e| e.code == lookup)
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
    fn label_integer_code_walks_to_parent() {
        if !Fdc::is_available() {
            return;
        }
        // For a 3-digit integer code, label() walks up one level via decimal_parent().
        // "006" has parent "000"; label("006") and label("000") must both look up
        // code "000" in the frame, so they return the same value.
        let via_child = Fdc::label("006");
        let direct_root = Fdc::label("000");
        assert!(via_child.is_some(), "label(\"006\") should resolve via parent \"000\"");
        assert_eq!(via_child, direct_root, "label(\"006\") must equal label(\"000\") — both look up the parent");
    }

    #[test]
    fn label_decimal_code_returns_own_label() {
        if !Fdc::is_available() {
            return;
        }
        // A decimal code (contains '.') returns its own label, not the parent's.
        // "006.6" must NOT equal label("006") (which is the "000" root label).
        let decimal_label = Fdc::label("006.6");
        let parent_label = Fdc::label("006");
        if decimal_label.is_some() && parent_label.is_some() {
            assert_ne!(
                decimal_label, parent_label,
                "label(\"006.6\") must return its own label, not the parent-walked \"000\" label"
            );
        }
    }
}
