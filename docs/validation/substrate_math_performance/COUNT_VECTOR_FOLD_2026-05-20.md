---
title: Count-Vector and the Count-Fold Primitive
status: accepted
created: 2026-05-20
last_updated: 2026-06-14
authors: MOOTx01 maintainers
sources:
  - packages/libs/SubstrateTypes/Sources/SubstrateTypes/CountVector256.swift
  - packages/libs/SubstrateKernel/Sources/SubstrateKernel/PortableKernel.swift
  - packages/libs/SubstrateKernel/Sources/SubstrateKernel/PortableKernel-SIMD.swift
  - packages/libs/SubstrateTypes/rust/src/count_vector.rs
  - packages/libs/SubstrateKernel/rust/src/kernel.rs
  - packages/libs/SubstrateKernel/rust/src/kernel_simd.rs
---

# Count-Vector and the Count-Fold Primitive

This documents the first primitive of the bundle-algebra and erasure
build, the count-vector and its fold. The `CountVector256` type lives in
the SubstrateTypes package and the `countFold256` kernel op in
SubstrateKernel, in both the Swift and Rust ports, and is
conformance-gated across the kernel backends. It is the foundation the
two-bundle materialization and the erasure verbs build on.

## What it is

A count-vector is the stored object for a bundle. For a set of member
fingerprints in the 256-bit space, it holds, for each bit position j,
the number of members with that bit set (c_j), and the member count n.

The normalized profile p_j = c_j / n is the probability a random member
lights bit j, equivalently the parameter of that bit's Bernoulli. The
majority-vote engram that Hamming recall consumes is a read-time view,
bit j set if and only if 2 c_j > n.

## Why the count-vector and not the engram

The count-vector composes losslessly up a node tree. Counts add, n
adds, and a parent's count-vector equals the direct accumulation of
every leaf beneath it, exactly, in any fold order. Majority-vote does
not compose: the majority of the children's majorities disagrees with
the true majority of the pooled members, and the error grows with
depth. So the stored object must be the count-vector, and the engram is
derived from it on read. The honest statistic yields the engram for
free; the engram cannot yield the statistic.

Two consequences follow. Count-vectors add commutatively, so a bundle
is a conflict-free replicated data type by construction, which is what
the federation layer wants to replicate. And the existing OR-reduce is
revealed as the degenerate case of this same fold, where each per-bit
accumulator saturates at one rather than counting; OR-reduce keeps any
bit set by even a single minority member, which is why it cannot be the
stored summary.

## The API

`CountVector256` (Swift) and `count_vector::CountVector256` (Rust) hold
256 counts and a member count.

- The empty vector (`zero`) is the identity of the fold and merge.
- `accumulate(fingerprint)` folds one member in: raise each set bit's
  count by one, raise n by one. This is the leaf step.
- `merge(other)`, and `+`, add counts elementwise and add n. This is
  the tree-fold step, commutative and associative.
- `majorityVote()` returns the derived engram under the strict
  threshold 2 c_j > n.
- `profile()` returns the 256 probabilities c_j / n, all zero when the
  vector is empty.
- `fold(fingerprints)` is the reference accumulation over a slice, the
  single canonical algorithm the kernel layer dispatches to.

Counts are 32-bit, which bounds one vector to about 4.3 billion members
before a count could saturate, far above any realistic node subtree.

## The tie convention

The majority-vote threshold is strict: a bit is set only when more than
half of the members carry it, 2 c_j > n. An exact tie at half does not
set the bit. This matches the proof's indicator 1[c_j / n > 0.5]. The
convention is part of the contract because it changes the derived
engram and must be identical across every kernel backend and across the
Swift and Rust ports. The conformance and parity tests pin it with a
four-member case where one bit is at exact tie and asserts that bit
clears.

## Kernel surface

`SubstrateKernel` gains `countFold256` (Swift) and `count_fold_256`
(Rust), with a batch variant alongside the existing `orReduceBatch`.
The operation is provided as a trait default that delegates to the
single reference fold, so every backend conforms and is correct
immediately, exactly as the batched Hamming and OR-reduce variants are
handled. A backend with a vectorized vertical counter overrides the
method and is gated against the reference output.

