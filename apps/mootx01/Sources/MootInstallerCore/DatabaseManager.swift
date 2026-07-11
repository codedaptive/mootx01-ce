// DatabaseManager.swift
//
// Named estate lifecycle: create, list, open, delete.
// Active estate name is persisted in config.json under the data directory.
//
// Layout:
//   ~/Library/Application Support/MOOTx01/estate.sqlite        — default estate (legacy flat path)
//   ~/Library/Application Support/MOOTx01/databases/<n>/estate.sqlite — named estates
//   ~/Library/Application Support/MOOTx01/config.json           — active estate name

import Foundation

/// Manages named estate database files and the active-estate pointer.
public enum DatabaseManager {

    // MARK: - Estate URL resolution

    /// URL for the estate database file of a named estate.
    ///
    /// The "default" estate uses the legacy flat path so existing client
    /// configs that pre-date the unified CLI binary still find their data.
    /// All other names get a dedicated subdirectory under `databases/`.
    ///
    /// - Parameters:
    ///   - name: estate name. "default" → legacy flat path; anything else → subdirectory.
    ///   - dataDirectory: resolved data directory (see `MootPaths.resolveDataDirectory`).
    /// - Returns: URL to `estate.sqlite`. Does not touch the filesystem.
    /// - Important: the name is validated before use. `Foundation.URL.appendingPathComponent`
    ///   appends the string literally; a name containing `..` or `/` would produce a
    ///   URL whose resolved filesystem path escapes `databases/`. Callers should
    ///   validate via `createEstate(name:in:)` or guard against `.` / `..` / slashes
    ///   before invoking this helper directly.
    public static func estateURL(for name: String, in dataDirectory: URL) -> URL {
        if name == "default" {
            return MootPaths.estateURL(in: dataDirectory)
        }
        // Sanitise: reject any name component that could traverse out of databases/.
        // Foundation appends the raw string, so "../evil" would produce a path
        // whose standardized form escapes the intended subtree.
        guard isValidEstateName(name) else {
            // Return a deliberately invalid sentinel inside the data directory;
            // callers that bypass createEstate (which validates) will hit a
            // non-existent path rather than an arbitrary location.
            return dataDirectory
                .appendingPathComponent("databases", isDirectory: true)
                .appendingPathComponent(".invalid", isDirectory: true)
                .appendingPathComponent("estate.sqlite", isDirectory: false)
        }
        return dataDirectory
            .appendingPathComponent("databases", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("estate.sqlite", isDirectory: false)
    }

    /// Returns true iff `name` is a safe single-component estate name: non-empty,
    /// not `.` or `..`, and contains no path separators. Mirrors the Rust `valid_name`
    /// predicate in `commands/db.rs` — both ports must agree.
    public static func isValidEstateName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
    }

    // MARK: - Config (active estate pointer)

    private static let configFileName = "config.json"

    private static func configURL(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(configFileName, isDirectory: false)
    }

    /// Read the name of the currently active estate from config.json.
    /// Returns "default" when the config file is absent or the key is missing.
    ///
    /// - Parameter dataDirectory: resolved data directory.
    /// - Returns: active estate name. Never empty.
    /// - Throws: `MOOTx01DatabaseError` if the config file exists but is malformed.
    public static func activeEstateName(in dataDirectory: URL) throws -> String {
        let url = configURL(in: dataDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return "default" }
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["activeEstate"] as? String,
              !name.isEmpty else {
            return "default"
        }
        return name
    }

