// EstateManifestRefresh.swift
//
// Keeps an estate's manifest (`estate.json`) truthful after an open. Every
// process that opens an estate and runs the migration catalog's prepare step
// (mootx01 serve, drain, dream and upgrade; aria-mcp) calls this afterwards:
// a migration changes what is on disk, and the manifest must say so. Older
// estates that predate the manifest get one here too, so every estate the
// product has opened carries the versions it actually holds.
//
// The manifest is written through the catalog, the one place that spells
// estate files. `created` is preserved from an existing manifest and set to
// `now` only when there was none. Lives in the migrations umbrella because
// the prepare result it reads is defined here.

import Foundation
import GeniusLocusKit
import PersistenceKit

public enum EstateManifestRefresh {

    /// Write `estate.json` for `estate` if it is missing or its recorded
    /// versions differ from what the estate now holds. Returns true when a
    /// manifest was written.
    @discardableResult
    public static func afterPrepare(_ preparation: GLKMigrationPreparation,
                                    estate: EstateRecord,
                                    encryption: EstateEncryptionConfig,
                                    now: Date) throws -> Bool {
        let posture: EstateManifest.Encryption
        if case .plaintext = encryption.mode { posture = .plaintext } else { posture = .encrypted }
        return try refresh(estate: estate, format: preparation.format, encryption: posture, now: now)
    }

    /// Write `estate.json` with the given format and posture if it is missing
    /// or differs. Returns true when a manifest was written.
    @discardableResult
    public static func refresh(estate: EstateRecord, format: EstateFormatVersion,
                               encryption: EstateManifest.Encryption, now: Date) throws -> Bool {
        let existing = (try? EstateCatalog.readManifest(of: estate))
        let created = existing?.created ?? ISO8601DateFormatter().string(from: now)
        let current = EstateManifest(
            name: estate.name,
            schemaVersion: GeniusLocusKitSchema.version,
            formatVersion: format,
            encryption: encryption,
            created: created)
        if let existing, existing == current { return false }
        try EstateCatalog.writeManifest(current, to: estate)
        return true
    }

    /// The posture the manifest declares for an estate that may not exist yet,
    /// used to decide how a NEW estate file is created. Missing manifest means
    /// the encrypted default.
    public static func declaresPlaintext(_ estate: EstateRecord) -> Bool {
        (try? EstateCatalog.readManifest(of: estate))?.encryption == .plaintext
    }
}
