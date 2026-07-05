// manager.rs — Rust twin of the Swift moot-mgr MootManager.swift.
//
// The manager core: store ownership, the global monitoring on/off switch, the
// retention window, and the read/status + HTTP-payload surface. A PURE OBSERVER
// — it never hosts an estate DB (the admin plane in estate_admin.rs does that).
//
// Responsibilities:
//   1. Own the ObserverSink StatsStore (SQLite) at a configurable path; migrate
//      on start.
//   2. Own the global on/off switch — set_monitoring writes the control flag row.
//      THAT is the broadcast: consumers' sinks read the flag.
//   3. Run a retention pass — run_retention(now) computes cutoff = now - window
//      (the app may read the clock here; determinism applies to engines/libs,
//      not the app's own loop) and rolls off old rows.
//   4. Expose a read/status surface grouped BY DROPBOX and BY ESTATE, plus the
//      HTTP read-API payload builders that project the store into the GUI wire
//      shapes (metadata only — content-safety invariant enforced at the boundary).
//
// ── Proxy behaviour (documented, not faked) ─────────────────────────────────
// The Swift MootManager proxies an ARIA_MCP resident daemon over URLSession for
// two surfaces: the admin/hosted-estate list merged into /api/estates, and the
// /api/lattice address snapshot.
//
// The Rust port now matches this proxy behaviour using a raw std::net HTTP GET
// (daemon_client module) with a 3-second connect+read timeout so the console
// degrades gracefully when the daemon is down:
//
//   /api/lattice      — proxied from `{base}/api/lattice` → LatticeSnapshotPayload
//                       with FDC heading labels from the bundled frame. On any
//                       failure (connect/timeout/non-200/parse): {addresses:[],pending:true}.
//   /api/admin/estates — proxied from `{base}/api/admin/estates` → stored in
//                        EstatesPayload.admin. On failure: None (honest degrade).
//                        Note: HttpReadApi overwrites admin with the local
//                        EstateAdmin payload rather than merging the two sections.
//
// Daemon address: ARIA_MCP_API_BASE env var, default http://127.0.0.1:4242.
// Mirrors Swift `MootManager.ariaAPIBase`. See `daemon_client` for the raw GET.

use std::collections::{BTreeMap, BTreeSet};

use cognition_kit::capability::shipped_capabilities;
use observer_sink::{DropboxMetricAggregate, EventRow, MetricRow, StatsStore};

use crate::api_payloads::{
    ConfigPayload, DropboxSummaryPayload, EstatePayload, EstatesPayload, EventPayload,
    EventsPayload, GraphAnalyticPayload, GraphCommunityPayload, GraphPayload, ServerPayload,
    StoredGraphPayload,
};
use crate::status_report::{GroupCount, StatusReport};

/// Errors raised by `MootManager` operations. Mirrors Swift `ManagerError`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ManagerError {
    /// A manager operation was called before `start()` opened the store.
    NotStarted,
    /// A retention window of zero or less was supplied to `set_retention`.
    InvalidRetention,
    /// An I/O failure from the underlying stats store.
    Storage { reason: String },
}

impl From<persistence_kit::StorageError> for ManagerError {
    fn from(e: persistence_kit::StorageError) -> Self {
        ManagerError::Storage {
            reason: format!("{e:?}"),
        }
    }
}

/// The MOOTx01 observer/manager. Owns the central stats store, the global
/// monitoring switch, and the retention window. Mirrors Swift `MootManager`.
///
/// The Rust store (`observer_sink::StatsStore`) is synchronous, so this type is
/// synchronous too — there is no actor; the resident host serializes access
/// through its own owner. The clock boundary is the caller's: every method that
/// needs "now" takes it as an epoch-seconds parameter (determinism rule).
pub struct MootManager {
    config: crate::manager_config::ManagerConfig,
    /// The owned stats store. `Some` after `start()` succeeds.
    store: Option<StatsStore>,
    /// Runtime override of the retention window (set via the gated control
    /// channel `set retention`). `None` means "use config.retention_window_secs".
    ///
    /// Persisted to a JSON sidecar file (`moot-mgr-prefs.json`) next to the
    /// stats store so the override survives process restart. Loaded in `start()`
    /// via `load_persisted_retention_override` and written in `set_retention`.
    /// The manager owns that directory, so it owns the sidecar file.
    /// Mirrors Swift `MootManager.retentionOverride`.
    retention_override_secs: Option<i64>,
    /// The cutoff (epoch seconds) the most-recent retention pass used, surfaced
    /// by /api/config. Held in-process (the store has no public reader for its
    /// retention-cutoff control row). Seeded to epoch zero (matches the store's
    /// own seed) until the first pass runs.
    last_retention_cutoff_epoch: f64,
}

impl MootManager {
    /// Create a manager with the given configuration. Call `start()` before any
    /// other method. Mirrors Swift `MootManager.init(config:)`.
    pub fn new(config: crate::manager_config::ManagerConfig) -> Self {
        MootManager {
            config,
            store: None,
            retention_override_secs: None,
            last_retention_cutoff_epoch: 0.0,
        }
    }

    /// The resolved configuration (store path + retention window/cadence).
    pub fn config(&self) -> &crate::manager_config::ManagerConfig {
        &self.config
    }

