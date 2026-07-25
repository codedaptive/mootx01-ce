// src/bin/ml_bench.rs
//
// SubstrateML algorithm benchmark sweep. Measures per-(algorithm,
// size, params) latency for the 15 SubstrateML algorithms — the
// cold-path / dreaming-daemon math — and emits structured JSON.
//
// Rust mirror of swift/Sources/MLBench/main.swift.
//
// METHODOLOGY GATE
//
//   Per the measured backend gate:
//   every cold-path algorithm gets measured on real hardware
//   before the dreaming-daemon schedule and platform-specific
//   default-backend selection are locked. No "I calculated that
//   X would be slower" — only "measured at N ns/call on
//   <hardware> <date>, commit <sha>".
//
// USAGE
//
//   ml-bench [--seed <0xhex>]
//            [--algorithm <name>]   (one of the 15 algorithms or `all`)
//            [--out <path>]          (.json file or directory)
//            [--quick]               (smaller sweep for iteration)

use std::env;
use std::fs;
use std::hint::black_box;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process;
use std::time::{Duration, Instant};

use harness::{hardware, SplitMix64};

use substrate_ml::moment_summary::TimeRange;
use substrate_types::fingerprint256::Fingerprint256;
use substrate_types::hlc::HLC;
use substrate_types::hyperplane::HyperplaneFamily;

use substrate_ml::anomaly::AnomalyDetection;
use substrate_ml::bradley_terry::{BradleyTerryEstimator, PreferenceObservation};
use substrate_ml::calibration::LLMCalibrationCurve;
use substrate_ml::community_detection::CommunityDetection;
use substrate_ml::composite_distance::CompositeDistance;
use substrate_ml::eigenvalue_centrality::EigenvalueCentrality;
use substrate_ml::feature_extractors::{
    CoreLocationExtractor, CoreLocationSample, HealthKitExtractor, HealthKitSample,
};
use substrate_ml::info_theory::InformationTheory;
use substrate_ml::lattice_distance::UDCTreeDistance;
use substrate_ml::moment_summary::{MomentSummary, RowLite};
use substrate_ml::nmf::NMFAlternatingLeastSquares;
use substrate_ml::random_walks::RandomWalks;
use substrate_ml::temporal_compression::{TemporalCompression, WindowLevel};

const DEFAULT_SEED: u64 = 0xCAFEBABEDEADBEEFu64;

const WARMUP_FULL: Duration = Duration::from_millis(50);
const MEASURE_FULL: Duration = Duration::from_millis(200);
const WARMUP_QUICK: Duration = Duration::from_millis(5);
const MEASURE_QUICK: Duration = Duration::from_millis(20);

#[derive(Debug, Clone)]
struct Measurement {
    algorithm: &'static str,
    params: String,
    iterations: u64,
    ns_per_call_min: u128,
    ns_per_call_mean: u128,
    ns_per_call_stddev: u128,
}

fn time_loop<F: FnMut()>(warmup: Duration, measure: Duration, mut f: F) -> (u64, u128, u128, u128) {
    let warm_until = Instant::now() + warmup;
    while Instant::now() < warm_until {
        f();
    }
    // Batch sub-tick operations until one timed sample spans at least 10 µs;
    // report the divided per-call duration and the true total call count.
    let mut calls_per_sample: u64 = 1;
    while calls_per_sample < 1_048_576 {
        let t0 = Instant::now();
        for _ in 0..calls_per_sample {
            f();
        }
        if t0.elapsed() >= Duration::from_micros(10) {
            break;
        }
        calls_per_sample *= 2;
    }
    let measure_until = Instant::now() + measure;
    let mut samples: Vec<u128> = Vec::with_capacity(1024);
    while Instant::now() < measure_until {
        let t0 = Instant::now();
        for _ in 0..calls_per_sample {
            f();
        }
        let elapsed = t0.elapsed().as_nanos();
        let divisor = calls_per_sample as u128;
        samples.push((elapsed + divisor - 1) / divisor);
    }
    let n = samples.len() as u128;
    if n == 0 {
        return (0, 0, 0, 0);
    }
    let min = *samples.iter().min().unwrap();
    let sum: u128 = samples.iter().sum();
    let mean = sum / n;
    let var: u128 = samples
        .iter()
        .map(|s| {
            let d = if *s > mean { s - mean } else { mean - s };
            d * d
        })
        .sum::<u128>()
        / n;
    let stddev = (var as f64).sqrt() as u128;
    (n as u64 * calls_per_sample, min, mean, stddev)
}