    /// Persist the active estate name to config.json.
    ///
    /// Creates the data directory if it doesn't exist. Writes atomically.
    ///
    /// - Parameters:
    ///   - name: estate name to set as active.
    ///   - dataDirectory: resolved data directory.
    /// - Throws: filesystem or JSON serialization errors.
    public static func setActiveEstate(_ name: String, in dataDirectory: URL) throws {
        try FileManager.default.createDirectory(
            at: dataDirectory, withIntermediateDirectories: true
        )
        let payload: [String: Any] = ["activeEstate": name]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: configURL(in: dataDirectory), options: .atomic)
    }

    // MARK: - CRUD

    /// Create a named estate directory structure. Does not initialise the
    /// SQLite schema — the substrate does that on first `serve` open.
    ///
    /// After creation the estate is immediately discoverable by `listEstates`
    /// and `db open`, which both test for the estate directory rather than the
    /// SQLite file (the file is written lazily by the substrate on first serve).
    ///
    /// - Parameters:
    ///   - name: must be a valid directory-name component (no slashes).
    ///   - dataDirectory: resolved data directory.
    /// - Throws: `MOOTx01DatabaseError.alreadyExists` if the estate directory
    ///   already exists, or filesystem errors.
    public static func createEstate(name: String, in dataDirectory: URL) throws {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else {
            throw MOOTx01DatabaseError.invalidName(name)
        }
        let url = estateURL(for: name, in: dataDirectory)
        let dir = url.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: dir.path) else {
            throw MOOTx01DatabaseError.alreadyExists(name)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// List all known estate names, including "default" when the legacy
    /// estate file is present.
    ///
    /// Named estates are detected by the presence of the estate DIRECTORY
    /// (`databases/<name>/`), not the SQLite file inside it. The SQLite file
    /// is written lazily by the substrate on first `serve`, so testing for the
    /// directory is the correct existence check — consistent with `createEstate`
    /// (which creates the directory) and `db open` (which checks the directory).
    ///
    /// - Parameter dataDirectory: resolved data directory.
    /// - Returns: sorted list of estate names. Never nil; may be empty.
    public static func listEstates(in dataDirectory: URL) -> [String] {
        var names: [String] = []

        // Default estate: flat path — present when serve has been run at least once.
        if FileManager.default.fileExists(
            atPath: MootPaths.estateURL(in: dataDirectory).path
        ) {
            names.append("default")
        }

        // Named estates: any subdirectory under databases/ is a registered estate.
        // The SQLite file does not need to exist yet — it is created on first serve.
        let databasesDir = dataDirectory.appendingPathComponent("databases", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: databasesDir.path) {
            var isDir: ObjCBool = false
            let valid = entries.filter { name in
                let entryPath = databasesDir.appendingPathComponent(name).path
                return FileManager.default.fileExists(atPath: entryPath, isDirectory: &isDir)
                    && isDir.boolValue
            }
            names.append(contentsOf: valid.sorted())
        }

        return names
    }

    /// Delete a named estate and its database files.
    ///
    /// Refuses to delete the default estate — pass `--purge` to the
    /// `mootx01 uninstall` command to trigger a full wipe.
    ///
    /// - Parameters:
    ///   - name: estate to delete. Must not be "default".
    ///   - dataDirectory: resolved data directory.
    /// - Throws: `MOOTx01DatabaseError.notFound` if the estate doesn't exist,
    ///   `MOOTx01DatabaseError.deleteDefault` if name is "default", or
    ///   filesystem errors.
    public static func deleteEstate(name: String, in dataDirectory: URL) throws {
        guard name != "default" else {
            throw MOOTx01DatabaseError.deleteDefault
        }
        // Validate before resolving the path: `estateURL(for:in:)` appends the
        // name literally via Foundation, so a traversal like "../private" would
        // compute a path outside the databases/ subtree and `removeItem` could
        // delete an arbitrary directory. The validation here mirrors the guard
        // already present in `createEstate` and the Rust `valid_name` predicate.
        guard isValidEstateName(name) else {
            throw MOOTx01DatabaseError.invalidName(name)
        }
        let dir = estateURL(for: name, in: dataDirectory).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: dir.path) else {
            throw MOOTx01DatabaseError.notFound(name)
        }
        // Data retention (#47): platform-appropriate removal so the user
        // has a recovery window on desktop OSes.
        //   macOS  → NSFileManager.trashItem (moves to Trash)
        //   Linux  → zero all regular files, then removeItem (no Trash)
        //   Windows → handled by the Rust port (Recycle Bin via SHFileOperation)
        #if os(macOS)
        try FileManager.default.trashItem(at: dir, resultingItemURL: nil)
        #elseif os(Linux)
        // Zero all regular files in the estate directory before deletion
        // so content is not recoverable from the raw filesystem.
        if let enumerator = FileManager.default.enumerator(atPath: dir.path) {
            while let file = enumerator.nextObject() as? String {
                let fileURL = dir.appendingPathComponent(file)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir),
                   !isDir.boolValue {
                    if let handle = try? FileHandle(forWritingTo: fileURL) {
                        let size = handle.seekToEndOfFile()
                        handle.seek(toFileOffset: 0)
                        handle.write(Data(count: Int(size)))
                        handle.closeFile()
                    }
                }
            }
        }
        try FileManager.default.removeItem(at: dir)
        #else
        try FileManager.default.removeItem(at: dir)
        #endif
    }

}

// MARK: - Error types

/// Errors from DatabaseManager operations.
public enum MOOTx01DatabaseError: Error, CustomStringConvertible {
    case alreadyExists(String)
    case notFound(String)
    case invalidName(String)
    /// Attempted to delete the default estate directly; use purge.
    case deleteDefault

    public var description: String {
        switch self {
        case .alreadyExists(let n): return "estate '\(n)' already exists"
        case .notFound(let n):     return "estate '\(n)' not found"
        case .invalidName(let n):  return "'\(n)' is not a valid estate name"
        case .deleteDefault:       return "cannot delete the default estate; use --purge"
        }
    }
}
