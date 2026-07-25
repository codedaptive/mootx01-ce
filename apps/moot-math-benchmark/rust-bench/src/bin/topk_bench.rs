// src/bin/topk_bench.rs
//
// Phase 2.delta-1 measurement: branchless top-K ladder
// maintenance (cookbook section 11.2). Rust mirror of
// `test-harness/swift/Sources/TopKBench/main.swift`. Sweeps K
// and N independently to characterize the SimdKernel
// hamming_top_k vs ScalarKernel hamming_top_k crossover and to
// check the cookbook section 17.1 hot-path budget of K=10 over
// 1M rows under 100 us.
//
// The Swift counterpart produced the number cited in row 5 of
// the measured production kernel table (commit 8e7916d,
// apple-m5-max, K=10 N=1M = 604 us for SimdKernel, 51x over
// scalar). This Rust binary mirrors the CLI and the JSON output
// schema so the two languages produce field-comparable files,
// extending the regression baseline to non-Apple targets and
// the Rust SimdKernel ladder at glref-rust-kernel_simd.rs line
// 194. The standalone binaries are historical instruments after
// this addition; the cookbook budget gate continues to be
// checkable from either language as needed.
//
// USAGE
//
//   topk-bench [--seed <0xhex>]
//              [--kernel <name>]    (default: all available)
//              [--n <list>]         (default: 256,1024,4096,16384,
//                                    65536,262144,1048576)
//              [--k <list>]         (default: 1,4,10,32,100)
//              [--out <path>]
//              [--quick]
//
// OUTPUT
//
//   Structured JSON with per-(kernel, N, K) latency. Reuses the
//   benchmarks/results/{date}-{hw}/ directory. Schema version
//   "topk-1" matches the Swift output; the only differing field
//   is `language` ("rust" vs "swift") so cross-language drift
//   checks are a single field diff.

use std::env;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process;
use std::time::{Duration, Instant};

use harness::SplitMix64;
use harness::{hardware, kernel_registry};

use substrate_kernel::kernel::{KernelKind, PortableKernel, SubstrateKernel};
use substrate_types::fingerprint256::Fingerprint256;

const DEFAULT_SEED: u64 = 0xCAFEBABEDEADBEEFu64;

const DEFAULT_N: &[usize] = &[256, 1024, 4096, 16384, 65536, 262144, 1048576];
const DEFAULT_K: &[usize] = &[1, 4, 10, 32, 100];

const WARMUP_FULL: Duration = Duration::from_millis(50);
const MEASURE_FULL: Duration = Duration::from_millis(200);
const WARMUP_QUICK: Duration = Duration::from_millis(10);
const MEASURE_QUICK: Duration = Duration::from_millis(40);

struct TopKMeasurement {
    kernel: KernelKind,
    n: usize,
    k: usize,
    iterations: u64,
    ns_min: u64,
    ns_mean: u64,
    ns_stddev: u64,
}

struct Args {
    seed: u64,
    kernel: Option<KernelKind>,
    n_list: Vec<usize>,
    k_list: Vec<usize>,
    out: Option<String>,
    quick: bool,
}

fn usage() -> ! {
    eprintln!(
        "usage: topk-bench [--seed <0xhex>] [--kernel <name>] \
         [--n <comma-list>] [--k <comma-list>] [--out <path>] [--quick]\n\
         \n\
         Defaults:\n\
           N: 256, 1024, 4096, 16384, 65536, 262144, 1048576\n\
           K: 1, 4, 10, 32, 100"
    );
    process::exit(2);
}

fn parse_seed(s: &str) -> u64 {
    let s = s.strip_prefix("0x").unwrap_or(s);
    u64::from_str_radix(s, 16).unwrap_or_else(|e| {
        eprintln!("invalid seed: {e}");
        process::exit(2);
    })
}

