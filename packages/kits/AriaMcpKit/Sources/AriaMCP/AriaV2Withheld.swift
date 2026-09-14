import GeniusLocusKit
import LocusKit

/// One dispatch's opt-in and count. Task-local ownership prevents session bleed
/// and keeps concurrently suspended Swift calls independent.
actor AriaV2WithheldCall {
    var enabled = false
    var count: Int?
    func configure(_ value: JSONValue?) { enabled = value == .bool(true) }
    func record(_ value: Int) { if enabled { count = value } }
}

enum AriaV2Withheld {
    @TaskLocal static var call: AriaV2WithheldCall?

    static var enabled: Bool { get async { await call?.enabled ?? false } }
    static func record(_ count: Int) async { await call?.record(count) }

    /// A public GLK read over the recipe's real frame. Locus owns counting;
    /// locusOnly/internal with no trace limit performs no reward/usage writes.
    static func recall(kit: GeniusLocusKit, handle: EstateHandle, frame: LocusKit.RecallFrame) async throws {
        guard await enabled else { return }
        let result = try await kit.recall(handle, GLKRecallRequest(
            frame: frame, mode: .locusOnly, scoring: .raw,
            limit: frame.limit ?? 50, fallback: .allowDegraded,
            traceLimit: nil, origin: .internal, subSpanScoring: .off))
        await record(result.withheldBySensitivity)
    }

    static func egress(_ result: JSONValue) async -> JSONValue {
        guard await enabled, let count = await call?.count,
              var root = result.objectValue, root["isError"] != .bool(true),
              var envelope = root["structuredContent"]?.objectValue,
              var meta = envelope["meta"]?.objectValue else { return result }
        meta["withheldBySensitivity"] = .integer(Int64(count))
        envelope["meta"] = .object(meta)
        root["structuredContent"] = .object(envelope)
        return .object(root)
    }
}
