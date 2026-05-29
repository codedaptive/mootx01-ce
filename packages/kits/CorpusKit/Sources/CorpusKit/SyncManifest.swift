// SyncManifest.swift
//
// Per-estate sync manifest for RAG content. Pairs with VectorKit's
// vectors-table sync (when the application enables both): chunks
// and their vectors travel together in the same CloudKit zone so
// they remain join-compatible across devices.

import Foundation
import ConvergenceKit

public enum CorpusKitSync {

    /// Build a SyncManifest for the chunks table in the given
    /// zone. Audit-log-style append-only conflict policy (chunks
    /// are content-addressed by id and never edited in place;
    /// duplicate inserts are idempotent).
    public static func manifest(zoneIdentifier: String) -> SyncManifest {
        SyncManifest(
            kitID: "CorpusKit",
            schemaVersion: 1,
            zoneIdentifier: zoneIdentifier,
            tables: [
                SyncedTable(
                    name: "chunks",
                    direction: .bidirectional,
                    primaryKeyColumn: "id",
                    conflictPolicy: .appendOnly
                )
            ]
        )
    }
}
