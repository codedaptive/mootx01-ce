// src/bin/stress_test.rs
//
// Empirical kernel benchmark sweep. Measures per-(kernel, op,
// batch_size, mode) latency and emits structured JSON for the
// kernel-learned-dispatch decision protocol.
//
// USAGE
//
//   stress-test [--seed <0xhex>]
//               [--op <name>]            (one of: hamming, simhash, or_reduce,
//                                          all; default: all)
//               [--kernel <name> | --all]  (default: --all)
//               [--out <path>]            (a directory; the binary chooses
//                                          the filename, or a single .json
//                                          path; default: standard
//                                          benchmarks/results/{date}-{hw}/
//                                          location)
//               [--quick]                 (faster, less stable; for iteration)
//
// MODES
//
//   batched     - the trait's batched method (default impl is a
//                 loop over the pair-at-a-time op; overrides exist
//                 in SimdKernel and any future SIMD-backed kernel)
//   sequential  - explicit N-call loop of the pair-at-a-time op
//                 from the caller side, no batched method
//
// At Phase 1 (Scalar only) the two modes do essentially identical
// work, so the gap measures the trait dispatch and parameter-
// passing overhead. Phase 2+ backends override the batched
// methods and the gap widens. The decision-doc citations point
// to specific runs of this binary.
//
// OUTPUT
//
//   JSON file written to
//     test-harness/benchmarks/results/{YYYY-MM-DD}-{hw-slug}/
//       {op}-rust.json
//
//   The directory is gitignored. Decision docs cite the date +
//   hardware tag + commit hash that produced the numbers they
//   quote. The schema is committed (this file); the numbers
//   are not.

use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process;
use std::time::{Duration, Instant};

use harness::SplitMix64;
use harness::{hardware, kernel_registry};

use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hyperplane::HyperplaneFamily;
use substrate_kernel::kernel::{KernelKind, PortableKernel, SubstrateKernel};

const DEFAULT_SEED: u64 = 0xCAFEBABEDEADBEEFu64;
const BATCH_SIZES: [usize; 9] = [1, 2, 4, 8, 16, 32, 64, 128, 256];

// Default per-(kernel, op, batch_size, mode) budget. The full
// sweep is BATCH_SIZES.len() * 3 ops * 2 modes * N kernels.
// Each cell needs warmup + measure, so total wall time is
// 9 * 3 * 2 * N * (WARMUP + MEASURE). For N=2, WARMUP=50ms,
// MEASURE=200ms, that's 27 seconds. Doubles for each new kernel.
const WARMUP_FULL: Duration = Duration::from_millis(50);
const MEASURE_FULL: Duration = Duration::from_millis(200);
const WARMUP_QUICK: Duration = Duration::from_millis(10);
const MEASURE_QUICK: Duration = Duration::from_millis(40);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Mode { Batched, Sequential }

impl Mode {
    fn as_str(&self) -> &'static str {
        match self { Mode::Batched => "batched", Mode::Sequential => "sequential" }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Op { HammingDistanceBatch, SimhashBlockBatch, OrReduceBatch }

impl Op {
    fn as_str(&self) -> &'static str {
        match self {
            Op::HammingDistanceBatch => "hamming_distance_batch",
            Op::SimhashBlockBatch    => "simhash_block_batch",
            Op::OrReduceBatch        => "or_reduce_batch",
        }
    }
    fn cli_name(&self) -> &'static str {
        match self {
            Op::HammingDistanceBatch => "hamming",
            Op::SimhashBlockBatch    => "simhash",
            Op::OrReduceBatch        => "or_reduce",
        }
    }
    fn parse_cli(s: &str) -> Option<Self> {
        match s {
            "hamming"               => Some(Op::HammingDistanceBatch),
            "simhash"               => Some(Op::SimhashBlockBatch),
            "or_reduce" | "or-reduce" => Some(Op::OrReduceBatch),
            _ => None,
        }
    }
}

#[allow(dead_code)] // op held for symmetry with Swift mirror; writer groups by op externally
struct Measurement {
    kernel: KernelKind,
    op: Op,
    batch_size: usize,
    mode: Mode,
    iterations: u64,
    ns_min: u64,
    ns_mean: u64,
    ns_stddev: u64,
}