fn make(algorithm: &'static str, params: String, t: (u64, u128, u128, u128)) -> Measurement {
    Measurement {
        algorithm,
        params,
        iterations: t.0,
        ns_per_call_min: t.1,
        ns_per_call_mean: t.2,
        ns_per_call_stddev: t.3,
    }
}

fn rand_f32_01(rng: &mut SplitMix64) -> f32 {
    (rng.next() >> 32) as u32 as f32 / u32::MAX as f32
}
fn rand_f64_01(rng: &mut SplitMix64) -> f64 {
    rng.next() as f64 / u64::MAX as f64
}

fn measure_anomaly(rng: &mut SplitMix64, warmup: Duration, measure: Duration) -> Vec<Measurement> {
    let mut out = Vec::new();
    for &n in &[100usize, 1_000, 10_000, 100_000] {
        let window: Vec<f32> = (0..n).map(|_| rand_f32_01(rng)).collect();
        let current = rand_f32_01(rng);
        // estate="" + ts=0 = telemetry off (no ObserverSink emit), so the
        // bench times pure compute. Swift's port defaults these; Rust has no
        // default args, so they are passed explicitly.
        let t = time_loop(warmup, measure, || {
            black_box(AnomalyDetection::rolling_z_score(&window, current, "", 0.0));
        });
        out.push(make("anomaly_z_score", format!("n={}", n), t));
        let t = time_loop(warmup, measure, || {
            black_box(AnomalyDetection::rolling_modified_z_score(
                &window, current, "", 0.0,
            ));
        });
        out.push(make("anomaly_modified_z_score", format!("n={}", n), t));
    }
    out
}

fn measure_bradley_terry(
    rng: &mut SplitMix64,
    warmup: Duration,
    measure: Duration,
) -> Vec<Measurement> {
    use substrate_ml::bradley_terry::RowId;
    let mut out = Vec::new();
    for &n_items in &[10usize, 100, 1_000] {
        let ids: Vec<RowId> = (0..n_items).map(|_| RowId(rng.next() as u128)).collect();
        let obs: Vec<PreferenceObservation> = (0..n_items.min(50))
            .map(|i| {
                let winner = ids[i % n_items];
                let losers = vec![ids[(i + 1) % n_items], ids[(i + 2) % n_items]];
                PreferenceObservation::new(winner, losers)
            })
            .collect();
        let mut est = BradleyTerryEstimator::new(0.1, 0.001);
        let single = &obs[0];
        let t = time_loop(warmup, measure, || {
            est.observe(single);
        });
        out.push(make(
            "bradley_terry_observe",
            format!("items={}", n_items),
            t,
        ));
        let mut est2 = BradleyTerryEstimator::new(0.1, 0.001);
        let t = time_loop(warmup, measure, || {
            est2.observe_batch(&obs);
        });
        out.push(make(
            "bradley_terry_observe_batch",
            format!("items={},batch={}", n_items, obs.len()),
            t,
        ));
    }
    out
}

fn build_adjacency(rng: &mut SplitMix64, n: usize) -> Vec<Vec<(usize, f64)>> {
    (0..n)
        .map(|i| {
            let edge_count = 3 + (rng.next() as usize % 4);
            (0..edge_count)
                .map(|_| {
                    let dst = (rng.next() as usize) % n;
                    let w = 0.1 + rand_f64_01(rng) * 5.0;
                    (dst, w)
                })
                .filter(|(dst, _)| *dst != i)
                .collect()
        })
        .collect()
}

fn measure_community_detection(
    rng: &mut SplitMix64,
    warmup: Duration,
    measure: Duration,
) -> Vec<Measurement> {
    let mut out = Vec::new();
    for &n in &[50usize, 200, 1_000] {
        let adjacency = build_adjacency(rng, n);
        // estate="" + ts=0.0: telemetry off — bench times pure compute.
        let t = time_loop(warmup, measure, || {
            black_box(CommunityDetection::detect(&adjacency, 10, "", 0.0));
        });
        out.push(make("community_detection", format!("n={}", n), t));
    }
    out
}

fn measure_composite_distance(
    _rng: &mut SplitMix64,
    warmup: Duration,
    measure: Duration,
) -> Vec<Measurement> {
    let mut out = Vec::new();
    let t = time_loop(warmup, measure, || {
        black_box(CompositeDistance::distance(0.42, 73, 0.6, 0.4, true));
    });
    out.push(make("composite_distance", "single_call".into(), t));
    out
}

