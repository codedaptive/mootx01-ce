// SubstrateValidator (Rust) — field validator of the substrate libs.
//
// Subsystems implemented here:
//   1. Conformance A/B vs harness — each primitive's committed vector is
//      re-validated through the descriptor (which calls the real packages/libs
//      impl, recomputes the canonical CRC32, compares to committed output_crc32).
//   2. Backend A/B — every primitive is re-validated under each available kernel
//      (scalar, simd, …); CRCs must be byte-identical across kernels.
//   4. Timing — per (primitive, kernel): StressTest methodology (warmup budget,
//      measured budget, ns/validate-call min/mean/stddev). Granularity is one
//      validate() call over the whole committed vector file, not per-op with
//      batch sizes — the per-op StressTest sweep is a separate follow-on.
//
// Subsystems 3 (cross-language compare), 5 (source<->cookbook audit), 6 (source
// CRC drift) land in sibling modules / the Swift app.
//
// Output: `--json` emits a machine report to stdout; default is a human table.
// Exit nonzero if any primitive is non-conformant or any backend disagrees.

use std::fs;
use std::path::{Path, PathBuf};
use std::process;
use std::time::{Duration, Instant};

use harness::{all_primitives, hardware, kernel_registry, kernel_selector, u32_hex, JsonReader, CRC32};
use serde_json::json;

mod cookbook_audit; // subsystem 5 (advisory): structural source↔cookbook audit

// ── subsystem 6: source-CRC drift ───────────────────────────────────────────
// MUST mirror build.rs exactly (same libs, recursion, sort, concatenation).
const LIBS: [&str; 4] = ["SubstrateTypes", "SubstrateKernel", "SubstrateML", "SubstrateLib"];
const STAMPED_SRC_CRC: &str = env!("SUBSTRATE_SRC_CRC");
const STAMPED_SRC_FILES: &str = env!("SUBSTRATE_SRC_FILES");

fn collect_rs(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_dir() {
            collect_rs(&p, out);
        } else if p.extension().map_or(false, |x| x == "rs") {
            out.push(p);
        }
    }
}

struct Drift {
    stamped_crc: String,
    current_crc: String,
    stamped_files: usize,
    current_files: usize,
    drifted: bool,
}

/// Recompute the CRC over the linked lib source as it is on disk right now,
/// using the canonical harness CRC32, and compare to the build-time stamp.
fn drift_check() -> Drift {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let mut files = Vec::new();
    for lib in LIBS {
        let src = manifest.join(format!("../../../../../packages/libs/{lib}/rust/src"));
        if let Ok(canon) = src.canonicalize() {
            collect_rs(&canon, &mut files);
        }
    }
    files.sort();
    let mut crc = CRC32::new();
    for f in &files {
        if let Ok(b) = fs::read(f) {
            crc.update(&b);
        }
    }
    let current_crc = format!("{:08x}", crc.finalize());
    let current_files = files.len();
    let stamped_files: usize = STAMPED_SRC_FILES.parse().unwrap_or(0);
    Drift {
        drifted: current_crc != STAMPED_SRC_CRC || current_files != stamped_files,
        stamped_crc: STAMPED_SRC_CRC.to_string(),
        current_crc,
        stamped_files,
        current_files,
    }
}

const WARMUP: Duration = Duration::from_millis(50);
const MEASURE: Duration = Duration::from_millis(150);

/// Committed vectors live two dirs up from this crate, beside the harness.
fn vectors_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../test-harness/vectors")
        .canonicalize()
        .expect("vectors dir must exist relative to the crate")
}

struct Timing {
    runs: usize,
    ns_min: f64,
    ns_mean: f64,
    ns_stddev: f64,
}

/// Run `f` repeatedly: discard a warmup window, then measure a window, returning
/// per-call nanosecond statistics. `f` returns the CRC so the optimizer can't
/// elide the call.
fn time_it<F: FnMut() -> u32>(mut f: F) -> Timing {
    let w0 = Instant::now();
    while w0.elapsed() < WARMUP {
        std::hint::black_box(f());
    }
    let mut samples: Vec<f64> = Vec::new();
    let m0 = Instant::now();
    while m0.elapsed() < MEASURE {
        let t = Instant::now();
        std::hint::black_box(f());
        samples.push(t.elapsed().as_nanos() as f64);
    }
    let runs = samples.len().max(1);
    let ns_min = samples.iter().cloned().fold(f64::INFINITY, f64::min);
    let ns_mean = samples.iter().sum::<f64>() / runs as f64;
    let ns_stddev = if runs > 1 {
        (samples.iter().map(|s| (s - ns_mean).powi(2)).sum::<f64>() / (runs - 1) as f64).sqrt()
    } else {
        0.0
    };
    Timing { runs, ns_min, ns_mean, ns_stddev }
}

struct KernelResult {
    kernel: &'static str,
    crc: u32,
    passed: bool,
    timing: Timing,
}

struct PrimReport {
    name: &'static str,
    section: String,
    committed_crc: u32,
    conformant: bool,
    backend_agreement: bool,
    kernels: Vec<KernelResult>,
}

