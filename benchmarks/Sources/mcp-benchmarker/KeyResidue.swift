import Foundation
import CryptoKit
#if canImport(Security)
import Security
#endif

// KeyResidue.swift — zero-residual-key verification for scratch estate
// retirement (P1.1b, the operator's 2026-07-30 requirement: when a test estate is
// retired, its key material goes with it — no orphaned keys ever).
//
// WHAT CAN LEAVE KEY MATERIAL BEHIND
//   - The Swift product's DURABLE posture mints one Keychain generic-password
//     item per estate (service "com.codedaptive.mootx01", account
//     "estate-db-key." + SHA-256 hex of the standardized estate file path —
//     contract with KeychainKeyStore.estateAccount(for:) in
//     PersistenceKitSQLite and EstateKeyProvider.keychainService in
//     MootInstallerCore; replicated here the same way ScratchPosture.swift
//     replicates the transient-record plaintext rule).
//   - A `db.key` file INSIDE the estate's own directory. This is how the Rust
//     product keys every estate (PersistenceKit rust encryption.rs
//     INSTALL_KEY_FILE), and how a harness build of the Swift product keys a
//     database the matrix converted and must reopen. Under a scratch dir,
//     teardown of the dir removes it.
//
// The harness's run modes are designed to leave NOTHING: unencrypted writes
// the transient-record rule (no key exists), and encrypted keeps every key out of
// the Keychain — either a temporal key in the serve process's memory, or a key
// file that dies with the scratch directory. This verifier is
// the enforcement: every retirement probes for both residue kinds, PURGES any
// Keychain item found (the key is removed along with the estate), and reports
// loudly — a residue hit means the posture contract was violated upstream and
// the run's cleanliness claim would otherwise be false.

/// Keychain service every mootx01 surface uses for estate db keys.
/// MUST match `EstateKeyProvider.keychainService` (MootInstallerCore).
let mootKeychainService = "com.codedaptive.mootx01"

/// The per-estate Keychain account for an estate file path.
/// MUST match `KeychainKeyStore.estateAccount(for:)` (PersistenceKitSQLite):
/// standardized path → SHA-256 → hex, prefixed "estate-db-key.".
func estateDbKeyAccount(forEstatePath path: String) -> String {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
    let digest = SHA256.hash(data: Data(standardized.utf8))
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return "estate-db-key.\(hex)"
}

/// What a scratch dir could leave behind, collected BEFORE teardown (the
/// estate files must still exist to enumerate them).
struct KeyResidueProbes: Sendable, Equatable {
    /// Keychain accounts derived from every estate database file found under
    /// the scratch dir (Swift-product residue candidates).
    let keychainAccounts: [String]
    /// On-disk key files found under the scratch dir (Rust-product `db.key`
    /// convention). Recorded as paths so post-teardown absence can be asserted
    /// even if the whole-dir removal partially failed.
    let keyFilePaths: [String]
    /// The scratch dir itself.
    let scratchDirPath: String
    /// Login-keychain item count under the ESTATE IDENTITY service
    /// (`com.mootx01.estate.identity`) at probe time. Identity items are
    /// keyed by the estate's own UUID, which the harness never learns, so
    /// residue is detected by GROWTH across the estate's lifetime rather
    /// than by account. Growth means the product wrote a scratch estate's
    /// Ed25519 identity key into the real Keychain — the exact leak that
    /// accumulated 971 orphans by 2026-08-06 (fixed product-side the same
    /// day: ephemeral lifetime forces the in-memory identity store, and the
    /// unencrypted lane now declares ephemeral).
    let identityItemCountBefore: Int
}

