// migration/mod.rs — Rust mirror of GeniusLocusKit's migration API.
//
// Ships ExternalCorpus, ExternalEntry, and the migration verb types
// (ParallelRunHandle, MigrationVerification, MigrationDivergence,
// ParallelCaptureMode, MigrationError). The hybrid_recall method
// routes through CorpusKit's Corpus struct, mirroring Swift's
// ExternalCorpus.hybridRecall(via:limit:now:).
//
// The `run_parallel` and `verify_migration` verb entry points live on
// the Swift `MigrationAPI` extension; here they are free functions
// that take the coordinator by reference, matching Rust ownership
// conventions. The `ParallelRunHandle.capture` method likewise takes
// the coordinator as a parameter rather than holding an unowned
// reference (Rust has no `unowned` — the caller that owns both the
// coordinator and the handle threads them through).

use std::sync::atomic::{AtomicBool, Ordering as AtomicOrdering};

use corpus_kit::{Corpus, CorpusKitResult, ScoredChunk};

use crate::coordinator::{EstateCoordinator, VerbDispatchError};
use crate::handle::EstateHandle;
use crate::intake::WriteMode;
use locus_kit::drawer::Drawer;
use locus_kit::filter::{Filter, RecallFrame};
use locus_kit::frames::CaptureFrame;

/// A single entry in an external reference corpus used for migration
/// benchmarking. Mirrors Swift's `ExternalEntry`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalEntry {
    /// Stable identifier from the source system.
    pub id: String,
    /// Verbatim text — the basis for the derived recall query.
    pub content: String,
    /// Classification tags carried from the source system.
    pub tags: Vec<String>,
}

impl ExternalEntry {
    pub fn new(
        id: impl Into<String>,
        content: impl Into<String>,
        tags: Vec<String>,
    ) -> Self {
        ExternalEntry {
            id: id.into(),
            content: content.into(),
            tags,
        }
    }
}

/// An external corpus for benchmark comparison. Mirrors Swift's
/// `ExternalCorpus`.
#[derive(Debug, Clone)]
pub struct ExternalCorpus {
    /// Human-readable corpus name.
    pub name: String,
    /// The reference entries.
    pub entries: Vec<ExternalEntry>,
}

impl ExternalCorpus {
    pub fn new(name: impl Into<String>, entries: Vec<ExternalEntry>) -> Self {
        ExternalCorpus {
            name: name.into(),
            entries,
        }
    }

    /// Execute hybrid BM25+vector recall for each corpus entry via the
    /// supplied `Corpus`. Returns one `Vec<ScoredChunk>` per entry, in
    /// entry order. Entries with empty content return an empty vec.
    ///
    /// Mirrors Swift's `ExternalCorpus.hybridRecall(via:limit:now:)`.
    ///
    /// - `corpus`: the estate's `Corpus`. Caller opens it from the same
    ///   storage backing the estate so chunk embeddings index the estate's
    ///   content.
    /// - `limit`: maximum scored chunks per entry.
    /// - `now_millis`: Unix epoch milliseconds for deterministic time.
    pub fn hybrid_recall(
        &self,
        corpus: &Corpus,
        limit: usize,
        now_millis: i64,
    ) -> CorpusKitResult<Vec<Vec<ScoredChunk>>> {
        let mut results: Vec<Vec<ScoredChunk>> = Vec::with_capacity(self.entries.len());
        for entry in &self.entries {
            if entry.content.trim().is_empty() {
                results.push(Vec::new());
                continue;
            }
            let hits = corpus.recall(&entry.content, limit, now_millis)?;
            results.push(hits);
        }
        Ok(results)
    }
}

// ---------------------------------------------------------------------------
// Migration verb types — mirrors Swift `MigrationTypes.swift`
// ---------------------------------------------------------------------------

/// Controls how captures are routed during a dual-estate parallel run.
/// Mirrors Swift's `ParallelCaptureMode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParallelCaptureMode {
    /// New captures go to the target only. Source is read-only.
    WriteToTarget,
    /// Reads fall through to source; captures go to target.
    ReadFromSource,
    /// New captures go to both estates simultaneously.
    MirrorBoth,
}

