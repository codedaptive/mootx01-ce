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
//   (cookbook §2.2 / §8: the Apple tagger and the non-Apple HMM are different
//   engines and need not agree). The Rust port implements the static-table
//   fast path AND the non-Apple HMM/Viterbi tagger (`word_class::hmm_tag`),
//   which is byte-identical to the Swift `HMMTagger.tag`. The static table is
//   the cross-platform-guaranteed surface for table tokens; the HMM is the
//   bit-identical Swift↔Rust surface for novel tokens. Only the Apple NLTagger
//   path is unported.

pub mod normalizer;
pub mod stemmer;
pub mod tokenizer;
pub mod word_class;
pub mod word_class_table;
pub mod lexicon;
pub mod fdc_frame;
pub mod fdc_signatures;
pub mod fdc_semantic_ranker;
pub mod concept_bag;
pub mod fdc_matcher;
pub mod fdc_runtime;
pub mod fdc_code_language;
pub mod code;
pub mod novel_token_cache;
pub mod novel_pool_submitter;
pub mod pool_reducer;
pub mod qid_closure;

pub use fdc_runtime::{Fdc, FdcContentKind};
pub use fdc_code_language::{detect_code_language, FdcCodeLanguage};
pub use fdc_matcher::FdcMatcher;
pub use fdc_semantic_ranker::{FdcSemanticCandidate, FdcSemanticDecision, FdcSemanticRanker};
pub use concept_bag::{build_bag, build_bag_with_tagger, build_encoder_bag_with_tagger, build_bag_no_record, build_encoder_bag_no_record};
pub use lexicon::CanonicalizationLexicon;
pub use fdc_frame::{FdcFrame, FdcEntry};
pub use word_class::{WordClass, NovelTokenTaggerChoice};
pub use code::{is_well_formed, integer_base, MAX_EXTENSION_DIGITS};
pub use novel_token_cache::{
    NovelTokenCache, PoolEntry, PoolSubmission, POOL_SUBMIT_THRESHOLD, SHARED_NOVEL_CACHE,
    pool_tag,
};
pub use novel_pool_submitter::{local_dir_submitter, default_submitter, default_pool_dir, default_table_artifact};
pub use word_class_table::{
    load_with_precedence as table_load_with_precedence, load_writable_table, BUNDLED_TABLE_JSON,
    global_table, table_version, word_class, word_class_no_record, swap_global_table,
    swap_global_table_from_precedence, seed_global_table, WordClassTableCache,
};
pub use pool_reducer::{reduce as pool_reduce, PoolReduceResult, PoolReducerError};
// The Q-ID taxonomic-closure surface (mission #7b): transitive P31/P279
// ancestors over the pinned `QIDClosureEdges.json` snapshot. Mirrors the
// Swift `QIDClosure` enum. Consumed by LocusKit's DrawerFingerprint to fill
// the lattice-block `qidClosureHash` slot.
pub use qid_closure::{
    ancestors as qid_ancestors, data_version as qid_closure_data_version,
    is_available as qid_closure_is_available,
};