    /// Provision and open the stats store, applying the schema/migrations.
    /// Creates the store's parent directory if needed. Idempotent at the store
    /// level (`StatsStore::open` is forward-only). Mirrors Swift `MootManager.start()`.
    ///
    /// Restores any persisted retention override from the sidecar JSON file so
    /// the custom window survives process restart. When the sidecar is absent
    /// or unparseable, `retention_override_secs` stays `None` and the configured
    /// default applies — the safe, expected behaviour on first start.
    pub fn start(&mut self) -> Result<(), ManagerError> {
        if let Some(parent) = std::path::Path::new(&self.config.store_path).parent() {
            std::fs::create_dir_all(parent).map_err(|e| ManagerError::Storage {
                reason: format!("create store parent dir failed: {e}"),
            })?;
            // Restrict the stats store directory to the owning user (planned
            // hardening). SQLite WAL/SHM files land here and must not be readable
            // by other local users. Mirrors Swift `start()` passing `.posixPermissions:
            // 0o700` through `FileManager.createDirectory(attributes:)`. Best-effort:
            // a chmod failure is logged but does not abort start() — the directory
            // was created and the store can still be opened.
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if let Err(e) = std::fs::set_permissions(
                    parent,
                    std::fs::Permissions::from_mode(0o700),
                ) {
                    eprintln!("moot-mgr: warning: could not chmod stats store dir to 0700: {e}");
                }
            }
        }
        let store = StatsStore::new(&self.config.store_path)?;
        store.open()?;
        self.store = Some(store);
        // Restore any persisted retention override so the window survives restart.
        self.retention_override_secs = self.load_persisted_retention_override();
        Ok(())
    }

    /// Close the store cleanly. Idempotent. Mirrors Swift `MootManager.stop()`.
    pub fn stop(&mut self) {
        if let Some(store) = &self.store {
            let _ = store.close();
        }
        self.store = None;
    }

    /// The opened stats store, for an in-process consumer (e.g. an integration
    /// test installing a sink against the manager's store). Mirrors Swift
    /// `MootManager.statsStore()`.
    pub fn stats_store(&self) -> Result<&StatsStore, ManagerError> {
        self.require_store()
    }

    // MARK: - Monitoring switch

    /// Set the global monitoring on/off switch. Writes the control flag row —
    /// this IS the broadcast (every consumer's sink reads the row). Mirrors Swift
    /// `MootManager.setMonitoring(_:)`.
    pub fn set_monitoring(&self, enabled: bool) -> Result<(), ManagerError> {
        Ok(self.require_store()?.set_monitoring_enabled(enabled)?)
    }

    /// Read the current global monitoring state. Mirrors Swift `MootManager.isMonitoring()`.
    pub fn is_monitoring(&self) -> Result<bool, ManagerError> {
        Ok(self.require_store()?.is_monitoring_enabled()?)
    }

    // MARK: - Retention

    /// The retention window currently in effect: the runtime override if the
    /// control channel set one, else the configured default. Mirrors Swift
    /// `MootManager.effectiveRetentionWindow`.
    pub fn effective_retention_window_secs(&self) -> i64 {
        self.retention_override_secs
            .unwrap_or(self.config.retention_window_secs)
    }

    /// Set the retention window at runtime (the gated `set retention` verb). A
    /// non-positive window is rejected. Mirrors Swift `MootManager.setRetention(window:)`.
    ///
    /// The new window takes effect on the next `run_retention` call. The override
    /// is persisted to the JSON sidecar file so it survives process restart. A
    /// write failure is logged to stderr but does not surface as an error — the
    /// in-process override applies immediately regardless of disk state.
    pub fn set_retention(&mut self, window_secs: i64) -> Result<(), ManagerError> {
        if window_secs <= 0 {
            return Err(ManagerError::InvalidRetention);
        }
        self.retention_override_secs = Some(window_secs);
        self.persist_retention_override(window_secs);
        Ok(())
    }

    /// Run one retention pass: roll off samples older than the retention window.
    /// `cutoff = now - effective_window`; the cutoff is computed here (the app's
    /// own loop may read the clock) and passed into the store's retention engine.
    /// Returns the total rows deleted. Mirrors Swift `MootManager.runRetention(now:)`.
    pub fn run_retention(&mut self, now_epoch: f64) -> Result<usize, ManagerError> {
        let window = self.effective_retention_window_secs() as f64;
        let cutoff = now_epoch - window;
        let store = self.require_store()?;
        let metrics_deleted = store.delete_metrics_before(cutoff, now_epoch)?;
        let events_deleted = store.delete_events_before(cutoff, now_epoch)?;
        self.last_retention_cutoff_epoch = cutoff;
        Ok(metrics_deleted + events_deleted)
    }

    // MARK: - Read / status surface (CLI)

    /// Build a `StatusReport` summarising the store's current contents, grouped
    /// BY DROPBOX and BY ESTATE. Mirrors Swift `MootManager.status(now:recentEventLimit:)`.
    pub fn status(
        &self,
        now_epoch: f64,
        recent_event_limit: usize,
    ) -> Result<StatusReport, ManagerError> {
        let store = self.require_store()?;
        let monitoring_enabled = store.is_monitoring_enabled()?;
        // Use aggregate queries rather than a full table scan.
        // count_metrics() issues a single SQL COUNT(*); per-dropbox metric
        // counts come from query_metric_aggregates_by_dropbox, driven by the
        // event dropbox IDs (every metric-emitting dropbox also emits events).
        let total_metrics = store.count_metrics()? as i64;
        let events = store.query_events(None)?;

        // Derive the set of known dropbox IDs from the (cheap) event rows.
        let event_dropbox_ids: Vec<String> = {
            let mut ids: BTreeSet<String> = BTreeSet::new();
            for e in &events {
                ids.insert(e.dropbox_id.clone());
            }
            ids.into_iter().collect()
        };
        let event_dropbox_id_strs: Vec<&str> = event_dropbox_ids.iter().map(String::as_str).collect();
        let metric_aggregates: Vec<DropboxMetricAggregate> =
            store.query_metric_aggregates_by_dropbox(&event_dropbox_id_strs)?;
        let mut dropbox_metric_counts: BTreeMap<String, i64> = metric_aggregates
            .into_iter()
            .map(|a| (a.dropbox_id, a.metric_count as i64))
            .collect();

        // By-dropbox: count metrics and events per dropbox id.
        let mut dropbox_events: BTreeMap<String, i64> = BTreeMap::new();
        for e in &events {
            *dropbox_events.entry(e.dropbox_id.clone()).or_insert(0) += 1;
        }
        let mut dropbox_keys: BTreeSet<String> = BTreeSet::new();
        dropbox_keys.extend(dropbox_metric_counts.keys().cloned());
        dropbox_keys.extend(dropbox_events.keys().cloned());
        let by_dropbox: Vec<GroupCount> = dropbox_keys
            .iter()
            .map(|key| GroupCount {
                key: key.clone(),
                metric_count: dropbox_metric_counts.remove(key).unwrap_or(0),
                event_count: *dropbox_events.get(key).unwrap_or(&0),
            })
            .collect();

        // By-estate: event-level field only (metric samples carry no estate id).
        let mut estate_events: BTreeMap<String, i64> = BTreeMap::new();
        for e in &events {
            *estate_events.entry(e.estate.clone()).or_insert(0) += 1;
        }
        let by_estate: Vec<GroupCount> = estate_events
            .iter()
            .map(|(key, count)| GroupCount {
                key: key.clone(),
                metric_count: 0,
                event_count: *count,
            })
            .collect();

        // Recent events: query_events returns oldest-first; take the newest tail
        // and reverse so the report is newest-first.
        let recent_events = tail_reversed(events, recent_event_limit);
        let store_health = store.storage_stats(now_epoch as i64)?;

        Ok(StatusReport {
            monitoring_enabled,
            total_metrics,
            total_events: recent_total_events(&recent_events, &by_estate),
            by_dropbox,
            by_estate,
            recent_events,
            store_health,
        })
    }

    // MARK: - HTTP read-API payload builders
    //
    // These project the store's current contents into the GUI wire shapes. All
    // are metadata-only — the content-safety invariant is enforced here at the
    // boundary: nothing that could carry rung/memory content is read or projected.

    /// Build the GET /api/server payload. Server.* metric fields are read from
    /// the latest matching samples; all default to `None` when no samples exist
    /// (the dashboard renders n/a chips rather than fabricating values). Mirrors
    /// Swift `MootManager.serverPayload(now:uptimeSeconds:)`.
    pub fn server_payload(
        &self,
        now_epoch: f64,
        uptime_seconds: i64,
    ) -> Result<ServerPayload, ManagerError> {
        let store = self.require_store()?;
        let monitoring_enabled = store.is_monitoring_enabled()?;
        // Use aggregate queries rather than a full table scan.
        // Per-dropbox metric summaries are populated from query_metric_aggregates_by_dropbox;
        // per-name server metrics use the existing targeted name-filtered query.
        let total_metrics = store.count_metrics()? as i64;
        let events = store.query_events(None)?;
        let estate_count = events
            .iter()
            .map(|e| e.estate.clone())
            .collect::<BTreeSet<_>>()
            .len() as i64;
        let health = store.storage_stats(now_epoch as i64)?;

        // --- Server-metric extraction (latest + second-latest per named metric) ---
        //
        // Bounded query: the name set is fixed and small (6 names). Using the
        // targeted SQL query instead of filtering `all_metrics` in-memory bounds
        // the server-metric surface to its intended names and avoids the DoS window
        // where a noisy producer floods arbitrary metric names into the server section.
        // Mirrors Swift `serverPayload()` which calls `store.queryMetricsByNames(serverMetricNames)`.
        let server_metric_names: &[&str] = &[
            "server.rss_mb",
            "server.cpu_user_ms",
            "server.rpc_count",
            "server.connections",
            "server.proto_version",
            "substrate.kernel.backend_selected",
        ];
        let server_metrics = store.query_metrics_by_names(server_metric_names, None)?;
        // latest_by_name[name] = (newer, older). older is None until the second sample.
        let mut latest_by_name: BTreeMap<String, (MetricRow, Option<MetricRow>)> = BTreeMap::new();
        for m in server_metrics.iter() {
            match latest_by_name.get(&m.name) {
                Some((prev, _)) if m.ts_epoch > prev.ts_epoch => {
                    let prev_clone = clone_metric(prev);
                    latest_by_name.insert(m.name.clone(), (clone_metric(m), Some(prev_clone)));
                }
                Some((prev, second)) => {
                    let newer_than_second =
                        second.as_ref().map(|s| m.ts_epoch > s.ts_epoch).unwrap_or(true);
                    if newer_than_second {
                        let prev_clone = clone_metric(prev);
                        latest_by_name.insert(m.name.clone(), (prev_clone, Some(clone_metric(m))));
                    }
                }
                None => {
                    latest_by_name.insert(m.name.clone(), (clone_metric(m), None));
                }
            }
        }

        let latest_value = |name: &str| latest_by_name.get(name).map(|(n, _)| n.value);
        let rss_mb = latest_value("server.rss_mb");
        let cpu_user_ms = latest_value("server.cpu_user_ms");
        let rpc_count = latest_value("server.rpc_count").map(|v| v as i64);
        let connections = latest_value("server.connections").map(|v| v as i64);
        let proto_version = latest_by_name
            .get("server.proto_version")
            .and_then(|(n, _)| n.tags.get("version").cloned());
        let kernel_backend = latest_by_name
            .get("substrate.kernel.backend_selected")
            .and_then(|(n, _)| n.tags.get("backend").cloned());

        // Delta-derived rates. None when fewer than two samples exist.
        let rpc_rate = latest_by_name.get("server.rpc_count").and_then(|(newer, older)| {
            older.as_ref().and_then(|o| {
                let wall = newer.ts_epoch - o.ts_epoch;
                if wall > 0.0 {
                    Some((newer.value - o.value).max(0.0) / wall)
                } else {
                    None
                }
            })
        });
        let cpu_pct = latest_by_name.get("server.cpu_user_ms").and_then(|(newer, older)| {
            older.as_ref().and_then(|o| {
                let wall_ms = (newer.ts_epoch - o.ts_epoch) * 1000.0;
                if wall_ms > 0.0 {
                    Some((100.0_f64).min(((newer.value - o.value).max(0.0) / wall_ms * 100.0).max(0.0)))
                } else {
                    None
                }
            })
        });

        // Per-dropbox summaries (Connects tab / Overview observers panel).
        // Drive the dropbox ID list from events (cheap); then fetch per-dropbox
        // metric aggregate (count + last ts) with a targeted SQL query, avoiding
        // a full metric_samples table scan for large stores.
        let payload_dropbox_ids: Vec<String> = {
            let mut ids: BTreeSet<String> = BTreeSet::new();
            for e in &events {
                ids.insert(e.dropbox_id.clone());
            }
            ids.into_iter().collect()
        };
        let payload_dropbox_id_strs: Vec<&str> = payload_dropbox_ids.iter().map(String::as_str).collect();
        let metric_aggregates: Vec<DropboxMetricAggregate> =
            store.query_metric_aggregates_by_dropbox(&payload_dropbox_id_strs)?;
        let by_dropbox = build_dropbox_summaries_from_aggregates(&metric_aggregates, &events);

        // NeuronKit capabilities: sourced from CognitionKit's compile-time
        // shipped_capabilities() constant, mirroring the Swift host's
        // shippedNeuronKitCapabilities call. Both ports now use the same static
        // manifest approach — no metrics dependency required.
        let capabilities: Vec<String> = shipped_capabilities()
            .iter()
            .map(|c| c.raw_value().to_string())
            .collect();

        Ok(ServerPayload {
            monitoring_enabled,
            uptime_seconds,
            estate_count,
            total_metrics,
            total_events: events.len() as i64,
            store_size_bytes: health.as_ref().map(|h| h.logical_size_bytes).unwrap_or(0),
            store_page_count: health.as_ref().and_then(|h| h.page_count),
            store_freelist_page_count: health.as_ref().and_then(|h| h.freelist_page_count),
            store_wal_frame_count: health.as_ref().and_then(|h| h.wal_frame_count),
            store_cache_hit_ratio: health.as_ref().and_then(|h| h.cache_hit_ratio),
            store_transaction_commit_count: health.as_ref().and_then(|h| h.transaction_commit_count),
            store_row_count: health.as_ref().and_then(|h| h.row_count.map(|r| r as i64)),
            rss_mb,
            cpu_user_ms,
            rpc_count,
            connections,
            proto_version,
            kernel_backend,
            rpc_rate,
            cpu_pct,
            by_dropbox,
            capabilities,
        })
    }

    /// Build the GET /api/estates payload: per-estate event rollups with queue
    /// stats, plus the admin section sourced by proxying the ARIA daemon's
    /// `GET /api/admin/estates` endpoint.
    ///
    /// The `admin` section is `None` here when the daemon is unreachable (the
    /// host's own EstateAdmin section is then the only source, merged in by
    /// HttpReadApi). When the daemon IS reachable, the daemon's hosted-estate
    /// list is decoded into `admin` so the console's Estates page shows the
    /// running daemon's estate. Mirrors Swift `MootManager.estatesPayload()`.
    pub fn estates_payload(&self) -> Result<EstatesPayload, ManagerError> {
        let store = self.require_store()?;
        let events = store.query_events(None)?;
        let mut counts: BTreeMap<String, i64> = BTreeMap::new();
        let mut last_ts: BTreeMap<String, f64> = BTreeMap::new();
        for e in &events {
            *counts.entry(e.estate.clone()).or_insert(0) += 1;
            let entry = last_ts.entry(e.estate.clone()).or_insert(f64::MIN);
            if e.ts_epoch > *entry {
                *entry = e.ts_epoch;
            }
        }

        // For each estate (dropbox) we only need the LATEST sample per queue metric —
        // not every historical row. With millions of rows a `WHERE name IN (...)` still
        // full-scans those rows when the flooded names ARE the queue.* names.
        // The replacement issues one indexed query per (name, dropboxID) pair and returns
        // ≤1 row per pair: 8 names × N dropboxes = at most 8N rows regardless of
        // table size, each using idx_metric_samples_dropbox_id + ts DESC LIMIT 1.
        let queue_metric_names: BTreeSet<&str> = [
            "queue.depth",
            "queue.drain_count",
            "queue.idle_nonempty",
            "queue.latency_p50_ms",
            "queue.latency_p95_ms",
            "queue.head_of_line_age_s",
            "locuskit.gate.admit_count",
            "locuskit.gate.reject_count",
        ]
        .into_iter()
        .collect();
        // Restrict to the dropboxIDs seen in the event stream — the same
        // set of dropboxes that report queue metrics.
        let queue_dropbox_ids: Vec<&str> = events
            .iter()
            .map(|e| e.dropbox_id.as_str())
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect();
        let queue_metric_name_slice: Vec<&str> = queue_metric_names.iter().copied().collect();
        let queue_metrics = store.query_latest_metrics_by_names_and_dropboxes(
            &queue_metric_name_slice,
            &queue_dropbox_ids,
        )?;
        // latest[(estate, metric)] = value of the newest sample.
        // The returned rows already hold ≤1 row per (name, dropboxID), but a single
        // dropbox may report metrics for multiple estates via tags["estate"]; take max
        // per (estate, metric) key for correctness.
        let mut latest: BTreeMap<(String, String), (f64, f64)> = BTreeMap::new(); // -> (value, ts)
        for m in queue_metrics.iter() {
            let est = m.tags.get("estate").cloned().unwrap_or_else(|| "unknown".to_string());
            let key = (est, m.name.clone());
            let entry = latest.entry(key).or_insert((m.value, m.ts_epoch));
            if m.ts_epoch > entry.1 {
                *entry = (m.value, m.ts_epoch);
            }
        }
        let latest_value = |estate: &str, metric: &str| {
            latest.get(&(estate.to_string(), metric.to_string())).map(|(v, _)| *v)
        };

        let rollups = counts
            .keys()
            .map(|id| {
                let has_queue = queue_metric_names
                    .iter()
                    .any(|n| latest_value(id, n).is_some());
                let queue = if has_queue {
                    Some(crate::api_payloads::QueueStats {
                        depth: latest_value(id, "queue.depth"),
                        drain_count: latest_value(id, "queue.drain_count"),
                        idle_nonempty: latest_value(id, "queue.idle_nonempty").map(|v| v > 0.0),
                        latency_p50_ms: latest_value(id, "queue.latency_p50_ms"),
                        latency_p95_ms: latest_value(id, "queue.latency_p95_ms"),
                        head_of_line_age_s: latest_value(id, "queue.head_of_line_age_s"),
                        gate_admit_count: latest_value(id, "locuskit.gate.admit_count"),
                        gate_reject_count: latest_value(id, "locuskit.gate.reject_count"),
                    })
                } else {
                    None
                };
                EstatePayload {
                    id: id.clone(),
                    event_count: *counts.get(id).unwrap_or(&0),
                    last_event_ts: last_ts
                        .get(id)
                        .filter(|t| **t > f64::MIN)
                        .map(|t| epoch_to_iso8601(*t)),
                    queue,
                }
            })
            .collect();

        // Proxy the daemon's admin/hosted-estate section. On any failure (daemon
        // down, decode error, timeout) admin is None. HttpReadApi overwrites this
        // field with the local admin payload, so the two admin sections are not
        // merged. Matches Swift's equivalent `ariaAdmin` block in
        // MootManager.estatesPayload().
        let aria_admin = proxy_admin_estates();

        Ok(EstatesPayload {
            estates: rollups,
            admin: aria_admin,
        })
    }

    /// Build the GET /api/events payload: the most-recent events, newest first.
    /// Mirrors Swift `MootManager.eventsPayload(limit:)`.
    pub fn events_payload(&self, limit: usize) -> Result<EventsPayload, ManagerError> {
        let store = self.require_store()?;
        let events = store.query_events(None)?;
        let recent = tail_reversed(events, limit);
        Ok(EventsPayload {
            events: recent.iter().map(project_event).collect(),
        })
    }

    /// Build the GET /api/config payload. Mirrors Swift `MootManager.configPayload()`.
    pub fn config_payload(&self) -> Result<ConfigPayload, ManagerError> {
        let store = self.require_store()?;
        let monitoring_enabled = store.is_monitoring_enabled()?;
        Ok(ConfigPayload {
            monitoring_enabled,
            retention_seconds: self.effective_retention_window_secs(),
            retention_cutoff: epoch_to_iso8601(self.last_retention_cutoff_epoch),
        })
    }

    /// Build the GET /api/graph payload: the Topology node-link snapshot.
    ///
    /// Structure (nodes/edges) is read from the shared stats store's
    /// `topology_snapshots` table (the autonomic governor writes a row per estate
    /// on its cadence). When no snapshot is available yet, `structure_pending` is
    /// true with an honest enumeration. The analytic overlay (analytics/
    /// communities) is always sourced locally from the VizGraph signal samples.
    /// Mirrors Swift `MootManager.graphPayload(now:estate:)`.
    pub fn graph_payload(
        &self,
        now_epoch: f64,
        estate: Option<&str>,
    ) -> Result<GraphPayload, ManagerError> {
        let store = self.require_store()?;

        // The five canonical VizGraph signal names — the wire contract between
        // the SubstrateML emitter and this reader (kept inline so the host takes
        // no dependency on the analytics layer just to recognise its names).
        let viz_signals: BTreeSet<&str> = [
            "community.assignment",
            "centrality.score",
            "nmf.factor",
            "anomaly.flag",
            "edge.decayed_weight",
        ]
        .into_iter()
        .collect();
        // VizGraph signal metrics: filter by event dropboxIDs to prevent a full
        // metric_samples table scan when millions of unrelated rows are present.
        // Unlike queue metrics (one dropbox per estate), VizGraph signals from
        // SubstrateML may be emitted by a single dropboxID for multiple estates —
        // the estate is carried as a row tag, not encoded in the dropboxID.  So
        // query_metrics_by_names per dropboxID is used (not query_latest_metrics_
        // by_names_and_dropboxes) to ensure rows for ALL estates within a dropboxID
        // are returned; the analytics code below keeps the latest per (estate, signal).
        let viz_events = store.query_events(None)?;
        let viz_dropbox_ids: Vec<String> = viz_events
            .iter()
            .map(|e| e.dropbox_id.clone())
            .collect::<std::collections::BTreeSet<_>>()
            .into_iter()
            .collect();
        let viz_signal_slice: Vec<&str> = viz_signals.iter().copied().collect();
        let mut viz_metrics: Vec<MetricRow> = Vec::new();
        for dropbox_id in &viz_dropbox_ids {
            let rows = store.query_metrics_by_names(&viz_signal_slice, Some(dropbox_id.as_str()))?;
            viz_metrics.extend(rows);
        }

        // Group by (estate, signal): keep the latest sample + the sample count.
        let mut latest: BTreeMap<(String, String), MetricRow> = BTreeMap::new();
        let mut sample_counts: BTreeMap<(String, String), i64> = BTreeMap::new();
        for m in viz_metrics
            .iter()
        {
            let est = m.tags.get("estate").cloned().unwrap_or_else(|| "unknown".to_string());
            // Honour the optional estate filter against the sample's estate tag.
            if let Some(filter) = estate {
                if !filter.is_empty() && filter != "all" && est != filter {
                    continue;
                }
            }
            let key = (est, m.name.clone());
            *sample_counts.entry(key.clone()).or_insert(0) += 1;
            match latest.get(&key) {
                Some(prev) if m.ts_epoch <= prev.ts_epoch => {}
                _ => {
                    latest.insert(key, clone_metric(m));
                }
            }
        }

        // Analytic overlay rows, sorted (estate, signal) for byte-stable output.
        let mut analytic_keys: Vec<&(String, String)> = latest.keys().collect();
        analytic_keys.sort();
        let analytics: Vec<GraphAnalyticPayload> = analytic_keys
            .iter()
            .map(|key| {
                let row = &latest[*key];
                GraphAnalyticPayload {
                    estate: key.0.clone(),
                    signal: key.1.clone(),
                    value: row.value,
                    ts: epoch_to_iso8601(row.ts_epoch),
                    sample_count: *sample_counts.get(*key).unwrap_or(&0),
                }
            })
            .collect();

        // Fallback community rollup from `community.assignment` (count-only).
        let mut communities: Vec<GraphCommunityPayload> = Vec::new();
        let mut comm_keys: Vec<&(String, String)> =
            latest.keys().filter(|k| k.1 == "community.assignment").collect();
        comm_keys.sort();
        for key in comm_keys {
            // Cap the untrusted metric value to prevent a crafted sample from
            // triggering an unbounded allocation loop. 10,000 community nodes is
            // a generous ceiling; legitimate graph analytics never approach it.
            // Mirrors Swift `graphPayload()` which clamps via max(0, min(Int(...), 10_000)).
            let count = latest[key].value.round().max(0.0).min(10_000.0) as i64;
            for _ in 0..count {
                communities.push(GraphCommunityPayload {
                    id: communities.len() as i64,
                    label: None,
                    size: 0,
                });
            }
        }

        // Read the topology snapshot from the shared stats store.
        let mut live_nodes = Vec::new();
        let mut live_edges = Vec::new();
        let mut structure_pending = true;
        let mut generated_ts: Option<String> = None;
        let mut pending = vec![
            "topology snapshot not yet available — the autonomic governor has not completed its first duty cycle"
                .to_string(),
        ];

        // "all"/empty/None → newest snapshot across all estates; an explicit
        // estate filter reads that estate's row.
        let estate_key: Option<&str> = match estate {
            Some(e) if !e.is_empty() && e != "all" => Some(e),
            _ => None,
        };
        if let Some(snapshot) = store.latest_topology_snapshot(estate_key)? {
            if let Ok(stored) = serde_json::from_str::<StoredGraphPayload>(&snapshot) {
                if !stored.structure_pending {
                    live_nodes = stored.nodes;
                    live_edges = stored.edges;
                    structure_pending = false;
                    generated_ts = stored.generated_ts;
                    pending = Vec::new();
                }
            }
        }

        Ok(GraphPayload {
            nodes: live_nodes,
            edges: live_edges,
            communities,
            analytics,
            structure_pending,
            pending,
            generated_ts,
            estate: estate
                .filter(|e| !e.is_empty())
                .map(|e| e.to_string())
                .unwrap_or_else(|| "all".to_string()),
            snapshot_ts: epoch_to_iso8601(now_epoch),
        })
    }

    // MARK: - Lexicon payload (GET /api/lexicon)

    /// Build the `GET /api/lexicon` payload: the ARIA grammar vocabulary and
    /// LatticeLib metadata as a static JSON document.
    ///
    /// Sourced entirely from `aria-lexicon-lib` compile-time enum definitions and
    /// `lattice-lib` runtime state — this builder is infallible and requires no
    /// store access. Mirrors Swift `MootManager.lexiconPayload()`.
    pub fn lexicon_payload(&self) -> crate::api_payloads::LexiconPayload {
        use aria_lexicon_lib::{Noun, Verb, Adjective, accepted_verbs};

        let nouns: Vec<String> = Noun::ALL.iter().map(|n| n.as_str().to_string()).collect();
        let verbs: Vec<String> = Verb::ALL.iter().map(|v| v.as_str().to_string()).collect();
        let adjectives: Vec<String> = Adjective::ALL.iter().map(|a| a.as_str().to_string()).collect();

        // Build the acceptance matrix: noun wire string → sorted accepted verb strings.
        // BTreeMap gives sorted JSON key order, matching Swift's .sortedKeys output.
        let mut acceptance: std::collections::BTreeMap<String, Vec<String>> = std::collections::BTreeMap::new();
        for noun in Noun::ALL.iter() {
            let mut verb_strs: Vec<String> = accepted_verbs(*noun)
                .iter()
                .map(|v| v.as_str().to_string())
                .collect();
            verb_strs.sort();
            acceptance.insert(noun.as_str().to_string(), verb_strs);
        }

        crate::api_payloads::LexiconPayload {
            nouns,
            verbs,
            adjectives,
            acceptance,
            fdc_available: lattice_lib::Fdc::is_available(),
            fdc_data_version: lattice_lib::Fdc::data_version().to_string(),
            lattice_version: lattice_lib::Fdc::version().to_string(),
        }
    }

    // MARK: - Lattice snapshot (GET /api/lattice)

    /// Build the `GET /api/lattice` payload: active lattice addresses with FDC
    /// heading labels, proxied from the ARIA daemon.
    ///
    /// Proxies the daemon's `GET /api/lattice` endpoint (which groups
    /// non-tombstoned drawers by their UDC code and returns code + count pairs).
    /// Each code is annotated with its FDC heading label from the bundled frame
    /// via `Fdc::label`. On any failure — daemon unreachable, timeout, non-200,
    /// decode error — returns `{addresses:[], pending:true}`, exactly mirroring
    /// the Swift host's fallback when the daemon is unreachable.
    ///
    /// CONTENT-SAFETY INVARIANT: only classification codes, FDC heading labels
    /// (bundled taxonomy, NOT estate content), and integer counts cross this
    /// surface — matching Swift `MootManager.latticePayload()`.
    pub fn lattice_payload(&self) -> crate::api_payloads::LatticeSnapshotPayload {
        proxy_lattice_snapshot()
    }

    // MARK: - Retention override persistence

    /// Filesystem path of the sidecar JSON file that persists the retention override.
    ///
    /// Placed alongside the stats store so the manager's data is self-contained —
    /// the manager already creates/owns that directory. The filename is derived from
    /// the store's filename stem to prevent collisions when two manager instances
    /// use stores in the same parent directory (e.g. `moot-mgr.sqlite` →
    /// `moot-mgr-prefs.json`). Mirrors Swift `MootManager.retentionPrefsURL`.
    fn retention_prefs_path(&self) -> std::path::PathBuf {
        let store_path = std::path::Path::new(&self.config.store_path);
        // Derive the prefs filename from the store stem so multiple stores in the
        // same directory do not share the same prefs file (filename collision fix).
        let stem = store_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("moot-mgr");
        store_path
            .parent()
            .unwrap_or_else(|| std::path::Path::new("."))
            .join(format!("{stem}-prefs.json"))
    }

    /// Persist the retention override to the sidecar JSON file.
    ///
    /// Best-effort write: logs to stderr on failure but does not propagate the
    /// error. The in-process value is authoritative for the current run;
    /// persistence is for restart survival. Format: `{"retentionWindow": <secs>}`.
    /// Mirrors Swift `MootManager.persistRetentionOverride(_:)`.
    fn persist_retention_override(&self, window_secs: i64) {
        let path = self.retention_prefs_path();
        let json = format!("{{\"retentionWindow\":{}}}", window_secs);
        if let Err(e) = std::fs::write(&path, json.as_bytes()) {
            eprintln!("moot-mgr: failed to persist retention override to {path:?}: {e}");
        }
    }

    /// Load the persisted retention override from the sidecar JSON file, if present.
    ///
    /// Returns `None` when the file is absent (first start, or removed), when
    /// the value is non-positive (guards against a corrupted write), or when the
    /// file cannot be decoded. Called once in `start()` after the store opens.
    /// Mirrors Swift `MootManager.loadPersistedRetentionOverride()`.
    fn load_persisted_retention_override(&self) -> Option<i64> {
        let path = self.retention_prefs_path();
        let data = std::fs::read(&path).ok()?;
        // Minimal JSON parse: {"retentionWindow": <integer>}
        // Using serde_json (already a transitive dependency via api_payloads) via
        // a local anonymous struct avoids adding a top-level import.
        let map: std::collections::BTreeMap<String, serde_json::Value> =
            serde_json::from_slice(&data).ok()?;
        let window = map.get("retentionWindow")?.as_i64()?;
        if window <= 0 {
            return None;
        }
        Some(window)
    }

    // MARK: - Internals

    fn require_store(&self) -> Result<&StatsStore, ManagerError> {
        self.store.as_ref().ok_or(ManagerError::NotStarted)
    }
}

