//! posture_equivalence_runner.rs — posture-equivalence loop for the timing lane.
//!
//! Rust twin of `PostureEquivalenceRunner.swift`.
//!
//! After the timing lane's checkpoints complete, this module provisions a small
//! independent scratch estate (POSTURE_EQUIV_DEFAULT_ROWS rows,
//! POSTURE_EQUIV_DEFAULT_PROBES probes), converts it to an encrypted twin using
//! the same `estate_encryption` helpers the matrix lane uses, and compares
//! ranked recall results exactly across both postures. A divergence in any
//! probe's top-k list indicates that at-rest encryption changed retrieval
//! ordering — a regression, not just an encryption cost.
//!
//! The Rust timing lane only runs the plaintext posture (no landscape cache
//! restore, no encrypted path in `run_timing_lane`). The equivalence loop
//! provisions its OWN estates in both postures and therefore exercises the
//! encrypted path here even though the parent timing run does not.
//!
//! Artifact: `posture-equivalence-disk-<serial>.json` — identity block only
//! (mootx01_binary_sha256, mootx01_version, protocol_version). No timing
//! metrics, no machine state. The arm is "disk" because both postures always
//! use the disk backend.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::config::{EndpointConfig, EndpointRole, ResultFormat, Transport, VerbMap};
use crate::encode_barrier::wait_for_encode_drain;
use crate::json_value::JsonValue;
use crate::mcp_client::{MCPClient, ToolCaller};
use crate::run_environment::IdentityEnvironment;
use crate::scratch_posture::{moot_serve_command, ScratchEstatePosture};
use crate::seed_export::{emit_seed_json, write_seed_file, SeedFileRecord};
use crate::timing_lane_runner::{timing_lane_records, TimingSeedRecord};

// ─── Constants ────────────────────────────────────────────────────────────────

/// Number of rows to ingest into the posture-equivalence scratch estate.
///
/// 200 rows give recall a real haystack: a 10-row estate might never reorder
/// between postures even if the encode path changed semantics, because
/// uniform-score ties are broken arbitrarily. 200 rows make rank sensitivity
/// non-trivial — divergence shows up when it is real.
/// Twin of Swift `postureEquivDefaultRows`.
pub const POSTURE_EQUIV_DEFAULT_ROWS: usize = 200;

/// Number of probe queries to run against each posture.
///
/// 50 probes across 200 rows is a meaningful sample. Each probe queries with
/// the row's own first-sentence content, and the top-k ranked result ID lists
/// are compared exactly. A divergence in any of the 50 probes is a detectable
/// retrieval regression.
/// Twin of Swift `postureEquivDefaultProbes`.
pub const POSTURE_EQUIV_DEFAULT_PROBES: usize = 50;

/// Ranked result depth per probe. Matches the matrix lane's default.
/// Twin of Swift `postureEquivTopK`.
const POSTURE_EQUIV_TOP_K: usize = 10;

// ─── Report structs ───────────────────────────────────────────────────────────

/// Per-probe divergence record: the two postures' ranked result ID lists for
/// one probe where the lists differed. Twin of Swift `PostureEquivDivergence`.
#[derive(Debug, Serialize)]
pub struct PostureEquivDivergence {
    /// 0-based index of this probe in the run's probe list.
    pub probe_index: usize,
    /// Top-k ranked result IDs returned by the plaintext estate.
    pub plaintext_ranks: Vec<String>,
    /// Top-k ranked result IDs returned by the encrypted estate.
    pub encrypted_ranks: Vec<String>,
}

/// Top-level posture-equivalence artifact.
///
/// Identity block only — no timing metrics, no machine state. Answers "did the
/// two postures return identical top-k ranked lists?" The timing lane report
/// carries latency figures; mixing them in here would make this artifact
/// machine-dependent, defeating the identity-only contract.
/// Twin of Swift `PostureEquivalenceReport`.
#[derive(Debug, Serialize)]
pub struct PostureEquivalenceReport {
    /// Binary identity and protocol version. No machine metrics or load state.
    pub run_environment: IdentityEnvironment,
    /// RNG seed governing corpus generation.
    pub seed: u64,
    /// Rows ingested into the scratch estate before probing.
    pub rows_ingested: usize,
    /// Probe queries run against each posture (identical set for both).
    pub probes_compared: usize,
    /// Probes whose top-k ranked result lists were identical across postures.
    pub identical_count: usize,
    /// Probes whose top-k ranked result lists differed between postures.
    pub divergent_count: usize,
    /// Full detail for each divergent probe. Empty when `divergent_count == 0`.
    pub divergences: Vec<PostureEquivDivergence>,
}

