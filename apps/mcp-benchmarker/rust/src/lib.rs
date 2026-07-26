//! mcp-benchmarker-rs — the Rust twin of the Swift mcp-benchmarker.
//!
//! This crate ports the Swift benchmarker module-by-module to full functional
//! parity. The pure, deterministic conformance core is driven by the shared
//! vectors in `tools/mcp-benchmarker/conformance/`; the IO modules (the MCP
//! stdio client, the transfer engine, the proxy translation layer) match the
//! Swift wire behavior and result semantics.
//!
//! ## Pure conformance core
//!
//! - [`divergence`] — `jaccard_divergence` (1 − |A∩B|/|A∪B|) and
//!   `rank_divergence` (normalized Kendall-tau on shared IDs). Matches
//!   `Divergence.swift`.
//! - [`manifest`] — `CapabilityManifest` decode + resolve. Matches
//!   `CapabilityManifest.swift`.
//! - [`degeneracy_guard`] — `DegeneracyGuard` verdicts. Matches
//!   `DegeneracyGuard.swift`.
//!
//! ## Config + result parsing
//!
//! - [`json_value`] — the loosely-typed `JsonValue` (Swift `JSONValue`).
//! - [`config`] — `BenchmarkerConfig` / `EndpointConfig` / `VerbMap` /
//!   `ResultFormat` with the Swift custom-decode semantics (missing-field
//!   errors, terse-config defaults). Matches `Config.swift`.
//! - [`mcp_result`] — `parse_tool_result` for the two real shapes
//!   (`jsonObjects` + `mootText`), `normalized_content_order`, and the
//!   MemPalace `drawer_id`/`content_preview` and MOOTx01 `filed memory <UUID>`
//!   parsing. Matches the parsing half of `MCPClient.swift` +
//!   `BenchmarkEngine.normalizedContentOrder`.
//!
//! ## IO + orchestration
//!
//! - [`mcp_client`] — the stdio JSON-RPC client (`initialize` handshake,
//!   monotonic ids, newline framing, `tools/call`). Matches `MCPClient.swift`.
//! - [`transfer_manifest`] — the transfer `Manifest` ground-truth record.
//!   Matches `Manifest.swift`.
//! - [`transfer`] — `TransferEngine`: paginate → fetch → write → verify.
//!   Matches `TransferEngine.swift`.
//! - [`proxy`] — `serve`-mode classify/translate mirror + `ProxyRunReport`.
//!   Matches the translation layer + report of `ProxyServer.swift`.
//!
//! ## Conformance contract
//!
//! Same inputs → identical outputs on both legs is the correctness definition
//! (BENCHMARKER_OPTIMIZER_CONTRACT.md §4).
//!
//! ## Parity notes (where the Rust leg necessarily differs)
//!
//! - Transport: the Swift `MCPClient`/`RawMCPBackend` also speak an `sse` HTTP
//!   transport; the Rust leg ships the stdio transport (the path both real
//!   servers use) and rejects an `sse` endpoint explicitly rather than
//!   silently succeeding. The wire behavior, framing, and result parsing on
//!   the stdio path match bit for bit.
//! - Concurrency: the Swift IO types are `actor`s for serialized transport
//!   access. The Rust transfer/proxy flow is synchronous request/response
//!   (one call at a time), so no actor isolation is needed; the recorded
//!   outcomes and math are identical.
//! - The `BenchmarkEngine`/`QualityEngine`/`PressureEngine` report-rendering
//!   and quality-scoring layers are out of scope for this parity pass — they
//!   sit above the wire/transfer/proxy core this crate targets. The shared
//!   divergence + content-order primitives they build on ARE ported here.

pub mod config;
pub mod degeneracy_guard;
pub mod divergence;
pub mod json_value;
pub mod lmeb_corpus;
pub mod lmeb_runner;
pub mod lmeb_scorer;
pub mod locomo_corpus;
pub mod locomo_runner;
pub mod locomo_scorer;
pub mod longmemeval_corpus;
pub mod longmemeval_judge;
pub mod longmemeval_runner;
pub mod longmemeval_scorer;
pub mod longmemeval_token_efficiency;
pub mod manifest;
pub mod mcp_client;
pub mod mcp_result;
pub mod proxy;
pub mod transfer;
pub mod transfer_manifest;
