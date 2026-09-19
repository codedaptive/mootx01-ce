// FlatLayoutStep.swift
//
// The commands' side of the flat-layout adoption (GeniusLocusKit
// `FlatLayoutMigration`). A 1.0.x install kept its estate flat in the
// configuration directory; the catalog names databases/default/. The
// catalog open itself performs the move, so every opener adopts; what the
// commands add is daemon custody and the both-present resolution:
//
//   - `pending` is asked BEFORE the catalog open. A flat estate predates the
//     PID marker the marker-based quiesce reads, and a flat estate at the
//     configuration directory is the resident's estate by definition, so
//     `upgrade` and `install` stop the resident unconditionally when it is
//     true, then open.
//   - `adopt` opens the catalog (which moves a lone flat estate) and, when
//     the open refuses because both layouts hold a database, runs
//     `FlatLayoutMigration.reclaimDefaultSlot`: a catalog estate that holds
//     only the product's seeded charter hints is retired with its Keychain
//     key and the flat estate moved in; anything else stays a refusal and
//     is printed for the operator.
//
// Retires with the adoption: delete this file, the two call sites, the
// kit's `FlatLayoutMigration.swift` and the block in `EstateCatalog.open()`.

#if GLK_MIGRATION_FLAT_LAYOUT_TO_CATALOG && os(macOS)

import Foundation
import GeniusLocusKit
import MootEstateOpen
import MootInstallerCore

enum FlatLayoutStep {

    /// True when a flat estate sits at the configuration directory: the
    /// next catalog open moves it, or refuses. The caller stops the resident
    /// only when this is true, and before it opens the catalog.
    static func pending() -> Bool {
        FlatLayoutMigration.pending(configurationDirectory: EstateCatalog.configurationDirectory)
    }

    /// Adopt the flat estate and report it. Returns false when the layout is
    /// still unresolved (both layouts hold a database and the catalog estate
    /// is not provably free of user content) or a move failed; the caller
    /// stops the command there, before anything opens the record's database.
    static func adopt() async -> Bool {
        let configuration = EstateCatalog.configurationDirectory
        do {
            _ = try EstateOpen.catalog(selecting: nil)
            print("  ✓ estate layout: flat estate moved from \(configuration.path) into the default estate's directory")
            return true
        } catch EstateCatalogError.twoDefaultEstates(let flat, let catalogDatabase) {
            return await reclaim(configuration: configuration, flat: flat, catalogDatabase: catalogDatabase)
        } catch {
            print("  ✗ estate layout migration failed: \(error)\n    The flat estate is still in place. Run the command again to resume.")
            return false
        }
    }

    /// The both-present case: retire a charter-only catalog estate and adopt
    /// the flat one, or print the refusal.
    private static func reclaim(configuration: URL, flat: URL, catalogDatabase: URL) async -> Bool {
        do {
            // `load` reads the catalog without adopting; the default record
            // is the only record a flat estate can become.
            guard let record = try EstateCatalog.load().record(named: EstateCatalog.defaultName) else {
                print("  ✗ estate layout: the catalog names no default estate; nothing was changed.")
                return false
            }
            switch try await FlatLayoutMigration.reclaimDefaultSlot(
                configurationDirectory: configuration, record: record,
                ownerIdentifier: MootPaths.defaultOwnerIdentifier) {
            case .reclaimed(let retired, let moved):
                print("  ✓ estate layout: the catalog estate held only the product's charter hints; retired \(retired.count) file(s) and moved \(moved.count) file(s) from \(configuration.path) into \(record.directory.path)")
                return true
            case .moved(let outcome):
                // Reached only when the other opener resolved the layout
                // between the refusal and the reclaim.
                if case .refused = outcome { return refusal(flat: flat, catalogDatabase: catalogDatabase, reason: nil) }
                print("  ✓ estate layout: adopted")
                return true
            case .refused(let flat, let catalogDatabase, let reason):
                return refusal(flat: flat, catalogDatabase: catalogDatabase, reason: reason.description)
            }
        } catch {
            print("  ✗ estate layout migration failed: \(error)\n    The flat estate is still in place. Run the command again to resume.")
            return false
        }
    }

    private static func refusal(flat: URL, catalogDatabase: URL, reason: String?) -> Bool {
        print("""
              ✗ estate layout: two default estates found and nothing was changed.
                flat:    \(flat.path)
                catalog: \(catalogDatabase.path)
                \(reason.map { "\($0)." } ?? "")
                Move or remove one of them, then run the command again.
            """)
        return false
    }
}

#endif
