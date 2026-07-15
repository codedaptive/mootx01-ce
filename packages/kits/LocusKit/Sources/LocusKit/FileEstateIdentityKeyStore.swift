// FileEstateIdentityKeyStore.swift
//
// DEBUG-ONLY estate identity key store backed by plain files.
//
// WHY THIS EXISTS (2026-07-11, upstreamed from the fulcrum consumer —
// dev runs were hanging): development builds are re-signed on every
// rebuild (ad-hoc identity on hosts without a team certificate), and
// the legacy macOS keychain binds item ACLs to the code signature.
// Every rebuild therefore made `KeychainEstateIdentityKeyStore` trigger
// a blocking "allow keychain access" prompt during estate-host
// construction — a hang at app bootstrap on every single dev run, and
// every consumer app hosting a durable on-disk estate hit it.
//
// SECURITY BOUNDARY (Perkins posture, carried verbatim from the
// consumer-side review that ratified this bypass): the Keychain store
// remains the production default (`Estate.defaultIdentityKeyStore(for:)`
// is UNCHANGED by this file — it still resolves durable backends to
// `KeychainEstateIdentityKeyStore`), and the release binary CANNOT
// reach this type — the entire file is compiled out of non-DEBUG
// builds. This preserves the ratified "production must never be
// wireable to a non-Keychain key store" posture while making DEBUG
// runs promptless. Key material in DEBUG lands in a 0600 file under
// Application Support; acceptable for development machines, never for
// release (which never compiles this path).
//
// Unlike `InMemoryEstateIdentityKeyStore` (whose keys vanish per-process
// and would re-mint the estate's federation identity on every launch),
// this store is durable across runs — the dev estate keeps ONE stable
// identity, matching the Keychain store's observable behavior minus the
// prompts.
//
// SWIFT/RUST PARITY RULING: this type intentionally has NO Rust
// counterpart. It is a host-side developer-experience workaround for a
// macOS/iOS code-signing artifact (ad-hoc re-signing invalidating
// Keychain ACLs), not a substrate algorithm or on-disk format — nothing
// a Rust-side consumer of LocusKit's data files would ever need to read
// or produce. The four-way conformance gate (Swift scalar, Swift Metal,
// Rust scalar, Rust BLAS/NEON) applies to algorithms operating on
// bitmap/vector data; it does not apply to key-store plumbing, and
// `EstateIdentityKeyStore` itself (the protocol this type conforms to)
// is a Swift-only seam — `KeychainEstateIdentityKeyStore` and
// `InMemoryEstateIdentityKeyStore` are likewise Swift-only. Parity is
// therefore N/A by construction, not waived.
//
// CALLER RESPONSIBILITY: this type is not wired into
// `Estate.defaultIdentityKeyStore(for:)` — that resolver's Keychain
// default for durable backends is untouched by this file. A DEBUG-only
// consumer that wants the promptless dev path must inject it
// explicitly:
//
//     #if DEBUG
//     let identityKeyStore = try FileEstateIdentityKeyStore(appSupportSubdirectory: "Fulcrum")
//     #else
//     let identityKeyStore: (any EstateIdentityKeyStore)? = nil // Keychain default
//     #endif
//     let estate = try await Estate.open(storage: storage, owner: owner,
//                                         identityKeyStore: identityKeyStore)
//
// ADAPTATION NOTE (upstreaming deviation from the fulcrum original): the
// consumer-side type hardcoded its Application Support subdirectory to
// the literal "Fulcrum". Landing in a shared kit consumed by more than
// one product, that literal is parameterized here
// (`appSupportSubdirectory`) so a second consumer app doesn't inherit a
// misleading path. This does not change the Perkins-reviewed security
// posture (DEBUG-only gate, 0600 file, 0700 directory, backup-excluded,
// per-estate-UUID filename) — only which folder name the caller chooses.

#if DEBUG

import Foundation

/// File-backed `EstateIdentityKeyStore` for DEBUG builds: one raw key file
/// per estate UUID, 0600 permissions, under
/// `Application Support/<AppSupportSubdirectory>/estate-identity-keys/`.
public struct FileEstateIdentityKeyStore: EstateIdentityKeyStore {

    /// Directory holding one `<estate-uuid>.key` file per estate.
    private let directory: URL

    /// Creates the store rooted at the default Application Support
    /// location. The directory is created lazily on first write.
    ///
    /// - Parameter appSupportSubdirectory: the consumer-owned folder name
    ///   under Application Support (e.g. an app's product name). Callers
    ///   from different apps sharing this DEBUG path on the same machine
    ///   must pass distinct values to avoid colliding on the same
    ///   `estate-identity-keys/` directory.
    public init(appSupportSubdirectory: String) throws {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        self.directory = base
            .appendingPathComponent(appSupportSubdirectory, isDirectory: true)
            .appendingPathComponent("estate-identity-keys", isDirectory: true)
    }

    private func keyURL(forEstateID estateID: UUID) -> URL {
        directory.appendingPathComponent("\(estateID.uuidString).key")
    }

    public func loadPrivateKey(forEstateID estateID: UUID) throws -> Data? {
        let url = keyURL(forEstateID: estateID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func storePrivateKey(_ keyData: Data, forEstateID estateID: UUID) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            // 0700 on the directory: owner-only traversal, matching the
            // 0600 files inside.
            attributes: [.posixPermissions: 0o700]
        )
        // Backup exclusion (Perkins hardening condition 1, carried forward
        // from the consumer-side review): key material must never ride
        // into Time Machine / backup tools — unlike Keychain items, plain
        // files carry no backup encryption of their own.
        var backupExcluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? backupExcluded.setResourceValues(values)
        let url = keyURL(forEstateID: estateID)
        try keyData.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

#endif
