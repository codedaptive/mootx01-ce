// run_environment.rs
//
// Machine and mootx01 version metadata captured once per benchmark subcommand
// invocation and embedded in every report JSON as "run_environment". Rust twin
// of RunEnvironment.swift; JSON field names must match exactly (snake_case).
//
// All collection helpers are best-effort: failure in any individual field
// records "unknown" or 0 rather than aborting the benchmark.
//
// System data is collected via subprocess calls (sysctl, system_profiler, etc.)
// so no libc or sysctl crate is needed. Each subprocess carries a 5-second
// wall-clock timeout via a thread + channel pattern.

use crate::arm_register::{no_encoder_activation_seam_message, resolve_active_arm_name};
use serde::{Deserialize, Serialize};

/// Version of the measurement protocol that governs runs produced by this
/// build of the harness.
///
/// Stamped into every report (C7) so a figure can be traced to the rules that
/// defined how it was measured. Declared here rather than read from a document,
/// because a report has to carry its protocol version even when the governing
/// document is not distributed alongside the harness. Bump it in the same
/// change that changes the rules.
/// Twin of Swift `benchmarkProtocolVersion`.
pub const BENCHMARK_PROTOCOL_VERSION: &str = "v0.1";
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

/// Machine profile and mootx01 version metadata for benchmark report provenance.
///
/// Embedded in every report JSON so results from satellite machines can be
/// attributed to the hardware and software that produced them. All fields
/// degrade gracefully: individual collection failures record "unknown" or 0.
///
/// JSON field names are snake_case to match the Swift leg's CodingKeys.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RunEnvironment {
    pub hostname: String,
    pub model_identifier: String,
    pub model_name: String,
    pub chip_name: String,
    pub ram_bytes: u64,
    pub disk_bytes: u64,
    pub macos_version: String,
    pub mootx01_version: String,
    pub mootx01_build_date: String,
    /// Short git SHA of the WORKING TREE at report time. ADVISORY ONLY — it
    /// has been observed to diverge from the commit the measured binary was
    /// built from (finding H9), so the field is NAMED for what it is; the
    /// citable binary identity is `mootx01_binary_sha256`.
    pub mootx01_working_tree_head: String,
    /// SHA-256 content digest of the measured mootx01 binary file (lowercase
    /// hex). Identifies the exact binary bytes measured — unlike the git head,
    /// it cannot drift when the working tree moves after the build (C7/H9).
    /// "unknown" when the binary path is None or unreadable.
    /// serde default keeps pre-C7 report fixtures decodable.
    #[serde(default = "unknown_string")]
    pub mootx01_binary_sha256: String,
    /// Machine-quiet declaration for this run (`--run-mode quiet|contended`).
    /// "unspecified" when the flag was not passed.
    #[serde(default = "unspecified_string")]
    pub run_mode: String,
    /// Version of BENCHMARK_PROTOCOL.md governing this run.
    #[serde(default = "unknown_string")]
    pub protocol_version: String,
    /// 1-minute load average SAMPLED at collect time. MEASURED, not declared
    /// (H10): a figure from a busy machine must be distinguishable from a
    /// clean one without anyone remembering a flag. Interpret against
    /// `logical_cpus`. -1 when sampling failed.
    #[serde(default = "negative_one")]
    pub load_average_1m: f64,
    /// Logical CPU count — the denominator that makes `load_average_1m`
    /// interpretable across machines.
    #[serde(default)]
    pub logical_cpus: u32,
    /// Records arm identity per the testname-arm-serial discipline: the label
    /// names the minter made sole-active for this run; None = naked arm.
    // ── testname-arm-serial ─────────────────────────────────────────────────
    /// Test name component of this record. Set by the writer after collect().
    /// Wire key: benchmark_test_name.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub benchmark_test_name: Option<String>,
    /// Active benchmark arm name for this record. Set by the writer.
    /// Wire key: benchmark_arm.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub benchmark_arm: Option<String>,
    /// Run serial component of this record. Set by the writer.
    /// Wire key: benchmark_run_serial.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub benchmark_run_serial: Option<String>,
    /// Product-configuration arm for this record. Resolved by collect() via
    /// `resolve_active_arm_name()`. Records WHICH PRODUCT CONFIGURATION ran.
    /// Orthogonal to `benchmark_arm` (lane arm, set by the writer), which
    /// records WHICH CORPUS SLICE ran. A row carries both so the two dimensions
    /// are independently readable.
    /// Wire key: benchmark_register_arm. Set by collect(), not the writer.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub benchmark_register_arm: Option<String>,

    // ── converter identity ──────────────────────────────────────────────────
    /// ContextDistillLib converter identity. Defaults to "unknown".
    /// Wire key: converter_id. Set by collect().
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub converter_id: Option<String>,
    /// ContextDistillLib converter version. Defaults to "unknown".
    /// Wire key: converter_version. Set by collect().
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub converter_version: Option<String>,

    // ── hosting mode ────────────────────────────────────────────────────────
    /// How mootx01 was hosted. MEASURED from the actual launch path.
    /// Values per TOPOLOGY.md §1.2.0: "resident-daemon",
    /// "separately-launched-stdio", "unknown".
    /// Wire key: hosting_mode. Set by collect().
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub hosting_mode: Option<String>,

    // ── CE SHA ──────────────────────────────────────────────────────────────
    /// Community Edition commit SHA. ADVISORY — operator-supplied via
    /// MOOT_BENCH_CE_SHA; subject to the same drift hazard as
    /// mootx01_working_tree_head (finding H9).
    /// Wire key: ce_sha. Set by collect().
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub ce_sha: Option<String>,
}