// ─── Scratch dir helpers ──────────────────────────────────────────────────────

/// Creates a fresh scratch directory for the posture-equivalence estate under
/// `/tmp/posture-equiv-<pid>-<suffix>`. Distinct prefix from the timing lane's
/// `/tmp/timing-lane-bench-<seed>` to avoid any prefix-guard conflicts during
/// teardown.
fn posture_equiv_scratch_dir(
    suffix: &str,
    posture: ScratchEstatePosture,
) -> Result<PathBuf, String> {
    let path = PathBuf::from(format!(
        "/tmp/posture-equiv-{}-{}",
        std::process::id(),
        suffix
    ));
    if path.exists() {
        std::fs::remove_dir_all(&path)
            .map_err(|e| format!("posture_equiv_scratch_dir: remove stale dir failed: {e}"))?;
    }
    std::fs::create_dir_all(&path)
        .map_err(|e| format!("posture_equiv_scratch_dir: create dir failed: {e}"))?;

    let canonical = std::fs::canonicalize(&path)
        .map_err(|e| format!("posture_equiv_scratch_dir: canonicalize failed: {e}"))?;

    // The posture is the record's: a transient record is plaintext by rule.
    let _ = posture;
    Ok(canonical)
}

/// Tears down a posture-equivalence scratch directory, refusing paths that do
/// not carry the expected `posture-equiv-` infix — the same safety convention
/// as the timing lane's `timing_guarded_teardown`. The check is intentionally
/// loose (infix, not exact prefix) so it catches both `/tmp/posture-equiv-` and
/// `/private/tmp/posture-equiv-` (the macOS canonical form after
/// `canonicalize`).
fn posture_equiv_guarded_teardown(path: &Path) {
    let path_str = path.to_string_lossy();
    if !path_str.contains("/posture-equiv-") {
        eprintln!(
            "[posture-equivalence] SAFETY: teardown refused '{}' — must contain /posture-equiv-",
            path_str
        );
        return;
    }
    if let Err(e) = std::fs::remove_dir_all(path) {
        eprintln!("[posture-equivalence] teardown warning: {e}");
    }
}

// ─── Endpoint builder ─────────────────────────────────────────────────────────

/// Builds an EndpointConfig for mootx01 pointing at a posture-equivalence
/// estate. VerbMap matches the timing lane (location: "timing/bench").
fn posture_equiv_endpoint_config(
    scratch_dir: &Path,
    binary: &Path,
    posture: ScratchEstatePosture,
) -> Result<EndpointConfig, String> {
    // The posture is the record's (transient: plaintext; the encrypted cell
    // carries the harness key file beside the estate).
    let _ = posture;
    let command = moot_serve_command(
        &binary.display().to_string(), scratch_dir, false,
        &["MOOTX01_VAULT=1", "MOOTX01_SUBJECT_RIDER=0"], None)
        .map_err(|e| format!("posture-equivalence: serve command error: {}", e))?;
    let mut constant_args = BTreeMap::new();
    constant_args.insert("location".to_string(), "timing/bench".to_string());
    let endpoint = EndpointConfig {
        name: "mootx01-posture-equiv".to_string(),
        transport: Transport::Stdio { command },
        auth: None,
        verb_map: VerbMap::new(
            crate::aria_v2_surface::FILE_MEMORY,
            crate::aria_v2_surface::MEMORY_SEARCH,
            None, // list: not used
            None, // fetch: not used
            None, // content_arg: defaults to "content"
            None, // query_arg: defaults to "query"
            Some(constant_args),
            Some(ResultFormat::MootV2),
        ),
        role: EndpointRole::Target,
    };
    // Belt-and-suspenders: assert_scratch_backend verifies the scratch constraint
    // (--db must point at /tmp) after the command is assembled.
    // Swift timing lanes reach the guard through `lmeEndpointConfig`; this lane builds
    // its own endpoint, so the check lives here.
    // Covers the posture-equivalence lane's own endpoint (not via lme_endpoint_config).
    crate::gauntlet_runner::assert_scratch_backend(
        &endpoint, &crate::gauntlet_runner::MOOT_SCRATCH_REQUIREMENT,
    );
    Ok(endpoint)
}

