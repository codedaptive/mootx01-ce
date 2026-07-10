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

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use cognition_kit::capability::shipped_capabilities;
use observer_sink::{DropboxMetricAggregate, EventRow, MetricRow, StatsStore};

use crate::api_payloads::{
    AriaCommunityDescriptor, ConfigPayload, DropboxSummaryPayload, EstatePayload, EstatesPayload,
    AriaFoldDescriptor, EventPayload, EventsPayload, GraphAnalyticPayload, GraphBridgePayload,
    GraphCommunityPayload, GraphEdgePayload, GraphFoldPayload, GraphNodePayload, GraphPayload,
    ServerPayload, StoredGraphPayload,
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
    /// true with an honest enumeration. Analytics are sourced locally from the
    /// VizGraph signal samples; communities prefer the snapshot's governor
    /// descriptors enriched via `enrich_communities` (VIZ_V2 L3), keeping the
    /// count-only local rollup when the snapshot predates the communities field.
    /// Mirrors Swift `MootManager.graphPayload(now:estate:)`.
    pub fn graph_payload(
        &self,
        now_epoch: f64,
        estate: Option<&str>,
    ) -> Result<GraphPayload, ManagerError> {
        self.graph_payload_view(now_epoch, estate, None, None)
    }

    pub fn graph_payload_view(
        &self,
        now_epoch: f64,
        estate: Option<&str>,
        level: Option<&str>,
        focus: Option<&str>,
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
                    code: None,
                    label: None,
                    size: 0,
                    stable_key: None, x: None, y: None, z: None,
                    fold_count: None, representative_ids: None,
                    classification_purity: None,
                });
            }
        }

        // Read the topology snapshot from the shared stats store.
        let mut live_nodes = Vec::new();
        let mut live_edges = Vec::new();
        let mut folds: Vec<GraphFoldPayload> = Vec::new();
        let mut bridges: Vec<GraphBridgePayload> = Vec::new();
        let mut topology_version = 2_i64;
        let mut coordinate_frame_version = 0_i64;
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
                    // VIZ_V2 L3: prefer the governor's real community
                    // descriptors, enriched with FDC labels (dominantUdcCode
                    // passed through as `code` — it drives the digit-derived
                    // community color). Keep the local count-only rollup when
                    // the snapshot predates the communities field. Mirrors the
                    // Swift host's enrichCommunities path.
                    if let Some(raw) = &stored.communities {
                        communities = Self::enrich_communities(raw);
                    }
                    folds = Self::enrich_folds(&stored.folds);
                    bridges = stored.bridges;
                    topology_version = stored.topology_version.unwrap_or(2);
                    coordinate_frame_version = stored.coordinate_frame_version.unwrap_or(0);
                }
            }
        }

        let mut resolved_level = if topology_version >= 3 { level.unwrap_or("full") } else { "full" };
        if !matches!(resolved_level, "estate" | "community" | "local" | "full") {
            resolved_level = "estate";
        }
        if matches!(resolved_level, "community" | "local")
            && focus.filter(|value| !value.is_empty()).is_none() {
            resolved_level = "estate";
        }
        let mut response_nodes = live_nodes.clone();
        let mut response_edges = live_edges.clone();
        let mut response_communities = communities.clone();
        let mut response_folds = folds.clone();
        let mut response_bridges = bridges.clone();
        let total_node_count = live_nodes.len();
        let total_edge_count = live_edges.len();
        let mut lod_truncated = false;
        let mut estate_visible_keys: Option<HashSet<String>> = None;
        if topology_version >= 3 {
            match resolved_level {
                "estate" => {
                    response_nodes.clear(); response_edges.clear(); response_folds.clear();
                    response_bridges.retain(|bridge| bridge.level == "community");
                    if response_communities.len() > 96 {
                        response_communities.sort_by(|a, b| b.size.cmp(&a.size)
                            .then_with(|| a.stable_key.cmp(&b.stable_key)));
                        let omitted = response_communities.split_off(95);
                        let omitted_size: i64 = omitted.iter().map(|community| community.size).sum();
                        let divisor = omitted_size.max(1) as f64;
                        let weighted = |axis: fn(&GraphCommunityPayload) -> Option<f64>| -> f64 {
                            omitted.iter().map(|community| axis(community).unwrap_or(0.0) * community.size as f64).sum::<f64>() / divisor
                        };
                        response_communities.push(GraphCommunityPayload {
                            id: -2, code: None, label: Some("Other structure".into()), size: omitted_size,
                            stable_key: Some("__other__".into()),
                            x: Some(weighted(|c| c.x)), y: Some(weighted(|c| c.y)), z: Some(weighted(|c| c.z)),
                            fold_count: Some(omitted.iter().map(|c| c.fold_count.unwrap_or(0)).sum()),
                            representative_ids: None, classification_purity: None,
                        });
                        let visible: HashSet<String> = response_communities.iter()
                            .filter_map(|community| community.stable_key.clone())
                            .filter(|key| key != "__other__").collect();
                        let mut buckets: BTreeMap<(String, String, String), (f64, i64)> = BTreeMap::new();
                        for bridge in &response_bridges {
                            let raw_source = if visible.contains(&bridge.source_key) { bridge.source_key.clone() } else { "__other__".into() };
                            let raw_target = if visible.contains(&bridge.target_key) { bridge.target_key.clone() } else { "__other__".into() };
                            if raw_source == raw_target { continue; }
                            let (source, target) = if raw_source < raw_target { (raw_source, raw_target) } else { (raw_target, raw_source) };
                            let value = buckets.entry((source, target, bridge.edge_type.clone())).or_insert((0.0, 0));
                            value.0 += bridge.weight; value.1 += bridge.edge_count;
                        }
                        response_bridges = buckets.into_iter().map(|((source_key, target_key, edge_type), (weight, edge_count))| GraphBridgePayload {
                            level: "community".into(), source_key, target_key, edge_type, weight, edge_count,
                        }).collect();
                        estate_visible_keys = Some(visible);
                        lod_truncated = true;
                    }
                }
                "community" => {
                    let focus = focus.expect("community level normalized to require focus");
                    let fold_set: HashSet<String> = folds.iter()
                        .filter(|fold| fold.community_key == focus)
                        .map(|fold| fold.stable_key.clone()).collect();
                    response_communities.retain(|community| community.stable_key.as_deref() == Some(focus));
                    response_folds.retain(|fold| fold.community_key == focus);
                    response_bridges.retain(|bridge| bridge.level == "fold"
                        && fold_set.contains(&bridge.source_key) && fold_set.contains(&bridge.target_key));
                    response_nodes.clear();
                    response_edges.clear();
                }
                "local" => {
                    let focus = focus.expect("local level normalized to require focus");
                    response_nodes.retain(|node| node.fold_key.as_deref() == Some(focus)
                        || node.community_key.as_deref() == Some(focus));
                    let node_set: HashSet<&str> = response_nodes.iter().map(|node| node.id.as_str()).collect();
                    response_edges.retain(|edge| node_set.contains(edge.source.as_str()) && node_set.contains(edge.target.as_str()));
                    if let Some(fold) = folds.iter().find(|fold| fold.stable_key == focus) {
                        response_communities.retain(|community| community.stable_key.as_deref() == Some(fold.community_key.as_str()));
                        response_folds.retain(|candidate| candidate.stable_key == fold.stable_key);
                    } else {
                        response_communities.retain(|community| community.stable_key.as_deref() == Some(focus));
                        response_folds.retain(|fold| fold.community_key == focus);
                    }
                    response_bridges.clear();
                    if response_nodes.len() > 2_000 {
                        response_nodes.sort_by(|a, b| b.representative.cmp(&a.representative)
                            .then_with(|| b.centrality.total_cmp(&a.centrality)).then_with(|| a.id.cmp(&b.id)));
                        response_nodes.truncate(2_000);
                        let node_set: HashSet<&str> = response_nodes.iter().map(|node| node.id.as_str()).collect();
                        response_edges.retain(|edge| node_set.contains(edge.source.as_str()) && node_set.contains(edge.target.as_str()));
                        lod_truncated = true;
                    }
                    if response_edges.len() > 12_000 {
                        response_edges = bounded_local_edges(response_edges, &response_nodes, 12_000);
                        lod_truncated = true;
                    }
                }
                _ => {}
            }
        }

        let mut activity_pairs = Vec::new();
        if topology_version >= 3 && matches!(resolved_level, "estate" | "community") {
            let node_by_id: HashMap<&str, &crate::api_payloads::GraphNodePayload> =
                live_nodes.iter().map(|node| (node.id.as_str(), node)).collect();
            let mut seen = HashSet::new();
            for event in viz_events.iter().rev() {
                if activity_pairs.len() >= 2_000 || event.estate_row_id.is_empty()
                    || !seen.insert(event.estate_row_id.as_str()) { continue; }
                let Some(node) = node_by_id.get(event.estate_row_id.as_str()) else { continue };
                let mut key = if resolved_level == "estate" { node.community_key.clone() } else { node.fold_key.clone() };
                if resolved_level == "estate" {
                    if let (Some(visible), Some(raw)) = (&estate_visible_keys, &key) {
                        if !visible.contains(raw) { key = Some("__other__".into()); }
                    }
                }
                if let Some(key) = key.filter(|key| !key.is_empty()) {
                    activity_pairs.push((event.estate_row_id.clone(), key));
                }
            }
        }

        live_nodes = response_nodes;
        live_edges = response_edges;
        communities = response_communities;
        folds = response_folds;
        bridges = response_bridges;

        // FIX 2b — build compact parallel-array wire payload from stored per-object nodes/edges.
        //
        // Parallel node arrays eliminate per-node JSON key overhead.
        // Compact edges `[si, ti, w, et]` eliminate UUID duplication in edge endpoints
        // (70k edges × 2 × 36-char UUIDs ≈ 5 MB saved).  Mirrors Swift GraphPayload init(nodes:edges:).
        use crate::api_payloads::{CompactEdge, topology_epoch_seconds};

        let node_count = live_nodes.len();
        let mut ids        = Vec::with_capacity(node_count);
        let mut community_id = Vec::with_capacity(node_count);
        let mut centrality  = Vec::with_capacity(node_count);
        let mut anomaly     = Vec::with_capacity(node_count);
        let mut created_ts  = Vec::with_capacity(node_count);
        // Sparse tombstone map: string(index) → ISO-8601 ts.
        let mut tombstoned: HashMap<String, String> = HashMap::new();
        // Build the id→index map for edge endpoint resolution.
        let mut id_to_idx: HashMap<String, usize> = HashMap::with_capacity(node_count);
        // Per-node classification-code dictionary (V2-P1b): deduped, first-
        // seen order. code_to_index resolves a repeated code to its existing
        // dictionary slot in O(1) instead of re-appending it — this is what
        // keeps `codes` sized to the distinct-code count (~10^2) rather than
        // the node count (up to 50k), inside the existing 5 MB wire ceiling.
        // Codes cross this surface on the same basis as `/api/lattice`: a
        // classification code is a pure function of the pinned public FDC/UDC
        // frame, never memory content.
        let mut codes: Vec<String> = Vec::new();
        let mut code_to_index: HashMap<String, i64> = HashMap::new();
        let mut code_index: Vec<i64> = Vec::with_capacity(node_count);
        let mut positions = Vec::with_capacity(node_count * 3);
        let mut representatives = Vec::new();
        let has_complete_positions = !live_nodes.is_empty() && live_nodes.iter().all(|node| {
            node.x.is_some_and(f64::is_finite)
                && node.y.is_some_and(f64::is_finite)
                && node.z.is_some_and(f64::is_finite)
        });

        for (idx, n) in live_nodes.iter().enumerate() {
            id_to_idx.insert(n.id.clone(), idx);
            ids.push(n.id.clone());
            community_id.push(n.community_id);
            centrality.push(n.centrality);
            anomaly.push(n.anomaly);
            created_ts.push(n.created_ts.clone());
            if let Some(ts) = &n.tombstoned_ts {
                tombstoned.insert(idx.to_string(), ts.clone());
            }
            // Absent/empty udc_code → -1 sentinel (no code), never a dictionary entry.
            let code_idx: i64 = match n.udc_code.as_deref().filter(|c| !c.is_empty()) {
                Some(code) => {
                    if let Some(&existing) = code_to_index.get(code) {
                        existing
                    } else {
                        let new_idx = codes.len() as i64;
                        codes.push(code.to_string());
                        code_to_index.insert(code.to_string(), new_idx);
                        new_idx
                    }
                }
                None => -1,
            };
            code_index.push(code_idx);
            let quantize = |value: Option<f64>| -> i16 {
                (value.unwrap_or(0.0).clamp(-1.0, 1.0) * 32_767.0).round() as i16
            };
            if has_complete_positions {
                positions.extend([quantize(n.x), quantize(n.y), quantize(n.z)]);
            }
            if n.representative { representatives.push(idx); }
        }

        // One shared epoch origin turns 10-digit timestamps into small offsets,
        // keeping truthful 70k-edge replay inside the 5 MB payload ceiling.
        let edge_time_origin = live_edges.iter()
            .flat_map(|e| [
                topology_epoch_seconds(e.created_ts.as_deref()),
                topology_epoch_seconds(e.tombstoned_ts.as_deref()),
            ])
            .flatten()
            .min();

        // Map stored per-object edges → compact index-pair edges.
        // Edges whose endpoints are not in the node set are dropped (safety guard
        // against snapshot inconsistency between node and edge lists).
        let compact_edges: Vec<CompactEdge> = live_edges.iter().filter_map(|e| {
            let si = id_to_idx.get(&e.source)?;
            let ti = id_to_idx.get(&e.target)?;
            Some(CompactEdge {
                si: *si,
                ti: *ti,
                w: e.weight,
                et: CompactEdge::edge_type_ordinal(&e.edge_type),
                born: topology_epoch_seconds(e.created_ts.as_deref())
                    .and_then(|t| edge_time_origin.map(|origin| t - origin)),
                dead: topology_epoch_seconds(e.tombstoned_ts.as_deref())
                    .and_then(|t| edge_time_origin.map(|origin| t - origin)),
            })
        }).collect();

        Ok(GraphPayload {
            ids,
            community_id,
            centrality,
            anomaly,
            created_ts,
            tombstoned,
            codes,
            code_index,
            position_q16: encode_q16_base64(&positions),
            representatives,
            edges: compact_edges,
            edge_time_origin,
            communities,
            folds,
            bridges,
            topology_version,
            coordinate_frame_version,
            view_level: resolved_level.to_string(),
            focus_key: focus.filter(|value| !value.is_empty()).map(str::to_owned),
            activity_ids: activity_pairs.iter().map(|pair| pair.0.clone()).collect(),
            activity_keys: activity_pairs.iter().map(|pair| pair.1.clone()).collect(),
            total_node_count,
            total_edge_count,
            lod_truncated,
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

    /// Enrich governor community descriptors to the browser wire shape
    /// (VIZ_V2 L3): `{id, size, dominantUdcCode}` → `{id, code, label, size}`.
    ///
    /// The dominant UDC code is resolved to its FDC heading label via
    /// `Fdc::label` (bundled taxonomy — never estate content) and the code
    /// itself is passed through: the dashboard derives the community color
    /// from its digits (hundreds → hue, tens → shade, ones → brightness).
    /// The code crosses this surface on the same basis as `/api/lattice`,
    /// which already serves raw classification codes — a code is a pure
    /// function of the pinned public frame, never memory content. An empty
    /// or absent code yields explicit nulls. Governor order is preserved.
    /// Mirrors Swift `MootManager.enrichCommunities(_:)`.
    fn enrich_communities(raw: &[AriaCommunityDescriptor]) -> Vec<GraphCommunityPayload> {
        raw.iter()
            .map(|d| {
                let code = d
                    .dominant_udc_code
                    .as_deref()
                    .filter(|c| !c.is_empty() && *c != "000")
                    .map(str::to_owned);
                let label = code.as_deref().and_then(lattice_lib::Fdc::label);
                GraphCommunityPayload {
                    id: d.id,
                    code,
                    label,
                    size: d.size,
                    stable_key: d.stable_key.clone(),
                    x: d.x, y: d.y, z: d.z,
                    fold_count: d.fold_count,
                    representative_ids: d.representative_ids.clone(),
                    classification_purity: d.classification_purity,
                }
            })
            .collect()
    }

    fn enrich_folds(raw: &[AriaFoldDescriptor]) -> Vec<GraphFoldPayload> {
        raw.iter().map(|descriptor| {
            let code = descriptor.dominant_udc_code.as_deref()
                .filter(|code| !code.is_empty() && *code != "000").map(str::to_owned);
            let label = code.as_deref().and_then(lattice_lib::Fdc::label);
            GraphFoldPayload {
                stable_key: descriptor.stable_key.clone(),
                community_key: descriptor.community_key.clone(),
                code, label, size: descriptor.size,
                x: descriptor.x, y: descriptor.y, z: descriptor.z,
                representative_ids: descriptor.representative_ids.clone(),
            }
        }).collect()
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

/// Keep Local views bounded while retaining a deterministic structural
/// spanning forest. Remaining slots prefer stronger evidence and edges that
/// touch representative nodes.
fn bounded_local_edges(
    edges: Vec<GraphEdgePayload>,
    nodes: &[GraphNodePayload],
    limit: usize,
) -> Vec<GraphEdgePayload> {
    if limit == 0 {
        return Vec::new();
    }
    if edges.len() <= limit {
        return edges;
    }
    let representatives: HashSet<&str> = nodes
        .iter()
        .filter(|node| node.representative)
        .map(|node| node.id.as_str())
        .collect();
    let type_priority = |edge_type: &str| match edge_type {
        "tunnel" => 0,
        "kgFact" => 1,
        "association" => 2,
        _ => 3,
    };
    let mut ranked: Vec<usize> = (0..edges.len()).collect();
    ranked.sort_by(|lhs, rhs| {
        let left = &edges[*lhs];
        let right = &edges[*rhs];
        type_priority(&left.edge_type)
            .cmp(&type_priority(&right.edge_type))
            .then_with(|| {
                let left_representative = representatives.contains(left.source.as_str())
                    || representatives.contains(left.target.as_str());
                let right_representative = representatives.contains(right.source.as_str())
                    || representatives.contains(right.target.as_str());
                right_representative.cmp(&left_representative)
            })
            .then_with(|| right.weight.total_cmp(&left.weight))
            .then_with(|| left.source.cmp(&right.source))
            .then_with(|| left.target.cmp(&right.target))
            .then_with(|| left.edge_type.cmp(&right.edge_type))
            .then_with(|| lhs.cmp(rhs))
    });

    let node_index: HashMap<&str, usize> = nodes
        .iter()
        .enumerate()
        .map(|(index, node)| (node.id.as_str(), index))
        .collect();
    let mut parent: Vec<usize> = (0..nodes.len()).collect();
    fn root(parent: &mut [usize], index: usize) -> usize {
        let mut value = index;
        while parent[value] != value {
            value = parent[value];
        }
        let mut cursor = index;
        while parent[cursor] != cursor {
            let next = parent[cursor];
            parent[cursor] = value;
            cursor = next;
        }
        value
    }
    let mut forest = HashSet::new();
    for &index in &ranked {
        let edge = &edges[index];
        if matches!(edge.edge_type.as_str(), "nmf_bond" | "lattice") {
            continue;
        }
        let (Some(&source), Some(&target)) = (
            node_index.get(edge.source.as_str()),
            node_index.get(edge.target.as_str()),
        ) else {
            continue;
        };
        let source_root = root(&mut parent, source);
        let target_root = root(&mut parent, target);
        if source_root != target_root {
            parent[target_root] = source_root;
            forest.insert(index);
        }
    }

    let mut result = Vec::with_capacity(limit);
    for &index in ranked.iter().filter(|index| forest.contains(index)) {
        if result.len() == limit {
            return result;
        }
        result.push(edges[index].clone());
    }
    for &index in ranked.iter().filter(|index| !forest.contains(index)) {
        if result.len() == limit {
            break;
        }
        result.push(edges[index].clone());
    }
    result
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

/// Dependency-free RFC 4648 base64 for the little-endian Q16 coordinate block.
fn encode_q16_base64(values: &[i16]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut bytes = Vec::with_capacity(values.len() * 2);
    for value in values { bytes.extend_from_slice(&value.to_le_bytes()); }
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let a = chunk[0];
        let b = chunk.get(1).copied().unwrap_or(0);
        let c = chunk.get(2).copied().unwrap_or(0);
        out.push(TABLE[(a >> 2) as usize] as char);
        out.push(TABLE[(((a & 0x03) << 4) | (b >> 4)) as usize] as char);
        out.push(if chunk.len() > 1 { TABLE[(((b & 0x0f) << 2) | (c >> 6)) as usize] as char } else { '=' });
        out.push(if chunk.len() > 2 { TABLE[(c & 0x3f) as usize] as char } else { '=' });
    }
    out
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

    #[test]
    fn local_edge_budget_preserves_structural_spanning_forest() {
        let nodes: Vec<GraphNodePayload> = serde_json::from_value(serde_json::json!([
            {"id":"a","representative":true}, {"id":"b"}, {"id":"c"}, {"id":"d"}
        ])).unwrap();
        let mut edges: Vec<GraphEdgePayload> = serde_json::from_value(serde_json::json!([
            {"source":"a","target":"b","edgeType":"tunnel","weight":1.0},
            {"source":"b","target":"c","edgeType":"tunnel","weight":0.8},
            {"source":"c","target":"d","edgeType":"kgFact","weight":0.3}
        ])).unwrap();
        for index in 0..20 {
            edges.push(serde_json::from_value(serde_json::json!({
                "source": if index % 2 == 0 { "a" } else { "b" },
                "target": if index % 2 == 0 { "d" } else { "c" },
                "edgeType":"nmf_bond","weight":0.2
            })).unwrap());
        }
        let bounded = bounded_local_edges(edges, &nodes, 3);
        assert_eq!(bounded.len(), 3);
        assert!(bounded.iter().all(|edge| edge.edge_type != "nmf_bond"));
        let endpoints: HashSet<&str> = bounded.iter()
            .flat_map(|edge| [edge.source.as_str(), edge.target.as_str()]).collect();
        assert_eq!(endpoints, HashSet::from(["a", "b", "c", "d"]));
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

    // ── FIX 2b: compact parallel-array wire format — size and shape contract ────

    #[test]
    fn graph_payload_wire_format_omits_dropped_fields() {
        // Build a 50 k-node, 70 k-edge compact GraphPayload (FIX 2b format) and verify:
        //  - payload is under 5 MB (target for 51k nodes / 70k edges)
        //  - "ids" key present (parallel-array format)
        //  - "nodes" key absent (old per-object format gone)
        //  - "source" / "target" keys absent (edges are index-pair arrays now)
        //  - "createdTs" appears once (as the parallel-array key, not per-node)
        //  - dropped fields (nounType, lastActiveTs, decayedWeight) absent
        //  - "codes"/"codeIndex" dictionary-encode ~135 distinct codes across
        //    the 50k nodes and the payload STILL stays under the 5 MB ceiling
        //    (V2-P1b)
        use crate::api_payloads::{CompactEdge, GraphPayload};
        use std::collections::HashMap;

        let n = 50_000usize;
        let ids: Vec<String>       = (0..n).map(|i| format!("{:08x}-0000-0000-0000-{:012x}", i, i)).collect();
        let community_id: Vec<i64> = (0..n).map(|i| (i as i64) % 16).collect();
        let centrality: Vec<f64>   = vec![0.5; n];
        let anomaly: Vec<bool>     = vec![false; n];
        let created_ts: Vec<Option<String>> = vec![None; n];
        let tombstoned: HashMap<String, String> = HashMap::new();

        // ~135 distinct classification codes cycled across the 50k nodes —
        // the dictionary stays sized to the distinct-code count, not the
        // node count, so this must not meaningfully move the payload size.
        let distinct_code_count = 135usize;
        let codes: Vec<String> = (0..distinct_code_count).map(|i| format!("{:03}", i)).collect();
        let code_index: Vec<i64> = (0..n).map(|i| (i % distinct_code_count) as i64).collect();

        // 70k edges using sequential index pairs so endpoint indices are valid.
        let edges: Vec<CompactEdge> = (0u64..70_000)
            .map(|i| {
                let si = (i as usize) % n;
                let ti = (i as usize + 1) % n;
                CompactEdge {
                    si, ti, w: 0.8, et: 0,
                    // Worst common case: every explicit tunnel owns a birth.
                    born: Some(0), dead: None,
                }
            })
            .collect();

        let payload = GraphPayload {
            ids,
            community_id,
            centrality,
            anomaly,
            created_ts,
            tombstoned,
            codes,
            code_index,
            position_q16: encode_q16_base64(&vec![0; n * 3]),
            representatives: vec![],
            edges,
            edge_time_origin: Some(1_700_000_000),
            communities: vec![],
            folds: vec![],
            bridges: vec![],
            topology_version: 3,
            coordinate_frame_version: 1,
            view_level: "full".to_string(),
            focus_key: None,
            activity_ids: vec![],
            activity_keys: vec![],
            total_node_count: n,
            total_edge_count: 70_000,
            lod_truncated: false,
            analytics: vec![],
            structure_pending: false,
            pending: vec![],
            generated_ts: Some("2026-07-05T00:00:00Z".to_string()),
            estate: "test".to_string(),
            snapshot_ts: "2026-07-05T00:00:00Z".to_string(),
        };

        let json = serde_json::to_string(&payload).expect("serialise must succeed");

        // --- Size gate: compact format + code dictionary and within 5 MB ceiling ---
        assert!(
            json.len() < 5_000_000,
            "50k-node/70k-edge payload with 135-code dictionary must be < 5 MB (compact format); got {} bytes",
            json.len()
        );

        // --- Format gate: parallel-array keys present ---
        assert!(json.contains("\"ids\""),        "\"ids\" key must appear in compact format");
        assert!(json.contains("\"communityId\""),"\"communityId\" key must appear in compact format");
        assert!(json.contains("\"codes\""),      "\"codes\" key must appear (V2-P1b dictionary)");
        assert!(json.contains("\"codeIndex\""),  "\"codeIndex\" key must appear (V2-P1b dictionary)");

        // --- Format gate: old per-object keys absent ---
        assert!(!json.contains("\"nodes\""),  "\"nodes\" key must NOT appear (compact format)");
        assert!(!json.contains("\"source\""), "\"source\" edge key must NOT appear (compact format)");
        assert!(!json.contains("\"target\""), "\"target\" edge key must NOT appear (compact format)");

        // --- Dropped-field gate ---
        assert!(!json.contains("\"nounType\""),      "nounType must not appear in wire output");
        assert!(!json.contains("\"lastActiveTs\""),  "lastActiveTs must not appear in wire output");
        assert!(!json.contains("\"decayedWeight\""), "decayedWeight must not appear in wire output");

        // createdTs appears exactly once — as the parallel-array key, not per-node.
        let created_ts_key_count = json.matches("\"createdTs\"").count();
        assert_eq!(
            created_ts_key_count, 1,
            "\"createdTs\" must appear exactly once (as the array key); got {}",
            created_ts_key_count
        );
    }

    // ── V2-P1b: per-node classification codes — dictionary encoding ──────────

    #[test]
    fn graph_payload_codes_dedupe_in_first_seen_order() {
        // Four nodes: n1="657", n2="615.85", n3="657" (repeat — must reuse
        // n1's dictionary slot, not append a duplicate), n4 has no udcCode
        // key at all (absent — tolerant decode, sentinel -1).
        let mgr = temp_manager();
        let store = mgr.stats_store().unwrap();
        let snapshot = r#"{"nodes":[
            {"id":"n1","communityId":0,"centrality":0.1,"anomaly":false,"udcCode":"657"},
            {"id":"n2","communityId":0,"centrality":0.2,"anomaly":false,"udcCode":"615.85"},
            {"id":"n3","communityId":0,"centrality":0.3,"anomaly":false,"udcCode":"657"},
            {"id":"n4","communityId":0,"centrality":0.4,"anomaly":false}
        ],"edges":[],"structurePending":false}"#;
        store.write_topology_snapshot("estate-codes", 100.0, snapshot, None).unwrap();
        let payload = mgr.graph_payload(100.0, Some("estate-codes")).expect("graph_payload must succeed");

        // Dictionary is deduped, first-seen order: "657" (n1) before "615.85" (n2).
        assert_eq!(payload.codes, vec!["657".to_string(), "615.85".to_string()]);
        // codeIndex is parallel to ids: n1→0, n2→1, n3→0 (reused slot), n4→-1 (absent).
        assert_eq!(payload.ids, vec!["n1", "n2", "n3", "n4"]);
        assert_eq!(payload.code_index, vec![0, 1, 0, -1]);
    }

    #[test]
    fn graph_payload_empty_udc_code_is_sentinel_not_dictionary_entry() {
        // An explicit empty-string udcCode is treated identically to an
        // absent key — never a "" entry in the dictionary.
        let mgr = temp_manager();
        let store = mgr.stats_store().unwrap();
        let snapshot = r#"{"nodes":[
            {"id":"n1","communityId":0,"centrality":0.1,"anomaly":false,"udcCode":""},
            {"id":"n2","communityId":0,"centrality":0.2,"anomaly":false,"udcCode":"540"}
        ],"edges":[],"structurePending":false}"#;
        store.write_topology_snapshot("estate-empty-code", 100.0, snapshot, None).unwrap();
        let payload = mgr.graph_payload(100.0, Some("estate-empty-code")).expect("graph_payload must succeed");

        assert_eq!(payload.codes, vec!["540".to_string()]);
        assert_eq!(payload.code_index, vec![-1, 0]);
    }

    #[test]
    fn graph_payload_tolerates_snapshot_predating_udc_code() {
        // A snapshot written before V2-P1b — no node carries a udcCode key
        // anywhere. Decode must not error; every node gets the -1 sentinel
        // and the dictionary stays empty.
        let mgr = temp_manager();
        let store = mgr.stats_store().unwrap();
        let snapshot = r#"{"nodes":[
            {"id":"n1","communityId":0,"centrality":0.1,"anomaly":false},
            {"id":"n2","communityId":1,"centrality":0.2,"anomaly":false}
        ],"edges":[],"structurePending":false}"#;
        store.write_topology_snapshot("estate-old", 100.0, snapshot, None).unwrap();
        let payload = mgr.graph_payload(100.0, Some("estate-old")).expect("graph_payload must succeed");

        assert!(payload.codes.is_empty(), "no udcCode anywhere → empty dictionary");
        assert_eq!(payload.code_index, vec![-1, -1]);
    }

    #[test]
    fn graph_payload_fallback_codes_are_empty_not_null() {
        // No snapshot written yet (structurePending path) — codes/codeIndex
        // must be present as empty arrays, never omitted or null.
        let mgr = temp_manager();
        let payload = mgr.graph_payload(100.0, None).expect("graph_payload must succeed");
        assert!(payload.structure_pending);
        assert!(payload.codes.is_empty());
        assert!(payload.code_index.is_empty());
        // Confirm the wire actually emits the keys (not an omitted Option).
        let json = serde_json::to_string(&payload).expect("serialise must succeed");
        assert!(json.contains("\"codes\":[]"));
        assert!(json.contains("\"codeIndex\":[]"));
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

    // ── community enrichment (VIZ_V2 L3) — mirrors Swift CommunityEnrichmentTests ──

    #[test]
    fn enrich_communities_treats_000_as_unclassified() {
        if !lattice_lib::Fdc::is_available() {
            return;
        }
        let enriched = MootManager::enrich_communities(&[AriaCommunityDescriptor {
            id: 3,
            size: 7,
            dominant_udc_code: Some("000".into()),
            ..Default::default()
        }]);
        assert_eq!(enriched.len(), 1);
        assert_eq!(enriched[0].id, 3);
        assert_eq!(enriched[0].size, 7);
        assert!(enriched[0].code.is_none());
        assert!(enriched[0].label.is_none());
    }

    #[test]
    fn enrich_communities_empty_or_absent_code_yields_nulls() {
        let enriched = MootManager::enrich_communities(&[
            AriaCommunityDescriptor { id: 0, size: 5, dominant_udc_code: Some("".into()), ..Default::default() },
            AriaCommunityDescriptor { id: 1, size: 2, dominant_udc_code: None, ..Default::default() },
        ]);
        assert!(enriched[0].code.is_none() && enriched[0].label.is_none());
        assert!(enriched[1].code.is_none() && enriched[1].label.is_none());
    }

    #[test]
    fn enriched_community_wire_shape_is_id_code_label_size() {
        // The wire object always carries all four keys, with explicit nulls
        // for absent code/label — and the ARIA-side key name never leaks.
        let enriched = MootManager::enrich_communities(&[AriaCommunityDescriptor {
            id: 4,
            size: 1,
            dominant_udc_code: None,
            ..Default::default()
        }]);
        let json = serde_json::to_value(&enriched[0]).expect("serialize");
        let obj = json.as_object().expect("object");
        let mut keys: Vec<&str> = obj.keys().map(String::as_str).collect();
        keys.sort_unstable();
        assert_eq!(keys, ["code", "id", "label", "size"]);
        assert!(obj["code"].is_null());
        assert!(obj["label"].is_null());
        let text = serde_json::to_string(&enriched).expect("serialize");
        assert!(!text.contains("dominantUdcCode"));
    }

    #[test]
    fn stored_snapshot_communities_decode_and_enrich() {
        // Snapshot envelope with governor descriptors decodes tolerantly
        // (older daemons omit dominantUdcCode) and enriches to wire shape.
        let wire = r#"{"nodes":[],"edges":[],"structurePending":false,
                       "communities":[{"id":0,"size":4,"dominantUdcCode":"000"},
                                      {"id":1,"size":2}]}"#;
        let stored: StoredGraphPayload = serde_json::from_str(wire).expect("decode");
        let raw = stored.communities.expect("communities present");
        let enriched = MootManager::enrich_communities(&raw);
        assert_eq!(enriched.len(), 2);
        assert!(enriched[0].code.is_none());
        assert!(enriched[1].code.is_none());
    }
}
