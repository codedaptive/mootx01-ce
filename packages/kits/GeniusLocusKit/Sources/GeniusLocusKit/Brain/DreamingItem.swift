// DreamingItem.swift — the dreaming-queue job payload.
//
// Each recall that surfaces ≥ 2 distinct drawers enqueues one DreamingItem
// onto the estate's shared queue.sqlite under stream_id = "dreaming". The item
// groups the co-recalled drawer set so the REM-ALPHA drainer (T9+) can form
// co-recall pairs without re-reading recall_trace.
//
// Field names are intentionally kept identical between Swift (Codable) and Rust
// (serde) so the JSON payload round-trips identically across ports — the dreaming
// drainer reads the payload it finds on disk; both ports must agree on the schema.
//
// This payload is drained by REM-ALPHA (T9). No drain loop or DrainLease is added
// here — T6 is enqueue-only; the lease is a drainer concern added in T9.

import Foundation

/// The payload carried by a `"dreaming"` stream job.
///
/// One item is enqueued per external recall that surfaces ≥ 2 distinct drawers.
/// `recallEventId` groups the co-recalled set (Decision 3): the drainer unions
/// all drawer sets from a drain window to form co-recall pairs. `drawerIds` lists
/// the surfaced drawer ids in result order (deterministic, same order as the recall
/// return value).
///
/// Codable: encoded as JSON and stored in `Job.payload`. Field keys are camelCase
/// in the JSON (`recall_event_id`, `drawer_ids`) because CodingKeys maps them
/// explicitly — matching the Rust serde `snake_case` rename_all so payloads are
/// cross-port legible.
public struct DreamingItem: Codable, Sendable {

    /// A fresh id generated once per recall event. Groups the co-recalled set
    /// in the drainer's union pass; not used for deduplication. Same id-shape as
    /// `JobID` (32-character lowercase hex UUID, no hyphens) per the queue convention.
    public let recallEventId: String

    /// Surfaced drawer ids from the recall result, in result order. The drainer
    /// reads these to form co-recall pairs (Decision 1). Count is always ≥ 2
    /// (the ≥ 2 guard is enforced at enqueue time by `enqueueDreamingItem`).
    public let drawerIds: [String]

    enum CodingKeys: String, CodingKey {
        case recallEventId = "recall_event_id"
        case drawerIds = "drawer_ids"
    }
}