/// Walks a scratch dir and records every residue candidate: one Keychain
/// account per estate database file (`*.sqlite` / `*.sqlite3`), plus every
/// on-disk `db.key`. Call BEFORE tearing the dir down. A missing dir yields
/// empty probes (nothing was created, nothing can linger).
///
/// - Precondition: `scratchDir` must be a harness-created temporary
///   directory. The Keychain purge in `verifyZeroKeyResidue` is
///   path-specific (accounts derive from SHA-256 of paths under this dir),
///   so probing a real estate's directory would target its real key.
func collectKeyResidueProbes(scratchDir: URL) -> KeyResidueProbes {
    var accounts: [String] = []
    var keyFiles: [String] = []
    let fm = FileManager.default
    if let walker = fm.enumerator(at: scratchDir, includingPropertiesForKeys: nil) {
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name.hasSuffix(".sqlite") || name.hasSuffix(".sqlite3") {
                accounts.append(estateDbKeyAccount(forEstatePath: url.path))
            }
            if name == "db.key" {
                keyFiles.append(url.path)
            }
        }
    }
    // The default estate path is probed even when the walk found no estate
    // file (e.g. a run that died before first write): a Keychain item keyed to
    // the path that WOULD have been created is still residue worth checking.
    let defaultEstate = scratchDir.appendingPathComponent("estate.sqlite").path
    let defaultAccount = estateDbKeyAccount(forEstatePath: defaultEstate)
    if !accounts.contains(defaultAccount) {
        accounts.append(defaultAccount)
    }
    return KeyResidueProbes(
        keychainAccounts: accounts.sorted(),
        keyFilePaths: keyFiles.sorted(),
        scratchDirPath: scratchDir.path,
        identityItemCountBefore: mootIdentityItemCount())
}

/// The outcome of a zero-residual verification.
struct KeyResidueReport: Sendable, Equatable {
    /// Keychain accounts that still held an item after retirement. Every entry
    /// here was PURGED by the verifier (the key is removed along with the
    /// estate); a non-empty list still marks the run as having violated the
    /// zero-residue contract upstream.
    var keychainItemsFoundAndPurged: [String] = []
    /// Keychain accounts whose item could not be removed (purge failed).
    var keychainItemsUnremovable: [String] = []
    /// On-disk key files still present after teardown.
    var keyFilesRemaining: [String] = []
    /// True when the scratch dir itself survived teardown.
    var scratchDirRemaining = false
    /// How many estate-identity Keychain items appeared during this estate's
    /// lifetime (growth over the probe-time count). Non-purgeable — identity
    /// items are keyed by the estate's own UUID, which the harness never
    /// learns — so a non-zero value is a loud product-fix regression signal,
    /// not a cleanup action.
    var identityItemsGrownBy = 0
    /// Estate database files that were expected plaintext but carry an
    /// encrypted header — the at-rest posture silently flipped (a product
    /// binary that predates the ephemeral+marker fix): the cell would be
    /// MISLABELED as unencrypted.
    var postureViolations: [String] = []

    /// Zero residual key material: nothing found, nothing left behind.
    var isClean: Bool {
        keychainItemsFoundAndPurged.isEmpty
            && keychainItemsUnremovable.isEmpty
            && keyFilesRemaining.isEmpty
            && !scratchDirRemaining
            && identityItemsGrownBy == 0
            && postureViolations.isEmpty
    }
}

/// Keychain service every mootx01 surface uses for estate Ed25519 identity
/// keys. MUST match `EstateIdentityKeyStore.service` in LocusKit.
let mootIdentityKeychainService = "com.mootx01.estate.identity"

/// Counts login-keychain items under the estate-identity service. 0 when
/// Security is unavailable or the query fails — the growth check then
/// degrades to a no-op rather than a false alarm.
func mootIdentityItemCount() -> Int {
    #if canImport(Security)
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: mootIdentityKeychainService,
        kSecMatchLimit as String: kSecMatchLimitAll,
        kSecReturnAttributes as String: true,
    ]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
          let items = result as? [[String: Any]] else { return 0 }
    return items.count
    #else
    return 0
    #endif
}

#if canImport(Security)
/// True when a generic-password item exists for the moot service + account.
func keychainItemExists(account: String) -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: mootKeychainService,
        kSecAttrAccount as String: account,
        kSecReturnAttributes as String: false,
    ]
    return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
}

