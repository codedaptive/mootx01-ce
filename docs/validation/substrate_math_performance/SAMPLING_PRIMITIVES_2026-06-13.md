---
title: Sampling Primitives — Normal, Gamma, Beta
status: accepted
created: 2026-06-13
last_updated: 2026-06-14
author: MOOTx01 maintainers
implements: NEURONKIT_SPEC §3.4 (SolverBandit sampling math, promoted to substrate)
sources:
  - packages/libs/SubstrateML/Sources/SubstrateML/Sampling.swift
  - packages/libs/SubstrateML/rust/src/sampling.rs
  - docs/validation/substrate_math_performance/test-harness/vectors/sampling.json
  - docs/validation/substrate_math_performance/test-harness/swift/Sources/Harness/Primitives/SamplingPrimitive.swift
  - docs/validation/substrate_math_performance/test-harness/rust/src/primitives/sampling.rs
---

# Sampling Primitives — Normal, Gamma, Beta

This documents the substrate's continuous-distribution sampling
primitives: the RNG-derived sampling math that underlies NeuronKit's
Thompson-Sampling dreaming-trigger bandit (`SolverBandit`). The math was
authored inside `SolverBandit` in both ports; it is promoted here as a
substrate atomic so one implementation serves every consumer (spec
invariant I-25: one implementation per substrate atomic, kits never
reimplement). It is implemented in SubstrateML in Swift and Rust and is
conformance-gated to exact f64 bit-identity across the two scalar ports.

The bandit *policy* (arms, `observe`, the argmax over
`DreamingTriggerMode`) stays in NeuronKit. Only the three distribution
samplers move to the substrate.

## The three primitives

| Primitive | Method | RNG draws | Inputs |
|---|---|---|---|
| `sampleNormal` | Box-Muller (cosine branch) | exactly 2 uniforms | none |
| `sampleGamma` | Marsaglia-Tsang (2000), shape≥1; Ahrens-Dieter reduction, shape<1 | variable (rejection) | `shape > 0` |
| `sampleBeta` | Gamma ratio `g1/(g1+g2)` | two Gamma draws | `alpha, beta > 0` |

**Normal(0,1) — Box-Muller.** `z = sqrt(-2 ln u1) · cos(2π u2)`, with
`u1, u2 ~ Uniform[0,1)`. Only the cosine branch is returned (the sine
branch is discarded) so RNG consumption is a fixed two uniforms per
call — there is no cached-sample state to keep the two ports' streams
aligned. `u1` is clamped up to the smallest positive normal so `ln` is
defined; the clamp is numerically invisible (P[u1 = 0] ≈ 2⁻⁵³).

**Gamma(shape, 1) — Marsaglia-Tsang.** For `shape ≥ 1`: `d = shape −
1/3`, `c = 1/sqrt(9d)`; propose `x ~ N(0,1)`, `v = (1 + c·x)³` requiring
`v > 0`; accept on the squeeze test `u < 1 − 0.0331·x⁴`, else the log
test `ln u < ½x² + d(1 − v + ln v)`. Expected iterations are O(1). For
`shape < 1` the Ahrens-Dieter reduction `Gamma(α) = Gamma(α+1)·U^(1/α)`
folds the problem into the `shape ≥ 1` branch. The shape<1 branch draws
its uniform **before** the recursive call; both ports draw in this order.

**Beta(α, β) — Gamma ratio.** `Beta(α,β) = Gamma(α,1)/(Gamma(α,1) +
Gamma(β,1))`. The α draw consumes its RNG words first, then β. Returns
0.5 for the degenerate zero-sum (unreachable for α,β ≥ 1).

All randomness routes through `SplitMix64` and `RandomWalks.uniform01`,
which the substrate already owns (cookbook §7.4). The samplers never
re-own the RNG. The 53-high-bits `uniform01` construction is identical
across ports, so the entire sampling stream is reproducible from a
single seed.

## Why substrate-owned and why conformance-gated

