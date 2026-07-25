use std::env;
use std::fs;
use std::hint::black_box;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use harness::{all_primitives, find_primitive, hardware, JsonReader, PrimitiveDescriptor};
use serde::Serialize;

#[derive(Serialize)]
struct Timing {
    warmup_ms: u64,
    measure_ms: u64,
    quick_mode: bool,
}

#[derive(Serialize)]
struct Platform {
    arch: String,
    os: String,
}

#[derive(Serialize)]
struct Measurement {
    primitive: String,
    cookbook_section: String,
    cases_per_iteration: usize,
    iterations: usize,
    ns_per_batch_min: u128,
    ns_per_batch_mean: u128,
    ns_per_batch_stddev: u128,
    ns_per_case_min: f64,
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
    vector_root: String,
    timing: Timing,
    platform: Platform,
    measurements: Vec<Measurement>,
}

fn usage() -> ! {
    eprintln!("usage: catalog-bench --vectors <dir> [--primitive <name>] [--out <path>] [--quick]");
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
    if samples.is_empty() {
        return (0, 0, 0);
    }
    let min = *samples.iter().min().unwrap();
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

fn measure<F>(
    warmup: Duration,
    window: Duration,
    mut body: F,
) -> Result<(usize, u128, u128, u128), Box<dyn std::error::Error>>
where
    F: FnMut() -> Result<u32, Box<dyn std::error::Error>>,
{
    let warm = Instant::now();
    while warm.elapsed() < warmup {
        black_box(body()?);
    }
    let start_window = Instant::now();
    let mut samples = Vec::new();
    while start_window.elapsed() < window {
        let start = Instant::now();
        black_box(body()?);
        samples.push(start.elapsed().as_nanos());
    }
    let (min, mean, stddev) = stats(&samples);
    Ok((samples.len(), min, mean, stddev))
}

fn run_one(
    desc: PrimitiveDescriptor,
    root: &Path,
    warmup: Duration,
    window: Duration,
) -> Result<Measurement, Box<dyn std::error::Error>> {
    let path = root.join(format!("{}.json", desc.name));
    let file = JsonReader::parse_vector_file(&fs::read_to_string(path)?)?;
    let initial = (desc.validate)(&file)?;
    if !initial.passed {
        return Err(format!("conformance prerequisite failed for {}", desc.name).into());
    }
    let timed = measure(warmup, window, || {
        let result = (desc.validate)(&file)?;
        if !result.passed {
            return Err(format!("validation drift for {}", desc.name).into());
        }
        Ok(result.crc_actual)
    })?;
    Ok(Measurement {
        primitive: desc.name.into(),
        cookbook_section: desc.cookbook_section.into(),
        cases_per_iteration: file.cases.len(),
        iterations: timed.0,
        ns_per_batch_min: timed.1,
        ns_per_batch_mean: timed.2,
        ns_per_batch_stddev: timed.3,
        ns_per_case_min: if file.cases.is_empty() {
            0.0
        } else {
            timed.1 as f64 / file.cases.len() as f64
        },
    })
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut vector_root: Option<PathBuf> = None;
    let mut primitive: Option<String> = None;
    let mut out = PathBuf::from("catalog-rust.json");
    let mut quick = false;
    let args: Vec<String> = env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--vectors" => {
                i += 1;
                if i >= args.len() {
                    usage()
                };
                vector_root = Some(PathBuf::from(&args[i]));
            }
            "--primitive" => {
                i += 1;
                if i >= args.len() {
                    usage()
                };
                primitive = Some(args[i].clone());
            }
            "--out" => {
                i += 1;
                if i >= args.len() {
                    usage()
                };
                out = PathBuf::from(&args[i]);
            }
            "--quick" => quick = true,
            "--help" | "-h" => usage(),
            _ => usage(),
        }
        i += 1;
    }
    let root = vector_root.unwrap_or_else(|| usage());
    let descriptors = if let Some(name) = primitive {
        vec![find_primitive(&name).unwrap_or_else(|| {
            eprintln!("unknown primitive: {name}");
            usage()
        })]
    } else {
        all_primitives()
    };
    let (warmup_ms, measure_ms) = if quick { (5, 20) } else { (30, 120) };
    let mut measurements = Vec::new();
    for desc in descriptors {
        let row = run_one(
            desc,
            &root,
            Duration::from_millis(warmup_ms),
            Duration::from_millis(measure_ms),
        )?;
        println!(
            "  {:30} {:4} cases  {:10} ns/batch  {:10.1} ns/case",
            row.primitive, row.cases_per_iteration, row.ns_per_batch_min, row.ns_per_case_min
        );
        measurements.push(row);
    }
    let generated_at = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let report = Report {
        schema_version: "catalog-1",
        language: "rust",
        op: "canonical_primitive_validation",
        date: generated_at[..10].into(),
        generated_at,
        hardware_tag: hardware::tag(),
        commit_sha: git_commit(),
        vector_root: root.display().to_string(),
        timing: Timing {
            warmup_ms,
            measure_ms,
            quick_mode: quick,
        },
        platform: Platform {
            arch: env::consts::ARCH.into(),
            os: env::consts::OS.into(),
        },
        measurements,
    };
    if let Some(parent) = out.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(&out, serde_json::to_string_pretty(&report)? + "\n")?;
    println!("  wrote {}", out.display());
    Ok(())
}