/// Deletes the generic-password item for the moot service + account.
/// Returns true when the item is gone afterwards (deleted, or never existed).
@discardableResult
func deleteKeychainItem(account: String) -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: mootKeychainService,
        kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
}
#endif

/// Verifies zero residual key material AFTER a scratch dir teardown, purging
/// any Keychain item it finds (requirement: the key is removed along with the
/// estate). Pure inspection plus purge — never throws; the caller decides how
/// loud to be from the report.
func verifyZeroKeyResidue(after probes: KeyResidueProbes) -> KeyResidueReport {
    var report = KeyResidueReport()
    let fm = FileManager.default
    report.scratchDirRemaining = fm.fileExists(atPath: probes.scratchDirPath)
    for keyFile in probes.keyFilePaths where fm.fileExists(atPath: keyFile) {
        report.keyFilesRemaining.append(keyFile)
    }
    #if canImport(Security)
    for account in probes.keychainAccounts where keychainItemExists(account: account) {
        if deleteKeychainItem(account: account), !keychainItemExists(account: account) {
            report.keychainItemsFoundAndPurged.append(account)
        } else {
            report.keychainItemsUnremovable.append(account)
        }
    }
    // Identity-item growth check: see KeyResidueProbes.identityItemCountBefore.
    report.identityItemsGrownBy =
        max(0, mootIdentityItemCount() - probes.identityItemCountBefore)
    #endif
    return report
}