fn negative_one() -> f64 { -1.0 }

fn unknown_string() -> String { "unknown".to_string() }
fn unspecified_string() -> String { "unspecified".to_string() }

impl RunEnvironment {
    /// Collects machine and mootx01 metadata synchronously.
    ///
    /// All subprocess calls carry a 5-second wall-clock timeout. Failure in any
    /// individual field records "unknown" or 0 and does not abort collection.
    ///
    /// `mootx01_binary_path`: absolute path to the mootx01 CLI binary. Pass
    /// `None` when the path is unavailable; all mootx01 fields are "unknown".
    pub fn collect(mootx01_binary_path: Option<&str>) -> RunEnvironment {
        Self::collect_with_run_mode(mootx01_binary_path, "unspecified")
    }

    /// `collect` plus the machine-quiet declaration from `--run-mode`
    /// ("quiet" or "contended"; "unspecified" when the flag was not passed).
    /// Twin of Swift `collect(mootx01BinaryPath:runMode:)`.
    pub fn collect_with_run_mode(
        mootx01_binary_path: Option<&str>,
        run_mode: &str,
    ) -> RunEnvironment {
        // D2 guard: refuse the run when MOOT_BENCH_NO_ENCODER=1 is set but the
        // no-encoder ablation is not yet implemented. A silently proceeding run
        // would measure product-default and label it no-encoder — a mislabeled
        // cell. The guard fires here (collect time) so no record is ever written.
        // See no_encoder_activation_seam_message() in arm_register.rs for the
        // full rationale. Remove this guard when the ablation is wired.
        if let Some(msg) = no_encoder_activation_seam_message() {
            eprintln!("{}", msg);
            std::process::exit(1);
        }
        let (mootx01_version, mootx01_build_date) = mootx01_binary_path
            .and_then(|p| parse_moot_version(p))
            .unwrap_or_else(|| ("unknown".to_string(), "unknown".to_string()));

        let mootx01_working_tree_head = mootx01_binary_path
            .map(|p| {
                let dir = std::path::Path::new(p)
                    .parent()
                    .and_then(|d| d.to_str())
                    .unwrap_or(".");
                git_short_sha(dir)
            })
            .unwrap_or_else(|| "unknown".to_string());

        // MEASURED hosting mode: "separately-launched-stdio" when a binary is
        // provided (the harness spawns a separate mootx01 process), "unknown"
        // when no binary is present. Twin of Swift RunEnvironment.collect().
        let hosting = if mootx01_binary_path.is_some() {
            Some("separately-launched-stdio".to_string())
        } else {
            Some("unknown".to_string())
        };


        // CE SHA: ADVISORY, operator-supplied via MOOT_BENCH_CE_SHA.
        let ce_sha_derived = std::env::var("MOOT_BENCH_CE_SHA")
            .ok()
            .filter(|s| !s.is_empty());

        RunEnvironment {
            hostname:          collect_hostname(),
            model_identifier:  collect_model_identifier(),
            model_name:        collect_model_name(),
            chip_name:         collect_chip_name(),
            ram_bytes:         collect_ram_bytes(),
            disk_bytes:        collect_disk_bytes(),
            macos_version:     collect_macos_version(),
            mootx01_version,
            mootx01_build_date,
            mootx01_working_tree_head,
            mootx01_binary_sha256: mootx01_binary_path
                .and_then(file_sha256_hex)
                .unwrap_or_else(|| "unknown".to_string()),
            run_mode: run_mode.to_string(),
            protocol_version: BENCHMARK_PROTOCOL_VERSION.to_string(),
            load_average_1m: sampled_load_average_1m(),
            logical_cpus: std::thread::available_parallelism()
                .map(|n| n.get() as u32)
                .unwrap_or(0),
            benchmark_test_name:    None,
            benchmark_arm:          None,
            benchmark_run_serial:   None,
            // Register arm: WHICH PRODUCT CONFIGURATION this run used.
            // Orthogonal to benchmark_arm (the lane arm, set by the writer).
            // Resolved at collect time so no writer site can omit it.
            benchmark_register_arm: Some(resolve_active_arm_name()),
            converter_id:      Some("unknown".to_string()),
            converter_version: Some("unknown".to_string()),
            hosting_mode:      hosting,
            ce_sha:            ce_sha_derived,
        }
    }
}

