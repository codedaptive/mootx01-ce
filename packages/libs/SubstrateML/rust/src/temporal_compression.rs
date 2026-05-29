// temporal_compression.rs
//
// Hierarchical temporal compression per cookbook § 8.14. Mirror of
// glref-swift-TemporalCompression.swift.

use std::collections::HashMap;
use substrate_types::hlc::HLC;
use substrate_types::fingerprint256::Fingerprint256;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum WindowLevel {
    Hour    = 0,
    Day     = 1,
    Week    = 2,
    Month   = 3,
    Quarter = 4,
    Year    = 5,
}

impl WindowLevel {
    pub fn next_coarser(self) -> Option<WindowLevel> {
        match self {
            WindowLevel::Hour    => Some(WindowLevel::Day),
            WindowLevel::Day     => Some(WindowLevel::Week),
            WindowLevel::Week    => Some(WindowLevel::Month),
            WindowLevel::Month   => Some(WindowLevel::Quarter),
            WindowLevel::Quarter => Some(WindowLevel::Year),
            WindowLevel::Year    => None,
        }
    }

    pub fn approx_seconds(self) -> i64 {
        match self {
            WindowLevel::Hour    => 3_600,
            WindowLevel::Day     => 86_400,
            WindowLevel::Week    => 604_800,
            WindowLevel::Month   => 2_592_000,
            WindowLevel::Quarter => 7_776_000,
            WindowLevel::Year    => 31_536_000,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TemporalWindow {
    pub start_hlc: HLC,
    pub end_hlc: HLC,
    pub level: WindowLevel,
    pub fingerprint: Fingerprint256,
    pub row_count: u32,
}

impl TemporalWindow {
    pub fn empty(level: WindowLevel) -> Self {
        Self {
            start_hlc: HLC::zero(),
            end_hlc: HLC::zero(),
            level,
            fingerprint: Fingerprint256::ZERO,
            row_count: 0,
        }
    }
}

pub struct TemporalCompression;

impl TemporalCompression {
    /// Compress a slice of row fingerprints into a single window.
    pub fn compress(rows: &[Fingerprint256],
                    start_hlc: HLC,
                    end_hlc: HLC,
                    level: WindowLevel) -> TemporalWindow {
        let mut summary = Fingerprint256::ZERO;
        for fp in rows {
            summary.block0 |= fp.block0;
            summary.block1 |= fp.block1;
            summary.block2 |= fp.block2;
            summary.block3 |= fp.block3;
        }
        TemporalWindow {
            start_hlc, end_hlc, level,
            fingerprint: summary,
            row_count: rows.len() as u32,
        }
    }

    /// Roll a set of lower-level windows up to a single target-level
    /// window. Associative and commutative.
    pub fn rollup(windows: &[TemporalWindow], target_level: WindowLevel) -> TemporalWindow {
        if windows.is_empty() {
            return TemporalWindow::empty(target_level);
        }
        let mut summary = Fingerprint256::ZERO;
        let mut total_rows: u32 = 0;
        let mut min_start = windows[0].start_hlc;
        let mut max_end = windows[0].end_hlc;
        for w in windows {
            summary.block0 |= w.fingerprint.block0;
            summary.block1 |= w.fingerprint.block1;
            summary.block2 |= w.fingerprint.block2;
            summary.block3 |= w.fingerprint.block3;
            total_rows = total_rows.wrapping_add(w.row_count);
            if w.start_hlc < min_start { min_start = w.start_hlc; }
            if w.end_hlc > max_end { max_end = w.end_hlc; }
        }
        TemporalWindow {
            start_hlc: min_start,
            end_hlc: max_end,
            level: target_level,
            fingerprint: summary,
            row_count: total_rows,
        }
    }

    /// Cascade: hour → day → week → month → ... → final_level.
    pub fn cascade_rollup(hour_windows: Vec<TemporalWindow>,
                          final_level: WindowLevel)
                         -> HashMap<WindowLevel, Vec<TemporalWindow>> {
        let mut by_level: HashMap<WindowLevel, Vec<TemporalWindow>> = HashMap::new();
        by_level.insert(WindowLevel::Hour, hour_windows);

        let mut current = WindowLevel::Hour;
        while current < final_level {
            let next = match current.next_coarser() {
                Some(n) => n,
                None => break,
            };
            let lower = by_level.get(&current).cloned().unwrap_or_default();
            let bucketed = Self::bucket_by_coarser_level(&lower, next);
            let mut rolled: Vec<TemporalWindow> = bucketed.into_values()
                .map(|ws| Self::rollup(&ws, next))
                .collect();
            rolled.sort_by(|a, b| a.start_hlc.cmp(&b.start_hlc));
            by_level.insert(next, rolled);
            current = next;
        }
        by_level
    }

    fn bucket_by_coarser_level(windows: &[TemporalWindow], coarser: WindowLevel)
                              -> HashMap<i64, Vec<TemporalWindow>> {
        let mut buckets: HashMap<i64, Vec<TemporalWindow>> = HashMap::new();
        for w in windows {
            let anchor = w.start_hlc.physical_seconds_since_epoch()
                       / coarser.approx_seconds();
            buckets.entry(anchor).or_default().push(*w);
        }
        buckets
    }
}
