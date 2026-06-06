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
use crate::novel_token_cache::init_shared_cache;
use crate::word_class_table::WordClassTableCache;

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
        // Parse the raw table struct first to extract the version string for the
        // novel-token cache, then build the membership-set cache from the same data.
        let raw_table: crate::word_class_table::WordClassTable =
            serde_json::from_slice(TABLE_JSON).ok()?;
        let table_version_str = raw_table.table_version.clone();
        let table = WordClassTableCache::from_json(TABLE_JSON)?;
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
        // default stays Raw; the runtime opts in here.
        let matcher = FdcMatcher::new_with_mode(
            lexicon,
            frame,
            table,
            &signatures,
            STOP_THRESHOLD,
            ScoreMode::Idf,
        );

        Some(Bundle { matcher, version })
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
}