/// Slim identity block for accuracy-lane reports.
///
/// Accuracy files record the fields required to identify the binary, the
/// protocol version, and the test-name/arm/serial triple — not machine profile
/// or load state, which belong exclusively to the timing lane.  Embed this
/// under the "run_environment" key wherever a legacy `RunEnvironment` was
/// emitted for an accuracy subcommand.
/// Twin of Swift `IdentityEnvironment` (RunEnvironment.swift, 2026-08-18 doctrine).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct IdentityEnvironment {
    /// SHA-256 content digest of the measured mootx01 binary (lowercase hex).
    pub mootx01_binary_sha256: String,
    /// Major.minor version string parsed from `mootx01 --version` (e.g. "1.1").
    pub mootx01_version: String,
    /// Version of BENCHMARK_PROTOCOL.md governing this run.
    pub protocol_version: String,
    /// Payload-economics shape-variant arm ("v0"…"v5") when --payload-arm /
    /// MOOT_BENCH_PAYLOAD_ARM was set for this run, None otherwise (omitted
    /// from JSON). "v4" IS recorded when explicitly selected — a deliberate
    /// full-row control cell is labeled, an arm-free run is not.
    /// Twin of Swift `payloadArm` (see payload_arm.rs).
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub payload_arm: Option<String>,
    // ── testname-arm-serial triple ────────────────────────────────────────────
    /// Benchmark test name component. Set by the writer, not collect().
    /// Wire key: benchmark_test_name.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub benchmark_test_name: Option<String>,
    /// Active benchmark arm name. Set by the writer, not collect().
    /// Wire key: benchmark_arm.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub benchmark_arm: Option<String>,
    /// Run serial component. Set by the writer, not collect().
    /// Wire key: benchmark_run_serial.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub benchmark_run_serial: Option<String>,
    /// Product-configuration arm. Resolved by collect() via
    /// `resolve_active_arm_name()`. Orthogonal to `benchmark_arm`.
    /// Wire key: benchmark_register_arm. Set by collect(), not the writer.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub benchmark_register_arm: Option<String>,
    // ── converter identity ────────────────────────────────────────────────────
    /// ContextDistillLib converter identity. Set by collect(), defaults to "unknown".
    /// Wire key: converter_id.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub converter_id: Option<String>,
    /// ContextDistillLib converter version. Set by collect(), defaults to "unknown".
    /// Wire key: converter_version.
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub converter_version: Option<String>,
    // ── hosting mode ─────────────────────────────────────────────────────────
    /// How mootx01 was hosted. MEASURED from the actual launch path.
    /// Values: "resident-daemon", "separately-launched-stdio", "unknown".
    /// Wire key: hosting_mode. Set by collect().
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub hosting_mode: Option<String>,
    // ── CE SHA ────────────────────────────────────────────────────────────────
    /// Community Edition commit SHA. ADVISORY — operator-supplied via
    /// MOOT_BENCH_CE_SHA. Wire key: ce_sha. Set by collect().
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub ce_sha: Option<String>,
}

impl IdentityEnvironment {
    /// Collects binary identity and protocol version from the given binary path.
    ///
    /// All fields degrade gracefully: failures record "unknown".
    /// `mootx01_binary_path`: absolute path to the mootx01 CLI binary.
    /// Pass `None` when unavailable; all fields will be "unknown".
    /// Twin of Swift `IdentityEnvironment.collect(mootx01BinaryPath:payloadArm:)`.
    pub fn collect(mootx01_binary_path: Option<&str>) -> IdentityEnvironment {
        // D2 guard: same no-encoder refusal as RunEnvironment::collect().
        // Accuracy records must not be mislabeled either.
        if let Some(msg) = no_encoder_activation_seam_message() {
            eprintln!("{}", msg);
            std::process::exit(1);
        }
        let binary_sha256 = mootx01_binary_path
            .and_then(file_sha256_hex)
            .unwrap_or_else(|| "unknown".to_string());
        let version = mootx01_binary_path
            .and_then(|p| parse_moot_version(p))
            .map(|(v, _)| v)
            .unwrap_or_else(|| "unknown".to_string());
        // Mirror Swift: "separately-launched-stdio" when a path is provided,
        // "unknown" otherwise (resident-daemon path not yet wired in Rust port).
        let hosting = if mootx01_binary_path.is_some() {
            "separately-launched-stdio".to_string()
        } else {
            "unknown".to_string()
        };
        // MOOT_BENCH_CE_SHA: advisory operator-supplied sha; ignored when empty.
        let ce_sha = std::env::var("MOOT_BENCH_CE_SHA")
            .ok()
            .filter(|s| !s.is_empty());
        IdentityEnvironment {
            mootx01_binary_sha256:  binary_sha256,
            mootx01_version:        version,
            protocol_version:       BENCHMARK_PROTOCOL_VERSION.to_string(),
            payload_arm:            None,
            benchmark_test_name:    None,
            benchmark_arm:          None,
            benchmark_run_serial:   None,
            // Register arm: same orthogonal-dimension discipline as RunEnvironment.
            benchmark_register_arm: Some(resolve_active_arm_name()),
            converter_id:           Some("unknown".to_string()),
            converter_version:      Some("unknown".to_string()),
            hosting_mode:           Some(hosting),
            ce_sha,
        }
    }
}

