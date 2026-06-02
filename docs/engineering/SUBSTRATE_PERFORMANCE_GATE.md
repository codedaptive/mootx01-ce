# Substrate Performance Gate

**Version 1.0 — 2026-06-02**
**Host: Apple silicon (arm64, macOS), Apple M5 Max**

Published cross-language performance measurements for the substrate's
federation-critical core. This document is the gate behind every
performance claim in our public documentation: a claim that cannot
cite a row in this file does not ship. Where `EDITIONS.md` says the
pure-Python core runs "two to three orders of magnitude slower than
the compiled builds," the number comes from §3 below.

---

## 1. What is measured, and why this shape

The substrate's hot path is not linear algebra — it is the exact
integer core: hashing, fingerprinting, and SimHash block computation.
That is what federation peers verify byte-for-byte, and that is what
dominates filing and recall cost. So the cross-language probe measures
two primitives, chosen as the light and heavy poles of that core:

- **`fnv`** (light): FNV-1a over a fixed 43-character string — a
  lower bound on per-call cost in each language.
- **`simhash_block`** (heavy): one 256-bit SimHash block over 4 input
  words — the most expensive exact-core primitive, dominated by
  SplitMix64 draws (two per bit) and bit accumulation.

The same probe also emits a **libm canary** (§4), so one tool answers
both questions that matter across platforms: *how fast* and *still
byte-identical?*

**Protocol.** Per language, per primitive: 30 ms warmup, 120 ms
measurement window, 3 repeats; the metric is **minimum ns per
operation** — best-case steady state, deliberately free of GC pauses
and scheduler noise. Each language runs the same fixed inputs
(`fnv` over "the quick brown fox jumps over the lazy dog";
`simhash_block` at 256 bits / 4 words).

## 2. The tool

`port/harness/bench_crosslang.py` builds and runs each language's
federation-core port on the host it is invoked on and writes a
self-describing result file (`bench_crosslang_result.json`) stamped
with arch, OS, and toolchain versions. Two result files from two
architectures diff into a single table of perf deltas and
per-(language, primitive) bit-identity verdicts:

```
python3 bench_crosslang.py                    # run on this host
python3 bench_crosslang.py --compare A.json B.json   # cross-arch diff
```

## 3. Cross-language results — arm64, 2026-06

Minimum ns per operation; ratio is relative to Rust on the heavy
primitive.

| Language | `fnv` (ns) | `simhash_block` (ns) | simhash × vs Rust |
|---|---:|---:|---:|
| Rust | 16.2 | 17,836 | 1.00× |
| Julia | 55.2 | 18,634 | 1.04× |
| C | 16.2 | 20,161 | 1.13× |
| Go | 22.8 | 23,253 | 1.30× |
| Swift | 49.8 | 47,381 | 2.66× |
| C# | 34.7 | 69,975 | 3.92× |
| JavaScript | 1,048.8 | 1,647,200 | 92× |
| Python (pure) | 2,107.6 | 8,807,146 | 494× |

Reading the table:

- **The compiled builds cluster.** Rust, Julia (JIT-to-native), C, Go,
  and Swift land within ~2.7× of each other on the heavy path; C#
  (managed JIT) sits just behind at ~4×.
- **The interpreted tier is a different regime.** JavaScript is ~92×
  off Rust; pure Python is ~494×. This is the measured basis for the
  "two to three orders of magnitude" sentence in `EDITIONS.md` —
  186× against the slowest compiled build (Swift), 494× against Rust.
- `fnv` at ~16 ns (Rust/C) is near the floor of a call into a few
  dozen integer ops; languages above it are paying call/dispatch
  overhead, which is why the heavy primitive is the honest comparison.

## 4. The libm canary — perf and bit-identity in one probe

Integer and IEEE correctly-rounded math is bit-identical on every
platform; transcendentals (`exp`, `ln`, `sin`, `cos`) are **not**
correctly rounded and legitimately differ across libm
implementations. ADR-001 (transcendental isolation) therefore keeps
transcendental-dependent results same-platform-only, while the exact
core must be byte-identical everywhere.

