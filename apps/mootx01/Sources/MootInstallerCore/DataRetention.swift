// DataRetention.swift
//
// Data-retention policy for uninstall and reinstall: user data (the estate
// databases and the moot-mgr history store) is only ever removed behind an
// explicit typed-'yes' confirmation, and removal means MOVE TO THE TRASH,
// never hard deletion — the user keeps a recovery window until they empty
// it. Mirrors commands/uninstall.rs (decide_data_removal) and
// commands/install.rs (decide_existing_db) in the Rust vertical; both ports
// must present the same contract.
//
// The decision matrices are pure functions over flags + prompt closures so
// the safety contract is unit-testable without a TTY or a real Trash.

import Foundation

public enum DataRetention {

    // MARK: - Uninstall: remove-data decision

    /// What the uninstall data phase decided to do.
    public enum DataDecision: Equatable {
        /// Move the data directory to the Trash.
        case trash
        /// Leave the data in place; the payload is the printed reason.
        case leave(String)
        /// The user was asked to confirm destruction and did not type 'yes'.
        case aborted
    }

    /// Resolve the prompt/flag matrix for data removal on uninstall.
    ///
    /// - `purge`       — `--purge` (pre-selects removal).
    /// - `yes`         — `--yes` skips the typed confirmation, but ONLY when
    ///                   combined with `--purge`; `--yes` alone keeps the
    ///                   historical "never touches data" contract so existing
    ///                   automation is not surprised by data loss.
    /// - `interactive` — stdin is a terminal.
    /// - `offer`       — asks "remove data too?"; only reached interactively
    ///                   when `--purge` was not given.
    /// - `confirm`     — the typed-'yes' destruction gate.
    public static func decideDataRemoval(
        purge: Bool,
        yes: Bool,
        interactive: Bool,
        offer: () -> Bool,
        confirm: () -> Bool
    ) -> DataDecision {
        if !purge && !interactive {
            return .leave("estate data left in place (non-interactive; pass --purge to remove)")
        }
        if !purge && !offer() {
            return .leave("estate data left in place")
        }
        if purge && yes {
            return .trash
        }
        if !interactive {
            // --purge without --yes on a non-TTY: nobody can type the
            // confirmation. Refuse rather than destroy unconfirmed.
            return .leave("estate data left in place (--purge needs --yes when non-interactive)")
        }
        return confirm() ? .trash : .aborted
    }

    // MARK: - Install: existing-database decision

    /// Explicit disposition of a pre-existing estate database at install
    /// time (`--reuse-db` / `--replace-db`).
    public enum ExistingDbChoice: Equatable {
        case reuse
        case replace
    }

    /// What the reinstall phase decided.
    public enum DbDecision: Equatable {
        /// Proceed without touching anything (with the printed reason).
        case untouched(String)
        /// Adopt the existing database; reset the moot-mgr store.
        case reuse
        /// Trash the default estate + moot-mgr store for a fresh start.
        case replace
        /// The user was asked to confirm destruction and did not type 'yes'.
        case aborted
    }