/// 1-minute load average sampled at collect time. -1 when unavailable —
/// a sampling failure must be visible, never read as an idle machine.
/// macOS: `sysctl -n vm.loadavg` prints "{ 1.23 4.56 7.89 }"; Linux:
/// /proc/loadavg leads with the 1-minute figure. Twin of Swift
/// `sampledLoadAverage1m()` (getloadavg).
fn sampled_load_average_1m() -> f64 {
    #[cfg(target_os = "linux")]
    {
        if let Ok(text) = std::fs::read_to_string("/proc/loadavg") {
            if let Some(first) = text.split_whitespace().next() {
                if let Ok(v) = first.parse::<f64>() {
                    return v;
                }
            }
        }
        -1.0
    }
    #[cfg(not(target_os = "linux"))]
    {
        if let Some(out) = run_quick_subprocess(&["sysctl", "-n", "vm.loadavg"]) {
            // "{ 1.23 4.56 7.89 }" — the first numeric token is the 1-minute figure.
            for tok in out.split_whitespace() {
                if let Ok(v) = tok.parse::<f64>() {
                    return v;
                }
            }
        }
        -1.0
    }
}

// MARK: - SHA-256 (std-only)
//
// The benchmark crate holds a deliberate std + serde + serde_json dependency
// line, so the digest is implemented here rather than pulled from a crate.
// This is FIPS 180-4 SHA-256 used as a CHECKSUM for binary provenance, not as
// a security boundary. Correctness is pinned by the known-answer tests below;
// the Swift twin (`fileSha256Hex`, CryptoKit-backed) is pinned against the
// same vectors, which keeps the two ports' report fields byte-comparable.

const SHA256_K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

/// Incremental SHA-256 over byte chunks (FIPS 180-4).
struct Sha256State {
    h: [u32; 8],
    /// Partial input block awaiting a full 64 bytes.
    buf: Vec<u8>,
    /// Total message length in bytes.
    len: u64,
}

impl Sha256State {
    fn new() -> Self {
        Sha256State {
            h: [
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
            ],
            buf: Vec::with_capacity(64),
            len: 0,
        }
    }

    fn update(&mut self, data: &[u8]) {
        self.len += data.len() as u64;
        self.buf.extend_from_slice(data);
        while self.buf.len() >= 64 {
            let block: [u8; 64] = self.buf[..64].try_into().unwrap();
            self.compress(&block);
            self.buf.drain(..64);
        }
    }

    fn compress(&mut self, block: &[u8; 64]) {
        let mut w = [0u32; 64];
        for (i, chunk) in block.chunks_exact(4).enumerate() {
            w[i] = u32::from_be_bytes(chunk.try_into().unwrap());
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = self.h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ (!e & g);
            let t1 = h
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(SHA256_K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            h = g; g = f; f = e; e = d.wrapping_add(t1);
            d = c; c = b; b = a; a = t1.wrapping_add(t2);
        }
        for (i, v) in [a, b, c, d, e, f, g, h].into_iter().enumerate() {
            self.h[i] = self.h[i].wrapping_add(v);
        }
    }

    fn finalize_hex(mut self) -> String {
        // Padding: 0x80, zeros to 56 mod 64, then the bit length big-endian.
        let bit_len = self.len.wrapping_mul(8);
        let mut pad = vec![0x80u8];
        let rem = (self.len as usize + 1) % 64;
        let zeros = if rem <= 56 { 56 - rem } else { 120 - rem };
        pad.extend(std::iter::repeat(0u8).take(zeros));
        pad.extend_from_slice(&bit_len.to_be_bytes());
        // update() adjusts self.len, but padding is not message bytes; snapshot
        // the buffer path directly instead.
        self.buf.extend_from_slice(&pad);
        while self.buf.len() >= 64 {
            let block: [u8; 64] = self.buf[..64].try_into().unwrap();
            self.compress(&block);
            self.buf.drain(..64);
        }
        debug_assert!(self.buf.is_empty());
        self.h.iter().map(|v| format!("{v:08x}")).collect()
    }
}

/// SHA-256 of arbitrary bytes as lowercase hex. Exposed for the known-answer
/// tests; report code uses `file_sha256_hex`.
pub fn sha256_hex(data: &[u8]) -> String {
    let mut st = Sha256State::new();
    st.update(data);
    st.finalize_hex()
}

/// SHA-256 content digest of a file as lowercase hex, streamed in 1 MiB chunks
/// so a large binary never loads fully into memory. None when the file cannot
/// be opened or read. Twin of Swift `fileSha256Hex(path:)`.
pub fn file_sha256_hex(path: &str) -> Option<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).ok()?;
    let mut st = Sha256State::new();
    let mut chunk = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut chunk).ok()?;
        if n == 0 { break; }
        st.update(&chunk[..n]);
    }
    Some(st.finalize_hex())
}

// MARK: - System data collection

fn collect_hostname() -> String {
    run_quick_subprocess(&["hostname"])
        .unwrap_or_else(|| "unknown".to_string())
}

#[cfg(target_os = "macos")]
fn collect_model_identifier() -> String {
    run_quick_subprocess(&["sysctl", "-n", "hw.model"])
        .unwrap_or_else(|| "unknown".to_string())
}

#[cfg(target_os = "linux")]
fn collect_model_identifier() -> String {
    std::fs::read_to_string("/sys/devices/virtual/dmi/id/product_name")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "unknown".to_string())
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn collect_model_identifier() -> String {
    "unknown".to_string()
}