fn fingerprint_from_rng(rng: &mut SplitMix64) -> Fingerprint256 {
    Fingerprint256 {
        block0: rng.next(), block1: rng.next(),
        block2: rng.next(), block3: rng.next(),
    }
}

fn expand_seed_to_32(seed: u64) -> [u8; 32] {
    let mut out = [0u8; 32];
    let mut s = seed;
    for i in 0..4 {
        s = s.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = s;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^= z >> 31;
        out[i * 8..(i + 1) * 8].copy_from_slice(&z.to_le_bytes());
    }
    out
}

fn time_loop<F: FnMut()>(warmup: Duration, measure: Duration, mut body: F)
    -> (u64, u64, u64, u64)
{
    let warmup_end = Instant::now() + warmup;
    while Instant::now() < warmup_end { body(); }

    let mut samples: Vec<u64> = Vec::with_capacity(1 << 16);
    let measure_end = Instant::now() + measure;
    while Instant::now() < measure_end {
        let t0 = Instant::now();
        body();
        let dt = t0.elapsed().as_nanos() as u64;
        samples.push(dt);
    }

    let iters = samples.len() as u64;
    if iters == 0 { return (0, 0, 0, 0); }
    let min = *samples.iter().min().unwrap_or(&0);
    let sum: u128 = samples.iter().map(|n| *n as u128).sum();
    let mean = (sum / (iters as u128)) as u64;
    let var: u128 = samples.iter()
        .map(|n| { let d = (*n as i128) - (mean as i128); (d * d) as u128 })
        .sum::<u128>() / (iters as u128);
    let stddev = (var as f64).sqrt() as u64;
    (iters, min, mean, stddev)
}

fn measure_hamming(kernel: &dyn SubstrateKernel, rng: &mut SplitMix64,
                   batch_size: usize, warmup: Duration, measure: Duration)
    -> (Measurement, Measurement)
{
    let probe = fingerprint_from_rng(rng);
    let candidates: Vec<Fingerprint256> = (0..batch_size)
        .map(|_| fingerprint_from_rng(rng)).collect();
    let mut out = vec![0u32; batch_size];

    let (it_b, mn_b, mu_b, sd_b) = time_loop(warmup, measure, || {
        kernel.hamming_distance_batch(&probe, &candidates, &mut out);
    });
    let (it_s, mn_s, mu_s, sd_s) = time_loop(warmup, measure, || {
        for i in 0..batch_size {
            out[i] = kernel.hamming_distance_256(&probe, &candidates[i]);
        }
    });

    let kind = kernel.kind();
    (
        Measurement { kernel: kind, op: Op::HammingDistanceBatch, batch_size,
                      mode: Mode::Batched, iterations: it_b,
                      ns_min: mn_b, ns_mean: mu_b, ns_stddev: sd_b },
        Measurement { kernel: kind, op: Op::HammingDistanceBatch, batch_size,
                      mode: Mode::Sequential, iterations: it_s,
                      ns_min: mn_s, ns_mean: mu_s, ns_stddev: sd_s },
    )
}

fn measure_simhash(kernel: &dyn SubstrateKernel, rng: &mut SplitMix64,
                   batch_size: usize, warmup: Duration, measure: Duration)
    -> (Measurement, Measurement)
{
    let block_index = 0usize;
    let input_bit_length = 192usize;
    let input_word_count = (input_bit_length + 63) / 64;
    let hyperplane_seed = rng.next();
    let seed_bytes = expand_seed_to_32(hyperplane_seed);
    let family = HyperplaneFamily::generate(
        &seed_bytes, block_index, input_bit_length, 1.0);

    let inputs_owned: Vec<Vec<u64>> = (0..batch_size)
        .map(|_| (0..input_word_count).map(|_| rng.next()).collect()).collect();
    let inputs: Vec<&[u64]> = inputs_owned.iter().map(|v| v.as_slice()).collect();
    let mut out = vec![0u64; batch_size];

    let (it_b, mn_b, mu_b, sd_b) = time_loop(warmup, measure, || {
        kernel.simhash_block_batch(&inputs, &family, &mut out);
    });
    let (it_s, mn_s, mu_s, sd_s) = time_loop(warmup, measure, || {
        for i in 0..batch_size {
            out[i] = kernel.simhash_block(inputs[i], &family);
        }
    });

    let kind = kernel.kind();
    (
        Measurement { kernel: kind, op: Op::SimhashBlockBatch, batch_size,
                      mode: Mode::Batched, iterations: it_b,
                      ns_min: mn_b, ns_mean: mu_b, ns_stddev: sd_b },
        Measurement { kernel: kind, op: Op::SimhashBlockBatch, batch_size,
                      mode: Mode::Sequential, iterations: it_s,
                      ns_min: mn_s, ns_mean: mu_s, ns_stddev: sd_s },
    )
}

