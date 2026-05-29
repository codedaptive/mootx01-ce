import Foundation

/// Aggregate count for a single wing — produced by `listWings`.
///
/// Wings and rooms are metadata-only strings on drawer rows, not
/// first-class tables. `WingSummary` and `RoomSummary` are
/// computed projections built by `SELECT ... GROUP BY` at query
/// time, mirroring MemPalace's `tool_list_wings` behavior. Their
/// counts therefore reflect whatever is currently in the store
/// rather than a separately maintained registry.
public struct WingSummary: Equatable, Hashable, Codable, Sendable {

    /// The wing name, as it appears on drawer rows.
    public let name: String

    /// Number of non-tombstoned drawers in this wing.
    public let drawerCount: Int

    /// Number of distinct room names found inside this wing,
    /// counting only non-tombstoned drawers.
    public let roomCount: Int

    /// Designated initializer.
    public init(name: String, drawerCount: Int, roomCount: Int) {
        self.name = name
        self.drawerCount = drawerCount
        self.roomCount = roomCount
    }
}

/// Aggregate count for a single room inside a wing — produced
/// by `listRooms`. As with `WingSummary`, this is a computed
/// projection over drawer rows; there is no `rooms` table.
public struct RoomSummary: Equatable, Hashable, Codable, Sendable {

    /// The wing this room belongs to.
    public let wing: String

    /// The room name, as it appears on drawer rows.
    public let name: String

    /// Number of non-tombstoned drawers in this room.
    public let drawerCount: Int

    /// Designated initializer.
    public init(wing: String, name: String, drawerCount: Int) {
        self.wing = wing
        self.name = name
        self.drawerCount = drawerCount
    }
}