fn measure_eigenvalue_centrality(
    rng: &mut SplitMix64,
    warmup: Duration,
    measure: Duration,
) -> Vec<Measurement> {
    let mut out = Vec::new();
    for &n in &[50usize, 200, 1_000] {
        let adjacency = build_adjacency(rng, n);
        // estate="" + ts=0 = telemetry off; bench times pure compute.
        let t = time_loop(warmup, measure, || {
            black_box(EigenvalueCentrality::compute(
                &adjacency, 100, 1e-6, "", 0.0,
            ));
        });
        out.push(make("eigenvalue_centrality", format!("n={}", n), t));
    }
    out
}

fn measure_feature_extractors(
    _rng: &mut SplitMix64,
    warmup: Duration,
    measure: Duration,
) -> Vec<Measurement> {
    let mut out = Vec::new();
    let family = HyperplaneFamily::generate(&[0u8; 32], 0, 64, 0.5);
    let family1 = HyperplaneFamily::generate(&[0u8; 32], 1, 64, 0.5);
    let family2 = HyperplaneFamily::generate(&[0u8; 32], 2, 64, 0.5);
    let family3 = HyperplaneFamily::generate(&[0u8; 32], 3, 64, 0.5);
    let hyperplanes = [family, family1, family2, family3];
    let hlc = HLC {
        physical_time: 1_700_000_000_000,
        logical_count: 0,
        node_id: 1,
    };
    let extractor = HealthKitExtractor {
        hyperplanes: &hyperplanes,
    };
    let sample = HealthKitSample {
        quantity_type: "stepCount".into(),
        value: 8500.0,
        unit: "count".into(),
        start_date: 1_700_000_000.0,
        end_date: 1_700_003_600.0,
        source_device: "iPhone".into(),
    };
    let t = time_loop(warmup, measure, || {
        black_box(extractor.extract(&sample, hlc, 0x12345678));
    });
    out.push(make(
        "feature_extractor_healthkit",
        "single_sample".into(),
        t,
    ));
    let ext2 = CoreLocationExtractor {
        hyperplanes: &hyperplanes,
    };
    let cls = CoreLocationSample {
        latitude: 37.7749,
        longitude: -122.4194,
        altitude: 16.0,
        speed: 0.0,
        course: 0.0,
        timestamp: 1_700_000_000.0,
        horizontal_accuracy: 5.0,
    };
    let t = time_loop(warmup, measure, || {
        black_box(ext2.extract(&cls, hlc, 0x12345678));
    });
    out.push(make(
        "feature_extractor_corelocation",
        "single_sample".into(),
        t,
    ));
    out
}

fn measure_fft(_rng: &mut SplitMix64, warmup: Duration, measure: Duration) -> Vec<Measurement> {
    let mut out = Vec::new();
    for &n in &[64usize, 256, 1024, 4096, 16384] {
        let input: Vec<f64> = (0..n).map(|i| (i as f64 * 0.1).sin()).collect();
        let t = time_loop(warmup, measure, || {
            black_box(substrate_ml::fft::forward(&input));
        });
        out.push(make("fft_forward", format!("n={}", n), t));
        let t = time_loop(warmup, measure, || {
            black_box(substrate_ml::fft::magnitude_spectrum(&input));
        });
        out.push(make("fft_magnitude_spectrum", format!("n={}", n), t));
    }
    out
}

fn measure_float_simhash(
    rng: &mut SplitMix64,
    warmup: Duration,
    measure: Duration,
) -> Vec<Measurement> {
    let mut out = Vec::new();
    for &dim in &[128usize, 384, 768, 1536] {
        let vector: Vec<f32> = (0..dim).map(|_| rand_f32_01(rng) * 2.0 - 1.0).collect();
        let t = time_loop(warmup, measure, || {
            black_box(substrate_ml::float_simhash::project(&vector, DEFAULT_SEED));
        });
        out.push(make("float_simhash_project", format!("dim={}", dim), t));
    }
    out
}

