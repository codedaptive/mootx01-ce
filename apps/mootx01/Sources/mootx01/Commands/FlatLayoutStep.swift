// FlatLayoutStep.swift
//
// The one place the mootx01 commands call the flat-layout capsule
// (GLKMigrationFlatLayoutToCatalog). A 1.0.x install kept its estate flat in
// the configuration directory; the catalog names databases/default/. Two
// commands meet such a machine: `upgrade`, before any migration step opens
// the record's database, and `install` re-run over a 1.0.x install, which
// treats the flat estate as a mandatory reuse. Both stop the resident first
// (a flat estate predates the PID marker the marker-based quiesce reads, and
// a flat estate at the configuration directory is the resident's estate by
// definition), then call `migrate`.
//
// Retires with the capsule: delete this file, the two call sites, the
// capsule target, its trait and its test target.

#if GLK_MIGRATION_FLAT_LAYOUT_TO_CATALOG && os(macOS)

import Foundation
import GeniusLocusKit
import GeniusLocusKitMigrations

enum FlatLayoutStep {

    /// True when a flat estate sits at the configuration directory and
    /// `estate` is the registered default: a move is due. The caller stops
    /// the resident only when this is true.
    static func pending(_ estate: EstateRecord) -> Bool {
        FlatLayoutMigration.pending(
            configurationDirectory: EstateCatalog.configurationDirectory, record: estate)
    }

    /// Run the move and report it. Returns false when the capsule refused
    /// (both layouts hold a database) or a rename failed; the caller stops
    /// the command there, before anything opens the record's database.
    static func migrate(_ estate: EstateRecord) -> Bool {
        do {
            switch try FlatLayoutMigration.run(
                configurationDirectory: EstateCatalog.configurationDirectory, into: estate) {
            case .moved(let files):
                print("  ✓ estate layout: moved \(files.count) file(s) from \(EstateCatalog.configurationDirectory.path) into \(estate.directory.path)")
                return true
            case .refused(let flat, let catalog):
                print("""
                      ✗ estate layout: two default estates found and nothing was changed.
                        flat:    \(flat.path)
                        catalog: \(catalog.path)
                        Move or remove one of them, then run the command again.
                    """)
                return false
            case .nothingToMove:
                return true
            }
        } catch {
            print("  ✗ estate layout migration failed: \(error)\n    The flat estate is still in place. Run the command again to resume.")
            return false
        }
    }
}

#endif
