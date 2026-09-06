//! Model-directory resolution for span-encoder activation.
//!
//! The `"encoder"` value of the `embedding_provider` manifest key makes the
//! coordinator build a `SpanEncoder` from the active registry row; the
//! resolver here answers "where are that model's files on this device". The
//! bundling unit supplies the production conformer; `NilModelDirectoryResolver`
//! (the default) answers `None` for every id, which the coordinator treats
//! as "model unavailable" (recall runs lexical-only, one stderr line).
//!
//! Mirror of Swift `EncoderActivation.swift` (`ModelDirectoryResolving`).

use std::path::{Path, PathBuf};

/// Resolves the on-disk directory holding a model's assets (`vocab.txt`,
/// `config.json`, `tokenizer.json`, `model.safetensors`).
pub trait ModelDirectoryResolving: Send + Sync {
    /// Directory for `model_id`, or `None` when this device has no copy.
    fn model_dir_for(&self, model_id: &str) -> Option<PathBuf>;
}

/// The default resolver: no model directories on this device.
#[derive(Debug, Default, Clone, Copy)]
pub struct NilModelDirectoryResolver;

impl ModelDirectoryResolving for NilModelDirectoryResolver {
    fn model_dir_for(&self, _model_id: &str) -> Option<PathBuf> {
        None
    }
}

/// The production resolver: `corpus_kit_providers::model_dir_for` searched
/// from the mootx01 data directory (the 1.2 download slot) and the installer
/// package slot beside the binary. Serve entry points install it with
/// `EstateCoordinator::set_model_directory_resolver` BEFORE the estate is
/// opened and wired, so the `"encoder"` activation can find the model;
/// without it the coordinator keeps `NilModelDirectoryResolver` and every
/// estate runs lexical-only. Twin of Swift `BundledModelDirectoryResolver`.
#[derive(Debug, Clone)]
pub struct BundledModelDirectoryResolver {
    /// The mootx01 data directory root (search slot 1, the 1.2 download
    /// location; empty in 1.1).
    data_dir: PathBuf,
}

impl BundledModelDirectoryResolver {
    /// Create the resolver over `data_dir`.
    pub fn new(data_dir: impl Into<PathBuf>) -> Self {
        BundledModelDirectoryResolver { data_dir: data_dir.into() }
    }

    /// The data directory the resolver searches first.
    pub fn data_dir(&self) -> &Path {
        &self.data_dir
    }
}

impl ModelDirectoryResolving for BundledModelDirectoryResolver {
    fn model_dir_for(&self, model_id: &str) -> Option<PathBuf> {
        corpus_kit_providers::model_dir_for(model_id, &self.data_dir)
    }
}
