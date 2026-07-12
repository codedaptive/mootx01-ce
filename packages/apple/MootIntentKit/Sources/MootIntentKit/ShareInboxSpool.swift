import Foundation

// MARK: - ShareInboxSpool  (A4b — the Share Extension ↔ host handoff)
//
// The Share Extension runs in its own process. One estate has one owning
// host (ADR-005), so the extension must never open the estate — instead it
// spools each shared item as a JSON file in the app-group container, and the
// HOST app drains the spool through CaptureSink using its live bridge
// (launch, foregrounding, and the mining tick are the drain moments).
//
// File protocol: one item per `<ISO-instant>-<uuid>.json` file, written
// atomically so the host never reads a half-written item. Filename ordering
// is drain ordering (oldest first). A file that fails to decode is moved to
// `quarantine/` — preserved for diagnosis, never retried, never fatal. A
// file whose CAPTURE fails (estate locked, substrate refusal) stays in the
// spool for the next drain.
//
// Why not QueueKit (validated 2026-07-11): QueueKit is the fleet's durable
// maildir queue and would otherwise be the reuse target, but its target
// hard-links PersistenceKit (SQLCipher) + IntellectusLib. This spool is
// linked into the Share Extension, which per ADR-005 must stay thin and must
// NOT carry the estate's storage/crypto stack. QueueKit's claim/reply/HLC/
// session model is also more than a one-way inbox needs. So this minimal,
// dependency-free atomic-file inbox is a deliberate app-specific choice, not
// an un-checked reinvention of QueueKit.

public struct ShareInboxSpool: Sendable {

    /// The spool directory. Files land here; `quarantine/` sits beneath it.
    public let directory: URL

    /// The app group both app targets and both Share Extension targets join.
    /// NOTE (submission gate): verify this identifier against the developer
    /// account before shipping — it mirrors project.yml's application-groups.
    public static let appGroupID = "group.com.codedaptive.mootx01"

    /// What one drain pass did: how many items were captured into the estate
    /// and how many remain spooled (capture failures awaiting retry).
    public struct DrainOutcome: Sendable, Equatable {
        public let captured: Int
        public let remaining: Int
    }

    /// Open (creating if needed) a spool rooted at an explicit directory.
    /// Tests use temp directories; production uses `groupSpool()`.
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The production spool in the app-group container. Fails explicitly
    /// (never a silent no-op) when the group container is unavailable —
    /// e.g. a build whose entitlements omit the group.
    public static func groupSpool() throws -> ShareInboxSpool {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID) else {
            throw SpoolError.groupContainerUnavailable(appGroupID)
        }
        return try ShareInboxSpool(
            directory: container.appendingPathComponent("ShareInbox", isDirectory: true))
    }

    public enum SpoolError: Error, CustomStringConvertible {
        case groupContainerUnavailable(String)

        public var description: String {
            switch self {
            case .groupContainerUnavailable(let group):
                return "App-group container \(group) is unavailable; the share spool cannot operate without it."
            }
        }
    }

    // MARK: extension side

    /// Spool one shared item. Called from the Share Extension process; must
    /// not touch the estate. Atomic write so a concurrent drain never sees a
    /// partial file.
    public func enqueue(_ item: CaptureSink.SharedItem) throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let url = directory.appendingPathComponent("\(stamp)-\(UUID().uuidString).json")
        let data = try JSONEncoder().encode(item)
        try data.write(to: url, options: .atomic)
    }

    // MARK: host side

    /// Drain every spooled item into the estate via CaptureSink, oldest
    /// first. Undecodable files are quarantined; failed captures stay put.
    public func drain(using caller: any MootToolCalling) async -> DrainOutcome {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let sink = CaptureSink()
        var captured = 0
        var remaining = 0
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let item = try? JSONDecoder().decode(CaptureSink.SharedItem.self, from: data) else {
                quarantine(file)
                continue
            }
            do {
                _ = try await sink.capture(item, using: caller)
                try? fm.removeItem(at: file)
                captured += 1
            } catch {
                // Estate unreachable or substrate refusal: leave the item
                // spooled so the next drain retries it.
                remaining += 1
            }
        }
        return DrainOutcome(captured: captured, remaining: remaining)
    }

    private func quarantine(_ file: URL) {
        let fm = FileManager.default
        let quarantineDir = directory.appendingPathComponent("quarantine", isDirectory: true)
        try? fm.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
        try? fm.moveItem(
            at: file,
            to: quarantineDir.appendingPathComponent(file.lastPathComponent))
    }
}
