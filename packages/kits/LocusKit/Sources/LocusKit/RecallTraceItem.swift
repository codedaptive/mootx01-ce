import Foundation

/// A record of one row returned by a recall operation.
///
/// RecallTraceItem is the "later two-source reward" hook from
/// NEURONKIT_SPEC §3.1: when a recall returns a drawer, the substrate
/// records a trace row so the reward signal can later distinguish rows
/// the user acted on (used=true) from rows returned but ignored
/// (used=false). Bradley-Terry (cookbook §8.12) consumes this
/// distinction when computing tournament weights.
///
/// The `used` flag is carried as bit 0 of `operationalBitmap` so no
/// Bool stored property appears on the struct (schema invariant per
/// CLAUDE.md). The accessor computed property follows the canonical
/// bitmap-patterns pattern.
///
/// ## Bitmap reservation for RecallTraceItem.operationalBitmap
///
///   bit 0   used          ASSIGNED — true when the recalled row was
///                         subsequently acted on by the reward path.
///   bits 1–63  FREE (63 bits headroom).
public struct RecallTraceItem: Equatable, Hashable, Codable, Sendable {

    // MARK: - Bitmap constants

    /// Bit 0 of operationalBitmap: the row was consumed by the two-source
    /// reward path. NEURONKIT_SPEC §3.1 tick-sequence note:
    /// "RecallTraceItem rows where used == true".
    public static let flagUsed: Int64 = 1 << 0   // bit 0

    // MARK: - Fields

    /// Stable identifier for this trace row. Defaults to a fresh UUID
    /// string, matching the DiaryEntry pattern.
    public let id: String

    /// The recalled drawer's identifier. This is the row the recall
    /// returned; the reward path looks up this id when it fires.
    public let target: String

    /// When the recall that produced this row was executed. TEXT ISO8601
    /// in SQLite (fleet date-storage rule).
    public let recalledAt: Date

    /// Similarity score assigned by the recall, if available. `nil`
    /// means the recall did not produce a score for this row (e.g.
    /// ordered-by-capture-time queries). Stored as REAL when non-nil.
    public let score: Double?

    /// Operational bitmap. Bit 0 = used. Bits 1–63 reserved.
    /// Defaults to 0 (unused).
    public let operationalBitmap: Int64

    // MARK: - Computed Bool accessor (bitmap-backed, never stored)

    /// True when the two-source reward path has consumed this trace row.
    /// Backed by bit 0 of operationalBitmap; there is no stored Bool
    /// property on this struct.
    public var used: Bool {
        operationalBitmap & RecallTraceItem.flagUsed != 0
    }

    // MARK: - Initializer

    /// Designated initializer.
    public init(
        id: String = UUID().uuidString,
        target: String,
        recalledAt: Date,
        score: Double? = nil,
        operationalBitmap: Int64 = 0
    ) {
        self.id = id
        self.target = target
        self.recalledAt = recalledAt
        self.score = score
        self.operationalBitmap = operationalBitmap
    }
}
