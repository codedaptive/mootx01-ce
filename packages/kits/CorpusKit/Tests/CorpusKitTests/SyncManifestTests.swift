// SyncManifestTests.swift
//
// Peer suite for CorpusKitSync.manifest (Sources/CorpusKit/SyncManifest.swift).
// The factory is pure: it builds the per-estate SyncManifest the CloudKit
// layer uses for the chunks table. These assertions pin the manifest
// shape — kit id, schema version, the single chunks table, and the
// append-only conflict policy that chunk content-addressing depends on.

import Testing
import CorpusKit
import ConvergenceKit

@Suite("SyncManifest")
struct SyncManifestTests {

    @Test func manifestIdentifiesCorpusKit() {
        let manifest = CorpusKitSync.manifest(zoneIdentifier: "estate-1")
        #expect(manifest.kitID == "CorpusKit")
        #expect(manifest.schemaVersion == 1)
    }

    @Test func manifestEchoesZoneIdentifier() {
        let manifest = CorpusKitSync.manifest(zoneIdentifier: "zone-XYZ")
        #expect(manifest.zoneIdentifier == "zone-XYZ")
    }

    @Test func manifestHasSingleChunksTable() {
        let manifest = CorpusKitSync.manifest(zoneIdentifier: "estate-1")
        #expect(manifest.tables.count == 1)
        let table = manifest.tables.first
        #expect(table?.name == "chunks")
        #expect(table?.primaryKeyColumn == "id")
    }

    @Test func chunksTableIsBidirectionalAppendOnly() {
        let manifest = CorpusKitSync.manifest(zoneIdentifier: "estate-1")
        let table = manifest.tables.first
        #expect(table?.direction == .bidirectional)
        #expect(table?.conflictPolicy == .appendOnly)
    }
}
