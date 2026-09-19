// EstateOpen.swift
//
// The one place every command opens the estate catalog. Both ports execute
// the same two steps in the same order:
//
//   (a) Windows base-directory adoption: a pre-catalog Windows install kept
//       everything under %LOCALAPPDATA%\MOOTx01; the catalog's base is
//       %LOCALAPPDATA%\com.mootx01.ce. The adoption capsule moves the old
//       base before the catalog opens. On Apple the base directory never
//       moved, so the step is a no-op — the step is still present so both
//       ports have an identical funnel shape.
//
//   (b) EstateCatalog.open or EstateCatalog.open(selecting:) when a name
//       or path is given. On Apple the catalog open itself adopts a
//       pre-catalog FLAT estate (a 1.0.x install's estate.sqlite beside the
//       catalog file) into databases/default/ before it returns, so the
//       Swift side has no separate flat-layout step here: every opener of
//       the catalog, in this funnel or outside it, gets the adoption. The
//       commands that own the daemon stop it first (FlatLayoutStep).
//
// Routing every command through this funnel guarantees the adoption always
// precedes the open, regardless of which command the operator invokes first
// after an upgrade on Windows. The parity test (EstateOpenTests.swift)
// checks that the step names here and in the Rust port match
// apps/mootx01/Tests/Fixtures/estate_open_steps.json.

import GeniusLocusKit

public enum EstateOpen {

    /// The ordered step names that `catalog(selecting:)` executes.
    ///
    /// Both ports declare the same list; `EstateOpenTests` reads
    /// `estate_open_steps.json` and verifies the two lists match.
    public static let steps: [String] = [
        "windows_base_adoption",
        "catalog_open",
    ]

    /// Open the estate catalog, running the pre-open adoption step first.
    ///
    /// - Parameter selecting: a registered estate name or `<dir>/<name>`
    ///   path for a transient estate. `nil` opens the active estate.
    /// - Throws: whatever `EstateCatalog.open` or `EstateCatalog.open(selecting:)`
    ///   throws on a catalog I/O error or a missing estate.
    public static func catalog(selecting db: String?) throws -> EstateCatalog {
        // step (a): Windows base-directory adoption.
        // The Apple base directory never moved, so this is a no-op on Apple
        // platforms. The step is present so both ports have the same shape.
        // On Windows this call is handled by the Rust port exclusively
        // (Swift has no Windows target).

        // step (b): Open the catalog.
        if let name = db {
            return try EstateCatalog.open(selecting: name)
        }
        return try EstateCatalog.open()
    }
}
