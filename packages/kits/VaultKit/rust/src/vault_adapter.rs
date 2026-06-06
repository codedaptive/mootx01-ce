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

/// Vault format adapter: vault directory ⇄ `NoteIR` slice.
pub trait VaultAdapter {
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
}
