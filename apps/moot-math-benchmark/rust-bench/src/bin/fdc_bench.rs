use std::env;
use std::fs;
use std::hint::black_box;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};

use harness::hardware;
use lattice_lib::{Fdc, FdcContentKind};
use serde::Serialize;

#[derive(Serialize)]
struct Measurement {
    operation: String,
    workload: String,
    bytes: usize,
    tokens: usize,
    iterations: usize,
    ns_per_call_min: u128,
    ns_per_call_mean: u128,
    ns_per_call_stddev: u128,
}

#[derive(Serialize)]
struct Timing {
    warmup_ms: u64,
    measure_ms: u64,
}

#[derive(Serialize)]
struct Report {
    schema_version: &'static str,
    language: &'static str,
    op: &'static str,
    date: String,
    generated_at: String,
    hardware_tag: String,
    commit_sha: String,
    classifier_version: String,
    data_version: String,
    semantic_model_version: String,
    semantic_model_sha256: String,
    cold_start_ns: u128,
    timing: Timing,
    quick_mode: bool,
    measurements: Vec<Measurement>,
}

fn usage() -> ! {
    eprintln!("usage: fdc-bench [--out <path>] [--quick]");
    std::process::exit(2)
}

fn git_commit() -> String {
    Command::new("git")
        .args(["rev-parse", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_owned())
        .unwrap_or_else(|| "unknown".into())
}

fn stats(samples: &[u128]) -> (u128, u128, u128) {
    let min = *samples.iter().min().unwrap_or(&0);
    if samples.is_empty() {
        return (min, 0, 0);
    }
    let mean = samples.iter().map(|&x| x as f64).sum::<f64>() / samples.len() as f64;
    let variance = samples
        .iter()
        .map(|&x| {
            let d = x as f64 - mean;
            d * d
        })
        .sum::<f64>()
        / samples.len() as f64;
    (min, mean.round() as u128, variance.sqrt().round() as u128)
}

fn timed<F>(warmup: Duration, window: Duration, mut body: F) -> (usize, u128, u128, u128)
where
    F: FnMut() -> usize,
{
    let warm = Instant::now();
    while warm.elapsed() < warmup {
        black_box(body());
    }
    let begin = Instant::now();
    let mut samples = Vec::new();
    while begin.elapsed() < window {
        let start = Instant::now();
        black_box(body());
        samples.push(start.elapsed().as_nanos());
    }
    let (min, mean, stddev) = stats(&samples);
    (samples.len(), min, mean, stddev)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut quick = false;
    let mut out = PathBuf::from("fdc-rust.json");
    let args: Vec<String> = env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--quick" => quick = true,
            "--out" => {
                i += 1;
                if i >= args.len() {
                    usage()
                };
                out = PathBuf::from(&args[i]);
            }
            "--help" | "-h" => usage(),
            _ => usage(),
        };
        i += 1;
    }
    let long = vec!["The memory substrate combines deterministic classification, bitmap filtering, semantic ranking, graph traversal, temporal scoring, and durable audit records."; 10].join(" ");
    let workloads: Vec<(&str, String)> = vec![
        ("short_resolved", "graph algorithms and information retrieval".into()),
        ("medium_resolved", "A deterministic local memory system classifies documents, stores fingerprints, and retrieves related evidence with graph centrality and matrix scoring.".into()),
        ("long_mixed", long), ("unresolved", "florble quux zibble wump snarkle".into()),
        ("code", "fn hamming(a: u64, b: u64) -> u32 { (a ^ b).count_ones() }".into()),
    ];
    let cold = Instant::now();
    black_box(Fdc::encode(&workloads[0].1));
    let cold_start_ns = cold.elapsed().as_nanos();
    if !Fdc::is_available() {
        return Err("FDC artifacts unavailable".into());
    }
    let (warmup_ms, measure_ms) = if quick { (5, 20) } else { (30, 120) };
    let warm = Duration::from_millis(warmup_ms);
    let window = Duration::from_millis(measure_ms);
    let mut rows = Vec::new();
    for (name, text) in &workloads {
        let is_code = *name == "code";
        let mut operations: Vec<(&str, Box<dyn FnMut() -> usize>)> = vec![
            (
                "encode",
                Box::new(|| Fdc::encode(text).map(|x| x.len()).unwrap_or(0)),
            ),
            (
                "encode_anchor_no_record",
                Box::new(|| {
                    let kind = if is_code {
                        FdcContentKind::Code
                    } else {
                        FdcContentKind::Text
                    };
                    let x = Fdc::encode_anchor_for_content_no_record(text, kind);
                    x.0.map(|s| s.len()).unwrap_or(0) ^ x.1.map(|s| s.len()).unwrap_or(0)
                }),
            ),
            (
                "semantic_candidates_8",
                Box::new(|| {
                    Fdc::semantic_candidates(text, 8)
                        .iter()
                        .fold(0usize, |a, c| a ^ c.code.len() ^ c.score as usize)
                }),
            ),
            (
                "semantic_decision",
                Box::new(|| {
                    Fdc::semantic_decision(text)
                        .map(|d| d.code.len() ^ d.score as usize)
                        .unwrap_or(0)
                }),
            ),
        ];
        for (operation, body) in operations.iter_mut() {
            let t = timed(warm, window, body);
            rows.push(Measurement {
                operation: (*operation).into(),
                workload: (*name).into(),
                bytes: text.len(),
                tokens: text.split_whitespace().count(),
                iterations: t.0,
                ns_per_call_min: t.1,
                ns_per_call_mean: t.2,
                ns_per_call_stddev: t.3,
            });
            println!("  {operation} {name}: {} ns", t.1);
        }
    }
    let generated_at = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let report = Report {
        schema_version: "fdc-1",
        language: "rust",
        op: "fdc_classifier_v4",
        date: generated_at[..10].into(),
        generated_at,
        hardware_tag: hardware::tag(),
        commit_sha: git_commit(),
        classifier_version: Fdc::CLASSIFIER_VERSION.into(),
        data_version: Fdc::data_version().into(),
        semantic_model_version: Fdc::semantic_model_version().into(),
        semantic_model_sha256: Fdc::semantic_model_sha256().into(),
        cold_start_ns,
        timing: Timing {
            warmup_ms,
            measure_ms,
        },
        quick_mode: quick,
        measurements: rows,
    };
    if let Some(parent) = out.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(&out, serde_json::to_string_pretty(&report)? + "\n")?;
    println!("  wrote {}", out.display());
    Ok(())
}
