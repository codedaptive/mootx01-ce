import Foundation

/// A first-person record written by an agent. Diary entries are
/// the audit trail of what an agent thought, did, or learned at
/// a point in time. They are stored alongside drawers in the
/// MemPalace surface but are queried separately so that an
/// agent's diary can be read back chronologically.
///
/// `wing` defaults conventionally to `wing_<agentName>` and
/// `room` to `"diary"` (callers honour the convention; the
/// type does not enforce it). The wing-per-agent convention
/// exists so that one agent's diary cannot leak into another's
/// search results when wing filtering is applied.
///
/// `embeddingModelID` is present from Rev 1.0 for the same
/// reason as on `Drawer`: the modelID-tagging contract must be
/// enforceable from day one even though embeddings are not yet
/// generated.
///
/// `tombstonedAt` and `removedByBatch` are present from
/// Rev 1.0 so the schema does not need to migrate when the
/// soft-delete workflow lands.
public struct DiaryEntry: Equatable, Hashable, Codable, Sendable {

    /// Stable identifier supplied by the caller. Defaults to a
    /// fresh UUID string.
    public let id: String

    /// Name of the agent that wrote this entry.
    public let agentName: String

    /// The entry text. Verbatim, no transformation.
    public let entry: String

    /// Free-form topic tag. Used by callers to group entries by
    /// session, project, or theme; LocusKit does not validate.
    public let topic: String

    /// Wing this entry is filed under. Conventionally
    /// `wing_<agentName>`; not enforced here.
    public let wing: String

    /// Room within the wing. Conventionally `"diary"`; not
    /// enforced here.
    public let room: String

    /// When the entry was written. TEXT ISO8601 in SQLite.
    public let filedAt: Date

    /// Identifier of the embedding model that produced (or will
    /// produce) the vector for this entry. Present for the
    /// modelID-tagging contract; this mission does not generate
    /// embeddings.
    public let embeddingModelID: String

    /// When this entry was tombstoned, if it has been.
    /// Reserved for the Rev 2.0 soft-delete workflow.
    public let tombstonedAt: Date?

    /// Batch identifier used for receipt-based rollback of a
    /// tombstone. Reserved for the Rev 2.0 soft-delete workflow.
    public let removedByBatch: String?

    /// Operational bitmap encoding `DiaryEventClass` (bits 0–3),
    /// `DiarySeverity` (bits 4–6), `DiaryActorClass` (bits 7–9),
    /// `DiaryBatchMembership` (bits 10–12), and `requiresFollowup`
    /// (bit 13) per `GENIUSLOCUS_ARCHITECTURE_SPEC_v0.35.md` § 5.6.
    /// Bits 14–63 reserved. Defaults to 0 (capture / trace / user /
    /// standalone / informational). Decoded via the accessors on
    /// `DiaryOperational.swift`.
    public let operationalBitmap: Int64

    /// Designated initializer.
    public init(
        id: String = UUID().uuidString,
        agentName: String,
        entry: String,
        topic: String,
        wing: String,
        room: String,
        filedAt: Date,
        embeddingModelID: String,
        tombstonedAt: Date? = nil,
        removedByBatch: String? = nil,
        operationalBitmap: Int64 = 0
    ) {
        self.id = id
        self.agentName = agentName
        self.entry = entry
        self.topic = topic
        self.wing = wing
        self.room = room
        self.filedAt = filedAt
        self.embeddingModelID = embeddingModelID
        self.tombstonedAt = tombstonedAt
        self.removedByBatch = removedByBatch
        self.operationalBitmap = operationalBitmap
    }
}