fn measure_info_theory(
    rng: &mut SplitMix64,
    warmup: Duration,
    measure: Duration,
) -> Vec<Measurement> {
    let mut out = Vec::new();
    for &k in &[64usize, 256, 1024] {
        let make_dist = |rng: &mut SplitMix64| {
            let raw: Vec<f32> = (0..k).map(|_| rand_f32_01(rng)).collect();
            let s: f32 = raw.iter().sum();
            raw.iter().map(|x| x / s).collect::<Vec<_>>()
        };
        let p = make_dist(rng);
        let q = make_dist(rng);
        let t = time_loop(warmup, measure, || {
            black_box(InformationTheory::entropy(&p));
        });
        out.push(make("info_theory_entropy", format!("k={}", k), t));
        let t = time_loop(warmup, measure, || {
            black_box(InformationTheory::kl_divergence(&p, &q));
        });
        out.push(make("info_theory_kl", format!("k={}", k), t));
        let t = time_loop(warmup, measure, || {
            black_box(InformationTheory::cross_entropy(&p, &q));
        });
        out.push(make("info_theory_cross_entropy", format!("k={}", k), t));
        let side = (k as f64).sqrt() as usize;
        let mut joint: Vec<Vec<f32>> = (0..side)
            .map(|_| (0..side).map(|_| rand_f32_01(rng)).collect())
            .collect();
        let total: f32 = joint.iter().flatten().sum();
        for row in joint.iter_mut() {
            for v in row.iter_mut() {
                *v /= total;
            }
        }
        let t = time_loop(warmup, measure, || {
            black_box(InformationTheory::mutual_information(&joint));
        });
        out.push(make("info_theory_mi", format!("k={}", k), t));
    }
    out
}

fn measure_lattice_distance(
    _rng: &mut SplitMix64,
    warmup: Duration,
    measure: Duration,
) -> Vec<Measurement> {
    let mut out = Vec::new();
    let pairs: &[(&str, &str)] = &[
        ("003", "004"),
        ("003.13", "003.14"),
        ("003.13.5.2", "003.13.5.7"),
        ("003.13.5.2.1.4.7.9", "003.13.5.2.1.4.7.8"),
    ];
    for (a, b) in pairs {
        let t = time_loop(warmup, measure, || {
            black_box(UDCTreeDistance::distance(a, b));
        });
        out.push(make("lattice_distance_udc", format!("len={}", a.len()), t));
    }
    out
}

fn measure_llm_calibration(
    _rng: &mut SplitMix64,
    warmup: Duration,
    measure: Duration,
) -> Vec<Measurement> {
    let mut out = Vec::new();
    for &n_obs in &[100usize, 1_000, 10_000] {
        let mut curve = LLMCalibrationCurve::new();
        let mut local = SplitMix64::new(DEFAULT_SEED);
        for _ in 0..n_obs {
            let c = rand_f32_01(&mut local);
            let o = local.next() & 1 == 0;
            curve.observe(c, o);
        }
        let t = time_loop(warmup, measure, || {
            curve.observe(0.75, true);
        });
        out.push(make(
            "llm_calibration_observe",
            format!("warm_obs={}", n_obs),
            t,
        ));
        let t = time_loop(warmup, measure, || {
            black_box(curve.expected_calibration_error());
        });
        out.push(make(
            "llm_calibration_ece",
            format!("warm_obs={}", n_obs),
            t,
        ));
        let t = time_loop(warmup, measure, || {
            black_box(curve.brier_score());
        });
        out.push(make(
            "llm_calibration_brier",
            format!("warm_obs={}", n_obs),
            t,
        ));
    }
    out
}

fn measure_moment_summary(
    rng: &mut SplitMix64,
    warmup: Duration,
    measure: Duration,
) -> Vec<Measurement> {
    let mut out = Vec::new();
    for &n_rows in &[100usize, 1_000, 10_000, 100_000] {
        let rows: Vec<RowLite> = (0..n_rows)
            .map(|i| RowLite {
                fingerprint: Fingerprint256 {
                    block0: rng.next(),
                    block1: rng.next(),
                    block2: rng.next(),
                    block3: rng.next(),
                },
                capture_hlc: HLC {
                    physical_time: 1_700_000_000_000 + i as i64,
                    logical_count: 0,
                    node_id: 1,
                },
            })
            .collect();
        let window = TimeRange {
            start: HLC {
                physical_time: 1_700_000_000_000,
                logical_count: 0,
                node_id: 1,
            },
            end: HLC {
                physical_time: 1_700_000_000_000 + n_rows as i64,
                logical_count: 0,
                node_id: 1,
            },
        };
        let t = time_loop(warmup, measure, || {
            black_box(MomentSummary::summarize(
                &rows,
                window,
                MomentSummary::captured_during,
            ));
        });
        out.push(make("moment_summary", format!("rows={}", n_rows), t));
    }
    out
}