fn main() {
    // Subsystem 5 (advisory): structural source↔cookbook audit. Heuristic, not a
    // gate — exits 0 regardless; the gates are conformance + cross-lang.
    if std::env::args().any(|a| a == "--audit") {
        cookbook_audit::run();
        std::process::exit(0);
    }

    let json_out = std::env::args().any(|a| a == "--json");
    let vdir = vectors_dir();
    let kinds = kernel_registry::available();

    let mut reports: Vec<PrimReport> = Vec::new();
    let mut missing: Vec<&str> = Vec::new();

    for d in all_primitives() {
        let path = vdir.join(format!("{}.json", d.name));
        let Ok(jtext) = fs::read_to_string(&path) else {
            missing.push(d.name);
            continue;
        };
        let file = match JsonReader::parse_vector_file(&jtext) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("parse error for {}: {e}", d.name);
                continue;
            }
        };

        let mut kernels: Vec<KernelResult> = Vec::new();
        for k in kinds.iter().copied() {
            kernel_selector::set(k);
            // one validate to capture crc + pass, then a timed loop
            let first = (d.validate)(&file).expect("validate");
            let timing = time_it(|| {
                kernel_selector::set(k);
                (d.validate)(&file).expect("validate").crc_actual
            });
            kernels.push(KernelResult {
                kernel: kernel_registry::name(k),
                crc: first.crc_actual,
                passed: first.passed,
                timing,
            });
        }

        let committed_crc = (d.validate)(&file).expect("validate").crc_expected;
        let conformant = kernels.iter().all(|kr| kr.crc == committed_crc);
        let backend_agreement = kernels
            .windows(2)
            .all(|w| w[0].crc == w[1].crc);

        reports.push(PrimReport {
            name: d.name,
            section: file.cookbook_section.clone(),
            committed_crc,
            conformant,
            backend_agreement,
            kernels,
        });
    }

    let drift = drift_check();
    let n_conf = reports.iter().filter(|r| r.conformant).count();
    let n_agree = reports.iter().filter(|r| r.backend_agreement).count();
    let total = reports.len();
    let all_ok = n_conf == total && n_agree == total && !drift.drifted;

    if json_out {
        emit_json(&reports, &kinds, &missing, &drift, all_ok);
    } else {
        emit_human(&reports, &kinds, &missing, &drift, n_conf, n_agree, total);
    }
    process::exit(if all_ok { 0 } else { 1 });
}

fn emit_human(
    reports: &[PrimReport],
    kinds: &[impl std::fmt::Debug],
    missing: &[&str],
    drift: &Drift,
    n_conf: usize,
    n_agree: usize,
    total: usize,
) {
    println!("SubstrateValidator (Rust)");
    println!("hardware: {}", hardware::tag());
    println!("kernels:  {:?}\n", kinds);
    println!(
        "{:<26} {:<6} {:<6} kernels (crc | ns/call mean)",
        "primitive", "conf", "agree"
    );
    for r in reports {
        let cells: Vec<String> = r
            .kernels
            .iter()
            .map(|k| format!("{}={}@{:.0}ns", k.kernel, u32_hex(k.crc), k.timing.ns_mean))
            .collect();
        println!(
            "{:<26} {:<6} {:<6} {}",
            r.name,
            if r.conformant { "ok" } else { "FAIL" },
            if r.backend_agreement { "ok" } else { "FAIL" },
            cells.join("  ")
        );
    }
    if !missing.is_empty() {
        println!("\nno committed vector: {}", missing.join(", "));
    }
    println!(
        "\nsource drift: {}  (stamped {} over {} files; now {} over {} files)",
        if drift.drifted { "DRIFTED" } else { "none" },
        drift.stamped_crc,
        drift.stamped_files,
        drift.current_crc,
        drift.current_files
    );
    println!(
        "{n_conf}/{total} conformant, {n_agree}/{total} backend-agree"
    );
}

fn emit_json(
    reports: &[PrimReport],
    kinds: &[impl std::fmt::Debug],
    missing: &[&str],
    drift: &Drift,
    all_ok: bool,
) {
    let prims: Vec<_> = reports
        .iter()
        .map(|r| {
            let kernels: Vec<_> = r
                .kernels
                .iter()
                .map(|k| {
                    json!({
                        "kernel": k.kernel,
                        "crc": u32_hex(k.crc),
                        "passed": k.passed,
                        "timing": {
                            "runs": k.timing.runs,
                            "ns_min": k.timing.ns_min,
                            "ns_mean": k.timing.ns_mean,
                            "ns_stddev": k.timing.ns_stddev,
                        }
                    })
                })
                .collect();
            json!({
                "primitive": r.name,
                "cookbook_section": r.section,
                "committed_crc": u32_hex(r.committed_crc),
                "conformant": r.conformant,
                "backend_agreement": r.backend_agreement,
                "kernels": kernels,
            })
        })
        .collect();

    let report = json!({
        "tool": "substrate-validator-rust",
        "hardware": hardware::tag(),
        "kernels_available": format!("{:?}", kinds),
        "all_ok": all_ok,
        "source_drift": {
            "drifted": drift.drifted,
            "stamped_crc": drift.stamped_crc,
            "current_crc": drift.current_crc,
            "stamped_files": drift.stamped_files,
            "current_files": drift.current_files,
        },
        "missing_vectors": missing,
        "primitives": prims,
    });
    println!("{}", serde_json::to_string_pretty(&report).unwrap());
}