The MomentSummary saturating-OR fold is the proto-Bundle-A. It is
superseded by the count-fold, which counts rather than saturates. The
OR-reduce stays for callers that genuinely want union semantics.

## Conformance and parity

A cross-backend conformance test runs the fold across every kernel kind
(scalar, simd, neon, and the rest) and asserts a count-vector identical
to the scalar reference. Backends that do not yet override the fold
inherit the reference and pass trivially; the gate becomes load-bearing
the moment a vectorized override lands, which is the safety net that
makes the per-backend specialization work safe to attempt.

Cross-language parity holds by construction rather than by a stored
digest. The fold is plain integer accumulation with identical semantics
in both languages, and the property tests drive both ports with the
same xorshift generator and the same seeds, so identical fingerprint
sequences produce identical count-vectors. The strict-tie case is
asserted with the same literal membership in both ports.

Tests: the count-vector suite lives in SubstrateTypes (the type and
the cross-backend gate) with the SIMD vertical-counter tests gated in
SubstrateKernel, in both ports. The SIMD count-fold tests run only
under the Rust `simd-nightly` feature, which exercises the SIMD
override in the conformance test; on stable Rust the backend inherits
the scalar reference.

## The SIMD vertical counter

The scalar reference prioritizes obvious correctness, since it is the
gold standard every backend is measured against. It iterates set bits
per word rather than running a bit-plane vertical counter. This is a
deliberate refinement of the scope, which had named a Harley-Seal
accumulator for the scalar path; clarity wins for the reference, and
the vertical counter belongs in the vectorized backends.

The SIMD backend now carries that vertical counter, in both the Swift
SimdKernel and the Rust SimdKernel (the latter under the simd-nightly
feature). It is the bit-sliced carry-save form: `planes[b]` holds bit b
of every column's running count in four-lane vectors, and each
fingerprint is a ripple-carry add, sum bit `plane XOR carry` and carry
out `plane AND carry`. The carry dies after about two planes on average,
the amortized cost of a binary-counter increment, so the per-fingerprint
work is a couple of vector XOR/AND pairs rather than the reference's
set-bit walk. For the dense, roughly balanced SimHash fingerprints this
is the case where the vectorized form pays. The per-column counts are
read out of the bit-sliced planes once at the end.

This is the production path on Apple silicon, where the dispatcher
returns SimdKernel. It is gated against the scalar reference by the
kernel conformance test and by a multi-size test that crosses the plane
boundaries (1, 2, 3, the 255/256/257 run, and larger cohorts), since a
carry-logic error surfaces exactly at a boundary where a new high bit
appears in some column's count.

## What remains

The remaining backends inherit the correct scalar reference and are
conformance-gated, but do not yet carry a specialized counter. NEON is
redundant with the SIMD path on the arm64 dispatch that matters; Metal
(a parallel per-column reduction) and BNNS (the matrix form) are
separate efforts whose dispatch overhead should be justified against a
measured workload before they are written. The conformance test gates
each of them the moment a specialized counter lands.

After the backends comes the LocusKit hierarchy decision, the two-bundle
materialization (the first real caller of the fold, which is where a
benchmark of the SIMD counter against the reference becomes meaningful),
and the deep-delete encapsulation with the three erasure verbs, per the
decision record.

## Open obligation, deferred to CognitionKit

A separate concern from correctness: on massive trees the SIMD vertical
counter may not stay the fastest choice, and the dispatcher may need a
throttle that falls back to another method past some size or density.
Determining whether and where that crossover exists needs a benchmark
harness, not more correctness work.

This is parked until CognitionKit, on purpose. The fold's first real
caller and its scaled hot path live there, so that is where a harness
has a workload to measure against. The deferral is safe because the
choice of backend is a speed decision that the conformance gate already
forces to be data-identical, so the optimization is isolated to a lower
layer and cannot affect any kit built on top of it. When CognitionKit
exercises the fold at scale, the harness measures the crossover and the
dispatcher gains a throttle if one is warranted.