fn measure_nmf(_rng: &mut SplitMix64, warmup: Duration, measure: Duration) -> Vec<Measurement> {
    let mut out = Vec::new();
    for &(m, n) in &[(16usize, 16usize), (32, 32), (64, 64), (128, 128)] {
        for &rank in &[4usize, 8, 16] {
            if rank >= m.min(n) {
                continue;
            }
            let mut rng = SplitMix64::new(DEFAULT_SEED ^ ((m * 1000 + n * 10 + rank) as u64));
            let v: Vec<Vec<f32>> = (0..m)
                .map(|_| (0..n).map(|_| rand_f32_01(&mut rng)).collect())
                .collect();
            // estate="" + ts=0 = telemetry off; bench times pure compute.
            let t = time_loop(warmup, measure, || {
                black_box(NMFAlternatingLeastSquares::factorize(
                    &v,
                    rank,
                    25,
                    1e-4,
                    DEFAULT_SEED,
                    "",
                    0.0,
                ));
            });
            out.push(make(
                "nmf_factorize",
                format!("m={},n={},rank={}", m, n, rank),
                t,
            ));
        }
    }
    out
}

fn measure_random_walks(
    rng: &mut SplitMix64,
    warmup: Duration,
    measure: Duration,
) -> Vec<Measurement> {
    let mut out = Vec::new();
    for &n in &[100usize, 1_000, 10_000] {
        let adjacency = build_adjacency(rng, n);
        for &length in &[50usize, 200] {
            let t = time_loop(warmup, measure, || {
                black_box(RandomWalks::walk(&adjacency, 0, length, 0.15, DEFAULT_SEED));
            });
            out.push(make(
                "random_walks_walk",
                format!("n={},length={}", n, length),
                t,
            ));
        }
    }
    out
}

fn measure_temporal_compression(
    rng: &mut SplitMix64,
    warmup: Duration,
    measure: Duration,
) -> Vec<Measurement> {
    let mut out = Vec::new();
    for &n_rows in &[100usize, 1_000, 10_000] {
        let rows: Vec<Fingerprint256> = (0..n_rows)
            .map(|_| Fingerprint256 {
                block0: rng.next(),
                block1: rng.next(),
                block2: rng.next(),
                block3: rng.next(),
            })
            .collect();
        let start = HLC {
            physical_time: 1_700_000_000_000,
            logical_count: 0,
            node_id: 1,
        };
        let end = HLC {
            physical_time: 1_700_000_000_000 + 3600,
            logical_count: 0,
            node_id: 1,
        };
        let t = time_loop(warmup, measure, || {
            black_box(TemporalCompression::compress(
                &rows,
                start,
                end,
                WindowLevel::Hour,
            ));
        });
        out.push(make(
            "temporal_compression_compress",
            format!("rows={}", n_rows),
            t,
        ));
    }
    out
}

fn write_report(
    out: &Path,
    seed: u64,
    quick: bool,
    measurements: &[Measurement],
) -> std::io::Result<()> {
    let mut f = fs::File::create(out)?;
    let date = chrono_date();
    let hw = hardware::tag();
    let (warmup_ms, measure_ms) = if quick { (5, 20) } else { (50, 200) };
    writeln!(f, "{{")?;
    writeln!(f, "  \"schema_version\": \"ml-1\",")?;
    writeln!(f, "  \"language\": \"rust\",")?;
    writeln!(f, "  \"op\": \"substrate_ml\",")?;
    writeln!(f, "  \"date\": \"{}\",", date)?;
    writeln!(f, "  \"hardware_tag\": \"{}\",", hw)?;
    writeln!(f, "  \"seed\": \"0x{:016x}\",", seed)?;
    writeln!(f, "  \"timing\": {{")?;
    writeln!(f, "    \"warmup_ms\": {},", warmup_ms)?;
    writeln!(f, "    \"measure_ms\": {},", measure_ms)?;
    writeln!(f, "    \"quick_mode\": {}", quick)?;
    writeln!(f, "  }},")?;
    writeln!(f, "  \"measurements\": [")?;
    for (i, m) in measurements.iter().enumerate() {
        let comma = if i + 1 < measurements.len() { "," } else { "" };
        writeln!(f, "    {{ \"algorithm\": \"{}\", \"params\": \"{}\", \"iterations\": {}, \"ns_per_call_min\": {}, \"ns_per_call_mean\": {}, \"ns_per_call_stddev\": {} }}{}",
            m.algorithm, m.params, m.iterations, m.ns_per_call_min, m.ns_per_call_mean, m.ns_per_call_stddev, comma)?;
    }
    writeln!(f, "  ]")?;
    writeln!(f, "}}")?;
    Ok(())
}

