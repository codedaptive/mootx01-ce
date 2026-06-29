//! Wing and room aggregate summary types. Ports `Summaries.swift`.
//!
//! `WingSummary` and `RoomSummary` are computed projections built by
//! counting drawers grouped by `parent_node_id` (ADR-017), mirroring
//! MemPalace's `tool_list_wings` behavior. Their counts reflect
//! whatever is in the store at query time. Wings and rooms are node
//! rows in the `nodes` table; drawers reference their parent room via
//! `parent_node_id`.

// MARK: - WingSummary

/// Aggregate count for a single wing — produced by `list_wings`.
///
/// Wings are node rows in the `nodes` table (ADR-017); drawers
/// reference their room via `parent_node_id`. This summary is a
/// computed projection over the node tree. Counts reflect
/// non-tombstoned drawers only.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WingSummary {
    /// The wing name, as it appears on drawer rows.
    pub name: String,

    /// Number of non-tombstoned drawers in this wing.
    pub drawer_count: i64,

    /// Number of distinct room names found inside this wing,
    /// counting only non-tombstoned drawers.
    pub room_count: i64,
}

impl WingSummary {
    pub fn new(name: impl Into<String>, drawer_count: i64, room_count: i64) -> Self {
        Self {
            name: name.into(),
            drawer_count,
            room_count,
        }
    }
}

// MARK: - RoomSummary

/// Aggregate count for a single room inside a wing — produced by
/// `list_rooms`. As with `WingSummary`, this is a computed projection
/// over drawer rows; there is no `rooms` table.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoomSummary {
    /// The wing this room belongs to.
    pub wing: String,

    /// The room name, as it appears on drawer rows.
    pub name: String,

    /// Number of non-tombstoned drawers in this room.
    pub drawer_count: i64,
}

impl RoomSummary {
    pub fn new(wing: impl Into<String>, name: impl Into<String>, drawer_count: i64) -> Self {
        Self {
            wing: wing.into(),
            name: name.into(),
            drawer_count,
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wing_summary_fields() {
        let ws = WingSummary::new("Science", 12, 3);
        assert_eq!(ws.name, "Science");
        assert_eq!(ws.drawer_count, 12);
        assert_eq!(ws.room_count, 3);
    }

    #[test]
    fn wing_summary_equality() {
        let a = WingSummary::new("Science", 12, 3);
        let b = WingSummary::new("Science", 12, 3);
        assert_eq!(a, b);
    }

    #[test]
    fn wing_summary_inequality_on_name() {
        let a = WingSummary::new("Science", 12, 3);
        let b = WingSummary::new("History", 12, 3);
        assert_ne!(a, b);
    }

    #[test]
    fn room_summary_fields() {
        let rs = RoomSummary::new("Science", "Chemistry", 5);
        assert_eq!(rs.wing, "Science");
        assert_eq!(rs.name, "Chemistry");
        assert_eq!(rs.drawer_count, 5);
    }

    #[test]
    fn room_summary_equality() {
        let a = RoomSummary::new("Science", "Chemistry", 5);
        let b = RoomSummary::new("Science", "Chemistry", 5);
        assert_eq!(a, b);
    }

    #[test]
    fn room_summary_inequality_on_count() {
        let a = RoomSummary::new("Science", "Chemistry", 5);
        let b = RoomSummary::new("Science", "Chemistry", 6);
        assert_ne!(a, b);
    }
}