// ─────────────────────── Daemon proxy helpers ────────────────────────────────
//
// These are module-level free functions so they can be unit-tested without a
// live MootManager, and to keep the MootManager impl block focused on its
// public surface.

/// The raw lattice proxy response shape from the ARIA daemon's `/api/lattice`
/// endpoint. Code + count only — labels are resolved from the bundled FDC frame
/// here (not stored in the daemon's response). Mirrors Swift `ARIALatticeAddress`.
#[derive(serde::Deserialize)]
struct DaemonLatticeAddress {
    code: String,
    count: i64,
}

/// The outer wrapper the daemon returns for `/api/lattice`.
#[derive(serde::Deserialize)]
struct DaemonLatticePayload {
    addresses: Vec<DaemonLatticeAddress>,
}

/// Proxy `GET {base}/api/lattice` from the ARIA daemon and annotate with FDC
/// labels. Returns the honest pending stub on any failure.
///
/// Only called from `MootManager::lattice_payload`. Extracted to allow
/// parse-path unit tests without spinning up a MootManager.
pub fn proxy_lattice_snapshot() -> crate::api_payloads::LatticeSnapshotPayload {
    use crate::api_payloads::{LatticeAddressPayload, LatticeSnapshotPayload};

    // Honest degraded state — returned on any failure.
    let degraded = LatticeSnapshotPayload {
        addresses: vec![],
        pending: true,
    };

    let (host, port) = crate::daemon_client::resolved_addr();
    let body = match crate::daemon_client::get(&host, port, "/api/lattice") {
        Some(b) => b,
        None => return degraded,
    };

    let daemon_payload: DaemonLatticePayload = match serde_json::from_slice(&body) {
        Ok(p) => p,
        Err(_) => return degraded,
    };

    let addresses: Vec<LatticeAddressPayload> = daemon_payload
        .addresses
        .into_iter()
        .map(|entry| LatticeAddressPayload {
            // FDC heading label from the bundled frame — never estate content.
            // None for MDCC codes, unknown codes, or when LatticeLib is
            // unavailable. Mirrors Swift `FDC.label(for: entry.code)`.
            label: lattice_lib::Fdc::label(&entry.code),
            code: entry.code,
            count: entry.count,
        })
        .collect();

    LatticeSnapshotPayload {
        addresses,
        pending: false,
    }
}