fn chrono_date() -> String {
    chrono::Utc::now().format("%Y-%m-%d").to_string()
}

fn usage() -> ! {
    eprintln!("usage: ml-bench [--seed <0xhex>] [--algorithm <name>] [--out <path>] [--quick]");
    eprintln!();
    eprintln!("Algorithms: anomaly, bradley_terry, community_detection, composite_distance,");
    eprintln!("            eigenvalue_centrality, feature_extractors, fft, float_simhash,");
    eprintln!("            info_theory, lattice_distance, llm_calibration, moment_summary,");
    eprintln!("            nmf, random_walks, temporal_compression, all (default: all)");
    process::exit(2);
}

fn parse_seed(s: &str) -> u64 {
    let s = s.trim_start_matches("0x").trim_start_matches("0X");
    u64::from_str_radix(s, 16).unwrap_or_else(|_| {
        eprintln!("bad seed: {}", s);
        process::exit(2)
    })
}

fn main() {
    let mut args = env::args().skip(1).peekable();
    let mut seed = DEFAULT_SEED;
    let mut algorithm: Option<String> = None;
    let mut out_arg: Option<PathBuf> = None;
    let mut quick = false;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--seed" => seed = parse_seed(&args.next().unwrap_or_else(|| usage())),
            "--algorithm" => algorithm = Some(args.next().unwrap_or_else(|| usage())),
            "--out" => out_arg = Some(PathBuf::from(args.next().unwrap_or_else(|| usage()))),
            "--quick" => quick = true,
            "--help" | "-h" => usage(),
            _ => {
                eprintln!("unknown arg: {}", arg);
                usage();
            }
        }
    }
    let want = algorithm.unwrap_or_else(|| "all".into());
    let (warmup, measure) = if quick {
        (WARMUP_QUICK, MEASURE_QUICK)
    } else {
        (WARMUP_FULL, MEASURE_FULL)
    };
    println!(
        "ml-bench (Rust) seed=0x{:016x} algorithm={} {}",
        seed,
        want,
        if quick { "[quick]" } else { "" }
    );
    let mut all = Vec::new();
    let mut rng = SplitMix64::new(seed);
    let want_all = want == "all";
    macro_rules! run {
        ($name:expr, $fn:ident) => {
            if want_all || want == $name {
                let ms = $fn(&mut rng, warmup, measure);
                for m in &ms {
                    println!(
                        "  {:32} {:40} min={:>10}ns iters={}",
                        m.algorithm, m.params, m.ns_per_call_min, m.iterations
                    );
                }
                all.extend(ms);
            }
        };
    }
    run!("anomaly", measure_anomaly);
    run!("bradley_terry", measure_bradley_terry);
    run!("community_detection", measure_community_detection);
    run!("composite_distance", measure_composite_distance);
    run!("eigenvalue_centrality", measure_eigenvalue_centrality);
    run!("feature_extractors", measure_feature_extractors);
    run!("fft", measure_fft);
    run!("float_simhash", measure_float_simhash);
    run!("info_theory", measure_info_theory);
    run!("lattice_distance", measure_lattice_distance);
    run!("llm_calibration", measure_llm_calibration);
    run!("moment_summary", measure_moment_summary);
    run!("nmf", measure_nmf);
    run!("random_walks", measure_random_walks);
    run!("temporal_compression", measure_temporal_compression);
    let out = match out_arg {
        Some(p) => {
            if p.is_dir() || p.extension().is_none() {
                fs::create_dir_all(&p).ok();
                p.join("substrate_ml-rust.json")
            } else {
                p
            }
        }
        None => {
            let date = chrono_date();
            let hw = hardware::tag();
            let dir = PathBuf::from(format!("results/{}-{}", date, hw));
            fs::create_dir_all(&dir).ok();
            dir.join("substrate_ml-rust.json")
        }
    };
    write_report(&out, seed, quick, &all).expect("write report");
    println!();
    println!("  wrote {}", out.display());
}
