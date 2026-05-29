//! Closed HLC interval [start, end].
//!
//! Moved here from substrate-lib in Phase 6.8 of the pre-ship
//! refactor (decision 2026-05-28 §6.6).

use crate::hlc::HLC;

/// Closed HLC interval [start, end].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TimeRange {
    pub start: HLC,
    pub end: HLC,
}

impl TimeRange {
    pub fn new(start: HLC, end: HLC) -> Self {
        assert!(start <= end, "TimeRange end must not precede start");
        Self { start, end }
    }
    pub fn contains(&self, hlc: HLC) -> bool {
        self.start <= hlc && hlc <= self.end
    }
}