fn measure_or_reduce(kernel: &dyn SubstrateKernel, rng: &mut SplitMix64,
                     batch_size: usize, warmup: Duration, measure: Duration)
    -> (Measurement, Measurement)
{
    let inner_count = 8usize;
    let batches_owned: Vec<Vec<Fingerprint256>> = (0..batch_size)
        .map(|_| (0..inner_count).map(|_| fingerprint_from_rng(rng)).collect()).collect();
    let batches: Vec<&[Fingerprint256]> = batches_owned.iter().map(|v| v.as_slice()).collect();
    let mut out = vec![Fingerprint256::ZERO; batch_size];

    let (it_b, mn_b, mu_b, sd_b) = time_loop(warmup, measure, || {
        kernel.or_reduce_batch(&batches, &mut out);
    });
    let (it_s, mn_s, mu_s, sd_s) = time_loop(warmup, measure, || {
        for i in 0..batch_size {
            out[i] = kernel.or_reduce_256(batches[i]);
        }
    });

    let kind = kernel.kind();
    (
        Measurement { kernel: kind, op: Op::OrReduceBatch, batch_size,
                      mode: Mode::Batched, iterations: it_b,
                      ns_min: mn_b, ns_mean: mu_b, ns_stddev: sd_b },
        Measurement { kernel: kind, op: Op::OrReduceBatch, batch_size,
                      mode: Mode::Sequential, iterations: it_s,
                      ns_min: mn_s, ns_mean: mu_s, ns_stddev: sd_s },
    )
}

fn measure_one_op(op: Op, kernel: &dyn SubstrateKernel,
                  rng: &mut SplitMix64,
                  warmup: Duration, measure: Duration)
    -> Vec<Measurement>
{
    let mut out: Vec<Measurement> = Vec::with_capacity(BATCH_SIZES.len() * 2);
    for &bs in BATCH_SIZES.iter() {
        let (b, s) = match op {
            Op::HammingDistanceBatch => measure_hamming(kernel, rng, bs, warmup, measure),
            Op::SimhashBlockBatch    => measure_simhash(kernel, rng, bs, warmup, measure),
            Op::OrReduceBatch        => measure_or_reduce(kernel, rng, bs, warmup, measure),
        };
        eprintln!("    bs={:>5}  batched: {:>7}ns  sequential: {:>7}ns",
                  bs, b.ns_min, s.ns_min);
        out.push(b);
        out.push(s);
    }
    out
}

fn git_short_sha() -> Option<String> {
    let out = std::process::Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output().ok()?;
    if !out.status.success() { return None; }
    let s = String::from_utf8(out.stdout).ok()?;
    let trimmed = s.trim();
    if trimmed.is_empty() { None } else { Some(trimmed.to_string()) }
}