// ─── Ingest helper ────────────────────────────────────────────────────────────

/// Ingests `records` into the estate via `moot_json_import` (background mode)
/// and waits for the encode drain to settle before returning. The drain barrier
/// ensures all rows are encoded before probing — ranked recall is only stable
/// after encoding completes.
fn ingest_posture_equiv_corpus(
    client: &mut MCPClient,
    scratch_dir: &Path,
    records: &[TimingSeedRecord],
    label: &str,
) -> Result<(), String> {
    let seed_records: Vec<SeedFileRecord> = records
        .iter()
        .map(|r| SeedFileRecord::new(&r.id, &r.content, &r.event_time, &r.room))
        .collect();
    let seed_name = format!("posture-equiv-{}", label);
    let seed_data = emit_seed_json(&seed_name, &seed_records, &[], &[]);
    let seed_path = write_seed_file(&seed_data, scratch_dir, &seed_name)
        .map_err(|e| format!("posture-equivalence: seed write failed: {}", e.description))?;

    let mut import_args = BTreeMap::new();
    import_args.insert(
        "path".to_string(),
        JsonValue::String(seed_path.to_string_lossy().into_owned()),
    );
    // Background mode: the estate encodes after the import ACK returns.
    // The drain barrier below waits until encoding is idle before probing.
    // v2: `mode` arg removed from moot_json_import (v2 manages encode scheduling internally).

    let import_result = client
        .call_tool(crate::aria_v2_surface::JSON_IMPORT, import_args, &ResultFormat::MootV2)
        .map_err(|e| format!("posture-equivalence: moot_json_import failed: {}", e.description))?;
    // v2: drawer count is in structuredContent.data.drawers_written, not text.
    if import_result.drawers_written != Some(records.len() as i64) {
        return Err(format!(
            "posture-equivalence: moot_json_import did not confirm {} drawers for '{}' — got: {}",
            records.len(),
            label,
            import_result.drawers_written
                .map(|n| n.to_string())
                .unwrap_or_else(|| "(no structured data)".to_string())
        ));
    }

    // Drain: rows must be encoded before probing so ranked recall is stable.
    wait_for_encode_drain(client, &format!("posture-equiv-{}", label), 300.0);
    Ok(())
}

// ─── Probe pass ───────────────────────────────────────────────────────────────

/// Runs `probe_count` recall queries against the served estate and returns the
/// top-k ranked result ID lists in probe order.
///
/// Query text is the first sentence of each row's content — the same strategy
/// the timing lane uses for its READ metric. The `ordered_ids` field on the
/// tool result carries the parsed ranked UUID list from the mootText response.
/// Twin of Swift `runPostureProbePass`.
fn run_probe_pass(
    client: &mut MCPClient,
    records: &[TimingSeedRecord],
    probe_count: usize,
) -> Vec<Vec<String>> {
    records
        .iter()
        .take(probe_count)
        .map(|record| {
            // First sentence of content: same extraction the timing READ metric uses.
            let query: String = record
                .content
                .split('.')
                .next()
                .unwrap_or("timing benchmark")
                .to_string();
            let mut args = BTreeMap::new();
            args.insert("query".to_string(), JsonValue::String(query));
            args.insert(
                "location".to_string(),
                JsonValue::String(record.room.clone()),
            );
            match client.call_tool(crate::aria_v2_surface::MEMORY_SEARCH, args, &ResultFormat::MootV2) {
                Ok(r) => r.ordered_ids.into_iter().take(POSTURE_EQUIV_TOP_K).collect(),
                Err(_) => Vec::new(),
            }
        })
        .collect()
}

// ─── Main entry point ─────────────────────────────────────────────────────────