/// Reports a scratch estate deliberately KEPT because its scope did not finish
/// cleanly, naming the path so the work can be inspected, salvaged, or removed
/// by hand.
///
/// Retirement is for a scope that SUCCEEDED. A scope that threw leaves whatever
/// it built where it lies. On 2026-08-17 an unconditional teardown deleted a
/// finished 100,000-row landscape because the call that would have returned it
/// was slow: 100 minutes of built and encoded work, destroyed by the error path
/// of the thing that had already done the work. Disk is cheap and a rebuild is
/// not, so an error keeps its evidence and the operator decides what happens
/// to it.
///
/// For an encrypted scratch estate this leaves key material on disk, which is
/// the deliberate trade: the run has already failed, and a kept estate under a
/// loud notice beats silently destroying hours of work.
func keepScratchEstateOnFailure(_ scratchDir: URL, lane: String) {
    // Mark the kept scratch with a `.kept` suffix so it is distinguishable
    // from ACTIVE scratches of concurrently running lanes (which share the
    // /tmp prefix); the pruning below must never touch a live scratch.
    let fm = FileManager.default
    var kept = scratchDir
    let marked = URL(fileURLWithPath: scratchDir.path + ".kept")
    if (try? fm.moveItem(at: scratchDir, to: marked)) != nil { kept = marked }
    FileHandle.standardError.write(Data(
        ("[\(lane)] scope did not finish cleanly — scratch estate KEPT at \(kept.path)\n"
         + "[\(lane)] it holds everything built up to the failure; remove it by hand "
         + "when you are done with it\n").utf8))

    // Cap the kept population. The keep-the-evidence rationale above
    // protects RECENT failures; a hundred identical transient-failure
    // scratches carry no additional evidence, and 181 accumulated keeps
    // produced a 61 GB disk crisis on 2026-08-26. Keep the newest 5 `.kept`
    // dirs sharing this scratch's family prefix (path up to the random
    // suffix); announce every prune so nothing disappears silently.
    let familyPrefix = kept.deletingLastPathComponent().path + "/"
        + kept.lastPathComponent.split(separator: "-").dropLast().joined(separator: "-") + "-"
    let parent = kept.deletingLastPathComponent()
    guard let siblings = try? fm.contentsOfDirectory(
        at: parent, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    let keptFamily = siblings.filter {
        $0.path.hasPrefix(familyPrefix) && $0.path.hasSuffix(".kept")
    }.sorted { a, b in
        let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return da > db
    }
    for old in keptFamily.dropFirst(5) {
        try? fm.removeItem(at: old)
        FileHandle.standardError.write(Data(
            ("[\(lane)] pruned old kept scratch (cap 5): \(old.path)\n").utf8))
    }
}

/// Retires one scratch estate: collect residue probes, run the guarded
/// teardown the caller supplies, then verify + purge. A dirty report is
/// shouted to stderr with every finding named — a residue hit means the
/// posture contract was violated upstream, and silence would let a run claim
/// cleanliness it does not have.
///
/// - Precondition: `scratchDir` must be a harness-created temporary
///   directory (see `collectKeyResidueProbes`).
func retireScratchEstate(
    _ scratchDir: URL,
    expectPlaintext: Bool = false,
    teardown: (URL) throws -> Void
) rethrows {
    let probes = collectKeyResidueProbes(scratchDir: scratchDir)

    // Posture check runs PRE-teardown (the files must still exist). A
    // plaintext SQLite file begins with the 16-byte magic "SQLite format 3\0";
    // an SQLCipher-encrypted file does not. `expectPlaintext` comes from the
    // lane's declared posture — a mismatch means the product silently flipped
    // the at-rest posture (e.g. a binary that predates the ephemeral+marker
    // fix) and the cell would be mislabeled as unencrypted.
    var postureViolations: [String] = []
    if expectPlaintext {
        let magic = Data("SQLite format 3".utf8) + Data([0])
        let fm = FileManager.default
        if let walker = fm.enumerator(at: scratchDir, includingPropertiesForKeys: nil) {
            for case let url as URL in walker
            where url.lastPathComponent.hasSuffix(".sqlite")
                || url.lastPathComponent.hasSuffix(".sqlite3") {
                if let handle = try? FileHandle(forReadingFrom: url),
                   let head = try? handle.read(upToCount: magic.count),
                   head != magic {
                    postureViolations.append(url.path)
                }
            }
        }
    }

    // Instrument seam (W2.5 Track R(c)): copy the working estate out for
    // the optimizer's trace aggregation BEFORE teardown destroys it. No-op
    // unless MOOT_BENCH_KEEP_ESTATES_DIR is set; retirement's residue
    // verification below still runs on the scratch itself.
    keepEstateSeam(from: scratchDir)

    try teardown(scratchDir)
    var report = verifyZeroKeyResidue(after: probes)
    report.postureViolations = postureViolations
    guard !report.isClean else { return }
    var lines = ["[key-residue] RESIDUAL KEY MATERIAL at retirement of \(scratchDir.path):"]
    for a in report.keychainItemsFoundAndPurged {
        lines.append("  keychain item FOUND (now purged): service=\(mootKeychainService) account=\(a)")
    }
    for a in report.keychainItemsUnremovable {
        lines.append("  keychain item FOUND and NOT REMOVABLE: service=\(mootKeychainService) account=\(a)")
    }
    for f in report.keyFilesRemaining {
        lines.append("  key file still on disk: \(f)")
    }
    if report.scratchDirRemaining {
        lines.append("  scratch dir still present: \(probes.scratchDirPath)")
    }
    if report.identityItemsGrownBy > 0 {
        lines.append("  estate-identity keychain items GREW by \(report.identityItemsGrownBy) "
            + "(service=\(mootIdentityKeychainService)) — the product wrote a scratch estate's "
            + "identity key to the real Keychain; requires a product binary at or after the "
            + "2026-08-06 ephemeral-identity fix. NOT purgeable by account from here.")
    }
    for p in report.postureViolations {
        lines.append("  POSTURE FLIP: expected plaintext but encrypted header at \(p) "
            + "— the cell is mislabeled; a transient record (--db <scratch>) must be "
            + "created plaintext by the product.")
    }
    lines.append("  zero-residue contract violated — investigate the run's estate mode plumbing.")
    FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
}
