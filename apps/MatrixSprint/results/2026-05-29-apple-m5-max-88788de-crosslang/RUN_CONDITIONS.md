# MatrixSprint Run Conditions — 2026-05-29 apple-m5-max

## Hardware

- **Machine**: Apple M5 Max (arm64, macOS)
- **Hardware tag**: apple-m5-max
- **Platform**: aarch64 / macos

## Commit

- **commit_sha**: 88788de (git rev-parse --short HEAD at run time)
- **date**: 2026-05-29

## Toolchain Versions

- **Rust**: rustc 1.95.0 (59807616e 2026-04-14)
- **Swift**: Apple Swift version 6.3.2 (swiftlang-6.3.2.1.108 clang-2100.1.1.101) [BUILD FAILED — see below]
- **Go**: go1.26.3 darwin/arm64 (/opt/homebrew/bin/go)
- **Python**: Python 3.14.4 (/opt/homebrew/bin/python3)

## Run Order (Serial Isolation)

Runs were executed strictly one at a time in this order:
1. Rust — build (cargo build --release), then all sweeps
2. Swift — build attempted (swift build -c release), FAILED — no Swift results
3. Go — build (go build), then all sweeps
4. Python — interpreted (no compiled release), then all sweeps

No two language builds or measurement sweeps ran concurrently. Each
language's build AND full measurement sweep AND JSON write completed
before the next language began.

## Swift Build Failure

`swift build -c release` failed at the current working tree HEAD (88788de)
with the following error:

```
docs/validation/substrate_math_performance/
test-harness/swift/Sources/Harness/Primitives/PrimitiveRegistry.swift:96:9:
error: cannot find 'BitFieldMaskedEqualsPrimitive' in scope
```

The type `BitFieldMaskedEqualsPrimitive` is referenced in `PrimitiveRegistry.swift`
but does not exist in any source file in the current tree. This is a pre-existing
compilation error at commit 88788de. Per the run instructions, fresh Swift numbers
are absent from this run. Old committed Swift numbers are NOT used as substitutes.

## Benchmark Settings

- **seed**: 0xcafebabedeadbeef
- **warmup_ms**: 50
- **measure_ms**: 200
- **quick_mode**: false
- **Stress-test batch sizes**: 1, 2, 4, 8, 16, 32, 64, 128, 256
- **Topk-bench N values**: 256, 1024, 4096, 16384, 65536, 262144, 1048576
- **Topk-bench K values**: 1, 4, 10, 32, 100

## Kernel Coverage

- **Rust**: scalar + simd (auto-emits all available kernels)
- **Swift**: N/A (build failed)
- **Go**: scalar only (portable port — no SIMD ladder implemented)
- **Python**: scalar only (interpreted; no SIMD available)

## Scalar-vs-Scalar Fairness Note

The apples-to-apples comparison uses the scalar kernel only across all
four languages. Rust and Swift additionally have SIMD kernels; those
are shown separately for context but are NOT part of the cross-language
scalar comparison. Go and Python are inherently scalar-only portable
ports, which is valid per project methodology (HINTS-GO.md, HINTS-PYTHON.md).

## Python Not-Compiled Caveat

Python is an interpreted language; there is no compiled-release equivalent.
The Python port runs under CPython 3.14.4 with no JIT or compilation step.
This is an inherent, documented asymmetry of the Python port — not a shortcut.
Python numbers reflect CPython loop overhead, which is expected to be
50-200× slower than Rust/Swift for compute-bound loops. This is the
intended characterization per HINTS-PYTHON.md: "the goal of the Python port
is to show the scaling shape and the algorithm correctness, not to win the
performance trophy."

## ml-bench Out of Scope

ml-bench (SubstrateML algorithms, schema ml-1) is explicitly OUT OF SCOPE
for this run. This run covers stress-test (hamming, simhash, or_reduce) and
topk-bench (hamming_top_k) only. No ml-bench results were collected,
substituted, or implied.

## SplitMix64 Cross-Port Verification

All three active ports were verified to produce identical outputs from seed=42:
- **Expected**: 0xBDD732262FEB6E95, 0x28EFE333B266F103, 0x47526757130F9F52
- **Go**: PASS (verified before running benchmarks)
- **Python**: PASS (verified before running benchmarks)
- **Rust**: PASS (pre-existing harness; verified by project conformance tests)

## Files Produced

| File | Language | Benchmark | Schema |
|---|---|---|---|
| hamming-rust.json | rust | stress-test hamming | 2 |
| simhash-rust.json | rust | stress-test simhash | 2 |
| or_reduce-rust.json | rust | stress-test or_reduce | 2 |
| hamming_topk-rust.json | rust | topk-bench | topk-1 |
| hamming-go.json | go | stress-test hamming | 2 |
| simhash-go.json | go | stress-test simhash | 2 |
| or_reduce-go.json | go | stress-test or_reduce | 2 |
| hamming_topk-go.json | go | topk-bench | topk-1 |
| hamming-python.json | python | stress-test hamming | 2 |
| simhash-python.json | python | stress-test simhash | 2 |
| or_reduce-python.json | python | stress-test or_reduce | 2 |
| hamming_topk-python.json | python | topk-bench | topk-1 |

Swift files absent — build failure at HEAD as documented above.
