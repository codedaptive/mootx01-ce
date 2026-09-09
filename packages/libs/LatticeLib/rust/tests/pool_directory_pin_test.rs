//! The pool directory rules, pinned as literals in both ports.
//!
//! The Swift twin is the `Novel pool directory rules` suite in
//! `Tests/LatticeLibTests/NovelPoolSubmitterTests.swift`, which asserts the
//! same two strings. The pair exists because this port once silently stopped
//! resolving the Apple container: the merged `WordClassTable.json` a Mac had
//! accumulated was abandoned, FDC classification fell back to the bundled
//! table, and nothing failed. Only a literal pin catches that; a test that
//! recomputes the rule agrees with whatever the rule became.

use lattice_lib::novel_pool_submitter::{
    apple_pool_directory, configured_pool_directory, CONFIGURATION_LATTICE_FOLDER, POOL_FOLDER,
};
use std::path::{Path, PathBuf};

#[test]
fn apple_pool_directory_is_the_lattice_sibling() {
    assert_eq!(
        apple_pool_directory(Path::new("/probe/Library/Application Support")),
        PathBuf::from("/probe/Library/Application Support/com.mootx01.lattice/pool"),
        "the Apple rule must match Swift NovelPoolSubmitter.applePoolDirectory byte for byte"
    );
    // The folder name is the product identity's `LATTICE_FOLDER`, consumed
    // here and nowhere else in this port.
    assert_eq!(moot_product_identity::storage::LATTICE_FOLDER, "com.mootx01.lattice");
}

#[test]
fn configured_pool_directory_lives_inside_the_install_folder() {
    assert_eq!(
        configured_pool_directory(Path::new("/probe/.local/share/mootx01")),
        PathBuf::from("/probe/.local/share/mootx01/lattice/pool"),
        "the Linux and Windows rule must match Swift configuredPoolDirectory"
    );
    assert_eq!(CONFIGURATION_LATTICE_FOLDER, "lattice");
    assert_eq!(POOL_FOLDER, "pool");
}

#[test]
fn the_windows_configured_pool_is_under_the_catalog_base() {
    // `%LOCALAPPDATA%\com.mootx01.ce\lattice\pool`. The old base was
    // `%LOCALAPPDATA%\MOOTx01\lattice\pool`; the Windows base-directory
    // adoption capsule in rust-migrations carries it across.
    assert_eq!(
        configured_pool_directory(Path::new("C:\\Users\\bo\\AppData\\Local\\com.mootx01.ce")),
        PathBuf::from("C:\\Users\\bo\\AppData\\Local\\com.mootx01.ce")
            .join("lattice")
            .join("pool")
    );
}

#[test]
fn the_merged_table_sits_beside_the_pool_not_inside_it() {
    let pool = apple_pool_directory(Path::new("/probe/Library/Application Support"));
    assert_eq!(
        pool.parent().expect("a parent").join("WordClassTable.json"),
        PathBuf::from("/probe/Library/Application Support/com.mootx01.lattice/WordClassTable.json")
    );
}
