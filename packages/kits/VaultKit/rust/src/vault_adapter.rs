//! VaultAdapter — the modular adapter seam: vault files ⇄ `NoteIR`.
//!
//! `VaultAdapter` is the one place where a concrete vault format (Obsidian
//! today; Joplin / Bear / Logseq / plain-Markdown later) is taught how to
//! read itself into the canonical `NoteIR` and write `NoteIR` back out.
//! Everything above this seam — `DrawerMapping` and `VaultBridge` — is
//! format-agnostic and never names a concrete adapter, so a new format adds
//! one `VaultAdapter` implementor with no change to the core (ADR-VAULTKIT-001 (c)).
//!
//! Both methods touch the filesystem and therefore return `Result`.
//! Both are pure with respect to the substrate — an adapter never reaches
//! a `Drawer`, a verb, or a coordinator.

use crate::error::VaultKitError;
use crate::note_ir::NoteIR;
use std::path::Path;

/// Progress callback for vault import/export operations.
///
/// Called every 100 items and at the final item with `(processed, total)`.
/// For operations with fewer than 100 notes, called once at completion.
/// Must be `Send + Sync` so it can be passed across thread boundaries.
pub type VaultProgress<'a> = dyn Fn(usize, usize) + Send + Sync + 'a;

/// Vault format adapter: vault directory ⇄ `NoteIR` slice.
///
/// `Send + Sync` required so adapters can be stored in `Arc` and shared
/// across thread boundaries (parity with Swift's `Sendable` conformance
/// on `VaultAdapter`).
pub trait VaultAdapter: Send + Sync {
    /// Read a vault directory into canonical notes.
    ///
    /// Returns one `NoteIR` per source note, in a deterministic order
    /// (sorted by `stable_source_key`) so repeated reads and round-trip
    /// equality `to_ir(from_ir(x)) == x` are stable regardless of
    /// filesystem enumeration order.
    fn to_ir(&self, vault_path: &Path) -> Result<Vec<NoteIR>, VaultKitError>;

    /// Write canonical notes back out to a vault directory, mirroring the
    /// folder tree carried in each note's `stable_source_key`.
    ///
    /// The directory is created if absent. The adapter writes only inside
    /// `vault_path`.
    fn from_ir(&self, notes: &[NoteIR], vault_path: &Path) -> Result<(), VaultKitError>;

    /// Write canonical notes with optional per-item progress reporting.
    ///
    /// This is a trait requirement (not merely a default-only method) so that
    /// concrete adapters can override it for real per-item firing and the
    /// override is reachable through a trait object. Adapters that do not
    /// support per-item progress do NOT need to implement this method — the
    /// default below delegates to `from_ir` and ignores the closure.
    ///
    /// Called every 100 items and at the final item with `(processed, total)`.
    fn from_ir_with_progress(
        &self,
        notes: &[NoteIR],
        vault_path: &Path,
        progress: Option<&VaultProgress<'_>>,
    ) -> Result<(), VaultKitError> {
        let _ = progress;
        self.from_ir(notes, vault_path)
    }
}
