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
//!                     ├─► tool_list (5-tier AI-client interface surface, 44 tools)
//!                     └─► tool_call  ──► dispatch::dispatch_tool
//!                                         ├─► teachme pre-check (intercepts before any runner)
//!                                         ├─► interface_tools (Tier 1–5, 19 tools)
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
//! 44 tools: 19 interface (Tier 1–5), 1 federation, 4 recipe, 16 lens, 4 vault.
//! Vault tools are backed by `vault-kit` (`VaultBridge`, `ObsidianAdapter`,
//! `DrawerMapping`). The ARIA layer owns the SHA-256 sidecar manifest for drift
//! detection (ADR-VAULTKIT-002 decision b).
//! SQLite persistence: `ARIA_MCP_SQLITE_PATH`. PostgreSQL: `ARIA_MCP_POSTGRES_URL`.

pub mod autonomic_governor;
pub mod build_serial;
pub mod coaching_engine;
pub mod dispatch;
pub mod dispatcher;
pub mod estate_registry;
pub mod graph_centrality;
pub mod http_server;
pub mod interface_tools;
pub mod jsonrpc;
pub mod lens_tools;
pub mod preference_producer;
pub mod recall_discrimination;
pub mod recipe_tools;
pub mod runtime;
pub mod server;
pub mod session_protocol;
pub mod surfaced_recall_ledger;
pub mod teachme_guides;
pub mod tool_list;
pub mod vault_tools;

/// Re-export the shared whole-file key entry point so the `mootx01` binary can
/// ensure the estate-encryption key exists at serve startup without a direct
/// dependency on PersistenceKit.
pub use persistence_kit::ensure_install_key;
