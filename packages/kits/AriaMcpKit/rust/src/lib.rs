//! `aria-mcp` — the ARIA_MCP Rust server library.
//!
//! This crate is the Rust vertical's counterpart to the Swift `ARIA_MCP`
//! binary (apps/aria-mcp-server). It links the Rust kits (cognition-kit,
//! genius-locus-kit, locus-kit) and hosts them behind a
//! JSON-RPC 2.0 / newline-delimited-JSON stdio transport, matching the
//! Swift server's wire contract exactly.
//!
//! # Architecture
//!
//! ```text
//! stdin (newline-delimited JSON frames)
//!   └─► framing::read_frames
//!         └─► jsonrpc::JSONRPCRequest::decode
//!               └─► dispatcher::Dispatcher::handle
//!                     ├─► tool_list (projected AI-client surface)
//!                     └─► tool_call  ──► dispatch::dispatch_tool
//!                                         ├─► teachme pre-check (intercepts before any runner)
//!                                         ├─► interface_tools (Tier 1–5 + maintenance/admin)
//!                                         ├─► vault_tools (moot_vault_export, moot_vault_import, …)
//!                                         ├─► dataset_tools (moot_file_dataset, moot_dataset_query, moot_dataset_stats; MX-TAB-7b)
//!                                         ├─► recipe_tools (moot_list_lenses, moot_synthesize, …)
//!                                         ├─► lens_tools (moot_lens_keystones … moot_lens_concepts)
//!                                         └─► hint injection (CoachingEngine, non-error results only)
//! stdout (newline-delimited JSON responses)
//! ```
//!
//! # No-FFI law
//!
//! This binary never calls Swift and Swift never calls it. The two servers
//! (Swift ARIA_MCP and this Rust server) are wire-contract peers: the same
//! JSON-RPC methods, the same tool names, the same tool descriptions —
//! but each is a complete, independent vertical using its own kit stack.
//!
//! # Surface boundary
//!
//! Surface: interface (Tier 1–5 + maintenance/admin), 1 federation, recipe, lens, and vault tools.
//! Vault tools are backed by `vault-kit` (`VaultBridge`, `ObsidianAdapter`,
//! `DrawerMapping`). The ARIA layer owns the SHA-256 sidecar manifest for drift
//! detection (Vault drift and candidate handling decision b).
//! The estate is selected by the host through the estate catalog and passed to
//! `runtime::run` as a `RuntimeEstate` (SQLite, PostgreSQL or in-memory).

pub mod build_serial;
pub mod coaching_engine;
// mode_registry: the five-mode roster, RecallVariant enum, and ModeDeclaration parser.
// Modes are advisory and fail-open (mirrors Swift ModeRegistry.swift).
pub mod mode_registry;
// mode_session_state: per-session sticky mode state and call counters.
// Uses Mutex for interior mutability (mirrors Swift ModeSessionState.swift actor).
pub mod mode_session_state;
// periodic_coach: deterministic coaching block renderer.
// Golden-pin tested against Tests/Conformance/modes_coaching_fixture.json.
pub mod periodic_coach;
pub mod dataset_tools;
// dense_row module deleted in COMPOSER-02B: all render sites migrated to result_composer.
pub mod dispatch;
pub mod dispatcher;
pub mod estate_posture;
// monitoring_control: injection seam for daemon telemetry monitoring state.
// AriaMcpKit defines the trait; serve host injects the StatsStore-backed impl.
pub mod monitoring_control;
// dream_runner: one-shot REM-ALPHA dreaming cycle for `mootx01 dream` (T10,
// recall-driven dreaming). Provides `run_one_dreaming_cycle` so the `dream` subcommand
// in `mootx01` can invoke dreaming without a direct dep on neuron-kit.
pub mod dream_runner;
pub mod estate_registry;
// governor_topology_adapter: the AriaMcpKit adapter that bridges
// neuron_kit::GovernorTopologySink → observer_sink::StatsStore.
// NeuronKit owns the governor and the trait; AriaMcpKit owns this adapter.
pub mod governor_topology_adapter;
pub mod http_server;
pub mod interface_tools;
pub mod jsonrpc;
pub mod memory_adapter;
pub mod lens_tools;
pub mod recall_discrimination;
// result_composer: the shared result composer for every ARIA MCP return shape
// (ARIA_MCP_SPEC 2.0.0 § 8 composer invariant). All render functions are free
// functions in this module; the typed intermediates (CandidateRowData,
// ControlSignals, etc.) are exported for use by callers and the conformance
// suite. Public so composer_conformance.rs integration tests can drive it.
pub mod result_composer;
pub mod recipe_tools;
pub mod runtime;
pub mod sensitivity_grant_ledger;
pub mod server;
pub mod session_protocol;
pub mod surfaced_recall_ledger;
pub mod teachme_guides;
pub mod tool_list;
pub mod tool_mutation_inventory;
pub mod vault_tools;

/// Re-export the shared whole-file key entry point so the `mootx01` binary can
/// ensure the estate-encryption key exists at serve startup without a direct
/// dependency on PersistenceKit.
pub use persistence_kit::ensure_install_key;

/// Re-export the key filename so `mootx01 upgrade` can detect whether a key
/// preexisted a migration run — and roll back one the run minted — without a
/// direct dependency on PersistenceKit. Same seam as `ensure_install_key`.
pub use persistence_kit::INSTALL_KEY_FILE;

/// Re-export the plaintext→SQLCipher migration primitives (CE-1.0.35-08,
/// Rust leg) so `mootx01 upgrade` can offer and perform estate encryption
/// without a direct dependency on PersistenceKit. Same seam as
/// `ensure_install_key` above.
pub use persistence_kit::estate_migration;
