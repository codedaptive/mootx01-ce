// src/primitives/sampling.rs
//
// Sampling primitives (cookbook §8.17). Mirror of Swift's
// SamplingPrimitive.swift.
//
// Wired to the production reference at
// packages/libs/SubstrateML/rust/src/sampling.rs via the substrate-ml
// crate dependency (the same wire-up fft / association_rule_mining use).
//
// Swift is the generator of record for sampling.json; this Rust side is
// the cross-port validator — it re-runs the production provider on the
// same per-case seeds and asserts every f64 sample is bit-identical to
// the Swift-generated vector, then re-checks the CRC32. That equality
// IS the conformance gate. `generate` is also implemented (parity) so
// the Rust harness can regenerate the vector if ever needed.
//
// The provider's RNG type is substrate_ml::random_walks::SplitMix64 —
// NOT the harness's own crate::harness::splitmix64::SplitMix64. They are
// bit-identical mixers, but the conformance gate must drive the
// production RNG the shipping code uses. Per-case seeds are derived with
// the substrate RNG so both ports agree.
//
// See SamplingPrimitive.swift for the full input/output schema and the
// note on Gamma's variable RNG consumption.

use std::collections::BTreeMap;

use crate::harness::{
    crc32::CRC32,
    encoder::CanonicalBinaryEncoder,
    hex::{decode_hex, f64_hex, u64_hex},
    vector_file::{
        Generator, JsonObject, JsonValue, VectorCase, VectorFile, HARNESS_VERSION,
    },
};
use crate::primitives::registry::{CaseResult, PrimitiveDescriptor, ValidationResult};

use substrate_ml::random_walks::SplitMix64;
use substrate_ml::sampling;

// The distribution + parameter grid, in a fixed order so case indices
// are stable across regenerations and identical to the Swift grid.
struct CaseSpec {
    distribution: &'static str,
    alpha: Option<f64>,
    beta: Option<f64>,
    count: usize,
}

fn grid() -> Vec<CaseSpec> {
    vec![
        // Normal(0,1): Box-Muller, fixed two-uniform consumption.
        CaseSpec { distribution: "normal", alpha: None,        beta: None,      count: 64 },
        // Gamma shape < 1 → Ahrens-Dieter reduction branch.
        CaseSpec { distribution: "gamma",  alpha: Some(0.25),  beta: None,      count: 32 },
        CaseSpec { distribution: "gamma",  alpha: Some(0.5),   beta: None,      count: 32 },
        CaseSpec { distribution: "gamma",  alpha: Some(0.9),   beta: None,      count: 32 },
        // Gamma shape == 1 → boundary into the Marsaglia-Tsang branch.
        CaseSpec { distribution: "gamma",  alpha: Some(1.0),   beta: None,      count: 32 },
        // Gamma shape > 1 → Marsaglia-Tsang squeeze/log rejection.
        CaseSpec { distribution: "gamma",  alpha: Some(2.0),   beta: None,      count: 32 },
        CaseSpec { distribution: "gamma",  alpha: Some(7.5),   beta: None,      count: 32 },
        CaseSpec { distribution: "gamma",  alpha: Some(50.0),  beta: None,      count: 32 },
        // Beta: the bandit's actual draw. Uniform prior + skewed posteriors.
        CaseSpec { distribution: "beta",   alpha: Some(1.0),   beta: Some(1.0), count: 32 },
        CaseSpec { distribution: "beta",   alpha: Some(2.0),   beta: Some(5.0), count: 32 },
        CaseSpec { distribution: "beta",   alpha: Some(0.5),   beta: Some(0.5), count: 32 },
        CaseSpec { distribution: "beta",   alpha: Some(201.0), beta: Some(1.0), count: 32 },
    ]
}

// Per-case seed derivation from the generator seed. Mirrors the Swift
// `caseSeed` exactly (SplitMix64 mix of base + index * golden ratio).
fn case_seed(base: u64, index: usize) -> u64 {
    let mut rng = SplitMix64::new(base.wrapping_add((index as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)));
    rng.next()
}