The bandit persists per-estate posterior state and must select the same
arm given the same posterior and seed on any replica — a federation
correctness requirement, not a convenience. That makes **cross-port
bit-identity of the sample stream a hard requirement**, not a
nice-to-have. The samplers use transcendentals (`ln`, `sqrt`, `cos`,
`pow`); the substrate already commits to platform-libm transcendentals
being bit-identical between Swift and Rust on the target hardware — FFT
(§8.10) gates its `cos`/`sin` twiddles to exact f64 `bitPattern`
equality by the same standing precedent. The conformance relation is
exact f64 equality (paper §11/§12); there is no tolerance band. The CRC
gate is the early-warning if libm parity ever ceases to hold.

## Conformance

Vector: `test-harness/vectors/sampling.json`, cookbook §8.17, seed
`0xCAFEBABEDEADBEEF`. 12 cases spanning every branch:

- Normal — the Box-Muller path, 64 samples.
- Gamma shape ∈ {0.25, 0.5, 0.9} — the Ahrens-Dieter reduction branch.
- Gamma shape = 1.0 — the boundary into Marsaglia-Tsang.
- Gamma shape ∈ {2.0, 7.5, 50.0} — the Marsaglia-Tsang rejection branch.
- Beta (1,1), (2,5), (0.5,0.5), (201,1) — uniform prior, skewed
  posterior, sub-unit shapes, and a converged-arm posterior.

The conformance check is exact f64 `bitPattern` equality of every
sample, gated by a CRC32 over the canonical f64 binary serialization of
all outputs.

| Cell | Result |
|---|---|
| Swift generate + self-validate | PASS |
| Rust validate (Swift JSON) | PASS — Swift scalar ≡ Rust scalar |
| Rust generate (independent) | byte parity — CRC `0xfc883023` |

**CRC32 = `0xfc883023`.**

Sampling is scalar-only; there is no SIMD or Metal path (the rejection
loop and per-sample transcendentals are not batch operations), so the
four-way kernel gate reduces to the two-way scalar cross-port gate here.

## Performance baseline

Apple Silicon (aarch64), release build (`opt-level = 3`), production
`substrate_ml::sampling`, 5M iterations per measurement, warmed:

| Sampler | ns/call |
|---|---|
| `sample_normal` | 14.9 |
| `sample_gamma(0.5)` | 19.8 |
| `sample_gamma(1.0)` | 14.8 |
| `sample_gamma(2.0)` | 14.4 |
| `sample_gamma(50)` | 13.9 |
| `sample_beta(1,1)` | 30.3 |
| `sample_beta(2,5)` | 29.1 |
| `sample_beta(201,1)` | 29.3 |

A Beta draw is ~2× a Gamma draw (two Gammas plus a divide), as expected.
The `shape < 1` Gamma is the most expensive single sampler (the extra
uniform + `pow` of the reduction). The Marsaglia-Tsang squeeze test
keeps `shape ≥ 1` at roughly Normal cost — most proposals are accepted
without the log.

**Bandit-cycle cost.** A `select` draws one Beta per arm (three arms):
measured **88 ns/cycle**. The dreaming cycle that consumes it is
measured in seconds, so sampling is not a hot loop and imposes no
selection-latency concern. The baseline is recorded so any future
regression (e.g. a libm change, an accidental re-seed inside the loop)
is visible against a known number, not discovered in production.

This was a one-shot measurement harness against the production crate; no
benchmark binary is committed (the substrate's perf convention records
the baseline in this document, as with `COUNT_VECTOR_FOLD` and the
`ACCELERATOR` records). Re-measure with the same loop shape if a
regression is suspected.

## Scope and remaining integration

This document and the substrate provider cover the substrate-side math,
tests, and conformance for the three samplers. NeuronKit's `SolverBandit`
still consumes its private copies of this math; wiring it to call
`SubstrateML.Sampling.{sampleNormal,sampleGamma,sampleBeta}` instead is a
follow-up change outside this document's scope.
