//! `GovernorTopologySink` — the host-injection seam for topology snapshot writes.
//!
//! The resident Autonomic Governor (NeuronKit) computes a topology snapshot on a
//! cadence and delivers it to the host via this trait. The host (AriaMcpKit)
//! provides a concrete implementation backed by `observer_sink::StatsStore`.
//!
//! # Why this trait exists
//!
//! `StatsStore` lives in `observer_sink` (a host/telemetry library). NeuronKit is
//! a substrate kit that must not depend on host-layer telemetry — that would
//! invert the layering (AriaMcpKit depends on NeuronKit, not the reverse).
//!
//! The trait is the injection seam: NeuronKit stores `Option<Box<dyn
//! GovernorTopologySink>>` and calls `write_topology_snapshot` through it.
//! AriaMcpKit provides `StatsStoreTopologySink` (wrapping `Arc<StatsStore>`) and
//! passes it at governor construction. Tests pass `None` (no write needed).
//!
//! This mirrors the Swift pattern: `topologyHandler: (@Sendable (String, Date, Data)
//! async -> Void)?` injected into `NeuronKit.AutonomicGovernor` so AriaMcpKit's
//! `AriaResident` calls `StatsStore.writeTopologySnapshot` without NeuronKit ever
//! importing `ObserverSink`.

/// Abstracts topology snapshot persistence for the Autonomic Governor.
///
/// The governor calls `write_topology_snapshot` when a cadence fires and the
/// monitoring gate is on. The trait's only obligation is to durably persist the
/// JSON payload (estate ID, generation timestamp, bytes) in a way the stats-
/// store consumer (moot-mgr) can read back. All error handling and retries are
/// the implementation's responsibility; the governor logs failures and continues.
///
/// `Send + Sync`: the governor holds the sink behind `Option<Box<dyn
/// GovernorTopologySink>>` and may reference it from a spawned thread.
pub trait GovernorTopologySink: Send + Sync {
    /// Persist a topology snapshot for `estate_id`.
    ///
    /// - `estate_id`: the estate UUID string identifying the snapshot row.
    /// - `now_epoch_secs`: generation timestamp as floating-point Unix epoch
    ///   seconds. Matches the `generatedTs` field embedded in `payload`.
    /// - `payload`: UTF-8 JSON snapshot bytes (the same wire shape moot-mgr
    ///   decodes as `GraphNodePayload` / `GraphEdgePayload`).
    /// - `fingerprint`: the stable topology-inputs fingerprint (F5). The
    ///   implementation persists it beside the snapshot so a restarting governor
    ///   can skip graph projection, encoding, and rewriting when inputs are unchanged.
    ///
    /// Returns `Ok(())` on success. Errors are logged by the governor; they
    /// do not propagate to the tick loop.
    fn write_topology_snapshot(
        &self,
        estate_id: &str,
        now_epoch_secs: f64,
        payload: &str,
        fingerprint: &str,
    ) -> Result<(), String>;

    /// Load the persisted topology fingerprint for `estate_id`, if any (F5).
    ///
    /// The governor calls this once on its first topology duty so it can compare
    /// the persisted fingerprint against freshly-computed inputs and skip graph
    /// projection, encoding, and rewriting when they match. Returns `None` when no
    /// snapshot/fingerprint has been persisted yet. A read failure should map to
    /// `None` (the governor then recomputes once, as if nothing was persisted).
    ///
    /// Mirrors Swift's `topologyFingerprintLoader` closure.
    fn load_topology_fingerprint(&self, estate_id: &str) -> Option<String>;

    /// Load the previous snapshot payload for overlap matching and coordinate
    /// continuity. Implementations predating topology V3 may keep the default.
    fn load_topology_snapshot(&self, _estate_id: &str) -> Option<String> {
        None
    }

    /// Return `true` when monitoring is enabled (the topology duty should fire).
    ///
    /// The governor calls this BEFORE any estate read or compute — "off is free".
    /// A read failure must fail OPEN (`true`) so a transient store error never
    /// silently freezes topology. The monitoring flag is read from the
    /// implementation's store on each due cadence, so a moot-mgr on/off flip
    /// takes effect at the next cadence without a restart.
    fn is_monitoring_enabled(&self) -> bool;
}
