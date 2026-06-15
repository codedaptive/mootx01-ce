// status_report.rs — Rust twin of the Swift moot-mgr StatusReport.swift.
//
// The read/status surface data model for the CLI `status` subcommand. The
// summary groups samples BY DROPBOX and BY ESTATE rather than collapsing to a
// single global figure; headline totals are kept too, but the per-group
// breakdowns are the primary view.

use observer_sink::EventRow;
use persistence_kit::StorageStats;

/// Sample counts attributed to one group key (a dropbox id or an estate id).
/// Mirrors Swift `GroupCount`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GroupCount {
    /// The group key — a dropbox id (by-dropbox) or an estate id (by-estate).
    pub key: String,
    /// Number of metric samples attributed to this group.
    pub metric_count: i64,
    /// Number of event samples attributed to this group.
    pub event_count: i64,
}

/// A point-in-time summary of the manager's stats store. Built by
/// `MootManager::status`. Mirrors Swift `StatusReport`.
pub struct StatusReport {
    /// Whether monitoring is currently enabled (the global on/off switch).
    pub monitoring_enabled: bool,
    /// Total metric samples in the store across all dropboxes.
    pub total_metrics: i64,
    /// Total event samples in the store across all dropboxes.
    pub total_events: i64,
    /// Per-dropbox sample breakdown, sorted by key for stable output.
    pub by_dropbox: Vec<GroupCount>,
    /// Per-estate event breakdown, sorted by key. Estate attribution comes from
    /// event samples only (metric samples carry a dropbox id but no estate id).
    pub by_estate: Vec<GroupCount>,
    /// The most-recent events (newest first), up to the caller's limit.
    pub recent_events: Vec<EventRow>,
    /// DB-layer health of the manager's own stats store, or `None` if the
    /// backend does not support introspection.
    pub store_health: Option<StorageStats>,
}

impl StatusReport {
    /// Render the report as a plain-text block for the CLI `status` subcommand.
    ///
    /// Deterministic: groups are pre-sorted by key, so the same store state
    /// renders identically. Timestamps use ISO-8601 UTC for stable output.
    /// Mirrors Swift `StatusReport.renderText()`.
    pub fn render_text(&self) -> String {
        let mut lines: Vec<String> = Vec::new();
        lines.push("moot-mgr status".to_string());
        lines.push(format!(
            "  monitoring: {}",
            if self.monitoring_enabled { "ON" } else { "OFF" }
        ));
        lines.push(format!(
            "  totals: {} metrics, {} events",
            self.total_metrics, self.total_events
        ));

        lines.push("  by dropbox:".to_string());
        if self.by_dropbox.is_empty() {
            lines.push("    (none)".to_string());
        } else {
            for g in &self.by_dropbox {
                lines.push(format!(
                    "    {}: {} metrics, {} events",
                    g.key, g.metric_count, g.event_count
                ));
            }
        }

        lines.push("  by estate:".to_string());
        if self.by_estate.is_empty() {
            lines.push("    (none)".to_string());
        } else {
            for g in &self.by_estate {
                lines.push(format!("    {}: {} events", g.key, g.event_count));
            }
        }

        lines.push("  recent events:".to_string());
        if self.recent_events.is_empty() {
            lines.push("    (none)".to_string());
        } else {
            for ev in &self.recent_events {
                let ts = crate::manager::epoch_to_iso8601(ev.ts_epoch);
                lines.push(format!(
                    "    [{}] {} noun={} estate={} dropbox={}",
                    ts, ev.kind, ev.noun_type, ev.estate, ev.dropbox_id
                ));
            }
        }

        lines.push("  store health:".to_string());
        if let Some(h) = &self.store_health {
            lines.push(format!("    size: {} bytes", h.logical_size_bytes));
            if let Some(pages) = h.page_count {
                lines.push(format!("    pages: {pages}"));
            }
            if let Some(free) = h.freelist_page_count {
                lines.push(format!("    freelist pages: {free}"));
            }
            if let Some(wal) = h.wal_frame_count {
                lines.push(format!("    WAL frames: {wal}"));
            }
            if let Some(hit) = h.cache_hit_ratio {
                lines.push(format!("    cache hit ratio: {hit}"));
            }
        } else {
            lines.push("    (introspection unavailable)".to_string());
        }

        lines.join("\n")
    }
}