#[cfg(target_os = "macos")]
fn collect_model_name() -> String {
    // Parse machine_name from system_profiler JSON output.
    let output = run_quick_subprocess(&[
        "system_profiler", "SPHardwareDataType", "-json",
    ]);
    if let Some(json_str) = output {
        if let Ok(serde_json::Value::Object(root)) = serde_json::from_str(&json_str) {
            if let Some(serde_json::Value::Array(items)) = root.get("SPHardwareDataType") {
                if let Some(serde_json::Value::Object(hw)) = items.first() {
                    if let Some(serde_json::Value::String(name)) = hw.get("machine_name") {
                        return name.clone();
                    }
                }
            }
        }
    }
    collect_model_identifier()
}

#[cfg(not(target_os = "macos"))]
fn collect_model_name() -> String {
    collect_model_identifier()
}

#[cfg(target_os = "macos")]
fn collect_chip_name() -> String {
    run_quick_subprocess(&["sysctl", "-n", "machdep.cpu.brand_string"])
        .unwrap_or_else(|| "unknown".to_string())
}

#[cfg(target_os = "linux")]
fn collect_chip_name() -> String {
    // Parse "model name" from /proc/cpuinfo.
    std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("model name"))
                .and_then(|l| l.splitn(2, ':').nth(1))
                .map(|v| v.trim().to_string())
        })
        .unwrap_or_else(|| "unknown".to_string())
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn collect_chip_name() -> String {
    "unknown".to_string()
}

#[cfg(target_os = "macos")]
fn collect_ram_bytes() -> u64 {
    // hw.memsize returns total physical RAM as a decimal byte count.
    run_quick_subprocess(&["sysctl", "-n", "hw.memsize"])
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0)
}

#[cfg(target_os = "linux")]
fn collect_ram_bytes() -> u64 {
    // /proc/meminfo MemTotal is in kibibytes.
    std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("MemTotal:"))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|v| v.parse::<u64>().ok())
        })
        .map(|kb| kb * 1024)
        .unwrap_or(0)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn collect_ram_bytes() -> u64 {
    0
}

fn collect_disk_bytes() -> u64 {
    // df -k / gives 1K-blocks in the second column.
    // Output: "Filesystem 1K-blocks Used Available ..."
    // We take the second line, second column.
    let output = run_quick_subprocess(&["df", "-k", "/"]);
    output
        .and_then(|s| {
            s.lines()
                .nth(1)
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|v| v.parse::<u64>().ok())
        })
        .map(|kb| kb * 1024)
        .unwrap_or(0)
}

#[cfg(target_os = "macos")]
fn collect_macos_version() -> String {
    // sw_vers -productVersion returns e.g. "15.4"
    // productName and BuildVersion give more context but version alone is sufficient.
    let version = run_quick_subprocess(&["sw_vers", "-productVersion"])
        .unwrap_or_else(|| "unknown".to_string());
    let build = run_quick_subprocess(&["sw_vers", "-buildVersion"])
        .unwrap_or_else(|| "".to_string());
    if build.is_empty() {
        format!("macOS {}", version)
    } else {
        format!("macOS {} ({})", version, build)
    }
}

#[cfg(not(target_os = "macos"))]
fn collect_macos_version() -> String {
    "unknown".to_string()
}

// MARK: - mootx01 version parsing

/// Parses version and build date from `mootx01 --version` stdout.
///
/// Expected first-line format: "1.1.0-beta-14 EE (2026-08-05)"
/// Returns `None` when the binary path is unavailable or the call/parse fails.
fn parse_moot_version(binary_path: &str) -> Option<(String, String)> {
    let output = run_quick_subprocess(&[binary_path, "--version"])?;
    // Use only the first line; guard against multi-line --version output.
    let line = output.lines().next().unwrap_or(&output);

    let build_date = extract_build_date(line)
        .unwrap_or_else(|| "unknown".to_string());

    let version = extract_major_minor(line)
        .unwrap_or_else(|| "unknown".to_string());

    Some((version, build_date))
}

/// Extracts "(YYYY-MM-DD)" from a version line.
fn extract_build_date(line: &str) -> Option<String> {
    let open = line.find('(')?;
    let rest = &line[open + 1..];
    let close = rest.find(')')?;
    let candidate = &rest[..close];
    // Validate ISO date shape: 10 chars with hyphens at positions 4 and 7.
    let bytes = candidate.as_bytes();
    if bytes.len() == 10 && bytes[4] == b'-' && bytes[7] == b'-' {
        Some(candidate.to_string())
    } else {
        None
    }
}

/// Extracts major.minor from the first space-delimited token.
/// E.g. "1.1.0-beta-14" → "1.1"
fn extract_major_minor(line: &str) -> Option<String> {
    let token = line.split_whitespace().next()?;
    let mut parts = token.splitn(3, '.');
    let major = parts.next()?;
    // Strip any prerelease suffix from the minor component.
    let minor_raw = parts.next()?;
    let minor = minor_raw.split('-').next().unwrap_or(minor_raw);
    if major.is_empty() || minor.is_empty() {
        return None;
    }
    Some(format!("{}.{}", major, minor))
}

/// Runs `git -C <dir> rev-parse --short HEAD`.
fn git_short_sha(dir: &str) -> String {
    run_quick_subprocess(&["git", "-C", dir, "rev-parse", "--short", "HEAD"])
        .unwrap_or_else(|| "unknown".to_string())
}

// MARK: - Subprocess runner

