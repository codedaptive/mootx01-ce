// EstateManifestRefreshTests.swift
//
// The manifest refresh every opener runs after `GLKMigrationCatalog.prepare`.
// Three behaviours, each pinned separately because a regression in any of
// them is silent: `created` survives a rewrite, an unchanged manifest is not
// rewritten, and a manifest the catalog refuses is never overwritten. Rust
// twin: `estate_manifest_refresh::tests` in rust-migrations.
//
// Every test drives a scratch directory; the machine's catalog is never
// opened, read, or referenced.

import Foundation
import GeniusLocusKit
import Testing
@testable import GeniusLocusKitMigrations

@Suite("EstateManifestRefresh — created preserved, no rewrite on equal, refused manifests untouched")
struct EstateManifestRefreshTests {

    private func scratchRecord() throws -> EstateRecord {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("estate-manifest-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return EstateRecord(name: "scratch", directory: base.appendingPathComponent("scratch", isDirectory: true), kind: .transient)
    }

    private func cleanup(_ record: EstateRecord) {
        try? FileManager.default.removeItem(at: record.directory.deletingLastPathComponent())
    }

    @Test("A first refresh writes created from now; a later one preserves it; an equal manifest returns false")
    func refreshWritesOncePreservesCreatedAndReportsNoChange() throws {
        let record = try scratchRecord()
        defer { cleanup(record) }
        let first = Date(timeIntervalSince1970: 1_788_825_600)   // 2026-09-08T00:00:00Z
        let later = Date(timeIntervalSince1970: 1_788_912_000)   // a day on
        #expect(try EstateManifestRefresh.refresh(estate: record, format: .current, encryption: .encrypted, now: first))
        let written = try EstateCatalog.readManifest(of: record)
        #expect(written.created == "2026-09-08T00:00:00Z")
        #expect(written.encryption == .encrypted)
        #expect(written.schemaVersion == GeniusLocusKitSchema.version)
        #expect(!EstateManifestRefresh.declaresPlaintext(record))
        // Same facts, later clock: nothing written, bytes untouched.
        let bytes = try Data(contentsOf: record.manifestURL)
        #expect(try EstateManifestRefresh.refresh(estate: record, format: .current, encryption: .encrypted, now: later) == false)
        #expect(try Data(contentsOf: record.manifestURL) == bytes)
        // A changed posture: rewritten, `created` preserved from the first write.
        #expect(try EstateManifestRefresh.refresh(estate: record, format: .current, encryption: .plaintext, now: later))
        let rewritten = try EstateCatalog.readManifest(of: record)
        #expect(rewritten.created == "2026-09-08T00:00:00Z", "`created` is the first write's instant")
        #expect(rewritten.encryption == .plaintext)
        #expect(EstateManifestRefresh.declaresPlaintext(record))
    }

    @Test("afterPrepare records the preparation's format and the open posture")
    func afterPrepareRecordsThePreparation() throws {
        let record = try scratchRecord()
        defer { cleanup(record) }
        let preparation = GLKMigrationPreparation(format: .current, migrated: false, migrationState: nil)
        #expect(try EstateManifestRefresh.afterPrepare(preparation, estate: record, encryption: .plaintext,
                                                        now: Date(timeIntervalSince1970: 0)))
        let written = try EstateCatalog.readManifest(of: record)
        #expect(written.formatVersion == .current)
        #expect(written.encryption == .plaintext)
        #expect(written.created == "1970-01-01T00:00:00Z")
    }

    @Test("A manifest the catalog refuses is thrown, never overwritten")
    func refreshRefusesToOverwriteAManifestItCouldNotRead() throws {
        let record = try scratchRecord()
        defer { cleanup(record) }
        try FileManager.default.createDirectory(at: record.directory, withIntermediateDirectories: true)
        let rogue = #"{"fileVersion":1,"name":"scratch","schemaVersion":1,"formatVersion":{"major":1,"minor":8},"encryption":"plaintext","created":"2020-01-01T00:00:00Z","path":"/elsewhere"}"#
        try rogue.write(to: record.manifestURL, atomically: true, encoding: .utf8)
        var thrown: EstateCatalogError?
        do {
            _ = try EstateManifestRefresh.refresh(estate: record, format: .current, encryption: .encrypted,
                                                  now: Date(timeIntervalSince1970: 1_788_825_600))
        } catch let e as EstateCatalogError { thrown = e }
        guard case .unreadableEstateManifest(_, let detail)? = thrown, detail.contains("path") else {
            Issue.record("expected the catalog's refusal, got \(String(describing: thrown))"); return
        }
        #expect(try String(contentsOf: record.manifestURL, encoding: .utf8) == rogue, "the refused file is untouched")
        // A foreign name is refused the same way; the declaration helper reads it as no declaration.
        try #"{"fileVersion":1,"name":"other","schemaVersion":1,"formatVersion":{"major":1,"minor":8},"encryption":"plaintext","created":"2020-01-01T00:00:00Z"}"#
            .write(to: record.manifestURL, atomically: true, encoding: .utf8)
        #expect(throws: EstateCatalogError.self) {
            _ = try EstateManifestRefresh.refresh(estate: record, format: .current, encryption: .encrypted, now: Date(timeIntervalSince1970: 0))
        }
        #expect(!EstateManifestRefresh.declaresPlaintext(record))
    }
}