    /// Resolve the flag/prompt matrix for an existing database on install.
    ///
    /// - `flag`        — explicit `--reuse-db` / `--replace-db`.
    /// - `yes`         — `--yes` answers the reuse-or-replace prompt with its
    ///                   default (reuse, non-destructive) instead of asking,
    ///                   and skips the typed destruction confirmation — but
    ///                   only when the choice itself was explicit
    ///                   (`--replace-db`). Under `--yes` with no explicit
    ///                   flag, replace is unreachable.
    /// - `interactive` — stdin is a terminal.
    /// - `choose`      — interactive reuse-or-replace prompt; true = replace.
    /// - `confirm`     — the typed-'yes' destruction gate for replace.
    public static func decideExistingDb(
        flag: ExistingDbChoice?,
        yes: Bool,
        interactive: Bool,
        choose: () -> Bool,
        confirm: () -> Bool
    ) -> DbDecision {
        // Was replace requested EXPLICITLY (--replace-db), or chosen at the
        // interactive prompt? `--yes` skips the typed destruction gate ONLY
        // for the explicit-flag automation path — a user who typed "replace"
        // at the prompt must still confirm, even under --yes.
        let explicitReplace = (flag == .replace)
        let replace: Bool
        switch flag {
        case .reuse:
            replace = false
        case .replace:
            replace = true
        case nil:
            guard interactive else {
                // No explicit choice and nobody to ask: leave everything as
                // it is. Existing automation (CI harnesses, scripted
                // installs) keeps its historical no-data-surprises contract.
                return .untouched(
                    "existing database left untouched (non-interactive; pass --reuse-db or --replace-db to choose)")
            }
            // `--yes` answers the prompt with its default: reuse. This keeps
            // wrappers that run `install --yes` with a terminal attached
            // (e.g. package-manager post-install hooks) from blocking on the
            // prompt, and it is non-destructive by construction — replace is
            // only reachable via the explicit --replace-db flag under --yes.
            if yes { return .reuse }
            replace = choose()
        }
        if !replace {
            return .reuse
        }
        // Explicit --replace-db + --yes is the only path that skips the typed
        // destruction confirmation. An interactively-chosen replace always
        // requires it, regardless of --yes.
        if yes && explicitReplace {
            return .replace
        }
        guard interactive else {
            return .untouched("existing database left untouched (--replace-db needs --yes when non-interactive)")
        }
        return confirm() ? .replace : .aborted
    }

    // MARK: - Filesystem inventory

