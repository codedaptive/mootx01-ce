// windows_base_directory_adoption.rs — legacy Windows base directory → catalog
// configuration directory adoption capsule. Rust port only.
//
// Root cause of this capsule's existence: every pre-catalog Windows install of
// the Rust CLI kept everything it owned under `%LOCALAPPDATA%\MOOTx01`, the
// base directory the retired `core::paths::data_dir()` resolved. The estate
// catalog resolves the same install's base directory as
// `%LOCALAPPDATA%\com.mootx01.ce` (the product identity's
// `APPLICATION_SUPPORT_FOLDER`). The layout INSIDE the base is unchanged —
// `databases\<name>\estate.sqlite` before and after — so no layout capsule
// applies; the base itself is what moved, and nothing moved it. Without this
// capsule a Windows machine upgraded across that line reports a default estate
// at a directory that does not exist, the next `serve` creates it empty, and
// everything under the old base is unreachable by every command including
// `uninstall --purge` (ruling R4, 2026-09-08).
//
// Linux is unaffected: both the retired resolver and the catalog resolve
// `${XDG_DATA_HOME:-~/.local/share}/mootx01` (`UNIX_DATA_FOLDER`). macOS is a
// developer-run target for this port and is not adopted.
//
// The Swift port needs no twin. Its Apple base directory did not move:
// `~/Library/Application Support/com.mootx01.ce` before the catalog and after
// it (`MootProductIdentity.Storage.applicationSupportFolder`). What moved on
// the Swift side is the layout inside that base, which the flat-layout
// adoption inside `EstateCatalog.open()` (`FlatLayoutMigration`) carries.
//
// What the capsule moves: EVERY child of the old base, not a named subset.
// The old base is the same role the new one now plays, so its whole content
// belongs at the new base — the estate root (`databases\`), the LatticeLib
// novel-token pool and the merged `WordClassTable.json` it derives
// (`lattice\`, resolved by `lattice_lib::default_pool_dir` as
// `<configuration>\lattice\pool`), the moot-mgr history store (`moot-mgr\`)
// and the daemon port file. A named subset would silently orphan whatever it
// failed to name, which is the defect this capsule exists to close.
//
// What the capsule does:
//   1. Reads the old base. Absent or empty means nothing to do — a fresh
//      install, a non-Windows host, or a machine already adopted.
//   2. Refuses when ANY child's destination already exists. Two directories
//      claiming one slot is an operator decision, never a guess; nothing is
//      touched. The Swift layout capsules refuse on the same rule.
//   3. Otherwise renames each child into the new base and removes the emptied
//      old base. Same volume (both live under `%LOCALAPPDATA%`), so each
//      rename is atomic and no bytes are copied.
//
// Resumption needs no move order here, unlike the Swift flat-layout capsule:
// each child is one atomic rename of a whole subtree, so a run interrupted
// between renames leaves every child either wholly moved or wholly in place,
// and the next run moves what is left.
//
// This capsule is compiled unconditionally, like geometry normalization and
// unlike the format-step capsules. It is a base-directory concern, not a
// schema concern: the old base can hold an estate of ANY format, so gating it
// on a migration floor would strand the machines furthest behind. It is also
// the reason it runs BEFORE the catalog opens rather than inside the
// migration chain — the chain needs an estate the catalog can already name.
//
// Retirement: when the product's floor rises past every release that could
// have written `%LOCALAPPDATA%\MOOTx01`, delete this module, its registration
// in `lib.rs`, its test file and its `[[test]]` entry, and
// `apps/mootx01/rust/src/core/estate_adoption.rs`, the whole file, which is
// the product's only caller. Deleting that file breaks every command that
// calls `adopt_before_catalog_open`, and the compiler names all of them.
// Nothing else in the product knows the old base existed.

use std::fs;
use std::path::{Path, PathBuf};

/// The base directory folder name every pre-catalog Windows install used,
/// under `%LOCALAPPDATA%`. Spelled here and nowhere else in the product; the
/// retired `core::paths::data_dir()` that wrote it is gone.
pub const LEGACY_WINDOWS_BASE_FOLDER: &str = "MOOTx01";

