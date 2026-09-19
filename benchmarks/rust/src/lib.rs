//! mcp-benchmarker-rs — the Rust twin of the Swift mcp-benchmarker.
//!
//! This crate ports the Swift benchmarker module-by-module to full functional
//! parity. The pure, deterministic conformance core is driven by the shared
//! vectors in `benchmarks/conformance/`; the IO modules (the MCP
//! stdio client, the transfer engine) match the
//! Swift wire behavior and result semantics.
//!
//! ## Pure conformance core
//!
//! - [`divergence`] — `jaccard_divergence` (1 − |A∩B|/|A∪B|) and
//!   `rank_divergence` (normalized Kendall-tau on shared IDs). Matches
//!   `Divergence.swift`.
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
//!   `drawer_id`/`content_preview` and MOOTx01 `filed memory <UUID>` parsing.
//!   Matches the parsing half of `MCPClient.swift` +
//!   `BenchmarkEngine.normalizedContentOrder`.
//!
//! ## IO + orchestration
//!
//! - [`mcp_client`] — the stdio JSON-RPC client (`initialize` handshake,
//!   monotonic ids, newline framing, `tools/call`). Matches `MCPClient.swift`.
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
//!   access. The Rust transfer flow is synchronous request/response
//!   (one call at a time), so no actor isolation is needed; the recorded
//!   outcomes and math are identical.
//! - The `BenchmarkEngine`/`QualityEngine`/`PressureEngine` report-rendering
//!   and quality-scoring layers are out of scope for this parity pass — they
//!   sit above the wire/transfer core this crate targets. The shared
//!   divergence + content-order primitives they build on ARE ported here.

pub mod aria_v2_surface;
pub mod arm_register;
pub mod config;
pub mod encode_barrier;
pub mod artifact_manifest;
pub mod artifact_recall;
pub mod gauntlet_corpus;
pub mod gauntlet_io;
pub mod gauntlet_report;
pub mod gauntlet_runner;
pub mod gauntlet_scorer;
pub mod drift_gate_receipt;
pub mod estate_cache;
pub mod matrix_command;
pub mod record_writer;
pub mod degeneracy_guard;
pub mod fact_layer_corpus;
pub mod fact_layer_runner;
pub mod divergence;
pub mod json_value;
pub mod journey_corpus;
pub mod journey_driver;
pub mod journey_metrics;
pub mod journey_recorder;
pub mod journey_runner;
pub mod key_residue;
pub mod lmeb_corpus;
pub mod lmeb_runner;
pub mod lmeb_scorer;
pub mod lmeb_spec_metrics;
pub mod locomo_corpus;
pub mod locomo_runner;
pub mod locomo_scorer;
pub mod locomo_spec_corpus;
pub mod membench_corpus;
pub mod membench_runner;
pub mod membench_scorer;
pub mod membench_spec_protocol;
pub mod lme_spec_corpus;
pub mod longmemeval_corpus;
pub mod longmemeval_judge;
pub mod longmemeval_runner;
pub mod longmemeval_scorer;
pub mod longmemeval_token_efficiency;
pub mod mcp_client;
pub mod mcp_result;
pub mod payload_arm;
pub mod payload_economics;
pub mod reranker;
pub mod judge_batch;
pub mod replay_lane;
pub mod run_environment;
pub mod scratch_posture;
pub mod seed_export;
pub mod retrieval_call_spec;
pub mod unit_id_filter;
pub mod subject_generator;
pub mod capturespread_corpus;
pub mod capturespread_runner;
pub mod supersession_corpus;
pub mod supersession_runner;
pub mod timing_capture;
pub mod timing_lane_runner;
pub mod lme_spec_answer_batch;
pub mod lme_spec_grader;
pub mod lme_spec_runner;
pub mod membench_spec_scorer;
pub mod locomo_spec_scorer;
pub mod locomo_spec_runner;
pub mod locomo_spec_answer_batch;
pub mod convomem_spec_protocol;
pub mod cl100k_tokenizer;
pub mod membench_spec_runner;
pub mod lmeb_spec_runner;
pub mod posture_equivalence_runner;
