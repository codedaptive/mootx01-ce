//! `aria-mcp` — the ARIA_MCP Rust server library.
//!
//! This crate is the Rust vertical's counterpart to the Swift `ARIA_MCP`
//! binary (apps/ARIA_MCP). It links the Rust kits (cognition-kit,
//! neuron-kit, genius-locus-kit, locus-kit) and hosts them behind a
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
//!                     ├─► tool_list (catalog + lexicon)
//!                     └─► tool_call  ──► dispatch::dispatch_tool
//!                                         ├─► recipe_tools
//!                                         ├─► lens_tools
//!                                         └─► lexicon_tools
//!                                               ├─► capture_drawer / drawer_recall / capture_tunnel
//!                                               └─► mutate_drawer / withdraw_drawer / expunge_drawer
//!                                                   / reanchor_drawer / tunnel_recall
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
//! See README.md for the full tool list (49 tools after v2b-p2) and what is
//! out of scope (live federation fan-out, and live learn + non-drawer recall
//! behavior — those tools are advertised and refuse honestly until their kit
//! surfaces land). SQLite persistence is now supported via `ARIA_MCP_SQLITE_PATH`;
//! CloudKit and federation remain future work.

pub mod dispatch;
pub mod dispatcher;
pub mod estate_registry;
pub mod jsonrpc;
pub mod lens_tools;
pub mod lexicon_tools;
pub mod recipe_tools;
pub mod server;
pub mod tool_list;
