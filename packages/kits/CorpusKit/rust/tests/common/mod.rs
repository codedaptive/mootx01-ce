//! Shared test-support for the CorpusKit integration suites.
//!
//! Files under `tests/` subdirectories are not compiled as their own test
//! binaries, so this module is the Rust home for helpers several suites share.
//! Declare it with `mod common;` at the top of an integration test file.

pub mod counts_integrity;
