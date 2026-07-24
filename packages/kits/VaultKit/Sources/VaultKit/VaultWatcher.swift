import Foundation
import OSLog

// VaultWatcher.swift
//
// A lightweight directory watcher for the Obsidian vault. Uses a polling
// loop rather than the FSEvents C API so the implementation is cross-platform
// (macOS and Linux). The poll interval governs maximum detection latency;
// 10 seconds is the default (configurable per MOOTX01_VAULT_POLL_INTERVAL_S).
//
// "Debounce" is achieved by collecting all changed paths within each poll
// interval and delivering them in a single batch callback. Multiple rapid
// file events (e.g. Obsidian saving frontmatter then body) collapse into
// one reconcile call.
//
// The watcher tracks modification dates of every .md file in the vault
// directory tree and fires the callback when any date changes or a file
// appears/disappears. Hidden files and non-.md files are ignored.

/// A polling vault-directory watcher.
///
/// Call `start(onChange:)` to begin watching. The `onChange` closure
/// receives a set of vault-relative paths (e.g. `"Projects/Sprint.md"`)
/// for every file whose modification date changed since the last poll.
/// An empty set is never delivered.
///
/// Vault deletions appear as paths whose last-known modification date no
/// longer exists on disk — the closure receives them with a `nil`-date
/// marker via the `deletedPaths` companion set. The service decides what
/// to do with them (report-not-erase policy).
public actor VaultWatcher {

    private static let log = Logger(subsystem: "com.mootx01.kit", category: "VaultWatcher")

    /// The vault root directory being watched.
    public let vaultURL: URL

    /// Poll interval in seconds (default 10). Set via MOOTX01_VAULT_POLL_INTERVAL_S.
    public let pollIntervalSeconds: Int

    // Last-seen modification dates, keyed by vault-relative path.
    private var lastSeen: [String: Date] = [:]
    private var watchTask: Task<Void, Never>?

    public init(vaultURL: URL, pollIntervalSeconds: Int = 10) {
        self.vaultURL = vaultURL
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    // MARK: - Lifecycle

    /// Start polling. `onChange` is called on each poll that detects changes.
    ///
    /// - Parameters:
    ///   - onChange: Async closure receiving changed vault-relative paths and
    ///     deleted vault-relative paths detected in this poll cycle.
    public func start(onChange: @Sendable @escaping ([String], [String]) async -> Void) {
        guard watchTask == nil else { return }
        // Seed initial snapshot without firing callback.
        lastSeen = currentSnapshot()
        let intervalNs = UInt64(pollIntervalSeconds) * 1_000_000_000
        let vaultURL = self.vaultURL
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: intervalNs) } catch { break }
                guard let self else { break }
                let (changed, deleted) = await self.poll()
                if !changed.isEmpty || !deleted.isEmpty {
                    Self.log.info("VaultWatcher: \(changed.count) changed, \(deleted.count) deleted in \(vaultURL.lastPathComponent, privacy: .public)")
                    await onChange(changed, deleted)
                }
            }
        }
    }

    /// Stop polling and cancel the watch task.
    public func stop() {
        watchTask?.cancel()
        watchTask = nil
    }

    // MARK: - Poll

    /// Compare the current snapshot to `lastSeen`, update state, return deltas.
    private func poll() -> ([String], [String]) {
        let current = currentSnapshot()
        var changed: [String] = []
        var deleted: [String] = []

        // Changed or new files.
        for (path, date) in current {
            if let prev = lastSeen[path] {
                if date != prev { changed.append(path) }
            } else {
                changed.append(path)  // new file
            }
        }
        // Deleted files (present in lastSeen, absent in current).
        for path in lastSeen.keys where current[path] == nil {
            deleted.append(path)
        }
        lastSeen = current
        return (changed, deleted)
    }

    // MARK: - Snapshot

    /// Walk the vault directory and collect all .md file modification dates,
    /// keyed by vault-relative path. Hidden files and non-.md files are ignored.
    private func currentSnapshot() -> [String: Date] {
        var snapshot: [String: Date] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: vaultURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return snapshot }

        for case let url as URL in enumerator {
            guard url.pathExtension == "md" else { continue }
            let rel = url.path.hasPrefix(vaultURL.path + "/")
                ? String(url.path.dropFirst(vaultURL.path.count + 1))
                : url.lastPathComponent
            let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            snapshot[rel] = mod ?? Date.distantPast
        }
        return snapshot
    }
}