fn write_json(measurements: &[Measurement], path: &Path, op: Op,
              seed: u64, warmup: Duration, measure: Duration,
              quick: bool) -> std::io::Result<()>
{
    let now = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let date = chrono::Utc::now().format("%Y-%m-%d").to_string();
    let hw = hardware::tag();
    let sha = git_short_sha().unwrap_or_else(|| "unknown".to_string());

    let f = fs::File::create(path)?;
    let mut w = std::io::BufWriter::new(f);
    writeln!(w, "{{")?;
    writeln!(w, "  \"schema_version\": \"2\",")?;
    writeln!(w, "  \"language\": \"rust\",")?;
    writeln!(w, "  \"op\": \"{}\",", op.as_str())?;
    writeln!(w, "  \"date\": \"{}\",", date)?;
    writeln!(w, "  \"generated_at\": \"{}\",", now)?;
    writeln!(w, "  \"hardware_tag\": \"{}\",", hw)?;
    writeln!(w, "  \"commit_sha\": \"{}\",", sha)?;
    writeln!(w, "  \"seed\": \"0x{:016x}\",", seed)?;
    writeln!(w, "  \"timing\": {{")?;
    writeln!(w, "    \"warmup_ms\": {},", warmup.as_millis())?;
    writeln!(w, "    \"measure_ms\": {},", measure.as_millis())?;
    writeln!(w, "    \"quick_mode\": {}", quick)?;
    writeln!(w, "  }},")?;
    writeln!(w, "  \"platform\": {{")?;
    writeln!(w, "    \"arch\": \"{}\",", std::env::consts::ARCH)?;
    writeln!(w, "    \"os\":   \"{}\"", std::env::consts::OS)?;
    writeln!(w, "  }},")?;
    writeln!(w, "  \"measurements\": [")?;
    for (i, m) in measurements.iter().enumerate() {
        let comma = if i + 1 < measurements.len() { "," } else { "" };
        // Per-element timing (best-case: ns_min / batch_size).
        let ns_per_element = if m.batch_size > 0 {
            m.ns_min as f64 / m.batch_size as f64
        } else { 0.0 };
        writeln!(w,
            "    {{ \"kernel\": \"{}\", \"batch_size\": {}, \"mode\": \"{}\", \
              \"iterations\": {}, \"ns_per_call_min\": {}, \
              \"ns_per_call_mean\": {}, \"ns_per_call_stddev\": {}, \
              \"ns_per_element_min\": {:.3} }}{}",
            m.kernel.as_str(), m.batch_size, m.mode.as_str(),
            m.iterations, m.ns_min, m.ns_mean, m.ns_stddev,
            ns_per_element, comma)?;
    }
    writeln!(w, "  ]")?;
    writeln!(w, "}}")?;
    Ok(())
}

fn default_output_dir() -> PathBuf {
    // Walk up from CARGO_MANIFEST_DIR to find the test-harness/
    // root (which contains both swift/ and rust/), then append
    // benchmarks/results/{date}-{hw}/.
    let manifest = env!("CARGO_MANIFEST_DIR");
    let mut p = PathBuf::from(manifest);
    // manifest = .../test-harness/rust
    // go up one to .../test-harness
    p.pop();
    p.push("benchmarks");
    p.push("results");
    let date = chrono::Utc::now().format("%Y-%m-%d").to_string();
    let hw = hardware::tag();
    p.push(format!("{}-{}", date, hw));
    p
}

fn usage() -> ! {
    eprintln!(
        "usage: stress-test [--seed <0xhex>] [--op <name>] \
         [--kernel <name> | --all] [--out <path>] [--quick]\n\
         \n\
         Ops:     hamming, simhash, or_reduce, all (default: all)\n\
         Kernels: scalar, simd, or use --all to iterate every available\n\
                  kernel (default: --all)\n\
         Output:  --out <path> may be a directory (the binary names the\n\
                  file) or a .json path. Default: standard\n\
                  test-harness/benchmarks/results/{{date}}-{{hw}}/ directory."
    );
    process::exit(2);
}