/// The raw admin/estates proxy response shape from the ARIA daemon's
/// `/api/admin/estates` endpoint. The `hosted` array matches `EstateAdminEntry`
/// field-for-field; we decode through `EstateAdminPayload` directly since the
/// JSON shape is identical.
///
/// Proxy `GET {base}/api/admin/estates` from the ARIA daemon and return the
/// decoded `EstateAdminPayload`, or `None` on any failure. The caller
/// (MootManager::estates_payload) assigns this to `admin` in the EstatesPayload
/// envelope. On failure the host's own local EstateAdmin section is the fallback
/// (merged in by HttpReadApi), so degradation is honest: the console shows the
/// locally-provisioned estates rather than fabricating data.
pub fn proxy_admin_estates() -> Option<crate::admin_payloads::EstateAdminPayload> {
    let (host, port) = crate::daemon_client::resolved_addr();
    let body = crate::daemon_client::get(&host, port, "/api/admin/estates")?;
    serde_json::from_slice::<crate::admin_payloads::EstateAdminPayload>(&body).ok()
}

/// Take the newest `limit` events (input is oldest-first) and reverse them so
/// the result is newest-first. Mirrors the Swift `events.suffix(limit).reversed()`.
fn tail_reversed(mut events: Vec<EventRow>, limit: usize) -> Vec<EventRow> {
    if events.len() > limit {
        events.drain(0..events.len() - limit);
    }
    events.reverse();
    events
}

