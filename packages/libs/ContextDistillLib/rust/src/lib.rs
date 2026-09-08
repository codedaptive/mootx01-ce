//! context-distill-lib — Rust port of the CDL-01 distillation classifier
//! and converter.
//!
//! Provides a deterministic, ML-free structural classifier (`shape`) and
//! the converter identity layer (`converter`) for the `intent-span` and
//! related distillation candidates. Conformance-gated against shared oracle
//! vectors in Tests/ContextDistillLibTests/Vectors/ alongside the Swift port.
//!
//! ## Modules
//! - [`shape`] — Record-shape classification. Port of `record_shape_classifier.py`.
//! - [`converter`] — Converter identity enum. Port of converter constants
//!   in `distill_plus_converter.py`.
//! - [`input`] — Input contract for the distillation algorithms.
//!
//! ## No regex, no external ML
//! All pattern matching uses hand-written scanners mirroring Python Unicode
//! semantics. No regex crate, no external model weights.

pub mod atoms;
pub mod converter;
pub mod complete_content;
pub mod passage_views;
pub mod digest;
pub mod distiller;
pub mod input;
pub mod python_text;
pub mod scanners;
pub mod selection;
pub mod shape;
pub mod terms;
