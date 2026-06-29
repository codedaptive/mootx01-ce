// as_of_coordinate.rs
//
// Temporal query parameter for as-of reads per ADR-017 §15–§17.
// AsOfCoordinate is a discriminated value — `Present` means
// "the live state now" and `AsOf(hlc)` means "the state at
// this HLC." This prevents the class of bug where a caller
// passes a zero HLC meaning "present" and the filter interprets
// it as "the dawn of time."

use crate::hlc::HLC;
use std::fmt;

/// Temporal coordinate for a substrate read operation.
///
/// Every as-of read carries an `AsOfCoordinate` that says "now"
/// or "at this HLC." The enum discriminant prevents zero-HLC
/// ambiguity — `Present` is always present, never confused
/// with an HLC at the epoch.
#[cfg_attr(feature = "serde-support", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde-support", serde(tag = "kind", content = "hlc"))]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AsOfCoordinate {
    /// Read the current live state.
    #[cfg_attr(feature = "serde-support", serde(rename = "present"))]
    Present,

    /// Read the state as it was at the given HLC.
    #[cfg_attr(feature = "serde-support", serde(rename = "asOf"))]
    AsOf(HLC),
}

impl fmt::Display for AsOfCoordinate {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Present => write!(f, "present"),
            Self::AsOf(hlc) => write!(f, "asOf({}/{}/{})",
                hlc.physical_time, hlc.logical_count, hlc.node_id),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn present_equality() {
        assert_eq!(AsOfCoordinate::Present, AsOfCoordinate::Present);
    }

    #[test]
    fn as_of_equality() {
        let hlc = HLC::new(1000, 0, 1);
        assert_eq!(
            AsOfCoordinate::AsOf(hlc),
            AsOfCoordinate::AsOf(hlc),
        );
    }

    #[test]
    fn present_not_equal_to_as_of() {
        let hlc = HLC::new(0, 0, 0);
        assert_ne!(AsOfCoordinate::Present, AsOfCoordinate::AsOf(hlc));
    }

    #[test]
    fn display_present() {
        assert_eq!(format!("{}", AsOfCoordinate::Present), "present");
    }

    #[test]
    fn display_as_of() {
        let hlc = HLC::new(1000, 5, 42);
        let s = format!("{}", AsOfCoordinate::AsOf(hlc));
        assert_eq!(s, "asOf(1000/5/42)");
    }

    #[test]
    fn zero_hlc_is_not_present() {
        // The core invariant: a zero HLC wrapped in AsOf is
        // distinct from Present, preventing the ambiguity bug.
        let zero_hlc = HLC::new(0, 0, 0);
        assert_ne!(
            AsOfCoordinate::Present,
            AsOfCoordinate::AsOf(zero_hlc),
        );
    }
}