/// What one run did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WindowsBaseAdoptionOutcome {
    /// No old base directory, or it holds nothing. Nothing touched.
    NothingToMove,
    /// The named children (file names, in the order they were renamed) now
    /// sit in the new base and no longer at the old one.
    Moved { entries: Vec<String> },
    /// A child's destination already exists. Nothing touched; the operator
    /// decides which copy is the machine's. `legacy` and `current` name the
    /// first colliding pair found.
    Refused { legacy: PathBuf, current: PathBuf },
}

/// The old base directory rule with its inputs passed in, for tests and for
/// the Windows resolver below. Always computes the Windows path
/// (`%LOCALAPPDATA%\MOOTx01`, falling back to `<home>\AppData\Local` when
/// `LOCALAPPDATA` is unset) so the rule can be pinned on any host;
/// `legacy_windows_base_directory` is what decides whether it applies.
/// `platform_variable` answers `LOCALAPPDATA`.
pub fn legacy_windows_base_directory_from(
    home: PathBuf,
    platform_variable: impl Fn(&str) -> Option<String>,
) -> PathBuf {
    let base = platform_variable("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join("AppData").join("Local"));
    base.join(LEGACY_WINDOWS_BASE_FOLDER)
}

/// The old base directory on this host, or `None` when this host never had
/// one. Only Windows did: Linux resolved `UNIX_DATA_FOLDER` before the catalog
/// and after it, and macOS is a developer-run target for this port.
pub fn legacy_windows_base_directory() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        Some(legacy_windows_base_directory_from(
            moot_product_identity::storage::process_home(),
            |name| std::env::var(name).ok().filter(|value| !value.is_empty()),
        ))
    }
    #[cfg(not(target_os = "windows"))]
    {
        None
    }
}

/// True when the old base holds at least one child: the capsule has work, or
/// a refusal, ahead. The command asks this first so it prints nothing and
/// stops no daemon on the overwhelmingly common no-op run.
pub fn windows_base_adoption_pending(legacy_base: &Path) -> bool {
    children(legacy_base).map(|c| !c.is_empty()).unwrap_or(false)
}

/// Move every child of `legacy_base` into `configuration_directory`.
///
/// Idempotent: an adopted machine (or any non-Windows host, whose caller
/// passes a path that does not exist) returns `NothingToMove`; a run
/// interrupted between renames resumes on the next call.
///
/// Errors are the file-system error of the directory creation or the rename
/// that failed. Children renamed before the failure stay renamed; the rest
/// are still at the old base, so the next run resumes.
pub fn run_windows_base_adoption(
    legacy_base: &Path,
    configuration_directory: &Path,
) -> Result<WindowsBaseAdoptionOutcome, std::io::Error> {
    let entries = match children(legacy_base) {
        Some(entries) if !entries.is_empty() => entries,
        _ => return Ok(WindowsBaseAdoptionOutcome::NothingToMove),
    };

    // Collision check over the whole set before the first rename: a refusal
    // must leave the machine exactly as it found it, so a half-moved base is
    // never the price of discovering the conflict.
    for name in &entries {
        let destination = configuration_directory.join(name);
        if destination.exists() {
            return Ok(WindowsBaseAdoptionOutcome::Refused {
                legacy: legacy_base.join(name),
                current: destination,
            });
        }
    }

    fs::create_dir_all(configuration_directory)?;
    let mut moved = Vec::with_capacity(entries.len());
    for name in entries {
        fs::rename(legacy_base.join(&name), configuration_directory.join(&name))?;
        moved.push(name);
    }
    // Best effort: the old base is meaningless once empty. A base still
    // holding something (a file created between the listing and here) is left
    // alone, and the next run adopts it.
    let _ = fs::remove_dir(legacy_base);
    Ok(WindowsBaseAdoptionOutcome::Moved { entries: moved })
}

/// The old base's child names, sorted so a run's reported order and its
/// rename order are the same on every host. `None` when the directory cannot
/// be read at all (absent, or not a directory).
fn children(legacy_base: &Path) -> Option<Vec<String>> {
    let mut names: Vec<String> = fs::read_dir(legacy_base)
        .ok()?
        .filter_map(|entry| entry.ok())
        .filter_map(|entry| entry.file_name().into_string().ok())
        .collect();
    names.sort();
    Some(names)
}