The canary makes that visible: each language computes a fixed
accumulation (k = 1..200 of exp + ln + sin + cos) and emits the f64
**bit pattern**. On this host all eight languages produced the same
bits (`4652597234704906541`) — one platform, one libm, as expected.
The cross-architecture `--compare` run is where divergence appears,
and the canary also distinguishes languages that ship their own math
(Go, Julia) from those that call the platform libm (C, Rust, Swift) —
exactly the distinction ADR-001 exists to manage.

## 5. The Python build's native fast path

The 494× row is the **pure-Python** core. The standalone Python build
recovers it with `mootlib_core_rs`: a PyO3-over-Rust extension
(ADR-002, Tier-1b) that is byte-identical to `mootlib._core` and
recovers the ~490× gap on the federation-critical path. It builds
against the stable limited API (`abi3-py310`), so one wheel covers
CPython 3.10+. The pure-Python core remains in the package as the
reference implementation and the fallback when the wheel is absent.

The provenance point matters as much as the speed: the fast path is
our own Rust, conformance-gated like every other build — the Python
build's performance problem is solved with our code, not by widening
its third-party surface.

## 6. Own vs. borrow — the float-path tiering data

Separate question, separate tool: for the **non-exact float paths**
(FFT, entropy, z-score), should the substrate run its own Rust or
borrow numpy/scipy? `bench_own_vs_borrow.py` measures both per
primitive and size (50 ms warmup, 200 ms window, min ns per call;
Rust source: 2026-05-29 Apple M5 Max run, commit 88788de).

| Primitive | n | Rust (ns) | numpy (ns) | scipy (ns) | Verdict |
|---|---:|---:|---:|---:|---|
| fft_forward | 64 | 291 | 1,458 | 1,375 | OWN (Rust) |
| fft_forward | 256 | 1,666 | 2,083 | 1,834 | OWN (Rust) |
| fft_forward | 1,024 | 8,625 | 4,625 | 3,875 | BORROW (scipy) |
| fft_forward | 4,096 | 44,750 | 16,750 | 13,833 | BORROW (scipy) |
| fft_forward | 16,384 | 214,167 | 94,958 | 71,083 | BORROW (scipy) |
| info_theory_entropy | 64 | 41 | 1,000 | 36,958 | OWN (Rust) |
| info_theory_entropy | 256 | 291 | 1,416 | 37,500 | OWN (Rust) |
| info_theory_entropy | 1,024 | 1,333 | 2,791 | 40,250 | OWN (Rust) |
| anomaly_z_score | 100 | 0 | 4,000 | 34,750 | OWN (Rust) |
| anomaly_z_score | 1,000 | 791 | 4,791 | 36,916 | OWN (Rust) |
| anomaly_z_score | 10,000 | 9,125 | 11,666 | 49,917 | OWN (Rust) |
| anomaly_z_score | 100,000 | 93,000 | 78,500 | 178,000 | BORROW (numpy) |

Reading the table: our Rust wins everywhere except large-N FFT
(≥1,024 points, where FFTW-class libraries earn their keep) and
very-large-N z-score (100k elements, where BLAS vectorization
overtakes). At the small-to-mid sizes the substrate actually operates
at, OWN wins — often by an order of magnitude, and scipy's per-call
overhead (~35 µs floor) makes it a poor fit there regardless of
asymptotics. These verdicts drive tier decisions for float paths
only; the federation-critical exact core is **never** borrowed —
that is the provenance standard (`EDITIONS.md`, Language
implementations).

## 7. Caveats

- One host (Apple M5 Max, arm64, macOS). x86_64 numbers come from
  running the same tool there and diffing with `--compare`.
- Min-of-runs is best-case steady state, not throughput under load.
- Two-primitive microbenchmark of the exact core plus three float
  primitives — not an end-to-end filing/recall benchmark.
- Numbers are dated (2026-06). Re-run the probe before citing them in
  new documents; this file is updated when the numbers move, and
  claims elsewhere cite this file rather than carrying their own
  copies of the data.