/// The status report's `total_events` is the full event count. `tail_reversed`
/// already truncated to the recent window, so recompute the full total from the
/// by-estate breakdown (which counts ALL events, pre-truncation). Mirrors the
/// Swift `status` which reads `events.count` before truncating.
fn recent_total_events(_recent: &[EventRow], by_estate: &[GroupCount]) -> i64 {
    by_estate.iter().map(|g| g.event_count).sum()
}

/// Clone a `MetricRow` (ObserverSink's MetricRow is not `Clone`, so reconstruct).
fn clone_metric(m: &MetricRow) -> MetricRow {
    MetricRow {
        row_id: m.row_id,
        name: m.name.clone(),
        value: m.value,
        tags: m.tags.clone(),
        ts_epoch: m.ts_epoch,
        dropbox_id: m.dropbox_id.clone(),
    }
}

/// Build per-dropbox sample summaries from the metric + event scans, sorted by
/// dropbox name. Mirrors the by-dropbox block of Swift `serverPayload`.
/// Build per-dropbox summary payloads from aggregate query results.
///
/// Takes pre-computed metric aggregates (count + last_ts from SQL) and raw
/// event rows, so no full metric_samples table scan is needed. The aggregate
/// queries issue O(|dropboxes|) targeted SQL calls instead of decoding every
/// metric row in the store. Mirrors the Swift serverPayload() helper.
fn build_dropbox_summaries_from_aggregates(
    metric_aggregates: &[DropboxMetricAggregate],
    events: &[EventRow],
) -> Vec<DropboxSummaryPayload> {
    let mut metric_counts: BTreeMap<String, i64> = BTreeMap::new();
    let mut last_metric_ts_iso: BTreeMap<String, String> = BTreeMap::new();
    for agg in metric_aggregates {
        metric_counts.insert(agg.dropbox_id.clone(), agg.metric_count as i64);
        if let Some(ref ts) = agg.last_metric_ts {
            last_metric_ts_iso.insert(agg.dropbox_id.clone(), ts.clone());
        }
    }
    let mut event_counts: BTreeMap<String, i64> = BTreeMap::new();
    let mut last_event_ts: BTreeMap<String, f64> = BTreeMap::new();
    for ev in events {
        *event_counts.entry(ev.dropbox_id.clone()).or_insert(0) += 1;
        let e = last_event_ts.entry(ev.dropbox_id.clone()).or_insert(f64::MIN);
        if ev.ts_epoch > *e {
            *e = ev.ts_epoch;
        }
    }
    let mut ids: BTreeSet<String> = BTreeSet::new();
    ids.extend(metric_counts.keys().cloned());
    ids.extend(event_counts.keys().cloned());
    ids.into_iter()
        .map(|id| {
            // last_seen is the later of the most-recent metric and most-recent event.
            let lm_iso = last_metric_ts_iso.get(&id).cloned();
            let le = last_event_ts.get(&id).copied().filter(|t| *t > f64::MIN);
            let last_seen_iso = match (lm_iso, le) {
                (Some(m_iso), Some(e_epoch)) => {
                    // Compare via ISO-8601 string lexicographic order (UTC, same format).
                    let e_iso = epoch_to_iso8601(e_epoch);
                    Some(if m_iso >= e_iso { m_iso } else { e_iso })
                }
                (Some(m_iso), None) => Some(m_iso),
                (None, Some(e_epoch)) => Some(epoch_to_iso8601(e_epoch)),
                (None, None) => None,
            };
            DropboxSummaryPayload {
                name: id.clone(),
                metric_count: *metric_counts.get(&id).unwrap_or(&0),
                event_count: *event_counts.get(&id).unwrap_or(&0),
                last_seen_iso,
            }
        })
        .collect()
}