    /// One-line inventory of what lives under the data directory, so the
    /// user knows what the confirmation destroys. `nil` when there is no
    /// user data worth prompting about. Mirrors `data_inventory` (Rust).
    public static func dataInventory(in dataDirectory: URL) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dataDirectory.path) else { return nil }
        let defaultEstate = defaultEstateExists(in: dataDirectory)
        let databasesDir = dataDirectory.appendingPathComponent("databases", isDirectory: true)
        let named = ((try? fm.contentsOfDirectory(atPath: databasesDir.path)) ?? [])
            .filter { name in
                guard name != "default" else { return false }
                var isDir: ObjCBool = false
                return fm.fileExists(
                    atPath: databasesDir.appendingPathComponent(name).path, isDirectory: &isDir)
                    && isDir.boolValue
            }
            .count
        let mgr = fm.fileExists(atPath: managerStoreDirectory(in: dataDirectory)
            .appendingPathComponent("stats.sqlite").path)
        guard defaultEstate || named > 0 || mgr else { return nil }
        var parts: [String] = []
        if defaultEstate { parts.append("the default estate database") }
        if named > 0 { parts.append("\(named) named estate(s)") }
        if mgr { parts.append("the moot-mgr history database") }
        return parts.joined(separator: ", ")
    }

    /// True when a default estate database already exists in the data
    /// directory, in either layout: the Swift flat `<data>/estate.sqlite`
    /// or the Rust `databases/default/estate.sqlite` (a migrated data
    /// directory). Mirrors `default_estate_exists` (Rust).
    public static func defaultEstateExists(in dataDirectory: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: MootPaths.estateURL(in: dataDirectory).path)
            || fm.fileExists(atPath: dataDirectory
                .appendingPathComponent("databases", isDirectory: true)
                .appendingPathComponent("default", isDirectory: true)
                .appendingPathComponent("estate.sqlite", isDirectory: false).path)
    }

    /// The moot-mgr history store directory (<data>/moot-mgr). The name is
    /// the manager's `ManagerConfig.storeSubdirectory` convention; the two
    /// binaries do not share a module, so the constant is mirrored here.
    public static func managerStoreDirectory(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("moot-mgr", isDirectory: true)
    }

    // MARK: - Removal actions

    /// The removal primitive: move `url` to the user's Trash. On macOS this
    /// is `FileManager.trashItem` (the shipped platform for the Swift
    /// vertical); elsewhere it falls back to `removeItem` so the Linux CI
    /// build of the Swift package stays functional. Injectable for tests so
    /// the suite never touches the real Trash.
    public typealias Mover = @Sendable (URL) throws -> Void

    public static let systemTrash: Mover = { url in
        #if os(macOS)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #else
        try FileManager.default.removeItem(at: url)
        #endif
    }

    /// Human name of the trash destination, for prompts and reports.
    public static var trashName: String {
        #if os(macOS)
        return "the macOS Trash"
        #else
        return "the system trash"
        #endif
    }

    /// Uninstall removal: the WHOLE data directory moves as one recoverable
    /// item (default estate + named estates + moot-mgr store + config).
    public static func trashDataDirectory(
        _ dataDirectory: URL, using move: Mover = systemTrash
    ) throws {
        try move(dataDirectory)
    }

    /// Reinstall 'reuse': the existing database stays THE default estate;
    /// the moot-mgr history store is trashed so the dashboard's estate
    /// registry rebuilds from what the daemon actually serves.
    public static func applyReuse(
        in dataDirectory: URL, using move: Mover = systemTrash
    ) throws {
        try DatabaseManager.setActiveEstate("default", in: dataDirectory)
        try trashManagerStore(in: dataDirectory, using: move)
    }

    /// Reinstall 'replace': the default estate files (both layouts) and the
    /// moot-mgr store move to the Trash; a fresh database is created on
    /// first serve. Named estates under databases/<name>/ are untouched —
    /// they are addressed by `mootx01 db`, not by the install flow.
    public static func applyReplace(
        in dataDirectory: URL, using move: Mover = systemTrash
    ) throws {
        let fm = FileManager.default
        // Flat layout: the SQLite file, its WAL/SHM sidecars, and the
        // derived vector / dreaming-queue siblings that carry estate content
        // (`estate.sqlite` → `estate.vectors.vec` / `estate.queue.sqlite`,
        //  see VectorStore.vectorsURL and EstateConfiguration.queueSibling).
        for name in [
            "estate.sqlite", "estate.sqlite-wal", "estate.sqlite-shm",
            "estate.vectors.vec",
            "estate.queue.sqlite", "estate.queue.sqlite-wal", "estate.queue.sqlite-shm",
            // The encryption opt-out marker describes the estate being replaced;
            // it dies with it. Leaving it behind would silently downgrade the
            // NEXT estate to plaintext despite the encrypted default the install
            // just advertised (stale-marker downgrade, Codex fe2cf887).
            EstateKeyProvider.encryptionOptOutMarkerName,
        ] {
            let url = dataDirectory.appendingPathComponent(name, isDirectory: false)
            if fm.fileExists(atPath: url.path) {
                try move(url)
            }
        }
        // Rust layout: the whole databases/default/ directory (SQLite,
        // sidecars, and the whole-file encryption key live together).
        let defaultDir = dataDirectory
            .appendingPathComponent("databases", isDirectory: true)
            .appendingPathComponent("default", isDirectory: true)
        if fm.fileExists(atPath: defaultDir.path) {
            try move(defaultDir)
        }
        try DatabaseManager.setActiveEstate("default", in: dataDirectory)
        try trashManagerStore(in: dataDirectory, using: move)
    }

    /// Move the moot-mgr history store to the Trash if present. The manager
    /// recreates an empty store on next start, so this is the "reset
    /// registration" primitive the reuse and replace branches share.
    private static func trashManagerStore(
        in dataDirectory: URL, using move: Mover
    ) throws {
        let mgr = managerStoreDirectory(in: dataDirectory)
        if FileManager.default.fileExists(atPath: mgr.path) {
            try move(mgr)
        }
    }
}