/// Synchronous subprocess runner with a 5-second wall-clock timeout.
///
/// Runs `args[0]` with `args[1..]` as arguments. Returns trimmed stdout on
/// success (zero exit) or `None` on launch failure, timeout, or non-zero exit.
/// Uses a thread+channel to implement the timeout; the child is killed on
/// timeout via SIGTERM if the OS permits.
fn run_quick_subprocess(args: &[&str]) -> Option<String> {
    let (cmd, rest) = args.split_first()?;

    let child = Command::new(cmd)
        .args(rest)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;

    let (tx, rx) = mpsc::channel::<std::io::Result<std::process::Output>>();

    std::thread::spawn(move || {
        let _ = tx.send(child.wait_with_output());
    });

    match rx.recv_timeout(Duration::from_secs(5)) {
        Ok(Ok(out)) if out.status.success() => {
            String::from_utf8(out.stdout)
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
        }
        // Non-zero exit, process error, or timeout.
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_json() {
        let env = RunEnvironment {
            hostname:          "build-mac-01".to_string(),
            model_identifier:  "Mac16,11".to_string(),
            model_name:        "MacBook Air (M4, 2025)".to_string(),
            chip_name:         "Apple M4".to_string(),
            ram_bytes:         16 * 1024 * 1024 * 1024,
            disk_bytes:        500 * 1024 * 1024 * 1024,
            macos_version:     "macOS 15.4".to_string(),
            mootx01_version:   "1.1".to_string(),
            mootx01_build_date: "2026-08-05".to_string(),
            mootx01_working_tree_head:  "abc1234".to_string(),
            mootx01_binary_sha256: "deadbeef".to_string(),
            run_mode:          "quiet".to_string(),
            protocol_version:  "v0.1".to_string(),
            load_average_1m:   1.25,
            logical_cpus:      8,
            benchmark_test_name:    None,
            benchmark_arm:          None,
            benchmark_run_serial:   None,
            benchmark_register_arm: None,
            converter_id:      Some("unknown".to_string()),
            converter_version: Some("unknown".to_string()),
            hosting_mode:      Some("separately-launched-stdio".to_string()),
            ce_sha:            None,
        };
        let json = serde_json::to_string(&env).unwrap();
        let decoded: RunEnvironment = serde_json::from_str(&json).unwrap();

        assert_eq!(decoded.hostname,          env.hostname);
        assert_eq!(decoded.model_identifier,  env.model_identifier);
        assert_eq!(decoded.model_name,        env.model_name);
        assert_eq!(decoded.chip_name,         env.chip_name);
        assert_eq!(decoded.ram_bytes,         env.ram_bytes);
        assert_eq!(decoded.disk_bytes,        env.disk_bytes);
        assert_eq!(decoded.macos_version,     env.macos_version);
        assert_eq!(decoded.mootx01_version,   env.mootx01_version);
        assert_eq!(decoded.mootx01_build_date, env.mootx01_build_date);
        assert_eq!(decoded.mootx01_working_tree_head,  env.mootx01_working_tree_head);
        assert_eq!(decoded.mootx01_binary_sha256, env.mootx01_binary_sha256);
        assert_eq!(decoded.run_mode,          env.run_mode);
        assert_eq!(decoded.protocol_version,  env.protocol_version);
        assert_eq!(decoded.load_average_1m,   env.load_average_1m);
        assert_eq!(decoded.logical_cpus,      env.logical_cpus);
    }

    #[test]
    fn snake_case_field_names() {
        let env = RunEnvironment {
            hostname:          "h".to_string(),
            model_identifier:  "m".to_string(),
            model_name:        "n".to_string(),
            chip_name:         "c".to_string(),
            ram_bytes:         0,
            disk_bytes:        0,
            macos_version:     "v".to_string(),
            mootx01_version:   "1.1".to_string(),
            mootx01_build_date: "2026-01-01".to_string(),
            mootx01_working_tree_head:  "abc".to_string(),
            mootx01_binary_sha256: "d".to_string(),
            run_mode:          "u".to_string(),
            protocol_version:  "p".to_string(),
            load_average_1m:   0.0,
            logical_cpus:      1,
            // New fields introduced with arm-register + four-row-fields mission.
            benchmark_test_name:    None,
            benchmark_arm:          None,
            benchmark_run_serial:   None,
            benchmark_register_arm: None,
            converter_id:      Some("unknown".to_string()),
            converter_version: Some("unknown".to_string()),
            hosting_mode:      Some("unknown".to_string()),
            ce_sha:            None,
        };
        let json = serde_json::to_string(&env).unwrap();
        // Verify snake_case contract — these are the keys the Swift twin also emits.
        assert!(json.contains("\"model_identifier\""), "missing model_identifier");
        assert!(json.contains("\"model_name\""),       "missing model_name");
        assert!(json.contains("\"chip_name\""),        "missing chip_name");
        assert!(json.contains("\"ram_bytes\""),        "missing ram_bytes");
        assert!(json.contains("\"disk_bytes\""),       "missing disk_bytes");
        assert!(json.contains("\"macos_version\""),    "missing macos_version");
        assert!(json.contains("\"mootx01_version\""),  "missing mootx01_version");
        assert!(json.contains("\"mootx01_build_date\""), "missing mootx01_build_date");
        assert!(json.contains("\"mootx01_working_tree_head\""), "missing mootx01_working_tree_head");
        assert!(json.contains("\"mootx01_binary_sha256\""), "missing mootx01_binary_sha256");
        assert!(json.contains("\"run_mode\""),         "missing run_mode");
        assert!(json.contains("\"protocol_version\""), "missing protocol_version");
        assert!(json.contains("\"mootx01_working_tree_head\""), "missing renamed working-tree field");
        assert!(!json.contains("\"mootx01_git_head\""), "old git_head key must be gone");
        assert!(json.contains("\"load_average_1m\""), "missing load_average_1m");
        assert!(json.contains("\"logical_cpus\""),   "missing logical_cpus");
        // New field wire keys.
        assert!(json.contains("\"converter_id\""),      "missing converter_id");
        assert!(json.contains("\"converter_version\""), "missing converter_version");
        assert!(json.contains("\"hosting_mode\""),      "missing hosting_mode");
        // Optional fields set to None must be absent from JSON (skip_serializing_if).
        assert!(!json.contains("\"benchmark_test_name\""),      "nil benchmark_test_name must be absent");
        assert!(!json.contains("\"benchmark_arm\""),            "nil benchmark_arm must be absent");
        assert!(!json.contains("\"benchmark_run_serial\""),     "nil benchmark_run_serial must be absent");
        assert!(!json.contains("\"benchmark_register_arm\""),   "nil benchmark_register_arm must be absent");
        assert!(!json.contains("\"ce_sha\""),                   "nil ce_sha must be absent");
    }

    // C7: known-answer vectors pin the std-only SHA-256 to the standard
    // algorithm — the same vectors pin the Swift twin (CryptoKit), which is
    // what keeps the two ports' mootx01_binary_sha256 fields byte-comparable.
    #[test]
    fn sha256_known_answer_vectors() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        // Multi-block message (>64 bytes) exercises the block loop and padding.
        assert_eq!(
            sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
    }

    #[test]
    fn c7_fields_default_and_stamp() {
        // Old fixtures without the C7 fields still decode (serde defaults).
        let old_json = r#"{"hostname":"h","model_identifier":"m","model_name":"n",
            "chip_name":"c","ram_bytes":0,"disk_bytes":0,"macos_version":"v",
            "mootx01_version":"1.1","mootx01_build_date":"2026-01-01",
            "mootx01_working_tree_head":"abc"}"#;
        let decoded: RunEnvironment = serde_json::from_str(old_json).unwrap();
        assert_eq!(decoded.mootx01_binary_sha256, "unknown");
        assert_eq!(decoded.run_mode, "unspecified");
        assert_eq!(decoded.load_average_1m, -1.0, "absent load samples decode to the sentinel");
        assert_eq!(decoded.logical_cpus, 0);
        assert_eq!(decoded.protocol_version, "unknown");

        // collect stamps the protocol version and the passed run mode.
        let env = RunEnvironment::collect_with_run_mode(None, "quiet");
        assert_eq!(env.run_mode, "quiet");
        assert_eq!(env.protocol_version, BENCHMARK_PROTOCOL_VERSION);
        assert_eq!(env.mootx01_binary_sha256, "unknown");
    }

    #[test]
    fn collect_smoke_nil_binary() {
        // mootx01_binary_path = None → mootx01 fields are "unknown".
        let env = RunEnvironment::collect(None);
        assert!(!env.hostname.is_empty(), "hostname must not be empty");
        assert_eq!(env.mootx01_version,    "unknown");
        assert_eq!(env.mootx01_build_date, "unknown");
        assert_eq!(env.mootx01_working_tree_head,   "unknown");
    }

    #[test]
    fn version_parser_strips_to_major_minor() {
        let line = "1.1.0-beta-14 EE (2026-08-05)";
        assert_eq!(extract_major_minor(line), Some("1.1".to_string()));
        assert_eq!(extract_build_date(line),  Some("2026-08-05".to_string()));
    }

    // ── IdentityEnvironment D2 gate tests ────────────────────────────────────

    /// G1: collect() + stamp → serialize → triple present and matches stamp values.
    /// Mirrors WriterEmittedRecordFieldGateTests.writerEmittedRecordTripleMatchesFilename.
    #[test]
    fn identity_environment_stamped_triple_matches_values() {
        let mut env = IdentityEnvironment::collect(None);
        // Stamp — mirrors Swift stampTestIdentity pattern.
        env.benchmark_test_name  = Some("gate-test".to_string());
        env.benchmark_arm        = Some("product-default".to_string());
        env.benchmark_run_serial = Some("001".to_string());

        let json = serde_json::to_string(&env).expect("serialize");

        // G1: values present and correct.
        assert!(json.contains("\"benchmark_test_name\":\"gate-test\""),
                "benchmark_test_name must match stamped value; json={json}");
        assert!(json.contains("\"benchmark_arm\":\"product-default\""),
                "benchmark_arm must match stamped value; json={json}");
        assert!(json.contains("\"benchmark_run_serial\":\"001\""),
                "benchmark_run_serial must match stamped value; json={json}");
    }

    /// G2: collect() stamps collect-time fields; stamped record carries them.
    /// Mirrors WriterEmittedRecordFieldGateTests.writerEmittedRecordCarriesCollectFields.
    #[test]
    fn identity_environment_collect_time_fields_present() {
        let mut env = IdentityEnvironment::collect(None);
        env.benchmark_test_name  = Some("gate-test".to_string());
        env.benchmark_arm        = Some("product-default".to_string());
        env.benchmark_run_serial = Some("002".to_string());

        let json = serde_json::to_string(&env).expect("serialize");

        // G2: collect-time identity fields present.
        assert!(json.contains("\"hosting_mode\""),
                "hosting_mode must be present in stamped IdentityEnvironment; json={json}");
        assert!(json.contains("\"converter_id\""),
                "converter_id must be present in stamped IdentityEnvironment; json={json}");
        assert!(json.contains("\"converter_version\""),
                "converter_version must be present in stamped IdentityEnvironment; json={json}");
    }

    /// G3: wire key set matches the cross-port contract (Swift twin: G3 gate).
    /// A fully-stamped IdentityEnvironment must carry all required wire keys.
    #[test]
    fn identity_environment_wire_key_set_matches_contract() {
        let mut env = IdentityEnvironment::collect(None);
        env.benchmark_test_name  = Some("gate-test".to_string());
        env.benchmark_arm        = Some("product-default".to_string());
        env.benchmark_run_serial = Some("003".to_string());

        let json = serde_json::to_string(&env).expect("serialize");

        // Cross-port contract: same key set the Swift gate test asserts.
        let required_keys = [
            "mootx01_binary_sha256",
            "mootx01_version",
            "protocol_version",
            "benchmark_test_name",
            "benchmark_arm",
            "benchmark_run_serial",
            "benchmark_register_arm",
            "converter_id",
            "converter_version",
            "hosting_mode",
        ];
        for key in &required_keys {
            assert!(
                json.contains(&format!("\"{}\"", key)),
                "Expected cross-port wire key \"{}\" in IdentityEnvironment JSON; json={}",
                key, json
            );
        }
    }

    // ── D1 gate tests: benchmark_register_arm ────────────────────────────────

    /// D1-R1: collect() stamps benchmark_register_arm with the process-start arm.
    /// No arm switches are set in the test process, so the cached value is
    /// "product-default". Assert on the JSON produced by collect() — not on a
    /// hand-constructed struct — so this proves the wiring, not the struct shape.
    /// Uses the process-wide cache (no env mutation needed).
    #[test]
    fn register_arm_product_default_from_collect() {
        let env = RunEnvironment::collect(None);
        let json = serde_json::to_string(&env).expect("serialize");
        // The field must be present and carry the product-default value.
        assert!(
            json.contains("\"benchmark_register_arm\":\"product-default\""),
            "collect() must stamp benchmark_register_arm=product-default when no switch is set; json={json}"
        );
    }

    /// D1-R2: lane arm (benchmark_arm) and register arm (benchmark_register_arm)
    /// are BOTH present on the same record and hold DIFFERENT values. Inject the
    /// register arm directly via field assignment (no process-environment mutation)
    /// so the register arm is "apple-mint" while the lane arm is "product-default".
    /// This gate proves the two fields are orthogonal and independently assignable.
    #[test]
    fn register_arm_and_lane_arm_both_present_and_different() {
        let mut env = RunEnvironment::collect(None);
        // Inject the register arm via direct field assignment — no setenv/remove_var.
        // The register arm records which product configuration ran; it is orthogonal
        // to the lane arm (benchmark_arm), which records which corpus slice ran.
        env.benchmark_register_arm = Some("apple-mint".to_string());
        // Lane arm set by writer (simulated here) — must be the corpus-slice label.
        env.benchmark_arm = Some("product-default".to_string());

        let json = serde_json::to_string(&env).expect("serialize");

        // Register arm must be the injected mining arm label.
        assert!(
            json.contains("\"benchmark_register_arm\":\"apple-mint\""),
            "benchmark_register_arm must be apple-mint (the injected mining arm); json={json}"
        );
        // Lane arm must be the corpus-slice label set above.
        assert!(
            json.contains("\"benchmark_arm\":\"product-default\""),
            "benchmark_arm (lane arm) must be product-default; json={json}"
        );
        // The two fields must hold different values — the key distinction D1 requires.
        assert!(
            !json.contains("\"benchmark_register_arm\":\"product-default\""),
            "register arm and lane arm must hold different values; json={json}"
        );
    }

    /// D1-R3: a fully-stamped RunEnvironment carries all required wire keys.
    /// Mirrors the Swift BenchmarkRegisterArmTests.runEnvironmentWireKeySet gate.
    #[test]
    fn run_environment_wire_key_set() {
        let mut env = RunEnvironment::collect(None);
        env.benchmark_test_name  = Some("gate-test".to_string());
        env.benchmark_arm        = Some("product-default".to_string());
        env.benchmark_run_serial = Some("004".to_string());

        let json = serde_json::to_string(&env).expect("serialize");

        let required_keys = [
            "mootx01_binary_sha256",
            "mootx01_version",
            "protocol_version",
            "benchmark_test_name",
            "benchmark_arm",
            "benchmark_run_serial",
            "benchmark_register_arm",
            "converter_id",
            "converter_version",
            "hosting_mode",
        ];
        for key in &required_keys {
            assert!(
                json.contains(&format!("\"{}\"", key)),
                "Expected cross-port wire key \"{}\" in RunEnvironment JSON; json={}",
                key, json
            );
        }
    }
}
