// lib.rs — LatticeLib Rust port
//
// This crate is the Rust-scalar port of LatticeLib's runtime FDC encode path.
// Swift LEADS: this Rust code must agree byte-for-byte with the Swift engine
// for the same input and the same pinned artifacts (Lexicon.json, FDCFrame.json,
// FDCSignatures.json).
//
// CONFORMANCE SCOPE
// The FDC algorithm is a pure string/bag computation — Normalizer (Unicode
// case-fold), Tokenizer (UAX #29 word boundaries), Stemmer (Porter2/Snowball),
// Lexicon lookup (HashMap), bag scoring (inverted-index scan), and frame
// descent (decimal-string ancestry). There is no vector/matrix dimension and
// therefore no Metal / BLAS / NEON leg. The conformance contract is:
//   Swift-scalar == Rust-scalar
// The four-way conformance matrix (Swift-scalar, Swift-Metal, Rust-scalar,
// Rust-BLAS/NEON) does not apply here; saying so rather than faking a
// four-way matrix is the correct call per the substrate contract.
//
// DEFERRED (not in this port)
// - LexRank.swift (build-time only; not in the runtime encode path)
// - CodeSignature.swift (build-time only; seed/build artefact producer)
// - Apple NLTagger fallback: the Swift code's `NaturalLanguage` branch is
//   Apple-platform-only and is explicitly contract-excluded from Rust parity
//   (cookbook §2.2 / §8: "novel-token tagging is platform-divergent BY DESIGN;
//   the static table is the cross-platform-guaranteed surface"). The Rust port
//   implements the static-table fast path and a deterministic `.other` stub for
//   novel tokens, mirroring the Swift non-Apple path (`hmmViterbiTag` returns
//   `.other`). This is correct and intentional.

pub mod normalizer;
pub mod stemmer;
pub mod tokenizer;
pub mod word_class;
pub mod word_class_table;
pub mod lexicon;
pub mod fdc_frame;
pub mod fdc_signatures;
pub mod concept_bag;
pub mod fdc_matcher;
pub mod fdc_runtime;
pub mod code;
pub mod novel_token_cache;

pub use fdc_runtime::Fdc;
pub use fdc_matcher::FdcMatcher;
pub use concept_bag::build_bag;
pub use lexicon::CanonicalizationLexicon;
pub use fdc_frame::{FdcFrame, FdcEntry};
pub use word_class::WordClass;
pub use code::{is_well_formed, integer_base, MAX_EXTENSION_DIGITS};
pub use novel_token_cache::{
    NovelTokenCache, PoolEntry, PoolSubmission, POOL_SUBMIT_THRESHOLD, SHARED_NOVEL_CACHE,
    pool_tag,
};