/// Project an `EventRow` to its metadata-only wire payload. An empty estate row
/// id projects to `None` so the wire carries null, never "". Mirrors Swift
/// `MootManager.projectEvent`.
pub fn project_event(e: &EventRow) -> EventPayload {
    EventPayload {
        ts: epoch_to_iso8601(e.ts_epoch),
        kind: e.kind.clone(),
        noun_type: e.noun_type,
        estate: e.estate.clone(),
        dropbox: e.dropbox_id.clone(),
        drawer_id: if e.estate_row_id.is_empty() {
            None
        } else {
            Some(e.estate_row_id.clone())
        },
    }
}

/// Format an epoch-seconds instant as ISO-8601 UTC TEXT
/// ("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"), matching the store's on-disk format so wire
/// timestamps equal stored ones. Mirrors Swift `MootManager.iso8601String(from:)`.
///
/// Hand-rolled (no chrono dependency — the host carries zero new external deps)
/// using the civil-from-days algorithm. UTC only.
pub fn epoch_to_iso8601(epoch_secs: f64) -> String {
    let total_millis = (epoch_secs * 1000.0).round() as i64;
    let secs = total_millis.div_euclid(1000);
    let frac_millis = total_millis.rem_euclid(1000);
    let days = secs.div_euclid(86_400);
    let secs_of_day = secs.rem_euclid(86_400);
    let (y, m, d) = civil_from_days(days);
    let hh = secs_of_day / 3600;
    let mm = (secs_of_day % 3600) / 60;
    let ss = secs_of_day % 60;
    format!("{y:04}-{m:02}-{d:02}T{hh:02}:{mm:02}:{ss:02}.{frac_millis:03}Z")
}