/// The result of `verify_migration`. Mirrors Swift's
/// `MigrationVerification`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MigrationVerification {
    /// Every corpus entry was recalled from the estate.
    Identical,
    /// One or more corpus entries could not be recalled.
    Diverged(Vec<MigrationDivergence>),
}

/// A single entry from an `ExternalCorpus` that could not be recalled
/// from the estate during `verify_migration`. Mirrors Swift's
/// `MigrationDivergence`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MigrationDivergence {
    /// The `ExternalEntry.id` of the entry that could not be recalled.
    pub entry_id: String,
    /// A human-readable description of the failure.
    pub reason: String,
}

impl MigrationDivergence {
    pub fn new(entry_id: impl Into<String>, reason: impl Into<String>) -> Self {
        MigrationDivergence {
            entry_id: entry_id.into(),
            reason: reason.into(),
        }
    }
}

/// Errors produced by the migration API. Mirrors Swift's
/// `MigrationError`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MigrationError {
    /// The external corpus could not be read or decoded.
    CorpusUnreadable { reason: String },
    /// A capture was attempted on a stopped `ParallelRunHandle`.
    ParallelRunStopped,
    /// The referenced estate (target or source mirror) is not open in
    /// the coordinator. Raised for both target-unavailable and
    /// source-side mirror-failure paths.
    TargetEstateNotOpen,
}

impl std::fmt::Display for MigrationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MigrationError::CorpusUnreadable { reason } => {
                write!(f, "MigrationError.corpusUnreadable: {}", reason)
            }
            MigrationError::ParallelRunStopped => {
                write!(
                    f,
                    "MigrationError.parallelRunStopped: capture attempted on a stopped parallel run handle"
                )
            }
            MigrationError::TargetEstateNotOpen => {
                write!(
                    f,
                    "MigrationError.targetEstateNotOpen: target estate is not open in this kit"
                )
            }
        }
    }
}

impl std::error::Error for MigrationError {}

/// Controls a dual-estate parallel capture run. Mirrors Swift's
/// `ParallelRunHandle` actor.
///
/// In Swift this is an `actor` because it holds mutable `stopped`
/// state. In Rust, `AtomicBool` provides the same thread-safe
/// one-way latch without requiring a lock.
///
/// The `stopped: AtomicBool` is NOT a schema-entity bitmap violation.
/// `ParallelRunHandle` is a transient control object that is never
/// persisted to SQLite. The no-Bool-on-entities rule applies
/// exclusively to persisted nouns.
pub struct ParallelRunHandle {
    /// The source estate (the estate being migrated away from).
    pub source: EstateHandle,
    /// The target estate (the estate being migrated into).
    pub target: EstateHandle,
    /// How new captures are routed during this run.
    pub mode: ParallelCaptureMode,
    /// Whether this run has been stopped. Once true, all subsequent
    /// `capture` calls return `MigrationError::ParallelRunStopped`.
    stopped: AtomicBool,
}

impl ParallelRunHandle {
    /// Construct a parallel run handle. Only `run_parallel` should
    /// create handles; callers receive them back and never construct
    /// their own.
    pub(crate) fn new(
        source: EstateHandle,
        target: EstateHandle,
        mode: ParallelCaptureMode,
    ) -> Self {
        ParallelRunHandle {
            source,
            target,
            mode,
            stopped: AtomicBool::new(false),
        }
    }

    /// File a new drawer according to the run's capture mode.
    ///
    /// Routes the capture to the target, both estates, or target-only
    /// (with source readable) depending on `mode`. Returns
    /// `Err(MigrationError::ParallelRunStopped)` if `stop()` has been
    /// called.
    ///
    /// Takes `coord: &mut EstateCoordinator` so it can route through
    /// `capture_with_mode(WriteMode::Regular)` — the mode-aware path that
    /// runs FDC classification and enqueues the corpus ingest job. The
    /// row-only `capture` path was a bug: migrated rows were index-dark
    /// (no FDC anchor, no encode queue entry). Parity with Swift
    /// `ParallelRunHandle.capture(_:)` which routes through
    /// `kit.capture(target, frame, mode: .regular)`.
    pub fn capture(
        &self,
        coord: &mut EstateCoordinator,
        frame: CaptureFrame,
        now_ms: i64,
    ) -> Result<Drawer, MigrationError> {
        if self.stopped.load(AtomicOrdering::Acquire) {
            return Err(MigrationError::ParallelRunStopped);
        }
        // Route through the mode-aware path so migrated rows get FDC classification
        // and corpus ingest queue entries — identical to a normal capture(mode: .regular).
        let do_capture = |c: &mut EstateCoordinator, h: &EstateHandle, f: CaptureFrame| {
            c.capture_with_mode(h, f, now_ms, WriteMode::Regular)
                .map_err(|_| MigrationError::TargetEstateNotOpen)
        };
        match self.mode {
            ParallelCaptureMode::WriteToTarget | ParallelCaptureMode::ReadFromSource => {
                do_capture(coord, &self.target, frame)
            }
            ParallelCaptureMode::MirrorBoth => {
                // Both must succeed. Target result is returned.
                let target_result = do_capture(coord, &self.target, frame.clone())?;
                let _ = do_capture(coord, &self.source, frame)?;
                Ok(target_result)
            }
        }
    }

