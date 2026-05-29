//! Match — result type for find_nearest and find_within.

/// A single match from a similarity query.
///
/// `index` points into the input candidate slice; `distance` is
/// the Hamming distance from the probe to the matched engram.
/// Matches sort by distance ascending, ties by index ascending.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Match {
    pub index: usize,
    pub distance: u32,
}

impl PartialOrd for Match {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Match {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.distance.cmp(&other.distance)
            .then_with(|| self.index.cmp(&other.index))
    }
}