// Draw `spec.count` samples from one substrate SplitMix64 stream seeded
// at `seed`, calling the production substrate_ml::sampling provider. The
// RNG is threaded across draws (never re-seeded) so the whole sequence
// shares one stream — exactly how the bandit draws one Beta per arm.
fn draw(spec: &CaseSpec, seed: u64) -> Vec<f64> {
    let mut rng = SplitMix64::new(seed);
    let mut out = Vec::with_capacity(spec.count);
    match spec.distribution {
        "normal" => {
            for _ in 0..spec.count {
                out.push(sampling::sample_normal(&mut rng));
            }
        }
        "gamma" => {
            let shape = spec.alpha.unwrap_or(1.0);
            for _ in 0..spec.count {
                out.push(sampling::sample_gamma(shape, &mut rng));
            }
        }
        "beta" => {
            let a = spec.alpha.unwrap_or(1.0);
            let b = spec.beta.unwrap_or(1.0);
            for _ in 0..spec.count {
                out.push(sampling::sample_beta(a, b, &mut rng));
            }
        }
        // Unknown distribution: empty sequence. The length-mismatch check
        // in validate_case turns this into a clear failure.
        _ => {}
    }
    out
}

fn case_description(spec: &CaseSpec) -> String {
    match spec.distribution {
        "normal" => format!("normal, {} samples", spec.count),
        "gamma" => format!("gamma shape={}, {} samples", spec.alpha.unwrap_or(1.0), spec.count),
        "beta" => format!(
            "beta a={} b={}, {} samples",
            spec.alpha.unwrap_or(1.0),
            spec.beta.unwrap_or(1.0),
            spec.count
        ),
        other => other.to_string(),
    }
}

pub struct SamplingPrimitive;

impl SamplingPrimitive {
    pub fn descriptor() -> PrimitiveDescriptor {
        PrimitiveDescriptor {
            name: "sampling",
            cookbook_section: "§8.17",
            reference_file: "SubstrateML/rust/src/sampling.rs",
            generate: Self::generate,
            validate: Self::validate,
        }
    }

    pub fn generate(seed: u64) -> Result<VectorFile, Box<dyn std::error::Error>> {
        let g = grid();
        let mut cases = Vec::with_capacity(g.len());

        for (i, spec) in g.iter().enumerate() {
            let cseed = case_seed(seed, i);
            let samples = draw(spec, cseed);

            let mut inputs: JsonObject = BTreeMap::new();
            inputs.insert("distribution".into(), JsonValue::String(spec.distribution.to_string()));
            inputs.insert("seed".into(), JsonValue::String(u64_hex(cseed)));
            inputs.insert("count".into(), JsonValue::String(u64_hex(spec.count as u64)));
            if let Some(a) = spec.alpha {
                inputs.insert("alpha".into(), JsonValue::String(f64_hex(a)));
            }
            if let Some(b) = spec.beta {
                inputs.insert("beta".into(), JsonValue::String(f64_hex(b)));
            }

            let samples_arr: Vec<JsonValue> =
                samples.iter().map(|v| JsonValue::String(f64_hex(*v))).collect();
            let mut output: JsonObject = BTreeMap::new();
            output.insert("samples".into(), JsonValue::Array(samples_arr));

            cases.push(VectorCase {
                id: format!("case_{:03}", i),
                description: case_description(spec),
                inputs,
                expected_output: output,
            });
        }

        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &cases {
            encode_output(&c.expected_output, &mut encoder);
        }
        let crc = CRC32::compute(encoder.as_slice());

        Ok(VectorFile {
            primitive: "sampling".to_string(),
            cookbook_section: "§8.17".to_string(),
            generator: Generator {
                language: "rust".to_string(),
                harness_version: HARNESS_VERSION.to_string(),
                reference_file: "SubstrateML/rust/src/sampling.rs".to_string(),
            },
            seed,
            generated_at: iso_timestamp(),
            output_crc32: crc,
            cases,
        })
    }

    pub fn validate(file: &VectorFile) -> Result<ValidationResult, Box<dyn std::error::Error>> {
        let mut case_results = Vec::with_capacity(file.cases.len());
        let mut encoder = CanonicalBinaryEncoder::new();
        for c in &file.cases {
            case_results.push(validate_case(c, &mut encoder));
        }
        let crc_actual = CRC32::compute(encoder.as_slice());
        let all_passed = case_results.iter().all(|r| r.passed);
        Ok(ValidationResult {
            passed: all_passed && crc_actual == file.output_crc32,
            case_results,
            crc_expected: file.output_crc32,
            crc_actual,
        })
    }
}

