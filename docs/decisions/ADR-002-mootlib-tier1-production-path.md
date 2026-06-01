# ADR-002 — mootlib Tier-1 Production Path: Pure-Python Reference + PyO3-over-Rust Fast Path

- Status: Accepted — Tier-1b implemented and gate-proven 2026-05-30
- Date: 2026-05-30
- Deciders: Bob (Commander)
- Scope: mootlib (the Python substrate library), the conformance gate, packaging
- Evidence: CROSSLANG_BENCH_2026-05-30.md (8-language federation-core benchmark),
  HAIKU_FLOOR_PROBE_2026-05-30.md F8 (5-language integer byte-identity),
  OWN_VS_BORROW_BENCH_2026-05-30.md (Tier-2 own/borrow line). Companion to
  ADR-001 (transcendental-isolation invariant).

## Context

mootlib is the two-tier Python substrate library (ADR-001): Tier 1 is the exact,
federation-critical integer + correctly-rounded core whose output IS or
DETERMINES a fingerprint; Tier 2 is local-only / ULP-tolerant math free to borrow
NumPy/SciPy. Tier 1 was built first as a pure-Python implementation, gate-proven
byte-identical to the Python/Go/Rust/Swift/C/JS/Julia/C# reference ports.

The cross-language benchmark (CROSSLANG_BENCH_2026-05-30) measured identical
computation across all eight ports. Pure-Python is **445x slower than C** on
`simhash_block` (8.9 ms vs 20 us per block) and **~130x** slower than C on `fnv`.
The federation core runs on every fingerprint, capture, and sync. Pure-Python is
correct, zero-dependency, and ideal as the reference/spec and as a locked-down
fallback — but it is not a viable production hot path at that cost.

Rust is the fastest port (18.0 us simhash, edging out C via LLVM vectorization)
and is already the substrate's maintained second leg, with a crate targeting
Linux x86_64/aarch64. A PyO3-over-Rust binding would be ~490x faster than
pure-Python while remaining byte-identical to every other port.

The counterfactual benchmark (CROSSLANG_BENCH_2026-05-30, "what the
no-borrowed-library policy costs") sharpens *why* a native language is the only
lever: the federation core is PRNG-bound and sequential. ~99.4% of simhash time
is the sequential SplitMix64 plane build (32,768 RNG draws), which no array
library can vectorize; numpy is 6.6x SLOWER than pure-Python on fnv (a sequential
hash chain) and only helps the <1% projection slice. So the fix is a fast
*language*, not a fast *array library* — and the no-borrowed-library policy
forgoes ~zero speed (the one numpy-only bulk-projection win is recovered natively
by Rust Tier-1b, bit-exact).

## Decision

mootlib's Tier 1 ships as **two interchangeable backends behind one API**, both
gated bit-identical:

1. **`mootlib._core` (pure-Python) — reference + fallback.** Zero third-party
   dependencies. The readable spec, the certification-friendly artifact, and the
   backend used when no compiled wheel is available. This is the source of truth
   the gate and the drift-guard (`test_parity.py`) lock everything else to.

2. **`mootlib._core_rs` (PyO3-over-Rust) — Tier-1b production fast path.** A
   `maturin`-built native wheel binding the existing substrate Rust crate. When
   importable, the front door binds the Tier-1 names to it; otherwise it falls
   back to pure-Python. Selection is transparent to callers and to the federation
   guard.

3. **Both backends MUST pass the canonical gate** (all committed CRCs,
   byte-identical) in CI before either ships. The federation guard
   (ADR-001 enforcement) treats `mootlib._core` and `mootlib._core_rs` as owned;
   binding any Tier-1 primitive to a borrowed library still aborts import.

4. **Packaging:**
   - `pip install mootlib` — pure-Python core, zero deps (cert baseline).
   - `pip install mootlib[fast]` — adds NumPy/SciPy for the Tier-2 borrow tier.
   - `pip install mootlib[native]` — adds the PyO3-over-Rust Tier-1b wheel.
   `native` and `fast` are independent: the cert baseline can take the native
   speed-up without pulling NumPy/SciPy, and vice versa.

## Consequences

- mootlib gets native-class Tier-1 speed (~490x over pure-Python) without
  sacrificing the zero-dependency, fully-auditable baseline that the FedRAMP /
  full-source posture needs — the native path is an additive opt-in, not a
  dependency of the core.
- Bit-identity is preserved across backends and across the other seven language
  ports: which backend is bound changes speed, never the fingerprint. Two
  mootdbs federate regardless of whether each runs pure-Python or native, because
  both reproduce the same committed CRCs (same core fingerprint).
- New CI obligation: the Rust crate's PyO3 binding is gated against the same
  vectors as every other port; a divergence blocks the native wheel, never the
  pure-Python baseline.
- Build/release complexity rises (per-platform native wheels via maturin:
  macOS arm64, Linux x86_64/aarch64). Mitigated by the pure-Python fallback —
  a platform without a wheel still works, slower.
- Open follow-ups (separate ADRs): (a) the federation-capability guard +
  DB-header stamp are implemented in mootlib but not yet formally recorded; (b)
  Tier-2 own/borrow dispatch + per-machine calibration policy
  (OWN_VS_BORROW_BENCH_2026-05-30) remains to be ratified.

## Implementation result (2026-05-30)

Tier-1b built: `port/mootlib/native/` (PyO3 0.24, abi3-py310, maturin). Compute
copied verbatim from the reference Rust port. Outcome:
- **Byte-identical**: passes all 5 committed CRCs (fingerprint 0x8e234944,
  bitwise 0x950c2305, fnv 0xbfd25f27, hlc 0x20e00393, simhash 0x128ed1dd).
- **477x faster** on simhash (9.0 ms -> 18.9 us) and 22.9x on fnv vs pure-Python
  — confirming the ~490x projection. 18.9 us through the FFI matches native Rust
  (18.0 us), so binding overhead is negligible on real work.
- mootlib auto-selects the Rust backend when its wheel is installed
  (`active_backend()`), the federation guard treats `mootlib_core_rs` as owned,
  and `core_fingerprint` is unchanged (0x1feedbfb) — the federation contract is
  backend-independent. Both backends agree bit-for-bit.

## Alternatives considered

- **Pure-Python only.** Rejected: 445x on the hot path is untenable for
  production fingerprinting/sync.
- **Native only (drop pure-Python).** Rejected: loses the zero-dependency
  certification baseline and the readable reference the gate locks to, and breaks
  on any platform lacking a wheel.
- **Cython / C-extension hand-port.** Rejected: would be a third implementation
  to keep byte-identical; the Rust crate already exists, is maintained, is the
  fastest measured port, and is already conformance-gated.
