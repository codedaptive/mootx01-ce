import Foundation
import QueueKit
import SubstrateTypes   // HLCGenerator

// MARK: - ShareInboxSpool  (A4b — the Share Extension ↔ host handoff)
//
// The Share Extension runs in its own process. One estate has one owning
// host (ADR-005), so the extension must never open the estate — instead it
// spools each shared item, and the HOST app drains the spool through
// CaptureSink using its live bridge (launch, foregrounding, and the mining
// tick are the drain moments).
//
// Durability is QueueKit's FilesystemBackend (a POSIX maildir: atomic
// write-then-rename, fsync, crash-recovery of stale tmp/ on open, oldest-
// first claim). This spool is a thin app-specific ADAPTER over it — the
// app-group container, the SharedItem payload, and the CaptureSink drain —
// NOT a re-rolled queue. QueueKit is safe in the Share Extension bundle: its
// weight is base PersistenceKit protocols + SubstrateTypes + IntellectusLib,
// none of which is SQLCipher and none of which can open the estate.
//
// Drain semantics via QueueKit: claim (drain) → capture → reply(.done). A
// payload that will not decode is retired as reply(.blocked) — preserved in
// the backend's done store for diagnosis, never retried. A capture that
// FAILS (estate locked, substrate refusal) is left in-flight and un-replied;
// the next drain reclaims it and retries.

public struct ShareInboxSpool: Sendable {

    /// The queue root directory (QueueKit owns the maildir layout beneath it).
    public let directory: URL

    /// The app group both app targets and both Share Extension targets join.
    /// NOTE (submission gate): verify this identifier against the developer
    /// account before shipping — it mirrors project.yml's application-groups.
    public static let appGroupID = "group.com.codedaptive.mootx01"

    /// One stream for the whole share inbox (a single ordered lane).
    private static let stream = StreamID(rawValue: "share-inbox")

    /// What one drain pass did: how many items were captured into the estate
    /// and how many remain spooled (capture failures awaiting retry).
    public struct DrainOutcome: Sendable, Equatable {
        public let captured: Int
        public let remaining: Int
    }

    // FilesystemBackend directly (not the QueueKit facade): the facade's
    // stream-scoped reclaimInFlight is a no-op for the FS backend, whereas the
    // backend's own no-arg reclaimInFlight() immediately returns every in-flight
    // ("cur/") item to claimable — which is exactly the per-drain retry the
    // share inbox wants (a capture that failed last drain re-drives this drain).
    private let backend: FilesystemBackend

    /// Open (creating if needed) a spool rooted at an explicit directory.
    /// Tests use temp directories; production uses `groupSpool()`.
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // nodeID 0: a single-device inbox needs monotonic-ish ordering, not
        // cross-node HLC uniqueness, which one generator provides.
        self.backend = try FilesystemBackend(root: directory, hlcGenerator: HLCGenerator(nodeID: 0))
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
    /// not touch the estate. QueueKit's write is atomic (write-then-rename),
    /// so a concurrent drain never claims a half-written item.
    public func enqueue(_ item: CaptureSink.SharedItem) async throws {
        let data = try JSONEncoder().encode(item)
        var hlc = HLCGenerator(nodeID: 0)
        let stamp = hlc.send(now: Int64(Date().timeIntervalSince1970 * 1000))
        let job = Job(id: .generate(), streamID: Self.stream, submittedAt: stamp, payload: data)
        try await backend.write(job)
    }

    // MARK: host side

    /// Drain every spooled item into the estate via CaptureSink, oldest
    /// first. Undecodable payloads are retired (.blocked, kept for diagnosis);
    /// captures that fail are left in-flight and retried on the next drain.
    public func drain(using caller: any MootToolCalling) async -> DrainOutcome {
        let sink = CaptureSink()
        var captured = 0
        var remaining = 0
        do {
            // Recover items left in-flight by a previous failed drain first.
            _ = try? await backend.reclaimInFlight()
            let claimed = try await backend.drainAvailable()
            for (job, _) in claimed {
                guard let item = try? JSONDecoder().decode(
                    CaptureSink.SharedItem.self, from: job.payload) else {
                    // Undecodable: retire it (kept in the backend's done store),
                    // never retried, never fatal.
                    try? await backend.complete(job.id, status: .blocked, artifacts: [])
                    continue
                }
                do {
                    _ = try await sink.capture(item, using: caller)
                    try await backend.complete(job.id, status: .done, artifacts: [])
                    captured += 1
                } catch {
                    // Estate unreachable / substrate refusal: leave it in-flight
                    // (un-replied) so the next drain reclaims and retries it.
                    remaining += 1
                }
            }
        } catch {
            // A drain/reclaim failure captures nothing this pass; items remain.
        }
        return DrainOutcome(captured: captured, remaining: remaining)
    }
}