/// Configuration for one posture-equivalence run.
pub struct PostureEquivConfig {
    /// Path to the mootx01 binary.
    pub moot_binary_path: PathBuf,
    /// RNG seed — same as the timing lane's seed for reproducibility.
    pub seed: u64,
    /// Number of rows to ingest (default `POSTURE_EQUIV_DEFAULT_ROWS`).
    pub row_count: usize,
    /// Number of probe queries per posture (default `POSTURE_EQUIV_DEFAULT_PROBES`).
    pub probe_count: usize,
    /// Output directory for the artifact. None → current working directory.
    pub out_dir: Option<PathBuf>,
    /// Run serial from `--run-id`, shared with the timing lane's params sidecar.
    pub run_id: Option<String>,
}

/// Runs the posture-equivalence loop and writes a unique artifact.
///
/// Provisions two small independent scratch estates (plaintext and encrypted),
/// ingests a seeded synthetic corpus, and compares ranked recall results exactly
/// across both postures. A divergence in any probe's top-k list is a retrieval
/// regression attributable to at-rest encryption.
///
/// A failure here should NOT abort the timing run — callers should catch this
/// error and log it. The timing report is already on disk before this runs.
/// Twin of Swift `runPostureEquivalenceLoop`.
pub fn run_posture_equivalence_loop(config: &PostureEquivConfig) -> Result<(), String> {
    eprintln!(
        "[posture-equivalence] starting ({} rows, {} probes)...",
        config.row_count, config.probe_count
    );

    let records = timing_lane_records(0, config.row_count, config.seed);

    // ── Provision and probe: plaintext estate ─────────────────────────────
    let plain_scratch =
        posture_equiv_scratch_dir("plain", ScratchEstatePosture::PlaintextTransient)?;

    let plain_endpoint = posture_equiv_endpoint_config(
        &plain_scratch,
        &config.moot_binary_path,
        ScratchEstatePosture::PlaintextTransient,
    )?;
    let mut plain_client = MCPClient::new(plain_endpoint);
    plain_client
        .connect()
        .map_err(|e| format!("posture-equivalence: plaintext connect failed: {}", e.description))?;

    ingest_posture_equiv_corpus(&mut plain_client, &plain_scratch, &records, "plain")?;

    let plain_results = run_probe_pass(&mut plain_client, &records, config.probe_count);

    plain_client.disconnect();

    // ── Clone plaintext → encrypted scratch dir ───────────────────────────
    let enc_scratch =
        posture_equiv_scratch_dir("enc", ScratchEstatePosture::EncryptedEphemeral)?;

    // Copy every file from the plaintext estate into the encrypted scratch dir
    // so the encrypted estate starts with identical row data.
    for entry in std::fs::read_dir(&plain_scratch)
        .map_err(|e| format!("posture-equivalence: read plain dir: {e}"))?
    {
        let entry = entry.map_err(|e| format!("posture-equivalence: dir entry error: {e}"))?;
        let dst = enc_scratch.join(entry.file_name());
        if dst.exists() {
            std::fs::remove_file(&dst)
                .map_err(|e| format!("posture-equivalence: remove dst: {e}"))?;
        }
        std::fs::copy(entry.path(), &dst)
            .map_err(|e| format!("posture-equivalence: copy to enc scratch: {e}"))?;
    }

    // Convert every SQLite file in the cloned directory to encrypted in place.
    // `matrix_key` is deterministic from seed, matching the Swift `matrixKey(seed:)`.
    let key = crate::matrix_command::matrix_key(config.seed);
    crate::matrix_command::convert_scratch_directory_to_encrypted(&enc_scratch, &key)
        .map_err(|e| format!("posture-equivalence: conversion failed: {e:?}"))?;

    // Write the key file so the server can open the converted database.
    // `estate_encryption::write_install_key` writes `db.key` into the scratch
    // dir; the server reads it under MOOTX01_ESTATE_LIFETIME=ephemeral.
    estate_encryption::write_install_key(&key, &enc_scratch)
        .map_err(|e| format!("posture-equivalence: write_install_key failed: {e:?}"))?;

    // ── Provision and probe: encrypted estate ─────────────────────────────
    let enc_endpoint = posture_equiv_endpoint_config(
        &enc_scratch,
        &config.moot_binary_path,
        ScratchEstatePosture::EncryptedEphemeral,
    )?;
    let mut enc_client = MCPClient::new(enc_endpoint);
    enc_client
        .connect()
        .map_err(|e| format!("posture-equivalence: encrypted connect failed: {}", e.description))?;

    let enc_results = run_probe_pass(&mut enc_client, &records, config.probe_count);

    enc_client.disconnect();

    // Tear down both scratch estates before writing results.
    posture_equiv_guarded_teardown(&enc_scratch);
    posture_equiv_guarded_teardown(&plain_scratch);

    // ── Compare ranked results ────────────────────────────────────────────
    let compared = plain_results.len().min(enc_results.len());
    let mut identical_count = 0usize;
    let mut divergences: Vec<PostureEquivDivergence> = Vec::new();
    for i in 0..compared {
        if plain_results[i] == enc_results[i] {
            identical_count += 1;
        } else {
            divergences.push(PostureEquivDivergence {
                probe_index: i,
                plaintext_ranks: plain_results[i].clone(),
                encrypted_ranks: enc_results[i].clone(),
            });
        }
    }
    let divergent_count = compared - identical_count;

    // ── Write artifact ────────────────────────────────────────────────────
    let identity =
        IdentityEnvironment::collect(Some(&config.moot_binary_path.to_string_lossy()));
    let report = PostureEquivalenceReport {
        run_environment: identity,
        seed: config.seed,
        rows_ingested: config.row_count,
        probes_compared: compared,
        identical_count,
        divergent_count,
        divergences,
    };

    let json = serde_json::to_vec_pretty(&report)
        .map_err(|e| format!("posture-equivalence: JSON encode failed: {e}"))?;

    // Arm is "disk": both postures always use the disk backend. The arm names
    // the storage scope, not which posture the comparison favoured.
    let serial = match &config.run_id {
        Some(id) if !id.is_empty() => id.clone(),
        _ => crate::record_writer::resolve_run_serial(&[]),
    };
    let filename =
        crate::record_writer::record_filename("posture-equivalence", "disk", &serial, "", "json");
    let report_path = match &config.out_dir {
        Some(dir) => {
            std::fs::create_dir_all(dir)
                .map_err(|e| format!("posture-equivalence: could not create out_dir: {e}"))?;
            dir.join(&filename)
        }
        None => PathBuf::from(&filename),
    };
    crate::record_writer::write_record_never_overwrite(&json, &report_path)
        .map_err(|e| format!("posture-equivalence: artifact write failed: {e}"))?;

    eprintln!(
        "[posture-equivalence] {} probes: {} identical, {} divergent",
        compared, identical_count, divergent_count
    );
    eprintln!(
        "[posture-equivalence] artifact: {}",
        report_path.display()
    );

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::run_environment::IdentityEnvironment;

    // ── IdentityEnvironment field contract ───────────────────────────────────

    /// Verify that IdentityEnvironment serializes exactly the three identity
    /// fields and NONE of the timing-lane machine-state fields.
    /// Twin of Swift `PostureEquivalenceRunnerTests.identityEnvironmentFieldSet`.
    #[test]
    fn identity_environment_no_timing_fields() {
        let identity = IdentityEnvironment {
            mootx01_binary_sha256: "aabb".to_string(),
            mootx01_version: "1.1".to_string(),
            protocol_version: "v0.1".to_string(),
            payload_arm: None,
            ..Default::default()
        };
        let json = serde_json::to_string(&identity).expect("encode");

        // Required fields.
        assert!(json.contains("\"mootx01_binary_sha256\""), "missing binary sha256");
        assert!(json.contains("\"mootx01_version\""), "missing version");
        assert!(json.contains("\"protocol_version\""), "missing protocol version");

        // Prohibited timing-lane fields.
        assert!(!json.contains("\"run_mode\""), "run_mode must not be in IdentityEnvironment");
        assert!(!json.contains("\"load_average_1m\""), "load_average_1m must not be in IdentityEnvironment");
        assert!(!json.contains("\"logical_cpus\""), "logical_cpus must not be in IdentityEnvironment");
        assert!(!json.contains("\"hostname\""), "hostname must not be in IdentityEnvironment");
        assert!(!json.contains("\"chip_name\""), "chip_name must not be in IdentityEnvironment");
        assert!(!json.contains("\"ram_bytes\""), "ram_bytes must not be in IdentityEnvironment");
        assert!(!json.contains("\"disk_bytes\""), "disk_bytes must not be in IdentityEnvironment");
    }

    // ── PostureEquivalenceReport field contract ──────────────────────────────

    /// Verify that PostureEquivalenceReport serializes all required accuracy-lane
    /// fields and NONE of the prohibited timing-lane fields.
    /// Twin of Swift `PostureEquivalenceRunnerTests.reportNoTimingFields`.
    #[test]
    fn report_shape_no_timing_fields() {
        let identity = IdentityEnvironment {
            mootx01_binary_sha256: "sha".to_string(),
            mootx01_version: "1.1".to_string(),
            protocol_version: "v0.1".to_string(),
            payload_arm: None,
            ..Default::default()
        };
        let report = PostureEquivalenceReport {
            run_environment: identity,
            seed: 20_260_813,
            rows_ingested: POSTURE_EQUIV_DEFAULT_ROWS,
            probes_compared: POSTURE_EQUIV_DEFAULT_PROBES,
            identical_count: POSTURE_EQUIV_DEFAULT_PROBES,
            divergent_count: 0,
            divergences: Vec::new(),
        };
        let json = serde_json::to_string(&report).expect("encode");

        // Required top-level fields.
        assert!(json.contains("\"run_environment\""), "missing run_environment");
        assert!(json.contains("\"seed\""), "missing seed");
        assert!(json.contains("\"rows_ingested\""), "missing rows_ingested");
        assert!(json.contains("\"probes_compared\""), "missing probes_compared");
        assert!(json.contains("\"identical_count\""), "missing identical_count");
        assert!(json.contains("\"divergent_count\""), "missing divergent_count");
        assert!(json.contains("\"divergences\""), "missing divergences");

        // Prohibited timing-lane fields.
        assert!(!json.contains("\"run_mode\""), "run_mode must not appear in posture-equivalence artifact");
        assert!(!json.contains("\"load_average_1m\""), "load_average_1m must not appear in posture-equivalence artifact");
        assert!(!json.contains("\"logical_cpus\""), "logical_cpus must not appear in posture-equivalence artifact");
        assert!(!json.contains("\"hostname\""), "hostname must not appear in posture-equivalence artifact");
        assert!(!json.contains("\"chip_name\""), "chip_name must not appear in posture-equivalence artifact");
        assert!(!json.contains("\"ram_bytes\""), "ram_bytes must not appear in posture-equivalence artifact");
        assert!(!json.contains("\"disk_bytes\""), "disk_bytes must not appear in posture-equivalence artifact");
        assert!(!json.contains("\"accept_ms\""), "accept_ms must not appear in posture-equivalence artifact");
        assert!(!json.contains("\"ingest_ms\""), "ingest_ms must not appear in posture-equivalence artifact");
        assert!(!json.contains("\"read_ms\""), "read_ms must not appear in posture-equivalence artifact");
    }

    // ── Divergence encoding ──────────────────────────────────────────────────

    /// Divergence struct serializes probe_index and both rank lists.
    #[test]
    fn divergence_field_shape() {
        let d = PostureEquivDivergence {
            probe_index: 7,
            plaintext_ranks: vec!["a".to_string(), "b".to_string()],
            encrypted_ranks: vec!["b".to_string(), "a".to_string()],
        };
        let json = serde_json::to_string(&d).expect("encode");
        assert!(json.contains("\"probe_index\""));
        assert!(json.contains("\"plaintext_ranks\""));
        assert!(json.contains("\"encrypted_ranks\""));
        assert!(json.contains("\"a\""));
    }

    // ── Constants ─────────────────────────────────────────────────────────────

    /// Cross-port golden pin: both Swift and Rust use the same documented defaults.
    /// A change here is a protocol change — update both ports together.
    #[test]
    fn default_constants_match_protocol() {
        assert_eq!(
            POSTURE_EQUIV_DEFAULT_ROWS,
            200,
            "default row count must match Swift postureEquivDefaultRows"
        );
        assert_eq!(
            POSTURE_EQUIV_DEFAULT_PROBES,
            50,
            "default probe count must match Swift postureEquivDefaultProbes"
        );
    }
}