    /// Permanently stop this parallel run. Once stopped, all
    /// subsequent `capture` calls return
    /// `MigrationError::ParallelRunStopped`. Irreversible.
    pub fn stop(&self) {
        self.stopped.store(true, AtomicOrdering::Release);
    }

    /// Whether this handle has been stopped.
    pub fn is_stopped(&self) -> bool {
        self.stopped.load(AtomicOrdering::Acquire)
    }
}

/// Open a dual-estate parallel capture run. Validates both handles
/// are open, then returns a `ParallelRunHandle` that routes new
/// captures according to `mode`. Mirrors Swift's
/// `GeniusLocusKit.runParallel(source:target:mode:)`.
pub fn run_parallel(
    coord: &EstateCoordinator,
    source: EstateHandle,
    target: EstateHandle,
    mode: ParallelCaptureMode,
) -> Result<ParallelRunHandle, VerbDispatchError> {
    // Validate both estates are open before issuing the handle.
    coord.estate_for(&source).map_err(|_| VerbDispatchError::EstateNotOpen {
        estate_uuid: source.estate_uuid,
    })?;
    coord.estate_for(&target).map_err(|_| VerbDispatchError::EstateNotOpen {
        estate_uuid: target.estate_uuid,
    })?;
    Ok(ParallelRunHandle::new(source, target, mode))
}

/// Verify migration fidelity by recalling each corpus entry from
/// the estate. Returns `Identical` when every participating entry
/// appears in its recall results; returns `Diverged` with a list of
/// missing entries otherwise. Mirrors Swift's
/// `GeniusLocusKit.verifyMigration(estate:against:now:)`.
///
/// Each entry is recalled using a content-match filter chain against
/// the estate. A content-match recall returns any drawer whose content
/// contains the entry's text. Entries whose content is blank after
/// trimming are skipped and do not contribute to the `Diverged` list.
pub fn verify_migration(
    coord: &EstateCoordinator,
    estate: &EstateHandle,
    corpus: &ExternalCorpus,
    now_ms: i64,
) -> Result<MigrationVerification, VerbDispatchError> {
    // Validate the handle up front. An empty corpus on a stale
    // handle should surface EstateNotOpen, not Identical.
    coord.estate_for(estate).map_err(|_| VerbDispatchError::EstateNotOpen {
        estate_uuid: estate.estate_uuid,
    })?;

    let mut divergences: Vec<MigrationDivergence> = Vec::new();

    for entry in &corpus.entries {
        if entry.content.trim().is_empty() {
            continue;
        }
        // Build a content-match recall frame for this entry. Uses
        // ContentMatches + Unconfirmed filters, matching the Swift
        // verifyMigration pattern: imported drawers are unconfirmed
        // by default and queryable by content substring.
        let frame = RecallFrame::new(vec![
            Filter::ContentMatches(entry.content.clone()),
            Filter::Unconfirmed,
        ]);
        let found = match coord.recall(estate, frame, now_ms) {
            Ok(ref drawers) => !drawers.is_empty(),
            Err(_) => false,
        };
        if !found {
            divergences.push(MigrationDivergence::new(
                &entry.id,
                "not found in recall results",
            ));
        }
    }

    if divergences.is_empty() {
        Ok(MigrationVerification::Identical)
    } else {
        Ok(MigrationVerification::Diverged(divergences))
    }
}