fn parse_list(s: &str) -> Option<Vec<usize>> {
    let mut out = Vec::new();
    for part in s.split(',') {
        let trimmed = part.trim();
        if trimmed.is_empty() {
            return None;
        }
        let v: usize = trimmed.parse().ok()?;
        out.push(v);
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

fn parse_args() -> Args {
    let argv: Vec<String> = env::args().collect();
    let mut args = Args {
        seed: DEFAULT_SEED,
        kernel: None,
        n_list: DEFAULT_N.to_vec(),
        k_list: DEFAULT_K.to_vec(),
        out: None,
        quick: false,
    };
    let mut i = 1;
    while i < argv.len() {
        match argv[i].as_str() {
            "--seed" => {
                i += 1;
                if i >= argv.len() {
                    usage();
                }
                args.seed = parse_seed(&argv[i]);
            }
            "--kernel" => {
                i += 1;
                if i >= argv.len() {
                    usage();
                }
                args.kernel = Some(KernelKind::parse(&argv[i]).unwrap_or_else(|| {
                    eprintln!("unknown kernel: {}", argv[i]);
                    process::exit(2);
                }));
            }
            "--n" => {
                i += 1;
                if i >= argv.len() {
                    usage();
                }
                args.n_list = parse_list(&argv[i]).unwrap_or_else(|| {
                    eprintln!("invalid --n list: {}", argv[i]);
                    process::exit(2);
                });
            }
            "--k" => {
                i += 1;
                if i >= argv.len() {
                    usage();
                }
                args.k_list = parse_list(&argv[i]).unwrap_or_else(|| {
                    eprintln!("invalid --k list: {}", argv[i]);
                    process::exit(2);
                });
            }
            "--out" => {
                i += 1;
                if i >= argv.len() {
                    usage();
                }
                args.out = Some(argv[i].clone());
            }
            "--quick" => {
                args.quick = true;
            }
            "--help" | "-h" => usage(),
            _ => usage(),
        }
        i += 1;
    }
    args
}

fn fingerprint_from_rng(rng: &mut SplitMix64) -> Fingerprint256 {
    Fingerprint256 {
        block0: rng.next(),
        block1: rng.next(),
        block2: rng.next(),
        block3: rng.next(),
    }
}

fn time_loop<F: FnMut()>(warmup: Duration, measure: Duration, mut body: F) -> (u64, u64, u64, u64) {
    let warmup_end = Instant::now() + warmup;
    while Instant::now() < warmup_end {
        body();
    }

    let mut calls_per_sample = 1u64;
    while calls_per_sample < (1 << 20) {
        let t0 = Instant::now();
        for _ in 0..calls_per_sample {
            body();
        }
        if t0.elapsed().as_nanos() >= 10_000 {
            break;
        }
        calls_per_sample *= 2;
    }

    let mut samples: Vec<u64> = Vec::with_capacity(1 << 16);
    let measure_end = Instant::now() + measure;
    while Instant::now() < measure_end {
        let t0 = Instant::now();
        for _ in 0..calls_per_sample {
            body();
        }
        let dt = t0.elapsed().as_nanos() as u64;
        samples.push((dt + calls_per_sample - 1) / calls_per_sample);
    }

    let sample_count = samples.len() as u64;
    if sample_count == 0 {
        return (0, 0, 0, 0);
    }
    let iters = sample_count * calls_per_sample;
    let min = *samples.iter().min().unwrap_or(&0);
    let sum: u128 = samples.iter().map(|n| *n as u128).sum();
    let mean = (sum / (sample_count as u128)) as u64;
    let var: u128 = samples
        .iter()
        .map(|n| {
            let d = (*n as i128) - (mean as i128);
            (d * d) as u128
        })
        .sum::<u128>()
        / (sample_count as u128);
    let stddev = (var as f64).sqrt() as u64;
    (iters, min, mean, stddev)
}

fn measure_top_k(
    kernel: &dyn SubstrateKernel,
    rng: &mut SplitMix64,
    n: usize,
    k: usize,
    warmup: Duration,
    measure: Duration,
) -> TopKMeasurement {
    let probe = fingerprint_from_rng(rng);
    let candidates: Vec<Fingerprint256> = (0..n).map(|_| fingerprint_from_rng(rng)).collect();
    // Sink reads result.1 (distance) to inhibit dead-code
    // elimination of the hot loop while preventing the compiler
    // from hoisting the call. Mirrors the Swift sink pattern.
    let mut sink: u32 = 0;

    let (iters, min, mean, stddev) = time_loop(warmup, measure, || {
        let result = kernel.hamming_top_k(&probe, &candidates, k);
        if !result.is_empty() {
            sink = sink.wrapping_add(result[0].1);
        }
    });
    if sink == 0xDEADBEEF {
        eprintln!("# sink: {}", sink);
    }

    TopKMeasurement {
        kernel: kernel.kind(),
        n,
        k,
        iterations: iters,
        ns_min: min,
        ns_mean: mean,
        ns_stddev: stddev,
    }
}

fn today_date_utc() -> String {
    chrono::Utc::now().format("%Y-%m-%d").to_string()
}

fn default_output_dir() -> PathBuf {
    // manifest = .../test-harness/rust
    // go up one to .../test-harness
    let manifest = env!("CARGO_MANIFEST_DIR");
    let mut p = PathBuf::from(manifest);
    p.pop();
    p.push("benchmarks");
    p.push("results");
    let date = today_date_utc();
    let hw = hardware::tag();
    p.push(format!("{}-{}", date, hw));
    p
}

fn write_json(
    ms: &[TopKMeasurement],
    path: &std::path::Path,
    seed: u64,
    warmup: Duration,
    measure: Duration,
    quick: bool,
) -> std::io::Result<()> {
    let f = fs::File::create(path)?;
    let mut w = std::io::BufWriter::new(f);
    writeln!(w, "{{")?;
    writeln!(w, "  \"schema_version\": \"topk-1\",")?;
    writeln!(w, "  \"language\": \"rust\",")?;
    writeln!(w, "  \"op\": \"hamming_top_k\",")?;
    writeln!(w, "  \"date\": \"{}\",", today_date_utc())?;
    writeln!(w, "  \"hardware_tag\": \"{}\",", hardware::tag())?;
    writeln!(w, "  \"seed\": \"0x{:016x}\",", seed)?;
    writeln!(w, "  \"timing\": {{")?;
    writeln!(w, "    \"warmup_ms\": {},", warmup.as_millis())?;
    writeln!(w, "    \"measure_ms\": {},", measure.as_millis())?;
    writeln!(w, "    \"quick_mode\": {}", quick)?;
    writeln!(w, "  }},")?;
    writeln!(w, "  \"measurements\": [")?;
    for (i, m) in ms.iter().enumerate() {
        let comma = if i + 1 < ms.len() { "," } else { "" };
        writeln!(
            w,
            "    {{ \"kernel\": \"{}\", \"n\": {}, \"k\": {}, \
              \"iterations\": {}, \"ns_per_call_min\": {}, \
              \"ns_per_call_mean\": {}, \"ns_per_call_stddev\": {} }}{}",
            m.kernel.as_str(),
            m.n,
            m.k,
            m.iterations,
            m.ns_min,
            m.ns_mean,
            m.ns_stddev,
            comma
        )?;
    }
    writeln!(w, "  ]")?;
    writeln!(w, "}}")?;
    Ok(())
}

fn main() {
    let args = parse_args();

    let kernels: Vec<KernelKind> = if let Some(k) = args.kernel {
        vec![k]
    } else {
        kernel_registry::available()
    };

    let (warmup, measure) = if args.quick {
        (WARMUP_QUICK, MEASURE_QUICK)
    } else {
        (WARMUP_FULL, MEASURE_FULL)
    };

    let out_path: PathBuf = if let Some(p) = args.out.as_deref() {
        PathBuf::from(p)
    } else {
        let dir = default_output_dir();
        if let Err(e) = fs::create_dir_all(&dir) {
            eprintln!("failed to create output dir {}: {}", dir.display(), e);
            process::exit(1);
        }
        dir.join("hamming_topk-rust.json")
    };

    eprintln!("# topk-bench (rust)");
    eprintln!("# seed:       0x{:016x}", args.seed);
    eprintln!("# hardware:   {}", hardware::tag());
    eprintln!(
        "# kernels:    {}",
        kernels
            .iter()
            .map(|k| k.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );
    eprintln!("# N values:   {:?}", args.n_list);
    eprintln!("# K values:   {:?}", args.k_list);
    eprintln!(
        "# timing:     warmup {}ms, measure {}ms{}",
        warmup.as_millis(),
        measure.as_millis(),
        if args.quick { " (quick)" } else { "" }
    );
    eprintln!();

    let mut all_measurements: Vec<TopKMeasurement> = Vec::new();
    for k_kind in &kernels {
        let kernel = PortableKernel::of_kind(*k_kind);
        // Match the Swift mirror: if the dispatcher returned a
        // different kind than requested (e.g. simd-nightly
        // feature disabled), skip rather than report misleading
        // numbers under the requested name.
        if kernel.kind() != *k_kind {
            eprintln!(
                "  skipping {} (dispatcher returned {})",
                k_kind.as_str(),
                kernel.kind().as_str()
            );
            continue;
        }
        eprintln!("  kernel={}", k_kind.as_str());
        let mut rng = SplitMix64::new(args.seed);
        for &n in &args.n_list {
            for &k_val in &args.k_list {
                let m = measure_top_k(&*kernel, &mut rng, n, k_val, warmup, measure);
                eprintln!(
                    "    N={:>7}  K={:>4}  min: {:>9}ns  ({} iters)",
                    n, k_val, m.ns_min, m.iterations
                );
                all_measurements.push(m);
            }
        }
        eprintln!();
    }

    if let Err(e) = write_json(
        &all_measurements,
        &out_path,
        args.seed,
        warmup,
        measure,
        args.quick,
    ) {
        eprintln!("write failed: {}", e);
        process::exit(1);
    }
    eprintln!("  wrote {}", out_path.display());
}