fn parse_seed(s: &str) -> u64 {
    let s = s.strip_prefix("0x").unwrap_or(s);
    u64::from_str_radix(s, 16).unwrap_or_else(|e| {
        eprintln!("invalid seed: {e}"); process::exit(2);
    })
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut seed = DEFAULT_SEED;
    let mut out_arg: Option<String> = None;
    let mut kernel_arg: Option<String> = None;
    let mut all_kernels = false;
    let mut op_arg: String = "all".to_string();
    let mut quick = false;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--seed"   => { i += 1; if i >= args.len() { usage(); } seed = parse_seed(&args[i]); }
            "--op"     => { i += 1; if i >= args.len() { usage(); } op_arg = args[i].clone(); }
            "--kernel" => { i += 1; if i >= args.len() { usage(); } kernel_arg = Some(args[i].clone()); }
            "--all"    => { all_kernels = true; }
            "--out"    => { i += 1; if i >= args.len() { usage(); } out_arg = Some(args[i].clone()); }
            "--quick"  => { quick = true; }
            "--help" | "-h" => usage(),
            _ => usage(),
        }
        i += 1;
    }

    // Resolve op list
    let ops: Vec<Op> = if op_arg == "all" {
        vec![Op::HammingDistanceBatch, Op::SimhashBlockBatch, Op::OrReduceBatch]
    } else {
        match Op::parse_cli(&op_arg) {
            Some(o) => vec![o],
            None => { eprintln!("unknown op: {op_arg}"); process::exit(2); }
        }
    };

    // Resolve kernel list
    let kernels: Vec<KernelKind> = match (kernel_arg, all_kernels) {
        (Some(_), true) => { eprintln!("--kernel and --all are mutually exclusive"); process::exit(2); }
        (Some(name), false) => {
            let k = KernelKind::parse(&name).unwrap_or_else(|| {
                eprintln!("unknown kernel: {name}"); process::exit(2);
            });
            vec![k]
        }
        (None, _) => kernel_registry::available(),
    };

    let (warmup, measure) = if quick {
        (WARMUP_QUICK, MEASURE_QUICK)
    } else {
        (WARMUP_FULL, MEASURE_FULL)
    };

    // Resolve output path
    let out_dir = match out_arg.as_deref() {
        Some(p) => {
            let pb = PathBuf::from(p);
            // If it ends with .json, we treat the whole path as a
            // single-file destination (only valid for one op).
            if pb.extension().map(|e| e == "json").unwrap_or(false) {
                if ops.len() != 1 {
                    eprintln!("--out <file.json> requires --op <one-op>");
                    process::exit(2);
                }
                pb
            } else {
                pb
            }
        }
        None => default_output_dir(),
    };

    eprintln!("# stress-test (rust)");
    eprintln!("# seed:          0x{:016x}", seed);
    eprintln!("# hardware:      {}", hardware::tag());
    eprintln!("# kernels:       {}", kernels.iter().map(|k| k.as_str()).collect::<Vec<_>>().join(", "));
    eprintln!("# ops:           {}", ops.iter().map(|o| o.as_str()).collect::<Vec<_>>().join(", "));
    eprintln!("# batch sizes:   {:?}", BATCH_SIZES);
    eprintln!("# timing:        warmup {}ms, measure {}ms{}",
              warmup.as_millis(), measure.as_millis(),
              if quick { " (quick)" } else { "" });
    eprintln!();

    for op in &ops {
        let mut all_measurements: Vec<Measurement> = Vec::new();

        for &k in &kernels {
            let kernel = PortableKernel::of_kind(k);
            // Verify the dispatcher gave us what we asked for.
            // If of_kind(Simd) falls back to Scalar (e.g. feature
            // disabled), skip this kernel rather than reporting
            // misleading numbers.
            if kernel.kind() != k {
                eprintln!("  skipping {} ({} requested but dispatcher returned {})",
                          k.as_str(), k.as_str(), kernel.kind().as_str());
                continue;
            }
            eprintln!("  kernel={}  op={}", k.as_str(), op.as_str());
            let mut rng = SplitMix64::new(seed);
            let ms = measure_one_op(*op, &*kernel, &mut rng, warmup, measure);
            all_measurements.extend(ms);
        }

        // Decide the file path
        let file_path: PathBuf = if out_dir.extension().map(|e| e == "json").unwrap_or(false) {
            out_dir.clone()
        } else {
            if let Err(e) = fs::create_dir_all(&out_dir) {
                eprintln!("failed to create output dir {}: {}", out_dir.display(), e);
                process::exit(1);
            }
            out_dir.join(format!("{}-rust.json", op.cli_name()))
        };

        if let Err(e) = write_json(&all_measurements, &file_path, *op,
                                   seed, warmup, measure, quick) {
            eprintln!("write failed: {}", e);
            process::exit(1);
        }
        eprintln!("  wrote {}", file_path.display());
        eprintln!();
    }
}
