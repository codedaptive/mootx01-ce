---
status: decided
question: How should the bit-identity conformance gate treat transcendental functions across platforms, given that libm implementations diverge?
authors: MOOTx01 maintainers
date: 2026-05-30
relates_to:
  - docs/reference/GENIUSLOCUS_ARCHITECTURE_SPEC.md
supersedes: none
context:
  - Integer/SimHash core reproduces byte-identical across all language ports.
  - BLAS/array-library float kernels diverge by up to ~1 ULP across platforms.
  - The identity/federation path is transcendental-free by construction.
---

# ADR-001 — Transcendental-Isolation Invariant and Cross-Platform Gate Policy

**Scope:** SubstrateML, SubstrateKernel, the conformance harness, the porting standard.

## Context

The substrate's conformance gate requires **bit-identity**: every committed
vector is a CRC32 over the exact little-endian bytes of the result, and the gate
is uniform across primitives — integer and floating-point alike.

Bit-identity on floating point is achievable **only for the operations IEEE-754
*mandates* to be correctly-rounded**: `+`, `−`, `*`, `/`, and `sqrt`. These
produce the same bits on every conformant FPU, on any hardware, in any language
(proven for the integer/SimHash core at five-language byte-identity, and
for `eigenvalue_centrality`/`nmf`, which use only `sqrt`).

**Transcendental functions are different.** `exp`, `log`, `log2`, `ln`, `sin`,
`cos`, `tan`, `pow`, `tanh` are **not** correctly-rounded-mandated. Conformant
`libm` implementations disagree by up to ~1 ULP. Today both substrate legs
(Swift `Foundation.cos`, Rust `f64::cos`) resolve to the **same Apple system
`libm`** on Apple Silicon, so they agree and the committed (Apple-generated)
vectors pass. But the Rust port targets **PC/Linux x86_64 and aarch64**, where
`f64::exp`/`sin`/`log` call **glibc/musl `libm`** — a different implementation.
A 1-ULP transcendental difference flips the bit-exact CRC.

Seven SubstrateML primitives use transcendentals: `fft` (`sin`/`cos`),
`matrix_decay`, `bradley_terry`, `lattice_distance` (`exp`), `info_theory`
(`log2`), `dp_or_reduce` (`ln`), `feature_extractors` (`pow`). Swift/Rust parity
at the function level is confirmed; the issue is cross-*platform*, not
cross-*language*.

### Does it matter for how the substrate uses them?

Largely no, and by design:

- **The identity path is transcendental-free.** Estate/drawer fingerprints —
  the values that must be bit-identical across replicas and that drive sync,
  dedup, and the KG — are SimHash over **integer bitmaps**. `FloatSimHash` and
  `TierContributionFingerprint` use **zero** transcendentals (grep-verified).
- **Five of the seven are not yet consumed** by any kit (`fft`/rhythm,
  `info_theory`, `lattice_distance`, `dp_or_reduce`).
- **The two with footprint feed soft consumers.** `bradley_terry` → preference
  ranking; `matrix_decay` → matrix-tier weights decayed locally by the dreaming
  daemon for recall scoring. A measured 2-ULP `exp` divergence flips the
  bit-exact CRC but leaves the ranking identical — the product never observes it.

This matches the substrate's existing **federation-critical vs local-only** split:
the federation-critical list is already transcendental-free; the transcendental
primitives are local-only.

## Decision

1. **Transcendental-Isolation Invariant (load-bearing).** No transcendental
   result may flow into a fingerprint, content-ID, CRDT/sync-compared value, or
   any value compared for equality across instances. Identity and
   federation-critical computation stays on integer + correctly-rounded math.
   This invariant is what makes cross-platform transcendental divergence
   harmless; it must be preserved deliberately, not by accident.

2. **Cross-platform gate policy.** The bit-exact CRC gate is correct and
   retained for: all integer primitives, and the correctly-rounded float
   primitives (`+ − * / sqrt` only — e.g. `eigenvalue_centrality`, `nmf`,
   `float_simhash`, `tier_contribution`). For the transcendental seven, bit-exact
   CRC is **same-platform only** (genuine Swift↔Rust agreement on one host). A
   cross-platform run of those seven is gated with **ULP-tolerance**, not
   bit-exact CRC; a bit-exact pass there is informational, not required.

3. **Owning transcendentals is deferred, not required.** Cross-platform
   bit-identity for the transcendental seven would require the substrate to ship
   its own fixed `libm` (correctly-rounded or pinned-polynomial). This is **not**
   undertaken now, because the invariant (1) keeps divergence off the identity
   path. It becomes required only if a future design needs a transcendental
   result on the federation/identity path — which (1) forbids by default.

## Consequences

- The port-doc standard's "bit-identity on floating point" rule
  is corrected to distinguish correctly-rounded ops (portable bit-identity) from
  transcendentals (same-platform bit-identity only), and names the invariant.
- The portability contract for ports (mootlib, Go, Python) shrinks: only the
  integer + correctly-rounded primitives must reproduce the Apple-generated
  vectors cross-platform. A native-`libm` port will diverge on the transcendental
  seven and that is acceptable per policy (2).
- A latent trap is removed: the `FFT.swift` header claims production `vDSP_fft`
  "MUST produce bit-identical output." A measured BLAS/array-library float
  divergence shows an Accelerate-class kernel will not. Because FFT is local-only
  and isolated from identity, this is a gate-policy
  issue (over-strict), not a correctness bug; the comment should be corrected to
  "ULP-equivalent" when that primitive is wired in.
- New review check: any change that routes a transcendental-derived value toward
  a fingerprint/sync/equality path is a CRITICAL violation of invariant (1).
