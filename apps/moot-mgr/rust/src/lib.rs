//! moot-mgr — the Rust twin of the Swift moot-mgr observer/manager + resident
//! multi-plane host.
//!
//! A headless cross-platform server (Windows and Linux) that:
//!   1. Owns the central ObserverSink `StatsStore` (SQLite) — the global
//!      monitoring on/off switch and the retention window. A PURE OBSERVER at
//!      the manager core: it never hosts an estate DB through the manager.
//!   2. Provisions and tears down estates through GeniusLocusKit (the admin
//!      plane) — the host's privileged writes, reached only via the gated
//!      control surface.
//!   3. Serves the loopback HTTP read-API dashboard (read plane).
//!   4. Exposes a gated local IPC control channel (UDS on Unix, named pipe on
//!      Windows) for the admin/control plane.
//!   5. Runs the retention loop on the configured cadence.
//!
//! This is the wire-contract peer of the Swift host; the internal architecture
//! is idiomatic Rust. Per the no-FFI law this binary is a COMPLETE Rust vertical
//! — it never calls Swift, Swift never calls it.
//!
//! ## What this port resolves
//!
//! The estate-construction path here (cache-on default + provision-with-corpus)
//! closes two parity gaps that existed in Swift but had no Rust home:
//!   - DEBT-1: the cache-on default (`EstateAdmin::resolve_cache_config`).
//!     The Swift host always wraps a LocusKit store in a CachingRowStore;
//!     Rust now does the same via `resolve_cache_config`.
//!   - DEBT-2: provision-with-corpus (the Rust host constructs estates via
//!     `EstateCoordinator::provision`, not `open`, so semantic BM25 recall
//!     is lit from the moment an estate is constructed).
//!
//! ## Not ported (headless Linux scope)
//!
//! The macOS SwiftUI GUI is intentionally not ported — Rust targets headless
//! Linux. The host serves the SAME language-neutral web dashboard assets
//! (HTML/CSS/JS) over the loopback HTTP listener (see `static_assets`).

pub mod admin_payloads;
pub mod api_payloads;
pub mod control_channel;
pub mod daemon_client;
pub mod estate_admin;
pub mod http_read_api;
pub mod manager;
pub mod manager_cli;
pub mod manager_config;
pub mod resident_host;
pub mod static_assets;
pub mod status_report;

pub use admin_payloads::{
    EstateAdminEntry, EstateAdminPayload, EstateAdminRequest, EstateAdminResult, EstateBackendKind,
    EstateLifecycleRequest,
};
pub use estate_admin::{AdminError, EstateAdmin};
pub use http_read_api::{ControlResponse, HttpReadApi};
pub use manager::{ManagerError, MootManager};
pub use manager_cli::{parse, run, usage, ManagerCommand};
pub use manager_config::ManagerConfig;
pub use resident_host::{ResidentHost, ResidentHostConfig};
pub use status_report::{GroupCount, StatusReport};
