import Testing
import Foundation
@testable import aria_mcp
@testable import GeniusLocusKit
@_spi(Testing) import GeniusLocusKit

/// Estate-selection tests: verify `isRegisteredOpening` with records drawn
/// from a real scratch catalog via `EstateCatalog.configurationDirectoryOverride`.
/// Twin of the Rust `estate_selection_tests` module in `main.rs`.
///
/// The configuration-directory override is process-global, so the suite is
/// serialized with `.serialized` to prevent parallel tests from colliding.
@Suite("aria-mcp estate selection", .serialized)
struct EstateSelectionTests {

    /// Runs `body` with the catalog configuration directory pointed at a
    /// private scratch directory, restoring the override on return.
    private func withScratchCatalog<T>(_ body: (URL) throws -> T) throws -> T {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aria-mcp-sel-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        EstateCatalog.configurationDirectoryOverride = tmp
        defer {
            EstateCatalog.configurationDirectoryOverride = nil
            try? FileManager.default.removeItem(at: tmp)
        }
        return try body(tmp)
    }

    /// `--in-memory` forces transient posture whatever the record kind says.
    /// A mutation that drops `&& !inMemory` from `isRegisteredOpening` fails
    /// this test.
    @Test func inMemoryAlwaysTransientWhateverTheRecordKind() throws {
        try withScratchCatalog { _ in
            let catalog = try EstateCatalog.create()
            let record = catalog.active
            // Sanity: catalog creates a registered default record.
            #expect(record.kind == .registered)
            // The claim: in-memory overrides the registered kind → transient posture.
            #expect(!AriaMCPMain.isRegisteredOpening(kind: record.kind, inMemory: true))
        }
    }

    /// A registered record without `--in-memory` → registered posture. Mirrors
    /// `AriaMCPMain.swift:143` (`isRegisteredOpening`) for mutation coverage.
    @Test func registeredRecordWithoutInMemoryIsRegistered() throws {
        try withScratchCatalog { _ in
            let catalog = try EstateCatalog.create()
            let record = catalog.active
            #expect(record.kind == .registered)
            #expect(AriaMCPMain.isRegisteredOpening(kind: record.kind, inMemory: false))
        }
    }

    /// A transient record (path-selected with `--db <dir>/<name>`) is never
    /// opened with registered posture regardless of `--in-memory`.
    @Test func transientRecordIsAlwaysTransient() throws {
        try withScratchCatalog { tmp in
            // Create the catalog first so open(selecting:) can find it.
            _ = try EstateCatalog.create()
            // Attach a transient estate by path (<dir>/<name> selector).
            let transientDir = tmp.appendingPathComponent("scratch", isDirectory: true)
            try FileManager.default.createDirectory(at: transientDir, withIntermediateDirectories: true)
            let selector = "\(transientDir.path)/bench"
            let catalog = try EstateCatalog.open(selecting: selector)
            let record = catalog.active
            #expect(record.kind == .transient)
            #expect(!AriaMCPMain.isRegisteredOpening(kind: record.kind, inMemory: false))
            #expect(!AriaMCPMain.isRegisteredOpening(kind: record.kind, inMemory: true))
        }
    }
}