fn validate_case(c: &VectorCase, encoder: &mut CanonicalBinaryEncoder) -> CaseResult {
    let distribution = match c.inputs.get("distribution") {
        Some(JsonValue::String(s)) => s.clone(),
        _ => return fail_case(c, "missing distribution"),
    };
    let cseed = match c.inputs.get("seed") {
        Some(JsonValue::String(s)) => match parse_u64_hex(s) {
            Some(v) => v,
            None => return fail_case(c, "malformed seed"),
        },
        _ => return fail_case(c, "missing seed"),
    };
    let count = match c.inputs.get("count") {
        Some(JsonValue::String(s)) => match parse_u64_hex(s) {
            Some(v) => v as usize,
            None => return fail_case(c, "malformed count"),
        },
        _ => return fail_case(c, "missing count"),
    };
    let alpha = parse_opt_f64(c.inputs.get("alpha"));
    let beta = parse_opt_f64(c.inputs.get("beta"));

    let spec = CaseSpec { distribution: leak_str(&distribution), alpha, beta, count };
    let actual = draw(&spec, cseed);

    let exp_arr = match c.expected_output.get("samples") {
        Some(JsonValue::Array(a)) => a,
        _ => return fail_case(c, "missing expected samples"),
    };
    let mut expected: Vec<f64> = Vec::with_capacity(exp_arr.len());
    for v in exp_arr {
        match v {
            JsonValue::String(s) => match parse_f64_hex(s) {
                Some(f) => expected.push(f),
                None => return fail_case(c, "malformed expected sample"),
            },
            _ => return fail_case(c, "non-string expected sample"),
        }
    }

    if actual.len() != expected.len() {
        return fail_case(
            c,
            &format!("sample length mismatch: {} vs {}", actual.len(), expected.len()),
        );
    }

    for f in &actual {
        encoder.write_f64(*f);
    }

    for k in 0..actual.len() {
        if actual[k].to_bits() != expected[k].to_bits() {
            return CaseResult {
                id: c.id.clone(),
                passed: false,
                diagnostic: Some(format!(
                    "samples[{}] mismatch: expected {}, got {}",
                    k,
                    f64_hex(expected[k]),
                    f64_hex(actual[k])
                )),
            };
        }
    }

    CaseResult { id: c.id.clone(), passed: true, diagnostic: None }
}

fn encode_output(output: &JsonObject, encoder: &mut CanonicalBinaryEncoder) {
    let arr = match output.get("samples") {
        Some(JsonValue::Array(a)) => a,
        _ => panic!("expected_output missing samples"),
    };
    for v in arr {
        if let JsonValue::String(s) = v {
            let f = parse_f64_hex(s).expect("malformed sample hex");
            encoder.write_f64(f);
        } else {
            panic!("non-string sample element");
        }
    }
}

fn fail_case(c: &VectorCase, msg: &str) -> CaseResult {
    CaseResult { id: c.id.clone(), passed: false, diagnostic: Some(msg.into()) }
}

fn parse_opt_f64(v: Option<&JsonValue>) -> Option<f64> {
    match v {
        Some(JsonValue::String(s)) => parse_f64_hex(s),
        _ => None,
    }
}

fn parse_f64_hex(s: &str) -> Option<f64> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 8 {
        return None;
    }
    let mut bits: u64 = 0;
    for (i, b) in bytes.iter().enumerate() {
        bits |= (*b as u64) << (i * 8);
    }
    Some(f64::from_bits(bits))
}

fn parse_u64_hex(s: &str) -> Option<u64> {
    let bytes = decode_hex(s).ok()?;
    if bytes.len() != 8 {
        return None;
    }
    let mut bits: u64 = 0;
    for (i, b) in bytes.iter().enumerate() {
        bits |= (*b as u64) << (i * 8);
    }
    Some(bits)
}

// CaseSpec.distribution is &'static str to match the grid; the validate
// path reads the distribution from JSON (an owned String). Leaking a tiny
// per-case string keeps the one CaseSpec shape for both generate and
// validate without a lifetime parameter. The leak is bounded by case
// count (12) per run — negligible and intentional for a CLI validator.
fn leak_str(s: &str) -> &'static str {
    Box::leak(s.to_string().into_boxed_str())
}

fn iso_timestamp() -> String {
    let now = chrono::Utc::now();
    now.format("%Y-%m-%dT%H:%M:%SZ").to_string()
}