/// Civil (y, m, d) date from days-since-1970 — Howard Hinnant's `civil_from_days`.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manager_config::ManagerConfig;

    /// Build a started manager backed by a unique temp directory.
    fn temp_manager() -> MootManager {
        let dir = std::env::temp_dir().join(format!("moot-mgr-rust-test-{}", uuid_hex()));
        std::fs::create_dir_all(&dir).unwrap();
        let store_path = dir.join("stats.sqlite").to_string_lossy().to_string();
        let mut mgr = MootManager::new(ManagerConfig::new(
            store_path,
            crate::manager_config::DEFAULT_RETENTION_WINDOW_SECS,
            crate::manager_config::DEFAULT_RETENTION_CADENCE_SECS,
        ));
        mgr.start().expect("manager start must succeed in tests");
        mgr
    }

    /// Tiny deterministic ID for temp paths (no rand dep).
    fn uuid_hex() -> String {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .subsec_nanos();
        format!("{:08x}-{:p}", nanos, &nanos as *const _)
    }

    // ── community count cap — unbounded allocation guard ─────────────────────

    #[test]
    fn graph_payload_community_count_capped_at_10000() {
        // A crafted metric carrying a value far above any sane community count
        // must be clamped to 10,000 so graph_payload() cannot allocate an
        // unbounded Vec in response to a crafted sample.
        let mgr = temp_manager();
        let store = mgr.stats_store().unwrap();
        // Insert a metric with a value of 999_999 — simulates a crafted sample.
        let mut tags = std::collections::BTreeMap::new();
        tags.insert("estate".to_string(), "home".to_string());
        tags.insert("node_count".to_string(), "12".to_string());
        tags.insert("community_count".to_string(), "999999".to_string());
        store
            .insert_metric("community.assignment", 999_999.0, &tags, 100.0, "substrateml")
            .expect("insert must succeed");
        // graph_payload() now derives dropboxIDs from events so it can use the
        // indexed query path.  Insert a matching event so "substrateml" appears
        // in viz_dropbox_ids and the metric row above is found.
        store
            .insert_event("write", 1, "node-0", "home", 100.0, "substrateml")
            .expect("insert event must succeed");
        let payload = mgr.graph_payload(100.0, None).expect("graph_payload must succeed");
        // The cap is 10,000 — the Vec must never exceed that regardless of the
        // stored value.
        assert!(
            payload.communities.len() <= 10_000,
            "community count must be capped at 10,000; got {}",
            payload.communities.len()
        );
        assert_eq!(payload.communities.len(), 10_000, "cap is exactly 10,000");
    }

    // ── FIX 2: GraphNodePayload/GraphEdgePayload dropped-field wire contract ────

    #[test]
    fn graph_payload_wire_format_omits_dropped_fields() {
        // Build a 50 k-node GraphPayload and verify that the dropped fields —
        // nounType + lastActiveTs (nodes), decayedWeight + createdTs (edges) —
        // do not appear in the serialised JSON.  Also verifies the payload stays
        // under the 6 MB ceiling established by FIX 2 (the old format was ~7.5 MB
        // for the same fixture).
        use crate::api_payloads::{GraphNodePayload, GraphEdgePayload, GraphPayload};

        let nodes: Vec<GraphNodePayload> = (0u64..50_000)
            .map(|i| GraphNodePayload {
                id: i.to_string(),
                community_id: (i as i64) % 16,
                centrality: 0.5,
                anomaly: false,
                created_ts: None,
                tombstoned_ts: None,
            })
            .collect();
        let edges: Vec<GraphEdgePayload> = (0u64..100)
            .map(|i| GraphEdgePayload {
                source: i.to_string(),
                target: (i + 1).to_string(),
                edge_type: "tunnel".to_string(),
                weight: 0.8,
                tombstoned_ts: None,
            })
            .collect();
        let payload = GraphPayload {
            nodes,
            edges,
            communities: vec![],
            analytics: vec![],
            structure_pending: false,
            pending: vec![],
            generated_ts: Some("2026-07-05T00:00:00Z".to_string()),
            estate: "test".to_string(),
            snapshot_ts: "2026-07-05T00:00:00Z".to_string(),
        };

        let json = serde_json::to_string(&payload).expect("serialise must succeed");

        // --- Size gate ---
        assert!(
            json.len() < 6_000_000,
            "50k-node payload must be < 6 MB; got {} bytes",
            json.len()
        );

        // --- Field-absence gate ---
        assert!(!json.contains("\"nounType\""), "nounType must not appear in wire output");
        assert!(!json.contains("\"lastActiveTs\""), "lastActiveTs must not appear in wire output");
        assert!(!json.contains("\"decayedWeight\""), "decayedWeight must not appear in wire output");
        // createdTs appears on NODES (as explicit null) but not on EDGES.
        // Count occurrences: must equal exactly 50 k (one per node, zero per edge).
        let created_ts_count = json.matches("\"createdTs\"").count();
        assert_eq!(
            created_ts_count, 50_000,
            "createdTs must appear exactly once per node (not edges); got {}",
            created_ts_count
        );
    }

    // ── retention prefs filename — stem-derived, not fixed ───────────────────

    #[test]
    fn retention_prefs_path_derives_from_store_stem() {
        // Two instances in the same parent directory with different store names
        // must write different prefs files — preventing the filename collision
        // that a fixed "moot-mgr-prefs.json" would cause.
        let dir = std::env::temp_dir().join(format!("moot-prefs-stem-{}", uuid_hex()));
        std::fs::create_dir_all(&dir).unwrap();

        let store_a = dir.join("alpha.sqlite").to_string_lossy().to_string();
        let mgr_a = MootManager::new(ManagerConfig::new(
            store_a,
            crate::manager_config::DEFAULT_RETENTION_WINDOW_SECS,
            crate::manager_config::DEFAULT_RETENTION_CADENCE_SECS,
        ));
        let prefs_a = mgr_a.retention_prefs_path();

        let store_b = dir.join("beta.sqlite").to_string_lossy().to_string();
        let mgr_b = MootManager::new(ManagerConfig::new(
            store_b,
            crate::manager_config::DEFAULT_RETENTION_WINDOW_SECS,
            crate::manager_config::DEFAULT_RETENTION_CADENCE_SECS,
        ));
        let prefs_b = mgr_b.retention_prefs_path();

        assert_eq!(
            prefs_a.file_name().unwrap().to_str().unwrap(),
            "alpha-prefs.json",
            "stem-derived prefs filename must match store stem"
        );
        assert_eq!(
            prefs_b.file_name().unwrap().to_str().unwrap(),
            "beta-prefs.json",
            "stem-derived prefs filename must match store stem"
        );
        assert_ne!(prefs_a, prefs_b, "two stores in the same dir must use different prefs files");
    }

    // ── store directory permissions — owner-only (0700) ──────────────────────

    #[cfg(unix)]
    #[test]
    fn start_creates_store_dir_with_0700_permissions() {
        // The stats store directory must not be world- or group-readable.
        // SQLite WAL/SHM files land here and must stay private to the owning user.
        use std::os::unix::fs::MetadataExt;
        let dir = std::env::temp_dir().join(format!("moot-perms-{}", uuid_hex()));
        let store_path = dir.join("stats.sqlite").to_string_lossy().to_string();
        let mut mgr = MootManager::new(ManagerConfig::new(
            store_path,
            crate::manager_config::DEFAULT_RETENTION_WINDOW_SECS,
            crate::manager_config::DEFAULT_RETENTION_CADENCE_SECS,
        ));
        mgr.start().expect("manager start must succeed");
        let meta = std::fs::metadata(&dir).expect("dir must exist after start");
        let mode = meta.mode() & 0o777;
        assert_eq!(mode, 0o700, "store dir must be 0700; got {:o}", mode);
    }
}
